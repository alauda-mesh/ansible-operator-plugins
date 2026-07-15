# runner-base 镜像构建流水线 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 `alauda-mesh/ansible-operator-plugins` 新增一条流水线，每周五 07:00（北京）自动 +手动构建最新 `latest` runner-base 镜像，按需做镜像漏洞检查，并推送到 ghcr.io 与 build-harbor.alauda.cn。

**Architecture:** 三 job 混合 runner——`precheck`（self-hosted，扫内网 harbor 决定是否重建）→ `build`（ubuntu-latest，apko 多架构推 ghcr）→ `sync-verify`（self-hosted，ghcr→harbor 同步 + 按 digest 复扫）。三 job 用 `needs` + job outputs 串联，无跨 workflow 触发、无 gh CLI。

**Tech Stack:** GitHub Actions（schedule/workflow_dispatch、self-hosted + ubuntu-latest）、apko（`chainguard-images/actions/apko-publish`）、`docker buildx imagetools`、bash + jq + curl 扫描封装、内部 Trivy 扫描 API。

## Global Constraints

以下值逐字取自设计文档 `docs/superpowers/specs/2026-07-15-runner-base-build-design.md`，每个任务都隐含遵守：

- **ghcr 镜像地址**：`ghcr.io/alauda-mesh/ansible-operator-plugins/runner-base:latest`
- **harbor 镜像地址**：`build-harbor.alauda.cn/asm/ansible-operator-plugins/runner-base:latest`
- **扫描 API**：`SCAN_API=http://192.168.25.100:8888`
- **扫描查询参数**（scan-image.sh 内固定，逐字复用）：`trivy_db_date=latest&severity=low&vulnerability_type=os%2Clibrary&version=v4.4.0`
- **无漏洞判定**：响应 `os` 与 `lang` 数组合并后长度为 0。
- **定时 cron**：`0 23 * * 4`（周四 23:00 UTC = 周五 07:00 北京时间 UTC+8），schedule 触发强制漏洞检查。
- **手动参数**：`workflow_dispatch` 的 `vulnerability_check`（boolean，默认 `true`）。
- **参数=false 语义**：构建前扫描与构建后复扫**全部跳过**（纯快速重建通道）。
- **复扫按 digest**：`sync-verify` 同步后取新镜像 digest，按 `runner-base@sha256:...` 扫描，防 `latest` 复用导致的扫描服务脏缓存误报。
- **复扫仍有漏洞**：写 Summary 明细表后 `exit 1`，job 标红失败（镜像仍已推送）。
- **self-hosted runner 标签**：`[self-hosted, linux, x64]`（与 `alauda-release.yaml` 一致）。
- **apko 配置**：`alauda/base.apko.yaml`（已含 `archs: [x86_64, aarch64]`，无需向 action 传 archs；无 melange、无 QEMU）。
- **action 版本**：`actions/checkout@v6`、`docker/login-action@v4`、`chainguard-images/actions/apko-publish@main`（与 istio-base-images 已验证用法一致）。
- **凭证**：ghcr 用 `secrets.GITHUB_TOKEN`（job `packages: write`）；harbor 用 `secrets.HARBOR_USERNAME` / `secrets.HARBOR_PASSWORD`（复用本仓库现有 secret）。
- **代理**：self-hosted job 设 `http_proxy/https_proxy/no_proxy`，值取本仓库现有大写 `vars.HTTP_PROXY` / `vars.HTTPS_PROXY` / `vars.NO_PROXY`（NO_PROXY 覆盖内网 + `.cn`）；ubuntu-latest 的 build job 不设代理。
- **脚本注入防护**：所有 `${{ }}`（event_name、inputs、step/needs outputs）经 `env:` 传入，`run:` 内以带引号的 shell 变量引用，绝不直接拼接进脚本正文。
- **errexit**：GitHub 以 `bash -e {0}` 运行 `run:`；本流水线各 step 逻辑独立、失败即失败，无"允许失败再判 rc"的循环，故不需要 `set +e`。每个 `run:` 顶部显式 `set -euo pipefail`。

