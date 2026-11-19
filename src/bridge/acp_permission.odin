package main

import "base:runtime"
import "core:encoding/json"
import vm "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// A worker owns only immutable request data and the blocking relay call.
// Completion, timeout and cancellation all arbitrate on the RPC dispatcher.
ACP_PERMISSION_CANCELLED :: `{"outcome":{"outcome":"cancelled"}}`
ACP_Permission_Worker :: struct {
    owner: ^ACP_Runtime,
    client: ^ACP_RPC_Client,
    id, params, blocker: string,
    timeout_ms: int,
    control: Bridge_Ext_Permission_Control,
    decision: string,
    done: bool, // atomic; set after the final dispatcher call
    worker: ^thread.Thread,
}

acp_permission_id :: proc(epoch, session, id: string) -> string {
    canonical, valid := acp_rpc_id(id)
    if !valid do return ""
    tuple, _ := json.marshal([3]string{epoch, session, canonical}, allocator = context.temp_allocator)
    hash := bridge_local_hash_token(string(tuple)); defer delete(hash)
    return strings.concatenate({"acpperm_", strings.trim_prefix(hash, "sha1:")})
}

acp_permission_pending :: proc(c: ^ACP_RPC_Client, id: string) -> ^ACP_RPC_Inbound {
    key, valid := acp_rpc_id(id)
    if !valid do return nil
    i, found := c.inbound[key]
    if !found || c.state.pending_inbound[i].response_json != "" do return nil
    return &c.state.pending_inbound[i]
}

acp_permission_request :: proc(params, blocker, provider: string, timeout_ms: int) -> Bridge_Ext_Permission_Request {
    obj := acp_event_object(params)
    tool, _ := obj["toolCall"].(json.Object)
    name := acp_event_string(tool, "title")
    if name == "" do name = acp_event_string(tool, "kind")
    if name == "" do name = "Tool"
    input := "{}"
    if raw, exists := tool["rawInput"]; exists do input = acp_event_json(raw)
    return {provider = provider, tool_name = name, tool_use_id = acp_event_string(tool, "toolCallId"),
        input = input, suggestions = "[]", timeout_ms = timeout_ms, blocker_id = blocker, explicit_decision_only = true}
}

// Never substitute a persistent option for a missing once option. Duplicate
// kinds/IDs are ambiguous and fail closed too.
acp_permission_result :: proc(params, decision: string) -> string {
    kind := ""
    if decision == "allow" do kind = "allow_once"
    if decision == "deny" do kind = "reject_once"
    if kind == "" do return ACP_PERMISSION_CANCELLED
    obj := acp_event_object(params)
    options, _ := obj["options"].(json.Array)
    selected := ""
    for value in options {
        option, _ := value.(json.Object)
        if acp_event_string(option, "kind") != kind do continue
        id := acp_event_string(option, "optionId")
        if id == "" || selected != "" do return ACP_PERMISSION_CANCELLED
        selected = id
    }
    if selected == "" do return ACP_PERMISSION_CANCELLED
    for value in options {
        option, _ := value.(json.Object)
        if acp_event_string(option, "optionId") == selected && acp_event_string(option, "kind") != kind do return ACP_PERMISSION_CANCELLED
    }
    return acp_event_json(struct{outcome: struct{outcome, optionId: string}}{outcome = {"selected", selected}})
}

acp_permission_reap :: proc(r: ^ACP_Runtime, all := false) {
    for i := len(r.permissions)-1; i >= 0; i -= 1 {
        w := r.permissions[i]
        if !all && !sync.atomic_load(&w.done) do continue
        thread.join(w.worker); thread.destroy(w.worker)
        delete(w.id); delete(w.params); delete(w.blocker); free(w)
        ordered_remove(&r.permissions, i)
    }
}

acp_permission_start :: proc(r: ^ACP_Runtime, id, params: string) {
    c := r.client
    p := acp_permission_pending(c, id)
    if p == nil do return
    if !acp_runtime_current(r) || r.d.error != "" || r.d.replay_only || r.d.cancelling {
        acp_rpc_reply(c, id, ACP_PERMISSION_CANCELLED); return
    }
    if acp_permission_result(params, "allow") == ACP_PERMISSION_CANCELLED && acp_permission_result(params, "deny") == ACP_PERMISSION_CANCELLED {
        acp_rpc_reply(c, id, ACP_PERMISSION_CANCELLED); return
    }
    blocker := acp_permission_id(r.epoch, r.session, id); defer delete(blocker)
    if p.blocker_id != "" && p.blocker_id != blocker {
        acp_rpc_fail(c, "acp_protocol_error"); return
    }
    if p.blocker_id == "" {
        p.blocker_id = strings.clone(blocker)
        p.deadline_unix_ms = acp_rpc_now(c)+i64(bridge_permission_clamp_timeout(bridge_ext_permission_default_timeout_ms()))
    }
    remaining := p.deadline_unix_ms-acp_rpc_now(c)
    if remaining <= 0 { acp_permission_timeout(r, id); return }
    // This checkpoint precedes registration and waiting, even during restore
    // or a frame whose final stdout sequence has not yet been acknowledged.
    if !acp_rpc_checkpoint(c) { acp_rpc_fail(c, "acp_state_write_failed"); return }
    acp_permission_reap(r)
    if len(r.permissions) >= ACP_RPC_MAX_PENDING_INBOUND { acp_rpc_reply(c, id, ACP_PERMISSION_CANCELLED); return }
    w := new(ACP_Permission_Worker)
    w.owner = r; w.client = c
    w.id = strings.clone(id); w.params = strings.clone(params); w.blocker = strings.clone(blocker)
    w.timeout_ms = int(min(remaining, i64(PERMISSION_MAX_TIMEOUT_MS)))
    append(&r.permissions, w)
    w.worker = thread.create_and_start_with_data(w, acp_permission_worker)
}

