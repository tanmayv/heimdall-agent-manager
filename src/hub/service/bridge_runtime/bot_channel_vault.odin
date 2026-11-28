package bridge_runtime

import "base:runtime"
import "core:crypto"
import "core:encoding/base64"
import "core:encoding/json"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import platform "odin_test:hub/platform"
import project "odin_test:hub/service/project"
import ws "odin_test:lib/ws"

// The application supplies the authorized target and the decoded input. This
// lane has no command ID, queue, result cache, retry, chunking or frame trace.
@(private)
bot_channel_vault_connection_live :: proc(c: ^project.Bridge_Runtime_Connection) -> bool {
	return c != nil && !sync.atomic_load(&c.retired) && !sync.atomic_load(&c.credential_revoked) &&
		!project.bridge_runtime_connection_auth_expired(c)
}

@(private)
bot_channel_vault_write :: proc(c: ^project.Bridge_Runtime_Connection, text: []byte, remaining: time.Duration) -> bool {
	started := time.tick_now()
	project.bridge_runtime_connection_lock_writer(c)
	defer sync.unlock(&c.writer_mutex)
	remaining := remaining - time.tick_since(started)
	if remaining <= 0 || c.socket == net.TCP_Socket(0) || !bot_channel_vault_connection_live(c) do return false
	header: [10]byte
	n := ws.server_frame_header(header[:], len(text))
	frame := make([]byte, n + len(text), runtime.default_allocator())
	defer {
		crypto.zero_explicit(raw_data(frame), len(frame))
		delete(frame, runtime.default_allocator())
	}
	copy(frame[:n], header[:n])
	copy(frame[n:], text)
	_, sent := ws.send_socket_bytes(c.socket, frame, remaining)
	if !sent do _ = net.shutdown(net.Any_Socket(c.socket), .Both)
	return sent
}

exchange_bot_channel_vault :: proc(registry: ^project.Bridge_Runtime_Registry, generation: int, request: contracts.Bot_Channel_Vault_Request) -> (contracts.Bot_Channel_Vault_Result, bool) {
	return exchange_bot_channel_vault_for(registry, generation, request, contracts.BOT_CHANNEL_VAULT_MAX_AGE_MS)
}

@(private)
exchange_bot_channel_vault_for :: proc(registry: ^project.Bridge_Runtime_Registry, generation: int, request: contracts.Bot_Channel_Vault_Request, budget: i64) -> (contracts.Bot_Channel_Vault_Result, bool) {
	now := project.bridge_runtime_wall_ms()
	if registry == nil || generation <= 0 || request.owner_user_id == "" || budget <= 0 || budget > contracts.BOT_CHANNEL_VAULT_MAX_AGE_MS do return {}, false
	limit := contracts.BOT_CHANNEL_VAULT_MAX_PLAINTEXT if request.operation == "seal" else contracts.BOT_CHANNEL_VAULT_MAX_TOKEN if request.operation == "open" else 0
	if len(request.body) == 0 || len(request.body) > limit do return {}, false
	c := project.bridge_runtime_connection_acquire(registry, request.bridge_id, generation)
	if c == nil do return {}, false
	defer project.bridge_runtime_connection_release(registry, c)
	if c.owner_id != request.owner_user_id || !bot_channel_vault_connection_live(c) do return {}, false

	started := time.tick_now()
	a := runtime.default_allocator()
	id, id_ok := platform.random_hex(16, a)
	if !id_ok do return {}, false
	defer delete(id, a)
	request := request
	request.type = contracts.BOT_CHANNEL_VAULT_REQUEST_FRAME
	request.request_id = id
	request.expires_at_ms = now + budget
	digest, digest_ok := contracts.bot_channel_vault_scope_digest(request, a)
	if !digest_ok do return {}, false
	defer delete(digest, a)
	request.scope_digest = digest
	body, enc_err := base64.encode(transmute([]byte)request.body, allocator = a)
	if enc_err != nil do return {}, false
	defer {
		crypto.zero_explicit(raw_data(body), len(body))
		delete(body, a)
	}
	request.body = body
	wire, marshal_err := json.marshal(request, allocator = a)
	defer if len(wire) > 0 {
		crypto.zero_explicit(raw_data(wire), len(wire))
		delete(wire, a)
	}
	if marshal_err != nil || len(wire) > contracts.BOT_CHANNEL_VAULT_MAX_FRAME do return {}, false

	pending := project.Channel_Vault_Pending{connection = c, request_id = id, operation = request.operation,
		scope_digest = digest, started = started, timeout = time.Millisecond * time.Duration(budget)}
	slot := -1
	sync.lock(&registry.channel_vault_mutex)
	for entry, i in registry.channel_vault_pending {
		if entry == nil {
			slot = i
			registry.channel_vault_pending[i] = &pending
			break
		}
	}
	sync.unlock(&registry.channel_vault_mutex)
	if slot < 0 do return {}, false
	defer {
		sync.lock(&registry.channel_vault_mutex)
		registry.channel_vault_pending[slot] = nil
		contracts.bot_channel_vault_result_destroy(&pending.result)
		sync.unlock(&registry.channel_vault_mutex)
	}

	sent := bot_channel_vault_write(c, wire, pending.timeout - time.tick_since(started))
	crypto.zero_explicit(raw_data(wire), len(wire))
	crypto.zero_explicit(raw_data(body), len(body))
	if !sent do return {}, false

	sync.lock(&registry.channel_vault_mutex)
	defer sync.unlock(&registry.channel_vault_mutex)
	for {
		remaining := pending.timeout - time.tick_since(started)
		if remaining <= 0 || !bot_channel_vault_connection_live(c) do return {}, false
		if pending.result.status != "" {
			result := pending.result
			pending.result = {}
			return result, true
		}
		_ = sync.cond_wait_with_timeout(&registry.channel_vault_cond, &registry.channel_vault_mutex, remaining)
	}
}

