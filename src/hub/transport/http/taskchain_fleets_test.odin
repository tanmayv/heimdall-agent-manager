package http

import "core:strings"
import "core:fmt"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import project_service "odin_test:hub/service/project"
import "core:testing"
import json "core:encoding/json"
import domain "odin_test:hub/domain"

@(test)
test_fleet_bridge_models_wire_roundtrip :: proc(t: ^testing.T) {
	fleet := domain.Task_Chain_Fleet{bridge_models_json = `{"bridge-a":{"provider":"codex","model":"model-a"},"bridge-b":{"provider":"claude","model":"model-b"}}`}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_fleet_json(&b, fleet)
	parsed: Task_Chain_Fleet_Wire
	err := json.unmarshal((transmute([]u8) strings.to_string(b)), &parsed, allocator = context.temp_allocator)
	if !testing.expect(t, err == nil, "fleet response is valid JSON") do return
	testing.expect_value(t, len(parsed.bridge_models), 2)
	testing.expect_value(t, parsed.bridge_models["bridge-a"].provider, "codex")
	testing.expect_value(t, parsed.bridge_models["bridge-b"].model, "model-b")
}

@(test)
test_write_fleet_json :: proc(t: ^testing.T) {
	fleet := domain.Task_Chain_Fleet{
		task_chain_id    = domain.Task_Chain_ID("chain_fleet_abc"),
		agent_id         = "agt_worker",
		capacity         = 4,
		min_warm         = 2,
		idle_ttl_seconds = 600,
		provider         = "claude",
		model             = "smart",
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:05:00Z",
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_fleet_json(&b, fleet)
	out := strings.to_string(b)

	testing.expect(t, strings.contains(out, `"task_chain_id":"chain_fleet_abc"`), "must contain task_chain_id")
	testing.expect(t, strings.contains(out, `"agent_id":"agt_worker"`), "must contain agent_id")
	testing.expect(t, strings.contains(out, `"capacity":4`), "must contain capacity 4")
	testing.expect(t, strings.contains(out, `"active_count":0`), "must contain active_count 0")
	testing.expect(t, strings.contains(out, `"min_warm":2`), "must contain min_warm 2")
	testing.expect(t, strings.contains(out, `"idle_ttl_seconds":600`), "must contain idle_ttl_seconds 600")
	testing.expect(t, strings.contains(out, `"created_at":"2026-09-23T10:00:00Z"`), "must contain created_at")
	testing.expect(t, strings.contains(out, `"updated_at":"2026-09-23T10:05:00Z"`), "must contain updated_at")
	testing.expect(t, strings.contains(out, `"provider":"claude"`), "must contain provider claude")
	testing.expect(t, strings.contains(out, `"model":"smart"`), "must contain model smart")
}

// write_fleet_json is shared by the PUT response and the GET list, so this pins
// the payload contract REQ-FLEET-PT-2 relies on for both verbs.
@(test)
test_write_fleet_json_omitted_provider_model_empty :: proc(t: ^testing.T) {
	fleet := domain.Task_Chain_Fleet{
		task_chain_id    = domain.Task_Chain_ID("chain_fleet_empty"),
		agent_id         = "agt_worker",
		capacity         = 1,
		min_warm         = 0,
		idle_ttl_seconds = 600,
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:05:00Z",
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_fleet_json(&b, fleet)
	out := strings.to_string(b)

	testing.expect(t, strings.contains(out, `"provider":""`), "omitted provider must serialize as empty string (inherit)")
	testing.expect(t, strings.contains(out, `"model":""`), "omitted model must serialize as empty string (inherit)")
}

@(test)
test_fleet_provider_model_parse :: proc(t: ^testing.T) {
	body := `{"capacity":2,"provider":"claude","model":"smart"}`
	testing.expect_value(t, json_string(body, "provider"), "claude")
	testing.expect_value(t, json_string(body, "model"), "smart")

	spaced := `{"provider": "claude", "model": "smart"}`
	testing.expect_value(t, json_string(spaced, "provider"), "claude")
	testing.expect_value(t, json_string(spaced, "model"), "smart")

	omitted := `{"capacity":2}`
	testing.expect_value(t, json_string(omitted, "provider"), "")
	testing.expect_value(t, json_string(omitted, "model"), "")
}

// restart_live_instances is an optional boolean body field: only a well-formed
// JSON boolean literal counts as "carried the flag" — absent or malformed values
// behave exactly like today's flag-less PUT.
@(test)
test_fleet_restart_live_instances_bool_parse :: proc(t: ^testing.T) {
	true_body := `{"capacity":1,"restart_live_instances":true}`
	value, ok := json_bool_literal(true_body, "restart_live_instances")
	testing.expect(t, ok, "present true must parse as a boolean literal")
	testing.expect(t, value, "true must parse to true")

	false_body := `{"restart_live_instances": false}`
	value_false, ok_false := json_bool_literal(false_body, "restart_live_instances")
	testing.expect(t, ok_false, "present false must parse as a boolean literal")
	testing.expect(t, !value_false, "false must parse to false")

	absent_body := `{"capacity":2,"provider":"claude","model":"smart"}`
	_, ok_absent := json_bool_literal(absent_body, "restart_live_instances")
	testing.expect(t, !ok_absent, "absent flag must not report ok")

	malformed_body := `{"restart_live_instances":"true"}`
	value_malformed, ok_malformed := json_bool_literal(malformed_body, "restart_live_instances")
	testing.expect(t, !ok_malformed, "quoted string value is not a boolean literal")
	testing.expect(t, !value_malformed, "malformed value must fall back to false")
}

// The restart selection mirrors the fleet list's active_count predicate: every
// runtime_status except the three terminal states counts as live.
@(test)
test_fleet_restart_instance_live_predicate :: proc(t: ^testing.T) {
	testing.expect(t, fleet_restart_instance_live("running"), "running is live")
	testing.expect(t, fleet_restart_instance_live("idle"), "idle is live")
	testing.expect(t, fleet_restart_instance_live("busy"), "busy is live")
	testing.expect(t, fleet_restart_instance_live("launching"), "launching is live")
	testing.expect(t, fleet_restart_instance_live("starting"), "starting is live")
	testing.expect(t, fleet_restart_instance_live("stopping"), "stopping is live")
	testing.expect(t, fleet_restart_instance_live("blocked"), "blocked is live")
	testing.expect(t, !fleet_restart_instance_live("stopped"), "stopped is not live")
	testing.expect(t, !fleet_restart_instance_live("failed"), "failed is not live")
	testing.expect(t, !fleet_restart_instance_live("terminated"), "terminated is not live")
}

// Only a real provider/model change versus the prior row restarts live instances;
// capacity-only edits never do.
@(test)
test_fleet_provider_model_changed :: proc(t: ^testing.T) {
	testing.expect(t, !fleet_provider_model_changed("claude", "smart", "claude", "smart"), "identical provider/model is no change")
	testing.expect(t, fleet_provider_model_changed("claude", "smart", "codex", "smart"), "provider change must be detected")
	testing.expect(t, fleet_provider_model_changed("claude", "smart", "claude", "cheap"), "model change must be detected")
	testing.expect(t, fleet_provider_model_changed("", "", "claude", "smart"), "unset (inherit) to set values is a change")
	testing.expect(t, fleet_provider_model_changed("claude", "smart", "", ""), "clearing to inherit is a change")
}

// The GET list calls write_fleet_json with the default nil restart params, so its
// payload must stay byte-identical to the pre-restart contract.
@(test)
test_write_fleet_json_default_omits_restart_fields :: proc(t: ^testing.T) {
	fleet := domain.Task_Chain_Fleet{
		task_chain_id    = domain.Task_Chain_ID("chain_fleet_default"),
		agent_id         = "agt_worker",
		capacity         = 1,
		idle_ttl_seconds = 600,
		provider         = "claude",
		model             = "smart",
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:05:00Z",
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_fleet_json(&b, fleet)
	out := strings.to_string(b)

	testing.expect(t, !strings.contains(out, "restarted_instance_ids"), "default output must not carry restart bookkeeping")
	testing.expect(t, !strings.contains(out, "restart_failures"), "default output must not carry restart bookkeeping")
}

// A PUT that carried the flag gets both fields even when nothing was restarted.
@(test)
test_write_fleet_json_restart_fields_empty_when_flagged :: proc(t: ^testing.T) {
	fleet := domain.Task_Chain_Fleet{
		task_chain_id    = domain.Task_Chain_ID("chain_fleet_flagged"),
		agent_id         = "agt_worker",
		capacity         = 1,
		idle_ttl_seconds = 600,
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:05:00Z",
	}
	restarted: []string
	failures: []Fleet_Restart_Failure

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_fleet_json(&b, fleet, 0, &restarted, &failures)
	out := strings.to_string(b)

	testing.expect(t, strings.contains(out, `"restarted_instance_ids":[]`), "flagged PUT must carry an empty restarted list")
	testing.expect(t, strings.contains(out, `"restart_failures":[]`), "flagged PUT must carry an empty failure list")
}

@(test)
test_write_fleet_json_restart_fields_present :: proc(t: ^testing.T) {
	fleet := domain.Task_Chain_Fleet{
		task_chain_id    = domain.Task_Chain_ID("chain_fleet_restart"),
		agent_id         = "agt_worker",
		capacity         = 2,
		idle_ttl_seconds = 600,
		provider         = "codex",
		model             = "cheap",
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:05:00Z",
	}
	restarted := []string{"inst_a", "inst_b"}
	failures := []Fleet_Restart_Failure{{instance_id = "inst_c", message = `bridge "offline"`}}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_fleet_json(&b, fleet, 0, &restarted, &failures)
	out := strings.to_string(b)

	testing.expect(t, strings.contains(out, `"restarted_instance_ids":["inst_a","inst_b"]`), "restarted ids must be emitted in order")
	testing.expect(t, strings.contains(out, `"restart_failures":[{"instance_id":"inst_c","message":"bridge \"offline\""}]`), "failures must carry instance_id + escaped message")
}

@(test)
test_json_int_field :: proc(t: ^testing.T) {
	body1 := `{"capacity": 3, "min_warm": 1}`
	testing.expect_value(t, json_int_field(body1, "capacity", 1), 3)
	testing.expect_value(t, json_int_field(body1, "min_warm", 0), 1)
	testing.expect_value(t, json_int_field(body1, "idle_ttl_seconds", 600), 600)

	body2 := `{"capacity": "5", "min_warm": "2", "idle_ttl_seconds": "900"}`
	testing.expect_value(t, json_int_field(body2, "capacity", 1), 5)
	testing.expect_value(t, json_int_field(body2, "min_warm", 0), 2)
	testing.expect_value(t, json_int_field(body2, "idle_ttl_seconds", 600), 900)
}

// Exercise the HTTP response against the existing real repository/start fixture.
fleet_result_send :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	assert(sqlite.tx_mutex_try_lock(), "fleet send must happen after commit")
	return coordinator_wake_test_command(ctx, command)
}

fleet_result_put :: proc(t: ^testing.T, c: ^Coordinator_Wake_Fixture, body: string) -> Response {
	path := fmt.tprintf("/api/v1/task-chains/%s/fleets/agt_wake", c.f.chain_id)
	return upsert_chain_fleet_handler(&c.f.th, wire_cookie_request(c.f, "PUT", path, body))
}

fleet_result_data :: proc(t: ^testing.T, response: Response) -> []Fleet_Restart_Result {
	testing.expectf(t, response.status == 200, "%d %s", response.status, response.body)
	parsed: struct {data: struct {restart_results: []Fleet_Restart_Result}}
	err := json.unmarshal_string(response.body, &parsed)
	testing.expect(t, err == nil)
	return parsed.data.restart_results
}

@(test)
test_fleet_result_mixed_candidates :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	f := c.f
	repos := iface.Repositories{agents=f.ag_repo, bridges=f.br_repo, taskchains=f.tc_repo, content=c.content_repo}
	impl: sqlite.SQLite_Unit_Of_Work_Factory
	factory := sqlite.new_unit_of_work_factory(&impl, &f.conn, &repos)
	f.tc_svc.uow_factory = &factory
	defer f.tc_svc.uow_factory = nil
	f.ag_svc.bridge_command_sink.send_runtime_command = fleet_result_send
	existing, _, _ := iface.agent_get_instance(&f.ag_repo, "inst_wake")
	// Persist an old fleet destination, then change it to the valid model.
	first := fleet_result_put(t, c, `{"capacity":8,"provider":"claude","model":"old"}`)
	testing.expect_value(t, first.status, 200)
	ids := []string{"inst_wake", "inst_unchanged", "inst_terminal", "inst_offline"}
	for id, i in ids {
		inst := existing
		inst.agent_instance_id = id
		inst.runtime_status = "running"
		inst.model = "old"
		if i == 1 do inst.model = existing.model
		if i == 2 do inst.runtime_status = "stopped"
		if i == 3 do inst.bridge_id = f.bridge_alt
		_, saved, save_err := iface.agent_save_instance(&f.ag_repo, inst)
		testing.expect(t, saved, save_err.message)
		_, member_ok, member_err := iface.taskchain_save_member(&f.tc_repo, {
			chain_id=f.chain_id, owner_user_id=f.owner, agent_id="agt_wake",
			agent_instance_id=id, role="worker", created_at="now",
		})
		testing.expect(t, member_ok, member_err.message)
	}
	body := strings.concatenate({`{"capacity":8,"provider":"claude","model":"`, existing.model, `","restart_live_instances":true}`})
	results := fleet_result_data(t, fleet_result_put(t, c, body))
	testing.expect_value(t, len(results), 4)
	expected := make(map[string]string)
	expected["inst_wake"] = "accepted"
	expected["inst_unchanged"] = "unchanged"
	expected["inst_terminal"] = "ineligible"
	expected["inst_offline"] = "failed"
	for result in results do testing.expect_value(t, result.outcome, expected[result.instance_id])
	launched, _, _ := iface.agent_get_instance(&f.ag_repo, "inst_wake")
	testing.expect_value(t, launched.run_count, existing.run_count+1)
	testing.expect_value(t, launched.model, existing.model)
	// Only the accepted candidate emits a launch; HTTP acceptance is not readiness.
	testing.expect_value(t, launched.runtime_status, "launching")
	testing.expect_value(t, len(c.commands), 1)
}

@(test)
test_fleet_result_lookup_failure_is_not_skipped :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	c.f.ag_repo.get_instance = nil
	results := fleet_result_data(t, fleet_result_put(t, c, `{"restart_live_instances":true}`))
	if testing.expect_value(t, len(results), 1) {
		testing.expect_value(t, results[0].instance_id, "inst_wake")
		testing.expect_value(t, results[0].outcome, "failed")
		testing.expect(t, results[0].message != "")
	}
	testing.expect_value(t, len(c.commands), 0)
}

