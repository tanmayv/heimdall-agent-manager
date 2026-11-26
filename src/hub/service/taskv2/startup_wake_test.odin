package taskv2

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import agent "odin_test:hub/service/agent"

@(test)
startup_wake_grant_generation_is_transactional_and_retries_reuse_it :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "startup_wake")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_startup_wake")
	seed_fleet(fx, chain, "agt_w", capacity = 1)
	// A stopped (warm) instance: the wake grant launches a new child (T8: a
	// live child would keep its generation and be nudged instead).
	previous := seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "stopped")
	previous.run_count = 7
	previous.startup_status = "ready"
	_, _, _ = iface.agent_save_instance(&fx.agents, previous)
	_ = publish_task(t, fx, chain, "task_startup_wake")
	lease, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "actual matcher grants wake lease") do return
	current, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	testing.expect_value(t, current.run_count, 8)
	testing.expect_value(t, current.runtime_transport, "pty")
	testing.expect_value(t, current.launch_epoch, "")
	testing.expect_value(t, current.startup_status, "starting")
	testing.expect(t, lease.confirmed_at == "", "replacement awaits its own ready hook")
	if !testing.expect(t, len(log.cmds) > 0) do return
	testing.expect(t, strings.contains(log.cmds[len(log.cmds)-1].body_json, `"run_count":8`), "wake carries committed generation")
	// The old callback may arrive after the new grant, even if its save preceded it.
	on_start_success(&fx.svc, previous)
	lease, _ = lease_of(fx, "inst_w1")
	testing.expect(t, lease.confirmed_at == "", "delayed old hook cannot confirm replacement")
	_, stored, err := iface.agent_save_instance(&fx.agents, previous)
	testing.expect(t, !stored && err.code == .Conflict, "stale save cannot roll generation backward")
	// Reconnect, hub boot and unconfirmed timer delivery all reuse effect_wake_lease.
	wake_log_reset(log)
	on_bridge_hello(&fx.svc, "br_1", nil)
	boot(&fx.svc)
	current, _, _ = iface.agent_get_instance(&fx.agents, "inst_w1")
	testing.expect_value(t, current.run_count, 8)
	for cmd in log.cmds do testing.expect(t, strings.contains(cmd.body_json, `"run_count":8`), "delivery retry preserves generation")
	testing.expect(t, len(log.cmds) >= 2, "reconnect and boot re-delivered pending wake")
	on_start_success(&fx.svc, current)
	lease, _ = lease_of(fx, "inst_w1")
	testing.expect(t, lease.confirmed_at != "", "current child confirms pending lease")
	// Confirmed reconnect is only a nudge, never a replacement.
	wake_log_reset(log)
	on_bridge_hello(&fx.svc, "br_1", []string{"inst_w1"})
	current, _, _ = iface.agent_get_instance(&fx.agents, "inst_w1")
	testing.expect_value(t, current.run_count, 8)
	testing.expect(t, !wake_log_has_run(log, "inst_w1"), "live notification has no run effect")
	// SCHED-1a (REQ-SCHED-25): the worker's next task gets a fresh process even
	// while the completed task's child is still running: exactly one more
	// generation, delivered as a launch, never a nudge.
	current.runtime_status = "running"
	_, _, _ = iface.agent_save_instance(&fx.agents, current)
	submit_via_release(t, fx, lease)
	wake_log_reset(log)
	_ = publish_task(t, fx, chain, "task_startup_wake_next")
	current, _, _ = iface.agent_get_instance(&fx.agents, "inst_w1")
	testing.expect_value(t, current.run_count, 9)
	if !testing.expect(t, len(log.cmds) > 0, "next grant is delivered") do return
	body := log.cmds[len(log.cmds)-1].body_json
	testing.expect(t, strings.contains(body, `"run_count":9`) && !strings.contains(body, `"deliver"`), "next task relaunches on one more generation")
	// A stopped child is likewise launched again with exactly one more generation.
	next, _ := lease_of(fx, "inst_w1")
	current.runtime_status = "stopped"
	_, _, _ = iface.agent_save_instance(&fx.agents, current)
	submit_via_release(t, fx, next)
	wake_log_reset(log)
	_ = publish_task(t, fx, chain, "task_startup_wake_third")
	current, _, _ = iface.agent_get_instance(&fx.agents, "inst_w1")
	testing.expect_value(t, current.run_count, 10)
	if !testing.expect(t, len(log.cmds) > 0, "third grant is delivered") do return
	testing.expect(t, !strings.contains(log.cmds[len(log.cmds)-1].body_json, `"deliver"`), "a launch is not a nudge")
}

