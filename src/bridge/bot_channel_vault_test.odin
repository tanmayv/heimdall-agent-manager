package main

import "base:runtime"
import "core:encoding/base64"
import "core:encoding/json"
import "core:log"
import "core:net"
import "core:strings"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import channelvault "odin_test:lib/channelvault"
import vault "odin_test:lib/vault"
import ws "odin_test:lib/ws"

@(test)
test_channel_vault_frame_is_consumed_and_scrubbed_even_when_disconnected :: proc(t: ^testing.T) {
	// The runtime read loop owns this mutable frame. A known sensitive frame
	// must never fall through to ordinary dispatch on an unavailable session.
	sensitive := strings.clone(`{"type":"bot_channel_vault","body":"c3ludGhldGljLWlucHV0"}`)
	defer delete(sensitive)
	testing.expect(t, bridge_bot_channel_vault_receive(nil, sensitive))
	for b in transmute([]byte)sensitive do testing.expect_value(t, b, byte(0))

	for sample in ([]string{
		`{"type":"bridge_heartbeat_ack"}`,
		`{"type":"normal","payload":{"type":"bot_channel_vault"}}`,
		`{"payload":{"before":[{"type":"bot_channel_vault"}]}}`,
		`{"note":"type","another":"bot_channel_vault"}`,
	}) {
		normal := strings.clone(sample)
		defer delete(normal)
		testing.expect(t, !bridge_bot_channel_vault_receive(nil, normal))
		testing.expect_value(t, normal, sample)
	}
	testing.expect(t, bridge_bot_channel_vault_frame(`{"padding":{"type":"unrelated"},"type":"bot_channel_vault"}`))
}

Channel_Vault_Log_Test :: struct { count: int }
channel_vault_count_log :: proc(raw: rawptr, _: log.Level, _: string, _: log.Options, _: runtime.Source_Code_Location) {
	(^Channel_Vault_Log_Test)(raw).count += 1
}

@(test)
test_channel_vault_bounded_ws_round_trip_and_no_log :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	if !testing.expect(t, listen_err == nil) do return
	defer net.close(listener)
	address, bound_err := net.bound_endpoint(listener)
	if !testing.expect(t, bound_err == nil) do return
	peer, dial_err := net.dial_tcp(address)
	if !testing.expect(t, dial_err == nil) do return
	defer net.close(peer)
	server, _, accept_err := net.accept_tcp(listener)
	if !testing.expect(t, accept_err == nil) do return
	defer net.close(server)
	_ = net.set_option(peer, .Receive_Timeout, time.Second)
	_ = net.set_option(server, .Receive_Timeout, time.Second)
	hub_conn := ws.Connection{socket = peer, connected = true}
	bridge_conn := ws.Connection{socket = server, connected = true}
	defer {delete(hub_conn.pending_bytes); delete(bridge_conn.pending_bytes)}

	id := vault.Vault_Id{}
	id[0] = 12
	key_bytes: [32]byte
	key_bytes[31] = 21
	key, key_ok := vault.keyring_from_single_key("test_owner", id, 2, key_bytes[:])
	if !testing.expect(t, key_ok) do return
	defer vault.keyring_wipe(&key)
	id_text: [vault.VAULT_ID_HEX_CHARS]byte
	now_ms :: 50_000
	req := contracts.Bot_Channel_Vault_Request{
		type=contracts.BOT_CHANNEL_VAULT_REQUEST_FRAME, request_id="relay_test_01", operation="seal",
		owner_user_id="test_owner", bridge_id="test_bridge", agent_instance_id="inst_test",
		conversation_id="chat_test", activation_generation=9, expires_at_ms=now_ms+1000,
		vault_id=vault.vault_id_hex(id,id_text[:]), vault_epoch=2, provider="telegram",
		provider_event_id="telegram:fake:94", binding_id="binding", binding_generation=2,
	}
	messages := Channel_Vault_Log_Test{}
	context.logger = {procedure=channel_vault_count_log, data=&messages, lowest_level=.Debug}
	plaintext :: "synthetic provider text"
	req.body, _ = base64.encode(transmute([]byte)string(plaintext), allocator=context.temp_allocator)
	sealed := channel_vault_wire_exchange(t, &hub_conn, &bridge_conn, req, now_ms, &key, "ok")
	opened, opened_result := vault.open(sealed, &key, context.temp_allocator)
	defer channelvault.wipe(opened)
	testing.expect(t, opened_result == .Ok)
	testing.expect_value(t, opened, plaintext)

	req.request_id, req.operation = "relay_test_02", "open"
	req.provider_event_id = ""
	req.input_message_id, req.reply_message_id = "msg_in", "msg_out"
	token, proof, minted := channelvault.seal_authored(channelvault.reply_scope(req), "synthetic authored reply", &key, context.temp_allocator)
	if !testing.expect(t, minted) do return
	req.source_proof = proof
	req.body, _ = base64.encode(transmute([]byte)token, allocator=context.temp_allocator)
	result := channel_vault_wire_exchange(t, &hub_conn, &bridge_conn, req, now_ms, &key, "ok")
	defer channelvault.wipe(result)
	testing.expect_value(t, result, "synthetic authored reply")
	req.request_id, req.input_message_id = "relay_test_03", "alternate_source"
	_ = channel_vault_wire_exchange(t, &hub_conn, &bridge_conn, req, now_ms, &key, "invalid_scope")
	testing.expect_value(t, messages.count, 0)
}

channel_vault_wire_exchange :: proc(t: ^testing.T, hub_conn, bridge_conn: ^ws.Connection, raw: contracts.Bot_Channel_Vault_Request, now_ms: i64, key: ^vault.Vault_Keyring, status: string) -> string {
	req := raw
	req.scope_digest, _ = contracts.bot_channel_vault_scope_digest(req, context.temp_allocator)
	wire, err := json.marshal(req, allocator=context.temp_allocator)
	defer channelvault.wipe(string(wire))
	if !testing.expect(t, err == nil && ws.send_text_sensitive(hub_conn, string(wire))) do return ""
	body, opcode, got := ws.poll_frame(bridge_conn)
	defer {channelvault.wipe(body); delete(body)}
	if !testing.expect(t, got && opcode == 0x1 && bridge_bot_channel_vault_frame(body)) do return ""
	bridge_bot_channel_vault_reply(bridge_conn, body, req.bridge_id, now_ms, key)
	raw_reply, reply_opcode, got_reply := ws.poll_frame(hub_conn)
	defer {channelvault.wipe(raw_reply); delete(raw_reply)}
	if !testing.expect(t, got_reply && reply_opcode == 0x1) do return ""
	rep: contracts.Bot_Channel_Vault_Result
	decode_err := json.unmarshal(transmute([]byte)raw_reply, &rep, allocator=context.temp_allocator)
	defer channelvault.wipe(rep.body)
	testing.expect(t, decode_err == nil)
	testing.expect_value(t, rep.type, contracts.BOT_CHANNEL_VAULT_RESULT_FRAME)
	testing.expect_value(t, rep.request_id, req.request_id)
	testing.expect_value(t, rep.scope_digest, req.scope_digest)
	testing.expect_value(t, rep.operation, req.operation)
	testing.expect_value(t, rep.status, status)
	if status != "ok" {
		testing.expect_value(t, rep.body, "")
		return ""
	}
	out, output_err := base64.decode(rep.body, allocator=context.temp_allocator)
	testing.expect(t, output_err == nil)
	return string(out)
}