## 本地校验工具（执行阶段用）

`actionlint` 与 `shellcheck` 未预装，已下载到 scratchpad：

- actionlint：`/tmp/claude-1000/-home-vscode-repo-istio-base-images/c5678fcf-17c0-447a-b047-ac2ca293864a/scratchpad/actionlint`
- shellcheck：`/tmp/claude-1000/-home-vscode-repo-istio-base-images/c5678fcf-17c0-447a-b047-ac2ca293864a/scratchpad/shellcheck`

若 scratchpad 被清空，重新下载（已验证可达 github release）：

```bash
SP=/tmp/claude-1000/-home-vscode-repo-istio-base-images/c5678fcf-17c0-447a-b047-ac2ca293864a/scratchpad
mkdir -p "$SP" && cd "$SP"
curl -fsSL https://github.com/rhysd/actionlint/releases/download/v1.7.7/actionlint_1.7.7_linux_amd64.tar.gz | tar xz actionlint
curl -fsSL https://github.com/koalaman/shellcheck/releases/download/v0.10.0/shellcheck-v0.10.0.linux.x86_64.tar.xz | tar xJ --strip-components=1 shellcheck-v0.10.0/shellcheck
```

内部扫描 API（`192.168.25.100:8888`）在本 dev 环境不可达，故 scan-image.sh 用 **stub curl** 做本地冒烟测试（见 Task 1），不依赖真实网络。真实 E2E 见计划末尾。

---

### Task 1: 移植 scan-image.sh 并本地验证

从 istio-base-images 逐字移植已实战验证的扫描封装脚本（原版已通过 shellcheck + bash -n），在本仓库落地并用 stub curl 冒烟测试。

**Files:**
- Create: `/home/vscode/repo/ansible-operator-plugins/.github/scripts/scan-image.sh`

**Interfaces:**
- Produces: 可执行脚本 `.github/scripts/scan-image.sh <完整镜像地址>`。
  - 必需 env：`SCAN_API`、`GITHUB_OUTPUT`。可覆盖 env：`MAX_ATTEMPTS`（默认 3）、`RETRY_DELAY`（默认 30）、`SCAN_TIMEOUT`（默认 300）。
  - 向 `$GITHUB_OUTPUT` 追加：`clean=true|false`；`clean=false` 时追加多行 `vulns_md`（Markdown 明细表，按 `CVE+包名` 去重）。
  - 扫描服务连续失败（HTTP 非 2xx 或响应无 `os`/`lang` 字段）达 `MAX_ATTEMPTS` 次 → `exit 1`。
  - 被 Task 2 的 precheck 与 Task 3 的 sync-verify 调用。

- [ ] **Step 1: 基于 main 创建实现分支**

```bash
cd /home/vscode/repo/ansible-operator-plugins
git checkout main && git pull --ff-only 2>/dev/null || true
git checkout -b feat/runner-base-pipeline
```

- [ ] **Step 2: 创建脚本目录与文件（逐字移植）**

创建 `/home/vscode/repo/ansible-operator-plugins/.github/scripts/scan-image.sh`，内容与 istio-base-images 版本**逐字一致**：

