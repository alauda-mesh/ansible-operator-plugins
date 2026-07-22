## 版本升级

使用仓库内置的 Claude Code skill [`sync-upstream`](../.claude/skills/sync-upstream/SKILL.md) 同步上游 [openshift/ansible-operator-plugins](https://github.com/openshift/ansible-operator-plugins) 代码（仅支持显式调用）。它会自动完成：

1. 基于目标分支创建 `sync/<日期>` 分支并 merge 上游（冲突时停下询问）
2. 分析上游 `openshift/Dockerfile` 新改动，同步到 `alauda/Dockerfile` 并给出理由
3. 清理 `alauda/patch.sh` 中已过时的 python 库版本 patch
4. 汇报同步后的版本（`internal/version/version.go` 的 `ImageVersion`）
5. 创建 PR 并监控 Alauda Release 流水线，失败时分析原因

使用示例（在 Claude Code 中，参数为 `<上游分支> <目标分支>`）：

```
/sync-upstream main main
```

## 漏洞修复

使用仓库内置的 Claude Code skill [`fix-image-vulns`](../.claude/skills/fix-image-vulns/SKILL.md) 修复 ansible-operator 镜像漏洞（仅支持显式调用）。它会自动完成：

1. 调内部扫描服务检测镜像漏洞，按修复途径分类（os 级漏洞属 `runner-base`，只报告不修复）
2. 按类修复：构建 go 版本（`alauda/Dockerfile`）、go.mod 依赖（含 vendor 同步与构建验证）、python 库（`alauda/patch.sh`）
3. 创建 PR 并监控 Alauda Release 流水线
4. 对新构建的镜像回归扫描，未清零则继续修（最多 3 轮），修不完如实报告

使用示例（参数为 Alauda Release 流水线 run ID/URL，或完整镜像地址）：

```
/fix-image-vulns build-harbor.alauda.cn/asm/ansible-operator:main
/fix-image-vulns 29894931080
```

## 构建说明

这个 ansible-operator 不通用，只能用于 kiali

1. urllib3 强行升级到了 `2.5.0`。因为有要求「修复」**所有**被扫描器扫描出来的安全漏洞
2. requests 升级
3. ansible 用户的 `GID` 被强制改为了与 `UID` 相同，也是要求「修复」**所有**被扫描器扫描出来的安全漏洞

这里的说明可能会过时，主要看看 `patch.sh` 吧

### 流水线构建 `runner-base` 镜像

详见：https://github.com/alauda-mesh/ansible-operator-plugins/actions/workflows/build-runner-base.yaml

该流水线每周会定时构建一次（用于修复最新的 base 漏洞），也可手动执行。

### 本地构建 `runner-base` 镜像

```bash
# 使用个人 token 登录到 GHCR
echo $GITHUB_TOKEN | docker login ghcr.io -u <YOUR_GITHUB_USERNAME> --password-stdin

# apko 构建和推送镜像（不用使用 docker run）
apko publish \
  ./base.apko.yaml \
  ghcr.io/alauda-mesh/ansible-operator-plugins/runner-base:latest \
  --arch x86_64,aarch64

# 检查 multi-arch
docker buildx imagetools inspect ghcr.io/alauda-mesh/ansible-operator-plugins/runner-base:latest

# 复制镜像到 build-harbor
skopeo copy --all \
  --dest-creds '<harbor_user>:<harbor_password>' \
  docker://ghcr.io/alauda-mesh/ansible-operator-plugins/runner-base:latest \
  docker://build-harbor.alauda.cn/asm/ansible-operator-plugins/runner-base:latest
```
