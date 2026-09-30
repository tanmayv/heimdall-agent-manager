package bridge_runtime

// Tests for the hub->bridge command chunker (REQ-SHELL-36).
//
// The property that matters is the ROUND TRIP: base64-decode each frame's
// payload_fragment and concatenate in chunk_index order, and you must get the original
// command back byte-for-byte. Everything else here exists to pin the boundaries where
// the old code silently dropped the command instead.
//
// These drive hub_command_chunk_frames with an EXPLICIT payload rather than the live
// contract constant, so they are deterministic and cheap: the ordering/metadata/
// round-trip logic is proven with a small payload, and the real constant gets its own
// single-frame wire-size bound check.

import "core:net"
import "core:strings"
import "core:testing"
import base64 "core:encoding/base64"
import "odin_test:contracts"
import domain "odin_test:hub/domain"

// _decode_concat rebuilds the original text from a frame set, reading each frame's
// declared chunk_index rather than trusting slice order — so a chunker that emitted
// frames in the wrong order could not pass by accident.
@(private = "file")
_decode_concat :: proc(frames: []string) -> string {
	parts := make([]string, len(frames))
	defer {
		for p in parts do delete(p)
		delete(parts)
	}
	for f in frames {
		idx := _frame_int(f, "chunk_index")
		frag := _frame_string(f, "payload_fragment")
		defer delete(frag)
		decoded, err := base64.decode(frag)
		if err != nil do return ""
		defer delete(decoded)
		if idx < 0 || idx >= len(parts) do return ""
		parts[idx] = strings.clone(string(decoded))
	}
	b := strings.builder_make()
	for p in parts do strings.write_string(&b, p)
	return strings.to_string(b)
}

@(private = "file")
_frame_string :: proc(frame, key: string) -> string {
	needle := strings.concatenate({"\"", key, "\":\""})
	defer delete(needle)
	i := strings.index(frame, needle)
	if i < 0 do return ""
	rest := frame[i + len(needle):]
	end := strings.index_byte(rest, '"')
	if end < 0 do return ""
	return strings.clone(rest[:end])
}

@(private = "file")
_frame_int :: proc(frame, key: string) -> int {
	needle := strings.concatenate({"\"", key, "\":"})
	defer delete(needle)
	i := strings.index(frame, needle)
	if i < 0 do return -1
	rest := frame[i + len(needle):]
	n := 0
	digits := 0
	for j in 0 ..< len(rest) {
		if rest[j] < '0' || rest[j] > '9' do break
		n = n * 10 + int(rest[j] - '0')
		digits += 1
	}
	if digits == 0 do return -1
	return n
}

@(private = "file")
_free_frames :: proc(frames: []string) {
	for f in frames do delete(f)
	delete(frames)
}

@(test)
hub_command_chunk_passes_small_through :: proc(t: ^testing.T) {
	// At or below the payload the command is sent WHOLE (nil frames). The boundary is
	// exact, not approximate: a command of exactly `payload` bytes must not be chunked.
	small := strings.repeat("a", 100)
	defer delete(small)
	frames := hub_command_chunk_frames(small, 100)
	testing.expect(t, frames == nil, "a command of exactly payload bytes must not be chunked")

	exact := strings.repeat("b", 64)
	defer delete(exact)
	f2 := hub_command_chunk_frames(exact, 64)
	testing.expect(t, f2 == nil, "64 bytes at payload 64 must pass through whole")
}

@(test)
hub_command_chunk_round_trips_exactly :: proc(t: ^testing.T) {
	// The core property. A deliberately awkward length (not a multiple of the payload)
	// so the final short chunk is exercised rather than an even split.
	original := strings.repeat("heimdall-chunk-", 700) // 10500 bytes
	defer delete(original)
	payload := 1000
	frames := hub_command_chunk_frames(original, payload)
	testing.expect(t, frames != nil, "an over-payload command must be chunked")
	defer _free_frames(frames)

	testing.expect_value(t, len(frames), 11) // ceil(10500/1000)
	rebuilt := _decode_concat(frames)
	defer delete(rebuilt)
	testing.expect_value(t, len(rebuilt), len(original))
	testing.expect(t, rebuilt == original, "decode+concat in index order must reproduce the command byte-for-byte")
}

