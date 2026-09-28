package main

// REQ-SHELL-10, bridge half: the inventory frame the hub's diff reasons from.
//
// WHY THESE ASSERTIONS AND NOT OTHERS. The hub's diff reads ABSENCE from this frame as
// "that session died while we were away" and lands a terminal status on it. So the
// frame's completeness and its live-only rule are not cosmetic — a session wrongly
// omitted is a session the hub marks dead, and a terminal session wrongly included is
// one the hub resurrects. Each test below pins one of those two failure directions.
//
// Each test stands up its OWN map on a mem.Tracking_Allocator rather than touching the
// process-wide bridge_shell_session_map, following shell_session_ownership_test.odin:
// it keeps the tests independent of each other's ordering and turns a double free or
// an allocator mismatch in the snapshot path into a visible failure rather than a
// silent one.

import "core:mem"
import "core:strings"
import "core:testing"

@(private = "file")
_inv_session :: proc(m: ^Bridge_Shell_Session_Map, session_id: string, status: Bridge_Shell_Session_Status, pid: int, run_seq := 0) -> Bridge_Shell_Session {
	a := bridge_shell_session_map_allocator(m)
	return Bridge_Shell_Session{
		session_id    = strings.clone(session_id, a),
		kind          = .Run,
		cmd           = strings.clone("sleep 600", a),
		cwd           = strings.clone("/tmp", a),
		bridge_id     = strings.clone("brg_inv", a),
		owner_user_id = strings.clone("owner_a", a),
		agent_instance_id = strings.clone("inst_a", a),
		label         = strings.clone("inv", a),
		status        = status,
		pid           = pid,
		run_seq       = run_seq,
		shell_id      = strings.clone("", a),
		project_id    = strings.clone("", a),
		chain_id      = strings.clone("", a),
		started_at    = strings.clone("2026-09-28T09:00:00Z", a),
		finished_at   = strings.clone("", a),
		pty_host      = true,
		pty_host_provenance_known = true,
	}
}

// LIVE ONLY. A terminal session in the inventory would tell the hub a process it has
// correctly recorded as finished is running again, and the hub's diff would revive the
// row — manufacturing the very "hub says terminal, bridge says running" divergence the
// diff exists to resolve, out of nothing.
@(test)
test_inventory_lists_only_live_sessions :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	m: Bridge_Shell_Session_Map
	m.allocator = mem.tracking_allocator(&track)
	defer bridge_shell_session_map_reset(&m)

	running  := _inv_session(&m, "sh_running",  .Running,  111)
	starting := _inv_session(&m, "sh_starting", .Starting, 222)
	exited   := _inv_session(&m, "sh_exited",   .Exited,   333)
	killed   := _inv_session(&m, "sh_killed",   .Killed,   444)
	failed   := _inv_session(&m, "sh_failed",   .Failed,   555)
	bridge_shell_session_register(&m, &running)
	bridge_shell_session_register(&m, &starting)
	bridge_shell_session_register(&m, &exited)
	bridge_shell_session_register(&m, &killed)
	bridge_shell_session_register(&m, &failed)

	frame := bridge_shell_inventory_build(&m)
	defer delete(frame)

	testing.expect(t, strings.contains(frame, "\"session_id\":\"sh_running\""),  "a running session must be listed")
	testing.expect(t, strings.contains(frame, "\"session_id\":\"sh_starting\""), "a starting session is live and must be listed")
	testing.expect(t, !strings.contains(frame, "sh_exited"), "an exited session must not be listed")
	testing.expect(t, !strings.contains(frame, "sh_killed"), "a killed session must not be listed")
	testing.expect(t, !strings.contains(frame, "sh_failed"), "a failed session must not be listed")
	testing.expect(t, strings.contains(frame, "\"type\":\"shell_inventory\""), "the hub dispatches on this type")
	testing.expect(t, strings.contains(frame, "\"truncated\":false"), "a complete inventory must say so")
}

