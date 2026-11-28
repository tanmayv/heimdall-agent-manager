package main

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:testing"
import vault "odin_test:lib/vault"

// G12: thoughts and plans stream like assistant text. Each kind is one sealed
// snapshot in the outbox (relayed live by the Hub, never stored); the prompt
// end re-sends them with the turn's terminal status so the UI can close it.
@(test)
g12_acp_thoughts_and_plan_stream_as_sealed_snapshots :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    reports:=acp_delivery_reports_enabled;acp_delivery_reports_enabled=false;defer acp_delivery_reports_enabled=reports
    previous_records:=bridge_local_token_records
    bridge_local_token_records=make([dynamic]Bridge_Local_Agent_Token_Record,allocator=runtime.heap_allocator())
    defer {delete(bridge_local_token_records);bridge_local_token_records=previous_records}
    prev_ingest:=acp_events_ingest;prev_keys:=acp_chat_keyring
    acp_events_ingest=t5_ingest;acp_chat_keyring=t5_keyring;sync.atomic_store(&t5_locked,false)
    defer {acp_events_ingest=prev_ingest;acp_chat_keyring=prev_keys;t5_reset_events()}
    f:T4_Runtime_Test;t5_fixture_open(&f);defer {f.r.d.stopped=true;acp_runtime_destroy(f.r);acp_test_delete(&f.f);bridge_runtime_set_status("inst_t5_events","stopped","idle")}
    testing.expect(t,acp_chat_prepare(f.r));t5_fixture_command(&f,"start")
    t5_update(&f,t,1,`{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"thinking "}}`)
    t5_update(&f,t,2,`{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"harder"}}`)
    t5_update(&f,t,3,`{"sessionUpdate":"plan","entries":[{"content":"step one","status":"pending","priority":"high"}]}`)
    f.r.chat.last_aux_flush=0
    testing.expect(t,t4_runtime_call(&f,"chat_tick"))
    find :: proc(f:^T4_Runtime_Test,kind:string) -> (int,bool) {
        for entry,i in f.r.chat.d.outbox do if entry.kind==kind do return i,true
        return -1,false
    }
    kr,_:=t5_keyring();defer vault.keyring_wipe(&kr)
    thought,has_thought:=find(&f,ACP_CHAT_KIND_THOUGHT)
    plan,has_plan:=find(&f,ACP_CHAT_KIND_PLAN)
    testing.expect(t,has_thought && has_plan,"one snapshot per kind")
    if !has_thought || !has_plan do return
    entry:=f.r.chat.d.outbox[thought]
    testing.expect(t,entry.revision==1 && entry.message_status=="pending" && strings.has_prefix(entry.message_id,"msg_") && len(entry.message_id)==20)
    testing.expect_value(t,entry.turn_id,f.r.chat.d.turn_id)
    opened,ok:=bridge_vault_decrypt_field(entry.body,&kr,context.temp_allocator)
    testing.expect(t,ok && opened=="thinking harder","thought text is sealed, accumulated per turn")
    testing.expect(t,!strings.contains(entry.body,"thinking"),"never plaintext in the outbox")
    opened,ok=bridge_vault_decrypt_field(f.r.chat.d.outbox[plan].body,&kr,context.temp_allocator)
    testing.expect(t,ok && strings.contains(opened,"step one"))
    // An unchanged tick creates no new revision.
    f.r.chat.last_aux_flush=0
    testing.expect(t,t4_runtime_call(&f,"chat_tick"))
    testing.expect_value(t,f.r.chat.d.outbox[thought].revision,i64(1))
    t5_fixture_command(&f,"finish")
    thought,_=find(&f,ACP_CHAT_KIND_THOUGHT);plan,_=find(&f,ACP_CHAT_KIND_PLAN)
    for i in ([]int{thought,plan}) {
        e:=f.r.chat.d.outbox[i]
        testing.expectf(t,e.revision==2 && e.message_status=="complete" && e.stop_reason=="end_turn","%s carries the terminal status: %v",e.kind,e)
    }
    // Thoughts after the turn ended are not captured; a new turn starts empty.
    t5_update(&f,t,4,`{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"late"}}`)
    testing.expect_value(t,f.r.chat.d.thought_text,"thinking harder")
    t5_fixture_command(&f,"start")
    testing.expect(t,f.r.chat.d.thought_text=="" && f.r.chat.d.plan_text=="" && f.r.chat.d.thought_revision==0)
}
