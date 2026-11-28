package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import agent_runtime "odin_test:lib/agent_runtime"

// Generated 0.162 schema frames, with synthetic IDs/paths and no credentials.
// T3 owns registry/catalog enablement; use a private descriptor on the T1 seam.
codex_test_open :: proc(f: ^T4_Runtime_Test, cwd: string = "/unused/bootstrap") {
    t4_runtime_open(f,"inst_t2_codex",cwd)
    acp_rpc_close(f.r.client); acp_test_delete(&f.f); f.f={}
    f.r.descriptor.protocol=.Codex_App_Server
    f.r.descriptor.permission_policy=.Once_Only
    f.r.descriptor.permission_category=""
    f.r.driver=&acp_protocol_codex_driver
    acp_runtime_replace(&f.r.mode,"ask")
    codex_test_connect(f)
}
codex_test_connect :: proc(f: ^T4_Runtime_Test) {
    sync.atomic_store(&f.f.clock,1000000)
    f.r.client,_=acp_rpc_open({data=&f.f,instance=f.r.instance,launch_epoch=f.r.epoch,
        write=acp_test_write,ack=acp_test_ack,close=acp_test_close,now_ms=acp_test_clock},
        {data=f,checkpoint=t4_runtime_checkpoint,notification=codex_test_notification,inbound_request=t9_inbound,
         inbound_timeout=codex_test_timeout,restore_completion=t4_runtime_restore_completion},
        acp_protocol_codex_driver.rpc)
}
codex_test_close :: proc(f: ^T4_Runtime_Test) {
    f.r.d.stopped=true
    acp_runtime_destroy(f.r); acp_test_delete(&f.f)
    bridge_permission_test_reset("inst_t2_codex")
    bridge_runtime_set_status("inst_t2_codex","stopped","idle")
}
codex_test_notification :: proc(data: rawptr,method,params: string) {
    f:=cast(^T4_Runtime_Test)data
    acp_runtime_notification(f.r,method,params)
}
codex_test_timeout :: proc(data: rawptr,id: string) { f:=cast(^T4_Runtime_Test)data; acp_runtime_inbound_timeout(f.r,id) }
codex_test_frame :: proc(t: ^testing.T,f: ^T4_Runtime_Test,seq: u64,line: string) {
    sync.mutex_lock(&f.f.mu); count:=len(f.f.acks); sync.mutex_unlock(&f.f.mu)
    testing.expect(t,f.r.client.io.feed(f.r.client,strings.concatenate({line,"\n"},context.temp_allocator),seq))
    acp_test_wait(t,&f.f,.Acks,count+1)
}
codex_test_reply :: proc(t: ^testing.T,f: ^T4_Runtime_Test,index: int,seq: u64,result: string) {
    if !acp_test_wait(t,&f.f,.Writes,index+1) do return
    sync.mutex_lock(&f.f.mu)
    id:=strings.clone(acp_rpc_raw_id(f.f.writes[index].bytes),context.temp_allocator)
    sync.mutex_unlock(&f.f.mu)
    codex_test_frame(t,f,seq,strings.concatenate({`{"id":`,id,`,"result":`,result,"}"},context.temp_allocator))
}
codex_test_write :: proc(t: ^testing.T,f: ^T4_Runtime_Test,index: int,method: string) -> json.Object {
    if !acp_test_wait(t,&f.f,.Writes,index+1) do return nil
    sync.mutex_lock(&f.f.mu); defer sync.mutex_unlock(&f.f.mu)
    obj:=acp_event_object(f.f.writes[index].bytes)
    testing.expect_value(t,acp_event_string(obj,"method"),method)
    testing.expect(t,!strings.contains(f.f.writes[index].bytes,"jsonrpc"))
    params,_:=obj["params"].(json.Object); return params
}
codex_test_active :: proc(f: ^T4_Runtime_Test) {
    acp_runtime_replace(&f.r.session,"s"); acp_runtime_replace(&f.r.d.phase,"ready")
    f.r.initialized=true; f.r.load_session=true; f.r.d.ready=true; f.r.d.starter_sent=true; f.r.d.steering_supported=true
}
codex_test_prompt :: proc(data: rawptr,c: ^ACP_RPC_Client,argument: string) -> bool {
    f:=cast(^T4_Runtime_Test)data
    acp_runtime_prompt(f.r,{id=argument,text="input"}); return true
}
codex_test_start :: proc(t: ^testing.T,f: ^T4_Runtime_Test,id: string) {
    cmd:=ACP_RPC_Command{kind=.Runtime,a=id,runtime_work=codex_test_prompt,runtime_data=f}
    acp_rpc_call(f.r.client,&cmd); testing.expect(t,cmd.ok)
}
codex_test_tick :: proc(data: rawptr,c: ^ACP_RPC_Client,argument: string) -> bool {
    f:=cast(^T4_Runtime_Test)data
    acp_codex_tick(f.r); return true
}

