package taskv2

import "core:testing"
import "core:fmt"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import project "odin_test:hub/service/project"
import agent "odin_test:hub/service/agent"
import sqlite "odin_test:hub/repository/sqlite"

delegation_blocked_task :: proc(t: ^testing.T, fx: ^Fixture, chain: domain.Task_Chain, brief := `{"goal":"g","assignee":"agt_w","review_roles":[]}`) -> domain.Task {
	seed_fleet(fx, chain, "agt_w")
	inst := seed_instance(fx, chain, "inst_old", "agt_w", "br_1", "stopped")
	inst.stopped_by = agent.STOPPED_BY_USER
	_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	task := publish_task(t, fx, chain, "task_delegate", brief = brief)
	testing.expect(t, is_agent_not_running_block(task.blocked_on_json), "stopped worker must produce an actionable block")
	return task
}

@(test)
test_delegate_running_stopped_and_failed_worker_is_ticket_scoped_and_duplicate_safe :: proc(t: ^testing.T) {
	for status in ([]string{"running", "stopped", "failed"}) {
		fx, log, ok := lease_fixture(t, fmt.tprintf("delegate_%s", status))
		defer lease_fixture_close(fx, log)
		if !ok do return
		chain := seed_live_chain(t, fx, "chain_delegate")
		task := delegation_blocked_task(t, fx, chain)
		seed_agent(fx, "agt_new")
		seed_fleet(fx, chain, "agt_new")
		inst := seed_instance(fx, chain, "inst_new", "agt_new", "br_1", status)
		if status != "running" {
			inst.stopped_by, inst.last_error_json = agent.STOPPED_BY_USER, `{"message":"previous launch failed"}`
			_, _, _ = iface.agent_save_instance(&fx.agents, inst)
		}
		// A second stopped child of the selected durable identity must retain
		// its stop protection; consent is consumed by the granted child only.
		other := seed_instance(fx, chain, "inst_other_stopped", "agt_new", "br_1", "stopped")
		other.stopped_by = agent.STOPPED_BY_USER
		_, _, _ = iface.agent_save_instance(&fx.agents, other)
		started, err := start_task_agent(&fx.svc, user_auth(), task.task_id, task.blocked_on_json, "agt_new", "agt_w", task.attempt_no)
		if !testing.expect(t, started, err.message) do continue
		fresh := get_task(fx, string(task.task_id))
		testing.expect_value(t, brief_assignee(fresh.brief_json), "agt_new")
		lease, held := lease_of(fx, "inst_new")
		testing.expect(t, held && lease.task_id == task.task_id && wake_log_has_run(log, "inst_new"), "selected replacement receives normal work lease and wake")
		after, _, _ := iface.agent_get_instance(&fx.agents, "inst_new")
		testing.expect_value(t, after.stopped_by, "")
		testing.expect_value(t, after.run_count, inst.run_count if status == "running" else inst.run_count + 1)
		untouched, _, _ := iface.agent_get_instance(&fx.agents, "inst_old")
		testing.expect_value(t, untouched.stopped_by, agent.STOPPED_BY_USER)
		untouched, _, _ = iface.agent_get_instance(&fx.agents, "inst_other_stopped")
		testing.expect_value(t, untouched.stopped_by, agent.STOPPED_BY_USER)
		duplicate, derr := start_task_agent(&fx.svc, user_auth(), task.task_id, task.blocked_on_json, "agt_r")
		testing.expect(t, !duplicate && derr.code == .Conflict, "stale duplicate cannot overwrite assignment")
		again, still_held := lease_of(fx, "inst_new")
		testing.expect(t, still_held && again.lease_id == lease.lease_id, "duplicate preserves exact lease")
		assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "delegated worker")
	}
}

