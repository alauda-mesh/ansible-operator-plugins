#!/bin/bash

set -eu

# 获取脚本所在的目录
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

rm -rf "${SCRIPT_DIR}/openshift"
cp -r "${SCRIPT_DIR}/../openshift" "${SCRIPT_DIR}"

if [[ "$(uname -s)" == "Darwin" ]]; then
  SED="gsed"
else
  SED="sed"
fi

# NOTE: 如果要修复 `openshift/requirements-build.txt` jaraco.context 和 wheel 的低版本漏洞，要同时升级 setuptools 的版本，因为 setuptools 引用了 jaraco.context 和 wheel。

"${SED}" -i \
  -e 's/^wheel==0.*$/wheel==0.46.3/' \
  "${SCRIPT_DIR}/openshift/requirements-pre-build.txt"

"${SED}" -i \
  -e 's/^requests==2.*$/requests==2.33.0/' \
  -e 's/^pyasn1==0.*$/pyasn1==0.6.3/' \
  -e 's/^idna==3.*$/idna==3.15/' \
  -e 's/^urllib3==2.*$/urllib3==2.7.0/' \
  -e 's/^ansible-core==2.*$/ansible-core==2.18.18/' \
  "${SCRIPT_DIR}/openshift/requirements.txt"

diff --color -ruN "${SCRIPT_DIR}/../openshift" "${SCRIPT_DIR}/openshift" || true
