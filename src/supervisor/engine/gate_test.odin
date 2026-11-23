package engine

// Agent gate tests (spec §12, D6, T0 Q3; J9, J10, J30, J35). The fake host's runtime
// reports `agents`; the clock is fake, so the 2 h wait runs in simulated time.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:testing"
import lc "../../launcher/core"

@(private = "file")
gate_world :: proc(w: ^World, t: ^testing.T, prefix: string) -> (from, to: Ref) {
	world_init(w, t, prefix)
	from = make_tree(w.root, Tree_Spec{version = "0.6.0", digit = 'a'})
	to = make_tree(w.root, Tree_Spec{version = "0.6.1", digit = 'b'})
	w.fake.behaviour[from.tree] = .Good
	w.fake.behaviour[to.tree] = .Good
	install(w, from)
	x, err := launch(w)
	testing.expect(t, err == nil && x == .Run, "launch")
	return
}

@(private = "file")
lines_of :: proc(w: ^World) -> []Line {
	r := read_journal_file(join(w.root, "supervisor", "journal", "ops.jsonl"), context.temp_allocator)
	return r.lines[:]
}

@(private = "file")
last_of :: proc(w: ^World) -> Line {
	ls := lines_of(w)
	if len(ls) == 0 do return {}
	return ls[len(ls) - 1]
}

// find: the first line of op_id in state/sub ("" sub = any).
@(private = "file")
find :: proc(w: ^World, op_id, state: string, sub := "") -> (Line, bool) {
	for l in lines_of(w) {
		if l.op_id == op_id && l.state == state && (sub == "" || l.sub == sub) do return l, true
	}
	return {}, false
}

@(private = "file")
count_state :: proc(w: ^World, op_id, state: string) -> int {
	n := 0
	for l in lines_of(w) do if l.op_id == op_id && l.state == state do n += 1
	return n
}

@(private = "file")
status_obj :: proc(w: ^World) -> json.Object {
	data := read_text(join(w.state, "supervisor-status.json"))
	v, err := json.parse(transmute([]byte)data, json.Specification.JSON, true, context.temp_allocator)
	if err != nil do return nil
	o, _ := v.(json.Object)
	return o
}

@(private = "file")
status_obj_busy_total :: proc(w: ^World) -> (i64, bool) {
	o := status_obj(w)
	if o == nil do return 0, false
	b, ok := o["busy"].(json.Object)
	if !ok do return 0, false
	return obj_int(b, "total")
}

@(private = "file")
status_int :: proc(w: ^World, key: string) -> (i64, bool) {
	o := status_obj(w)
	if o == nil do return 0, false
	return obj_int(o, key)
}

// begin a timer op for `to` and run it into the gate.
@(private = "file")
timer_op :: proc(w: ^World, op_id: string, to: Ref) -> (Exit, Error) {
	if err := begin_verified(&w.e, Activation{op_id, "update_now", TIMER_ACTOR, to}); err != nil do return .Run, err
	return activate(&w.e)
}

// advance the clock by `secs` in 5 s ticks; stops at the first non-Run result or error.
@(private = "file")
advance :: proc(w: ^World, secs: i64) -> (x: Exit, err: Error) {
	for elapsed: i64 = 0; elapsed < secs; elapsed += 5 {
		w.fake.clock += 5
		x, err = tick(&w.e)
		if err != nil || x != .Run do return
	}
	return .Run, nil
}

// finish: hand over and let the candidate pass probation; returns the op's terminal line.
@(private = "file")
finish :: proc(w: ^World, op_id: string) -> Outcome {
	handover(w)
	x, err := launch(w)
	testing.expect(w.t, err == nil && x == .Run, "launch after handover")
	for _ in 0 ..< 100 {
		if w.e.active == nil do break
		w.fake.clock += 5
		tx, terr := tick(&w.e)
		if !handle(w, tx, terr) do break
	}
	return final_outcome(w, op_id)
}

