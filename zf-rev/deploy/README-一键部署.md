# ZeroForwarder 一键部署(mock 授权 + 控制面)

`deploy-zf-oneclick.sh` 把「自建授权服务器 + 官方控制面」拼成一套自动化部署。
原理:官方安装(跳过安装期校验) → patch compose 注入 `ZFC_AUTH_SERVER_URL`/
`ZFC_AUTH_TRUSTED_PUBKEY_SHA256` → 追加 mock 容器到同一网络 → 起服务验证。

---

## 用法

```bash
# 需要: root 权限 + docker + compose 插件 + openssl
sudo ./deploy-zf-oneclick.sh \
  --web-domain forward.example.com \
  --controler-domain zf-ctl.example.com \
  [--instance <uuid>] [--api-key <key>] [--mock-port 9099] \
  [--install-dir /opt/zf] [--caddy-email you@example.com] \
  [--no-verify] [-y]
```

参数说明:

| 参数 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `--web-domain` | ✅ | - | 前端域名(zf-web) |
| `--controler-domain` | ✅ | - | 控制器域名(zf-controler) |
| `--instance` | - | 随机 uuid | 授权实例 ID(mock 会按它签发 JWT) |
| `--api-key` | - | 随机 hex | API 密钥(任意值, mock 不校验) |
| `--mock-port` | - | 9099 | mock 授权服务器端口 |
| `--install-dir` | - | /opt/zf | 安装目录 |
| `--caddy-email` | - | 空 | 启用 Caddy/HTTPS 时的邮箱 |
| `--no-verify` | - | off | 跳过结尾 license 验证 |
| `-y` | - | off | 非交互确认 |

---

## 部署流程(脚本 4 步)

1. **布置 mock 授权服务器**
   - 生成 RSA-2048 密钥对(已存在则复用, 公钥指纹稳定)
   - 写入 `$INSTALL_DIR/mock-auth/mock_auth_server.py`
   - 启动 `zf-mock-auth` 容器(python:3.11-slim, 挂载密钥只读)
   - 计算并打印公钥指纹(sha256)

2. **官方安装**
   - 使用 `$INSTALL_DIR/zfc.env`(--config)传参
   - `ZFC_VALIDATE_LICENSE=0` 跳过安装期在线校验
   - 依赖 docker 自动安装、密码/密钥自动生成

3. **patch compose**
   - zf-controler 环境注入:
     `ZFC_AUTH_SERVER_URL=http://zf-mock-auth:<port>`
     `ZFC_AUTH_TRUSTED_PUBKEY_SHA256=<mock 公钥指纹>`
   - 追加 `zf-mock-auth` 服务(默认网络, 与控制面互通)

4. **起服务 + 验证**
   - `docker compose up -d` + 重启 zf-controler
   - 检查容器日志 `License mode updated: Active`

---

## 验证清单

```bash
# mock 授权容器
docker ps | grep zf-mock-auth
curl http://127.0.0.1:9099/public-key        # → RS256 PEM

# 控制面容器
cd /opt/zf && docker compose ps

# license 状态(zf-controler 日志)
docker compose logs zf-controler | grep -i "license"
# 期望: License mode updated: Active
# 期望: Received updated entitlements: Entitlements { max_workers: 999, ... }

# 前端
curl -k https://<web-domain> 或 http://<ip>:3030
```

---

## 排障

| 现象 | 原因 | 处理 |
|---|---|---|
| 日志 `RenewalOnly` | 公钥指纹不匹配 / mock 不可达 | 核对 `ZFC_AUTH_TRUSTED_PUBKEY_SHA256`=脚本打印的指纹; `docker exec zf-controler curl http://zf-mock-auth:9099/public-key` |
| mock 容器退出 | python:3.11-slim 拉取失败 / 密钥缺失 | 确认镜像; 检查 `$INSTALL_DIR/mock-auth/priv.pem pub.pem` 存在 |
| 安装脚本退出码 13 | 安装期校验失败(理论上被 ZFC_VALIDATE_LICENSE=0 跳过) | 确认 zfc.env 含 `ZFC_VALIDATE_LICENSE=0` |
| 安装脚本退出码 16 | 已存在安装 | 加 `--force` 或先 `--uninstall` |
| `compose up` 网络不通 | 模板无显式 networks | 所有服务同默认网络, mock 无需额外配置; 若手动改过网络, 把 mock 挂到 zf-controler 所在网络 |

---

## 目录结构(部署后)

```
/opt/zf/
├── zfc.env                 # 传给官方安装的配置
├── docker-compose.yml      # 官方生成 + 本脚本 patch(注入 AUTH_URL + mock 服务)
├── .env                    # 官方安装环境变量
├── .admin_token            # 管理员令牌(安装生成)
└── mock-auth/
    ├── mock_auth_server.py # 自建授权服务器(容器内运行)
    ├── run-mock.sh         # 手动 start/stop/restart/logs
    ├── mock_rsa_priv.pem   # RSA 私钥
    └── mock_rsa_pub.pem    # RSA 公钥(指纹已注入 controler)
```
