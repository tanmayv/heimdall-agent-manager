package taskv2

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import jsonx "odin_test:lib/jsonx"

// SCHED-0a migration tests (spec art_18eb828949cd9431, section 14.6).

// SCHED0_REARM_SQL writes what migration 259 snapshots on an existing database:
// the fleet role data (the role columns themselves are dropped by 260) and the
// one-shot marker. The pre-0b role state of tasks, verdicts and pauses is
// written directly, since the engine no longer has roles.
@(private = "file")
SCHED0_REARM_SQL :: `INSERT OR IGNORE INTO sched0_fleet_roles (chain_id, agent_id, roles_json, paused_roles_json) VALUES
 ('chain_mixed', 'agt_w', '["worker"]', ''), ('chain_mixed', 'agt_s', '["sec"]', ''), ('chain_mixed', 'agt_u', '["ux"]', ''),
 ('chain_mixed', 'agt_n', '["named-reviewer"]', ''), ('chain_mixed', 'agt_r', '["worker","reviewer"]', '["reviewer"]'),
 ('chain_mixed', 'agt_p', '["worker"]', '["*"]'), ('chain_solo', 'agt_solo', '["worker"]', ''), ('chain_wf', 'agt_s', '["sec"]', '');
INSERT OR IGNORE INTO sched0_migration_pending (singleton) VALUES (1);`

@(private = "file")
Sched0_Notices :: struct {
	lines: [dynamic]string,
}

@(private = "file")
sched0_notice_observer :: proc(ctx: rawptr, instance_id, trigger, line: string) {
	c := (^Sched0_Notices)(ctx)
	if trigger == NOTICE_MIGRATION_HOLD do append(&c.lines, fmt.aprintf("%s|%s", instance_id, line))
}

@(private = "file")
sched0_set_fleet :: proc(fx: ^Fixture, chain: domain.Task_Chain, agent_id: string, paused: bool) {
	now := platform.clock_now(&fx.clock)
	_, _ = iface.taskchain_upsert_fleet(&fx.repo, domain.Task_Chain_Fleet{task_chain_id = chain.chain_id, agent_id = agent_id, capacity = 1, paused = paused, created_at = now, updated_at = now})
}

@(private = "file")
sched0_hold_reason :: proc(fx: ^Fixture, task_id: string) -> string {
	return scalar_text(fx, fmt.tprintf("SELECT coalesce(json_extract(payload_json, '$.reason'), '') FROM task_events WHERE task_id = '%s' AND kind = 'held' ORDER BY event_id DESC LIMIT 1;", task_id))
}

// sched0_world_digest: everything the mapping writes (briefs, its events and
// holds, verdict rows, review lease roles, fleet pause, workflow snapshots).
@(private = "file")
sched0_world_digest :: proc(fx: ^Fixture) -> string {
	return scalar_text(fx, `SELECT (SELECT count(*) FROM task_events WHERE kind IN ('sched0_migrated', 'held')) || '|' || coalesce((SELECT group_concat(task_id || brief_json, ';') FROM (SELECT * FROM tasks ORDER BY task_id)), '') || '|' || coalesce((SELECT group_concat(task_id || attempt_no || role || reviewer_agent_id || verdict, ';') FROM (SELECT * FROM task_reviews ORDER BY task_id, attempt_no, role, reviewer_agent_id)), '') || '|' || coalesce((SELECT group_concat(lease_id || phase, ';') FROM (SELECT * FROM task_leases WHERE kind = 'review' ORDER BY lease_id)), '') || '|' || coalesce((SELECT group_concat(task_chain_id || agent_id || paused, ';') FROM (SELECT * FROM task_chain_fleets ORDER BY task_chain_id, agent_id)), '') || '|' || coalesce((SELECT group_concat(spec_json || revision, ';') FROM workflow_runs), '');`)
}

@(private = "file")
sched0_reviewers :: proc(brief_json: string) -> string {
	raw, _ := jsonx.extract_raw_array(brief_json, "reviewers", true, context.temp_allocator)
	return raw
}

