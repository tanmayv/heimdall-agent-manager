package hub_phase8_bridge_runtime_test

import "core:fmt"
import "core:os"
import "core:strings"
import bridge_runtime "odin_test:hub/service/bridge_runtime"
import project_service "odin_test:hub/service/project"

main :: proc() {
	registry: project_service.Bridge_Runtime_Registry
	defer bridge_runtime.runtime_command_cache_destroy(&registry)
	first, first_ok, first_err := bridge_runtime.runtime_accept_hello(&registry, "brg_a", 1, "ws://127.0.0.1:1/bridge-ws")
	check(first_ok && first.accepted && !first.replaced_existing && first.generation == 1, first_err.message)
	second, second_ok, second_err := bridge_runtime.runtime_accept_hello(&registry, "brg_a", 1, "ws://127.0.0.1:1/bridge-ws")
	check(second_ok && second.replaced_existing && second.generation == 2, second_err.message)
	_, version_ok, version_err := bridge_runtime.runtime_accept_hello(&registry, "brg_bad", 2, "")
	check(!version_ok && version_err.code == .Validation_Failed, "unsupported protocol version must be rejected")

	accepted := strings.clone("{\"type\":\"command_result\",\"payload\":{\"status\":\"accepted\"}}")
	terminal := strings.clone("{\"type\":\"command_result\",\"payload\":{\"status\":\"succeeded\"}}")
	result1, dup1 := bridge_runtime.runtime_command_result_idempotent(&registry, "brg_a", second.generation, "cmd_1", accepted)
	_, cached_before_terminal := bridge_runtime.runtime_command_cached(&registry, "brg_a", second.generation, "cmd_1")
	result2, dup2 := bridge_runtime.runtime_command_result_idempotent(&registry, "brg_a", second.generation, "cmd_1", terminal)
	result3, dup3 := bridge_runtime.runtime_command_result_idempotent(&registry, "brg_a", second.generation, "cmd_1", "{\"type\":\"command_result\",\"payload\":{\"status\":\"failed\"}}")
	check(!dup1 && !cached_before_terminal, "accepted must not satisfy terminal waiters")
	check(!dup2 && result2 == terminal, "terminal result must replace accepted")
	check(dup3 && result3 == terminal, "first terminal result must remain idempotent")
	_ = result1
	delete(accepted)
	delete(terminal)

	edge1 := bridge_runtime.runtime_apply_state_report(&registry, "inst_1", 10, "running", "idle")
	check(!edge1, "initial report establishes state without runtime edge")
	edge_dup := bridge_runtime.runtime_apply_state_report(&registry, "inst_1", 10, "stopped", "idle")
	runtime_status, activity_status, state_seq, got := bridge_runtime.runtime_instance_status(&registry, "inst_1")
	check(!edge_dup && got && runtime_status == "running" && activity_status == "idle" && state_seq == 10, "duplicate state_seq must be ignored")
	edge_old := bridge_runtime.runtime_apply_state_report(&registry, "inst_1", 9, "failed", "active")
	runtime_status, activity_status, state_seq, got = bridge_runtime.runtime_instance_status(&registry, "inst_1")
	check(!edge_old && runtime_status == "running" && activity_status == "idle" && state_seq == 10, "out-of-order state_seq must be ignored")
	before_edges := registry.edge_event_count
	activity_edge := bridge_runtime.runtime_apply_state_report(&registry, "inst_1", 11, "running", "active")
	check(!activity_edge && registry.edge_event_count == before_edges, "activity-only flapping must not emit runtime edge events")
	changed := bridge_runtime.runtime_reconcile_digest(&registry, []string{})
	runtime_status, _, _, _ = bridge_runtime.runtime_instance_status(&registry, "inst_1")
	check(changed == 1 && runtime_status == "unreachable" && registry.edge_event_count == before_edges + 1, "missing digest entry must reconcile running instance to unreachable")
	fmt.println("PASS: hub phase8 bridge runtime")
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln(message); os.exit(1) }