@(test)
codex_driver_handshake_bootstrap_and_ask_yolo_policy :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    old:=bridge_local_token_records; bridge_local_token_records=make([dynamic]Bridge_Local_Agent_Token_Record,allocator=runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records=old }
    dir:=fmt.tprintf("%s/.cache/heimdall-tests/codex-bootstrap-%d",os.get_env("HOME",context.temp_allocator),time.tick_now()._nsec)
    testing.expect(t,os.make_directory_all(dir)==nil); defer os.remove_all(dir)
    path:=strings.concatenate({dir,"/CLAUDE.md"},context.temp_allocator)
    testing.expect(t,os.write_entire_file_from_string(path,"Heimdall bootstrap comms and task instructions") == nil)
    f:T4_Runtime_Test; codex_test_open(&f,dir); defer codex_test_close(&f)
    testing.expect(t,t4_runtime_call(&f,"begin"))
    init:=codex_test_write(t,&f,0,"initialize")
    caps,_:=init["capabilities"].(json.Object); experimental,_:=caps["experimentalApi"].(json.Boolean); testing.expect(t,bool(experimental))
    codex_test_reply(t,&f,0,1,`{"userAgent":"codex/0.162.0"}`)
    codex_test_write(t,&f,1,"initialized")
    codex_test_write(t,&f,2,"account/read")
    codex_test_reply(t,&f,2,2,`{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}`)
    start:=codex_test_write(t,&f,3,"thread/start")
    testing.expect_value(t,acp_event_string(start,"cwd"),dir)
    testing.expect_value(t,acp_event_string(start,"developerInstructions"),"Heimdall bootstrap comms and task instructions")
    testing.expect_value(t,acp_event_string(start,"approvalPolicy"),"on-request")
    testing.expect_value(t,acp_event_string(start,"sandbox"),"workspace-write")
    testing.expect_value(t,acp_event_string(start,"model"),"sonnet")
    codex_test_reply(t,&f,3,3,`{"thread":{"id":"s"}}`)
    turn:=codex_test_write(t,&f,4,"turn/start")
    testing.expect(t,f.r.d.ready && f.r.d.starter_sent && f.r.d.phase=="prompt")
    inputs,_:=turn["input"].(json.Array); first,_:=inputs[0].(json.Object)
    // Codex has no seeded bootstrap sentence, so the lease instruction is appended once.
    testing.expect_value(t,acp_event_string(first,"text"),"EXACT starter text Then " + agent_runtime.STARTUP_LEASE_INSTRUCTION)
    sandbox,_:=turn["sandboxPolicy"].(json.Object)
    testing.expect_value(t,acp_event_string(sandbox,"type"),"workspaceWrite")
    _,null:=turn["effort"].(json.Null); testing.expect(t,null)
    codex_test_reply(t,&f,4,4,`{"turn":{"id":"turn-1","status":"inProgress"}}`)
    testing.expect_value(t,f.r.d.current_input,"starter")
    codex_test_frame(t,&f,5,`{"method":"turn/completed","params":{"threadId":"s","turn":{"id":"turn-1","status":"completed"}}}`)
    testing.expect(t,f.r.d.phase=="ready" && f.r.d.current_input=="")
    acp_runtime_replace(&f.r.mode,"yolo")
    codex_test_start(t,&f,"msg_second")
    yolo:=codex_test_write(t,&f,5,"turn/start")
    policy,_:=yolo["approvalPolicy"].(json.Object); granular,_:=policy["granular"].(json.Object)
    mcp,_:=granular["mcp_elicitations"].(json.Boolean); testing.expect(t,bool(mcp))
    for key in ([]string{"rules","sandbox_approval","request_permissions","skill_approval"}) {
        flag,ok:=granular[key].(json.Boolean); testing.expect(t,ok && !bool(flag))
    }
    sb,_:=yolo["sandboxPolicy"].(json.Object); testing.expect_value(t,acp_event_string(sb,"type"),"dangerFullAccess")
    testing.expect_value(t,f.f.order_errors,0)
}

@(test)
codex_driver_auth_required_and_api_key_account :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    old:=bridge_local_token_records; bridge_local_token_records=make([dynamic]Bridge_Local_Agent_Token_Record,allocator=runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records=old }
    f:T4_Runtime_Test; codex_test_open(&f); defer codex_test_close(&f)
    testing.expect(t,t4_runtime_call(&f,"begin"))
    codex_test_reply(t,&f,0,1,`{"userAgent":"codex/0.162.0"}`)
    codex_test_reply(t,&f,2,2,`{"account":null,"requiresOpenaiAuth":true}`)
    testing.expect(t,f.r.d.auth_required && !f.r.d.ready && f.r.d.error=="acp_auth_required")
    blockers:=bridge_blockers_list(f.r.instance); testing.expect_value(t,len(blockers),1)
    if len(blockers)==1 do testing.expect_value(t,blockers[0].kind,"startup")
    testing.expect_value(t,len(f.f.writes),3)
}

