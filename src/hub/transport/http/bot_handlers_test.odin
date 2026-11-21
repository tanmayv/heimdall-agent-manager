package http

import "core:fmt"
import "core:encoding/json"
import platform "odin_test:hub/platform"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import bots "odin_test:hub/service/bots"
import provider_service "odin_test:hub/service/provider"
import content_service "odin_test:hub/service/content"
import project_service "odin_test:hub/service/project"
import channel "odin_test:hub/service/channel"

Bot_HTTP_Fixture :: struct {
	wire: ^wire_fixture,
	bot_impl: sqlite.Bot_Repo_SQLite,
	experiment_impl: sqlite.Experiment_Repo_SQLite,
	provider_impl: sqlite.Provider_Repo_SQLite,
	content_impl: sqlite.Content_Repo_SQLite,
	bot_repo: iface.Bot_Repository,
	uow_impl: sqlite.SQLite_Unit_Of_Work_Factory,
	uow: iface.Unit_Of_Work_Factory,
	experiments: iface.Experiment_Repository,
	provider_repo: iface.Provider_Repository,
	content_repo: iface.Content_Repository,
	providers: provider_service.Provider_Service,
	service: bots.Bots_Service,
	handlers: Bot_Handlers,
	registry: project_service.Bridge_Runtime_Registry,
	stop_commands, disconnect_notices: int,
}
bot_http_stop_command :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	f := (^Bot_HTTP_Fixture)(ctx)
	if strings.contains(command.body_json, "bot_deleted") do f.stop_commands += 1
	return true, {}
}
bot_http_disconnect_notice :: proc(ctx: rawptr, chat, text: string) -> (string, channel.Channel_Error) {
	f := (^Bot_HTTP_Fixture)(ctx)
	if chat == "100" && text == "Disconnected from Ninjy. Your messages here are no longer delivered to your bot." do f.disconnect_notices += 1
	return strings.clone("notice"), {}
}
bot_http_fixture :: proc(t: ^testing.T, enabled := true) -> ^Bot_HTTP_Fixture {
	f := new(Bot_HTTP_Fixture)
	f.wire = wire_setup(t, "bots")
	f.bot_repo = sqlite.new_bot_repository(&f.bot_impl, &f.wire.conn)
	f.uow = sqlite.new_unit_of_work_factory(&f.uow_impl, &f.wire.conn, nil)
	f.experiments = sqlite.new_experiment_repository(&f.experiment_impl, &f.wire.conn)
	f.provider_repo = sqlite.new_provider_repository(&f.provider_impl, &f.wire.conn)
	f.content_repo = sqlite.new_content_repository(&f.content_impl, &f.wire.conn)
	f.providers.repo = &f.provider_repo
	f.service = {repo = &f.bot_repo, uow_factory = &f.uow, experiments = &f.experiments, agents = &f.wire.ag_svc, bridges = &f.wire.br_repo, providers = &f.providers, clock = &f.wire.clock, ids = &f.wire.ids, timers = bots.default_bot_timer_config()}
	f.handlers = {auth = &f.wire.auth_svc, bots = &f.service, experiments = &f.experiments, content = &f.content_repo}
	_, err := iface.experiment_set(&f.experiments, {owner_user_id = string(f.wire.owner), key = "bots", enabled = enabled, updated_at = "now"})
	testing.expect_value(t, err.code, domain.Error_Code.None)
	return f
}
bot_http_destroy :: proc(f: ^Bot_HTTP_Fixture) {project_service.bridge_runtime_registry_destroy(&f.registry); wire_teardown(f.wire); free(f)}
bot_http_request :: proc(f: ^Bot_HTTP_Fixture, method, path, body: string) -> Request {return wire_cookie_request(f.wire, method, path, body)}
bot_http_create :: proc(t: ^testing.T, f: ^Bot_HTTP_Fixture) -> domain.Bot {
	response := bot_me_handler(&f.handlers, bot_http_request(f, "POST", "/api/v1/bots/me", "{}"))
	testing.expectf(t, response.status == 201, "create: %d %s", response.status, response.body)
	bot, found, err := iface.bot_get_by_owner(&f.bot_repo, string(f.wire.owner))
	testing.expect(t, found); testing.expect_value(t, err.code, domain.Error_Code.None)
	return bot
}

