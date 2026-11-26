package main

import "base:runtime"
import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:sync"
import agent_runtime "odin_test:lib/agent_runtime"
import contracts "odin_test:contracts"

ACP_INITIALIZE_PARAMS :: `{"protocolVersion":1,"clientInfo":{"name":"heimdall","version":"`+contracts.APP_VERSION+`"},"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false}}`

acp_runtime_session_params :: proc(r: ^ACP_Runtime) -> string {
    raw, _ := json.marshal(struct{cwd: string, mcpServers: []string}{r.run_dir, {}} , allocator = context.temp_allocator)
    return string(raw)
}

acp_runtime_configure :: proc(r: ^ACP_Runtime, category, value, failure: string) {
    if category == "mode" && r.descriptor.permission_policy == .Once_Only {
        if !contracts.acp_descriptor_effective_mode_valid(r.descriptor, value) {
            acp_runtime_error(r, failure); return
        }
        // Once-only policy is enforced by the bridge for each inbound request.
        // Provider session/reasoning modes are unrelated to tool approval.
        acp_runtime_ready(r)
        return
    }
    bound := r.descriptor.model_category if category == "model" else r.descriptor.permission_category
    id, ok := acp_config_selection(r.d.config_json, bound, value)
    defer delete(id)
    if !ok { acp_runtime_error(r, failure); return }
    acp_runtime_replace(&r.d.phase, category)
    raw, _ := json.marshal(struct{sessionId, configId, value: string}{r.session, id, value}, allocator = context.temp_allocator)
    acp_runtime_request(r, "session/set_config_option", string(raw))
}

// Embedded resources are optional in ACP; resource_link is baseline. Only a
// descriptor that opts in may fall back to linking the bootstrap file.
acp_runtime_bootstrap_supported :: proc(r: ^ACP_Runtime) -> bool {
    return r.d.embedded_context || r.descriptor.bootstrap_resource_link
}

// The descriptor's agent-default model keeps the agent's own model choice.
acp_runtime_model_selected :: proc(r: ^ACP_Runtime) -> bool {
    return r.model != "" && (r.descriptor.agent_default_model == "" || r.model != r.descriptor.agent_default_model)
}

acp_driver_acp_ready :: proc(r: ^ACP_Runtime) {
    if !r.d.starter_sent && !acp_runtime_bootstrap_supported(r) { acp_runtime_error(r, "acp_bootstrap_unsupported"); return }
    r.d.ready = true
    acp_events_ready(r)
    acp_runtime_replace(&r.d.phase, "ready")
    if !acp_rpc_checkpoint(r.client) { acp_runtime_error(r, "acp_state_write_failed"); return }
    if !acp_runtime_current(r) do return
    sync.mutex_lock(&bridge_runtime_mutex)
    for &inst in bridge_runtime_instances do if inst.agent_instance_id == r.instance do inst.acp_session_ready = true
    sync.mutex_unlock(&bridge_runtime_mutex)
    bridge_startup_accept(r.rec, bridge_runtime_now_ms())
    bridge_runtime_mark_start_success(r.instance)
    if !r.d.starter_sent {
        r.d.starter_sent = true
        acp_runtime_prompt(r, {id = "starter", text = agent_runtime.render_acp_starter_prompt(r.d.starter, !r.d.embedded_context)}, bootstrap = true)
    } else {
        acp_runtime_drain(r)
    }
}

