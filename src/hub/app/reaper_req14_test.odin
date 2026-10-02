package app

// REQ-SHELL-14 sweep tests — the JUDGEMENT half: blip vs gone for good.
//
// Split from the row-level tests in
// src/hub/service/shell_session/shell_session_req14_test.odin deliberately. That file
// proves WHAT happens once a bridge is judged gone; this one proves WHICH bridges are
// judged gone, which is where the destructive failure mode lives. Three call sites in
// this codebase choose CONVERT-NOT-KILL on a WS drop because a drop is usually a
// transient blip with the child processes alive, so the regression that matters most
// here is not "does a dead bridge get reaped" but "does a bridge that merely blinked get
// left alone".
//
//   t14_blip_leaves_rows_live         a bridge seen 2 minutes ago: rows UNCHANGED
//   t14_gone_bridge_is_swept          a bridge seen 3 hours ago: rows terminal
//   t14_threshold_boundary            59m no, exactly 60m yes, 61m yes
//   t14_unreadable_or_future_last_seen_is_never_gone
//   t14_revoked_bridge_is_not_aged_out
//   t14_healthy_bridge_is_untouched_by_its_neighbours_absence
//
// The fake repositories mirror the real ones' OWNERSHIP, not just their logic: both
// return deep clones, because bridge_absence_marker calls domain.bridge_destroy on what
// it read and the reap calls domain.shell_sessions_destroy on its rows. A fake handing
// back its own pointers would turn that correct freeing into a bad free and would be
// testing an ownership rule the sqlite repositories do not have.

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import agent_service "odin_test:hub/service/agent"
import bridge_service "odin_test:hub/service/bridge"
import shell_session_svc "odin_test:hub/service/shell_session"

// --- time helpers ------------------------------------------------------------

// R14_NOW is when the sweep runs. Absence is expressed by seeding last_seen_at earlier
// on the same day, so every offset below is readable as plain wall-clock arithmetic
// rather than as an epoch computation.
@(private = "file")
R14_NOW :: "2026-09-28T12:00:00Z"

// r14_now_ms is R14_NOW in unix ms, via the SAME parser the sweep uses, so a test that
// asserts a boundary cannot drift from the code by parsing the timestamp differently.
@(private = "file")
r14_now_ms :: proc() -> (i64, bool) { return agent_service.rfc3339_to_unix_ms(R14_NOW) }

@(private = "file")
r14_now_proc :: proc(ctx: rawptr) -> string { _ = ctx; return strings.clone(R14_NOW) }

// --- fake bridge repository --------------------------------------------------

@(private = "file")
BRepo14 :: struct {
	bridges: map[string]domain.Bridge,
	reads:   int,
}

@(private = "file")
b14_clone :: proc(b: domain.Bridge) -> domain.Bridge {
	out := b
	out.bridge_id         = strings.clone(b.bridge_id)
	out.owner_user_id     = domain.User_ID(strings.clone(string(b.owner_user_id)))
	out.label             = strings.clone(b.label)
	out.machine_hostname  = strings.clone(b.machine_hostname)
	out.machine_os        = strings.clone(b.machine_os)
	out.machine_arch      = strings.clone(b.machine_arch)
	out.capabilities_json = strings.clone(b.capabilities_json)
	out.hub_url           = strings.clone(b.hub_url)
	out.bridge_token_hash = strings.clone(b.bridge_token_hash)
	out.created_at        = strings.clone(b.created_at)
	out.updated_at        = strings.clone(b.updated_at)
	out.last_seen_at      = strings.clone(b.last_seen_at)
	out.revoked_at        = strings.clone(b.revoked_at)
	out.telemetry_enabled = strings.clone(b.telemetry_enabled)
	return out
}

// Returns an OWNED clone, like the sqlite row reader: bridge_absence_marker destroys
// what it read, and it must not be destroying the fake's own storage.
@(private = "file")
b14_get :: proc(ctx: rawptr, bridge_id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	r := (^BRepo14)(ctx)
	r.reads += 1
	if b, had := r.bridges[bridge_id]; had do return b14_clone(b), true, domain.Domain_Error{}
	return domain.Bridge{}, false, domain.Domain_Error{}
}

// --- fake shell session repository -------------------------------------------

@(private = "file")
SRepo14 :: struct {
	stored: map[string]domain.Shell_Session, // "<bridge_id>\x00<session_id>" -> row
}

@(private = "file")
s14_key :: proc(bridge_id, session_id: string) -> string {
	return strings.concatenate({bridge_id, "\x00", session_id}, context.temp_allocator)
}

