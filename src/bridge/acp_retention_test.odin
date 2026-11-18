package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

// All inspection follows a synchronous dispatcher barrier, so neither state nor
// its index maps are read concurrently with a queued receipt or stdout frame.
acp_test_barrier :: proc(c: ^ACP_RPC_Client) { acp_rpc_reply(c, "null", "{}") }

acp_test_inbound_frame :: proc(id: int) -> string {
    return strings.concatenate({`{"jsonrpc":"2.0","id":`, fmt.tprintf("%d", id),
        `,"method":"session/request_permission","params":{}}`, "\n"}, context.temp_allocator)
}

acp_test_receipt :: proc(t: ^testing.T, c: ^ACP_RPC_Client, f: ^ACP_Test, write_index: int) -> bool {
    if !acp_test_wait(t, f, .Writes, write_index+1) do return false
    sync.mutex_lock(&f.mu)
    id := strings.clone(f.writes[write_index].delivery_id)
    sync.mutex_unlock(&f.mu)
    defer delete(id)
    if !testing.expect(t, acp_rpc_enqueue_frame(c, {kind = .Receipt, bytes = id})) do return false
    acp_test_barrier(c)
    return true
}

@(test)
acp_rpc_retention_long_session_has_bounded_journal_and_maps :: proc(t: ^testing.T) {
    f: ACP_Test; f.handle_permission = true
    defer acp_test_delete(&f)
    c := acp_test_open(&f); defer acp_rpc_close(c)
    cycles := 4*max(ACP_RPC_RECENT_INBOUND_COUNT, ACP_RPC_COMPLETED_DELIVERY_COUNT)
    reply := `{"text":"bounded response body"}`
    steady_size := 0
    for i in 0..<cycles {
        c.io.feed(c, acp_test_inbound_frame(i), u64(i+1))
        testing.expect(t, acp_rpc_reply(c, fmt.tprintf("%d", i), reply))
        if !acp_test_receipt(t, c, &f, i) do return
        testing.expect_value(t, len(c.state.pending_inbound), 0)
        testing.expect_value(t, len(c.inbound), 0)
        testing.expect_value(t, len(c.state.pending_writes), 0)
        testing.expect(t, len(c.state.recent_inbound) <= ACP_RPC_RECENT_INBOUND_COUNT)
        testing.expect_value(t, len(c.recent_inbound), len(c.state.recent_inbound))
        testing.expect(t, c.recent_inbound_bytes <= ACP_RPC_RECENT_INBOUND_BYTES)
        testing.expect(t, len(c.state.completed_delivery_ids) <= ACP_RPC_COMPLETED_DELIVERY_COUNT)
        if i == cycles/2-1 {
            raw := acp_test_snapshot(&f); steady_size = len(raw); delete(raw)
        }
    }
    raw := acp_test_snapshot(&f); defer delete(raw)
    // Past the windows, only the few extra digits in IDs/counters can grow.
    testing.expect(t, len(raw) <= steady_size+4*(ACP_RPC_RECENT_INBOUND_COUNT+ACP_RPC_COMPLETED_DELIVERY_COUNT)+64)
    testing.expect(t, len(raw) < 128*1024)
    testing.expect_value(t, len(c.state.recent_inbound), ACP_RPC_RECENT_INBOUND_COUNT)
    testing.expect_value(t, len(c.state.completed_delivery_ids), ACP_RPC_COMPLETED_DELIVERY_COUNT)
    testing.expect_value(t, c.state.recent_inbound[0].id_json, fmt.tprintf("%d", cycles-ACP_RPC_RECENT_INBOUND_COUNT))
    testing.expect_value(t, c.state.completed_delivery_ids[0], f.writes[cycles-ACP_RPC_COMPLETED_DELIVERY_COUNT].delivery_id)
    // A recent duplicate reuses its response; a duplicate receipt is a no-op.
    c.io.feed(c, acp_test_inbound_frame(cycles-1), u64(cycles+1))
    if !acp_test_receipt(t, c, &f, cycles) do return
    testing.expect_value(t, f.writes[cycles].bytes, f.writes[cycles-1].bytes)
    testing.expect_value(t, len(f.inbound_ids), cycles)
    acp_rpc_enqueue_frame(c, {kind = .Receipt, bytes = f.writes[cycles].delivery_id})
    acp_test_barrier(c)
    testing.expect_value(t, len(c.state.completed_delivery_ids), ACP_RPC_COMPLETED_DELIVERY_COUNT)
    testing.expect_value(t, f.order_errors, 0)
    // The bounded completed cache is durable and rebuilt without permission
    // callbacks. A replayed recent ID still returns the cached body after restore.
    restored: ACP_Test; restored.handle_permission = true
    defer acp_test_delete(&restored)
    c2 := acp_test_open(&restored); defer acp_rpc_close(c2)
    testing.expect(t, acp_rpc_restore(c2, raw))
    c2.io.feed(c2, acp_test_inbound_frame(cycles-1), u64(cycles+1))
    if !acp_test_receipt(t, c2, &restored, 0) do return
    testing.expect_value(t, len(restored.inbound_ids), 0)
    testing.expect_value(t, restored.writes[0].bytes, f.writes[cycles-1].bytes)
    testing.expect_value(t, len(c2.inbound), 0)
    testing.expect_value(t, len(c2.recent_inbound), ACP_RPC_RECENT_INBOUND_COUNT)
}

