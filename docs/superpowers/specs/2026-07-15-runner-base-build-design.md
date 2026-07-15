# runner-base 镜像构建流水线设计

**日期**：2026-07-15
**仓库**：`alauda-mesh/ansible-operator-plugins`（本地 `/home/vscode/repo/ansible-operator-plugins`）
**目标**：新增一条流水线，每周自动（+手动）构建最新 `latest` 的 runner-base 镜像，按需做镜像漏洞检查，并推送到 ghcr.io 与 build-harbor.alauda.cn。

---

## 1. 背景与需求

`alauda/base.apko.yaml` 用 apko 构建 runner-base 基础镜像（供上层 ansible-operator 的 `alauda/Dockerfile` 作为 `FROM` 基底）。本地构建方法见 `alauda/README.md`：apko publish 到 ghcr，再 skopeo/imagetools 拷贝到 build-harbor。

该镜像 tag 恒为 `latest`（无版本号、无 VERSION 文件），因此每次重建都是覆盖同一 tag。`base.apko.yaml` 未固定软件包版本，重新构建即可拉到修复后的上游包，从而消除漏洞。

**需求流程**：

1. 若开启漏洞检查，先扫 `build-harbor.alauda.cn/asm/ansible-operator-plugins/runner-base:latest`。
   1.1 无漏洞 → 流水线停止，输出 Summary。
   1.2 有漏洞 → 继续。
2. 构建 runner-base 镜像。
3. 推送到 ghcr.io 和 build-harbor.alauda.cn。
4. 复扫最新构建的 harbor `latest`，输出 Summary。

**触发时机**：

- 自动：每周五早 7 点（北京时间）构建，强制开启漏洞检查。
- 手动：GitHub Actions 页面 `Run workflow`，漏洞检查参数默认 `true`。

**已确认的两个决策**：

- 手动触发且漏洞检查参数为 `false` 时，**构建前扫描与构建后复扫全部跳过**——纯粹的快速重建通道。
- 构建并同步后复扫**仍发现漏洞**时，job 以**失败（标红）**结束——Actions 列表里一眼可见需人工介入（镜像仍会被推送，标红仅表示重建未能修复）。

---

## 2. 架构：三 job 混合 runner

```
precheck (self-hosted)          扫内网 harbor:latest,决定是否重建
    │  outputs: should_build / vuln_check
    ▼
build (ubuntu-latest)           apko-publish → ghcr.io latest (x86_64 + aarch64)
    │
    ▼
sync-verify (self-hosted)       ghcr→harbor 同步 + 复扫(按 digest) + Summary
```

三 job 用 `needs` + job outputs 串联，各自职责单一，失败点清晰。

**为什么必须拆三 job（硬约束，非偏好）**：

- **扫描 API（`http://192.168.25.100:8888`）与 `build-harbor.alauda.cn` 均为内网**，只有 self-hosted runner 可达 → `precheck` 与 `sync-verify` 必须跑在 self-hosted。
- **apko 多架构构建**要拉 wolfi 公网包（`packages.wolfi.dev`）和 `alauda-mesh.github.io/istio-base-images` 的 GitHub Pages keyring，GitHub 托管的 `ubuntu-latest` 直连公网最顺，且可复用 istio-base-images 已验证的 `chainguard-images/actions/apko-publish` 模式 → `build` 用 `ubuntu-latest`。
- **build-harbor 从 ubuntu-latest 不可达**（Alauda 内网 registry），所以 harbor 推送不能在 `build` job 完成，必须由 self-hosted 的 `sync-verify` 用 `docker buildx imagetools create` 从 ghcr 拷贝过去。这条硬约束正是三 job 拆分的根因。

需求"上传到 ghcr 和 build-harbor"由两 job 合成：`build` 推 ghcr，`sync-verify` 拷到 harbor。

**本设计不需要 gh CLI**：三 job 靠 `needs` + job outputs 串联，无跨 workflow 触发、无轮询等待，从而绕开 self-hosted runner 上 gh 版本过老的坑。

---

## 3. 触发与"漏洞检查"参数

```yaml
on:
  schedule:
    - cron: '0 23 * * 4'   # 周四 23:00 UTC = 周五 07:00 北京时间(UTC+8)
  workflow_dispatch:
    inputs:
      vulnerability_check:
        description: '是否进行镜像漏洞检查'
        type: boolean
        default: true
```

