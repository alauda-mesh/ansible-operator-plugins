---
name: fix-image-vulns
description: 修复 ansible-operator 镜像的安全漏洞。输入一个 Alauda Release 流水线 run（ID 或 URL）或明确的镜像地址，完成：调内部扫描服务检测漏洞并分类、按途径修复（构建 go 版本 / go.mod 依赖 / python 库 patch）、创建 PR 并监控流水线、对新镜像回归扫描（最多 3 轮修复），os 级漏洞只报告不修复。仅限用户显式通过 /fix-image-vulns 调用。
argument-hint: "[RUN_ID | run URL | 镜像地址]，例如: build-harbor.alauda.cn/asm/ansible-operator:main"
disable-model-invocation: true
---

# 修复 ansible-operator 镜像漏洞

对指定镜像做漏洞扫描，按修复责任分类处理，直到镜像干净或达到轮次上限。
下文的 `$SKILL_DIR` 指本 skill 的根目录（即调用时提示的 Base directory）。

## 参数

- `$0`：Alauda Release 流水线 run（纯数字 ID 或 run URL），或完整镜像地址（如 `build-harbor.alauda.cn/asm/ansible-operator:main`）。

参数为空时用 AskUserQuestion 向用户询问，不要自行猜测。

## 背景知识

镜像由三层来源组成，漏洞的修复责任对应不同途径：

| 来源 | 漏洞表现 | 处理 |
| --- | --- | --- |
| runner-base 基础镜像（apko 构建，每周自动重建） | 扫描结果 `.os[]`（glibc 等 os 包） | **不修复**，最终汇报中如实列出即可 |
| go 二进制 `ansible-operator`（builder 阶段编译） | `lang` 中 Target 为二进制路径 | stdlib → 升级 `alauda/Dockerfile` 构建 go 版本；依赖库 → 升级 `go.mod` |
| python 栈（`openshift/requirements*.txt` 经 `alauda/patch.sh` sed 强升后安装） | `lang` 中 Target 为 Python | 在 `alauda/patch.sh` 增改 sed 行强升版本 |

- 本仓库有 `origin`（alauda-mesh）和 `upstream`（openshift）两个 remote，**gh 命令必须显式指定 `--repo`**（skill 脚本已内置）。
- 全程禁止 `git commit --amend`，一律创建新 commit。步骤 3 之前不要 push、不要建 PR。
- go 构建是 vendor 模式，`go.mod` 升级必须连带 `go mod vendor`（`gomod-bump.sh` 已包含）。
- 修复轮次上限 3 轮（首轮 + 回归后最多再修 2 次），修不完就如实汇报。

## 步骤 1：漏洞检测

```bash
bash "$SKILL_DIR/scripts/resolve-image.sh" <用户输入>       # 输出 IMAGE=<镜像>
bash "$SKILL_DIR/scripts/scan-image.sh" <镜像> <scratchpad>/scan-round1.json
bash "$SKILL_DIR/scripts/classify-vulns.sh" <scratchpad>/scan-round1.json
```

扫描服务通常十几秒返回，但首次扫描未缓存的镜像可能要几分钟，Bash 调用把 timeout 设为 600000。无论结果如何，都先向用户输出扫描摘要（总数、各分类计数、关键漏洞列表）。然后按 `RESULT:` 分支：

- **CLEAN**：镜像无漏洞，汇报后直接结束；
- **REPORT_ONLY**：只有 os 级漏洞（runner-base 层），列出漏洞明细并说明"属 runner-base，不在本次修复范围"，结束；
- **FIX_NEEDED**：继续步骤 2。

## 步骤 2：修复

先基于目标分支创建修复分支（要求工作区干净；目标分支一般是 `main`，除非用户另有指定）：

```bash
git fetch origin && git checkout -b fix/image-vulns-$(date +%F) origin/main
```

按分类逐项修复。参考分类输出中"按包聚合"一节确定每个包的目标版本：同一库有多个修复候选时，选**能覆盖该库全部 CVE 的最低稳定版本**（保守升级，减少破坏性）。候选全是 rc/预发布版本时，先查上游是否已发布对应稳定版——扫描库的 FixedVersion 常滞后于实际发布（python 包：`curl -s https://pypi.org/pypi/<包名>/json | jq -r '.releases | keys[]' | sort -V | tail`）；有稳定版就用稳定版，确实只有预发布时停下来问用户（pin 预发布有稳定性风险）。

### 2.1 GO_STDLIB → 升级构建 go 版本

`alauda/Dockerfile` builder 阶段用 wolfi 的 `apk add go-1.26` 安装 go（版本号在包名里）。对照 stdlib 漏洞的修复版本：

- 修复版本仍在当前 minor 内（如 1.26.x）：wolfi 的 `go-1.26` 包滚动更新，**无需改文件**，重新构建即可带上最新 patch 版。用 `git commit --allow-empty -m "fix(alauda): rebuild to pick up patched go toolchain"` 记录意图；
- 需要更高 minor（如 1.27）：把包名改成 `go-1.27`。可先确认 wolfi 是否已提供该包：
  `curl -s https://packages.wolfi.dev/os/x86_64/APKINDEX.tar.gz | tar -xzO APKINDEX | grep -E '^P:go-1\.' | sort -u`