@(test)
test_sched0_migration_maps_production_shaped_database :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fx, log, ok := lease_fixture(t, "sched0_migration")
	defer lease_fixture_close(fx, log)
	if !ok do return
	notices := Sched0_Notices{lines = make([dynamic]string)}
	fx.svc.notify_observer = sched0_notice_observer
	fx.svc.notify_observer_ctx = &notices

	// ---- chain_mixed: ordinary coordinator, role-based and named reviews -------
	chain := seed_live_chain(t, fx, "chain_mixed")
	chain.defaults_json = `{"review_roles":{"sec":{"description":"Check the security boundary"}}}`
	_, _, _ = iface.taskchain_save_chain(&fx.repo, chain)
	for id in ([]string{"agt_s", "agt_u", "agt_n", "agt_p"}) do seed_agent(fx, id)
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_s")
	seed_fleet(fx, chain, "agt_u")
	seed_fleet(fx, chain, "agt_n")
	sched0_set_fleet(fx, chain, "agt_r", true) // partial pause (worker+reviewer, reviewer paused) in the snapshot
	sched0_set_fleet(fx, chain, "agt_p", true) // full pause
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_s1", "agt_s", "br_1", "idle")
	seed_instance(fx, chain, "inst_u1", "agt_u", "br_1", "idle")

	// In review with one of two role approvals; the approving reviewer's lease
	// is parked as a waiting claim (legacy data: since SCHED-1a a posted review
	// deletes the lease, so the parked row is re-seeded directly). Driven with
	// agent reviewers, then rewritten to the pre-0b role form below.
	_ = publish_task(t, fx, chain, "t_review", brief = `{"goal":"g","acceptance":["a"],"assignee":"agt_w","reviewers":["agt_s","agt_u"]}`)
	confirm_holder(fx, "inst_w1")
	_, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "v1", vcs_json = `{"head":"h1","dirty":false}`})
	if !testing.expect(t, sok, fmt.tprintf("submit: %s", serr.message)) do return
	s1_review, s1_held := lease_of(fx, "inst_s1")
	if !testing.expect(t, s1_held && s1_review.kind == domain.LEASE_KIND_REVIEW, "fixture: reviewer s1 holds its review lease") do return
	g1, g1ok, g1err := review_post(&fx.svc, inst_auth("inst_s1"), Review_Input{verdict = "approve", findings_json = "[]"})
	if !testing.expect(t, g1ok, fmt.tprintf("review: %s", g1err.message)) do return
	testing.expect_value(t, g1.gate, Gate_Result.Waiting)
	s1_review.phase = domain.LEASE_PHASE_WAITING
	_, _, _ = iface.taskchain_save_lease(&fx.repo, s1_review)
	parked, has_parked := lease_of(fx, "inst_s1")
	testing.expect(t, has_parked && parked.phase == domain.LEASE_PHASE_WAITING, "fixture: approving reviewer holds a parked claim")
	live, has_live := lease_of(fx, "inst_u1")
	testing.expect(t, has_live && live.phase == domain.LEASE_PHASE_ACTIVE && live.kind == domain.LEASE_KIND_REVIEW, "fixture: pending reviewer holds a live review lease")
	testing.expect(t, sqlite.exec(&fx.conn, `UPDATE tasks SET brief_json = '{"goal":"g","acceptance":["a"],"assignee":"agt_w","review_roles":["sec","ux"]}' WHERE task_id = 't_review'; UPDATE task_reviews SET role = 'sec' WHERE task_id = 't_review';`), "fixture: pre-0b role form")

	named_brief := `{"goal":"g","acceptance":["a"],"assignee":"agt_w","reviewers":["agt_n"]}`
	_ = publish_task(t, fx, chain, "t_named", brief = named_brief)
	_ = publish_task(t, fx, chain, "t_unassigned", brief = `{"goal":"g","assignee":"","review_roles":["sec"]}`)
	_ = publish_task(t, fx, chain, "t_unheld", brief = `{"goal":"g","assignee":"agt_w","review_roles":["perf"]}`)
	_ = publish_task(t, fx, chain, "t_ghost", brief = `{"goal":"g","assignee":"agt_ghost"}`)
	_ = publish_task(t, fx, chain, "t_gone", brief = `{"goal":"g","assignee":"agt_w","reviewers":["agt_gone"]}`)
	cancelled := publish_task(t, fx, chain, "t_cancelled", brief = `{"goal":"g","assignee":"","review_roles":["sec"]}`)
	_, cok, cerr := task_cancel(&fx.svc, cancelled, Actor{kind = ACTOR_USER, id = "u1"}, Task_Cancel_Input{reason = "obsolete", request_id = "req_sched0_cancel"})
	testing.expect(t, cok, fmt.tprintf("cancel: %s", cerr.message))
	named_before := get_task(fx, "t_named").brief_json

	// ---- chain_solo: the coordinator's agent is the only agent of the fleet ----
	seed_agent(fx, "agt_solo")
	solo := seed_chain(t, fx, "chain_solo", true)
	solo.coordinator_agent_instance_id = "inst_solo"
	_, _, _ = iface.taskchain_save_chain(&fx.repo, solo)
	seed_instance(fx, solo, "inst_solo", "agt_solo", "br_1", "running", "coordinator")
	seed_fleet(fx, solo, "agt_solo")
	_ = publish_task(t, fx, solo, "t_solo", brief = `{"goal":"g","assignee":""}`)

	// ---- chain_wf: a running workflow run whose stage still names a role --------
	wf_chain := seed_chain(t, fx, "chain_wf", false)
	seed_fleet(fx, wf_chain, "agt_s")
	now := platform.clock_now(&fx.clock)
	wu, wuok, _ := begin_uow(&fx.svc)
	testing.expect(t, wuok, "workflow fixture uow")
	_, rok, rerr := iface.taskchain_insert_workflow_run(&fx.repo, domain.Workflow_Run{
		run_id = "wfr_sched0", chain_id = wf_chain.chain_id, owner_user_id = "u1", title = "wf", definition_ref = "wf@1",
		spec_json = `{"schema":"workflow.v1","name":"wf","stages":[{"key":"build","brief":{"goal":"b","assignee":"agt_w","review_roles":["sec"]}},{"key":"check","brief":{"goal":"c"}}]}`,
		inputs_json = "{}", current_execution_no = 1, request_id = "wfr_sched0", request_hash = "h",
		created_by_kind = "user", created_by_id = "u1", created_at = now, updated_at = now, revision = 1,
	})
	_, eok, eerr := iface.taskchain_insert_workflow_execution(&fx.repo, domain.Workflow_Run_Execution{
		run_id = "wfr_sched0", execution_no = 1, chain_id = wf_chain.chain_id, owner_user_id = "u1",
		state = domain.WORKFLOW_EXECUTION_RUNNING, resolved_inputs_json = "{}", output_manifest_json = "{}", revision = 1,
	})
	_, _ = end_uow(&fx.svc, &wu, rok && eok)
	testing.expect(t, rok && eok, fmt.tprintf("fixture: running workflow run: %s %s", rerr.message, eerr.message))

	// ---- migrate ----------------------------------------------------------------
	testing.expect(t, sqlite.exec(&fx.conn, SCHED0_REARM_SQL), "re-arm migration 259 data snapshot")
	boot(&fx.svc)

	// Role-based review mapped to named reviewers; review roles gone; focus kept.
	review := get_task(fx, "t_review")
	testing.expect_value(t, sched0_reviewers(review.brief_json), `["agt_s","agt_u"]`)
	testing.expect(t, !jsonx.has_key(review.brief_json, "review_roles", true), "review_roles removed")
	testing.expect_value(t, scalar_text(fx, "SELECT json_extract(brief_json, '$.review_focus.agt_s') FROM tasks WHERE task_id = 't_review';"), "Check the security boundary")
	testing.expect_value(t, scalar_text(fx, "SELECT assignee_agent_id FROM tasks WHERE task_id = 't_review';"), "agt_w")
	testing.expect_value(t, scalar_text(fx, "SELECT group_concat(agent_id, ',') FROM (SELECT agent_id FROM task_reviewers WHERE task_id = 't_review' ORDER BY agent_id);"), "agt_s,agt_u")
	testing.expect_value(t, count_events(fx, "t_review", EV_SCHED0_MIGRATED), 1)
	testing.expect_value(t, review.state, domain.Task_State.In_Review)
	testing.expect(t, !task_is_held(review), "a mappable task is not held")
	// Exactly the missing approval is still needed: agt_s's verdict carried over.
	testing.expect_value(t, scalar_text(fx, "SELECT group_concat(reviewer_agent_id || ':' || role || ':' || verdict, ',') FROM task_reviews WHERE task_id = 't_review' AND attempt_no = 1;"), "agt_s:review:approve")
	_, still_parked := lease_of(fx, "inst_s1")
	testing.expect(t, !still_parked, "parked review claim deleted")
	moved, moved_ok := lease_of(fx, "inst_u1")
	testing.expect(t, moved_ok && moved.phase == domain.LEASE_PHASE_ACTIVE && moved.kind == domain.LEASE_KIND_REVIEW, fmt.tprintf("live review lease kept for the agent's single verdict: ok=%v phase=%s task=%s", moved_ok, moved.phase, moved.task_id))
	g2, g2ok, g2err := review_post(&fx.svc, inst_auth("inst_u1"), Review_Input{verdict = "approve", findings_json = "[]"})
	if testing.expect(t, g2ok, fmt.tprintf("post-migration review: %s", g2err.message)) {
		testing.expect_value(t, g2.gate, Gate_Result.Approved)
		testing.expect_value(t, get_task(fx, "t_review").state, domain.Task_State.Done)
	}

	// Named reviewers alone: nothing to change, no event.
	testing.expect_value(t, get_task(fx, "t_named").brief_json, named_before)
	testing.expect_value(t, count_events(fx, "t_named", EV_SCHED0_MIGRATED), 0)

	// Unmappable open tasks are held with their cause, never reassigned.
	testing.expect(t, task_is_held(get_task(fx, "t_unassigned")), "unassigned task in a mixed chain held")
	testing.expect(t, strings.has_prefix(sched0_hold_reason(fx, "t_unassigned"), "sched0_migration: no_assignee"), sched0_hold_reason(fx, "t_unassigned"))
	testing.expect_value(t, brief_assignee(get_task(fx, "t_unassigned").brief_json), "")
	testing.expect_value(t, sched0_reviewers(get_task(fx, "t_unassigned").brief_json), `["agt_s"]`)
	testing.expect(t, task_is_held(get_task(fx, "t_unheld")), "role without a holder held")
	testing.expect(t, strings.contains(sched0_hold_reason(fx, "t_unheld"), "review_role_unheld perf"), sched0_hold_reason(fx, "t_unheld"))
	testing.expect(t, task_is_held(get_task(fx, "t_ghost")), "missing assignee agent held")
	testing.expect(t, strings.contains(sched0_hold_reason(fx, "t_ghost"), "assignee_missing agt_ghost"), sched0_hold_reason(fx, "t_ghost"))
	testing.expect_value(t, brief_assignee(get_task(fx, "t_ghost").brief_json), "agt_ghost")
	testing.expect(t, task_is_held(get_task(fx, "t_gone")), "missing reviewer agent held")
	testing.expect(t, strings.contains(sched0_hold_reason(fx, "t_gone"), "reviewer_missing agt_gone"), sched0_hold_reason(fx, "t_gone"))

	// Terminal tasks: rewritten best-effort, never held.
	gone := get_task(fx, "t_cancelled")
	testing.expect_value(t, gone.state, domain.Task_State.Cancelled)
	testing.expect(t, !task_is_held(gone) && !jsonx.has_key(gone.brief_json, "review_roles", true), "cancelled task mapped, not held")

	// True soloist chain: its unassigned task goes to the coordinator's agent.
	solo_task := get_task(fx, "t_solo")
	testing.expect_value(t, brief_assignee(solo_task.brief_json), "agt_solo")
	testing.expect(t, !task_is_held(solo_task), "soloist chain task not held")
	testing.expect_value(t, scalar_text(fx, "SELECT json_extract(payload_json, '$.assigned_to_coordinator') FROM task_events WHERE task_id = 't_solo' AND kind = 'sched0_migrated';"), "1")

	// Fleet pause: partial becomes full (fail closed); full stays; others untouched.
	testing.expect_value(t, scalar_int(fx, "SELECT paused FROM task_chain_fleets WHERE task_chain_id = 'chain_mixed' AND agent_id = 'agt_r';"), 1)
	testing.expect_value(t, scalar_int(fx, "SELECT paused FROM task_chain_fleets WHERE task_chain_id = 'chain_mixed' AND agent_id = 'agt_p';"), 1)
	testing.expect_value(t, scalar_int(fx, "SELECT paused FROM task_chain_fleets WHERE task_chain_id = 'chain_mixed' AND agent_id = 'agt_w';"), 0)

	// Running workflow run: the immutable snapshot is kept; the stage mapping is
	// recorded as a run event.
	run, run_ok, _ := iface.taskchain_get_workflow_run(&fx.repo, "wfr_sched0", "u1")
	testing.expect(t, run_ok && run.revision == 1 && strings.contains(run.spec_json, "review_roles"), "workflow snapshot untouched")
	testing.expect_value(t, scalar_text(fx, "SELECT json_extract(payload_json, '$.stages.build.reviewers') FROM workflow_run_events WHERE run_id = 'wfr_sched0' AND kind = 'sched0_migrated';"), `["agt_s"]`)

	// One alert to the mixed chain's coordinator, none to the soloist.
	mixed_alerts, solo_alerts := 0, 0
	for line in notices.lines {
		if strings.has_prefix(line, "inst_coord|") {
			mixed_alerts += 1
			for id in ([]string{"t_unassigned", "t_unheld", "t_ghost", "t_gone", "agt_r (was paused for reviewer only)"}) {
				testing.expect(t, strings.contains(line, id), fmt.tprintf("alert names %s: %s", id, line))
			}
			testing.expect(t, !strings.contains(line, "agt_p"), "a fully paused row is not reported")
		}
		if strings.has_prefix(line, "inst_solo|") do solo_alerts += 1
	}
	testing.expect_value(t, mixed_alerts, 1)
	testing.expect_value(t, solo_alerts, 0)
	testing.expect_value(t, scalar_int(fx, "SELECT count(*) FROM sched0_migration_pending;"), 0)
	testing.expect_value(t, scalar_int(fx, "SELECT count(*) FROM sched0_fleet_roles;"), 0)

	// SCHED-0b applies the recorded stage mapping when the running run creates
	// the stage task; a stage that never named roles is left alone.
	wf_run := domain.Workflow_Run{run_id = "wfr_sched0", owner_user_id = "u1"}
	staged := workflow_apply_sched0_mapping(&fx.svc, wf_run, "build", `{"goal":"b","assignee":"agt_w","review_roles":["sec"]}`)
	testing.expect(t, !jsonx.has_key(staged, "review_roles", true) && sched0_reviewers(staged) == `["agt_s"]`, fmt.tprintf("stage mapped at creation: %s", staged))
	seed_fleet(fx, wf_chain, "agt_w")
	testing.expect(t, workflow_validate_fleet(&fx.svc, wf_chain, staged).code == .None, fmt.tprintf("mapped stage validates: %s", staged))
	testing.expect_value(t, workflow_apply_sched0_mapping(&fx.svc, wf_run, "check", `{"goal":"c","assignee":"agt_w"}`), `{"goal":"c","assignee":"agt_w"}`)

	// A second boot changes nothing.
	before := sched0_world_digest(fx)
	clear(&notices.lines)
	boot(&fx.svc)
	testing.expect_value(t, sched0_world_digest(fx), before)
	testing.expect_value(t, len(notices.lines), 0)
}

