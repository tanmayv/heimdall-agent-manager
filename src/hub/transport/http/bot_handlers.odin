package http

import "core:encoding/json"
import "core:strings"
import "core:strconv"
import "core:sync"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import auth_service "odin_test:hub/service/auth"
import bots "odin_test:hub/service/bots"
import provider_service "odin_test:hub/service/provider"
import placement "odin_test:hub/service/placement"

Bot_Handlers :: struct {
	auth: ^auth_service.Auth_Service,
	bots: ^bots.Bots_Service,
	experiments: ^iface.Experiment_Repository,
	content: ^iface.Content_Repository,
	cards: ^iface.Card_Repository,
}

bot_require_auth :: proc(h: ^Bot_Handlers, req: Request) -> (contracts.Auth_Context, bool, Response) {
	auth, ok, resp := require_auth(h.auth, req)
	if !ok do return auth, false, resp
	if enabled, refusal := require_experiment_enabled(h.experiments, auth.user_id, "bots", req.request_id); !enabled do return auth, false, refusal
	return auth, true, {}
}

bot_me_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bot_Handlers)(ctx)
	auth, ok, refusal := bot_require_auth(h, req)
	if !ok do return refusal
	if req.method == "POST" {
		if err := bots.bots_create(h.bots, auth); err.code != .None do return respond_error(err, req.request_id)
	}
	if req.method == "DELETE" {
		if err := bots.bots_delete(h.bots, auth); err.code != .None do return respond_error(err, req.request_id)
		return respond_success(`{"deleted":true}`, req.request_id, auth_ctx_server_time(req))
	}
	body, err := bots.bots_view_json(h.bots, auth.user_id)
	defer delete(body)
	if err.code != .None do return respond_error(err, req.request_id)
	return respond_success(body, req.request_id, auth_ctx_server_time(req), 201 if req.method == "POST" else 200)
}

Bot_Placement_Row :: struct {bridge_id, provider, model, tier: string}
Bot_Placement_View :: struct {
	placement_revision: int,
	candidates: []Bot_Placement_Row,
}
bot_placement_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bot_Handlers)(ctx)
	auth, ok, refusal := bot_require_auth(h, req)
	if !ok do return refusal
	bot, err := bots.bots_get(h.bots, auth.user_id)
	if err.code != .None do return respond_error(err, req.request_id)
	defer domain.bot_destroy(&bot)
	if req.method == "PUT" {
		input: struct {expected_revision: int, candidates: []Bot_Placement_Row}
		value, parse_err := json.parse(req.body, parse_integers = true, allocator = context.temp_allocator)
		obj, object_ok := value.(json.Object)
		_, revision_ok := obj["expected_revision"].(json.Integer)
		_, candidates_ok := obj["candidates"].(json.Array)
		if parse_err != nil || !object_ok || !revision_ok || !candidates_ok do return respond_error(domain.domain_error(.Validation_Failed, "expected_revision and candidates are required"), req.request_id)
		if json.unmarshal(transmute([]u8)req.body, &input, allocator = context.temp_allocator) != nil do return respond_error(domain.domain_error(.Validation_Failed, "invalid placement"), req.request_id)
		rows := make([]domain.Bot_Placement_Candidate, len(input.candidates), context.temp_allocator)
		for row, i in input.candidates {
			tier, tier_ok := domain.bot_placement_tier_from_text(row.tier)
			if !tier_ok do return respond_error(domain.domain_error(.Validation_Failed, "tier must be preferred or allowed"), req.request_id)
			rows[i] = {position = i, bridge_id = row.bridge_id, provider = row.provider, model = row.model, tier = tier}
		}
		_, put_err := bots.bots_put_placement(h.bots, auth.user_id, input.expected_revision, rows)
		if put_err.code != .None do return respond_error(put_err, req.request_id)
	}
	// Read revision and rows together under the same service lock as PUT.
	// The repository's replacement is atomic; this lock keeps the view consistent.
	return bot_placement_response(h, auth.user_id, req)
}

bot_placement_response :: proc(h: ^Bot_Handlers, owner: string, req: Request) -> Response {
	sync.mutex_lock(&h.bots.mutex); defer sync.mutex_unlock(&h.bots.mutex)
	bot, err := bots.bots_get(h.bots, owner)
	if err.code != .None do return respond_error(err, req.request_id)
	defer domain.bot_destroy(&bot)
	rows, list_err := iface.placement_list(h.bots.repo, bot.bot_id)
	defer {for &row in rows do domain.bot_placement_candidate_destroy(&row); delete(rows)}
	if list_err.code != .None do return respond_error(list_err, req.request_id)
	wire := make([]Bot_Placement_Row, len(rows), context.temp_allocator)
	for row, i in rows do wire[i] = {bridge_id = row.bridge_id, provider = row.provider, model = row.model, tier = domain.bot_placement_tier_text(row.tier)}
	return respond_success_typed(Bot_Placement_View{placement_revision = bot.placement_revision, candidates = wire}, req.request_id, auth_ctx_server_time(req))
}