```bash
#!/usr/bin/env bash
# 镜像漏洞扫描封装：调用内部扫描服务，带超时与重试，判定结果写入 GITHUB_OUTPUT。
#
# 用法：scan-image.sh <完整镜像地址>
# 必需 env：SCAN_API、GITHUB_OUTPUT
# 可覆盖 env：MAX_ATTEMPTS（默认 3）、RETRY_DELAY（默认 30 秒）、SCAN_TIMEOUT（默认 300 秒）
#
# 输出（GITHUB_OUTPUT）：
#   clean=true|false        os+lang 均为空即 true
#   vulns_md=<多行>         有漏洞时的 Markdown 明细表（按 CVE+包名去重）
set -euo pipefail

IMAGE_ADDR="${1:?用法: scan-image.sh <完整镜像地址>}"
: "${SCAN_API:?SCAN_API 未设置}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT 未设置}"
: "${MAX_ATTEMPTS:=3}"
: "${RETRY_DELAY:=30}"
: "${SCAN_TIMEOUT:=300}"

# 镜像地址做 URL 编码后拼接扫描请求
encoded="$(jq -rn --arg v "$IMAGE_ADDR" '$v|@uri')"
url="${SCAN_API}/image/vulnerability/custom?image_full_address=${encoded}&trivy_db_date=latest&severity=low&vulnerability_type=os%2Clibrary&version=v4.4.0"

# 内部扫描服务可能不稳定：单次超时上限 SCAN_TIMEOUT，最多 MAX_ATTEMPTS 次尝试；
# 单次成功标准 = HTTP 2xx 且响应可被 jq 解析出 os/lang 字段
resp=""
for i in $(seq 1 "$MAX_ATTEMPTS"); do
  echo "扫描尝试 ${i}/${MAX_ATTEMPTS}: ${IMAGE_ADDR}" >&2
  if resp="$(curl -sS --fail --max-time "$SCAN_TIMEOUT" -H 'accept: application/json' "$url")" \
     && jq -e 'has("os") and has("lang")' <<<"$resp" >/dev/null 2>&1; then
    break
  fi
  resp=""
  if [ "$i" -lt "$MAX_ATTEMPTS" ]; then
    echo "本次扫描失败，${RETRY_DELAY}s 后重试" >&2
    sleep "$RETRY_DELAY"
  fi
done

if [ -z "$resp" ]; then
  echo "扫描服务连续 ${MAX_ATTEMPTS} 次失败: ${IMAGE_ADDR}" >&2
  exit 1
fi

count="$(jq '((.os // []) + (.lang // [])) | length' <<<"$resp")"
if [ "$count" -eq 0 ]; then
  echo "clean=true" >> "$GITHUB_OUTPUT"
  echo "镜像无漏洞: ${IMAGE_ADDR}" >&2
else
  echo "clean=false" >> "$GITHUB_OUTPUT"
  # 生成去重后的 Markdown 明细表（多行 output 用 heredoc 分隔符语法，分隔符加进程号防注入）
  {
    echo "vulns_md<<EOF_VULNS_$$"
    echo "| CVE | 包名 | 当前版本 | 修复版本 | 严重度 |"
    echo "| --- | --- | --- | --- | --- |"
    jq -r '((.os // []) + (.lang // []))
      | unique_by(.VulnerabilityID + "/" + .PkgName)
      | .[] | "| \(.VulnerabilityID) | \(.PkgName) | \(.InstalledVersion) | \(.FixedVersion) | \(.Severity) |"' <<<"$resp"
    echo "EOF_VULNS_$$"
  } >> "$GITHUB_OUTPUT"
  echo "发现 ${count} 条漏洞记录（去重前）: ${IMAGE_ADDR}" >&2
fi
```

- [ ] **Step 3: 赋可执行权限**

```bash
chmod +x /home/vscode/repo/ansible-operator-plugins/.github/scripts/scan-image.sh
```

- [ ] **Step 4: 语法与静态检查**

```bash
SP=/tmp/claude-1000/-home-vscode-repo-istio-base-images/c5678fcf-17c0-447a-b047-ac2ca293864a/scratchpad
bash -n /home/vscode/repo/ansible-operator-plugins/.github/scripts/scan-image.sh && echo "SYNTAX OK"
"$SP/shellcheck" /home/vscode/repo/ansible-operator-plugins/.github/scripts/scan-image.sh && echo "SHELLCHECK CLEAN"
```

Expected: `SYNTAX OK` 与 `SHELLCHECK CLEAN` 均打印，无告警。

