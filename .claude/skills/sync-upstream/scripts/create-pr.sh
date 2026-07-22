#!/bin/bash
# 步骤 5a：push 同步分支并创建 PR
# 用法: create-pr.sh <上游分支> <目标分支> [PR正文文件]
# 幂等：若当前分支已存在 PR，直接复用并输出其信息
# 退出码: 0=成功（输出 PR_NUMBER= 与 PR_URL=） 1=前置条件失败

set -euo pipefail

die() { echo "错误: $*" >&2; exit 1; }

[[ $# -ge 2 ]] || die "用法: create-pr.sh <上游分支> <目标分支> [PR正文文件]"
UPSTREAM_BRANCH="$1"
TARGET_BRANCH="$2"
BODY_FILE="${3:-}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "当前目录不在 git 仓库内"
cd "${REPO_ROOT}"

CUR_BRANCH="$(git branch --show-current)"
[[ "${CUR_BRANCH}" == sync/* ]] || die "当前分支 ${CUR_BRANCH} 不是 sync/* 同步分支，请先完成步骤 1"
[[ -z "$(git status --porcelain)" ]] || die "工作区不干净，请先提交所有改动"
[[ -z "${BODY_FILE}" || -f "${BODY_FILE}" ]] || die "PR 正文文件不存在: ${BODY_FILE}"

command -v gh >/dev/null 2>&1 || die "找不到 gh CLI"
gh auth status >/dev/null 2>&1 || die "gh 未认证。请提示用户在会话中执行: ! gh auth login"

# 本仓库有 origin/upstream 两个 remote，gh 未 set-default 时会把仓库解析到
# upstream（openshift），因此所有 gh 命令显式指定 --repo（从 origin URL 推导）
ORIGIN_URL="$(git remote get-url origin 2>/dev/null)" || die "找不到 origin remote"
REPO_SLUG="$(sed -E 's#^(https://[^/]+/|git@[^:]+:|ssh://git@[^/]+(:[0-9]+)?/)##; s#\.git$##' <<<"${ORIGIN_URL}")"
[[ "${REPO_SLUG}" == */* ]] || die "无法从 origin URL 解析仓库名: ${ORIGIN_URL}"

echo "==> push ${CUR_BRANCH} 到 origin ..."
git push -u origin "${CUR_BRANCH}"

# 已存在 PR 则复用（幂等，便于失败后重跑）
if PR_INFO="$(gh pr view "${CUR_BRANCH}" --repo "${REPO_SLUG}" --json number,url --jq '"\(.number) \(.url)"' 2>/dev/null)" && [[ -n "${PR_INFO}" ]]; then
  echo "==> 分支 ${CUR_BRANCH} 已存在 PR，直接复用"
else
  TITLE="chore(sync): merge upstream/${UPSTREAM_BRANCH} ($(date +%F))"
  if [[ -n "${BODY_FILE}" ]]; then
    gh pr create --repo "${REPO_SLUG}" --base "${TARGET_BRANCH}" --head "${CUR_BRANCH}" --title "${TITLE}" --body-file "${BODY_FILE}" >/dev/null
  else
    # 兜底正文：合入的上游提交列表
    BODY="$(printf '同步上游 openshift/ansible-operator-plugins 的 %s 分支。\n\n```\n%s\n```\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n' \
      "${UPSTREAM_BRANCH}" "$(git log --oneline "origin/${TARGET_BRANCH}..HEAD" | head -20)")"
    gh pr create --repo "${REPO_SLUG}" --base "${TARGET_BRANCH}" --head "${CUR_BRANCH}" --title "${TITLE}" --body "${BODY}" >/dev/null
  fi
  PR_INFO="$(gh pr view "${CUR_BRANCH}" --repo "${REPO_SLUG}" --json number,url --jq '"\(.number) \(.url)"')"
fi

PR_NUMBER="${PR_INFO%% *}"
PR_URL="${PR_INFO##* }"
echo ""
echo "PR_NUMBER=${PR_NUMBER}"
echo "PR_URL=${PR_URL}"
