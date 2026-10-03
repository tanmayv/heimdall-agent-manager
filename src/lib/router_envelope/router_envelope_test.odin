package router_envelope

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

@(test)
test_router_envelope_round_trip :: proc(t: ^testing.T) {
	env := Router_Envelope {
		protocol_version         = 1,
		envelope_id              = "env_roundtrip_1001",
		logical_message_id       = "msg_roundtrip_2002",
		nonce                    = "nonce_roundtrip_3003",
		user_id                  = "usr_tanmay",
		namespace                = "default_ns",
		source_daemon_id         = "brg_src_01",
		target_daemon_id         = "brg_tgt_02",
		target_agent_instance_id = "inst_worker_75",
		payload_type             = PAYLOAD_MESSAGE_SEND,
		payload_version          = 1,
		encrypted_payload_json   = "stub-v1:a1b2c3d4e5f6",
	}

	json_str := router_envelope_to_json(env)
	testing.expect(t, len(json_str) > 0, "router_envelope_to_json produced empty string")

	decoded, ok := router_envelope_from_json(json_str)
	testing.expect(t, ok, "router_envelope_from_json failed to decode valid envelope")
	testing.expect_value(t, decoded.protocol_version, env.protocol_version)
	testing.expect_value(t, decoded.envelope_id, env.envelope_id)
	testing.expect_value(t, decoded.logical_message_id, env.logical_message_id)
	testing.expect_value(t, decoded.nonce, env.nonce)
	testing.expect_value(t, decoded.user_id, env.user_id)
	testing.expect_value(t, decoded.namespace, env.namespace)
	testing.expect_value(t, decoded.source_daemon_id, env.source_daemon_id)
	testing.expect_value(t, decoded.target_daemon_id, env.target_daemon_id)
	testing.expect_value(t, decoded.target_agent_instance_id, env.target_agent_instance_id)
	testing.expect_value(t, decoded.payload_type, env.payload_type)
	testing.expect_value(t, decoded.payload_version, env.payload_version)
	testing.expect_value(t, decoded.encrypted_payload_json, env.encrypted_payload_json)
}

@(test)
test_message_send_payload_round_trip :: proc(t: ^testing.T) {
	from_id := "inst_sender_alpha"
	target_id := "inst_receiver_beta"
	body := "Hello! Here is a multiline message\nwith a \"quoted string\" and \\ escaped characters."

	raw := message_send_payload_json(from_id, target_id, body)
	testing.expect(t, len(raw) > 0, "message_send_payload_json produced empty string")

	payload, ok := parse_message_send_payload_json(raw)
	testing.expect(t, ok, "parse_message_send_payload_json should succeed")
	testing.expect_value(t, payload.from_agent_instance_id, from_id)
	testing.expect_value(t, payload.target_agent_instance_id, target_id)
	testing.expect_value(t, payload.body, body)
}

@(test)
test_message_read_payload_round_trip :: proc(t: ^testing.T) {
	conv_id := "chat_gamma_789"
	msg_id := "msg_delta_012"
	reader_id := "inst_reader_omega"
	read_unix_ms := i64(1791053600123)

	raw := message_read_payload_json(conv_id, msg_id, reader_id, read_unix_ms)
	testing.expect(t, len(raw) > 0, "message_read_payload_json produced empty string")

	payload, ok := parse_message_read_payload_json(raw)
	testing.expect(t, ok, "parse_message_read_payload_json should succeed")
	testing.expect_value(t, payload.conversation_id, conv_id)
	testing.expect_value(t, payload.message_id, msg_id)
	testing.expect_value(t, payload.read_by_agent_instance_id, reader_id)
	testing.expect_value(t, payload.read_unix_ms, read_unix_ms)
}

