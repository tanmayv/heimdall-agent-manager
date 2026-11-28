package main

import "core:fmt"
import "core:strings"
import "core:testing"
import vault "odin_test:lib/vault"

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

// G12: an ACP prompt tells the agent its reply is an explicit chat send, to the
// user for user input and to the sending instance for agent-to-agent input.
@(test)
g12_acp_input_prompt_names_chat_send_reply :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	kr, ok := t5_keyring(); defer vault.keyring_wipe(&kr)
	testing.expect(t, ok)
	body, sealed := bridge_encrypt_vault_text("hello", &kr)
	testing.expect(t, sealed)
	user := acp_event_object(fmt.tprintf(`{{"message_id":"msg_u","direction":"user_to_agent","body":"%s","metadata":{{}}}}`, body))
	text, opened := acp_chat_input_text(user, &kr)
	testing.expect(t, opened)
	testing.expect(t, strings.contains(text, "Reply with `./bin/ham-ctl chat send --to user"), text)
	peer := acp_event_object(fmt.tprintf(`{{"message_id":"msg_a","direction":"agent_to_agent","sender_agent_instance_id":"inst_peer","body":"%s","metadata":{{}}}}`, body))
	text, opened = acp_chat_input_text(peer, &kr)
	testing.expect(t, opened && strings.contains(text, "chat send --to inst_peer"), text)
}
