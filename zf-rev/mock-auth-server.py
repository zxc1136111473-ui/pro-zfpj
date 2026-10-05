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
    p = b64u(json.dumps({"sub":iid,"sid":"mock-session-001","iat":now,"exp":now+86400*3650,"mode":"active",
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
        import sys
        print(f"[MOCK] {self.command} {self.path}", flush=True)
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        print(f"[MOCK-GET] {self.path}", flush=True)
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
                self.connection.settimeout(30)
                # 持续读帧保持连接, 收到任何帧回 pong 保持活跃
                end = time.time() + 300
                while time.time() < end:
                    try:
                        self.connection.recv(4096)
                    except Exception:
                        pass
                    # 周期发心跳帧
                    if time.time() % 30 < 1:
                        try:
                            self.connection.sendall(ws_frame(msg))
                        except Exception:
                            break
                    time.sleep(0.5)
            except Exception:
                pass
            try: self.connection.close()
            except Exception: pass
            return
        if self.path == "/public-key":
            with open(PUB) as f: pem = f.read()
            self._j(200, {"success":True,"data":{"publicKey":pem,"algorithm":"RS256"}})
        elif self.path.endswith("/status"):
            self._j(200, {"success":True,"data":{"status":"active","mode":"active","instance_id":INSTANCE_ID,"version":"1.2.0"}})
        elif "/download-forwarder" in self.path:
            # 返回 forwarder 二进制下载元数据(版本 1.2.0, 无实际内容, 让端点保持本地二进制)
            self._j(200, {"success":True,"data":{"version":"1.2.0","arch":"x86_64","controller_version":"1.2.0","download_url":"","sha256":"","size":0,"total_size":0,"chunk_size":0,"decoded_size":0,"chunk_index":0,"is_last":True}})
        elif "/download-worker" in self.path:
            self._j(200, {"success":True,"data":{"version":"1.2.0","arch":"x86_64","controller_version":"1.2.0","download_url":"","sha256":"","size":0,"total_size":0,"chunk_size":0,"decoded_size":0,"chunk_index":0,"is_last":True}})
        elif "/worker-version" in self.path:
            self._j(200, {"success":True,"data":{"version":"1.2.0","controller_version":"1.2.0","arch":"x86_64","download_url":"","sha256":"","total_size":0,"chunk_size":1048576,"decoded_size":0,"chunk_index":0,"is_last":True,"version_info":{"version":"1.2.0","arch":"x86_64","sha256":""}}})
        elif "/forwarder-version" in self.path:
            self._j(200, {"success":True,"data":{"version":"1.2.0","controller_version":"1.2.0","arch":"x86_64","download_url":"","sha256":"","total_size":0,"chunk_size":1048576,"decoded_size":0,"chunk_index":0,"is_last":True,"version_info":{"version":"1.2.0","arch":"x86_64","sha256":""}}})
        else:
            self._j(404, {"success":False,"error":"not_found"})
    def do_GET_versions(self, kind):
        # 给 controler 返回推荐 worker/forwarder 版本(避免 404 重试)
        return {"success":True,"data":{"version":"1.2.0","download_url":"","recommended":True}}
    def do_POST(self):
        ln = int(self.headers.get("Content-Length",0) or 0)
        body = self.rfile.read(ln) if ln else b""
        if self.path.startswith("/instance/") and self.path.endswith("/heartbeat"):
            import os
            iid = self.path.split("/")[2] or INSTANCE_ID
            st = os.environ.get("STRUCT", "0")
            tok = make_jwt(iid)
            lic = {"mode":"active","expires_at":"2036-01-01T00:00:00Z"}
            if st == "0":   b = {"success":True,"token":tok,"data":{"status":"active","token":tok,"access_token":tok,"jwt":tok,"license":lic,"entitlements":ENT,"expires_at":"2036-01-01T00:00:00Z"},"license":lic,"entitlements":ENT,"expires_at":"2036-01-01T00:00:00Z","status":"active"}
            elif st == "1": b = {"success":True,"data":{"status":"active","access_token":tok,"license":lic,"entitlements":ENT}}
            elif st == "2": b = {"success":True,"data":{"status":"active","jwt":tok,"license":lic,"entitlements":ENT}}
            elif st == "3": b = {"success":True,"data":{"status":"active","token_value":tok,"license":lic,"entitlements":ENT}}
            elif st == "4": b = {"success":True,"data":{"status":"active","token":{"jwt":tok,"expires_at":"2036-01-01T00:00:00Z"},"license":lic,"entitlements":ENT}}
            elif st == "5": b = {"success":True,"data":tok}
            elif st == "6": b = {"status":"active","token":tok,"license":lic,"entitlements":ENT,"success":True,"data":{"ok":1}}
            self._j(200, b)
        elif self.path.startswith("/instance/") and self.path.endswith("/status"):
            self._j(200, {"success":True,"data":{"status":"active","instance_id":INSTANCE_ID}})
        else:
            self._j(200, {"success":True})

if __name__ == "__main__":
    port = int(os.environ.get("MOCK_PORT","9099"))
    print(f"[mock-auth] listening :{port}", flush=True)
    http.server.ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()
