package taskv2

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"

// REQ-CIS-5: coordinator idle-stop timers over the real SQLite fixture and a
// fake clock. X = 1 h (completed chains), Y = 6 h (any status).

IDLE_X :: 60 * 60
IDLE_Y :: 6 * 60 * 60

Idle_Stop_Log :: struct {
	ids:     [dynamic]string,
	reasons: [dynamic]string,
	refuse:  bool,
}

idle_stop_observe :: proc(ctx: rawptr, owner: domain.User_ID, instance_id, reason: string) -> bool {
	log := (^Idle_Stop_Log)(ctx)
	append(&log.ids, strings.clone(instance_id))
	append(&log.reasons, strings.clone(reason))
	return !log.refuse
}

idle_stop_log_destroy :: proc(log: ^Idle_Stop_Log) {
	for s in log.ids do delete(s)
	for s in log.reasons do delete(s)
	delete(log.ids)
	delete(log.reasons)
	free(log)
}

Idle_Fixture :: struct {
	fx:           ^Fixture,
	wake:         ^Wake_Log,
	stops:        ^Idle_Stop_Log,
	content_impl: sqlite.Content_Repo_SQLite,
	content:      iface.Content_Repository,
	chain:        domain.Task_Chain,
}

// idle_fixture: a live chain with coordinator inst_coord (conversation
// conv_coord), X/Y configured, stops recorded instead of sent.
idle_fixture :: proc(t: ^testing.T, tag: string) -> (^Idle_Fixture, bool) {
	ifx := new(Idle_Fixture)
	fx, wake, ok := lease_fixture(t, tag)
	ifx.fx, ifx.wake = fx, wake
	ifx.stops = new(Idle_Stop_Log)
	if !ok do return ifx, false
	fx.svc.coordinator_idle_completed_seconds = IDLE_X
	fx.svc.coordinator_idle_seconds = IDLE_Y
	fx.svc.coordinator_stop = idle_stop_observe
	fx.svc.coordinator_stop_ctx = rawptr(ifx.stops)
	ifx.content = sqlite.new_content_repository(&ifx.content_impl, &fx.conn)
	fx.svc.content = &ifx.content
	ifx.chain = seed_live_chain(t, fx, fmt.tprintf("chain_%s", tag))
	// conversation_id is fixed at insert (not part of the instance upsert).
	testing.expect(t, sqlite.exec(&fx.conn, "UPDATE agent_instances SET conversation_id = 'conv_coord' WHERE agent_instance_id = 'inst_coord';"), "bind coordinator conversation")
	now := platform.clock_now(&fx.clock)
	_, conv_ok, conv_err := iface.content_save_conversation(&ifx.content, domain.Chat_Conversation{conversation_id = "conv_coord", owner_user_id = "u1", agent_id = "agt_c", agent_instance_id = "inst_coord", chain_id = string(ifx.chain.chain_id), title = "coord", title_source = "default", created_at = now, updated_at = now})
	testing.expect(t, conv_ok, fmt.tprintf("save conversation: %s", conv_err.message))
	return ifx, true
}

idle_fixture_close :: proc(ifx: ^Idle_Fixture) {
	fx, wake := ifx.fx, ifx.wake
	idle_stop_log_destroy(ifx.stops)
	free(ifx)
	// Last: fixture_close resets the tracking allocator's map.
	lease_fixture_close(fx, wake)
}

idle_now :: proc(ifx: ^Idle_Fixture) -> i64 { return now_ms(&ifx.fx.clock) }

idle_tick :: proc(ifx: ^Idle_Fixture, advance_seconds: i64) {
	fixture_advance(ifx.fx, advance_seconds)
	_ = fire_due(&ifx.fx.svc, idle_now(ifx))
}

idle_stamp :: proc(ifx: ^Idle_Fixture, id := "inst_coord") -> string {
	stamp, _, _ := iface.agent_get_user_activity(&ifx.fx.agents, id)
	return stamp
}

// set_chain_status writes the column directly: completion and reopen have
// their own engine verbs; the timers only read the stored status.
set_chain_status :: proc(ifx: ^Idle_Fixture, status: domain.Task_Chain_Status) {
	name := "completed" if status == .Completed else "active"
	_ = sqlite.exec(&ifx.fx.conn, fmt.tprintf("UPDATE task_chains SET status = '%s', completion_summary = 'done' WHERE chain_id = '%s';", name, ifx.chain.chain_id))
	chain, _, _ := iface.taskchain_get_chain(&ifx.fx.repo, ifx.chain.chain_id)
	ifx.chain = chain
}

