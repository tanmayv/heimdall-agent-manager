package bridge_runtime

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:time"
import domain "odin_test:hub/domain"
import project_service "odin_test:hub/service/project"
import jsonx "odin_test:lib/jsonx"

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
	if project_service.bridge_runtime_registry_writer_mutex(registry, bridge_id) == nil do return Hello_Result{}, false, domain.domain_error(.Bridge_Busy, "hub bridge writer capacity is exhausted")
	replaced, generation, admitted := project_service.bridge_runtime_registry_accept_live(registry, bridge_id, validation_ws_url != "", validation_ws_url)
	if !admitted do return Hello_Result{}, false, domain.domain_error(.Bridge_Busy, "hub live bridge capacity is exhausted")
	return Hello_Result{accepted = true, replaced_existing = replaced, generation = generation}, true, domain.Domain_Error{}
}

RUNTIME_COMMAND_RESULTS_PER_BRIDGE :: 8

runtime_command_cached :: proc(registry: ^project_service.Bridge_Runtime_Registry, bridge_id, command_id: string) -> (string, bool) {
	if registry == nil || bridge_id == "" || command_id == "" do return "", false
	project_service.bridge_runtime_registry_command_lock(registry)
	defer project_service.bridge_runtime_registry_command_unlock(registry)
	live := registry.command_slots_used
	for i in 0..<live {
		if registry.command_bridge_ids[i] == bridge_id && registry.command_ids[i] == command_id && registry.command_results_terminal[i] do return registry.command_results_json[i], true
	}
	return "", false
}

// Returns an owned process-allocator copy for callers that use the result after
// releasing the cache lock. The borrowed lookup above remains useful for
// immediate assertions/internal inspection, but must never cross a concurrent
// eviction point.
runtime_command_cached_copy :: proc(registry: ^project_service.Bridge_Runtime_Registry, bridge_id, command_id: string) -> (string, bool) {
	if registry == nil || bridge_id == "" || command_id == "" do return "", false
	project_service.bridge_runtime_registry_command_lock(registry)
	defer project_service.bridge_runtime_registry_command_unlock(registry)
	for i in 0..<registry.command_slots_used {
		if registry.command_bridge_ids[i] == bridge_id && registry.command_ids[i] == command_id && registry.command_results_terminal[i] {
			return strings.clone(registry.command_results_json[i], runtime.default_allocator()), true
		}
	}
	return "", false
}

// Efficiently parks an HTTP/RPC waiter until a terminal result is published.
// The condition may wake spuriously, so the cache predicate and real deadline are
// checked in a loop under the same mutex used by result insertion.
runtime_command_wait_terminal :: proc(registry: ^project_service.Bridge_Runtime_Registry, bridge_id, command_id: string, timeout: time.Duration) -> (string, bool) {
	if registry == nil || bridge_id == "" || command_id == "" || timeout <= 0 do return "", false
	deadline := time.time_add(time.now(), timeout)
	sync.lock(&registry.command_mutex)
	defer sync.unlock(&registry.command_mutex)
	for {
		for i in 0..<registry.command_slots_used {
			if registry.command_bridge_ids[i] == bridge_id && registry.command_ids[i] == command_id && registry.command_results_terminal[i] {
				return strings.clone(registry.command_results_json[i], runtime.default_allocator()), true
			}
		}
		remaining := time.diff(time.now(), deadline)
		if remaining <= 0 do return "", false
		_ = sync.cond_wait_with_timeout(&registry.command_cond, &registry.command_mutex, remaining)
	}
}

// command_result acknowledgements are observations, not completion. Every
// command-specific result frame is terminal; for the generic envelope only the
// explicit accepted state is non-terminal. Missing status remains terminal for the
// older command-specific payloads which use command_result as their result type.
runtime_command_result_is_terminal :: proc(result_json: string) -> bool {
	frame_type := jsonx.extract_string(result_json, "type")
	defer delete(frame_type)
	if frame_type != "command_result" do return true
	status := jsonx.extract_string(result_json, "status")
	defer delete(status)
	return status != "accepted"
}

