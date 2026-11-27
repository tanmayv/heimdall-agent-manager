// Legacy heartbeat inventory can carry explicit observations, but omission
// is not evidence that a PTY-host child exited.
package http

import "base:runtime"
import "core:encoding/json"
import "core:mem/virtual"
import "core:unicode/utf8"
import agent_service "odin_test:hub/service/agent"
import bridge_runtime_service "odin_test:hub/service/bridge_runtime"
import domain "odin_test:hub/domain"
import metrics "odin_test:lib/metrics"
import project_service "odin_test:hub/service/project"

Bridge_Heartbeat_Inventory_State :: enum {
	Malformed,
	Absent,
	Complete,
}

// Bounded bridge_frames_rejected{reason} labels.
HEARTBEAT_INVENTORY_REJECT_ABSENT    :: "inventory_absent"
HEARTBEAT_INVENTORY_REJECT_MALFORMED :: "inventory_malformed"
HEARTBEAT_INVENTORY_REJECT_CONFLICT  :: "inventory_digest_conflict"

// Everything the decoder allocates (parse tree, active_ids, reports and the strings
// they borrow) lives in its own arena: core's parse_value does not free the partial
// tree of a truncated frame (and frees some of it through context.allocator), so
// per-value destroys would leak or bad-free exactly the rejects.
Bridge_Heartbeat_Inventory :: struct {
	state:          Bridge_Heartbeat_Inventory_State,
	reason:         string, // static rejection label; "" when Complete
	active_ids:     []string,
	reports:        []Bridge_Agent_Status_Report,
	arena:          virtual.Arena,
	arena_ok:       bool,
}

bridge_heartbeat_inventory_destroy :: proc(inv: ^Bridge_Heartbeat_Inventory) {
	if inv.arena_ok do virtual.arena_destroy(&inv.arena)
	inv^ = {}
}

// inv must be zero (or destroyed); the caller destroys it whatever the state.
bridge_decode_heartbeat_inventory :: proc(inv: ^Bridge_Heartbeat_Inventory, text: string) {
	inv.state = .Malformed
	inv.reason = HEARTBEAT_INVENTORY_REJECT_MALFORMED
	// Core's string decoder assumes valid UTF-8, and its convenience parsers accept
	// trailing bytes, so parse exactly one value and require EOF after it.
	if !utf8.valid_string(text) do return
	inv.arena_ok = virtual.arena_init_growing(&inv.arena) == nil
	if !inv.arena_ok do return
	allocator := virtual.arena_allocator(&inv.arena)
	// parse_value's error paths free through context.allocator, not the parser's.
	context.allocator = allocator
	parser := json.make_parser_from_string(text, .JSON, true, allocator)
	value, parse_err := json.parse_value(&parser)
	object, is_object := value.(json.Object)
	if parse_err != nil || !is_object || parser.curr_token.kind != .EOF do return

	active_value, active_present := object["active_instance_ids"]
	instances_value, instances_present := object["instances"]
	digest_value, digest_present := object["digest"]
	if !active_present && !instances_present && !digest_present {
		inv.state = .Absent
		inv.reason = HEARTBEAT_INVENTORY_REJECT_ABSENT
		return
	}
	if active_present {
		ids, ok := heartbeat_inventory_ids(active_value, allocator)
		inv.active_ids = ids
		if !ok do return
	}
	if instances_present {
		reports, ok := heartbeat_inventory_reports(instances_value, allocator)
		inv.reports = reports
		if !ok do return
	}
	if digest_present {
		// Legacy alias (D6): no current Bridge sends it, but an old one may. The same
		// presence rules apply, and a frame carrying both must say the same thing.
		digest, ok := heartbeat_inventory_reports(digest_value, allocator)
		if !ok do return
		if instances_present {
			if !heartbeat_inventory_reports_equal(inv.reports, digest) {
				inv.reason = HEARTBEAT_INVENTORY_REJECT_CONFLICT
				return
			}
		} else {
			inv.reports = digest
		}
	}
	inv.state = .Complete
	inv.reason = ""
}

@(private = "file")
heartbeat_inventory_ids :: proc(value: json.Value, allocator: runtime.Allocator) -> ([]string, bool) {
	array, is_array := value.(json.Array)
	if !is_array do return nil, false
	ids := make([]string, len(array), allocator)
	for element, i in array {
		id, is_string := element.(json.String)
		if !is_string || id == "" do return ids, false
		ids[i] = string(id)
	}
	return ids, true
}

