#!/usr/bin/env python3
"""Phase 9 real-binary smoke for AgentInstance launch/stop through Bridge WS."""
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

def req(method,url,body=None,headers=None):
    data=None if body is None else json.dumps(body).encode(); h={"Content-Type":"application/json", **(headers or {})}
    r=urllib.request.Request(url,data=data,headers=h,method=method)
    try:
        with urllib.request.urlopen(r,timeout=5) as resp: return resp.status,json.loads(resp.read().decode())
    except urllib.error.HTTPError as e: return e.code,json.loads(e.read().decode())

def ws_send_json(s, obj):
    payload=json.dumps(obj).encode(); mask=os.urandom(4)
    if len(payload) <= 125: header=bytes([0x81,0x80|len(payload)])
    else: header=bytes([0x81,0x80|126,(len(payload)>>8)&255,len(payload)&255])
    s.sendall(header+mask+bytes(b^mask[i%4] for i,b in enumerate(payload)))

def ws_recv_json(s):
    frame=s.recv(65536); assert frame and frame[0]&0x0f==1, frame
    ln=frame[1]&0x7f; start=2
    if ln==126:
        ln=(frame[2]<<8)|frame[3]; start=4
    return json.loads(frame[start:start+ln].decode())

def ws_connect_bridge(port, token, bridge_id):
    key=base64.b64encode(os.urandom(16)).decode()
    s=socket.create_connection(("127.0.0.1",port),timeout=5)
    request=(f"GET /api/v1/bridge-ws HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer {token}\r\n\r\n").encode()
    s.sendall(request); resp=s.recv(4096); assert b"101 Switching Protocols" in resp, resp
    ws_send_json(s,{"type":"bridge_hello","bridge_id":bridge_id,"protocol_version":1,"hostname":"runner"})
    ready=ws_recv_json(s); assert ready["type"]=="bridge_ready", ready
    return s

def main():
    hub_bin=Path(os.environ.get("HAM_HUB_BIN","/tmp/ham-hub-phase9"))
    if not hub_bin.exists(): raise SystemExit(f"missing HAM_HUB_BIN: {hub_bin}")
    port=free_port(); base=f"http://127.0.0.1:{port}/api/v1"; alice={"X-authentik-username":"alice"}; bob={"X-authentik-username":"bob"}
    with tempfile.TemporaryDirectory(prefix="ham-hub-p9-") as tmp:
        hub=subprocess.Popen([str(hub_bin),"--listen",f"127.0.0.1:{port}","--db",str(Path(tmp)/"hub.db"),"--logout-url","/_dev/logout"],cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        bridge_ws=None
        try:
            wait_get(f"{base}/health")
            st,enr=req("POST",f"{base}/bridge-enrollments",{"label":"runtime"},alice); assert st==201,enr
            st,br=req("POST",f"{base}/bridges/enroll",{"machine":{"hostname":"runtime"},"capabilities":[{"provider":"claude","tiers":["normal","smart"],"default_tier":"normal"}]},{"Authorization":f"Bearer {enr['data']['enrollment_token']}"}); assert st==201,br
            bridge_id=br["data"]["bridge_id"]; bridge_token=br["data"]["bridge_token"]
            st,agent=req("POST",f"{base}/agents",{"name":"Agent","slug":"agent","default_provider":"claude","default_tier":"normal"},alice); assert st==201,agent
            agent_id=agent["data"]["agent_id"]
            st,support=req("PATCH",f"{base}/agents/{agent_id}/bridge-support/{bridge_id}",{"enabled":True,"provider":"claude","tier":"smart","priority":7},alice); assert st==200,support
            st,project=req("POST",f"{base}/projects",{"name":"Proj","slug":"proj","default_path":"/tmp/hub-phase9","vcs_kind":"none"},alice); assert st==201,project
            project_id=project["data"]["project_id"]
            st,offline=req("POST",f"{base}/agent-instances",{"agent_id":agent_id,"bridge_id":bridge_id,"project_id":project_id,"provider":"claude","tier":"smart"},alice); assert st==503 and offline["error"]["code"]=="bridge_offline",offline
            bridge_ws=ws_connect_bridge(port, bridge_token, bridge_id)
            st,created=req("POST",f"{base}/agent-instances",{"agent_id":agent_id,"project_id":project_id,"provider":"claude","tier":"smart"},alice); assert st==201,created
            inst=created["data"]; instance_id=inst["agent_instance_id"]
            assert inst["bridge_id"]==bridge_id and inst["provider"]=="claude" and inst["tier"]=="smart" and inst["project_path"]=="/tmp/hub-phase9" and inst["runtime_status"]=="launching",inst
            launch=ws_recv_json(bridge_ws); assert launch["type"]=="launch_agent" and launch["payload"]["agent_instance_id"]==instance_id and launch["payload"]["project_path"]=="/tmp/hub-phase9",launch
            st,bob_get=req("GET",f"{base}/agent-instances/{instance_id}",headers=bob); assert st==404,bob_get
            ws_send_json(bridge_ws,{"type":"bridge_heartbeat","instances":[{"agent_instance_id":instance_id,"state_seq":5,"runtime_status":"running","activity_status":"active"}]}); hb_digest=ws_recv_json(bridge_ws); assert hb_digest["type"]=="bridge_heartbeat_ack" and hb_digest["payload"]["reconciled_unreachable_count"]==0,hb_digest
            st,detail=req("GET",f"{base}/agent-instances/{instance_id}",headers=alice); assert st==200 and detail["data"]["runtime_status"]=="running" and detail["data"]["activity_status"]=="active" and detail["data"]["last_applied_seq"]==5,detail
            ws_send_json(bridge_ws,{"type":"agent_instance_status","agent_instance_id":instance_id,"state_seq":4,"runtime_status":"failed","activity_status":"idle"}); ack_old=ws_recv_json(bridge_ws); assert ack_old["payload"]["applied"] is False,ack_old
            st,detail=req("GET",f"{base}/agent-instances/{instance_id}",headers=alice); assert detail["data"]["runtime_status"]=="running" and detail["data"]["last_applied_seq"]==5,detail
            st,stopping=req("POST",f"{base}/agent-instances/{instance_id}/stop",{"reason":"user_requested"},alice); assert st==202 and stopping["data"]["runtime_status"]=="stopping",stopping
            stop=ws_recv_json(bridge_ws); assert stop["type"]=="stop_agent" and stop["payload"]["agent_instance_id"]==instance_id,stop
            ws_send_json(bridge_ws,{"type":"agent_instance_status","agent_instance_id":instance_id,"state_seq":6,"runtime_status":"stopped","activity_status":"idle"}); _=ws_recv_json(bridge_ws)
            st,detail=req("GET",f"{base}/agent-instances/{instance_id}",headers=alice); assert st==200 and detail["data"]["runtime_status"]=="stopped" and detail["data"]["last_applied_seq"]==6,detail
        finally:
            if bridge_ws:
                try: bridge_ws.close()
                except Exception: pass
            hub.terminate()
            try: hub.wait(timeout=3)
            except subprocess.TimeoutExpired: hub.kill()
    print("PASS: hub phase9 real smoke")
if __name__=="__main__": main()