update_coord :: proc(ifx: ^Idle_Fixture, runtime_status := "", activity_status := "", stopped_by := "", started_at := "") {
	inst, _, _ := iface.agent_get_instance(&ifx.fx.agents, "inst_coord")
	if runtime_status != "" do inst.runtime_status = runtime_status
	if activity_status != "" do inst.activity_status = activity_status
	if stopped_by != "" do inst.stopped_by = stopped_by
	if started_at != "" do inst.started_at = started_at
	_, _, _ = iface.agent_save_instance(&ifx.fx.agents, inst)
}

@(test)
test_coordinator_idle_y_stops_on_active_chain_x_does_not :: proc(t: ^testing.T) {
	ifx, ok := idle_fixture(t, "cis_y_active")
	defer idle_fixture_close(ifx)
	if !ok do return
	rebuild_timers(&ifx.fx.svc)
	stamp := idle_stamp(ifx)
	testing.expect(t, stamp != "", "a stamp-less coordinator is seeded once at arming")
	idle_tick(ifx, IDLE_X + 1)
	testing.expect_value(t, len(ifx.stops.ids), 0) // X never applies while the chain is Active
	idle_tick(ifx, IDLE_Y - IDLE_X - 2)
	testing.expect_value(t, len(ifx.stops.ids), 0)
	idle_tick(ifx, 2)
	if !testing.expect_value(t, len(ifx.stops.ids), 1) do return
	testing.expect_value(t, ifx.stops.ids[0], "inst_coord")
	testing.expect_value(t, ifx.stops.reasons[0], string(COORDINATOR_IDLE_REASON))
	testing.expect(t, !strings.has_prefix(ifx.stops.reasons[0], "user"), "the reason never marks a user stop")
	testing.expect_value(t, idle_stamp(ifx), stamp) // firing is not a reset
}

@(test)
test_coordinator_idle_x_stops_completed_chain_with_reason :: proc(t: ^testing.T) {
	ifx, ok := idle_fixture(t, "cis_x_completed")
	defer idle_fixture_close(ifx)
	if !ok do return
	set_chain_status(ifx, .Completed)
	arm_coordinator_idle_for_chain(&ifx.fx.svc, ifx.chain)
	idle_tick(ifx, IDLE_X - 1)
	testing.expect_value(t, len(ifx.stops.ids), 0)
	idle_tick(ifx, 2)
	if !testing.expect_value(t, len(ifx.stops.ids), 1) do return
	testing.expect_value(t, ifx.stops.reasons[0], string(COORDINATOR_IDLE_REASON_COMPLETED))
}

@(test)
test_coordinator_idle_user_events_reset_the_stamp :: proc(t: ^testing.T) {
	ifx, ok := idle_fixture(t, "cis_reset")
	defer idle_fixture_close(ifx)
	if !ok do return
	set_chain_status(ifx, .Completed)
	arm_coordinator_idle_for_chain(&ifx.fx.svc, ifx.chain)
	first := idle_stamp(ifx)
	idle_tick(ifx, 30 * 60)
	note_user_activity(&ifx.fx.svc, "inst_coord") // user chat / answer / action card
	second := idle_stamp(ifx)
	testing.expect(t, second > first, "a user event moves the stamp forward")
	idle_tick(ifx, 30 * 60 + 1) // first X deadline passes: the stale timer is a no-op
	testing.expect_value(t, len(ifx.stops.ids), 0)
	idle_tick(ifx, 30 * 60)
	if !testing.expect_value(t, len(ifx.stops.ids), 1) do return
	testing.expect_value(t, ifx.stops.reasons[0], string(COORDINATOR_IDLE_REASON_COMPLETED))
	// The stamp never moves backwards.
	_, _ = iface.agent_touch_user_activity(&ifx.fx.agents, "inst_coord", first)
	testing.expect_value(t, idle_stamp(ifx), second)
}

@(test)
test_coordinator_idle_completed_then_reopened_cancels_x_and_recomplete_rearms :: proc(t: ^testing.T) {
	ifx, ok := idle_fixture(t, "cis_reopen")
	defer idle_fixture_close(ifx)
	if !ok do return
	set_chain_status(ifx, .Completed)
	arm_coordinator_idle_for_chain(&ifx.fx.svc, ifx.chain)
	idle_tick(ifx, 10 * 60)
	set_chain_status(ifx, .Active) // reopened before X fires
	idle_tick(ifx, IDLE_X)
	testing.expect_value(t, len(ifx.stops.ids), 0)
	set_chain_status(ifx, .Completed)
	arm_coordinator_idle_for_chain(&ifx.fx.svc, ifx.chain) // re-complete re-arms (overdue → next tick)
	idle_tick(ifx, 1)
	if !testing.expect_value(t, len(ifx.stops.ids), 1) do return
	testing.expect_value(t, ifx.stops.reasons[0], string(COORDINATOR_IDLE_REASON_COMPLETED))
}

