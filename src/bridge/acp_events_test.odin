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
import vault "odin_test:lib/vault"
import live "odin_test:lib/tool_live"

t5_events:[dynamic]string
t5_locked:bool
t5_ingest :: proc(rec:Bridge_Local_Agent_Token_Record,raw:string,now:i64) -> Bridge_Ext_Ingest_Result {
    context.allocator=runtime.heap_allocator()
    append(&t5_events,strings.clone(raw));return {accepted=1}
}
t5_keyring :: proc() -> (vault.Vault_Keyring,bool) {
    if sync.atomic_load(&t5_locked) do return {},false
    key:[32]byte
    return vault.keyring_from_single_key("t5",{1,2,3,4,5,6,7,8},1,key[:])
}

t5_input_fixture:^T4_Runtime_Test
t5_input_rows:string
t5_ack_attempts:int
t5_ack_before_checkpoint:bool
t5_input_relay :: proc(path:[]string,method,params:string,rec:Bridge_Local_Agent_Token_Record,timeout_ms:int) -> Bridge_Local_Relay_Result {
    obj:=acp_event_object(params)
    if _,ack:=obj["ack_message_ids"];ack {
        sync.mutex_lock(&t5_input_fixture.f.mu)
        saved,valid:=acp_state_decode(t5_input_fixture.f.snapshot)
        sync.mutex_unlock(&t5_input_fixture.f.mu)
        if !valid || len(saved.queued_input_message_ids)!=3 do t5_ack_before_checkpoint=true
        acp_state_delete(&saved)
        t5_ack_attempts+=1
        if t5_ack_attempts==1 do return {ok=true,status=503,body=strings.clone("{}")}
        return {ok=true,status=200,body=strings.clone(`{"data":{"marked_count":3}}`)}
    }
    if t5_ack_attempts>=2 do return {ok=true,status=200,body=strings.clone(`{"data":{"messages":[]}}`)}
    return {ok=true,status=200,body=strings.clone(t5_input_rows)}
}

@(test)
t5_acp_input_queue_before_ack_fifo_and_duplicate_notice :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    previous_records:=bridge_local_token_records
    bridge_local_token_records=make([dynamic]Bridge_Local_Agent_Token_Record,allocator=runtime.heap_allocator())
    defer {delete(bridge_local_token_records);bridge_local_token_records=previous_records}
    prev_ingest:=acp_events_ingest;prev_keys:=acp_chat_keyring;prev_relay:=acp_chat_relay
    acp_events_ingest=t5_ingest;acp_chat_keyring=t5_keyring;acp_chat_relay=t5_input_relay;sync.atomic_store(&t5_locked,false)
    defer {acp_events_ingest=prev_ingest;acp_chat_keyring=prev_keys;acp_chat_relay=prev_relay;t5_reset_events();t5_input_fixture=nil;t5_input_rows=""}
    f:T4_Runtime_Test;t5_fixture_open(&f);defer {f.r.d.stopped=true;acp_runtime_destroy(f.r);acp_test_delete(&f.f);bridge_runtime_set_status("inst_t5_events","stopped","idle")}
    testing.expect(t,acp_chat_prepare(f.r));t5_input_fixture=&f;t5_ack_attempts=0;t5_ack_before_checkpoint=false
    kr,_:=t5_keyring();defer vault.keyring_wipe(&kr)
    body,_:=bridge_encrypt_vault_text("actual message",&kr,context.temp_allocator)
    label,_:=bridge_encrypt_vault_text("chosen answer",&kr,context.temp_allocator)
    rows:=make([dynamic]json.Value,allocator=context.temp_allocator)
    for i in 1..=3 {
        row:=make(json.Object,allocator=context.temp_allocator)
        row["message_id"]=json.String(fmt.tprintf("msg_%d",i));row["body"]=json.String(body)
        row["direction"]=json.String("user_to_agent");row["sender_agent_instance_id"]=json.String("inst_t5_events")
        row["metadata"]=acp_event_object(fmt.tprintf("{{\"source_message_id\":\"question\",\"option_id\":\"selected\",\"custom_text\":\"%s\"}}",label))
        append(&rows,row)
    }
    t5_input_rows=acp_event_json(struct{data:struct{messages:[]json.Value}}{data={rows[:]}})
    testing.expect(t,!acp_chat_fetch_inputs(f.r.chat),"first ack deliberately fails after durable queueing")
    testing.expect(t,!t5_ack_before_checkpoint)
    testing.expect_value(t,len(f.r.inbox.queue),3)
    testing.expect(t,acp_chat_fetch_inputs(f.r.chat),"same unread rows are retried and acknowledged")
    testing.expect_value(t,len(f.r.inbox.queue),3)
    for input,i in f.r.inbox.queue {
        testing.expect_value(t,input.id,fmt.tprintf("msg_%d",i+1))
        testing.expect(t,strings.contains(input.text,"actual message") && strings.contains(input.text,"chosen answer") && strings.contains(input.text,"selected") && !strings.contains(input.text,"chat read"))
    }
    testing.expect_value(t,len(f.r.client.state.queued_input_message_ids),0)
    // The prompt queue is still durable after the Hub receipt was recorded.
    restored,valid:=acp_state_decode(f.f.snapshot);defer acp_state_delete(&restored)
    testing.expect(t,valid && strings.contains(restored.runtime_json,"actual message"))
}
t5_notification :: proc(data:rawptr,method,params:string) {
    f:=cast(^T4_Runtime_Test)data;defer {delete(method);delete(params)}
    acp_events_notification(f.r,method,params)
}
t5_inbound :: proc(data:rawptr,id,method,params:string) -> bool {
    f:=cast(^T4_Runtime_Test)data;return acp_runtime_inbound(f.r,id,method,params)
}
t5_fixture_work :: proc(data:rawptr,c:^ACP_RPC_Client,arg:string) -> bool {
    f:=cast(^T4_Runtime_Test)data
    switch arg {
    case "start": acp_events_prompt_started(f.r,"msg_input")
    case "finish": acp_events_prompt_finished(f.r,"msg_input",`{"stopReason":"end_turn"}`,"")
    case "replay": f.r.d.replay_only=true
    case "restore-live": f.r.d.replay_only=false
    case "config-ready":
        acp_runtime_replace(&f.r.d.config_json,T4_CONFIG);f.r.d.ready=true
    case "many-chunks":
        for _ in 0..<10000 {
            before:=cap(f.r.chat.text_buffer)
            acp_chat_chunk(f.r,"é**\n")
            if cap(f.r.chat.text_buffer)!=before do t5_buffer_growths+=1
        }
    case: return false
    }
    return acp_rpc_checkpoint(c)
}

