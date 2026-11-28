package http

import "base:runtime"
import "core:encoding/json"
import "core:strings"
import "core:encoding/base64"
import contracts "odin_test:contracts"
import content_service "odin_test:hub/service/content"
import "core:unicode/utf8"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import bots "odin_test:hub/service/bots"

Bot_Channel_Read_Message :: struct {message_id, body, created_at, sender, channel: string, attachments: []Bot_Channel_Attachment_Wire `json:"attachments,omitempty"`}
Bot_Channel_History_Message :: struct {message_id, direction, body, created_at, channel: string, attachments: []Bot_Channel_Attachment_Wire `json:"attachments,omitempty"`}

Bot_Agent_Handlers :: struct {
	agent_actions: ^Agent_Action_Handlers,
	bots: ^bots.Bots_Service,
	experiments: ^iface.Experiment_Repository,
}

bot_channel_require :: proc(h: ^Bot_Agent_Handlers, req: Request) -> (domain.Bot, contracts.Auth_Context, bool, Response) {
	auth, inst, ok, refusal := require_instance_action_auth(h.agent_actions, req)
	if !ok do return {}, auth, false, refusal
	defer domain.agent_instance_destroy(&inst)
	if enabled, resp := require_experiment_enabled(h.experiments, auth.user_id, "bots", req.request_id); !enabled do return {}, auth, false, resp
	bot, found, err := iface.bot_get_by_instance(h.bots.repo, inst.agent_instance_id)
	if err.code != .None {domain.bot_destroy(&bot); return {}, auth, false, respond_error(err, req.request_id)}
	if !found || bot.owner_user_id != auth.user_id {
		domain.bot_destroy(&bot)
		return {}, auth, false, respond_error(bots.bots_detail_error(.Forbidden, "not_a_bot"), req.request_id)
	}
	if fence := bots.bots_legacy_guard(h.bots, bot.owner_user_id); fence.code != .None {
		domain.bot_destroy(&bot)
		return {}, auth, false, respond_error(fence, req.request_id)
	}
	bindings, binding_err := iface.bindings_active_for_owner(h.bots.repo, bot.owner_user_id)
	defer {for &b in bindings do domain.channel_binding_destroy(&b); delete(bindings)}
	if binding_err.code != .None || len(bindings) == 0 {
		domain.bot_destroy(&bot)
		if binding_err.code == .None do binding_err = bots.bots_detail_error(.Conflict, "channel_not_paired")
		return {}, auth, false, respond_error(binding_err, req.request_id)
	}
	return bot, auth, true, {}
}

bot_channel_limit :: proc(req: Request, maximum: int) -> (int, bool) {
	params := json_object_raw(req.body, "params", context.temp_allocator)
	if params == "" do return 20, true
	value, err := json.parse(params, parse_integers = true, allocator = context.temp_allocator)
	if err != nil do return 0, false
	obj, ok := value.(json.Object)
	if !ok do return 0, false
	raw, present := obj["limit"]
	if !present do return 20, true
	n, integer := raw.(json.Integer)
	return int(n), integer && n >= 1 && n <= json.Integer(maximum)
}

bot_agent_channel_read_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bot_Agent_Handlers)(ctx)
	bot, _, ok, refusal := bot_channel_require(h, req)
	if !ok do return refusal
	defer domain.bot_destroy(&bot)
	limit, valid := bot_channel_limit(req, 50)
	if !valid do return respond_error(domain.domain_error(.Validation_Failed, "limit must be 1..50"), req.request_id)
	binding, found, binding_err := bots.bots_read_binding(h.bots, bot.owner_user_id, bot.bot_id)
	defer domain.channel_binding_destroy(&binding)
	if binding_err.code != .None do return respond_error(binding_err, req.request_id)
	if !found do return respond_error(bots.bots_detail_error(.Conflict, "channel_not_paired"), req.request_id)
	messages, total, err := bots.bots_channel_read(h.bots, bot.bot_id, binding, limit)
	defer {for &m in messages do domain.channel_message_destroy(&m); delete(messages)}
	if err.code != .None do return respond_error(err, req.request_id)
	attachments, ae := bot_channel_attachments(h, messages)
	defer {for &a in attachments do domain.channel_attachment_destroy(&a); delete(attachments)}
	if ae.code != .None do return respond_error(ae, req.request_id)
	wire := make([dynamic]Bot_Channel_Read_Message, context.temp_allocator)
	for m in messages do append(&wire, Bot_Channel_Read_Message{message_id = m.message_id, body = m.body, created_at = m.created_at, sender = binding.external_display, channel = binding.provider, attachments = bot_channel_attachment_wires(attachments, m.message_id)})
	return respond_success_typed(struct {messages: []Bot_Channel_Read_Message, pending_total: int}{wire[:], total}, req.request_id, auth_ctx_server_time(req))
}

