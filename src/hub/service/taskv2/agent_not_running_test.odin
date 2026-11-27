package taskv2

import "core:strings"
import "core:fmt"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import jsonx "odin_test:lib/jsonx"
import iface "odin_test:hub/repository/iface"
import agent "odin_test:hub/service/agent"
import sqlite "odin_test:hub/repository/sqlite"
import project "odin_test:hub/service/project"

@(test)
test_agent_not_running_offline_start_failure_retry_and_dead_holder :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "anr_retry")
	defer lease_fixture_close(fx, log)
	if !ok do return
	log.service.bridge_command_sink.ctx = log
	log.service.bridge_command_sink.send_runtime_command_wait = fixture_confirm_blocked_start
	chain := seed_live_chain(t, fx, "chain_anr")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "stopped")
	set_bridge_status(fx, "br_1", false)
	task := publish_task(t, fx, chain, "task_anr")
	testing.expect(t, task.state == .Ready && task.blocked_on_json == "", "offline placement leaves task ready")
	for part in ([]string{"agt_w", "br_1", "offline"}) do testing.expect(t, strings.contains(placement_body(fx, "task_anr"), part), part)
	attempts, _ := iface.taskchain_list_attempts_by_task(&fx.repo, task.task_id, "u1")
	testing.expect_value(t, len(attempts), 0)
	auth := contracts.Auth_Context{kind = .Session, user_id = "u1"}
	started, err := start_task_agent(&fx.svc, auth, task.task_id, "outdated block")
	testing.expect(t, !started && err.code == .Conflict, "stale retry cannot act on a newer failure")
	started, err = start_task_agent(&fx.svc, auth, task.task_id)
	testing.expect(t, !started && err.code == .Conflict, "placement alone does not offer legacy Start")
	kind, badge := user_attention(&fx.svc, get_task(fx, "task_anr"))
	testing.expect(t, kind == .None && badge == "", "placement does not replace existing attention identity")
	set_bridge_status(fx, "br_1", true)
	fx.svc.bridge_command_sink = project.Bridge_Command_Sink{send_runtime_command = proc(ctx: rawptr, cmd: project.Runtime_Command) -> (bool, domain.Domain_Error) {
		return false, domain.domain_error(.Internal_Error, "launch refused: no credentials")
	}}
	on_bridge_hello(&fx.svc, "br_1", nil)
	testing.expect(t, strings.contains(get_task(fx, "task_anr").blocked_on_json, "launch refused"), "synchronous reconnect launch failure remains actionable")
	task = get_task(fx, "task_anr")
	testing.expect(t, task.state == .Backlog && strings.contains(task.blocked_on_json, "no credentials"), "failure kept and updated block")
	fx.svc.bridge_command_sink = log.service.bridge_command_sink
	started, err = start_task_agent(&fx.svc, contracts.Auth_Context{kind = .Instance_Token, user_id = "u1"}, task.task_id)
	testing.expect(t, !started && err.code == .Forbidden, "agents cannot start task agents")
 // The native app authenticates with an OIDC bearer, not a browser session.
	started, err = start_task_agent(&fx.svc, contracts.Auth_Context{kind = .OIDC, user_id = "u1"}, task.task_id)
	testing.expect(t, started && err.code == .None, "browser-session retry succeeds")
	lease, held := lease_of(fx, "inst_w1")
	testing.expect(t, held && wake_log_has_run(log, "inst_w1"), "success dispatches")
	confirm_holder(fx, "inst_w1")
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	inst.runtime_status = "stopped"
	_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	on_instance_terminal(&fx.svc, "inst_w1")
	task = get_task(fx, "task_anr")
	testing.expect(t, task.state == .Backlog && is_agent_not_running_block(task.blocked_on_json), "confirmed dead holder blocks")
	waiting, retained := lease_of(fx, "inst_w1")
	testing.expect(t, retained && waiting.lease_id == lease.lease_id && waiting.phase == "waiting", "dead holder retains waiting ownership")
	attempts, _ = iface.taskchain_list_attempts_by_task(&fx.repo, lease.task_id, "u1")
	for a in attempts do testing.expect(t, !a.counts_toward_budget, "infrastructure never spends budget")
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "anr")
	_, forbidden := start_task_agent(&fx.svc, contracts.Auth_Context{kind = .Session, user_id = "someone_else"}, task.task_id)
	testing.expect_value(t, forbidden.code, domain.Error_Code.Not_Found)
}

