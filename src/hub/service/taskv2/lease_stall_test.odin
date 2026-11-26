package taskv2

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import project "odin_test:hub/service/project"
import jsonx "odin_test:lib/jsonx"

// Lease stall detection (lease_stall.odin): a confirmed, silent work lease is
// nudged once, then reported to the coordinator; activity resets the window;
// the timers rebuild from durable rows after a hub restart; the lease is never
// expired, blocked or stopped.

@(private = "file")
stall_record_runtime :: proc(ctx: rawptr, command: project.Runtime_Command) -> (bool, domain.Domain_Error) {
	wake_log_observe(ctx, {bridge_id = command.bridge_id, body_json = command.body_json})
	return true, {}
}

// stall_fixture: inst_w1 holds a confirmed work lease on task_1; every
// runtime command (terminal nudges) and coordinator notice is captured.
@(private = "file")
stall_fixture :: proc(t: ^testing.T, tag: string, defaults_json := "") -> (fx: ^Fixture, log: ^Wake_Log, notices: ^Notice_Log, lease: domain.Task_Lease, ok: bool) {
	fx, log, ok = lease_fixture(t, tag)
	if !ok do return
	fx.svc.bridge_command_sink = {ctx = log, send_runtime_command = stall_record_runtime}
	chain := seed_live_chain(t, fx, fmt.tprintf("chain_%s", tag))
	if defaults_json != "" {
		chain.defaults_json = defaults_json
		_, _, _ = iface.taskchain_save_chain(&fx.repo, chain)
	}
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	notices = notice_capture(fx)
	_ = publish_task(t, fx, chain, "task_1")
	granted, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "inst_w1 holds the work lease") { ok = false; return }
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	on_start_success(&fx.svc, inst)
	lease, held = lease_of(fx, "inst_w1")
	if !testing.expect(t, held && lease.lease_id == granted.lease_id && lease.confirmed_at != "", "lease confirmed") { ok = false; return }
	wake_log_reset(log)
	return
}

@(private = "file")
stall_nudges :: proc(log: ^Wake_Log, inst: string) -> int {
	n := 0
	for c in log.cmds {
		if jsonx.extract_string(c.body_json, "origin", "", true, context.temp_allocator) != "taskv2_nudge" do continue
		if jsonx.extract_string(c.body_json, "agent_instance_id", "", true, context.temp_allocator) != inst do continue
		if strings.contains(c.body_json, "lease_stall") do n += 1
	}
	return n
}

@(private = "file")
stall_tick :: proc(fx: ^Fixture, seconds: i64) {
	fixture_advance(fx, seconds)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
}

@(private = "file")
stall_expect_lease_kept :: proc(t: ^testing.T, fx: ^Fixture, log: ^Wake_Log, lease_id: string) {
	l, held := lease_of(fx, "inst_w1")
	testing.expect(t, held && l.lease_id == lease_id && l.phase == domain.LEASE_PHASE_ACTIVE, "the stalled lease is kept, active")
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Progress)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_EXPIRED), 0)
	testing.expect_value(t, count_events(fx, "task_1", EV_BLOCKED), 0)
	testing.expect(t, !wake_log_has_stop(log, "inst_w1"), "the holder is never stopped")
}

