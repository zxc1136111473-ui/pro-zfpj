#!/usr/bin/env bash
# ============================================================================
# ZeroForwarder 自建授权 + 控制面 一键部署
# ----------------------------------------------------------------------------
# 原理:
#   官方安装脚本(ZFC_VALIDATE_LICENSE=0 跳过安装期校验)装出控制面后,
#   zf-controler 容器默认连 https://zf-license.luny60.top, 装完必须把
#   ZFC_AUTH_SERVER_URL 指向自建 mock 授权服务器、ZFC_AUTH_TRUSTED_PUBKEY_SHA256
#   设为 mock 公钥指纹, 才能拿到 active license + 全量 entitlements。
#   本脚本把这套「patch compose + 注入 mock 服务」自动化。
#
# 用法:
#   sudo ./deploy-zf-oneclick.sh [选项]
#      --web-domain <域名>        前端域名(必填, 如 forward.example.com)
#      --controler-domain <域名>  控制器域名(必填, 如 zf-ctl.example.com)
#      --instance <uuid>          授权实例 ID(可选, 默认自动生成 uuid)
#      --api-key <key>            API 密钥(可选, 默认随机)
#      --mock-port <port>         mock 授权服务器端口(默认 9099)
#      --install-dir <dir>        安装目录(默认 /opt/zf)
#      --caddy-email <email>      可选, 启用 Caddy 时用于 Let's Encrypt
#      --disable-tdengine         禁用 TDengine(时序统计), 生产机内存紧张时推荐
      --no-verify                跳过结尾 license 验证
#      -y                          全默认直接跑(仍需 --web-domain/--controler-domain)
#
# 输出:
#   <install-dir>/mock-auth/      自建授权服务器(run-mock.sh 可独立重启)
#   <install-dir>/.env           官方安装生成的环境文件
#   验证: curl <web-domain>/api/license/info 或容器日志 License mode=active
#
# 依赖: docker + compose 插件, curl, openssl, python3(容器内), uuidgen
# ============================================================================
set -uo pipefail

# ---------- 默认值 ----------
WEB_DOMAIN=""
CONTROLER_DOMAIN=""
INSTANCE_ID=""
API_KEY=""
MOCK_PORT=9099
INSTALL_DIR="/opt/zf"
CADDY_EMAIL=""
DISABLE_TDENGINE=0
VERIFY=1
YES=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
log()  { echo -e "${BLUE}[ZF-1C]${NC} $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

# ---------- 参数解析 ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --web-domain)       WEB_DOMAIN="$2"; shift 2 ;;
    --controler-domain) CONTROLER_DOMAIN="$2"; shift 2 ;;
    --instance)         INSTANCE_ID="$2"; shift 2 ;;
    --api-key)          API_KEY="$2"; shift 2 ;;
    --mock-port)        MOCK_PORT="$2"; shift 2 ;;
    --install-dir)      INSTALL_DIR="$2"; shift 2 ;;
    --caddy-email)      CADDY_EMAIL="$2"; shift 2 ;;
    --no-verify)        VERIFY=0; shift ;;
    --disable-tdengine) DISABLE_TDENGINE=1; shift ;;
    -y)                 YES=1; shift ;;
    *) die "未知参数: $1" ;;
  esac
done

