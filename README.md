# pro-zfpj · 

对 ****(商业化内网穿透平台,`get.`)的
授权协议还原与自建授权部署方案。

> 免责声明:本仓库内容基于对公开发布安装包的本地安全研究,仅用于
> 私有化部署评估与安全测试,请遵守软件授权条款。

## 目录结构

```
├── REPORT--授权逆向.md    # 完整逆向报告(二进制清单/授权链/绕过方案)
├── 授权协议笔记.md                      # 授权协议还原 + 真实服务器实测响应模板
├── mock-auth-server.py                 # 自建授权服务器(RS256 + entitlements 拉满)
├── deploy/
│   ├── deploy-zf-oneclick.sh           # 一键部署脚本(mock 授权 + 控制面)
│   └── README-一键部署.md               # 部署用法/验证清单/排障
```

## 快速开始(真机一键部署)

在装有 docker 的 Linux 服务器上:

```bash
sudo ./deploy/deploy-.sh \
  --web-domain .com \
  --controler-domain .com
```

脚本四步:布置 mock 授权容器 → 官方非交互安装(ZFC_VALIDATE_LICENSE=0)→
patch compose 注入自建授权地址与公钥指纹 → 起服务并验证 `License mode: Active`。

详细用法见 `deploy/README-一键部署.md`。

## 核心结论

- 节点端 `server` 单二进制,无 license 校验,`config.json` 预置凭据直跑即用
- 控制面 6 个 Rust 二进制,授权收敛在 zf-controler(安装期校验 + 运行期
  RS256 JWT 心跳 + WebSocket 吊销)
- 自建授权通过官方可配置项 `ZFC_AUTH_SERVER_URL` +
  `Z` 实现,无需二进制篡改