bot_agent_channel_send_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bot_Agent_Handlers)(ctx)
	bot, auth, ok, refusal := bot_channel_require(h, req)
	if !ok do return refusal
	defer domain.bot_destroy(&bot)
	params := json_object_raw(req.body, "params", context.temp_allocator)
	value, parse_err := json.parse(params, parse_integers = true, allocator = context.temp_allocator)
	obj, object_ok := value.(json.Object)
	if parse_err == nil && object_ok {
		if _, present := obj["artifact_id"]; present {
			if _, actions_present := obj["action_ids"]; actions_present do return respond_error(bots.bots_detail_error(.Validation_Failed, "action_ids_require_text"), req.request_id)
			if !utf8.valid_string(params) do return respond_error(bots.bots_detail_error(.Validation_Failed, "text_invalid"), req.request_id)
			return bot_agent_channel_send_media(h, req, bot, auth, obj)
		}
		if _, present := obj["media"]; present do return respond_error(bots.bots_detail_error(.Validation_Failed, "media_invalid"), req.request_id)
	}
	text, string_ok := obj["text"].(string)
	if parse_err != nil || !object_ok || !string_ok || !utf8.valid_string(params) do return respond_error(bots.bots_detail_error(.Validation_Failed, "text_invalid"), req.request_id)
	if len(text) < 1 || len(text) > 16384 || !utf8.valid_string(text) do return respond_error(bots.bots_detail_error(.Validation_Failed, "text_invalid"), req.request_id)
	binding, found, binding_err := bots.bots_reply_binding(h.bots, bot.owner_user_id, bot.bot_id)
	defer domain.channel_binding_destroy(&binding)
	if binding_err.code != .None do return respond_error(binding_err, req.request_id)
	if !found do return respond_error(bots.bots_detail_error(.Conflict, "channel_not_paired"), req.request_id)
	action_ids_json, actions_err := bot_web_action_refs(h, auth, binding.provider, obj)
	if actions_err.code != .None do return respond_error(actions_err, req.request_id)
	ids, held, err := bots.channel_send(h.bots, binding, text, true, action_ids_json)
	defer {for id in ids do delete(id); delete(ids)}
	if err.code != .None do return respond_error(err, req.request_id)
	if e := bots.bots_channel_replied(h.bots, bot.bot_id, binding.binding_id); e.code != .None do return respond_error(e, req.request_id)
	return respond_success_typed(struct {message_ids: []string, chunks: int, channel: string, held: bool}{ids, len(ids), binding.provider, held}, req.request_id, auth_ctx_server_time(req))
}

// Card details remain in the existing card API. Persist only validated IDs.
bot_web_action_refs :: proc(h: ^Bot_Agent_Handlers, auth: contracts.Auth_Context, provider: string, params: json.Object) -> (string, domain.Domain_Error) {
	raw, supplied := params["action_ids"]
	if !supplied do return "", {}
	if provider != domain.CHANNEL_PROVIDER_WEB do return "", bots.bots_detail_error(.Conflict, "action_ids_require_web")
	items, array_ok := raw.(json.Array)
	invalid := bots.bots_detail_error(.Validation_Failed, "action_ids_invalid")
	if !array_ok || len(items) == 0 || len(items) > contracts.BOT_WEB_MAX_ACTION_IDS do return "", invalid
	ids := make([]string, len(items), context.temp_allocator)
	for item, i in items {
		id, string_ok := item.(string)
		if !string_ok || !strings.has_prefix(id, "crd_") || len(id) > 200 do return "", invalid
		for prior in ids[:i] do if prior == id do return "", invalid
		ids[i] = id
	}
	if h.agent_actions.cards == nil do return "", domain.domain_error(.Internal_Error, "card service is not configured")
	visible, lookup_err := bot_visible_action_ids(h.agent_actions.cards.cards, domain.User_ID(auth.user_id), ids)
	if lookup_err.code != .None do return "", lookup_err
	if len(visible) != len(ids) do return "", bots.bots_detail_error(.Not_Found, "action_card_not_found")
	data, err := json.marshal(ids, allocator = context.temp_allocator)
	if err != nil do return "", invalid
	return string(data), {}
}

