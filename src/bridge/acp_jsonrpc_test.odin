package main

import "base:runtime"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import vm "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"

ACP_Test :: struct {
    mu: sync.Mutex,
    cond: sync.Cond,
    client: ^ACP_RPC_Client,
    snapshot: string,
    writes: [dynamic]ACP_RPC_Write,
    acks: [dynamic]u64,
    results: [dynamic]ACP_RPC_Result,
    frames: [dynamic]ACP_RPC_Frame,
    inbound_ids: [dynamic]string,
    notification_params: [dynamic]string,
    restored_roles: [dynamic]ACP_RPC_Role,
    faults: int,
    fault_reasons: [dynamic]string,
    unknown: int,
    checkpoints: int,
    order_errors: int,
    callback_thread: int,
    writer_thread: int,
    closed: bool,
    checkpoint_fail: bool,
    write_fail: bool,
    reentrant: bool,
    handle_permission: bool,
    clock: i64,
}
ACP_Test_Count :: enum { Writes, Acks, Results, Inbound, Notifications, Faults, Unknown, Checkpoints }

acp_test_open :: proc(f: ^ACP_Test, reader: bool = false, state_path: string = "", policy: ACP_RPC_Policy = ACP_RPC_POLICY_ACP) -> ^ACP_RPC_Client {
    sync.atomic_store(&f.clock, 1000000)
    io := ACP_RPC_IO{data = f, instance = "inst_test_acp", launch_epoch = "epoch_test", state_path = state_path,
        write = acp_test_write, ack = acp_test_ack, close = acp_test_close, now_ms = acp_test_clock}
    if reader do io.read = acp_test_read
    c, ok := acp_rpc_open(io, {data = f, checkpoint = acp_test_checkpoint, notification = acp_test_notification,
        inbound_request = acp_test_inbound, fault = acp_test_fault, restore_completion = acp_test_restore_completion, unknown_response = acp_test_unknown}, policy)
    if !ok do return nil
    f.client = c
    return c
}
acp_test_delete :: proc(f: ^ACP_Test) {
    context.allocator = runtime.heap_allocator()
    delete(f.snapshot)
    for w in f.writes { delete(w.bytes); delete(w.delivery_id) }; delete(f.writes)
    for r in f.results do acp_rpc_result_delete(r)
    delete(f.results); delete(f.acks); delete(f.restored_roles)
    for reason in f.fault_reasons do delete(reason)
    delete(f.fault_reasons)
    for frame in f.frames do delete(frame.bytes)
    delete(f.frames)
    for id in f.inbound_ids do delete(id)
    delete(f.inbound_ids)
    for params in f.notification_params do delete(params)
    delete(f.notification_params)
}
acp_test_clock :: proc(data: rawptr) -> i64 { f := cast(^ACP_Test)data; return sync.atomic_load(&f.clock) }
acp_test_completion :: proc(f: ^ACP_Test) -> ACP_RPC_Completion { return {data = f, callback = acp_test_complete} }
acp_test_checkpoint :: proc(data: rawptr, state: ^ACP_State) -> bool {
    f := cast(^ACP_Test)data
    sync.mutex_lock(&f.mu); defer sync.mutex_unlock(&f.mu)
    if f.checkpoint_fail do return false
    raw, err := json.marshal(state^)
    if err != nil do return false
    delete(f.snapshot); f.snapshot = string(raw)
    f.checkpoints += 1; sync.cond_broadcast(&f.cond)
    return true
}
acp_test_write :: proc(data: rawptr, bytes, delivery_id: string) -> bool {
    f := cast(^ACP_Test)data
    sync.mutex_lock(&f.mu); defer sync.mutex_unlock(&f.mu)
    f.writer_thread = sync.current_thread_id()
    s, ok := acp_state_decode(f.snapshot)
    found := false
    if ok {
        for w in s.pending_writes { if w.delivery_id == delivery_id && w.bytes == bytes do found = true }
        acp_state_delete(&s)
    }
    if !ok || !found do f.order_errors += 1
    append(&f.writes, ACP_RPC_Write{strings.clone(delivery_id), strings.clone(bytes)})
    sync.cond_broadcast(&f.cond)
    return !f.closed && !f.write_fail
}
acp_test_ack :: proc(data: rawptr, seq: u64) -> bool {
    f := cast(^ACP_Test)data
    sync.mutex_lock(&f.mu); defer sync.mutex_unlock(&f.mu)
    s, ok := acp_state_decode(f.snapshot)
    if !ok || s.last_stdout_seq < seq do f.order_errors += 1
    if ok do acp_state_delete(&s)
    append(&f.acks, seq); sync.cond_broadcast(&f.cond)
    return !f.closed
}
acp_test_read :: proc(data: rawptr) -> (ACP_RPC_Frame, bool) {
    f := cast(^ACP_Test)data
    sync.mutex_lock(&f.mu); defer sync.mutex_unlock(&f.mu)
    for !f.closed && len(f.frames) == 0 do sync.cond_wait(&f.cond, &f.mu)
    if f.closed do return {}, false
    frame := f.frames[0]; ordered_remove(&f.frames, 0); return frame, true
}
acp_test_close :: proc(data: rawptr) {
    f := cast(^ACP_Test)data
    sync.mutex_lock(&f.mu); defer sync.mutex_unlock(&f.mu)
    f.closed = true; sync.cond_broadcast(&f.cond)
}
acp_test_fault :: proc(data: rawptr, reason: string) {
    defer delete(reason, runtime.heap_allocator())
    f := cast(^ACP_Test)data
    sync.mutex_lock(&f.mu); defer sync.mutex_unlock(&f.mu)
    f.faults += 1; sync.cond_broadcast(&f.cond)
    append(&f.fault_reasons, strings.clone(reason))
}
acp_test_unknown :: proc(data: rawptr, id: string) {
    defer delete(id, runtime.heap_allocator())
    f := cast(^ACP_Test)data
    sync.mutex_lock(&f.mu); defer sync.mutex_unlock(&f.mu)
    f.unknown += 1; sync.cond_broadcast(&f.cond)
}
acp_test_complete :: proc(data: rawptr, result: ACP_RPC_Result) {
    f := cast(^ACP_Test)data
    // Exercises reentrant API use. A pending-map lock around callbacks would
    // deadlock here; a runtime worker must never hold its global lock either.
    if f.reentrant && result.ok do acp_rpc_notify(f.client, "session/cancel", "{}")
    sync.mutex_lock(&f.mu); defer sync.mutex_unlock(&f.mu)
    f.callback_thread = sync.current_thread_id()
    append(&f.results, result); sync.cond_broadcast(&f.cond)
}
acp_test_restore_completion :: proc(data: rawptr, role: ACP_RPC_Role, id: ACP_RPC_ID) -> ACP_RPC_Completion {
    defer delete(string(id), runtime.heap_allocator())
    f := cast(^ACP_Test)data
    sync.mutex_lock(&f.mu); defer sync.mutex_unlock(&f.mu)
    append(&f.restored_roles, role)
    return acp_test_completion(f)
}
acp_test_inbound :: proc(data: rawptr, id, method, params: string) -> bool {
    context.allocator = runtime.heap_allocator()
    defer delete(method); defer delete(params)
    f := cast(^ACP_Test)data
    sync.mutex_lock(&f.mu); defer sync.mutex_unlock(&f.mu)
    append(&f.inbound_ids, id); sync.cond_broadcast(&f.cond)
    return f.handle_permission && method == "session/request_permission"
}
acp_test_notification :: proc(data: rawptr, method, params: string) {
    defer delete(method, runtime.heap_allocator())
    f := cast(^ACP_Test)data
    sync.mutex_lock(&f.mu); defer sync.mutex_unlock(&f.mu)
    append(&f.notification_params, params); sync.cond_broadcast(&f.cond)
}
acp_test_count :: proc(f: ^ACP_Test, which: ACP_Test_Count) -> int {
    switch which {
    case .Writes: return len(f.writes)
    case .Acks: return len(f.acks)
    case .Results: return len(f.results)
    case .Inbound: return len(f.inbound_ids)
    case .Notifications: return len(f.notification_params)
    case .Faults: return f.faults
    case .Unknown: return f.unknown
    case .Checkpoints: return f.checkpoints
    }
    return 0
}
acp_test_wait :: proc(t: ^testing.T, f: ^ACP_Test, which: ACP_Test_Count, count: int) -> bool {
    start := time.tick_now()
    sync.mutex_lock(&f.mu)
    for acp_test_count(f, which) < count && time.tick_since(start) < 5*time.Second do sync.cond_wait_with_timeout(&f.cond, &f.mu, 20*time.Millisecond)
    got := acp_test_count(f, which)
    sync.mutex_unlock(&f.mu)
    return testing.expectf(t, got >= count, "%v: expected >=%d, got %d", which, count, got)
}
acp_test_snapshot :: proc(f: ^ACP_Test) -> string {
    sync.mutex_lock(&f.mu); defer sync.mutex_unlock(&f.mu)
    return strings.clone(f.snapshot, context.allocator)
}
acp_test_response :: proc(id: ACP_RPC_ID, result: string) -> string {
    return strings.concatenate({`{"jsonrpc":"2.0","id":`, acp_rpc_quote(string(id)), `,"result":`, result, "}\n"}, context.temp_allocator)
}

