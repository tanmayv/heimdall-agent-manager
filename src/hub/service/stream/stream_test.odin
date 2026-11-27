package stream

import "core:testing"
import contracts "odin_test:contracts"

@(test)
test_stream_snapshots_drop_whole_stale_frames :: proc(t: ^testing.T) {
	r: Route
	defer delete(r.partial)
	defer delete(r.latest)
	r.ready, r.viewers = true, 1
	r.info.expires = 20_000
	push := proc(r: ^Route, seq: u64, i, n: u16, payload: string) {
		accept_piece(r, {"", seq, i, n, contracts.STREAM_MIME_JPEG, transmute([]byte)payload}, 10_000)
	}
	push(&r, 1, 0, 1, "one")
	first, first_seq, first_version := snapshot(&r, 0)
	defer delete(first)
	testing.expect_value(t, first_seq, u64(1))
	push(&r, 2, 0, 1, "two")
	push(&r, 3, 0, 2, "three-")
	push(&r, 4, 1, 2, "out-of-order-tail")
	late, late_seq, _ := snapshot(&r, 0)
	defer delete(late)
	testing.expect_value(t, late_seq, u64(2))
	testing.expect_value(t, string(late), "two")
	push(&r, 5, 0, 2, "five-")
	push(&r, 5, 1, 2, "complete")
	last, last_seq, last_version := snapshot(&r, first_version)
	defer delete(last)
	testing.expect_value(t, string(first), "one")
	testing.expect_value(t, last_seq, u64(5))
	testing.expect_value(t, string(last), "five-complete")
	unchanged, _, _ := snapshot(&r, last_version)
	defer delete(unchanged)
	testing.expect(t, unchanged == nil, "a viewer doesn't queue or resend already-seen frames")
}

@(test)
test_stream_registration_cap_and_generation_replacement :: proc(t: ^testing.T) {
	reg: Registry
	defer destroy(&reg)
	r := contracts.Stream_Registration{bridge = "bridge_a", owner = "alice", expires = 100}
	ids := []string{"a", "b", "c", "d"}
	for id in ids {
		r.stream_id = id
		testing.expect_value(t, register(&reg, r, 7, 1), "")
	}
	r.stream_id = "a"
	testing.expect_value(t, register(&reg, r, 7, 1), "duplicate")
	r.stream_id = "e"
	testing.expect_value(t, register(&reg, r, 7, 1), "limit")
	r.stream_id = "a"
	serial := reg.routes["a"].serial
	testing.expect_value(t, register(&reg, r, 8, 2), "")
	testing.expect_value(t, len(reg.routes), 1)
	testing.expect(t, reg.routes["a"].serial != serial)
	prune(&reg, 2, "bridge_a", 7)
	testing.expect_value(t, len(reg.routes), 1)
	prune(&reg, 100)
	testing.expect_value(t, len(reg.routes), 0)
}
