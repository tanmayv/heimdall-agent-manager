package bridge_runtime

import "core:encoding/base64"
import "core:encoding/json"
import "core:net"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import project "odin_test:hub/service/project"
import ws "odin_test:lib/ws"

Bot_Vault_Fixture :: struct {
	registry: ^project.Bridge_Runtime_Registry,
	generation: int,
	peer, hub: net.TCP_Socket,
}

bot_vault_fixture_open :: proc(t: ^testing.T) -> (f: Bot_Vault_Fixture, ok: bool) {
	listener, err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	if !testing.expect(t, err == nil) do return
	defer net.close(listener)
	bound, _ := net.bound_endpoint(listener)
	f.peer, f.hub = replaced_test_socket_pair(t, listener, bound.port)
	if !testing.expect(t, f.peer != 0 && f.hub != 0) do return
	f.registry = new(project.Bridge_Runtime_Registry)
	hello, admitted, _ := runtime_accept_hello(f.registry, "brg_vault", PROTOCOL_VERSION, "", "usr_vault")
	if !testing.expect(t, admitted) do return
	f.generation = hello.generation
	project.bridge_runtime_registry_set_command_socket(f.registry, "brg_vault", f.hub, f.generation)
	return f, true
}

bot_vault_fixture_close :: proc(f: Bot_Vault_Fixture) {
	if f.registry != nil {
		runtime_command_cache_destroy(f.registry)
		project.bridge_runtime_registry_destroy(f.registry)
		free(f.registry)
	}
	if f.peer != 0 do net.close(f.peer)
	if f.hub != 0 do net.close(f.hub)
}

Bot_Vault_Test_Call :: struct {
	f: Bot_Vault_Fixture,
	req: contracts.Bot_Channel_Vault_Request,
	timeout_ms: i64,
	result: contracts.Bot_Channel_Vault_Result,
	ok: bool,
}

bot_vault_test_call :: proc(raw: rawptr) {
	call := (^Bot_Vault_Test_Call)(raw)
	call.result, call.ok = exchange_bot_channel_vault_for(call.f.registry, call.f.generation, call.req, call.timeout_ms)
}

bot_vault_test_request :: proc() -> contracts.Bot_Channel_Vault_Request {
	return {
		request_id = "not-caller-controlled", expires_at_ms = 1, owner_user_id = "usr_vault", bridge_id = "brg_vault",
		operation = "seal", provider = "telegram", agent_instance_id = "inst_vault", conversation_id = "chat_vault",
		provider_event_id = "fixture-event", activation_generation = 2, binding_generation = 3, binding_id = "bnd_test",
		body = "private fixture inlet",
	}
}

bot_vault_read_wire :: proc(t: ^testing.T, peer: net.TCP_Socket) -> (request: contracts.Bot_Channel_Vault_Request, ok: bool) {
	reader := ws.reader_make(peer, allow_64bit = false, max_buffer_bytes = contracts.BOT_CHANNEL_VAULT_MAX_FRAME+20)
	defer ws.reader_destroy(&reader)
	op, frame, received := ws.read_frame(peer, &reader, time.Second)
	defer delete(frame)
	if !testing.expect(t, received && op == 0x1, "one direct text frame reached the authenticated target") do return
	err := json.unmarshal_string(frame, &request, .JSON, context.temp_allocator)
	if !testing.expect(t, err == nil && request.type == contracts.BOT_CHANNEL_VAULT_REQUEST_FRAME) do return
	return request, true
}

bot_vault_expect_no_cache :: proc(t: ^testing.T, f: Bot_Vault_Fixture, request_id: string) {
	_, cached := runtime_command_cached(f.registry, "brg_vault", f.generation, request_id)
	testing.expect(t, !cached, "private traffic never populated the standard command result cache")
	sync.lock(&f.registry.channel_vault_mutex)
	defer sync.unlock(&f.registry.channel_vault_mutex)
	for slot in f.registry.channel_vault_pending do testing.expect(t, slot == nil, "finished requests leave no volatile pending entry")
}

