#!/usr/bin/env python3
"""Phase 7 real-binary smoke for Project effective paths and validation."""
from __future__ import annotations
import base64, json, os, socket, subprocess, tempfile, threading, time, urllib.error, urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

def free_port():
    s=socket.socket(); s.bind(("127.0.0.1",0)); p=s.getsockname()[1]; s.close(); return p

def wait_get(url, timeout=10):
    end=time.time()+timeout
    while time.time()<end:
        try: urllib.request.urlopen(url,timeout=.5).close(); return
        except Exception: time.sleep(.1)
    raise RuntimeError(url)

def req(method,url,body=None,headers=None):
    data=None if body is None else json.dumps(body).encode(); h={"Content-Type":"application/json", **(headers or {})}
    r=urllib.request.Request(url,data=data,headers=h,method=method)
    try:
        with urllib.request.urlopen(r,timeout=5) as resp: return resp.status,json.loads(resp.read().decode())
    except urllib.error.HTTPError as e: return e.code,json.loads(e.read().decode())

def enroll_offline(base, user, label):
    st,enr=req("POST",f"{base}/bridge-enrollments",{"label":label},user); assert st==201,enr
    token=enr["data"]["enrollment_token"]
    st,br=req("POST",f"{base}/bridges/enroll",{"machine":{"hostname":label},"capabilities":[{"provider":"claude","tiers":["normal"],"default_tier":"normal"}]},{"Authorization":f"Bearer {token}"}); assert st==201,br
    return br["data"]["bridge_id"], br["data"]["bridge_token"]

def ws_send_json(s, obj):
    payload=json.dumps(obj).encode(); mask=os.urandom(4)
    if len(payload) <= 125: header=bytes([0x81,0x80|len(payload)])
    else: header=bytes([0x81,0x80|126,(len(payload)>>8)&255,len(payload)&255])
    s.sendall(header+mask+bytes(b^mask[i%4] for i,b in enumerate(payload)))

def ws_recv_json(s):
    frame=s.recv(4096); assert frame and frame[0]&0x0f==1, frame
    ln=frame[1]&0x7f; start=2
    if ln==126: ln=(frame[2]<<8)|frame[3]; start=4
    return json.loads(frame[start:start+ln].decode())

def connect_bridge(base, bridge_token, validation_ws_url=None, keep_open=False):
    port=int(base.split(':')[-1].split('/')[0])
    key=base64.b64encode(os.urandom(16)).decode()
    s=socket.create_connection(("127.0.0.1",port),timeout=5)
    request=(f"GET /api/v1/bridge-ws HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer {bridge_token}\r\n\r\n").encode()
    s.sendall(request); resp=s.recv(4096); assert b"101 Switching Protocols" in resp, resp
    body={"type":"bridge_hello","hostname":"host","protocol_version":1,"capabilities":[{"provider":"claude","tiers":["normal"],"default_tier":"normal"}]}
    if validation_ws_url: body["validation_ws_url"]=validation_ws_url
    ws_send_json(s,body); ready=ws_recv_json(s); assert ready["type"]=="bridge_ready",ready
    if keep_open:
        return s
    s.close()
    return None

class ValidationHandler(BaseHTTPRequestHandler):
    seen=[]
    def do_POST(self):
        length=int(self.headers.get("Content-Length","0")); body=json.loads(self.rfile.read(length).decode() or "{}")
        ValidationHandler.seen.append(body)
        p=Path(body.get("path","")); ok=True; code=""; msg=""
        if not p.exists(): ok=False; code="path_not_found"; msg="Path does not exist"
        elif not p.is_dir(): ok=False; code="path_not_directory"; msg="Path is not a directory"
        elif body.get("vcs_kind")=="git" and not any((parent/".git").exists() for parent in [p,*p.parents]): ok=False; code="git_root_not_found"; msg="Git root was not found"
        result={"type":"project_path_validation_result","command_id":body.get("command_id"),"project_id":body.get("project_id"),"path":body.get("path"),"ok":ok,"validation_error":msg,"error":{"code":code,"message":msg}}
        raw=json.dumps(result).encode(); self.send_response(200); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(raw))); self.end_headers(); self.wfile.write(raw)
    def log_message(self,*args): pass