@(test)
test_key_reordering_resilience :: proc(t: ^testing.T) {
	// Envelope with reversed/arbitrary field order
	scrambled_envelope := `{"encrypted_payload_json":"enc_order_test","payload_version":1,"payload_type":"message.send","target_agent_instance_id":"target_inst","target_daemon_id":"target_daemon","source_daemon_id":"source_daemon","namespace":"ns_test","user_id":"usr_test","nonce":"nonce_test","logical_message_id":"msg_test","envelope_id":"env_test","protocol_version":1}`
	env, ok := router_envelope_from_json(scrambled_envelope)
	testing.expect(t, ok, "reordered envelope keys should parse successfully")
	testing.expect_value(t, env.envelope_id, "env_test")
	testing.expect_value(t, env.logical_message_id, "msg_test")
	testing.expect_value(t, env.nonce, "nonce_test")
	testing.expect_value(t, env.user_id, "usr_test")
	testing.expect_value(t, env.namespace, "ns_test")
	testing.expect_value(t, env.source_daemon_id, "source_daemon")
	testing.expect_value(t, env.target_daemon_id, "target_daemon")
	testing.expect_value(t, env.target_agent_instance_id, "target_inst")
	testing.expect_value(t, env.payload_type, "message.send")
	testing.expect_value(t, env.payload_version, 1)
	testing.expect_value(t, env.encrypted_payload_json, "enc_order_test")

	// Message send payload with body first
	scrambled_send := `{"body":"hello reordered","target_agent_instance_id":"tgt_99","from_agent_instance_id":"src_88"}`
	send_payload, send_ok := parse_message_send_payload_json(scrambled_send)
	testing.expect(t, send_ok, "reordered send payload keys should parse successfully")
	testing.expect_value(t, send_payload.from_agent_instance_id, "src_88")
	testing.expect_value(t, send_payload.target_agent_instance_id, "tgt_99")
	testing.expect_value(t, send_payload.body, "hello reordered")

	// Message read payload with read_unix_ms first
	scrambled_read := `{"read_unix_ms":123456789,"read_by_agent_instance_id":"reader_00","message_id":"msg_11","conversation_id":"conv_22"}`
	read_payload, read_ok := parse_message_read_payload_json(scrambled_read)
	testing.expect(t, read_ok, "reordered read payload keys should parse successfully")
	testing.expect_value(t, read_payload.conversation_id, "conv_22")
	testing.expect_value(t, read_payload.message_id, "msg_11")
	testing.expect_value(t, read_payload.read_by_agent_instance_id, "reader_00")
	testing.expect_value(t, read_payload.read_unix_ms, i64(123456789))
}

@(test)
test_whitespace_tolerance :: proc(t: ^testing.T) {
	pretty_json := `
	{
		"protocol_version": 1,
		"envelope_id": "env_pretty",
		"logical_message_id": "msg_pretty",
		"nonce": "nonce_pretty",
		"user_id": "usr_pretty",
		"namespace": "ns_pretty",
		"source_daemon_id": "src_pretty",
		"target_daemon_id": "tgt_pretty",
		"target_agent_instance_id": "inst_pretty",
		"payload_type": "message.read",
		"payload_version": 1,
		"encrypted_payload_json": "stub-v1:deadbeef"
	}
	`
	env, ok := router_envelope_from_json(pretty_json)
	testing.expect(t, ok, "pretty-printed whitespace JSON must parse cleanly")
	testing.expect_value(t, env.envelope_id, "env_pretty")
	testing.expect_value(t, env.target_agent_instance_id, "inst_pretty")

	send_ws := "  \n\t {\t\"from_agent_instance_id\" : \"a1\" , \n \"target_agent_instance_id\" : \"b2\" , \"body\" : \"test ws\" \n} \t "
	send_payload, send_ok := parse_message_send_payload_json(send_ws)
	testing.expect(t, send_ok, "whitespace around send payload should parse cleanly")
	testing.expect_value(t, send_payload.from_agent_instance_id, "a1")
	testing.expect_value(t, send_payload.target_agent_instance_id, "b2")
	testing.expect_value(t, send_payload.body, "test ws")
}

