#!/bin/bash
# 步骤 5b：监控当前分支（PR）上的 "Alauda Release" 流水线
# 用法: watch-release.sh [分支名]（缺省为当前分支）
# 环境变量:
#   SYNC_WATCH_INTERVAL        轮询间隔秒数，默认 30
#   SYNC_WATCH_TIMEOUT         流水线完成等待上限秒数，默认 2400（40 分钟）
#   SYNC_WATCH_APPEAR_TIMEOUT  等待 run 出现的上限秒数，默认 180
# 退出码: 0=成功  1=前置失败  2=流水线失败（已附失败日志摘要）  3=等待超时  4=未发现流水线 run
# 注意：本脚本会阻塞较久，调用方应以后台方式运行。

set -euo pipefail

WORKFLOW="Alauda Release"
INTERVAL="${SYNC_WATCH_INTERVAL:-30}"
TIMEOUT="${SYNC_WATCH_TIMEOUT:-2400}"
APPEAR_TIMEOUT="${SYNC_WATCH_APPEAR_TIMEOUT:-180}"

die() { echo "错误: $*" >&2; exit 1; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "当前目录不在 git 仓库内"
cd "${REPO_ROOT}"
BRANCH="${1:-$(git branch --show-current)}"
[[ -n "${BRANCH}" ]] || die "无法确定分支名"

command -v gh >/dev/null 2>&1 || die "找不到 gh CLI"
gh auth status >/dev/null 2>&1 || die "gh 未认证。请提示用户在会话中执行: ! gh auth login"

# 本仓库有 origin/upstream 两个 remote，gh 未 set-default 时会把仓库解析到
# upstream（openshift），因此所有 gh 命令显式指定 --repo（从 origin URL 推导）
ORIGIN_URL="$(git remote get-url origin 2>/dev/null)" || die "找不到 origin remote"
REPO_SLUG="$(sed -E 's#^(https://[^/]+/|git@[^:]+:|ssh://git@[^/]+(:[0-9]+)?/)##; s#\.git$##' <<<"${ORIGIN_URL}")"
[[ "${REPO_SLUG}" == */* ]] || die "无法从 origin URL 解析仓库名: ${ORIGIN_URL}"

# 等待 run 出现（push/PR 刚创建时 run 可能尚未注册）
echo "==> 等待分支 ${BRANCH} 上的 '${WORKFLOW}' run 出现（最长 ${APPEAR_TIMEOUT}s）..."
START="$(date +%s)"
RUN_ID=""
while :; do
  RUN_ID="$(gh run list --repo "${REPO_SLUG}" --workflow "${WORKFLOW}" --branch "${BRANCH}" --limit 1 \
    --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true)"
  [[ -n "${RUN_ID}" ]] && break
  if (( $(date +%s) - START > APPEAR_TIMEOUT )); then
    echo "==> RESULT: PIPELINE_NOT_FOUND 在 ${APPEAR_TIMEOUT}s 内没有发现 '${WORKFLOW}' 的 run"
    echo "    可能原因: 1) PR 的 base 分支不是 main（该流水线的 pull_request 触发只针对 main）；"
    echo "             2) self-hosted runner 未在线；3) workflow 文件在该分支上有语法问题"
    exit 4
  fi
  sleep 10
done

RUN_URL="$(gh run view --repo "${REPO_SLUG}" "${RUN_ID}" --json url --jq .url)"
echo "==> 发现 run ${RUN_ID}: ${RUN_URL}"

# 轮询直至完成或超时
START="$(date +%s)"
LAST_STATUS=""
while :; do
  read -r STATUS CONCLUSION < <(gh run view --repo "${REPO_SLUG}" "${RUN_ID}" --json status,conclusion \
    --jq '"\(.status) \(.conclusion // "-")"' 2>/dev/null || echo "unknown -")
  if [[ "${STATUS}" != "${LAST_STATUS}" ]]; then
    echo "[$(date +%H:%M:%S)] status=${STATUS}"
    LAST_STATUS="${STATUS}"
  fi
  [[ "${STATUS}" == "completed" ]] && break
  if (( $(date +%s) - START > TIMEOUT )); then
    echo "==> RESULT: PIPELINE_TIMEOUT 等待超过 ${TIMEOUT}s 仍未完成，请稍后自行查看: ${RUN_URL}"
    exit 3
  fi
  sleep "${INTERVAL}"
done

if [[ "${CONCLUSION}" == "success" ]]; then
  # 从日志中提取产物镜像名（Output image 步骤输出的 BUILD_IMAGE=）；
  # 排除以 $ 或 " 开头的值，跳过 Actions 日志里未展开的命令回显 echo "BUILD_IMAGE=${IMAGE}"
  IMAGE="$(gh run view --repo "${REPO_SLUG}" "${RUN_ID}" --log 2>/dev/null | grep -m1 -oE 'BUILD_IMAGE=[^"$[:space:]]\S*' | cut -d= -f2- || true)"
  echo "==> RESULT: PIPELINE_SUCCESS ${RUN_URL}"
  [[ -n "${IMAGE}" ]] && echo "==> 构建镜像: ${IMAGE}"
  exit 0
fi

echo "==> RESULT: PIPELINE_FAILED conclusion=${CONCLUSION} ${RUN_URL}"
echo "==> 失败 job/step 概览："
gh run view --repo "${REPO_SLUG}" "${RUN_ID}" 2>/dev/null | grep -E "^(X|✓|-|\*)" | head -20 || true
echo ""
echo "==> 失败日志摘要（最后 120 行，完整日志用: gh run view --repo ${REPO_SLUG} ${RUN_ID} --log-failed）："
gh run view --repo "${REPO_SLUG}" "${RUN_ID}" --log-failed 2>/dev/null | tail -120 || echo "（拉取失败日志出错，请手动查看 ${RUN_URL}）"
exit 2