// Migration 259 itself on a pre-259 schema: columns, projections, backfill,
// marker and snapshot; and an empty database gets no marker.
@(test)
test_sched0_migration_259_schema_and_projections :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fx, ok := fixture_open(t, "sched0_259", stop_before = "259_agent_id_assignment.sql")
	defer fixture_close(fx)
	if !ok do return
	testing.expect(t, sqlite.exec(&fx.conn, `INSERT INTO task_chains (chain_id, owner_user_id, title, description, publish_state, status, kind, coordinator_agent_instance_id, defaults_json, created_at, updated_at, published_at, completed_at, last_activity_at, last_title_nudge_at, title_source, is_pinned, pinned_at) VALUES ('chain_259', 'u1', 'c', '', 'published', 'active', 'mixed_work', '', '{}', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '', '', '', '', '', 0, '');
INSERT INTO task_chain_fleets (task_chain_id, agent_id, capacity, min_warm, idle_ttl_seconds, provider, model, created_at, updated_at, bridge_models_json, roles_json, bridge_id, paused_roles_json, provider_profile) VALUES
 ('chain_259', 'agt_a', 1, 0, 0, '', '', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '{}', '["worker"]', '', '', ''),
 ('chain_259', 'agt_b', 1, 0, 0, '', '', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '{}', '["worker","sec"]', '', '["sec"]', '');`), "seed pre-259 chain and fleet")
	// The pre-259 schema stops before the post-loop upgrade twins, so the task row
	// is written with the columns every schema has.
	testing.expect(t, sqlite.exec(&fx.conn, `INSERT INTO tasks (task_id, chain_id, owner_user_id, title, brief_json, created_at, updated_at) VALUES ('t_259', 'chain_259', 'u1', 't', '{"goal":"g","assignee":" agt_a ","reviewers":["agt_b","user"," agt_c ",""],"review_roles":["sec"]}', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');`), "seed pre-259 task")

	migrated, merr := sqlite.run_migrations(&fx.conn)
	if !testing.expect(t, migrated, merr.message) do return
	testing.expect_value(t, scalar_int(fx, "SELECT paused FROM task_chain_fleets WHERE agent_id = 'agt_a';"), 0)
	testing.expect_value(t, scalar_int(fx, "SELECT paused FROM task_chain_fleets WHERE agent_id = 'agt_b';"), 1)
	testing.expect_value(t, scalar_int(fx, "SELECT max_parallel + review_reserve FROM task_chains WHERE chain_id = 'chain_259';"), 0)
	testing.expect_value(t, scalar_text(fx, "SELECT assignee_agent_id FROM tasks WHERE task_id = 't_259';"), "agt_a")
	testing.expect_value(t, scalar_text(fx, "SELECT group_concat(agent_id || '@' || chain_id || '@' || owner_user_id, ',') FROM (SELECT * FROM task_reviewers WHERE task_id = 't_259' ORDER BY agent_id);"), "agt_b@chain_259@u1,agt_c@chain_259@u1")
	testing.expect_value(t, scalar_int(fx, "SELECT count(*) FROM sched0_migration_pending;"), 1)
	testing.expect_value(t, scalar_text(fx, "SELECT roles_json || paused_roles_json FROM sched0_fleet_roles WHERE agent_id = 'agt_b';"), `["worker","sec"]["sec"]`)
	testing.expect_value(t, scalar_int(fx, "SELECT count(*) FROM sqlite_master WHERE name = 'idx_tasks_chain_assignee_state';"), 1)

	// Projections follow every later brief write, whatever path wrote it.
	task := get_task(fx, "t_259")
	task.brief_json = `{"goal":"g","assignee":"agt_z","reviewers":["agt_y"]}`
	_, saved, serr := iface.taskchain_save_task(&fx.repo, task)
	testing.expect(t, saved, serr.message)
	testing.expect_value(t, scalar_text(fx, "SELECT assignee_agent_id FROM tasks WHERE task_id = 't_259';"), "agt_z")
	testing.expect_value(t, scalar_text(fx, "SELECT group_concat(agent_id, ',') FROM task_reviewers WHERE task_id = 't_259';"), "agt_y")
	testing.expect(t, sqlite.exec(&fx.conn, `UPDATE tasks SET brief_json = 'not json' WHERE task_id = 't_259';`), "an unreadable brief does not fail the write")
	testing.expect_value(t, scalar_text(fx, "SELECT assignee_agent_id FROM tasks WHERE task_id = 't_259';"), "")
	testing.expect_value(t, scalar_int(fx, "SELECT count(*) FROM task_reviewers WHERE task_id = 't_259';"), 0)
	testing.expect(t, sqlite.exec(&fx.conn, `UPDATE tasks SET brief_json = '{"reviewers":["agt_x"]}' WHERE task_id = 't_259'; DELETE FROM tasks WHERE task_id = 't_259';`), "delete task")
	testing.expect_value(t, scalar_int(fx, "SELECT count(*) FROM task_reviewers;"), 0)

	// 260 dropped the role columns; `paused` is the row's own field (SCHED-0b).
	testing.expect(t, !sqlite.table_column_exists(&fx.conn, "task_chain_fleets", "roles_json") && !sqlite.table_column_exists(&fx.conn, "task_chain_fleets", "paused_roles_json") && !sqlite.table_column_exists(&fx.conn, "task_leases", "review_role"), "role columns dropped")
	_, ferr := iface.taskchain_upsert_fleet(&fx.repo, domain.Task_Chain_Fleet{task_chain_id = "chain_259", agent_id = "agt_b", capacity = 1, paused = false})
	testing.expect_value(t, ferr.code, domain.Error_Code.None)
	fleets, _ := iface.taskchain_list_fleets_by_chain(&fx.repo, "chain_259", "u1")
	for f in fleets do if f.agent_id == "agt_b" do testing.expect(t, !f.paused, "resumed row reads unpaused")
	_, _ = iface.taskchain_upsert_fleet(&fx.repo, domain.Task_Chain_Fleet{task_chain_id = "chain_259", agent_id = "agt_a", capacity = 1, paused = true})
	testing.expect_value(t, scalar_int(fx, "SELECT paused FROM task_chain_fleets WHERE agent_id = 'agt_a';"), 1)

	// Chain caps round-trip through the repository.
	c, cok, _ := iface.taskchain_get_chain(&fx.repo, "chain_259")
	if testing.expect(t, cok, "chain readable after 259") {
		c.max_parallel = 3
		c.review_reserve = 1
		_, _, _ = iface.taskchain_save_chain(&fx.repo, c)
		again, _, _ := iface.taskchain_get_chain(&fx.repo, "chain_259")
		testing.expect(t, again.max_parallel == 3 && again.review_reserve == 1, "chain caps persisted")
	}

	// Re-running the migrations is a no-op.
	again_ok, again_err := sqlite.run_migrations(&fx.conn)
	testing.expect(t, again_ok, again_err.message)
	testing.expect_value(t, scalar_int(fx, "SELECT count(*) FROM schema_migrations WHERE version = '259_agent_id_assignment.sql';"), 1)

	// A database with no task-system data has nothing to map.
	fresh, fok := fixture_open(t, "sched0_259_fresh")
	defer fixture_close(fresh)
	if fok do testing.expect_value(t, scalar_int(fresh, "SELECT count(*) FROM sched0_migration_pending;"), 0)
}

