#!/usr/bin/env python3
from __future__ import annotations
import base64, json, os, socket, subprocess, tempfile, time, urllib.error, urllib.request
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def free_port():
    s=socket.socket(); s.bind(('127.0.0.1',0)); p=s.getsockname()[1]; s.close(); return p
def wait_get(url,timeout=10):
    end=time.time()+timeout
    while time.time()<end:
        try: urllib.request.urlopen(url,timeout=.5).close(); return
        except Exception: time.sleep(.1)
    raise RuntimeError(url)
def req(method,url,body=None,headers=None):
    data=None if body is None else json.dumps(body).encode(); h={'Content-Type':'application/json', **(headers or {})}
    r=urllib.request.Request(url,data=data,headers=h,method=method)
    try:
        with urllib.request.urlopen(r,timeout=5) as resp:
            raw=resp.read().decode(); return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw=e.read().decode(); return e.code, (json.loads(raw) if raw else {})
def ws_send_json(s,obj):
    payload=json.dumps(obj).encode(); mask=os.urandom(4)
    header=bytes([0x81,0x80|len(payload)]) if len(payload)<=125 else bytes([0x81,0x80|126,(len(payload)>>8)&255,len(payload)&255])
    s.sendall(header+mask+bytes(b^mask[i%4] for i,b in enumerate(payload)))
def ws_recv_json(s):
    s.settimeout(5); frame=s.recv(65536); assert frame and frame[0]&0x0f==1,frame
    ln=frame[1]&0x7f; start=2
    if ln==126: ln=(frame[2]<<8)|frame[3]; start=4
    return json.loads(frame[start:start+ln].decode())
def ws_connect_bridge(port,token,bridge_id):
    key=base64.b64encode(os.urandom(16)).decode(); s=socket.create_connection(('127.0.0.1',port),timeout=5)
    req=(f'GET /api/v1/bridge-ws HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer {token}\r\n\r\n').encode()
    s.sendall(req); resp=s.recv(4096); assert b'101 Switching Protocols' in resp,resp
    ws_send_json(s,{'type':'bridge_hello','bridge_id':bridge_id,'protocol_version':1,'hostname':'runtime','capabilities':[{'provider':'claude','tiers':['normal'],'default_tier':'normal'}]})
    ready=ws_recv_json(s); assert ready['type']=='bridge_ready',ready
    return s
