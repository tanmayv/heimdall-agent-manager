package main

// Bridge-side reassembly of chunked hub->bridge COMMANDS (REQ-SHELL-36).
//
// WHAT WAS MISSING. The kind:"chunk" protocol existed in ONE direction only: the
// bridge chunked bridge->hub (bridge_hub_send / bridge_hub_chunk_frames) and the hub
// reassembled (bridge_ws_reassemble_chunk). Nothing reassembled the other way, because
// nothing chunked the other way — the hub's writer simply refused anything over 65535
// bytes and its caller reported that refusal as .Bridge_Offline. So an oversized
// command was dropped and the operator was pointed at a healthy bridge.
//
// The hub's own comment claimed this file already existed: bridge_ws_reassemble_chunk
// said it "Mirrors the bridge's own inbound reassembly (bridge_ws_handle_chunk_skeleton)"
// — a procedure that appeared nowhere in the tree. The symmetry was documented and not
// implemented. This is the implementation; that comment now points here.
//
// >>> THE PROPERTY THIS GUARANTEES: ALL-OR-NOTHING DISPATCH. <<<
// A command is handed to bridge_hub_handle_command only when every chunk slot is filled
// AND the byte total matches what the stream declared. The bridge therefore NEVER acts
// on a partial command, which is the one thing chunking is responsible for and the one
// thing that would violate the chain's core invariant if it were wrong.
//
// WHAT IT DOES NOT CHANGE, stated because the honest boundary matters more than a
// reassuring one. For fire-and-forget commands the hub can still believe "sent" while
// the bridge never ran the command, if the connection dies between the write and the
// read. THAT GAP EXISTS TODAY FOR A SINGLE SMALL FRAME — chunking neither introduces
// nor closes it, and this channel's at-most-once delivery is unchanged. The
// send_runtime_command_wait callers have no such gap: no reply means the hub times out
// and reports failure, so both ends agree the command did not happen. Closing the
// fire-and-forget gap is a delivery-semantics change and is filed separately.
//
// INTERRUPTED BY A RECONNECT. The buffer is per-connection: created in
// bridge_hub_runtime_loop and freed when that loop exits. So a reconnect DISCARDS every
// partial stream rather than carrying it across, and a chunk sequence cut in half is
// simply a command that did not arrive — never half a command that did. A stream whose
// tail never comes is also bounded in TIME, not only in count, so an abandoned stream on
// a long-lived connection cannot pin memory until the connection ends.

import base64 "core:encoding/base64"
import "core:fmt"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"

// Hub_Command_Reassembly buffers the fragments of one in-flight hub->bridge chunk
// stream, keyed by chunk_id. Mirrors the hub's Bridge_Chunk_Reassembly.
Hub_Command_Reassembly :: struct {
	chunk_id:        string,
	chunk_count:     int,
	total_bytes:     int,
	received_chunks: int,
	received_bytes:  int,
	fragments:       []string,
	started_at_ns:   i64,
}

// HUB_COMMAND_REASSEMBLY_TTL bounds how long an INCOMPLETE stream is kept, measured
// from its FIRST chunk. Matches the hub's BRIDGE_WS_REASSEMBLY_TTL so neither end
// abandons a stream the other still considers live.
//
// Like the hub's, this is an AGE limit and not an idle timeout, and the same narrow gap
// follows: a stream still arriving steadily but slower than the TTL overall is expired
// mid-flight, and its remaining chunks open a fresh partial that never completes. It is
// tolerable for the same reason — the hub writes one command's chunks back to back under
// the registry command lock, so a stream this old has almost certainly been abandoned.
// REQ-SHELL-43 tracks making both ends idle-based; deliberately NOT diverging here,
// because two ends with different expiry rules is worse than two with the same flawed one.
HUB_COMMAND_REASSEMBLY_TTL :: 30 * time.Second

// hub_command_reassembly_free releases one entry's owned strings and removes it.
// Order among the remaining streams is irrelevant.
hub_command_reassembly_free :: proc(buf: ^[dynamic]Hub_Command_Reassembly, idx: int) {
	for frag in buf[idx].fragments do delete(frag)
	delete(buf[idx].fragments)
	delete(buf[idx].chunk_id)
	unordered_remove(buf, idx)
}

// hub_command_reassemblies_free drops every buffered (incomplete) stream when the
// connection ends, so a mid-stream reconnect leaks nothing. THIS IS ALSO THE
// MECHANISM that makes an interrupted sequence a non-event: the partial dies here.
hub_command_reassemblies_free :: proc(buf: ^[dynamic]Hub_Command_Reassembly) {
	for i in 0 ..< len(buf) {
		for frag in buf[i].fragments do delete(frag)
		delete(buf[i].fragments)
		delete(buf[i].chunk_id)
	}
	delete(buf^)
}

