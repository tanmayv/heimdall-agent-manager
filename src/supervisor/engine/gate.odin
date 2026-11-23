package engine

// Agent gate (spec §12, D6, T0 Q3; T14).
//
// Before an activation stops the runtime, the gate closes launch admission in the runtime
// and counts what would be interrupted: live PTY sessions, in-flight launches and helper
// processes of this instance (Host.gate_count, answered by the runtime). Then:
//
//   user-started op (any actor but `timer`)  -> interrupt now; the count is journaled on
//                                               `activating/gate_closed`
//   timer op, idle                           -> close admission, re-count; still 0 ->
//                                               activate; a launch raced -> reopen, wait
//   timer op, busy                           -> `waiting_for_idle` with
//                                               force_at = now + 2 h (admission stays open)
//   waiting, force_at reached                -> close admission, activate with forced:true
//   waiting, `interrupt` (update_now, J30)   -> activate now; the update_now op is closed
//                                               `noop superseded_by <op>`
//   waiting, `cancel_active` (J9/J35)        -> `cancelled`
//
// The wait is journaled once (`waiting_for_idle` carries force_at and the first count), so
// a supervisor restart keeps the original deadline. The countdown is in
// supervisor-status.json (`force_at`, `remaining_s`, `busy`), rewritten when the count
// changes or the remaining time crosses a minute (gate_status_due).
// Only this instance's processes are stopped afterwards: Host.stop_children stops the
// children the supervisor recorded by (pid, start_time) (src/supervisor/procs).

import "core:fmt"
import "core:strings"

GATE_WAIT_S :: 2 * 3600

TIMER_ACTOR :: "timer"

// How long after an interrupted op failed before the switch the next timer op for the same
// tree still counts as interrupted (interrupt_pending).
INTERRUPT_CARRY_S :: 15 * 60

// gate decides for an op that passed precheck (engine.odin): wait, or close admission and
// run activate_steps.
@(private)
gate :: proc(e: ^Engine, op: Line, rule: Schema_Rule) -> (Exit, Error) {
	if op.actor != TIMER_ACTOR || interrupt_pending(e, op) {
		cur := op
		cur.busy = gate_close_and_count(e)
		cur.forced = false
		return activate_steps(e, cur, rule)
	}
	t := now(e)
	b := gate_count(e)
	if b.counted && busy_total(b) == 0 {
		// Idle: close admission and re-count atomically with respect to new launches.
		again := gate_close_and_count(e)
		if again.counted && busy_total(again) == 0 {
			cur := op
			cur.busy = again
			cur.forced = false
			return activate_steps(e, cur, rule)
		}
		// A launch raced the close: reopen and keep (or start) waiting.
		gate_open_admission(e)
		b = again
	}
	if op.state == "waiting_for_idle" && op.force_at != 0 && t >= op.force_at {
		cur := op
		cur.busy = gate_close_and_count(e)
		cur.forced = true
		return activate_steps(e, cur, rule)
	}
	e.gate_busy = b
	if op.state != "waiting_for_idle" {
		w := op
		w.state = "waiting_for_idle"
		w.sub = ""
		w.force_at = t + e.cfg.gate_wait_s
		w.busy = b
		if err := journal(e, w); err != nil do return .Run, err
		return .Run, nil
	}
	// Still waiting: refresh the countdown (status only), throttled.
	if gate_status_due(e, op, b, t) do write_status(e, op)
	return .Run, nil
}

// Gate_Shown: what the waiting status file last showed.
Gate_Shown :: struct {
	force_at: i64, // identifies the wait (0 = nothing shown yet)
	minute:   i64, // remaining time in whole minutes, rounded up
	busy:     Busy,
}

// gate_status_due throttles the waiting status: tick runs every second for up to 2 h and
// each status write is a synced write plus a replace (7200 fsyncs per wait). The file is
// rewritten only when the count changes or the remaining time crosses a minute; the app
// counts down between writes from the absolute `force_at`.
@(private)
gate_status_due :: proc(e: ^Engine, op: Line, b: Busy, t: i64) -> bool {
	minute := (max(op.force_at - t, 0) + 59) / 60
	shown := Gate_Shown{op.force_at, minute, b}
	if shown == e.gate_shown do return false
	e.gate_shown = shown
	return true
}

// interrupt: an `update_now` (op `by_op_id`, actor `actor`) arrived while the active op is
// verified or waiting for idle agents (§10 coalescing, J30). The active op activates now:
// its `activating/gate_closed` line names `interrupted_by`, then the update_now op is
// closed `noop` with note `superseded_by <active op_id>`. Usage refusals (nothing written):
// `no_op` when no op is active (run the intent as its own op), `bad_state` when the active
// op is past waiting (the caller applies the rest of §10: `cancelled busy`).
interrupt :: proc(e: ^Engine, by_op_id, actor: string) -> (x: Exit, err: Error) {
	if e.failed != nil do return .Run, e.failed
	defer poison(e, err)
	op, ok := e.active.?
	if !ok do return .Run, fail("no_op", "no active operation")
	if op.state != "verified" && op.state != "waiting_for_idle" {
		return .Run, fail("bad_state", "operation %s is %s", op.op_id, op.state)
	}
	cur, rule, done, px, perr := precheck(e, op)
	if done {
		// The active op ended without activating; the update_now runs as its own op.
		return px, perr
	}
	cur.busy = gate_close_and_count(e)
	cur.forced = false
	cur.interrupted_by = by_op_id
	superseded := Line {
		op_id  = by_op_id,
		action = "update_now",
		actor  = actor,
		state  = "noop",
		note   = fmt.tprintf("superseded_by %s", op.op_id),
	}
	return activate_steps(e, cur, rule, superseded)
}

