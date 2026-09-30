package bridge_runtime

// Hub->bridge command chunking (REQ-SHELL-36).
//
// THE DEFECT THIS EXISTS FOR. write_ws_text_frame refuses any payload over 65535
// bytes, and its caller turned that `false` into .Bridge_Offline — so an oversized
// command was DROPPED and the operator was told the bridge was down while the bridge
// was perfectly healthy. `send_lsp_message` routes a whole JSON-RPC message through
// that writer, and a textDocument/didOpen carrying a large file is exactly that case.
//
// WHY CHUNKING AND NOT A 64-BIT LENGTH ARM. The 16-bit bound on this channel is a
// DELIBERATE INVARIANT, not an oversight. Our own readers stop at the 126/2-byte
// extended length: ws.odin's take_text sets conn.connected = false on a 127 length and
// the hub's bridge_ws_take_frame returns fatal=true on it. Emitting a 64-bit frame
// toward a bridge would therefore convert a dropped frame into a KILLED bridge
// connection — strictly worse than the bug. server_frame.odin states the same rule in
// prose. So the frame stays under the cap and the SPLIT happens above it, which is
// what the bridge->hub direction has always done.
//
// THIS IS THE MIRROR OF AN EXISTING PROTOCOL, NOT A NEW ONE. The bridge has chunked
// bridge->hub since REQ-SHELL-32 (bridge_hub_chunk_frames / bridge_hub_send) and the
// hub reassembles it (bridge_ws_reassemble_chunk). Only the hub->bridge direction was
// missing. The frame shape emitted here is the SUBSET the reassembler reads, and the
// reassembler accepts both shapes — so the two directions are one protocol rather than
// two that resemble each other. It is NOT byte-for-byte identical: this emitter writes
// 8 fields, the bridge's bridge_ws_chunk_json writes 14, omitting frame_id, stream_id,
// src_daemon_id, dest_daemon_id, original_kind and idempotency_key. That is not a
// defect — the reassembler is superset-tolerant and the interop test below pins it —
// but do not read this comment as a promise that a given field is on the wire.
//
// >>> THIS FILE MUST NOT TOUCH THE TEMP ALLOCATOR. READ send_runtime_command_wait <<<
// FIRST. That procedure clones command_id AFTER the frame write, and its comment
// states plainly that the placement is safe ONLY BECAUSE the writing path allocates on
// context.allocator (heap) and never advances the per-thread temp ring. A single
// fmt.tprintf in here would silently invalidate that argument: the clone would still be
// there, still read as correct, and protect nothing, and NO TEST WOULD FAIL. That is
// why the integers below go through strconv.write_int into STACK buffers instead of the
// fmt.tprintf that would be the obvious way to write this.

import "core:encoding/base64"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import "odin_test:contracts"

// _hub_chunk_seq disambiguates two chunk streams started in the same nanosecond.
// Atomic because several request threads can be writing commands to different
// bridges at once.
@(private = "file")
_hub_chunk_seq: u64

// hub_chunk_next_id returns a process-unique chunk stream id. Heap-allocated; the
// caller owns it. No temp allocator — see the file header.
hub_chunk_next_id :: proc() -> string {
	n := sync.atomic_add(&_hub_chunk_seq, 1)
	ns_buf: [32]byte
	seq_buf: [32]byte
	ns := strconv.write_int(ns_buf[:], time.to_unix_nanoseconds(time.now()), 10)
	seq := strconv.write_int(seq_buf[:], i64(n), 10)
	return strings.concatenate({"hubcmd", ns, "_", seq})
}

// hub_command_chunk_count is the number of chunks `total` bytes needs at `payload`
// bytes each. Split out so the count is testable on its own and so the framing loop
// and the cap check below cannot disagree about it.
hub_command_chunk_count :: proc(total, payload: int) -> int {
	if payload <= 0 do return 0
	return (total + payload - 1) / payload
}

// hub_command_chunk_frames returns the ordered kind:"chunk" wire frames for `text`,
// or nil when `text` already fits in one frame (send it whole). Pure and socket-free
// so the round-trip property — base64-decode each frame's payload_fragment, concat in
// index order, get `text` back exactly — is unit-testable without a bridge.
//
// Caller owns the returned slice AND every string in it.
hub_command_chunk_frames :: proc(text: string, payload: int) -> []string {
	if payload <= 0 do return nil
	if len(text) <= payload do return nil
	chunk_count := hub_command_chunk_count(len(text), payload)
	chunk_id := hub_chunk_next_id()
	defer delete(chunk_id)
	frames := make([]string, chunk_count)
	for i in 0 ..< chunk_count {
		start := i * payload
		end := start + payload
		if end > len(text) do end = len(text)
		fragment := base64.encode(transmute([]byte)text[start:end])
		frames[i] = hub_command_chunk_json(chunk_id, i, chunk_count, len(text), string(fragment))
		delete(fragment)
	}
	return frames
}

// hub_command_chunk_json builds one chunk frame. The field set is the SUBSET of the
// bridge's bridge_ws_chunk_json that the reassembler actually reads — 8 fields here
// against its 14 — and the reassembler accepts both shapes, so both directions are the
// same protocol. Not a mirror image; see the header note for the six omitted fields.
//
// The fragment needs no JSON escaping: it is base64, whose alphabet contains no quote,
// no backslash and no control byte. That is a property of the encoding rather than an
// assumption about the payload, which is why there is no escape pass here — and why
// the ~4/3 expansion is the ONLY expansion the chunk size has to budget for.
hub_command_chunk_json :: proc(chunk_id: string, chunk_index, chunk_count, total_bytes: int, fragment: string) -> string {
	b := strings.builder_make()
	ibuf: [32]byte
	strings.write_string(&b, `{"version":`)
	strings.write_string(&b, strconv.write_int(ibuf[:], i64(contracts.BRIDGE_WS_FRAME_VERSION), 10))
	strings.write_string(&b, `,"kind":"`)
	strings.write_string(&b, contracts.BRIDGE_WS_FRAME_KIND_CHUNK)
	strings.write_string(&b, `","chunk_id":"`)
	strings.write_string(&b, chunk_id)
	strings.write_string(&b, `","chunk_index":`)
	strings.write_string(&b, strconv.write_int(ibuf[:], i64(chunk_index), 10))
	strings.write_string(&b, `,"chunk_count":`)
	strings.write_string(&b, strconv.write_int(ibuf[:], i64(chunk_count), 10))
	strings.write_string(&b, `,"total_bytes":`)
	strings.write_string(&b, strconv.write_int(ibuf[:], i64(total_bytes), 10))
	strings.write_string(&b, `,"payload_fragment":"`)
	strings.write_string(&b, fragment)
	strings.write_string(&b, `","end_stream":`)
	strings.write_string(&b, "true" if chunk_index + 1 == chunk_count else "false")
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

// hub_command_is_chunkable reports whether `text` can be carried at all, i.e. whether
// it fits inside the reassembly caps the BRIDGE will enforce on the other end. Checked
// on the hub so an impossible payload is refused with a precise error at the source
// rather than becoming a stream the bridge silently drops.
//
// Both caps are shared constants rather than local numbers precisely so the two ends
// cannot drift into disagreeing about what is deliverable.
hub_command_is_chunkable :: proc(text: string, payload: int) -> bool {
	if len(text) > contracts.BRIDGE_WS_MAX_REASSEMBLY_BYTES do return false
	return hub_command_chunk_count(len(text), payload) <= contracts.BRIDGE_WS_MAX_CHUNK_COUNT
}
