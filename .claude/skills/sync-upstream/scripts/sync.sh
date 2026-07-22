#!/bin/bash
# 步骤 1：同步上游代码
# 用法: sync.sh <上游分支> <目标分支>
# 行为:
#   - 确保 upstream remote 存在（不存在则自动添加）
#   - fetch upstream 和 origin
#   - 基于目标分支最新状态创建 sync/<日期> 分支
#   - 合并 upstream/<上游分支>
# 退出码: 0=合并成功或已是最新  1=前置条件失败  2=合并冲突（需要人工解决）
#
# 测试用环境变量: SYNC_UPSTREAM_URL 可覆盖默认 upstream 地址

set -euo pipefail

UPSTREAM_URL="${SYNC_UPSTREAM_URL:-https://github.com/openshift/ansible-operator-plugins.git}"

die() { echo "错误: $*" >&2; exit 1; }

[[ $# -eq 2 ]] || die "用法: sync.sh <上游分支> <目标分支>"
UPSTREAM_BRANCH="$1"
TARGET_BRANCH="$2"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "当前目录不在 git 仓库内"
cd "${REPO_ROOT}"

[[ -z "$(git status --porcelain)" ]] || die "工作区不干净，请先提交或 stash 后重试"

if ! git remote get-url upstream >/dev/null 2>&1; then
  git remote add upstream "${UPSTREAM_URL}"
  echo "==> 已添加 upstream remote: ${UPSTREAM_URL}"
fi

echo "==> fetch upstream / origin ..."
git fetch upstream
git fetch origin

git rev-parse --verify -q "refs/remotes/upstream/${UPSTREAM_BRANCH}" >/dev/null \
  || die "upstream 上不存在分支: ${UPSTREAM_BRANCH}"

# 目标分支基点：优先取 origin 上的最新状态，其次本地分支
if git rev-parse --verify -q "refs/remotes/origin/${TARGET_BRANCH}" >/dev/null; then
  BASE_REF="origin/${TARGET_BRANCH}"
elif git rev-parse --verify -q "refs/heads/${TARGET_BRANCH}" >/dev/null; then
  BASE_REF="${TARGET_BRANCH}"
else
  die "找不到目标分支: ${TARGET_BRANCH}（本地与 origin 均不存在）"
fi

SYNC_BRANCH="sync/$(date +%F)"
git rev-parse --verify -q "refs/heads/${SYNC_BRANCH}" >/dev/null \
  && die "分支 ${SYNC_BRANCH} 已存在（可能今天已同步过），请人工确认后再处理"

ORIG_BRANCH="$(git branch --show-current || true)"

echo "==> 基于 ${BASE_REF} 创建同步分支 ${SYNC_BRANCH}"
git checkout -b "${SYNC_BRANCH}" "${BASE_REF}"

# 记录合并前 HEAD，后续步骤用它计算本次同步引入的 diff
PREV_HEAD="$(git rev-parse HEAD)"
echo "${PREV_HEAD}" > "$(git rev-parse --git-dir)/SYNC_UPSTREAM_PREV_HEAD"

echo "==> 合并 upstream/${UPSTREAM_BRANCH} ..."
if ! git merge --no-edit "upstream/${UPSTREAM_BRANCH}"; then
  echo ""
  echo "==> RESULT: CONFLICT 合并存在冲突，需要人工解决。冲突文件："
  git diff --name-only --diff-filter=U
  echo ""
  echo "SYNC_BRANCH=${SYNC_BRANCH}"
  echo "PREV_HEAD=${PREV_HEAD}"
  exit 2
fi

if [[ "$(git rev-parse HEAD)" == "${PREV_HEAD}" ]]; then
  echo "==> RESULT: UP_TO_DATE 目标分支已包含 upstream/${UPSTREAM_BRANCH} 的全部提交，无需同步"
  # 清理刚创建的空同步分支
  git checkout "${ORIG_BRANCH:-${TARGET_BRANCH}}" >/dev/null 2>&1 || git checkout --detach "${BASE_REF}" >/dev/null 2>&1
  git branch -D "${SYNC_BRANCH}"
  exit 0
fi

MERGED_COUNT="$(git rev-list --count "${PREV_HEAD}..upstream/${UPSTREAM_BRANCH}")"
echo ""
echo "==> RESULT: MERGED 合并成功，无冲突"
echo "==> 本次合入 upstream 提交 ${MERGED_COUNT} 个，最近 20 个："
git log --oneline "${PREV_HEAD}..upstream/${UPSTREAM_BRANCH}" | head -20
echo ""
echo "==> 本次同步改动的文件（最多显示 40 行）："
git diff --stat "${PREV_HEAD}..HEAD" | tail -40
echo ""
echo "SYNC_BRANCH=${SYNC_BRANCH}"
echo "PREV_HEAD=${PREV_HEAD}"
