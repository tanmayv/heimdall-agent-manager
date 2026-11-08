package card

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import project "odin_test:hub/service/project"
import jsonx "odin_test:lib/jsonx"
import taskv2 "odin_test:hub/service/taskv2"

@(test)
test_start_agent_card_failure_preserves_block_and_retry_dispatches :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_start_agent")
	defer ph_close(&h)
	bridge_impl: sqlite.Bridge_Repo_SQLite
	bridges := sqlite.new_bridge_repository(&bridge_impl, &h.conn)
	repos := iface.Repositories{taskchains = h.tasks, agents = h.agents, bridges = bridges}
	uow_impl: sqlite.SQLite_Unit_Of_Work_Factory
	uow := sqlite.new_unit_of_work_factory(&uow_impl, &h.conn, &repos)
	h.engine.bridges = &bridges
	h.engine.uow_factory = &uow
	h.engine.attention = &h.svc.attention_notifier
	h.svc.uow_factory = &uow
	// Offline placement has its own card. Start agent is reserved for process
	// failure/explicit-stop consent, separate from placement outages.
	_, _, _ = iface.bridge_save_bridge(&bridges, domain.Bridge{bridge_id = "br_anr", owner_user_id = PH_OWNER, status = .Online})
	_, _ = iface.taskchain_upsert_fleet(&h.tasks, domain.Task_Chain_Fleet{task_chain_id = PH_CHAIN, agent_id = "agt_anr", bridge_id = "br_anr", capacity = 1, roles_json = "[\"worker\"]"})
	_, _, _ = iface.agent_save_instance(&h.agents, domain.Agent_Instance{agent_instance_id = "inst_anr", agent_id = "agt_anr", owner_user_id = PH_OWNER, chain_id = string(PH_CHAIN), bridge_id = "br_anr", provider = "claude", model = "claude-opus-5-5", runtime_status = "stopped", stopped_by = "user"})
	task := ph_task("task_anr", .In_Progress, "2026-10-01T02:00:00Z")
	task.brief_json = "{\"goal\":\"g\",\"review_roles\":[]}"
	task.state = .Backlog
	_, _, _ = iface.taskchain_save_task(&h.tasks, task)
	err := taskv2.task_created(&h.engine, task, taskv2.Actor{kind = taskv2.ACTOR_USER, id = string(PH_OWNER)})
	testing.expect_value(t, err.code, domain.Error_Code.None)
	cid := attention_task_card_id(task.task_id)
	c, exists := ph_card(t, &h, cid)
	if !testing.expect(t, exists, "unavailable agent raises a card") do return
	testing.expect(t, strings.contains(c.operations_json, "\"op\":\"agent.start\"") && strings.contains(c.operations_json, "Start agent"), "card offers Start agent")
	auth := contracts.Auth_Context{kind = .Session, user_id = string(PH_OWNER)}
	_, accepted, acc_err := accept_card(&h.svc, contracts.Auth_Context{kind = .Instance_Token, user_id = string(PH_OWNER), agent_instance_id = "inst_anr"}, cid)
	testing.expect(t, !accepted && acc_err.code == .Forbidden, "agent cannot execute user's Start action")
	_, accepted, acc_err = accept_card(&h.svc, auth, cid, Card_Decision{expected_block = "stale"})
	testing.expect(t, !accepted && acc_err.code == .Conflict, "stale browser block rejected")
	h.engine.bridge_command_sink = project.Bridge_Command_Sink{send_runtime_command = proc(ctx: rawptr, cmd: project.Runtime_Command) -> (bool, domain.Domain_Error) {
		return false, domain.domain_error(.Internal_Error, "bridge launch refused")
	}}
	_, accepted, acc_err = accept_card(&h.svc, auth, cid)
	testing.expect(t, !accepted && strings.contains(acc_err.message, "launch refused"), "post-commit launch error propagated")
	c, _ = ph_card(t, &h, cid)
	testing.expect(t, c.status == domain.CARD_STATUS_PENDING && strings.contains(c.details_json, "launch refused"), "new structured failure persists despite card accept error")
	_, _, _ = iface.agent_save(&h.agents, domain.Agent{agent_id = "agt_replacement", owner_user_id = PH_OWNER, name = "Replacement", slug = "replacement", template_id = domain.TEMPLATE_EMPTY_ID, state = .Active})
	_, _ = iface.taskchain_upsert_fleet(&h.tasks, domain.Task_Chain_Fleet{task_chain_id = PH_CHAIN, agent_id = "agt_replacement", bridge_id = "br_anr", capacity = 1, roles_json = `["worker"]`})
	_, _, _ = iface.agent_save_instance(&h.agents, domain.Agent_Instance{agent_instance_id = "inst_replacement", agent_id = "agt_replacement", owner_user_id = PH_OWNER, chain_id = string(PH_CHAIN), bridge_id = "br_anr", provider = "claude", model = "claude-opus-5-5", runtime_status = "stopped", stopped_by = "user"})
	_, accepted, acc_err = accept_card(&h.svc, auth, cid, Card_Decision{replacement_agent_id = "agt_replacement"})
	testing.expect(t, !accepted && acc_err.code == .Validation_Failed, "delegation requires browser observation")
	current, _, _ := iface.taskchain_get_task(&h.tasks, task.task_id)
	decision := Card_Decision{expected_block = attention_task_block_id(current), replacement_agent_id = "agt_replacement"}
	h.engine.bridge_command_sink = {}
	_, accepted, acc_err = accept_card(&h.svc, auth, cid, decision)
	testing.expect(t, accepted && acc_err.code == .None, "selected replacement delegates and starts through card service")
	fresh, _, _ := iface.taskchain_get_task(&h.tasks, task.task_id)
	testing.expect(t, fresh.state == .In_Progress && fresh.blocked_on_json == "", "retry dispatched task")
	testing.expect(t, strings.contains(fresh.brief_json, "agt_replacement"), "card changed worker assignment")
	lease, held, _ := iface.taskchain_get_lease_by_holder(&h.tasks, "inst_replacement")
	testing.expect(t, held && lease.task_id == task.task_id, "replacement owns normal lease")
	_, duplicate, duplicate_err := accept_card(&h.svc, auth, cid, decision)
	testing.expect(t, !duplicate && duplicate_err.code == .Conflict, "accepted/stale card cannot delegate again")
	c, _ = ph_card(t, &h, cid)
	testing.expect(t, c.status == domain.CARD_STATUS_RESOLVED || c.status == domain.CARD_STATUS_ACCEPTED, "success retires card")
}