@(test)
test_bots_routes_refuse_when_experiment_off :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := bot_http_fixture(t, false); defer bot_http_destroy(f)
	for tc in ([]struct {method, path: string, handler: Handler_Proc}{
		{"GET", "/api/v1/bots/me", bot_me_handler}, {"POST", "/api/v1/bots/me", bot_me_handler}, {"DELETE", "/api/v1/bots/me", bot_me_handler},
		{"GET", "/api/v1/bots/me/placement", bot_placement_handler}, {"PUT", "/api/v1/bots/me/placement", bot_placement_handler},
		{"POST", "/api/v1/bots/me/channels/telegram/pairing", bot_pairing_handler}, {"DELETE", "/api/v1/bots/me/channels/telegram", bot_disconnect_handler}, {"GET", "/api/v1/bots/me/channels/telegram/messages", bot_messages_handler},
		{"GET", "/api/v1/bots/me/placement/options", bot_placement_options_handler}, {"GET", "/api/v1/bots/me/deliveries", bot_deliveries_handler},
	}) {
		resp := tc.handler(&f.handlers, bot_http_request(f, tc.method, tc.path, "{}"))
		testing.expect_value(t, resp.status, 403)
		testing.expect(t, strings.contains(resp.body, "experimental_feature_disabled"))
	}
	_, found, _ := iface.bot_get_by_owner(&f.bot_repo, string(f.wire.owner))
	testing.expect(t, !found)
	unauth := bot_me_handler(&f.handlers, {method = "GET", path = "/api/v1/bots/me"})
	testing.expect_value(t, unauth.status, 401)
}

@(test)
test_create_bot_once :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := bot_http_fixture(t); defer bot_http_destroy(f)
	missing := bot_me_handler(&f.handlers, bot_http_request(f, "GET", "/api/v1/bots/me", ""))
	testing.expect_value(t, missing.status, 404)
	testing.expect(t, strings.contains(missing.body, "bot_not_found"))
	bot := bot_http_create(t, f)
	testing.expect_value(t, bot.agent_instance_id, "")
	testing.expect_value(t, bot.placement_revision, 1)
	agent, found, err := iface.agent_get(&f.wire.ag_repo, bot.agent_id)
	testing.expect(t, found); testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, agent.template_id, domain.TEMPLATE_BOT_ID)
	testing.expect_value(t, agent.name, "Ninjy bot")
	testing.expect_value(t, agent.permission_mode, "yolo")
	second := bot_me_handler(&f.handlers, bot_http_request(f, "POST", "/api/v1/bots/me", "{}"))
	testing.expect_value(t, second.status, 409)
	testing.expect(t, strings.contains(second.body, "bot_exists"))
	view := bot_me_handler(&f.handlers, bot_http_request(f, "GET", "/api/v1/bots/me", ""))
	testing.expect_value(t, view.status, 200)
	testing.expect(t, strings.contains(view.body, `"status":"new"`))
	testing.expect(t, strings.contains(view.body, `"configured":false`))
	testing.expect(t, strings.contains(view.body, `"binding":null`))
	testing.expect(t, strings.contains(view.body, `"agent_instance_id":""`))
	content := content_service.Content_Service{content = &f.content_repo}
	templates, template_err := content_service.list_templates(&content, {kind = .Internal_User, user_id = string(f.wire.owner)})
	testing.expect_value(t, template_err.code, domain.Error_Code.None)
	for template in templates do testing.expect(t, template.template_id != domain.TEMPLATE_BOT_ID)
	builtin, builtin_ok := domain.builtin_template(domain.TEMPLATE_BOT_ID)
	testing.expect(t, builtin_ok); testing.expect(t, builtin.instructions != "" && strings.has_prefix(builtin.instructions, "# Role: Ninjy bot"))
}

