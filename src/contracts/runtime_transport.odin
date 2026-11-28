package contracts

import "core:encoding/json"
import "core:strings"

ACP_Recipe :: struct {
	command: string `json:"command"`,
	args: []string `json:"args"`,
	env: map[string]string `json:"env"`,
	protocol_version: int `json:"protocol_version"`,
	adapter_package: string `json:"adapter_package"`,
	adapter_version: string `json:"adapter_version"`,
}

// Only absent legacy values normalize to PTY. Unknown explicit values fail.
runtime_transport_or_pty :: proc(value: string) -> string {
	return "pty" if value == "" else value
}

runtime_transport_valid :: proc(value: string) -> bool {
	return value == "pty" || value == "acp"
}

// What an explicit Send now needs from the Hub, per runtime transport. It is
// a property of the runtime adapter an instance was launched with (its frozen
// runtime_transport), not of the provider: one provider can run under either
// transport. Shared Hub and UI code read this, never a transport name.
//   Members: the runtime delivers message bodies; the Hub freezes the
//            turn-held messages as the batch members (ACP).
//   Notice:  the agent reads its own conversation (chat read returns every
//            unread message), so the Hub sends only a request id and the
//            bridge types the unread notice (PTY).
Runtime_Send_Now :: enum u8 { Unsupported, Members, Notice }

RUNTIME_SEND_NOW_WIRE := [Runtime_Send_Now]string {
	.Unsupported = "",
	.Members     = "members",
	.Notice      = "notice",
}

Runtime_Transport_Capabilities :: struct {
	send_now: Runtime_Send_Now,
}

@(private)
Runtime_Transport_Entry :: struct { transport: string, caps: Runtime_Transport_Capabilities }

@(private)
runtime_transport_table := [?]Runtime_Transport_Entry{
	{"pty", {send_now = .Notice}},
	{"acp", {send_now = .Members}},
}

// runtime_transport_capabilities: an unknown transport supports nothing.
runtime_transport_capabilities :: proc(transport: string) -> Runtime_Transport_Capabilities {
	for e in runtime_transport_table do if e.transport == transport do return e.caps
	return {}
}

// The outcome of an explicit Send now at the agent's runtime. Only Delivered
// means the agent was asked to read now. Every other outcome keeps the unread
// notice queued at the bridge; the bridge reports it as the cause of a failed
// command result, and the Hub records the batch as not delivered with the
// outcome's batch error (the UI's reason key). A queued outcome is not a
// failure: the notice goes out at the agent's next trusted idle.
//   Failed:      the terminal did not take it.
//   Not_Running: the agent is stopped, dead or not started yet.
//   Held:        a context rollover is in progress (queued).
Runtime_Send_Now_Outcome :: enum u8 { Delivered, Failed, Not_Running, Held }

// Failed keeps the bridge's historic generic cause.
RUNTIME_SEND_NOW_CAUSE := [Runtime_Send_Now_Outcome]string {
	.Delivered   = "",
	.Failed      = "acp_runtime_unavailable",
	.Not_Running = "agent_not_running",
	.Held        = "runtime_held",
}

RUNTIME_SEND_NOW_BATCH_ERROR := [Runtime_Send_Now_Outcome]string {
	.Delivered   = "",
	.Failed      = "send_failed",
	.Not_Running = "agent_stopped",
	.Held        = "held",
}

// runtime_send_now_outcome_from_cause reads a bridge refusal's cause; an
// unknown cause is a plain failure.
runtime_send_now_outcome_from_cause :: proc(cause: string) -> Runtime_Send_Now_Outcome {
	if cause == "" do return .Failed
	for c, o in RUNTIME_SEND_NOW_CAUSE do if o != .Delivered && c == cause do return o
	return .Failed
}

// runtime_send_now_outcome_queued: the notice waits for the next trusted idle.
runtime_send_now_outcome_queued :: proc(o: Runtime_Send_Now_Outcome) -> bool {
	return o == .Held
}

provider_supports_transport :: proc(raw, transport: string) -> bool {
	if !runtime_transport_valid(transport) do return false
	if raw == "" do return transport == "pty"
	value, err := json.parse(raw)
	if err != nil do return false
	defer json.destroy_value(value)
	array, ok := value.(json.Array)
	if !ok || len(array) < 1 || len(array) > 2 do return false
	found := false
	for item, i in array {
		name, valid := item.(json.String)
		if !valid || !runtime_transport_valid(string(name)) do return false
		for prev in array[:i] do if previous, valid := prev.(json.String); valid && previous==name do return false
		if string(name) == transport do found = true
	}
	return found
}

// The catalog owns executable recipes. Status reports never supply commands.
acp_recipe_valid :: proc(raw: string) -> bool {
	value, err := json.parse(raw, parse_integers = true)
	if err != nil do return false
	defer json.destroy_value(value)
	return acp_recipe_value_valid(value)
}

acp_recipe_value_valid :: proc(value: json.Value) -> bool {
	obj, ok := value.(json.Object)
	if !ok || len(obj) != 6 do return false
	command, cok := obj["command"].(json.String)
	pkg, pok := obj["adapter_package"].(json.String)
	version, vok := obj["adapter_version"].(json.String)
	protocol, iok := obj["protocol_version"].(json.Integer)
	args, aok := obj["args"].(json.Array)
	env, eok := obj["env"].(json.Object)
	if !cok || !pok || !vok || !iok || !aok || !eok do return false
	for d in acp_provider_descriptors {
		if string(command) != d.command || string(pkg) != d.pkg.name || string(version) != d.pkg.version ||
		   int(protocol) != d.protocol_version || len(args) != len(d.args) || len(env) != len(d.env) { continue }
		matches := true
		for arg, i in args do if s, valid := arg.(json.String); !valid || string(s) != d.args[i] do matches = false
		for pair in d.env do if s, valid := env[pair[0]].(json.String); !valid || string(s) != pair[1] do matches = false
		if matches do return true
	}
	return false
}

