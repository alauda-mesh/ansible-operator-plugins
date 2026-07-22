#!/bin/bash
# 步骤 1c：解析扫描结果 JSON，把漏洞按修复责任分类
# 用法: classify-vulns.sh <扫描结果JSON文件>
# 分类规则（对应本仓库的修复途径）:
#   OS_REPORT_ONLY  .os[] 中的漏洞      → 属 runner-base 镜像 os 层，不修复，如实报告
#   GO_STDLIB       lang 中 PkgName=stdlib → 升级 alauda/Dockerfile 构建用 go 版本
#   GO_MODULE       lang 中 go 二进制内的依赖库 → 升级 go.mod（用 gomod-bump.sh）
#   PYTHON          lang 中 Target 为 Python  → 通过 alauda/patch.sh 强升版本
#   UNKNOWN         无法归类，需要人工判断
# 输出: 明细 + 按包聚合 + SUMMARY 计数行 + RESULT 行
#   RESULT: CLEAN        无任何漏洞
#   RESULT: REPORT_ONLY  只有 os 级漏洞（无可修复项）
#   RESULT: FIX_NEEDED   存在需要修复的漏洞
# 退出码: 0=解析成功（无论结论） 1=文件/解析错误

set -euo pipefail

die() { echo "错误: $*" >&2; exit 1; }

[[ $# -ge 1 ]] || die "用法: classify-vulns.sh <扫描结果JSON文件>"
SCAN_FILE="$1"
[[ -f "${SCAN_FILE}" ]] || die "文件不存在: ${SCAN_FILE}"
command -v jq >/dev/null 2>&1 || die "找不到 jq"
jq -e 'has("os") and has("lang")' "${SCAN_FILE}" >/dev/null 2>&1 \
  || die "不是有效的扫描结果 JSON（缺少 os/lang 字段）: ${SCAN_FILE}"

jq -r '
  def cat:
    if .__src == "os" then "OS_REPORT_ONLY"
    elif .PkgName == "stdlib" then "GO_STDLIB"
    elif ((.Target // "") | test("python|requirements"; "i")) then "PYTHON"
    elif ((.Target // "") | contains("/")) then "GO_MODULE"
    else "UNKNOWN"
    end;
  def order: {"OS_REPORT_ONLY":0,"GO_STDLIB":1,"GO_MODULE":2,"PYTHON":3,"UNKNOWN":4}[.];
  # 每条修复候选版本可能是逗号分隔的多值（跨多个发布线），拆开去重
  def fixes: [.FixedVersion // empty | split(",")[] | gsub("^\\s+|\\s+$";"") | select(. != "")];

  ( [(.os // [])[] | . + {__src:"os"}]
  + [(.lang // [])[] | . + {__src:"lang"}]
  | map(. + {__cat: cat}) ) as $all
  | ($all | map(select(.__cat != "OS_REPORT_ONLY")) | length) as $fixable

  | "== 镜像漏洞分类 ==",
    "",
    "--- 明细（\($all | length) 条）---",
    ( $all | sort_by((.__cat | order), .PkgName, .VulnerabilityID) | .[]
      | "[\(.__cat)] \(.PkgName) \(.VulnerabilityID) \(.Severity // "?") \(.InstalledVersion // "?") → \((fixes | join(", ")) // "" | if . == "" then "（无修复版本）" else . end)" ),
    "",
    "--- 按包聚合（定修复目标用）---",
    ( $all | group_by([.__cat, .PkgName]) | sort_by((.[0].__cat | order), .[0].PkgName) | .[]
      | "[\(.[0].__cat)] \(.[0].PkgName) \(.[0].InstalledVersion // "?")  CVE×\(length)  修复候选: \([.[] | fixes[]] | unique | join(" / ") | if . == "" then "（无）" else . end)" ),
    "",
    "修复途径: GO_STDLIB → alauda/Dockerfile 构建 go 版本 | GO_MODULE → go.mod（gomod-bump.sh） | PYTHON → alauda/patch.sh | OS_REPORT_ONLY → 不修复，如实报告 | UNKNOWN → 人工判断",
    "",
    "SUMMARY: TOTAL=\($all | length) GO_STDLIB=\([$all[] | select(.__cat == "GO_STDLIB")] | length) GO_MODULE=\([$all[] | select(.__cat == "GO_MODULE")] | length) PYTHON=\([$all[] | select(.__cat == "PYTHON")] | length) OS_REPORT_ONLY=\([$all[] | select(.__cat == "OS_REPORT_ONLY")] | length) UNKNOWN=\([$all[] | select(.__cat == "UNKNOWN")] | length)",
    ( if ($all | length) == 0 then "RESULT: CLEAN"
      elif $fixable == 0 then "RESULT: REPORT_ONLY"
      else "RESULT: FIX_NEEDED"
      end )
' "${SCAN_FILE}"
