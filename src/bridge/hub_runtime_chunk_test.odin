package main

// Tests for bridge_hub_chunk_frames — the bridge->hub outbound chunker. A frame
// larger than the edge proxy's ~16KB per-message cap must be split into ordered
// kind:"chunk" frames that (a) each stay well under the cap on the wire and (b)
// reconstruct the original byte-for-byte when their base64 payload_fragments are
// decoded and concatenated in index order. Small frames must pass through whole.

import "core:strings"
import "core:testing"
import base64 "core:encoding/base64"
import contracts "odin_test:contracts"

@(test)
hub_chunk_frames_passes_small_through :: proc(t: ^testing.T) {
	// A frame at or below the cap is sent whole: no chunking.
	small := strings.repeat("x", contracts.BRIDGE_WS_HUB_RUNTIME_CHUNK_PAYLOAD_BYTES)
	defer delete(small)
	frames := bridge_hub_chunk_frames(small)
	testing.expect(t, frames == nil)
}

@(test)
hub_chunk_frames_splits_and_roundtrips :: proc(t: ^testing.T) {
	// Build an original ~2.5 chunks long so we get multiple chunks incl. a short
	// final one. Vary the bytes so a wrong offset/order would corrupt the result.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..< (contracts.BRIDGE_WS_HUB_RUNTIME_CHUNK_PAYLOAD_BYTES * 2 + 1234) {
		strings.write_byte(&b, byte('A' + (i % 26)))
	}
	original := strings.to_string(b)

	frames := bridge_hub_chunk_frames(original)
	testing.expect(t, frames != nil)
	defer { for f in frames do delete(f); delete(frames) }
	testing.expect(t, len(frames) >= 3) // 2 full chunks + a partial

	reassembled := strings.builder_make()
	defer strings.builder_destroy(&reassembled)
	for f, i in frames {
		// Each chunk frame must stay safely under the ~16KB proxy cap on the wire.
		testing.expect(t, len(f) < 16384)
		// Metadata is consistent across every chunk of the stream.
		testing.expect_value(t, extract_json_string(f, "kind", ""), contracts.BRIDGE_WS_FRAME_KIND_CHUNK)
		testing.expect_value(t, extract_json_int(f, "chunk_index", -1), i)
		testing.expect_value(t, extract_json_int(f, "chunk_count", -1), len(frames))
		testing.expect_value(t, extract_json_int(f, "total_bytes", -1), len(original))
		// stream_id mirrors chunk_id (the hub keys reassembly on it).
		testing.expect_value(t, extract_json_string(f, "stream_id", ""), extract_json_string(f, "chunk_id", "x"))

		fragment := extract_json_string(f, "payload_fragment", "")
		testing.expect(t, fragment != "")
		decoded, derr := base64.decode(fragment)
		testing.expect(t, derr == nil)
		defer delete(decoded)
		strings.write_string(&reassembled, string(decoded))
	}
	// Decoding + concatenating in index order reproduces the original exactly.
	testing.expect_value(t, strings.to_string(reassembled), original)
}