@(test)
acp_rpc_retention_byte_budget_and_evicted_id_reuse :: proc(t: ^testing.T) {
    // Exercise the pure dispatcher-owned eviction kernel with the test tracking
    // allocator. This also checks frees of evicted records and rebuilt map keys.
    c := ACP_RPC_Client{inbound = make(map[string]int), recent_inbound = make(map[string]int)}
    c.state = {schema_version = 1, instance = strings.clone("inst_test_acp"), launch_epoch = strings.clone("epoch_test"),
        effective_transport = strings.clone("acp"), next_rpc_id = 1, next_delivery_id = 1, last_stdout_seq = 3}
    defer {
        for key in c.inbound do delete(key)
        for key in c.recent_inbound do delete(key)
        delete(c.inbound); delete(c.recent_inbound); acp_state_delete(&c.state)
    }
    body := make([]byte, 3*1024*1024); defer delete(body)
    for &ch in body do ch = 'x'
    result := strings.concatenate({`{"text":"`, string(body), `"}`}); defer delete(result)
    for i in 0..<3 {
        id := fmt.aprintf("%d", i)
        append(&c.state.pending_inbound, ACP_RPC_Inbound{id_json = id, method = strings.clone("session/request_permission"), params_json = strings.clone("{}"),
            response_json = strings.clone(acp_rpc_envelope(id, "", "", "result", result)), response_delivery_id = strings.clone("receipt")})
        acp_rpc_reindex_inbound(&c.inbound, c.state.pending_inbound[:])
        acp_rpc_retire_inbound(&c, "receipt")
        testing.expect_value(t, len(c.inbound), 0)
        testing.expect_value(t, len(c.state.pending_inbound), 0)
        testing.expect(t, c.recent_inbound_bytes <= ACP_RPC_RECENT_INBOUND_BYTES)
    }
    testing.expect_value(t, len(c.state.recent_inbound), 2)
    testing.expect_value(t, len(c.recent_inbound), 2)
    testing.expect_value(t, c.state.recent_inbound[0].id_json, "1")
    encoded, _ := json.marshal(c.state); defer delete(encoded)
    raw := string(encoded)
    testing.expect(t, len(raw) < 2*ACP_RPC_RECENT_INBOUND_BYTES)
    f2: ACP_Test; f2.handle_permission = true
    defer acp_test_delete(&f2)
    c2 := acp_test_open(&f2); defer acp_rpc_close(c2)
    testing.expect(t, acp_rpc_restore(c2, raw))
    testing.expect_value(t, len(c2.recent_inbound), 2)
    // ID 0 was evicted by bytes, so a new request can now use it.
    c2.io.feed(c2, acp_test_inbound_frame(0), 4)
    acp_test_barrier(c2)
    testing.expect_value(t, len(c2.inbound), 1)
    testing.expect_value(t, len(f2.inbound_ids), 1)
}