// ---- acceptance: a busy timer op waits visibly, then forces after 2 h ----

@(test)
test_gate_timer_waits_with_countdown_then_forces :: proc(t: ^testing.T) {
	w: World
	from, to := gate_world(&w, t, "t14-wait")
	defer world_destroy(&w)
	w.fake.agents = Busy{pty_sessions = 2, launches = 1, helpers = 1}
	t0 := w.fake.clock

	x, err := timer_op(&w, "op_timer", to)
	testing.expect(t, err == nil && x == .Run, "a busy timer op keeps running")
	l := last_of(&w)
	testing.expect_value(t, l.state, "waiting_for_idle")
	testing.expect_value(t, l.force_at, t0 + GATE_WAIT_S)
	testing.expect(t, l.busy.counted && busy_total(l.busy) == 4, "the wait journals the count")
	testing.expect(t, w.fake.admission_open, "admission stays open while waiting")
	testing.expect_value(t, w.fake.running, from.tree)
	testing.expect_value(t, len(w.fake.stops), 0)
	rem, ok := status_int(&w, "remaining_s")
	testing.expect(t, ok && rem == GATE_WAIT_S, "status carries the countdown")
	fa, _ := status_int(&w, "force_at")
	testing.expect_value(t, fa, t0 + GATE_WAIT_S)

	// One hour later: still waiting, countdown down to 1 h, nothing stopped, no new lines.
	n_lines := len(lines_of(&w))
	x, err = advance(&w, 3600)
	testing.expect(t, err == nil && x == .Run)
	testing.expect_value(t, len(lines_of(&w)), n_lines)
	rem, _ = status_int(&w, "remaining_s")
	testing.expect_value(t, rem, i64(3600))
	gs := gate_status(&w.e)
	testing.expect(t, gs.waiting && gs.remaining_s == 3600 && busy_total(gs.busy) == 4, "gate_status countdown")
	// A new agent starts during the wait (admission open): the count follows.
	w.fake.agents.pty_sessions = 3
	x, err = advance(&w, 5)
	gs = gate_status(&w.e)
	testing.expect_value(t, busy_total(gs.busy), 5)
	testing.expect_value(t, len(w.fake.stops), 0)

	// Just before force_at: still waiting.
	x, err = advance(&w, t0 + GATE_WAIT_S - 5 - w.fake.clock)
	testing.expect(t, err == nil && x == .Run && w.e.active.?.state == "waiting_for_idle", "still waiting before force_at")
	// force_at: admission closed, agents stopped, activation proceeds.
	x, err = advance(&w, 10)
	testing.expect(t, err == nil, "force")
	testing.expect_value(t, x, Exit.Handover)
	gc, found := find(&w, "op_timer", "activating", "gate_closed")
	testing.expect(t, found && gc.forced, "gate_closed is journaled forced:true")
	testing.expect(t, gc.busy.counted && busy_total(gc.busy) == 5, "forced gate_closed carries the count")
	testing.expect(t, !w.fake.admission_open || w.fake.running == "", "admission closed at force")
	testing.expect(t, len(w.fake.stops) == 1 && w.fake.stops[0] == from.tree, "only this instance's runtime tree is stopped")
	out := finish(&w, "op_timer")
	testing.expect_value(t, out.state, "committed")
}

@(test)
test_gate_timer_proceeds_when_agents_finish :: proc(t: ^testing.T) {
	w: World
	_, to := gate_world(&w, t, "t14-idle")
	defer world_destroy(&w)
	w.fake.agents = Busy{pty_sessions = 1}
	x, err := timer_op(&w, "op_timer", to)
	testing.expect(t, err == nil && x == .Run)
	testing.expect_value(t, last_of(&w).state, "waiting_for_idle")
	x, err = advance(&w, 600)
	testing.expect(t, err == nil && x == .Run)
	w.fake.agents = {}
	x, err = advance(&w, 5)
	testing.expect(t, err == nil)
	testing.expect_value(t, x, Exit.Handover)
	gc, found := find(&w, "op_timer", "activating", "gate_closed")
	testing.expect(t, found && !gc.forced && gc.busy.counted && busy_total(gc.busy) == 0, "idle activation: not forced, count 0")
	testing.expect_value(t, finish(&w, "op_timer").state, "committed")
}