@(test)
test_start_agent_card_operations_require_task_and_are_standalone :: proc(t: ^testing.T) {
	ok, _ := validate_card_operations("[{\"op\":\"agent.start\",\"args\":{\"task_id\":\"task_a\"}}]")
	testing.expect(t, ok, "valid start")
	ok, _ = validate_card_operations("[{\"op\":\"agent.start\",\"args\":{}}]")
	testing.expect(t, !ok, "task required")
	ok, _ = validate_card_operations("[{\"op\":\"agent.start\",\"args\":{\"task_id\":\"task_a\"}},{\"op\":\"memory.approve\",\"args\":{\"memory_id\":\"mem_a\"}}]")
	testing.expect(t, !ok, "start has its own transaction and cannot mix with other operations")
}

@(test)
test_start_agent_projection_resolves_names_and_deleted_fallbacks :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_start_names_18e60c46")
	defer ph_close(&h)
	bridge_impl: sqlite.Bridge_Repo_SQLite
	bridges := sqlite.new_bridge_repository(&bridge_impl, &h.conn)
	h.engine.bridges = &bridges
	_, _, _ = iface.agent_save(&h.agents, domain.Agent{agent_id = "agt_named", owner_user_id = PH_OWNER, name = "Smoke worker", slug = "smoke-worker", template_id = domain.TEMPLATE_EMPTY_ID, state = .Active})
	_, _, _ = iface.bridge_save_bridge(&bridges, domain.Bridge{bridge_id = "br_named", owner_user_id = PH_OWNER, label = "Mundus", status = .Online})
	task := ph_task("task_names", .In_Progress, "2026-10-01T02:00:00Z")
	task.state = .Backlog
	task.blocked_on_json = `{"kind":"agent_not_running","agent_id":"agt_named","bridge_id":"br_named","reason":"Agent agt_named on bridge br_named failed: instance_not_drained"}`
	c := build_task_card(&h.svc, task, .Blocked, "agent_not_running")
	testing.expect(t, !strings.contains(c.rationale, "agt_named") && !strings.contains(c.rationale, "br_named"), "primary explanation never embeds IDs")
	ctx, exists := jsonx.extract_raw_object(c.details_json, "start_agent", true, context.temp_allocator)
	testing.expect(t, exists, "structured failure context")
	testing.expect_value(t, jsonx.extract_string(ctx, "agent_name", "", true, context.temp_allocator), "Smoke worker")
	testing.expect_value(t, jsonx.extract_string(ctx, "bridge_name", "", true, context.temp_allocator), "Mundus")
	testing.expect(t, strings.contains(ctx, "instance_not_drained"), "legacy details remain diagnostic")
	observed := attention_task_block_id(task)
	task.brief_json = `{"assignee":"agt_changed"}`
	testing.expect(t, attention_task_block_id(task) != observed, "assignment edit invalidates browser observation without changing failure prose")
	observed = attention_task_block_id(task)
	task.attempt_no += 1
	testing.expect(t, attention_task_block_id(task) != observed, "attempt edit invalidates browser observation")
	task.blocked_on_json = `{"kind":"agent_not_running","agent_id":"agt_deleted","bridge_id":"br_deleted"}`
	c = build_task_card(&h.svc, task, .Blocked, "agent_not_running")
	testing.expect(t, strings.contains(c.details_json, "Unavailable or deleted agent") && strings.contains(c.details_json, "Unavailable or deleted Bridge"), "missing records have readable fallbacks")
}
