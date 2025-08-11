#syntax=docker/dockerfile:1.4

ARG RUNNER_BASE_REPO=ghcr.io/alauda-mesh/ansible-operator-plugins/runner-base
ARG RUNNER_BASE_TAG=latest

FROM cgr.dev/chainguard/wolfi-base AS builder

RUN apk update && \
    apk add --no-cache build-base curl go-1.23 unzip git

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