@(test)
test_coordinator_idle_guards_defer_then_stop :: proc(t: ^testing.T) {
	ifx, ok := idle_fixture(t, "cis_guards")
	defer idle_fixture_close(ifx)
	if !ok do return
	fx := ifx.fx
	rebuild_timers(&fx.svc)
	task := seed_task(t, fx, ifx.chain, "task_cis_guard")
	// busy
	update_coord(ifx, activity_status = "busy")
	idle_tick(ifx, IDLE_Y + 1)
	testing.expect_value(t, len(ifx.stops.ids), 0)
	update_coord(ifx, activity_status = "idle")
	// a live lease (Solo coordinator working a task)
	now := platform.clock_now(&fx.clock)
	testing.expect(t, sqlite.exec(&fx.conn, fmt.tprintf("INSERT INTO task_leases(lease_id, task_id, chain_id, owner_user_id, attempt_no, holder_instance_id, kind, granted_at, expires_at, hard_deadline_at, delivery) VALUES ('lease_cis','%s','%s','u1',1,'inst_coord','work','%s','','','wake');", task.task_id, ifx.chain.chain_id, now)), "seed coordinator lease")
	idle_tick(ifx, COORDINATOR_IDLE_RETRY_SECONDS)
	testing.expect_value(t, len(ifx.stops.ids), 0)
	testing.expect(t, sqlite.exec(&fx.conn, "DELETE FROM task_leases WHERE lease_id = 'lease_cis';"), "drop lease")
	// unread user input
	_, msg_ok, msg_err := iface.content_save_message(&ifx.content, domain.Chat_Message{message_id = "msg_cis_unread", conversation_id = "conv_coord", owner_user_id = "u1", direction = "user_to_agent", sender_agent_id = "agt_c", sender_agent_instance_id = "inst_coord", body = "still there?", artifact_ids_json = "[]", message_type = "text", message_status = "complete", metadata_json = "{}", created_at = platform.clock_now(&fx.clock)})
	testing.expect(t, msg_ok, fmt.tprintf("save message: %s", msg_err.message))
	idle_tick(ifx, COORDINATOR_IDLE_RETRY_SECONDS)
	testing.expect_value(t, len(ifx.stops.ids), 0)
	testing.expect(t, sqlite.exec(&fx.conn, fmt.tprintf("UPDATE chat_messages SET read_at = '%s' WHERE message_id = 'msg_cis_unread';", platform.clock_now(&fx.clock))), "mark read")
	// just (re)started
	update_coord(ifx, started_at = platform.clock_now(&fx.clock))
	idle_tick(ifx, COORDINATOR_IDLE_RETRY_SECONDS)
	testing.expect_value(t, len(ifx.stops.ids), 0)
	idle_tick(ifx, COORDINATOR_IDLE_START_GRACE_SECONDS)
	// every guard cleared, stamp unchanged: stop once.
	if !testing.expect_value(t, len(ifx.stops.ids), 1) do return
	testing.expect_value(t, ifx.stops.reasons[0], string(COORDINATOR_IDLE_REASON))
	idle_tick(ifx, COORDINATOR_IDLE_RETRY_SECONDS * 3)
	testing.expect_value(t, len(ifx.stops.ids), 1)
}

@(test)
test_coordinator_idle_noop_when_user_stopped_not_live_or_stamp_moved :: proc(t: ^testing.T) {
	ifx, ok := idle_fixture(t, "cis_noop")
	defer idle_fixture_close(ifx)
	if !ok do return
	rebuild_timers(&ifx.fx.svc)
	update_coord(ifx, runtime_status = "stopped", stopped_by = "user")
	idle_tick(ifx, IDLE_Y + 1)
	testing.expect_value(t, len(ifx.stops.ids), 0)
	testing.expect_value(t, timers_armed_count(&ifx.fx.svc), 0) // no retry loop for a gone instance
	inst, _, _ := iface.agent_get_instance(&ifx.fx.agents, "inst_coord")
	inst.runtime_status, inst.stopped_by = "running", ""
	_, _, _ = iface.agent_save_instance(&ifx.fx.agents, inst)
	// An armed timer whose stamp was moved by a later write is a no-op.
	timers_arm(&ifx.fx.svc, .Coordinator_Idle, "inst_coord", idle_now(ifx), "2000-01-01T00:00:00Z")
	idle_tick(ifx, 1)
	testing.expect_value(t, len(ifx.stops.ids), 0)
	// A failed stop retries instead of being lost.
	ifx.stops.refuse = true
	note_user_activity(&ifx.fx.svc, "inst_coord")
	idle_tick(ifx, IDLE_Y + 1)
	testing.expect_value(t, len(ifx.stops.ids), 1)
	ifx.stops.refuse = false
	idle_tick(ifx, COORDINATOR_IDLE_RETRY_SECONDS)
	testing.expect_value(t, len(ifx.stops.ids), 2)
}