- [ ] **Step 5: 写 stub-curl 冒烟测试脚本（放 scratchpad，不入库）**

创建 `/tmp/claude-1000/-home-vscode-repo-istio-base-images/c5678fcf-17c0-447a-b047-ac2ca293864a/scratchpad/test-scan-image.sh`：

```bash
#!/usr/bin/env bash
# scan-image.sh 冒烟测试：用 stub curl 喂已知 JSON，断言 clean/vulns_md 输出契约。
set -euo pipefail
SCRIPT="${1:?用法: test-scan-image.sh <scan-image.sh 路径>}"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# 用例1：无漏洞（os/lang 空）→ clean=true
mkdir -p "$workdir/bin1"
cat >"$workdir/bin1/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"os":[],"lang":[],"secret":[],"config":[]}'
EOF
chmod +x "$workdir/bin1/curl"
out1="$workdir/out1"; : >"$out1"
PATH="$workdir/bin1:$PATH" SCAN_API="http://scan.test" GITHUB_OUTPUT="$out1" MAX_ATTEMPTS=1 RETRY_DELAY=1 "$SCRIPT" "example.com/img:latest"
grep -qx 'clean=true' "$out1" || { echo "FAIL case1: 期望 clean=true"; cat "$out1"; exit 1; }
echo "PASS case1 (无漏洞 → clean=true)"

# 用例2：有漏洞 → clean=false + 明细表含 CVE
mkdir -p "$workdir/bin2"
cat >"$workdir/bin2/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"os":[{"VulnerabilityID":"CVE-2026-6791","Severity":"UNKNOWN","PkgName":"glibc","InstalledVersion":"2.43-r7","FixedVersion":"2.43-r10"}],"lang":[],"secret":[],"config":[]}'
EOF
chmod +x "$workdir/bin2/curl"
out2="$workdir/out2"; : >"$out2"
PATH="$workdir/bin2:$PATH" SCAN_API="http://scan.test" GITHUB_OUTPUT="$out2" MAX_ATTEMPTS=1 RETRY_DELAY=1 "$SCRIPT" "example.com/img:latest"
grep -qx 'clean=false' "$out2" || { echo "FAIL case2: 期望 clean=false"; cat "$out2"; exit 1; }
grep -q 'CVE-2026-6791' "$out2" || { echo "FAIL case2: 期望明细表含 CVE"; cat "$out2"; exit 1; }
echo "PASS case2 (有漏洞 → clean=false + 表)"

# 用例3：扫描服务持续失败（curl 非0）→ exit 1
mkdir -p "$workdir/bin3"
cat >"$workdir/bin3/curl" <<'EOF'
#!/usr/bin/env bash
exit 22
EOF
chmod +x "$workdir/bin3/curl"
out3="$workdir/out3"; : >"$out3"
if PATH="$workdir/bin3:$PATH" SCAN_API="http://scan.test" GITHUB_OUTPUT="$out3" MAX_ATTEMPTS=2 RETRY_DELAY=1 "$SCRIPT" "example.com/img:latest"; then
  echo "FAIL case3: 期望非 0 退出"; exit 1
fi
echo "PASS case3 (扫描失败 → exit 1)"

echo "ALL SCAN TESTS PASSED"
```

- [ ] **Step 6: 运行冒烟测试**

```bash
SP=/tmp/claude-1000/-home-vscode-repo-istio-base-images/c5678fcf-17c0-447a-b047-ac2ca293864a/scratchpad
bash "$SP/test-scan-image.sh" /home/vscode/repo/ansible-operator-plugins/.github/scripts/scan-image.sh
```

Expected 末尾输出：`PASS case1 ...` / `PASS case2 ...` / `PASS case3 ...` / `ALL SCAN TESTS PASSED`。

- [ ] **Step 7: 提交（校验 git 记录了 100755 可执行位）**

