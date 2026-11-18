package main

import "core:encoding/base64"
import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"

// This is the on-disk contract, not a runtime snapshot containing pointers or
// credentials. The dispatcher is the only writer. JSON-valued runtime fields
// are strings so subsequent runtime modules can evolve their own payloads.
ACP_State :: struct {
    schema_version: int,
    instance: string,
    bridge: string,
    launch_epoch: string,
    effective_transport: string,
    provider: string,
    profile: string,
    run_dir: string,
    catalog_etag: string,
    adapter_version: string,
    pipe_generation: string,
    initialized: bool,
    loadSession: bool,
    sessionId: string,
    selected_model: string,
    selected_mode: string,
    next_rpc_id: u64,
    next_delivery_id: u64,
    pending_outbound: [dynamic]ACP_RPC_Pending,
    pending_inbound: [dynamic]ACP_RPC_Inbound,
    recent_inbound: [dynamic]ACP_RPC_Inbound,
    pending_writes: [dynamic]ACP_RPC_Write,
    queued_input_message_ids: [dynamic]string,
    completed_delivery_ids: [dynamic]string,
    last_stdout_seq: u64,
    partial_line_base64: string,
    tool_map_json: string,
    chat_outbox_json: string,
}

ACP_RPC_Pending :: struct {
    id: string,
    method: string,
    params_json: string,
    deadline_unix_ms: i64,
    delivery_id: string,
    role: ACP_RPC_Role,
}
ACP_RPC_Inbound :: struct {
    id_json: string,
    method: string,
    params_json: string,
    deadline_unix_ms: i64,
    response_json: string,
    // Receipt for the final chunk proves the serialized response reached stdin.
    // Empty for unanswered requests and entries in the recent replay window.
    response_delivery_id: string,
}
ACP_RPC_Write :: struct { delivery_id: string, bytes: string }

acp_state_component_ok :: proc(s: string) -> bool {
    if len(s) == 0 || len(s) > 256 || s == "." || s == ".." do return false
    for ch in s { if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '_' || ch == '-') do return false }
    return true
}

acp_state_path :: proc(data_dir, instance, epoch: string) -> (string, bool) {
    if !filepath.is_abs(data_dir) || !acp_state_component_ok(instance) || !acp_state_component_ok(epoch) do return "", false
    path, err := filepath.join({data_dir, "bridge", "acp", instance, epoch, "state.json"})
    return path, err == nil
}

acp_state_write :: proc(path: string, state: ^ACP_State) -> bool {
    if state.schema_version != 1 || state.effective_transport != "acp" do return false
    // The existing helper uses exclusive 0600 staging, file fsync, rename and
    // parent fsync (retry_journal.odin). Restrict every ACP ancestor as well.
    dir := filepath.dir(path)
    if bridge_make_directory_all(dir) != nil && !os.is_dir(dir) do return false
    when ODIN_OS != .Windows {
        current := dir
        for _ in 0..<3 {
            if os.chmod(current, {.Read_User, .Write_User, .Execute_User}) != nil do return false
            current = filepath.dir(current)
        }
    }
    raw, err := json.marshal(state^)
    if err != nil do return false
    defer delete(raw)
    return bridge_retry_atomic_write(path, raw)
}

acp_state_read :: proc(path: string) -> (ACP_State, bool) {
    raw, err := os.read_entire_file(path, context.allocator)
    if err != nil do return {}, false
    defer delete(raw)
    return acp_state_decode(string(raw))
}

acp_state_decode :: proc(raw: string) -> (state: ACP_State, ok: bool) {
    defer { if !ok do acp_state_delete(&state) }
    if !acp_rpc_json(raw) || json.unmarshal(transmute([]byte)raw, &state, spec = .JSON) != nil do return state, false
    if state.schema_version != 1 || state.effective_transport != "acp" ||
       !acp_state_component_ok(state.instance) || !acp_state_component_ok(state.launch_epoch) ||
       state.next_rpc_id == 0 || state.next_delivery_id == 0 { return state, false }
    partial, err := base64.decode(state.partial_line_base64)
    defer delete(partial)
    if err != nil || len(partial) > ACP_RPC_MAX_LINE || strings.contains(string(partial), "\n") do return state, false
    return state, true
}

acp_state_delete :: proc(s: ^ACP_State) {
    delete(s.instance); delete(s.bridge); delete(s.launch_epoch); delete(s.effective_transport)
    delete(s.provider); delete(s.profile); delete(s.run_dir); delete(s.catalog_etag)
    delete(s.adapter_version); delete(s.pipe_generation); delete(s.sessionId)
    delete(s.selected_model); delete(s.selected_mode); delete(s.partial_line_base64)
    delete(s.tool_map_json); delete(s.chat_outbox_json)
    for p in s.pending_outbound { delete(p.id); delete(p.method); delete(p.params_json); delete(p.delivery_id) }
    for p in s.pending_inbound do acp_state_inbound_delete(p)
    for p in s.recent_inbound do acp_state_inbound_delete(p)
    for w in s.pending_writes { delete(w.delivery_id); delete(w.bytes) }
    for id in s.queued_input_message_ids do delete(id)
    for id in s.completed_delivery_ids do delete(id)
    delete(s.pending_outbound); delete(s.pending_inbound); delete(s.recent_inbound); delete(s.pending_writes)
    delete(s.queued_input_message_ids); delete(s.completed_delivery_ids)
    s^ = {}
}

acp_state_inbound_delete :: proc(p: ACP_RPC_Inbound) {
    delete(p.id_json); delete(p.method); delete(p.params_json)
    delete(p.response_json); delete(p.response_delivery_id)
}
