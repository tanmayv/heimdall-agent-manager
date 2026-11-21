package taskv2

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// REQ-CIS-2: every [taskv2] coordinator notice that survives the send-time
// re-check queues one wake of its coordinator. The queue collapses a burst and
// runs nothing until drained (the timer thread drains it once a second).

Coordinator_Wake_Log :: struct {
	owners:    [dynamic]string,
	instances: [dynamic]string,
}

coordinator_wake_capture :: proc(fx: ^Fixture) -> ^Coordinator_Wake_Log {
	log := new(Coordinator_Wake_Log, context.temp_allocator)
	log.owners = make([dynamic]string, context.temp_allocator)
	log.instances = make([dynamic]string, context.temp_allocator)
	fx.svc.wake_coordinator_ctx = log
	fx.svc.wake_coordinator = proc(ctx: rawptr, owner, instance_id: string) {
		l := (^Coordinator_Wake_Log)(ctx)
		append(&l.owners, strings.clone(owner, context.temp_allocator))
		append(&l.instances, strings.clone(instance_id, context.temp_allocator))
	}
	return log
}

coordinator_wake_notify :: proc(fx: ^Fixture, chain: domain.Task_Chain, trigger, line: string) {
	u, _, _ := begin_uow(&fx.svc)
	effect_notify_coordinator(&fx.svc, &u, chain.chain_id, chain.owner_user_id, trigger, line)
	_, _ = end_uow(&fx.svc, &u, true)
}

@(test)
test_task_notice_burst_queues_one_coordinator_wake :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "cis2_burst")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_cis2_burst")
	wakes := coordinator_wake_capture(fx)
	coordinator_wake_notify(fx, chain, "proposal_decided", "[taskv2] proposal_decided: one")
	coordinator_wake_notify(fx, chain, "summary_overflow", "[taskv2] summary_overflow: two")
	coordinator_wake_notify(fx, chain, "workflow_failed", "[taskv2] workflow_failed: three")
	// Nothing runs inside the flush: the restart waits for the drain.
	testing.expect_value(t, len(wakes.instances), 0)
	testing.expect_value(t, len(fx.svc.pending_coordinator_wakes), 1)
	drain_coordinator_wakes(&fx.svc)
	testing.expect_value(t, len(wakes.instances), 1)
	testing.expect_value(t, wakes.instances[0], "inst_coord")
	testing.expect_value(t, wakes.owners[0], string(chain.owner_user_id))
	testing.expect(t, fx.svc.pending_coordinator_wakes == nil)
	// A drained set starts over: the next notice queues the next wake.
	drain_coordinator_wakes(&fx.svc)
	testing.expect_value(t, len(wakes.instances), 1)
	coordinator_wake_notify(fx, chain, "proposal_decided", "[taskv2] proposal_decided: four")
	drain_coordinator_wakes(&fx.svc)
	testing.expect_value(t, len(wakes.instances), 2)
}

@(test)
test_task_notice_wake_queued_for_completed_chain :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "cis2_completed")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_cis2_completed")
	chain.status = .Completed
	_, _, _ = iface.taskchain_save_chain(&fx.repo, chain)
	wakes := coordinator_wake_capture(fx)
	coordinator_wake_notify(fx, chain, "proposal_decided", "[taskv2] proposal_decided: after completion")
	drain_coordinator_wakes(&fx.svc)
	testing.expect_value(t, len(wakes.instances), 1)
}

@(test)
test_dropped_task_notice_queues_no_wake :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "cis2_dropped")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_cis2_dropped")
	task := publish_task(t, fx, chain, "task_1")
	// A second open task keeps the chain open after the cancel below.
	_ = publish_task(t, fx, chain, "task_2")
	wakes := coordinator_wake_capture(fx)
	notices := notice_capture(fx)
	u, _, _ := begin_uow(&fx.svc)
	effect_notify_task(&fx.svc, &u, task, "ready_unclaimed", "[taskv2] ready_unclaimed: task task_1")
	// Cancelled in the same unit of work: the notice is stale, so is the wake.
	_, _, rok, _ := record_event(&fx.svc, &u, task, hub_actor(), EV_CANCELLED, `{"reason":"test"}`)
	testing.expect(t, rok, "cancel")
	_, _ = end_uow(&fx.svc, &u, true)
	drain_coordinator_wakes(&fx.svc)
	testing.expectf(t, len(notices.triggers) == 0, "notices sent: %v", notices.triggers[:])
	testing.expect_value(t, len(wakes.instances), 0)
}

@(test)
test_task_notice_without_wake_hook_queues_nothing :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "cis2_nohook")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_cis2_nohook")
	coordinator_wake_notify(fx, chain, "proposal_decided", "[taskv2] proposal_decided: unwired")
	testing.expect(t, fx.svc.pending_coordinator_wakes == nil)
}
