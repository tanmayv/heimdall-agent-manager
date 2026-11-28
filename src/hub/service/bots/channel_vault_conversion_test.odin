package bots

import "base:runtime"
import "core:crypto"
import "core:crypto/ecdsa"
import "core:encoding/base64"
import "core:mem/virtual"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import sqlite "odin_test:hub/repository/sqlite"
import iface "odin_test:hub/repository/iface"
import channel "odin_test:hub/service/channel"
import project "odin_test:hub/service/project"
import channelvault "odin_test:lib/channelvault"
import random "odin_test:lib/os_random"
import vault "odin_test:lib/vault"

Vault_Roundtrip :: struct {
	fixture: Activation_Fixture,
	directory: domain.Vault_Directory,
	devices: [2]domain.Vault_Device,
	repo: iface.Vault_Directory_Repository,
	kr: vault.Vault_Keyring,
	locked, lose_ack, retire_during_open, wrong_token: bool,
	exchanges, sends: int,
	provider, address, received: string,
}

roundtrip_directory :: proc(ctx: rawptr, owner: string) -> (domain.Vault_Directory, bool, domain.Domain_Error) {
	f := (^Vault_Roundtrip)(ctx)
	if owner != f.directory.user_id do return {}, false, {}
	return f.directory, true, {}
}
roundtrip_devices :: proc(ctx: rawptr, owner: string) -> ([]domain.Vault_Device, domain.Domain_Error) {
	f := (^Vault_Roundtrip)(ctx)
	if owner != f.directory.user_id do return nil, {}
	return f.devices[:], {}
}

// Only the transport is replaced. The loopback bridge uses the production
// conversion and proof verifier with its own disposable keyring.
roundtrip_exchange :: proc(ctx: rawptr, generation: int, req: contracts.Bot_Channel_Vault_Request) -> (contracts.Bot_Channel_Vault_Result, bool) {
	f := (^Vault_Roundtrip)(ctx)
	f.exchanges += 1
	if generation != project.bridge_runtime_registry_generation(&f.fixture.placement.registry, req.bridge_id) do return {}, false
	wire := req
	wire.request_id, wire.expires_at_ms = "req_local_test", 1005
	wire.scope_digest, _ = contracts.bot_channel_vault_scope_digest(wire, context.temp_allocator)
	wire.body, _ = base64.encode(transmute([]byte)req.body, allocator=context.temp_allocator)
	defer channelvault.wipe(wire.body)
	key := &f.kr
	if f.locked do key = nil
	body, status := channelvault.convert(wire, req.bridge_id, 1000, key, runtime.default_allocator())
	if f.lose_ack {
		channelvault.wipe(body)
		delete(body, runtime.default_allocator())
		return {}, false
	}
	if f.wrong_token && req.operation == "seal" {
		delete(body, runtime.default_allocator())
		body = strings.clone("unsealed response", runtime.default_allocator())
	}
	if f.retire_during_open && req.operation == "open" do f.devices[1].retired_at = CONVERSION_AT
	return {operation=req.operation, status=status, body=body}, true
}

roundtrip_recipient :: proc(ctx: rawptr, provider, address, text: string) {
	f := (^Vault_Roundtrip)(ctx)
	f.sends += 1
	f.provider, f.address, f.received = provider, address, strings.clone(text, context.temp_allocator)
}