@(private = "file")
s14_clone :: proc(s: domain.Shell_Session) -> domain.Shell_Session {
	out := s
	out.session_id        = strings.clone(s.session_id)
	out.owner_user_id     = strings.clone(s.owner_user_id)
	out.bridge_id         = strings.clone(s.bridge_id)
	out.project_id        = strings.clone(s.project_id)
	out.chain_id          = strings.clone(s.chain_id)
	out.agent_instance_id = strings.clone(s.agent_instance_id)
	out.kind              = strings.clone(s.kind)
	out.conversation_id   = strings.clone(s.conversation_id)
	out.label             = strings.clone(s.label)
	out.cmd               = strings.clone(s.cmd)
	out.cwd               = strings.clone(s.cwd)
	out.status            = strings.clone(s.status)
	out.kill_requested_at = strings.clone(s.kill_requested_at)
	out.started_at        = strings.clone(s.started_at)
	out.finished_at       = strings.clone(s.finished_at)
	out.created_at        = strings.clone(s.created_at)
	out.last_activity_at  = strings.clone(s.last_activity_at)
	return out
}

@(private = "file")
s14_upsert :: proc(ctx: rawptr, session: domain.Shell_Session) -> (bool, domain.Domain_Error) {
	r := (^SRepo14)(ctx)
	key := s14_key(session.bridge_id, session.session_id)
	next := s14_clone(session)
	if prev, had := r.stored[key]; had {
		// The real upsert's REQ-SHELL-3 CASE: any terminal status clears a pending kill.
		if domain.shell_session_status_is_terminal(session.status) {
			delete(next.kill_requested_at)
			next.kill_requested_at = strings.clone("")
		}
		domain.shell_session_destroy(prev)
		r.stored[key] = next
	} else {
		r.stored[strings.clone(key)] = next
	}
	return true, domain.Domain_Error{}
}

@(private = "file")
s14_list_live_by_bridge :: proc(ctx: rawptr, bridge_id: string, limit: int) -> ([dynamic]domain.Shell_Session, domain.Domain_Error) {
	r := (^SRepo14)(ctx)
	out := make([dynamic]domain.Shell_Session)
	for _, s in r.stored {
		if s.bridge_id != bridge_id do continue
		if domain.shell_session_is_terminal(s) do continue
		append(&out, s14_clone(s))
	}
	return out, domain.Domain_Error{}
}

// The candidate listing the sweep drives: DISTINCT bridges holding at least one live
// row. Same "live" rule as the listing above, so the fake cannot disagree with itself
// about which bridges are candidates.
@(private = "file")
s14_list_live_bridge_ids :: proc(ctx: rawptr, limit: int) -> ([dynamic]string, domain.Domain_Error) {
	r := (^SRepo14)(ctx)
	out := make([dynamic]string)
	for _, s in r.stored {
		if s.bridge_id == "" do continue
		if domain.shell_session_is_terminal(s) do continue
		seen := false
		for id in out {
			if id == s.bridge_id { seen = true; break }
		}
		if !seen do append(&out, strings.clone(s.bridge_id))
	}
	return out, domain.Domain_Error{}
}

// --- fixture -----------------------------------------------------------------

@(private = "file")
Fx :: struct {
	bridges:  bridge_service.Bridge_Service,
	sessions: shell_session_svc.Shell_Session_Service,
	brepo:    iface.Bridge_Repository,
	srepo:    iface.Shell_Session_Repository,
	b:        BRepo14,
	s:        SRepo14,
	ids:      platform.ID_Generator,
	clk:      platform.Clock,
}

@(private = "file")
fx_make :: proc(fx: ^Fx) {
	fx.b.bridges = make(map[string]domain.Bridge)
	fx.s.stored = make(map[string]domain.Shell_Session)
	fx.brepo = iface.Bridge_Repository{ctx = rawptr(&fx.b), get_bridge = b14_get}
	fx.srepo = iface.Shell_Session_Repository{
		ctx                  = rawptr(&fx.s),
		upsert               = s14_upsert,
		list_live_by_bridge  = s14_list_live_by_bridge,
		list_live_bridge_ids = s14_list_live_bridge_ids,
	}
	fx.ids = platform.real_id_generator()
	fx.clk = platform.Clock{ctx = nil, now = r14_now_proc}
	fx.bridges = bridge_service.Bridge_Service{repo = &fx.brepo, clock = &fx.clk, ids = &fx.ids}
	fx.sessions = shell_session_svc.new_shell_session_service(repo = &fx.srepo, ids = &fx.ids, clock = &fx.clk)
}