@(test)
test_agent_not_running_capacity_is_queueing_and_failed_ready_is_blocked :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "anr_capacity")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_anr_capacity")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "running")
	_ = publish_task(t, fx, chain, "task_occupied")
	set_bridge_status(fx, "br_1", false)
	queued := publish_task(t, fx, chain, "task_queued")
	testing.expect(t, queued.state == .Ready && queued.blocked_on_json == "", "full row remains queued even offline")
	set_bridge_status(fx, "br_1", true)
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	inst.runtime_status = "failed"
	inst.last_error_json = "{\"message\":\"provider authentication failed\",\"class\":\"recoverable\"}"
	_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	on_instance_terminal(&fx.svc, "inst_w1")
	queued = get_task(fx, "task_queued")
	testing.expect(t, queued.state == .Ready && queued.blocked_on_json == "", "retained owner keeps other tasks queued")
	occupied := get_task(fx, "task_occupied")
	testing.expect(t, occupied.state == .Backlog && strings.contains(occupied.blocked_on_json, "provider authentication failed"), "failed owner blocks its own task")
	attempts, _ := iface.taskchain_list_attempts_by_task(&fx.repo, queued.task_id, "u1")
	testing.expect_value(t, len(attempts), 0)
	testing.expect_value(t, fleet_changed(&fx.svc, chain, "agt_w").code, domain.Error_Code.None)
	_, held := lease_of(fx, "inst_w1")
	testing.expect(t, held, "fleet repair resets idle failed instance and retries dispatch")
	testing.expect(t, get_task(fx, "task_queued").blocked_on_json == "", "fleet edit clears affected agent blocks")
}

@(test)
test_agent_not_running_unresolvable_provider_and_model :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "anr_model")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_anr_model")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "stopped")
	pv_impl := sqlite.Provider_Repo_SQLite{conn = &fx.conn}
	pv_repo := sqlite.new_provider_repository(&pv_impl, &fx.conn)
	ag_service := log.service
	ag_service.providers = &pv_repo
	fx.svc.agent_service = &ag_service
	fleets, _ := iface.taskchain_list_fleets_by_chain(&fx.repo, chain.chain_id, "u1")
	fleets[0].provider = "unknown-provider"
	fleets[0].model = "unknown-model"
	_, _ = iface.taskchain_upsert_fleet(&fx.repo, fleets[0])
	task := publish_task(t, fx, chain, "task_unknown_provider")
	testing.expect(t, task.state == .Ready && strings.contains(placement_body(fx, "task_unknown_provider"), "unknown-provider"), "unknown provider records placement failure before grant")
	fleets[0].provider = "claude"
	_, _ = iface.taskchain_upsert_fleet(&fx.repo, fleets[0])
	task = publish_task(t, fx, chain, "task_unknown_model")
	testing.expect(t, task.state == .Ready && strings.contains(placement_body(fx, "task_unknown_model"), "unknown-model"), "unknown model records placement failure before grant")
	attempts, _ := iface.taskchain_list_attempts_by_task(&fx.repo, task.task_id, "u1")
	testing.expect_value(t, len(attempts), 0)
}

