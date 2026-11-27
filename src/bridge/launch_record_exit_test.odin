package main

import "core:strings"
import "core:sync"
import "core:testing"

// T16d: a dead agent must not keep a launch record (it holds the auto-update
// quiet window). The ACP SIGTERM path ends in acp_runtime_lost_status once
// pipe-lost recovery cannot reattach/respawn; the PTY path ends in
// bridge_pty_host_apply_child_exited.

@(test)
test_acp_lost_status_removes_launch_record :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	for closed in ([2]bool{true, false}) {
		id := "inst_t16d_acp_lost"
		bridge_runtime_record_launch({agent_instance_id = id})
		defer bridge_runtime_remove_launch(id)
		_, recorded := bridge_runtime_get_launch(id)
		testing.expect(t, recorded)
		acp_runtime_lost_status(id, closed)
		_, still := bridge_runtime_get_launch(id)
		testing.expect(t, !still, "ACP lost-status must drop the launch record")
	}
}

@(test)
test_pty_child_exit_removes_launch_record :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	id := "inst_t16d_pty_exit"
	bridge_runtime_record_launch({agent_instance_id = id})
	defer bridge_runtime_remove_launch(id)
	bridge_runtime_set_status(id, "running", "idle")
	sync.mutex_lock(&bridge_runtime_mutex)
	for &inst in bridge_runtime_instances do if inst.agent_instance_id == id {
		inst.startup.rec.run_count = 2
		inst.startup.pty_pid = 42
	}
	sync.mutex_unlock(&bridge_runtime_mutex)
	bridge_pty_host_apply_child_exited(id, 143, proc(instance: string) -> Bridge_Instance_Probe_Result {
		return {agent_instance_id = instance, state = "exited", pid = 41, exit_code = i32(143)}
	})
	_, still_live := bridge_runtime_get_launch(id)
	testing.expect(t, still_live, "old exit must not drop the replacement launch")
	bridge_pty_host_apply_child_exited(id, 143, proc(instance: string) -> Bridge_Instance_Probe_Result {
		return {agent_instance_id = instance, state = "exited", pid = 42, exit_code = i32(143)}
	})
	frame := bridge_instance_status_json(id)
	defer delete(frame)
	testing.expect(t, strings.contains(frame, `"process_exit":{"pid":42,"exit_code":143,"run_count":2}`))
	_, still := bridge_runtime_get_launch(id)
	testing.expect(t, !still, "PTY child exit must drop the launch record")
}

@(test)
test_auto_update_busy_ids_do_not_go_stale :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&auto_test_mutex)
	defer sync.mutex_unlock(&auto_test_mutex)
	id := "inst_t16d_stale_ids"
	bridge_runtime_record_launch({agent_instance_id = id})
	bridge_runtime_set_status(id, "running", "idle")
	testing.expect(t, !bridge_auto_update_quiet_with_host(false, auto_update_test_empty_host))
	testing.expect(t, strings.contains(bridge_auto_update_busy_text(), id))
	bridge_runtime_remove_launch(id)
	testing.expect(t, bridge_auto_update_launch_enter())
	defer bridge_auto_update_launch_leave()
	testing.expect(t, !bridge_auto_update_quiet_with_host(false, auto_update_test_empty_host))
	testing.expect(t, !strings.contains(bridge_auto_update_busy_text(), id), "Launch_Preparing must not show stale ids")
}