roundtrip_boot :: proc(t: ^testing.T, f: ^Vault_Roundtrip) -> bool {
	activation_fixture_open(t, &f.fixture, true)
	f.fixture.placement.bridges[0].capabilities_json = `{"features":["bot_channel_vault_v1","instance_reconfiguration_v1","bot_deliver_v1"]}`
	f.repo = {ctx=f, get_directory=roundtrip_directory, list_devices=roundtrip_devices}
	s := &f.fixture.pair.service
	s.channel_vault_directory = &f.repo
	s.channel_vault_exchange = {ctx=f, run=roundtrip_exchange}
	root_public, bridge_public: string
	for i in 0..<2 {
		scalar: [32]byte
		scalar[31] = byte(i+1) // Deterministic disposable identity signatures.
		priv: ecdsa.Private_Key
		if !ecdsa.private_key_set_bytes(&priv, .SECP256R1, scalar[:]) do return false
		defer ecdsa.private_key_clear(&priv)
		pub: [65]byte
		ecdsa.private_key_public_bytes(&priv, pub[:])
		public_key := vault.hex_encode_lower(pub[:], context.temp_allocator)
		device_id, _ := vault.device_id_from_sign_pub(public_key, context.temp_allocator)
		f.devices[i] = {user_id="alice", device_id=device_id, sign_public_key=public_key, sign_alg=vault.SIGN_ALG_ECDSA_P256_SHA256, status=.Approved}
		if i == 0 {
			root_public = public_key
			f.directory = {user_id="alice", root_device_id=device_id, head_hash="test-head", version=2, current_epoch=1}
			continue
		}
		bridge_public = public_key
		f.devices[i].bridge_id, f.devices[i].kind = "b", "bridge"
		boot, _ := vault.bridge_unseal_key_canonical("b", bridge_public, "ab", context.temp_allocator)
		signature, ok := vault.sign_p256(&priv, transmute([]byte)boot)
		if !ok do return false
		sig_json, _ := vault.signature_object(&signature, context.temp_allocator)
		project.bridge_runtime_registry_set_unseal_identity(s.registry, "b", {
			public_key=bridge_public, unseal_boot_id="ab", unseal_key_signature=sig_json,
			identity_public_key=bridge_public, identity_sign_alg=vault.SIGN_ALG_ECDSA_P256_SHA256,
		})
	}
	vid, _ := vault.vault_id_from_root_sign_pub(root_public)
	key: [32]byte
	if !random.fill(key[:]) do return false
	defer crypto.zero_explicit(&key, size_of(key))
	kr, ok := vault.keyring_from_single_key("alice", vid, 1, key[:])
	defer vault.keyring_wipe(&kr)
	f.kr = kr
	return ok
}

ROUNDTRIP_INPUT :: "FjordIngress74Qv"
ROUNDTRIP_REPLY :: "FjordReply52Xp"

Roundtrip_Log :: struct {
	outer: log.Logger,
	markers: [4]string,
	exposed: bool,
}

roundtrip_log :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, loc := #caller_location) {
	capture := (^Roundtrip_Log)(data)
	for marker in capture.markers {
		if strings.contains(text, marker) {
			capture.exposed = true
			return
		}
	}
	if capture.outer.procedure != nil do capture.outer.procedure(capture.outer.data,level,text,options,loc)
}

roundtrip_check_storage :: proc(t: ^testing.T, conn: ^sqlite.Conn, markers: []string, token: string) {
	matches, ok := sqlite.scalar_count(conn, "SELECT count(*) FROM chat_messages_fts WHERE chat_messages_fts MATCH 'FjordIngress74Qv OR FjordReply52Xp';")
	testing.expect(t, ok && matches == 0, "search index contains neither message")
	base, base_err := os.temp_directory(context.temp_allocator)
	if !testing.expect(t, base_err == nil) do return
	dir, dir_err := os.make_directory_temp(base, "ham-channel-vault-*", context.temp_allocator)
	if !testing.expect(t, dir_err == nil) do return
	defer _ = os.remove_all(dir)
	path := strings.concatenate({dir, "/snapshot.db"})
	stmt: sqlite.sqlite3_stmt
	if !testing.expect_value(t, sqlite.sqlite3_prepare_v2(conn.db, "VACUUM INTO ?;", -1, &stmt, nil), sqlite.SQLITE_OK) do return
	defer sqlite.sqlite3_finalize(stmt)
	if !testing.expect_value(t, sqlite.sqlite3_bind_text(stmt, 1, cstring(raw_data(path)), i32(len(path)), sqlite.SQLITE_TRANSIENT), sqlite.SQLITE_OK) do return
	if !testing.expect_value(t, sqlite.sqlite3_step(stmt), sqlite.SQLITE_DONE) do return
	data, err := os.read_entire_file(path, context.temp_allocator)
	if !testing.expect(t, err == nil && strings.contains(string(data), token), "database snapshot includes the stored vault envelope") do return
	for marker in markers {
		testing.expect(t, !strings.contains(string(data), marker), "database contains no clear or base64 message text")
	}
}

