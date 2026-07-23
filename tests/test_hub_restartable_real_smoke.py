#!/usr/bin/env python3
"""Real-binary smoke for restartable AgentInstance sessions and provider/tier PATCH."""
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
        with urllib.request.urlopen(r,timeout=5) as resp: return resp.status,json.loads(resp.read().decode() or '{}')
    except urllib.error.HTTPError as e: return e.code,json.loads(e.read().decode() or '{}')

def ws_send_json(s,obj):
    payload=json.dumps(obj).encode(); mask=os.urandom(4)
    if len(payload)<=125: header=bytes([0x81,0x80|len(payload)])
    else: header=bytes([0x81,0x80|126,(len(payload)>>8)&255,len(payload)&255])
    s.sendall(header+mask+bytes(b^mask[i%4] for i,b in enumerate(payload)))

def ws_recv_json(s,timeout=5):
    s.settimeout(timeout); frame=s.recv(65536); assert frame and frame[0]&0x0f==1,frame
    ln=frame[1]&0x7f; start=2
    if ln==126: ln=(frame[2]<<8)|frame[3]; start=4
    return json.loads(frame[start:start+ln].decode())

def ws_connect_bridge(port,token,bridge_id):
    key=base64.b64encode(os.urandom(16)).decode(); s=socket.create_connection(('127.0.0.1',port),timeout=5)
    request=(f'GET /api/v1/bridge-ws HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer {token}\r\n\r\n').encode()
    s.sendall(request); resp=s.recv(4096); assert b'101 Switching Protocols' in resp,resp
    ws_send_json(s,{'type':'bridge_hello','bridge_id':bridge_id,'protocol_version':1,'hostname':'runner','capabilities':[{'provider':'claude','tiers':['normal','smart'],'default_tier':'normal'}]})
    ready=ws_recv_json(s); assert ready['type']=='bridge_ready',ready
    return s

