package shell_session

// REQ-SHELL-4 service-level acceptance tests — the HUB half of "exit status must
// reach the hub reliably, including across a bridge restart".
//
// The bridge half (a durable outbox that survives the process going away) is
// asserted in src/bridge/shell_exited_outbox_test.odin. What is asserted HERE is
// the property that makes a durable, at-least-once outbox safe to have at all:
// applying the same exit twice, or applying a stale one late, must not corrupt the
// row.
//
//   AC2  the SAME shell_exited delivered twice changes nothing the second time
//   AC3  a shell_exited for an ALREADY-TERMINAL session does not change its status
//   AC5  a shell_exited naming ANOTHER BRIDGE's session is still ignored (the
//        regression guard on the scoping check REQ-SHELL-4 §5 says to keep)
//   A1   …with ONE exception: a bridge-reported exit supersedes a hub-SYNTHESIZED
//        terminal status exactly once, because a guess must not outrank an
//        observation (REQ-SHELL-14's sweep is the guess in question)
//
// WHY THE ASSERTIONS COUNT WRITES rather than inspecting an event bus: the publish
// in shell_session_handle_exited sits behind the same early return as the upsert, so
// "no second write" and "no second fan-out" are the same branch. events.User_Event_Bus
// publishes to real TCP sockets and cannot be faked here without testing the socket
// layer instead of the decision, so the write count is the honest proxy — and it is
// the stronger half, since a duplicated DB write is the part that corrupts state.

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"

// --- fake repository ---------------------------------------------------------
//
// Deliberately PERMISSIVE about statuses — it stores whatever it is handed. The
// decisions under test all belong to the service, so a repository that enforced
// them would hide a wrong decision behind a right storage layer.

@(private = "file")
Repo4 :: struct {
	stored: map[string]domain.Shell_Session,
	writes: int,
}

@(private = "file")
r4_upsert :: proc(ctx: rawptr, session: domain.Shell_Session) -> (bool, domain.Domain_Error) {
	r := (^Repo4)(ctx)
	r.writes += 1
	r.stored[session.session_id] = session
	return true, domain.Domain_Error{}
}

@(private = "file")
r4_get :: proc(ctx: rawptr, owner_user_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	r := (^Repo4)(ctx)
	s, had := r.stored[session_id]
	if !had || s.owner_user_id != owner_user_id do return domain.Shell_Session{}, false, domain.Domain_Error{}
	return s, true, domain.Domain_Error{}
}

// r4_get_by_id mirrors the real repository's key: (bridge_id, session_id). Getting
// this wrong in the fake would make AC5 pass for the wrong reason — the lookup would
// miss instead of the scoping check rejecting — so the fake resolves within the
// reporting bridge exactly as the SQL does.
@(private = "file")
r4_get_by_id :: proc(ctx: rawptr, bridge_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	r := (^Repo4)(ctx)
	s, had := r.stored[session_id]
	if !had || s.bridge_id != bridge_id do return domain.Shell_Session{}, false, domain.Domain_Error{}
	return s, true, domain.Domain_Error{}
}

@(private = "file")
r4_find_live_by_port :: proc(ctx: rawptr, bridge_id: string, server_port: int) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	return domain.Shell_Session{}, false, domain.Domain_Error{}
}

@(private = "file")
r4_count_live :: proc(ctx: rawptr, owner_user_id, kind, scope_column, scope_value: string) -> (int, domain.Domain_Error) {
	return 0, domain.Domain_Error{}
}

// --- fixture -----------------------------------------------------------------

@(private = "file")
Fx4 :: struct {
	svc:  Shell_Session_Service,
	repo: iface.Shell_Session_Repository,
	r:    Repo4,
	ids:  platform.ID_Generator,
	clk:  platform.Clock,
}

// A fixed, LATER clock than any seeded timestamp, so "finished_at moved" is
// detectable: if a second application wrote the row, finished_at would become this.
@(private = "file")
now4 :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-09-28T12:00:00Z" }

