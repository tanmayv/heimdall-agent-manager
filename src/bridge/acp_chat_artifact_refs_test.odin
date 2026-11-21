package main

import "core:testing"

// REQ-VOICE-5: the ACP prompt's artifact_refs line names each attachment's kind
// and media type, flags unavailable ones, and falls back to bare ids for rows
// from hubs that do not send descriptors.
@(test)
acp_chat_artifact_refs_text_includes_kind_and_mime :: proc(t: ^testing.T) {
	row := acp_event_object(`{"artifact_ids":["art_v","art_d","art_x","art_k"],"artifacts":[` +
		`{"artifact_id":"art_v","kind":"voice","mime":"audio/ogg","available":true},` +
		`{"artifact_id":"art_d","kind":"file","mime":"","available":true},` +
		`{"artifact_id":"art_x","kind":"","mime":"","available":false},` +
		`{"artifact_id":"art_k","kind":"","mime":"audio/mpeg"}]}`)
	testing.expect_value(t, acp_chat_artifact_refs_text(row), "[art_v (voice, audio/ogg), art_d (file), art_x (unavailable), art_k (audio/mpeg)]")
}

@(test)
acp_chat_artifact_refs_text_falls_back_to_ids :: proc(t: ^testing.T) {
	testing.expect_value(t, acp_chat_artifact_refs_text(acp_event_object(`{"artifact_ids":["art_a","art_b"]}`)), "[art_a, art_b]")
	testing.expect_value(t, acp_chat_artifact_refs_text(acp_event_object(`{"artifact_ids":[],"artifacts":[]}`)), "[]")
	testing.expect_value(t, acp_chat_artifact_refs_text(acp_event_object(`{}`)), "[]")
}