Bot_Provider_Option :: struct {provider, label: string, models: []string}
Bot_Bridge_Option :: struct {
	bridge_id, label: string,
	online, bot_capable: bool,
	providers: []Bot_Provider_Option,
}
bot_placement_options_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bot_Handlers)(ctx)
	auth, ok, refusal := bot_require_auth(h, req)
	if !ok do return refusal
	bot, err := bots.bots_get(h.bots, auth.user_id)
	if err.code != .None do return respond_error(err, req.request_id)
	defer domain.bot_destroy(&bot)
	bridges, list_err := iface.bridge_list_by_owner(h.bots.bridges, domain.User_ID(auth.user_id))
	defer {for &b in bridges do domain.bridge_destroy(&b); delete(bridges)}
	if list_err.code != .None do return respond_error(list_err, req.request_id)
	options := make([dynamic]Bot_Bridge_Option, context.temp_allocator)
	for b in bridges {
		if string(b.owner_user_id) != auth.user_id do continue
		views, view_err := provider_service.list_bridge_providers(h.bots.providers, b.bridge_id)
		defer provider_service.bridge_provider_views_destroy(views)
		if view_err.code != .None do return respond_error(view_err, req.request_id)
		providers := make([dynamic]Bot_Provider_Option, context.temp_allocator)
		for view in views {
			models := make([dynamic]string, context.temp_allocator)
			for model in view.catalog.models do if model.state == "active" do append(&models, strings.clone(model.model_id, context.temp_allocator))
			duplicate := false
			for provider in providers do if provider.provider == view.catalog.provider do duplicate = true
			if duplicate do continue
			append(&providers, Bot_Provider_Option{provider = strings.clone(view.catalog.provider, context.temp_allocator), label = strings.clone(view.catalog.display_name, context.temp_allocator), models = models[:]})
		}
		ps:=bots.bots_placement(h.bots)
 online,_:=placement.bridge_eligible(&ps,b,{owner=auth.user_id})
 capable,_:=placement.bridge_eligible(&ps,b,{owner=auth.user_id,features={"bot_deliver_v1","instance_reconfiguration_v1"}})
 append(&options,Bot_Bridge_Option{bridge_id=b.bridge_id,label=b.label,online=online,bot_capable=capable,providers=providers[:]})
	}
	return respond_success_typed(struct {bridges: []Bot_Bridge_Option}{options[:]}, req.request_id, auth_ctx_server_time(req))
}

bot_deliveries_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bot_Handlers)(ctx)
	auth, ok, refusal := bot_require_auth(h, req)
	if !ok do return refusal
	bot, err := bots.bots_get(h.bots, auth.user_id)
	if err.code != .None do return respond_error(err, req.request_id)
	defer domain.bot_destroy(&bot)
	limit := 20
	if raw := query_value(req.query, "limit"); has_query_key(req.query, "limit") {
		parsed, valid := strconv.parse_int(raw)
		if !valid || parsed < 1 || parsed > 100 do return respond_error(domain.domain_error(.Validation_Failed, "limit must be 1..100"), req.request_id)
		limit = parsed
	}
	deliveries, list_err := iface.delivery_list_recent(h.bots.repo, bot.bot_id, limit)
	defer {for &d in deliveries do domain.bot_delivery_destroy(&d); delete(deliveries)}
	if list_err.code != .None do return respond_error(list_err, req.request_id)
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `{"deliveries":[`)
	for d, i in deliveries {
		if i > 0 do strings.write_byte(&b, ',')
		wire := struct {delivery_id, state: string, round: int, waiting_reason, finish_reason, created_at, finished_at: string}{d.delivery_id, domain.bot_delivery_state_text(d.state), d.round, d.waiting_reason, d.finish_reason, d.created_at, d.finished_at}
		encoded, _ := json.marshal(wire, allocator = context.temp_allocator)
		strings.write_string(&b, string(encoded[:len(encoded)-1]))
		strings.write_string(&b, `,"attempts":[`)
		attempts, attempt_err := iface.attempt_list_for_delivery(h.bots.repo, d.delivery_id)
		defer {for &a in attempts do domain.bot_delivery_attempt_destroy(&a); delete(attempts)}
		if attempt_err.code != .None do return respond_error(attempt_err, req.request_id)
		for a, j in attempts {
			if j > 0 do strings.write_byte(&b, ',')
			awire := struct {attempt_id, bridge_id, state: string}{a.attempt_id, a.bridge_id, domain.bot_attempt_state_text(a.state)}
			adata, _ := json.marshal(awire, allocator = context.temp_allocator)
			strings.write_string(&b, string(adata[:len(adata)-1]))
			strings.write_string(&b, `,"report":`)
			strings.write_string(&b, a.report_json if a.report_json != "" else "{}")
			strings.write_byte(&b, '}')
		}
		strings.write_string(&b, "]}")
	}
	strings.write_string(&b, "]}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

bot_pairing_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bot_Handlers)(ctx)
	auth, ok, refusal := bot_require_auth(h, req)
	if !ok do return refusal
	link, err := bots.bots_pairing_create(h.bots, auth.user_id, "telegram")
	defer {delete(link.pairing_url); delete(link.expires_at)}
	if err.code != .None do return respond_error(err, req.request_id)
	return respond_success_typed(struct {pairing_url, expires_at: string}{link.pairing_url, link.expires_at}, req.request_id, auth_ctx_server_time(req), 201)
}