- **定时触发**：schedule 事件下 `inputs.*` 为空，`precheck` 判定 `github.event_name == 'schedule'` → `vuln_check=true`（强制检查）。
- **手动触发**：`vuln_check` 取 `inputs.vulnerability_check`，默认 `true`。
- **参数=false**：`precheck` 不扫描直接判 `should_build=true`；`sync-verify` 同步后不复扫。

cron 换算：北京时间（UTC+8）周五 07:00 − 8h = UTC 周四 23:00，cron day-of-week `4`=周四，故 `0 23 * * 4`。

---

## 4. 流程与 job 间数据流

### 4.1 precheck（self-hosted）

输出：`vuln_check`（归一化布尔字符串）、`should_build`。

步骤逻辑：

1. **确定 vuln_check**：`github.event_name == 'schedule'` → `true`；否则取 `inputs.vulnerability_check`。经 `env:` 传入、shell 变量引用，不拼接进 `run:`（防脚本注入）。
2. **决定 should_build 并写 Summary**：
   - `vuln_check == false` → `should_build=true`，Summary：`已跳过漏洞检查，直接重建`。
   - `vuln_check == true` → 调 `scan-image.sh` 扫 `build-harbor.alauda.cn/asm/ansible-operator-plugins/runner-base:latest`：
     - `clean=true`（os+lang 均空）→ `should_build=false`，Summary：`当前镜像无漏洞，流水线停止`。
     - `clean=false` → `should_build=true`，Summary：`发现漏洞，将重建` + 漏洞明细表。

### 4.2 build（ubuntu-latest，`if: needs.precheck.outputs.should_build == 'true'`）

`chainguard-images/actions/apko-publish@main` 用 `alauda/base.apko.yaml` 构建并推送多架构（x86_64+aarch64）镜像到 `ghcr.io/alauda-mesh/ansible-operator-plugins/runner-base:latest`（与 istio-base-images `_shared_publish.yaml` 已验证用法一致；版本引用沿用其 `@main`，实现阶段如需 pin 到具体 tag 可另行处理）。

- 权限：`packages: write`、`contents: read`、`id-token: write`。
- 凭证：`generic-user: ${{ github.repository_owner }}`、`generic-pass: ${{ secrets.GITHUB_TOKEN }}`。
- 无需 melange-build、无需 QEMU（base.apko.yaml 直接从 GitHub Pages apk 仓库拉预构建的 `alauda-baselayout`）。

### 4.3 sync-verify（self-hosted，`if: needs.precheck.outputs.should_build == 'true'`）

1. **登录** ghcr.io（`github.actor` + `GITHUB_TOKEN`，为拉取源镜像）与 build-harbor（`HARBOR_USERNAME/PASSWORD`）。
2. **同步**：`docker buildx imagetools create --tag build-harbor.alauda.cn/asm/ansible-operator-plugins/runner-base:latest ghcr.io/alauda-mesh/ansible-operator-plugins/runner-base:latest`（多架构 manifest + 跨 registry blob 拷贝，与 istio-base-images sync-harbor 同款、已验证）。
3. **复扫（仅当 `vuln_check == true`）**：先 `docker buildx imagetools inspect ... --format '{{.Manifest.Digest}}'` 取新 digest，按 `build-harbor.alauda.cn/asm/ansible-operator-plugins/runner-base@sha256:<digest>` 调 `scan-image.sh`：
   - `clean=true` → Summary：`重建后镜像无漏洞`。
   - `clean=false` → Summary：`重建后仍存在漏洞` + 明细表，然后 `exit 1` 使 job 标红。
4. `vuln_check == false` → Summary：`已构建并同步，未执行漏洞检查`。

---

## 5. 扫描机制与两个关键细节

**复用** istio-base-images 已实战验证的 `scan-image.sh`，原样移植到本仓库 `.github/scripts/scan-image.sh`：

- 单次超时 `SCAN_TIMEOUT=300`（5 分钟），最多 `MAX_ATTEMPTS=3` 次尝试，间隔 `RETRY_DELAY=30`——应对内部扫描服务不稳定。
- 单次成功标准 = HTTP 2xx 且响应可 jq 解析出 `os`/`lang` 字段。
- 无漏洞判定：`((.os // []) + (.lang // [])) | length == 0`。
- 有漏洞时按 `CVE+包名` 去重生成 Markdown 表（多行 output 用带进程号的 heredoc 分隔符）。
- 查询参数与 istio 一致：`trivy_db_date=latest&severity=low&vulnerability_type=os%2Clibrary&version=v4.4.0`。
- 用法：`scan-image.sh <完整镜像地址>`；必需 env `SCAN_API`、`GITHUB_OUTPUT`；输出 `clean`、`vulns_md` 到 `GITHUB_OUTPUT`。