@(test)
test_coordinator_idle_boot_rebuild_fires_overdue_promptly :: proc(t: ^testing.T) {
	ifx, ok := idle_fixture(t, "cis_boot")
	defer idle_fixture_close(ifx)
	if !ok do return
	set_chain_status(ifx, .Completed)
	// The hub was down past X: the durable stamp is older than the deadline.
	old := platform.clock_now(&ifx.fx.clock)
	_, _ = iface.agent_touch_user_activity(&ifx.fx.agents, "inst_coord", old)
	fixture_advance(ifx.fx, IDLE_X + 600)
	testing.expect_value(t, timers_armed_count(&ifx.fx.svc), 0)
	rebuild_timers(&ifx.fx.svc)
	testing.expect_value(t, idle_stamp(ifx), old) // boot never resets
	_ = fire_due(&ifx.fx.svc, idle_now(ifx))
	if !testing.expect_value(t, len(ifx.stops.ids), 1) do return
	testing.expect_value(t, ifx.stops.reasons[0], string(COORDINATOR_IDLE_REASON_COMPLETED))
}

@(test)
test_coordinator_idle_zero_disables :: proc(t: ^testing.T) {
	ifx, ok := idle_fixture(t, "cis_disabled")
	defer idle_fixture_close(ifx)
	if !ok do return
	ifx.fx.svc.coordinator_idle_completed_seconds = 0
	ifx.fx.svc.coordinator_idle_seconds = 0
	set_chain_status(ifx, .Completed)
	rebuild_timers(&ifx.fx.svc)
	note_user_activity(&ifx.fx.svc, "inst_coord")
	idle_tick(ifx, IDLE_Y * 4)
	testing.expect_value(t, len(ifx.stops.ids), 0)
	testing.expect(t, idle_stamp(ifx) != "", "the stamp is still recorded while disabled")
}

// Review verdicts: a user's LGTM/NGTM and a coordinator's --on-behalf-of user
// verdict reset the stamp; worker submit/heartbeat and an agent reviewer's
// verdict do not.
@(test)
test_coordinator_idle_review_resets_only_for_user_verdicts :: proc(t: ^testing.T) {
	ifx, ok := idle_fixture(t, "cis_review")
	defer idle_fixture_close(ifx)
	if !ok do return
	fx := ifx.fx
	rebuild_timers(&fx.svc)
	seeded := idle_stamp(ifx)
	seed_fleet(fx, ifx.chain, "agt_w")
	seed_instance(fx, ifx.chain, "inst_w1", "agt_w", "br_1", "idle")
	task := publish_task(t, fx, ifx.chain, "task_cis_review")
	task.requires_user_approval = true
	_, _, _ = iface.taskchain_save_task(&fx.repo, task)
	confirm_holder(fx, "inst_w1")
	fixture_advance(fx, 60)
	lease, _ := lease_of(fx, "inst_w1")
	_, _, _ = lease_heartbeat(&fx.svc, inst_auth("inst_w1"), Lease_Heartbeat_Input{lease_id = lease.lease_id, note = "progress"})
	_, submitted, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "ready"})
	if !testing.expect(t, submitted, fmt.tprintf("submit: %s", serr.message)) do return
	testing.expect_value(t, idle_stamp(ifx), seeded) // leases, heartbeats, submits and notices are not user events
	fixture_advance(fx, 60)
	_, reviewed, rerr := user_review(&fx.svc, user_auth(), task.task_id, Review_Input{verdict = "request_changes", summary = "NGTM: fix it"})
	if !testing.expect(t, reviewed, fmt.tprintf("user review: %s", rerr.message)) do return
	after_user := idle_stamp(ifx)
	testing.expect(t, after_user > seeded, "user NGTM resets the coordinator stamp")
	// Rework and resubmit, then the coordinator relays the user's LGTM.
	confirm_holder(fx, "inst_w1")
	_, resubmitted, rserr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "fixed"})
	if !testing.expect(t, resubmitted, fmt.tprintf("resubmit: %s", rserr.message)) do return
	testing.expect_value(t, idle_stamp(ifx), after_user)
	fixture_advance(fx, 60)
	_, proxied, perr := review_post(&fx.svc, inst_auth("inst_coord"), Review_Input{task_id = string(task.task_id), verdict = "approve", on_behalf_of = "user"})
	if !testing.expect(t, proxied, fmt.tprintf("proxy review: %s", perr.message)) do return
	testing.expect(t, idle_stamp(ifx) > after_user, "review post --on-behalf-of user resets the stamp")
}