@(test)
acp_rpc_split_utf8_multiline_interleaved_and_reentrant :: proc(t: ^testing.T) {
    f: ACP_Test; f.reentrant = true
    defer acp_test_delete(&f)
    c := acp_test_open(&f); if !testing.expect(t, c != nil) do return
    defer acp_rpc_close(c)
    one, ok := acp_rpc_request(c, "initialize", "{}", 0, acp_test_completion(&f)); testing.expect(t, ok)
    defer delete(string(one), runtime.heap_allocator())
    two, ok2 := acp_rpc_request(c, "session/new", "{}", 0, acp_test_completion(&f)); testing.expect(t, ok2)
    defer delete(string(two), runtime.heap_allocator())
    message := strings.concatenate({`{"jsonrpc":"2.0","method":"session/update","params":{"text":"A🌍B\nC"}}`, "\n", acp_test_response(two, `{"sessionId":"s"}`), acp_test_response(one, `{"protocolVersion":1}`)}, context.temp_allocator)
    split := strings.index(message, "🌍")+2
    testing.expect(t, c.io.feed(c, message[:split], 1))
    acp_test_wait(t, &f, .Acks, 1)
    raw := acp_test_snapshot(&f); defer delete(raw)
    s, valid := acp_state_decode(raw); testing.expect(t, valid)
    if valid {
        partial, _ := base64.decode(s.partial_line_base64); defer delete(partial)
        testing.expect_value(t, string(partial), message[:split]); acp_state_delete(&s)
    }
    testing.expect(t, c.io.feed(c, message[split:], 2))
    if !acp_test_wait(t, &f, .Acks, 2) do return
    sync.mutex_lock(&f.mu); defer sync.mutex_unlock(&f.mu)
    testing.expect_value(t, len(f.results), 2)
    if len(f.results) == 2 {
        testing.expect_value(t, f.results[0].id, two)
        testing.expect_value(t, f.results[1].id, one)
        testing.expect(t, f.results[0].ok && f.results[1].ok)
    }
    testing.expect_value(t, len(f.notification_params), 1)
    testing.expect_value(t, f.order_errors, 0)
    testing.expect(t, f.callback_thread != f.writer_thread && f.callback_thread != sync.current_thread_id())
}

