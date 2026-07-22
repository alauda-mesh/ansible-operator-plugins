#!/bin/bash
# 步骤 4 辅助：汇总同步结果（分支、提交、版本号、工作区状态）
# 用法: report.sh [合并前的commit]

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "错误: 当前目录不在 git 仓库内" >&2; exit 1; }
cd "${REPO_ROOT}"

STATE_FILE="$(git rev-parse --git-dir)/SYNC_UPSTREAM_PREV_HEAD"
PREV_HEAD="${1:-$(cat "${STATE_FILE}" 2>/dev/null || true)}"

echo "==> 当前分支: $(git branch --show-current)"

VERSION_LINE="$(grep -oE 'ImageVersion = "[^"]+"' internal/version/version.go | head -1 || true)"
echo "==> internal/version/version.go: ${VERSION_LINE:-未找到 ImageVersion}"

if [[ -n "${PREV_HEAD}" ]] && git rev-parse --verify -q "${PREV_HEAD}^{commit}" >/dev/null; then
  echo "==> 本次同步引入提交数（含合并及后续提交）: $(git rev-list --count "${PREV_HEAD}..HEAD")"
  echo "==> 同步分支上的最近提交:"
  git log --oneline "${PREV_HEAD}..HEAD" | head -10
fi

echo "==> 工作区状态（应为空，若非空说明还有未提交改动）:"
git status --short | head -20
