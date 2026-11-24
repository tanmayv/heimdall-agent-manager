package http

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import agent_service "odin_test:hub/service/agent"
import project_service "odin_test:hub/service/project"

// Use the existing request-arena fixture; ticket ownership is exercised through
// production cleanup and registry counts, including commit failure after reserve.
Chain_Start_Commit_Failure :: struct {
    factory: ^iface.Unit_Of_Work_Factory,
    registry: ^project_service.Bridge_Runtime_Registry,
    commits, rollbacks, reserved_at_commit: int,
}
Chain_Start_Test_UOW :: struct {
    inner: iface.Unit_Of_Work,
    failure: ^Chain_Start_Commit_Failure,
}
chain_start_failed_commit :: proc(ctx: rawptr) -> (bool, domain.Domain_Error) {
    h := (^Chain_Start_Test_UOW)(ctx)
    defer free(h)
    // create_chain opens a nested savepoint too. Fail only the outer COMMIT,
    // after the coordinator ticket has actually acquired its reservation.
    if h.inner.nested do return iface.unit_of_work_commit(&h.inner)
    h.failure.commits += 1
    h.failure.reserved_at_commit = h.failure.registry.active_instances
    iface.unit_of_work_rollback(&h.inner)
    return false, domain.domain_error(.Internal_Error, "injected commit failure")
}
chain_start_rollback :: proc(ctx: rawptr) {
    h := (^Chain_Start_Test_UOW)(ctx)
    defer free(h)
    if !h.inner.nested do h.failure.rollbacks += 1
    iface.unit_of_work_rollback(&h.inner)
}
chain_start_begin_failed_commit :: proc(ctx: rawptr) -> (iface.Unit_Of_Work, bool, domain.Domain_Error) {
    failure := (^Chain_Start_Commit_Failure)(ctx)
    inner, ok, err := iface.unit_of_work_begin(failure.factory)
    if !ok do return {}, false, err
    h := new(Chain_Start_Test_UOW)
    h.inner, h.failure = inner, failure
    return {ctx=h, repos=inner.repos, nested=inner.nested, commit=chain_start_failed_commit, rollback=chain_start_rollback}, true, {}
}
chain_start_failed_send :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
    _, _ = coordinator_wake_test_command(ctx, command)
    return false, domain.domain_error(.Bridge_Offline, "injected send failure")
}