@(test)
test_agent_not_running_coordinator_start_launches_only_on_user_action :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "anr_coord")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_anr_coord")
	coord, _, _ := iface.agent_get_instance(&fx.agents, "inst_coord")
	coord.runtime_status = "stopped"
	_, _, _ = iface.agent_save_instance(&fx.agents, coord)
	task := publish_coordinator_task(t, fx, chain, "task_coord_anr")
	testing.expect(t, task.state == .Backlog && is_agent_not_running_block(task.blocked_on_json), "dead coordinator blocks ready work")
	testing.expect(t, !wake_log_has_run(log, "inst_coord"), "no automatic coordinator wake")

	pr_impl: sqlite.Project_Repo_SQLite
	pr_repo := sqlite.new_project_repository(&pr_impl, &fx.conn)
	co_impl: sqlite.Content_Repo_SQLite
	co_repo := sqlite.new_content_repository(&co_impl, &fx.conn)
	pv_impl: sqlite.Provider_Repo_SQLite
	pv_repo := sqlite.new_provider_repository(&pv_impl, &fx.conn)
	_, _ = iface.bridge_provider_status_upsert(&pv_repo, domain.Bridge_Provider_Status{bridge_id = "br_1", provider = "claude", state = "present"})
	_, _ = iface.bridge_provider_setting_upsert(&pv_repo, domain.Bridge_Provider_Setting{bridge_id = "br_1", provider = "claude", enabled = true})
	_, _, _ = iface.agent_save_support(&fx.agents, domain.Agent_Bridge_Support{agent_id = "agt_c", bridge_id = "br_1", owner_user_id = "u1", enabled = true})
	registry := project.Bridge_Runtime_Registry{}
	project.bridge_runtime_registry_mark_live(&registry, "br_1", false, "")
	Coordinator_Start :: struct { refuse: bool, service: ^agent.Agent_Service }
	fixture := Coordinator_Start{refuse = true}
	sink := project.Bridge_Command_Sink{ctx = &fixture, send_runtime_command_wait = proc(ctx: rawptr, cmd: project.Runtime_Command, _: int) -> (string, bool, domain.Domain_Error) {
		start := (^Coordinator_Start)(ctx)
		if start.refuse do return "", false, domain.domain_error(.Internal_Error, "coordinator launch refused")
		count := jsonx.extract_int(cmd.body_json, "run_count", 0, false)
		_, ready, err := agent.mark_instance_start_success(start.service, {kind = .Instance_Token, user_id = "u1", agent_instance_id = "inst_coord"}, count)
		if !ready do return "", false, err
		return fmt.aprintf(`{{"ok":true,"command_id":"%s","payload":{{"status":"succeeded","result":{{"agent_instance_id":"inst_coord","runtime_status":"running","expected_run_count":%d,"process_pid":42}}}}}}`, cmd.command_id, count), true, {}
	}}
	ag_service := agent.new_agent_service_with_runtime(&fx.agents, &fx.bridges, &pr_repo, &co_repo, &fx.repo, sink, &registry, &fx.clock, &fx.ids)
	fixture.service = &ag_service
	ag_service.providers = &pv_repo
	ag_service.providers = &pv_repo
	fx.svc.agent_service = &ag_service
	auth := contracts.Auth_Context{kind = .Session, user_id = "u1"}
	started, err := start_task_agent(&fx.svc, auth, task.task_id)
	testing.expect(t, !started && strings.contains(err.message, "coordinator launch refused"), "explicit failed launch returned")
	task = get_task(fx, "task_coord_anr")
	testing.expect(t, task.state == .Backlog && strings.contains(task.blocked_on_json, "coordinator launch refused"), "failed coordinator start remains blocked with updated reason")
	fixture.refuse = false
	started, err = start_task_agent(&fx.svc, auth, task.task_id)
	testing.expect(t, started && err.code == .None, "explicit coordinator start succeeded")
	coord, _, _ = iface.agent_get_instance(&fx.agents, "inst_coord")
	testing.expect_value(t, coord.runtime_status, "running")
	task = get_task(fx, "task_coord_anr")
	testing.expect(t, task.state == .Ready && task.blocked_on_json == "", "successful coordinator start clears block")
	_, held := lease_of(fx, "inst_coord")
	testing.expect(t, !held && !wake_log_has_run(log, "inst_coord"), "matcher remains pull-only")
	coord.runtime_status = "failed"
	coord.last_error_json = `{"code":"provider_error","class":"fatal","message":"provider credentials expired"}`
	_, _, _ = iface.agent_save_instance(&fx.agents, coord)
	u, begun, _ := begin_uow(&fx.svc)
	if !testing.expect(t, begun, "rematch async coordinator failure") do return
	matched, _ := match_chain_in_uow(&fx.svc, &u, chain, .Instance_Terminal)
	_, _ = end_uow(&fx.svc, &u, matched)
	task = get_task(fx, "task_coord_anr")
	testing.expect(t, task.state == .Backlog, "async coordinator failure reblocks")
	reason := jsonx.extract_string(task.blocked_on_json, "reason", "", true, context.temp_allocator)
	testing.expect(t, strings.contains(reason, "provider credentials expired"), "async provider error visible")
	testing.expect(t, !strings.contains(reason, "{"), "provider error is readable text")
	started, err = start_task_agent(&fx.svc, auth, task.task_id)
	testing.expect(t, started && err.code == .None, "coordinator retry after async failure")
	coord, _, _ = iface.agent_get_instance(&fx.agents, "inst_coord")
	coord.runtime_status = "running"
	_, _, _ = iface.agent_save_instance(&fx.agents, coord)
	res, pulled, _ := lease_next(&fx.svc, inst_auth("inst_coord"), Lease_Next_Input{})
	testing.expect(t, pulled && res.status == "granted", "started coordinator pulls task")
}