@(test)
t5_acp_configuration_updates_preserve_frozen_launch_policy :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    previous_records:=bridge_local_token_records
    bridge_local_token_records=make([dynamic]Bridge_Local_Agent_Token_Record,allocator=runtime.heap_allocator())
    defer {delete(bridge_local_token_records);bridge_local_token_records=previous_records}
    prev:=acp_events_ingest;acp_events_ingest=t5_ingest;defer {acp_events_ingest=prev;t5_reset_events()}
    f:T4_Runtime_Test;t5_fixture_open(&f);defer {f.r.d.stopped=true;acp_runtime_destroy(f.r);acp_test_delete(&f.f);bridge_runtime_set_status("inst_t5_events","stopped","idle")}
    t5_fixture_command(&f,"config-ready")
    config:=acp_event_object(T4_CONFIG);config["sessionUpdate"]=json.String("config_option_update")
    t5_update(&f,t,1,acp_event_json(config))
    testing.expect_value(t,f.r.d.error,"")
    t5_update(&f,t,2,`{"sessionUpdate":"plan","entries":[{"content":"diagnostic only","status":"pending","priority":"medium"}]}`)
    testing.expect(t,strings.contains(f.r.d.plan_json,"diagnostic only"))
    t5_update(&f,t,3,`{"sessionUpdate":"current_mode_update","currentModeId":"default"}`)
    testing.expect_value(t,f.r.d.error,"")
    t5_update(&f,t,4,`{"sessionUpdate":"current_mode_update","currentModeId":"bypassPermissions"}`)
    testing.expect_value(t,f.r.d.error,"acp_permission_mode_unsupported")
    testing.expect_value(t,len(t5_events),0)
}
t5_fixture_command :: proc(f:^T4_Runtime_Test,arg:string) -> bool {
    cmd:=ACP_RPC_Command{kind=.Runtime,a=arg,runtime_work=t5_fixture_work,runtime_data=f}
    acp_rpc_call(f.r.client,&cmd);return cmd.ok
}
t5_fixture_open :: proc(f:^T4_Runtime_Test) {
    t4_runtime_open(f,"inst_t5_events","/unused/bootstrap")
    acp_runtime_replace(&f.r.session,"s")
    f.r.client.callbacks.notification=t5_notification
    f.r.client.callbacks.inbound_request=t5_inbound
}
t5_reset_events :: proc() {
    for raw in t5_events do delete(raw,runtime.heap_allocator())
    delete(t5_events);t5_events=nil
}
t5_update :: proc(f:^T4_Runtime_Test,t:^testing.T,seq:u64,update:string) {
    frame:=fmt.tprintf("{{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{{\"sessionId\":\"s\",\"update\":%s}}}}\n",update)
    testing.expect(t,f.r.client.io.feed(f.r.client,frame,seq))
    acp_test_wait(t,&f.f,.Acks,int(seq))
}