@(test)
test_put_placement_revision_conflict :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := bot_http_fixture(t); defer bot_http_destroy(f)
	bot := bot_http_create(t, f)
	d := domain.Bot_Delivery{delivery_id = "bdl_placement", bot_id = bot.bot_id, owner_user_id = bot.owner_user_id, through_message_id = "m", state = .Waiting, round = 1, waiting_reason = "no_bridge", created_at = "now", updated_at = "now"}
	testing.expect_value(t, iface.delivery_insert(&f.bot_repo, d).code, domain.Error_Code.None)
	body := `{"expected_revision":1,"candidates":[{"bridge_id":"*","provider":"*","model":"*","tier":"preferred"}]}`
	resp := bot_placement_handler(&f.handlers, bot_http_request(f, "PUT", "/api/v1/bots/me/placement", body))
	testing.expectf(t, resp.status == 200, "put: %d %s", resp.status, resp.body)
	testing.expect(t, strings.contains(resp.body, `"placement_revision":2`))
	conflict := bot_placement_handler(&f.handlers, bot_http_request(f, "PUT", "/api/v1/bots/me/placement", body))
	testing.expect_value(t, conflict.status, 409)
	testing.expect(t, strings.contains(conflict.body, "placement_revision_changed"))
	rows, _ := iface.placement_list(&f.bot_repo, bot.bot_id)
	testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 {testing.expect_value(t, rows[0].position, 0); testing.expect_value(t, rows[0].tier, domain.Bot_Placement_Tier.Preferred)}
	updated, open, _ := iface.delivery_get_open(&f.bot_repo, bot.bot_id)
	testing.expect(t, open); testing.expect_value(t, updated.state, domain.Bot_Delivery_State.Pending)
	testing.expect_value(t, updated.waiting_reason, "")
	history_req := bot_http_request(f, "GET", "/api/v1/bots/me/deliveries", "")
	history := bot_deliveries_handler(&f.handlers, history_req)
	testing.expect_value(t, history.status, 200)
	testing.expect(t, strings.contains(history.body, "bdl_placement"))
	for query in ([]string{"limit=", "limit=0", "limit=101", "limit=1.5", "limit=x"}) {
		history_req.query = query
		testing.expect_value(t, bot_deliveries_handler(&f.handlers, history_req).status, 400)
	}
	for bad in ([]string{`{}`, `{"expected_revision":"2","candidates":[]}`, `{"expected_revision":2,"candidates":null}`, `{"expected_revision":2,"candidates":[{"bridge_id":"*","provider":"*","model":"*","tier":"bad"}]}`}) do testing.expect_value(t, bot_placement_handler(&f.handlers, bot_http_request(f, "PUT", "/api/v1/bots/me/placement", bad)).status, 400)
	options := bot_placement_options_handler(&f.handlers, bot_http_request(f, "GET", "/api/v1/bots/me/placement/options", ""))
	testing.expect_value(t, options.status, 200)
	testing.expect(t, strings.contains(options.body, f.wire.bridge_pin))
	testing.expect(t, !strings.contains(options.body, f.wire.bridge_foreign))
	get := bot_placement_handler(&f.handlers, bot_http_request(f, "GET", "/api/v1/bots/me/placement", ""))
	testing.expect_value(t, get.status, 200)
	testing.expect(t, strings.contains(get.body, `"placement_revision":2`))
}