// Bind a valid recipe to its catalog provider, preventing a copied Claude
// recipe from enabling a different provider.
acp_provider_recipe_valid :: proc(provider, raw: string) -> bool {
	d, known := acp_provider_descriptor(provider)
	if !known do return false
	value, err := json.parse(raw, parse_integers = true)
	if err != nil do return false
	defer json.destroy_value(value)
	if !acp_recipe_value_valid(value) do return false
	obj := value.(json.Object)
	command, _ := obj["command"].(json.String)
	return string(command) == d.command
}

exact_adapter_version :: proc(version: string) -> bool {
	// Exact numeric semver pins; ranges, tags, shell fragments and prefixes fail.
	parts := strings.split(version, ".", context.temp_allocator)
	if len(parts) != 3 do return false
	for part in parts {
		if len(part) == 0 || (len(part) > 1 && part[0] == '0') do return false
		for c in part do if c < '0' || c > '9' do return false
	}
	return true
}

// Features are replaced on hello. acp_runtime_v1 is advertised only once the
// Bridge has detected compatible piped hosting, so this gates both capabilities.
bridge_supports_acp_runtime :: proc(raw: string) -> bool {
	value, err := json.parse(raw)
	if err != nil do return false
	defer json.destroy_value(value)
	obj, ok := value.(json.Object)
	if !ok do return false
	features, valid := obj["features"].(json.Array)
	if !valid do return false
	for feature in features do if name, valid := feature.(json.String); valid && name==BRIDGE_FEATURE_ACP_RUNTIME do return true
	return false
}

// The bridge's deadline for one install_acp_adapter command (an npm install or
// a probe Re-check), shared so the Hub never gives up on a live one first.
ACP_INSTALL_COMMAND_TIMEOUT_MS :: 140_000

// ACP availability is the Hub's single verdict for one bridge + provider pair
// (GET /api/v1/bridges/{id}/provider-status providers[].acp_availability). The
// UI renders it and never re-derives the rules. Mirrored in TS as
// AcpAvailability (src/ui/components/providers/providerRuntime.ts).
ACP_Availability_Reason :: enum u8 {
	Ready,
	No_Recipe,
	Unsupported_Bridge,
	Adapter_Missing,
	Adapter_Outdated,
	Adapter_Missing_Node,
	Adapter_Missing_Npm,
	Adapter_Error,
	Installing,
	Not_Checked,
}

ACP_Availability_Fix :: enum u8 {
	None, // serialized as JSON null
	Update_Bridge,
	Install_Adapter,
	Check_Now,
}

ACP_AVAILABILITY_REASON_WIRE := [ACP_Availability_Reason]string {
	.Ready                = "ready",
	.No_Recipe            = "no_recipe",
	.Unsupported_Bridge   = "unsupported_bridge",
	.Adapter_Missing      = "adapter_missing",
	.Adapter_Outdated     = "adapter_outdated",
	.Adapter_Missing_Node = "adapter_missing_node",
	.Adapter_Missing_Npm  = "adapter_missing_npm",
	.Adapter_Error        = "adapter_error",
	.Installing           = "installing",
	.Not_Checked          = "not_checked",
}

ACP_AVAILABILITY_FIX_WIRE := [ACP_Availability_Fix]string {
	.None            = "",
	.Update_Bridge   = "update_bridge",
	.Install_Adapter = "install_adapter",
	.Check_Now       = "check_now",
}

ACP_Availability :: struct {
	available: bool,
	reason:    ACP_Availability_Reason,
	fix:       ACP_Availability_Fix,
}

// Each reason has exactly one fix; the pair is never chosen independently.
acp_availability_for :: proc(reason: ACP_Availability_Reason) -> ACP_Availability {
	switch reason {
	case .Ready:
		return {available = true, reason = reason, fix = .None}
	case .No_Recipe, .Installing:
		return {reason = reason, fix = .None}
	case .Unsupported_Bridge:
		return {reason = reason, fix = .Update_Bridge}
	case .Adapter_Missing, .Adapter_Outdated, .Adapter_Missing_Node, .Adapter_Missing_Npm, .Adapter_Error:
		return {reason = reason, fix = .Install_Adapter}
	case .Not_Checked:
		return {reason = reason, fix = .Check_Now}
	}
	return {reason = .Not_Checked, fix = .Check_Now}
}

// Writes {"available":bool,"reason":"...","fix":"..."|null}.
write_acp_availability_json :: proc(b: ^strings.Builder, value: ACP_Availability) {
	strings.write_string(b, `{"available":`)
	strings.write_string(b, "true" if value.available else "false")
	strings.write_string(b, `,"reason":"`)
	strings.write_string(b, ACP_AVAILABILITY_REASON_WIRE[value.reason])
	strings.write_string(b, `","fix":`)
	if value.fix == .None {
		strings.write_string(b, "null")
	} else {
		strings.write_byte(b, '"')
		strings.write_string(b, ACP_AVAILABILITY_FIX_WIRE[value.fix])
		strings.write_byte(b, '"')
	}
	strings.write_byte(b, '}')
}
