#!/usr/bin/env python3
"""M4 real Hub+Bridge-binary smoke for runtime launch/status/stop."""
from __future__ import annotations
import json, os, socket, subprocess, tempfile, time, urllib.error, urllib.request
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

def req(method,url,body=None,headers=None,timeout=5):
    data=None if body is None else json.dumps(body).encode(); h={"Content-Type":"application/json", **(headers or {})}
    r=urllib.request.Request(url,data=data,headers=h,method=method)
    try:
        with urllib.request.urlopen(r,timeout=timeout) as resp: return resp.status,json.loads(resp.read().decode())
    except urllib.error.HTTPError as e: return e.code,json.loads(e.read().decode() or '{}')

def wait_bridge_online(base, bridge_id, user_headers, timeout=10):
    end=time.time()+timeout
    last=None
    while time.time()<end:
        st,body=req("GET",f"{base}/bridges/{bridge_id}",headers=user_headers)
        last=body
        if st==200 and body["data"].get("status")=="online": return body
        time.sleep(.1)
    raise AssertionError(f"bridge did not become online: {last}")

def wait_instance_status(base, instance_id, user_headers, wanted, min_seq=0, timeout=10):
    end=time.time()+timeout
    last=None
    while time.time()<end:
        st,body=req("GET",f"{base}/agent-instances/{instance_id}",headers=user_headers)
        last=body
        if st==200 and body["data"].get("runtime_status")==wanted and body["data"].get("last_applied_seq",0)>=min_seq:
            return body
        time.sleep(.1)
    raise AssertionError(f"instance did not reach {wanted}: {last}")

def main():
    hub_bin=Path(os.environ.get("HAM_HUB_BIN","/tmp/ham-hub-m4"))
    bridge_bin=Path(os.environ.get("HAM_BRIDGE_BIN","/tmp/ham-bridge-m4"))
    if not hub_bin.exists(): raise SystemExit(f"missing HAM_HUB_BIN: {hub_bin}")
    if not bridge_bin.exists(): raise SystemExit(f"missing HAM_BRIDGE_BIN: {bridge_bin}")
    hub_port=free_port(); bridge_port=free_port(); base=f"http://127.0.0.1:{hub_port}/api/v1"; alice={"X-authentik-username":"alice"}
    with tempfile.TemporaryDirectory(prefix="ham-hub-m4-") as tmp:
        hub=subprocess.Popen([str(hub_bin),"--listen",f"127.0.0.1:{hub_port}","--db",str(Path(tmp)/"hub.db"),"--logout-url","/_dev/logout"],cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        bridge=None
        try:
            wait_get(f"{base}/health")
            st,enr=req("POST",f"{base}/bridge-enrollments",{"label":"real-runtime"},alice); assert st==201,enr
            tunneled_http=f"http://127.0.0.1:{hub_port}"
            st,br=req("POST",f"{base}/bridges/enroll",{"hub_url":tunneled_http,"machine":{"hostname":"real-runtime"},"capabilities":[{"provider":"openai","tiers":["normal"],"default_tier":"normal"}]},{"Authorization":f"Bearer {enr['data']['enrollment_token']}"}); assert st==201 and br["data"]["hub_url"]==tunneled_http,br
            bridge_id=br["data"]["bridge_id"]; bridge_token=br["data"]["bridge_token"]
            bridge=subprocess.Popen([str(bridge_bin),"--bind-host","127.0.0.1","--port",str(bridge_port),"--daemon-url",tunneled_http,"--daemon-id","real-runtime","--bridge-token",bridge_token],cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
            wait_bridge_online(base, bridge_id, alice)
            st,agent=req("POST",f"{base}/agents",{"name":"Runtime Agent","slug":"runtime-agent","default_provider":"claude","default_tier":"normal","instructions":"Smoke runtime"},alice); assert st==201,agent
            agent_id=agent["data"]["agent_id"]
            st,support=req("PATCH",f"{base}/agents/{agent_id}/bridge-support/{bridge_id}",{"enabled":True,"provider":"claude","tier":"normal","priority":1},alice); assert st==200,support
            st,project=req("POST",f"{base}/projects",{"name":"Runtime Project","slug":"runtime-project","default_path":"/tmp/hub-m4","vcs_kind":"none"},alice); assert st==201,project
            project_id=project["data"]["project_id"]
            st,created=req("POST",f"{base}/agent-instances",{"agent_id":agent_id,"bridge_id":bridge_id,"project_id":project_id},alice); assert st==201,created
            instance_id=created["data"]["agent_instance_id"]
            running=wait_instance_status(base, instance_id, alice, "running", min_seq=2)
            assert running["data"]["bridge_id"]==bridge_id and running["data"]["last_applied_seq"]>=2, running
            time.sleep(2.5)
            reasserted=wait_instance_status(base, instance_id, alice, "running", min_seq=2)
            assert reasserted["data"]["runtime_status"]=="running", reasserted
            st,stopping=req("POST",f"{base}/agent-instances/{instance_id}/stop",{"reason":"m4_smoke"},alice); assert st==202,stopping
            stopped=wait_instance_status(base, instance_id, alice, "stopped", min_seq=4)
            assert stopped["data"]["runtime_status"]=="stopped", stopped
        except Exception:
            if bridge and bridge.stdout:
                bridge.terminate()
                try: bridge.wait(timeout=3)
                except subprocess.TimeoutExpired: bridge.kill()
                print('--- bridge log ---')
                print(bridge.stdout.read())
                bridge=None
            if hub and hub.stdout:
                hub.terminate()
                try: hub.wait(timeout=3)
                except subprocess.TimeoutExpired: hub.kill()
                print('--- hub log ---')
                print(hub.stdout.read())
            raise
        finally:
            if bridge:
                bridge.terminate()
                try: bridge.wait(timeout=3)
                except subprocess.TimeoutExpired: bridge.kill()
            hub.terminate()
            try: hub.wait(timeout=3)
            except subprocess.TimeoutExpired: hub.kill()
    print("PASS: hub M4 real smoke")
if __name__=="__main__": main()
