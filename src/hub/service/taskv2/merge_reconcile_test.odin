package taskv2

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import project "odin_test:hub/service/project"

// F1: the first merge conflict (since the last successful merge) is answered
// automatically with a reconcile attempt; a repeat conflict stays parked for
// the coordinator.
@(test)
test_merge_conflict_auto_reconcile_is_bounded :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "merge_auto")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_merge_auto")
	task := publish_task(t, fx, chain, "task_1")
	_, _, _ = append_event(&fx.repo, &fx.clock, task, hub_actor(), EV_MERGE_CONFLICT, `{"branch":"b"}`)
	testing.expect(t, merge_conflict_auto_reconcile_allowed(&fx.svc, task), "first conflict auto-reconciles")
	_, _, _ = append_event(&fx.repo, &fx.clock, task, hub_actor(), EV_ANSWERED, `{"auto":true}`)
	_, _, _ = append_event(&fx.repo, &fx.clock, task, hub_actor(), EV_MERGE_CONFLICT, `{"branch":"b"}`)
	testing.expect(t, !merge_conflict_auto_reconcile_allowed(&fx.svc, task), "a repeat conflict stays parked for the coordinator")
	_, _, _ = append_event(&fx.repo, &fx.clock, task, hub_actor(), EV_MERGED, `{"branch":"b"}`)
	_, _, _ = append_event(&fx.repo, &fx.clock, task, hub_actor(), EV_MERGE_CONFLICT, `{"branch":"b"}`)
	testing.expect(t, merge_conflict_auto_reconcile_allowed(&fx.svc, task), "a successful merge resets the bound")
}

@(private = "file")
merge_conflict_reply :: proc(ctx: rawptr, cmd: project.Runtime_Command, timeout_ms: int) -> (string, bool, domain.Domain_Error) {
	return strings.clone(`{"ok":false,"conflict":true,"files":["README.md"],"detail":"CONFLICT"}`), true, domain.Domain_Error{}
}

@(private = "file")
done_task_for_merge :: proc(t: ^testing.T, fx: ^Fixture, chain_id: string) -> (domain.Task, bool) {
	chain := seed_live_chain(t, fx, chain_id)
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1")
	confirm_holder(fx, "inst_w1")
	_, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "done", vcs_json = GREEN_VCS})
	if !testing.expect(t, sok, fmt.tprintf("submit: %s", serr.message)) do return {}, false
	task := get_task(fx, "task_1")
	return task, testing.expect_value(t, task.state, domain.Task_State.Done)
}

// F1: the run_merge path — a conflict reply records the conflict AND starts the
// reconcile attempt (the task leaves the coordinator's queue).
@(test)
test_run_merge_conflict_auto_reconciles :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "merge_run_auto")
	defer lease_fixture_close(fx, log)
	if !ok do return
	task, dok := done_task_for_merge(t, fx, "chain_merge_run_auto")
	if !dok do return
	fx.svc.bridge_command_sink = project.Bridge_Command_Sink{send_runtime_command_wait = merge_conflict_reply}
	run_merge(&fx.svc, Merge_Effect{task_id = string(task.task_id), bridge_id = "br_1", repo = "/repo", workdir = "/repo/.heimdall/worktrees/task_1", branch = "heimdall/task_1"})
	testing.expect_value(t, count_events(fx, "task_1", EV_MERGE_CONFLICT), 1)
	testing.expect_value(t, count_events(fx, "task_1", EV_ANSWERED), 1)
	after := get_task(fx, "task_1")
	testing.expect(t, !strings.contains(after.blocked_on_json, "merge_conflict"), fmt.tprintf("reconcile started, not parked: %v %s", after.state, after.blocked_on_json))
}

// F1: if writing the auto-answer fails, the conflict is still committed and the
// task stays parked for the coordinator (no whole-unit rollback).
@(test)
test_run_merge_conflict_commits_when_auto_answer_fails :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "merge_run_fail")
	defer lease_fixture_close(fx, log)
	if !ok do return
	task, dok := done_task_for_merge(t, fx, "chain_merge_run_fail")
	if !dok do return
	fx.svc.bridge_command_sink = project.Bridge_Command_Sink{send_runtime_command_wait = merge_conflict_reply}
	fx.svc.test_fail_merge_auto_answer = true
	run_merge(&fx.svc, Merge_Effect{task_id = string(task.task_id), bridge_id = "br_1", repo = "/repo", workdir = "/repo/.heimdall/worktrees/task_1", branch = "heimdall/task_1"})
	testing.expect_value(t, count_events(fx, "task_1", EV_MERGE_CONFLICT), 1)
	testing.expect_value(t, count_events(fx, "task_1", EV_ANSWERED), 0)
	parked := get_task(fx, "task_1")
	testing.expect_value(t, parked.state, domain.Task_State.Backlog)
	testing.expect(t, strings.contains(parked.blocked_on_json, `"kind":"coordinator"`) && strings.contains(parked.blocked_on_json, "merge_conflict"), parked.blocked_on_json)
}