// Match the card endpoint's owner check without materializing projected cards.
bot_visible_action_ids :: proc(repo: ^iface.Card_Repository, owner: domain.User_ID, ids: []string) -> ([]string, domain.Domain_Error) {
	visible := make([dynamic]string, context.temp_allocator)
	for id in ids {
		temp := runtime.default_temp_allocator_temp_begin()
		context.allocator = context.temp_allocator
		card, found, err := iface.card_get(repo, domain.Card_ID(id))
		allowed := found && card.owner_user_id == owner
		runtime.default_temp_allocator_temp_end(temp)
		if err.code != .None && err.code != .Not_Found do return nil, domain.domain_error(err.code, "card lookup failed")
		if allowed do append(&visible, id)
	}
	return visible[:], {}
}

bot_agent_channel_history_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bot_Agent_Handlers)(ctx)
	bot, _, ok, refusal := bot_channel_require(h, req)
	if !ok do return refusal
	defer domain.bot_destroy(&bot)
	limit, valid := bot_channel_limit(req, 100)
	if !valid do return respond_error(domain.domain_error(.Validation_Failed, "limit must be 1..100"), req.request_id)
	messages, err := iface.messages_history(h.bots.repo, bot.bot_id, -1)
	defer {for &m in messages do domain.channel_message_destroy(&m); delete(messages)}
	if err.code != .None do return respond_error(err, req.request_id)
	active, active_err := iface.bindings_active_for_owner(h.bots.repo, bot.owner_user_id)
	defer {for &b in active do domain.channel_binding_destroy(&b); delete(active)}
	if active_err.code != .None do return respond_error(active_err, req.request_id)
	attachments, ae := bot_channel_attachments(h, messages)
	defer {for &a in attachments do domain.channel_attachment_destroy(&a); delete(attachments)}
	if ae.code != .None do return respond_error(ae, req.request_id)
	wire := make([dynamic]Bot_Channel_History_Message, context.temp_allocator)
	for m in messages {
		if m.body_purged do continue
		provider := ""
		for b in active do if b.binding_id == m.binding_id {provider = b.provider; break}
		if provider == "" do continue
		if len(wire) == limit do break
		append(&wire, Bot_Channel_History_Message{message_id = m.message_id, direction = domain.channel_direction_text(m.direction), body = m.body, created_at = m.created_at, channel = provider, attachments = bot_channel_attachment_wires(attachments, m.message_id)})
	}
	return respond_success_typed(struct {messages: []Bot_Channel_History_Message}{wire[:]}, req.request_id, auth_ctx_server_time(req))
}

// Attachment strings are borrowed from snapshots held until the response is serialized.
Bot_Channel_Attachment_Wire :: struct {attachment_id, kind, name, mime: string, size: i64, artifact_id, state: string}
bot_channel_attachment_wires :: proc(attachments: []domain.Channel_Attachment, message_id: string) -> []Bot_Channel_Attachment_Wire {
	out := make([dynamic]Bot_Channel_Attachment_Wire, context.temp_allocator)
	for a in attachments do if a.message_id == message_id do append(&out, Bot_Channel_Attachment_Wire{
		a.attachment_id, domain.channel_media_kind_text(a.kind), a.name, a.mime, a.size_bytes, a.artifact_id, domain.channel_attachment_state_text(a.state)})
	return out[:]
}
bot_channel_attachments :: proc(h: ^Bot_Agent_Handlers, messages: []domain.Channel_Message) -> ([]domain.Channel_Attachment, domain.Domain_Error) {
	ids := make([]string, len(messages), context.temp_allocator)
	for m, i in messages do ids[i] = m.message_id
	return iface.attachments_for_messages(h.bots.repo, ids)
}
bot_media_object :: proc(body: string) -> (json.Object, bool) {
	value, err := json.parse(body, parse_integers = true, allocator = context.temp_allocator)
	obj, ok := value.(json.Object)
	return obj, ok && err == nil && utf8.valid_string(body)
}
bot_media_artifact_check :: proc(h: ^Bot_Agent_Handlers, auth: contracts.Auth_Context, id: string) -> domain.Domain_Error {
	// Ownership rejection in get_artifact may discard its loaded snapshot.
	// All allocations in this check belong to the request scratch arena.
	context.allocator = context.temp_allocator
	if h.agent_actions.content == nil do return bots.bots_detail_error(.Not_Found, "artifact_not_found")
	a, found, err := content_service.get_artifact(h.agent_actions.content, auth, id)
	defer domain.artifact_destroy(&a)
	if err.code != .None || !found || a.deleted_at != "" do return bots.bots_detail_error(.Not_Found, "artifact_not_found")
	return {}
}

