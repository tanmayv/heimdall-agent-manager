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

c4_chat_test :: proc(t:^testing.T,scenario:proc(t:^testing.T,f:^T4_Runtime_Test)) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    records:=bridge_local_token_records
    bridge_local_token_records=make([dynamic]Bridge_Local_Agent_Token_Record,allocator=runtime.heap_allocator())
    defer {delete(bridge_local_token_records);bridge_local_token_records=records}
    ingest:=acp_events_ingest;keys:=acp_chat_keyring
    acp_events_ingest=t5_ingest;acp_chat_keyring=t5_keyring;sync.atomic_store(&t5_locked,false)
    // These scenarios pin the assistant-only outbox layout.
    reports:=acp_delivery_reports_enabled;acp_delivery_reports_enabled=false
    defer {acp_events_ingest=ingest;acp_chat_keyring=keys;sync.atomic_store(&t5_locked,false);t5_reset_events();acp_delivery_reports_enabled=reports}
    f:T4_Runtime_Test;c4_open(t,&f);defer t16_close(&f)
    scenario(t,&f)
}

c4_open :: proc(t:^testing.T,f:^T4_Runtime_Test) {
    t16_open(f,"inst_c4_chat")
    acp_runtime_replace(&f.r.session,"s")
    f.r.client.callbacks.notification=t5_notification
    f.r.client.callbacks.can_process=t5_admit_frame
    testing.expect(t,acp_chat_prepare(f.r))
}

c4_text :: proc(f:^T4_Runtime_Test,t:^testing.T,seq:u64,text:string) {
    update:=acp_event_json(struct{sessionUpdate:string,content:struct{type,text:string}}{"agent_message_chunk",{"text",text}})
    t5_update(f,t,seq,update)
}

c4_body :: proc(t:^testing.T,entry:contracts.ACP_Assistant_Message_Input,expected:string) {
    kr,_:=t5_keyring();defer vault.keyring_wipe(&kr)
    text,ok:=bridge_vault_decrypt_field(entry.body,&kr,context.temp_allocator)
    testing.expect(t,ok);testing.expect_value(t,text,expected)
}

c4_work :: proc(data:rawptr,c:^ACP_RPC_Client,arg:string) -> bool {
    f:=cast(^T4_Runtime_Test)data
    switch arg {
    case "split": acp_chat_boundary(f.r);acp_chat_chunk(f.r,"x")
    case "defer":
        acp_chat_boundary(f.r);sync.atomic_store(&t5_locked,true)
        acp_chat_chunk(f.r,"after lock")
    case "finish-locked":
        sync.atomic_store(&t5_locked,true)
        acp_events_prompt_finished(f.r,"msg_original",`{"stopReason":"end_turn"}`,"")
    case: return false
    }
    return acp_rpc_checkpoint(c)
}

c4_call :: proc(f:^T4_Runtime_Test,arg:string) -> bool {
    cmd:=ACP_RPC_Command{kind=.Runtime,a=arg,runtime_work=c4_work,runtime_data=f}
    acp_rpc_call(f.r.client,&cmd);return cmd.ok
}

