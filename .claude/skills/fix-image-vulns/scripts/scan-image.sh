#!/bin/bash
# 步骤 1b：调用内部扫描服务对镜像做漏洞扫描（主备自动切换），保存原始结果 JSON
# 用法: scan-image.sh <完整镜像地址> <输出JSON文件>
# 环境变量:
#   SCAN_API_PRIMARY  主扫描服务，默认 http://192.168.141.42:8888
#   SCAN_API_BACKUP   备扫描服务，默认 http://192.168.25.100:8888（该地址的服务容易故障）
#   SCAN_API          显式指定单一服务，跳过主备探测与切换，用于调试
#   MAX_ATTEMPTS      单个服务最多尝试次数，默认 3
#   RETRY_DELAY       重试间隔秒数，默认 15
#   SCAN_TIMEOUT      单次请求超时秒数，默认 240
# 主备策略（与 .github/scripts/scan-image.sh 保持一致）:
#   先探测主服务，可达则主为首选、备作后援；主不可达则降级用备；均不可达直接失败。
#   扫描阶段当前服务连续 MAX_ATTEMPTS 次失败后自动切换到下一个服务。
# 退出码: 0=扫描完成并已保存（无论有无漏洞） 1=参数错误或服务连续失败
# 注意: 服务端要拉取镜像再扫描，单次可能需要几分钟，调用方应设置较长的命令超时

set -euo pipefail

die() { echo "错误: $*" >&2; exit 1; }

[[ $# -ge 2 ]] || die "用法: scan-image.sh <完整镜像地址> <输出JSON文件>"
IMAGE_ADDR="$1"
OUT_FILE="$2"
SCAN_API_PRIMARY="${SCAN_API_PRIMARY:-http://192.168.141.42:8888}"
SCAN_API_BACKUP="${SCAN_API_BACKUP:-http://192.168.25.100:8888}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
RETRY_DELAY="${RETRY_DELAY:-15}"
SCAN_TIMEOUT="${SCAN_TIMEOUT:-240}"

command -v jq >/dev/null 2>&1 || die "找不到 jq"
mkdir -p "$(dirname "${OUT_FILE}")"

# 服务是否可达：能返回任意 HTTP 状态码即算在线（连接被拒/超时时 curl 输出 000）
probe_api() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 -m 10 "$1/" 2>/dev/null || true)"
  [[ -n "${code}" && "${code}" != "000" ]]
}

# 选定扫描服务顺序：优先主地址，失效切备（SCAN_API 显式指定时跳过探测）
APIS=()
if [[ -n "${SCAN_API:-}" ]]; then
  APIS=("${SCAN_API}")
  echo "==> 使用显式指定的扫描服务: ${SCAN_API}" >&2
elif probe_api "${SCAN_API_PRIMARY}"; then
  APIS=("${SCAN_API_PRIMARY}" "${SCAN_API_BACKUP}")
  echo "==> 使用主扫描服务: ${SCAN_API_PRIMARY}（备用: ${SCAN_API_BACKUP}）" >&2
elif probe_api "${SCAN_API_BACKUP}"; then
  APIS=("${SCAN_API_BACKUP}")
  echo "==> 主扫描服务不可达（${SCAN_API_PRIMARY}），切换到备用: ${SCAN_API_BACKUP}" >&2
else
  die "主备扫描服务均不可达: ${SCAN_API_PRIMARY} / ${SCAN_API_BACKUP}"
fi

# 镜像地址 URL 编码后拼接扫描请求（参数与 .github/scripts/scan-image.sh 保持一致）
encoded="$(jq -rn --arg v "${IMAGE_ADDR}" '$v|@uri')"

# 扫描服务可能不稳定：单次成功标准 = HTTP 2xx 且响应能被 jq 解析出 os/lang 字段；
# 当前服务连续 MAX_ATTEMPTS 次失败后切换到下一个服务
resp=""
for api in "${APIS[@]}"; do
  url="${api}/image/vulnerability/custom?image_full_address=${encoded}&trivy_db_date=latest&severity=low&vulnerability_type=os%2Clibrary&version=v4.4.0"
  for i in $(seq 1 "${MAX_ATTEMPTS}"); do
    echo "==> 扫描尝试 ${i}/${MAX_ATTEMPTS}（服务 ${api}）: ${IMAGE_ADDR}" >&2
    if resp="$(curl -sS --fail --max-time "${SCAN_TIMEOUT}" -H 'accept: application/json' "${url}")" \
       && jq -e 'has("os") and has("lang")' <<<"${resp}" >/dev/null 2>&1; then
      break 2
    fi
    resp=""
    if [[ "${i}" -lt "${MAX_ATTEMPTS}" ]]; then
      echo "==> 本次扫描失败，${RETRY_DELAY}s 后重试" >&2
      sleep "${RETRY_DELAY}"
    fi
  done
  echo "==> 服务 ${api} 连续 ${MAX_ATTEMPTS} 次失败，尝试切换下一个服务" >&2
done

[[ -n "${resp}" ]] || die "所有扫描服务均失败: ${IMAGE_ADDR}（已尝试: ${APIS[*]}）"

printf '%s\n' "${resp}" > "${OUT_FILE}"
total="$(jq '((.os // []) + (.lang // [])) | length' <<<"${resp}")"
echo "RESULT: SCAN_OK image=${IMAGE_ADDR} total=${total} file=${OUT_FILE}"
