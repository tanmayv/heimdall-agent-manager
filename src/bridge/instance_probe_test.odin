package main

import "core:testing"

@(test)
test_instance_probe_observes_only_named_pty_process :: proc(t: ^testing.T) {
	children := [?]Pty_Host_Agent_Info{
		{instance_id = "inst_live", pid = 42, alive = true},
		{instance_id = "inst_exited", pid = 43, has_exit_code = true, exit_code = 0},
		{instance_id = "inst_unverified", pid = 44, has_exit_code = false},
	}
	roster := Pty_Host_Reply{kind = .Agent_List, agents = children[:]}
	live := bridge_instance_probe_from_roster("inst_live", roster)
	testing.expect(t, live.state == "alive" && live.pid == 42)
	exited := bridge_instance_probe_from_roster("inst_exited", roster)
	code, known := exited.exit_code.?
	testing.expect(t, exited.state == "exited" && exited.pid == 43 && known && code == 0)
	testing.expect_value(t, bridge_instance_probe_from_roster("inst_unverified", roster).state, "unknown")
	testing.expect_value(t, bridge_instance_probe_from_roster("inst_missing", roster).state, "absent")
	testing.expect_value(t, bridge_instance_probe_from_roster("inst_live", {}).state, "unknown")
}

@(test)
test_instance_stop_will_not_touch_replacement_pid :: proc(t: ^testing.T) {
	observe :: proc(id: string) -> Bridge_Instance_Probe_Result {
		return {agent_instance_id = id, pid = 45, state = "alive"}
	}
	stop :: proc(_: string, _: bool) -> bool { return true }
	ok, restored, stale := bridge_runtime_stop_generation("inst_probe_stop_guard", false, -1, stop = stop, expected_pid = 44, observe = observe)
	defer delete(restored)
	testing.expect(t, !ok && stale)
}

@(test)
test_instance_probe_does_not_attribute_previous_child_exit_to_replacement :: proc(t: ^testing.T) {
	old := Bridge_Instance_Probe_Result{state = "exited", pid = 42, exit_code = 0}
	unbound := old
	bridge_instance_probe_bind(&unbound, 0, 2, "new")
	testing.expect_value(t, unbound.state, "unknown")
	bridge_instance_probe_bind(&old, 43, 2, "new")
	testing.expect_value(t, old.state, "unknown")
	_, old_code_present := old.exit_code.?
	testing.expect(t, !old_code_present)
	current := Bridge_Instance_Probe_Result{state = "exited", pid = 43, exit_code = 0}
	bridge_instance_probe_bind(&current, 43, 2, "new")
	testing.expect_value(t, current.state, "exited")
	testing.expect_value(t, current.run_count, 2)
	testing.expect_value(t, current.launch_epoch, "new")
}

@(test)
test_instance_probe_limits_legacy_absence_to_launch_with_a_complete_roster :: proc(t: ^testing.T) {
	omitted := bridge_instance_probe_from_roster("inst_legacy", {kind = .Agent_List})
	unknown :: proc(_: string, _: int, _: bool) -> (Bridge_Agent_Process_State, i32, bool) {
		return .Unknown, 0, false
	}
	unconfirmed_pid :: proc(_: string, _: int, _: bool) -> (Bridge_Agent_Process_State, i32, bool) {
		return .Unknown, 42, false
	}
	clear_scan :: proc(_: string, _: int, reap: bool) -> bool { return !reap }
	unverified_scan :: proc(_: string, _: int, _: bool) -> bool { return false }

	ordinary := omitted
	bridge_instance_probe_qualify_absence(&ordinary, 4, false, unknown, clear_scan)
	testing.expect_value(t, ordinary.state, "unknown")

	launch := omitted
	bridge_instance_probe_qualify_absence(&launch, 4, true, unknown, clear_scan)
	testing.expect(t, launch.state == "absent" && launch.source == "launch_absence" && launch.pid == 0 && launch.exit_code == nil)

	unavailable := bridge_instance_probe_from_roster("inst_legacy", {})
	bridge_instance_probe_qualify_absence(&unavailable, 4, true, unknown, clear_scan)
	testing.expect_value(t, unavailable.state, "unknown")

	for probe_case in ([3]struct {
		run: int,
		observe: proc(string, int, bool) -> (Bridge_Agent_Process_State, i32, bool),
		scan: proc(string, int, bool) -> bool,
	}{{0, unknown, clear_scan}, {4, unconfirmed_pid, clear_scan}, {4, unknown, unverified_scan}}) {
		refused := omitted
		bridge_instance_probe_qualify_absence(&refused, probe_case.run, true, probe_case.observe, probe_case.scan)
		testing.expect_value(t, refused.state, "unknown")
	}
}
