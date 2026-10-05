#!/usr/bin/env python3
"""
ZeroForwarder 自建授权服务器 (mock zf-license)
=================================================
已逆向出的真实授权协议(2026-10, v1.2.0):

[真实服务器行为]
  GET  /public-key
    -> {"success":true,"data":{"publicKey":"-----BEGIN PUBLIC KEY-----...-----END PUBLIC KEY-----","algorithm":"RS256"}}
    算法 RS256,公钥 PEM。controler 以 TOFU 方式首次抓取后 pin 到磁盘,
    或由 ZFC_AUTH_TRUSTED_PUBKEY_SHA256 / ZFC_AUTH_EMBED_PUBKEY_FILES 预置信任。

  POST /instance/{instance_id}/heartbeat
    body: {"instance_id":"<uuid>"}
    应返回带 token(JWT RS256, 用 /public-key 对应私钥签名)的 license 信息。
    controler 会解析 token 并校验签名与 entitlements。

  WebSocket /ws/instance/{instance_id}
    controler 连上后发 AuthRequest, 期望收到带 token/entitlements 的消息。

[本 mock 实现]
  - 自带 RSA-2048 密钥对(首次运行自动生成到 ./mock_rsa_priv.pem / mock_rsa_pub.pem)
  - 监听 0.0.0.0:9099, 提供 /public-key 与 /instance/{id}/heartbeat
  - 签发 10 年期 active JWT, entitlements 拉满(max_workers=999, 全 feature on)
  - 可选 --ws-port 提供基础 WebSocket 授权帧应答

[用法]
  python3 mock-auth-server.py [--port 9099] [--instance <uuid>]
  # 部署时给 zf-controler 设:
  #   ZFC_AUTH_SERVER_URL=http://<本机IP>:9099
  #   ZFC_INSTANCE_ID=<uuid>
  #   ZFC_API_KEY=<任意>
  #   ZFC_AUTH_TRUSTED_PUBKEY_SHA256=<mock_rsa_pub.pem 的 sha256 指纹>  (推荐, 跳过 TOFU)
"""
import argparse
import base64
import hashlib
import http.server
import json
import os
import struct
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PRIV = os.path.join(HERE, "mock_rsa_priv.pem")
PUB = os.path.join(HERE, "mock_rsa_pub.pem")

ENTITLEMENTS_FULL = {
    "max_workers": 999,
    "max_subscription_number": 99999,
    "max_users_per_worker": 9999,
    "feature_udp_forwarding_enabled": True,
    "feature_autoip_enabled": True,
    "feature_payment_enabled": True,
    "feature_rbac_enabled": True,
    "feature_multi_tenant_enabled": True,
    "max_tenants": 999,
    "monthly_rate": 0,
}


def b64url(d: bytes) -> str:
    return base64.urlsafe_b64encode(d).rstrip(b"=").decode()


def ensure_keys():
    if not (os.path.exists(PRIV) and os.path.exists(PUB)):
        subprocess.run(["openssl", "genrsa", "-out", PRIV, "2048"], check=True)
        subprocess.run(["openssl", "rsa", "-in", PRIV, "-pubout", "-out", PUB], check=True)
    with open(PUB) as f:
        return f.read()


def sign_rs256(signing_input: bytes) -> bytes:
    return subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", PRIV],
        input=signing_input,
        capture_output=True,
        check=True,
    ).stdout


def make_jwt(instance_id: str, expires_days: int = 3650) -> str:
    header = {"alg": "RS256", "typ": "JWT"}
    now = int(time.time())
    payload = {
        "sub": instance_id,
        "iat": now,
        "exp": now + 86400 * expires_days,
        "mode": "active",
        "entitlements": ENTITLEMENTS_FULL,
    }
    h = b64url(json.dumps(header, separators=(",", ":")).encode())
    p = b64url(json.dumps(payload, separators=(",", ":")).encode())
    sig = b64url(sign_rs256(f"{h}.{p}".encode()))
    return f"{h}.{p}.{sig}"


def ws_accept(key: str) -> str:
    return base64.b64encode(
        hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
    ).decode()


def ws_frame(payload: bytes) -> bytes:
    ln = len(payload)
    if ln < 126:
        head = bytes([0x81, ln])
    elif ln < 65536:
        head = bytes([0x81, 126]) + struct.pack(">H", ln)
    else:
        head = bytes([0x81, 127]) + struct.pack(">Q", ln)
    return head + payload


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _json(self, code: int, obj: dict):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # ---- GET ----
    def do_GET(self):
        up = self.headers.get("Upgrade", "").lower()
        if "websocket" in up:
            return self._ws_upgrade()
        if self.path == "/public-key":
            pub_pem = ensure_keys()
            return self._json(200, {
                "success": True,
                "data": {"publicKey": pub_pem, "algorithm": "RS256"},
            })
        self._json(404, {"success": False, "error": "not_found"})

    def _ws_upgrade(self):
        key = self.headers.get("Sec-WebSocket-Key", "")
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", ws_accept(key))
        self.end_headers()
        try:
            # 收 AuthRequest(简单读取一帧即可)
            conn = self.connection
            conn.settimeout(3)
            try:
                conn.recv(2)
                ln = conn.recv(2)[1] & 0x7F
                mask = conn.recv(4)
                payload = b""
                while len(payload) < ln:
                    payload += conn.recv(ln - len(payload))
                print("[WS] recv:", payload[:200], flush=True)
            except Exception:
                pass
            # 应答:带 token 与 entitlements 的授权消息
            iid = self.path.rstrip("/").split("/")[-1]
            token = make_jwt(iid)
            msg = {
                "token": token,
                "status": "active",
                "mode": "active",
                "license": {"mode": "active", "expires_at": "2036-01-01T00:00:00Z"},
                "entitlements": ENTITLEMENTS_FULL,
            }
            conn.sendall(ws_frame(json.dumps(msg).encode()))
            time.sleep(5)
        except Exception as e:
            print("[WS] error:", repr(e), flush=True)

    # ---- POST ----
    def do_POST(self):
        ln = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(ln) if ln else b""
        print(f"[POST] {self.path} body={body[:200]!r}", flush=True)
        if self.path.startswith("/instance/") and self.path.endswith("/heartbeat"):
            iid = self.path.split("/")[2]
            token = make_jwt(iid)
            return self._json(200, {
                "success": True,
                "data": {
                    "status": "active",
                    "token": token,
                    "expires_at": "2036-01-01T00:00:00Z",
                    "license": {"mode": "active", "expires_at": "2036-01-01T00:00:00Z"},
                    "entitlements": ENTITLEMENTS_FULL,
                },
            })
        self._json(200, {"success": True})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9099)
    args = ap.parse_args()
    pub_pem = ensure_keys()
    digest = hashlib.sha256(pub_pem.encode()).hexdigest()
    print(f"[*] mock auth server on 0.0.0.0:{args.port}")
    print(f"[*] pubkey file : {PUB}")
    print(f"[*] pubkey sha256: {digest}")
    print("[*] controler 配置:")
    print(f"    ZFC_AUTH_SERVER_URL=http://<host>:{args.port}")
    print(f"    ZFC_AUTH_TRUSTED_PUBKEY_SHA256={digest}")
    http.server.ThreadingHTTPServer(("0.0.0.0", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