**细节 1 — 复扫按 digest 而非 tag（防脏缓存误报）**：本任务 tag 恒为 `latest`，`precheck` 扫的旧 `latest` 与 `sync-verify` 扫的新 `latest` 是同一地址字符串。若扫描服务按地址缓存结果，复扫可能返回旧的（有漏洞）结果，造成误标红。故 `sync-verify` 同步后取新镜像 digest，按 `runner-base@sha256:...` 不可变地址扫描，保证扫的是新内容。（istio 那套用时间戳 tag 天然无此问题，本任务复用 `latest` 才需要这层防护。）

**细节 2 — Summary 输出**：三种结局均写 `$GITHUB_STEP_SUMMARY`——无漏洞停止 / 重建后已修复 / 重建后仍有漏洞（明细表 + 标红）。

---

## 6. 凭证、代理与 runner

| 用途 | 凭证/变量 | 来源 |
|---|---|---|
| 推 ghcr.io | `secrets.GITHUB_TOKEN` + job `packages: write` | 自带 |
| 推/拉 build-harbor | `secrets.HARBOR_USERNAME` / `secrets.HARBOR_PASSWORD` | 复用本仓库 `alauda-release.yaml` 现有 secret |
| 扫描 API 地址 | `SCAN_API=http://192.168.25.100:8888` | workflow env 常量 |
| 代理 | `vars.HTTP_PROXY` / `vars.HTTPS_PROXY` / `vars.NO_PROXY` | 复用本仓库现有大写命名 |

- self-hosted job（precheck / sync-verify）设置代理 env：拉 ghcr 走代理，访问内网 harbor 与扫描 API 由 `NO_PROXY` 直连。命名沿用本仓库 `alauda-release.yaml` 的大写 `vars.HTTP_PROXY`。
- `build` job 在 GitHub 托管 runner 上直连公网，无需代理。
- runner 标签：self-hosted job 用 `[self-hosted, linux, x64]`（与 `alauda-release.yaml` 一致）。

---

## 7. 文件清单

**新增（2 个）**：

- `.github/workflows/build-runner-base.yaml` — 三 job 主流水线（precheck / build / sync-verify）。
- `.github/scripts/scan-image.sh` — 扫描封装，移植自 istio-base-images（逐字复用，仅本任务无需改动其逻辑）。

无需 composite action（ghcr→harbor 同步为单条 imagetools 命令，YAGNI）。

---

## 8. 错误处理与边界

- **扫描服务连续 3 次失败** → `scan-image.sh` `exit 1`，precheck/sync-verify job 失败标红（无法判定漏洞状态，宁可失败也不误判为无漏洞）。
- **apko 构建失败** → build job 失败，sync-verify 因 `needs` 失败被跳过，不会推送半成品到 harbor。
- **should_build=false**（无漏洞）→ build 与 sync-verify 被 `if` 跳过，workflow 绿色结束，符合"无漏洞则停止"。
- **imagetools 同步失败** → sync-verify 失败标红，不进入复扫。
- **脚本注入防护**：所有 `${{ }}`（event_name、inputs、镜像地址片段）经 `env:` 传入，`run:` 内以带引号的 shell 变量引用，绝不直接拼接。

---

## 9. 测试与验证

- **静态检查**：`actionlint` 校验 workflow 语法；`bash -n` 与 `shellcheck` 校验 scan-image.sh。
- **手动 E2E**：合并后在 Actions 页面手动 `Run workflow`：
  - `vulnerability_check=true` 且当前 latest 有漏洞 → 预期走完整链路（扫描→构建→同步→复扫），Summary 三段齐全。
  - `vulnerability_check=true` 且当前 latest 无漏洞 → 预期 precheck 后即停，Summary 记"无漏洞停止"，build/sync-verify skipped。
  - `vulnerability_check=false` → 预期跳过所有扫描，直接构建+同步，Summary 记"未执行漏洞检查"。
- **errexit 陷阱注意**：GitHub 以 `bash -e {0}` 运行 `run:` 步骤；本设计无循环容错需求（三 job 各自独立，失败即失败），故无需 istio 那样的 `set +e` 隔离。若后续在单 step 内新增"允许失败再判 rc"的逻辑，须显式 `set +e`（本地务必用 `bash -e` 而非 `bash -c` 复现）。
