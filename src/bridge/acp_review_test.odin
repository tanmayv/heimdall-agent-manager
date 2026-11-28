package main

import contracts "odin_test:contracts"

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

t5_tool_event_count :: proc(event,id:string) -> int {
    count:=0
    event_field:=fmt.tprintf("\"event\":\"%s\"",event)
    id_field:=fmt.tprintf("\"use_id\":\"%s\"",id)
    for raw in t5_events {
        if strings.contains(raw,event_field) && strings.contains(raw,id_field) do count+=1
    }
    return count
}

@(test)
t5_acp_parallel_large_tools_degrade_payload_without_failing_turn :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    prev:=acp_events_ingest;acp_events_ingest=t5_ingest;defer {acp_events_ingest=prev;t5_reset_events()}
    c:ACP_RPC_Client;r:=ACP_Runtime{client=&c,session="parallel",provider="claude"}
    defer {context.allocator=runtime.heap_allocator();acp_tools_destroy(&r);acp_state_delete(&c.state);delete(r.d.error)}
    input:=strings.repeat("i",30000,context.temp_allocator)
    content:=strings.repeat("c",50000,context.temp_allocator)
    legacy:=make([dynamic]ACP_Tool_State,allocator=context.temp_allocator)
    // Sixteen concurrent ~80 KB Writes exceed even the input-only estimate,
    // exercising both degradation stages while keeping every tool open.
    for i in 0..<16 {
        update:=acp_event_object(fmt.tprintf("{{\"toolCallId\":\"write-%d\",\"name\":\"Write\",\"status\":\"pending\",\"rawInput\":{{\"content\":\"%s\"}},\"content\":[{{\"type\":\"text\",\"text\":\"%s\"}}]}}",i,input,content))
        append(&legacy,ACP_Tool_State{id=fmt.tprintf("write-%d",i),name="Write",status="pending",started=true,input=acp_event_json(update["rawInput"]),content=acp_event_json(update["content"])})
        acp_events_tool(&r,update);acp_events_tool(&r,update)
        testing.expect_value(t,r.d.error,"")
        testing.expect_value(t,r.tools.active,i+1)
        testing.expect(t,r.tools.bytes<=ACP_TOOLS_JOURNAL_MAX)
    }
    dropped_input:=false
    for _,tool in r.tools.entries {
        if tool.input=="" && tool.payload_truncated do dropped_input=true
        testing.expect(t,tool.name=="Write" && tool.started && !tool.ended)
    }
    testing.expect(t,dropped_input,"input is discarded only after output/content cannot satisfy the budget")
    testing.expect(t,acp_tools_checkpoint(&r,&c.state))
    restored:=ACP_Runtime{client=&c,session="parallel",provider="claude"};defer acp_tools_destroy(&restored)
    // Recover a well-formed older journal that predates payload degradation.
    testing.expect(t,acp_tools_prepare(&restored,acp_event_json(legacy)))
    testing.expect_value(t,restored.tools.active,16)
    testing.expect(t,restored.tools.bytes<=ACP_TOOLS_JOURNAL_MAX)
    for i in 0..<16 {
        id:=fmt.tprintf("write-%d",i)
        update:=acp_event_object(fmt.tprintf("{{\"toolCallId\":\"%s\",\"status\":\"completed\"}}",id))
        acp_events_tool(&restored,update);acp_events_tool(&restored,update)
        testing.expect_value(t,t5_tool_event_count("tool.start",id),1)
        testing.expect_value(t,t5_tool_event_count("tool.end",id),1)
    }
    testing.expect_value(t,restored.d.error,"")
    testing.expect_value(t,restored.tools.active,0)
    truncated_ends:=0
    for raw in t5_events do if strings.contains(raw,`"telemetry_truncated":true`) do truncated_ends+=1
    testing.expect(t,truncated_ends>0,"terminal telemetry identifies discarded payload detail")
    testing.expect(t,acp_tools_checkpoint(&restored,&c.state))
}