// Owner legacy source fences, verbatim from the Mundus database (fixture).
@(private = "file")
SCHED0_OWNER_LEGACY_FENCES_SQL :: #load("../../../../tests/fixtures/owner_legacy_fences.sql", string)

@(private = "file")
SCHED0_OL_DIGEST :: "0000000000000000000000000000000000000000000000000000000000000000"

// The boot mapping on a database with owner legacy source fences (v0.5.92 on
// Mundus): every row of a 'frozen' or 'imported' chain is read-only, so a single
// write there would abort the whole boot UoW and the mapping would never
// commit. Those chains are skipped; every other chain is mapped as usual; the
// fences are untouched.
@(test)
test_sched0_migration_skips_owner_legacy_frozen_chains :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	// Built as Mundus is: the fences predate 260, so 260 runs fence-aware.
	fx, log, ok := lease_fixture(t, "sched0_owner_legacy", stop_before = "260_drop_fleet_roles.sql")
	defer lease_fixture_close(fx, log)
	if !ok do return
	if !testing.expect(t, sqlite.exec(&fx.conn, SCHED0_OWNER_LEGACY_FENCES_SQL), "install owner legacy fences") do return
	migrated, merr := sqlite.run_migrations(&fx.conn)
	if !testing.expect(t, migrated, merr.message) do return
	testing.expect(t, sqlite.table_column_exists(&fx.conn, "task_leases", "review_role"), "fence-aware 260 keeps review_role")
	notices := Sched0_Notices{lines = make([dynamic]string)}
	fx.svc.notify_observer = sched0_notice_observer
	fx.svc.notify_observer_ctx = &notices

	live := seed_live_chain(t, fx, "chain_live")
	seed_agent(fx, "agt_s")
	seed_fleet(fx, live, "agt_w")
	seed_fleet(fx, live, "agt_s")
	_ = publish_task(t, fx, live, "t_live")
	testing.expect(t, sqlite.exec(&fx.conn, `UPDATE tasks SET brief_json = '{"goal":"g","assignee":"agt_w","review_roles":["sec"]}' WHERE task_id = 't_live';`), "live task in pre-0b role form")

	// Frozen and imported chains as the export leaves them (published, still
	// active, quiescent): done and cancelled tasks plus an unassigned open task
	// that would otherwise be held, all in pre-0b role form.
	legacy_briefs := make(map[string]string)
	for chain_id in ([]string{"chain_frozen", "chain_imported", "chain_drain"}) {
		chain := seed_chain(t, fx, chain_id, true)
		chain.coordinator_agent_instance_id = "inst_coord"
		_, _, _ = iface.taskchain_save_chain(&fx.repo, chain)
		seed_fleet(fx, chain, "agt_s")
		for suffix in ([]string{"done", "cancelled", "open"}) {
			id := fmt.tprintf("t_%s_%s", chain_id[len("chain_"):], suffix)
			_ = seed_task(t, fx, chain, id)
			state := "backlog" if suffix == "open" else suffix
			testing.expect(t, sqlite.exec(&fx.conn, fmt.tprintf(`UPDATE tasks SET state = '%s', publish_state = 'published', brief_json = '{{"goal":"g","assignee":"","review_roles":["sec"]}}' WHERE task_id = '%s';`, state, id)), id)
			legacy_briefs[id] = get_task(fx, id).brief_json
		}
	}
	testing.expect(t, sqlite.exec(&fx.conn, `INSERT OR IGNORE INTO sched0_fleet_roles (chain_id, agent_id, roles_json, paused_roles_json) VALUES
 ('chain_live', 'agt_w', '["worker"]', ''), ('chain_live', 'agt_s', '["sec"]', ''),
 ('chain_frozen', 'agt_s', '["sec","worker"]', '["sec"]'), ('chain_imported', 'agt_s', '["sec"]', ''), ('chain_drain', 'agt_s', '["sec"]', '');
INSERT OR IGNORE INTO sched0_migration_pending (singleton) VALUES (1);`), "re-arm migration 259 data snapshot")

	d := SCHED0_OL_DIGEST
	testing.expect(t, sqlite.exec(&fx.conn, fmt.tprintf(`INSERT INTO owner_legacy_source_generations (chain_id, account_id, generation) VALUES ('chain_drain', 'acct', 1), ('chain_frozen', 'acct', 1), ('chain_imported', 'acct', 1);
INSERT INTO owner_legacy_migrations (migration_id, chain_id, account_id, owner_bridge_id, owner_key_id, selection_digest, state, revision, frozen_generation, quiescence_digest, manifest_digest, receipt_digest) VALUES
 ('olm_drain', 'chain_drain', 'acct', 'brg_o', 'key_o', '%s', 'draining', 1, 0, '', '', ''),
 ('olm_frozen', 'chain_frozen', 'acct', 'brg_o', 'key_o', '%s', 'frozen', 2, 1, '%s', '', ''),
 ('olm_imported', 'chain_imported', 'acct', 'brg_o', 'key_o', '%s', 'imported', 3, 1, '%s', '%s', '%s');`, d, d, d, d, d, d, d)), "seed owner legacy migrations")
	fences_before := scalar_text(fx, "SELECT count(*) || ':' || group_concat(name || '=' || sql, ';') FROM (SELECT name, sql FROM sqlite_master WHERE name LIKE 'owner_legacy%' ORDER BY name);")
	// The fixture is live: a write to a frozen chain's task aborts.
	testing.expect(t, !sqlite.exec(&fx.conn, "UPDATE tasks SET title = title WHERE task_id = 't_frozen_done';"), "frozen task rows are read-only")

	boot(&fx.svc)

	// The boot UoW committed: marker taken, snapshot cleared, live chain mapped.
	testing.expect_value(t, scalar_int(fx, "SELECT count(*) FROM sched0_migration_pending;"), 0)
	testing.expect_value(t, scalar_int(fx, "SELECT count(*) FROM sched0_fleet_roles;"), 0)
	live_task := get_task(fx, "t_live")
	testing.expect_value(t, sched0_reviewers(live_task.brief_json), `["agt_s"]`)
	testing.expect(t, !jsonx.has_key(live_task.brief_json, "review_roles", true), "live task review_roles removed")
	testing.expect_value(t, count_events(fx, "t_live", EV_SCHED0_MIGRATED), 1)

	// Frozen and imported chains: nothing written, nothing held, no alert.
	for chain in ([]string{"frozen", "imported"}) {
		for suffix in ([]string{"done", "cancelled", "open"}) {
			id := fmt.tprintf("t_%s_%s", chain, suffix)
			task := get_task(fx, id)
			testing.expect(t, task.brief_json == legacy_briefs[id], fmt.tprintf("%s brief untouched: %s", id, task.brief_json))
			testing.expect_value(t, count_events(fx, id, EV_SCHED0_MIGRATED), 0)
			testing.expect(t, !task_is_held(task), fmt.tprintf("%s not held", id))
		}
	}
	// A draining chain is still the hub's canonical copy: mapped as usual (the
	// fences only bump its source generation).
	testing.expect(t, !jsonx.has_key(get_task(fx, "t_drain_done").brief_json, "review_roles", true), "draining chain mapped")
	testing.expect(t, task_is_held(get_task(fx, "t_drain_open")), "draining chain's unassigned open task held")
	testing.expect(t, scalar_int(fx, "SELECT generation FROM owner_legacy_source_generations WHERE chain_id = 'chain_drain';") > 1, "draining chain writes advance its source generation")
	testing.expect_value(t, scalar_int(fx, "SELECT generation FROM owner_legacy_source_generations WHERE chain_id = 'chain_frozen';"), 1)
	testing.expect_value(t, scalar_int(fx, "SELECT generation FROM owner_legacy_source_generations WHERE chain_id = 'chain_imported';"), 1)
	for line in notices.lines {
		testing.expect(t, !strings.contains(line, "t_frozen_") && !strings.contains(line, "t_imported_"), fmt.tprintf("no alert for a frozen chain: %s", line))
	}
	testing.expect_value(t, scalar_text(fx, "SELECT count(*) || ':' || group_concat(name || '=' || sql, ';') FROM (SELECT name, sql FROM sqlite_master WHERE name LIKE 'owner_legacy%' ORDER BY name);"), fences_before)

	// A second boot changes nothing.
	before := sched0_world_digest(fx)
	boot(&fx.svc)
	testing.expect_value(t, sched0_world_digest(fx), before)
}