@(test)
test_delegate_launch_failure_commits_new_assignment_and_retry_uses_new_block :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "delegate_launch_failure")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_delegate_failure")
	task := delegation_blocked_task(t, fx, chain)
	seed_agent(fx, "agt_new")
	seed_fleet(fx, chain, "agt_new")
	seed_instance(fx, chain, "inst_new", "agt_new", "br_1", "stopped")
	fx.svc.bridge_command_sink = project.Bridge_Command_Sink{send_runtime_command = proc(ctx: rawptr, cmd: project.Runtime_Command) -> (bool, domain.Domain_Error) {
		return false, domain.domain_error(.Conflict, "instance_not_drained")
	}}
	started, err := start_task_agent(&fx.svc, user_auth(), task.task_id, task.blocked_on_json, "agt_new", "agt_w", task.attempt_no)
	testing.expect(t, !started && strings.contains(err.message, "instance_not_drained"), "real admission failure propagates without bypass")
	fresh := get_task(fx, string(task.task_id))
	testing.expect(t, brief_assignee(fresh.brief_json) == "agt_new" && is_agent_not_running_block(fresh.blocked_on_json), "launch failure retains new assignment and actionable block")
	_, held := lease_of(fx, "inst_new")
	testing.expect(t, !held, "failed launch releases lease")
	stale, serr := start_task_agent(&fx.svc, user_auth(), task.task_id, task.blocked_on_json, "agt_r")
	testing.expect(t, !stale && serr.code == .Conflict, "old card cannot change newly failed replacement")
	// The fixture clock stays frozen: identical same-tick failures still have
	// distinct identities and cannot authorize a repeated stale launch.
	started, err = start_task_agent(&fx.svc, user_auth(), task.task_id, fresh.blocked_on_json)
	testing.expect(t, !started && strings.contains(err.message, "instance_not_drained"), "retry may fail with the same drain reason")
	latest := get_task(fx, string(task.task_id))
	testing.expect(t, latest.blocked_on_json != fresh.blocked_on_json, "same-tick repeated failure receives fresh identity")
	before_retry, _, _ := iface.agent_get_instance(&fx.agents, "inst_new")
	stale, serr = start_task_agent(&fx.svc, user_auth(), task.task_id, fresh.blocked_on_json)
	testing.expect(t, !stale && serr.code == .Conflict, "stale same-reason retry rejected")
	after_retry, _, _ := iface.agent_get_instance(&fx.agents, "inst_new")
	testing.expect_value(t, after_retry.run_count, before_retry.run_count)
	fx.svc.bridge_command_sink = {}
	started, err = start_task_agent(&fx.svc, user_auth(), task.task_id, latest.blocked_on_json)
	testing.expect(t, started && err.code == .None, "fresh Start retries assigned replacement")
	_, held = lease_of(fx, "inst_new")
	testing.expect(t, held, "retry has one normal lease")
	attempts, _ := iface.taskchain_list_attempts_by_task(&fx.repo, task.task_id, "u1")
	for a in attempts do if a.ended_at != "" do testing.expect(t, !a.counts_toward_budget, "infrastructure failure refunded")
}