@(test)
test_delete_bot_cleans_up :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := bot_http_fixture(t); defer bot_http_destroy(f)
	bot := bot_http_create(t, f)
	// Bindings and messages are seeded directly so this test precedes A5 pairing.
	_, conversation_ok, conversation_err := iface.content_save_conversation(&f.content_repo, {conversation_id = "chat_bot_delete", owner_user_id = f.wire.owner, agent_id = bot.agent_id, agent_instance_id = "inst_bot_delete", created_at = "now", updated_at = "now"})
	testing.expect(t, conversation_ok); testing.expect_value(t, conversation_err.code, domain.Error_Code.None)
	_, instance_ok, instance_err := iface.agent_save_instance(&f.wire.ag_repo, {agent_instance_id = "inst_bot_delete", owner_user_id = f.wire.owner, agent_id = bot.agent_id, bridge_id = f.wire.bridge_pin, conversation_id = "chat_bot_delete", runtime_status = "running", created_at = "now", updated_at = "now"})
	testing.expect(t, instance_ok); testing.expect_value(t, instance_err.code, domain.Error_Code.None)
	testing.expect_value(t, iface.bot_set_instance(&f.bot_repo, bot.bot_id, "inst_bot_delete", "now").code, domain.Error_Code.None)
	f.wire.ag_svc.bridge_runtime_registry = &f.registry
	f.wire.ag_svc.bridge_command_sink = {ctx = f, send_runtime_command = bot_http_stop_command}
	testing.expect(t, project_service.bridge_runtime_registry_mark_live(&f.registry, f.wire.bridge_pin, false, ""))
	adapter := channel.Channel_Adapter{ctx = f, send_text = bot_http_disconnect_notice}
	f.service.adapter = &adapter
	testing.expect(t, sqlite.exec(&f.wire.conn, fmt.tprintf(`INSERT INTO channel_bindings(binding_id,owner_user_id,bot_id,provider,external_chat_id,external_user_id,state,created_at) VALUES('chb_delete','%s','%s','telegram','100','200','active','now');`, bot.owner_user_id, bot.bot_id)))
	testing.expect_value(t, iface.message_insert_outbound(&f.bot_repo, {message_id = "chm_delete", binding_id = "chb_delete", owner_user_id = bot.owner_user_id, bot_id = bot.bot_id, direction = .Outbound, body = "private", send_state = .Sent, created_at = "now"}).code, domain.Error_Code.None)
	testing.expect_value(t, iface.message_insert_outbound(&f.bot_repo, {message_id = "chm_revoked", binding_id = "chb_old", owner_user_id = bot.owner_user_id, bot_id = bot.bot_id, direction = .Outbound, body = "older", send_state = .Sent, created_at = "before"}).code, domain.Error_Code.None)
	testing.expect_value(t, iface.delivery_insert(&f.bot_repo, {delivery_id = "bdl_delete", bot_id = bot.bot_id, owner_user_id = bot.owner_user_id, through_message_id = "chm_delete", state = .Dispatched, round = 1, created_at = "now", updated_at = "now"}).code, domain.Error_Code.None)
	testing.expect_value(t, iface.attempt_insert(&f.bot_repo, {attempt_id = "bda_delete", delivery_id = "bdl_delete", bridge_id = f.wire.bridge_pin, round = 1, state = .Accepted, candidates_json = "[]", report_json = "{}", created_at = "now"}).code, domain.Error_Code.None)
	testing.expect_value(t, iface.pairing_insert(&f.bot_repo, {code_hash = "code", bot_id = bot.bot_id, owner_user_id = bot.owner_user_id, provider = "telegram", created_at = "now", expires_at = "later"}).code, domain.Error_Code.None)
	_, _ = iface.placement_replace(&f.bot_repo, bot.bot_id, 1, {{bridge_id = "*", provider = "*", model = "*"}}, "now")
	resp := bot_me_handler(&f.handlers, bot_http_request(f, "DELETE", "/api/v1/bots/me", ""))
	testing.expect_value(t, resp.status, 200)
	testing.expect(t, strings.contains(resp.body, `"deleted":true`))
	_, exists, _ := iface.bot_get_by_owner(&f.bot_repo, bot.owner_user_id)
	testing.expect(t, !exists)
	agent, found, _ := iface.agent_get(&f.wire.ag_repo, bot.agent_id)
	testing.expect(t, found); testing.expect_value(t, agent.state, domain.Agent_State.Archived)
	testing.expect_value(t, f.stop_commands, 1)
	testing.expect_value(t, f.disconnect_notices, 1)
	inst, kept, _ := iface.agent_get_instance(&f.wire.ag_repo, "inst_bot_delete")
	testing.expect(t, kept); testing.expect_value(t, inst.conversation_id, "chat_bot_delete")
	_, chat_kept, _ := iface.content_get_conversation(&f.content_repo, "chat_bot_delete")
	testing.expect(t, chat_kept)
	_, bound, _ := iface.binding_get_active_by_owner(&f.bot_repo, bot.owner_user_id, "telegram")
	testing.expect(t, !bound)
	messages, _ := iface.messages_history(&f.bot_repo, bot.bot_id, -1)
	testing.expect_value(t, len(messages), 2)
	for m in messages {testing.expect(t, m.body_purged); testing.expect_value(t, m.body, "")}
	delivery, _, _ := iface.delivery_get(&f.bot_repo, "bdl_delete")
	testing.expect_value(t, delivery.state, domain.Bot_Delivery_State.Abandoned)
	testing.expect_value(t, delivery.finish_reason, "bot_deleted")
	attempt, _, _ := iface.attempt_get(&f.bot_repo, "bda_delete")
	testing.expect_value(t, attempt.state, domain.Bot_Attempt_State.Cancelled)
	rows, _ := iface.placement_list(&f.bot_repo, bot.bot_id)
	testing.expect_value(t, len(rows), 0)
	_, pairing, _ := iface.pairing_get(&f.bot_repo, "code")
	testing.expect(t, !pairing)
	testing.expect_value(t, bot_me_handler(&f.handlers, bot_http_request(f, "DELETE", "/api/v1/bots/me", "")).status, 404)
	recreated := bot_http_create(t, f)
	testing.expect(t, recreated.agent_id != bot.agent_id)
	testing.expect(t, recreated.bot_id != bot.bot_id)
}

