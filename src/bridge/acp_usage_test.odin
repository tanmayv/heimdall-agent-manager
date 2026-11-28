package main

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:testing"

// ACP runtimes report token usage through their protocol driver into the same
// per-instance accumulator as ham.ext.v1 extensions (extension_token_usage.odin).

Usage_Test_Snapshot :: struct {
    found, has_context, has_output, pushed: bool,
    context_tokens, reported_window, output_tokens_total, pushed_context: i64,
    source, session: string,
}
usage_test_snapshot :: proc(instance: string) -> (s: Usage_Test_Snapshot) {
    sync.mutex_lock(&bridge_ext_mutex); defer sync.mutex_unlock(&bridge_ext_mutex)
    for e in bridge_ext_states {
        if e.agent_instance_id != instance do continue
        u := e.token_usage
        return {true, u.has_context, u.has_output_total, u.has_pushed, u.context_tokens, u.reported_window, u.output_tokens_total, u.last_push_context,
            strings.clone(u.context_source, context.temp_allocator), strings.clone(u.session_id, context.temp_allocator)}
    }
    return
}

usage_test_open :: proc(f: ^T4_Runtime_Test, instance: string) {
    t4_runtime_open(f, instance, "/unused/bootstrap")
    acp_rpc_close(f.r.client); acp_test_delete(&f.f); f.f = {}
    sync.atomic_store(&f.f.clock, 1000000)
    f.r.client, _ = acp_rpc_open({data = &f.f, instance = f.r.instance, launch_epoch = f.r.epoch,
        write = acp_test_write, ack = acp_test_ack, close = acp_test_close, now_ms = acp_test_clock},
        {data = f, checkpoint = t4_runtime_checkpoint, notification = codex_test_notification, restore_completion = t4_runtime_restore_completion},
        acp_runtime_driver(f.r).rpc)
    acp_runtime_replace(&f.r.session, "s")
}
usage_test_close :: proc(f: ^T4_Runtime_Test, instance: string) {
    f.r.d.stopped = true
    acp_runtime_destroy(f.r); acp_test_delete(&f.f)
    bridge_runtime_set_status(instance, "stopped", "idle")
}
usage_test_replay :: proc(data: rawptr, c: ^ACP_RPC_Client, argument: string) -> bool {
    f := cast(^T4_Runtime_Test)data
    f.r.d.replay_only = argument == "on"
    return true
}

@(test)
acp_usage_update_reaches_token_accumulator :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    old := bridge_local_token_records; bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record, allocator = runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records = old }
    instance := "inst_acp_usage_claude"
    f: T4_Runtime_Test; usage_test_open(&f, instance); defer usage_test_close(&f, instance)
    testing.expect(t, f.r.driver == &acp_protocol_acp_driver)
    // Shape from @agentclientprotocol/claude-agent-acp: used/size plus cost and _meta.
    codex_test_frame(t, &f, 1, `{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"usage_update","used":53000,"size":200000,"cost":{"amount":0.42,"currency":"USD"},"_meta":{"_claude/model":"m"}}}}`)
    s := usage_test_snapshot(instance)
    testing.expect(t, s.found && s.has_context && !s.has_output)
    testing.expect_value(t, s.context_tokens, i64(53000))
    testing.expect_value(t, s.reported_window, i64(200000))
    testing.expect_value(t, s.source, ACP_USAGE_SOURCE)
    testing.expect_value(t, s.session, "s")
    // The first snapshot goes to the hub at once (throttled push).
    testing.expect(t, s.pushed && s.pushed_context == 53000)
    // Another session's update and replayed history do not move the snapshot.
    codex_test_frame(t, &f, 2, `{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"other","update":{"sessionUpdate":"usage_update","used":1,"size":2}}}`)
    cmd := ACP_RPC_Command{kind = .Runtime, a = "on", runtime_work = usage_test_replay, runtime_data = &f}
    acp_rpc_call(f.r.client, &cmd)
    codex_test_frame(t, &f, 3, `{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"usage_update","used":7,"size":200000}}}`)
    testing.expect_value(t, usage_test_snapshot(instance).context_tokens, i64(53000))
    cmd = {kind = .Runtime, a = "off", runtime_work = usage_test_replay, runtime_data = &f}
    acp_rpc_call(f.r.client, &cmd)
    codex_test_frame(t, &f, 4, `{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"usage_update","used":61000,"size":1000000}}}`)
    s = usage_test_snapshot(instance)
    testing.expect_value(t, s.context_tokens, i64(61000))
    testing.expect_value(t, s.reported_window, i64(1000000))
    // Near-full context does not start a PTY-only context rollover.
    codex_test_frame(t, &f, 5, `{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"usage_update","used":950000,"size":1000000}}}`)
    testing.expect_value(t, usage_test_snapshot(instance).context_tokens, i64(950000))
    testing.expect_value(t, bridge_rollover_phase_of(instance), Bridge_Rollover_Phase.Normal)
}