```bash
cd /home/vscode/repo/ansible-operator-plugins
git add .github/scripts/scan-image.sh
git ls-files -s .github/scripts/scan-image.sh   # 期望前缀 100755
git commit -m "feat: add scan-image.sh vulnerability scan wrapper

从 istio-base-images 逐字移植:5 分钟超时 + 3 次重试,os/lang 判定,
按 CVE+包名去重的 Markdown 明细表。stub-curl 冒烟测试三用例通过。

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

Expected：`git ls-files -s` 输出以 `100755` 开头（可执行位已入库，workflow 可直接调用）。

---

### Task 2: build-runner-base.yaml 主体 + precheck job

创建 workflow 文件，含触发器、全局 env、以及 `precheck` job（self-hosted：判定漏洞检查、扫当前 harbor latest、输出 `should_build`/`vuln_check`、写 Summary）。此时 workflow 已是 actionlint-clean 的合法文件（只有 precheck 一个 job）。

**Files:**
- Create: `/home/vscode/repo/ansible-operator-plugins/.github/workflows/build-runner-base.yaml`

**Interfaces:**
- Consumes: `.github/scripts/scan-image.sh`（Task 1）。
- Produces: `precheck` job 的两个 outputs——`should_build`（`true`/`false`）、`vuln_check`（`true`/`false`）——供 Task 3 的 `build`、`sync-verify` 用 `needs.precheck.outputs.*` 引用。

- [ ] **Step 1: 创建 workflow 文件（触发器 + env + precheck job）**

创建 `/home/vscode/repo/ansible-operator-plugins/.github/workflows/build-runner-base.yaml`：

```yaml
name: Build runner-base image

on:
  schedule:
    - cron: '0 23 * * 4'   # 周四 23:00 UTC = 周五 07:00 北京时间(UTC+8)
  workflow_dispatch:
    inputs:
      vulnerability_check:
        description: '是否进行镜像漏洞检查'
        type: boolean
        default: true

env:
  GHCR_IMAGE: ghcr.io/alauda-mesh/ansible-operator-plugins/runner-base
  HARBOR_IMAGE: build-harbor.alauda.cn/asm/ansible-operator-plugins/runner-base
  SCAN_API: http://192.168.25.100:8888

concurrency:
  group: build-runner-base
  cancel-in-progress: false

jobs:
  precheck:
    name: 检查当前镜像漏洞
    runs-on: [self-hosted, linux, x64]
    env:
      http_proxy: ${{ vars.HTTP_PROXY }}
      https_proxy: ${{ vars.HTTPS_PROXY }}
      no_proxy: ${{ vars.NO_PROXY }}
    outputs:
      should_build: ${{ steps.decide.outputs.should_build }}
      vuln_check: ${{ steps.determine.outputs.vuln_check }}
    steps:
      - name: Checkout source
        uses: actions/checkout@v6

      - name: 确定是否进行漏洞检查
        id: determine
        env:
          EVENT_NAME: ${{ github.event_name }}
          INPUT_CHECK: ${{ inputs.vulnerability_check }}
        run: |
          set -euo pipefail
          # 定时触发强制检查;手动触发取输入(默认 true)
          if [ "$EVENT_NAME" = "schedule" ]; then
            vuln_check=true
          else
            vuln_check="$INPUT_CHECK"
          fi
          echo "vuln_check=${vuln_check}" >> "$GITHUB_OUTPUT"
          echo "vuln_check=${vuln_check}"

      - name: 扫描当前镜像
        id: scan
        if: steps.determine.outputs.vuln_check == 'true'
        run: |
          set -euo pipefail
          .github/scripts/scan-image.sh "${HARBOR_IMAGE}:latest"

      - name: 决定是否构建并写 Summary
        id: decide
        env:
          VULN_CHECK: ${{ steps.determine.outputs.vuln_check }}
          SCAN_CLEAN: ${{ steps.scan.outputs.clean }}
          VULNS_MD: ${{ steps.scan.outputs.vulns_md }}
        run: |
          set -euo pipefail
          if [ "$VULN_CHECK" != "true" ]; then
            echo "should_build=true" >> "$GITHUB_OUTPUT"
            {
              echo "## runner-base 构建"
              echo "已跳过漏洞检查，直接重建。"
            } >> "$GITHUB_STEP_SUMMARY"
          elif [ "$SCAN_CLEAN" = "true" ]; then
            echo "should_build=false" >> "$GITHUB_OUTPUT"
            {
              echo "## runner-base 漏洞检查"
              echo "当前镜像 \`${HARBOR_IMAGE}:latest\` 无漏洞，流水线停止。"
            } >> "$GITHUB_STEP_SUMMARY"
          else
            echo "should_build=true" >> "$GITHUB_OUTPUT"
            {
              echo "## runner-base 漏洞检查"
              echo "当前镜像 \`${HARBOR_IMAGE}:latest\` 发现漏洞，将重建："
              echo ""
              echo "$VULNS_MD"
            } >> "$GITHUB_STEP_SUMMARY"
          fi