@(test)
test_agent_not_running_capacity_accounts_for_manual_extra_instances :: proc(t: ^testing.T) {
	instances := make([dynamic]domain.Agent_Instance)
	append(&instances,
		domain.Agent_Instance{agent_instance_id = "held", agent_id = "agt", bridge_id = "br", runtime_status = "running"},
		domain.Agent_Instance{agent_instance_id = "free", agent_id = "agt", bridge_id = "br", runtime_status = "running"},
	)
	held := make(map[string]bool)
	defer delete(held)
	defer delete(instances)
	held["held"] = true
	ctx := Match_Context{instances = instances, held = held}
	testing.expect(t, fleet_row_full(&ctx, domain.Task_Chain_Fleet{agent_id = "agt", capacity = 1}, Placement{bridge_id = "br"}), "manual extra instance cannot bypass full capacity")
	testing.expect(t, !fleet_row_full(&ctx, domain.Task_Chain_Fleet{agent_id = "agt", capacity = 2}, Placement{bridge_id = "br"}), "free capacity is available")
}

@(test)
test_agent_not_running_retriable_failure_queues_until_backoff :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "anr_backoff")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_anr_backoff")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "failed")
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	inst.stopped_at = platform.clock_now(&fx.clock)
	inst.last_error_json = `{"code":"bridge_busy","class":"retriable","message":"rate limited","retry_after_ms":120000,"attempt":1}`
	_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	task := publish_task(t, fx, chain, "task_backoff")
	testing.expect(t, task.state == .Ready && task.blocked_on_json == "", "retriable failure queues")
	fixture_advance(fx, 119)
	_ = fire_due(&fx.svc, now_ms(&fx.clock), false)
	testing.expect_value(t, get_task(fx, string(task.task_id)).state, domain.Task_State.Ready)
	fixture_advance(fx, REMATCH_DELAYS_SECONDS[1] + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock), false)
	_, held := lease_of(fx, "inst_w1")
	testing.expect(t, held && wake_log_has_run(log, "inst_w1"), "automatic grant after backoff")
	testing.expect(t, get_task(fx, string(task.task_id)).blocked_on_json == "", "no user intervention")
}