@(test)
t5_acp_tool_partial_terminal_diff_and_replay :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    previous_records:=bridge_local_token_records
    bridge_local_token_records=make([dynamic]Bridge_Local_Agent_Token_Record,allocator=runtime.heap_allocator())
    defer { delete(bridge_local_token_records);bridge_local_token_records=previous_records }
    previous:=acp_events_ingest;acp_events_ingest=t5_ingest;defer {acp_events_ingest=previous;t5_reset_events()}
    f:T4_Runtime_Test;t5_fixture_open(&f);defer {f.r.d.stopped=true;acp_runtime_destroy(f.r);acp_test_delete(&f.f);bridge_runtime_set_status("inst_t5_events","stopped","idle")}
    t5_update(&f,t,1,`{"sessionUpdate":"tool_call","toolCallId":"c","name":"Bash","status":"pending","rawInput":{"command":"pwd"}}`)
    t5_update(&f,t,2,`{"sessionUpdate":"tool_call_update","toolCallId":"c","status":"in_progress"}`)
    t5_update(&f,t,3,`{"sessionUpdate":"tool_call_update","toolCallId":"c","status":"completed","rawOutput":{"ok":true},"content":[{"type":"diff","path":"a.txt","oldText":"old","newText":"new"}]}`)
    t5_update(&f,t,4,`{"sessionUpdate":"tool_call_update","toolCallId":"c","status":"completed","content":[{"type":"diff","path":"a.txt","oldText":"old","newText":"new"}]}`)
    testing.expect_value(t,len(t5_events),3)
    testing.expect(t,strings.contains(t5_events[0],`"event":"tool.start"`))
    testing.expect(t,strings.contains(t5_events[1],`"name":"Bash"`) && strings.contains(t5_events[1],`"command":"pwd"`))
    testing.expect(t,strings.contains(t5_events[2],`"event":"file.edit"`))
    t5_update(&f,t,5,`{"sessionUpdate":"tool_call_update","toolCallId":"terminal-first","status":"failed","kind":"execute"}`)
    testing.expect_value(t,len(t5_events),5)
    t5_fixture_command(&f,"replay")
    t5_update(&f,t,6,`{"sessionUpdate":"tool_call","toolCallId":"historical","status":"pending"}`)
    t5_update(&f,t,7,`{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"historical assistant"}}`)
    testing.expect_value(t,len(t5_events),5)
    t5_fixture_command(&f,"restore-live")
    t5_update(&f,t,8,`{"sessionUpdate":"plan","entries":[]}`)
    testing.expect_value(t,len(t5_events),5)
    // A large diff remains bounded after JSON encoding and UTF-8 clipping.
    diff:=acp_event_json(struct{type,path,oldText,newText:string}{"diff","big",strings.repeat("a",70000,context.temp_allocator),strings.repeat("b",70000,context.temp_allocator)})
    t5_update(&f,t,9,fmt.tprintf("{{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"diff\",\"status\":\"completed\",\"content\":[%s]}}",diff))
    last:=t5_events[len(t5_events)-1]
    testing.expect(t,len(last)<=contracts.EXT_EVENT_MAX_BYTES && strings.contains(last,`"diff_truncated":true`))
}