@(test)
test_gate_timer_idle_activates_at_once :: proc(t: ^testing.T) {
	w: World
	_, to := gate_world(&w, t, "t14-idle0")
	defer world_destroy(&w)
	x, err := timer_op(&w, "op_timer", to)
	testing.expect(t, err == nil)
	testing.expect_value(t, x, Exit.Handover)
	_, waited := find(&w, "op_timer", "waiting_for_idle")
	testing.expect(t, !waited, "an idle instance never waits")
	testing.expect_value(t, w.fake.closes, 1)
}

// A launch that races the close is seen by the re-count: admission reopens and the op
// waits instead of killing the new agent.
@(test)
test_gate_admission_race_reopens_and_waits :: proc(t: ^testing.T) {
	w: World
	from, to := gate_world(&w, t, "t14-race")
	defer world_destroy(&w)
	w.fake.race_on_close = true
	x, err := timer_op(&w, "op_timer", to)
	testing.expect(t, err == nil && x == .Run)
	l := last_of(&w)
	testing.expect_value(t, l.state, "waiting_for_idle")
	testing.expect(t, l.busy.counted && l.busy.launches == 1, "the raced launch is counted")
	testing.expect(t, w.fake.admission_open, "admission reopened after the race")
	testing.expect_value(t, w.fake.opens, 1)
	testing.expect_value(t, w.fake.running, from.tree)
	testing.expect_value(t, len(w.fake.stops), 0)
}

// The runtime does not answer: unknown counts as busy, so the op waits, then forces.
@(test)
test_gate_silent_runtime_waits_then_forces :: proc(t: ^testing.T) {
	w: World
	_, to := gate_world(&w, t, "t14-silent")
	defer world_destroy(&w)
	w.gate_wait_s = 0
	w.fake.silent = true
	x, err := timer_op(&w, "op_timer", to)
	testing.expect(t, err == nil && x == .Run)
	l := last_of(&w)
	testing.expect(t, l.state == "waiting_for_idle" && !l.busy.counted, "unknown count waits; busy is null")
	x, err = advance(&w, GATE_WAIT_S + 5)
	testing.expect(t, err == nil)
	testing.expect_value(t, x, Exit.Handover)
	gc, _ := find(&w, "op_timer", "activating", "gate_closed")
	testing.expect(t, gc.forced, "forced")
}

// ---- acceptance: user-started ops and update_now interrupt at once ----

@(test)
test_gate_user_op_interrupts_immediately :: proc(t: ^testing.T) {
	w: World
	from, to := gate_world(&w, t, "t14-user")
	defer world_destroy(&w)
	w.fake.agents = Busy{pty_sessions = 3}
	testing.expect(t, begin_verified(&w.e, Activation{"op_user", "update_now", "app:usr_1", to}) == nil)
	x, err := activate(&w.e)
	testing.expect(t, err == nil)
	testing.expect_value(t, x, Exit.Handover)
	_, waited := find(&w, "op_user", "waiting_for_idle")
	testing.expect(t, !waited, "a user op never waits")
	gc, found := find(&w, "op_user", "activating", "gate_closed")
	testing.expect(t, found && !gc.forced && gc.busy.counted && gc.busy.pty_sessions == 3, "the interrupted count is journaled")
	testing.expect(t, len(w.fake.stops) == 1 && w.fake.stops[0] == from.tree)
	testing.expect_value(t, finish(&w, "op_user").state, "committed")
}