@(test)
test_fleet_result_list_failure_reports_saved_partial_result :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	c.f.tc_repo.list_members_by_chain = nil
	response := fleet_result_put(t, c, `{"capacity":3,"restart_live_instances":true}`)
	testing.expect_value(t, response.status, 200)
	testing.expect(t, strings.contains(response.body, "could not be listed"))
	testing.expect(t, strings.contains(response.body, `"restart_failures":[{`))
	fleets, err := iface.taskchain_list_fleets_by_chain(&c.f.tc_repo, c.f.chain_id, c.f.owner)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, len(fleets), 1)
	testing.expect_value(t, fleets[0].capacity, 3)
}

@(test)
test_fleet_result_prior_list_failure_prevents_save :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	c.f.tc_repo.list_fleets_by_chain = nil
	response := fleet_result_put(t, c, `{"capacity":3,"restart_live_instances":true}`)
	testing.expect_value(t, response.status, 500)
	testing.expect_value(t, len(c.commands), 0)
	// Restore the real read function, and verify nothing was persisted.
	c.f.tc_repo = sqlite.new_taskchain_repository(&c.f.tc_impl, &c.f.conn)
	fleets, _ := iface.taskchain_list_fleets_by_chain(&c.f.tc_repo, c.f.chain_id, c.f.owner)
	testing.expect_value(t, len(fleets), 0)
}

