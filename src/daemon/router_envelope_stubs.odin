package main

import "core:fmt"
import re "odin_test:lib/router_envelope"

router_payload_from_message_event :: proc(event: Message_Event) -> (payload_type: string, payload_json: string) {
	#partial switch event.kind {
	case .Messages_Available, .Message_Stored, .New_Message_Requested:
		return re.PAYLOAD_MESSAGE_SEND, re.message_send_payload_json(string(event.from_agent_instance_id), string(event.target_agent_instance_id), event.body)
	case .Message_Read:
		return re.PAYLOAD_MESSAGE_READ, re.message_read_payload_json(string(event.conversation_id), string(event.message_id), string(event.read_by_agent_instance_id), event.read_unix_ms)
	case:
		return "", ""
	}
}

router_envelope_stub_from_event :: proc(event: Message_Event, user_token, user_id, namespace, source_daemon_id, target_daemon_id: string) -> (re.Router_Envelope, bool) {
	payload_type, payload_json := router_payload_from_message_event(event)
	if payload_type == "" do return re.Router_Envelope{}, false
	crypto := re.encrypt_payload_for_router(payload_json, user_token)
	if !crypto.ok do return re.Router_Envelope{}, false
	seed := event.created_unix_ms + event.read_unix_ms
	if seed == 0 do seed = router_now_unix_ms()
	logical_message_id := string(event.message_id)
	if logical_message_id == "" do logical_message_id = fmt.tprintf("logical_%d_%s_%s", seed, string(event.from_agent_instance_id), string(event.target_agent_instance_id))
	envelope_id := fmt.tprintf("env_%d_%s", seed, logical_message_id)
	nonce := fmt.tprintf("nonce_%d", seed)
	envelope := re.new_router_envelope(
		envelope_id,
		logical_message_id,
		nonce,
		user_id,
		namespace,
		source_daemon_id,
		target_daemon_id,
		string(event.target_agent_instance_id),
		payload_type,
		re.PAYLOAD_VERSION,
		crypto.encrypted_payload_json,
	)
	return envelope, re.validate_router_envelope_metadata(envelope)
}