@(private = "file")
fx_free :: proc(fx: ^Fx) {
	shell_session_svc.shell_session_service_free(&fx.sessions)
	// Keys as well as values: fx_bridge clones the id for the key, exactly as fx_session
	// does, so both maps have to be drained the same way.
	for k, b in fx.b.bridges { delete(k); bb := b; domain.bridge_destroy(&bb) }
	delete(fx.b.bridges)
	for k, s in fx.s.stored { delete(k); domain.shell_session_destroy(s) }
	delete(fx.s.stored)
}

@(private = "file")
fx_bridge :: proc(fx: ^Fx, bridge_id, last_seen_at: string, status := domain.Bridge_Status.Offline) {
	fx.b.bridges[strings.clone(bridge_id)] = b14_clone(domain.Bridge{
		bridge_id = bridge_id, owner_user_id = domain.User_ID("owner_a"),
		status = status, last_seen_at = last_seen_at,
	})
}

@(private = "file")
fx_session :: proc(fx: ^Fx, session_id, bridge_id: string, kill_at := "") {
	fx.s.stored[strings.clone(s14_key(bridge_id, session_id))] = s14_clone(domain.Shell_Session{
		session_id = session_id, owner_user_id = "owner_a", bridge_id = bridge_id,
		kind = domain.Shell_Session_Kind_Shell, cmd = "zsh",
		status = domain.Shell_Session_Status_Running,
		kill_requested_at = kill_at, started_at = "2026-09-28T09:00:00Z",
	})
}

@(private = "file")
fx_row :: proc(fx: ^Fx, session_id, bridge_id: string) -> (domain.Shell_Session, bool) {
	s, had := fx.s.stored[s14_key(bridge_id, session_id)]
	return s, had
}

@(private = "file")
fx_sweep :: proc(fx: ^Fx) -> int {
	return reaper_reap_gone_bridges(&fx.bridges, &fx.sessions, R14_NOW)
}

// --- tests -------------------------------------------------------------------

// THE REGRESSION THAT MATTERS MOST. A bridge whose WS dropped two minutes ago is a blip,
// not a corpse: its child processes are almost certainly fine, and the three
// convert-not-kill call sites exist precisely because killing here destroys in-flight
// work — a 20-minute build ended by a network hiccup. Two minutes is also comfortably
// past REAPER_STALE_MS (90s), so this asserts the thing that makes REQ-SHELL-14 different
// from the liveness reap rather than merely a shorter version of it: being unreachable is
// NOT being gone.
@(test)
t14_blip_leaves_rows_live :: proc(t: ^testing.T) {
	fx: Fx; fx_make(&fx); defer fx_free(&fx)
	fx_bridge(&fx, "brg_blip", "2026-09-28T11:58:00Z") // 2 minutes ago
	fx_session(&fx, "sh_1", "brg_blip")

	testing.expect_value(t, fx_sweep(&fx), 0)

	row, had := fx_row(&fx, "sh_1", "brg_blip")
	testing.expect(t, had, "row must still exist")
	testing.expect_value(t, row.status, domain.Shell_Session_Status_Running)
	testing.expect_value(t, row.finished_at, "")
}

// The hole this task exists to close: no reconnect ever happens, so nothing else in the
// hub can land a terminal status, and without this sweep the row reports live forever.
@(test)
t14_gone_bridge_is_swept :: proc(t: ^testing.T) {
	fx: Fx; fx_make(&fx); defer fx_free(&fx)
	fx_bridge(&fx, "brg_gone", "2026-09-28T09:00:00Z") // 3 hours ago
	// A kill requested while the bridge was already silent. On a bridge that never
	// returns this sweep is the ONLY thing that can land a terminal status, so it is also
	// the only thing that can ever retire the intent through REQ-SHELL-3's auto-clear.
	fx_session(&fx, "sh_1", "brg_gone", "2026-09-28T10:00:00Z")

	testing.expect_value(t, fx_sweep(&fx), 1)

	row, _ := fx_row(&fx, "sh_1", "brg_gone")
	testing.expect_value(t, row.status, shell_session_svc.SHELL_SESSION_INVENTORY_UNOBSERVED_TERMINAL)
	testing.expect(t, domain.shell_session_status_is_terminal(row.status), "must be in the terminal set")
	testing.expect_value(t, row.finished_at, R14_NOW)
	testing.expect_value(t, row.kill_requested_at, "")
	testing.expect(t, !row.exit_code_set, "nothing was observed, so no exit code may be claimed")
}

