package http

import "core:encoding/json"
import "core:strconv"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import bots "odin_test:hub/service/bots"

bot_web_messages_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bot_Handlers)(ctx)
	auth, ok, refusal := bot_require_auth(h, req)
	if !ok do return refusal
	value, parse_err := json.parse(req.body, allocator = context.temp_allocator)
	obj, object_ok := value.(json.Object)
	text, text_ok := obj["text"].(json.String)
	key, key_ok := obj["idempotency_key"].(json.String)
	if parse_err != nil || !object_ok || !text_ok || !key_ok do return respond_error(domain.domain_error(.Validation_Failed, "text and idempotency_key must be strings"), req.request_id)
	message, fresh, err := bots.bots_web_send(h.bots, auth.user_id, string(text), string(key))
	defer domain.channel_message_destroy(&message)
	if err.code != .None do return respond_error(err, req.request_id)
	return respond_success_typed(struct {message_id: string, created: bool}{message.message_id, fresh}, req.request_id, auth_ctx_server_time(req), 201 if fresh else 200)
}

Bot_History_Message :: struct {
	message_id, binding_id, provider, direction, body: string,
	body_purged: bool,
	send_state, created_at, read_at, replied_at: string,
}
bot_unified_messages_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bot_Handlers)(ctx)
	auth, ok, refusal := bot_require_auth(h, req)
	if !ok do return refusal
	bot, err := bots.bots_get(h.bots, auth.user_id)
	defer domain.bot_destroy(&bot)
	if err.code != .None do return respond_error(err, req.request_id)
	limit := 50
	if has_query_key(req.query, "limit") {
		n, valid := strconv.parse_int(query_value(req.query, "limit"))
		if !valid || n < 1 || n > 200 do return respond_error(domain.domain_error(.Validation_Failed, "limit must be 1..200"), req.request_id)
		limit = n
	}
	cursor := query_value(req.query, "cursor")
	if len(cursor) > 200 do return respond_error(domain.domain_error(.Validation_Failed, "invalid history cursor"), req.request_id)
	messages, list_err := iface.messages_page(h.bots.repo, auth.user_id, bot.bot_id, cursor, limit + 1)
	defer {for &m in messages do domain.channel_message_destroy(&m); delete(messages)}
	if list_err.code != .None do return respond_error(list_err, req.request_id)
	wire := make([]Bot_History_Message, min(limit, len(messages)), context.temp_allocator)
	for m, i in messages[:len(wire)] {
		binding, found, e := iface.binding_get(h.bots.repo, m.binding_id)
		defer domain.channel_binding_destroy(&binding)
		if e.code != .None do return respond_error(e, req.request_id)
		if !found || binding.owner_user_id != auth.user_id || binding.bot_id != bot.bot_id do return respond_error(domain.domain_error(.Internal_Error, "message binding missing"), req.request_id)
		wire[i] = {m.message_id, m.binding_id, binding.provider, domain.channel_direction_text(m.direction), m.body, m.body_purged, domain.channel_send_state_text(m.send_state), m.created_at, m.read_at, m.replied_at}
	}
	next := ""
	if len(messages) > limit do next = messages[limit-1].message_id
	return respond_success_typed(struct {messages: []Bot_History_Message, next_cursor: string}{wire, next}, req.request_id, auth_ctx_server_time(req))
}
