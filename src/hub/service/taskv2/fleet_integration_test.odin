package taskv2

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import fleet "odin_test:hub/service/fleet_application"

@(test)
test_fleet_restart_coordinator_waiting_worker_and_active_reviewer :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "fleet_roles")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "fleet_roles")
	seed_fleet(fx, chain, "agt_w", bridge_id="br_1")
	seed_fleet(fx, chain, "agt_r", roles=`["reviewer"]`, bridge_id="br_1")
	seed_directory(fx, chain, "fleet_roles_dir", "br_1", "git")
	for item in ([]struct {id, agent_id, role: string}{
		{"inst_coord", "agt_c", "coordinator"},
		{"fleet_author", "agt_w", "worker"},
		{"fleet_reviewer", "agt_r", "reviewer"},
	}) {
		i := seed_instance(fx, chain, item.id, item.agent_id, "br_1", "running", item.role)
		testing.expect_value(t, iface.fleet_scope_set(&fx.bridges, i, "chain").code, domain.Error_Code.None)
	}
	task := publish_task(t, fx, chain, "fleet_review_task", brief=`{"goal":"g","acceptance":["a"],"assignee":"agt_w","review_roles":["reviewer"],"reviewers":["agt_r"]}`)
	task.requires_user_approval = true
	_, _, _ = iface.taskchain_save_task(&fx.repo, task)
	confirm_holder(fx, "fleet_author")
	_, submitted, se := lease_submit(&fx.svc, inst_auth("fleet_author"), {summary="review this", vcs_json=`{"head":"fixture-head","dirty":false}`})
	if !testing.expect(t, submitted && se.code==.None, se.message) do return
	confirm_holder(fx, "fleet_reviewer")
	worker, wh := lease_of(fx, "fleet_author")
	reviewer, rh := lease_of(fx, "fleet_reviewer")
	if !testing.expect(t, wh && rh && worker.phase==domain.LEASE_PHASE_WAITING && reviewer.kind==domain.LEASE_KIND_REVIEW && reviewer.phase==domain.LEASE_PHASE_ACTIVE) do return
	task_before := get_task(fx, string(task.task_id))
	fleet_feature_bridge(fx, "br_1")
	p: Fleet_Probe
	defer fleet_probe_close(&p)
	s, sok := fleet_test_service(t, fx, log, &p)
	if !sok do return
	r, accepted, e := fleet_test_apply(&s, "roles")
	if !testing.expect(t, accepted && e.code==.None && len(r.application.targets)==3, e.message) do return
	defer domain.fleet_application_record_destroy(&r)
	testing.expect(t, len(p.commands)==3 && r.application.state=="restarting")
	for target in r.application.targets {
		before, _, _ := iface.agent_get_instance(&fx.agents, target.agent_instance_id)
		on_instance_terminal(&fx.svc, target.agent_instance_id)
		fleet_test_ready(t, fx, log, target)
		after, _, _ := iface.agent_get_instance(&fx.agents, target.agent_instance_id)
		testing.expect(t, after.agent_instance_id==before.agent_instance_id && after.conversation_id==before.conversation_id && after.chain_id==before.chain_id && after.permission_mode==before.permission_mode && after.run_count==before.run_count+1 && after.model=="claude-sonnet-5-5")
		domain.agent_instance_destroy(&before)
		domain.agent_instance_destroy(&after)
	}
	fleet.reconcile(&s)
	status, found, _ := fleet.read_application(&s, {user_id="u1"}, "br_1", r.application.application_id)
	if testing.expect(t, found) {
		testing.expect(t, status.application.state=="ready" && len(p.commands)==6 && !p.under_tx)
		domain.fleet_application_record_destroy(&status)
	}
	for original in ([]domain.Task_Lease{worker, reviewer}) {
		current, held := lease_of(fx, original.holder_instance_id)
		testing.expect(t, held && current.lease_id==original.lease_id && current.attempt_no==original.attempt_no && current.phase==original.phase && current.kind==original.kind && current.review_role==original.review_role && current.model=="claude-sonnet-5-5")
		packed := false
		for cmd in p.commands do if strings.contains(cmd.body_json, original.lease_id) {
			packed = strings.contains(cmd.body_json, "/srv/fleet_roles_dir/.heimdall/worktrees/fleet_review_task")
		}
		testing.expect(t, packed, "worker/reviewer normal launch preserves the task worktree")
	}
	task_after := get_task(fx, string(task.task_id))
	testing.expect(t, task_after.state==task_before.state && task_after.requires_user_approval && task_after.brief_json==task_before.brief_json)
	_, reviewed, re := review_post(&fx.svc, inst_auth("fleet_reviewer"), {verdict="approve"})
	testing.expect(t, reviewed && re.code==.None && get_task(fx, string(task.task_id)).state==.In_Review, "reviewer can finish after Fleet restart; required user gate still waits")
}

@(test)
test_fleet_preview_revalidates_changed_running_targets :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "fleet_preview_race")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "fleet_preview_race")
	coord, _, _ := iface.agent_get_instance(&fx.agents, "inst_coord")
	_=iface.fleet_scope_set(&fx.bridges, coord, "manual")
	domain.agent_instance_destroy(&coord)
	i := seed_instance(fx, chain, "fleet_was_running", "agt_w", "br_1", "running")
	_=iface.fleet_scope_set(&fx.bridges, i, "chain")
	fleet_feature_bridge(fx, "br_1")
	p: Fleet_Probe
	defer fleet_probe_close(&p)
	s, sok := fleet_test_service(t, fx, log, &p)
	if !sok do return
	preview, pe := fleet.preview(&s, {user_id="u1"}, "br_1", {default_runtime={"claude","claude","claude-sonnet-5-5"}})
	testing.expect(t, pe.code==.None && preview.affected_instances==1 && len(p.commands)==0)
	i.runtime_status="stopped"
	_, _, _=iface.agent_save_instance(&fx.agents, i)
	next := seed_instance(fx, chain, "fleet_now_running", "agt_w", "br_1", "running")
	_=iface.fleet_scope_set(&fx.bridges, next, "chain")
	r, accepted, e := fleet_test_apply(&s, "after_preview")
	if !testing.expect(t, accepted && e.code==.None && len(r.application.targets)==1, e.message) do return
	defer domain.fleet_application_record_destroy(&r)
	testing.expect(t, r.application.targets[0].agent_instance_id==next.agent_instance_id && len(p.commands)==1, "Apply independently snapshots current targets; preview does not reserve them")
	stopped, _, _ := iface.agent_get_instance(&fx.agents, i.agent_instance_id)
	testing.expect(t, stopped.runtime_status=="stopped" && stopped.run_count==i.run_count && stopped.configuration_revision==i.configuration_revision)
	domain.agent_instance_destroy(&stopped)
}