@(test)
codex_driver_streams_items_and_notification_owned_completion :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    old:=bridge_local_token_records; bridge_local_token_records=make([dynamic]Bridge_Local_Agent_Token_Record,allocator=runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records=old }
    prev_ingest,prev_keys:=acp_events_ingest,acp_chat_keyring
    acp_events_ingest=t5_ingest; acp_chat_keyring=t5_keyring; sync.atomic_store(&t5_locked,false)
    defer { acp_events_ingest=prev_ingest; acp_chat_keyring=prev_keys; t5_reset_events() }
    f:T4_Runtime_Test; codex_test_open(&f); defer codex_test_close(&f)
    codex_test_active(&f); testing.expect(t,acp_chat_prepare(f.r))
    codex_test_start(t,&f,"msg_stream")
    codex_test_reply(t,&f,0,1,`{"turn":{"id":"t","status":"inProgress"}}`)
    codex_test_frame(t,&f,2,`{"method":"item/started","params":{"threadId":"s","turnId":"t","item":{"type":"reasoning","id":"r"}}}`)
    codex_test_frame(t,&f,3,`{"method":"item/agentMessage/delta","params":{"threadId":"s","turnId":"t","itemId":"m","delta":"Hello "}}`)
    codex_test_frame(t,&f,4,`{"method":"item/completed","params":{"threadId":"s","turnId":"t","item":{"type":"agentMessage","id":"m","text":"Hello world"}}}`)
    testing.expect_value(t,f.r.chat.d.text,"Hello world")
    codex_test_frame(t,&f,5,`{"method":"item/completed","params":{"threadId":"s","turnId":"t","item":{"type":"agentMessage","id":"m","text":"Hello world"}}}`)
    testing.expect_value(t,f.r.chat.d.text,"Hello world")
    codex_test_frame(t,&f,6,`{"method":"item/started","params":{"threadId":"s","turnId":"t","item":{"type":"commandExecution","id":"cmd","command":"pwd","status":"inProgress"}}}`)
    codex_test_frame(t,&f,7,`{"method":"item/commandExecution/outputDelta","params":{"threadId":"s","turnId":"t","itemId":"cmd","delta":"/work\n"}}`)
    testing.expect(t,strings.contains(f.r.tools.entries["cmd"].output,"/work"))
    codex_test_frame(t,&f,8,`{"method":"item/completed","params":{"threadId":"s","turnId":"t","item":{"type":"commandExecution","id":"cmd","command":"pwd","status":"completed","aggregatedOutput":"/work\n"}}}`)
    codex_test_frame(t,&f,9,`{"method":"item/completed","params":{"threadId":"s","turnId":"t","item":{"type":"fileChange","id":"edit","status":"completed","changes":[{"path":"file.txt","kind":{"type":"update"},"diff":"@@ -1 +1 @@\n-old\n+new"}]}}}`)
    count:=len(t5_events)
    codex_test_frame(t,&f,10,`{"method":"item/completed","params":{"threadId":"s","turnId":"t","item":{"type":"fileChange","id":"edit","status":"completed","changes":[{"path":"file.txt","diff":"@@ -1 +1 @@\n-old\n+new"}]}}}`)
    testing.expect_value(t,len(t5_events),count)
    edits,starts,ends:=0,0,0
    for raw in t5_events {
        switch acp_event_string(acp_event_object(raw),"event") {
        case "file.edit": edits+=1
        case "tool.start": starts+=1
        case "tool.end": ends+=1
        }
    }
    testing.expect(t,edits==1 && starts==2 && ends==2)
    codex_test_frame(t,&f,11,`{"method":"error","params":{"threadId":"s","turnId":"t","willRetry":true,"error":{"message":"retrying"}}}`)
    codex_test_frame(t,&f,12,`{"method":"item/agentMessage/delta","params":[]}`)
    codex_test_frame(t,&f,13,`{"method":"item/agentMessage/delta","params":{"threadId":"other","turnId":"t","delta":"wrong"}}`)
    testing.expect_value(t,f.r.d.phase,"prompt")
    codex_test_frame(t,&f,14,`{"method":"turn/completed","params":{"threadId":"s","turn":{"id":"t","status":"completed"}}}`)
    testing.expect(t,f.r.d.phase=="ready" && f.r.chat.d.status=="complete" && len(f.r.d.completed_inputs)==1)
    testing.expect_value(t,f.r.d.error,"")
    testing.expect_value(t,f.f.order_errors,0)
}