def main():
    hub_bin=Path(os.environ.get('HAM_HUB_BIN','/tmp/ham-hub-p11'))
    if not hub_bin.exists(): raise SystemExit(f'missing HAM_HUB_BIN: {hub_bin}')
    port=free_port(); base=f'http://127.0.0.1:{port}/api/v1'; alice={'X-authentik-username':'alice'}; bob={'X-authentik-username':'bob'}
    with tempfile.TemporaryDirectory(prefix='ham-hub-p11-') as tmp:
        hub=subprocess.Popen([str(hub_bin),'--listen',f'127.0.0.1:{port}','--db',str(Path(tmp)/'hub.db'),'--logout-url','/_dev/logout'],cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        bridge_ws=None
        try:
            wait_get(f'{base}/health')
            st,enr=req('POST',f'{base}/bridge-enrollments',{'label':'runtime'},alice); assert st==201,enr
            st,br=req('POST',f'{base}/bridges/enroll',{'machine':{'hostname':'runtime'},'capabilities':[{'provider':'claude','tiers':['normal'],'default_tier':'normal'}]},{'Authorization':f"Bearer {enr['data']['enrollment_token']}"}); assert st==201,br
            bridge_id=br['data']['bridge_id']; bridge_token=br['data']['bridge_token']; bridge_ws=ws_connect_bridge(port,bridge_token,bridge_id)
            st,agent=req('POST',f'{base}/agents',{'name':'Agent','slug':'agent','default_provider':'claude','default_tier':'normal'},alice); assert st==201,agent
            agent_id=agent['data']['agent_id']
            st,support=req('PATCH',f'{base}/agents/{agent_id}/bridge-support/{bridge_id}',{'enabled':True,'provider':'claude','tier':'normal'},alice); assert st==200,support
            st,project=req('POST',f'{base}/projects',{'name':'Project','slug':'project','default_path':tmp,'vcs_kind':'none'},alice); assert st==201,project
            project_id=project['data']['project_id']
            st,bob_bad_agent_art=req('POST',f'{base}/artifacts',{'kind':'markdown','name':'Bob-linked-to-alice-agent','content':'bad','agent_id':agent_id},bob); assert st in (403,404,409),bob_bad_agent_art
            st,bob_bad_project_art=req('POST',f'{base}/artifacts',{'kind':'markdown','name':'Bob-linked-to-alice-project','content':'bad','project_id':project_id},bob); assert st in (403,404,409),bob_bad_project_art
            st,mem=req('POST',f'{base}/memories',{'agent_id':agent_id,'type':'fact','title':'Pref','body':'Prefers concise summaries','evidence':'feedback'},alice); assert st==201 and mem['data']['status']=='pending',mem
            mem_id=mem['data']['memory_id']
            st,bob_mem=req('GET',f'{base}/memories/{mem_id}',headers=bob); assert st==404,bob_mem
            st,approved=req('POST',f'{base}/memories/{mem_id}/approve',headers=alice); assert st==200 and approved['data']['status']=='active',approved
            st,rejected=req('POST',f'{base}/memories/{mem_id}/reject',headers=alice); assert st==200 and rejected['data']['status']=='rejected',rejected
            st,arch=req('POST',f'{base}/memories/{mem_id}/archive',headers=alice); assert st==200 and arch['data']['status']=='archived',arch
            st,a1=req('POST',f'{base}/artifacts',{'kind':'markdown','name':'Report','description':'first','content_type':'text/markdown','content':'hello','agent_id':agent_id},alice); assert st==201,a1
            st,a2=req('POST',f'{base}/artifacts',{'kind':'markdown','name':'Report','description':'second','content_type':'text/markdown','content':'bye'},alice); assert st==201 and a2['data']['name']=='Report' and a2['data']['artifact_id']!=a1['data']['artifact_id'],a2
            art_id=a1['data']['artifact_id']
            st,content=req('GET',f'{base}/artifacts/{art_id}/content',headers=alice); assert st==200 and content['data']['content']=='hello',content
            st,bob_art=req('GET',f'{base}/artifacts/{art_id}/content',headers=bob); assert st==404,bob_art
            st,bob_owned_art=req('POST',f'{base}/artifacts',{'kind':'markdown','name':'Bob-owned','content':'secret'},bob); assert st==201,bob_owned_art
            bob_art_id=bob_owned_art['data']['artifact_id']
            st,bad_initial=req('POST',f'{base}/chats',{'agent_id':agent_id,'bridge_id':bridge_id,'provider':'claude','tier':'normal','initial_message':{'body':'bad cross-owner ref'},'artifact_ids':[bob_art_id]},alice); assert st in (403,404,409),bad_initial
            st,chats_empty=req('GET',f'{base}/chats',headers=alice); assert st==200 and len(chats_empty['data'])==0,chats_empty
            st,patched=req('PATCH',f'{base}/artifacts/{art_id}',{'name':'Renamed','description':'updated'},alice); assert st==200 and patched['data']['name']=='Renamed' and patched['data']['description']=='updated',patched
            st,chat=req('POST',f'{base}/chats',{'agent_id':agent_id,'bridge_id':bridge_id,'provider':'claude','tier':'normal','initial_message':{'body':'see artifact'},'artifact_ids':[art_id]},alice); assert st==201 and chat['data']['agent_instance_id'] and chat['data']['last_message_preview']=='see artifact',chat
            launch=ws_recv_json(bridge_ws); assert launch['type']=='launch_agent' and launch['payload']['agent_instance_id']==chat['data']['agent_instance_id'],launch
            chat_id=chat['data']['conversation_id']
            st,msgs=req('GET',f'{base}/chats/{chat_id}/messages?limit=1',headers=alice); assert st==200 and len(msgs['data'])==1 and msgs['page']['limit']==1 and 'unavailable/deleted' not in json.dumps(msgs),msgs
            st,bob_chat=req('GET',f'{base}/chats/{chat_id}/messages',headers=bob); assert st==404,bob_chat
            st,send=req('POST',f'{base}/chats/{chat_id}/messages',{'body':'second','artifact_ids':[]},alice); assert st==201,send
            st,page1=req('GET',f'{base}/chats/{chat_id}/messages?limit=1',headers=alice); assert st==200 and page1['page']['has_more'] is True,page1
            cursor=page1['page']['next_cursor']; st,page2=req('GET',f'{base}/chats/{chat_id}/messages?limit=1&cursor={cursor}',headers=alice); assert st==200,page2
            st,read=req('POST',f'{base}/chats/{chat_id}/read',headers=alice); assert st==200,read
            st,deleted=req('DELETE',f'{base}/artifacts/{art_id}',headers=alice); assert st==204,deleted
            st,msgs2=req('GET',f'{base}/chats/{chat_id}/messages?limit=5',headers=alice); assert st==200 and 'unavailable/deleted' in json.dumps(msgs2),msgs2
            st,t1=req('POST',f'{base}/templates',{'name':'Reviewer','description':'Careful','persona':'Review','instructions':'Test'},alice); assert st==201,t1
            st,templates=req('GET',f'{base}/templates',headers=alice); assert st==200 and any(t['name']=='Reviewer' and not t['is_system'] for t in templates['data']),templates
            st,bob_templates=req('GET',f'{base}/templates',headers=bob); assert st==200 and all(t['name']!='Reviewer' for t in bob_templates['data']) and any(t['is_system'] for t in bob_templates['data']),bob_templates
        finally:
            if bridge_ws:
                try: bridge_ws.close()
                except Exception: pass
            hub.terminate()
            try: hub.wait(timeout=3)
            except subprocess.TimeoutExpired: hub.kill()
    print('PASS: hub phase11 real smoke')
if __name__=='__main__': main()
