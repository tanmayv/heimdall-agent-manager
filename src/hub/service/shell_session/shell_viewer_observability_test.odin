package shell_session

import "core:testing"
import ws "odin_test:lib/ws"

// REQ-SHELL-41 (P0 addendum). The trio the coordinator asked for, each pinned:
// detach reasons, the write-result mapping, and the once-only first frame.

@(private = "file")
reset_first_frame :: proc() {
	shell_first_frame_tracker.slots = {}
	shell_first_frame_tracker.next = 0
}

// Every detach reason must render distinctly — a detach line whose reasons collide would
// not answer "why did this viewer go away".
@(test)
shell_viewer_detach_reasons_are_distinct :: proc(t: ^testing.T) {
	reasons := []Shell_Viewer_Detach_Reason{.Unspecified, .Stream_Closed, .Peer_Gone, .Desynchronised}
	seen := make([dynamic]string)
	defer delete(seen)
	for r in reasons {
		str := shell_viewer_detach_reason_string(r)
		testing.expect(t, len(str) > 0)
		for prior in seen do testing.expect(t, prior != str, "two detach reasons render identically")
		append(&seen, str)
	}
}

// The two write results that END a session must map onto forced detach reasons, and the
// two that do NOT end it must never be reported as a forced detach.
@(test)
shell_detach_reason_tracks_the_write_result :: proc(t: ^testing.T) {
	testing.expect_value(t, _detach_reason_for_write(.Peer_Gone), Shell_Viewer_Detach_Reason.Peer_Gone)
	testing.expect_value(t, _detach_reason_for_write(.Desynchronised), Shell_Viewer_Detach_Reason.Desynchronised)
	testing.expect_value(t, _detach_reason_for_write(.Ok), Shell_Viewer_Detach_Reason.Unspecified)
	testing.expect_value(t, _detach_reason_for_write(.Too_Large), Shell_Viewer_Detach_Reason.Unspecified)
}

// THE INVARIANT THAT KEEPS THIS OFF THE PER-FRAME PATH (AC3): arming yields exactly ONE
// true, no matter how many frames follow.
@(test)
shell_first_frame_fires_exactly_once_per_attach :: proc(t: ^testing.T) {
	reset_first_frame()
	defer reset_first_frame()
	shell_first_frame_arm("sh_once")
	testing.expect(t, shell_first_frame_take("sh_once"), "the first frame must be reported")
	for i in 0 ..< 500 {
		testing.expect(t, !shell_first_frame_take("sh_once"), "only the FIRST frame may be reported")
	}
}

// A session that was never armed must stay silent, so an unrelated session's frames can
// never produce a first-frame line.
@(test)
shell_first_frame_is_silent_without_an_attach :: proc(t: ^testing.T) {
	reset_first_frame()
	defer reset_first_frame()
	testing.expect(t, !shell_first_frame_take("sh_never_attached"))
}

// A RE-attach re-arms: a session whose viewers went 0->1->0->1 must report the first
// frame of the SECOND attach too, since that is a fresh "did anything arrive" question.
@(test)
shell_first_frame_rearms_on_reattach :: proc(t: ^testing.T) {
	reset_first_frame()
	defer reset_first_frame()
	shell_first_frame_arm("sh_re")
	testing.expect(t, shell_first_frame_take("sh_re"))
	testing.expect(t, !shell_first_frame_take("sh_re"))
	shell_first_frame_arm("sh_re")
	testing.expect(t, shell_first_frame_take("sh_re"), "a re-attach must re-arm the first-frame log")
}

// Sessions must not share the one-shot: arming one may not consume another's.
@(test)
shell_first_frame_is_per_session :: proc(t: ^testing.T) {
	reset_first_frame()
	defer reset_first_frame()
	shell_first_frame_arm("sh_a")
	shell_first_frame_arm("sh_b")
	testing.expect(t, shell_first_frame_take("sh_a"))
	testing.expect(t, shell_first_frame_take("sh_b"), "sh_b's one-shot was consumed by sh_a")
}

// More concurrent sessions than slots must degrade by eviction rather than by corrupting
// the table or reporting a stale session's frame.
@(test)
shell_first_frame_survives_more_sessions_than_slots :: proc(t: ^testing.T) {
	reset_first_frame()
	defer reset_first_frame()
	ids := make([dynamic]string)
	defer { for s in ids do delete(s); delete(ids) }
	for i in 0 ..< SHELL_FIRST_FRAME_SLOTS * 2 {
		id := session_id_for_test(i)
		append(&ids, id)
		shell_first_frame_arm(id)
	}
	// The most recently armed sessions survive eviction and still report once.
	last := ids[len(ids) - 1]
	testing.expect(t, shell_first_frame_take(last), "the newest armed session must still fire")
	testing.expect(t, !shell_first_frame_take(last))
}

@(private = "file")
session_id_for_test :: proc(n: int) -> string {
	digits := "0123456789"
	buf: [24]byte
	copy(buf[:], "sh_")
	i := len(buf)
	v := n
	if v == 0 {
		i -= 1
		buf[i] = '0'
	}
	for v > 0 {
		i -= 1
		buf[i] = digits[v % 10]
		v /= 10
	}
	out := make([]byte, 3 + (len(buf) - i))
	copy(out[:3], "sh_")
	copy(out[3:], buf[i:])
	return string(out)
}

// Unused-import guard: the write-result mapping above is the only user of ws here.
@(test)
shell_write_result_enum_is_reachable :: proc(t: ^testing.T) {
	r := ws.Text_Write_Result.Ok
	testing.expect_value(t, r, ws.Text_Write_Result.Ok)
}
