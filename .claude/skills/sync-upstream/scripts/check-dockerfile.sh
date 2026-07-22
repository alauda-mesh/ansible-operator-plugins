#!/bin/bash
# 步骤 2 辅助：提取本次同步引入的 openshift/Dockerfile 改动
# 用法: check-dockerfile.sh [合并前的commit]
#   不传参数时读取 sync.sh 记录的合并前 HEAD（.git/SYNC_UPSTREAM_PREV_HEAD）
# 本脚本只输出 diff，不修改任何文件；是否需要同步到 alauda/Dockerfile 由调用方分析判断。

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "错误: 当前目录不在 git 仓库内" >&2; exit 1; }
cd "${REPO_ROOT}"

STATE_FILE="$(git rev-parse --git-dir)/SYNC_UPSTREAM_PREV_HEAD"
PREV_HEAD="${1:-$(cat "${STATE_FILE}" 2>/dev/null || true)}"
[[ -n "${PREV_HEAD}" ]] || { echo "错误: 未找到合并前 HEAD 记录，请显式传入: check-dockerfile.sh <合并前的commit>" >&2; exit 1; }
git rev-parse --verify -q "${PREV_HEAD}^{commit}" >/dev/null || { echo "错误: 无效的 commit: ${PREV_HEAD}" >&2; exit 1; }

echo "==> 本次同步（${PREV_HEAD:0:8}..HEAD）openshift/ 目录的改动概览："
git diff --stat "${PREV_HEAD}..HEAD" -- openshift/ | cat
echo ""
echo "    提示: openshift/ 下除 Dockerfile 以外的改动（如 install-ansible.sh、requirements*.txt）"
echo "    会经 alauda/patch.sh 拷贝自动生效，无需手工同步；只有 openshift/Dockerfile 的改动"
echo "    需要人工分析是否要移植到 alauda/Dockerfile。"
echo ""

if git diff --quiet "${PREV_HEAD}..HEAD" -- openshift/Dockerfile; then
  echo "==> RESULT: NO_CHANGE openshift/Dockerfile 无改动，alauda/Dockerfile 无需同步更新"
  exit 0
fi

echo "==> RESULT: CHANGED openshift/Dockerfile 改动如下，请逐条分析是否需要同步到 alauda/Dockerfile："
git diff "${PREV_HEAD}..HEAD" -- openshift/Dockerfile