acp_driver_acp_prompt :: proc(r: ^ACP_Runtime, input: ACP_Runtime_Input, bootstrap := false) {
    r.d.cancelling = false
    acp_runtime_replace(&r.d.phase, "prompt")
    acp_runtime_replace(&r.d.current_input, input.id)
    blocks := make([dynamic]json.Value, allocator = context.temp_allocator)
    text := make(json.Object, allocator = context.temp_allocator)
    text["type"] = json.String("text"); text["text"] = json.String(input.text); append(&blocks, text)
    if bootstrap {
        if !acp_runtime_bootstrap_supported(r) { acp_runtime_error(r, "acp_bootstrap_unsupported"); return }
        path := strings.concatenate({r.run_dir, "/", r.binding.bootstrap_filename}, context.temp_allocator)
        uri := strings.concatenate({"file://", path}, context.temp_allocator)
        block := make(json.Object, allocator = context.temp_allocator)
        if r.d.embedded_context {
            content, err := os.read_entire_file(path, context.temp_allocator)
            if err != nil { acp_runtime_error(r, "acp_bootstrap_unsupported"); return }
            resource := make(json.Object, allocator = context.temp_allocator)
            resource["uri"] = json.String(uri)
            resource["mimeType"] = json.String("text/markdown"); resource["text"] = json.String(string(content))
            block["type"] = json.String("resource"); block["resource"] = resource
        } else {
            if !os.exists(path) { acp_runtime_error(r, "acp_bootstrap_unsupported"); return }
            block["type"] = json.String("resource_link"); block["uri"] = json.String(uri)
            block["name"] = json.String(r.binding.bootstrap_filename); block["mimeType"] = json.String("text/markdown")
        }
        append(&blocks, block)
    }
    raw, _ := json.marshal(struct{sessionId: string, prompt: []json.Value}{r.session, blocks[:]}, allocator = context.temp_allocator)
    if acp_runtime_events.prompt_started != nil do acp_runtime_events.prompt_started(r, input.id)
    if acp_runtime_request(r, "session/prompt", string(raw)) {
        bridge_runtime_note_agent_activity(r.instance, "active", "acp")
    }
}

acp_driver_acp_result :: proc(data: rawptr, result: ACP_RPC_Result) {
    defer acp_rpc_result_delete(result)
    r := cast(^ACP_Runtime)data
    if !acp_runtime_current(r) || r.d.error != "" do return
    if !result.ok {
        // A failed attachment does not prove process death. The owner replaces
        // the RPC connection from its last checkpoint after this callback exits.
        if result.error.message == "acp_pipe_lost" || result.error.message == "acp_pipe_gap" do return
        // Local RPC shutdown/timeouts use -32000 too; they are never auth.
        local := strings.has_prefix(result.error.message, "acp_")
        safe_reason := "acp_rpc_failed"
        switch result.error.message {
        case "acp_pipe_lost", "acp_pipe_write_failed", "acp_adapter_exited", "acp_rpc_timeout", "acp_protocol_error", "acp_state_write_failed": safe_reason = result.error.message
        }
        acp_runtime_error(r, "acp_auth_required" if result.error.code == -32000 && !local else safe_reason, auth = result.error.code == -32000 && !local)
        return
    }
    root, err := json.parse(result.result_json, parse_integers = true)
    if err != nil { acp_runtime_error(r, "acp_protocol_error"); return }
    defer json.destroy_value(root)
    obj, valid := root.(json.Object)
    if !valid { acp_runtime_error(r, "acp_protocol_error"); return }
    switch r.d.phase {
    case "initialize":
        version, _ := obj["protocolVersion"].(json.Integer)
        if version != 1 { acp_runtime_error(r, "acp_protocol_error"); return }
        r.initialized = true
        caps, _ := obj["agentCapabilities"].(json.Object)
        load, _ := caps["loadSession"].(json.Boolean); r.load_session = bool(load)
        prompts, _ := caps["promptCapabilities"].(json.Object)
        embedded, _ := prompts["embeddedContext"].(json.Boolean); r.d.embedded_context = bool(embedded)
        meta, _ := obj["_meta"].(json.Object)
        steering, _ := meta["steering"].(json.Object)
        supported, _ := steering["supported"].(json.Boolean); r.d.steering_supported = bool(supported)
        if r.recovering {
            if !r.load_session { acp_runtime_error(r, "acp_pipe_lost"); return }
            r.d.replay_only = true; acp_runtime_replace(&r.d.phase, "load")
            raw, _ := json.marshal(struct{sessionId, cwd: string, mcpServers: []string}{r.session, r.run_dir, {}}, allocator = context.temp_allocator)
            acp_runtime_request(r, "session/load", string(raw))
        } else {
            if !acp_runtime_bootstrap_supported(r) { acp_runtime_error(r, "acp_bootstrap_unsupported"); return }
            acp_runtime_replace(&r.d.phase, "new")
            acp_runtime_request(r, "session/new", acp_runtime_session_params(r))
        }
    case "new", "load":
        if r.d.phase == "new" {
            session, _ := obj["sessionId"].(json.String)
            if session == "" { acp_runtime_error(r, "acp_protocol_error"); return }
            acp_runtime_replace(&r.session, string(session))
        }
        r.d.replay_only = false
        acp_runtime_replace(&r.d.config_json, result.result_json)
        if acp_runtime_model_selected(r) { acp_runtime_configure(r, "model", r.model, "acp_model_unavailable") }
        else { acp_runtime_configure(r, "mode", r.mode, "acp_permission_mode_unsupported") }
    case "model", "mode":
        category := r.d.phase
        value := r.model if category == "model" else r.mode
        bound := r.descriptor.model_category if category == "model" else r.descriptor.permission_category
        id, selected := acp_config_selection(result.result_json, bound, value, selected = true); delete(id)
        if !selected { acp_runtime_error(r, "acp_model_unavailable" if category == "model" else "acp_permission_mode_unsupported"); return }
        acp_runtime_replace(&r.d.config_json, result.result_json)
        if category == "model" { acp_runtime_configure(r, "mode", r.mode, "acp_permission_mode_unsupported") }
        else { acp_runtime_ready(r) }
    case "prompt":
        reason, _ := obj["stopReason"].(json.String)
        switch string(reason) {
        case "end_turn", "max_tokens", "max_turn_requests", "refusal", "cancelled":
        case: acp_runtime_error(r, "acp_protocol_error"); return
        }
        acp_permissions_cancel(r)
        if acp_runtime_events.prompt_finished != nil do acp_runtime_events.prompt_finished(r, r.d.current_input, result.result_json, "")
        append(&r.d.completed_inputs, strings.clone(r.d.current_input))
        if len(r.d.completed_inputs) > 256 { delete(r.d.completed_inputs[0]); ordered_remove(&r.d.completed_inputs, 0) }
        acp_runtime_replace(&r.d.current_input, ""); acp_runtime_replace(&r.d.phase, "ready")
        bridge_runtime_note_agent_activity(r.instance, "idle", "acp")
        acp_runtime_drain(r)
    }
}

