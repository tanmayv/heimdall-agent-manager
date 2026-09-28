package main

// REQ-SHELL-3 bridge-side tests — the DELIVERY half of durable kill intent:
//   AC3  a kill DELIVERED TWICE is a no-op the second time
//   AC4  a kill whose target already exited signals nothing, including the PID-REUSE
//        case (target exited, pid reassigned: nothing is signalled)
//   §5b  a kill that arrives BEFORE the session exists is recorded, not dropped, and
//        is applied exactly once when the spawn produces a pid
//
// WHAT THESE TESTS DELIBERATELY DO NOT DO: arm a real kill worker. Arming calls
// bridge_pty_host_ensure_daemon, which SPAWNS the pty-host daemon (or attaches to the
// live one on this host) and then signals it — a side effect on the developer's
// machine that a unit test has no business having, and one that would make the
// assertions depend on a daemon's state rather than on this code. Every test below
// therefore asserts the DECISION that precedes arming, which is where all of the new
// logic lives; the arming sequence itself is unchanged code, extracted verbatim into
// bridge_shell_kill_arm.

import "core:strings"
import "core:sync"
import "core:testing"

@(private = "file")
intent_session :: proc(session_id: string, status: Bridge_Shell_Session_Status, pid: int) -> Bridge_Shell_Session {
	return Bridge_Shell_Session{
		session_id = bridge_shell_test_session_str(session_id),
		kind       = .Run,
		cmd        = bridge_shell_test_session_str("sleep 600"),
		status     = status,
		pid        = pid,
		shell_id   = bridge_shell_test_session_str(session_id),
		started_at = bridge_shell_test_session_str("2026-09-28T09:00:00Z"),
		pty_host   = true,
		pty_host_provenance_known = true,
	}
}

// --- §5b: a kill for a session that does not exist yet -------------------------

// KILL BEFORE START. The hub writes its row and then sends shell_start, so a kill
// accepted in between arrives here for a session that is not in the map: there is no
// pid to signal and no status to mark. This used to `return` silently and the process
// leaked the instant it spawned. The intent must be RECORDED so the spawn applies it.
@(test)
bridge_shell3_kill_before_start_is_recorded_not_dropped :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()

	testing.expect(t, !bridge_shell_kill_intent_pending("sh_unborn"), "nothing pending to begin with")

	bridge_hub_handle_shell_kill(`{"type":"shell_kill","session_id":"sh_unborn"}`)

	testing.expect(t, bridge_shell_kill_intent_pending("sh_unborn"),
		"a kill for an unknown session must be remembered, not dropped on the floor")
	// And it did not invent a session record for it.
	testing.expect(t, !bridge_shell_session_exists(&bridge_shell_session_map, "sh_unborn"),
		"recording an intent does not fabricate a session")
}

// The intent is ONE-SHOT: the spawn path consumes it, so a session cannot be killed
// twice off the back of a single recorded intent, and the entry cannot linger to be
// applied to a later session that reuses the id.
@(test)
bridge_shell3_a_recorded_intent_is_consumed_exactly_once :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()

	bridge_shell_kill_intent_record("sh_1")
	// Recording twice is idempotent — the set holds an intent, not a count.
	bridge_shell_kill_intent_record("sh_1")

	testing.expect(t, bridge_shell_kill_intent_take("sh_1"), "the first take finds the intent")
	testing.expect(t, !bridge_shell_kill_intent_take("sh_1"), "and the second finds nothing — it is one-shot")
	testing.expect(t, !bridge_shell_kill_intent_pending("sh_1"), "so nothing is left pending")
}

// An intent is only ever applied to the session it NAMES. This is what makes a
// recorded intent for a session that never starts inert rather than dangerous.
@(test)
bridge_shell3_an_intent_never_applies_to_a_different_session :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()

	bridge_shell_kill_intent_record("sh_wanted_dead")

	testing.expect(t, !bridge_shell_kill_intent_take("sh_innocent"),
		"a different session's spawn must not consume this intent")
	testing.expect(t, bridge_shell_kill_intent_pending("sh_wanted_dead"),
		"and the real target's intent is still waiting for it")
}

// --- AC3: a kill delivered twice is a no-op the second time --------------------

