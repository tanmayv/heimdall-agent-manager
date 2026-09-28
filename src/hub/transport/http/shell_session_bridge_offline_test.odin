package http

// REQ-SHELL-10 work item 3 / AC3 + AC6: the BRIDGE-OFFLINE SESSION STATE.
//
// The requirement: a session whose owning bridge is gone must not be presented as
// plainly `running` (which asserts something we cannot see) nor as `failed`/`killed`
// (which assert something we do not know). It needs a third reading — "the bridge that
// owns this is gone; its true status is unknown until it returns" — which REQ-SHELL-6
// §8 renders.
//
// WHY THE TESTS LIVE HERE rather than in the service package. The state is DERIVED at
// serialization time from the live bridge registry, not stored on the row and not
// written on disconnect. That is the design decision of this work item (see
// shell_session_status_unknown for the full reasoning), and it puts the whole of the
// behaviour in this package — so this is where it can be asserted end to end, against
// the real registry rather than a fake of it.

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import bridge_runtime_service "odin_test:hub/service/bridge_runtime"
import project_service "odin_test:hub/service/project"

@(private = "file")
_offline_session :: proc(status: string) -> domain.Shell_Session {
	return domain.Shell_Session{
		session_id    = "sh_1",
		owner_user_id = "owner_a",
		bridge_id     = "brg_1",
		kind          = domain.Shell_Session_Kind_Shell,
		cmd           = "zsh",
		status        = status,
		started_at    = "2026-09-28T09:00:00Z",
	}
}

@(private = "file")
_offline_json :: proc(registry: ^project_service.Bridge_Runtime_Registry, s: domain.Shell_Session) -> string {
	b := strings.builder_make()
	write_shell_session_json(&b, s, registry)
	return strings.to_string(b)
}

// AC3, BOTH DIRECTIONS in one test, because the reverse is the half a stored status
// would get wrong: a design that wrote a state on disconnect has to remember to unwind
// it, and a fast reconnect racing that teardown is exactly how a live session gets
// stuck looking dead. Deriving the state means the reverse direction is the same line
// of code read again, which is what this asserts.
@(test)
test_shell_session_bridge_offline_state_both_directions :: proc(t: ^testing.T) {
	registry: project_service.Bridge_Runtime_Registry
	session := _offline_session(domain.Shell_Session_Status_Running)

	// 1. CONNECTED: the row's status stands on its own.
	_, _, _ = bridge_runtime_service.runtime_accept_hello(&registry, "brg_1", 1, "")
	online := _offline_json(&registry, session)
	defer delete(online)
	testing.expect(t, strings.contains(online, "\"bridge_online\":true"), "a connected bridge must report online")
	testing.expect(t, strings.contains(online, "\"status_unknown\":false"), "a connected bridge's session status is trustworthy")

	// 2. DISCONNECTED: the status is reported verbatim but flagged untrustworthy —
	// never rewritten to failed/killed, which would assert a death nobody observed.
	project_service.bridge_runtime_registry_mark_offline(&registry, "brg_1", 0)
	offline := _offline_json(&registry, session)
	defer delete(offline)
	testing.expect(t, strings.contains(offline, "\"bridge_online\":false"), "a disconnected bridge must report offline")
	testing.expect(t, strings.contains(offline, "\"status_unknown\":true"), "its live session's status is no longer trustworthy")
	testing.expect(t, strings.contains(offline, "\"status\":\"running\""),
		"the stored status is still reported verbatim — this state qualifies it, it does not replace it")

	// 3. RECONNECTED: back to trustworthy, with nothing to unwind.
	_, _, _ = bridge_runtime_service.runtime_accept_hello(&registry, "brg_1", 1, "")
	back := _offline_json(&registry, session)
	defer delete(back)
	testing.expect(t, strings.contains(back, "\"bridge_online\":true"), "reconnect must clear the flag")
	testing.expect(t, strings.contains(back, "\"status_unknown\":false"), "reconnect must restore the true status")
}

// A TERMINAL session is exempt, and this is the reason the rule is a named predicate
// rather than `!bridge_online` at the call site. A session that has already ended has a
// FINAL status — a fact about the past that no bridge needs to vouch for. Flagging it
// unknown would tell a user the outcome of a finished job is in doubt, every time its
// bridge happened to be offline.
@(test)
test_shell_session_terminal_status_is_never_unknown :: proc(t: ^testing.T) {
	registry: project_service.Bridge_Runtime_Registry // nothing live

	for status in ([]string{
		domain.Shell_Session_Status_Exited,
		domain.Shell_Session_Status_Killed,
		domain.Shell_Session_Status_Failed,
	}) {
		session := _offline_session(status)
		body := _offline_json(&registry, session)
		defer delete(body)
		testing.expectf(t, strings.contains(body, "\"status_unknown\":false"),
			"a %s session has a final status and must not be flagged unknown", status)
		testing.expect(t, strings.contains(body, "\"bridge_online\":false"),
			"the bridge fact is still reported truthfully")
	}
}

// AC6 — THE GENERATION GUARD, asserted on this path specifically.
//
// A bridge reconnects fast enough that the PREVIOUS connection's teardown runs after
// the new one is established. If that teardown could evict the fresh entry, every
// session on a perfectly healthy bridge would be presented as status-unknown until
// something else re-marked it live.
//
// The guard already exists in bridge_runtime_registry_mark_offline (it ignores a
// teardown whose generation is not the current one) and bridge_ws_disconnect gates its
// whole cascade on the same comparison. What this test pins is that the derived state
// INHERITS it rather than needing a second copy — which is the payoff of deriving from
// the registry instead of writing a status on disconnect.
@(test)
test_superseded_teardown_does_not_flip_a_fresh_reconnect :: proc(t: ^testing.T) {
	registry: project_service.Bridge_Runtime_Registry
	session := _offline_session(domain.Shell_Session_Status_Running)

	first, _, _ := bridge_runtime_service.runtime_accept_hello(&registry, "brg_1", 1, "")
	second, _, _ := bridge_runtime_service.runtime_accept_hello(&registry, "brg_1", 1, "")
	testing.expect(t, second.generation != first.generation, "a reconnect must take a new generation")

	// The OLD connection's teardown arrives late, naming its own (now superseded)
	// generation.
	project_service.bridge_runtime_registry_mark_offline(&registry, "brg_1", first.generation)

	body := _offline_json(&registry, session)
	defer delete(body)
	testing.expect(t, strings.contains(body, "\"bridge_online\":true"),
		"a superseded connection's teardown must not evict the live reconnect")
	testing.expect(t, strings.contains(body, "\"status_unknown\":false"),
		"and so must not present a healthy bridge's sessions as status-unknown")
}