@(test)
t5_acp_permission_cancelled_and_turn_continues :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    previous_records:=bridge_local_token_records
    bridge_local_token_records=make([dynamic]Bridge_Local_Agent_Token_Record,allocator=runtime.heap_allocator())
    defer { delete(bridge_local_token_records);bridge_local_token_records=previous_records }
    previous:=acp_events_ingest;acp_events_ingest=t5_ingest;defer {acp_events_ingest=previous;t5_reset_events()}
    f:T4_Runtime_Test;t5_fixture_open(&f);defer {f.r.d.stopped=true;acp_runtime_destroy(f.r);acp_test_delete(&f.f);bridge_runtime_set_status("inst_t5_events","stopped","idle")}
    id,sent:=acp_rpc_request(f.r.client,"session/prompt",`{"sessionId":"s","prompt":[]}`,0,acp_test_completion(&f.f))
    defer delete(string(id),runtime.heap_allocator());testing.expect(t,sent)
    permission:="{\"jsonrpc\":\"2.0\",\"id\":700,\"method\":\"session/request_permission\",\"params\":{\"sessionId\":\"s\",\"toolCall\":{\"toolCallId\":\"c\",\"title\":\"Run command\"},\"options\":[]}}\n"
    f.r.client.io.feed(f.r.client,permission,1);acp_test_wait(t,&f.f,.Acks,1);acp_test_wait(t,&f.f,.Writes,2)
    testing.expect(t,strings.contains(f.f.writes[1].bytes,`"outcome":"cancelled"`))
    // No once options means no actionable prompt; duplicate IDs reuse the reply.
    f.r.client.io.feed(f.r.client,permission,2);acp_test_wait(t,&f.f,.Acks,2)
    f.r.client.io.feed(f.r.client,acp_test_response(id,`{"stopReason":"end_turn"}`),3)
    testing.expect(t,acp_test_wait(t,&f.f,.Results,1),"the turn has a bounded, explicit completion after cancellation")
    testing.expect_value(t,len(t5_events),0)
    testing.expect(t,f.f.results[0].ok)
    sync.mutex_lock(&bridge_permission_mutex)
    for pending in bridge_permission_pending do testing.expect(t,pending.agent_instance_id!="inst_t5_events","ACP cancellation must not create an interactive prompt")
    sync.mutex_unlock(&bridge_permission_mutex)
}

t5_admit_frame :: proc(data:rawptr) -> bool {
    f:=cast(^T4_Runtime_Test)data;return acp_chat_can_process(f.r)
}

@(test)
t5_acp_vault_lock_backpressures_frames_and_resumes :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    previous_records:=bridge_local_token_records
    bridge_local_token_records=make([dynamic]Bridge_Local_Agent_Token_Record,allocator=runtime.heap_allocator())
    defer {delete(bridge_local_token_records);bridge_local_token_records=previous_records}
    prev_ingest:=acp_events_ingest;prev_keys:=acp_chat_keyring
    acp_events_ingest=t5_ingest;acp_chat_keyring=t5_keyring;sync.atomic_store(&t5_locked,false)
    defer {acp_events_ingest=prev_ingest;acp_chat_keyring=prev_keys;t5_reset_events();sync.atomic_store(&t5_locked,false)}
    f:T4_Runtime_Test;t5_fixture_open(&f);defer {f.r.d.stopped=true;acp_runtime_destroy(f.r);acp_test_delete(&f.f);bridge_runtime_set_status("inst_t5_events","stopped","idle")}
    testing.expect(t,acp_chat_prepare(f.r));t5_fixture_command(&f,"start")
    f.r.client.callbacks.can_process=t5_admit_frame
    sync.atomic_store(&t5_locked,true)
    line:="{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"s\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"after unlock\"}}}}\n"
    testing.expect(t,f.r.client.io.feed(f.r.client,line,1))
    time.sleep(50*time.Millisecond)
    sync.mutex_lock(&f.f.mu);testing.expect_value(t,len(f.f.acks),0);sync.mutex_unlock(&f.f.mu)
    testing.expect_value(t,f.r.chat.d.text,"")
    // Controls remain responsive while stdout is paused.
    testing.expect(t,t5_fixture_command(&f,"restore-live"))
    sync.atomic_store(&t5_locked,false)
    testing.expect(t,acp_test_wait(t,&f.f,.Acks,1))
    testing.expect_value(t,f.r.chat.d.text,"after unlock")
}