@(test)
codex_driver_interrupt_steer_and_terminal_statuses :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    old:=bridge_local_token_records; bridge_local_token_records=make([dynamic]Bridge_Local_Agent_Token_Record,allocator=runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records=old }
    f:T4_Runtime_Test; codex_test_open(&f); defer codex_test_close(&f)
    codex_test_active(&f); codex_test_start(t,&f,"msg_cancel")
    testing.expect(t,t4_runtime_call(&f,"interrupt"))
    codex_test_reply(t,&f,0,1,`{"turn":{"id":"one","status":"inProgress"}}`)
    interrupt:=codex_test_write(t,&f,1,"turn/interrupt")
    testing.expect_value(t,acp_event_string(interrupt,"turnId"),"one")
    codex_test_reply(t,&f,1,2,`{}`)
    testing.expect_value(t,f.r.d.phase,"prompt")
    codex_test_frame(t,&f,3,`{"method":"turn/completed","params":{"threadId":"s","turn":{"id":"one","status":"interrupted"}}}`)
    testing.expect_value(t,f.r.d.phase,"ready")
    codex_test_start(t,&f,"msg_steer")
    input:=acp_event_json(ACP_Runtime_Input{id="msg_injected",text="redirect",lane=.Steer})
    testing.expect(t,t4_runtime_call(&f,input))
    testing.expect(t,!f.r.d.steering_pending && len(f.r.d.queue)==1,"steering waits for start's native ID")
    codex_test_reply(t,&f,2,4,`{"turn":{"id":"two","status":"inProgress"}}`)
    steer:=codex_test_write(t,&f,3,"turn/steer")
    testing.expect_value(t,acp_event_string(steer,"expectedTurnId"),"two")
    codex_test_reply(t,&f,3,5,`{"turnId":"two"}`)
    testing.expect(t,!f.r.d.steering_pending && len(f.r.d.queue)==0)
    codex_test_frame(t,&f,6,`{"method":"turn/completed","params":{"threadId":"s","turn":{"id":"two","status":"failed","error":{"message":"secret detail"}}}}`)
    testing.expect(t,f.r.d.phase=="ready" && f.r.d.error=="" && len(f.r.d.completed_inputs)==3)
    codex_test_start(t,&f,"msg_stop")
    codex_test_reply(t,&f,4,7,`{"turn":{"id":"three","status":"inProgress"}}`)
    testing.expect(t,t4_runtime_call(&f,"stop"))
    codex_test_write(t,&f,5,"turn/interrupt")
    testing.expect_value(t,f.f.order_errors,0)
}

@(test)
codex_driver_approval_schemas_relay_yolo_replay_and_cancel :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    old:=bridge_local_token_records; bridge_local_token_records=make([dynamic]Bridge_Local_Agent_Token_Record,allocator=runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records=old }
    f:T4_Runtime_Test; codex_test_open(&f); defer codex_test_close(&f)
    codex_test_active(&f); acp_runtime_replace(&f.r.d.phase,"prompt"); acp_runtime_replace(&acp_codex(f.r).turn_id,"t")
    methods:=[]string{"item/commandExecution/requestApproval","item/fileChange/requestApproval","item/permissions/requestApproval","execCommandApproval","applyPatchApproval"}
    seq:u64=0; index:=0
    for method,i in methods {
        params:=codex_test_approval_params(method)
        // All five methods use the real blocking permission relay in ask mode.
        frame:=acp_rpc_envelope(fmt.tprintf("%d",100+i),method,params,"","",ACP_RPC_POLICY_CODEX.codec)
        seq+=1; codex_test_frame(t,&f,seq,strings.trim_space(frame))
        blocker:=t9_blocker(t,&f,fmt.tprintf("%d",100+i)); defer delete(blocker)
        decision:="allow" if i%2==0 else "deny"
        testing.expect(t,bridge_permission_resolve(f.r.instance,blocker,decision,""))
        if !acp_test_wait(t,&f.f,.Writes,index+1) do return
        sync.mutex_lock(&f.f.mu)
        obj:=acp_event_object(f.f.writes[index].bytes); result,_:=obj["result"].(json.Object)
        if i==2 {
            testing.expect_value(t,acp_event_string(result,"scope"),"turn")
            permissions,_:=result["permissions"].(json.Object); network,_:=permissions["network"].(json.Object)
            enabled,_:=network["enabled"].(json.Boolean); testing.expect(t,bool(enabled))
        } else if i==3 {
            choice,_:=result["decision"].(json.Object); denied,_:=choice["denied"].(json.Object)
            testing.expect(t,acp_event_string(denied,"rejection")!="")
        } else {
            expected:="approved" if i==4 else ("accept" if decision=="allow" else "decline")
            testing.expect_value(t,acp_event_string(result,"decision"),expected)
        }
        sync.mutex_unlock(&f.f.mu)
        t9_worker_barrier(&f); index+=1
        // Identical duplicate server request replays the same durable receipt.
        seq+=1; codex_test_frame(t,&f,seq,strings.trim_space(frame))
        if !acp_test_wait(t,&f.f,.Writes,index+1) do return
        testing.expect_value(t,f.f.writes[index].bytes,f.f.writes[index-1].bytes); index+=1
        // Method-specific encoders never broaden a single decision.
        for value in ([]string{"allow","deny","none"}) {
            encoded:=acp_codex_permission_result(method,params,value)
            testing.expect(t,!strings.contains(encoded,"acceptForSession") && !strings.contains(encoded,"approved_for_session") && !strings.contains(encoded,`"scope":"session"`))
        }
    }
    params:=codex_test_approval_params(methods[0])
    acp_runtime_replace(&f.r.mode,"yolo")
    seq+=1; codex_test_frame(t,&f,seq,strings.trim_space(acp_rpc_envelope("200",methods[0],params,"","",ACP_RPC_POLICY_CODEX.codec)))
    acp_test_wait(t,&f.f,.Writes,index+1)
    testing.expect(t,strings.contains(f.f.writes[index].bytes,`"decision":"accept"`)); index+=1
    f.r.d.cancelling=true
    seq+=1; codex_test_frame(t,&f,seq,strings.trim_space(acp_rpc_envelope("201",methods[0],params,"","",ACP_RPC_POLICY_CODEX.codec)))
    acp_test_wait(t,&f.f,.Writes,index+1)
    testing.expect(t,strings.contains(f.f.writes[index].bytes,`"decision":"cancel"`))
    testing.expect_value(t,f.f.order_errors,0)
}