@(test)
test_agent_not_running_reviewer_restart_preserves_rounds :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "anr_reviewer")
	defer lease_fixture_close(fx, log)
	if !ok do return
	log.service.bridge_command_sink.ctx = log
	log.service.bridge_command_sink.send_runtime_command_wait = fixture_confirm_blocked_start
	chain := seed_live_chain(t, fx, "chain_anr_reviewer")
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_r")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_review_restart", brief = `{"goal":"g","acceptance":["a"],"assignee":"agt_w","reviewers":["agt_r"]}`)
	confirm_holder(fx, "inst_w1")
	_, submitted, _ := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "v1", vcs_json = `{"head":"h1","dirty":false}`})
	if !testing.expect(t, submitted, "first submission") do return
	_, reviewed, _ := review_post(&fx.svc, inst_auth("inst_r1"), Review_Input{verdict = "request_changes", findings_json = `[{"path":"a","line":1,"severity":"major","text":"fix"}]`})
	if !testing.expect(t, reviewed, "first review") do return
	confirm_holder(fx, "inst_w1")
	_, submitted, _ = lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "v2", vcs_json = `{"head":"h2","dirty":false}`})
	if !testing.expect(t, submitted, "second submission") do return
	confirm_holder(fx, "inst_r1")
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_r1")
	inst.runtime_status = "failed"
	_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	on_instance_terminal(&fx.svc, "inst_r1")
	task = get_task(fx, string(task.task_id))
	testing.expect(t, is_agent_not_running_block(task.blocked_on_json), "dead reviewer blocks")
	evs, _ := iface.taskchain_list_events_by_task(&fx.repo, task.task_id, "u1")
	testing.expect_value(t, fold_task(evs, fold_input_for_task(task, true)).review_rounds, 1)
	started, err := start_task_agent(&fx.svc, user_auth(), task.task_id)
	testing.expect(t, started && err.code == .None, "reviewer restart")
	lease, held := lease_of(fx, "inst_r1")
	testing.expect(t, held && lease.kind == domain.LEASE_KIND_REVIEW, "review regranted")
	task = get_task(fx, string(task.task_id))
	evs, _ = iface.taskchain_list_events_by_task(&fx.repo, task.task_id, "u1")
	testing.expect_value(t, fold_task(evs, fold_input_for_task(task, true)).review_rounds, 1)
	testing.expect_value(t, task.state, domain.Task_State.In_Review)
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "review restart")
}

@(test)
test_agent_not_running_hello_only_answers_matching_offline_blocks :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "anr_hello")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_anr_hello")
	seed_bridge(fx, "br_2", online = false)
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "failed")
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	inst.last_error_json = `{"code":"provider_error","class":"fatal","message":"login required"}`
	_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	provider_task := publish_task(t, fx, chain, "task_login")
	offline_task := publish_task(t, fx, chain, "task_other_bridge", bridge_pin = "br_2")
	testing.expect(t, is_agent_not_running_block(provider_task.blocked_on_json), "provider failure blocks")
	testing.expect(t, offline_task.state == .Ready && strings.contains(placement_body(fx, "task_other_bridge"), "bridge_offline"), "other bridge records placement failure")
	on_bridge_hello(&fx.svc, "br_1", nil)
	testing.expect_value(t, get_task(fx, "task_login").blocked_on_json, provider_task.blocked_on_json)
	testing.expect_value(t, get_task(fx, "task_other_bridge").blocked_on_json, offline_task.blocked_on_json)
	testing.expect_value(t, count_events(fx, "task_login", EV_ANSWERED), 0)
	testing.expect_value(t, count_events(fx, "task_other_bridge", EV_ANSWERED), 0)
}

// Covers bridge retry floors and exponential backoff beyond the last rematch,
// including failures after the task's standard rematch timers have expired.
@(test)
test_agent_not_running_long_backoff_retries_at_deadline :: proc(t: ^testing.T) {
	for attempt in ([]int{1, 5, 50}) {
		fx, log, ok := lease_fixture(t, fmt.tprintf("anr_long_%d", attempt))
		defer lease_fixture_close(fx, log)
		if !ok do return
		chain := seed_live_chain(t, fx, "chain_anr_long")
		seed_fleet(fx, chain, "agt_w")
		seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "running")
		task: domain.Task
		if attempt != 1 {
			_ = publish_task(t, fx, chain, "task_occupied")
			confirm_holder(fx, "inst_w1")
			task = publish_task(t, fx, chain, "task_long")
			fixture_advance(fx, 601)
			_ = fire_due(&fx.svc, now_ms(&fx.clock), false)
		}
		inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
		inst.runtime_status = "failed"
		inst.stopped_at = platform.clock_now(&fx.clock)
		inst.last_error_json = fmt.tprintf(`{{"code":"bridge_busy","class":"retriable","message":"rate limited","retry_after_ms":900000,"attempt":%d}}`, attempt)
		_, saved, save_err := iface.agent_save_instance(&fx.agents, inst)
		testing.expect(t, saved, save_err.message)
		stored, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
		testing.expect(t, agent.failed_instance_disposition(stored, now_ms(&fx.clock)) == .Hold, fmt.tprintf("typed failure stored: %s", stored.last_error_json))
		if attempt == 1 {
			task = publish_task(t, fx, chain, "task_long")
		} else {
			// Explicit cancellation frees the occupied worker; the independent
			// queued task must still obey its provider's retry deadline.
			testing.expect_value(t, cancel_task(&fx.svc, get_task(fx, "task_occupied"), Actor{kind = ACTOR_USER, id = "u1"}, "free backoff fixture").code, domain.Error_Code.None)
			confirm_pending_ownership_stop_for_test(t, fx, get_task(fx, "task_occupied"), "inst_w1")
		}
		task = get_task(fx, "task_long")
		testing.expect(t, task.state == .Ready && task.blocked_on_json == "", fmt.tprintf("late failure queues task: %v %s", task.state, task.blocked_on_json))
		wake_log_reset(log)
		delay := agent.instance_retry_delay_ms(attempt, 900000)
		fixture_advance(fx, delay / 1000 - 1)
		_ = fire_due(&fx.svc, now_ms(&fx.clock), false)
		_, held := lease_of(fx, "inst_w1")
		testing.expect(t, !held && !wake_log_has_run(log, "inst_w1"), "no retry before deadline")
		fixture_advance(fx, 2)
		_ = fire_due(&fx.svc, now_ms(&fx.clock), false)
		lease, granted := lease_of(fx, "inst_w1")
		testing.expect(t, granted && lease.task_id == task.task_id && wake_log_has_run(log, "inst_w1"), "long backoff grants without external trigger")
	}
}

