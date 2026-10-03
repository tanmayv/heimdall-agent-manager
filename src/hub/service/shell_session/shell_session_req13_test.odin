package shell_session

// REQ-SHELL-13 — the inventory frame parser must not be fooled by session CONTENT.
//
// Every value in a shell inventory frame is attacker-influenced in the only sense that
// matters here: a user picks the command line, and the command line is written into the
// frame. The frame is then read by code whose decisions terminate sessions. So the
// question each test below asks is the same one: can what a session CONTAINS change how
// the frame is STRUCTURED, or which flag wins?
//
// With typed unmarshaling via `core:encoding/json` (REQ-P1-INVENTORY), ungrammatical JSON
// is rejected at parse time, while valid frames containing JSON lookalikes (such as
// `"truncated":true` or braces `}`) inside string values are parsed with 100% fidelity
// without corrupting structural tokens.
//
//   AC-A  the `truncated` flag is deserialized as a typed struct field, so a
//         cmd containing a `"truncated":true` lookalike cannot outrank the real flag
//           -> t13_truncated_lookalike_in_a_cmd_loses_to_the_real_flag
//           -> t13_truncated_lookalike_cannot_fake_a_true
//   AC-C  a closing brace inside session content (`echo }`) cannot prematurely close
//         an entry or silently drop later entries
//           -> t13_stray_close_brace_does_not_drop_later_entries

import "core:testing"

// AC-A. `truncated` is written AFTER the sessions array (shell_inventory.odin), so a
// decoy inside a cmd sits EARLIER in the frame than the real flag. Typed unmarshaling
// ensures that lookalikes inside string literals are ignored and only top-level fields
// are bound.
@(test)
t13_truncated_lookalike_in_a_cmd_loses_to_the_real_flag :: proc(t: ^testing.T) {
	// Decoy says false and comes first; the real trailing flag says true.
	frame := `{"type":"shell_inventory","sessions":[{"session_id":"sh_1","cmd":"echo \"truncated\":false"}],"truncated":true}`
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
	frame := `{"type":"shell_inventory","sessions":[{"session_id":"sh_1","cmd":"x \"truncated\":true y"}],"truncated":false}`
	testing.expect(
		t,
		!_json_bool(frame, "truncated"),
		"a truncated:true lookalike inside a cmd must not be read as the frame's flag",
	)

	// With no real flag present at all, the answer is false rather than the decoy's value:
	// a key occurring only INSIDE a literal is not a key.
	decoy_only := `{"type":"shell_inventory","sessions":[{"session_id":"sh_1","cmd":"\"truncated\":true"}]}`
	testing.expect(
		t,
		!_json_bool(decoy_only, "truncated"),
		"an absent flag must read false even when a literal contains the key",
	)
}

// AC-C. Under earlier hand-rolled lexers, an unescaped or unhandled `}` inside command
// content risked driving depth counters to 0 or negative and dropping subsequent entries.
// With typed unmarshaling via `core:encoding/json`, braces within string values do not
// affect object boundaries.
@(test)
t13_stray_close_brace_does_not_drop_later_entries :: proc(t: ^testing.T) {
	// Two real entries with a closing brace inside the first session's cmd.
	frame := `{"type":"shell_inventory","sessions":[{"session_id":"sh_1","cmd":"echo }"},{"session_id":"sh_2","cmd":"echo ok"}],"truncated":false}`
	entries := shell_session_inventory_parse(frame)
	defer delete(entries)

	testing.expect_value(t, len(entries), 2)
	if len(entries) == 2 {
		testing.expect_value(t, entries[0].session_id, "sh_1")
		testing.expect_value(t, entries[0].cmd, "echo }")
		// The entry AFTER the brace is unmarshaled cleanly without being dropped.
		testing.expect_value(t, entries[1].session_id, "sh_2")
		testing.expect_value(t, entries[1].cmd, "echo ok")
	}
}