@(test)
test_gate_rollback_to_previous_interrupts_immediately :: proc(t: ^testing.T) {
	w: World
	_, to := gate_world(&w, t, "t14-rbuser")
	defer world_destroy(&w)
	// Install `to`, then roll back to `from` while agents are busy.
	testing.expect(t, begin_verified(&w.e, Activation{"op_up", "update_now", "cli", to}) == nil)
	x, err := activate(&w.e)
	testing.expect(t, err == nil && x == .Handover)
	testing.expect_value(t, finish(&w, "op_up").state, "committed")
	w.fake.agents = Busy{pty_sessions = 1}
	x, err = rollback_to_previous(&w.e, "op_rb", "app:usr_1")
	testing.expect(t, err == nil)
	testing.expect_value(t, x, Exit.Handover)
	gc, found := find(&w, "op_rb", "activating", "gate_closed")
	testing.expect(t, found && gc.busy.pty_sessions == 1, "rollback_to_previous journals the count and does not wait")
}

@(test)
test_gate_update_now_interrupts_the_wait :: proc(t: ^testing.T) {
	w: World
	from, to := gate_world(&w, t, "t14-interrupt")
	defer world_destroy(&w)
	w.fake.agents = Busy{pty_sessions = 2}
	x, err := timer_op(&w, "op_timer", to)
	testing.expect(t, err == nil && x == .Run && last_of(&w).state == "waiting_for_idle")
	x, err = advance(&w, 900)
	testing.expect(t, err == nil && x == .Run)

	x, err = interrupt(&w.e, "op_now", "app:usr_1")
	testing.expect(t, err == nil)
	testing.expect_value(t, x, Exit.Handover)
	ls := lines_of(&w)
	// J30 order: active op gate_closed with interrupted_by, then the update_now op's noop.
	gi, ni := -1, -1
	for l, i in ls {
		if l.op_id == "op_timer" && l.sub == "gate_closed" do gi = i
		if l.op_id == "op_now" do ni = i
	}
	testing.expect(t, gi >= 0 && ni == gi + 1, "gate_closed, then the superseded op's line")
	if gi >= 0 {
		testing.expect_value(t, ls[gi].interrupted_by, "op_now")
		testing.expect(t, !ls[gi].forced && ls[gi].busy.pty_sessions == 2, "interrupt journals the count, not forced")
	}
	if ni >= 0 {
		testing.expect_value(t, ls[ni].state, "noop")
		testing.expect_value(t, ls[ni].note, "superseded_by op_timer")
	}
	idx, _ := read_op_index(join(w.root, "supervisor", "journal", OP_INDEX_FILE), context.temp_allocator)
	testing.expect(t, idx["op_now"].state == "noop", "the update_now op is in the op index")
	testing.expect(t, len(w.fake.stops) == 1 && w.fake.stops[0] == from.tree)
	testing.expect_value(t, finish(&w, "op_timer").state, "committed")
}

@(test)
test_gate_interrupt_refusals_write_nothing :: proc(t: ^testing.T) {
	w: World
	_, to := gate_world(&w, t, "t14-intref")
	defer world_destroy(&w)
	_, err := interrupt(&w.e, "op_now", "app:usr_1")
	testing.expect_value(t, error_code(err), "no_op")
	testing.expect(t, !fatal(err), "no_op is a usage refusal")
	testing.expect_value(t, len(lines_of(&w)), 0)
	// Past the wait (probation): bad_state, the caller coalesces (§10).
	testing.expect(t, begin_verified(&w.e, Activation{"op_up", "update_now", "cli", to}) == nil)
	x, aerr := activate(&w.e)
	testing.expect(t, aerr == nil && x == .Handover)
	handover(&w)
	x, aerr = launch(&w)
	testing.expect(t, aerr == nil && x == .Run && w.e.phase == .Probation)
	n := len(lines_of(&w))
	_, err = interrupt(&w.e, "op_now2", "app:usr_1")
	testing.expect_value(t, error_code(err), "bad_state")
	testing.expect_value(t, len(lines_of(&w)), n)
}

