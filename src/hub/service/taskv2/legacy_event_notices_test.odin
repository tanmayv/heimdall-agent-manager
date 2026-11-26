package taskv2

import "core:testing"

@(test)
test_legacy_event_notice_catalog_switch :: proc(t: ^testing.T) {
	svc: Service
	migrated := []string {
		"review_requested_from_user",
		"blocked_on human",
		"requirements_changed",
		"merge_conflict",
		"work_batch_finished",
		"workflow_complete",
		"workflow_failed",
	}
	retained := []string {
		"agent_not_running",
		"ready_unclaimed",
		"budget_exhausted",
		"oscillation",
		"hold_stale",
		"review_stalled",
		"dependency_stalled",
		"summary_overflow",
		"proposal_decided",
		"gate_rejected",
		"workflow_budget",
		"workflow_trigger_failed",
		"coordinator_item_ready",
		"merge_failed",
	}
	for trigger in migrated do testing.expect(t, legacy_event_notice_enabled(&svc, trigger), "unset defaults on")
	svc.legacy_event_notices = false
	for trigger in migrated do testing.expect(t, !legacy_event_notice_enabled(&svc, trigger), trigger)
	for trigger in retained do testing.expect(t, legacy_event_notice_enabled(&svc, trigger), trigger)
	svc.legacy_event_notices = true
	for trigger in migrated do testing.expect(t, legacy_event_notice_enabled(&svc, trigger), trigger)
}

@(test)
test_legacy_requirements_notice_disabled_preserves_revision :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "legacy_requirements_disabled")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_requirements")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"]}`)
	confirm_holder(fx, "inst_w1")
	probe: Requirements_Notice_Probe
	fx.svc.bridge_command_sink = {
		ctx                  = &probe,
		send_runtime_command = requirements_test_send,
	}
	fx.svc.legacy_event_notices = false
	requirements_test_change(t, fx, "task_1", `{"goal":"g2","acceptance":["a"]}`, 1)
	testing.expect_value(t, probe.attempts, 0)
	state, _ := requirements_read(&fx.repo, get_task(fx, "task_1"))
	testing.expect_value(t, state.revision, i64(2))
	testing.expect_value(t, count_events(fx, "task_1", EV_REQUIREMENTS_NOTICE_ATTEMPTED), 0)
	for timer in fx.svc.timers.heap {
		testing.expect(t, timer.kind != .Requirements_Notice || timer.key != "task_1", "suppressed notice must not arm retries")
	}
	fixture_advance(fx, REQUIREMENTS_RETRY_SECONDS + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, probe.attempts, 0)
	testing.expect_value(t, count_events(fx, "task_1", EV_REQUIREMENTS_NOTICE_ATTEMPTED), 0)
}

@(test)
test_legacy_coordinator_notifications_switch :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "legacy_coord")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_legacy")
	triggers := []string {
		"review_requested_from_user",
		"blocked_on human",
		"merge_conflict",
		"work_batch_finished",
		"workflow_complete",
		"workflow_failed",
		"ready_unclaimed",
		"merge_failed",
		"gate_rejected",
	}
	for enabled in ([]bool{true, false}) {
		if !enabled do fx.svc.legacy_event_notices = false
		u: Uow
		for trigger in triggers do effect_notify_coordinator(&fx.svc, &u, chain.chain_id, chain.owner_user_id, trigger, "[taskv2] test notice")
		testing.expect_value(t, len(u.effects.notifications), 9 if enabled else 3)
		if !enabled {
			for n in u.effects.notifications do testing.expect(t, n.trigger == "ready_unclaimed" || n.trigger == "merge_failed" || n.trigger == "gate_rejected")
		}
		destroy_effects(&u.effects)
	}
}
