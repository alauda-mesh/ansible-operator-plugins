#!/bin/bash
# 步骤 3 辅助：检查 alauda/patch.sh 中的 python 库版本 patch 是否已过时
# 判定规则:
#   OBSOLETE — 同步后的上游版本 >= patch 目标版本，patch 已无必要，建议删除对应 -e 行
#   KEEP     — 上游版本仍低于 patch 目标版本，patch 需保留
#   BROKEN   — patch 的匹配模式在上游文件中找不到对应行，patch 不会生效，需人工确认
# 比较对象是仓库根目录 openshift/ 下的上游文件（即同步后的最新上游内容）。
# 本脚本只做检查与报告，不修改任何文件。

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "错误: 当前目录不在 git 仓库内" >&2; exit 1; }
cd "${REPO_ROOT}"

PATCH_FILE="alauda/patch.sh"
[[ -f "${PATCH_FILE}" ]] || { echo "错误: 找不到 ${PATCH_FILE}" >&2; exit 1; }

# 从 patch.sh 提取 sed patch 及其所在 sed 调用的目标文件。
# 输出（tab 分隔）:
#   V<TAB>库名<TAB>目标版本<TAB>文件   —— 版本类 patch: -e 's/^lib==.*$/lib==x.y.z/'
#   S<TAB>搜索文本<TAB>文件           —— 其他 sed patch: -e 's/搜索/替换/'
extract_patches() {
  awk '
    # 版本类 patch 行
    match($0, /s\/\^[A-Za-z0-9._-]+==[^\/]*\$\/[A-Za-z0-9._-]+==[0-9][^\/]*\//) {
      expr = substr($0, RSTART, RLENGTH)
      split(expr, a, "/")
      lib = a[3]; sub(/==.*/, "", lib)
      ver = a[3]; sub(/^[^=]+==/, "", ver)
      pend[++n] = "V\t" lib "\t" ver
      next
    }
    # 其他 -e sed patch 行（提取搜索文本）
    /-e[[:space:]]+'\''s\// {
      expr = $0
      sub(/.*'\''s\//, "", expr)
      split(expr, a, "/")
      pend[++n] = "S\t" a[1]
      next
    }
    # sed 调用的目标文件行，flush 之前累计的 -e 条目
    /\$\{SCRIPT_DIR\}\/openshift\/[^"]+"/ {
      file = $0
      sub(/.*\$\{SCRIPT_DIR\}\/openshift\//, "", file)
      sub(/".*/, "", file)
      for (i = 1; i <= n; i++) print pend[i] "\t" file
      n = 0
    }
  ' "${PATCH_FILE}"
}

# version_ge A B：A >= B 时返回 0（按版本号语义比较）
version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]
}

OBSOLETE_COUNT=0
BROKEN_COUNT=0
FOUND_ANY=0

echo "==> alauda/patch.sh patch 检查（与同步后的 openshift/ 上游文件比较）："
echo ""

while IFS=$'\t' read -r kind f1 f2 f3; do
  FOUND_ANY=1
  if [[ "${kind}" == "V" ]]; then
    lib="${f1}"; target="${f2}"; file="${f3}"
    src="openshift/${file}"
    if [[ ! -f "${src}" ]]; then
      echo "[BROKEN]   ${lib}==${target} @ ${file} —— 上游文件不存在，需人工确认"
      BROKEN_COUNT=$((BROKEN_COUNT + 1))
      continue
    fi
    current="$(grep -m1 -E "^${lib}==" "${src}" | sed -E 's/^[^=]+==//; s/[[:space:]].*$//' || true)"
    if [[ -z "${current}" ]]; then
      echo "[BROKEN]   ${lib}==${target} @ ${file} —— 上游文件中找不到 ^${lib}== 行，patch 不会生效，需人工确认"
      BROKEN_COUNT=$((BROKEN_COUNT + 1))
    elif version_ge "${current}" "${target}"; then
      echo "[OBSOLETE] ${lib}: 上游当前 ${current} >= patch 目标 ${target} @ ${file} —— 建议删除该 patch 行"
      OBSOLETE_COUNT=$((OBSOLETE_COUNT + 1))
    else
      echo "[KEEP]     ${lib}: 上游当前 ${current} <  patch 目标 ${target} @ ${file} —— patch 仍需保留"
    fi
  else
    search="${f1}"; file="${f2}"
    src="openshift/${file}"
    if [[ -f "${src}" ]] && grep -qF "${search}" "${src}"; then
      echo "[KEEP]     非版本类 patch @ ${file}: 's/${search}/...' 仍可匹配 —— 不属于版本检查范围，保持不变"
    else
      echo "[BROKEN]   非版本类 patch @ ${file}: 's/${search}/...' 已无法匹配上游内容，需人工确认"
      BROKEN_COUNT=$((BROKEN_COUNT + 1))
    fi
  fi
done < <(extract_patches)

if [[ "${FOUND_ANY}" -eq 0 ]]; then
  echo "（未在 alauda/patch.sh 中解析到任何 sed patch）"
fi

echo ""
echo "==> 汇总: OBSOLETE=${OBSOLETE_COUNT} BROKEN=${BROKEN_COUNT}"
if [[ "${OBSOLETE_COUNT}" -gt 0 ]]; then
  echo "    请删除上述 OBSOLETE 的 -e 行；若某个 sed 调用的所有 -e 行都被删除，"
  echo "    必须把整个 sed 调用块（含 \"\${SED}\" -i 行和文件行）一起删除，"
  echo "    否则残留的 'sed -i \"文件\"' 会把文件名当作 sed 表达式执行，属于严重错误。"
fi
if [[ "${BROKEN_COUNT}" -gt 0 ]]; then
  echo "    BROKEN 项不要自行修改，请停下来向用户确认。"
fi