@(private = "file")
fx4_make :: proc(fx: ^Fx4) {
	fx.r.stored = make(map[string]domain.Shell_Session)
	fx.repo = iface.Shell_Session_Repository{
		ctx               = rawptr(&fx.r),
		upsert            = r4_upsert,
		get               = r4_get,
		get_by_id         = r4_get_by_id,
		find_live_by_port = r4_find_live_by_port,
		count_live        = r4_count_live,
	}
	fx.ids = platform.real_id_generator()
	fx.clk = platform.Clock{ctx = nil, now = now4}
	fx.svc = new_shell_session_service(
		repo                = &fx.repo,
		bridge_command_sink = project_service.Bridge_Command_Sink{},
		ids                 = &fx.ids,
		clock               = &fx.clk,
	)
	// events stays nil: the publish is behind the same return as the upsert (see the
	// file header), and a real bus would need live sockets.
}

@(private = "file")
fx4_free :: proc(fx: ^Fx4) {
	shell_session_service_free(&fx.svc)
	delete(fx.r.stored)
}

@(private = "file")
fx4_seed :: proc(
	fx: ^Fx4,
	session_id := "sh_1",
	status := domain.Shell_Session_Status_Running,
	bridge_id := "brg_1",
	exit_code := 0,
	exit_code_set := false,
	run_seq := 0,
) {
	fx.r.stored[session_id] = domain.Shell_Session{
		session_id    = session_id,
		owner_user_id = "owner_a",
		bridge_id     = bridge_id,
		kind          = domain.Shell_Session_Kind_Run,
		cmd           = "sleep 1",
		status        = status,
		exit_code     = exit_code,
		exit_code_set = exit_code_set,
		run_seq       = run_seq,
		started_at    = "2026-09-28T09:00:00Z",
		finished_at   = "2026-09-28T09:30:00Z" if domain.shell_session_status_is_terminal(status) else "",
	}
	fx.r.writes = 0 // seeding is not a write under test
}

// --- baseline: the first exit DOES apply --------------------------------------
//
// Stated as its own test so the three "nothing happened" assertions below cannot
// pass vacuously — a handle_exited that returned unconditionally would satisfy AC2,
// AC3 and AC5 and break the feature entirely.

@(test)
test_req4_first_exit_applies :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	fx4_seed(&fx)

	shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Exited, 7, true)

	stored := fx.r.stored["sh_1"]
	testing.expect_value(t, fx.r.writes, 1)
	testing.expect_value(t, stored.status, domain.Shell_Session_Status_Exited)
	testing.expect_value(t, stored.exit_code, 7)
	testing.expect(t, stored.exit_code_set, "the exit code the bridge observed must be recorded")
	testing.expect_value(t, stored.finished_at, "2026-09-28T12:00:00Z")
}

// --- AC2: the same exit delivered TWICE is a no-op the second time -------------
//
// This is the property the bridge's at-least-once outbox depends on. The outbox
// removes an exit's envelope only AFTER the frame is sent, so a bridge that dies in
// that window replays the exit on its next boot. Before this guard the replay wrote
// the row again and published a SECOND exit event to the owner — one process ending
// announced twice.

@(test)
test_req4_duplicate_exit_is_a_no_op :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	fx4_seed(&fx)

	shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Exited, 7, true)
	first := fx.r.stored["sh_1"]
	testing.expect_value(t, fx.r.writes, 1)

	// Byte-identical redelivery — exactly what a replayed envelope is.
	shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Exited, 7, true)

	testing.expect_value(t, fx.r.writes, 1)
	second := fx.r.stored["sh_1"]
	testing.expect_value(t, second.status, first.status)
	testing.expect_value(t, second.exit_code, first.exit_code)
	testing.expect_value(t, second.finished_at, first.finished_at)
}

// --- AC3: a LATE exit must not overwrite a more accurate terminal status --------
//
// Order is not guaranteed across a bridge restart, and this is the case where that
// costs something real. The user killed the session, so the row is `killed` with the
// code the bridge reported. A stale `exited` replayed from the restarted bridge's
// outbox would downgrade that to `exited`, overwrite the exit code, and slide
// finished_at forward to the moment of the replay — the row would claim the process
// ended half an hour later than it did.

@(test)
test_req4_late_exit_does_not_overwrite_terminal_status :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	fx4_seed(&fx, status = domain.Shell_Session_Status_Killed, exit_code = 137, exit_code_set = true)

	shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Exited, 0, true)

	testing.expect_value(t, fx.r.writes, 0)
	stored := fx.r.stored["sh_1"]
	testing.expect_value(t, stored.status, domain.Shell_Session_Status_Killed)
	testing.expect_value(t, stored.exit_code, 137)
	testing.expect_value(t, stored.finished_at, "2026-09-28T09:30:00Z")
}

