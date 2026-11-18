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
	if !ok do return false
	command, cok := obj["command"].(json.String)
	pkg, pok := obj["adapter_package"].(json.String)
	version, vok := obj["adapter_version"].(json.String)
	protocol, iok := obj["protocol_version"].(json.Integer)
	args, aok := obj["args"].(json.Array)
	env, eok := obj["env"].(json.Object)
	if !cok || !pok || !vok || !iok || !aok || !eok do return false
	if command != "claude-agent-acp" || pkg != "@agentclientprotocol/claude-agent-acp" || protocol != 1 do return false
	for arg in args do if _, valid := arg.(json.String); !valid do return false
	for _, item in env do if _, valid := item.(json.String); !valid do return false
	mode, mok := env["CLAUDE_AGENT_ACP_PROTOCOL"].(json.String)
	if !mok || mode!="v1" do return false
	return exact_adapter_version(string(version))
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
