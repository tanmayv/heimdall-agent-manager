#!/usr/bin/env python3
"""Phase 10 real-binary smoke for user-ws invalidation and bootstrap fetch."""
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
    except urllib.error.HTTPError as e: return e.code,json.loads(e.read().decode() or '{}')

def ws_send_json(s,obj):
    payload=json.dumps(obj).encode(); mask=os.urandom(4)
    if len(payload)<=125: header=bytes([0x81,0x80|len(payload)])
    else: header=bytes([0x81,0x80|126,(len(payload)>>8)&255,len(payload)&255])
    s.sendall(header+mask+bytes(b^mask[i%4] for i,b in enumerate(payload)))

# Per-socket receive buffer so multiple WS frames delivered in one TCP segment
# are parsed one-at-a-time instead of being dropped. Keyed by fileno.
_WS_BUFFERS={}

def ws_recv_json(s):
    buf=_WS_BUFFERS.get(s.fileno(),b"")
    while True:
        # Need at least the 2-byte header before we can size the frame.
        while len(buf)<2:
            chunk=s.recv(65536)
            if not chunk: raise AssertionError("socket closed while reading ws frame")
            buf+=chunk
        ln=buf[1]&0x7f; start=2
        if ln==126:
            while len(buf)<4:
                chunk=s.recv(65536)
                if not chunk: raise AssertionError("socket closed while reading ws frame")
                buf+=chunk
            ln=(buf[2]<<8)|buf[3]; start=4
        while len(buf)<start+ln:
            chunk=s.recv(65536)
            if not chunk: raise AssertionError("socket closed while reading ws frame")
            buf+=chunk
        assert buf[0]&0x0f==1, buf[:start+ln]
        payload=buf[start:start+ln]
        _WS_BUFFERS[s.fileno()]=buf[start+ln:]
        return json.loads(payload.decode())