codex_test_approval_params :: proc(method: string) -> string {
    switch method {
    case "execCommandApproval": return `{"conversationId":"s","callId":"tool","command":["pwd"],"cwd":"/work","parsedCmd":[]}`
    case "applyPatchApproval": return `{"conversationId":"s","callId":"tool","fileChanges":{}}`
    case "item/permissions/requestApproval": return `{"threadId":"s","turnId":"t","itemId":"tool","startedAtMs":1,"cwd":"/work","permissions":{"network":{"enabled":true}}}`
    case "item/fileChange/requestApproval": return `{"threadId":"s","turnId":"t","itemId":"tool","startedAtMs":1}`
    }
    return `{"threadId":"s","turnId":"t","itemId":"tool","startedAtMs":1,"command":"pwd","cwd":"/work"}`
}

@(test)
codex_driver_resume_retries_unarchive_and_never_creates_new_thread :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    old:=bridge_local_token_records; bridge_local_token_records=make([dynamic]Bridge_Local_Agent_Token_Record,allocator=runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records=old }
    dir:=fmt.tprintf("%s/.cache/heimdall-tests/codex-resume-%d",os.get_env("HOME",context.temp_allocator),time.tick_now()._nsec)
    testing.expect(t,os.make_directory_all(dir)==nil); defer os.remove_all(dir)
    testing.expect(t,os.write_entire_file_from_string(strings.concatenate({dir,"/CLAUDE.md"},context.temp_allocator),"Bootstrap") == nil)
    f:T4_Runtime_Test; codex_test_open(&f,dir); defer codex_test_close(&f)
    codex_test_active(&f); f.r.recovering=true; f.r.d.ready=false
    testing.expect(t,t4_runtime_call(&f,"begin"))
    codex_test_reply(t,&f,0,1,`{"userAgent":"codex/0.162.0"}`)
    // API-compatible providers need no OpenAI account.
    codex_test_reply(t,&f,2,2,`{"account":null,"requiresOpenaiAuth":false}`)
    resume:=codex_test_write(t,&f,3,"thread/resume"); testing.expect_value(t,acp_event_string(resume,"threadId"),"s")
    codex_test_frame(t,&f,3,`{"id":3,"error":{"code":-32600,"message":"thread s is closing"}}`)
    sync.atomic_store(&f.f.clock,1001000)
    tick:=ACP_RPC_Command{kind=.Runtime,runtime_work=codex_test_tick,runtime_data=&f}
    acp_rpc_call(f.r.client,&tick)
    codex_test_write(t,&f,4,"thread/resume")
    codex_test_frame(t,&f,4,`{"id":4,"error":{"code":-32600,"message":"session s is archived; run codex unarchive"}}`)
    codex_test_write(t,&f,5,"thread/unarchive")
    codex_test_reply(t,&f,5,5,`{"thread":{"id":"s"}}`)
    codex_test_write(t,&f,6,"thread/resume")
    codex_test_reply(t,&f,6,6,`{"thread":{"id":"s","turns":[{"id":"historical","status":"completed"}]}}`)
    testing.expect(t,f.r.d.ready && !f.r.d.replay_only && f.r.d.phase=="ready")
    for w in f.f.writes do testing.expect(t,!strings.contains(w.bytes,`"method":"thread/start"`) && !strings.contains(w.bytes,`"method":"turn/start"`))
    testing.expect_value(t,f.f.order_errors,0)
}