bot_http_fail_insert :: proc(ctx: rawptr, bot: domain.Bot) -> domain.Domain_Error {return domain.domain_error(.Internal_Error, "injected bot insert failure")}
@(test)
test_create_bot_insert_failure_archives_agent :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := bot_http_fixture(t); defer bot_http_destroy(f)
	f.bot_repo.bot_insert = bot_http_fail_insert
	response := bot_me_handler(&f.handlers, bot_http_request(f, "POST", "/api/v1/bots/me", "{}"))
	testing.expect_value(t, response.status, 500)
	_, exists, _ := iface.bot_get_by_owner(&f.bot_repo, string(f.wire.owner))
	testing.expect(t, !exists)
	agents, err := iface.agent_list_by_owner(&f.wire.ag_repo, f.wire.owner, 50, "")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	bots_found := 0
	for a in agents {
		if a.template_id != domain.TEMPLATE_BOT_ID do continue
		bots_found += 1
		testing.expect_value(t, a.state, domain.Agent_State.Archived)
	}
	testing.expect_value(t, bots_found, 1)
}

@(test)
test_bot_view_status_and_delivery_history :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := bot_http_fixture(t); defer bot_http_destroy(f)
	bot := bot_http_create(t, f)
	inst := domain.Agent_Instance{agent_instance_id = "inst_bot_view", owner_user_id = f.wire.owner, agent_id = bot.agent_id, bridge_id = f.wire.bridge_pin, provider = "claude", model = "opus", created_at = "2026-11-17T00:00:00Z", updated_at = "2026-11-17T00:00:00Z"}
	testing.expect_value(t, iface.bot_set_instance(&f.bot_repo, bot.bot_id, inst.agent_instance_id, "now").code, domain.Error_Code.None)
	for tc in ([]struct {runtime_status, status: string}{{"starting", "starting"}, {"launching", "starting"}, {"running", "ready"}, {"idle", "ready"}, {"busy", "ready"}, {"stopped", "sleeping"}, {"failed", "sleeping"}}) {
		inst.runtime_status = tc.runtime_status
		_, saved, err := iface.agent_save_instance(&f.wire.ag_repo, inst)
		testing.expect(t, saved); testing.expect_value(t, err.code, domain.Error_Code.None)
		view := bot_me_handler(&f.handlers, bot_http_request(f, "GET", "/api/v1/bots/me", ""))
		testing.expect_value(t, view.status, 200)
		testing.expect(t, strings.contains(view.body, fmt.tprintf(`"status":"%s"`, tc.status)))
		testing.expect(t, strings.contains(view.body, `"provider":"claude"`))
	}
	d := domain.Bot_Delivery{delivery_id = "bdl_view", bot_id = bot.bot_id, owner_user_id = bot.owner_user_id, through_message_id = "chm_view", state = .Waiting, round = 1, waiting_reason = "busy", created_at = "2026-11-17T01:00:00Z", updated_at = "2026-11-17T01:00:00Z"}
	testing.expect_value(t, iface.delivery_insert(&f.bot_repo, d).code, domain.Error_Code.None)
	waiting := bot_me_handler(&f.handlers, bot_http_request(f, "GET", "/api/v1/bots/me", ""))
	testing.expect(t, strings.contains(waiting.body, `"status":"waiting_for_machine"`))
	testing.expect(t, strings.contains(waiting.body, `"status_detail":"busy"`))
	d.state = .Dispatched
	_, _ = iface.delivery_update(&f.bot_repo, d, .Waiting)
	working := bot_me_handler(&f.handlers, bot_http_request(f, "GET", "/api/v1/bots/me", ""))
	testing.expect(t, strings.contains(working.body, `"status":"working"`))
	d.state, d.finish_reason, d.finished_at = .Abandoned, "all_tried", "2026-11-17T02:00:00Z"
	_, _ = iface.delivery_update(&f.bot_repo, d, .Dispatched)
	gave_up := bot_me_handler(&f.handlers, bot_http_request(f, "GET", "/api/v1/bots/me", ""))
	testing.expect(t, strings.contains(gave_up.body, `"status_detail":"gave_up"`))
	ids, insert_err := iface.inbound_store_batch(&f.bot_repo, "telegram", {{message_id = "chm_view", bot_id = bot.bot_id, owner_user_id = bot.owner_user_id, binding_id = "chb_view", direction = .Inbound, provider_update_key = "telegram:view:1", body = "retry", created_at = "2026-11-17T03:00:00Z"}}, "2", "now")
	testing.expect_value(t, insert_err.code, domain.Error_Code.None); testing.expect_value(t, len(ids), 1)
	new_inbound := bot_me_handler(&f.handlers, bot_http_request(f, "GET", "/api/v1/bots/me", ""))
	testing.expect(t, strings.contains(new_inbound.body, `"status_detail":""`))
	testing.expect(t, !strings.contains(new_inbound.body, "gave_up"))
	testing.expect_value(t, iface.attempt_insert(&f.bot_repo, {attempt_id = "bda_view", delivery_id = d.delivery_id, bridge_id = f.wire.bridge_pin, round = 1, state = .Exhausted, candidates_json = "[]", report_json = `{"status":"exhausted"}`, created_at = "now"}).code, domain.Error_Code.None)
	history := bot_deliveries_handler(&f.handlers, bot_http_request(f, "GET", "/api/v1/bots/me/deliveries", ""))
	testing.expect_value(t, history.status, 200)
	testing.expect(t, strings.contains(history.body, `"report":{"status":"exhausted"}`))
	testing.expect(t, strings.contains(history.body, `"finish_reason":"all_tried"`))
}