bot_agent_media_fetch_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bot_Agent_Handlers)(ctx)
	bot, _, ok, refusal := bot_channel_require(h, req)
	if !ok do return refusal
	defer domain.bot_destroy(&bot)
	obj, valid := bot_media_object(req.body)
	id, is_string := obj["attachment_id"].(string)
	if !valid || !is_string do return respond_error(bots.bots_detail_error(.Validation_Failed, "attachment_id_invalid"), req.request_id)
	f, err := bots.bots_media_fetch(h.bots, bot, id)
	defer bots.bot_media_fetch_destroy(&f)
	if err.code != .None do return respond_error(err, req.request_id)
	switch f.outcome {
	case "fetched":
		encoded := base64.encode(f.bytes)
		defer delete(encoded)
		return respond_success_typed(struct {attachment_id, outcome, kind, name, mime: string, size: int, content_base64: string}{
			id, f.outcome, domain.channel_media_kind_text(f.attachment.kind), f.attachment.name, f.mime, len(f.bytes), encoded}, req.request_id, auth_ctx_server_time(req))
	case "stored":
		return respond_success_typed(struct {attachment_id, outcome, artifact_id: string}{id, f.outcome, f.attachment.artifact_id}, req.request_id, auth_ctx_server_time(req))
	case "failed":
		return respond_success_typed(struct {attachment_id, outcome, error: string}{id, f.outcome, f.error_kind}, req.request_id, auth_ctx_server_time(req))
	}
	return respond_success_typed(struct {attachment_id, outcome: string}{id, f.outcome}, req.request_id, auth_ctx_server_time(req))
}

bot_agent_media_stored_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bot_Agent_Handlers)(ctx)
	bot, auth, ok, refusal := bot_channel_require(h, req)
	if !ok do return refusal
	defer domain.bot_destroy(&bot)
	obj, valid := bot_media_object(req.body)
	id, is_string := obj["attachment_id"].(string)
	if !valid || !is_string do return respond_error(bots.bots_detail_error(.Validation_Failed, "attachment_id_invalid"), req.request_id)
	artifact_id, _ := obj["artifact_id"].(string)
	if e := bot_media_artifact_check(h, auth, artifact_id); e.code != .None do return respond_error(e, req.request_id)
	recorded, err := bots.bots_media_stored(h.bots, bot, id, artifact_id)
	defer delete(recorded)
	if err.code != .None do return respond_error(err, req.request_id)
	return respond_success_typed(struct {attachment_id, artifact_id: string}{id, recorded}, req.request_id, auth_ctx_server_time(req))
}

