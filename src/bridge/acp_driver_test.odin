package main

import "base:runtime"
import "core:encoding/json"
import "core:strings"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"

@(test)
acp_driver_protocol_envelopes_and_strict_versions :: proc(t: ^testing.T) {
    for protocol in ([]contracts.ACP_Protocol{.ACP, .Codex_App_Server}) {
        f: ACP_Test
        // The codec comes from the driver's RPC policy, not the protocol name.
        c := acp_test_open(&f, policy = acp_protocol_driver(protocol).rpc)
        defer { acp_rpc_close(c); acp_test_delete(&f) }
        id, sent := acp_rpc_request(c, "initialize", "{}", 0, acp_test_completion(&f))
        defer delete(string(id), runtime.heap_allocator())
        testing.expect(t, sent)
        if !acp_test_wait(t, &f, .Writes, 1) do return
        sync.mutex_lock(&f.mu)
        value, _ := acp_rpc_parse(strings.trim_space(f.writes[0].bytes))
        obj, _ := value.(json.Object)
        _, has_version := obj["jsonrpc"]
        testing.expect_value(t, has_version, protocol == .ACP)
        if protocol == .Codex_App_Server {
            number, integer := obj["id"].(json.Integer)
            testing.expect(t, integer && number == 1)
        } else {
            testing.expect_value(t, acp_event_string(obj, "id"), string(id))
        }
        sync.mutex_unlock(&f.mu)
        // A wrong ID type cannot complete the request in either protocol.
        response := `{"jsonrpc":"2.0","id":1,"result":{}}`+"\n"
        if protocol == .Codex_App_Server do response = `{"id":"ham:epoch_test:1","result":{}}`+"\n"
        testing.expect(t, c.io.feed(c, response, 1))
        if !acp_test_wait(t, &f, .Acks, 1) do return
        sync.mutex_lock(&f.mu)
        testing.expect_value(t, len(f.results), 0)
        sync.mutex_unlock(&f.mu)
        response = acp_test_response(id, "{}")
        if protocol == .Codex_App_Server do response = `{"id":1,"result":{}}`+"\n"
        testing.expect(t, c.io.feed(c, response, 2))
        if !acp_test_wait(t, &f, .Results, 1) do return
        testing.expect(t, c.io.feed(c, `{"jsonrpc":"1.0","method":"notice","params":{}}`+"\n", 3))
        acp_test_wait(t, &f, .Faults, 1)
    }
}

@(test)
acp_driver_codex_notifications_replies_and_restore :: proc(t: ^testing.T) {
    f: ACP_Test
    c := acp_test_open(&f, policy = ACP_RPC_POLICY_CODEX)
    id, sent := acp_rpc_request(c, "initialize", "{}", 0, acp_test_completion(&f))
    defer delete(string(id), runtime.heap_allocator())
    testing.expect(t, sent)
    if !acp_test_wait(t, &f, .Writes, 1) { acp_rpc_close(c); acp_test_delete(&f); return }
    snapshot := acp_test_snapshot(&f)
    defer delete(snapshot)
    acp_rpc_close(c); acp_test_delete(&f)
    restored: ACP_Test
    next := acp_test_open(&restored, policy = ACP_RPC_POLICY_CODEX)
    defer { acp_rpc_close(next); acp_test_delete(&restored) }
    testing.expect(t, acp_rpc_restore(next, snapshot))
    if !acp_test_wait(t, &restored, .Writes, 1) do return
    sync.mutex_lock(&restored.mu)
    testing.expect(t, strings.contains(restored.writes[0].bytes, `"id":1`))
    testing.expect(t, !strings.contains(restored.writes[0].bytes, "jsonrpc"))
    sync.mutex_unlock(&restored.mu)
    testing.expect(t, acp_rpc_notify(next, "initialized", "{}"))
    testing.expect(t, next.io.feed(next,
        `{"id":1,"result":{}}`+"\n"+
        `{"method":"notice","params":{"ok":true}}`+"\n"+
        `{"id":42,"method":"unsupported","params":{}}`+"\n", 1))
    if !acp_test_wait(t, &restored, .Acks, 1) do return
    if !acp_test_wait(t, &restored, .Writes, 3) do return
    sync.mutex_lock(&restored.mu)
    testing.expect(t, len(restored.results) == 1 && restored.results[0].ok)
    testing.expect_value(t, len(restored.notification_params), 1)
    value, _ := acp_rpc_parse(strings.trim_space(restored.writes[2].bytes))
    error_obj, _ := value.(json.Object)
    number, integer := error_obj["id"].(json.Integer)
    testing.expect(t, integer && number == 42)
    _, version := error_obj["jsonrpc"]
    testing.expect(t, !version)
    sync.mutex_unlock(&restored.mu)
}

