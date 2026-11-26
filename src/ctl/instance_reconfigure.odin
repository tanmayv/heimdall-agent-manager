package main

// `ham-ctl agents instance reconfigure|reconfigurations|cancel-reconfiguration`.
//
// POST /api/v1/agent-instances/{id}/reconfigurations takes a FULL destination
// (bridge_id, project_id, provider, model, expected_revision, idempotency_key)
// and rejects unknown keys. The CLI reads the current instance first and fills
// every flag the caller left out from it. project_id is ALWAYS sent: an empty
// project_id clears the instance's project. permission_mode and
// runtime_transport are optional on the wire (omitted keeps the instance's
// current value), so they are sent only when the caller names them.
// provider_profile is kept when the provider stays the same and omitted when it
// changes, so the hub selects the new provider's default profile.

import "core:encoding/json"
import "core:strconv"
import "core:strings"
import os_random "odin_test:lib/os_random"
import vault "odin_test:lib/vault"

// Ctl_Instance_Config is the part of GET /api/v1/agent-instances/{id} that a
// reconfiguration destination is filled from.
Ctl_Instance_Config :: struct {
	bridge_id:              string,
	project_id:             string,
	provider:               string,
	provider_profile:       string,
	model:                  string,
	configuration_revision: int,
}

// Field order and omitempty match the hub's create handler: the required keys
// are always present (project_id may be ""), the optional ones only when set.
Ctl_Reconfigure_Body :: struct {
	bridge_id:         string `json:"bridge_id"`,
	project_id:        string `json:"project_id"`,
	provider:          string `json:"provider"`,
	provider_profile:  string `json:"provider_profile,omitempty"`,
	model:             string `json:"model"`,
	permission_mode:   string `json:"permission_mode,omitempty"`,
	runtime_transport: string `json:"runtime_transport,omitempty"`,
	apply:             string `json:"apply,omitempty"`,
	expected_revision: int    `json:"expected_revision"`,
	idempotency_key:   string `json:"idempotency_key"`,
}

Ctl_Reconfigure_Params :: struct {
	instance_id:     string               `json:"instance_id"`,
	reconfiguration: Ctl_Reconfigure_Body `json:"reconfiguration"`,
}

Ctl_Reconfiguration_Cancel_Params :: struct {
	instance_id:                 string `json:"instance_id"`,
	idempotency_key:             string `json:"idempotency_key"`,
	expected_operation_revision: int    `json:"expected_operation_revision"`,
}

// The hub marshals the phase as its enum ordinal; this order matches
// domain.Instance_Reconfiguration_Phase (waiting_for_idle was appended).
CTL_RECONFIGURATION_PHASES :: [?]string{"prepared", "stopping", "source_stopped", "launching", "ready", "failed", "recovery_required", "waiting_for_idle"}

// ctl_bridge_response_data unwraps a local Bridge response
// {"ok":true,"data":<hub body>} and the hub's {"data":...} envelope. On a
// failed call it returns the response's message. Temp-allocated.
ctl_bridge_response_data :: proc(response: string) -> (json.Object, bool, string) {
	value, err := json.parse_string(response, .JSON, true, context.temp_allocator)
	if err != nil do return nil, false, "the Bridge returned a response that is not JSON"
	root, is_object := value.(json.Object)
	if !is_object do return nil, false, "the Bridge returned a response that is not a JSON object"
	if ok, has_ok := root["ok"].(json.Boolean); has_ok && !bool(ok) {
		if message, has_message := root["message"].(json.String); has_message do return nil, false, string(message)
		if failure, has_error := root["error"].(json.Object); has_error {
			if message, has_message := failure["message"].(json.String); has_message do return nil, false, string(message)
		}
		return nil, false, "the request failed"
	}
	data, has_data := root["data"].(json.Object)
	if !has_data do return nil, false, "the Bridge response has no data"
	if inner, has_inner := data["data"].(json.Object); has_inner do return inner, true, ""
	return data, true, ""
}

ctl_json_object_string :: proc(object: json.Object, key: string) -> string {
	if value, ok := object[key].(json.String); ok do return string(value)
	return ""
}

ctl_json_object_int :: proc(object: json.Object, key: string) -> (int, bool) {
	#partial switch value in object[key] {
	case json.Integer: return int(value), true
	case json.Float: return int(value), f64(int(value)) == f64(value)
	}
	return 0, false
}

// ctl_instance_config_from_response reads the current configuration from an
// agent.agents.instance_get response.
ctl_instance_config_from_response :: proc(response: string) -> (Ctl_Instance_Config, bool, string) {
	data, ok, message := ctl_bridge_response_data(response)
	if !ok do return {}, false, message
	config := Ctl_Instance_Config{
		bridge_id        = ctl_json_object_string(data, "bridge_id"),
		project_id       = ctl_json_object_string(data, "project_id"),
		provider         = ctl_json_object_string(data, "provider"),
		provider_profile = ctl_json_object_string(data, "provider_profile"),
		model            = ctl_json_object_string(data, "model"),
	}
	revision, has_revision := ctl_json_object_int(data, "configuration_revision")
	if !has_revision || config.bridge_id == "" || config.provider == "" do return {}, false, "the instance response has no current configuration (bridge_id, provider, configuration_revision)"
	config.configuration_revision = revision
	return config, true, ""
}