// A `failed` row is terminal for the same reason and gets the same treatment —
// asserted separately because SHELL_SESSION_TERMINAL_STATUSES has three members and
// a guard written against one status spelling would pass the test above.
@(test)
test_req4_late_exit_does_not_overwrite_failed :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	fx4_seed(&fx, status = domain.Shell_Session_Status_Failed, exit_code = 1, exit_code_set = true)

	shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Exited, 0, true)

	testing.expect_value(t, fx.r.writes, 0)
	testing.expect_value(t, fx.r.stored["sh_1"].status, domain.Shell_Session_Status_Failed)
}

// --- A1: a bridge-reported exit SUPERSEDES a hub-synthesized terminal status ----
//
// The exception to AC3, and the reason it is not a hole in it. REQ-SHELL-14 lands a
// terminal status on the sessions of a bridge judged never to be coming back. That
// is a guess made without watching any process end — it carries no exit code,
// because the hub has none to record. If that bridge DOES come back (which a durable
// outbox makes considerably more likely — that is this task), a flat
// first-terminal-wins would discard the genuine exit and leave the guess standing
// forever, with the user unable to ever learn the real exit code.
//
// Knowledge beats a guess. The discriminator is domain.shell_session_terminal_is_observed.

@(test)
test_req4_bridge_exit_supersedes_synthesized_terminal :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	// The shape REQ-SHELL-14's sweep leaves behind: terminal, but no observed code.
	fx4_seed(&fx, status = domain.Shell_Session_Status_Failed, exit_code_set = false)
	testing.expect(
		t,
		!domain.shell_session_terminal_is_observed(fx.r.stored["sh_1"]),
		"precondition: a synthesized terminal status carries no observed exit code",
	)

	shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Exited, 3, true)

	testing.expect_value(t, fx.r.writes, 1)
	stored := fx.r.stored["sh_1"]
	testing.expect_value(t, stored.status, domain.Shell_Session_Status_Exited)
	testing.expect_value(t, stored.exit_code, 3)
	testing.expect(t, stored.exit_code_set, "the real exit code must replace the guess")
}

// EXACTLY ONCE, and structurally rather than by a counter: superseding requires the
// INCOMING event to be observed, and applying it makes the ROW observed — so the
// next delivery takes the first-writer-wins branch. Without this the supersession
// would be a standing exemption, and two bridges (or one replaying bridge) could
// keep rewriting a terminal row indefinitely.
@(test)
test_req4_supersession_happens_only_once :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	fx4_seed(&fx, status = domain.Shell_Session_Status_Failed, exit_code_set = false)

	shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Exited, 3, true)
	testing.expect_value(t, fx.r.writes, 1)

	// A different, later bridge report. AC3 applies now — the row is observed.
	shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Killed, 137, true)

	testing.expect_value(t, fx.r.writes, 1)
	stored := fx.r.stored["sh_1"]
	testing.expect_value(t, stored.status, domain.Shell_Session_Status_Exited)
	testing.expect_value(t, stored.exit_code, 3)
}

// The other half of "exactly once": an UNOBSERVED incoming event cannot supersede a
// synthesized terminal either. Two guesses about the same session do not add up to
// knowledge, and letting one overwrite the other would flip the row's status on
// every delivery with nothing ever settling it.
@(test)
test_req4_unobserved_exit_does_not_supersede_synthesized_terminal :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	fx4_seed(&fx, status = domain.Shell_Session_Status_Failed, exit_code_set = false)

	shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Exited, 0, false)

	testing.expect_value(t, fx.r.writes, 0)
	testing.expect_value(t, fx.r.stored["sh_1"].status, domain.Shell_Session_Status_Failed)
}

// --- AC5: BRIDGE SCOPING regression guard --------------------------------------
//
// REQ-SHELL-4 §5 says to keep this check, and it is the only thing stopping any
// connected bridge from terminating any user's session record by emitting a
// shell_exited with that session_id. It is load-bearing precisely BECAUSE of the
// REQ-RECON-5 fallback above it: session_owners used to make cross-bridge reports
// unreachable by accident, and the by-id fallback removed that accident.
//
// No edit was made here — this test exists so that removing the check fails a test
// with AC5's name on it rather than passing silently.