@(test)
acp_driver_rpc_codec_ids_and_notifications :: proc(t: ^testing.T) {
    acp, codex := ACP_RPC_POLICY_ACP.codec, ACP_RPC_POLICY_CODEX.codec
    // ACP sends the quoted epoch-scoped ID and correlates only string echoes.
    testing.expect_value(t, acp_rpc_wire_id(acp, "ham:e:7", 7), `"ham:e:7"`)
    key, ok := acp_rpc_response_key(acp, "e", json.String("ham:e:7"))
    testing.expect(t, ok && key == "ham:e:7")
    _, ok = acp_rpc_response_key(acp, "e", json.Integer(7))
    testing.expect(t, !ok)
    // Codex sends the bare counter and correlates only positive integers.
    testing.expect_value(t, acp_rpc_wire_id(codex, "ham:e:7", 7), "7")
    key, ok = acp_rpc_response_key(codex, "e", json.Integer(7))
    testing.expect(t, ok && key == "ham:e:7")
    for bad in ([]json.Value{json.String("ham:e:7"), json.Integer(0), json.Integer(-3), json.Float(7)}) {
        _, ok = acp_rpc_response_key(codex, "e", bad)
        testing.expect(t, !ok)
    }
    testing.expect(t, !strings.contains(acp_rpc_envelope("1", "m", "{}", "", "", codex), "jsonrpc"))
    testing.expect(t, strings.contains(acp_rpc_envelope(`"x"`, "m", "{}", "", "", acp), `"jsonrpc":"2.0"`))

    // Integer IDs are signed on the wire: the counter cannot pass max(i64).
    f: ACP_Test
    c := acp_test_open(&f, policy = ACP_RPC_POLICY_CODEX)
    defer { acp_rpc_close(c); acp_test_delete(&f) }
    cmd := ACP_RPC_Command{kind = .Runtime, runtime_work = proc(_: rawptr, client: ^ACP_RPC_Client, _: string) -> bool {
        client.state.next_rpc_id = u64(max(i64))+1; return true
    }}
    acp_rpc_call(c, &cmd)
    id, sent := acp_rpc_request(c, "initialize", "{}", 0, acp_test_completion(&f))
    defer delete(string(id), runtime.heap_allocator())
    testing.expect(t, !sent)
    // Malformed notification params are dropped by Codex but fail ACP.
    testing.expect(t, c.io.feed(c, `{"method":"notice","params":"x"}`+"\n", 1))
    if !acp_test_wait(t, &f, .Acks, 1) do return
    sync.mutex_lock(&f.mu)
    testing.expect(t, len(f.fault_reasons) == 0 && len(f.notification_params) == 0)
    sync.mutex_unlock(&f.mu)
    g: ACP_Test
    strict := acp_test_open(&g)
    defer { acp_rpc_close(strict); acp_test_delete(&g) }
    testing.expect(t, strict.io.feed(strict, `{"jsonrpc":"2.0","method":"notice","params":"x"}`+"\n", 1))
    acp_test_wait(t, &g, .Faults, 1)
}

driver_test_role :: proc(method: string) -> ACP_RPC_Role {
    return .Prompt if method == "custom/turn" else .Other
}
driver_test_timeout :: proc(method: string) -> i64 { return 777 }
driver_test_inbound_timeout :: proc(method: string) -> i64 { return 888 }
driver_test_cancel_timeout :: proc(method: string) -> i64 { return 999 if method == "custom/cancel" else 0 }

