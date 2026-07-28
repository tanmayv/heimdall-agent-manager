#!/usr/bin/env python3
"""Phase 6 real-binary smoke for Agent + AgentBridgeSupport APIs."""
from __future__ import annotations
import json, os, socket, subprocess, tempfile, time, urllib.error, urllib.request
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

def free_port() -> int:
    s=socket.socket(); s.bind(("127.0.0.1",0)); p=s.getsockname()[1]; s.close(); return p

def wait_get(url: str, timeout: float=10.0) -> None:
    end=time.time()+timeout
    while time.time()<end:
        try:
            urllib.request.urlopen(url, timeout=.5).close(); return
        except Exception: time.sleep(.1)
    raise RuntimeError(url)

def req(method: str, url: str, body=None, headers=None):
    data=None if body is None else json.dumps(body).encode()
    r=urllib.request.Request(url, data=data, headers={"Content-Type":"application/json", **(headers or {})}, method=method)
    try:
        with urllib.request.urlopen(r, timeout=5) as resp: return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read().decode())

def main() -> None:
    hub_bin=Path(os.environ.get("HAM_HUB_BIN","/tmp/ham-hub-phase6"))
    if not hub_bin.exists(): raise SystemExit(f"missing HAM_HUB_BIN: {hub_bin}")
    port=free_port(); base=f"http://127.0.0.1:{port}/api/v1"
    alice={"X-authentik-username":"alice"}; bob={"X-authentik-username":"bob"}
    with tempfile.TemporaryDirectory(prefix="ham-hub-p6-") as tmp:
        hub=subprocess.Popen([str(hub_bin),"--listen",f"127.0.0.1:{port}","--db",str(Path(tmp)/"hub.db"),"--logout-url","/_dev/logout"], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            wait_get(f"{base}/health")
            st,enr=req("POST",f"{base}/bridge-enrollments",{"label":"P6 Bridge"},alice); assert st==201,enr
            token=enr["data"]["enrollment_token"]
            st,br=req("POST",f"{base}/bridges/enroll",{"machine":{"hostname":"p6"},"capabilities":[{"provider":"claude","tiers":["normal","smart"],"default_tier":"normal"}]},{"Authorization":f"Bearer {token}"}); assert st==201,br
            bridge_id=br["data"]["bridge_id"]
            st,enr2=req("POST",f"{base}/bridge-enrollments",{"label":"P6 Bridge 2"},alice); assert st==201,enr2
            token2=enr2["data"]["enrollment_token"]
            st,br2=req("POST",f"{base}/bridges/enroll",{"machine":{"hostname":"p6b"},"capabilities":[{"provider":"claude","tiers":["normal","smart"],"default_tier":"normal"}]},{"Authorization":f"Bearer {token2}"}); assert st==201,br2
            bridge_id_2=br2["data"]["bridge_id"]
            st,agent=req("POST",f"{base}/agents",{"name":"Backend","slug":"backend","default_provider":"claude","default_tier":"normal"},alice); assert st==201,agent
            agent_id=agent["data"]["agent_id"]
            st,bob_detail=req("GET",f"{base}/agents/{agent_id}",headers=bob); assert st==404,bob_detail
            st,substring=req("PATCH",f"{base}/agents/{agent_id}/bridge-support/{bridge_id}",{"enabled":True,"provider":"laud","tier":"mart"},alice); assert st==503,substring
            st,provider_tier=req("PATCH",f"{base}/agents/{agent_id}/bridge-support/{bridge_id}",{"enabled":True,"provider":"claude","tier":"claude"},alice); assert st==503,provider_tier
            st,key_tier=req("PATCH",f"{base}/agents/{agent_id}/bridge-support/{bridge_id}",{"enabled":True,"provider":"claude","tier":"tiers"},alice); assert st==503,key_tier
            st,bad=req("PATCH",f"{base}/agents/{agent_id}/bridge-support/{bridge_id}",{"enabled":True,"provider":"openai","tier":"smart"},alice); assert st==503,bad
            st,support=req("PATCH",f"{base}/agents/{agent_id}/bridge-support/{bridge_id}",{"enabled":True,"provider":"claude","tier":"smart","priority":10,"max_instances":2},alice); assert st==200,support
            st,replaced=req("PUT",f"{base}/agents/{agent_id}/bridge-support",{"bridges":[{"bridge_id":bridge_id,"enabled":True,"provider":"claude","tier":"smart"},{"bridge_id":bridge_id_2,"enabled":True,"provider":"claude","tier":"normal"}]},alice); assert st==200 and len(replaced["data"])==2,replaced
            st,supports=req("GET",f"{base}/agents/{agent_id}/bridge-support",headers=alice); assert st==200 and {s["bridge_id"] for s in supports["data"]}=={bridge_id, bridge_id_2},supports
            st,arch=req("POST",f"{base}/agents/{agent_id}/archive",headers=alice); assert st==200 and arch["data"]["state"]=="archived",arch
        finally:
            hub.terminate()
            try: hub.wait(timeout=3)
            except subprocess.TimeoutExpired: hub.kill()
    print("PASS: hub phase6 real smoke")
if __name__ == "__main__": main()