@(test)
test_req4_exit_from_another_bridge_is_ignored :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	fx4_seed(&fx, bridge_id = "brg_owner")

	// brg_attacker reports an exit for a session that lives on brg_owner.
	shell_session_handle_exited(&fx.svc, "sh_1", "brg_attacker", domain.Shell_Session_Status_Killed, 137, true)

	testing.expect_value(t, fx.r.writes, 0)
	stored := fx.r.stored["sh_1"]
	testing.expect_value(t, stored.status, domain.Shell_Session_Status_Running)
	testing.expect_value(t, stored.finished_at, "")
	testing.expect(t, !stored.exit_code_set, "a foreign bridge must not be able to stamp an exit code")
}

// The same guard must hold on the REQ-RECON-5 fallback path specifically, i.e. when
// the session is NOT in the in-memory session_owners map. That is the path the
// comment in shell_session_handle_exited calls out as the one that would otherwise
// let any bridge terminate any session — and it is the ONLY path exercised by these
// tests, since nothing here populates session_owners. Asserted explicitly so the
// coverage is a stated fact rather than an accident of the fixture.
@(test)
test_req4_foreign_bridge_cannot_resolve_via_the_by_id_fallback :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	fx4_seed(&fx, bridge_id = "brg_owner")

	// Prove the precondition rather than assuming it: the owner map is empty, so the
	// lookup below can only go through shell_session_get_by_id.
	testing.expect_value(t, len(fx.svc.session_owners), 0)

	shell_session_handle_exited(&fx.svc, "sh_1", "brg_attacker", domain.Shell_Session_Status_Exited, 0, true)
	testing.expect_value(t, fx.r.writes, 0)

	// …and the owning bridge, on that same fallback path, still works. Without this
	// the test above would pass just as well against a fallback that was broken
	// outright, which would "fix" AC5 by breaking the convergence AC1 needs.
	shell_session_handle_exited(&fx.svc, "sh_1", "brg_owner", domain.Shell_Session_Status_Exited, 0, true)
	testing.expect_value(t, fx.r.writes, 1)
	testing.expect_value(t, fx.r.stored["sh_1"].status, domain.Shell_Session_Status_Exited)
}

// --- an unknown session is ignored without writing anything --------------------
//
// AC4's hub-side counterpart. The bridge's outbox bound eventually DISCARDS an exit
// whose session no longer exists hub-side; until it does, that exit is re-sent on
// every reconnect, so the hub must absorb it silently rather than resurrecting a
// row from an event.
@(test)
test_req4_exit_for_unknown_session_writes_nothing :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)

	shell_session_handle_exited(&fx.svc, "sh_gone", "brg_1", domain.Shell_Session_Status_Exited, 0, true)

	testing.expect_value(t, fx.r.writes, 0)
	testing.expect_value(t, len(fx.r.stored), 0)
	_ = strings.trim_space("")
}

// --- run identity: a STALE run's exit must not terminate a LIVE session ---------
//
// The hazard a durable outbox introduces, and the one this half of the task exists
// to close. A session_id is not a run: shell_session_restart re-spawns under the
// same session_id. So run 0 exits while the bridge is offline and its exit is queued
// on the bridge's disk; the session is restarted (run 1) and is genuinely alive; the
// bridge reconnects and delivers run 0's exit. Applying it marks a LIVE session
// terminal — the "hub says terminal, bridge says running" divergence this chain
// exists to eliminate, manufactured by the durability mechanism itself.