@(test)
hub_command_chunk_metadata_is_consistent :: proc(t: ^testing.T) {
	original := strings.repeat("x", 5000)
	defer delete(original)
	frames := hub_command_chunk_frames(original, 1000)
	defer _free_frames(frames)
	testing.expect_value(t, len(frames), 5)

	// Every frame must agree on chunk_count/total_bytes and carry a single shared
	// chunk_id — the hub keys reassembly on it, so a per-frame id would open five
	// streams that never complete.
	first_id := _frame_string(frames[0], "chunk_id")
	defer delete(first_id)
	testing.expect(t, first_id != "", "chunk_id must be present")
	for f, i in frames {
		testing.expect_value(t, _frame_int(f, "chunk_index"), i)
		testing.expect_value(t, _frame_int(f, "chunk_count"), 5)
		testing.expect_value(t, _frame_int(f, "total_bytes"), 5000)
		id := _frame_string(f, "chunk_id")
		defer delete(id)
		testing.expect(t, id == first_id, "every chunk of one stream must share one chunk_id")
		kind := _frame_string(f, "kind")
		defer delete(kind)
		testing.expect_value(t, kind, contracts.BRIDGE_WS_FRAME_KIND_CHUNK)
	}
	// end_stream marks the LAST frame and only the last.
	testing.expect(t, strings.contains(frames[4], `"end_stream":true`), "last frame must set end_stream")
	testing.expect(t, strings.contains(frames[0], `"end_stream":false`), "a non-final frame must not set end_stream")
}

@(test)
hub_command_chunk_ids_are_unique_per_stream :: proc(t: ^testing.T) {
	// Two streams chunked back to back must not share a chunk_id, or the bridge would
	// merge them into one corrupt command. This is why hub_chunk_next_id carries an
	// atomic counter and not only a timestamp: two calls can land in the same nanosecond.
	text := strings.repeat("y", 3000)
	defer delete(text)
	a := hub_command_chunk_frames(text, 1000)
	defer _free_frames(a)
	b := hub_command_chunk_frames(text, 1000)
	defer _free_frames(b)
	ida := _frame_string(a[0], "chunk_id")
	defer delete(ida)
	idb := _frame_string(b[0], "chunk_id")
	defer delete(idb)
	testing.expect(t, ida != idb, "two chunk streams must not share a chunk_id")
}

@(test)
hub_command_every_frame_fits_the_16bit_cap :: proc(t: ^testing.T) {
	// THE WHOLE POINT OF THE CHUNK SIZE. At the LIVE contract payload, every frame this
	// chunker emits must fit under the 16-bit WS length — because the bridge's reader
	// treats a 127 length as FATAL, so a frame over the cap would not merely be dropped,
	// it would KILL the connection. Guards the base64 ~4/3 expansion plus the JSON
	// wrapper, which is exactly the arithmetic the preview tunnel got wrong by one byte.
	payload := contracts.BRIDGE_WS_HUB_TO_BRIDGE_CHUNK_PAYLOAD_BYTES
	original := strings.repeat("z", payload * 3 + 17)
	defer delete(original)
	frames := hub_command_chunk_frames(original, payload)
	defer _free_frames(frames)
	testing.expect(t, len(frames) == 4, "three full chunks plus a short tail")
	for f in frames {
		testing.expect(t, len(f) <= 65535, "a chunk frame over the 16-bit cap would kill the bridge connection, not just drop")
	}
	rebuilt := _decode_concat(frames)
	defer delete(rebuilt)
	testing.expect(t, rebuilt == original, "round trip must hold at the live payload too")
}

