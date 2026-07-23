#!/usr/bin/env python3
"""Phase 8 real-binary smoke for Bridge runtime hello/auth/version behavior."""
from __future__ import annotations
import base64, json, os, socket, subprocess, tempfile, time, urllib.error, urllib.request
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

def ws_send_json(s, obj):
    payload=json.dumps(obj).encode(); mask=os.urandom(4)
    if len(payload) <= 125: header=bytes([0x81,0x80|len(payload)])
    else: header=bytes([0x81,0x80|126,(len(payload)>>8)&255,len(payload)&255])
    s.sendall(header+mask+bytes(b^mask[i%4] for i,b in enumerate(payload)))

def ws_recv_json(s):
    frame=s.recv(4096); assert frame and frame[0]&0x0f==1, frame
    ln=frame[1]&0x7f; start=2
    if ln==126:
        ln=(frame[2]<<8)|frame[3]; start=4
    return json.loads(frame[start:start+ln].decode())

def ws_connect_hello_payload(port, token, payload):
    key=base64.b64encode(os.urandom(16)).decode()
    s=socket.create_connection(("127.0.0.1",port),timeout=5)
    req=(f"GET /api/v1/bridge-ws HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer {token}\r\n\r\n").encode()
    s.sendall(req); resp=s.recv(4096); assert b"101 Switching Protocols" in resp, resp
    ws_send_json(s,payload)
    return s, ws_recv_json(s)

def ws_connect_hello(port, token, bridge_id):
    return ws_connect_hello_payload(port, token, {"type":"bridge_hello","bridge_id":bridge_id,"protocol_version":1})

def ws_bridge_hello(port, token, bridge_id):
    s, ready=ws_connect_hello(port, token, bridge_id); s.close(); return ready

def req(method,url,body=None,headers=None):
    data=None if body is None else json.dumps(body).encode(); h={"Content-Type":"application/json", **(headers or {})}
    r=urllib.request.Request(url,data=data,headers=h,method=method)
    try:
        with urllib.request.urlopen(r,timeout=5) as resp: return resp.status,json.loads(resp.read().decode())
    except urllib.error.HTTPError as e: return e.code,json.loads(e.read().decode())

def main():
    hub_bin=Path(os.environ.get("HAM_HUB_BIN","/tmp/ham-hub-phase8"))
    if not hub_bin.exists(): raise SystemExit(f"missing HAM_HUB_BIN: {hub_bin}")
    port=free_port(); base=f"http://127.0.0.1:{port}/api/v1"; alice={"X-authentik-username":"alice"}
    with tempfile.TemporaryDirectory(prefix="ham-hub-p8-") as tmp:
        hub=subprocess.Popen([str(hub_bin),"--listen",f"127.0.0.1:{port}","--db",str(Path(tmp)/"hub.db"),"--logout-url","/_dev/logout"],cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        try:
            wait_get(f"{base}/health")
            st,enr=req("POST",f"{base}/bridge-enrollments",{"label":"runtime"},alice); assert st==201,enr
            st,br=req("POST",f"{base}/bridges/enroll",{"machine":{"hostname":"runtime"},"capabilities":[{"provider":"claude","tiers":["normal"],"default_tier":"normal"}]},{"Authorization":f"Bearer {enr['data']['enrollment_token']}"}); assert st==201,br
            bridge_id=br["data"]["bridge_id"]; token=br["data"]["bridge_token"]; auth={"Authorization":f"Bearer {token}"}
            st,plain=req("POST",f"{base}/bridge-ws",{"type":"bridge_hello","bridge_id":bridge_id,"protocol_version":1},auth); assert st==404,plain
            bad_s,badver=ws_connect_hello_payload(port, token, {"type":"bridge_hello","bridge_id":bridge_id,"protocol_version":2}); assert badver["type"]=="bridge_error",badver; bad_s.close()
            mis_s,mismatch=ws_connect_hello_payload(port, token, {"type":"bridge_hello","bridge_id":"brg_wrong","protocol_version":1}); assert mismatch["type"]=="bridge_error",mismatch; mis_s.close()
            s,ws_ready=ws_connect_hello(port, token, bridge_id); assert ws_ready["type"]=="bridge_ready" and ws_ready["payload"]["connection_generation"]==1,ws_ready
            st,health_while_ws=req("GET",f"{base}/health"); assert st==200 and health_while_ws["data"]["ok"] is True,health_while_ws
            time.sleep(4)
            ws_send_json(s,{"type":"agent_instance_status","agent_instance_id":"inst_1","state_seq":10,"runtime_status":"running","activity_status":"idle"}); ack1=ws_recv_json(s); assert ack1["type"]=="agent_instance_status_ack" and ack1["payload"]["applied"] is True and ack1["payload"]["state_seq"]==10,ack1
            ws_send_json(s,{"type":"agent_instance_status","agent_instance_id":"inst_1","state_seq":9,"runtime_status":"failed","activity_status":"active"}); ack_old=ws_recv_json(s); assert ack_old["payload"]["applied"] is False and ack_old["payload"]["runtime_status"]=="running" and ack_old["payload"]["state_seq"]==10,ack_old
            ws_send_json(s,{"type":"bridge_heartbeat","instances":[{"agent_instance_id":"inst_1","state_seq":11,"runtime_status":"running","activity_status":"active"}]}); hb_digest=ws_recv_json(s); assert hb_digest["type"]=="bridge_heartbeat_ack" and hb_digest["payload"]["reconciled_unreachable_count"]==0,hb_digest
            ws_send_json(s,{"type":"bridge_heartbeat","active_instance_ids":[]}); hb=ws_recv_json(s); assert hb["type"]=="bridge_heartbeat_ack" and hb["payload"]["reconciled_unreachable_count"]==1,hb
            s.close()
            old,old_ready=ws_connect_hello(port, token, bridge_id); assert old_ready["payload"]["replaced_existing"] is False,old_ready
            new,new_ready=ws_connect_hello(port, token, bridge_id); assert new_ready["payload"]["connection_generation"]==old_ready["payload"]["connection_generation"]+1 and new_ready["payload"]["replaced_existing"] is True,new_ready
            ws_send_json(old,{"type":"agent_instance_status","agent_instance_id":"inst_old","state_seq":1,"runtime_status":"running","activity_status":"idle"}); replaced=ws_recv_json(old); assert replaced["type"]=="connection_replaced",replaced
            ws_send_json(new,{"type":"bridge_heartbeat","active_instance_ids":[]}); hb_new=ws_recv_json(new); assert hb_new["payload"]["reconciled_unreachable_count"]==0,hb_new
            old.close(); new.close()
        finally:
            hub.terminate()
            try: hub.wait(timeout=3)
            except subprocess.TimeoutExpired: hub.kill()
    print("PASS: hub phase8 real smoke")
if __name__=="__main__": main()
