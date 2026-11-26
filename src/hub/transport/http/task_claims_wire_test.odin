package http

import "core:testing"
import "core:fmt"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import project_service "odin_test:hub/service/project"
import taskv2 "odin_test:hub/service/taskv2"
import jsonx "odin_test:lib/jsonx"

@(test)
test_explicit_claim_wire_rejects_missing_task :: proc(t: ^testing.T) {
    f := wire_setup(t, "claim_missing")
    defer wire_teardown(f)
    engine := taskv2.new_service(&f.tc_repo, &f.ag_repo, &f.br_repo, &f.clock, &f.ids)
    f.ah.task_engine = &engine
    response := agent_action_lease_claim_handler(&f.ah, wire_agent_request(f, "lease/claim", `{"params":{"task_id":"missing"}}`))
    testing.expect(t, response.status != 200, "claim cannot invent a task")
}

claim_wire_seed_task :: proc(f: ^wire_fixture, id, assignee: string) -> domain.Task {
    task := domain.Task{task_id = domain.Task_ID(id), chain_id = f.chain_id, owner_user_id = f.owner,
        title = "Claim authority", kind = .Task, publish_state = .Published, state = .Ready,
        brief_json = fmt.tprintf(`{{"goal":"g","acceptance":["a"],"assignee":"%s"}}`, assignee)}
    _, _, _ = iface.taskchain_save_task(&f.tc_repo, task)
    _, _, _ = iface.taskchain_append_event(&f.tc_repo, domain.Task_Event{task_id = task.task_id,
        chain_id = task.chain_id, owner_user_id = f.owner, kind = taskv2.EV_MIGRATED,
        payload_json = `{"state":"ready","published":true}`})
    return task
}

// REQ-AUTHZ-2/3: any agent instance of the task's owner may cancel it over the
// wire, with no chain membership at all; a different owner still sees 404.
@(test)
test_task_cancel_http_non_member_same_owner_cancels_cross_owner_hidden :: proc(t: ^testing.T) {
    f := wire_setup(t, "control_denied")
    defer wire_teardown(f)
    engine := taskv2.new_service(&f.tc_repo, &f.ag_repo, &f.br_repo, &f.clock, &f.ids)
    f.th.task_engine = &engine
    task := claim_wire_seed_task(f, "task_cancel_denied", "agt_wire_tb2")
    // Strip the fixture's coordinator seat: the caller is a same-owner non-member.
    _, _ = iface.taskchain_remove_member(&f.tc_repo, f.chain_id, f.instance_id, f.owner)
    chain, _, _ := iface.taskchain_get_chain(&f.tc_repo, f.chain_id)
    chain.publish_state = .Published
    _, _, _ = iface.taskchain_save_chain(&f.tc_repo, chain)
    path := fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/cancel", f.chain_id, task.task_id)
    body := `{"reason":"not needed","request_id":"nonmember","expected_generation":1}`
    request := wire_cookie_request(f, "POST", path, body)
    other_headers := http_test_login(t, &f.auth_svc, "claims_foreign_owner")
    request.headers = other_headers
    foreign_result := task_cancel_handler(&f.th, request)
    testing.expectf(t, foreign_result.status == 404, "cross-owner task hidden: %s", foreign_result.body)
    fresh, _, _ := iface.taskchain_get_task(&f.tc_repo, task.task_id)
    testing.expect_value(t, fresh.state, domain.Task_State.Ready)
    request.headers = f.agent_headers[:]
    allowed := task_cancel_handler(&f.th, request)
    testing.expectf(t, allowed.status == 200, "same-owner non-member cancels: %s", allowed.body)
    fresh, _, _ = iface.taskchain_get_task(&f.tc_repo, task.task_id)
    testing.expect_value(t, fresh.state, domain.Task_State.Cancelled)
}