@(test)
test_delegate_forbidden_selection_keeps_assignment_stop_and_block :: proc(t: ^testing.T) {
	for scenario in ([]string{"foreign", "archived", "paused", "reviewer_only", "named_reviewer", "role_reviewer", "coordinator", "workflow", "held", "offline", "capacity", "stale", "agent_auth", "runtime_busy", "provider", "grant_storage", "live_task_lease", "assignment_changed", "attempt_changed"}) {
		fx, log, ok := lease_fixture(t, fmt.tprintf("delegate_forbid_%s", scenario))
		defer lease_fixture_close(fx, log)
		if !ok do return
		chain := seed_live_chain(t, fx, "chain_delegate_forbid")
		brief := `{"goal":"g","assignee":"agt_w","review_roles":[],"reviewers":["agt_new"]}` if scenario == "named_reviewer" else `{"goal":"g","assignee":"agt_w","review_roles":["security"]}` if scenario == "role_reviewer" else `{"goal":"g","assignee":"agt_w","review_roles":[]}`
		task := delegation_blocked_task(t, fx, chain, brief)
		if scenario == "foreign" {
			_, saved, serr := iface.agent_save(&fx.agents, domain.Agent{agent_id = "agt_new", owner_user_id = "someone_else", name = "Foreign", slug = "foreign", template_id = domain.TEMPLATE_EMPTY_ID, state = .Active})
			testing.expect(t, saved, serr.message)
		} else { seed_agent(fx, "agt_new") }
		seed_fleet(fx, chain, "agt_new", roles = `["reviewer"]` if scenario == "reviewer_only" else `["worker","security"]` if scenario == "role_reviewer" else `["worker"]`)
		inst := seed_instance(fx, chain, "inst_new", "agt_new", "br_1", "stopped")
		inst.stopped_by = agent.STOPPED_BY_USER
		_, _, _ = iface.agent_save_instance(&fx.agents, inst)
		if scenario == "archived" {
			a, _, _ := iface.agent_get(&fx.agents, "agt_new")
			a.state = .Archived
			_, _, _ = iface.agent_save(&fx.agents, a)
		}
		if scenario == "paused" {
			rows, _ := iface.taskchain_list_fleets_by_chain(&fx.repo, chain.chain_id, "u1")
			for row in rows do if row.agent_id == "agt_new" { changed := row; changed.paused_roles_json = `["worker"]`; _, _ = iface.taskchain_upsert_fleet(&fx.repo, changed) }
		}
		if scenario == "held" { _, _, _ = task_hold(&fx.svc, task, actor_from_auth(user_auth()), "pause"); task = get_task(fx, string(task.task_id)) }
		if scenario == "offline" do set_bridge_status(fx, "br_1", false)
		if scenario == "capacity" {
			seed_instance(fx, chain, "inst_busy", "agt_new", "br_1", "running")
			_ = publish_task(t, fx, chain, "task_busy", brief = `{"goal":"busy","assignee":"agt_new","review_roles":[]}`)
		}
		if scenario == "runtime_busy" do fx.agents.runtime_busy = proc(ctx: rawptr, instance_id: string) -> (bool, domain.Domain_Error) { return instance_id == "inst_new", {} }
		provider_impl: sqlite.Provider_Repo_SQLite
		providers := sqlite.new_provider_repository(&provider_impl, &fx.conn)
		agent_service := agent.new_agent_service(&fx.agents, &fx.bridges, &fx.clock, &fx.ids)
		if scenario == "provider" { agent_service.providers = &providers; fx.svc.agent_service = &agent_service }
		if scenario == "grant_storage" do testing.expect(t, sqlite.exec(&fx.conn, "CREATE TRIGGER reject_delegation_lease BEFORE INSERT ON task_leases BEGIN SELECT RAISE(ABORT, 'injected grant failure'); END;"), "inject grant failure after assignment and reset")
		if scenario == "live_task_lease" {
			_, saved, serr := iface.taskchain_save_lease(&fx.repo, domain.Task_Lease{lease_id = "lease_live", task_id = task.task_id, chain_id = chain.chain_id, owner_user_id = "u1", holder_instance_id = "inst_old", kind = domain.LEASE_KIND_WORK, granted_at = "2026-09-21T00:00:00Z", expires_at = "2026-09-22T00:00:00Z", hard_deadline_at = "2026-09-22T00:00:00Z", delivery = domain.LEASE_DELIVERY_WAKE})
			testing.expect(t, saved, serr.message)
		}
		before := get_task(fx, string(task.task_id))
		auth := inst_auth("inst_coord") if scenario == "agent_auth" else user_auth()
		started := false
		err: domain.Domain_Error
		if scenario == "workflow" {
			// Exercise the early fence with a workflow identity without forging
			// immutable workflow execution rows into this legacy fixture.
			u, opened, uerr := begin_uow(&fx.svc)
			if !testing.expect(t, opened, uerr.message) do continue
			workflow_task := before
			workflow_task.workflow_run_id = "wfr_guard"
			started, err = delegate_task_agent_in_uow(&fx.svc, &u, user_auth(), workflow_task, "agt_new")
			_, _ = end_uow(&fx.svc, &u, false)
		} else {
			started, err = start_task_agent(&fx.svc, auth, task.task_id, "stale" if scenario == "stale" else before.blocked_on_json, "agt_c" if scenario == "coordinator" else "agt_new", "agt_previous_assignment" if scenario == "assignment_changed" else "agt_w", before.attempt_no + 1 if scenario == "attempt_changed" else before.attempt_no)
		}
		testing.expect(t, !started && err.code != .None, scenario)
		after := get_task(fx, string(task.task_id))
		testing.expect_value(t, after.brief_json, before.brief_json)
		testing.expect_value(t, after.blocked_on_json, before.blocked_on_json)
		kept, _, _ := iface.agent_get_instance(&fx.agents, "inst_new")
		testing.expect_value(t, kept.stopped_by, agent.STOPPED_BY_USER)
	}
}