@(test)
hub_command_chunkability_matches_the_shared_caps :: proc(t: ^testing.T) {
	payload := contracts.BRIDGE_WS_HUB_TO_BRIDGE_CHUNK_PAYLOAD_BYTES
	// Ordinary large command: deliverable.
	ok_len := payload * 10
	body := strings.repeat("q", ok_len)
	defer delete(body)
	testing.expect(t, hub_command_is_chunkable(body, payload), "a 10-chunk command must be deliverable")

	// >>> THE FALSE CASES. Without these, hub_command_is_chunkable is only ever <<<
	// >>> asserted TRUE, and the guard it feeds could be deleted with the suite   <<<
	// >>> still green -- an over-cap command would then be chunked and written,   <<<
	// >>> the bridge would reject every frame at reassembly, and the hub would    <<<
	// >>> report SUCCESS. Each cap is driven past on its own, so neither arm can  <<<
	// >>> be the only thing refusing.                                             <<<
	//
	// BYTE cap, at the live payload. One byte over is enough; the count cap cannot be
	// what refuses this, because 16 MB at 6000 bytes a chunk is ~2797 chunks, under 4096.
	over_bytes := strings.repeat("b", contracts.BRIDGE_WS_MAX_REASSEMBLY_BYTES + 1)
	defer delete(over_bytes)
	testing.expect(
		t,
		!hub_command_is_chunkable(over_bytes, payload),
		"a command past the reassembly BYTE cap must be refused, not chunked",
	)

	// COUNT cap, ISOLATED with a small payload. At the live payload the byte cap always
	// binds first (see the ordering note below), so driving the count arm past 4096 while
	// staying well under 16 MB is the only way to prove the second arm does any work:
	// 4097 chunks of 100 bytes is 409,700 bytes, ~2.4% of the byte cap.
	small_payload := 100
	over_count := strings.repeat("c", small_payload * (contracts.BRIDGE_WS_MAX_CHUNK_COUNT + 1))
	defer delete(over_count)
	testing.expect_value(
		t,
		hub_command_chunk_count(len(over_count), small_payload),
		contracts.BRIDGE_WS_MAX_CHUNK_COUNT + 1,
	)
	testing.expect(
		t,
		len(over_count) < contracts.BRIDGE_WS_MAX_REASSEMBLY_BYTES,
		"this case must be under the byte cap or it proves nothing about the COUNT arm",
	)
	testing.expect(
		t,
		!hub_command_is_chunkable(over_count, small_payload),
		"a command past the reassembly CHUNK-COUNT cap must be refused, not chunked",
	)

	// The BYTE cap binds before the chunk-count cap at this payload, and that ordering is
	// worth pinning: 4096 * 6000 = 24.5 MB against a 16 MB byte cap, so a command between
	// those is refused by BYTES. Both are checked, so neither can be the only guard.
	testing.expect_value(t, hub_command_chunk_count(0, payload), 0)
	testing.expect_value(t, hub_command_chunk_count(1, payload), 1)
	testing.expect_value(t, hub_command_chunk_count(payload, payload), 1)
	testing.expect_value(t, hub_command_chunk_count(payload + 1, payload), 2)
	// A payload of 0 must not divide by zero or claim deliverability.
	testing.expect_value(t, hub_command_chunk_count(100, 0), 0)
	testing.expect(t, hub_command_chunk_frames("abc", 0) == nil, "a zero payload must refuse rather than loop")
}

@(test)
hub_command_write_refuses_an_over_cap_command_at_the_guard :: proc(t: ^testing.T) {
	// >>> THIS IS THE TEST THAT KILLS THE MUTATION. Asserting the PREDICATE <<<
	// >>> false does not: hub_command_is_chunkable keeps returning false with <<<
	// >>> or without its call site, so deleting the guard in write_ws_command <<<
	// >>> leaves predicate-only assertions green. Only driving write_ws_command <<<
	// >>> itself can tell the fix from its absence.                            <<<
	//
	// Fd 0 is NOT a socket, and that is what makes this work without any I/O setup --
	// the same idiom as write_server_text's Too_Large test in src/lib/ws. The guard sits
	// ABOVE every write, so with it present nothing touches the descriptor and the result
	// is .Too_Large. Delete the guard and the command gets chunked and written instead,
	// the first send fails on ENOTSOCK, and the result is .Send_Failed -- a DIFFERENT
	// value, so this assertion fails. That is the whole point: the two worlds must not
	// produce the same answer.
	//
	// The failure this guards against is worse than the one REQ-SHELL-36 fixes. Without
	// it, a real socket would accept every frame, the bridge would reject them all at
	// hub_command_reassembly.odin:179, write_ws_command would return .Ok, and the hub
	// would report SUCCESS on a command that was silently dropped.
	over_bytes := strings.repeat("b", contracts.BRIDGE_WS_MAX_REASSEMBLY_BYTES + 1)
	defer delete(over_bytes)
	testing.expect_value(t, write_ws_command(net.TCP_Socket(0), over_bytes), Command_Write_Result.Too_Large)

	// And the mapping stays honest end to end: this must not surface as an offline bridge.
	testing.expect_value(
		t,
		command_write_error(write_ws_command(net.TCP_Socket(0), over_bytes)).code,
		domain.Error_Code.Validation_Failed,
	)
}

