package main

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

@(test)
t5_acp_tool_history_compacts_and_restores_after_a_thousand_calls :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    prev:=acp_events_ingest;acp_events_ingest=t5_ingest;defer {acp_events_ingest=prev;t5_reset_events()}
    c:ACP_RPC_Client;r:=ACP_Runtime{client=&c,session="history",provider="claude"}
    defer {context.allocator=runtime.heap_allocator();acp_tools_destroy(&r);acp_state_delete(&c.state);delete(r.d.error)}
    title:=strings.repeat("x",4096,context.temp_allocator)
    for i in 0..<1000 {
        update:=acp_event_object(fmt.tprintf("{{\"toolCallId\":\"tool-%d\",\"name\":\"Bash\",\"title\":\"%s\",\"status\":\"completed\"}}",i,title))
        acp_events_tool(&r,update)
        acp_events_tool(&r,update)
        if i%32==0 do testing.expect(t,acp_tools_checkpoint(&r,&c.state))
    }
    testing.expect_value(t,r.d.error,"")
    testing.expect_value(t,len(t5_events),2000)
    for i in 0..<1000 {
        testing.expect(t,strings.contains(t5_events[2*i],`"event":"tool.start"`) && strings.contains(t5_events[2*i+1],`"event":"tool.end"`))
    }
    testing.expect_value(t,r.tools.active,0)
    testing.expect(t,len(r.tools.entries)<=ACP_TOOLS_RECENT_MAX)
    testing.expect(t,acp_tools_checkpoint(&r,&c.state) && len(c.state.tool_map_json)<=ACP_TOOLS_JOURNAL_MAX)
    restored:=ACP_Runtime{client=&c,session="history",provider="claude"};defer acp_tools_destroy(&restored)
    testing.expect(t,acp_tools_prepare(&restored,c.state.tool_map_json))
    acp_events_tool(&restored,acp_event_object(`{"toolCallId":"tool-999","status":"completed"}`))
    testing.expect_value(t,len(t5_events),2000)
    acp_events_tool(&restored,acp_event_object(`{"toolCallId":"open","status":"pending","rawInput":{"command":"pwd"}}`))
    testing.expect(t,acp_tools_checkpoint(&restored,&c.state))
    next:=ACP_Runtime{client=&c,session="history",provider="claude"};defer acp_tools_destroy(&next)
    testing.expect(t,acp_tools_prepare(&next,c.state.tool_map_json))
    acp_events_tool(&next,acp_event_object(`{"toolCallId":"open","status":"completed"}`))
    testing.expect_value(t,len(t5_events),2002)
    testing.expect(t,strings.contains(t5_events[2001],"pwd"),"partial active input survives restore without a duplicate start")
}

@(test)
t5_acp_corrupt_tool_restore_reports_protocol_error :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    c:ACP_RPC_Client
    c.state.tool_map_json=strings.clone(`[{"id":"allocated","diffs":["hash"]},{"id":42}]`,runtime.heap_allocator())
    r:=ACP_Runtime{client=&c}
    defer {context.allocator=runtime.heap_allocator();acp_tools_destroy(&r);acp_state_delete(&c.state);delete(r.d.error)}
    acp_events_tool(&r,acp_event_object(`{"toolCallId":"new","status":"pending"}`))
    testing.expect_value(t,r.d.error,"acp_protocol_error")
    testing.expect_value(t,len(r.tools.entries),0)
    run_dir:string
    { context.allocator=context.temp_allocator;run_dir=bridge_runtime_default_run_dir("inst_t5_corrupt_restore") }
    saved:=ACP_State{bridge=bridge_config.daemon_id,adapter_version=ACP_CLAUDE_VERSION,provider="claude",run_dir=run_dir,pipe_generation="generation",selected_mode="default",instance="inst_t5_corrupt_restore",launch_epoch="epoch",tool_map_json=c.state.tool_map_json,
        runtime_json=acp_event_json(ACP_Runtime_Durable{phase="initialize",error="acp_auth_required",auth_required=true})}
    restored,built:=acp_runtime_from_state(&saved,{})
    testing.expect(t,built)
    if built {
        defer acp_runtime_destroy(restored)
        testing.expect(t,restored.d.error=="acp_protocol_error" && !restored.d.auth_required && !restored.d.ready && acp_runtime_terminal_error(&restored.d),"corruption is terminal even when the old journal waited for authentication")
    }
}