// A disposable, bounded copy is allowed only for the exact live waiter. Body
// bytes in an unmatched, repeated, expired or invalid result are never stored.
complete_bot_channel_vault :: proc(registry: ^project.Bridge_Runtime_Registry, bridge_id: string, generation: int, reply: contracts.Bot_Channel_Vault_Result) -> bool {
	if registry == nil || generation <= 0 || reply.type != contracts.BOT_CHANNEL_VAULT_RESULT_FRAME || len(reply.request_id) != 32 || len(reply.scope_digest) != 64 do return false
	c := project.bridge_runtime_connection_acquire(registry, bridge_id, generation)
	if c == nil do return false
	defer project.bridge_runtime_connection_release(registry, c)
	if !bot_channel_vault_connection_live(c) do return false

	status := ""
	for code in ([]string{"ok", "invalid_request", "stale_placement", "owner_mismatch", "vault_locked", "key_unavailable", "invalid_scope"}) {
		if reply.status == code do status = code
	}
	if status == "" || (status != "ok" && reply.body != "") do return false

	sync.lock(&registry.channel_vault_mutex)
	defer sync.unlock(&registry.channel_vault_mutex)
	for pending in registry.channel_vault_pending {
		if pending == nil || pending.connection != c || pending.request_id != reply.request_id ||
			pending.scope_digest != reply.scope_digest || pending.operation != reply.operation ||
			pending.result.status != "" || time.tick_since(pending.started) >= pending.timeout {
			continue
		}
		if !bot_channel_vault_connection_live(c) do return false
		a := runtime.default_allocator()
		out: []byte
		if status == "ok" {
			limit := contracts.BOT_CHANNEL_VAULT_MAX_TOKEN if pending.operation == "seal" else contracts.BOT_CHANNEL_VAULT_MAX_PLAINTEXT
			if len(reply.body) == 0 || len(reply.body) > ((limit+2)/3)*4 do return false
			decoded, err := base64.decode(reply.body, allocator = a)
			out = decoded
			if err != nil || len(out) == 0 || len(out) > limit {
				if len(out) > 0 do crypto.zero_explicit(raw_data(out), len(out))
				delete(out, a)
				return false
			}
		}
		operation := "seal" if pending.operation == "seal" else "open"
		pending.result = {
			type = contracts.BOT_CHANNEL_VAULT_RESULT_FRAME, request_id = strings.clone(reply.request_id, a),
			operation = operation, scope_digest = strings.clone(reply.scope_digest, a), status = status, body = string(out),
		}
		sync.cond_broadcast(&registry.channel_vault_cond)
		return true
	}
	return false
}