@(test)
t5_acp_unfinished_tools_close_on_turn_end_and_capacity_is_nonfatal :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    prev:=acp_events_ingest;acp_events_ingest=t5_ingest;defer {acp_events_ingest=prev;t5_reset_events()}
    c:ACP_RPC_Client;r:=ACP_Runtime{client=&c,session="cancel",provider="claude"}
    defer {context.allocator=runtime.heap_allocator();acp_tools_destroy(&r);acp_state_delete(&c.state);delete(r.d.error)}
    for turn in 0..<180 {
        for i in 0..<4 {
            acp_events_tool(&r,acp_event_object(fmt.tprintf("{{\"toolCallId\":\"turn-%d-%d\",\"name\":\"Bash\",\"status\":\"in_progress\"}}",turn,i)))
        }
        result:=`{"stopReason":"cancelled"}`;error:=""
        if turn%3==1 { result="";error="acp_rpc_failed" }
        if turn%3==2 do result=`{"stopReason":"end_turn"}`
        acp_events_prompt_finished(&r,"input",result,error)
        acp_events_prompt_finished(&r,"input",result,error)
        testing.expect_value(t,r.tools.active,0)
        for i in 0..<4 {
            id:=fmt.tprintf("turn-%d-%d",turn,i)
            acp_events_tool(&r,acp_event_object(fmt.tprintf("{{\"toolCallId\":\"%s\",\"status\":\"completed\"}}",id)))
            testing.expect_value(t,t5_tool_event_count("tool.start",id),1)
            testing.expect_value(t,t5_tool_event_count("tool.end",id),1)
        }
        testing.expect_value(t,r.d.error,"")
        testing.expect(t,len(r.tools.entries)<=ACP_TOOLS_RECENT_MAX && acp_tools_checkpoint(&r,&c.state))
    }
    for reason in ([]string{"cancelled","acp_rpc_failed","end_turn"}) {
        found:=false
        for raw in t5_events do if strings.contains(raw,fmt.tprintf("\"stop_reason\":\"%s\"",reason)) && strings.contains(raw,`"outcome":"failure"`) do found=true
        testing.expect(t,found,"orphan tool ends retain the cancellation, failure or completion reason")
    }
    // A partial record with no status emitted no start. Once its turn ends,
    // a late terminal update must not invent an unmatched new start.
    acp_events_tool(&r,acp_event_object(`{"toolCallId":"never-started","name":"Bash"}`))
    acp_events_prompt_finished(&r,"input",`{"stopReason":"cancelled"}`,"")
    acp_events_tool(&r,acp_event_object(`{"toolCallId":"never-started","status":"completed"}`))
    testing.expect_value(t,t5_tool_event_count("tool.start","never-started"),0)
    testing.expect_value(t,t5_tool_event_count("tool.end","never-started"),0)
    testing.expect_value(t,r.tools.active,0)
    t5_reset_events()
    for i in 0..<520 {
        acp_events_tool(&r,acp_event_object(fmt.tprintf("{{\"toolCallId\":\"capacity-%d\",\"name\":\"Bash\",\"status\":\"pending\"}}",i)))
        testing.expect(t,r.tools.active<=ACP_TOOLS_ACTIVE_MAX && r.d.error=="")
    }
    acp_events_prompt_finished(&r,"input",`{"stopReason":"cancelled"}`,"")
    testing.expect_value(t,r.tools.active,0)
    for i in 0..<520 {
        id:=fmt.tprintf("capacity-%d",i)
        testing.expect_value(t,t5_tool_event_count("tool.start",id),1)
        testing.expect_value(t,t5_tool_event_count("tool.end",id),1)
    }
    testing.expect(t,len(r.tools.entries)<=ACP_TOOLS_RECENT_MAX && acp_tools_checkpoint(&r,&c.state))
    testing.expect_value(t,r.d.error,"")
}

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
    saved:=ACP_State{schema_version=3,runtime_binding_version=1,binding=acp_provider_binding(contracts.ACP_CLAUDE_DESCRIPTOR,"claude","2.1.70","CLAUDE.md"),profile="claude",bridge=bridge_config.daemon_id,adapter_version=ACP_CLAUDE_VERSION,provider="claude",run_dir=run_dir,pipe_generation="generation",selected_mode="default",instance="inst_t5_corrupt_restore",launch_epoch="epoch",tool_map_json=c.state.tool_map_json,
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
    return {ok=t5_publish_status==200,status=t5_publish_status,body=strings.clone(`{"error":{"message":"rejected"}}`)}
}

@(test)
t5_acp_small_chunks_use_growing_wiped_buffer_and_publish_errors_are_bounded :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    reports:=acp_delivery_reports_enabled;acp_delivery_reports_enabled=false;defer acp_delivery_reports_enabled=reports
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
    // is in flight. The old revision's receipt cannot drop the newer one.
    t5_fixture_command(&f,"finish")
    t5_publish_status=200
    testing.expect_value(t,acp_chat_publish(f.r.chat),ACP_Chat_Publication_Result.Saved)
    testing.expect_value(t,len(f.r.chat.d.outbox),1)
    t4_runtime_call(&f,"chat_tick")
    testing.expect_value(t,acp_chat_publish(f.r.chat),ACP_Chat_Publication_Result.Saved)
    testing.expect_value(t,len(f.r.chat.d.outbox),0)
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