bot_http_wa_identity :: proc(ctx: rawptr) -> (channel.Identity, channel.Channel_Error) {
	return {bot_user_id = "phone_fake", bot_username = "15550100001"}, {}
}
bot_http_wa_identity_fail :: proc(ctx: rawptr) -> (channel.Identity, channel.Channel_Error) {
	return {}, {kind = .Unauthorized}
}
bot_http_wa_url :: proc(ctx: rawptr, identity: channel.Identity, code: string, allocator := context.allocator) -> string {
	return strings.concatenate({"https://wa.me/", identity.bot_username, "?text=Connect%20Ninjy%20", code}, allocator)
}
bot_http_wa_text :: proc(ctx: rawptr, code: string, allocator := context.allocator) -> string {
	return strings.concatenate({"Connect Ninjy ", code}, allocator)
}
bot_http_wa_adapter :: proc(f: ^Bot_HTTP_Fixture) -> channel.Channel_Adapter {
	return {ctx = f, provider = "whatsapp", identity = bot_http_wa_identity, pairing_url = bot_http_wa_url, pairing_text = bot_http_wa_text, send_text = bot_http_disconnect_notice, reply_window_ms = 86_400_000}
}
bot_http_wa_binding :: proc(t: ^testing.T, f: ^Bot_HTTP_Fixture, bot: domain.Bot) {
	now := platform.clock_now(&f.wire.clock)
	testing.expect(t, sqlite.exec(&f.wire.conn, fmt.tprintf("INSERT INTO channel_bindings(binding_id,owner_user_id,bot_id,provider,external_chat_id,external_user_id,external_display,state,created_at,last_inbound_at) VALUES('chb_wa','%s','%s','whatsapp','100','200','Alice','active','%s','%s');", bot.owner_user_id, bot.bot_id, now, now)))
}
@(test)
test_whatsapp_pairing_route_not_configured :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := bot_http_fixture(t); defer bot_http_destroy(f)
	_ = bot_http_create(t, f)
	req := bot_http_request(f, "POST", "/api/v1/bots/me/channels/whatsapp/pairing", "{}")
	missing := bot_whatsapp_pairing_handler(&f.handlers, req)
	testing.expect(t, missing.status == 503 && strings.contains(missing.body, "channel_not_configured"))
	a := bot_http_wa_adapter(f)
	a.identity = bot_http_wa_identity_fail
	f.service.whatsapp = &a
	unavailable := bot_whatsapp_pairing_handler(&f.handlers, req)
	testing.expect_value(t, unavailable.status, 503)
	testing.expect_value(t, bot_whatsapp_pairing_handler(&f.handlers, {method = "POST", path = req.path}).status, 401)
	_, _ = iface.experiment_set(&f.experiments, {owner_user_id = string(f.wire.owner), key = "bots", enabled = false})
	testing.expect_value(t, bot_whatsapp_pairing_handler(&f.handlers, req).status, 403)
}
@(test)
test_whatsapp_pairing_route_returns_text_and_phone :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := bot_http_fixture(t); defer bot_http_destroy(f)
	_ = bot_http_create(t, f)
	a := bot_http_wa_adapter(f); f.service.whatsapp = &a
	resp := bot_whatsapp_pairing_handler(&f.handlers, bot_http_request(f, "POST", "/api/v1/bots/me/channels/whatsapp/pairing", "{}"))
	testing.expect_value(t, resp.status, 201)
	wire: struct {data: struct {pairing_url, pairing_text, phone_display, expires_at: string}}
	testing.expect(t, json.unmarshal(transmute([]byte)resp.body, &wire) == nil)
	testing.expect_value(t, wire.data.phone_display, "+15550100001")
	if !testing.expect(t, strings.has_prefix(wire.data.pairing_text, "Connect Ninjy ")) do return
	code := wire.data.pairing_text[len("Connect Ninjy "):]
	testing.expect_value(t, len(code), 32)
	testing.expect_value(t, wire.data.pairing_url, strings.concatenate({"https://wa.me/15550100001?text=Connect%20Ninjy%20", code}, context.temp_allocator))
	testing.expect(t, wire.data.expires_at != "")
}
@(test)
test_whatsapp_disconnect_route :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := bot_http_fixture(t); defer bot_http_destroy(f)
	bot := bot_http_create(t, f)
	a := bot_http_wa_adapter(f); f.service.whatsapp = &a
	bot_http_wa_binding(t, f, bot)
	testing.expect(t, sqlite.exec(&f.wire.conn, fmt.tprintf("INSERT INTO channel_bindings(binding_id,owner_user_id,bot_id,provider,external_chat_id,external_user_id,state,created_at) VALUES('chb_tg','%s','%s','telegram','other','other','active','now');", bot.owner_user_id, bot.bot_id)))
	req := bot_http_request(f, "DELETE", "/api/v1/bots/me/channels/whatsapp", "")
	resp := bot_whatsapp_disconnect_handler(&f.handlers, req)
	testing.expect_value(t, resp.status, 200)
	testing.expect(t, strings.contains(resp.body, "disconnected"))
	testing.expect_value(t, f.disconnect_notices, 1)
	_, tg_found, _ := iface.binding_get_active_by_owner(&f.bot_repo, bot.owner_user_id, "telegram")
	_, wa_found, _ := iface.binding_get_active_by_owner(&f.bot_repo, bot.owner_user_id, "whatsapp")
	testing.expect(t, tg_found && !wa_found)
	second := bot_whatsapp_disconnect_handler(&f.handlers, req)
	testing.expect(t, second.status == 404 && strings.contains(second.body, "binding_not_found"))
	testing.expect_value(t, bot_whatsapp_disconnect_handler(&f.handlers, {method = "DELETE", path = req.path}).status, 401)
}
@(test)
test_bot_view_whatsapp_block :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := bot_http_fixture(t); defer bot_http_destroy(f)
	bot := bot_http_create(t, f)
	a := bot_http_wa_adapter(f); f.service.whatsapp = &a
	req := bot_http_request(f, "GET", "/api/v1/bots/me", "")
	wire: struct {data: struct {whatsapp: struct {configured: bool, phone_display: string, binding: json.Value, window_open, reengage_sent: bool, reengage_error: string, held_replies: []struct {message_id, body, created_at: string}}}}
	resp := bot_me_handler(&f.handlers, req)
	testing.expect(t, resp.status == 200 && json.unmarshal(transmute([]byte)resp.body, &wire) == nil)
	testing.expect(t, wire.data.whatsapp.configured && wire.data.whatsapp.phone_display == "+15550100001")
	_, binding_null := wire.data.whatsapp.binding.(json.Null)
	testing.expect(t, binding_null && !wire.data.whatsapp.window_open && len(wire.data.whatsapp.held_replies) == 0)
	bot_http_wa_binding(t, f, bot)
	resp = bot_me_handler(&f.handlers, req)
	testing.expect(t, resp.status == 200 && json.unmarshal(transmute([]byte)resp.body, &wire) == nil)
	testing.expect(t, wire.data.whatsapp.window_open)
	testing.expect(t, sqlite.exec(&f.wire.conn, "UPDATE channel_bindings SET last_inbound_at='2000-01-01T00:00:00Z', reengage_error='template_unavailable' WHERE binding_id='chb_wa';"))
	for i in 0..<22 {
		testing.expect_value(t, iface.message_insert_outbound(&f.bot_repo, {message_id = fmt.tprintf("chm_held_%02d", i), binding_id = "chb_wa", owner_user_id = bot.owner_user_id, bot_id = bot.bot_id, direction = .Outbound, body = fmt.tprintf("reply %d", i), send_state = .Held, created_at = fmt.tprintf("2026-11-17T12:00:%02dZ", i)}).code, domain.Error_Code.None)
	}
	resp = bot_me_handler(&f.handlers, req)
	testing.expect(t, resp.status == 200 && json.unmarshal(transmute([]byte)resp.body, &wire) == nil)
	testing.expect(t, !wire.data.whatsapp.window_open && !wire.data.whatsapp.reengage_sent && wire.data.whatsapp.reengage_error == "template_unavailable")
	if testing.expect_value(t, len(wire.data.whatsapp.held_replies), 20) {
		testing.expect_value(t, wire.data.whatsapp.held_replies[0].message_id, "chm_held_00")
		testing.expect_value(t, wire.data.whatsapp.held_replies[19].message_id, "chm_held_19")
		testing.expect_value(t, wire.data.whatsapp.held_replies[0].body, "reply 0")
	}
	testing.expect_value(t, iface.binding_set_reengage(&f.bot_repo, "chb_wa", "2026-11-17T12:00:00Z", "").code, domain.Error_Code.None)
	resp = bot_me_handler(&f.handlers, req)
	testing.expect(t, json.unmarshal(transmute([]byte)resp.body, &wire) == nil && wire.data.whatsapp.reengage_sent && wire.data.whatsapp.reengage_error == "")
	a.identity = bot_http_wa_identity_fail
	resp = bot_me_handler(&f.handlers, req)
	testing.expect(t, json.unmarshal(transmute([]byte)resp.body, &wire) == nil && wire.data.whatsapp.phone_display == "")
}
@(test)
test_telegram_pairing_response_unchanged :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := bot_http_fixture(t); defer bot_http_destroy(f)
	_ = bot_http_create(t, f)
	a := bot_http_wa_adapter(f)
	a.provider, a.pairing_text = "telegram", nil
	f.service.adapter = &a
	resp := bot_pairing_handler(&f.handlers, bot_http_request(f, "POST", "/api/v1/bots/me/channels/telegram/pairing", "{}"))
	testing.expect_value(t, resp.status, 201)
	value, err := json.parse(resp.body)
	testing.expect(t, err == nil)
	root, root_ok := value.(json.Object)
	if !testing.expect(t, root_ok) do return
	data, data_ok := root["data"].(json.Object)
	if !testing.expect(t, data_ok) do return
	testing.expect_value(t, len(data), 2)
	testing.expect(t, "pairing_url" in data && "expires_at" in data)
}
Bot_HTTP_WA_Lookup :: struct {enabled: bool}
bot_http_wa_lookup :: proc(ctx: rawptr, user_id: string) -> (domain.User_Entitlements, domain.Domain_Error) {
	return {whatsapp_enabled = (^Bot_HTTP_WA_Lookup)(ctx).enabled}, {}
}
// REQ-WAI-2a/3: pairing refuses with whatsapp_invite_only; the bot view tells
// the UI whether to show Connect or the invite-only message.
@(test)
test_whatsapp_pairing_route_invite_only :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := bot_http_fixture(t); defer bot_http_destroy(f)
	_ = bot_http_create(t, f)
	a := bot_http_wa_adapter(f); f.service.whatsapp = &a
	tg := bot_http_wa_adapter(f)
	tg.provider, tg.pairing_text = "telegram", nil
	f.service.adapter = &tg
	lookup := Bot_HTTP_WA_Lookup{}
	f.service.entitlements = {ctx = &lookup, lookup = bot_http_wa_lookup}
	req := bot_http_request(f, "POST", "/api/v1/bots/me/channels/whatsapp/pairing", "{}")
	refused := bot_whatsapp_pairing_handler(&f.handlers, req)
	testing.expect_value(t, refused.status, 403)
	testing.expect(t, strings.contains(refused.body, `"code":"whatsapp_invite_only"`), refused.body)
	view := bot_me_handler(&f.handlers, bot_http_request(f, "GET", "/api/v1/bots/me", ""))
	wire: struct {data: struct {whatsapp: struct {configured, enabled: bool}}}
	testing.expect(t, json.unmarshal(transmute([]byte)view.body, &wire) == nil)
	testing.expect(t, wire.data.whatsapp.configured && !wire.data.whatsapp.enabled)
	// Telegram pairing is unaffected.
	testing.expect_value(t, bot_pairing_handler(&f.handlers, bot_http_request(f, "POST", "/api/v1/bots/me/channels/telegram/pairing", "{}")).status, 201)

	lookup.enabled = true
	testing.expect_value(t, bot_whatsapp_pairing_handler(&f.handlers, req).status, 201)
	view = bot_me_handler(&f.handlers, bot_http_request(f, "GET", "/api/v1/bots/me", ""))
	testing.expect(t, json.unmarshal(transmute([]byte)view.body, &wire) == nil)
	testing.expect(t, wire.data.whatsapp.enabled)
}
