#syntax=docker/dockerfile:1.4

ARG RUNNER_BASE_REPO=ghcr.io/alauda-mesh/ansible-operator-plugins/runner-base
ARG RUNNER_BASE_TAG=latest

FROM cgr.dev/chainguard/wolfi-base AS builder

# 构建阶段只负责编译出 ansible-operator 二进制，最终镜像仅 COPY 该二进制，
# 因此这里装什么都不会影响发布镜像的内容与漏洞扫描结果。
#
# 依赖说明：
#   bash    —— Makefile 第 1 行强制 `SHELL = /bin/bash`，而 wolfi-base 只带 busybox sh，
#              缺失时 make 会报 `/bin/bash: No such file or directory` 并以 Error 127 退出
#   make    —— 执行 `make -e build`
#   git     —— Makefile 用 git describe / git rev-parse 生成版本信息
#   go-1.26 —— 编译二进制
#
# 刻意不再安装 build-base：Makefile 已设置 `CGO_ENABLED = 0`，gcc/binutils/glibc-dev 等
# C 工具链完全用不到。去掉后 apk 下载量从约 670 MiB 降到约 200 MiB，构建更快，
# 暴露在网络抖动下的时间窗口也大幅缩短。curl/unzip 在本阶段同样无人使用，一并去掉。
#
# apk.cgr.dev 偶发单个包下载中断（`ERROR: <pkg>: IO ERROR`），只要有一个包出错整条命令
# 就会退出 1 导致构建失败，因此加上退避重试。
RUN set -eu; \
    for i in 1 2 3 4 5; do \
        if apk update && apk add --no-cache bash make git go-1.26; then \
            exit 0; \
        fi; \
        [ "${i}" -lt 5 ] || break; \
        echo "apk 安装失败（第 ${i}/5 次尝试），$((i * 10)) 秒后重试" >&2; \
        sleep "$((i * 10))"; \
    done; \
    echo "apk 安装连续 5 次均失败，终止构建" >&2; \
    exit 1

ARG GOPROXY
env GOPROXY=${GOPROXY}

ENV GO111MODULE=on \
    GOFLAGS=-mod=vendor

COPY . /tmp/ansible-operator-plugins

RUN cd /tmp/ansible-operator-plugins \
    && export SIMPLE_VERSION="$(make -pRrq --no-print-directory | grep '^IMAGE_VERSION' | awk -F'= ' '{print $2}')" \
    && export GIT_VERSION="$(make -pRrq --no-print-directory | grep '^IMAGE_VERSION' | awk -F'= ' '{print $2}')" \
    && make -e build


FROM ${RUNNER_BASE_REPO}:${RUNNER_BASE_TAG}

RUN mkdir -p /etc/ansible \
    && echo "localhost ansible_connection=local" > /etc/ansible/hosts \
    && echo '[defaults]' > /etc/ansible/ansible.cfg \
    && echo 'roles_path = /opt/ansible/roles' >> /etc/ansible/ansible.cfg \
    && echo 'library = /usr/share/ansible/openshift' >> /etc/ansible/ansible.cfg

ENV HOME=/opt/ansible \
    USER_NAME=ansible \
    USER_UID=1001

ENV REMOTE_SOURCES=${REMOTE_SOURCES:-"./alauda/openshift"}
ENV REMOTE_SOURCES_DIR=${REMOTE_SOURCES_DIR:-"/cachito"}

COPY ${REMOTE_SOURCES} ${REMOTE_SOURCES_DIR}
# Copy our local ansible-runner-http replacement module
COPY images/ansible-operator/ansible_runner_http /ansible_runner_http
COPY alauda/openshift/install-ansible.sh .
RUN sh ./install-ansible.sh

COPY --from=builder --link /tmp/ansible-operator-plugins/ansible-operator /usr/local/bin/ansible-operator
COPY alauda/openshift/release/ansible/ansible_collections ${HOME}/.ansible/collections/ansible_collections

# Ensure directory permissions are properly set
# 原来是这样:
#  "${USER_NAME}:x:${USER_UID}:0:${USER_NAME} user:${HOME}:/sbin/nologin"
# 改成了这样
#  "${USER_NAME}:x:${USER_UID}:${USER_UID}:${USER_NAME} user:${HOME}:/sbin/nologin"
# 为了让扫描器开心做得「必要」修改 :(
# 这样改 Ansible Operator 可能无法通用了，只能用于 kiali，Be careful
RUN mkdir -p ${HOME}/.ansible/tmp \
    && chown -R ${USER_UID}:${USER_UID} ${HOME} \
    && chmod -R ug+rwx ${HOME}

WORKDIR ${HOME}
USER ${USER_UID}
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/ansible-operator", "run", "--watches-file=./watches.yaml"]