t5_buffer_growths:int
t5_publish_status:int
t5_publish_relay :: proc(path:[]string,method,params:string,rec:Bridge_Local_Agent_Token_Record,timeout_ms:int) -> Bridge_Local_Relay_Result {
    return {ok=t5_publish_status==200,status=t5_publish_status,body=strings.clone(`{"error":{"message":"assistant terminal status is immutable"}}`)}
}

@(test)
t5_acp_small_chunks_use_growing_wiped_buffer_and_publish_errors_are_bounded :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    previous_records:=bridge_local_token_records
    bridge_local_token_records=make([dynamic]Bridge_Local_Agent_Token_Record,allocator=runtime.heap_allocator())
    defer {delete(bridge_local_token_records);bridge_local_token_records=previous_records}
    prev_ingest:=acp_events_ingest;prev_keys:=acp_chat_keyring;prev_relay:=acp_chat_relay
    acp_events_ingest=t5_ingest;acp_chat_keyring=t5_keyring;acp_chat_relay=t5_publish_relay;sync.atomic_store(&t5_locked,false)
    defer {acp_events_ingest=prev_ingest;acp_chat_keyring=prev_keys;acp_chat_relay=prev_relay;t5_reset_events()}
    f:T4_Runtime_Test;t5_fixture_open(&f);defer {f.r.d.stopped=true;acp_runtime_destroy(f.r);acp_test_delete(&f.f);bridge_runtime_set_status("inst_t5_events","stopped","idle")}
    testing.expect(t,acp_chat_prepare(f.r));t5_fixture_command(&f,"start");t5_buffer_growths=0
    testing.expect(t,t5_fixture_command(&f,"many-chunks"))
    testing.expect_value(t,f.r.chat.d.text,strings.repeat("é**\n",10000,context.temp_allocator))
    testing.expect(t,t5_buffer_growths<=10,"small chunks grow geometrically rather than copying the full prefix each time")
    t4_runtime_call(&f,"chat_tick");t5_publish_status=503
    testing.expect_value(t,acp_chat_publish(f.r.chat),ACP_Chat_Publication_Result.Retry)
    testing.expect_value(t,len(f.r.chat.d.outbox),1)
    // A newer coalesced terminal revision may arrive while the old HTTP request
    // is in flight. Terminal conflict settles the message regardless of revision.
    t5_fixture_command(&f,"finish")
    t5_publish_status=409
    testing.expect_value(t,acp_chat_publish(f.r.chat),ACP_Chat_Publication_Result.Terminal)
    testing.expect_value(t,len(f.r.chat.d.outbox),0)
    testing.expect(t,f.r.chat.d.remote_terminal)
    t5_fixture_command(&f,"start")
    testing.expect_value(t,f.r.chat.d.text,"")
    for b in raw_data(f.r.chat.text_buffer)[:cap(f.r.chat.text_buffer)] do testing.expect_value(t,b,byte(0))
    t5_update(&f,t,1,`{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"next reply"}}`)
    t4_runtime_call(&f,"chat_tick");t5_publish_status=400
    testing.expect_value(t,acp_chat_publish(f.r.chat),ACP_Chat_Publication_Result.Rejected)
    testing.expect_value(t,f.r.d.error,"acp_chat_publish_rejected")
    testing.expect(t,f.r.chat.d.publication_failed)
    testing.expect(t,!t4_runtime_call(&f,"chat_tick"),"a permanent rejection must not keep retrying or silently stall the queue")
    saved,valid:=acp_state_decode(f.f.snapshot);defer acp_state_delete(&saved)
    testing.expect(t,valid && strings.contains(saved.chat_outbox_json,`"publication_failed":true`) && strings.contains(saved.runtime_json,"acp_chat_publish_rejected"))
    for status in ([]int{0,408,429,500,503}) do testing.expect_value(t,acp_chat_publication_result({status=status}),ACP_Chat_Publication_Result.Retry)
    for status in ([]int{400,401,403,404,409,422}) do testing.expect_value(t,acp_chat_publication_result({status=status}),ACP_Chat_Publication_Result.Rejected)
}
