#!/bin/bash
# 步骤 2.2：升级 go.mod 依赖并验证构建
# 用法: gomod-bump.sh <module@version> [module@version ...]
#   例: gomod-bump.sh golang.org/x/net@v0.56.0 google.golang.org/grpc@v1.79.3
# 本仓库用 vendor 模式构建（GOFLAGS=-mod=vendor），升级必须"三件套"齐全:
#   go get → go mod tidy → go mod vendor，缺 vendor 会导致流水线构建失败
# 环境变量: GOPROXY 默认 https://goproxy.cn,direct（与流水线一致）
# 退出码: 0=构建验证通过（输出 RESULT: BUILD_OK） 非0=某一步失败（保留现场供分析）

set -euo pipefail

die() { echo "错误: $*" >&2; exit 1; }

[[ $# -ge 1 ]] || die "用法: gomod-bump.sh <module@version> [module@version ...]"
command -v go >/dev/null 2>&1 || die "找不到 go 工具链"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "当前目录不在 git 仓库内"
cd "${REPO_ROOT}"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"

echo "==> go get $*"
go get "$@"
echo "==> go mod tidy"
go mod tidy
echo "==> go mod vendor"
go mod vendor
echo "==> go build ./... （验证构建）"
go build ./...

echo "==> 变更概览:"
# vendor 同步的变更常达数千行，git status 直接管给 head 会被截断触发 SIGPIPE，
# 在 set -o pipefail 下使脚本以 141 退出（此时构建其实已成功）——先落变量再截取
STATUS="$(git status --short)"
sed -n '1,30p' <<< "${STATUS}"
TOTAL="$(wc -l <<< "${STATUS}")"
if [[ "${TOTAL}" -gt 30 ]]; then
  echo "    ...（共 ${TOTAL} 个文件变更，多为 vendor/ 同步产生）"
fi
echo "RESULT: BUILD_OK"