@(test)
t5_acp_chat_snapshots_retry_cap_and_sealed_journal :: proc(t:^testing.T) {
    // Pins the assistant-only outbox layout (reports covered in acp_send_now_test).
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    reports:=acp_delivery_reports_enabled;acp_delivery_reports_enabled=false;defer acp_delivery_reports_enabled=reports
    previous_records:=bridge_local_token_records
    bridge_local_token_records=make([dynamic]Bridge_Local_Agent_Token_Record,allocator=runtime.heap_allocator())
    defer { delete(bridge_local_token_records);bridge_local_token_records=previous_records }
    prev_ingest:=acp_events_ingest;prev_keys:=acp_chat_keyring
    acp_events_ingest=t5_ingest;acp_chat_keyring=t5_keyring;t5_locked=false
    defer {acp_events_ingest=prev_ingest;acp_chat_keyring=prev_keys;t5_reset_events()}
    f:T4_Runtime_Test;t5_fixture_open(&f);defer {f.r.d.stopped=true;acp_runtime_destroy(f.r);acp_test_delete(&f.f);bridge_runtime_set_status("inst_t5_events","stopped","idle")}
    testing.expect(t,acp_chat_prepare(f.r))
    t5_fixture_command(&f,"start")
    t5_update(&f,t,1,`{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"private **Markdown**"}}`)
    testing.expect_value(t,len(f.r.chat.d.outbox),1)
    testing.expect(t,strings.has_prefix(f.r.chat.d.outbox[0].body,"vault:v2:"))
    t4_runtime_call(&f,"chat_tick");retry:=strings.clone(f.r.chat.publication);defer delete(retry)
    t4_runtime_call(&f,"chat_tick");testing.expect_value(t,f.r.chat.publication,retry)
    t5_fixture_command(&f,"finish")
    testing.expect_value(t,len(f.r.chat.d.outbox),1)
    testing.expect_value(t,f.r.chat.d.outbox[0].message_status,"complete")
    testing.expect(t,f.r.chat.d.outbox[0].revision>1)
    root:=fmt.tprintf("%s/.cache/heimdall-tests/t5-sealed-%d",os.get_env("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    path,_:=acp_state_path(root,"inst_t5_events","t4_epoch");defer delete(path);defer os.remove_all(root)
    saved,decoded:=acp_state_decode(f.f.snapshot);testing.expect(t,decoded);defer acp_state_delete(&saved)
    testing.expect(t,acp_state_write(path,&saved))
    raw,_:=os.read_entire_file(path,context.allocator);defer delete(raw)
    testing.expect(t,!strings.contains(string(raw),"Markdown") && !strings.contains(string(raw),"session/prompt") && strings.contains(string(raw),"sealed_state"))
    restored,opened:=acp_state_read(path);testing.expect(t,opened && restored.chat_outbox_json==saved.chat_outbox_json);acp_state_delete(&restored)
    t5_locked=true
    testing.expect(t,acp_state_waiting_for_vault(string(raw)),"cold reconcile must preserve a sealed journal until unlock")
    locked,readable:=acp_state_read(path);testing.expect(t,!readable);acp_state_delete(&locked)
    testing.expect(t,!acp_state_write(path,&saved),"a locked vault cannot write plaintext fallback")
    t5_locked=false
    testing.expect(t,!acp_state_waiting_for_vault(string(raw)))
    t5_fixture_command(&f,"start")
    t5_update(&f,t,2,`{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"partial"}}`)
    oversized:=acp_event_json(struct{sessionUpdate:string,content:struct{type,text:string}}{"agent_message_chunk",{"text",strings.repeat("z",contracts.ACP_ASSISTANT_MAX_BYTES,context.temp_allocator)}})
    t5_update(&f,t,3,oversized)
    testing.expect_value(t,f.r.chat.d.status,"failed")
    testing.expect_value(t,f.r.chat.d.text,"partial")
    testing.expect_value(t,f.r.chat.d.stop_reason,"assistant_message_too_large")
    testing.expect(t,acp_chat_bytes(f.r.chat)<=ACP_CHAT_OUTBOX_MAX)
}

t5_recovery_path, t5_recovery_request:string
t5_recovery_attempts:int
t5_recovery_durable:bool
t5_recovery_relay :: proc(path:[]string,method,params:string,rec:Bridge_Local_Agent_Token_Record,timeout_ms:int) -> Bridge_Local_Relay_Result {
    saved,valid:=acp_state_read(t5_recovery_path)
    t5_recovery_durable=valid && strings.contains(saved.chat_outbox_json,`"message_status":"failed"`)
    acp_state_delete(&saved)
    t5_recovery_attempts+=1
    if t5_recovery_request=="" do t5_recovery_request=strings.clone(params,runtime.heap_allocator())
    if params!=t5_recovery_request || rec.instance_token!="hit_inst_t5_events~t4_epoch" || rec.token_hash!="" do t5_recovery_durable=false
    return {ok=true,status=503 if t5_recovery_attempts==1 else 200,body=strings.clone("{}")}
}

@(test)
t5_acp_detached_finalization_retries_durably_after_token_invalidation :: proc(t:^testing.T) {
    // Pins the assistant-only outbox layout (reports covered in acp_send_now_test).
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    reports:=acp_delivery_reports_enabled;acp_delivery_reports_enabled=false;defer acp_delivery_reports_enabled=reports
    previous_records:=bridge_local_token_records;previous_owners:=acp_runtimes
    bridge_local_token_records=make([dynamic]Bridge_Local_Agent_Token_Record,allocator=runtime.heap_allocator())
    acp_runtimes=make(map[string]^ACP_Runtime,allocator=runtime.heap_allocator())
    defer {delete(bridge_local_token_records);bridge_local_token_records=previous_records;delete(acp_runtimes);acp_runtimes=previous_owners}
    prev_ingest:=acp_events_ingest;prev_keys:=acp_chat_keyring;prev_relay:=acp_chat_relay
    acp_events_ingest=t5_ingest;acp_chat_keyring=t5_keyring;acp_chat_relay=t5_recovery_relay;sync.atomic_store(&t5_locked,false)
    defer {acp_events_ingest=prev_ingest;acp_chat_keyring=prev_keys;acp_chat_relay=prev_relay;t5_reset_events();delete(t5_recovery_request,runtime.heap_allocator());t5_recovery_request="";t5_recovery_path=""}
    f:T4_Runtime_Test;t5_fixture_open(&f);defer {f.r.d.stopped=true;acp_runtime_destroy(f.r);acp_test_delete(&f.f);bridge_runtime_set_status("inst_t5_events","stopped","idle")}
    testing.expect(t,acp_chat_prepare(f.r));t5_fixture_command(&f,"start")
    t5_update(&f,t,1,`{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"interrupted private reply"}}`)
    root:=fmt.tprintf("%s/.cache/heimdall-tests/t5-orphan-%d",os.get_env("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    path,_:=acp_state_path(root,"inst_t5_events","t4_epoch");defer delete(path);defer os.remove_all(root)
    saved,valid:=acp_state_decode(f.f.snapshot);testing.expect(t,valid);defer acp_state_delete(&saved)
    testing.expect(t,acp_state_write(path,&saved));t5_recovery_path=path;t5_recovery_attempts=0;t5_recovery_durable=false
    // A live same-epoch dispatcher alone owns the journal.
    acp_runtimes[f.r.instance]=f.r
    testing.expect(t,!acp_chat_recover_journal(path));testing.expect_value(t,t5_recovery_attempts,0)
    delete_key(&acp_runtimes,f.r.instance)
    bridge_local_token_records[0].instance_token="hit_inst_t5_events~replacement"
    bridge_local_token_records[0].invalidated_at_unix_ms=1
    testing.expect(t,acp_chat_recover_journal(path));testing.expect(t,t5_recovery_durable)
    first,opened:=acp_state_read(path);testing.expect(t,opened);defer acp_state_delete(&first)
    testing.expect(t,strings.contains(first.chat_outbox_json,`"message_status":"failed"`))
    testing.expect(t,acp_chat_recover_journal(path));testing.expect(t,t5_recovery_durable,"retry must retain the exact revision and ciphertext")
    final,readable:=acp_state_read(path);testing.expect(t,readable);defer acp_state_delete(&final)
    restored:=ACP_Runtime{epoch="t4_epoch",saved_outbox=final.chat_outbox_json}
    testing.expect(t,acp_chat_prepare(&restored));defer acp_chat_destroy(&restored)
    testing.expect_value(t,len(restored.chat.d.outbox),0)
    testing.expect_value(t,restored.chat.d.status,"failed")
    route:=bridge_agent_route("agent.chat.assistant_message","{}")
    testing.expect_value(t,bridge_agent_route_target(route),"/api/v1/agent-actions/chat/assistant-message")
    testing.expect(t,bridge_agent_method_allowed("agent.chat.assistant_message"))
}

@(test)
t14_acp_event_timestamp_preserves_reset_fence_precision :: proc(t:^testing.T) {
    now:=time.unix(1795075200,123456789)
    stamp:=acp_events_timestamp(now)
    parsed,valid:=live.tool_live_ns(stamp)
    testing.expect(t,valid)
    testing.expect_value(t,parsed,time.to_unix_nanoseconds(now))
}
