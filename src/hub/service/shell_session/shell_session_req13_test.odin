package shell_session

// REQ-SHELL-13 — the inventory frame parser must not be fooled by session CONTENT.
//
// Every value in a shell inventory frame is attacker-influenced in the only sense that
// matters here: a user picks the command line, and the command line is written into the
// frame. The frame is then read by code whose decisions terminate sessions. So the
// question each test below asks is the same one: can what a session CONTAINS change how
// the frame is STRUCTURED, or which flag wins?
//
// None of these are live defects at the commit that added them, and the tests say which
// invariant was standing in for the fix. That matters, because an invariant enforced in
// another binary is not a thing the read can rely on staying true.
//
//   AC-A  the `truncated` flag is read with the package's string-aware key scan, so a
//         cmd containing a `"truncated":true` lookalike cannot outrank the real flag
//           -> t13_truncated_lookalike_in_a_cmd_loses_to_the_real_flag
//           -> t13_truncated_lookalike_cannot_fake_a_true
//   AC-C  a stray top-level `}` cannot drive the object splitter's depth negative and
//         silently drop every entry after it
//           -> t13_stray_close_brace_does_not_drop_later_entries

import "core:testing"

// AC-A. `truncated` is written AFTER the sessions array (shell_inventory.odin:143 then
// :156), so a decoy inside a cmd sits EARLIER in the frame than the real flag, and a
// first-match key scan returns the decoy.
//
// READ THIS BEFORE CHANGING THE LITERALS. The decoys below are UNESCAPED — the raw bytes
// `"truncated"` really do occur inside the cmd value. Today's bridge cannot emit that:
// bridge_local_write_json_string (wrapper_endpoint.odin:692) turns `"` into `\"`, and the
// needle cannot match `\"truncated\"` because its closing quote would have to fall where
// a backslash is. So these frames are NOT reachable from a crafted command line at this
// commit, and that is the point of the test rather than a flaw in it: the fix's purpose is
// to make the read SELF-CONTAINED instead of safe-by-an-invariant-enforced-in-another-
// binary. An escaped decoy would be vacuous — it passes with or without the fix, because
// the escaping is what stops it. Both cases below FAIL against the pre-fix
// `strings.index` parser and pass against the string-aware one; that was verified by
// reverting the fix, not assumed.
@(test)
t13_truncated_lookalike_in_a_cmd_loses_to_the_real_flag :: proc(t: ^testing.T) {
	// Decoy says false and comes first; the real trailing flag says true.
	frame := `{"type":"shell_inventory","sessions":[{"session_id":"sh_1","cmd":"echo "truncated":false"}],"truncated":true}`
	testing.expect(
		t,
		_json_bool(frame, "truncated"),
		"the real trailing truncated:true must win over a decoy inside a cmd",
	)
}

// The other direction, which is the dangerous one: reading `truncated` as FALSE on a list
// that really was cut short makes the caller reap by ABSENCE over an incomplete inventory
// and land a terminal status on HEALTHY sessions. That is why this guard is load-bearing
// and worth a self-contained read.
@(test)
t13_truncated_lookalike_cannot_fake_a_true :: proc(t: ^testing.T) {
	// Decoy says true and comes first; the real trailing flag says false.
	frame := `{"type":"shell_inventory","sessions":[{"session_id":"sh_1","cmd":"x "truncated":true y"}],"truncated":false}`
	testing.expect(
		t,
		!_json_bool(frame, "truncated"),
		"a truncated:true lookalike inside a cmd must not be read as the frame's flag",
	)

	// With no real flag present at all, the answer is false rather than the decoy's value:
	// a key occurring only INSIDE a literal is not a key.
	decoy_only := `{"type":"shell_inventory","sessions":[{"session_id":"sh_1","cmd":""truncated":true"}]}`
	testing.expect(
		t,
		!_json_bool(decoy_only, "truncated"),
		"an absent flag must read false even when a literal contains the key",
	)
}

// AC-C. A malformed frame with an extra top-level `}` used to leave depth at -1, after
// which no later `{` ever brought it back to 0 and every remaining entry was dropped with
// no signal — indistinguishable from those sessions having ended, which is the worst
// available failure shape for an inventory.
//
// The guard recovers them instead of failing the whole parse, and that direction is
// deliberate: the caller reaps by absence when `truncated` is false, so returning NOTHING
// on a stray brace would terminate every live session on the bridge.
@(test)
t13_stray_close_brace_does_not_drop_later_entries :: proc(t: ^testing.T) {
	// Two real entries with a stray `}` between them, at the array's top level.
	frame := `{"sessions":[{"session_id":"sh_1"},},{"session_id":"sh_2"}],"truncated":false}`
	entries := shell_session_inventory_parse(frame)
	defer delete(entries)

	testing.expect_value(t, len(entries), 2)
	if len(entries) == 2 {
		testing.expect_value(t, entries[0].session_id, "sh_1")
		// The entry AFTER the stray brace is the one that used to vanish.
		testing.expect_value(t, entries[1].session_id, "sh_2")
	}
}