@(test)
test_channel_vault_converts_only_fresh_verified_text :: proc(t: ^testing.T) {
	for provider in ([]string{"telegram","whatsapp"}) {
		arena: virtual.Arena
		_ = virtual.arena_init_growing(&arena)
		defer virtual.arena_destroy(&arena)
		context.allocator = virtual.arena_allocator(&arena)
		context.temp_allocator = context.allocator
		input64, _ := base64.encode(transmute([]byte)string(ROUNDTRIP_INPUT), allocator=context.temp_allocator)
		reply64, _ := base64.encode(transmute([]byte)string(ROUNDTRIP_REPLY), allocator=context.temp_allocator)
		logs := Roundtrip_Log{outer=context.logger, markers={ROUNDTRIP_INPUT, ROUNDTRIP_REPLY, input64, reply64}}
		context.logger = {procedure=roundtrip_log, data=&logs, lowest_level=.Debug}
		defer {
			context.logger = logs.outer
			testing.expect(t, !logs.exposed, "Hub logs contain no clear or base64 message text")
		}
		f: Vault_Roundtrip
		if !testing.expect(t, roundtrip_boot(t,&f)) do return
		defer activation_fixture_close(&f.fixture)
		defer vault.keyring_wipe(&f.kr)
		s := &f.fixture.pair.service
		active, activation_err := set_web_activation(s, "alice", true, 0)
		if !testing.expect(t, activation_err.code == .None, activation_err.message) do return
		if !make_conversion_binding(t,&f.fixture,"chb_fresh",provider,3) do return
		event := channel.Inbound{kind=.Text, update_key="update-1", external_chat_id="fake-recipient",
			external_user_id="fake-sender", text=ROUNDTRIP_INPUT}
		f.locked = true
		_, locked := seal_channel_input(s,"alice","chb_fresh","msg_input",provider,event)
		testing.expect_value(t, locked.code, domain.Error_Code.Vault_Locked)
		f.locked, f.lose_ack = false, true
		_, lost := seal_channel_input(s,"alice","chb_fresh","msg_input",provider,event)
		testing.expect_value(t, lost.code, domain.Error_Code.Bridge_Timeout)
		f.lose_ack, f.wrong_token = false, true
		_, malformed := seal_channel_input(s,"alice","chb_fresh","msg_input",provider,event)
		testing.expect_value(t, malformed.code, domain.Error_Code.Validation_Failed)
		f.wrong_token = false
		token, err := seal_channel_input(s,"alice","chb_fresh","msg_input",provider,event)
		if !testing.expect(t, err.code == .None && !strings.contains(token, event.text), err.message) do return
		opened, result := vault.open(token, &f.kr)
		testing.expect(t, result == .Ok && opened == event.text)
		if !conversion_store_chat(t,&f.fixture,active,"msg_input","user_to_agent",token) do return
		repos := &f.fixture.repos
		testing.expect_value(t, iface.bot_channel_conversion_origin_insert(&repos.bots,{
			inbound_message_id="msg_input", binding_id="chb_fresh", provider_update_key=event.update_key,
		}).code, domain.Error_Code.None)
		answer :: ROUNDTRIP_REPLY
		scope := channelvault.Reply_Scope{owner_user_id="alice", agent_instance_id=active.agent_instance_id, conversation_id=active.conversation_id,
			provider=provider, binding_id="chb_fresh", binding_generation=3, input_message_id="msg_input", reply_message_id="msg_reply"}
		reply, proof, authored := channelvault.seal_authored(scope, answer, &f.kr)
		if !testing.expect(t, authored && conversion_store_chat(t,&f.fixture,active,"msg_reply","agent_to_user",reply)) do return
		testing.expect_value(t, iface.bot_channel_conversion_reply_insert(&repos.bots,"msg_reply","msg_input",proof).code, domain.Error_Code.None)
		receive := Bound_Reply_Consumer{ctx=&f, accept=roundtrip_recipient}
		f.lose_ack = true
		testing.expect_value(t, with_bound_channel_reply(s,"alice","msg_reply",receive).code, domain.Error_Code.Bridge_Timeout)
		testing.expect_value(t, f.sends, 0)
		f.lose_ack = false
		err = with_bound_channel_reply(s,"alice","msg_reply",receive)
		testing.expect(t, err.code == .None && f.sends == 1 && f.received == answer && f.provider == provider && f.address == "fake-recipient", err.message)
		f.retire_during_open = true
		testing.expect_value(t, with_bound_channel_reply(s,"alice","msg_reply",receive).code, domain.Error_Code.Forbidden)
		roundtrip_check_storage(t, &f.fixture.pair.conn, logs.markers[:], token)
		before := f.exchanges
		testing.expect_value(t, with_bound_channel_reply(s,"alice","msg_reply",receive).code, domain.Error_Code.Forbidden)
		testing.expect(t, f.sends == 1 && f.exchanges == before, "retired identity cannot release or request plaintext")
	}
}