// The hub adopts an unknown session from this frame alone, so every column its scope
// validator needs has to be on it. A missing owner or scope key is not a cosmetic gap:
// the hub refuses the entry, and the untracked process stays untracked.
@(test)
test_inventory_entry_carries_the_adoptable_columns :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	m: Bridge_Shell_Session_Map
	m.allocator = mem.tracking_allocator(&track)
	defer bridge_shell_session_map_reset(&m)

	s := _inv_session(&m, "sh_1", .Running, 4242, run_seq = 7)
	bridge_shell_session_register(&m, &s)

	frame := bridge_shell_inventory_build(&m)
	defer delete(frame)

	for needle in ([]string{
		"\"session_id\":\"sh_1\"",
		"\"kind\":\"run\"",
		"\"status\":\"running\"",
		"\"owner_user_id\":\"owner_a\"",
		"\"agent_instance_id\":\"inst_a\"", // kind=run is AGENT scoped — its scope KEY
		"\"pid\":4242",
		"\"run_seq\":7",
		"\"started_at\":\"2026-09-28T09:00:00Z\"",
		"\"background\":false",
	}) {
		testing.expectf(t, strings.contains(frame, needle), "the frame must carry %s", needle)
	}
}

// An empty inventory is a MEANINGFUL frame, not a missing one: it says "I have nothing
// running", which is exactly what lets the hub converge every stale live row on that
// bridge. If this returned nothing, the single most common convergence case — a bridge
// that restarted and lost everything — would never be reported at all.
@(test)
test_inventory_is_sent_when_empty :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	m: Bridge_Shell_Session_Map
	m.allocator = mem.tracking_allocator(&track)
	defer bridge_shell_session_map_reset(&m)

	frame := bridge_shell_inventory_build(&m)
	defer delete(frame)

	testing.expect(t, strings.contains(frame, "\"sessions\":[]"), "an empty live set must still be reported")
	testing.expect(t, strings.contains(frame, "\"truncated\":false"), "empty is complete, not truncated")
}

// The cap must announce itself. A truncated inventory that claimed to be complete
// would have the hub read its missing entries as deaths and terminate rows whose
// processes are alive — a bound turning into a kill switch.
@(test)
test_inventory_marks_itself_truncated_at_the_cap :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	m: Bridge_Shell_Session_Map
	m.allocator = mem.tracking_allocator(&track)
	defer bridge_shell_session_map_reset(&m)

	for i in 0 ..< BRIDGE_SHELL_INVENTORY_MAX_ENTRIES + 5 {
		id := strings.concatenate({"sh_", bridge_agent_itoa(i)}, context.temp_allocator)
		s := _inv_session(&m, id, .Running, 1000 + i)
		bridge_shell_session_register(&m, &s)
	}

	frame := bridge_shell_inventory_build(&m)
	defer delete(frame)

	testing.expect(t, strings.contains(frame, "\"truncated\":true"), "over the cap the frame must say it is incomplete")
	testing.expect_value(t, strings.count(frame, "\"session_id\":"), BRIDGE_SHELL_INVENTORY_MAX_ENTRIES)
}

// The queue holds the NEWEST snapshot, not a backlog of them. Reconnect flapping
// otherwise queues one inventory per attempt, and the hub would then apply a sequence
// of increasingly stale truths — the last one landing after the fresh one.
@(test)
test_inventory_queue_keeps_only_the_newest :: proc(t: ^testing.T) {
	bridge_shell_inventory_reset()
	defer bridge_shell_inventory_reset()

	bridge_shell_inventory_enqueue("{\"type\":\"shell_inventory\",\"sessions\":[],\"truncated\":false,\"gen\":1}")
	bridge_shell_inventory_enqueue("{\"type\":\"shell_inventory\",\"sessions\":[],\"truncated\":false,\"gen\":2}")

	pending, had := bridge_shell_inventory_pending_frame()
	testing.expect(t, had, "a frame must be queued")
	defer delete(pending)
	testing.expect(t, strings.contains(pending, "\"gen\":2"), "the newer snapshot must win")
	testing.expect(t, !strings.contains(pending, "\"gen\":1"), "the superseded snapshot must be gone, not queued behind it")
}