@(test)
test_fleet_result_unavailable_agent_service_accounts_known_members :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	c.f.th.agents = nil
	results := fleet_result_data(t, fleet_result_put(t, c, `{"restart_live_instances":true}`))
	if testing.expect_value(t, len(results), 1) {
		testing.expect_value(t, results[0].instance_id, "inst_wake")
		testing.expect_value(t, results[0].outcome, "failed")
	}
}

@(test)
test_fleet_result_profile_only_edit_preserves_launch_identity :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	f := c.f
	profile_err := c.providers.reconcile_profiles(c.providers.ctx, f.bridge_pin, {
		{profile_id="claude", provider="claude", enabled=true, state="ok"},
		{profile_id="work", provider="claude", enabled=true, state="ok"},
	})
	testing.expect_value(t, profile_err.code, domain.Error_Code.None)
	_, status_err := iface.bridge_provider_status_upsert(&c.providers, {
		bridge_id=f.bridge_pin, provider="claude", profile_id="work", state="present", binary_path="/bin/claude", checked_at="now",
	})
	testing.expect_value(t, status_err.code, domain.Error_Code.None)
	existing, _, _ := iface.agent_get_instance(&f.ag_repo, "inst_wake")
	existing.runtime_status = "running"
	_, saved, _ := iface.agent_save_instance(&f.ag_repo, existing)
	testing.expect(t, saved)
	first_body := strings.concatenate({`{"provider":"claude","model":"`, existing.model, `"}`})
	testing.expect_value(t, fleet_result_put(t, c, first_body).status, 200)
	body := strings.concatenate({`{"provider":"claude","provider_profile":"work","model":"`, existing.model, `","restart_live_instances":true}`})
	results := fleet_result_data(t, fleet_result_put(t, c, body))
	if testing.expect_value(t, len(results), 1) do testing.expect_value(t, results[0].outcome, "accepted")
	after, _, _ := iface.agent_get_instance(&f.ag_repo, "inst_wake")
	testing.expect_value(t, after.provider, "claude")
	testing.expect_value(t, after.provider_profile, "work")
	testing.expect_value(t, after.run_count, existing.run_count+1)
	testing.expect_value(t, len(c.commands), 1)
	if len(c.commands) == 1 do testing.expect(t, strings.contains(c.commands[0], `"provider_profile":"work"`))
}