// The hub replays outstanding intents on EVERY reconnect and reconnects can race, so
// a second delivery of the same kill is expected, not exceptional.
//
// The state seeded here is precisely "after the first delivery": the kill path marks
// the session .Killed before its worker starts. The second delivery must change
// nothing — in particular it must not arm a second SIGTERM/SIGKILL pair, because the
// 5s grace window between them is exactly when the OS is free to hand that pid to an
// unrelated process. The observable proof is that the exit bookkeeping the first
// delivery (and the exit that followed it) left behind is untouched: arming rewrites
// exit_code to -1 and clears exit_code_set.
@(test)
bridge_shell3_a_redelivered_kill_is_a_no_op :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()

	sess := intent_session("sh_1", .Killed, 4242)
	sess.exit_code     = 143
	sess.exit_code_set = true
	bridge_shell_session_register(&bridge_shell_session_map, &sess)

	bridge_hub_handle_shell_kill(`{"type":"shell_kill","session_id":"sh_1"}`)

	after, found := bridge_shell_session_scalars(&bridge_shell_session_map, "sh_1")
	testing.expect(t, found, "the session is still there")
	testing.expect(t, after.status == .Killed, "still killed")
	testing.expect_value(t, after.exit_code, 143)
	testing.expect(t, after.exit_code_set, "the recorded exit survives a redelivered kill — nothing was re-armed")
	// It was not mistaken for a kill-before-start either: the session exists, so no
	// intent is recorded for a spawn to pick up later.
	testing.expect(t, !bridge_shell_kill_intent_pending("sh_1"),
		"a redelivered kill for a known session records no pending intent")
}

// --- AC4: an already-exited target signals nothing, pid reuse included ---------

// Every terminal status is a no-op, not just .Killed — a session that exited on its
// own, or failed, is equally gone.
//
// THE PID-REUSE CASE IS THE POINT. Each session below is seeded with a pid that is
// still a perfectly plausible live pid; the guard does NOT consult liveness at all,
// it reads the session's own terminal status. That ordering is what makes pid reuse
// unreachable from this path: nothing is signalled, so it cannot matter whose process
// that pid now belongs to. A guard that had instead asked "is pid still alive?" would
// answer yes for the unrelated process that inherited it and signal that.
@(test)
bridge_shell3_a_kill_for_an_exited_target_signals_nothing :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)

	terminal := [3]Bridge_Shell_Session_Status{.Exited, .Killed, .Failed}
	for status in terminal {
		bridge_shell_test_reset()

		sess := intent_session("sh_gone", status, 4242)
		sess.exit_code     = 0
		sess.exit_code_set = true
		bridge_shell_session_register(&bridge_shell_session_map, &sess)

		bridge_hub_handle_shell_kill(`{"type":"shell_kill","session_id":"sh_gone"}`)

		after, _ := bridge_shell_session_scalars(&bridge_shell_session_map, "sh_gone")
		testing.expect(t, after.status == status, "a terminal session's status is not rewritten by a kill")
		testing.expect(t, after.exit_code_set, "and its exit bookkeeping is left alone — no worker was armed")
		testing.expect_value(t, after.exit_code, 0)
	}
	bridge_shell_test_reset()
}

// The guard the two tests above rest on, asserted directly and exhaustively: a new
// status added to the enum has to be classified here, and the compiler's exhaustive
// switch is what forces that rather than it silently defaulting to "live".
@(test)
bridge_shell3_terminal_status_classification :: proc(t: ^testing.T) {
	testing.expect(t, bridge_shell_session_status_is_terminal(.Exited), "exited is terminal")
	testing.expect(t, bridge_shell_session_status_is_terminal(.Killed), "killed is terminal")
	testing.expect(t, bridge_shell_session_status_is_terminal(.Failed), "failed is terminal")
	testing.expect(t, !bridge_shell_session_status_is_terminal(.Running), "running is live")
	testing.expect(t, !bridge_shell_session_status_is_terminal(.Starting), "starting is live")
}

// A malformed kill frame is ignored rather than recording an intent under an empty
// key — an entry no spawn could ever consume, and one that would make
// bridge_shell_kill_intent_pending("") true forever.
@(test)
bridge_shell3_a_kill_without_a_session_id_records_nothing :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()

	bridge_hub_handle_shell_kill(`{"type":"shell_kill"}`)
	testing.expect(t, !bridge_shell_kill_intent_pending(""), "no intent under an empty key")
}