acp_driver_acp_notification :: proc(r: ^ACP_Runtime, method, params: string) {
    if acp_runtime_events.notification != nil do acp_runtime_events.notification(r, method, params)
}
acp_driver_acp_inbound :: proc(r: ^ACP_Runtime, id, method, params: string) -> bool {
    if method != "session/request_permission" do return false
    obj := acp_event_object(params)
    if r.session == "" || acp_event_string(obj, "sessionId") != r.session { acp_rpc_reply_error(r.client,id,{code=-32602,message="wrong ACP session"}); return true }
    acp_permission_start(r, id, params)
    return true
}

acp_driver_acp_steer :: proc(r: ^ACP_Runtime) -> bool {
    raw, _ := json.marshal(struct{
        sessionId: string,
        prompt: [1]struct{type, text: string},
        _meta: struct{steering: struct{idleBehavior: string}},
    }{sessionId = r.session, prompt = {{"text", r.d.steering_input.text}}, _meta = {steering = {idleBehavior = "promptRequired"}}}, allocator = context.temp_allocator)
    id, sent := acp_rpc_request(r.client, "_session/steering", string(raw), 0, {acp_inbox_steering_result, r})
    delete(string(id))
    return sent
}

acp_driver_acp_steering_result :: proc(data: rawptr, result: ACP_RPC_Result) {
    defer acp_rpc_result_delete(result)
    r := cast(^ACP_Runtime)data
    if !acp_runtime_current(r) || r.d.error != "" do return
    // A lost connection restores this pending RPC and its exact completion;
    // it must not consume or resubmit an ambiguous steering input.
    if !result.ok && (result.error.message == "acp_pipe_lost" || result.error.message == "acp_pipe_gap") do return
    outcome := ""
    if result.ok {
        obj := acp_event_object(result.result_json)
        outcome = acp_event_string(obj, "outcome")
    }
    if outcome != "injected" && outcome != "promptRequired" && (result.ok || result.error.code != -32601) {
        acp_runtime_error(r, "acp_rpc_failed"); return
    }
    input := r.d.steering_input; r.d.steering_input = {}; r.d.steering_pending = false
    if outcome == "injected" {
        if input.id!="" && r.d.phase=="prompt" do acp_chat_boundary(r)
        acp_delivery_steer_injected(r, input)
        acp_inbox_remember(r, input.id); acp_inbox_input_delete(input)
    } else {
        if !result.ok do r.d.steering_supported = false
        // Front reinsertion keeps FIFO; the input is never steered again.
        acp_delivery_steer_rejected(r, input)
    }
    if !acp_rpc_checkpoint(r.client) { acp_runtime_error(r, "acp_state_write_failed"); return }
    acp_runtime_drain(r)
}

