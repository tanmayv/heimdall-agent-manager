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

T9_OPTIONS :: `[{"optionId":"persistent-allow","kind":"allow_always"},{"optionId":"opaque-yes-123","kind":"allow_once"},{"optionId":"persistent-deny","kind":"reject_always"},{"optionId":"opaque-no-456","kind":"reject_once"}]`

t9_inbound :: proc(data: rawptr, id, method, params: string) -> bool {
    f := cast(^T4_Runtime_Test)data
    return acp_runtime_inbound(f.r, id, method, params)
}
t9_timeout :: proc(data: rawptr, id: string) { f := cast(^T4_Runtime_Test)data; acp_permission_timeout(f.r, id) }
t9_notification :: proc(data: rawptr, method, params: string) {
    f := cast(^T4_Runtime_Test)data
    acp_test_notification(&f.f, method, params)
}
t9_fixture_open :: proc(f: ^T4_Runtime_Test, instance: string) {
    t4_runtime_open(f, instance, "/unused/bootstrap")
    acp_runtime_replace(&f.r.session, "s")
    acp_runtime_replace(&f.r.d.phase, "ready")
    f.r.d.ready = true; f.r.d.starter_sent = true
    f.r.client.io.now_ms = acp_test_clock
    sync.atomic_store(&f.f.clock, 1000000)
    f.r.client.callbacks.inbound_request = t9_inbound
    f.r.client.callbacks.inbound_timeout = t9_timeout
    f.r.client.callbacks.notification = t9_notification
}
t9_fixture_close :: proc(f: ^T4_Runtime_Test) {
    instance := strings.clone(f.r.instance, context.temp_allocator)
    acp_runtime_destroy(f.r); acp_test_delete(&f.f)
    bridge_permission_test_reset(instance)
}
t9_permission :: proc(f: ^T4_Runtime_Test, t: ^testing.T, id: string, seq: u64, options := T9_OPTIONS, session := "s") {
    params := strings.concatenate({`{"sessionId":`, acp_rpc_quote(session),
        `,"toolCall":{"toolCallId":"call-1","title":"Run command","kind":"execute","rawInput":{"command":"pwd"}},"options":`, options, "}"}, context.temp_allocator)
    line := acp_rpc_envelope(id, "session/request_permission", params, "", "")
    testing.expect(t, f.r.client.io.feed(f.r.client, line, seq))
    acp_test_wait(t, &f.f, .Acks, int(seq))
}
t9_blocker :: proc(t: ^testing.T, f: ^T4_Runtime_Test, id: string) -> string {
    blocker := acp_permission_id(f.r.epoch, f.r.session, id)
    deadline := time.tick_now()._nsec + 3*i64(time.Second)
    for time.tick_now()._nsec < deadline {
        for b in bridge_blockers_list(f.r.instance) do if b.blocker_id == blocker do return blocker
        time.sleep(time.Millisecond)
    }
    testing.expect(t, false, "permission worker must register without blocking the reader")
    return blocker
}
t9_snapshot :: proc(f: ^T4_Runtime_Test) -> string {
    sync.mutex_lock(&f.f.mu); defer sync.mutex_unlock(&f.f.mu)
    return strings.clone(f.f.snapshot)
}
t9_response :: proc(t: ^testing.T, f: ^T4_Runtime_Test, index: int, id, option: string) {
    if !acp_test_wait(t, &f.f, .Writes, index+1) do return
    sync.mutex_lock(&f.f.mu); defer sync.mutex_unlock(&f.f.mu)
    root := acp_event_object(f.f.writes[index].bytes)
    testing.expect_value(t, acp_rpc_raw_id(f.f.writes[index].bytes), id)
    result, _ := root["result"].(json.Object)
    outcome, _ := result["outcome"].(json.Object)
    testing.expect_value(t, acp_event_string(outcome, "outcome"), "cancelled" if option == "" else "selected")
    testing.expect_value(t, acp_event_string(outcome, "optionId"), option)
    testing.expect_value(t, f.f.order_errors, 0)
}
t9_worker_barrier :: proc(f: ^T4_Runtime_Test) {
    // Joining outside the dispatcher is safe after the control/response settles.
    for w in f.r.permissions {
        deadline := time.tick_now()._nsec+3*i64(time.Second)
        for !sync.atomic_load(&w.done) && time.tick_now()._nsec < deadline do time.sleep(time.Millisecond)
    }
    t4_runtime_call(f, "resume")
}