@(test)
test_special_character_escaping :: proc(t: ^testing.T) {
	special_body := "Line1\r\nLine2\tTabbed\nBackslash: \\, ForwardSlash: /, Quotes: \"Hello 'World'\", Unicode: 🚀, Japanese: こんにちは"
	raw := message_send_payload_json("sender", "receiver", special_body)
	payload, ok := parse_message_send_payload_json(raw)
	testing.expect(t, ok, "special characters must parse cleanly")
	testing.expect_value(t, payload.body, special_body)

	// Envelope with nested escaped JSON payload string
	nested_json := `{"inner_key":"inner_value","quotes":"\"quoted\"","number":42}`
	env := new_router_envelope(
		"env_nested",
		"msg_nested",
		"nonce_nested",
		"usr_nested",
		"ns_nested",
		"src_nested",
		"tgt_nested",
		"agent_nested",
		"message.send",
		1,
		nested_json,
	)
	env_raw := router_envelope_to_json(env)
	decoded, dec_ok := router_envelope_from_json(env_raw)
	testing.expect(t, dec_ok, "envelope with nested json string should parse successfully")
	testing.expect_value(t, decoded.encrypted_payload_json, nested_json)
}

@(test)
test_envelope_validation_failures :: proc(t: ^testing.T) {
	valid_env := Router_Envelope {
		protocol_version         = 1,
		envelope_id              = "env_val",
		logical_message_id       = "msg_val",
		nonce                    = "nonce_val",
		user_id                  = "usr_val",
		namespace                = "ns_val",
		source_daemon_id         = "src_val",
		target_daemon_id         = "tgt_val",
		target_agent_instance_id = "inst_val",
		payload_type             = "test_type",
		payload_version          = 1,
		encrypted_payload_json   = "enc_val",
	}

	// 1. Invalid protocol version
	bad_proto := valid_env
	bad_proto.protocol_version = 99
	_, ok := router_envelope_from_json(router_envelope_to_json(bad_proto))
	testing.expect(t, !ok, "protocol_version != 1 must fail validation")

	// 2. Empty envelope_id
	bad_eid := valid_env
	bad_eid.envelope_id = ""
	_, ok = router_envelope_from_json(router_envelope_to_json(bad_eid))
	testing.expect(t, !ok, "empty envelope_id must fail validation")

	// 3. Empty logical_message_id
	bad_mid := valid_env
	bad_mid.logical_message_id = ""
	_, ok = router_envelope_from_json(router_envelope_to_json(bad_mid))
	testing.expect(t, !ok, "empty logical_message_id must fail validation")

	// 4. Empty nonce
	bad_nonce := valid_env
	bad_nonce.nonce = ""
	_, ok = router_envelope_from_json(router_envelope_to_json(bad_nonce))
	testing.expect(t, !ok, "empty nonce must fail validation")

	// 5. Empty user_id AND namespace
	bad_user_ns := valid_env
	bad_user_ns.user_id = ""
	bad_user_ns.namespace = ""
	_, ok = router_envelope_from_json(router_envelope_to_json(bad_user_ns))
	testing.expect(t, !ok, "both user_id and namespace empty must fail validation")

	// 6. user_id present, namespace empty (valid)
	user_only := valid_env
	user_only.namespace = ""
	_, ok = router_envelope_from_json(router_envelope_to_json(user_only))
	testing.expect(t, ok, "user_id without namespace should pass validation")

	// 7. user_id empty, namespace present (valid)
	ns_only := valid_env
	ns_only.user_id = ""
	_, ok = router_envelope_from_json(router_envelope_to_json(ns_only))
	testing.expect(t, ok, "namespace without user_id should pass validation")

	// 8. Empty target_daemon_id AND target_agent_instance_id
	bad_target := valid_env
	bad_target.target_daemon_id = ""
	bad_target.target_agent_instance_id = ""
	_, ok = router_envelope_from_json(router_envelope_to_json(bad_target))
	testing.expect(t, !ok, "both target daemon and agent instance id empty must fail validation")

	// 9. Empty payload_type
	bad_ptype := valid_env
	bad_ptype.payload_type = ""
	_, ok = router_envelope_from_json(router_envelope_to_json(bad_ptype))
	testing.expect(t, !ok, "empty payload_type must fail validation")

	// 10. payload_version <= 0
	bad_pver := valid_env
	bad_pver.payload_version = 0
	_, ok = router_envelope_from_json(router_envelope_to_json(bad_pver))
	testing.expect(t, !ok, "payload_version <= 0 must fail validation")

	// 11. Empty encrypted_payload_json
	bad_enc := valid_env
	bad_enc.encrypted_payload_json = ""
	_, ok = router_envelope_from_json(router_envelope_to_json(bad_enc))
	testing.expect(t, !ok, "empty encrypted_payload_json must fail validation")

	// 12. Invalid JSON string
	_, ok = router_envelope_from_json("{not valid json}")
	testing.expect(t, !ok, "malformed JSON string must fail deserialization")
}