// SCHED-0c contracts (spec 6.5): fleet rows have no roles. A PUT or pause
// body naming `roles` is refused with fleet_roles_removed; PUT takes `paused`;
// pause/resume take no body; the wire has no roles, paused_roles or warning.
@(test)
test_fleet_contract_roles_removed_and_paused :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	f := c.f

	roles := fleet_result_put(t, c, `{"capacity":2,"provider":"claude","model":"old","roles":["worker"]}`)
	testing.expectf(t, roles.status == 400 && strings.contains(roles.body, "fleet_roles_removed"), "PUT roles: %d %s", roles.status, roles.body)
	empty_roles := fleet_result_put(t, c, `{"capacity":2,"provider":"claude","model":"old","roles":[]}`)
	testing.expectf(t, empty_roles.status == 400 && strings.contains(empty_roles.body, "fleet_roles_removed"), "PUT empty roles: %d %s", empty_roles.status, empty_roles.body)
	bad_paused := fleet_result_put(t, c, `{"capacity":2,"provider":"claude","model":"old","paused":"yes"}`)
	testing.expect_value(t, bad_paused.status, 400)

	paused := fleet_result_put(t, c, `{"capacity":2,"provider":"claude","model":"old","paused":true}`)
	testing.expectf(t, paused.status == 200 && strings.contains(paused.body, `"paused":true`), "PUT paused: %d %s", paused.status, paused.body)
	for key in ([]string{`"roles"`, `"paused_roles"`, `"warning"`, `"implicit"`}) {
		testing.expectf(t, !strings.contains(paused.body, key), "fleet wire has no %s: %s", key, paused.body)
	}

	base := fmt.tprintf("/api/v1/task-chains/%s/fleets/agt_wake/", f.chain_id)
	resumed := pause_chain_fleet_handler(&f.th, wire_cookie_request(f, "POST", strings.concatenate({base, "resume"}), ""))
	testing.expectf(t, resumed.status == 200 && strings.contains(resumed.body, `"paused":false`), "resume: %d %s", resumed.status, resumed.body)
	paused_again := pause_chain_fleet_handler(&f.th, wire_cookie_request(f, "POST", strings.concatenate({base, "pause"}), ""))
	testing.expectf(t, paused_again.status == 200 && strings.contains(paused_again.body, `"paused":true`), "pause: %d %s", paused_again.status, paused_again.body)
	role_pause := pause_chain_fleet_handler(&f.th, wire_cookie_request(f, "POST", strings.concatenate({base, "resume"}), `{"roles":["reviewer"]}`))
	testing.expectf(t, role_pause.status == 400 && strings.contains(role_pause.body, "fleet_roles_removed"), "per-role resume: %d %s", role_pause.status, role_pause.body)
}

// Task create/patch refuse review_roles by name (REQ-SCHED-8).
@(test)
test_task_create_refuses_review_roles :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	f := c.f
	path := fmt.tprintf("/api/v1/task-chains/%s/tasks", f.chain_id)
	resp := create_task_handler(&f.th, wire_cookie_request(f, "POST", path, `{"title":"t","assignee":"agt_wake","review_roles":["reviewer"]}`))
	testing.expectf(t, resp.status == 400 && strings.contains(resp.body, "review_roles_removed"), "create review_roles: %d %s", resp.status, resp.body)
}
