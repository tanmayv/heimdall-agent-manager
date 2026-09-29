package shell_session

// REQ-SHELL-25 — THE CREATION PUSH EVENT.
//
// REQ-SHELL-6 §6 deleted every poller and made the shell UI purely push-driven, but the
// only publish in shell_session_service was the TERMINAL one. A session therefore
// existed in the DB from the moment it was created and the client heard about it for
// the first time when it DIED: a foreground run was invisible for its whole life and
// then appeared already-terminal, which also meant the live-only controls (the spinner
// and the Background toggle, both rendered only while a run is live and foreground)
// could never be reached at all. Reported from the UI on 2026-09-29.
//
// WHAT THESE TESTS GUARD, and why they stop at the builder: per the REQ-SHELL-4 test
// header, events.User_Event_Bus publishes to real TCP sockets and cannot be faked here
// without testing the socket layer instead of the decision. So the bus call itself is
// left to the deploy dogfood, and what is pinned here is the WIRE CONTRACT — the exact
// `type` string the client switches on, and the fields it reads off the payload. That
// is the half that breaks silently: a renamed type or a dropped chain_id produces no
// error anywhere, just a UI that quietly stops repainting, which is precisely the
// failure being fixed.

import "core:strings"
import "core:testing"

// The client matches this string literally (wsInvalidation.ts). If it is ever renamed
// on one side only, the push silently stops arriving and the original bug returns with
// no build error and no test failure anywhere else.
@(test)
req25_started_event_names_the_type_the_client_switches_on :: proc(t: ^testing.T) {
	evt := _shell_session_started_event_json("sh_1", "run", "running", "")
	defer delete(evt)
	testing.expect(
		t,
		strings.contains(evt, `"type":"shell_session_started"`),
		"the client switches on this exact type string",
	)
	testing.expect(t, strings.contains(evt, `"session_id":"sh_1"`))
	testing.expect(t, strings.contains(evt, `"kind":"run"`))
	testing.expect(t, strings.contains(evt, `"status":"running"`))
}

// chain_id is what lets a `server` repaint the chain summary's active-server list on the
// same frame, because the client invalidates by session AND by chain.
@(test)
req25_started_event_carries_chain_id_for_servers :: proc(t: ^testing.T) {
	evt := _shell_session_started_event_json("sh_2", "server", "running", "chain_7")
	defer delete(evt)
	testing.expect(t, strings.contains(evt, `"chain_id":"chain_7"`))
	testing.expect(t, strings.contains(evt, `"kind":"server"`))
}

// Omitted rather than sent as "", matching how the exited event treats an absent
// exit_code. A run has no chain, so this is the common case, not an edge one.
@(test)
req25_started_event_omits_empty_chain_id :: proc(t: ^testing.T) {
	evt := _shell_session_started_event_json("sh_3", "run", "running", "")
	defer delete(evt)
	testing.expect(
		t,
		!strings.contains(evt, "chain_id"),
		"an empty chain_id is omitted, not emitted as an empty string",
	)
}

// The event is emitted for ALL THREE KINDS, not runs only: the transcript marker is
// runs-only because it is conversation content, but this is a cache invalidation and a
// `shell` must reach the session list as promptly as a run reaches the thread.
@(test)
req25_started_event_is_not_run_only :: proc(t: ^testing.T) {
	for kind in ([]string{"run", "shell", "server"}) {
		evt := _shell_session_started_event_json("sh_4", kind, "running", "")
		defer delete(evt)
		testing.expect(
			t,
			strings.contains(evt, strings.concatenate({`"kind":"`, kind, `"`}, context.temp_allocator)),
			"every kind gets a creation event",
		)
	}
}