acp_permission_worker :: proc(data: rawptr) {
    context.allocator = runtime.heap_allocator()
    arena: vm.Arena; _ = vm.arena_init_growing(&arena); defer vm.arena_destroy(&arena)
    context.temp_allocator = vm.arena_allocator(&arena)
    w := cast(^ACP_Permission_Worker)data
    req := acp_permission_request(w.params, w.blocker, w.owner.provider, w.timeout_ms)
    req.control = &w.control
    out := bridge_ext_permission_run(w.owner.rec, req)
    w.decision = out.decision
    for {
        cmd := ACP_RPC_Command{kind = .Runtime, runtime_work = acp_permission_complete, runtime_data = w}
        acp_rpc_call(w.client, &cmd)
        if cmd.ok || sync.atomic_load(&w.client.closing) do break
        time.sleep(50*time.Millisecond)
    }
    sync.atomic_store(&w.done, true)
}

acp_permission_complete :: proc(data: rawptr, c: ^ACP_RPC_Client, _: string) -> bool {
    w := cast(^ACP_Permission_Worker)data
    r := w.owner
    // Detach is a transport event: leave the durable unanswered request for the
    // next owner. Stop/interrupt explicitly reply before releasing the waiter.
    if r.quiescing || c.failed do return true
    p := acp_permission_pending(c, w.id)
    if p == nil || p.blocker_id != w.blocker do return true
    // The journal can be sealed only while the vault is unlocked. Retain the
    // relay decision on this worker until it can be committed; never stall the
    // dispatcher or turn a normal vault lock into a fatal state-write fault.
    if r.chat != nil && !acp_chat_vault_ready() do return false
    decision := w.decision
    sync.mutex_lock(&w.control.mu)
    cancelled := w.control.cancelled
    sync.mutex_unlock(&w.control.mu)
    if cancelled || !acp_runtime_current(r) || r.d.error != "" || acp_rpc_now(c) >= p.deadline_unix_ms do decision = "none"
    replied := acp_rpc_reply(c, w.id, acp_permission_result(w.params, decision))
    acp_permissions_activity(r)
    return replied
}

acp_permissions_activity :: proc(r: ^ACP_Runtime) {
    if r.quiescing || r.d.stopped || r.client.failed do return
    waiting := false
    for pending in r.client.state.pending_inbound {
        if pending.method == "session/request_permission" && pending.response_json == "" do waiting = true
    }
    // The extension relay keeps waiting_user after none for a native TUI.
    // ACP has no such fallback, and other pending requests still need attention.
    bridge_runtime_note_agent_activity(r.instance, "waiting_user" if waiting else ("active" if r.d.phase == "prompt" else "idle"), bridge_ext_activity_source(r.provider))
}

acp_permission_timeout :: proc(data: rawptr, id: string) {
    r := cast(^ACP_Runtime)data
    for w in r.permissions {
        if w.id == id do bridge_ext_permission_cancel(&w.control, r.instance, w.blocker)
    }
    acp_rpc_reply(r.client, id, ACP_PERMISSION_CANCELLED)
    acp_permissions_activity(r)
}

acp_permissions_cancel :: proc(r: ^ACP_Runtime) {
    for w in r.permissions do bridge_ext_permission_cancel(&w.control, r.instance, w.blocker)
    for p in r.client.state.pending_inbound {
        if p.method == "session/request_permission" && p.response_json == "" do acp_rpc_reply(r.client, p.id_json, ACP_PERMISSION_CANCELLED)
    }
    acp_permissions_activity(r)
}

// Quiesce on the dispatcher before the owner joins. No ownership mutex is taken
// by workers and no dispatcher callback joins a live permission thread.
acp_permissions_quiesce :: proc(data: rawptr, _: ^ACP_RPC_Client, _: string) -> bool {
    r := cast(^ACP_Runtime)data
    r.quiescing = true
    for w in r.permissions do bridge_ext_permission_cancel(&w.control, r.instance, w.blocker)
    return true
}

acp_permissions_stop :: proc(r: ^ACP_Runtime) {
    if r.client != nil {
        cmd := ACP_RPC_Command{kind = .Runtime, runtime_work = acp_permissions_quiesce, runtime_data = r}
        acp_rpc_call(r.client, &cmd)
    }
    acp_permission_reap(r, true)
    delete(r.permissions)
}
