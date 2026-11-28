package main

import "core:encoding/base64"
import "core:encoding/json"
import "core:mem/virtual"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import channelvault "odin_test:lib/channelvault"
import vault "odin_test:lib/vault"
import ws "odin_test:lib/ws"

// Runs only on the authenticated runtime socket's read loop. This is never a
// dispatcher job, cached command result, CLI/agent operation, or durable event.
bridge_bot_channel_vault_receive :: proc(conn: ^ws.Connection, frame: string) -> bool {
	if !contracts.bot_channel_vault_frame_is(frame, contracts.BOT_CHANNEL_VAULT_REQUEST_FRAME) do return false
	defer channelvault.wipe(frame) // read loop owns and frees the frame
	if len(frame) > contracts.BOT_CHANNEL_VAULT_MAX_FRAME || conn == nil || !conn.connected ||
	   !sync.atomic_load(&bridge_hub_runtime_up) || sync.atomic_load(&bridge_hub_traffic_stopped) {return true}

	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000
	kr, unlocked := bridge_read_vault_keyring()
	defer vault.keyring_wipe(&kr)
	bridge_bot_channel_vault_reply(conn, frame, bridge_config.daemon_id, now_ms, &kr if unlocked else nil)
	return true
}

// Bounded bridge-side reply path shared by the live receiver and loopback
// tests. The caller owns and scrubs the incoming frame.
bridge_bot_channel_vault_reply :: proc(conn: ^ws.Connection, frame, daemon_id: string, now_ms: i64, keyring: ^vault.Vault_Keyring) {
	if conn == nil || len(frame) > contracts.BOT_CHANNEL_VAULT_MAX_FRAME do return
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	if !json.is_valid(transmute([]byte)frame, .JSON, true) do return
	req: contracts.Bot_Channel_Vault_Request
	err := json.unmarshal(transmute([]byte)frame, &req, allocator = context.temp_allocator)
	defer channelvault.wipe(req.body)
	defer channelvault.wipe(req.source_proof)
	if err != nil || !channelvault.valid_id(req.request_id) do return
	// The Hub independently binds this waiter to this authenticated connection
	// and rechecks placement and binding authority before using a result.
	body, status := channelvault.convert(req, daemon_id, now_ms, keyring, context.temp_allocator)
	defer channelvault.wipe(body)
	reply := contracts.Bot_Channel_Vault_Result{type = contracts.BOT_CHANNEL_VAULT_RESULT_FRAME, request_id = req.request_id, status = status}
	if req.operation == "seal" || req.operation == "open" do reply.operation = req.operation
	if len(req.scope_digest) == 64 && vault.valid_id_value(req.scope_digest) do reply.scope_digest = req.scope_digest
	if status == "ok" {
		encoded, encode_err := base64.encode(transmute([]byte)body, allocator = context.temp_allocator)
		if encode_err != nil do return
		reply.body = encoded
	}
	defer channelvault.wipe(reply.body)
	wire, wire_err := json.marshal(reply, allocator = context.temp_allocator)
	defer channelvault.wipe(string(wire))
	// Keep sensitive payloads out of generic chunk-reassembly storage.
	if wire_err == nil do _ = bridge_hub_send_channel_vault(conn, string(wire))
}