@(test)
startup_wake_refuses_frozen_acp_after_capability_withdrawal :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "transport_wake")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_transport_wake")
	seed_fleet(fx, chain, "agt_w", capacity=1)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "stopped")
	_ = publish_task(t, fx, chain, "task_transport_wake")
	inst, found, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	if !testing.expect(t, found) do return
	// Simulate a pending ACP generation whose capable Bridge later reconnects
	// with an older binary. The new hello no longer advertises acp_runtime_v1.
	inst.run_count += 1
	inst.runtime_transport = "acp"
	inst.launch_epoch = "acp_epoch"
	_, saved, err := iface.agent_save_instance(&fx.agents, inst)
	if !testing.expect(t, saved, err.message) do return
	provider_impl: sqlite.Provider_Repo_SQLite
	providers := sqlite.new_provider_repository(&provider_impl, &fx.conn)
	agents := agent.new_agent_service(&fx.agents, &fx.bridges, &fx.clock, &fx.ids)
	agents.providers = &providers
	fx.svc.agent_service = &agents
	wake_log_reset(log)
	on_bridge_hello(&fx.svc, "br_1", nil)
	testing.expect(t, !wake_log_has_run(log, "inst_w1"), "an unsupported Bridge must never receive ACP even on retry")
	lease, held := lease_of(fx, "inst_w1")
	testing.expect(t, !held || lease.phase == domain.LEASE_PHASE_WAITING, "failed dispatch parks its pending claim")
}

@(test)
startup_inline_grant_and_rolled_back_wake_preserve_generation :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "startup_inline")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_startup_inline")
	inst := seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "running")
	inst.run_count = 5
	_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	task := publish_task(t, fx, chain, "task_startup_inline")
	deliveries := [2]bool{false, true}
	for is_inline in deliveries {
		u, begun, err := begin_uow(&fx.svc)
		if !testing.expect(t, begun, fmt.tprintf("begin: %s", err.message)) do return
		lease, granted, grant_err := grant_in_uow(&fx.svc, &u, Grant_Request{
			chain = chain, task = task, instance = inst, kind = domain.LEASE_KIND_WORK,
			delivery = domain.LEASE_DELIVERY_INLINE if is_inline else domain.LEASE_DELIVERY_WAKE,
			placement = Placement{bridge_id = "br_1"}, actor = hub_actor(),
		})
		testing.expect(t, granted, fmt.tprintf("grant: %s", grant_err.message))
		_, _ = end_uow(&fx.svc, &u, is_inline && granted)
		current, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
		testing.expect_value(t, current.run_count, 5)
		if is_inline do testing.expect(t, lease.confirmed_at != "", "inline grant is already confirmed")
	}
	testing.expect(t, !wake_log_has_run(log, "inst_w1"), "rollback and inline grant emit no launch")
}

@(test)
startup_pending_wake_is_stopped_when_task_is_cancelled :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "startup_cancel")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_startup_cancel")
	seed_fleet(fx, chain, "agt_w", capacity = 1)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "stopped")
	task := publish_task(t, fx, chain, "task_startup_cancel")
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	testing.expect(t, instance_is_pending(inst), "wake grant is pending readiness")
	wake_log_reset(log)
	err := cancel_task(&fx.svc, task, Actor{kind = ACTOR_USER, id = "u1"}, "cancel before ready")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect(t, wake_log_has_stop(log, "inst_w1"), "pending replacement is included in stop effect")
	_, held := lease_of(fx, "inst_w1")
	testing.expect(t, !held, "cancelled wake lease is reclaimed")
}
