#!/bin/bash
# 步骤 1b：调用内部扫描服务对镜像做漏洞扫描，保存原始结果 JSON
# 用法: scan-image.sh <完整镜像地址> <输出JSON文件>
# 环境变量:
#   SCAN_API      扫描服务地址，默认 http://192.168.25.100:8888（与 .github/workflows 一致）
#   MAX_ATTEMPTS  最多尝试次数，默认 3
#   RETRY_DELAY   重试间隔秒数，默认 15
#   SCAN_TIMEOUT  单次请求超时秒数，默认 240
# 退出码: 0=扫描完成并已保存（无论有无漏洞） 1=参数错误或服务连续失败
# 注意: 服务端要拉取镜像再扫描，单次可能需要几分钟，调用方应设置较长的命令超时

set -euo pipefail

die() { echo "错误: $*" >&2; exit 1; }

[[ $# -ge 2 ]] || die "用法: scan-image.sh <完整镜像地址> <输出JSON文件>"
IMAGE_ADDR="$1"
OUT_FILE="$2"
SCAN_API="${SCAN_API:-http://192.168.25.100:8888}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
RETRY_DELAY="${RETRY_DELAY:-15}"
SCAN_TIMEOUT="${SCAN_TIMEOUT:-240}"

command -v jq >/dev/null 2>&1 || die "找不到 jq"
mkdir -p "$(dirname "${OUT_FILE}")"

# 镜像地址 URL 编码后拼接扫描请求（参数与 .github/scripts/scan-image.sh 保持一致）
encoded="$(jq -rn --arg v "${IMAGE_ADDR}" '$v|@uri')"
url="${SCAN_API}/image/vulnerability/custom?image_full_address=${encoded}&trivy_db_date=latest&severity=low&vulnerability_type=os%2Clibrary&version=v4.4.0"

# 扫描服务可能不稳定：单次成功标准 = HTTP 2xx 且响应能被 jq 解析出 os/lang 字段
resp=""
for i in $(seq 1 "${MAX_ATTEMPTS}"); do
  echo "==> 扫描尝试 ${i}/${MAX_ATTEMPTS}: ${IMAGE_ADDR}" >&2
  if resp="$(curl -sS --fail --max-time "${SCAN_TIMEOUT}" -H 'accept: application/json' "${url}")" \
     && jq -e 'has("os") and has("lang")' <<<"${resp}" >/dev/null 2>&1; then
    break
  fi
  resp=""
  if [[ "${i}" -lt "${MAX_ATTEMPTS}" ]]; then
    echo "==> 本次扫描失败，${RETRY_DELAY}s 后重试" >&2
    sleep "${RETRY_DELAY}"
  fi
done

[[ -n "${resp}" ]] || die "扫描服务连续 ${MAX_ATTEMPTS} 次失败: ${IMAGE_ADDR}（SCAN_API=${SCAN_API}）"

printf '%s\n' "${resp}" > "${OUT_FILE}"
total="$(jq '((.os // []) + (.lang // [])) | length' <<<"${resp}")"
echo "RESULT: SCAN_OK image=${IMAGE_ADDR} total=${total} file=${OUT_FILE}"
