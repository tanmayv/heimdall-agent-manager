package router_envelope

PROTOCOL_VERSION :: 1
PAYLOAD_VERSION :: 1

PAYLOAD_MESSAGE_SEND :: "message.send"
PAYLOAD_MESSAGE_READ :: "message.read"

Router_Envelope :: struct {
	protocol_version: int,
	envelope_id: string,
	logical_message_id: string,
	nonce: string,
	user_id: string,
	namespace: string,
	source_daemon_id: string,
	target_daemon_id: string,
	target_agent_instance_id: string,
	payload_type: string,
	payload_version: int,

	// Opaque to the router. The router may store/route this string, but must not parse it.
	encrypted_payload_json: string,
}

new_router_envelope :: proc(
	envelope_id, logical_message_id, nonce, user_id, namespace, source_daemon_id, target_daemon_id, target_agent_instance_id, payload_type: string,
	payload_version: int,
	encrypted_payload_json: string,
) -> Router_Envelope {
	version := payload_version
	if version <= 0 do version = PAYLOAD_VERSION
	return Router_Envelope {
		protocol_version = PROTOCOL_VERSION,
		envelope_id = envelope_id,
		logical_message_id = logical_message_id,
		nonce = nonce,
		user_id = user_id,
		namespace = namespace,
		source_daemon_id = source_daemon_id,
		target_daemon_id = target_daemon_id,
		target_agent_instance_id = target_agent_instance_id,
		payload_type = payload_type,
		payload_version = version,
		encrypted_payload_json = encrypted_payload_json,
	}
}

validate_router_envelope_metadata :: proc(envelope: Router_Envelope) -> bool {
	if envelope.protocol_version != PROTOCOL_VERSION do return false
	if envelope.envelope_id == "" do return false
	if envelope.logical_message_id == "" do return false
	if envelope.nonce == "" do return false
	if envelope.user_id == "" && envelope.namespace == "" do return false
	if envelope.target_daemon_id == "" && envelope.target_agent_instance_id == "" do return false
	if envelope.payload_type == "" do return false
	if envelope.payload_version <= 0 do return false
	if envelope.encrypted_payload_json == "" do return false
	return true
}