bot_agent_media_plan_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bot_Agent_Handlers)(ctx)
	bot, _, ok, refusal := bot_channel_require(h, req)
	if !ok do return refusal
	defer domain.bot_destroy(&bot)
	obj, valid := bot_media_object(req.body)
	mime, is_string := obj["mime"].(string)
	size, integer := obj["size"].(json.Integer)
	if !valid || !is_string || !integer || size < 1 || size > json.Integer(contracts.ARTIFACT_MAX_CONTENT_BYTES) do return respond_error(bots.bots_detail_error(.Validation_Failed, "media_invalid"), req.request_id)
	binding, found, err := bots.bots_reply_binding(h.bots, bot.owner_user_id, bot.bot_id)
	defer domain.channel_binding_destroy(&binding)
	if err.code != .None do return respond_error(err, req.request_id)
	if !found do return respond_error(bots.bots_detail_error(.Conflict, "channel_not_paired"), req.request_id)
	plan := bots.bots_media_plan(bots.bots_adapter(h.bots, binding.provider), binding, bots.bots_media_mime(.Document, mime), i64(size), bots.bots_now_ms(h.bots))
	kind := ""
	if plan.mode == .Native do kind = domain.channel_media_kind_text(domain.Channel_Media_Kind(plan.rules[0].kind))
	return respond_success_typed(struct {channel, mode, kind, reason: string}{
		binding.provider, "native" if plan.mode == .Native else "link", kind, plan.reason}, req.request_id, auth_ctx_server_time(req))
}

bot_agent_channel_send_media :: proc(h: ^Bot_Agent_Handlers, req: Request, bot: domain.Bot, auth: contracts.Auth_Context, obj: json.Object) -> Response {
	bad := bots.bots_detail_error(.Validation_Failed, "media_invalid")
	artifact_id, id_string := obj["artifact_id"].(string)
	if !id_string || len(artifact_id) < 1 || len(artifact_id) > 128 do return respond_error(bad, req.request_id)
	for c in transmute([]byte)artifact_id {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-') do return respond_error(bad, req.request_id)
	}
	text := ""
	if value, present := obj["text"]; present {
		caption, is_string := value.(string)
		if !is_string || len(caption) > 16384 || !utf8.valid_string(caption) do return respond_error(bots.bots_detail_error(.Validation_Failed, "text_invalid"), req.request_id)
		text = caption
	}
	media, is_object := obj["media"].(json.Object)
	if !is_object do return respond_error(bad, req.request_id)
	mime, mime_string := media["mime"].(string)
	name, name_string := media["name"].(string)
	size, integer := media["size"].(json.Integer)
	if !mime_string || !name_string || !integer || size < 1 || size > json.Integer(contracts.ARTIFACT_MAX_CONTENT_BYTES) do return respond_error(bad, req.request_id)
	mime = bots.bots_media_mime(.Document, mime)
	name = bots.bots_media_name(bots.bots_media_kind_for_mime(mime), name, mime)
	bytes: []byte
	defer delete(bytes)
	if value, present := media["content_base64"]; present {
		encoded, is_string := value.(string)
		// Bound decoding before allocating; valid canonical base64 needs exactly this length.
		if !is_string || len(encoded) != 4 * ((int(size)+2)/3) do return respond_error(bad, req.request_id)
		decoded, e := base64.decode(encoded)
		bytes = decoded
		if e != nil || len(bytes) != int(size) do return respond_error(bad, req.request_id)
	}
	if e := bot_media_artifact_check(h, auth, artifact_id); e.code != .None do return respond_error(e, req.request_id)
	binding, found, binding_err := bots.bots_reply_binding(h.bots, bot.owner_user_id, bot.bot_id)
	defer domain.channel_binding_destroy(&binding)
	if binding_err.code != .None do return respond_error(binding_err, req.request_id)
	if !found do return respond_error(bots.bots_detail_error(.Conflict, "channel_not_paired"), req.request_id)
	ids, held, sent_as, unsent, err := bots.channel_send_media(h.bots, binding, text, {artifact_id, name, mime, i64(size), bytes})
	defer {for id in ids do delete(id); delete(ids)}
	if err.code != .None do return respond_error(err, req.request_id)
	if e := bots.bots_channel_replied(h.bots, bot.bot_id, binding.binding_id); e.code != .None do return respond_error(e, req.request_id)
	if unsent == 0 {
		return respond_success_typed(struct {message_ids: []string, chunks: int, channel: string, held: bool, sent_as: string}{
			ids, len(ids), binding.provider, held, sent_as}, req.request_id, auth_ctx_server_time(req))
	}
	return respond_success_typed(struct {
		message_ids: []string, chunks: int, channel: string, held: bool,
		sent_as: string, unsent_chunks: int,
	}{ids, len(ids), binding.provider, held, sent_as, unsent}, req.request_id, auth_ctx_server_time(req))
}
