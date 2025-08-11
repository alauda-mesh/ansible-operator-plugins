#syntax=docker/dockerfile:1.4

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

FROM cgr.dev/chainguard/wolfi-base AS baselayout

# Just make some ridiculous scanners happy
COPY <<'EOF' /etc/passwd
root:x:0:0:root:/root:/bin/ash
bin:x:1:1:bin:/bin:/sbin/nologin
daemon:x:2:2:daemon:/sbin:/sbin/nologin
adm:x:3:4:adm:/var/adm:/sbin/nologin
lp:x:4:7:lp:/var/spool/lpd:/sbin/nologin
mail:x:8:12:mail:/var/mail:/sbin/nologin
news:x:9:13:news:/usr/lib/news:/sbin/nologin
uucp:x:10:14:uucp:/var/spool/uucppublic:/sbin/nologin
man:x:13:15:man:/usr/man:/sbin/nologin
postmaster:x:14:12:postmaster:/var/mail:/sbin/nologin
cron:x:16:16:cron:/var/spool/cron:/sbin/nologin
ftp:x:21:21::/var/lib/ftp:/sbin/nologin
sshd:x:22:22:sshd:/dev/null:/sbin/nologin
nobody:x:65534:65534:nobody:/:/sbin/nologin
EOF

# Set a '*' for the root password to make scanners happy
RUN <<'EOF'
awk -F: '{
    pw = ":!:"
    if ($1 == "root") { pw = ":*:" }
    print($1 pw ":0:::::")
}' /etc/passwd > /etc/shadow
EOF

FROM cgr.dev/chainguard/wolfi-base

COPY --from=baselayout --link /etc/passwd /etc/passwd
COPY --from=baselayout --link /etc/shadow /etc/shadow

RUN mkdir -p /etc/ansible \
    && echo "localhost ansible_connection=local" > /etc/ansible/hosts \
    && echo '[defaults]' > /etc/ansible/ansible.cfg \
    && echo 'roles_path = /opt/ansible/roles' >> /etc/ansible/ansible.cfg \
    && echo 'library = /usr/share/ansible/openshift' >> /etc/ansible/ansible.cfg

ENV HOME=/opt/ansible \
    USER_NAME=ansible \
    USER_UID=1001

RUN apk update && apk add --no-cache curl tini python-3.12 py3.12-pip py3.12-cryptography

ENV REMOTE_SOURCES=${REMOTE_SOURCES:-"./alauda/openshift"}
ENV REMOTE_SOURCES_DIR=${REMOTE_SOURCES_DIR:-"/cachito"}

COPY ${REMOTE_SOURCES} ${REMOTE_SOURCES_DIR}
COPY alauda/openshift/install-ansible.sh .
RUN sh ./install-ansible.sh

COPY --from=builder /tmp/ansible-operator-plugins/ansible-operator /usr/local/bin/ansible-operator
COPY alauda/openshift/release/ansible/ansible_collections ${HOME}/.ansible/collections/ansible_collections

# Ensure directory permissions are properly set
# 原来是这样:
#  "${USER_NAME}:x:${USER_UID}:0:${USER_NAME} user:${HOME}:/sbin/nologin"
# 改成了这样
#  "${USER_NAME}:x:${USER_UID}:${USER_UID}:${USER_NAME} user:${HOME}:/sbin/nologin"
# 为了让扫描器开心做得「必要」修改
# 要知道 Ansible 是一个很有历史的项目，因此GID0在很多情况下是需要的，不然 Ansible 访问的系统路径可能都没有权限
# 这样改 Ansible Operator 无法通用了，只能用于 kiali
RUN echo "${USER_NAME}:x:${USER_UID}:${USER_UID}:${USER_NAME} user:${HOME}:/sbin/nologin" >> /etc/passwd \
  && mkdir -p ${HOME}/.ansible/tmp \
  && chown -R ${USER_UID}:${USER_UID} ${HOME} \
  && chmod -R ug+rwx ${HOME}

WORKDIR ${HOME}
USER ${USER_UID}
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/ansible-operator", "run", "--watches-file=./watches.yaml"]
