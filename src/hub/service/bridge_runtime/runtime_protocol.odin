package bridge_runtime

import "core:strings"
import domain "odin_test:hub/domain"
import project_service "odin_test:hub/service/project"

// The command cache is shared across threads (the runtime loop writes results;
// fs/file HTTP requests poll for them), so every access takes the registry command
// lock. The lock is NOT reentrant, so these helpers must not be called while the
// caller already holds it (socket-write sites lock separately and never nest a
// cache call inside that section).

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
	project_service.bridge_runtime_registry_command_lock(registry)
	defer project_service.bridge_runtime_registry_command_unlock(registry)
	// command_count is a monotonic counter; live slots are min(count, cap) because
	// the cache is a ring (see runtime_command_result_idempotent).
	live := min(registry.command_count, len(registry.command_ids))
	for i in 0..<live { if registry.command_ids[i] == command_id do return registry.command_results_json[i], true }
	return "", false
}

runtime_command_result_idempotent :: proc(registry: ^project_service.Bridge_Runtime_Registry, bridge_id, command_id, result_json: string) -> (string, bool) {
	_ = bridge_id
	if registry == nil || command_id == "" do return "", false
	project_service.bridge_runtime_registry_command_lock(registry)
	defer project_service.bridge_runtime_registry_command_unlock(registry)
	// Idempotent: first result for an id wins (the bridge sends e.g. a providers_report
	// then a command_result under one command_id — keep the informative first one).
	live := min(registry.command_count, len(registry.command_ids))
	for i in 0..<live { if registry.command_ids[i] == command_id do return registry.command_results_json[i], true }
	// Ring buffer: overwrite the oldest slot once the array is full so a busy hub
	// never STOPS caching. The previous fixed-array-with-no-eviction dropped every
	// result past the 256th, which made send_runtime_command_wait miss the reply and
	// 409-timeout every bridge relay (fs/providers/path-validation) hub-wide until a
	// restart. command_count is a monotonic counter; slot = count % cap points at the
	// oldest live entry (each slot s was last written at count values s, s+cap, ...).
	slot := registry.command_count % len(registry.command_ids)
	registry.command_ids[slot] = command_id
	registry.command_results_json[slot] = result_json
	registry.command_count += 1
	return result_json, false
}

canonical_runtime_status :: proc(s: string) -> string {
	switch s {
	case "running": return "running"
	case "idle": return "idle"
	case "busy": return "busy"
	case "launching": return "launching"
	case "starting": return "starting"
	case "stopping": return "stopping"
	case "blocked": return "blocked"
	case "stopped": return "stopped"
	case "unreachable": return "unreachable"
	case "failed": return "failed"
	}
	return s
}

canonical_activity_status :: proc(s: string) -> string {
	switch s {
	case "idle": return "idle"
	case "busy": return "busy"
	case "waiting": return "waiting"
	}
	return s
}

runtime_apply_state_report :: proc(registry: ^project_service.Bridge_Runtime_Registry, instance_id: string, state_seq: int, runtime_status, activity_status: string) -> bool {
	if registry == nil || instance_id == "" do return false
	idx := runtime_instance_index(registry, instance_id)
	if idx < 0 {
		if registry.instance_count >= len(registry.instance_ids) do return false
		idx = registry.instance_count
		registry.instance_count += 1
		registry.instance_ids[idx] = strings.clone(instance_id)
	}
	if state_seq <= registry.instance_state_seq[idx] do return false
	old_runtime := registry.instance_runtime_status[idx]
	registry.instance_state_seq[idx] = state_seq
	registry.instance_runtime_status[idx] = canonical_runtime_status(runtime_status)
	registry.instance_activity_status[idx] = canonical_activity_status(activity_status)
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