@(test)
acp_driver_rpc_policy_controls_roles_deadlines_and_restore :: proc(t: ^testing.T) {
    policy := ACP_RPC_Policy{driver_test_role, driver_test_timeout, driver_test_inbound_timeout, driver_test_cancel_timeout, ACP_RPC_POLICY_ACP.codec}
    f: ACP_Test
    c := acp_test_open(&f, policy = policy)
    defer { acp_rpc_close(c); acp_test_delete(&f) }
    id, sent := acp_rpc_request(c, "custom/turn", "{}", 0, acp_test_completion(&f))
    defer delete(string(id), runtime.heap_allocator())
    testing.expect(t, sent)
    if !acp_test_wait(t, &f, .Writes, 1) do return
    raw := acp_test_snapshot(&f); defer delete(raw)
    state, valid := acp_state_decode(raw)
    defer acp_state_delete(&state)
    testing.expect(t, valid && len(state.pending_outbound) == 1)
    testing.expect_value(t, state.pending_outbound[0].role, ACP_RPC_Role.Prompt)
    testing.expect_value(t, state.pending_outbound[0].deadline_unix_ms, i64(1000777))
    testing.expect(t, acp_rpc_restore_checkpoint_valid(&state, true, policy))
    testing.expect(t, !acp_rpc_restore_checkpoint_valid(&state, true))
    testing.expect(t, acp_rpc_notify(c, "custom/cancel", "{}"))
    if !acp_test_wait(t, &f, .Writes, 2) do return
    updated := acp_test_snapshot(&f); defer delete(updated)
    changed, decoded := acp_state_decode(updated); defer acp_state_delete(&changed)
    testing.expect(t, decoded)
    testing.expect_value(t, changed.pending_outbound[0].deadline_unix_ms, i64(1000999))
    // The shared permission fixture handles this method; its deadline comes
    // from the supplied driver policy, rather than a method-name check.
    sync.mutex_lock(&f.mu)
    f.handle_permission = true
    sync.mutex_unlock(&f.mu)
    testing.expect(t, c.io.feed(c, `{"jsonrpc":"2.0","id":4,"method":"session/request_permission","params":{}}`+"\n", 1))
    if !acp_test_wait(t, &f, .Acks, 1) do return
    inbound := acp_test_snapshot(&f); defer delete(inbound)
    pending, parsed := acp_state_decode(inbound); defer acp_state_delete(&pending)
    testing.expect(t, parsed && len(pending.pending_inbound) == 1)
    testing.expect_value(t, pending.pending_inbound[0].deadline_unix_ms, i64(1000888))
}

driver_test_begin :: proc(r: ^ACP_Runtime) -> bool { r.d.phase = "begin"; return true }
driver_test_result :: proc(data: rawptr, result: ACP_RPC_Result) {
    r := cast(^ACP_Runtime)data
    r.d.phase = "result"
    acp_rpc_result_delete(result)
}
driver_test_prompt :: proc(r: ^ACP_Runtime, input: ACP_Runtime_Input, bootstrap: bool) { r.d.phase = input.text }
driver_test_ready :: proc(r: ^ACP_Runtime) { r.d.phase = "ready" }
driver_test_permissions_cancel :: proc(r: ^ACP_Runtime) { r.d.phase = "cancel_permissions" }
driver_test_cancel :: proc(r: ^ACP_Runtime) -> bool { r.next_rpc_id += 1; return true }


@(test)
acp_driver_runtime_dispatch_is_per_owner :: proc(t: ^testing.T) {
    custom := acp_protocol_acp_driver
    custom.begin = driver_test_begin
    custom.result = driver_test_result
    custom.prompt = driver_test_prompt
    custom.ready = driver_test_ready
    custom.permissions_cancel = driver_test_permissions_cancel
    custom.cancel = driver_test_cancel
    r := ACP_Runtime{driver = &custom}
    c: ACP_RPC_Client
    testing.expect(t, acp_runtime_work(&r, &c, "begin"))
    testing.expect_value(t, r.d.phase, "begin")
    acp_runtime_result(&r, {})
    testing.expect_value(t, r.d.phase, "result")
    acp_runtime_prompt(&r, {text = "prompt"})
    testing.expect_value(t, r.d.phase, "prompt")
    acp_runtime_ready(&r)
    testing.expect_value(t, r.d.phase, "ready")
    // Lifecycle interrupt/stop cancellation can use a protocol's own approval
    // response shape rather than the ACP cancellation object.
    testing.expect(t, acp_runtime_work(&r, &c, "stop"))
    testing.expect(t, r.d.stopped && r.next_rpc_id == 1)
    testing.expect_value(t, r.d.phase, "cancel_permissions")
    for provider in ([]string{"claude", "copilot", "kiro"}) {
        d, _ := contracts.acp_provider_descriptor(provider)
        owner := ACP_Runtime{descriptor = d}
        testing.expect(t, acp_runtime_driver(&owner) == &acp_protocol_acp_driver)
    }
    testing.expect(t, acp_protocol_driver(.Codex_App_Server) == &acp_protocol_codex_driver)
    testing.expect(t, acp_protocol_driver(contracts.ACP_Protocol(99)) == nil)
}