@(test)
acp_codex_token_usage_reaches_token_accumulator :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    old := bridge_local_token_records; bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record, allocator = runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records = old }
    f: T4_Runtime_Test; codex_test_open(&f); defer codex_test_close(&f)
    codex_test_active(&f)
    // Shape from `codex app-server generate-json-schema`
    // (v2/ThreadTokenUsageUpdatedNotification.json); it arrives outside a prompt too.
    codex_test_frame(t, &f, 1, `{"method":"thread/tokenUsage/updated","params":{"threadId":"s","turnId":"t1","tokenUsage":{`+
        `"total":{"totalTokens":90000,"inputTokens":80000,"cachedInputTokens":40000,"outputTokens":10000,"reasoningOutputTokens":2000},`+
        `"last":{"totalTokens":31000,"inputTokens":29000,"cachedInputTokens":20000,"outputTokens":2000,"reasoningOutputTokens":500},"modelContextWindow":258400}}}`)
    s := usage_test_snapshot(f.r.instance)
    testing.expect(t, s.found && s.has_context && s.has_output)
    testing.expect_value(t, s.context_tokens, i64(31000))
    testing.expect_value(t, s.output_tokens_total, i64(10000))
    testing.expect_value(t, s.reported_window, i64(258400))
    testing.expect_value(t, s.source, ACP_CODEX_USAGE_SOURCE)
    // A null window keeps the last reported one; another thread is ignored.
    codex_test_frame(t, &f, 2, `{"method":"thread/tokenUsage/updated","params":{"threadId":"s","turnId":"t2","tokenUsage":{`+
        `"total":{"totalTokens":95000,"inputTokens":84000,"cachedInputTokens":40000,"outputTokens":11000,"reasoningOutputTokens":2000},`+
        `"last":{"totalTokens":36000,"inputTokens":35000,"cachedInputTokens":20000,"outputTokens":1000,"reasoningOutputTokens":0},"modelContextWindow":null}}}`)
    codex_test_frame(t, &f, 3, `{"method":"thread/tokenUsage/updated","params":{"threadId":"other","turnId":"t","tokenUsage":{"total":{"totalTokens":1,"outputTokens":1},"last":{"totalTokens":1},"modelContextWindow":5}}}`)
    s = usage_test_snapshot(f.r.instance)
    testing.expect_value(t, s.context_tokens, i64(36000))
    testing.expect_value(t, s.output_tokens_total, i64(11000))
    testing.expect_value(t, s.reported_window, i64(258400))
}

@(test)
acp_driver_usage_rejects_malformed_reports :: proc(t: ^testing.T) {
    r := ACP_Runtime{session = "s"}
    for params in ([]string{
        `{"sessionId":"s","update":{"sessionUpdate":"usage_update","size":200000}}`,
        `{"sessionId":"s","update":{"sessionUpdate":"usage_update","used":-1,"size":200000}}`,
        `{"sessionId":"s","update":{"sessionUpdate":"usage_update","used":"10","size":200000}}`,
        `{"sessionId":"s","update":{"sessionUpdate":"usage_update","used":10.5,"size":200000}}`,
        `{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","used":10}}`,
    }) {
        _, ok := acp_driver_acp_usage(&r, "session/update", params)
        testing.expectf(t, !ok, "%s rejected", params)
    }
    _, ok := acp_driver_acp_usage(&r, "session/other", `{"sessionId":"s","update":{"sessionUpdate":"usage_update","used":1}}`)
    testing.expect(t, !ok)
    // A missing or zero size reports context without a window.
    u, sized := acp_driver_acp_usage(&r, "session/update", `{"sessionId":"s","update":{"sessionUpdate":"usage_update","used":12,"size":0}}`)
    testing.expect(t, sized && u.context_tokens == 12 && !u.has_context_window)
    _, ok = acp_codex_usage(&r, "thread/tokenUsage/updated", `{"threadId":"s","tokenUsage":{"total":{"outputTokens":3},"last":{}}}`)
    testing.expect(t, !ok)
    u, ok = acp_codex_usage(&r, "thread/tokenUsage/updated", `{"threadId":"s","tokenUsage":{"total":{},"last":{"totalTokens":5}}}`)
    testing.expect(t, ok && u.context_tokens == 5 && !u.has_output_tokens_total && !u.has_context_window)
}