@(test)
test_explicit_claim_http_coordinator_actor_and_beneficiary_separate :: proc(t: ^testing.T) {
    f := wire_setup(t, "claim_target")
    defer wire_teardown(f)
    engine := taskv2.new_service(&f.tc_repo, &f.ag_repo, &f.br_repo, &f.clock, &f.ids)
    repos := iface.Repositories{taskchains=f.tc_repo,agents=f.ag_repo,bridges=f.br_repo}
    uow_impl: sqlite.SQLite_Unit_Of_Work_Factory
    uow:=sqlite.new_unit_of_work_factory(&uow_impl,&f.conn,&repos)
    engine.uow_factory=&uow
    // Wake grants now use the shared start-ticket service, even for a live target.
    engine.agent_service = &f.ag_svc
    engine.bridge_command_sink = project_service.Bridge_Command_Sink{send_runtime_command = proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) { return true, {} }}
    f.ah.task_engine = &engine
    chain, _, _ := iface.taskchain_get_chain(&f.tc_repo, f.chain_id)
    chain.publish_state = .Published
    _, _, _ = iface.taskchain_save_chain(&f.tc_repo, chain)
    bridge,_,_:=iface.bridge_get_bridge(&f.br_repo,f.bridge_alt)
    bridge.status=.Online
    _,_,_=iface.bridge_save_bridge(&f.br_repo,bridge)
    task := claim_wire_seed_task(f, "task_claim_target", "agt_target")
    self := agent_action_lease_claim_handler(&f.ah, wire_agent_request(f, "lease/claim",
        `{"params":{"task_id":"task_claim_target"}}`))
    testing.expectf(t, self.status == 403, "coordinator self must match assignee: %s", self.body)
    _, _, _ = iface.agent_save_instance(&f.ag_repo, domain.Agent_Instance{
        agent_instance_id="inst_claim_target", owner_user_id=f.owner, agent_id="agt_target",
        bridge_id=f.bridge_alt, runtime_status="running", startup_status="ready"})
    assigned := agent_action_lease_claim_handler(&f.ah, wire_agent_request(f, "lease/claim",
        `{"params":{"task_id":"task_claim_target","instance_id":"inst_claim_target","reason":"assign remotely","request_id":"target-claim"}}`))
    if !testing.expectf(t, assigned.status == 200, "target claim: %s", assigned.body) do return
    data, _ := jsonx.extract_raw_object(assigned.body, "data", true, context.temp_allocator)
    testing.expect_value(t, jsonx.extract_string(data,"target_instance_id","",true,context.temp_allocator), "inst_claim_target")
    testing.expect_value(t, jsonx.extract_string(data,"agent_id","",true,context.temp_allocator), "agt_target")
    testing.expect(t, strings.contains(data, `"pack":null`), "coordinator never receives target execution context")
    lease, held, _ := iface.taskchain_get_lease_by_holder(&f.tc_repo, "inst_claim_target")
    testing.expect(t, held && lease.task_id == task.task_id, "beneficiary receives ownership")
    _, caller_held, _ := iface.taskchain_get_lease_by_holder(&f.tc_repo, f.instance_id)
    testing.expect(t, !caller_held, "actor is not silently assigned target work")
    events, _ := iface.taskchain_list_events_by_task(&f.tc_repo, task.task_id, f.owner)
    actor_recorded := false
    for event in events do if event.kind == taskv2.EV_LEASE_GRANTED {
        actor_recorded = event.actor_id == f.instance_id
    }
    testing.expect(t, actor_recorded, "audit preserves authenticated coordinator actor")
}


@(test)
test_task_cancel_http_without_generation_is_idempotent :: proc(t: ^testing.T) {
    f := wire_setup(t, "cancel_retry")
    defer wire_teardown(f)
    engine := taskv2.new_service(&f.tc_repo, &f.ag_repo, &f.br_repo, &f.clock, &f.ids)
    f.th.task_engine = &engine
    task := claim_wire_seed_task(f, "task_cancel_retry", "agt_wire_tb2")
    path := fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/cancel", f.chain_id, task.task_id)
    body := `{"reason":"user cancelled","request_id":"cancel-retry"}`
    first := task_cancel_handler(&f.th, wire_cookie_request(f, "POST", path, body))
    if !testing.expectf(t, first.status == 200, "cancel without generation: %s", first.body) do return
    testing.expect(t, strings.contains(first.body, `"changed":true`))
    fresh, _, _ := iface.taskchain_get_task(&f.tc_repo, task.task_id)
    testing.expect_value(t, fresh.state, domain.Task_State.Cancelled)
    events_before, _ := iface.taskchain_list_events_by_task(&f.tc_repo, task.task_id, f.owner)
    again := task_cancel_handler(&f.th, wire_cookie_request(f, "POST", path, body))
    testing.expectf(t, again.status == 200, "cancel retry: %s", again.body)
    events_after, _ := iface.taskchain_list_events_by_task(&f.tc_repo, task.task_id, f.owner)
    testing.expect_value(t, len(events_after), len(events_before))
}