acp_driver_acp_probe_result :: proc(data: rawptr, result: ACP_RPC_Result) {
    defer acp_rpc_result_delete(result)
    p := cast(^ACP_Adapter_Probe)data
    value, err := json.parse(result.result_json, parse_integers = true)
    valid := false
    if err == nil {
        if obj, ok := value.(json.Object); ok { v, _ := obj["protocolVersion"].(json.Integer); valid = v == 1 }
        json.destroy_value(value)
    }
    sync.mutex_lock(&p.mu); p.ok = result.ok && valid; p.done = true; sync.cond_broadcast(&p.cond); sync.mutex_unlock(&p.mu)
}

acp_driver_acp_begin :: proc(r: ^ACP_Runtime) -> bool {
    return acp_runtime_request(r, "initialize", ACP_INITIALIZE_PARAMS)
}
acp_driver_acp_cancel :: proc(r: ^ACP_Runtime) -> bool {
    raw, _ := json.marshal(struct{sessionId: string}{r.session}, allocator = context.temp_allocator)
    return acp_rpc_notify(r.client, "session/cancel", string(raw))
}
acp_driver_acp_probe :: proc(c: ^ACP_RPC_Client, p: ^ACP_Adapter_Probe) -> bool {
    id, sent := acp_rpc_request(c, "initialize", ACP_INITIALIZE_PARAMS, 15000, {acp_driver_acp_probe_result, p})
    delete(string(id))
    return sent
}

acp_driver_acp_rpc_role :: proc(method: string) -> ACP_RPC_Role {
    switch method {
    case "initialize": return .Initialize
    case "session/new": return .New
    case "session/load": return .Load
    case "session/set_config_option": return .Config
    case "session/prompt": return .Prompt
    case "_session/steering": return .Steering
    }
    return .Other
}

acp_driver_acp_rpc_timeout :: proc(method: string) -> i64 {
    if method == "session/prompt" do return 0
    if method == "session/new" || method == "session/load" do return 60000
    return 15000
}
acp_driver_acp_inbound_timeout :: proc(method: string) -> i64 {
    return 300000 if method == "session/request_permission" else 0
}
acp_driver_acp_cancel_timeout :: proc(method: string) -> i64 {
    return 10000 if method == "session/cancel" else 0
}

acp_driver_acp_durable_valid :: proc(d: ^ACP_Runtime_Durable) -> bool {
    switch d.phase {
    case "initialize", "new", "load", "model", "mode", "ready", "prompt":
    case: return false
    }
    switch d.error {
    case "", "acp_auth_required", "acp_pipe_lost", "acp_pipe_write_failed", "acp_adapter_exited", "acp_rpc_timeout", "acp_rpc_failed", "acp_protocol_error", "acp_state_write_failed", "acp_bootstrap_unsupported", "acp_model_unavailable", "acp_permission_mode_unsupported", "acp_chat_publish_rejected":
    case: return false
    }
    if len(d.config_json) > ACP_RPC_MAX_LINE || len(d.plan_json)>64*1024 || len(d.starter) > ACP_RPC_MAX_LINE || len(d.current_input) > 1024 || len(d.queue) > 128 || len(d.completed_inputs) > 256 || d.stream_retries < 0 || d.stream_retries > 4 do return false
    bytes := len(d.steering_input.text)
    for input in d.queue {
        if !acp_inbox_input_valid(input) do return false
        bytes += len(input.text)
    }
    if bytes > ACP_INBOX_MAX_BYTES || len(d.queue)+int(d.steering_pending) > 128 || d.steering_pending != (d.steering_input.id != "") ||
       (d.steering_pending && !acp_inbox_input_valid(d.steering_input)) { return false }
    if d.batch_first_ms < 0 || d.batch_last_ms < d.batch_first_ms || d.last_notice_turn_ms < 0 do return false
    for id in d.completed_inputs do if id == "" || len(id) > 1024 do return false
    if d.report_seq < 0 || !acp_send_now_valid(&d.send_now) do return false
    return true
}

acp_driver_acp_permission_request :: proc(method: string) -> bool {
    return method == "session/request_permission"
}

acp_driver_acp_permission_result :: proc(method, params, decision: string) -> string {
    return acp_permission_result(params, decision)
}
acp_driver_acp_permission_relay :: proc(method, params, blocker, provider: string, timeout_ms: int) -> Bridge_Ext_Permission_Request {
    return acp_permission_request(params, blocker, provider, timeout_ms)
}