// hub_command_reassembly_sweep drops every stream past its TTL, returning how many.
// Swept LAZILY at the admission gate rather than by a timer: the buffer is reached only
// from its own connection's read loop, so a lazy sweep needs no lock and cannot outlive
// what it walks.
hub_command_reassembly_sweep :: proc(buf: ^[dynamic]Hub_Command_Reassembly, now_ns: i64) -> int {
	dropped := 0
	for i := len(buf) - 1; i >= 0; i -= 1 {
		if now_ns - buf[i].started_at_ns >= i64(HUB_COMMAND_REASSEMBLY_TTL) {
			hub_command_reassembly_free(buf, i)
			dropped += 1
		}
	}
	return dropped
}

// hub_command_reassembly_oldest returns the index of the oldest stream, or -1.
hub_command_reassembly_oldest :: proc(buf: ^[dynamic]Hub_Command_Reassembly) -> int {
	idx := -1
	for i in 0 ..< len(buf) {
		if idx < 0 || buf[i].started_at_ns < buf[idx].started_at_ns do idx = i
	}
	return idx
}

// hub_command_frame_is_chunk reports whether a frame is a chunk ENVELOPE rather than a
// command. A false positive here is not cosmetic: the frame would be fed to the
// reassembler, rejected as malformed, and the command SILENTLY DROPPED — the very
// failure mode REQ-SHELL-36 exists to remove.
//
// >>> "kind" ALONE IS NOT A SAFE DISCRIMINATOR, WHICH IS WHY "type" IS ALSO CHECKED. <<<
// The obvious implementation — kind == "chunk" — looks right and is one commit away from
// being wrong. extract_json_string finds the FIRST "kind" ANYWHERE in the frame, and
// hub->bridge commands on THIS channel genuinely do carry a "kind" field today:
// _shell_start_command_json (shell_session_service.odin) emits
// {"type":"shell_start",...,"kind":"run"|"shell"|"server",...}. Its value is never the
// literal "chunk", so kind-only happens to work TODAY — but it would start swallowing a
// real command the day anyone adds a nested kind whose value is "chunk", and the symptom
// would be a command that silently never arrives.
//
// (The agent bootstrap manifest also nests kind:"AGENTS_TEMPLATE"/"AGENTS_MD"/"SKILL",
// but it is served over HTTP REST — bridge_handlers.odin respond_success — and never
// travels this WS command path, so it is NOT an example of the hazard. Named here only
// because it is the first thing a grep for '"kind"' turns up, and mistaking it for a
// command on this channel would be an easy error to inherit.)
//
// So the test is BOTH halves: a chunk envelope has kind == "chunk" AND carries NO "type"
// at all, while every hub->bridge command has a "type" (it is what the dispatcher
// switches on — a command without one could not be handled). Requiring the absence of
// "type" means a false positive would need a command that the dispatcher could not
// route anyway.
hub_command_frame_is_chunk :: proc(text: string) -> bool {
	kind := extract_json_string(text, "kind", "")
	defer delete(kind)
	if kind != contracts.BRIDGE_WS_FRAME_KIND_CHUNK do return false
	type := extract_json_string(text, "type", "")
	defer delete(type)
	return type == ""
}

