---
name: sync-upstream
description: 同步上游 openshift/ansible-operator-plugins 指定分支到本仓库（alauda-mesh fork）的目标分支。完成五件事：merge 上游代码并创建 sync/<日期> 分支、把 openshift/Dockerfile 的新改动分析并同步到 alauda/Dockerfile、清理 alauda/patch.sh 中已过时的 python 库版本 patch、汇报同步后的 ImageVersion、创建 PR 并监控 Alauda Release 流水线（失败时分析原因）。仅限用户显式通过 /sync-upstream 调用。
argument-hint: "[上游分支] [目标分支]，例如: main main"
disable-model-invocation: true
---

# 同步上游代码（openshift → alauda-mesh）

把 https://github.com/openshift/ansible-operator-plugins 的指定分支同步到本仓库的目标分支。
下文的 `$SKILL_DIR` 指本 skill 的根目录（即调用时提示的 Base directory）。

## 参数

- 上游分支：`$0`（如 `main`、`release-5.0`）
- 目标分支：`$1`（如 `main`）

两个参数都必须明确。若上面任一处为空，用 AskUserQuestion 向用户询问（推荐默认：上游 `main`、目标 `main`），不要自行猜测。

## 背景知识

- 本仓库是 openshift/ansible-operator-plugins 的 fork，remote 名为 `upstream`；alauda 定制内容集中在 `alauda/` 目录、`.github/workflows/` 的部分改动和少量零散文件。
- `alauda/Dockerfile` 基于 `openshift/Dockerfile` 改造：builder 阶段换成了 wolfi-base + apk 安装 go；运行时基础镜像换成了 apko 构建的 `runner-base`（见 `alauda/base.apko.yaml`）；并包含 ACP 合规性改造（如 ansible 用户 GID 改为与 UID 相同）。因此上游 Dockerfile 的改动**不能照抄**，必须逐条分析适用性。
- `alauda/patch.sh` 会把 `openshift/` 拷贝为 `alauda/openshift/` 并用 sed 打 patch（主要是 python 库版本强升，用来满足漏洞扫描）。上游版本追上来之后，对应 patch 就该删掉。
- 全程禁止 `git commit --amend`，一律创建新 commit。步骤 5 之前不要 push、不要建 PR；步骤 5 只 push 同步分支本身并创建对应 PR，不做其他推送。

## 步骤 1：同步最新代码

```bash
bash "$SKILL_DIR/scripts/sync.sh" <上游分支> <目标分支>
```

脚本会自动：确保 upstream remote 存在 → fetch → 基于目标分支最新状态创建 `sync/<今天日期>` 分支 → merge `upstream/<上游分支>`。按退出结果处理：

- **MERGED（退出码 0）**：合并成功，继续步骤 2。
- **UP_TO_DATE（退出码 0）**：已是最新，无需同步。脚本已自动清理空分支，直接向用户汇报并结束（仍要输出步骤 4 的 ImageVersion）。
- **CONFLICT（退出码 2）**：出现合并冲突，需要你解决。原则：
  - alauda 定制内容（`alauda/` 目录、workflows 里的 alauda 专属改动等）要保留，上游的新增内容要合入，两者通常是"都要"而不是二选一；
  - 逐个文件看冲突上下文再决定，不要机械选 ours/theirs；
  - **只要有一个冲突拿不准，立即停下来向用户提问**（附上冲突片段和你的倾向方案），得到答复后再继续；
  - 解决完后 `git add <文件>` 并 `git commit --no-edit` 完成合并（禁止 amend）。
- **其他失败（退出码 1）**：前置条件问题（工作区不干净、当天同步分支已存在、分支不存在等），把脚本的报错原样告知用户并询问如何处理，不要擅自 stash 或删分支。

## 步骤 2：同步更新 alauda/Dockerfile

```bash
bash "$SKILL_DIR/scripts/check-dockerfile.sh"
```

脚本输出本次同步中 `openshift/Dockerfile` 的 diff（NO_CHANGE 则直接跳到步骤 3）。有改动时，先 Read 当前的 `alauda/Dockerfile`，然后**逐条**分析 diff 中的每个改动：

- 判断是否适用于 alauda/Dockerfile。常见情形：
  - 上游升级 golang 版本 → alauda 对应调整 wolfi 的 `go-x.y` 包版本（若已一致则无需改）；
  - 上游更换 RHEL/OCP 基础镜像 tag → alauda 使用 runner-base，通常不适用；
  - dnf/rpm/cachito 等 RHEL 生态特有改动 → wolfi/apk 体系通常不适用，但要想清楚其**意图**（如"删除某个有漏洞的包"）在 alauda 侧是否需要等价处理（如改 `alauda/base.apko.yaml`，改动 base.apko.yaml 时要在汇报中特别标注）；
  - 上游新增 COPY/ENV/入口逻辑 → 一般需要等价同步。
