package main

import contracts "odin_test:contracts"

// Immutable protocol policy. Runtime callbacks run on the existing RPC
// dispatcher; string/result ownership is documented at the wrappers.
ACP_Protocol_Driver :: struct {
    durable_valid: proc(d: ^ACP_Runtime_Durable) -> bool,
    begin: proc(r: ^ACP_Runtime) -> bool,
    result: proc(data: rawptr, result: ACP_RPC_Result),
    // Notification/inbound arguments are borrowed; result callbacks own results.
    notification: proc(r: ^ACP_Runtime, method, params: string),
    inbound: proc(r: ^ACP_Runtime, id, method, params: string) -> bool,
    prompt: proc(r: ^ACP_Runtime, input: ACP_Runtime_Input, bootstrap: bool),
    ready: proc(r: ^ACP_Runtime),
    cancel: proc(r: ^ACP_Runtime) -> bool,
    steer: proc(r: ^ACP_Runtime) -> bool,
    steering_result: proc(data: rawptr, result: ACP_RPC_Result),
    inbound_timeout: proc(data: rawptr, id: string),
    probe: proc(c: ^ACP_RPC_Client, p: ^ACP_Adapter_Probe) -> bool,
    rpc: ACP_RPC_Policy,
    // Protocols can expose several approval methods and different reply shapes.
    permission_request: proc(method: string) -> bool,
    permissions_cancel: proc(r: ^ACP_Runtime),
    permission_result: proc(method, params, decision: string) -> string,
    permission_relay: proc(method, params, blocker, provider: string, timeout_ms: int) -> Bridge_Ext_Permission_Request,
    tick: proc(r: ^ACP_Runtime),
    // Whether the running turn accepts a steering input. nil means Now
    // whenever the session advertised steering support.
    can_steer: proc(r: ^ACP_Runtime) -> ACP_Steer_Readiness,
    // Opaque driver-owned durable state (ACP_Runtime_Durable.driver_state).
    // It persists in the runtime journal JSON under state_key; load reads it
    // from the whole journal JSON. Drivers without state leave these nil.
    state_key: string,
    state_load: proc(runtime_json: string) -> (rawptr, bool),
    state_save: proc(state: rawptr) -> (string, bool),
    state_delete: proc(state: rawptr),
    // Appends protocol-specific flags (temp-allocated) to a launch or probe argv.
    launch_args: proc(argv: ^[dynamic]string),
    // Converts a protocol notification (borrowed) into a usage snapshot for
    // this runtime's session; ok=false when it carries none. usage.source is
    // a constant. Called for every notification before `notification`.
    usage: proc(r: ^ACP_Runtime, method, params: string) -> (usage: contracts.Ext_Usage, ok: bool),
}

// Later: the turn will accept steering once the protocol has admitted it (e.g.
// a native turn id is still pending), so a held input waits instead of
// cancelling. Never: this turn cannot be steered.
ACP_Steer_Readiness :: enum { Now, Later, Never }

// Steering readiness for the input at the front of the steer lane. Shared by
// the inbox and Send now: inputs that already failed a steer go next turn.
acp_runtime_steer_readiness :: proc(r: ^ACP_Runtime, front: ACP_Runtime_Input) -> ACP_Steer_Readiness {
    if !r.d.steering_supported || acp_inbox_next_turn_only(front.kind) do return .Never
    driver := acp_runtime_driver(r)
    if driver.can_steer == nil do return .Now
    return driver.can_steer(r)
}

// RPC policy contains no runtime pointer and can also be used by install probes.
// The codec fields describe the protocol's wire dialect; the shared JSON-RPC
// client reads them instead of branching on a protocol name.
ACP_RPC_Policy :: struct {
    role: proc(method: string) -> ACP_RPC_Role,
    timeout: proc(method: string) -> i64,
    inbound_timeout: proc(method: string) -> i64,
    cancel_timeout: proc(method: string) -> i64,
    codec: ACP_RPC_Codec,
}
ACP_RPC_Codec :: struct {
    // Outgoing frames carry "jsonrpc":"2.0" and incoming frames must carry it.
    // Without it the header is omitted and only checked when present.
    jsonrpc_header: bool,
    // Request IDs go on the wire as the positive signed-integer counter and only
    // integer responses correlate. Otherwise the quoted epoch-scoped ID is sent
    // and string/number response IDs keep their distinction.
    integer_ids: bool,
    // A notification with malformed params is dropped instead of failing the
    // connection.
    drop_malformed_notifications: bool,
}
ACP_RPC_POLICY_ACP :: ACP_RPC_Policy{
    acp_driver_acp_rpc_role, acp_driver_acp_rpc_timeout,
    acp_driver_acp_inbound_timeout, acp_driver_acp_cancel_timeout,
    {jsonrpc_header = true},
}

acp_protocol_acp_driver := ACP_Protocol_Driver{
    durable_valid = acp_driver_acp_durable_valid,
    begin = acp_driver_acp_begin, result = acp_driver_acp_result,
    notification = acp_driver_acp_notification, inbound = acp_driver_acp_inbound,
    prompt = acp_driver_acp_prompt, ready = acp_driver_acp_ready,
    cancel = acp_driver_acp_cancel, steer = acp_driver_acp_steer,
    steering_result = acp_driver_acp_steering_result,
    inbound_timeout = acp_permission_timeout, probe = acp_driver_acp_probe,
    rpc = ACP_RPC_POLICY_ACP, permission_request = acp_driver_acp_permission_request,
    permissions_cancel = acp_permissions_cancel,
    permission_result = acp_driver_acp_permission_result,
    permission_relay = acp_driver_acp_permission_relay,
    usage = acp_driver_acp_usage,
}

acp_protocol_driver :: proc(protocol: contracts.ACP_Protocol) -> ^ACP_Protocol_Driver {
    switch protocol {
    case .ACP: return &acp_protocol_acp_driver
    case .Codex_App_Server: return &acp_protocol_codex_driver
    }
    return nil
}

// Production owners freeze their driver at construction. The fallback supports
// zero-initialized ACP test/embedded owners without selecting an unknown protocol.
acp_runtime_driver :: proc(r: ^ACP_Runtime) -> ^ACP_Protocol_Driver {
    if r.driver != nil do return r.driver
    return acp_protocol_driver(r.descriptor.protocol)
}