```

- [ ] **Step 2: actionlint 校验**

```bash
SP=/tmp/claude-1000/-home-vscode-repo-istio-base-images/c5678fcf-17c0-447a-b047-ac2ca293864a/scratchpad
cd /home/vscode/repo/ansible-operator-plugins
"$SP/actionlint" .github/workflows/build-runner-base.yaml && echo "ACTIONLINT CLEAN"
```

Expected：`ACTIONLINT CLEAN`，无 error（表达式上下文、shell 引用、job 依赖均合法）。

- [ ] **Step 3: 人工核对 precheck 三分支逻辑**

对照检查（无命令，读代码确认）：
- `vuln_check != true` → `should_build=true`，Summary 记"已跳过漏洞检查"。
- `vuln_check == true` 且 `scan.clean == true` → `should_build=false`，Summary 记"无漏洞，流水线停止"。
- `vuln_check == true` 且 `scan.clean == false` → `should_build=true`，Summary 含漏洞表。
- 确认所有 `${{ }}` 均经 `env:` 传入、`run:` 内以 `"$VAR"` 引用（无直接拼接）。

- [ ] **Step 4: 提交**

```bash
cd /home/vscode/repo/ansible-operator-plugins
git add .github/workflows/build-runner-base.yaml
git commit -m "feat: add build-runner-base workflow precheck job

触发器(周五 07:00 北京定时 + 手动 vulnerability_check 默认 true)、全局 env、
precheck job:判定是否检查、扫当前 harbor latest、输出 should_build/vuln_check、
三分支写 Summary。actionlint clean。

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: build + sync-verify job（完成 workflow）

向 workflow 追加 `build`（ubuntu-latest：apko-publish 推 ghcr）与 `sync-verify`（self-hosted：ghcr→harbor 同步 + 按 digest 复扫 + Summary + 标红）两个 job，完成完整链路。

**Files:**
- Modify: `/home/vscode/repo/ansible-operator-plugins/.github/workflows/build-runner-base.yaml`（在 `precheck` job 之后追加两个 job）

**Interfaces:**
- Consumes: `needs.precheck.outputs.should_build`、`needs.precheck.outputs.vuln_check`（Task 2）；`.github/scripts/scan-image.sh`（Task 1）。
- Produces: 完整三 job 流水线（终态 workflow）。

- [ ] **Step 1: 追加 build job**

在 `build-runner-base.yaml` 末尾（`precheck` job 之后，保持 `jobs:` 缩进）追加：

```yaml
  build:
    name: 构建并推送到 GHCR
    needs: precheck
    if: needs.precheck.outputs.should_build == 'true'
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
      id-token: write
    steps:
      - name: Checkout source
        uses: actions/checkout@v6

      - name: Build and publish to GHCR
        uses: chainguard-images/actions/apko-publish@main
        with:
          config: alauda/base.apko.yaml
          tag: ${{ env.GHCR_IMAGE }}:latest
          generic-user: ${{ github.repository_owner }}
          generic-pass: ${{ secrets.GITHUB_TOKEN }}
          annotations: org.opencontainers.image.source:https://github.com/${{ github.repository }}
```