[[ -z "$WEB_DOMAIN" || -z "$CONTROLER_DOMAIN" ]] && die "必填: --web-domain 与 --controler-domain"
[[ "$WEB_DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] || die "WEB_DOMAIN 格式非法: $WEB_DOMAIN"
[[ "$CONTROLER_DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] || die "CONTROLER_DOMAIN 格式非法: $CONTROLER_DOMAIN"
[[ -z "$INSTANCE_ID" ]] && INSTANCE_ID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
[[ -z "$API_KEY" ]] && API_KEY=$(openssl rand -hex 16)
if [[ -n "$CADDY_EMAIL" ]]; then
  [[ "$CADDY_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]] || die "CADDY_EMAIL 格式非法: $CADDY_EMAIL"
fi

# ---------- 前置检查 ----------
command -v docker >/dev/null || die "缺少 docker"
docker compose version >/dev/null 2>&1 || docker-compose --version >/dev/null 2>&1 || \
  die "缺少 docker compose 插件"
command -v openssl >/dev/null || die "缺少 openssl"
[[ "$(id -u)" != "0" ]] && warn "建议以 root 运行(安装脚本需要 systemd/容器权限)"

mkdir -p "$INSTALL_DIR/mock-auth" || die "无法创建 $INSTALL_DIR"
log "目标目录: $INSTALL_DIR"
log "实例 ID  : $INSTANCE_ID"
log "API KEY  : (已生成, 见下方 .env)"

# ============================================================================
# 第 1 步: 布置 mock 授权服务器(RSA 密钥 + 服务脚本)
# ============================================================================
log "第 1/4 步: 布置自建授权服务器 → $INSTALL_DIR/mock-auth"

MOCK_DIR="$INSTALL_DIR/mock-auth"
MOCK_PRIV="$MOCK_DIR/mock_rsa_priv.pem"
MOCK_PUB="$MOCK_DIR/mock_rsa_pub.pem"

# RSA 密钥(已存在则复用, 保公钥指纹稳定)
if [[ ! -s "$MOCK_PRIV" || ! -s "$MOCK_PUB" ]]; then
  openssl genrsa -out "$MOCK_PRIV" 2048 2>/dev/null
  openssl rsa -in "$MOCK_PRIV" -pubout -out "$MOCK_PUB" 2>/dev/null
  ok "生成 RSA-2048 密钥对"
fi
PUBKEY_SHA=$(sha256sum "$MOCK_PUB" | awk '{print $1}')
ok "mock 公钥指纹: $PUBKEY_SHA"

# mock 授权服务器源码(容器内运行)
cat > "$MOCK_DIR/mock_auth_server.py" << 'PYEOF'
#!/usr/bin/env python3
"""ZeroForwarder 自建授权服务器 (RS256 + entitlements 拉满)"""
import base64, hashlib, http.server, json, os, struct, subprocess, sys, time

PRIV = os.environ.get("MOCK_PRIV", "/keys/priv.pem")
PUB  = os.environ.get("MOCK_PUB",  "/keys/pub.pem")
INSTANCE_ID = os.environ.get("ZF_INSTANCE_ID", "")

ENT = {
    "max_workers": 999, "max_subscription_number": 99999, "max_users_per_worker": 9999,
    "feature_udp_forwarding_enabled": True, "feature_autoip_enabled": True,
    "feature_payment_enabled": True, "feature_rbac_enabled": True,
    "feature_multi_tenant_enabled": True, "max_tenants": 999, "monthly_rate": 0,
}

def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

def make_jwt(iid):
    h = b64u(json.dumps({"alg":"RS256","typ":"JWT"}, separators=(",",":")).encode())
    now = int(time.time())
    p = b64u(json.dumps({"sub":iid,"iat":now,"exp":now+86400*3650,"mode":"active",
        "entitlements":ENT}, separators=(",",":")).encode())
    sig = subprocess.run(["openssl","dgst","-sha256","-sign",PRIV],
        input=f"{h}.{p}".encode(), capture_output=True).stdout
    return f"{h}.{p}.{b64u(sig)}"

def ws_accept(key):
    return base64.b64encode(hashlib.sha1((key+"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()

def ws_frame(p):
    ln = len(p)
    head = bytes([0x81, ln]) if ln < 126 else bytes([0x81,126]) + struct.pack(">H", ln)
    return head + p

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def _j(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if "websocket" in self.headers.get("Upgrade","").lower():
            key = self.headers.get("Sec-WebSocket-Key","")
            self.send_response(101)
            self.send_header("Upgrade","websocket"); self.send_header("Connection","Upgrade")
            self.send_header("Sec-WebSocket-Accept", ws_accept(key)); self.end_headers()
            iid = self.path.rstrip("/").split("/")[-1] or INSTANCE_ID
            msg = json.dumps({"token":make_jwt(iid),"status":"active","mode":"active",
                "license":{"mode":"active","expires_at":"2036-01-01T00:00:00Z"},
                "entitlements":ENT}).encode()
            try:
                self.connection.settimeout(2)
                try: self.connection.recv(4096)
                except Exception: pass
                self.connection.sendall(ws_frame(msg))
                time.sleep(10)
            except Exception: pass
            return
        if self.path == "/public-key":
            with open(PUB) as f: pem = f.read()
            self._j(200, {"success":True,"data":{"publicKey":pem,"algorithm":"RS256"}})
        else:
            self._j(404, {"success":False,"error":"not_found"})
    def do_POST(self):
        ln = int(self.headers.get("Content-Length",0) or 0)
        body = self.rfile.read(ln) if ln else b""
        if self.path.startswith("/instance/") and self.path.endswith("/heartbeat"):
            iid = self.path.split("/")[2] or INSTANCE_ID
            self._j(200, {"success":True,"data":{
                "status":"active","token":make_jwt(iid),
                "expires_at":"2036-01-01T00:00:00Z",
                "license":{"mode":"active","expires_at":"2036-01-01T00:00:00Z"},
                "entitlements":ENT}})
        elif self.path.startswith("/instance/") and self.path.endswith("/status"):
            self._j(200, {"success":True,"data":{"status":"active","instance_id":INSTANCE_ID}})
        else:
            self._j(200, {"success":True})

if __name__ == "__main__":
    port = int(os.environ.get("MOCK_PORT","9099"))
    print(f"[mock-auth] listening :{port}", flush=True)
    http.server.ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()
PYEOF

# 独立重启脚本(手动维护用)
cat > "$MOCK_DIR/run-mock.sh" << EOF
#!/usr/bin/env bash
# 依赖: docker + python:3.11-slim 镜像; 用法: ./run-mock.sh [start|stop|restart|logs]
DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
NAME="zf-mock-auth"
case "\${1:-start}" in
  start)
    docker rm -f \$NAME >/dev/null 2>&1
    docker run -d --name \$NAME --restart unless-stopped \\
      -e MOCK_PRIV=/keys/priv.pem -e MOCK_PUB=/keys/pub.pem -e MOCK_PORT=$MOCK_PORT \\
      -v \$DIR:/keys:ro \\
      -p $MOCK_PORT:$MOCK_PORT \\
      python:3.11-slim python3 /keys/mock_auth_server.py ;;
  stop)   docker rm -f \$NAME >/dev/null 2>&1 ;;
  restart) "\$0" stop; "\$0" start ;;
  logs)   docker logs -f \$NAME ;;
  *) echo "usage: \$0 start|stop|restart|logs" ;;
esac
EOF
chmod +x "$MOCK_DIR/run-mock.sh" "$MOCK_DIR/mock_auth_server.py"

# 启动 mock
"$MOCK_DIR/run-mock.sh" start >/dev/null 2>&1 || die "mock 容器启动失败"
sleep 2
curl -s "http://127.0.0.1:$MOCK_PORT/public-key" >/dev/null 2>&1 \
  && ok "mock 授权服务器 :$MOCK_PORT 就绪" || warn "mock 端口探测未通过, 继续尝试"

# ============================================================================
# 第 2 步: 官方安装(跳过安装期 license 校验)
# ============================================================================
log "第 2/4 步: 官方安装脚本(ZFC_VALIDATE_LICENSE=0)"

INSTALL_SCRIPT="$SCRIPT_DIR/zf_install.sh"
if [[ ! -f "$INSTALL_SCRIPT" ]]; then
  log "下载官方安装脚本…"
  curl -fsSL --max-time 120 https://get.zeroforwarder.com/install.sh -o "$INSTALL_SCRIPT" \
    || die "下载 install.sh 失败"
fi
chmod +x "$INSTALL_SCRIPT"

INSTALL_ARGS=(
  --install
  --non-interactive
  --config "$INSTALL_DIR/zfc.env"
)
# --config 文件: install.sh 会 source 它
cat > "$INSTALL_DIR/zfc.env" << EOF
WEB_DOMAIN=$WEB_DOMAIN
CONTROLER_DOMAIN=$CONTROLER_DOMAIN
ZFC_INSTANCE_ID=$INSTANCE_ID
ZFC_API_KEY=$API_KEY
ZFC_VALIDATE_LICENSE=0
ZFC_AUTO_INSTALL_DOCKER=1
ZFC_UPDATE_CHANNEL=latest
EOF
[[ "$DISABLE_TDENGINE" == "1" ]] && echo "DISABLE_TDENGINE=true" >> "$INSTALL_DIR/zfc.env"
[[ -n "$CADDY_EMAIL" ]] && echo "CADDY_EMAIL=$CADDY_EMAIL" >> "$INSTALL_DIR/zfc.env"

log "运行官方安装(可能耗时 5-10 分钟, 请耐心)…"
cd "$INSTALL_DIR" || die "无法进入 $INSTALL_DIR"
"$INSTALL_SCRIPT" "${INSTALL_ARGS[@]}" </dev/null || {
  code=$?
  # 13 = license invalid; 10 = 缺输入; 16 = 已存在安装。提示后不硬退(继续 patch)
  warn "官方安装脚本退出码 $code(可接受: 已装/校验跳过), 继续 patch compose"
}

# ============================================================================
# 第 3 步: patch compose —— 注入自建授权 + 追加 mock 服务
# ============================================================================
log "第 3/4 步: patch docker-compose.yml"

COMPOSE="$INSTALL_DIR/docker-compose.yml"
[[ -f "$COMPOSE" ]] || die "未找到 $COMPOSE (安装未生成 compose)"

# 3.1 给 zf-controler 环境注入 ZFC_AUTH_SERVER_URL + TRUSTED_PUBKEY
if grep -q "ZFC_AUTH_SERVER_URL" "$COMPOSE"; then
  ok "ZFC_AUTH_SERVER_URL 已存在, 跳过注入"
else
  # 在 zf-controler 的 ZFC_API_KEY: ${ZFC_API_KEY} 行后插入(awk 保缩进)
  awk -v keyline='      ZFC_API_KEY: ${ZFC_API_KEY}' \
      -v inject1="      ZFC_AUTH_SERVER_URL: http://zf-mock-auth:${MOCK_PORT}" \
      -v inject2="      ZFC_AUTH_TRUSTED_PUBKEY_SHA256: ${PUBKEY_SHA}" '
      $0 == keyline && !done { print; print inject1; print inject2; done=1; next }
      { print }' "$COMPOSE" > "$COMPOSE.tmp" && mv "$COMPOSE.tmp" "$COMPOSE"
  ok "已注入 ZFC_AUTH_SERVER_URL=http://zf-mock-auth:$MOCK_PORT"
fi

# 3.2 追加 mock 服务到 compose
if grep -q "zf-mock-auth:" "$COMPOSE"; then
  ok "zf-mock-auth 服务已存在, 跳过"
else
  cat >> "$COMPOSE" << 'EOF'

  zf-mock-auth:
    image: python:3.11-slim
    container_name: zf-mock-auth
    environment:
      MOCK_PRIV: /keys/priv.pem
      MOCK_PUB: /keys/pub.pem
    volumes:
      - ./mock-auth:/keys:ro
    restart: unless-stopped
    command: ["python3", "/keys/mock_auth_server.py"]
EOF
  ok "已追加 zf-mock-auth 服务"
fi

# 3.3 把 .env 里补上 AUTH_SERVER_URL(供 compose 替换; 虽然模板未引用, 留档)
grep -q '^ZFC_AUTH_SERVER_URL=' "$INSTALL_DIR/.env" 2>/dev/null || \
  echo "ZFC_AUTH_SERVER_URL=http://zf-mock-auth:${MOCK_PORT}" >> "$INSTALL_DIR/.env"

# ============================================================================
# 第 4 步: 起服务 + 验证
# ============================================================================
log "第 4/4 步: 拉起服务并验证"

# 官方 compose 模板无显式 networks: 全部服务在同一默认网络, mock 无需加入任何额外网络
cd "$INSTALL_DIR"
docker compose up -d >/dev/null 2>&1 || { docker-compose up -d >/dev/null 2>&1 || warn "compose up 失败, 请手动检查"; }

# 重启 zf-controler 以生效新 env
docker compose restart zf-controler >/dev/null 2>&1 || warn "重启 zf-controler 失败(可能已在更新)"

sleep 8
ok "部署完成: 控制面 + 自建授权"

# ---------- 验证 ----------
if [[ "$VERIFY" == "1" ]]; then
  log "验证 license 状态…"
  for i in $(seq 1 6); do
    MODE=$(docker compose logs zf-controler 2>/dev/null | grep -aoE "License mode updated: [A-Za-z]+" | tail -1)
    [[ -n "$MODE" ]] && break
    sleep 5
  done
  echo "   → ${MODE:-未捕获到 mode 日志}"
  echo
  echo "=============== 部署摘要 ==============="
  echo "  前端域名    : $WEB_DOMAIN"
  echo "  控制器域名  : $CONTROLER_DOMAIN"
  echo "  实例 ID     : $INSTANCE_ID"
  echo "  API KEY     : $API_KEY"
  echo "  mock 授权   : http://<server-ip>:$MOCK_PORT (容器内 zf-mock-auth:$MOCK_PORT)"
  echo "  mock 公钥指纹: $PUBKEY_SHA"
  echo "  controler env: ZFC_AUTH_SERVER_URL=http://zf-mock-auth:$MOCK_PORT"
  echo "  控制面容器  : docker compose -f $INSTALL_DIR/docker-compose.yml ps"
  echo "  license 校验: 日志应见 License mode updated: Active"
  echo "======================================="
  if [[ "$MODE" == *"Active"* ]]; then
    ok "license=active → 免费部署成功, entitlements 全量生效"
  else
    warn "未确认 active; 若为 RenewalOnly 请检查: mock 容器存活 / 网络 / 公钥指纹"
  fi
fi