// cancel_active: a `cancel` intent (op `by_op_id`) for the active op (J9, J35 target side;
// the cancel op's own `requested` / `applied` lines are the caller's, §10). Only an op
// before `activating/gate_closed` can be cancelled; it ends `cancelled` with
// `cancelled_by`. Usage refusals (nothing written): `nothing_to_cancel`, `op_mismatch`
// (target_op_id given and not the active op), `past_point_of_no_return`.
cancel_active :: proc(e: ^Engine, by_op_id: string, target_op_id := "") -> (err: Error) {
	if e.failed != nil do return e.failed
	defer poison(e, err)
	op, ok := e.active.?
	if !ok do return fail("nothing_to_cancel", "no active operation")
	if target_op_id != "" && target_op_id != op.op_id {
		return fail("op_mismatch", "active operation is %s", op.op_id)
	}
	switch op.state {
	case "requested", "resolving", "downloading", "verifying", "verified", "waiting_for_idle":
	case:
		return fail("past_point_of_no_return", "operation %s is %s", op.op_id, op.state)
	}
	l := terminal_of(op, "cancelled", "")
	l.cancelled_by = by_op_id
	e.gate_busy = {}
	// Admission stays open while an op waits (§12), so there is nothing to reopen.
	return journal(e, l)
}

// host_end_sessions: §12 "ask the runtime to end sessions" before stop_children.
@(private)
host_end_sessions :: proc(e: ^Engine) {
	if e.host.end_sessions != nil do e.host.end_sessions(e.host.user)
}

// gate_status: what the app shows while an op waits ("Updating in 1 h 12 min — N agents
// will be stopped").
Gate_Status :: struct {
	waiting:     bool,
	op_id:       string,
	force_at:    i64,
	remaining_s: i64,
	busy:        Busy,
}

gate_status :: proc(e: ^Engine) -> (s: Gate_Status) {
	op, ok := e.active.?
	if !ok || op.state != "waiting_for_idle" do return
	s.waiting = true
	s.op_id = op.op_id
	s.force_at = op.force_at
	s.remaining_s = max(op.force_at - now(e), 0)
	s.busy = e.gate_busy if e.gate_busy.counted else op.busy
	return
}

// ---- host wrappers ----

// gate_count fails closed: a host without the hook (or a runtime that does not answer)
// reports counted = false, which a timer op treats as busy (wait, then force at force_at).
@(private)
gate_count :: proc(e: ^Engine) -> Busy {
	if e.host.gate_count == nil do return Busy{}
	return e.host.gate_count(e.host.user)
}

// gate_close_and_count closes admission and counts. A runtime that did not confirm the
// close still gets stopped by activate_steps; the count says what it reported.
@(private)
gate_close_and_count :: proc(e: ^Engine) -> Busy {
	if e.host.close_admission != nil do _ = e.host.close_admission(e.host.user)
	return gate_count(e)
}

@(private)
gate_open_admission :: proc(e: ^Engine) {
	if e.host.open_admission != nil do e.host.open_admission(e.host.user)
}

// interrupt_pending: J30 after-the-fact. An interrupted op that fails before the switch
// (a crash after its `activating/gate_closed` line -> `failed interrupted_before_switch`,
// J10; or stop_timeout, snapshot_failed, …) has already answered its update_now
// `noop superseded_by`. Without this rule the user's intent would be lost and the retried
// timer op would wait 2 h again, so the next timer op after such a failure interrupts too.
//
// Bounded: only for the same candidate tree and within INTERRUPT_CARRY_S of the failure, so
// agents started hours later are not killed without their 2 h countdown.
@(private)
interrupt_pending :: proc(e: ^Engine, op: Line) -> bool {
	lt, ok := e.last_terminal.?
	if !ok || lt.interrupted_by == "" || lt.state != "failed" do return false
	return lt.to.tree == op.to.tree && now(e) - lt.ts <= INTERRUPT_CARRY_S
}

// write_gate_status: gate members of supervisor-status.json (engine.odin write_status).
@(private)
write_gate_status :: proc(e: ^Engine, b: ^strings.Builder, l: Line) {
	busy := l.busy
	if l.state == "waiting_for_idle" && e.gate_busy.counted do busy = e.gate_busy
	strings.write_string(b, `,"force_at":`)
	if l.state == "waiting_for_idle" && l.force_at != 0 {
		fmt.sbprintf(b, `%d,"remaining_s":%d`, l.force_at, max(l.force_at - now(e), 0))
	} else {
		strings.write_string(b, `null,"remaining_s":null`)
	}
	strings.write_string(b, `,"busy":`)
	if busy.counted {
		fmt.sbprintf(b, `{{"pty_sessions":%d,"launches":%d,"helpers":%d,"total":%d}}`, busy.pty_sessions, busy.launches, busy.helpers, busy_total(busy))
	} else {
		strings.write_string(b, "null")
	}
	fmt.sbprintf(b, `,"forced":%v`, l.forced)
}