chain_start_scenario :: proc(t: ^testing.T, c: ^Coordinator_Wake_Fixture, updated, rollback, failed_send: bool) {
    f := c.f
    repos := iface.Repositories{agents=f.ag_repo, bridges=f.br_repo, taskchains=f.tc_repo, content=c.content_repo}
    impl: sqlite.SQLite_Unit_Of_Work_Factory
    factory := sqlite.new_unit_of_work_factory(&impl, &f.conn, &repos)
    commit_failure := Chain_Start_Commit_Failure{factory=&factory, registry=&c.registry}
    failing_factory := iface.Unit_Of_Work_Factory{ctx=&commit_failure, begin=chain_start_begin_failed_commit}
    f.tc_svc.uow_factory = &factory
    if rollback do f.tc_svc.uow_factory = &failing_factory
    f.ag_svc.taskchains = &f.tc_repo
    if updated {
        bridge, found, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_pin)
        testing.expect(t, found)
        bridge.capabilities_json = `{"features":["start_agent_v1"]}`
        _, saved, save_err := iface.bridge_save_bridge(&f.br_repo, bridge)
        testing.expect(t, saved, save_err.message)
    }
    existing, _, _ := iface.agent_get_instance(&f.ag_repo, "inst_wake")
    before, _ := iface.taskchain_list_chains_by_owner(&f.tc_repo, f.owner)
    auth := contracts.Auth_Context{kind=.Session, user_id=string(f.owner)}
    chain, ticket, err := create_chain_with_prepared_coordinator(&f.th, auth, {title="Phase S coordinator"}, {agent_id="agt_wake", bridge_id=f.bridge_pin, provider="claude", model=existing.model})
    defer agent_service.start_ticket_destroy(&ticket)
    testing.expect_value(t, len(c.commands), 0)
    if rollback {
        testing.expect_value(t, err.code, domain.Error_Code.Internal_Error)
        testing.expect_value(t, commit_failure.commits, 1)
        testing.expect_value(t, commit_failure.rollbacks, 0)
        testing.expect_value(t, commit_failure.reserved_at_commit, 1)
        testing.expect_value(t, c.registry.active_instances, 0)
        after, _ := iface.taskchain_list_chains_by_owner(&f.tc_repo, f.owner)
        testing.expect_value(t, len(after), len(before))
        rows, _ := iface.agent_list_instances_by_bridge(&f.ag_repo, f.bridge_pin)
        for row in rows do testing.expect(t, row.agent_instance_id == "inst_wake" || row.agent_instance_id == f.instance_id)
        return
    }
    if !testing.expect_value(t, err.code, domain.Error_Code.None) do return
    testing.expect_value(t, ticket.instance.chain_id, string(chain.chain_id))
    testing.expect_value(t, ticket.instance.run_count, 1)
    testing.expect_value(t, ticket.instance.runtime_status, "launching")
    testing.expect_value(t, c.registry.active_instances, 1)
    // Legacy wire must be the exact complete launch object, with no envelope conversion.
    legacy := agent_service.start_launch_json(&f.ag_svc, ticket)
    if failed_send do f.ag_svc.bridge_command_sink.send_runtime_command = chain_start_failed_send
    testing.expect(t, sqlite.tx_mutex_try_lock(), "sending must happen after the UOW releases its lock")
    send_err := taskchain_send_prepared_coordinator(&f.th, &ticket)
    testing.expect_value(t, len(c.commands), 1)
    testing.expect(t, !ticket.reserved)
    if failed_send {
        testing.expect_value(t, send_err.code, domain.Error_Code.Bridge_Offline)
        stored, found, _ := iface.agent_get_instance(&f.ag_repo, ticket.instance.agent_instance_id)
        testing.expect(t, found)
        testing.expect_value(t, stored.runtime_status, "failed")
        testing.expect_value(t, stored.run_count, 1)
        testing.expect_value(t, c.registry.active_instances, 0)
    } else {
        testing.expect_value(t, send_err.code, domain.Error_Code.None)
        if updated {
            testing.expect(t, strings.contains(c.commands[0], `"type":"start_agent"`))
            testing.expect(t, strings.contains(c.commands[0], `"run_count":1`))
        } else {
            testing.expect_value(t, c.commands[0], legacy)
        }
    }
}
chain_start_updated :: proc(t: ^testing.T, c: ^Coordinator_Wake_Fixture) { chain_start_scenario(t,c,true,false,false) }
chain_start_legacy :: proc(t: ^testing.T, c: ^Coordinator_Wake_Fixture) { chain_start_scenario(t,c,false,false,false) }
chain_start_rollback_case :: proc(t: ^testing.T, c: ^Coordinator_Wake_Fixture) { chain_start_scenario(t,c,true,true,false) }
chain_start_send_failure :: proc(t: ^testing.T, c: ^Coordinator_Wake_Fixture) { chain_start_scenario(t,c,true,false,true) }

@(test)
test_chain_coordinator_start_agent :: proc(t: ^testing.T) { start_http_run(t,chain_start_updated) }
@(test)
test_chain_coordinator_legacy_launch :: proc(t: ^testing.T) { start_http_run(t,chain_start_legacy) }
@(test)
test_chain_coordinator_rollback_cancels_ticket :: proc(t: ^testing.T) { start_http_run(t,chain_start_rollback_case) }
@(test)
test_chain_coordinator_send_failure :: proc(t: ^testing.T) { start_http_run(t,chain_start_send_failure) }
