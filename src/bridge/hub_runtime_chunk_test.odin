package main

// Tests for the bridge->hub outbound chunker. A frame larger than the per-message
// chunk payload must be split into ordered kind:"chunk" frames that (a) each stay
// under the single-WS-frame limit on the wire and (b) reconstruct the original
// byte-for-byte when their base64 payload_fragments are decoded and concatenated in
// index order. Small frames must pass through whole.
//
// SOCAT-1: the LIVE chunk payload is gated on the TLS backend (HAM_TLS_BACKEND) via
// bridge_hub_runtime_chunk_payload_bytes():
//   - s_client (legacy fallback): BRIDGE_WS_HUB_RUNTIME_CHUNK_PAYLOAD_BYTES (6000),
//     under the ~16 KB edge-proxy per-message cap.
//   - socat (default): BRIDGE_WS_HUB_RUNTIME_CHUNK_PAYLOAD_BYTES_SOCAT (45000),
//     safe because socat does not tear down on multi-read bursts; each frame still
//     stays under the 65535-byte single-WS-frame limit.
//
// These drive the pure bridge_hub_chunk_frames_with_payload core with an EXPLICIT
// payload so they are (a) deterministic, (b) free of global-env mutation (the Odin
// test runner runs tests concurrently — env mutation would race other tests), and
// (c) cheap: the ordering/metadata/round-trip logic is proven with a tiny payload,
// and the two real backend payloads get a single-frame wire-size bound check.

import "core:strings"
import "core:testing"
import base64 "core:encoding/base64"
import contracts "odin_test:contracts"

@(test)
hub_chunk_frames_passes_small_through :: proc(t: ^testing.T) {
	// <= payload is sent whole (nil); the boundary is exact.
	whole := strings.repeat("x", 200); defer delete(whole)
	testing.expect(t, bridge_hub_chunk_frames_with_payload(whole, 200) == nil)
	testing.expect(t, bridge_hub_chunk_frames_with_payload(whole, 201) == nil)
	// one byte over the payload chunks.
	testing.expect(t, bridge_hub_chunk_frames_with_payload(whole, 199) != nil)
}

@(test)
hub_chunk_frames_splits_and_roundtrips :: proc(t: ^testing.T) {
	// Tiny payload proves the algorithm cheaply: ordering, per-frame metadata, and a
	// byte-exact base64 round-trip across multiple chunks incl. a short final one.
	payload := 200
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	for i in 0 ..< (payload * 2 + 37) { strings.write_byte(&b, byte('A' + (i % 26))) } // vary bytes
	original := strings.to_string(b)

	frames := bridge_hub_chunk_frames_with_payload(original, payload)
	testing.expect(t, frames != nil)
	defer { for f in frames do delete(f); delete(frames) }
	testing.expect(t, len(frames) == 3) // 2 full + 1 partial

	reassembled := strings.builder_make(); defer strings.builder_destroy(&reassembled)
	for f, i in frames {
		testing.expect_value(t, extract_json_string(f, "kind", ""), contracts.BRIDGE_WS_FRAME_KIND_CHUNK)
		testing.expect_value(t, extract_json_int(f, "chunk_index", -1), i)
		testing.expect_value(t, extract_json_int(f, "chunk_count", -1), len(frames))
		testing.expect_value(t, extract_json_int(f, "total_bytes", -1), len(original))
		// stream_id mirrors chunk_id (the hub keys reassembly on it).
		testing.expect_value(t, extract_json_string(f, "stream_id", ""), extract_json_string(f, "chunk_id", "x"))
		fragment := extract_json_string(f, "payload_fragment", "")
		testing.expect(t, fragment != "")
		decoded, derr := base64.decode(fragment); defer delete(decoded)
		testing.expect(t, derr == nil)
		strings.write_string(&reassembled, string(decoded))
	}
	testing.expect_value(t, strings.to_string(reassembled), original)
}

@(test)
hub_chunk_frames_s_client_payload_stays_under_proxy_cap :: proc(t: ^testing.T) {
	// A full-size s_client chunk (6000 raw bytes) must stay under the ~16 KB
	// edge-proxy per-message cap on the wire.
	wire_bound_check(t, contracts.BRIDGE_WS_HUB_RUNTIME_CHUNK_PAYLOAD_BYTES, 16384)
}

@(test)
hub_chunk_frames_socat_payload_stays_under_ws_frame_limit :: proc(t: ^testing.T) {
	// A full-size socat chunk (45000 raw bytes) must stay under the 65535-byte
	// single-WS-frame limit enforced by ws.send_text.
	wire_bound_check(t, contracts.BRIDGE_WS_HUB_RUNTIME_CHUNK_PAYLOAD_BYTES_SOCAT, 65535)
}

// wire_bound_check builds an input of payload+10 bytes so the first frame carries a
// FULL `payload`-byte chunk (the worst-case wire size), and asserts every frame
// stays under `wire_max` and reassembles exactly.
@(private = "file")
wire_bound_check :: proc(t: ^testing.T, payload: int, wire_max: int) {
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	for i in 0 ..< (payload + 10) { strings.write_byte(&b, byte('A' + (i % 26))) }
	original := strings.to_string(b)
	frames := bridge_hub_chunk_frames_with_payload(original, payload)
	testing.expect(t, frames != nil)
	defer { for f in frames do delete(f); delete(frames) }
	testing.expect_value(t, len(frames), 2) // one full chunk + a 10-byte tail
	reassembled := strings.builder_make(); defer strings.builder_destroy(&reassembled)
	for f in frames {
		testing.expect(t, len(f) < wire_max)
		fragment := extract_json_string(f, "payload_fragment", "")
		decoded, derr := base64.decode(fragment); defer delete(decoded)
		testing.expect(t, derr == nil)
		strings.write_string(&reassembled, string(decoded))
	}
	testing.expect_value(t, strings.to_string(reassembled), original)
}