def ws_connect(path, port, headers=None):
    key=base64.b64encode(os.urandom(16)).decode(); s=socket.create_connection(("127.0.0.1",port),timeout=5)
    extra=''.join(f"{k}: {v}\r\n" for k,v in (headers or {}).items())
    request=(f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n{extra}\r\n").encode()
    s.sendall(request); resp=s.recv(4096); assert b"101 Switching Protocols" in resp, resp
    return s

def ws_connect_bridge(port, token, bridge_id):
    s=ws_connect('/api/v1/bridge-ws', port, {"Authorization":f"Bearer {token}"})
    ws_send_json(s,{"type":"bridge_hello","bridge_id":bridge_id,"protocol_version":1,"hostname":"runner"})
    ready=ws_recv_json(s); assert ready["type"]=="bridge_ready",ready
    return s

def recv_resource_changed(s):
    end=time.time()+5
    while time.time()<end:
        evt=ws_recv_json(s)
        if evt.get("type")=="resource_changed": return evt
    raise AssertionError("resource_changed not received")

def main():
    hub_bin=Path(os.environ.get("HAM_HUB_BIN","/tmp/ham-hub-phase10"))
    bridge_bin=Path(os.environ.get("HAM_BRIDGE_BIN","/tmp/ham-bridge-phase10"))
    if not hub_bin.exists(): raise SystemExit(f"missing HAM_HUB_BIN: {hub_bin}")
    if not bridge_bin.exists(): raise SystemExit(f"missing HAM_BRIDGE_BIN: {bridge_bin}")
    port=free_port(); base=f"http://127.0.0.1:{port}/api/v1"; alice={"X-authentik-username":"alice"}; bob={"X-authentik-username":"bob"}
    with tempfile.TemporaryDirectory(prefix="ham-hub-p10-") as tmp:
        hub=subprocess.Popen([str(hub_bin),"--listen",f"127.0.0.1:{port}","--db",str(Path(tmp)/"hub.db"),"--logout-url","/_dev/logout"],cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        user_ws=bridge_ws=None
        try:
            wait_get(f"{base}/health")
            st,token_q=req("GET",f"{base}/bridge/agent-instances/inst_x/bootstrap?token=hbr_bad"); assert st==401,token_q
            user_ws=ws_connect('/api/v1/user-ws', port, alice)
            st,enr=req("POST",f"{base}/bridge-enrollments",{"label":"runtime"},alice); assert st==201,enr
            st,br=req("POST",f"{base}/bridges/enroll",{"machine":{"hostname":"runtime"},"capabilities":[{"provider":"claude","tiers":["normal"],"default_tier":"normal"}]},{"Authorization":f"Bearer {enr['data']['enrollment_token']}"}); assert st==201,br
            bridge_id=br["data"]["bridge_id"]; bridge_token=br["data"]["bridge_token"]
            bridge_ws=ws_connect_bridge(port, bridge_token, bridge_id)
            st,agent=req("POST",f"{base}/agents",{"name":"Agent","slug":"agent","default_provider":"claude","default_tier":"normal","instructions":"Be helpful"},alice); assert st==201,agent
            agent_id=agent["data"]["agent_id"]
            st,support=req("PATCH",f"{base}/agents/{agent_id}/bridge-support/{bridge_id}",{"enabled":True,"provider":"claude","tier":"normal"},alice); assert st==200,support
            st,project=req("POST",f"{base}/projects",{"name":"Proj","slug":"proj","default_path":"/tmp/hub-phase10","vcs_kind":"none"},alice); assert st==201,project
            project_id=project["data"]["project_id"]
            st,created=req("POST",f"{base}/agent-instances",{"agent_id":agent_id,"bridge_id":bridge_id,"project_id":project_id},alice); assert st==201,created
            inst_id=created["data"]["agent_instance_id"]
            coordinator_chain_id=created["data"]["chain_id"]
            event=recv_resource_changed(user_ws); assert event["resource"]=="agent_instance" and event["resource_id"]==inst_id and event["change"]=="created",event
            launch=ws_recv_json(bridge_ws); assert launch["type"]=="launch_agent",launch
            st,bundle=req("GET",f"{base}/bridge/agent-instances/{inst_id}/bootstrap",headers={"Authorization":f"Bearer {bridge_token}"}); assert st==200,bundle
            data=bundle["data"]; assert data["agent_instance_id"]==inst_id and data["runtime"]["project_path"]=="/tmp/hub-phase10" and data["instance_token"].startswith("hit_") and data["files"][0]["relative_path"]=="AGENTS.md",data
            run_dir=Path(tmp)/"bridge-run"; subprocess.run([str(bridge_bin),"--bootstrap-fetch","--daemon-url",f"http://127.0.0.1:{port}","--bridge-token",bridge_token,"--instance-id",inst_id,"--run-dir",str(run_dir)],cwd=ROOT,check=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
            assert (run_dir/"AGENTS.md").exists() and (run_dir/"heimdall-bootstrap-manifest.json").exists(), list(run_dir.iterdir())
            st,bob_enr=req("POST",f"{base}/bridge-enrollments",{"label":"bob"},bob); assert st==201,bob_enr
            st,bob_br=req("POST",f"{base}/bridges/enroll",{"machine":{"hostname":"bob"},"capabilities":[{"provider":"claude","tiers":["normal"],"default_tier":"normal"}]},{"Authorization":f"Bearer {bob_enr['data']['enrollment_token']}"}); assert st==201,bob_br
            st,bob_boot=req("GET",f"{base}/bridge/agent-instances/{inst_id}/bootstrap",headers={"Authorization":f"Bearer {bob_br['data']['bridge_token']}"}); assert st==404,bob_boot
            ws_send_json(bridge_ws,{"type":"agent_instance_status","agent_instance_id":inst_id,"state_seq":1,"runtime_status":"running","activity_status":"idle"}); ack=ws_recv_json(bridge_ws); assert ack["payload"]["applied"] is True,ack
            status_event=recv_resource_changed(user_ws); assert status_event["resource"]=="agent_instance" and status_event["change"]=="status_changed" and status_event["summary"]["runtime_status"]=="running",status_event

            # Agent-initiated add-agent: a running agent adds another agent to its own
            # chain using its bridge-relayed instance token (bridge bearer token +
            # X-Heimdall-Instance-Token: hit_<instance>), exactly as ham-ctl relays
            # agent.rest.request. Previously POST /agent-instances was user-token only
            # and returned 403 'bridge token cannot call user APIs'.
            agent_relay_headers={"Authorization":f"Bearer {bridge_token}","X-Heimdall-Instance-Token":f"hit_{inst_id}"}
            st,agent_added=req("POST",f"{base}/agent-instances",{"agent_id":agent_id,"bridge_id":bridge_id,"project_id":project_id,"chain_id":coordinator_chain_id},agent_relay_headers); assert st==201,agent_added
            added_inst_id=agent_added["data"]["agent_instance_id"]
            assert agent_added["data"]["chain_id"]==coordinator_chain_id,agent_added
            added_event=recv_resource_changed(user_ws); assert added_event["resource"]=="agent_instance" and added_event["resource_id"]==added_inst_id and added_event["change"]=="created",added_event
            added_launch=ws_recv_json(bridge_ws); assert added_launch["type"]=="launch_agent",added_launch
            # The new instance is bound to the coordinator's chain as a member.
            st,members=req("GET",f"{base}/task-chains/{coordinator_chain_id}/members",None,alice); assert st==200,members
            member_ids={m["agent_instance_id"] for m in members["data"]}; assert added_inst_id in member_ids and inst_id in member_ids,members
            # A foreign bridge token (bob) must NOT be able to act for alice's instance.
            st,forbidden=req("POST",f"{base}/agent-instances",{"agent_id":agent_id,"bridge_id":bridge_id,"project_id":project_id,"chain_id":coordinator_chain_id},{"Authorization":f"Bearer {bob_br['data']['bridge_token']}","X-Heimdall-Instance-Token":f"hit_{inst_id}"}); assert st in (403,404),forbidden

            # UI-BE-7: task/chain mutations MUST also fan out resource_changed so the
            # UI task views live-update without a manual refresh. Prior to the fix the
            # taskchain handlers published nothing on the user WebSocket.
            st,chain=req("POST",f"{base}/task-chains",{"title":"Live update chain","description":"d"},alice); assert st==201,chain
            chain_id=chain["data"]["chain_id"]
            chain_created=recv_resource_changed(user_ws); assert chain_created["resource"]=="task_chain" and chain_created["resource_id"]==chain_id and chain_created["change"]=="created",chain_created
            st,task=req("POST",f"{base}/task-chains/{chain_id}/tasks",{"title":"Live task","description":"d"},alice); assert st==201,task
            task_id=task["data"]["task_id"]
            # create_task emits a task 'created' event and a chain 'updated' event.
            task_created=recv_resource_changed(user_ws); assert task_created["resource"]=="task" and task_created["resource_id"]==task_id and task_created["change"]=="created" and task_created["summary"]["chain_id"]==chain_id,task_created
            chain_updated=recv_resource_changed(user_ws); assert chain_updated["resource"]=="task_chain" and chain_updated["resource_id"]==chain_id and chain_updated["change"]=="updated",chain_updated
            # Tasks start as drafts; publishing the chain publishes + auto-promotes its
            # tasks (one chain resource_changed) before a status transition is legal.
            st,pub_chain=req("POST",f"{base}/task-chains/{chain_id}/publish",{},alice); assert st==200,pub_chain
            pub_chain_evt=recv_resource_changed(user_ws); assert pub_chain_evt["resource"]=="task_chain" and pub_chain_evt["resource_id"]==chain_id,pub_chain_evt
            st,status_resp=req("POST",f"{base}/task-chains/{chain_id}/tasks/{task_id}/status",{"status":"in_progress"},alice); assert st==200,status_resp
            task_status=recv_resource_changed(user_ws); assert task_status["resource"]=="task" and task_status["resource_id"]==task_id and task_status["change"]=="status_changed",task_status
        finally:
            for s in (user_ws,bridge_ws):
                if s:
                    try: s.close()
                    except Exception: pass
            hub.terminate()
            try: hub.wait(timeout=3)
            except subprocess.TimeoutExpired: hub.kill()
    print("PASS: hub phase10 real smoke")
if __name__=="__main__": main()
