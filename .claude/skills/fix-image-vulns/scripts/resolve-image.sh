#!/bin/bash
# 步骤 1a：把用户输入解析为完整镜像地址
# 用法: resolve-image.sh <RUN_ID | run URL | 镜像地址>
#   - 纯数字 / GitHub Actions run URL → 通过 gh 从该 run 的 "Output image: " 步骤名提取镜像
#   - 其他（含 / 或 :）→ 视为完整镜像地址直通
# 环境变量: FIX_VULNS_REPO 覆盖仓库（默认 alauda-mesh/ansible-operator-plugins，测试用）
# 输出: IMAGE=<镜像>；来源为流水线时额外输出 RUN_ID=<id>
# 退出码: 0=成功 1=失败

set -euo pipefail

die() { echo "错误: $*" >&2; exit 1; }

[[ $# -ge 1 && -n "${1}" ]] || die "用法: resolve-image.sh <RUN_ID | run URL | 镜像地址>"
INPUT="$1"
# 本仓库有 origin/upstream 两个 remote，gh 会把仓库错误解析到 upstream（openshift），
# 因此 gh 命令一律显式指定 --repo
REPO="${FIX_VULNS_REPO:-alauda-mesh/ansible-operator-plugins}"

RUN_ID=""
if [[ "${INPUT}" =~ ^[0-9]+$ ]]; then
  RUN_ID="${INPUT}"
elif [[ "${INPUT}" =~ /actions/runs/([0-9]+) ]]; then
  RUN_ID="${BASH_REMATCH[1]}"
fi

if [[ -n "${RUN_ID}" ]]; then
  command -v gh >/dev/null 2>&1 || die "找不到 gh CLI"
  gh auth status >/dev/null 2>&1 || die "gh 未认证。请提示用户在会话中执行: ! gh auth login"
  # Alauda Release 的构建 job 有一个名为 "Output image: <镜像>" 的步骤，
  # 从步骤名结构化提取比 grep 日志可靠（日志里的 BUILD_IMAGE= 可能是未展开的命令回显）
  IMAGE="$(gh run view "${RUN_ID}" --repo "${REPO}" --json jobs \
    --jq '.jobs[].steps[].name | select(startswith("Output image: ")) | sub("^Output image: "; "")' \
    | head -1)"
  [[ -n "${IMAGE}" ]] || die "run ${RUN_ID} 中没有 'Output image: ' 步骤：可能构建未完成/失败，或它不是 Alauda Release 流水线的 run"
  echo "RUN_ID=${RUN_ID}"
else
  [[ "${INPUT}" == */* || "${INPUT}" == *:* ]] || die "无法识别输入: ${INPUT}（应为 run ID、run URL 或完整镜像地址）"
  IMAGE="${INPUT}"
fi

echo "IMAGE=${IMAGE}"