- 需要修改的就修改 `alauda/Dockerfile`，并且无论改不改，都要在最终汇报里给出**每一条改动的结论和理由**（方便用户 review）；
- 拿不准的改动，停下来向用户提问，不要凭猜测改；
- 若有修改，单独提交一个 commit（建议message：`chore(alauda): sync Dockerfile changes from openshift/Dockerfile`）。

## 步骤 3：清理 alauda/patch.sh 中过时的 patch

```bash
bash "$SKILL_DIR/scripts/check-patches.sh"
```

脚本会把 `alauda/patch.sh` 里的每个 sed patch 与同步后的上游文件比对，输出判定。本步骤**只删过时 patch，不新增 patch、不修漏洞**：

- **OBSOLETE**（上游版本 >= patch 目标版本）：用 Edit 从 `alauda/patch.sh` 删除对应 `-e` 行。注意：若一个 sed 调用的所有 `-e` 行都被删光，必须把整个调用块（`"${SED}" -i \` 到文件参数行）一起删除——残留 `sed -i "文件"` 会把文件名当 sed 表达式执行，属于严重错误；
- **KEEP**：保持不动；
- **BROKEN**（匹配不到上游内容）：不要自行修改，停下来向用户报告并提问；
- 删除后重跑一次 `check-patches.sh` 确认结果，再运行 `bash alauda/patch.sh` 验证脚本本身仍能正常执行（它只写 `alauda/openshift/`，是安全的；验证完后若 `alauda/openshift/` 出现在工作区，属于 gitignore 内容，无需处理）；
- 若有修改，单独提交一个 commit（建议 message：`chore(alauda): remove obsolete patches`）。

## 步骤 4：汇报

```bash
bash "$SKILL_DIR/scripts/report.sh"
```

综合前面各步骤，向用户汇报（用清晰的列表，这是用户 review 的依据）：

1. 同步分支名、合入的上游提交数、是否有冲突及解决方式；
2. `alauda/Dockerfile`：逐条列出上游 Dockerfile 改动 → 同步结论（改了什么 / 为什么不用改）；
3. `alauda/patch.sh`：删除了哪些 patch（含版本对比数据），或"全部保留"；
4. **同步后的 ansible-operator-plugins 版本**：`internal/version/version.go` 中的 `ImageVersion`（如 `v1.42.1`）。

汇报后继续执行步骤 5（UP_TO_DATE 时无 PR 可建，到此结束）。

## 步骤 5：创建 PR 并监控 Alauda Release 流水线

先把 PR 描述写进临时文件（scratchpad 下，如 `pr-body.md`）：内容取步骤 4 汇报的精简版（合入提交、Dockerfile 结论、patch 清理、ImageVersion），结尾加一行 `🤖 Generated with [Claude Code](https://claude.com/claude-code)`。然后：

```bash
bash "$SKILL_DIR/scripts/create-pr.sh" <上游分支> <目标分支> <PR正文文件>
```

脚本会 push 同步分支并创建 PR（分支已有 PR 时幂等复用），输出 `PR_NUMBER=` 与 `PR_URL=`。若报 gh 未认证，提示用户执行 `! gh auth login` 后重试。

接着监控流水线。self-hosted runner 的多平台镜像构建通常需要 10～30 分钟，**必须用后台方式运行**（Bash 工具的 `run_in_background: true`），完成后会收到通知：

```bash
bash "$SKILL_DIR/scripts/watch-release.sh"
```

按退出结果处理：

- **PIPELINE_SUCCESS（退出码 0）**：流水线成功，把输出中的构建镜像名（`build-harbor.alauda.cn/asm/ansible-operator:<tag>-pr.<PR号>`）加入最终汇报；
- **PIPELINE_FAILED（退出码 2）**：脚本已附失败 job/step 概览与失败日志摘要。**分析失败原因**：定位失败 step，结合日志判断是本次同步引入（如 Dockerfile 改动、patch.sh 清理、上游代码不兼容）还是环境问题（runner、registry 登录、代理、基础镜像拉取）。需要更多日志时用 `gh run view <run-id> --log-failed`。给出结论和建议的修复方向；修复涉及代码改动且拿不准时向用户提问，不要盲目改了就重推；
- **PIPELINE_TIMEOUT（退出码 3）**：告知用户流水线仍在运行，附 run 链接，之后可用 `gh run view <run-id>` 查看；
- **PIPELINE_NOT_FOUND（退出码 4）**：按脚本提示排查（常见：目标分支不是 main 时 `pull_request` 不触发该流水线、runner 不在线），如实告知用户。

最后补充汇报：PR 链接 + 流水线结果（成功镜像名 / 失败原因分析）。到此整个同步流程结束，等用户 review 与合并；不要自行 merge PR。