// ---- cancel (J9, J35 target side) ----

@(test)
test_gate_cancel_while_waiting :: proc(t: ^testing.T) {
	w: World
	from, to := gate_world(&w, t, "t14-cancel")
	defer world_destroy(&w)
	w.fake.agents = Busy{pty_sessions = 1}
	x, err := timer_op(&w, "op_timer", to)
	testing.expect(t, err == nil && x == .Run)
	testing.expect_value(t, error_code(cancel_active(&w.e, "op_c", "op_other")), "op_mismatch")
	testing.expect(t, cancel_active(&w.e, "op_c", "op_timer") == nil)
	l := last_of(&w)
	testing.expect(t, l.state == "cancelled" && l.cancelled_by == "op_c", "cancelled with cancelled_by")
	testing.expect(t, w.e.active == nil)
	testing.expect(t, w.fake.admission_open && w.fake.running == from.tree, "work continues untouched")
	testing.expect_value(t, len(w.fake.stops), 0)
	testing.expect_value(t, error_code(cancel_active(&w.e, "op_c2")), "nothing_to_cancel")
	// Nothing resumes after a restart.
	close(&w.e)
	w.open = false
	w.fake.running = ""
	x, err = launch(&w)
	testing.expect(t, err == nil && x == .Run && w.e.active == nil)
	x, err = advance(&w, GATE_WAIT_S + 10)
	testing.expect(t, err == nil && x == .Run && len(w.fake.stops) == 0, "a cancelled wait never forces")
	_ = lc.TARGET
}

@(test)
test_gate_cancel_past_gate_is_refused :: proc(t: ^testing.T) {
	w: World
	_, to := gate_world(&w, t, "t14-cancel2")
	defer world_destroy(&w)
	testing.expect(t, begin_verified(&w.e, Activation{"op_up", "update_now", "cli", to}) == nil)
	x, err := activate(&w.e)
	testing.expect(t, err == nil && x == .Handover)
	handover(&w)
	x, err = launch(&w)
	testing.expect(t, err == nil && x == .Run)
	cerr := cancel_active(&w.e, "op_c")
	testing.expect_value(t, error_code(cerr), "past_point_of_no_return")
	testing.expect(t, !fatal(cerr))
}

// ---- restarts ----

// A supervisor restart (crash or reboot) keeps the journaled force_at: the 2 h are not reset.
@(test)
test_gate_restart_keeps_force_at :: proc(t: ^testing.T) {
	for flavour in Crash_Flavour {
		w: World
		from, to := gate_world(&w, t, "t14-restart")
		w.flavour = flavour
		w.fake.agents = Busy{pty_sessions = 1}
		t0 := w.fake.clock
		x, err := timer_op(&w, "op_timer", to)
		testing.expect(t, err == nil && x == .Run)
		x, err = advance(&w, 1800)
		crash(&w)
		x, err = launch(&w)
		testing.expect(t, err == nil && x == .Run)
		op, has := w.e.active.?
		testing.expectf(t, has && op.state == "waiting_for_idle" && op.force_at == t0 + GATE_WAIT_S, "%v: still waiting with the original force_at", flavour)
		testing.expect_value(t, w.fake.running, from.tree)
		testing.expect(t, w.fake.admission_open, "fresh runtime, admission open")
		rem, _ := status_int(&w, "remaining_s")
		x, err = advance(&w, 5)
		rem, _ = status_int(&w, "remaining_s")
		// Throttled to whole minutes (gate_status_due): within a minute of the exact value.
		exact := i64(GATE_WAIT_S - 1805)
		testing.expectf(t, rem >= exact && rem < exact + 60, "%v: countdown continues (%d)", flavour, rem)
		x, err = advance(&w, t0 + GATE_WAIT_S - w.fake.clock + 5)
		testing.expectf(t, err == nil && x == .Handover, "%v: forced at the original deadline", flavour)
		world_destroy(&w)
	}
}