@(test)
hub_command_write_error_separates_size_from_offline :: proc(t: ^testing.T) {
	// AC1. These two must not be the same error: an operator told "bridge offline" looks
	// at the bridge, the network and the token long before a frame size.
	too_big := command_write_error(.Too_Large)
	send_failed := command_write_error(.Send_Failed)
	testing.expect_value(t, too_big.code, domain.Error_Code.Validation_Failed)
	testing.expect_value(t, send_failed.code, domain.Error_Code.Bridge_Offline)
	testing.expect(t, too_big.code != send_failed.code, "a size failure must be distinguishable from an offline bridge")
	testing.expect(t, strings.contains(too_big.message, "NOT offline"), "the size error must say the bridge is not the problem")
	// .Ok maps to the zero error so a success path cannot accidentally report a failure.
	testing.expect_value(t, command_write_error(.Ok).code, domain.Error_Code.None)
}

@(test)
hub_command_chunk_envelope_carries_no_type_field :: proc(t: ^testing.T) {
	// >>> THE OTHER HALF OF A TWO-SIDED INVARIANT. Read the bridge's <<<
	// >>> hub_command_frame_is_chunk before changing the emitter.    <<<
	//
	// The bridge decides "chunk envelope or command?" with: kind == "chunk" AND NO "type"
	// field. That rests on two facts, and they live on OPPOSITE SIDES of the protocol:
	//   (a) every command carries a "type"  — the bridge's dispatcher switches on it, and
	//       the bridge-side tests cover that half.
	//   (b) a chunk envelope NEVER carries a "type" — THIS SIDE. This emitter is the only
	//       thing that makes (b) true, and nothing else in the tree would notice if it
	//       stopped being true.
	//
	// WHY THIS TEST EXISTS RATHER THAN A COMMENT SAYING "do not add type". Adding
	// `"type":"chunk"` to this envelope is a TEMPTING-LOOKING edit: every other frame on
	// this channel has a "type", so adding one reads as consistency rather than as a
	// protocol break. The moment it lands, hub_command_frame_is_chunk returns FALSE for
	// real chunks, they are routed to the dispatcher instead of the reassembler, match no
	// handler, and are SILENTLY DROPPED — the exact invisible-drop failure REQ-SHELL-36
	// was filed to remove, reached from the opposite direction.
	//
	// So the assertion is on the EMITTER'S OUTPUT, deliberately, and not on the
	// discriminator: a test that went through hub_command_frame_is_chunk would pass by
	// agreeing with itself. This one fails the instant the wire format changes, which is
	// the only place the coupling is real.
	original := strings.repeat("no-type-field-here-", 400)
	defer delete(original)
	frames := hub_command_chunk_frames(original, 1000)
	testing.expect(t, frames != nil, "this must chunk, or the test proves nothing")
	defer _free_frames(frames)
	for f, i in frames {
		testing.expect(
			t,
			!strings.contains(f, `"type"`),
			"a chunk envelope must carry NO \"type\" field: the bridge treats its presence as proof the frame is a COMMAND and would route real chunks to the dispatcher, where they are silently dropped",
		)
		// And the positive half of the same contract, so the discriminator's first
		// condition cannot rot either.
		testing.expect(t, strings.contains(f, `"kind":"chunk"`), "a chunk envelope must carry kind=chunk")
		_ = i
	}
}