def start_validation_server():
    bridge_bin=os.environ.get("HAM_BRIDGE_BIN")
    port=free_port()
    if bridge_bin and Path(bridge_bin).exists():
        no_config=str(Path(tempfile.gettempdir())/f"ham-bridge-no-config-{port}.toml")
        proc=subprocess.Popen([bridge_bin,"--config",no_config,"--bind-host","127.0.0.1","--port",str(port),"--daemon-url","http://127.0.0.1:9"],cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        wait_get(f"http://127.0.0.1:{port}/bridge/health")
        return proc, f"ws://127.0.0.1:{port}/bridge-ws", True
    raise SystemExit("HAM_BRIDGE_BIN is required for Bridge WebSocket validation smoke")

def main():
    hub_bin=Path(os.environ.get("HAM_HUB_BIN","/tmp/ham-hub-phase7"))
    if not hub_bin.exists(): raise SystemExit(f"missing HAM_HUB_BIN: {hub_bin}")
    port=free_port(); base=f"http://127.0.0.1:{port}/api/v1"; alice={"X-authentik-username":"alice"}; bob={"X-authentik-username":"bob"}
    with tempfile.TemporaryDirectory(prefix="ham-hub-p7-") as tmp:
        db_path=Path(tmp)/"hub.db"
        default_path=Path(tmp)/"default"; bridge_path=Path(tmp)/"bridge"
        default_path.mkdir(); (default_path/".git").mkdir()
        bridge_path.mkdir(); (bridge_path/".git").mkdir()
        def start_hub():
            h=subprocess.Popen([str(hub_bin),"--listen",f"127.0.0.1:{port}","--db",str(db_path),"--logout-url","/_dev/logout"],cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
            wait_get(f"{base}/health")
            return h
        validation_server, validation_url, validation_is_bridge = start_validation_server()
        hub=start_hub()
        sockets=[]
        try:
            bridge_id,bridge_token=enroll_offline(base, alice, "alice-bridge"); sockets.append(connect_bridge(base, bridge_token, validation_url, keep_open=True))
            bob_bridge_id,bob_bridge_token=enroll_offline(base, bob, "bob-bridge"); connect_bridge(base, bob_bridge_token, validation_url)
            offline_bridge_id,_=enroll_offline(base, alice, "offline-bridge")
            no_adapter_bridge_id,no_adapter_token=enroll_offline(base, alice, "no-adapter-bridge"); connect_bridge(base, no_adapter_token)
            st,missing=req("POST",f"{base}/projects",{"name":"No Path"},alice); assert st==400,missing
            st,proj=req("POST",f"{base}/projects",{"name":"Heimdall","slug":"heimdall","default_path":str(default_path),"vcs_kind":"git"},alice); assert st==201,proj
            project_id=proj["data"]["project_id"]
            st,bob_detail=req("GET",f"{base}/projects/{project_id}",headers=bob); assert st==404,bob_detail
            st,bad=req("PUT",f"{base}/projects/{project_id}/bridge-paths/{bob_bridge_id}",{"path":"/bob/path"},alice); assert st==404,bad
            st,offline=req("POST",f"{base}/projects/{project_id}/bridge-paths/{offline_bridge_id}/validate",headers=alice); assert st==503 and offline["error"]["code"]=="bridge_offline",offline
            st,no_adapter=req("POST",f"{base}/projects/{project_id}/bridge-paths/{no_adapter_bridge_id}/validate",headers=alice); assert st==503 and no_adapter["error"]["code"]=="bridge_offline",no_adapter
            st,setp=req("PUT",f"{base}/projects/{project_id}/bridge-paths/{bridge_id}",{"path":str(bridge_path)},alice); assert st==200 and setp["data"]["path"]==str(bridge_path) and setp["data"]["is_validated"] is False,setp
            before=len(ValidationHandler.seen)
            st,val=req("POST",f"{base}/projects/{project_id}/bridge-paths/{bridge_id}/validate",headers=alice); assert st==200 and val["data"]["is_validated"] is True and val["data"]["validation_details"]["command"]=="validate_project_path" and val["data"]["validation_details"]["command_id"].startswith("cmd_"),val
            if validation_is_bridge:
                assert val["data"]["validation_details"]["command"]=="validate_project_path" and val["data"]["validation_details"]["bridge_id"]==bridge_id, val
            else:
                assert len(ValidationHandler.seen)==before+1 and ValidationHandler.seen[-1]["type"]=="validate_project_path" and ValidationHandler.seen[-1]["bridge_id"]==bridge_id, ValidationHandler.seen[-1:]
            st,invalid_proj=req("POST",f"{base}/projects",{"name":"Invalid","slug":"invalid","default_path":"/definitely/not/a/real/path/heimdall-review","vcs_kind":"git","repo_url":"https://example.invalid/mismatch"},alice); assert st==201,invalid_proj
            invalid_project_id=invalid_proj["data"]["project_id"]
            st,invalid_val=req("POST",f"{base}/projects/{invalid_project_id}/bridge-paths/{bridge_id}/validate",headers=alice); assert st==200 and invalid_val["data"]["is_validated"] is False and invalid_val["data"]["validation_error"] and invalid_val["data"]["validation_details"]["error"]["code"]=="path_not_found",invalid_val
            revoked_bridge_id,revoked_bridge_token=enroll_offline(base, alice, "revoked-bridge"); sockets.append(connect_bridge(base, revoked_bridge_token, validation_url, keep_open=True))
            st,revoked=req("POST",f"{base}/bridges/{revoked_bridge_id}/revoke",headers=alice); assert st==200 and revoked["data"]["status"]=="revoked",revoked
            st,revoked_val=req("POST",f"{base}/projects/{project_id}/bridge-paths/{revoked_bridge_id}/validate",headers=alice); assert st==403 and revoked_val["error"]["code"]=="bridge_revoked",revoked_val
            st,bad_delete=req("DELETE",f"{base}/projects/{project_id}/bridge-paths/{bob_bridge_id}",headers=alice); assert st==404,bad_delete
            st,delete=req("DELETE",f"{base}/projects/{project_id}/bridge-paths/{bridge_id}",headers=alice); assert st==200 and delete["data"]["deleted"] is True,delete
            hub.terminate(); hub.wait(timeout=3)
            hub=start_hub()
            st,restart_val=req("POST",f"{base}/projects/{project_id}/bridge-paths/{bridge_id}/validate",headers=alice); assert st==503 and restart_val["error"]["code"]=="bridge_offline",restart_val
        finally:
            for sock in sockets:
                if sock:
                    try: sock.close()
                    except OSError: pass
            if validation_is_bridge:
                validation_server.terminate()
                try: validation_server.wait(timeout=3)
                except subprocess.TimeoutExpired: validation_server.kill()
            else:
                validation_server.shutdown(); validation_server.server_close()
            hub.terminate()
            try: hub.wait(timeout=3)
            except subprocess.TimeoutExpired: hub.kill()
    print("PASS: hub phase7 real smoke")
if __name__=="__main__": main()