// An interrupted op that fails before the switch (here stop_timeout) has already answered
// the update_now `noop superseded_by`; the retried timer op must not wait another 2 h.
@(test)
test_gate_interrupt_not_lost_after_failure_before_switch :: proc(t: ^testing.T) {
	w: World
	from, to := gate_world(&w, t, "t14-j30fail")
	defer world_destroy(&w)
	w.fake.agents = Busy{pty_sessions = 2}
	x, err := timer_op(&w, "op_timer", to)
	testing.expect(t, err == nil && x == .Run)
	w.fake.stop_fail_once = from.tree
	x, err = interrupt(&w.e, "op_now", "app:usr_1")
	testing.expect(t, err == nil && x == .Run)
	l := last_of(&w)
	testing.expect(t, l.state == "failed" && l.error == "stop_timeout" && l.interrupted_by == "op_now", "failed before the switch")
	testing.expect_value(t, w.fake.running, from.tree)
	testing.expect(t, begin_verified(&w.e, Activation{"op_t2", "update_now", TIMER_ACTOR, to}) == nil)
	x, err = activate(&w.e)
	testing.expect(t, err == nil)
	testing.expect_value(t, x, Exit.Handover)
	_, waited := find(&w, "op_t2", "waiting_for_idle")
	testing.expect(t, !waited, "the timer op after an interrupted failure does not wait again")
	// Once that op ends, a later timer op gates normally again.
	testing.expect_value(t, finish(&w, "op_t2").state, "committed")
}

// A real J30 crash: the supervisor dies right after the interrupt's lines (gate_closed +
// noop) and before stopping; the restart applies J10 and the next timer op activates at once.
@(test)
test_gate_interrupt_crash_matrix :: proc(t: ^testing.T) {
	crashes, past_switch, waiting_again, j10 := 0, 0, 0, 0
	defer {
		fmt.printfln("t14 interrupt crash matrix: %d crashes (%d past switch, %d still waiting, %d J10)", crashes, past_switch, waiting_again, j10)
		testing.expectf(t, crashes >= 12 && j10 >= 6 && waiting_again >= 1, "matrix too small: %d crashes, %d J10", crashes, j10)
	}
	for mode in Crash_Mode do for k := 1; k < 40; k += 1 {
		w: World
		_, to := gate_world(&w, t, "t14-j30m")
		w.fake.agents = Busy{pty_sessions = 2}
		x, err := timer_op(&w, "op_timer", to)
		testing.expect(t, err == nil && x == .Run)
		w.inj = Injector{crash_at = k, mode = mode}
		x, err = interrupt(&w.e, "op_now", "app:usr_1")
		crashed_now := is_crash(err)
		if !crashed_now {
			world_destroy(&w)
			break
		}
		crashes += 1
		crash(&w)
		x, err = launch(&w)
		if !handle(&w, x, err) {
			x, err = launch(&w)
		}
		testing.expectf(t, w.fake.violations == 0, "%v k=%d: two runtimes", mode, k)
		rec := lc.read_records(w.root)
		if rec.current == to.tree {
			past_switch += 1
			world_destroy(&w)
			continue // past the switch: probation decides (T13 matrix)
		}
		op, has := w.e.active.?
		if has && op.state == "waiting_for_idle" {
			// Crash before gate_closed landed: still waiting; an update_now resent works.
			waiting_again += 1
			x, err = interrupt(&w.e, "op_now", "app:usr_1")
			testing.expectf(t, err == nil && x == .Handover, "%v k=%d: resent interrupt: %v %v", mode, k, x, err)
		} else {
			testing.expectf(t, !has, "%v k=%d: unexpected active op %s/%s", mode, k, op.state, op.sub)
			lt := w.e.last_terminal.?
			if lt.op_id == "op_timer" {
				j10 += 1
				testing.expectf(t, lt.error == "interrupted_before_switch", "%v k=%d: %s %s", mode, k, lt.state, lt.error)
			}
			testing.expect(t, begin_verified(&w.e, Activation{"op_retry", "update_now", TIMER_ACTOR, to}) == nil)
			x, err = activate(&w.e)
			if lt.interrupted_by != "" {
				testing.expectf(t, err == nil && x == .Handover, "%v k=%d: the retried timer op must not wait after an interrupt (%v %v)", mode, k, x, err)
			}
		}
		world_destroy(&w)
	}
}