@(test)
test_agent_not_running_reviewer_long_backoff_retries :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "anr_review_backoff")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_review_backoff")
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_r")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "failed")
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_r1")
	inst.stopped_at = platform.clock_now(&fx.clock)
	inst.last_error_json = `{"code":"bridge_busy","class":"retriable","message":"rate limited","retry_after_ms":900000,"attempt":1}`
	_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	task := publish_task(t, fx, chain, "task_review_backoff", brief = `{"goal":"g","assignee":"agt_w","reviewers":["agt_r"]}`)
	confirm_holder(fx, "inst_w1")
	_, submitted, _ := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "v1", vcs_json = `{"head":"h1","dirty":false}`})
	if !testing.expect(t, submitted, "submit for review") do return
	fixture_advance(fx, 899)
	_ = fire_due(&fx.svc, now_ms(&fx.clock), false)
	_, held := lease_of(fx, "inst_r1")
	testing.expect(t, !held, "review waits for backoff")
	fixture_advance(fx, 2)
	_ = fire_due(&fx.svc, now_ms(&fx.clock), false)
	lease, granted := lease_of(fx, "inst_r1")
	testing.expect(t, granted && lease.kind == domain.LEASE_KIND_REVIEW && wake_log_has_run(log, "inst_r1"), "review retries after long backoff")
}

@(test)
test_agent_not_running_coordinator_hello_recovers_offline_coordinator :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "anr_coord_hello")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_coord_hello")
	coord, _, _ := iface.agent_get_instance(&fx.agents, "inst_coord")
	coord.runtime_status = "unreachable"
	_, _, _ = iface.agent_save_instance(&fx.agents, coord)
	set_bridge_status(fx, "br_1", false)
	task := publish_coordinator_task(t, fx, chain, "task_coord_hello")
	testing.expect(t, task.state == .Ready && strings.contains(placement_body(fx, "task_coord_hello"), "bridge_offline"), "coordinator bridge absence recorded separately")
	set_bridge_status(fx, "br_1", true)
	coord.runtime_status = "running"
	_, _, _ = iface.agent_save_instance(&fx.agents, coord)
	on_bridge_hello(&fx.svc, "br_1", []string{"inst_coord"})
	task = get_task(fx, "task_coord_hello")
	testing.expect(t, task.state == .Ready && task.blocked_on_json == "", "hello clears coordinator offline block")
	testing.expect_value(t, count_events(fx, "task_coord_hello", EV_ANSWERED), 0)
	testing.expect(t, !wake_log_has_run(log, "inst_coord") && !wake_log_has_stop(log, "inst_coord"), "the coordinator remains pull-only")
	res, pulled, _ := lease_next(&fx.svc, inst_auth("inst_coord"), Lease_Next_Input{})
	testing.expect(t, pulled && res.status == "granted", "reconnected coordinator pulls without Start")
}