@(test)
acp_rpc_inbound_id_isolation_duplicates_unknown_and_params :: proc(t: ^testing.T) {
    f: ACP_Test; f.handle_permission = true
    defer acp_test_delete(&f)
    c := acp_test_open(&f); defer acp_rpc_close(c)
    prompt, ok := acp_rpc_request(c, "session/prompt", "{}", 0, acp_test_completion(&f)); testing.expect(t, ok)
    defer delete(string(prompt), runtime.heap_allocator())
    frame := "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/request_permission\",\"params\":{}}\n"+
        "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"session/request_permission\",\"params\":{}}\n"+
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/request_permission\",\"params\":{}}\n"
    c.io.feed(c, frame, 1); acp_test_wait(t, &f, .Acks, 1)
    testing.expect(t, acp_rpc_reply(c, "1", `{"outcome":"numeric"}`))
    testing.expect(t, acp_rpc_reply(c, `"1"`, `{"outcome":"string"}`))
    testing.expect(t, !acp_rpc_reply(c, "1", "{}"))
    // Completed duplicate reuses response; pending duplicate creates no blocker.
    c.io.feed(c, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/request_permission\",\"params\":{}}\n"+
        "{\"jsonrpc\":\"2.0\",\"id\":2.50,\"method\":\"unknown\",\"params\":{}}\n"+
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"unknown\",\"params\":false}\n"+
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n"+
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n", 2)
    acp_test_wait(t, &f, .Acks, 2); acp_test_wait(t, &f, .Writes, 6)
    sync.mutex_lock(&f.mu); defer sync.mutex_unlock(&f.mu)
    testing.expect_value(t, len(f.inbound_ids), 3)
    testing.expect_value(t, f.unknown, 1)
    testing.expect_value(t, len(f.results), 0)
    testing.expect_value(t, f.order_errors, 0)
    if len(f.writes) >= 6 {
        testing.expect(t, strings.contains(f.writes[1].bytes, `"id":1,`))
        testing.expect(t, strings.contains(f.writes[2].bytes, `"id":"1",`))
        testing.expect_value(t, f.writes[3].bytes, f.writes[1].bytes)
        testing.expect(t, strings.contains(f.writes[4].bytes, `"id":2.50,`) && strings.contains(f.writes[4].bytes, "-32601"))
        testing.expect(t, strings.contains(f.writes[5].bytes, "-32602"))
    }
}

@(test)
acp_rpc_deadlines_prompt_cancel_and_close_once :: proc(t: ^testing.T) {
    methods := [?]string{"initialize", "session/new", "session/load", "session/set_config_option"}
    limits := [?]i64{15000, 60000, 60000, 15000}
    for method, i in methods {
        f: ACP_Test
        c := acp_test_open(&f)
        id, ok := acp_rpc_request(c, method, "{}", 0, acp_test_completion(&f)); testing.expect(t, ok)
        delete(string(id), runtime.heap_allocator())
        sync.atomic_store(&f.clock, 1000000+limits[i])
        acp_test_wait(t, &f, .Faults, 1)
        // The late response must never turn setup into success.
        c.io.feed(c, "{\"jsonrpc\":\"2.0\",\"id\":\"ham:epoch_test:1\",\"result\":{}}\n", 1)
        acp_rpc_close(c)
        testing.expect_value(t, len(f.results), 1)
        if len(f.results) == 1 do testing.expect(t, !f.results[0].ok)
        acp_test_delete(&f)
    }
    f: ACP_Test; defer acp_test_delete(&f)
    c := acp_test_open(&f, true)
    id, ok := acp_rpc_request(c, "session/prompt", "{}", 1, acp_test_completion(&f)); testing.expect(t, ok)
    defer delete(string(id), runtime.heap_allocator())
    sync.atomic_store(&f.clock, 1000000+86400000)
    // FIFO barrier ensures expiry ran after the clock jump.
    testing.expect(t, acp_rpc_notify(c, "session/update", "{}"))
    testing.expect(t, acp_rpc_notify(c, "session/cancel", "{}"))
    sync.atomic_store(&f.clock, 1000000+86400000+9999)
    testing.expect(t, acp_rpc_notify(c, "session/update", "{}"))
    sync.atomic_store(&f.clock, 1000000+86400000+10000)
    acp_test_wait(t, &f, .Faults, 1)
    acp_rpc_close(c) // wakes and joins the blocked read worker
    testing.expect_value(t, len(f.results), 1)
    testing.expect_value(t, f.faults, 1)
}

@(test)
acp_rpc_restore_partial_pending_roles_and_delivery_ids :: proc(t: ^testing.T) {
    f: ACP_Test; f.handle_permission = true
    defer acp_test_delete(&f)
    c := acp_test_open(&f)
    id, ok := acp_rpc_request(c, "session/prompt", "{}", 0, acp_test_completion(&f)); testing.expect(t, ok)
    defer delete(string(id), runtime.heap_allocator())
    response := acp_test_response(id, `{"text":"🌍"}`)
    split := strings.index(response, "🌍")+1
    c.io.feed(c, strings.concatenate({"{\"jsonrpc\":\"2.0\",\"id\":\"p\",\"method\":\"session/request_permission\",\"params\":{}}\n", response[:split]}, context.temp_allocator), 1)
    acp_test_wait(t, &f, .Acks, 1)
    raw := acp_test_snapshot(&f); defer delete(raw)
    acp_rpc_close(c)
    testing.expect_value(t, len(f.results), 1)
    f2: ACP_Test; f2.handle_permission = true
    defer acp_test_delete(&f2)
    c2 := acp_test_open(&f2, true); defer acp_rpc_close(c2)
    testing.expect(t, acp_rpc_restore(c2, raw))
    testing.expect(t, !acp_rpc_restore(c2, raw))
    if !acp_test_wait(t, &f2, .Writes, 1) do return
    sync.mutex_lock(&f2.mu)
    testing.expect_value(t, len(f2.restored_roles), 1)
    if len(f2.restored_roles) == 1 do testing.expect_value(t, f2.restored_roles[0], ACP_RPC_Role.Prompt)
    testing.expect_value(t, f2.writes[0].delivery_id, f.writes[0].delivery_id)
    testing.expect_value(t, f2.writes[0].bytes, f.writes[0].bytes)
    sync.mutex_unlock(&f2.mu)
    c2.io.feed(c2, response[split:], 2)
    acp_test_wait(t, &f2, .Acks, 1)
    testing.expect(t, acp_rpc_reply(c2, `"p"`, "{}"))
    // Frame replay is ignored; completed request cannot run twice.
    c2.io.feed(c2, response[split:], 2)
    testing.expect(t, acp_rpc_notify(c2, "barrier", "{}"))
    sync.mutex_lock(&f2.mu); defer sync.mutex_unlock(&f2.mu)
    testing.expect_value(t, len(f2.results), 1)
    if len(f2.results) == 1 do testing.expect(t, f2.results[0].ok)
    testing.expect_value(t, len(f2.inbound_ids), 1)
    testing.expect_value(t, f2.order_errors, 0)
}

@(test)
acp_rpc_rejects_invalid_shapes_utf8_oversize_and_checkpoint_failure :: proc(t: ^testing.T) {
    bad := [?]string{
        "not json\n", "[]\n", "{\"jsonrpc\":\"1.0\",\"method\":\"x\"}\n",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{},\"error\":{}}\n",
        "{\"jsonrpc\":\"2.0\",\"id\":1}\n", "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"x\"}\n",
        "{\"jsonrpc\":\"2.0\",\"method\":false}\n", "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":\"bad\",\"message\":\"bad\"}}\n",
        "{\"jsonrpc\":\"2.0\",\"method\":\"x\",\"params\":\"\xff\"}\n",
        "{jsonrpc:'2.0',method:'x'}\n", "{\"jsonrpc\":\"2.0\",\"method\":\"x\",}\n",
        "{\"jsonrpc\":\"2.0\",\"method\":\"x\"}garbage\n",
        "{\"jsonrpc\":\"2.0\",\"method\":\"x\",\"id\":1,\"id\":2}\n",
    }
    for line in bad {
        f: ACP_Test; c := acp_test_open(&f)
        c.io.feed(c, line, 1); acp_test_wait(t, &f, .Faults, 1); acp_rpc_close(c)
        testing.expect_value(t, len(f.acks), 0)
        testing.expect_value(t, f.faults, 1); acp_test_delete(&f)
    }
    f: ACP_Test; c := acp_test_open(&f)
    chunk := make([]byte, 64*1024); defer delete(chunk)
    for &b in chunk do b = ' '
    for seq in 1..=64 { c.io.feed(c, string(chunk), u64(seq)); acp_test_wait(t, &f, .Acks, seq) }
    c.io.feed(c, "x", 65); acp_test_wait(t, &f, .Faults, 1); acp_rpc_close(c)
    testing.expect_value(t, len(f.acks), 64); acp_test_delete(&f)
    f2: ACP_Test; f2.checkpoint_fail = true; defer acp_test_delete(&f2)
    c2 := acp_test_open(&f2)
    id, ok := acp_rpc_request(c2, "initialize", "{}", 0, acp_test_completion(&f2))
    testing.expect(t, !ok && id == "")
    acp_rpc_close(c2)
    testing.expect_value(t, len(f2.writes), 0)
    testing.expect_value(t, len(f2.results), 1)
}

@(test)
acp_rpc_allocator_lifetime_close_and_receipt_checkpoint :: proc(t: ^testing.T) {
    f: ACP_Test; defer acp_test_delete(&f)
    arena: vm.Arena; _ = vm.arena_init_growing(&arena)
    saved := context.allocator
    context.allocator = vm.arena_allocator(&arena)
    c := acp_test_open(&f, true)
    id, ok := acp_rpc_request(c, strings.clone("session/prompt"), strings.clone("{}"), 0, acp_test_completion(&f))
    testing.expect(t, ok)
    context.allocator = saved
    vm.arena_destroy(&arena)
    defer delete(string(id), runtime.heap_allocator())
    if !acp_test_wait(t, &f, .Writes, 1) { acp_rpc_close(c); return }
    sync.mutex_lock(&f.mu)
    delivery := strings.clone(f.writes[0].delivery_id)
    sync.mutex_unlock(&f.mu)
    defer delete(delivery)
    acp_rpc_enqueue_frame(c, {kind = .Receipt, bytes = delivery})
    testing.expect(t, acp_rpc_notify(c, "barrier", "{}"))
    raw := acp_test_snapshot(&f); defer delete(raw)
    s, valid := acp_state_decode(raw); testing.expect(t, valid)
    if valid {
        testing.expect_value(t, len(s.completed_delivery_ids), 1)
        testing.expect_value(t, len(s.pending_writes), 1)
        acp_state_delete(&s)
    }
    acp_rpc_close(c)
    testing.expect_value(t, len(f.results), 1)
    testing.expect(t, f.closed)
    testing.expect_value(t, f.order_errors, 0)
}

@(test)
acp_state_atomic_roundtrip_schema_paths_and_permissions :: proc(t: ^testing.T) {
    root := fmt.tprintf("%s/.cache/heimdall-tests/acp-state-%d", os.get_env("HOME", context.temp_allocator), time.to_unix_nanoseconds(time.now()))
    path, ok := acp_state_path(root, "inst_test_acp", "epoch_test"); testing.expect(t, ok)
    defer delete(path)
    defer os.remove_all(root)
    _, traversal := acp_state_path(root, "../outside", "epoch"); testing.expect(t, !traversal)
    f: ACP_Test; defer acp_test_delete(&f)
    c := acp_test_open(&f, false, path)
    id, requested := acp_rpc_request(c, "initialize", "{}", 0, acp_test_completion(&f)); testing.expect(t, requested)
    delete(string(id), runtime.heap_allocator())
    c.io.feed(c, "{\"jsonrpc\":\"2.0\",", 1); acp_test_wait(t, &f, .Acks, 1)
    s, valid := acp_state_read(path); testing.expect(t, valid)
    if valid {
        testing.expect_value(t, s.schema_version, 1)
        testing.expect_value(t, s.last_stdout_seq, u64(1))
        testing.expect_value(t, len(s.pending_outbound), 1)
        acp_state_delete(&s)
    }
    testing.expect(t, !os.exists(strings.concatenate({path, ".tmp"}, context.temp_allocator)))
    when ODIN_OS != .Windows {
        info, err := os.stat(path, context.temp_allocator)
        testing.expect(t, err == nil && info.mode == {.Read_User, .Write_User})
        parent := path[:strings.last_index(path, "/")]
        dir_info, dir_err := os.stat(parent, context.temp_allocator)
        testing.expect(t, dir_err == nil && dir_info.mode == {.Read_User, .Write_User, .Execute_User})
    }
    acp_rpc_close(c)
}

@(test)
acp_rpc_restore_rejects_corrupt_counters_and_identity :: proc(t: ^testing.T) {
    f: ACP_Test; c := acp_test_open(&f)
    id, _ := acp_rpc_request(c, "initialize", "{}", 0, acp_test_completion(&f))
    delete(string(id), runtime.heap_allocator())
    raw := acp_test_snapshot(&f); defer delete(raw)
    acp_rpc_close(c); acp_test_delete(&f)
    replacements := [?][2]string{
        {`"schema_version":1`, `"schema_version":99`},
        {`"instance":"inst_test_acp"`, `"instance":"inst_wrong"`},
        {`"next_rpc_id":2`, `"next_rpc_id":1`},
        {`"next_delivery_id":2`, `"next_delivery_id":1`},
        {`"partial_line_base64":""`, `"partial_line_base64":"invalid%"`},
    }
    for replacement in replacements {
        corrupt, _ := strings.replace_all(raw, replacement[0], replacement[1]); defer delete(corrupt)
        testing.expect(t, corrupt != raw)
        f2: ACP_Test; c2 := acp_test_open(&f2)
        testing.expect(t, !acp_rpc_restore(c2, corrupt))
        acp_rpc_close(c2); acp_test_delete(&f2)
    }
}

@(test)
acp_rpc_permission_deadline_and_outbound_inbound_same_id :: proc(t: ^testing.T) {
    f: ACP_Test; f.handle_permission = true; defer acp_test_delete(&f)
    c := acp_test_open(&f); defer acp_rpc_close(c)
    id, ok := acp_rpc_request(c, "session/prompt", "{}", 0, acp_test_completion(&f)); testing.expect(t, ok)
    defer delete(string(id), runtime.heap_allocator())
    inbound := strings.concatenate({`{"jsonrpc":"2.0","id":`, acp_rpc_quote(string(id)), `,"method":"session/request_permission","params":{}}`, "\n"}, context.temp_allocator)
    c.io.feed(c, inbound, 1); acp_test_wait(t, &f, .Acks, 1)
    // A response with the same ID belongs to the outbound map only.
    c.io.feed(c, acp_test_response(id, "{}"), 2); acp_test_wait(t, &f, .Acks, 2)
    sync.atomic_store(&f.clock, 1300000)
    acp_test_wait(t, &f, .Writes, 2)
    testing.expect(t, acp_rpc_notify(c, "barrier", "{}"))
    sync.mutex_lock(&f.mu); defer sync.mutex_unlock(&f.mu)
    testing.expect_value(t, len(f.results), 1)
    testing.expect_value(t, len(f.inbound_ids), 1)
    testing.expect_value(t, f.faults, 0)
    if len(f.writes) >= 2 do testing.expect(t, strings.contains(f.writes[1].bytes, "permission timeout"))
}

@(test)
acp_rpc_restore_expired_setup_does_not_resend :: proc(t: ^testing.T) {
    f: ACP_Test; c := acp_test_open(&f)
    id, ok := acp_rpc_request(c, "session/new", "{}", 0, acp_test_completion(&f)); testing.expect(t, ok)
    delete(string(id), runtime.heap_allocator())
    raw := acp_test_snapshot(&f); defer delete(raw)
    acp_rpc_close(c); acp_test_delete(&f)
    f2: ACP_Test; defer acp_test_delete(&f2)
    c2 := acp_test_open(&f2); defer acp_rpc_close(c2)
    sync.atomic_store(&f2.clock, 1060000)
    testing.expect(t, !acp_rpc_restore(c2, raw))
    sync.mutex_lock(&f2.mu); defer sync.mutex_unlock(&f2.mu)
    testing.expect_value(t, len(f2.writes), 0)
    testing.expect_value(t, len(f2.results), 1)
    testing.expect_value(t, f2.faults, 1)
}
