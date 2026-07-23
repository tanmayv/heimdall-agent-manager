package bridge_runtime

import "core:strings"
import domain "odin_test:hub/domain"
import project_service "odin_test:hub/service/project"

PROTOCOL_VERSION :: 1

Hello_Result :: struct {
	accepted: bool,
	replaced_existing: bool,
	generation: int,
}

runtime_accept_hello :: proc(registry: ^project_service.Bridge_Runtime_Registry, bridge_id: string, protocol_version: int, validation_ws_url: string) -> (Hello_Result, bool, domain.Domain_Error) {
	if protocol_version != PROTOCOL_VERSION do return Hello_Result{}, false, domain.domain_error(.Validation_Failed, "unsupported bridge protocol_version")
	if bridge_id == "" do return Hello_Result{}, false, domain.domain_error(.Validation_Failed, "bridge_id is required")
	replaced := project_service.bridge_runtime_registry_has_live(registry, bridge_id)
	generation := runtime_next_generation(registry, bridge_id)
	project_service.bridge_runtime_registry_mark_live(registry, bridge_id, validation_ws_url != "", validation_ws_url)
	runtime_set_generation(registry, bridge_id, generation)
	return Hello_Result{accepted = true, replaced_existing = replaced, generation = generation}, true, domain.Domain_Error{}
}

runtime_command_cached :: proc(registry: ^project_service.Bridge_Runtime_Registry, command_id: string) -> (string, bool) {
	if registry == nil || command_id == "" do return "", false
	for i in 0..<registry.command_count { if registry.command_ids[i] == command_id do return registry.command_results_json[i], true }
	return "", false
}

runtime_command_result_idempotent :: proc(registry: ^project_service.Bridge_Runtime_Registry, bridge_id, command_id, result_json: string) -> (string, bool) {
	_ = bridge_id
	if registry == nil || command_id == "" do return "", false
	for i in 0..<registry.command_count { if registry.command_ids[i] == command_id do return registry.command_results_json[i], true }
	if registry.command_count < len(registry.command_ids) {
		registry.command_ids[registry.command_count] = command_id
		registry.command_results_json[registry.command_count] = result_json
		registry.command_count += 1
	}
	return result_json, false
}

runtime_apply_state_report :: proc(registry: ^project_service.Bridge_Runtime_Registry, instance_id: string, state_seq: int, runtime_status, activity_status: string) -> bool {
	if registry == nil || instance_id == "" do return false
	idx := runtime_instance_index(registry, instance_id)
	if idx < 0 {
		if registry.instance_count >= len(registry.instance_ids) do return false
		idx = registry.instance_count
		registry.instance_count += 1
		registry.instance_ids[idx] = instance_id
	}
	if state_seq <= registry.instance_state_seq[idx] do return false
	old_runtime := registry.instance_runtime_status[idx]
	registry.instance_state_seq[idx] = state_seq
	registry.instance_runtime_status[idx] = runtime_status
	registry.instance_activity_status[idx] = activity_status
	if old_runtime != "" && old_runtime != runtime_status {
		registry.edge_event_count += 1
		return true
	}
	return false
}

runtime_reconcile_digest :: proc(registry: ^project_service.Bridge_Runtime_Registry, active_instance_ids: []string) -> int {
	if registry == nil do return 0
	changed := 0
	for i in 0..<registry.instance_count {
		if registry.instance_runtime_status[i] == "running" && !string_slice_contains(active_instance_ids, registry.instance_ids[i]) {
			registry.instance_runtime_status[i] = "unreachable"
			registry.edge_event_count += 1
			changed += 1
		}
	}
	return changed
}

runtime_instance_status :: proc(registry: ^project_service.Bridge_Runtime_Registry, instance_id: string) -> (runtime_status: string, activity_status: string, state_seq: int, ok: bool) {
	idx := runtime_instance_index(registry, instance_id)
	if idx < 0 do return "", "", 0, false
	return registry.instance_runtime_status[idx], registry.instance_activity_status[idx], registry.instance_state_seq[idx], true
}

runtime_next_generation :: proc(registry: ^project_service.Bridge_Runtime_Registry, bridge_id: string) -> int {
	if registry == nil do return 1
	for i in 0..<registry.live_bridge_count { if registry.live_bridge_ids[i] == bridge_id do return registry.connection_generations[i] + 1 }
	return 1
}

runtime_set_generation :: proc(registry: ^project_service.Bridge_Runtime_Registry, bridge_id: string, generation: int) {
	if registry == nil do return
	for i in 0..<registry.live_bridge_count { if registry.live_bridge_ids[i] == bridge_id { registry.connection_generations[i] = generation; return } }
}

runtime_instance_index :: proc(registry: ^project_service.Bridge_Runtime_Registry, instance_id: string) -> int {
	if registry == nil do return -1
	for i in 0..<registry.instance_count { if registry.instance_ids[i] == instance_id do return i }
	return -1
}

string_slice_contains :: proc(values: []string, needle: string) -> bool {
	for value in values { if strings.trim_space(value) == needle do return true }
	return false
}