runtime_command_result_idempotent :: proc(registry: ^project_service.Bridge_Runtime_Registry, bridge_id, command_id, result_json: string) -> (string, bool) {
	if registry == nil || command_id == "" do return "", false
	terminal := runtime_command_result_is_terminal(result_json)
	project_service.bridge_runtime_registry_command_lock(registry)
	defer project_service.bridge_runtime_registry_command_unlock(registry)
	// The first TERMINAL result wins. An accepted acknowledgement may be replaced by
	// exactly one terminal result; otherwise a background Bridge worker could be
	// acknowledged successfully while every synchronous Hub caller times out or sees
	// the acknowledgement as the operation result.
	live := registry.command_slots_used
	for i in 0..<live {
		if registry.command_ids[i] != command_id || registry.command_bridge_ids[i] != bridge_id do continue
		if registry.command_results_terminal[i] || !terminal do return registry.command_results_json[i], true
		delete(registry.command_results_json[i], runtime.default_allocator())
		registry.command_results_json[i] = strings.clone(result_json, runtime.default_allocator())
		registry.command_results_terminal[i] = true
		sync.cond_broadcast(&registry.command_cond)
		return registry.command_results_json[i], false
	}
	// Retention is partitioned by Bridge. Once a Bridge reaches its quota, replace
	// its own oldest terminal observation even when global free slots remain. A
	// reconnect storm or command burst on one machine therefore cannot evict pending
	// results for every other machine.
	live = registry.command_slots_used
	bridge_entries := 0
	oldest_same := -1
	oldest_same_seq := ~u64(0)
	oldest_global := -1
	oldest_global_seq := ~u64(0)
	for i in 0..<live {
		seq := registry.command_result_sequence[i]
		if seq < oldest_global_seq { oldest_global = i; oldest_global_seq = seq }
		if registry.command_bridge_ids[i] == bridge_id {
			bridge_entries += 1
			if seq < oldest_same_seq { oldest_same = i; oldest_same_seq = seq }
		}
	}
	slot := live
	if bridge_entries >= RUNTIME_COMMAND_RESULTS_PER_BRIDGE {
		slot = oldest_same
	} else if live >= len(registry.command_ids) {
		slot = oldest_global
	}
	if slot < live {
		delete(registry.command_ids[slot], runtime.default_allocator())
		delete(registry.command_bridge_ids[slot], runtime.default_allocator())
		delete(registry.command_results_json[slot], runtime.default_allocator())
	} else {
		registry.command_slots_used += 1
	}
	registry.command_ids[slot] = strings.clone(command_id, runtime.default_allocator())
	registry.command_bridge_ids[slot] = strings.clone(bridge_id, runtime.default_allocator())
	registry.command_results_json[slot] = strings.clone(result_json, runtime.default_allocator())
	registry.command_results_terminal[slot] = terminal
	registry.command_count += 1
	registry.command_result_sequence[slot] = u64(registry.command_count)
	if terminal do sync.cond_broadcast(&registry.command_cond)
	return registry.command_results_json[slot], false
}

runtime_command_cache_destroy :: proc(registry: ^project_service.Bridge_Runtime_Registry) {
	if registry == nil do return
	project_service.bridge_runtime_registry_command_lock(registry)
	defer project_service.bridge_runtime_registry_command_unlock(registry)
	live := registry.command_slots_used
	for i in 0..<live {
		delete(registry.command_ids[i], runtime.default_allocator())
		delete(registry.command_bridge_ids[i], runtime.default_allocator())
		delete(registry.command_results_json[i], runtime.default_allocator())
		registry.command_ids[i] = ""
		registry.command_bridge_ids[i] = ""
		registry.command_results_json[i] = ""
	}
	for i in 0..<registry.writer_count {
		delete(registry.writer_bridge_ids[i], runtime.default_allocator())
		registry.writer_bridge_ids[i] = ""
	}
	registry.command_count = 0
	registry.command_slots_used = 0
	registry.writer_count = 0
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

runtime_instance_index :: proc(registry: ^project_service.Bridge_Runtime_Registry, instance_id: string) -> int {
	if registry == nil do return -1
	for i in 0..<registry.instance_count { if registry.instance_ids[i] == instance_id do return i }
	return -1
}

string_slice_contains :: proc(values: []string, needle: string) -> bool {
	for value in values { if strings.trim_space(value) == needle do return true }
	return false
}