// Service stop right after gate_closed: the op fails service_stopped and the running
// runtime gets its admission back (no second runtime).
@(test)
test_gate_service_stop_reopens_admission :: proc(t: ^testing.T) {
	w: World
	from, to := gate_world(&w, t, "t14-svcstop")
	defer world_destroy(&w)
	w.fake.agents = Busy{pty_sessions = 1}
	testing.expect(t, begin_verified(&w.e, Activation{"op_u", "update_now", "cli", to}) == nil)
	w.fake.stop_flag = true
	x, err := activate(&w.e)
	testing.expect(t, err == nil && x == .Run)
	l := last_of(&w)
	testing.expect(t, l.state == "failed" && l.error == "service_stopped")
	testing.expect(t, w.fake.admission_open, "admission reopened")
	testing.expect_value(t, w.fake.running, from.tree)
	testing.expect_value(t, w.fake.violations, 0)
}

// Journal members added by T14 round-trip and are covered by the crc.
@(test)
test_gate_journal_members_roundtrip :: proc(t: ^testing.T) {
	l := Line {
		js             = 1,
		seq            = 3,
		ts             = 1800000000,
		op_id          = "op_x",
		action         = "update_now",
		actor          = "timer",
		state          = "activating",
		sub            = "gate_closed",
		force_at       = 1800007200,
		forced         = true,
		busy           = Busy{true, 2, 1, 3},
		interrupted_by = "op_y",
		cancelled_by   = "op_z",
	}
	text := encode_line(l)
	got, ok := decode_line(text[:len(text) - 1], context.temp_allocator)
	testing.expect(t, ok)
	testing.expect(t, got.forced && got.busy == l.busy && got.interrupted_by == "op_y" && got.cancelled_by == "op_z" && got.force_at == l.force_at)
	l.busy = {}
	l.forced = false
	text = encode_line(l)
	got, ok = decode_line(text[:len(text) - 1], context.temp_allocator)
	testing.expect(t, ok && !got.busy.counted && !got.forced, "busy null round-trips")
}

// interrupt_pending is bounded: 15 min after the interrupted failure (or for another tree)
// a timer op waits its 2 h again.
@(test)
test_gate_interrupt_carry_is_bounded :: proc(t: ^testing.T) {
	w: World
	from, to := gate_world(&w, t, "t14-carry")
	defer world_destroy(&w)
	w.fake.agents = Busy{pty_sessions = 2}
	x, err := timer_op(&w, "op_timer", to)
	testing.expect(t, err == nil && x == .Run)
	w.fake.stop_fail_once = from.tree
	x, err = interrupt(&w.e, "op_now", "app:usr_1")
	testing.expect(t, err == nil && x == .Run && last_of(&w).error == "stop_timeout")
	w.fake.clock += INTERRUPT_CARRY_S + 5
	x, err = timer_op(&w, "op_later", to)
	testing.expect(t, err == nil && x == .Run)
	testing.expect_value(t, last_of(&w).state, "waiting_for_idle")
	testing.expect_value(t, len(w.fake.stops), 1) // only the failed attempt's stop
}