@(test)
t9_acp_permission_identity_and_once_option_mapping :: proc(t: ^testing.T) {
    context.allocator = runtime.heap_allocator()
    a := acp_permission_id("epoch", "session", `"a"`); defer delete(a)
    escaped := acp_permission_id("epoch", "session", `"\u0061"`); defer delete(escaped)
    numeric := acp_permission_id("epoch", "session", "1"); defer delete(numeric)
    text := acp_permission_id("epoch", "session", `"1"`); defer delete(text)
    other := acp_permission_id("new-epoch", "session", `"a"`); defer delete(other)
    session := acp_permission_id("epoch", "other-session", `"a"`); defer delete(session)
    testing.expect(t, bridge_blocker_valid_id(a) && len(a) <= 64 && a == escaped && numeric != text && a != other && a != session)
    params := strings.concatenate({`{"toolCall":{"kind":"execute","toolCallId":"actual-call","rawInput":{"command":"pwd"}},"options":`, T9_OPTIONS, "}"}, context.temp_allocator)
    req := acp_permission_request(params, a, "claude", 1000)
    testing.expect(t, req.tool_name == "execute" && req.tool_use_id == "actual-call" && strings.contains(req.input, "pwd"))
    for decision in ([]string{"none", "stopped", "cancelled", "superseded", "timeout"}) do testing.expect_value(t, acp_permission_result(params, decision), ACP_PERMISSION_CANCELLED)
    duplicate := `{"options":[{"kind":"allow_once","optionId":"x"},{"kind":"allow_always","optionId":"x"}]}`
    testing.expect_value(t, acp_permission_result(duplicate, "allow"), ACP_PERMISSION_CANCELLED)
}

@(test)
t9_acp_permission_allow_deny_reader_progress_and_duplicate :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    previous := bridge_local_token_records
    bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record, allocator = runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records = previous }
    f: T4_Runtime_Test; t9_fixture_open(&f, "inst_t9_decisions"); defer t9_fixture_close(&f)
    t9_permission(&f, t, "7", 1)
    yes := t9_blocker(t, &f, "7"); defer delete(yes)
    t9_permission(&f, t, `"7"`, 2)
    no := t9_blocker(t, &f, `"7"`); defer delete(no)
    testing.expect(t, yes != no)
    saved := t9_snapshot(&f); defer delete(saved)
    state, valid := acp_state_decode(saved); defer acp_state_delete(&state)
    testing.expect(t, valid && len(state.pending_inbound) == 2)
    if len(state.pending_inbound) == 2 {
        testing.expect(t, state.pending_inbound[0].blocker_id == yes && strings.contains(state.pending_inbound[0].params_json, "opaque-yes-123"))
        testing.expect_value(t, state.pending_inbound[1].blocker_id, no)
    }
    t9_permission(&f, t, "7", 3)
    sync.mutex_lock(&bridge_permission_mutex)
    count := 0
    for p in bridge_permission_pending do if p.agent_instance_id == f.r.instance { count += 1; testing.expect_value(t, p.generation, 1) }
    sync.mutex_unlock(&bridge_permission_mutex)
    testing.expect_value(t, count, 2)
    testing.expect_value(t, bridge_blockers_on_extension_event(f.r.instance, contracts.Ext_Event{kind = .Activity, activity_state = "active"}, bridge_runtime_now_ms()), 0)
    testing.expect_value(t, len(bridge_blockers_list(f.r.instance)), 2)
    testing.expect(t, f.r.client.io.feed(f.r.client, acp_rpc_envelope("", "test/progress", "{}", "", ""), 4))
    testing.expect(t, acp_test_wait(t, &f.f, .Notifications, 1))
    testing.expect(t, t4_runtime_call(&f, "resume"), "control commands also remain responsive")
    frame := acp_event_json(struct{agent_instance_id, request_id, decision: string}{f.r.instance, yes, "allow"})
    testing.expect(t, bridge_ext_permission_handle_decision_frame(frame))
    t9_response(t, &f, 0, "7", "opaque-yes-123")
    testing.expect(t, bridge_permission_resolve(f.r.instance, no, "deny", ""))
    t9_response(t, &f, 1, `"7"`, "opaque-no-456")
    t9_worker_barrier(&f)
    sync.mutex_lock(&f.f.mu); testing.expect_value(t, len(f.f.writes), 2); sync.mutex_unlock(&f.f.mu)
    t9_permission(&f, t, "99", 5, session = "wrong-session")
    if acp_test_wait(t, &f.f, .Writes, 3) {
        sync.mutex_lock(&f.f.mu)
        testing.expect(t, strings.contains(f.f.writes[2].bytes, "wrong ACP session") && strings.contains(f.f.writes[2].bytes, "-32602"))
        sync.mutex_unlock(&f.f.mu)
    }
}

