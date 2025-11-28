## 构建说明

这个 ansible-operator 不通用，只能用于 kiali

1. urllib3 强行升级到了 `2.5.0`。因为有要求「修复」**所有**被扫描器扫描出来的安全漏洞
2. requests 升级
3. ansible 用户的 `GID` 被强制改为了与 `UID` 相同，也是要求「修复」**所有**被扫描器扫描出来的安全漏洞

这里的说明可能会过时，主要看看 `patch.sh` 吧

## 本地构建 `runner-base` 镜像

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