@(test)
bot_channel_vault_correlates_only_the_authenticated_live_connection_and_scope :: proc(t: ^testing.T) {
	f, fixture_ok := bot_vault_fixture_open(t)
	defer bot_vault_fixture_close(f)
	if !fixture_ok do return
	call := Bot_Vault_Test_Call{f = f, req = bot_vault_test_request(), timeout_ms = 2_000}

	wrong_owner := call.req
	wrong_owner.owner_user_id = "usr_other"
	out, wrong_ok := exchange_bot_channel_vault_for(f.registry, f.generation, wrong_owner, 500)
	defer contracts.bot_channel_vault_result_destroy(&out)
	testing.expect(t, !wrong_ok, "wrong owner never reaches transport")

	other, _, _ := runtime_accept_hello(f.registry, "brg_other", PROTOCOL_VERSION, "", "usr_vault")
	worker := thread.create_and_start_with_data(&call, bot_vault_test_call)
	if !testing.expect(t, worker != nil) do return
	joined := false
	defer {
		if !joined do thread.join(worker)
		thread.destroy(worker)
		contracts.bot_channel_vault_result_destroy(&call.result)
	}
	wire, got := bot_vault_read_wire(t, f.peer)
	if !got do return
	testing.expect(t, len(wire.request_id) == 32 && wire.request_id != call.req.request_id)
	testing.expect(t, wire.expires_at_ms > project.bridge_runtime_wall_ms(), "a new transport deadline replaces the caller's")
	digest, hashed := contracts.bot_channel_vault_scope_digest(wire, context.temp_allocator)
	testing.expect(t, hashed)
	testing.expect_value(t, digest, wire.scope_digest)
	decoded, decode_err := base64.decode(wire.body, allocator = context.temp_allocator)
	testing.expect(t, decode_err == nil)
	testing.expect_value(t, string(decoded), call.req.body)

	result_text: string = "fixture armoured result"
	body, _ := base64.encode(transmute([]byte)result_text, allocator = context.temp_allocator)
	reply := contracts.Bot_Channel_Vault_Result{
		type = contracts.BOT_CHANNEL_VAULT_RESULT_FRAME, request_id = wire.request_id, operation = wire.operation,
		scope_digest = wire.scope_digest, status = "ok", body = body,
	}
	testing.expect(t, !complete_bot_channel_vault(f.registry, "brg_other", other.generation, reply), "other bridge cannot claim the exact request")
	testing.expect(t, !complete_bot_channel_vault(f.registry, "brg_vault", f.generation+99, reply), "noncurrent generation ignored")
	bad := reply
	bad.scope_digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	testing.expect(t, !complete_bot_channel_vault(f.registry, "brg_vault", f.generation, bad), "modified digest ignored")
	bad = reply
	bad.operation = "open"
	testing.expect(t, !complete_bot_channel_vault(f.registry, "brg_vault", f.generation, bad), "different operation ignored")
	bad = reply
	bad.body = "%%=="
	testing.expect(t, !complete_bot_channel_vault(f.registry, "brg_vault", f.generation, bad), "invalid result body ignored")
	testing.expect(t, complete_bot_channel_vault(f.registry, "brg_vault", f.generation, reply))
	thread.join(worker)
	joined = true
	testing.expect(t, call.ok)
	testing.expect_value(t, call.result.body, "fixture armoured result")
	testing.expect(t, !complete_bot_channel_vault(f.registry, "brg_vault", f.generation, reply), "duplicate result has no waiter")
	bot_vault_expect_no_cache(t, f, wire.request_id)
}

@(test)
bot_channel_vault_discards_lost_reply_and_superseded_connection :: proc(t: ^testing.T) {
	for replaced in ([]bool{false, true}) {
		f, fixture_ok := bot_vault_fixture_open(t)
		defer bot_vault_fixture_close(f)
		if !fixture_ok do return
		call := Bot_Vault_Test_Call{f = f, req = bot_vault_test_request(), timeout_ms = 500 if !replaced else 2_000}
		worker := thread.create_and_start_with_data(&call, bot_vault_test_call)
		if !testing.expect(t, worker != nil) do return
		joined := false
		defer {
			if !joined do thread.join(worker)
			thread.destroy(worker)
			contracts.bot_channel_vault_result_destroy(&call.result)
		}
		wire, got := bot_vault_read_wire(t, f.peer)
		if !got do return
		reply := contracts.Bot_Channel_Vault_Result{
			type = contracts.BOT_CHANNEL_VAULT_RESULT_FRAME, request_id = wire.request_id, operation = wire.operation,
			scope_digest = wire.scope_digest, status = "vault_locked",
		}
		if replaced {
			new_hello, admitted, _ := runtime_accept_hello(f.registry, "brg_vault", PROTOCOL_VERSION, "", "usr_vault")
			testing.expect(t, admitted && new_hello.replaced_existing)
			testing.expect(t, !complete_bot_channel_vault(f.registry, "brg_vault", new_hello.generation, reply), "new socket cannot claim the old slot")
		}
		thread.join(worker)
		joined = true
		testing.expect(t, !call.ok && call.result.body == "")
		testing.expect(t, !complete_bot_channel_vault(f.registry, "brg_vault", f.generation, reply), "late or superseded reply has no active waiter")
		bot_vault_expect_no_cache(t, f, wire.request_id)
	}
}
