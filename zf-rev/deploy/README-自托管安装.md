# ZeroForwarder 自托管安装脚本套件

把 ZeroForwarder 的**控制面安装脚本**从官方域名 `get.zeroforwarder.com`
迁移到你的 GitHub(`zxc1136111473-ui/pro-zfpj`),以后装控制面不再依赖官方。

## 文件清单

| 文件 | 说明 |
|---|---|
| `zf_install_selfhost.sh` | 官方 install.sh 改造版(下载地址指向本仓库) |
| `docker-compose.template.yml` | compose 模板(install.sh 从本仓库拉取) |
| `schema.prisma` | Prisma schema 1.2.0 版(镜像 bundle 抽取,3307 行) |

## 用法

### 控制面安装(替代官方)
```bash
bash <(curl -sL https://raw.githubusercontent.com/zxc1136111473-ui/pro-zfpj/main/zf-rev/deploy/zf_install_selfhost.sh) --install -y
# 或交互式:
bash <(curl -sL https://raw.githubusercontent.com/zxc1136111473-ui/pro-zfpj/main/zf-rev/deploy/zf_install_selfhost.sh)
```

### 服务器节点 / 转发端点安装(无需改,已指向你的控制面)
面板里生成的脚本 `HOST=https://iplcjh.wqyhr.com`,二进制从**你的控制面 API**下载:

```bash
# 转发端点
bash <(curl -s https://iplcjh.wqyhr.com/setup_script/<token>)
# 服务器 worker
curl -s "https://iplcjh.wqyhr.com/worker_setup_script/<pubkey>?token=<token>" | bash -s eth0
```

⚠️ **这些脚本是控制面 API 动态生成的(每个端点 token 唯一),不能静态化到 git**;
但它们的下载源已经是你的控制面,无需再改。

## 改造内容对照

| 原文(官方) | 改成(本仓库) |
|---|---|
| `https://get.zeroforwarder.com/docker-compose.template.yml` | `https://raw.githubusercontent.com/zxc1136111473-ui/pro-zfpj/main/zf-rev/deploy/docker-compose.template.yml` |
| `https://get.zeroforwarder.com/schema.prisma` | 同仓库 `schema.prisma` |
| `get.zeroforwarder.com/install.sh`(提示文案) | 同仓库 `zf_install_selfhost.sh` |

## 未替换(保持官方)及原因

| 项 | 原因 |
|---|---|
| `hub.covm.net` 镜像仓库 | 控制面二进制(Docker 镜像)托管在官方 registry,无法自托管 |
| `zf-license.luny60.top` 授权服务器默认地址 | 部署时用 `ZFC_AUTH_SERVER_URL` 指向自建 mock 覆盖即可 |

## 更新维护

修改脚本后重新推送 main,raw URL 立即生效。注意:
- 仓库文件路径变化会破坏 raw URL,需同步改脚本内引用
- schema.prisma 是 1.2.0 控制面版本;若官方发新版本,从镜像 bundle 重新抽取替换