@(test)
c4_acp_chat_steering_splits_after_injection_without_another_prompt :: proc(t:^testing.T) {
    c4_chat_test(t,proc(t:^testing.T,f:^T4_Runtime_Test) {
        f.r.d.steering_supported=true
        testing.expect(t,t16_input(f,"msg_original","start",.Steer))
        c4_text(f,t,1,"before ")
        turn:=strings.clone(f.r.chat.d.turn_id,context.temp_allocator)
        first:=strings.clone(f.r.chat.d.message_id,context.temp_allocator)
        testing.expect(t,t16_input(f,"msg_steer","change direction",.Steer))
        c4_text(f,t,2,"injection") // Before the adapter confirms injection.
        testing.expect(t,!f.r.chat.d.split_pending)
        t4_runtime_reply(t,f,1,`{"outcome":"injected"}`,3)
        testing.expect(t,f.r.chat.d.split_pending)
        testing.expect(t,t16_input(f,"msg_steer","duplicate",.Steer))
        c4_text(f,t,4,"")
        testing.expect_value(t,len(f.r.chat.d.outbox),1)
        c4_text(f,t,5,"after steering")
        d:=&f.r.chat.d
        testing.expect_value(t,d.turn_id,turn)
        testing.expect_value(t,d.segment_index,1)
        if !testing.expect_value(t,len(d.outbox),2) do return
        testing.expect_value(t,d.outbox[0].message_id,first)
        testing.expect_value(t,d.outbox[0].turn_id,turn)
        testing.expect_value(t,d.outbox[1].turn_id,strings.concatenate({turn,":s1"},context.temp_allocator))
        testing.expect(t,d.outbox[1].message_id!=first && d.outbox[1].revision==1)
        testing.expect_value(t,d.outbox[0].message_status,"complete")
        testing.expect_value(t,d.outbox[0].stop_reason,"")
        c4_body(t,d.outbox[0],"before injection");c4_body(t,d.outbox[1],"after steering")
        t4_runtime_reply(t,f,0,`{"stopReason":"end_turn"}`,6)
        testing.expect_value(t,d.outbox[1].message_status,"complete")
        testing.expect_value(t,d.outbox[1].stop_reason,"end_turn")
        testing.expect_value(t,t16_writes(f),2) // One prompt, one steering RPC.
        active,idle:=0,0
        for raw in t5_events {
            if strings.contains(raw,`"state":"active"`) do active+=1
            if strings.contains(raw,`"state":"idle"`) do idle+=1
        }
        testing.expect(t,active==1 && idle==1,"chat segments must not add activity/turn boundaries")
        // A receipt for an in-flight older revision cannot delete its closed
        // replacement.
        testing.expect(t,t4_runtime_call(f,strings.concatenate({"chat_saved:",acp_event_json(struct{message_id:string,revision:i64}{first,1})},context.temp_allocator)))
        testing.expect_value(t,len(d.outbox),2)
        testing.expect(t,t4_runtime_call(f,strings.concatenate({"chat_saved:",acp_event_json(d.outbox[0])},context.temp_allocator)))
        testing.expect_value(t,len(d.outbox),1)
        testing.expect(t,t4_runtime_call(f,strings.concatenate({"chat_saved:",acp_event_json(d.outbox[0])},context.temp_allocator)))
        testing.expect(t,t4_runtime_call(f,"chat_tick"))
        testing.expect(t,len(d.outbox)==0 && f.r.chat.publication=="","acknowledged snapshots are not recreated")
    })
}

@(test)
c4_acp_chat_tool_boundaries_no_empty_bubbles_and_last_stop_reason :: proc(t:^testing.T) {
    c4_chat_test(t,proc(t:^testing.T,f:^T4_Runtime_Test) {
        testing.expect(t,t16_input(f,"msg_original","start",.Steer))
        t5_update(f,t,1,`{"sessionUpdate":"tool_call","toolCallId":"first","status":"pending"}`)
        testing.expect_value(t,len(f.r.chat.d.outbox),0)
        c4_text(f,t,2,"before tool")
        t5_update(f,t,3,`{"sessionUpdate":"tool_call_update","toolCallId":"first","status":"completed"}`)
        c4_text(f,t,4,"")
        c4_text(f,t,5,"after tool")
        testing.expect_value(t,f.r.chat.d.segment_index,1)
        // Duplicate terminal telemetry is a receipt, not another tool boundary.
        t5_update(f,t,6,`{"sessionUpdate":"tool_call_update","toolCallId":"first","status":"completed"}`)
        c4_text(f,t,7," continues")
        testing.expect_value(t,f.r.chat.d.segment_index,1)
        t5_update(f,t,8,`{"sessionUpdate":"tool_call","toolCallId":"last","status":"completed"}`)
        t4_runtime_reply(t,f,0,`{"stopReason":"cancelled"}`,9)
        if !testing.expect_value(t,len(f.r.chat.d.outbox),2) do return
        c4_body(t,f.r.chat.d.outbox[0],"before tool")
        c4_body(t,f.r.chat.d.outbox[1],"after tool continues")
        testing.expect_value(t,f.r.chat.d.outbox[0].stop_reason,"")
        testing.expect_value(t,f.r.chat.d.outbox[1].stop_reason,"cancelled")
        testing.expect_value(t,t16_writes(f),1)
    })
}