def main():
    hub_bin=Path(os.environ.get('HAM_HUB_BIN','/tmp/ham-hub-restartable'))
    if not hub_bin.exists(): raise SystemExit(f'missing HAM_HUB_BIN: {hub_bin}')
    port=free_port(); base=f'http://127.0.0.1:{port}/api/v1'; alice={'X-authentik-username':'alice'}
    with tempfile.TemporaryDirectory(prefix='ham-hub-restart-') as tmp:
        hub=subprocess.Popen([str(hub_bin),'--listen',f'127.0.0.1:{port}','--db',str(Path(tmp)/'hub.db'),'--logout-url','/_dev/logout'],cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        bridge_ws=None
        try:
            wait_get(f'{base}/health')
            st,enr=req('POST',f'{base}/bridge-enrollments',{'label':'runtime'},alice); assert st==201,enr
            st,br=req('POST',f'{base}/bridges/enroll',{'machine':{'hostname':'runtime'},'capabilities':[{'provider':'claude','tiers':['normal','smart'],'default_tier':'normal'}]},{'Authorization':f"Bearer {enr['data']['enrollment_token']}"}); assert st==201,br
            bridge_id=br['data']['bridge_id']; bridge_token=br['data']['bridge_token']
            st,agent=req('POST',f'{base}/agents',{'name':'Agent','slug':'agent','default_provider':'claude','default_tier':'normal'},alice); assert st==201,agent
            agent_id=agent['data']['agent_id']
            st,support=req('PATCH',f'{base}/agents/{agent_id}/bridge-support/{bridge_id}',{'enabled':True,'provider':'claude','tier':'','priority':7},alice); assert st==200,support
            st,project=req('POST',f'{base}/projects',{'name':'Proj','slug':'proj','default_path':'/tmp/hub-restartable','vcs_kind':'none'},alice); assert st==201,project
            project_id=project['data']['project_id']
            st,offline=req('POST',f'{base}/agent-instances',{'agent_id':agent_id,'bridge_id':bridge_id,'project_id':project_id,'provider':'claude','tier':'normal'},alice); assert st==503 and offline['error']['code']=='bridge_offline',offline
            bridge_ws=ws_connect_bridge(port,bridge_token,bridge_id)
            st,created=req('POST',f'{base}/agent-instances',{'agent_id':agent_id,'bridge_id':bridge_id,'project_id':project_id,'provider':'claude','tier':'normal'},alice); assert st==201,created
            inst=created['data']; instance_id=inst['agent_instance_id']; private_chain_id=inst['chain_id']; private_conversation_id=inst['conversation_id']; assert inst['run_count']==1 and inst['tier']=='normal' and private_chain_id and private_conversation_id,inst
            launch1=ws_recv_json(bridge_ws); assert launch1['type']=='launch_agent' and launch1['payload']['agent_instance_id']==instance_id and launch1['payload']['tier']=='normal' and launch1['payload']['chain_id']==private_chain_id and launch1['payload']['conversation_id']==private_conversation_id,launch1
            st,private_chain=req('GET',f'{base}/task-chains/{private_chain_id}',headers=alice); assert st==200 and private_chain['data']['kind']=='private_conversation',private_chain
            st,bundle=req('GET',f'{base}/bridge/agent-instances/{instance_id}/bootstrap',headers={'Authorization':f'Bearer {bridge_token}'}); assert st==200 and bundle['data']['agent_instance_id']==instance_id and bundle['data']['chain_id']==private_chain_id and bundle['data']['conversation_id']==private_conversation_id and bundle['data']['chain']['chain_id']==private_chain_id and bundle['data']['chain']['coordinator_agent_instance_id']==instance_id and bundle['data']['chain']['default_reviewer_refs']==[] and bundle['data']['task_context']['effective_assignee_ref']['agent_instance_id']==instance_id and 'effective_reviewer_refs' in bundle['data']['task_context'] and 'current_task' in bundle['data']['task_context'] and 'runnable_frontier' in bundle['data']['task_context'] and bundle['data']['conversation']['conversation_id']==private_conversation_id and 'recent_messages' in bundle['data']['conversation'],bundle
            ws_send_json(bridge_ws,{'type':'agent_instance_status','agent_instance_id':instance_id,'state_seq':5,'runtime_status':'running','activity_status':'idle'}); _=ws_recv_json(bridge_ws)
            st,detail=req('GET',f'{base}/agent-instances/{instance_id}',headers=alice); assert st==200 and detail['data']['runtime_status']=='running' and detail['data']['last_applied_seq']==5,detail
            st,chats=req('GET',f'{base}/chats',headers=alice); assert st==200 and len(chats['data'])==1 and chats['data'][0]['agent_instance_id']==instance_id and chats['data'][0]['agent_id']==agent_id and chats['data'][0]['conversation_id']==private_conversation_id and chats['data'][0]['chain_id']==private_chain_id,chats
            chat_id=chats['data'][0]['conversation_id']
            st,dupe_chat=req('POST',f'{base}/chats',{'agent_id':agent_id,'agent_instance_id':instance_id,'project_id':project_id,'title':'Duplicate'},alice); assert st==409 and dupe_chat['error']['code']=='conflict',dupe_chat
            st,chat2=req('POST',f'{base}/chats',{'agent_id':agent_id,'bridge_id':bridge_id,'project_id':project_id,'provider':'claude','tier':'normal','initial_message':{'body':'first message creates session'}},alice); assert st==201 and chat2['data']['conversation_id']!=chat_id and chat2['data']['agent_instance_id']!=instance_id,chat2
            instance2_id=chat2['data']['agent_instance_id']; launch_extra=ws_recv_json(bridge_ws); assert launch_extra['type']=='launch_agent' and launch_extra['payload']['agent_instance_id']==instance2_id and launch_extra['payload']['chain_id']==chat2['data']['chain_id'] and launch_extra['payload']['conversation_id']==chat2['data']['conversation_id'],launch_extra
            st,coord_chain=req('POST',f'{base}/task-chains',{'title':'Coordinator chain','coordinator_agent_id':agent_id,'bridge_id':bridge_id,'project_id':project_id,'provider':'claude','tier':'normal'},alice); assert st==201 and coord_chain['data']['coordinator_agent_instance_id'],coord_chain
            coord_chain_id=coord_chain['data']['chain_id']; coord_instance_id=coord_chain['data']['coordinator_agent_instance_id']
            launch_coord=ws_recv_json(bridge_ws); assert launch_coord['type']=='launch_agent' and launch_coord['payload']['agent_instance_id']==coord_instance_id and launch_coord['payload']['chain_id']==coord_chain_id,launch_coord
            st,coord_task=req('POST',f'{base}/task-chains/{coord_chain_id}/tasks',{'title':'defaults to coordinator'},alice); assert st==201 and coord_task['data']['assignee_ref']['agent_instance_id']==coord_instance_id,coord_task
            st,coord_bundle=req('GET',f'{base}/bridge/agent-instances/{coord_instance_id}/bootstrap',headers={'Authorization':f'Bearer {bridge_token}'}); assert st==200 and coord_bundle['data']['chain']['coordinator_agent_instance_id']==coord_instance_id and coord_bundle['data']['task_context']['effective_assignee_ref']['agent_instance_id']==coord_instance_id and isinstance(coord_bundle['data']['task_context']['runnable_frontier'],list),coord_bundle
            st,chain=req('POST',f'{base}/task-chains',{'title':'System chain','default_reviewer_refs':[{'type':'user','user_id':'alice'}]},alice); assert st==201,chain
            chain_id=chain['data']['chain_id']; assert chain['data']['kind']=='team_work' and chain['data']['default_reviewer_refs'][0]['user_id']=='alice',chain
            st,chain_inst=req('POST',f'{base}/agent-instances',{'agent_id':agent_id,'bridge_id':bridge_id,'project_id':project_id,'chain_id':chain_id,'provider':'claude','tier':'normal'},alice); assert st==201,chain_inst
            chain_instance_id=chain_inst['data']['agent_instance_id']; assert chain_inst['data']['chain_id']==chain_id and chain_inst['data']['conversation_id'],chain_inst
            launch_chain=ws_recv_json(bridge_ws); assert launch_chain['type']=='launch_agent' and launch_chain['payload']['agent_instance_id']==chain_instance_id and launch_chain['payload']['chain_id']==chain_id and launch_chain['payload']['conversation_id']==chain_inst['data']['conversation_id'],launch_chain
            st,same_chain_task=req('POST',f'{base}/task-chains/{chain_id}/tasks',{'title':'same chain actor','assignee_ref':{'type':'agent_instance','agent_instance_id':chain_instance_id},'reviewer_refs':[{'type':'user','user_id':'alice'}]},alice); assert st==201 and same_chain_task['data']['assignee_ref']['agent_instance_id']==chain_instance_id and same_chain_task['data']['reviewer_refs'][0]['user_id']=='alice',same_chain_task
            st,default_reviewer_task=req('POST',f'{base}/task-chains/{chain_id}/tasks',{'title':'default reviewer','assignee_ref':{'type':'agent_instance','agent_instance_id':chain_instance_id}},alice); assert st==201 and default_reviewer_task['data']['reviewer_refs'][0]['user_id']=='alice',default_reviewer_task
            st,title_edge_task=req('POST',f'{base}/task-chains/{chain_id}/tasks',{'title':'reviewer_refs','assignee_ref':{'type':'agent_instance','agent_instance_id':chain_instance_id}},alice); assert st==201 and title_edge_task['data']['reviewer_refs'][0]['user_id']=='alice',title_edge_task
            st,explicit_empty_task=req('POST',f'{base}/task-chains/{chain_id}/tasks',{'title':'explicit empty','assignee_ref':{'type':'agent_instance','agent_instance_id':chain_instance_id},'reviewer_refs':[]},alice); assert st==201 and explicit_empty_task['data']['reviewer_refs']==[],explicit_empty_task
            st,cross_chain_task=req('POST',f'{base}/task-chains/{chain_id}/tasks',{'title':'bad actor','assignee_ref':{'type':'agent_instance','agent_instance_id':instance_id}},alice); assert st==409 and cross_chain_task['error']['code']=='conflict',cross_chain_task
            st,filtered_tasks=req('GET',f'{base}/task-chains/{chain_id}/tasks?assignee_agent_instance_id={chain_instance_id}',headers=alice); assert st==200 and {t['task_id'] for t in filtered_tasks['data']}=={same_chain_task['data']['task_id'],default_reviewer_task['data']['task_id'],title_edge_task['data']['task_id'],explicit_empty_task['data']['task_id']},filtered_tasks
            st,reviewer_filtered=req('GET',f'{base}/task-chains/{chain_id}/tasks?reviewer_user_id=alice',headers=alice); assert st==200 and {t['task_id'] for t in reviewer_filtered['data']}=={same_chain_task['data']['task_id'],default_reviewer_task['data']['task_id'],title_edge_task['data']['task_id']},reviewer_filtered
            st,chats_after=req('GET',f'{base}/chats',headers=alice); assert st==200 and len(chats_after['data'])==4,chats_after
            assert any(c['agent_instance_id']==chain_instance_id and c['chain_id']==chain_id for c in chats_after['data']),chats_after
            ws_send_json(bridge_ws,{'type':'agent_instance_status','agent_instance_id':instance_id,'state_seq':6,'runtime_status':'idle','activity_status':'idle'}); _=ws_recv_json(bridge_ws)
            st,continued=req('POST',f'{base}/chats/{chat_id}/messages',{'body':'continue same session'},alice); assert st==201,continued
            launch2=ws_recv_json(bridge_ws); assert launch2['type']=='launch_agent' and launch2['payload']['agent_instance_id']==instance_id and launch2['payload']['tier']=='normal',launch2
            st,after_continue=req('GET',f'{base}/agent-instances/{instance_id}',headers=alice); assert st==200 and after_continue['data']['run_count']==2 and after_continue['data']['last_applied_seq']==6 and after_continue['data']['runtime_status']=='launching',after_continue
            st,bad_immutable=req('PATCH',f'{base}/agent-instances/{instance_id}',{'project_id':'proj_other'},alice); assert st==409 and bad_immutable['error']['code']=='conflict',bad_immutable
            st,bad_chain_move=req('PATCH',f'{base}/agent-instances/{instance_id}',{'chain_id':chain_id},alice); assert st==409 and bad_chain_move['error']['code']=='conflict',bad_chain_move
            st,bad_provider=req('PATCH',f'{base}/agent-instances/{instance_id}',{'provider':'openai','tier':'normal'},alice); assert st==503 and bad_provider['error']['code']=='provider_unavailable',bad_provider
            st,patched=req('PATCH',f'{base}/agent-instances/{instance_id}',{'provider':'claude','tier':'smart'},alice); assert st==200,patched
            p=patched['data']; assert p['agent_instance_id']==instance_id and p['run_count']==3 and p['tier']=='smart' and p['last_applied_seq']==6 and p['runtime_status']=='launching',p
            launch3=ws_recv_json(bridge_ws); assert launch3['type']=='launch_agent' and launch3['payload']['agent_instance_id']==instance_id and launch3['payload']['tier']=='smart',launch3
            ws_send_json(bridge_ws,{'type':'agent_instance_status','agent_instance_id':instance_id,'state_seq':7,'runtime_status':'running','activity_status':'idle'}); _=ws_recv_json(bridge_ws)
            st,stopping=req('POST',f'{base}/agent-instances/{instance_id}/stop',{'reason':'test'},alice); assert st==202 and stopping['data']['runtime_status']=='stopping',stopping
            stop=ws_recv_json(bridge_ws); assert stop['type']=='stop_agent' and stop['payload']['agent_instance_id']==instance_id,stop
            ws_send_json(bridge_ws,{'type':'agent_instance_status','agent_instance_id':instance_id,'state_seq':8,'runtime_status':'stopped','activity_status':'idle'}); _=ws_recv_json(bridge_ws)
            st,stopped=req('GET',f'{base}/agent-instances/{instance_id}',headers=alice); assert st==200 and stopped['data']['runtime_status']=='stopped' and stopped['data']['run_count']==3 and stopped['data']['last_applied_seq']==8,stopped
            st,stored=req('PATCH',f'{base}/agent-instances/{instance_id}',{'provider':'claude','tier':'normal'},alice); assert st==200 and stored['data']['runtime_status']=='stopped' and stored['data']['run_count']==3 and stored['data']['tier']=='normal',stored
            st,restarted=req('POST',f'{base}/agent-instances/{instance_id}/restart',headers=alice); assert st==202,restarted
            r=restarted['data']; assert r['agent_instance_id']==instance_id and r['bridge_id']==bridge_id and r['project_id']==project_id and r['chain_id']==private_chain_id and r['conversation_id']==private_conversation_id and r['tier']=='normal' and r['run_count']==4 and r['last_applied_seq']==8 and r['runtime_status']=='launching',r
            launch4=ws_recv_json(bridge_ws); assert launch4['type']=='launch_agent' and launch4['payload']['agent_instance_id']==instance_id and launch4['payload']['tier']=='normal' and launch4['payload']['chain_id']==private_chain_id and launch4['payload']['conversation_id']==private_conversation_id,launch4
            bridge_ws.close(); bridge_ws=None; time.sleep(.2)
            st,offline_restart=req('POST',f'{base}/agent-instances/{instance_id}/restart',headers=alice); assert st==503 and offline_restart['error']['code']=='bridge_offline',offline_restart
        finally:
            if bridge_ws:
                try: bridge_ws.close()
                except Exception: pass
            hub.terminate()
            try: hub.wait(timeout=3)
            except subprocess.TimeoutExpired: hub.kill()
    print('PASS: hub restartable real smoke')
if __name__=='__main__': main()