// REQ-AUTHZ-1: POST /api/v1/agent-actions/chain/set-status works for a same-owner
// agent instance that is neither a member nor the coordinator of the chain.
@(test)
test_chain_set_status_wire_non_member_same_owner :: proc(t: ^testing.T) {
    f := wire_setup(t, "set_status_nonmember")
    defer wire_teardown(f)
    _, _ = iface.taskchain_remove_member(&f.tc_repo, f.chain_id, f.instance_id, f.owner)
    chain, _, _ := iface.taskchain_get_chain(&f.tc_repo, f.chain_id)
    chain.publish_state = .Published
    _, _, _ = iface.taskchain_save_chain(&f.tc_repo, chain)
    body := fmt.tprintf(`{{"params":{{"chain_id":"%s","status":"archived"}}}}`, f.chain_id)
    archived := agent_action_chain_set_status_handler(&f.ah, wire_agent_request(f, "chain/set-status", body))
    testing.expectf(t, archived.status == 200, "non-member archives: %s", archived.body)
    fresh, _, _ := iface.taskchain_get_chain(&f.tc_repo, f.chain_id)
    testing.expect_value(t, fresh.status, domain.Task_Chain_Status.Archived)
    body = fmt.tprintf(`{{"params":{{"chain_id":"%s","status":"cancelled"}}}}`, f.chain_id)
    _ = agent_action_chain_set_status_handler(&f.ah, wire_agent_request(f, "chain/set-status", fmt.tprintf(`{{"params":{{"chain_id":"%s","status":"active"}}}}`, f.chain_id)))
    cancelled := agent_action_chain_set_status_handler(&f.ah, wire_agent_request(f, "chain/set-status", body))
    testing.expectf(t, cancelled.status == 200, "non-member cancels: %s", cancelled.body)
    fresh, _, _ = iface.taskchain_get_chain(&f.tc_repo, f.chain_id)
    testing.expect_value(t, fresh.status, domain.Task_Chain_Status.Cancelled)
}

// The web UI used to POST `{}` to the cancel route, which the taskv2 handler
// refuses: reason and request_id are part of the idempotent cancel contract.
// The refusal must leave the task untouched and name the missing fields.
@(test)
test_task_cancel_http_empty_body_is_refused_untouched :: proc(t: ^testing.T) {
    f := wire_setup(t, "cancel_empty")
    defer wire_teardown(f)
    engine := taskv2.new_service(&f.tc_repo, &f.ag_repo, &f.br_repo, &f.clock, &f.ids)
    f.th.task_engine = &engine
    task := claim_wire_seed_task(f, "task_cancel_empty", "agt_wire_tb2")
    path := fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/cancel", f.chain_id, task.task_id)
    refused := task_cancel_handler(&f.th, wire_cookie_request(f, "POST", path, `{}`))
    testing.expectf(t, refused.status == 400, "empty cancel body is refused: %d %s", refused.status, refused.body)
    testing.expectf(t, strings.contains(refused.body, "reason and request_id are required"), "refusal names the fields: %s", refused.body)
    fresh, _, _ := iface.taskchain_get_task(&f.tc_repo, task.task_id)
    testing.expect_value(t, fresh.state, domain.Task_State.Ready)
}

// `ham-ctl task cancel <id>` relays {reason, request_id} with the agent's
// credentials (ctl_v2_task_cancel_body). It cancels end to end, keeps history,
// and the reply tells the caller what happened.
@(test)
test_task_cancel_http_cli_body_cancels_with_history :: proc(t: ^testing.T) {
    f := wire_setup(t, "cancel_cli")
    defer wire_teardown(f)
    engine := taskv2.new_service(&f.tc_repo, &f.ag_repo, &f.br_repo, &f.clock, &f.ids)
    f.th.task_engine = &engine
    task := claim_wire_seed_task(f, "task_cancel_cli", "agt_wire_tb2")
    path := fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/cancel", f.chain_id, task.task_id)
    request := wire_cookie_request(f, "POST", path, `{"reason":"Task cancellation requested via CLI","request_id":"req_0123456789abcdef","expected_generation":0}`)
    request.headers = f.agent_headers[:]
    response := task_cancel_handler(&f.th, request)
    if !testing.expectf(t, response.status == 200, "CLI cancel: %s", response.body) do return
    data, _ := jsonx.extract_raw_object(response.body, "data", true, context.temp_allocator)
    testing.expectf(t, strings.contains(data, `"changed":true`), "reply says it changed: %s", data)
    testing.expectf(t, strings.contains(data, `"state":"cancelled"`), "reply carries the cancelled task: %s", data)
    fresh, _, _ := iface.taskchain_get_task(&f.tc_repo, task.task_id)
    testing.expect_value(t, fresh.state, domain.Task_State.Cancelled)
    events, _ := iface.taskchain_list_events_by_task(&f.tc_repo, task.task_id, f.owner)
    migrated, cancelled, requested := false, false, false
    for event in events {
        switch event.kind {
        case taskv2.EV_MIGRATED: migrated = true
        case taskv2.EV_CANCELLED: cancelled = strings.contains(event.payload_json, "Task cancellation requested via CLI")
        case taskv2.EV_TASK_CANCEL_REQUESTED: requested = strings.contains(event.payload_json, "req_0123456789abcdef")
        }
    }
    testing.expect(t, migrated, "earlier history is kept")
    testing.expect(t, cancelled, "cancel event records the reason")
    testing.expect(t, requested, "audit records the request id")
}