// Explicit recovery is scoped to retained responsibility, not every stopped
// instance of the same agent on the machine.
@(test)
test_start_recovery_resets_only_own_waiting_holder :: proc(t: ^testing.T) {
 fx, log, ok := lease_fixture(t, "anr_scoped_recovery")
 defer lease_fixture_close(fx, log)
 if !ok do return
 chain := seed_live_chain(t, fx, "chain_scoped_recovery")
 seed_bridge(fx, "br_1")
 seed_agent(fx, "agt_w")
 for pair in ([]struct {instance, task, phase:string}{
  {"own", "task_own", "waiting"},
  {"other_waiting", "task_other_waiting", "waiting"},
  {"other_active", "task_other_active", "active"},
  {"warm", "", ""},
 }) {
  inst := seed_instance(fx, chain, pair.instance, "agt_w", "br_1", "failed")
  inst.stopped_by="user"; inst.last_error_json=`{"message":"launch failed"}`; inst.run_count=7; inst.start_ref="previous"
  _, saved, err := iface.agent_save_instance(&fx.agents, inst)
  testing.expect(t, saved && err.code==.None)
  if pair.task=="" do continue
  _, saved, err = iface.taskchain_save_task(&fx.repo, {task_id=domain.Task_ID(pair.task), chain_id=chain.chain_id, owner_user_id="u1", title=pair.task, state=.Backlog, publish_state=.Published})
  testing.expect(t, saved && err.code==.None)
  _, saved, err = iface.taskchain_save_lease(&fx.repo, {lease_id=pair.instance, task_id=domain.Task_ID(pair.task), chain_id=chain.chain_id, owner_user_id="u1", holder_instance_id=pair.instance, kind=domain.LEASE_KIND_WORK, phase=pair.phase, bridge_id="br_1"})
  testing.expect(t, saved && err.code==.None)
 }
 // Automatic fleet repair must preserve every held instance.
 reset, err := reset_idle_agent_instances(&fx.svc, nil, "u1", chain.chain_id, "agt_w", "br_1")
 testing.expect(t, reset && err.code==.None)
 own, _, _ := iface.agent_get_instance(&fx.agents, "own")
 testing.expect(t, own.runtime_status=="failed" && own.stopped_by=="user")
 reset, err = reset_idle_agent_instances(&fx.svc, nil, "u1", chain.chain_id, "agt_w", "br_1", true, "task_own")
 testing.expect(t, reset && err.code==.None)
 for id in ([]string{"own","other_waiting","other_active","warm"}) {
  inst, found, err := iface.agent_get_instance(&fx.agents, id)
  testing.expect(t, found && err.code==.None)
  if id=="own" {
   testing.expect(t, inst.runtime_status=="failed" && inst.stopped_by=="" && inst.last_error_json=="")
  } else {
   testing.expectf(t, inst.runtime_status=="failed" && inst.stopped_by=="user" && inst.last_error_json==`{"message":"launch failed"}`, "unrelated instance %s unchanged", id)
  }
  testing.expect(t, inst.run_count==7 && inst.start_ref=="previous")
 }
 claim, found, _ := iface.taskchain_get_lease_by_holder(&fx.repo, "own")
 testing.expect(t, found && claim.task_id=="task_own" && claim.phase==domain.LEASE_PHASE_WAITING)
}

