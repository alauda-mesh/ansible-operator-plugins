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

"${SED}" -i \
  -e 's/^urllib3==1.*$/urllib3==2.5.0/' \
  -e 's/^requests==2.*$/requests==2.32.4/' \
  "${SCRIPT_DIR}/openshift/requirements.txt"

"${SED}" -i \
  -e 's/pipenv check --ignore 71064/pipenv check --ignore 71064 --ignore 77680 --ignore 77744 --ignore 77745/' \
  "${SCRIPT_DIR}/openshift/Dockerfile.requirements"

diff --color -ruN "${SCRIPT_DIR}/../openshift" "${SCRIPT_DIR}/openshift" || true