@(test)
test_lease_stall_nudges_holder_then_notifies_coordinator :: proc(t: ^testing.T) {
	fx, log, notices, lease, ok := stall_fixture(t, "stall_flow")
	defer lease_fixture_close(fx, log)
	if !ok do return
	confirmed_at := lease.confirmed_at
	// Window 1: nothing until the full window has passed.
	stall_tick(fx, LEASE_STALL_SECONDS - 2)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_STALL_NUDGED), 0)
	testing.expect_value(t, stall_nudges(log, "inst_w1"), 0)
	stall_tick(fx, 3)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_STALL_NUDGED), 1)
	testing.expect_value(t, stall_nudges(log, "inst_w1"), 1)
	testing.expect_value(t, notice_count(notices, "lease_stalled"), 0)
	nudge := last_event_payload(fx, "task_1", EV_LEASE_STALL_NUDGED)
	testing.expect_value(t, jsonx.extract_string(nudge, "last_activity_at", "", true, context.temp_allocator), confirmed_at)
	// Window 2 (after the nudge): the coordinator is told, once.
	stall_tick(fx, LEASE_STALL_SECONDS - 2)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_STALLED), 0)
	stall_tick(fx, 3)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_STALLED), 1)
	testing.expect_value(t, notice_count(notices, "lease_stalled", "task_1"), 1)
	if len(notices.lines) > 0 {
		line := notices.lines[len(notices.lines) - 1]
		testing.expect(t, strings.contains(line, "inst_w1") && strings.contains(line, confirmed_at), line)
	}
	for r, i in notices.recipients do if notices.triggers[i] == "lease_stalled" do testing.expect_value(t, r, "inst_coord")
	stalled := last_event_payload(fx, "task_1", EV_LEASE_STALLED)
	testing.expect_value(t, jsonx.extract_string(stalled, "holder_instance_id", "", true, context.temp_allocator), "inst_w1")
	testing.expect_value(t, jsonx.extract_string(stalled, "lease_id", "", true, context.temp_allocator), lease.lease_id)
	// Typed catalog event for the coordinator's event inbox.
	testing.expect_value(t, catalog_count(fx, "task.lease_stalled"), 1)
	env := scalar_text(fx, "SELECT envelope_json FROM event_outbox WHERE json_extract(envelope_json,'$.type')='task.lease_stalled' LIMIT 1;")
	data, _ := jsonx.extract_raw_object(env, "data", true, context.temp_allocator)
	testing.expect_value(t, jsonx.extract_string(data, "holder_instance_id", "", true, context.temp_allocator), "inst_w1")
	testing.expect_value(t, jsonx.extract_string(data, "last_activity_at", "", true, context.temp_allocator), confirmed_at)
	// Silence continues: no repeats, and the lease is never expired or stopped.
	for _ in 0..<5 do stall_tick(fx, LEASE_STALL_SECONDS + 1)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_STALL_NUDGED), 1)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_STALLED), 1)
	testing.expect_value(t, notice_count(notices, "lease_stalled"), 1)
	testing.expect_value(t, stall_nudges(log, "inst_w1"), 1)
	stall_expect_lease_kept(t, fx, log, lease.lease_id)
}

@(test)
test_lease_stall_activity_resets_window :: proc(t: ^testing.T) {
	fx, log, notices, lease, ok := stall_fixture(t, "stall_reset")
	defer lease_fixture_close(fx, log)
	if !ok do return
	holder := Actor{kind = ACTOR_AGENT, id = "inst_w1"}
	// A plain heartbeat (no note) just before the window ends resets it.
	stall_tick(fx, LEASE_STALL_SECONDS - 60)
	u, uok, _ := begin_uow(&fx.svc)
	if !testing.expect(t, uok, "begin uow") do return
	_, hok, _ := heartbeat_in_uow(&fx.svc, &u, lease, holder, "")
	_, _ = end_uow(&fx.svc, &u, hok)
	testing.expect(t, hok, "heartbeat")
	stall_tick(fx, 120)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_STALL_NUDGED), 0)
	stall_tick(fx, LEASE_STALL_SECONDS)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_STALL_NUDGED), 1)
	// The holder answers the nudge with a task comment: no coordinator notice,
	// and a fresh silence period gets its own nudge later.
	stall_tick(fx, 60)
	testing.expect_value(t, task_comment(&fx.svc, get_task(fx, "task_1"), holder, "cmt_1").code, domain.Error_Code.None)
	stall_tick(fx, LEASE_STALL_SECONDS - 2)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_STALLED), 0)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_STALL_NUDGED), 1)
	stall_tick(fx, 3)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_STALLED), 0)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_STALL_NUDGED), 2)
	testing.expect_value(t, notice_count(notices, "lease_stalled"), 0)
	// Someone else's activity (a user comment) is not holder activity.
	testing.expect_value(t, task_comment(&fx.svc, get_task(fx, "task_1"), Actor{kind = ACTOR_USER, id = "u1"}, "cmt_2").code, domain.Error_Code.None)
	stall_tick(fx, LEASE_STALL_SECONDS + 1)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_STALLED), 1)
	testing.expect_value(t, notice_count(notices, "lease_stalled"), 1)
	stall_expect_lease_kept(t, fx, log, lease.lease_id)
}