// Fails closed: a host without gate hooks makes a timer op wait (not counted), never
// activate at once; it is forced at force_at.
@(test)
test_gate_fails_closed_without_hooks :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t14-closed")
	defer world_destroy(&w)
	from := make_tree(w.root, Tree_Spec{version = "0.6.0", digit = 'a'})
	to := make_tree(w.root, Tree_Spec{version = "0.6.1", digit = 'b'})
	w.fake.behaviour[from.tree] = .Good
	w.fake.behaviour[to.tree] = .Good
	install(&w, from)
	host := fake_host(w.fake)
	host.gate_count = nil
	host.close_admission = nil
	host.open_admission = nil
	testing.expect(t, open(&w.e, world_config(&w), host) == .Run)
	w.open = true
	x, err := start(&w.e, from.tree, .Normal)
	testing.expect(t, err == nil && x == .Run)
	x, err = timer_op(&w, "op_timer", to)
	testing.expect(t, err == nil && x == .Run)
	l := last_of(&w)
	testing.expect(t, l.state == "waiting_for_idle" && !l.busy.counted, "no hooks: wait, busy null")
	x, err = advance(&w, GATE_WAIT_S + 5)
	testing.expect(t, err == nil && x == .Handover, "forced at force_at")
}

// §12 stopping: the runtime is asked to end its sessions after `stopping` is journaled and
// before stop_children's grace and hard stop.
@(test)
test_gate_end_sessions_before_stop :: proc(t: ^testing.T) {
	w: World
	_, to := gate_world(&w, t, "t14-end")
	defer world_destroy(&w)
	w.fake.agents = Busy{pty_sessions = 1}
	x, err := timer_op(&w, "op_timer", to)
	testing.expect(t, err == nil && x == .Run)
	testing.expect_value(t, len(w.fake.ends), 0)
	x, err = advance(&w, GATE_WAIT_S + 5)
	testing.expect(t, err == nil && x == .Handover, "forced")
	testing.expect_value(t, len(w.fake.ends), 1)
	testing.expect_value(t, len(w.fake.stops), 1)
	if len(w.fake.ends) == 1 do testing.expect_value(t, w.fake.ends[0], 0)
	_, has := find(&w, "op_timer", "activating", "stopping")
	testing.expect(t, has, "stopping journaled")
}

// The waiting status file is rewritten only when the count changes or the remaining time
// crosses a minute, not on every tick (7200 synced writes per 2 h wait otherwise).
@(test)
test_gate_waiting_status_is_throttled :: proc(t: ^testing.T) {
	w: World
	_, to := gate_world(&w, t, "t14-throttle")
	defer world_destroy(&w)
	w.fake.agents = Busy{pty_sessions = 1}
	x, err := timer_op(&w, "op_timer", to)
	testing.expect(t, err == nil && x == .Run)
	path := join(w.e.cfg.state_root, "supervisor-status.json")
	// Align to the start of a minute of remaining time, so the next ticks stay in it.
	x, err = advance(&w, 60)
	rem, _ := status_int(&w, "remaining_s")
	testing.expect_value(t, rem, i64(GATE_WAIT_S - 60))
	testing.expect(t, os.remove(path) == nil, "remove status")
	// 50 s in the same minute, same count: no rewrite.
	x, err = advance(&w, 50)
	testing.expect(t, err == nil && x == .Run)
	testing.expect(t, !os.exists(path), "no rewrite within the minute")
	// The count changes: rewritten at once.
	w.fake.agents.helpers = 1
	x, err = advance(&w, 5)
	testing.expect(t, os.exists(path), "rewritten on a count change")
	b, _ := status_obj_busy_total(&w)
	testing.expect_value(t, b, i64(2))
	testing.expect(t, os.remove(path) == nil, "remove status")
	// The remaining time crosses a minute: rewritten.
	x, err = advance(&w, 10)
	testing.expect(t, os.exists(path), "rewritten when the minute changes")
	rem, _ = status_int(&w, "remaining_s")
	testing.expect_value(t, rem, i64(GATE_WAIT_S - 120))
}