// hub_command_reassemble ingests one kind:"chunk" frame and, once the stream is
// complete, returns the reassembled original command text (caller owns it).
//
// Returns (assembled, complete, ok):
//   ok=false       -> malformed or over-cap: caller DROPS the frame, no dispatch
//   complete=false -> buffered, awaiting more chunks: caller continues
//   complete=true  -> assembled is the full command text to dispatch
//
// ACK-LESS, matching the other direction: this channel has no chunk_ack path, and the
// hub holds the registry command lock across a whole sequence, so the chunks arrive in
// order on a single ordered connection and per-chunk acks would be pure latency.
hub_command_reassemble :: proc(buf: ^[dynamic]Hub_Command_Reassembly, text: string) -> (assembled: string, complete: bool, ok: bool) {
	// extract_json_string allocates (it unescapes into a builder), so both transient
	// lookups are freed here: chunk_id is cloned into the buffer and the fragment is
	// decoded, so neither is retained. Leaking per chunk would defeat the point of
	// chunking a large command.
	chunk_id := extract_json_string(text, "chunk_id", "")
	defer delete(chunk_id)
	fragment_b64 := extract_json_string(text, "payload_fragment", "")
	defer delete(fragment_b64)
	chunk_index := extract_json_int(text, "chunk_index", -1)
	chunk_count := extract_json_int(text, "chunk_count", 0)
	total_bytes := extract_json_int(text, "total_bytes", 0)
	if chunk_id == "" || chunk_index < 0 || chunk_count <= 0 || chunk_index >= chunk_count || total_bytes <= 0 || fragment_b64 == "" {
		return "", false, false
	}
	// Contract caps, checked BEFORE allocating: a malformed or hostile stream must not
	// be able to make the bridge reserve memory for it. Shared constants rather than
	// local numbers so the two ends cannot drift about what is deliverable.
	if chunk_count > contracts.BRIDGE_WS_MAX_CHUNK_COUNT || chunk_count > total_bytes || total_bytes > contracts.BRIDGE_WS_MAX_REASSEMBLY_BYTES {
		return "", false, false
	}
	decoded, derr := base64.decode(fragment_b64)
	if derr != nil || len(decoded) == 0 do return "", false, false
	defer delete(decoded)
	decoded_text := string(decoded)

	idx := -1
	for i in 0 ..< len(buf) {
		if buf[i].chunk_id == chunk_id { idx = i; break }
	}
	// Whether THIS call opened the stream. Load-bearing below: a first fragment that is
	// then rejected must not leave the entry it just created behind as an orphan, while a
	// bad fragment arriving for a stream that ALREADY existed must leave that stream
	// alone. Caught by hub_command_reassemble_rejects_malformed_and_over_cap, which found
	// a buffered entry surviving a frame whose fragment exceeded its declared total.
	created := idx < 0
	if idx < 0 {
		// Bound concurrent reassemblies. EXPIRE FIRST, then fall back to evicting the
		// oldest — and never REFUSE. Refusing is what turned the hub's identical cap
		// into a countdown under REQ-SHELL-32: nothing removed incomplete entries, so
		// once the array filled, every chunked frame was dropped forever while the
		// connection looked perfectly healthy (small frames never touch this path).
		// Evicting can drop a stream that was still legitimately in flight, so it is
		// the fallback rather than the first response, and it is logged differently
		// because "stale" and "still arriving" are different diagnoses.
		now_ns := time.to_unix_nanoseconds(time.now())
		if len(buf) >= contracts.BRIDGE_WS_MAX_REASSEMBLIES {
			if expired := hub_command_reassembly_sweep(buf, now_ns); expired > 0 {
				fmt.eprintfln(
					"ham-bridge WARN hub command reassembly expired streams=%d ttl=%v (admission gate)",
					expired, HUB_COMMAND_REASSEMBLY_TTL)
			}
		}
		if len(buf) >= contracts.BRIDGE_WS_MAX_REASSEMBLIES {
			oldest := hub_command_reassembly_oldest(buf)
			if oldest < 0 do return "", false, false
			fmt.eprintfln(
				"ham-bridge WARN hub command reassembly full in_flight=%d none_expired evicting_oldest chunk_id=%s progress=%d/%d to_admit=%s",
				len(buf), buf[oldest].chunk_id, buf[oldest].received_chunks,
				buf[oldest].chunk_count, chunk_id)
			hub_command_reassembly_free(buf, oldest)
		}
		append(buf, Hub_Command_Reassembly{
			chunk_id      = strings.clone(chunk_id),
			chunk_count   = chunk_count,
			total_bytes   = total_bytes,
			fragments     = make([]string, chunk_count),
			started_at_ns = now_ns,
		})
		idx = len(buf) - 1
	}
	// Conflicting metadata for the same chunk_id: drop this frame, keep the stream.
	if buf[idx].chunk_count != chunk_count || buf[idx].total_bytes != total_bytes {
		return "", false, false
	}
	// Duplicate/retransmit: fill an EMPTY slot only, and never exceed the declared
	// total. Both halves matter — without the empty-slot check a retransmit would
	// double-count received_chunks and complete the stream early with a hole in it.
	if buf[idx].fragments[chunk_index] == "" {
		if buf[idx].received_bytes + len(decoded_text) > buf[idx].total_bytes {
			// The stream declared fewer bytes than its fragments carry: it is malformed,
			// not merely late. Drop the entry if this call created it, so a malformed
			// sender cannot leave orphans occupying reassembly slots; keep it if the
			// stream predates this frame, so ONE bad frame cannot cancel a good command.
			if created do hub_command_reassembly_free(buf, idx)
			return "", false, false
		}
		buf[idx].fragments[chunk_index] = strings.clone(decoded_text)
		buf[idx].received_chunks += 1
		buf[idx].received_bytes += len(decoded_text)
	}
	if buf[idx].received_chunks == buf[idx].chunk_count {
		// Belt and braces against a stream that filled every slot but does not add up.
		// Cannot happen given the two guards above; if it ever does, DROP the command
		// rather than dispatch a command we cannot vouch for.
		if buf[idx].received_bytes != buf[idx].total_bytes {
			hub_command_reassembly_free(buf, idx)
			return "", false, false
		}
		b := strings.builder_make()
		for frag in buf[idx].fragments do strings.write_string(&b, frag)
		out := strings.to_string(b)
		hub_command_reassembly_free(buf, idx)
		return out, true, true
	}
	return "", false, true
}