@(test)
acp_rpc_retention_multichunk_response_survives_restore_until_final_receipt :: proc(t: ^testing.T) {
    f: ACP_Test; f.handle_permission = true; defer acp_test_delete(&f)
    c := acp_test_open(&f)
    body := make([]byte, 64*1024+100); defer delete(body)
    for &ch in body do ch = 'x'
    result := strings.concatenate({`{"text":"`, string(body), `"}`}); defer delete(result)
    c.io.feed(c, acp_test_inbound_frame(1), 1)
    testing.expect(t, acp_rpc_reply(c, "1", result))
    testing.expect_value(t, len(c.inbound), 1)
    if !acp_test_wait(t, &f, .Writes, 2) { acp_rpc_close(c); return }
    if !acp_test_receipt(t, c, &f, 0) { acp_rpc_close(c); return }
    testing.expect_value(t, len(c.inbound), 1)
    testing.expect_value(t, len(c.state.pending_inbound), 1)
    raw := acp_test_snapshot(&f); defer delete(raw)
    acp_rpc_close(c)
    f2: ACP_Test; f2.handle_permission = true; defer acp_test_delete(&f2)
    c2 := acp_test_open(&f2); defer acp_rpc_close(c2)
    testing.expect(t, acp_rpc_restore(c2, raw))
    testing.expect_value(t, len(c2.inbound), 1)
    if !acp_test_receipt(t, c2, &f2, 0) do return
    testing.expect_value(t, f2.writes[0].delivery_id, f.writes[1].delivery_id)
    testing.expect_value(t, len(c2.inbound), 0)
    testing.expect_value(t, len(c2.state.pending_inbound), 0)
    testing.expect_value(t, len(c2.recent_inbound), 1)
    c2.io.feed(c2, acp_test_inbound_frame(1), 2)
    if !acp_test_receipt(t, c2, &f2, 1) do return
    if !acp_test_receipt(t, c2, &f2, 2) do return
    testing.expect_value(t, len(f2.inbound_ids), 0)
    testing.expect_value(t, len(c2.inbound), 0)
    testing.expect_value(t, len(c2.recent_inbound), 1)
    testing.expect_value(t, f2.writes[1].bytes, f.writes[0].bytes)
    testing.expect_value(t, f2.writes[2].bytes, f.writes[1].bytes)
}

@(test)
acp_rpc_retention_active_request_count_and_restore_bounds :: proc(t: ^testing.T) {
    f: ACP_Test; f.handle_permission = true; defer acp_test_delete(&f)
    c := acp_test_open(&f); defer acp_rpc_close(c)
    for i in 0..<ACP_RPC_MAX_PENDING_INBOUND {
        c.io.feed(c, acp_test_inbound_frame(i), u64(i+1))
        acp_test_barrier(c)
    }
    testing.expect_value(t, len(c.inbound), ACP_RPC_MAX_PENDING_INBOUND)
    c.io.feed(c, acp_test_inbound_frame(ACP_RPC_MAX_PENDING_INBOUND), ACP_RPC_MAX_PENDING_INBOUND+1)
    acp_test_wait(t, &f, .Faults, 1)
    acp_test_barrier(c)
    testing.expect_value(t, len(c.inbound), ACP_RPC_MAX_PENDING_INBOUND)
    testing.expect_value(t, len(c.state.pending_inbound), ACP_RPC_MAX_PENDING_INBOUND)
    // A corrupt/oversized cache is not admitted on recovery either.
    f2: ACP_Test; c2 := acp_test_open(&f2)
    state := ACP_State{schema_version = 1, instance = "inst_test_acp", launch_epoch = "epoch_test", effective_transport = "acp", next_rpc_id = 1, next_delivery_id = 1}
    state.recent_inbound = make([dynamic]ACP_RPC_Inbound)
    defer delete(state.recent_inbound)
    for i in 0..=ACP_RPC_RECENT_INBOUND_COUNT {
        append(&state.recent_inbound, ACP_RPC_Inbound{id_json = "1", method = "x", params_json = "{}", response_json = "{}\n"})
    }
    raw, _ := json.marshal(state); defer delete(raw)
    testing.expect(t, !acp_rpc_restore(c2, string(raw)))
    clear(&state.recent_inbound)
    // Older receipt histories can be reduced to a recent window in one pass;
    // discarded IDs are still deduplicated by the daemon, not this journal.
    for i in 0..<4*ACP_RPC_COMPLETED_DELIVERY_COUNT {
        append(&state.completed_delivery_ids, fmt.aprintf("ham:epoch_test:write:%d", i+1))
    }
    defer {
        for id in state.completed_delivery_ids do delete(id)
        delete(state.completed_delivery_ids)
    }
    state.next_delivery_id = u64(len(state.completed_delivery_ids)+1)
    older, _ := json.marshal(state); defer delete(older)
    testing.expect(t, acp_rpc_restore(c2, string(older)))
    testing.expect_value(t, len(c2.state.completed_delivery_ids), ACP_RPC_COMPLETED_DELIVERY_COUNT)
    testing.expect_value(t, c2.state.completed_delivery_ids[0], state.completed_delivery_ids[3*ACP_RPC_COMPLETED_DELIVERY_COUNT])
    acp_rpc_close(c2); acp_test_delete(&f2)
    f3: ACP_Test; defer acp_test_delete(&f3)
    c3 := acp_test_open(&f3)
    for i in 0..<ACP_RPC_MAX_PENDING_OUTBOUND {
        id, ok := acp_rpc_request(c3, "session/prompt", "{}", 0, acp_test_completion(&f3))
        testing.expect(t, ok); delete(string(id), runtime.heap_allocator())
    }
    id, ok := acp_rpc_request(c3, "session/prompt", "{}", 0, acp_test_completion(&f3))
    testing.expect(t, !ok && id == "")
    testing.expect_value(t, len(c3.outbound), ACP_RPC_MAX_PENDING_OUTBOUND)
    acp_rpc_close(c3)
    testing.expect_value(t, len(f3.results), ACP_RPC_MAX_PENDING_OUTBOUND)
}

