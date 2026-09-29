package shell_session

// REQ-SHELL-14 service-level tests — invariant (b) for the bridge that NEVER COMES BACK.
//
// The hole this task fills: every hub-side terminal write needs an event FROM the owning
// bridge, so a bridge that is gone for good leaves its rows reporting "running" forever.
// REQ-SHELL-10 closes the RECONNECT half; this closes the never-reconnected half.
//
// What is asserted here, and what is asserted in package app:
//   HERE, the ROW WORK — given the judgement "this bridge is gone", exactly which rows
//   move, to what, and what must NOT be touched:
//     t14_gone_bridge_live_rows_go_terminal      every live row -> failed + finished_at
//     t14_reap_never_fabricates_an_exit_code     exit_code_set stays false
//     t14_already_terminal_rows_are_untouched    idempotent; observed terminals survive
//     t14_reap_cannot_touch_another_bridge       one bridge's absence is not another's
//     t14_pending_kill_intent_is_cleared         REQ-SHELL-3 composes structurally
//     t14_synthesized_terminal_is_revived        the threshold's safety net actually fires
//   IN src/hub/app/reaper_req14_test.odin, the JUDGEMENT — blip vs gone, which is where
//   the destructive failure mode would live. Both halves are needed: this file would
//   happily terminate a bridge that blinked, because being told to reap is its whole
//   contract.
//
// The fake repository mirrors the real SQL's OWNERSHIP and its kill_requested_at CASE for
// the same reasons spelled out at the top of shell_session_req10_test.odin — a fake
// without the CASE would let t14_pending_kill_intent_is_cleared pass while the real
// upsert left a spent intent behind, which is precisely the composition this task is
// required to prove.

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import project_service "odin_test:hub/service/project"

// --- fake repository ---------------------------------------------------------

@(private = "file")
Repo14 :: struct {
	stored: map[string]domain.Shell_Session, // "<bridge_id>\x00<session_id>" -> row
	writes: int,
}

@(private = "file")
r14_key :: proc(bridge_id, session_id: string) -> string {
	return strings.concatenate({bridge_id, "\x00", session_id}, context.temp_allocator)
}

