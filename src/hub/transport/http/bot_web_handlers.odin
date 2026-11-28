package http

import "core:encoding/json"
import "core:strconv"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import bots "odin_test:hub/service/bots"

bot_web_messages_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bot_Handlers)(ctx)
	auth, ok, refusal := bot_require_auth(h, req)
	if !ok do return refusal
	if fence := bots.bots_legacy_guard(h.bots, auth.user_id); fence.code != .None do return respond_error(fence, req.request_id)
	value, parse_err := json.parse(req.body, allocator = context.temp_allocator)
	obj, object_ok := value.(json.Object)
	text, text_ok := obj["text"].(json.String)
	key, key_ok := obj["idempotency_key"].(json.String)
	if parse_err != nil || !object_ok || !text_ok || !key_ok do return respond_error(domain.domain_error(.Validation_Failed, "text and idempotency_key must be strings"), req.request_id)
	attachments := make([dynamic]domain.Channel_Attachment, context.temp_allocator)
	if raw, present := obj["artifact_ids"]; present {
		ids, array_ok := raw.(json.Array)
		if !array_ok || len(ids) > 20 do return respond_error(domain.domain_error(.Validation_Failed, "artifact_ids must be an array of up to 20 IDs"), req.request_id)
		seen := make(map[string]bool, context.temp_allocator)
		for item in ids {
			id, valid := item.(json.String)
			if !valid || len(id) == 0 || len(id) > 128 || seen[string(id)] do return respond_error(domain.domain_error(.Validation_Failed, "invalid or duplicate artifact ID"), req.request_id)
			seen[string(id)] = true
			a, found, e := iface.content_get_artifact(h.content, string(id))
			defer domain.artifact_destroy(&a)
			if e.code != .None do return respond_error(e, req.request_id)
			if !found || string(a.owner_user_id) != auth.user_id || a.deleted_at != "" do return respond_error(domain.domain_error(.Not_Found, "artifact not found"), req.request_id)
			mime := a.mime if a.mime != "" else a.content_type
			append(&attachments, domain.Channel_Attachment{
				kind = .Image if strings.has_prefix(mime, "image/") else .Document,
				artifact_id = strings.clone(a.artifact_id, context.temp_allocator),
				name = strings.clone(a.name, context.temp_allocator), mime = strings.clone(mime, context.temp_allocator),
				size_bytes = i64(a.size_bytes), state = .Stored,
			})
		}
	}
	message, fresh, err := bots.bots_web_send(h.bots, auth.user_id, string(text), string(key), attachments[:])
	defer domain.channel_message_destroy(&message)
	if err.code != .None do return respond_error(err, req.request_id)
	return respond_success_typed(struct {message_id: string, created: bool}{message.message_id, fresh}, req.request_id, auth_ctx_server_time(req), 201 if fresh else 200)
}

Bot_History_Message :: struct {
	message_id, binding_id, provider, direction, body: string,
	body_purged: bool,
	send_state, created_at, read_at, replied_at: string,
	attachments: []Bot_Channel_Attachment_Wire,
	metadata: json.Object `json:"metadata,omitempty"`,
}
bot_history_message_ids :: proc(raw: string) -> ([]string, bool) {
	if len(raw) > 6000 do return nil, false
	value, err := json.parse(raw, allocator = context.temp_allocator)
	array, ok := value.(json.Array)
	if err != nil || !ok || len(array) == 0 || len(array) > 25 do return nil, false
	ids := make([]string, len(array), context.temp_allocator)
	for item, i in array {
		id, valid := item.(json.String)
		if !valid || len(id) == 0 || len(id) > 200 do return nil, false
		ids[i] = string(id)
	}
	return ids, true
}

bot_unified_messages_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bot_Handlers)(ctx)
	auth, ok, refusal := bot_require_auth(h, req)
	if !ok do return refusal
	if fence := bots.bots_legacy_guard(h.bots, auth.user_id); fence.code != .None do return respond_error(fence, req.request_id)
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
	messages: []domain.Channel_Message
	list_err: domain.Domain_Error
	if has_query_key(req.query, "message_ids") {
		ids, valid := bot_history_message_ids(query_value(req.query, "message_ids"))
		if !valid || has_query_key(req.query, "cursor") || has_query_key(req.query, "limit") {
			return respond_error(domain.domain_error(.Validation_Failed, "message_ids requires an array of 1..25 IDs without pagination"), req.request_id)
		}
		messages, list_err = iface.messages_by_ids(h.bots.repo, auth.user_id, bot.bot_id, ids)
	} else {
		messages, list_err = iface.messages_page(h.bots.repo, auth.user_id, bot.bot_id, cursor, limit + 1)
	}
	defer {for &m in messages do domain.channel_message_destroy(&m); delete(messages)}
	if list_err.code != .None do return respond_error(list_err, req.request_id)
	ids := make([]string, min(limit, len(messages)), context.temp_allocator)
	for m, i in messages[:len(ids)] do ids[i] = m.message_id
	attachments, ae := iface.attachments_for_messages(h.bots.repo, ids)
	defer {for &a in attachments do domain.channel_attachment_destroy(&a); delete(attachments)}
	if ae.code != .None do return respond_error(ae, req.request_id)
	wire := make([]Bot_History_Message, min(limit, len(messages)), context.temp_allocator)
	for m, i in messages[:len(wire)] {
		binding, found, e := iface.binding_get(h.bots.repo, m.binding_id)
		defer domain.channel_binding_destroy(&binding)
		if e.code != .None do return respond_error(e, req.request_id)
		if !found || binding.owner_user_id != auth.user_id || binding.bot_id != bot.bot_id do return respond_error(domain.domain_error(.Internal_Error, "message binding missing"), req.request_id)
		metadata: json.Object
		if binding.provider == domain.CHANNEL_PROVIDER_WEB && m.direction == .Outbound && !m.body_purged && m.action_ids_json != "" {
			ids: []string
			if json.unmarshal(transmute([]u8)m.action_ids_json, &ids, allocator = context.temp_allocator) == nil && len(ids) > 0 {
				visible, card_err := bot_visible_action_ids(h.cards, domain.User_ID(auth.user_id), ids)
				if card_err.code != .None do return respond_error(card_err, req.request_id)
				if len(visible) > 0 {
					values := make(json.Array, len(visible), context.temp_allocator)
					for id, index in visible do values[index] = json.String(id)
					metadata = make(json.Object, 1, context.temp_allocator)
					metadata["action_ids"] = values
				}
			}
		}
		wire[i] = {m.message_id, m.binding_id, binding.provider, domain.channel_direction_text(m.direction), m.body, m.body_purged, domain.channel_send_state_text(m.send_state), m.created_at, m.read_at, m.replied_at, nil if m.body_purged else bot_channel_attachment_wires(attachments, m.message_id), metadata}
	}
	next := ""
	if len(messages) > limit do next = messages[limit-1].message_id
	return respond_success_typed(struct {messages: []Bot_History_Message, next_cursor: string}{wire, next}, req.request_id, auth_ctx_server_time(req))
}