// ctl_reconfigure_params builds the agent.agents.instance_reconfigure params:
// the full destination, with every flag the caller left out filled from
// `current`. The returned string is temp-allocated.
ctl_reconfigure_params :: proc(instance_id: string, current: Ctl_Instance_Config, args: []string, idempotency_key: string) -> (string, bool, string) {
	if strings.trim_space(instance_id) == "" do return "", false, "reconfigure needs an <agent-instance-id>"
	body := Ctl_Reconfigure_Body{
		bridge_id         = strings.trim_space(option_value(args, "--bridge", current.bridge_id)),
		project_id        = current.project_id,
		provider          = strings.trim_space(option_value(args, "--provider", current.provider)),
		model             = strings.trim_space(option_value(args, "--model", current.model)),
		expected_revision = current.configuration_revision,
		idempotency_key   = idempotency_key,
	}
	if body.bridge_id == "" || body.provider == "" || body.model == "" do return "", false, "--bridge, --provider and --model must not be empty"
	if profile := strings.trim_space(option_value(args, "--profile", "")); profile != "" {
		body.provider_profile = profile
	} else if body.provider == current.provider {
		body.provider_profile = current.provider_profile
	}
	if mode := option_value(args, "--permission-mode", ""); mode != "" {
		if mode != "yolo" && mode != "ask" do return "", false, "--permission-mode must be yolo or ask"
		body.permission_mode = mode
	}
	if transport := option_value(args, "--transport", ""); transport != "" {
		if transport != "pty" && transport != "acp" do return "", false, "--transport must be pty or acp"
		body.runtime_transport = transport
	}
	if apply := option_value(args, "--apply", ""); apply != "" {
		if apply != "now" && apply != "after_turn" do return "", false, "--apply must be now or after_turn"
		body.apply = apply
	}
	if revision_text := option_value(args, "--expected-revision", ""); revision_text != "" {
		revision, parsed := strconv.parse_int(strings.trim_space(revision_text), 10)
		if !parsed || revision < 0 do return "", false, "--expected-revision must be a non-negative integer"
		body.expected_revision = revision
	}
	if strings.trim_space(body.idempotency_key) == "" || len(body.idempotency_key) > 128 do return "", false, "--idempotency-key must be 1-128 characters"
	data, err := json.marshal(Ctl_Reconfigure_Params{instance_id = instance_id, reconfiguration = body}, allocator = context.temp_allocator)
	if err != nil do return "", false, "could not encode the reconfiguration request"
	return string(data), true, ""
}

ctl_reconfiguration_phase :: proc(op: json.Object) -> string {
	phases := CTL_RECONFIGURATION_PHASES
	#partial switch value in op["phase"] {
	case json.Integer:
		if value >= 0 && int(value) < len(phases) do return phases[value]
	case json.Float:
		index := int(value)
		if index >= 0 && index < len(phases) && f64(index) == f64(value) do return phases[index]
	case json.String:
		return strings.to_lower(string(value), context.temp_allocator)
	}
	return ""
}

// ctl_cancel_reconfiguration_params finds the operation queued after the
// current turn (phase waiting_for_idle) in an agent.agents.instance_reconfigurations
// response and builds the cancel params from its key and revision.
ctl_cancel_reconfiguration_params :: proc(instance_id, list_response: string) -> (string, bool, string) {
	if strings.trim_space(instance_id) == "" do return "", false, "cancel-reconfiguration needs an <agent-instance-id>"
	data, ok, message := ctl_bridge_response_data(list_response)
	if !ok do return "", false, message
	ops, has_ops := data["operations"].(json.Array)
	if !has_ops do return "", false, "the reconfiguration list response has no operations"
	for entry in ops {
		op, is_object := entry.(json.Object)
		if !is_object || ctl_reconfiguration_phase(op) != "waiting_for_idle" do continue
		key := ctl_json_object_string(op, "idempotency_key")
		revision, has_revision := ctl_json_object_int(op, "revision")
		if key == "" || !has_revision do return "", false, "the queued reconfiguration has no idempotency_key or revision"
		encoded, err := json.marshal(Ctl_Reconfiguration_Cancel_Params{instance_id = instance_id, idempotency_key = key, expected_operation_revision = revision}, allocator = context.temp_allocator)
		if err != nil do return "", false, "could not encode the cancel request"
		return string(encoded), true, ""
	}
	return "", false, "no configuration change is queued after the current turn for this instance"
}

// ctl_reconfigure_idempotency_key returns --idempotency-key, or a fresh random
// key so that a re-run is a new request while a retry can pass the same key.
ctl_reconfigure_idempotency_key :: proc(args: []string) -> string {
	if key := strings.trim_space(option_value(args, "--idempotency-key", "")); key != "" do return key
	bytes: [16]byte
	if !os_random.fill(bytes[:]) do ctl_print_error_exit("system randomness unavailable; cannot generate an idempotency key")
	return strings.concatenate({"ctl_", vault.hex_encode_lower(bytes[:], context.temp_allocator)}, context.temp_allocator)
}