@(test)
t9_acp_permission_timeout_interrupt_stop_cancel_and_supersede :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    previous := bridge_local_token_records
    bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record, allocator = runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records = previous }
    for reason in ([]string{"timeout", "interrupt", "stop", "cancel", "supersede"}) {
        instance := fmt.tprintf("inst_t9_%s", reason)
        f: T4_Runtime_Test; t9_fixture_open(&f, instance)
        t9_permission(&f, t, "8", 1)
        blocker := t9_blocker(t, &f, "8")
        switch reason {
        case "timeout":
            sync.atomic_store(&f.f.clock, 1000000+600001)
            t4_runtime_call(&f, "resume")
        case "interrupt", "stop":
            testing.expect(t, t4_runtime_call(&f, reason))
        case "cancel": testing.expect(t, bridge_blockers_cancel(instance, blocker))
        case "supersede":
            context.allocator = runtime.heap_allocator()
            generation, refreshed := bridge_blockers_register_permission({request_id = strings.clone(blocker), agent_instance_id = strings.clone(instance), input = strings.clone("{}"),
                deadline_unix_ms = bridge_runtime_now_ms()+10000})
            testing.expect(t, refreshed && generation == 2)
        }
        t9_response(t, &f, 0, "8", "")
        t9_worker_barrier(&f)
        sync.mutex_lock(&f.f.mu)
        testing.expect_value(t, len(f.f.writes), 2 if reason == "interrupt" || reason == "stop" else 1)
        if len(f.f.writes) == 2 do testing.expect(t, strings.contains(f.f.writes[1].bytes, "session/cancel"), "permissions resolve before session/cancel")
        sync.mutex_unlock(&f.f.mu)
        if reason == "supersede" {
            sync.mutex_lock(&bridge_permission_mutex)
            found := false
            for p in bridge_permission_pending do if p.agent_instance_id == instance && p.request_id == blocker { found = p.generation == 2 && !p.decided }
            sync.mutex_unlock(&bridge_permission_mutex)
            testing.expect(t, found, "superseded waiter leaves the new generation intact")
        }
        delete(blocker); t9_fixture_close(&f)
    }
}

@(test)
t9_acp_permission_missing_once_never_selects_always :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    previous := bridge_local_token_records
    bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record, allocator = runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records = previous }
    for decision in ([]string{"allow", "deny"}) {
        f: T4_Runtime_Test; t9_fixture_open(&f, fmt.tprintf("inst_t9_missing_%s", decision))
        options := `[{"optionId":"only-always","kind":"allow_always"},{"optionId":"can-reject","kind":"reject_once"}]` if decision == "allow" else
            `[{"optionId":"can-allow","kind":"allow_once"},{"optionId":"only-always","kind":"reject_always"}]`
        t9_permission(&f, t, "9", 1, options)
        blocker := t9_blocker(t, &f, "9")
        testing.expect(t, bridge_permission_resolve(f.r.instance, blocker, decision, ""))
        t9_response(t, &f, 0, "9", "")
        delete(blocker); t9_fixture_close(&f)
    }
}

