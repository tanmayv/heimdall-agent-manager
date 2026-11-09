package main

import "core:strings"
import "core:testing"

// Mixed-work CLI surface (plan item 2): typed refs for `task depend`, the
// --depends-on normalizer, and agent-mode routing of the chain-level graph verbs
// through the authenticated agent.work.* Bridge methods.

@(test)
test_task_depend_target_typed_refs :: proc(t: ^testing.T) {
	kind, id, msg := ctl_task_depend_target("task_b")
	testing.expect(t, kind == .Task && id == "task_b" && msg == "", "bare id is a ticket prerequisite")
	kind, id, _ = ctl_task_depend_target(" task:task_b ")
	testing.expect(t, kind == .Task && id == "task_b", "task:<id> strips the kind")
	kind, id, _ = ctl_task_depend_target("workflow_run:wrun_1")
	testing.expect(t, kind == .Workflow_Run && id == "wrun_1", "workflow_run:<id> is a graph edge")

	for bad in ([?]string{"stage:audit", "workflow:research", "issue:iss_1"}) {
		kind, _, msg = ctl_task_depend_target(bad)
		testing.expectf(t, kind == .Invalid, "%s must be rejected", bad)
		testing.expectf(t, strings.contains(msg, "unsupported prerequisite kind") && strings.contains(msg, "workflow_run:<run-id>") && strings.contains(msg, "task-chain depend"), "actionable error for %s: %s", bad, msg)
	}
	kind, _, msg = ctl_task_depend_target("workflow_run:")
	testing.expect(t, kind == .Invalid && strings.contains(msg, "has no id"), "empty typed id rejected")
	kind, _, msg = ctl_task_depend_target("")
	testing.expect(t, kind == .Invalid && strings.contains(msg, "requires --on"), "missing prerequisite rejected")
}

@(test)
test_task_depends_on_csv_normalizes_and_rejects_runs :: proc(t: ^testing.T) {
	out, ok, _ := ctl_task_depends_on_csv("task_a, task:task_b,,")
	testing.expect(t, ok, "ticket ids accepted")
	testing.expect_value(t, out, "task_a,task_b")
	out, ok, _ = ctl_task_depends_on_csv("")
	testing.expect(t, ok && out == "", "empty list clears")
	msg: string
	_, ok, msg = ctl_task_depends_on_csv("task_a,workflow_run:wrun_1")
	testing.expect(t, !ok, "workflow runs are not ticket-list entries")
	testing.expectf(t, strings.contains(msg, "ham-ctl task depend <task-id> --on workflow_run:wrun_1"), "points at the supported command: %s", msg)
	_, ok, msg = ctl_task_depends_on_csv("stage:x")
	testing.expect(t, !ok && strings.contains(msg, "--depends-on: unsupported prerequisite kind"), "other kinds rejected")
}

@(test)
test_agent_mode_task_chain_complete_routes_to_agent_work :: proc(t: ^testing.T) {
	ok_line := "{\"ok\":true,\"result\":{}}\n"
	responses := []string{ok_line, ok_line}
	fb := fake_bridge_start(t, responses)
	if fb == nil do return
	defer fake_bridge_stop(fb)
	kr := tkr_b64(CTL_TEST_WRITE_KEY)
	// chain.complete of a Bridge-owned chain stays (owner-routed agent.work.complete);
	// the Hub-only graph/depend/scope verbs are gone.
	ctl_v2_task_chain(fb.endpoint, "tok", []string{"complete", "chain_g"}, []string{"ham-ctl", "task-chain", "complete", "chain_g", "--expected-work-revision", "4", "--summary", "done", "--vault-keyring", kr})
	// A task:<id> prerequisite stays a ticket dependency (agent.task.depend).
	ctl_v2_task(fb.endpoint, "tok", []string{"depend", "task_r"}, []string{"ham-ctl", "task", "depend", "task_r", "--on", "task:task_p", "--vault-keyring", kr})
	testing.expect_value(t, fb.served, 2)
	complete := fake_bridge_request(fb, 0)
	testing.expectf(t, strings.contains(complete, `"method":"agent.work.complete"`) && strings.contains(complete, `"chain_id":"chain_g"`) && strings.contains(complete, `"expected_work_revision":4`) && strings.contains(complete, `"summary":"done"`), "complete: %s", complete)
	ticket_depend := fake_bridge_request(fb, 1)
	testing.expectf(t, strings.contains(ticket_depend, `"method":"agent.task.depend"`) && strings.contains(ticket_depend, `"task_id":"task_r"`) && strings.contains(ticket_depend, `"depends_on_task_id":"task_p"`), "task: ref stays a ticket dependency: %s", ticket_depend)
}

// Agent chain creation is served by the caller's Bridge as owner: the verb
// sends agent.task_chain.create with title, description and the optional
// coordinator agent (no hub_chains_removed).
@(test)
test_agent_mode_task_chain_create_routes_to_owner_bridge :: proc(t: ^testing.T) {
	ok_line := "{\"ok\":true,\"data\":{\"chain_id\":\"chain_x\"}}\n"
	responses := []string{ok_line, ok_line}
	fb := fake_bridge_start(t, responses)
	if fb == nil do return
	defer fake_bridge_stop(fb)
	ctl_v2_task_chain(fb.endpoint, "tok", []string{"create"}, []string{"ham-ctl", "task-chain", "create", "--title", "Release", "--description", "Ship it"})
	ctl_v2_task_chain(fb.endpoint, "tok", []string{"create"}, []string{"ham-ctl", "task-chain", "create", "--title", "Docs", "--coordinator-agent", "agt_writer"})
	testing.expect_value(t, fb.served, 2)
	first, second := fake_bridge_request(fb, 0), fake_bridge_request(fb, 1)
	testing.expectf(t, strings.contains(first, `"method":"agent.task_chain.create"`) && strings.contains(first, `"title":"Release"`) && strings.contains(first, `"description":"Ship it"`) && !strings.contains(first, "coordinator_agent_id"), "default create: %s", first)
	testing.expectf(t, strings.contains(second, `"title":"Docs"`) && strings.contains(second, `"coordinator_agent_id":"agt_writer"`), "named coordinator: %s", second)
}