@(private = "file")
heartbeat_inventory_reports :: proc(value: json.Value, allocator: runtime.Allocator) -> ([]Bridge_Agent_Status_Report, bool) {
	array, is_array := value.(json.Array)
	if !is_array do return nil, false
	reports := make([]Bridge_Agent_Status_Report, len(array), allocator)
	for element, i in array {
		entry, is_object := element.(json.Object)
		if !is_object do return reports, false
		id, id_ok := entry["agent_instance_id"].(json.String)
		if !id_ok || id == "" do return reports, false
		report := Bridge_Agent_Status_Report{agent_instance_id = string(id)}
		// Optional members default to zero values, but a present one must be typed.
		if seq_value, present := entry["state_seq"]; present {
			seq, seq_ok := seq_value.(json.Integer)
			if !seq_ok do return reports, false
			report.state_seq = int(seq)
		}
		ok := true
		report.runtime_status, ok = heartbeat_inventory_optional_string(entry, "runtime_status")
		if !ok do return reports, false
		report.runtime_reason, ok = heartbeat_inventory_optional_string(entry, "runtime_reason")
		if !ok do return reports, false
		report.activity_status, ok = heartbeat_inventory_optional_string(entry, "activity_status")
		if !ok do return reports, false
		report.launch_epoch, ok = heartbeat_inventory_optional_string(entry, "launch_epoch")
		if !ok do return reports, false
		reports[i] = report
	}
	return reports, true
}

@(private = "file")
heartbeat_inventory_optional_string :: proc(entry: json.Object, key: string) -> (string, bool) {
	value, present := entry[key]
	if !present do return "", true
	s, is_string := value.(json.String)
	return string(s), is_string
}

@(private = "file")
heartbeat_inventory_reports_equal :: proc(a, b: []Bridge_Agent_Status_Report) -> bool {
	if len(a) != len(b) do return false
	for i in 0 ..< len(a) {
		if a[i] != b[i] do return false
	}
	return true
}

// The positive liveness set. A non-empty active_instance_ids is authoritative; an
// empty or absent one falls back to the reports, but ONLY to those whose status is
// active: terminal rows recur so a dropped terminal push is repaired, and must never
// refresh liveness. The returned slice is the caller's; its strings borrow from inv.
bridge_heartbeat_inventory_active_ids :: proc(inv: ^Bridge_Heartbeat_Inventory, allocator := context.allocator) -> []string {
	if len(inv.active_ids) > 0 {
		out := make([]string, len(inv.active_ids), allocator)
		copy(out, inv.active_ids)
		return out
	}
	out := make([dynamic]string, 0, len(inv.reports), allocator)
	for report in inv.reports {
		if agent_service.runtime_expected_active(report.runtime_status) do append(&out, report.agent_instance_id)
	}
	return out[:]
}

// Repairs durable and registry status from every report, active or terminal. Epoch
// and state_seq fencing live in apply_bridge_status_report / the registry.
bridge_apply_heartbeat_reports :: proc(h: ^Bridge_Handlers, bridge_id: string, generation: int, reports: []Bridge_Agent_Status_Report) {
	if h == nil do return
	current_generation := generation
	if current_generation == 0 do current_generation = project_service.bridge_runtime_registry_generation(h.bridge_runtime_registry, bridge_id)
	for report in reports {
		if h.agents == nil {
			_ = bridge_runtime_service.runtime_apply_state_report(h.bridge_runtime_registry, bridge_id, current_generation, report.agent_instance_id, report.state_seq, report.runtime_status, report.activity_status, "")
			continue
		}
		status_moved := false
		if inst, applied, _ := bridge_apply_validated_status(h, bridge_id, current_generation, report.agent_instance_id, report.state_seq, report.runtime_status, report.activity_status, report.launch_epoch, changed = &status_moved, source = "bridge_heartbeat", reason = report.runtime_reason); applied {
			// A beat that only refreshed last_seen_at is not news (REQ-2).
			if status_moved do publish_instance_changed(h.event_bus, inst, "status_changed")
			domain.agent_instance_destroy(&inst)
		}
	}
}

// Preserve the legacy ack shape without inferring exits from missing rows.
bridge_reconcile_heartbeat_inventory :: proc(h: ^Bridge_Handlers, bridge_id: string, generation: int, text: string) -> (reconciled: int, superseded: []string, state: Bridge_Heartbeat_Inventory_State) {
	inventory: Bridge_Heartbeat_Inventory
	bridge_decode_heartbeat_inventory(&inventory, text)
	defer bridge_heartbeat_inventory_destroy(&inventory)
	state = inventory.state
	if state == .Complete {
		bridge_apply_heartbeat_reports(h, bridge_id, generation, inventory.reports)
	} else {
		metrics.counter_inc(metrics.with(project_service.fleet_metrics.bridge_frames_rejected, inventory.reason))
	}
	if h.agents != nil do agent_service.reconcile_instance_reconfigurations(h.agents, bridge_id)
	if state == .Complete {
		active := bridge_heartbeat_inventory_active_ids(&inventory)
		defer delete(active)
		if h.agents != nil {
			superseded = agent_service.detect_superseded_instances(h.agents, bridge_id, active)
		}
	}
	return
}