@(test)
t9_acp_permission_restart_reuses_blocker_and_original_reply_once :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    previous := bridge_local_token_records
    bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record, allocator = runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records = previous }
    context.allocator = runtime.heap_allocator()
    f: T4_Runtime_Test; t9_fixture_open(&f, "inst_t9_restart")
    id := `"original-\u0061"`
    t9_permission(&f, t, id, 1)
    blocker := t9_blocker(t, &f, id); defer delete(blocker)
    saved := t9_snapshot(&f); defer delete(saved)
    state, valid := acp_state_decode(saved); defer acp_state_delete(&state)
    testing.expect(t, valid)
    path := fmt.tprintf("%s/.cache/heimdall-tests/t9-journal-%d/state.json", os.get_env("HOME", context.temp_allocator), time.tick_now()._nsec)
    defer os.remove_all(path[:len(path)-len("/state.json")])
    testing.expect(t, acp_state_write(path, &state))
    acp_runtime_destroy(f.r); acp_test_delete(&f.f)
    restored, read := acp_state_read(path); defer acp_state_delete(&restored)
    testing.expect(t, read && len(restored.pending_inbound) == 1 && restored.pending_inbound[0].blocker_id == blocker && restored.pending_inbound[0].response_json == "")
    next: T4_Runtime_Test; t9_fixture_open(&next, "inst_t9_restart"); defer t9_fixture_close(&next)
    testing.expect(t, acp_rpc_restore(next.r.client, saved))
    again := t9_blocker(t, &next, id); defer delete(again)
    testing.expect_value(t, again, blocker)
    sync.mutex_lock(&next.f.mu); testing.expect_value(t, len(next.f.writes), 0); sync.mutex_unlock(&next.f.mu)
    testing.expect(t, bridge_permission_resolve(next.r.instance, blocker, "allow", ""))
    t9_response(t, &next, 0, id, "opaque-yes-123")
    t9_worker_barrier(&next)
    raw := t9_snapshot(&next); defer delete(raw)
    sync.mutex_lock(&next.f.mu)
    delivery := strings.clone(next.f.writes[0].delivery_id)
    reply := strings.clone(next.f.writes[0].bytes)
    sync.mutex_unlock(&next.f.mu)
    defer { delete(delivery); delete(reply) }
    acp_runtime_destroy(next.r); acp_test_delete(&next.f); next = {}
    t9_fixture_open(&next, "inst_t9_restart")
    testing.expect(t, acp_rpc_restore(next.r.client, raw))
    t9_response(t, &next, 0, id, "opaque-yes-123")
    sync.mutex_lock(&next.f.mu)
    testing.expect(t, next.f.writes[0].delivery_id == delivery && next.f.writes[0].bytes == reply, "an unreceipted response retries with daemon dedup identity")
    sync.mutex_unlock(&next.f.mu)
    testing.expect_value(t, len(bridge_blockers_list(next.r.instance)), 0)
}

@(test)
t9_acp_permission_decision_waits_for_vault_and_detach_does_not_deadlock :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    previous := bridge_local_token_records
    bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record, allocator = runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records = previous }
    keys := acp_chat_keyring; acp_chat_keyring = t5_keyring; sync.atomic_store(&t5_locked, false)
    defer { acp_chat_keyring = keys; sync.atomic_store(&t5_locked, false) }
    f: T4_Runtime_Test; t9_fixture_open(&f, "inst_t9_vault"); defer t9_fixture_close(&f)
    testing.expect(t, acp_chat_prepare(f.r))
    t9_permission(&f, t, "10", 1)
    blocker := t9_blocker(t, &f, "10"); defer delete(blocker)
    sync.atomic_store(&t5_locked, true)
    testing.expect(t, bridge_permission_resolve(f.r.instance, blocker, "allow", ""))
    // Let the worker consume the decision while the journal is unavailable.
    deadline := time.tick_now()._nsec+3*i64(time.Second)
    for len(bridge_blockers_list(f.r.instance)) != 0 && time.tick_now()._nsec < deadline do time.sleep(time.Millisecond)
    time.sleep(60*time.Millisecond)
    testing.expect(t, t4_runtime_call(&f, "resume"), "dispatcher remains available during vault lock")
    sync.mutex_lock(&f.f.mu)
    testing.expect_value(t, len(f.f.writes), 0)
    sync.mutex_unlock(&f.f.mu)
    sync.atomic_store(&t5_locked, false)
    t9_response(t, &f, 0, "10", "opaque-yes-123")
    t9_worker_barrier(&f)
    t9_permission(&f, t, "11", 2)
    blocker2 := t9_blocker(t, &f, "11"); defer delete(blocker2)
    sync.atomic_store(&t5_locked, true)
    testing.expect(t, bridge_permission_resolve(f.r.instance, blocker2, "deny", ""))
    // Teardown must quiesce and join even when an outcome is waiting on unlock.
    acp_runtime_destroy(f.r); acp_test_delete(&f.f); f = {}
    sync.atomic_store(&t5_locked, false)
    t9_fixture_open(&f, "inst_t9_vault")
}