@(test)
test_payload_validation_failures :: proc(t: ^testing.T) {
	// Send payload missing from_agent_instance_id
	_, send_ok1 := parse_message_send_payload_json(`{"target_agent_instance_id":"t1","body":"b1"}`)
	testing.expect(t, !send_ok1, "send payload missing from_agent_instance_id must fail")

	// Send payload missing target_agent_instance_id
	_, send_ok2 := parse_message_send_payload_json(`{"from_agent_instance_id":"f1","body":"b1"}`)
	testing.expect(t, !send_ok2, "send payload missing target_agent_instance_id must fail")

	// Send payload malformed JSON
	_, send_ok3 := parse_message_send_payload_json(`{bad json`)
	testing.expect(t, !send_ok3, "send payload with bad JSON must fail")

	// Read payload missing conversation_id
	_, read_ok1 := parse_message_read_payload_json(`{"message_id":"m1","read_by_agent_instance_id":"r1","read_unix_ms":100}`)
	testing.expect(t, !read_ok1, "read payload missing conversation_id must fail")

	// Read payload missing message_id
	_, read_ok2 := parse_message_read_payload_json(`{"conversation_id":"c1","read_by_agent_instance_id":"r1","read_unix_ms":100}`)
	testing.expect(t, !read_ok2, "read payload missing message_id must fail")

	// Read payload missing read_by_agent_instance_id
	_, read_ok3 := parse_message_read_payload_json(`{"conversation_id":"c1","message_id":"m1","read_unix_ms":100}`)
	testing.expect(t, !read_ok3, "read payload missing read_by_agent_instance_id must fail")

	// Read payload malformed JSON
	_, read_ok4 := parse_message_read_payload_json(`not json`)
	testing.expect(t, !read_ok4, "read payload with bad JSON must fail")
}

@(test)
test_zero_tracking_allocator_leaks :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	// Scoped test execution with custom allocator tracking
	{
		context.allocator = mem.tracking_allocator(&track)

		env := Router_Envelope {
			protocol_version         = 1,
			envelope_id              = "env_leak_test",
			logical_message_id       = "msg_leak_test",
			nonce                    = "nonce_leak_test",
			user_id                  = "usr_leak_test",
			namespace                = "ns_leak_test",
			source_daemon_id         = "src_leak_test",
			target_daemon_id         = "tgt_leak_test",
			target_agent_instance_id = "inst_leak_test",
			payload_type             = PAYLOAD_MESSAGE_SEND,
			payload_version          = 1,
			encrypted_payload_json   = "enc_leak_test",
		}

		for i := 0; i < 50; i += 1 {
			json_str := router_envelope_to_json(env)
			_, ok := router_envelope_from_json(json_str)
			testing.expect(t, ok, "envelope round trip in loop should succeed")

			send_json := message_send_payload_json("agent_a", "agent_b", "hello")
			_, send_ok := parse_message_send_payload_json(send_json)
			testing.expect(t, send_ok, "send payload in loop should succeed")

			read_json := message_read_payload_json("conv_1", "msg_1", "agent_a", 1700000000)
			_, read_ok := parse_message_read_payload_json(read_json)
			testing.expect(t, read_ok, "read payload in loop should succeed")
		}
	}

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}