### 2.2 GO_MODULE → 升级 go.mod 依赖

```bash
bash "$SKILL_DIR/scripts/gomod-bump.sh" <module@version> [module@version ...]
```

脚本执行 go get → tidy → vendor → build 并验证构建。构建失败时分析原因（常见：依赖间版本冲突、新版本要求更高 go 版本、API 变更导致编译错误），能明确解决就解决，拿不准就带着报错向用户提问，不要凭猜测大版本连锁升级。

### 2.3 PYTHON → 通过 alauda/patch.sh 强升

先用 `grep -rn '<包名>==' openshift/requirements*.txt` 确认该包 pin 在哪个文件，然后编辑 `alauda/patch.sh`（参考文件内已有写法和 `git log --oneline -- alauda/patch.sh` 的历史修复记录）：

- 已有该包的 `-e 's/^pkg==.*$/pkg==x.y.z/'` 行 → 直接改目标版本号；
- 没有 → 在对应目标文件的 sed 块里新增 `-e` 行；该文件还没有 sed 块则仿照现有块新建；
- 注意文件顶部 NOTE：修 `jaraco.context`/`wheel`（requirements-build.txt）时必须同步升级 `setuptools`；
- 改完执行 `bash alauda/patch.sh`，确认末尾 diff 显示新版本已生效（它只写 gitignore 的 `alauda/openshift/`，可放心运行）。

### 提交

每个途径的修复各自独立 commit，方便 review 与回退（建议 message）：

- 2.1：`fix(alauda): bump build go version to fix stdlib CVEs`
- 2.2：`fix: bump vulnerable go modules`
- 2.3：`fix(alauda): bump vulnerable python libs`

## 步骤 3：创建 PR 并监控 Alauda Release 流水线

把 PR 描述写进临时文件（scratchpad 下，如 `pr-body.md`）：扫描摘要（镜像、漏洞分类计数）+ 修复清单（每项：包、版本变化、对应 CVE）+ 结尾一行 `🤖 Generated with [Claude Code](https://claude.com/claude-code)`。然后：

```bash
bash "$SKILL_DIR/scripts/create-pr.sh" <目标分支> <PR正文文件>
```

脚本会 push 修复分支并创建 PR（分支已有 PR 时幂等复用，迭代轮只推新 commit），输出 `PR_NUMBER=` 与 `PR_URL=`。

接着监控流水线。self-hosted runner 的多平台构建通常需要 10～30 分钟，**必须用后台方式运行**（Bash 工具的 `run_in_background: true`），完成后会收到通知：

```bash
bash "$SKILL_DIR/scripts/watch-release.sh"
```

脚本按当前 HEAD 的 sha 精确匹配 run（迭代修复多次 push 也不会误拿旧 run）。按退出结果处理：

- **PIPELINE_SUCCESS（退出码 0）**：输出中含本次构建镜像名（`…:<tag>-pr.<PR号>`），进入步骤 4；
- **PIPELINE_FAILED（退出码 2）**：脚本已附失败 step 概览与日志摘要。**分析失败原因**：判断是本次修复引入（如 go 依赖升级编译错、patch.sh 的 sed 模式失配、pip 装不上新版本）还是环境问题（runner、registry、代理）。修复方向拿不准时向用户提问，不要盲目改了就重推；
- **PIPELINE_TIMEOUT（退出码 3）**：告知用户流水线仍在运行，附 run 链接；
- **PIPELINE_NOT_FOUND（退出码 4）**：按脚本提示排查，如实告知用户。

## 步骤 4：回归扫描与迭代

流水线成功后，对**新构建的 PR 镜像**再次扫描（复用步骤 1 的 scan + classify，结果存 `scan-round2.json` 等按轮递增）：

- **CLEAN / REPORT_ONLY**：修复完成，进入最终汇报；
- **FIX_NEEDED**：先分析为什么还有漏洞（上轮目标版本仍带 CVE？升级未生效？新版本引入新漏洞？），再回到步骤 2 继续修（不新建分支，在现有 fix 分支上追加 commit → 重跑 create-pr.sh push → 后台 watch → 再扫描）。

**最多 3 轮修复**。到限仍未清零时停止，如实汇报剩余漏洞、已尝试的措施和失败原因，让用户决策。

## 最终汇报

用清晰列表汇报：

1. 目标镜像与初次扫描摘要（总数、分类计数）；
2. 修复清单：每项包名、版本变化、覆盖的 CVE、所在 commit；
3. 剩余未修复项：os 级漏洞明细（如实报告，注明属 runner-base 不在修复范围）、修不掉的项及原因；
4. PR 链接、流水线结果、最终镜像名与回归扫描结论。

不要自行 merge PR，等用户 review。
