package main

import "core:fmt"
import "core:net"
import "core:strings"

handle_hub_append :: proc(client: net.TCP_Socket, body: string) {
	user_id := extract_json_string(body, "user_id", "")
	namespace := extract_json_string(body, "namespace", "")
	auth := extract_json_string(body, "hub_auth_token", "")
	if !hub_adapter_authorized(user_id, namespace, auth) {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"unauthorized hub append"}`)
		return
	}
	record, ok := central_hub_append(Hub_Record {
		record_id = extract_json_string(body, "record_id", ""),
		message_id = extract_json_string(body, "message_id", ""),
		kind = hub_record_kind_from_string(extract_json_string(body, "record_type", "message.send")),
		user_id = user_id,
		namespace = namespace,
		source_daemon_id = extract_json_string(body, "source_daemon_id", ""),
		target_agent_instance_id = extract_json_string(body, "target_agent_instance_id", ""),
		payload_type = extract_json_string(body, "payload_type", "message.send"),
		payload_version = extract_json_int(body, "payload_version", 1),
		encrypted_payload_json = extract_json_string(body, "encrypted_payload_json", ""),
	})
	if !ok {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid hub record"}`)
		return
	}
	write_response(client, 200, "OK", hub_append_response_json(record))
}

handle_hub_poll :: proc(client: net.TCP_Socket, body: string) {
	user_id := extract_json_string(body, "user_id", "")
	namespace := extract_json_string(body, "namespace", "")
	auth := extract_json_string(body, "hub_auth_token", "")
	if !hub_adapter_authorized(user_id, namespace, auth) {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"unauthorized hub poll"}`)
		return
	}
	after_seq := i64(extract_json_int(body, "after_seq", 0))
	limit := extract_json_int(body, "limit", 100)
	records := central_hub_poll(user_id, namespace, after_seq, limit)
	write_response(client, 200, "OK", hub_poll_response_json(records))
}

handle_hub_ack :: proc(client: net.TCP_Socket, body: string) {
	user_id := extract_json_string(body, "user_id", "")
	namespace := extract_json_string(body, "namespace", "")
	auth := extract_json_string(body, "hub_auth_token", "")
	if !hub_adapter_authorized(user_id, namespace, auth) {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"unauthorized hub ack"}`)
		return
	}
	ok := central_hub_ack(user_id, namespace, extract_json_string(body, "record_id", ""))
	write_response(client, 200, "OK", `{"ok":true,"acked":true}` if ok else `{"ok":true,"acked":false}`)
}

handle_hub_presence :: proc(client: net.TCP_Socket, body: string) {
	user_id := extract_json_string(body, "user_id", "")
	namespace := extract_json_string(body, "namespace", "")
	auth := extract_json_string(body, "hub_auth_token", "")
	if !hub_adapter_authorized(user_id, namespace, auth) {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"unauthorized hub presence"}`)
		return
	}
	ok := central_hub_presence(user_id, namespace, extract_json_string(body, "daemon_id", ""), extract_json_string(body, "agent_instance_id", ""), extract_json_string(body, "status", "online"))
	write_response(client, 200, "OK", `{"ok":true,"updated":true}` if ok else `{"ok":true,"updated":false}`)
}

hub_record_kind_from_string :: proc(value: string) -> Hub_Record_Kind {
	switch value {
	case "message.read": return .Message_Read
	case "status": return .Status
	case "presence": return .Presence
	case: return .Message_Send
	}
}

hub_append_response_json :: proc(record: Hub_Record) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"record_id":"`)
	json_write_string(&builder, record.record_id)
	strings.write_string(&builder, `","record_seq":`)
	strings.write_string(&builder, fmt.tprintf("%d", record.record_seq))
	strings.write_string(&builder, `}`)
	return strings.to_string(builder)
}

hub_poll_response_json :: proc(records: []Hub_Record) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"records":[`)
	for record, i in records {
		if i > 0 do strings.write_string(&builder, ",")
		strings.write_string(&builder, `{"record_id":"`)
		json_write_string(&builder, record.record_id)
		strings.write_string(&builder, `","record_seq":`)
		strings.write_string(&builder, fmt.tprintf("%d", record.record_seq))
		strings.write_string(&builder, `,"message_id":"`)
		json_write_string(&builder, record.message_id)
		strings.write_string(&builder, `","payload_type":"`)
		json_write_string(&builder, record.payload_type)
		strings.write_string(&builder, `","payload_version":`)
		strings.write_string(&builder, fmt.tprintf("%d", record.payload_version))
		strings.write_string(&builder, `,"encrypted_payload_json":"`)
		json_write_string(&builder, record.encrypted_payload_json)
		strings.write_string(&builder, `"}`)
	}
	strings.write_string(&builder, `]}`)
	return strings.to_string(builder)
}
