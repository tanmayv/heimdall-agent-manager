package http

import "core:testing"
import "core:fmt"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
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
        brief_json = fmt.tprintf(`{{"goal":"g","acceptance":["a"],"assignee":"%s","review_roles":[]}}`, assignee)}
    _, _, _ = iface.taskchain_save_task(&f.tc_repo, task)
    _, _, _ = iface.taskchain_append_event(&f.tc_repo, domain.Task_Event{task_id = task.task_id,
        chain_id = task.chain_id, owner_user_id = f.owner, kind = taskv2.EV_MIGRATED,
        payload_json = `{"state":"ready","published":true}`})
    return task
}

@(test)
test_task_cancel_http_noncoordinator_and_cross_owner_cannot_cancel :: proc(t: ^testing.T) {
    f := wire_setup(t, "control_denied")
    defer wire_teardown(f)
    engine := taskv2.new_service(&f.tc_repo, &f.ag_repo, &f.br_repo, &f.clock, &f.ids)
    f.th.task_engine = &engine
    task := claim_wire_seed_task(f, "task_cancel_denied", "agt_wire_tb2")
    _, _, _ = iface.taskchain_save_member(&f.tc_repo, domain.Task_Chain_Member{chain_id=f.chain_id,
        owner_user_id=f.owner,agent_instance_id=f.instance_id,agent_id="agt_wire_tb2",role="worker"})
    path := fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/cancel", f.chain_id, task.task_id)
    body := `{"reason":"unauthorized","request_id":"denied","expected_generation":1}`
    request := wire_cookie_request(f, "POST", path, body)
    request.headers = f.agent_headers[:]
    denied := task_cancel_handler(&f.th, request)
    testing.expectf(t, denied.status == 403, "worker denial: %s", denied.body)
    fresh, _, _ := iface.taskchain_get_task(&f.tc_repo, task.task_id)
    testing.expect_value(t, fresh.state, domain.Task_State.Ready)
    other_headers := http_test_login(t, &f.auth_svc, "claims_foreign_owner")
    request.headers = other_headers
    foreign_result := task_cancel_handler(&f.th, request)
    testing.expectf(t, foreign_result.status == 404, "cross-owner task hidden: %s", foreign_result.body)
    fresh, _, _ = iface.taskchain_get_task(&f.tc_repo, task.task_id)
    testing.expect_value(t, fresh.state, domain.Task_State.Ready)
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
