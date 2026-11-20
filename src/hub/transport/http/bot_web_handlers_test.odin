package http

import "core:encoding/json"
import "core:fmt"
import "core:testing"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"

@(test)
test_web_http_auth_gate_validation_idempotency :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := bot_http_fixture(t); defer bot_http_destroy(f)
	_ = bot_http_create(t, f)
	lookup := Bot_HTTP_WA_Lookup{}
	f.service.entitlements = {ctx = &lookup, lookup = bot_http_wa_lookup}
	path := "/api/v1/bots/me/channels/web/messages"
	unauth := bot_web_messages_handler(&f.handlers, {method = "POST", path = path, body = "{}"})
	testing.expect_value(t, unauth.status, 401)
	for body in ([]string{`{}`, `{"text":9,"idempotency_key":"k"}`, `{"text":"hi","idempotency_key":null}`, `{"text":"","idempotency_key":"k"}`, `{"text":"hi","idempotency_key":""}`, `{"text":"   ","idempotency_key":"k"}`, `[]`, `{`}) {
		response := bot_web_messages_handler(&f.handlers, bot_http_request(f, "POST", path, body))
		testing.expectf(t, response.status == 400, "%s: %s", body, response.body)
	}
	oversized, _ := json.marshal(struct {text, idempotency_key: string}{strings.repeat("x", 16385), "k"}, allocator = context.temp_allocator)
	testing.expect_value(t, bot_web_messages_handler(&f.handlers, bot_http_request(f, "POST", path, string(oversized))).status, 400)
	first := bot_web_messages_handler(&f.handlers, bot_http_request(f, "POST", path, `{"text":"hello","idempotency_key":"once"}`))
	testing.expectf(t, first.status == 201, "%s", first.body)
	wire: struct {data: struct {message_id: string, created: bool}}
	_ = json.unmarshal(transmute([]u8)first.body, &wire, allocator = context.temp_allocator)
	testing.expect(t, wire.data.created && wire.data.message_id != "")
	replay := bot_web_messages_handler(&f.handlers, bot_http_request(f, "POST", path, `{"text":"hello","idempotency_key":"once"}`))
	testing.expect_value(t, replay.status, 200)
	replay_wire: type_of(wire)
	_ = json.unmarshal(transmute([]u8)replay.body, &replay_wire, allocator = context.temp_allocator)
	testing.expect(t, !replay_wire.data.created && replay_wire.data.message_id == wire.data.message_id)
	conflict := bot_web_messages_handler(&f.handlers, bot_http_request(f, "POST", path, `{"text":"different","idempotency_key":"once"}`))
	testing.expect_value(t, conflict.status, 409)
	_, _ = iface.experiment_set(&f.experiments, {owner_user_id = string(f.wire.owner), key = "bots", enabled = false})
	testing.expect_value(t, bot_web_messages_handler(&f.handlers, bot_http_request(f, "POST", path, `{"text":"hello","idempotency_key":"next"}`)).status, 403)
	testing.expect_value(t, bot_unified_messages_handler(&f.handlers, bot_http_request(f, "GET", "/api/v1/bots/me/messages", "")).status, 403)
}

@(test)
test_web_unified_history_mixed_providers_paging_and_owner_scope :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := bot_http_fixture(t); defer bot_http_destroy(f)
	bot := bot_http_create(t, f)
	for provider in ([]string{"telegram", "whatsapp", "web"}) {
		binding_id := strings.concatenate({"chb_history_", provider}, context.temp_allocator)
		testing.expect(t, sqlite.exec(&f.wire.conn, fmt.tprintf(`INSERT INTO channel_bindings(binding_id,owner_user_id,bot_id,provider,external_chat_id,external_user_id,state,created_at) VALUES('%s','%s','%s','%s','chat','user','active','2026-11-20T00:00:00Z');`, binding_id, bot.owner_user_id, bot.bot_id, provider)))
		for direction in ([]domain.Channel_Direction{.Inbound, .Outbound}) {
			id := strings.concatenate({provider, "-", domain.channel_direction_text(direction)}, context.temp_allocator)
			testing.expect_value(t, iface.message_insert_outbound(&f.bot_repo, {message_id = id, binding_id = binding_id, owner_user_id = bot.owner_user_id, bot_id = bot.bot_id, direction = direction, body = id, send_state = .Sent if direction == .Outbound else .None, created_at = "2026-11-20T00:00:00Z"}).code, domain.Error_Code.None)
		}
	}
	testing.expect_value(t, iface.message_insert_outbound(&f.bot_repo, {message_id = "other-owner", binding_id = "other-binding", owner_user_id = "bob", bot_id = bot.bot_id, direction = .Inbound, body = "secret", created_at = "2026-11-20T00:01:00Z"}).code, domain.Error_Code.None)
	seen := make(map[string]bool, context.temp_allocator)
	providers := make(map[string]bool, context.temp_allocator)
	cursor := ""
	for page in 0..<3 {
		req := bot_http_request(f, "GET", "/api/v1/bots/me/messages", "")
		req.query = fmt.tprintf("limit=2&cursor=%s", cursor)
		response := bot_unified_messages_handler(&f.handlers, req)
		testing.expectf(t, response.status == 200, "%s", response.body)
		wire: struct {data: struct {messages: []Bot_History_Message, next_cursor: string}}
		_ = json.unmarshal(transmute([]u8)response.body, &wire, allocator = context.temp_allocator)
		testing.expect_value(t, len(wire.data.messages), 2)
		for m in wire.data.messages {
			testing.expect(t, !seen[m.message_id] && m.body != "secret")
			seen[m.message_id] = true
			providers[m.provider] = true
			testing.expect(t, m.created_at != "" && m.direction != "")
		}
		cursor = wire.data.next_cursor
		testing.expect_value(t, cursor != "", page < 2)
	}
	testing.expect_value(t, len(seen), 6)
	testing.expect_value(t, len(providers), 3)
	for query in ([]string{"limit=0", "limit=201", "limit=no", "cursor=missing", "cursor=other-owner"}) {
		req := bot_http_request(f, "GET", "/api/v1/bots/me/messages", ""); req.query = query
		testing.expect_value(t, bot_unified_messages_handler(&f.handlers, req).status, 400)
	}
	// No messages is a normal terminal page.
	testing.expect(t, sqlite.exec(&f.wire.conn, "DELETE FROM channel_messages;"))
	empty := bot_unified_messages_handler(&f.handlers, bot_http_request(f, "GET", "/api/v1/bots/me/messages", ""))
	testing.expect(t, empty.status == 200 && strings.contains(empty.body, `"next_cursor":""`))
}
