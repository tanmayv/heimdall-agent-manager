package taskv2

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import project "odin_test:hub/service/project"

@(test)
test_ready_workspace_mapping_requires_a_single_validated_legacy_directory :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "workspace_mapping")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_workspace_mapping")
	seed_fleet(fx, chain, "agt_w", bridge_id = "br_1")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_directory(fx, chain, "dir_legacy", "", "git")
	seed_directory(fx, chain, "dir_second", "", "git")
	Probe :: struct { accept: bool, calls: int }
	probe: Probe
	fx.svc.bridge_command_sink.ctx = &probe
	fx.svc.bridge_command_sink.validate_project_path = proc(ctx: rawptr, command: project.Validate_Project_Path_Command) -> (project.Project_Path_Validation_Result, bool, domain.Domain_Error) {
		p := (^Probe)(ctx)
		p.calls += 1
		valid := p.accept && command.bridge_id == "br_1" && command.path == "/srv/dir_legacy" && command.vcs_kind == "git"
		return {ok = valid, validation_error = "Git root was not found"}, true, {}
	}
	task := publish_task(t, fx, chain, "task_workspace_mapping")
	testing.expect(t, strings.contains(placement_body(fx, string(task.task_id)), "more than one workspace is unmapped"), "ambiguity explained without a bridge command")
	attempt_workspace_mapping(&fx.svc, task.task_id)
	testing.expect_value(t, probe.calls, 0)
	_, _ = iface.taskchain_remove_directory(&fx.repo, "dir_second", chain.chain_id, chain.owner_user_id)
	_, _, _ = task_recheck(&fx.svc, task, actor_from_auth(user_auth()))
	_ = fire_due(&fx.svc, now_ms(fx.svc.clock))
	testing.expect_value(t, probe.calls, 1)
	unmapped, _, _ := iface.taskchain_get_directory(&fx.repo, "dir_legacy", chain.chain_id, chain.owner_user_id)
	testing.expect_value(t, unmapped.bridge_id, "")
	testing.expect(t, strings.contains(placement_body(fx, string(task.task_id)), "Git root was not found"), "bridge rejection explained and task not granted")
	probe.accept = true
	_, _, _ = task_recheck(&fx.svc, task, actor_from_auth(user_auth()))
	testing.expect(t, strings.contains(placement_body(fx, string(task.task_id)), "Git root was not found"), "routine matching preserves the failure until a new preflight completes")
	_ = fire_due(&fx.svc, now_ms(fx.svc.clock))
	testing.expect_value(t, probe.calls, 2)
	mapped, _, _ := iface.taskchain_get_directory(&fx.repo, "dir_legacy", chain.chain_id, chain.owner_user_id)
	testing.expect_value(t, mapped.bridge_id, "br_1")
	lease, held := lease_of(fx, "inst_w1")
	testing.expect(t, held && lease.task_id == task.task_id, "successful mapping dispatches the ready task")
	seed_bridge(fx, "br_other")
	seed_fleet(fx, chain, "agt_w", bridge_id = "br_other", capacity = 2)
	other := publish_task(t, fx, chain, "task_workspace_do_not_remap", bridge_pin = "br_other")
	attempt_workspace_mapping(&fx.svc, other.task_id)
	still_mapped, _, _ := iface.taskchain_get_directory(&fx.repo, "dir_legacy", chain.chain_id, chain.owner_user_id)
	testing.expect_value(t, still_mapped.bridge_id, "br_1")
	testing.expect_value(t, probe.calls, 2)
}