- [ ] **Step 2: 追加 sync-verify job**

紧接 `build` job 之后追加：

```yaml
  sync-verify:
    name: 同步到 Harbor 并复扫
    needs: [precheck, build]
    if: needs.precheck.outputs.should_build == 'true'
    runs-on: [self-hosted, linux, x64]
    env:
      http_proxy: ${{ vars.HTTP_PROXY }}
      https_proxy: ${{ vars.HTTPS_PROXY }}
      no_proxy: ${{ vars.NO_PROXY }}
    steps:
      - name: Checkout source
        uses: actions/checkout@v6

      - name: Log in to GHCR
        uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Login Harbor
        uses: docker/login-action@v4
        with:
          registry: build-harbor.alauda.cn
          username: ${{ secrets.HARBOR_USERNAME }}
          password: ${{ secrets.HARBOR_PASSWORD }}

      - name: 同步 GHCR → Harbor
        run: |
          set -euo pipefail
          # 多架构 manifest + 跨 registry blob 拷贝(与 istio-base-images sync-harbor 同款)
          docker buildx imagetools create \
            --tag "${HARBOR_IMAGE}:latest" \
            "${GHCR_IMAGE}:latest"

      - name: 复扫新镜像(按 digest)
        id: rescan
        if: needs.precheck.outputs.vuln_check == 'true'
        run: |
          set -euo pipefail
          # 取新镜像的不可变 digest,避免复用 latest tag 命中扫描服务脏缓存
          digest="$(docker buildx imagetools inspect "${HARBOR_IMAGE}:latest" --format '{{.Manifest.Digest}}')"
          case "$digest" in
            sha256:*) ;;
            *) echo "无法解析镜像 digest: '${digest}'" >&2; exit 1 ;;
          esac
          echo "新镜像 digest: ${digest}"
          .github/scripts/scan-image.sh "${HARBOR_IMAGE}@${digest}"

      - name: 汇报复扫结果
        if: needs.precheck.outputs.vuln_check == 'true'
        env:
          RESCAN_CLEAN: ${{ steps.rescan.outputs.clean }}
          RESCAN_VULNS_MD: ${{ steps.rescan.outputs.vulns_md }}
        run: |
          set -euo pipefail
          if [ "$RESCAN_CLEAN" = "true" ]; then
            {
              echo "## runner-base 重建复扫"
              echo "重建后镜像 \`${HARBOR_IMAGE}:latest\` 无漏洞，已修复。"
            } >> "$GITHUB_STEP_SUMMARY"
          else
            {
              echo "## runner-base 重建复扫"
              echo "重建后镜像 \`${HARBOR_IMAGE}:latest\` **仍存在漏洞**："
              echo ""
              echo "$RESCAN_VULNS_MD"
            } >> "$GITHUB_STEP_SUMMARY"
            exit 1
          fi

      - name: 汇报(未执行漏洞检查)
        if: needs.precheck.outputs.vuln_check != 'true'
        run: |
          set -euo pipefail
          {
            echo "## runner-base 构建"
            echo "已构建并同步到 GHCR 与 build-harbor(tag: latest)，未执行漏洞检查。"
          } >> "$GITHUB_STEP_SUMMARY"
```

> **digest 格式串说明**：`--format '{{.Manifest.Digest}}'` 是 Go 模板（无 `$` 前缀，非 GitHub Actions 表达式，actionlint 不解析它），照字面写入即可，输出多架构镜像顶层 index 的 `sha256:...` digest。若该 runner 上此格式串不产出 `sha256:` 前缀，`case` 分支会 `exit 1` 报错；备用方案：`docker buildx imagetools inspect "${HARBOR_IMAGE}:latest" | awk '/^Digest:/{print $2}'`。