@(test)
test_lease_stall_rebuilds_after_hub_restart :: proc(t: ^testing.T) {
	fx, log, notices, lease, ok := stall_fixture(t, "stall_restart")
	defer lease_fixture_close(fx, log)
	if !ok do return
	restart :: proc(fx: ^Fixture) {
		for &timer in fx.svc.timers.heap do timer_destroy(&timer)
		delete(fx.svc.timers.heap)
		fx.svc.timers = Timer_Service{}
		rebuild_timers(&fx.svc)
	}
	restart(fx)
	stall_tick(fx, LEASE_STALL_SECONDS + 1)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_STALL_NUDGED), 1)
	// Restart between nudge and notice: the rebuilt timer neither repeats the
	// nudge nor reports early, and the notice still goes out on time.
	restart(fx)
	stall_tick(fx, 1)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_STALL_NUDGED), 1)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_STALLED), 0)
	stall_tick(fx, LEASE_STALL_SECONDS)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_STALLED), 1)
	testing.expect_value(t, notice_count(notices, "lease_stalled"), 1)
	restart(fx)
	stall_tick(fx, LEASE_STALL_SECONDS + 1)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_STALL_NUDGED), 1)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_STALLED), 1)
	testing.expect_value(t, stall_nudges(log, "inst_w1"), 1)
	// One pending stall timer per lease however often it is armed.
	arm_lease_stall(&fx.svc, lease)
	arm_lease_stall(&fx.svc, lease)
	pending := 0
	for timer in fx.svc.timers.heap do if timer.kind == .Lease_Stalled && timer.key == lease.lease_id do pending += 1
	testing.expect_value(t, pending, 1)
	stall_expect_lease_kept(t, fx, log, lease.lease_id)
}

@(test)
test_lease_stall_ends_when_lease_is_submitted :: proc(t: ^testing.T) {
	fx, log, notices, lease, ok := stall_fixture(t, "stall_submit")
	defer lease_fixture_close(fx, log)
	if !ok do return
	submit_via_release(t, fx, lease)
	for _ in 0..<3 do stall_tick(fx, LEASE_STALL_SECONDS + 1)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_STALL_NUDGED), 0)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_STALLED), 0)
	testing.expect_value(t, notice_count(notices, "lease_stalled"), 0)
}

@(test)
test_lease_stall_chain_override_and_hub_disable :: proc(t: ^testing.T) {
	{
		fx, log, notices, _, ok := stall_fixture(t, "stall_override", `{"lease_stall_seconds":60}`)
		defer lease_fixture_close(fx, log)
		if !ok do return
		stall_tick(fx, 61)
		testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_STALL_NUDGED), 1)
		stall_tick(fx, 61)
		testing.expect_value(t, notice_count(notices, "lease_stalled"), 1)
	}
	{
		fx, log, notices, _, ok := stall_fixture(t, "stall_disabled", `{"lease_stall_seconds":60}`)
		defer lease_fixture_close(fx, log)
		if !ok do return
		fx.svc.lease_stall_seconds = -1 // hub-wide disable wins over a chain override
		for _ in 0..<3 do stall_tick(fx, LEASE_STALL_SECONDS + 1)
		testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_STALL_NUDGED), 0)
		testing.expect_value(t, notice_count(notices, "lease_stalled"), 0)
	}
}
