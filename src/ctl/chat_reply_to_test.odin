package main

import "core:encoding/json"
import "core:testing"

// R7: chat send --reply-to <message_id> names the user message a reply answers.

@(test)
test_chat_send_reply_to_is_forwarded :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	args := []string{"--vault-keyring", tkr_b64(TEST_CHAT_VAULT_KEY), "--reply-to", " msg_abc123 "}
	out := ctl_agentmode_chat_send_params("user", "Answer.", args)
	val, err := json.parse_string(out, allocator = context.temp_allocator)
	if !testing.expect(t, err == .None, out) do return
	obj := val.(json.Object)
	testing.expect_value(t, string(obj["reply_to"].(json.String)), "msg_abc123")
	testing.expect_value(t, string(obj["to"].(json.String)), "user")
	// With options the field joins the same object.
	with_options := []string{"--vault-keyring", tkr_b64(TEST_CHAT_VAULT_KEY), "--options", "a,b", "--reply-to", "msg_abc123"}
	out = ctl_agentmode_chat_send_params("user", "Pick.", with_options)
	val, err = json.parse_string(out, allocator = context.temp_allocator)
	if !testing.expect(t, err == .None, out) do return
	obj = val.(json.Object)
	testing.expect_value(t, string(obj["reply_to"].(json.String)), "msg_abc123")
	testing.expect(t, len(obj["options"].(json.Array)) == 2)
	// Absent: no field.
	out = ctl_agentmode_chat_send_params("user", "Plain.", []string{"--vault-keyring", tkr_b64(TEST_CHAT_VAULT_KEY)})
	val, _ = json.parse_string(out, allocator = context.temp_allocator)
	_, present := val.(json.Object)["reply_to"]
	testing.expect(t, !present)
}

@(test)
test_chat_send_reply_to_argument_validation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	id, invalid := ctl_chat_send_reply_to("user", []string{"--reply-to"})
	testing.expect_value(t, invalid, "--reply-to requires a message id")
	id, invalid = ctl_chat_send_reply_to("user", []string{"--reply-to", "--body", "x"})
	testing.expect_value(t, invalid, "--reply-to requires a message id")
	id, invalid = ctl_chat_send_reply_to("inst_peer", []string{"--reply-to", "msg_1"})
	testing.expect_value(t, invalid, "--reply-to applies only to --to user")
	id, invalid = ctl_chat_send_reply_to("user", []string{"--body", "x"})
	testing.expect_value(t, id, "")
	testing.expect_value(t, invalid, "")
	id, invalid = ctl_chat_send_reply_to("user", []string{"--reply-to", "msg_1"})
	testing.expect_value(t, id, "msg_1")
	testing.expect_value(t, invalid, "")
	testing.expect_value(t, ctl_json_object_add_field("{}", `"a":1`), `{"a":1}`)
	testing.expect_value(t, ctl_json_object_add_field(`{"b":2}`, `"a":1`), `{"b":2,"a":1}`)
}

@(test)
test_chat_prepare_channel_reply_reads_scope_from_bridge_and_hub_envelopes :: proc(t: ^testing.T) {
	raw := `{"ok":true,"data":{"data":{"scope":{"owner_user_id":"alice","provider":"telegram","binding_id":"chb_x","binding_generation":2,"input_message_id":"msg_input","reply_message_id":"msg_chreply_x"}}}}`
	s, found := ctl_channel_reply_scope(raw)
	testing.expect(t,found && s.provider=="telegram" && s.binding_generation==2 && s.input_message_id=="msg_input" && s.reply_message_id=="msg_chreply_x")
	_, found = ctl_channel_reply_scope(`{"ok":true,"data":{"data":{"route_status":"ambiguous","scope":{}}}}`)
	testing.expect(t,!found,"an ambiguous route leaves the reply in web chat")
}