@(test)
codex_driver_native_spawn_overrides_and_profile_shadow_home :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    d:=contracts.ACP_CODEX_DESCRIPTOR
    args,built:=acp_provider_launch_argv(d,"","/profile/codex")
    testing.expect(t,built && args[0]=="/profile/codex" && args[1]=="app-server")
    for arg in args do testing.expect(t,arg!="--no-daemon", "native PTY daemon bypass must not change ACP server argv")
    joined:=strings.join(args," ",context.temp_allocator)
    testing.expect(t,strings.contains(joined,"thread_unload_delay_secs=0") && strings.contains(joined,"features.hooks=false") && strings.contains(joined,"notify=[]"))
    testing.expect(t,strings.contains(joined,"plugins.heimdall@heimdall-codex.enabled=false"))
    pp:=Provider_Profile{provider="codex",config={home_path="/account/home",shadow_home_path="/account/shadow"}}
    env,ok:=profile_child_env(&pp); testing.expect(t,ok)
    testing.expect_value(t,profile_env_value(env,"CODEX_HOME"),"/account/shadow")
    // Existing ACP providers keep their exact fixed argv.
    args,built=acp_provider_launch_argv(contracts.ACP_KIRO_DESCRIPTOR,"","/profile/kiro")
    testing.expect(t,built && len(args)==4 && args[1]=="acp")
}

@(test)
codex_driver_active_journal_restore_and_reused_turn_rejected :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    old:=bridge_local_token_records; bridge_local_token_records=make([dynamic]Bridge_Local_Agent_Token_Record,allocator=runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records=old }
    f:T4_Runtime_Test; codex_test_open(&f); defer codex_test_close(&f)
    codex_test_active(&f); codex_test_start(t,&f,"msg_restore")
    codex_test_reply(t,&f,0,1,`{"turn":{"id":"restored","status":"inProgress"}}`)
    // A real daemon receipt removes stdin replay without ending the native turn.
    if !acp_test_wait(t,&f.f,.Writes,1) do return
    receipt:=strings.clone(f.f.writes[0].delivery_id,runtime.heap_allocator())
    testing.expect(t,acp_rpc_enqueue_frame(f.r.client,{kind=.Receipt,bytes=receipt}))
    testing.expect(t,t4_runtime_call(&f,"resume"))
    raw:=acp_test_snapshot(&f.f); defer delete(raw)
    state,valid:=acp_state_decode(raw); defer acp_state_delete(&state)
    testing.expect(t,valid && len(state.pending_outbound)==0 && len(state.pending_writes)==0)
    durable:ACP_Runtime_Durable
    testing.expect(t,acp_runtime_durable_load(&acp_protocol_codex_driver,state.runtime_json,&durable,context.temp_allocator))
    testing.expect(t,acp_codex_durable_valid(&durable) && acp_codex_durable(&durable).turn_id=="restored" && durable.current_input=="msg_restore")
    acp_runtime_durable_free_driver_state(&acp_protocol_codex_driver,&durable)
    acp_rpc_close(f.r.client); acp_test_delete(&f.f); f.f={}
    codex_test_connect(&f)
    testing.expect(t,acp_rpc_restore(f.r.client,raw))
    testing.expect(t,t4_runtime_call(&f,"resume"))
    testing.expect_value(t,len(f.f.writes),0)
    codex_test_frame(t,&f,2,`{"method":"turn/completed","params":{"threadId":"s","turn":{"id":"restored","status":"completed"}}}`)
    codex_test_start(t,&f,"msg_new")
    codex_test_reply(t,&f,0,3,`{"turn":{"id":"restored","status":"inProgress"}}`)
    testing.expect_value(t,f.r.d.error,"acp_protocol_error")
}