// The boundary itself, asserted on the pure predicate so it needs no repository: the
// acceptance criterion is a threshold, and a threshold is only meaningfully tested at its
// edge. >= is the comparison, so exactly one hour is gone.
@(test)
t14_threshold_boundary :: proc(t: ^testing.T) {
	now_ms, ok := r14_now_ms()
	testing.expect(t, ok, "the fixture's own timestamp must parse")

	testing.expect(t, !reaper_bridge_absence_is_terminal(now_ms, "2026-09-28T11:01:00Z"), "59m is a blip")
	testing.expect(t,  reaper_bridge_absence_is_terminal(now_ms, "2026-09-28T11:00:00Z"), "exactly 60m is gone")
	testing.expect(t,  reaper_bridge_absence_is_terminal(now_ms, "2026-09-28T10:59:00Z"), "61m is gone")
	// Sanity on the intent of the constant: the liveness threshold must NOT be enough.
	testing.expect(t, !reaper_bridge_absence_is_terminal(now_ms, "2026-09-28T11:58:00Z"), "REAPER_STALE_MS-scale absence is not gone")
}

// Both directions of "we cannot tell" resolve to NOT GONE, because the cost of being
// wrong is asymmetric: guessing "gone" from a timestamp we could not read, or from a
// clock skewed into the future, marks live sessions failed, which is the one direction
// this design must never take by accident.
@(test)
t14_unreadable_or_future_last_seen_is_never_gone :: proc(t: ^testing.T) {
	now_ms, _ := r14_now_ms()
	testing.expect(t, !reaper_bridge_absence_is_terminal(now_ms, ""), "empty is not evidence of absence")
	testing.expect(t, !reaper_bridge_absence_is_terminal(now_ms, "not-a-timestamp"), "garbage is not evidence of absence")
	testing.expect(t, !reaper_bridge_absence_is_terminal(now_ms, "2026-09-29T12:00:00Z"), "clock skew must not manufacture absence")

	// And a bridge with no last_seen_at at all is skipped before the age test is reached.
	fx: Fx; fx_make(&fx); defer fx_free(&fx)
	fx_bridge(&fx, "brg_never_seen", "")
	fx_session(&fx, "sh_1", "brg_never_seen")
	testing.expect_value(t, fx_sweep(&fx), 0)
	row, _ := fx_row(&fx, "sh_1", "brg_never_seen")
	testing.expect_value(t, row.status, domain.Shell_Session_Status_Running)
}

// A REVOKED bridge is an administrative end, not an absence: the decision has already
// been taken and acted on elsewhere. Aging it out here would be a second mechanism
// racing that decision, so revocation is excluded from the age test entirely rather than
// merely arriving at the same answer by a different route.
@(test)
t14_revoked_bridge_is_not_aged_out :: proc(t: ^testing.T) {
	fx: Fx; fx_make(&fx); defer fx_free(&fx)
	fx_bridge(&fx, "brg_revoked", "2026-09-28T09:00:00Z", domain.Bridge_Status.Revoked)
	fx_session(&fx, "sh_1", "brg_revoked")

	testing.expect_value(t, fx_sweep(&fx), 0)
	row, _ := fx_row(&fx, "sh_1", "brg_revoked")
	testing.expect_value(t, row.status, domain.Shell_Session_Status_Running)
}

// The sweep is host-wide and owner-unscoped, so it must discriminate per bridge: one
// bridge's absence cannot end another's sessions, and a bridge unknown to the repository
// must not be treated as absent either.
@(test)
t14_healthy_bridge_is_untouched_by_its_neighbours_absence :: proc(t: ^testing.T) {
	fx: Fx; fx_make(&fx); defer fx_free(&fx)
	fx_bridge(&fx, "brg_gone", "2026-09-28T09:00:00Z")
	fx_bridge(&fx, "brg_live", R14_NOW, domain.Bridge_Status.Online)
	fx_session(&fx, "sh_gone", "brg_gone")
	fx_session(&fx, "sh_live", "brg_live")
	fx_session(&fx, "sh_orphan", "brg_unknown") // no bridge row at all

	testing.expect_value(t, fx_sweep(&fx), 1)

	gone, _ := fx_row(&fx, "sh_gone", "brg_gone")
	testing.expect_value(t, gone.status, shell_session_svc.SHELL_SESSION_INVENTORY_UNOBSERVED_TERMINAL)

	live, _ := fx_row(&fx, "sh_live", "brg_live")
	testing.expect_value(t, live.status, domain.Shell_Session_Status_Running)

	orphan, _ := fx_row(&fx, "sh_orphan", "brg_unknown")
	testing.expect_value(t, orphan.status, domain.Shell_Session_Status_Running)
}
