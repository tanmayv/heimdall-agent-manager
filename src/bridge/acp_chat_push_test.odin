package main

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"

@(test)
t13_acp_input_edges_idle_60_seconds_and_reconnect :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    previous:=acp_runtimes
    acp_runtimes=make(map[string]^ACP_Runtime,allocator=runtime.heap_allocator())
    defer {delete(acp_runtimes);acp_runtimes=previous}
    chat,other,stopped:ACP_Chat
    stopped.stop=true
    r:=ACP_Runtime{chat=&chat};r2:=ACP_Runtime{chat=&other};r3:=ACP_Runtime{chat=&stopped}
    acp_runtimes["live"]=&r;acp_runtimes["other"]=&r2;acp_runtimes["stopped"]=&r3
    // Advance the same worker decision through 60 seconds of idle 50ms ticks.
    for now:i64=0;now<=60000;now+=50 do testing.expect(t,!acp_chat_fetch_due(&chat,now),"idle must issue zero reads")
    testing.expect(t,acp_chat_notify("live"))
    testing.expect(t,acp_chat_fetch_due(&chat,60050),"a push is due on the next 50ms tick")
    // A push arriving during an in-flight drain must survive success.
    testing.expect(t,acp_chat_notify("live"))
    acp_chat_fetch_finished(&chat,true,60060)
    testing.expect(t,acp_chat_fetch_due(&chat,60100))
    acp_chat_fetch_finished(&chat,true,60100)
    testing.expect(t,!acp_chat_fetch_due(&chat,120000))
    acp_chat_fetch_finished(&chat,false,120001)
    // Messages missed while disconnected get one coalesced drain per live chat.
    acp_chat_hub_reconnected();acp_chat_hub_reconnected()
    testing.expect(t,acp_chat_fetch_due(&chat,120050) && acp_chat_fetch_due(&other,120050))
    testing.expect(t,!sync.atomic_load(&stopped.fetch))
    acp_chat_fetch_finished(&chat,true,120050);acp_chat_fetch_finished(&other,true,120050)
    testing.expect(t,!acp_chat_fetch_due(&chat,180100) && !acp_chat_fetch_due(&other,180100))
}

@(test)
t13_acp_input_failure_backoff_caps_and_resets :: proc(t:^testing.T) {
    chat:=ACP_Chat{fetch=true}
    now:i64=100
    testing.expect(t,acp_chat_fetch_due(&chat,now))
    for delay in ([]i64{1000,2000,4000,8000,16000,30000,30000}) {
        acp_chat_fetch_finished(&chat,false,now)
        testing.expect_value(t,chat.input_retry_after,now+delay)
        testing.expect(t,!acp_chat_fetch_due(&chat,now+delay-1))
        now+=delay
        testing.expect(t,acp_chat_fetch_due(&chat,now))
    }
    acp_chat_fetch_finished(&chat,true,now)
    testing.expect(t,!acp_chat_fetch_due(&chat,now+60000),"success stops failure retries")
    sync.atomic_store(&chat.fetch,true)
    testing.expect(t,acp_chat_fetch_due(&chat,now+60050))
    acp_chat_fetch_finished(&chat,false,now+60050)
    testing.expect_value(t,chat.input_retry_delay,i64(1000))
    sync.atomic_store(&chat.fetch,true)
    testing.expect(t,acp_chat_fetch_due(&chat,now+60051),"fresh pushes bypass the old failure deadline")
}

t13_reads:int
t13_bad_source:bool
t13_malformed:bool
t13_input_relay :: proc(path:[]string,method,params:string,rec:Bridge_Local_Agent_Token_Record,timeout_ms:int) -> Bridge_Local_Relay_Result {
    obj:=acp_event_object(params)
    if acp_event_string(obj,"input_source")!=contracts.ACP_CHAT_INPUT_SOURCE do sync.atomic_store(&t13_bad_source,true)
    sync.atomic_add(&t13_reads,1)
    return {ok=true,status=200,body=strings.clone(`{"data":{"messages":[]}}` if !t13_malformed else `{"data":{}}`)}
}

@(test)
t13_acp_worker_push_and_reconnect_fetch_within_one_second :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    previous_records:=bridge_local_token_records;previous_owners:=acp_runtimes
    bridge_local_token_records=make([dynamic]Bridge_Local_Agent_Token_Record,allocator=runtime.heap_allocator())
    acp_runtimes=make(map[string]^ACP_Runtime,allocator=runtime.heap_allocator())
    defer {delete(bridge_local_token_records);bridge_local_token_records=previous_records;delete(acp_runtimes);acp_runtimes=previous_owners}
    prev_keys:=acp_chat_keyring;prev_relay:=acp_chat_relay
    acp_chat_keyring=t5_keyring;acp_chat_relay=t13_input_relay;sync.atomic_store(&t5_locked,false)
    defer {acp_chat_keyring=prev_keys;acp_chat_relay=prev_relay;t13_malformed=false}
    f:T4_Runtime_Test;t5_fixture_open(&f)
    defer {delete_key(&acp_runtimes,f.r.instance);f.r.d.stopped=true;acp_runtime_destroy(f.r);acp_test_delete(&f.f);bridge_runtime_set_status("inst_t5_events","stopped","idle")}
    testing.expect(t,acp_chat_prepare(f.r))
    // A malformed HTTP 200 is a failure, so it cannot strand an unread inbox.
    t13_malformed=true
    testing.expect(t,!acp_chat_fetch_inputs(f.r.chat))
    t13_malformed=false;sync.atomic_store(&t13_reads,0);sync.atomic_store(&t13_bad_source,false)
    acp_runtimes[f.r.instance]=f.r
    acp_chat_run(f.r)
    for expected in 1..=3 {
        started:=time.tick_now()
        for sync.atomic_load(&t13_reads)<expected && time.tick_since(started)<time.Second do time.sleep(time.Millisecond)
        testing.expect_value(t,sync.atomic_load(&t13_reads),expected)
        testing.expect(t,time.tick_since(started)<time.Second,"launch/push/reconnect drain starts within 1s")
        time.sleep(150*time.Millisecond)
        testing.expect_value(t,sync.atomic_load(&t13_reads),expected)
        when #config(ACP_CHAT_IDLE_SOAK,false) {
            // Opt-in wall-clock proof in addition to the fast virtual-time test.
            if expected==1 {
                testing.set_fail_timeout(t,90*time.Second)
                time.sleep(61*time.Second)
                testing.expect(t,sync.atomic_load(&t13_reads)==1,"61 idle seconds must add zero reads")
            }
        }
        if expected==1 do testing.expect(t,acp_chat_notify(f.r.instance))
        if expected==2 do acp_chat_hub_reconnected()
    }
    acp_chat_stop(f.r)
    testing.expect(t,!sync.atomic_load(&t13_bad_source),"only the ACP drain supplies its explicit source")
}