@(test)
codex_driver_approval_timeout_wrong_thread_and_replay_only :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    old:=bridge_local_token_records; bridge_local_token_records=make([dynamic]Bridge_Local_Agent_Token_Record,allocator=runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records=old }
    f:T4_Runtime_Test; codex_test_open(&f); defer codex_test_close(&f)
    codex_test_active(&f); acp_runtime_replace(&f.r.d.phase,"prompt"); acp_runtime_replace(&acp_codex(f.r).turn_id,"t")
    method:="item/permissions/requestApproval"
    params:=`{"threadId":"s","turnId":"t","itemId":"p","cwd":"/work","startedAtMs":1,"permissions":{"network":{"enabled":true}}}`
    codex_test_frame(t,&f,1,strings.trim_space(acp_rpc_envelope("11",method,params,"","",ACP_RPC_POLICY_CODEX.codec)))
    blocker:=t9_blocker(t,&f,"11"); defer delete(blocker)
    sync.atomic_store(&f.f.clock,2000000)
    testing.expect(t,t4_runtime_call(&f,"resume"))
    if !acp_test_wait(t,&f.f,.Writes,1) do return
    testing.expect(t,strings.contains(f.f.writes[0].bytes,`"permissions":{}`))
    // A racing UI click may still reach the relay registry until its worker
    // reaps. The dispatcher-owned cancellation must still win on the wire.
    bridge_permission_resolve(f.r.instance,blocker,"allow","")
    t9_worker_barrier(&f)
    testing.expect_value(t,len(f.f.writes),1)
    f.r.d.replay_only=true
    codex_test_frame(t,&f,2,strings.trim_space(acp_rpc_envelope("12",method,params,"","",ACP_RPC_POLICY_CODEX.codec)))
    if !acp_test_wait(t,&f.f,.Writes,2) do return
    testing.expect(t,strings.contains(f.f.writes[1].bytes,`"permissions":{}`))
    f.r.d.replay_only=false
    codex_test_frame(t,&f,3,`{"id":13,"method":"item/commandExecution/requestApproval","params":{"threadId":"other","turnId":"t","itemId":"p"}}`)
    if !acp_test_wait(t,&f.f,.Writes,3) do return
    testing.expect(t,strings.contains(f.f.writes[2].bytes,`"decision":"cancel"`))
    testing.expect_value(t,f.f.order_errors,0)
}

@(test)
codex_driver_steer_rejection_keeps_input_and_interrupt_has_deadline :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    old:=bridge_local_token_records; bridge_local_token_records=make([dynamic]Bridge_Local_Agent_Token_Record,allocator=runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records=old }
    f:T4_Runtime_Test; codex_test_open(&f); defer codex_test_close(&f)
    codex_test_active(&f); codex_test_start(t,&f,"msg_start")
    codex_test_reply(t,&f,0,1,`{"turn":{"id":"t","status":"inProgress"}}`)
    input:=acp_event_json(ACP_Runtime_Input{id="msg_later",text="retain me",lane=.Steer})
    testing.expect(t,t4_runtime_call(&f,input))
    codex_test_write(t,&f,1,"turn/steer")
    codex_test_frame(t,&f,2,`{"id":2,"error":{"code":-32600,"message":"no active turn"}}`)
    testing.expect(t,!f.r.d.steering_pending && len(f.r.d.queue)==1 && f.r.d.queue[0].text=="retain me")
    testing.expect(t,t4_runtime_call(&f,"interrupt"))
    codex_test_write(t,&f,2,"turn/interrupt")
    codex_test_reply(t,&f,2,3,`{}`)
    // The ack cannot leave an interrupted native turn hanging indefinitely.
    sync.atomic_store(&f.f.clock,1010000)
    tick:=ACP_RPC_Command{kind=.Runtime,runtime_work=codex_test_tick,runtime_data=&f}
    acp_rpc_call(f.r.client,&tick)
    testing.expect_value(t,f.r.d.error,"acp_rpc_timeout")
}

@(test)
codex_driver_probe_and_missing_thread_fail_without_auth_or_new_thread :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    old:=bridge_local_token_records; bridge_local_token_records=make([dynamic]Bridge_Local_Agent_Token_Record,allocator=runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records=old }
    fixture:ACP_Test
    c:=acp_test_open(&fixture,policy=acp_protocol_codex_driver.rpc)
    defer { acp_rpc_close(c); acp_test_delete(&fixture) }
    p:ACP_Adapter_Probe
    testing.expect(t,acp_codex_probe(c,&p))
    if !acp_test_wait(t,&fixture,.Writes,1) do return
    testing.expect(t,c.io.feed(c,`{"id":1,"result":{"userAgent":"codex/0.162.0"}}`+"\n",1))
    if !acp_test_wait(t,&fixture,.Acks,1) do return
    sync.mutex_lock(&p.mu); testing.expect(t,p.ok && p.done); sync.mutex_unlock(&p.mu)
    f:T4_Runtime_Test; codex_test_open(&f); defer codex_test_close(&f)
    codex_test_active(&f); f.r.recovering=true
    acp_runtime_replace(&f.r.d.phase,"resume")
    // Provider -32000 is not an auth signal in app-server; account/read owns it.
    testing.expect(t,acp_runtime_request(f.r,"thread/resume",`{"threadId":"s"}`))
    codex_test_frame(t,&f,1,`{"id":1,"error":{"code":-32000,"message":"thread not found: secret path"}}`)
    testing.expect(t,f.r.d.error=="acp_pipe_lost" && !f.r.d.auth_required && !f.r.d.ready)
    testing.expect_value(t,len(f.f.writes),1)
    state:=ACP_Codex_Durable{turn_id="t"}
    d:=ACP_Runtime_Durable{phase="prompt",driver_state=&state}
    testing.expect(t,acp_codex_durable_valid(&d))
    state.resume_attempts=4; testing.expect(t,!acp_codex_durable_valid(&d)); state.resume_attempts=0
    state.completed_turns=make([dynamic]string,257,allocator=context.temp_allocator)
    testing.expect(t,!acp_codex_durable_valid(&d))
}