@(private = "file")
r14_clone :: proc(s: domain.Shell_Session) -> domain.Shell_Session {
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
_r14_replace :: proc(current, with: string) -> string {
	delete(current)
	return strings.clone(with)
}

@(private = "file")
r14_upsert :: proc(ctx: rawptr, session: domain.Shell_Session) -> (bool, domain.Domain_Error) {
	r := (^Repo14)(ctx)
	r.writes += 1
	key := r14_key(session.bridge_id, session.session_id)
	next := r14_clone(session)
	if prev, had := r.stored[key]; had {
		// The real upsert's kill_requested_at CASE (REQ-SHELL-3): a terminal status
		// clears the intent, a non-empty incoming value sets it, otherwise the stored
		// value survives. This task writes no intent of its own and depends entirely on
		// that clause, so the fake must have it.
		switch {
		case domain.shell_session_status_is_terminal(session.status): next.kill_requested_at = _r14_replace(next.kill_requested_at, "")
		case session.kill_requested_at != "":                          // keep incoming
		case:                                                          next.kill_requested_at = _r14_replace(next.kill_requested_at, prev.kill_requested_at)
		}
		domain.shell_session_destroy(prev)
		r.stored[key] = next
	} else {
		if domain.shell_session_status_is_terminal(next.status) {
			next.kill_requested_at = _r14_replace(next.kill_requested_at, "")
		}
		r.stored[strings.clone(key)] = next
	}
	return true, domain.Domain_Error{}
}

// Bridge-scoped and owner-unscoped, like the real get_by_id. The bridge check is the
// load-bearing part: it is what stops one bridge's inventory resolving another's row.
//
// RETURNS AN OWNED CLONE, because _apply_inventory_entry does
// `defer domain.shell_session_destroy(row)` on what this hands back. A fake returning
// its own stored pointers would have the service free the map's contents out from under
// it — the ownership rule the sqlite reader satisfies by construction.
@(private = "file")
r14_get_by_id :: proc(ctx: rawptr, bridge_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	r := (^Repo14)(ctx)
	s, had := r.stored[r14_key(bridge_id, session_id)]
	if !had do return domain.Shell_Session{}, false, domain.Domain_Error{}
	return r14_clone(s), true, domain.Domain_Error{}
}

// r14_list_live_by_bridge is the read the reap drives: this bridge's NON-terminal rows.
// "Live" is domain.shell_session_is_terminal inverted, the same rule the SQL builds from
// domain.SHELL_SESSION_TERMINAL_STATUSES, so the fake cannot disagree with it about which
// rows are candidates.
@(private = "file")
r14_list_live_by_bridge :: proc(ctx: rawptr, bridge_id: string, limit: int) -> ([dynamic]domain.Shell_Session, domain.Domain_Error) {
	r := (^Repo14)(ctx)
	out := make([dynamic]domain.Shell_Session)
	for _, s in r.stored {
		if s.bridge_id != bridge_id do continue
		if domain.shell_session_is_terminal(s) do continue
		append(&out, r14_clone(s))
	}
	return out, domain.Domain_Error{}
}

// --- fixture -----------------------------------------------------------------

@(private = "file")
Fx14 :: struct {
	svc:  Shell_Session_Service,
	repo: iface.Shell_Session_Repository,
	r:    Repo14,
	ids:  platform.ID_Generator,
	clk:  platform.Clock,
}

// NOW14 is when the SWEEP runs. Absence is expressed by seeding a bridge's last_seen_at
// in the past relative to it (in the app-package tests); here it is simply the timestamp
// the reap is expected to stamp into finished_at.
@(private = "file")
NOW14 :: "2026-09-28T12:00:00Z"

@(private = "file")
now14 :: proc(ctx: rawptr) -> string { _ = ctx; return strings.clone(NOW14) }

@(private = "file")
fx14_make :: proc(fx: ^Fx14) {
	fx.r.stored = make(map[string]domain.Shell_Session)
	fx.repo = iface.Shell_Session_Repository{
		ctx                 = rawptr(&fx.r),
		upsert              = r14_upsert,
		get_by_id           = r14_get_by_id,
		list_live_by_bridge = r14_list_live_by_bridge,
	}
	fx.ids = platform.real_id_generator()
	fx.clk = platform.Clock{ctx = nil, now = now14}
	fx.svc = new_shell_session_service(repo = &fx.repo, ids = &fx.ids, clock = &fx.clk)
}

@(private = "file")
fx14_free :: proc(fx: ^Fx14) {
	shell_session_service_free(&fx.svc)
	for k, s in fx.r.stored { delete(k); domain.shell_session_destroy(s) }
	delete(fx.r.stored)
}

@(private = "file")
Seed14 :: struct {
	session_id:    string,
	bridge_id:     string,
	status:        string,
	exit_code:     int,
	exit_code_set: bool,
	run_seq:       int,
	kill_at:       string,
}

@(private = "file")
fx14_seed :: proc(fx: ^Fx14, seed: Seed14) {
	status := seed.status if seed.status != "" else domain.Shell_Session_Status_Running
	row := domain.Shell_Session{
		session_id        = seed.session_id,
		owner_user_id     = "owner_a",
		bridge_id         = seed.bridge_id,
		kind              = domain.Shell_Session_Kind_Shell,
		cmd               = "zsh",
		status            = status,
		exit_code         = seed.exit_code,
		exit_code_set     = seed.exit_code_set,
		run_seq           = seed.run_seq,
		kill_requested_at = seed.kill_at,
		started_at        = "2026-09-28T09:00:00Z",
	}
	fx.r.stored[strings.clone(r14_key(seed.bridge_id, seed.session_id))] = r14_clone(row)
}

@(private = "file")
fx14_row :: proc(fx: ^Fx14, session_id: string, bridge_id := "brg_gone") -> (domain.Shell_Session, bool) {
	s, had := fx.r.stored[r14_key(bridge_id, session_id)]
	return s, had
}

// --- tests -------------------------------------------------------------------

// The core write: a bridge judged gone has EVERY live row moved to a terminal status
// with finished_at set, which is what stops the hub reporting them live.
@(test)
t14_gone_bridge_live_rows_go_terminal :: proc(t: ^testing.T) {
	fx: Fx14; fx14_make(&fx); defer fx14_free(&fx)
	fx14_seed(&fx, Seed14{session_id = "sh_1", bridge_id = "brg_gone"})
	fx14_seed(&fx, Seed14{session_id = "sh_2", bridge_id = "brg_gone", status = domain.Shell_Session_Status_Starting})

	moved := shell_session_reap_gone_bridge(&fx.svc, "brg_gone", NOW14)
	testing.expect_value(t, moved, 2)

	for id in ([]string{"sh_1", "sh_2"}) {
		row, had := fx14_row(&fx, id)
		testing.expect(t, had, "row must still exist — reaping is a status change, not a delete")
		// The EXISTING unobserved-terminal spelling, not a new status value.
		testing.expect_value(t, row.status, SHELL_SESSION_INVENTORY_UNOBSERVED_TERMINAL)
		testing.expect(t, domain.shell_session_status_is_terminal(row.status), "status must be in the terminal set")
		testing.expect_value(t, row.finished_at, NOW14)
		testing.expect_value(t, row.last_activity_at, NOW14)
	}
}

// exit_code_set MUST stay false. It is the discriminator
// domain.shell_session_terminal_is_observed reads to tell a hub-side guess from a
// bridge-reported fact: the moment this path stamps a fabricated code, the guess
// outranks ground truth, REQ-SHELL-4's supersession in shell_session_handle_exited stops
// firing, and the revive below — the entire safety net under the one-hour threshold —
// goes with it. This is a condition on the mechanism, not a preference.
@(test)
t14_reap_never_fabricates_an_exit_code :: proc(t: ^testing.T) {
	fx: Fx14; fx14_make(&fx); defer fx14_free(&fx)
	fx14_seed(&fx, Seed14{session_id = "sh_1", bridge_id = "brg_gone"})

	testing.expect_value(t, shell_session_reap_gone_bridge(&fx.svc, "brg_gone", NOW14), 1)

	row, _ := fx14_row(&fx, "sh_1")
	testing.expect(t, !row.exit_code_set, "a path that observed nothing must report no exit code")
	testing.expect_value(t, row.exit_code, 0)
	testing.expect(
		t,
		!domain.shell_session_terminal_is_observed(row),
		"the terminal must remain UNOBSERVED so a returning bridge's real exit code still wins",
	)
}

// Already-terminal rows are not candidates, so the sweep is idempotent — it runs every
// 20 seconds and must not rewrite rows or re-emit events on each tick. The observed
// terminal in particular must survive untouched: overwriting a real exit code with a
// guess is the same defect as fabricating one.
@(test)
t14_already_terminal_rows_are_untouched :: proc(t: ^testing.T) {
	fx: Fx14; fx14_make(&fx); defer fx14_free(&fx)
	fx14_seed(&fx, Seed14{
		session_id = "sh_observed", bridge_id = "brg_gone",
		status = domain.Shell_Session_Status_Exited, exit_code = 7, exit_code_set = true,
	})
	fx14_seed(&fx, Seed14{session_id = "sh_live", bridge_id = "brg_gone"})

	testing.expect_value(t, shell_session_reap_gone_bridge(&fx.svc, "brg_gone", NOW14), 1)
	writes_after_first := fx.r.writes

	observed, _ := fx14_row(&fx, "sh_observed")
	testing.expect_value(t, observed.status, domain.Shell_Session_Status_Exited)
	testing.expect_value(t, observed.exit_code, 7)
	testing.expect(t, observed.exit_code_set, "a bridge-reported exit code must not be overwritten by a guess")

	// Second tick: nothing left live, so no rows move and no writes are issued.
	testing.expect_value(t, shell_session_reap_gone_bridge(&fx.svc, "brg_gone", NOW14), 0)
	testing.expect_value(t, fx.r.writes, writes_after_first)
}

// One bridge's absence says nothing about another's. The reap is scoped by bridge_id,
// which matters because the candidate listing that drives it is owner-unscoped and
// host-wide.
@(test)
t14_reap_cannot_touch_another_bridge :: proc(t: ^testing.T) {
	fx: Fx14; fx14_make(&fx); defer fx14_free(&fx)
	fx14_seed(&fx, Seed14{session_id = "sh_1", bridge_id = "brg_gone"})
	fx14_seed(&fx, Seed14{session_id = "sh_2", bridge_id = "brg_healthy"})

	testing.expect_value(t, shell_session_reap_gone_bridge(&fx.svc, "brg_gone", NOW14), 1)

	other, had := fx14_row(&fx, "sh_2", "brg_healthy")
	testing.expect(t, had, "the healthy bridge's row must still be there")
	testing.expect_value(t, other.status, domain.Shell_Session_Status_Running)
	testing.expect_value(t, other.finished_at, "")
}

// ACCEPTANCE: a pending kill_requested_at is cleared BY the transition, through
// REQ-SHELL-3's existing auto-clear in the upsert's CASE — with no REQ-SHELL-3 code in
// this task. That is the proof the two compose: T3 clears the intent whenever any
// terminal status lands, and on a bridge that never returns this reap is the only thing
// that can ever land one, so without it the kill intent would also stick forever.
@(test)
t14_pending_kill_intent_is_cleared :: proc(t: ^testing.T) {
	fx: Fx14; fx14_make(&fx); defer fx14_free(&fx)
	fx14_seed(&fx, Seed14{
		session_id = "sh_1", bridge_id = "brg_gone",
		kill_at = "2026-09-28T11:00:00Z", // requested while the bridge was already silent
	})
	before, _ := fx14_row(&fx, "sh_1")
	testing.expect_value(t, before.kill_requested_at, "2026-09-28T11:00:00Z")

	testing.expect_value(t, shell_session_reap_gone_bridge(&fx.svc, "brg_gone", NOW14), 1)

	row, _ := fx14_row(&fx, "sh_1")
	testing.expect_value(t, row.status, SHELL_SESSION_INVENTORY_UNOBSERVED_TERMINAL)
	testing.expect_value(t, row.kill_requested_at, "")
}

// ACCEPTANCE, and the CONDITION the one-hour threshold rests on: a row this task
// synthesized to `failed` is REVIVED when the bridge comes back with the process still
// alive. Asserted as an executed sequence — reap, then a real inventory frame — rather
// than inferred from REQ-SHELL-10 having a revive branch, because if revive did not fire
// for hub-synthesized rows the threshold would not be conservative, it would be
// destructive: every partition longer than an hour would permanently mark live work
// failed. REQ-SHELL-10's diff is the ONLY reconciler; this task adds none.
@(test)
t14_synthesized_terminal_is_revived :: proc(t: ^testing.T) {
	fx: Fx14; fx14_make(&fx); defer fx14_free(&fx)
	fx14_seed(&fx, Seed14{session_id = "sh_1", bridge_id = "brg_gone"})

	// 1. The hub decides the bridge is gone and synthesizes a terminal.
	testing.expect_value(t, shell_session_reap_gone_bridge(&fx.svc, "brg_gone", NOW14), 1)
	reaped, _ := fx14_row(&fx, "sh_1")
	testing.expect_value(t, reaped.status, SHELL_SESSION_INVENTORY_UNOBSERVED_TERMINAL)

	// 2. The bridge returns and reports the process is still running.
	frame := strings.concatenate({
		"{\"type\":\"shell_inventory\",\"sessions\":[{\"session_id\":\"sh_1\",\"kind\":\"",
		domain.Shell_Session_Kind_Shell,
		"\",\"status\":\"", domain.Shell_Session_Status_Running,
		"\",\"shell_id\":\"\",\"started_at\":\"2026-09-28T09:00:00Z\",\"label\":\"\",\"cmd\":\"zsh\"",
		",\"cwd\":\"/tmp\",\"owner_user_id\":\"owner_a\",\"project_id\":\"\",\"chain_id\":\"\"",
		",\"agent_instance_id\":\"\",\"background\":false,\"pid\":4242,\"server_port\":0,\"run_seq\":0}",
		"],\"truncated\":false}",
	})
	defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_gone", frame)

	// 3. The wrong call is corrected by REQ-SHELL-10's diff, not by anything here.
	testing.expect_value(t, res.revived, 1)
	row, _ := fx14_row(&fx, "sh_1")
	testing.expect_value(t, row.status, domain.Shell_Session_Status_Running)
	testing.expect_value(t, row.finished_at, "")
}