- [ ] **Step 3: actionlint 校验完整 workflow**

```bash
SP=/tmp/claude-1000/-home-vscode-repo-istio-base-images/c5678fcf-17c0-447a-b047-ac2ca293864a/scratchpad
cd /home/vscode/repo/ansible-operator-plugins
"$SP/actionlint" .github/workflows/build-runner-base.yaml && echo "ACTIONLINT CLEAN"
```

Expected：`ACTIONLINT CLEAN`。确认写入文件里 digest 格式串是字面 `{{.Manifest.Digest}}`（非本文档的转义写法）。

- [ ] **Step 4: 人工核对完整数据流**

对照检查（读代码确认）：
- `should_build=false`（无漏洞）→ build 与 sync-verify 均因 `if` 跳过，workflow 绿色结束。
- `should_build=true` 且 build 成功 → sync-verify 运行；build 失败 → sync-verify 因 `needs` 失败而跳过（不同步半成品）。
- `vuln_check=true` → sync-verify 复扫；`clean=false` 时 `exit 1` 标红。
- `vuln_check=false` → sync-verify 只同步 + 走"未执行漏洞检查"汇报分支。
- 所有 `${{ }}` 经 `env:`/`with:` 传入，`run:` 内 `"$VAR"` 引用。

- [ ] **Step 5: 提交**

```bash
cd /home/vscode/repo/ansible-operator-plugins
git add .github/workflows/build-runner-base.yaml
git commit -m "feat: add build + sync-verify jobs to runner-base workflow

build(ubuntu-latest):apko-publish 多架构推 ghcr latest。
sync-verify(self-hosted):imagetools 同步 ghcr→harbor、按 digest 复扫、
三态 Summary(已修复/仍有漏洞标红/未检查)。完成三 job 完整链路。

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## 真实 E2E 验证（合并后手动，非本地）

本地无法访问内网扫描 API 与 harbor，完整链路须在 self-hosted runner 上跑。合并到 main 后，在 Actions 页面手动 `Run workflow` 验证三条路径：

1. **`vulnerability_check=true` 且当前 latest 有漏洞** → 预期完整链路（扫描→构建→同步→按 digest 复扫），Summary 三段齐全；若复扫已修复则绿色，若仍有漏洞则标红。
2. **`vulnerability_check=true` 且当前 latest 无漏洞** → 预期 precheck 后即停，Summary 记"无漏洞停止"，build/sync-verify 显示 skipped。
3. **`vulnerability_check=false`** → 预期跳过所有扫描，直接构建 + 同步，Summary 记"未执行漏洞检查"。

首跑重点核对：apko-publish 能用 `GITHUB_TOKEN` 推 ghcr；`imagetools create` ghcr→harbor 成功；`imagetools inspect --format '{{.Manifest.Digest}}'` 在该 runner 上产出 `sha256:` digest（否则用备用 awk 方案）。

---

## Self-Review 记录

- **Spec 覆盖**：§1 需求流程 → Task 2 precheck（步骤1无漏洞停止）+ Task 3（步骤2/3/4 构建、双推、复扫）；§2 三 job 架构 → Task 2+3；§3 触发与参数 → Task 2 触发器 + determine step；§4 数据流 → Task 2/3 job outputs；§5 扫描 + digest 细节 → Task 1 脚本 + Task 3 rescan step；§6 凭证代理 → Global Constraints + 各 job env；§7 文件清单 → Task 1+2+3；§8 错误处理 → 各 job `if`/`needs`/`exit 1`；§9 测试 → Task 内 gate + E2E 段。无遗漏。
- **占位符扫描**：无 TBD/TODO；所有代码步骤含完整代码。
- **类型一致性**：`should_build`/`vuln_check`/`clean`/`vulns_md` 命名在 Task 1→2→3 间一致；镜像地址、runner 标签、action 版本与 Global Constraints 一致。