// THE ACCEPTANCE TEST, and it asserts the DISCARD SPECIFICALLY rather than merely
// that the row ended up Running — a handler that ignored the event for any unrelated
// reason (wrong bridge, missing row, a bug that dropped every exit) would leave the
// row Running too. Pinning writes == 0, the return value == false, and every field
// unchanged is what makes it a test of the run comparison and not of the outcome.
@(test)
test_req4_stale_run_exit_does_not_terminate_a_restarted_session :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	// The session has been restarted once and is LIVE on run 1.
	fx4_seed(&fx, status = domain.Shell_Session_Status_Running, run_seq = 1)

	// Run 0's exit, replayed from the bridge's durable outbox after a restart.
	applied := shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Exited, 0, true, 0)

	testing.expect(t, !applied, "a stale run's exit must be reported as NOT applied")
	testing.expect_value(t, fx.r.writes, 0)
	stored := fx.r.stored["sh_1"]
	testing.expect_value(t, stored.status, domain.Shell_Session_Status_Running)
	testing.expect_value(t, stored.finished_at, "")
	testing.expect_value(t, stored.run_seq, 1)
	testing.expect(t, !stored.exit_code_set, "a stale exit must not stamp an exit code on a live run")
}

// The CURRENT run's exit still applies, on a session that has been restarted. Without
// this the test above could pass against a handler that discarded every exit for any
// restarted session, which would strand every such session as running forever — a
// worse bug than the one being fixed.
@(test)
test_req4_current_run_exit_applies_after_a_restart :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	fx4_seed(&fx, status = domain.Shell_Session_Status_Running, run_seq = 1)

	applied := shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Exited, 5, true, 1)

	testing.expect(t, applied)
	testing.expect_value(t, fx.r.writes, 1)
	testing.expect_value(t, fx.r.stored["sh_1"].status, domain.Shell_Session_Status_Exited)
	testing.expect_value(t, fx.r.stored["sh_1"].exit_code, 5)
}

// A report from a bridge that is AHEAD of the row applies. This is the crash window
// in shell_session_restart: the bridge respawned successfully and adopted run 1, and
// the hub died before its own upsert, so the row still says 0. The bridge's reports
// are about a run at least as current as the one the row knows about, and discarding
// them would strand the session as running forever — so the comparison is STRICTLY
// LESS THAN, not "not equal".
@(test)
test_req4_exit_from_a_bridge_ahead_of_the_row_applies :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	fx4_seed(&fx, status = domain.Shell_Session_Status_Running, run_seq = 0)

	applied := shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Exited, 0, true, 1)

	testing.expect(t, applied, "a bridge AHEAD of the row means the hub lost a write, not that the exit is stale")
	testing.expect_value(t, fx.r.writes, 1)
	testing.expect_value(t, fx.r.stored["sh_1"].status, domain.Shell_Session_Status_Exited)
}

// A report that names no run applies. It cannot be SHOWN to be stale, and the safe
// direction for an unprovable claim is to converge rather than leave a row live
// forever. Asserted on a session with a non-zero run_seq, because the bug this
// guards against is spelling "unstated" as 0 — which would make every unstamped
// report look like run 0 and be discarded for any session ever restarted.
@(test)
test_req4_exit_without_a_run_seq_applies :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	fx4_seed(&fx, status = domain.Shell_Session_Status_Running, run_seq = 3)

	testing.expect(t, SHELL_SESSION_RUN_SEQ_UNSTATED != 0, "UNSTATED must not collide with run 0")

	applied := shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Exited, 0, true, SHELL_SESSION_RUN_SEQ_UNSTATED)

	testing.expect(t, applied)
	testing.expect_value(t, fx.r.writes, 1)
	testing.expect_value(t, fx.r.stored["sh_1"].status, domain.Shell_Session_Status_Exited)
	// The row keeps its own run number: an unstamped report says nothing about which
	// run is current, so it must not be allowed to move the counter.
	testing.expect_value(t, fx.r.stored["sh_1"].run_seq, 3)
}

// The run check runs BEFORE the terminal/idempotency guard, so a stale exit is
// discarded whatever state the row is in. Stated as its own test because the two
// guards are independent and a reordering that let a stale exit reach the
// supersession branch would let a previous run's exit overwrite a synthesized
// terminal status with the WRONG run's exit code.
@(test)
test_req4_stale_run_exit_cannot_supersede_a_synthesized_terminal :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	fx4_seed(&fx, status = domain.Shell_Session_Status_Failed, exit_code_set = false, run_seq = 2)

	applied := shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Exited, 9, true, 1)

	testing.expect(t, !applied)
	testing.expect_value(t, fx.r.writes, 0)
	testing.expect(t, !fx.r.stored["sh_1"].exit_code_set, "a previous run's exit code must not become this row's")
}
