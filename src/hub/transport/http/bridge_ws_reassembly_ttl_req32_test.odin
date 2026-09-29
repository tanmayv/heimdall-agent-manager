package http

import "core:fmt"
import "core:testing"
import "core:time"
import base64 "core:encoding/base64"
import contracts "odin_test:contracts"

// REQ-SHELL-32 regression tests for the chunk-reassembly admission gate.
//
// THE DEFECT THESE PIN. `bridge_ws_reassemble_chunk` refused every new stream once
// BRIDGE_WS_MAX_REASSEMBLIES entries were buffered, and NOTHING ever removed an
// incomplete entry — it was freed only when the whole bridge connection ended. So the
// cap was not a bound on concurrency, it was a COUNTDOWN: 64 abandoned streams over a
// connection's life and every subsequent chunked frame was refused for good, silently.
// Chunking applies only above BRIDGE_WS_HUB_RUNTIME_CHUNK_PAYLOAD_BYTES, so the
// connection went on looking healthy — small frames never touch this path — while
// every large frame was dropped.

@(private = "file")
ttl_chunk_frame :: proc(chunk_id: string, index, count, total: int, raw: []byte) -> string {
	fragment := base64.encode(raw)
	defer delete(fragment)
	end := "true" if index + 1 == count else "false"
	return fmt.aprintf(
		`{{"version":1,"kind":"chunk","frame_id":"f","stream_id":"%s","src_daemon_id":"d","dest_daemon_id":"","original_kind":"frame","idempotency_key":"","chunk_id":"%s","chunk_index":%d,"chunk_count":%d,"total_bytes":%d,"payload_fragment":"%s","end_stream":%s}}`,
		chunk_id, chunk_id, index, count, total, fragment, end,
	)
}

// Fill the array with `n` streams that declare 2 chunks and send only chunk 0, so each
// one is admitted and then never completes — exactly what a lost chunk leaves behind.
@(private = "file")
ttl_abandon_streams :: proc(reassemblies: ^[dynamic]Bridge_Chunk_Reassembly, n: int) {
	for i in 0 ..< n {
		id := fmt.aprintf("abandoned_%d", i)
		defer delete(id)
		frame := ttl_chunk_frame(id, 0, 2, 8, transmute([]byte)string("AAAA"))
		defer delete(frame)
		_, complete, ok := bridge_ws_reassemble_chunk(reassemblies, frame)
		if !ok || complete do break
	}
}

// AC4 PRIMARY: with the gate full of abandoned streams, the NEXT valid stream must
// still reassemble. This is the test that fails before the fix — the 65th stream was
// refused at the gate and its frame silently dropped.
@(test)
req32_gate_full_of_abandoned_streams_still_admits_a_new_one :: proc(t: ^testing.T) {
	reassemblies := make([dynamic]Bridge_Chunk_Reassembly)
	defer bridge_chunk_reassemblies_free(&reassemblies)

	ttl_abandon_streams(&reassemblies, contracts.BRIDGE_WS_MAX_REASSEMBLIES)
	testing.expect_value(t, len(reassemblies), contracts.BRIDGE_WS_MAX_REASSEMBLIES)

	// A complete, well-formed single-chunk stream arriving at a full gate.
	original := `{"type":"shell_pty_output","session_id":"s1","data_b64":"QUJD"}`
	frame := ttl_chunk_frame("fresh", 0, 1, len(original), transmute([]byte)original)
	defer delete(frame)
	assembled, complete, ok := bridge_ws_reassemble_chunk(&reassemblies, frame)
	defer if complete do delete(assembled)

	testing.expect(t, ok, "a full gate must not refuse a new stream forever (REQ-SHELL-32)")
	testing.expect(t, complete, "the single-chunk stream should complete immediately")
	testing.expect_value(t, assembled, original)
}

// AC4 SECONDARY: assert the ENTRY IS GONE once past its deadline, not merely that
// admission still works. Without this a future change could satisfy the test above by
// raising the cap from 64 to 65 and leave the leak and the countdown intact.
@(test)
req32_expired_reassembly_entry_is_actually_removed :: proc(t: ^testing.T) {
	reassemblies := make([dynamic]Bridge_Chunk_Reassembly)
	defer bridge_chunk_reassemblies_free(&reassemblies)

	ttl_abandon_streams(&reassemblies, 3)
	testing.expect_value(t, len(reassemblies), 3)

	// Sweeping at "now" must keep them: they are well inside the TTL.
	now_ns := time.to_unix_nanoseconds(time.now())
	testing.expect_value(t, bridge_chunk_reassembly_sweep(&reassemblies, now_ns), 0)
	testing.expect_value(t, len(reassemblies), 3)

	// Sweeping one nanosecond past the TTL must drop every one of them, and the array
	// must actually shrink — the entry is freed, not just skipped.
	expired_ns := now_ns + i64(BRIDGE_WS_REASSEMBLY_TTL) + 1
	testing.expect_value(t, bridge_chunk_reassembly_sweep(&reassemblies, expired_ns), 3)
	testing.expect_value(t, len(reassemblies), 0)
}

// A YOUNG stream that is still being filled must not be expired out from under itself.
// NAMED FOR WHAT IT ACTUALLY ASSERTS: it sweeps at time.now(), well inside the TTL, so
// it proves only that a sweep does not drop a stream that has not aged out. It does NOT
// establish "the TTL bounds abandonment, not throughput" — an earlier version of this
// comment claimed that, and the clock cannot deliver it, because started_at_ns is
// first-chunk and never refreshed (see BRIDGE_WS_REASSEMBLY_TTL). A stream arriving
// steadily for longer than the TTL is expired mid-flight; no test here covers that, and
// that is the known gap, not an oversight.
@(test)
req32_young_in_flight_stream_survives_a_sweep_and_still_completes :: proc(t: ^testing.T) {
	reassemblies := make([dynamic]Bridge_Chunk_Reassembly)
	defer bridge_chunk_reassemblies_free(&reassemblies)

	original := `{"type":"shell_pty_output","session_id":"s2","data_b64":"WVla"}`
	half := len(original) / 2
	first := ttl_chunk_frame("live", 0, 2, len(original), transmute([]byte)original[:half])
	defer delete(first)
	_, complete, ok := bridge_ws_reassemble_chunk(&reassemblies, first)
	testing.expect(t, ok && !complete, "first of two chunks buffers")

	testing.expect_value(t, bridge_chunk_reassembly_sweep(&reassemblies, time.to_unix_nanoseconds(time.now())), 0)

	second := ttl_chunk_frame("live", 1, 2, len(original), transmute([]byte)original[half:])
	defer delete(second)
	assembled, complete2, ok2 := bridge_ws_reassemble_chunk(&reassemblies, second)
	defer if complete2 do delete(assembled)
	testing.expect(t, ok2 && complete2, "second chunk completes the stream")
	testing.expect_value(t, assembled, original)
	testing.expect_value(t, len(reassemblies), 0)
}