// A WAITING claim (submitted and awaiting the user's review, or blocked on the
// user) permits no work: it must not defer Y. Otherwise a Solo coordinator
// idling on the user is never stopped. Only an active claim defers.
@(test)
test_coordinator_idle_waiting_claim_does_not_defer :: proc(t: ^testing.T) {
	ifx, ok := idle_fixture(t, "cis_waiting")
	defer idle_fixture_close(ifx)
	if !ok do return
	fx := ifx.fx
	rebuild_timers(&fx.svc)
	task := seed_task(t, fx, ifx.chain, "task_cis_waiting")
	now := platform.clock_now(&fx.clock)
	testing.expect(t, sqlite.exec(&fx.conn, fmt.tprintf("INSERT INTO task_leases(lease_id, task_id, chain_id, owner_user_id, attempt_no, holder_instance_id, kind, granted_at, expires_at, hard_deadline_at, delivery, phase) VALUES ('lease_cis_wait','%s','%s','u1',1,'inst_coord','work','%s','','','wake','waiting');", task.task_id, ifx.chain.chain_id, now)), "seed waiting claim")
	lease, held, _ := iface.taskchain_get_lease_by_holder(&fx.repo, "inst_coord")
	if !testing.expect(t, held && lease.phase == domain.LEASE_PHASE_WAITING, "waiting claim stored") do return
	idle_tick(ifx, IDLE_Y + 1)
	if !testing.expect_value(t, len(ifx.stops.ids), 1) do return
	testing.expect_value(t, ifx.stops.reasons[0], string(COORDINATOR_IDLE_REASON))
}

// The stop re-checks the stamp and unread input right before stop_instance:
// a user event that committed after the fire's reads cancels (stamp moved) or
// defers (unread input) the stop.
@(test)
test_coordinator_idle_stop_rechecks_after_commit :: proc(t: ^testing.T) {
	ifx, ok := idle_fixture(t, "cis_recheck")
	defer idle_fixture_close(ifx)
	if !ok do return
	fx := ifx.fx
	note_user_activity(&fx.svc, "inst_coord")
	armed := idle_stamp(ifx)
	fixture_advance(fx, 60)
	note_user_activity(&fx.svc, "inst_coord") // the late user event
	stop := Coordinator_Idle_Stop{owner = "u1", instance_id = "inst_coord", reason = COORDINATOR_IDLE_REASON, kind = .Coordinator_Idle, armed = armed}
	coordinator_idle_stop_after_commit(&fx.svc, stop, idle_now(ifx))
	testing.expect_value(t, len(ifx.stops.ids), 0)
	// Same stamp, but an unread user message arrived: defer and retry.
	stop.armed = idle_stamp(ifx)
	_, msg_ok, _ := iface.content_save_message(&ifx.content, domain.Chat_Message{message_id = "msg_cis_late", conversation_id = "conv_coord", owner_user_id = "u1", direction = "user_to_agent", sender_agent_id = "agt_c", sender_agent_instance_id = "inst_coord", body = "wait", artifact_ids_json = "[]", message_type = "text", message_status = "complete", metadata_json = "{}", created_at = platform.clock_now(&fx.clock)})
	testing.expect(t, msg_ok, "save late message")
	before := timers_armed_count(&fx.svc)
	coordinator_idle_stop_after_commit(&fx.svc, stop, idle_now(ifx))
	testing.expect_value(t, len(ifx.stops.ids), 0)
	testing.expect_value(t, timers_armed_count(&fx.svc), before + 1)
	testing.expect(t, sqlite.exec(&fx.conn, "UPDATE chat_messages SET read_at = '2099-01-01T00:00:00Z' WHERE message_id = 'msg_cis_late';"), "mark read")
	coordinator_idle_stop_after_commit(&fx.svc, stop, idle_now(ifx))
	testing.expect_value(t, len(ifx.stops.ids), 1)
}