// A terminal status can come from reconnect inventory loss even while the
// agent owns a confirmed claim. Only process evidence can park its work.
@(test)
test_terminal_hint_needs_pty_exit_for_current_claim :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "terminal_probe")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_probe")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "running")
	_ = publish_task(t, fx, chain, "task_probe")
	confirm_holder(fx, "inst_w1")
	original, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held && original.confirmed_at != "", "confirmed lease fixture") do return
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	inst.runtime_status = "failed"
	if inst.run_count == 0 do inst.run_count = 1
	_, stored, _ := iface.agent_save_instance(&fx.agents, inst)
	if !testing.expect(t, stored, "persist fixture generation") do return

	Probe :: struct { state, epoch: string, calls, run_count: int }
	probe := Probe{run_count = inst.run_count, epoch = inst.launch_epoch}
	service := agent.Agent_Service{ids = &fx.ids, bridge_command_sink = {
		ctx = &probe,
		send_runtime_command_wait = proc(ctx: rawptr, command: project.Runtime_Command, timeout: int) -> (string, bool, domain.Domain_Error) {
			p := (^Probe)(ctx)
			p.calls += 1
			if p.state == "offline" do return "", false, domain.domain_error(.Bridge_Offline, "mock disconnected")
			return fmt.aprintf(`{{"command_id":"%s","ok":true,"payload":{{"result":{{"agent_instance_id":"inst_w1","state":"%s","pid":42,"exit_code":0,"run_count":%d,"launch_epoch":"%s"}}}}}}`, command.command_id, p.state, p.run_count, p.epoch), true, {}
		},
	}}
	fx.svc.agent_service = &service
	for state in ([]string{"alive", "offline"}) {
		probe.state = state
		queue_instance_terminal_probe(&fx.svc, "inst_w1")
		queue_instance_terminal_probe(&fx.svc, "inst_w1")
		drain_instance_terminal_probes(&fx.svc)
		current, current_held := lease_of(fx, "inst_w1")
		testing.expect(t, current_held && current.lease_id == original.lease_id && current.phase != domain.LEASE_PHASE_WAITING, state)
	}
	testing.expect_value(t, probe.calls, 2)
	probe.state = "exited"
	probe.run_count += 1
	queue_instance_terminal_probe(&fx.svc, "inst_w1")
	drain_instance_terminal_probes(&fx.svc)
	testing.expect_value(t, get_task(fx, "task_probe").state, domain.Task_State.In_Progress)
	probe.run_count = inst.run_count

	stale := inst
	stale.run_count += 1
	on_instance_terminal(&fx.svc, "inst_w1", &stale, original.lease_id)
	on_instance_terminal(&fx.svc, "inst_w1", &inst, "different_claim")
	testing.expect_value(t, get_task(fx, "task_probe").state, domain.Task_State.In_Progress)
	probe.state = "exited"
	queue_instance_terminal_probe(&fx.svc, "inst_w1")
	drain_instance_terminal_probes(&fx.svc)
	current, current_held := lease_of(fx, "inst_w1")
	testing.expect(t, current_held && current.lease_id == original.lease_id && current.phase == domain.LEASE_PHASE_WAITING, "confirmed exit parks the same claim")
	testing.expect(t, is_agent_not_running_block(get_task(fx, "task_probe").blocked_on_json))
}


fixture_confirm_blocked_start :: proc(raw: rawptr, command: project.Runtime_Command, _: int) -> (string, bool, domain.Domain_Error) {
	log := (^Wake_Log)(raw)
	payload, exists := jsonx.extract_raw_object(command.body_json, "payload", true, context.temp_allocator)
	if !exists || !jsonx.extract_bool(command.body_json, "confirm_start", false, true) {
		return "", false, domain.domain_error(.Validation_Failed, "Start agent must request a confirmed launch")
	}
	id := jsonx.extract_string(payload, "agent_instance_id", "", true, context.temp_allocator)
	count := jsonx.extract_int(payload, "run_count", 0, true)
	owner := string(domain.User_ID("u1"))
	row, ready, err := agent.mark_instance_start_success(&log.service, {kind = .Instance_Token, user_id = owner, agent_instance_id = id}, count)
	defer domain.agent_instance_destroy(&row)
	if !ready do return "", false, err
	result := json_begin()
	json_str(&result, "agent_instance_id", id)
	json_int(&result, "expected_run_count", i64(count))
	json_int(&result, "process_pid", 42)
	json_str(&result, "runtime_status", "running")
	outcome := json_begin()
	json_str(&outcome, "status", "succeeded")
	json_raw(&outcome, "result", json_end(&result))
	reply := json_begin()
	json_str(&reply, "command_id", command.command_id)
	json_bool(&reply, "ok", true)
	json_raw(&reply, "payload", json_end(&outcome))
	return strings.clone(json_end(&reply)), true, {}
}