@(test)
acp_rpc_retention_unknown_id_storm_is_bounded_and_faults_are_classified :: proc(t: ^testing.T) {
    f: ACP_Test; defer acp_test_delete(&f)
    c := acp_test_open(&f); defer acp_rpc_close(c)
    frames: strings.Builder; strings.builder_init(&frames); defer strings.builder_destroy(&frames)
    for i in 0..<4*ACP_RPC_UNKNOWN_ID_COUNT {
        strings.write_string(&frames, strings.concatenate({`{"jsonrpc":"2.0","id":`, fmt.tprintf("%d", i), `,"result":{}}`, "\n"}, context.temp_allocator))
    }
    c.io.feed(c, strings.to_string(frames), 1); acp_test_barrier(c)
    testing.expect_value(t, len(c.unknown_ids), ACP_RPC_UNKNOWN_ID_COUNT)
    testing.expect(t, c.unknown_id_bytes <= ACP_RPC_UNKNOWN_ID_BYTES)
    testing.expect_value(t, f.unknown, ACP_RPC_UNKNOWN_ID_COUNT+1)
    c.io.feed(c, strings.to_string(frames), 2); acp_test_barrier(c)
    testing.expect_value(t, f.unknown, ACP_RPC_UNKNOWN_ID_COUNT+1)
    testing.expect_value(t, f.faults, 0)
    f2: ACP_Test; f2.write_fail = true; defer acp_test_delete(&f2)
    c2 := acp_test_open(&f2)
    acp_rpc_notify(c2, "test", "{}")
    acp_test_wait(t, &f2, .Faults, 1)
    acp_rpc_close(c2)
    testing.expect_value(t, f2.fault_reasons[0], "acp_pipe_write_failed")
    f3: ACP_Test; defer acp_test_delete(&f3)
    c3 := acp_test_open(&f3)
    acp_rpc_enqueue_frame(c3, {kind = .Fault, bytes = "untrusted\nsecret diagnostic"})
    acp_test_wait(t, &f3, .Faults, 1)
    acp_rpc_close(c3)
    testing.expect_value(t, f3.fault_reasons[0], "acp_pipe_lost")
    f4: ACP_Test; defer acp_test_delete(&f4)
    c4 := acp_test_open(&f4); defer acp_rpc_close(c4)
    large_id := make([]byte, ACP_RPC_UNKNOWN_ID_BYTES+1); defer delete(large_id)
    for &b in large_id do b = 'x'
    frame := strings.concatenate({`{"jsonrpc":"2.0","id":"`, string(large_id), `","result":{}}`, "\n"}, context.temp_allocator)
    c4.io.feed(c4, frame, 1); acp_test_barrier(c4)
    c4.io.feed(c4, frame, 2); acp_test_barrier(c4)
    testing.expect_value(t, len(c4.unknown_ids), 0)
    testing.expect_value(t, f4.unknown, 1)
    testing.expect_value(t, f4.faults, 0)
}