// Durable runtime JSON exactly as written before driver state became opaque
// (json.marshal of the old ACP_Runtime_Durable with an embedded codex struct).
CODEX_OLD_FORMAT_DURABLE :: `{"phase":"prompt","config_json":"","plan_json":"","starter":"","current_input":"msg_old","error":"","starter_sent":true,"ready":true,"stopped":false,"auth_required":false,"replay_only":false,"embedded_context":false,"queue":[],"completed_inputs":[],"token_reissued":false,"exit_pending":false,"cancelling":false,"stream_retries":0,"steering_supported":true,"steering_pending":false,"steering_input":{"id":"","text":"","lane":0,"key":"","kind":""},"batch_first_ms":0,"batch_last_ms":0,"last_notice_turn_ms":0,"codex":{"turn_id":"turn_old","start_id":"ham:codex_epoch:3","steering_turn_id":"","completed_turns":["turn_a","turn_b"],"message_id":"item_1","message_bytes":5,"message_done":false,"interrupt_deadline":0,"interrupt_sent":false,"resume_attempts":2,"resume_retry_after":0,"unarchived":true},"report_seq":4,"send_now":{"batch_id":"","state":"","attempt":0,"members":[]}}`

@(test)
codex_driver_restores_old_format_durable_state :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    instance := "inst_codex_old_format"
    state := ACP_State{schema_version = 3, runtime_binding_version = 1, provider = "codex", profile = "work", bridge = bridge_config.daemon_id,
        instance = instance, launch_epoch = "codex_epoch", run_dir = bridge_runtime_default_run_dir(instance), pipe_generation = "saved-generation",
        adapter_version = contracts.ACP_CODEX_DESCRIPTOR.pkg.version, selected_mode = "ask", initialized = true, sessionId = "thread_old",
        runtime_json = CODEX_OLD_FORMAT_DURABLE,
        binding = acp_provider_binding(contracts.ACP_CODEX_DESCRIPTOR, "work", contracts.ACP_CODEX_DESCRIPTOR.pkg.version, "AGENTS.md", 7)}
    r, valid := acp_runtime_from_state(&state, {})
    if !testing.expect(t, valid && r != nil) do return
    defer acp_runtime_destroy(r)
    testing.expect(t, r.driver == &acp_protocol_codex_driver && r.d.current_input == "msg_old" && r.d.report_seq == 4)
    c := acp_codex(r)
    testing.expect(t, c.turn_id == "turn_old" && c.start_id == "ham:codex_epoch:3" && c.message_id == "item_1" && c.message_bytes == 5)
    testing.expect(t, len(c.completed_turns) == 2 && c.completed_turns[1] == "turn_b" && c.resume_attempts == 2 && c.unarchived)
    testing.expect_value(t, acp_codex_can_steer(r), ACP_Steer_Readiness.Now)
    // The new writer keeps the same "codex" object, so the journal round-trips
    // (and stays readable by the previous reader).
    raw, saved := acp_runtime_durable_json(r)
    testing.expect(t, saved && strings.contains(raw, `"codex":{"turn_id":"turn_old"`) && !strings.contains(raw, "driver_state"))
    again: ACP_Runtime_Durable
    testing.expect(t, acp_runtime_durable_load(&acp_protocol_codex_driver, raw, &again, context.temp_allocator))
    defer acp_runtime_durable_free_driver_state(&acp_protocol_codex_driver, &again)
    testing.expect(t, acp_codex_durable_valid(&again) && acp_codex_durable(&again).completed_turns[0] == "turn_a")
    // ACP drivers own no state: the legacy zero "codex" object is ignored.
    plain: ACP_Runtime_Durable
    testing.expect(t, acp_runtime_durable_load(&acp_protocol_acp_driver, CODEX_OLD_FORMAT_DURABLE, &plain, context.temp_allocator))
    testing.expect(t, plain.driver_state == nil && plain.current_input == "msg_old")
    // A malformed driver object fails the restore instead of being dropped.
    bad: ACP_Runtime_Durable
    testing.expect(t, !acp_runtime_durable_load(&acp_protocol_codex_driver, `{"phase":"ready","codex":{"turn_id":7}}`, &bad, context.temp_allocator))
    acp_runtime_durable_free_driver_state(&acp_protocol_codex_driver, &bad)
}
