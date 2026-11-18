package http

import "core:encoding/json"
import "core:unicode/utf8"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import bots "odin_test:hub/service/bots"

Bot_Channel_Read_Message :: struct {message_id, body, created_at, sender, channel: string}
Bot_Channel_History_Message :: struct {message_id, direction, body, created_at, channel: string}

Bot_Agent_Handlers :: struct {
	agent_actions: ^Agent_Action_Handlers,
	bots: ^bots.Bots_Service,
	experiments: ^iface.Experiment_Repository,
}

bot_channel_require :: proc(h: ^Bot_Agent_Handlers, req: Request) -> (domain.Bot, bool, Response) {
	auth, inst, ok, refusal := require_instance_action_auth(h.agent_actions, req)
	if !ok do return {}, false, refusal
	defer domain.agent_instance_destroy(&inst)
	if enabled, resp := require_experiment_enabled(h.experiments, auth.user_id, "bots", req.request_id); !enabled do return {}, false, resp
	bot, found, err := iface.bot_get_by_instance(h.bots.repo, inst.agent_instance_id)
	if err.code != .None {domain.bot_destroy(&bot); return {}, false, respond_error(err, req.request_id)}
	if !found || bot.owner_user_id != auth.user_id {
		domain.bot_destroy(&bot)
		return {}, false, respond_error(bots.bots_detail_error(.Forbidden, "not_a_bot"), req.request_id)
	}
	bindings, binding_err := iface.bindings_active_for_owner(h.bots.repo, bot.owner_user_id)
	defer {for &b in bindings do domain.channel_binding_destroy(&b); delete(bindings)}
	if binding_err.code != .None || len(bindings) == 0 {
		domain.bot_destroy(&bot)
		if binding_err.code == .None do binding_err = bots.bots_detail_error(.Conflict, "channel_not_paired")
		return {}, false, respond_error(binding_err, req.request_id)
	}
	return bot, true, {}
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
	bot, ok, refusal := bot_channel_require(h, req)
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
	wire := make([dynamic]Bot_Channel_Read_Message, context.temp_allocator)
	for m in messages do append(&wire, Bot_Channel_Read_Message{m.message_id, m.body, m.created_at, binding.external_display, binding.provider})
	return respond_success_typed(struct {messages: []Bot_Channel_Read_Message, pending_total: int}{wire[:], total}, req.request_id, auth_ctx_server_time(req))
}

bot_agent_channel_send_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bot_Agent_Handlers)(ctx)
	bot, ok, refusal := bot_channel_require(h, req)
	if !ok do return refusal
	defer domain.bot_destroy(&bot)
	params := json_object_raw(req.body, "params", context.temp_allocator)
	value, parse_err := json.parse(params, allocator = context.temp_allocator)
	obj, object_ok := value.(json.Object)
	text, string_ok := obj["text"].(string)
	if parse_err != nil || !object_ok || !string_ok || !utf8.valid_string(params) do return respond_error(bots.bots_detail_error(.Validation_Failed, "text_invalid"), req.request_id)
	if len(text) < 1 || len(text) > 16384 || !utf8.valid_string(text) do return respond_error(bots.bots_detail_error(.Validation_Failed, "text_invalid"), req.request_id)
	binding, found, binding_err := bots.bots_reply_binding(h.bots, bot.owner_user_id, bot.bot_id)
	defer domain.channel_binding_destroy(&binding)
	if binding_err.code != .None do return respond_error(binding_err, req.request_id)
	if !found do return respond_error(bots.bots_detail_error(.Conflict, "channel_not_paired"), req.request_id)
	ids, held, err := bots.channel_send(h.bots, binding, text, true)
	defer {for id in ids do delete(id); delete(ids)}
	if err.code != .None do return respond_error(err, req.request_id)
	if e := bots.bots_channel_replied(h.bots, bot.bot_id, binding.binding_id); e.code != .None do return respond_error(e, req.request_id)
	return respond_success_typed(struct {message_ids: []string, chunks: int, channel: string, held: bool}{ids, len(ids), binding.provider, held}, req.request_id, auth_ctx_server_time(req))
}

bot_agent_channel_history_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bot_Agent_Handlers)(ctx)
	bot, ok, refusal := bot_channel_require(h, req)
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
	wire := make([dynamic]Bot_Channel_History_Message, context.temp_allocator)
	for m in messages {
		if m.body_purged do continue
		provider := ""
		for b in active do if b.binding_id == m.binding_id {provider = b.provider; break}
		if provider == "" do continue
		if len(wire) == limit do break
		append(&wire, Bot_Channel_History_Message{m.message_id, domain.channel_direction_text(m.direction), m.body, m.created_at, provider})
	}
	return respond_success_typed(struct {messages: []Bot_Channel_History_Message}{wire[:]}, req.request_id, auth_ctx_server_time(req))
}