@(test)
c4_acp_chat_restore_keeps_segments_deferred_text_and_replay_identity :: proc(t:^testing.T) {
    c4_chat_test(t,proc(t:^testing.T,f:^T4_Runtime_Test) {
        testing.expect(t,t16_input(f,"msg_original","start",.Steer))
        c4_text(f,t,1,"first")
        t5_update(f,t,2,`{"sessionUpdate":"tool_call","toolCallId":"tool","status":"completed"}`)
        c4_text(f,t,3,"second")
        testing.expect(t,c4_call(f,"defer"))
        testing.expect_value(t,f.r.chat.d.deferred_text,"after lock")
        testing.expect(t,!acp_chat_can_process(f.r))
        sync.atomic_store(&t5_locked,false)
        sync.mutex_lock(&f.f.mu);snapshot:=strings.clone(f.f.snapshot,runtime.heap_allocator());sync.mutex_unlock(&f.f.mu)
        defer delete(snapshot,runtime.heap_allocator())
        state,valid:=acp_state_decode(snapshot);defer acp_state_delete(&state)
        if !testing.expect(t,valid) do return
        root:=fmt.tprintf("%s/.cache/heimdall-tests/c4-sealed-%d",os.get_env("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
        path,_:=acp_state_path(root,f.r.instance,f.r.epoch);defer delete(path);defer os.remove_all(root)
        testing.expect(t,acp_state_write(path,&state))
        disk,opened:=acp_state_read(path);defer acp_state_delete(&disk)
        testing.expect(t,opened && disk.chat_outbox_json==state.chat_outbox_json)
        raw,_:=os.read_entire_file(path,context.temp_allocator)
        testing.expect(t,!strings.contains(string(raw),"after lock"))
        original_ids: [2]string
        for entry,i in f.r.chat.d.outbox do original_ids[i]=strings.clone(entry.message_id,context.temp_allocator)
        t16_close(f)
        f^={};c4_open(t,f)
        acp_chat_destroy(f.r)
        acp_runtime_replace(&f.r.saved_outbox,disk.chat_outbox_json)
        testing.expect(t,acp_chat_prepare(f.r))
        delete(f.r.d.phase,runtime.heap_allocator());delete(f.r.d.starter,runtime.heap_allocator());f.r.d={}
        testing.expect(t,json.unmarshal_string(disk.runtime_json,&f.r.d,allocator=runtime.heap_allocator())==nil)
        testing.expect(t,acp_rpc_restore(f.r.client,snapshot))
        testing.expect(t,t4_runtime_call(f,"chat_tick"))
        testing.expect(t,f.r.chat.d.deferred_text=="" && f.r.chat.d.segment_index==2)
        if !testing.expect_value(t,len(f.r.chat.d.outbox),3) do return
        for id,i in original_ids do testing.expect_value(t,f.r.chat.d.outbox[i].message_id,id)
        c4_body(t,f.r.chat.d.outbox[2],"after lock")
        // Replayed durable daemon frames and session/load historical updates
        // must not create segments, append text, or change ciphertext/revisions.
        before:=strings.clone(acp_event_json(f.r.chat.d),context.temp_allocator)
        testing.expect(t,f.r.client.io.feed(f.r.client,`{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"duplicate"}}}}`+"\n",3))
        testing.expect(t,t5_fixture_command(f,"replay"))
        testing.expect(t,f.r.client.io.feed(f.r.client,`{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call","toolCallId":"historical","status":"completed"}}}`+"\n",4))
        if !acp_test_wait(t,&f.f,.Acks,1) do return
        testing.expect_value(t,acp_event_json(f.r.chat.d),before)
        testing.expect(t,t5_fixture_command(f,"restore-live"))
        response:=acp_test_response(ACP_RPC_ID("ham:t4_epoch:1"),`{"stopReason":"end_turn"}`)
        testing.expect(t,f.r.client.io.feed(f.r.client,response,5))
        if !acp_test_wait(t,&f.f,.Acks,2) do return
        testing.expect_value(t,f.r.chat.d.outbox[2].stop_reason,"end_turn")
        testing.expect_value(t,f.f.order_errors,0)
    })
}

@(test)
c4_acp_chat_split_preserves_aggregate_size_cap_and_failure_on_last :: proc(t:^testing.T) {
    c4_chat_test(t,proc(t:^testing.T,f:^T4_Runtime_Test) {
        testing.expect(t,t16_input(f,"msg_original","start",.Steer))
        half:=strings.repeat("z",contracts.ACP_ASSISTANT_MAX_BYTES/2,context.temp_allocator)
        c4_text(f,t,1,half)
        t5_update(f,t,2,`{"sessionUpdate":"tool_call","toolCallId":"first","status":"completed"}`)
        c4_text(f,t,3,half)
        testing.expect_value(t,f.r.chat.d.turn_bytes,contracts.ACP_ASSISTANT_MAX_BYTES)
        t5_update(f,t,4,`{"sessionUpdate":"tool_call","toolCallId":"last","status":"completed"}`)
        c4_text(f,t,5,"x")
        testing.expect_value(t,f.r.chat.d.status,"failed")
        testing.expect_value(t,f.r.chat.d.text,half)
        if !testing.expect_value(t,len(f.r.chat.d.outbox),2) do return
        testing.expect_value(t,f.r.chat.d.outbox[0].message_status,"complete")
        testing.expect_value(t,f.r.chat.d.outbox[0].stop_reason,"")
        testing.expect_value(t,f.r.chat.d.outbox[1].message_status,"failed")
        testing.expect_value(t,f.r.chat.d.outbox[1].stop_reason,"assistant_message_too_large")
        testing.expect(t,acp_chat_bytes(f.r.chat)<=ACP_CHAT_OUTBOX_MAX)
        t4_runtime_reply(t,f,0,`{"stopReason":"cancelled"}`,6)
        testing.expect_value(t,f.r.chat.d.outbox[1].stop_reason,"assistant_message_too_large")
    })
}

@(test)
c4_acp_chat_terminal_flush_retries_after_vault_race :: proc(t:^testing.T) {
    c4_chat_test(t,proc(t:^testing.T,f:^T4_Runtime_Test) {
        testing.expect(t,t16_input(f,"msg_original","start",.Steer))
        c4_text(f,t,1,"before lock")
        testing.expect(t,c4_call(f,"finish-locked"))
        testing.expect_value(t,f.r.chat.d.outbox[0].message_status,"pending")
        sync.atomic_store(&t5_locked,false)
        testing.expect(t,t4_runtime_call(f,"chat_tick"))
        testing.expect_value(t,f.r.chat.d.outbox[0].message_status,"complete")
        testing.expect_value(t,f.r.chat.d.outbox[0].stop_reason,"end_turn")
        // A stop while a split is deferred must also keep the actual reason on
        // the continuation, rather than terminalizing its previous segment.
        t4_runtime_reply(t,f,0,`{"stopReason":"end_turn"}`,2)
        testing.expect(t,t16_input(f,"msg_second","next turn",.Steer))
        c4_text(f,t,3,"before split")
        testing.expect(t,c4_call(f,"defer"))
        testing.expect(t,c4_call(f,"finish-locked"))
        sync.atomic_store(&t5_locked,false)
        testing.expect(t,t4_runtime_call(f,"chat_tick"))
        last:=f.r.chat.d.outbox[len(f.r.chat.d.outbox)-1]
        c4_body(t,last,"after lock")
        testing.expect_value(t,last.message_status,"complete")
        testing.expect_value(t,last.stop_reason,"end_turn")
    })
}

@(test)
c4_acp_chat_segment_count_backpressure_and_legacy_restore :: proc(t:^testing.T) {
    c4_chat_test(t,proc(t:^testing.T,f:^T4_Runtime_Test) {
        testing.expect(t,t16_input(f,"msg_original","start",.Steer))
        for _ in 0..<ACP_CHAT_OUTBOX_ITEMS_MAX-1 do testing.expect(t,c4_call(f,"split"))
        d:=&f.r.chat.d
        testing.expect_value(t,len(d.outbox),ACP_CHAT_OUTBOX_ITEMS_MAX-1)
        testing.expect(t,!acp_chat_can_process(f.r),"reserve two slots for acknowledged-old plus new segment")
        saved:=strings.clone(acp_event_json(d.outbox[0]),context.temp_allocator)
        testing.expect(t,t4_runtime_call(f,strings.concatenate({"chat_saved:",saved},context.temp_allocator)))
        testing.expect(t,acp_chat_can_process(f.r))
        c4_text(f,t,1,"resumed")
        testing.expect(t,len(d.outbox)<=ACP_CHAT_OUTBOX_ITEMS_MAX && strings.has_suffix(d.text,"resumed"))
        // Journals written before segmentation omit all three new fields.
        legacy:=ACP_Runtime{instance="legacy",epoch="epoch",saved_outbox=`{"turn_id":"turn","message_id":"msg_0123456789abcdef","text":"old text","status":"pending","revision":1,"flushed_bytes":8,"flushed_status":"pending"}`}
        testing.expect(t,acp_chat_prepare(&legacy));defer acp_chat_destroy(&legacy)
        testing.expect(t,legacy.chat.d.turn_bytes==8 && legacy.chat.d.segment_index==0)
        testing.expect_value(t,legacy.chat.d.message_id,"msg_0123456789abcdef")
        testing.expect_value(t,acp_chat_wire_turn(&legacy.chat.d),"turn")
        corrupt:=ACP_Runtime{saved_outbox=`{"turn_id":"turn","text":"text","turn_bytes":2,"segment_index":1}`}
        testing.expect(t,!acp_chat_prepare(&corrupt))
    })
}