bot_disconnect_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bot_Handlers)(ctx)
	auth, ok, refusal := bot_require_auth(h, req)
	if !ok do return refusal
	bot, err := bots.bots_get(h.bots, auth.user_id)
	defer domain.bot_destroy(&bot)
	if err.code != .None do return respond_error(err, req.request_id)
	if e := bots.bots_disconnect(h.bots, auth.user_id, "telegram", true); e.code != .None do return respond_error(e, req.request_id)
	return respond_success("{\"disconnected\":true}", req.request_id, auth_ctx_server_time(req))
}

bot_messages_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bot_Handlers)(ctx)
	auth, ok, refusal := bot_require_auth(h, req)
	if !ok do return refusal
	if fence := bots.bots_legacy_guard(h.bots, auth.user_id); fence.code != .None do return respond_error(fence, req.request_id)
	bot, err := bots.bots_get(h.bots, auth.user_id)
	defer domain.bot_destroy(&bot)
	if err.code != .None do return respond_error(err, req.request_id)
	limit := 50
	if raw := query_value(req.query, "limit"); has_query_key(req.query, "limit") {
		n, valid := strconv.parse_int(raw)
		if !valid || n < 1 || n > 200 do return respond_error(domain.domain_error(.Validation_Failed, "limit must be 1..200"), req.request_id)
		limit = n
	}
	messages, list_err := iface.messages_history(h.bots.repo, bot.bot_id, limit)
	defer {for &m in messages do domain.channel_message_destroy(&m); delete(messages)}
	if list_err.code != .None do return respond_error(list_err, req.request_id)
	wire := make([]struct {
		message_id, direction, body: string,
		body_purged: bool,
		send_state, created_at, read_at, replied_at: string,
	}, len(messages), context.temp_allocator)
	for m, i in messages do wire[i] = {m.message_id, domain.channel_direction_text(m.direction), m.body, m.body_purged, domain.channel_send_state_text(m.send_state), m.created_at, m.read_at, m.replied_at}
	return respond_success_typed(struct {messages: type_of(wire)}{wire}, req.request_id, auth_ctx_server_time(req))
}

bot_whatsapp_pairing_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bot_Handlers)(ctx)
	auth, ok, refusal := bot_require_auth(h, req)
	if !ok do return refusal
	link, err := bots.bots_pairing_create(h.bots, auth.user_id, "whatsapp")
	defer {delete(link.pairing_url); delete(link.pairing_text); delete(link.expires_at)}
	if err.code != .None do return respond_error(err, req.request_id)
	a := bots.bots_adapter(h.bots, "whatsapp")
	identity, identity_err := a.identity(a.ctx)
	if identity_err.kind != .None do return respond_error(domain.domain_error(.Provider_Unavailable, "channel identity unavailable"), req.request_id)
	phone := strings.concatenate({"+", identity.bot_username}, context.temp_allocator)
	return respond_success_typed(struct {pairing_url, pairing_text, phone_display, expires_at: string}{link.pairing_url, link.pairing_text, phone, link.expires_at}, req.request_id, auth_ctx_server_time(req), 201)
}

bot_whatsapp_disconnect_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bot_Handlers)(ctx)
	auth, ok, refusal := bot_require_auth(h, req)
	if !ok do return refusal
	bot, err := bots.bots_get(h.bots, auth.user_id)
	defer domain.bot_destroy(&bot)
	if err.code != .None do return respond_error(err, req.request_id)
	if e := bots.bots_disconnect(h.bots, auth.user_id, "whatsapp", true); e.code != .None do return respond_error(e, req.request_id)
	return respond_success("{\"disconnected\":true}", req.request_id, auth_ctx_server_time(req))
}
