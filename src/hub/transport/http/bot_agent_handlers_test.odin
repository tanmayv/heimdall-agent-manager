package http

import "core:encoding/json"
import content_service "odin_test:hub/service/content"
import "core:strings"
import "core:testing"
import "core:time"
import "core:fmt"
import "core:unicode/utf8"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import bots "odin_test:hub/service/bots"
import channel "odin_test:hub/service/channel"
import card_service "odin_test:hub/service/card"

Bot_Channel_Fixture :: struct {
	f: ^Bot_HTTP_Fixture,
	content: content_service.Content_Service,
	uow_impl: sqlite.SQLite_Unit_Of_Work_Factory,
	uow: iface.Unit_Of_Work_Factory,
	h: Bot_Agent_Handlers,
	adapter: channel.Channel_Adapter,
	whatsapp: channel.Channel_Adapter,
	sent_chat: string,
	sent: [dynamic]string,
	fail_send: bool,
	media_fetch_error: channel.Channel_Error_Kind,
}
bot_channel_test_send :: proc(ctx: rawptr, chat, text: string) -> (string, channel.Channel_Error) {
	c := (^Bot_Channel_Fixture)(ctx)
	c.sent_chat = chat
	append(&c.sent, strings.clone(text))
	if c.fail_send do return "", {kind = .Chat_Unavailable}
	return strings.clone("telegram_id"), {}
}
bot_channel_fixture :: proc(t: ^testing.T, paired := true, is_bot := true) -> ^Bot_Channel_Fixture {
	c := new(Bot_Channel_Fixture)
	c.f = bot_http_fixture(t)
	c.content = content_service.Content_Service{content = &c.f.content_repo}
	c.f.wire.ah.content = &c.content
	c.uow = sqlite.new_unit_of_work_factory(&c.uow_impl, &c.f.wire.conn, nil)
	c.f.service.uow_factory = &c.uow
	c.adapter = {ctx = c, provider = "telegram", send_text = bot_channel_test_send}
	c.f.service.adapter = &c.adapter
	c.h = {agent_actions = &c.f.wire.ah, bots = &c.f.service, experiments = &c.f.experiments}
	bot := bot_http_create(t, c.f)
	defer domain.bot_destroy(&bot)
	if is_bot do testing.expect_value(t, iface.bot_set_instance(&c.f.bot_repo, bot.bot_id, c.f.wire.instance_id, "now").code, domain.Error_Code.None)
	if paired {
		testing.expect_value(t, iface.pairing_insert(&c.f.bot_repo, {code_hash = "hash", owner_user_id = bot.owner_user_id, bot_id = bot.bot_id, provider = "telegram", expires_at = "9999"}).code, domain.Error_Code.None)
		prev, _, err := iface.binding_activate(&c.f.bot_repo, {binding_id = "chb_a", owner_user_id = bot.owner_user_id, bot_id = bot.bot_id, provider = "telegram", external_chat_id = "111", external_user_id = "222", external_display = "@alice", state = .Active}, "hash", "2026-11-17T12:00:00Z")
		domain.channel_binding_destroy(&prev)
		testing.expect_value(t, err.code, domain.Error_Code.None)
	}
	return c
}
bot_channel_destroy :: proc(c: ^Bot_Channel_Fixture) {
	for text in c.sent do delete(text)
	delete(c.sent)
	bot_http_destroy(c.f)
	free(c)
}
bot_channel_req :: proc(c: ^Bot_Channel_Fixture, action, body: string) -> Request {
	req := wire_agent_request(c.f.wire, action, body)
	req.path = strings.concatenate({"/api/v1/agent-actions/channel/",action}, context.temp_allocator)
	return req
}
bot_channel_inbound :: proc(t: ^testing.T, c: ^Bot_Channel_Fixture, id: string) {
	bot, _, _ := iface.bot_get_by_owner(&c.f.bot_repo, string(c.f.wire.owner)); defer domain.bot_destroy(&bot)
	ids, err := iface.inbound_store_batch(&c.f.bot_repo, "telegram", {{
		message_id = id, binding_id = "chb_a", owner_user_id = bot.owner_user_id, bot_id = bot.bot_id,
		direction = .Inbound, provider_update_key = id, body = id, created_at = "2026-11-17T12:00:00Z",
	}}, "2", "2026-11-17T12:00:00Z")
	defer {for id in ids do delete(id); delete(ids)}
	testing.expect_value(t, err.code, domain.Error_Code.None)
}
bot_channel_read :: proc(c: ^Bot_Channel_Fixture, body := "{\"params\":{}}") -> Response {return bot_agent_channel_read_handler(&c.h, bot_channel_req(c,"read",body))}
bot_channel_send :: proc(c: ^Bot_Channel_Fixture, body := "{\"params\":{\"text\":\"answer\"}}") -> Response {return bot_agent_channel_send_handler(&c.h, bot_channel_req(c,"send",body))}

@(test)
test_channel_read_marks_read_and_repeats_unreplied :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := bot_channel_fixture(t); defer bot_channel_destroy(c)
	bot_channel_inbound(t, c, "chm_1")
	bot_channel_inbound(t, c, "chm_2")
	response := bot_channel_read(c, "{\"params\":{\"limit\":1}}")
	testing.expectf(t, response.status == 200, "%s",response.body)
	wire: struct {data: struct {messages: []Bot_Channel_Read_Message, pending_total: int}}
	_ = json.unmarshal(transmute([]u8)response.body, &wire, allocator = context.temp_allocator)
	testing.expect(t, len(wire.data.messages) == 1 && wire.data.messages[0].message_id == "chm_1" && wire.data.messages[0].sender == "@alice" && wire.data.pending_total == 2)
	bot, _, _ := iface.bot_get_by_owner(&c.f.bot_repo, string(c.f.wire.owner))
	rows, _ := iface.messages_pending(&c.f.bot_repo, bot.bot_id, -1)
	testing.expect(t, len(rows) == 2 && rows[0].read_at != "" && rows[1].read_at == "" && rows[0].replied_at == "")
	first_read := rows[0].read_at
	repeat := bot_channel_read(c, "{\"params\":{\"limit\":1}}")
	testing.expect_value(t, repeat.status, 200)
	_ = json.unmarshal(transmute([]u8)repeat.body, &wire, allocator = context.temp_allocator)
	testing.expect_value(t, wire.data.messages[0].message_id, "chm_1")
	again, _ := iface.messages_pending(&c.f.bot_repo, bot.bot_id, -1)
	testing.expect_value(t, again[0].read_at, first_read)
	_, open, _ := iface.delivery_get_open(&c.f.bot_repo, bot.bot_id)
	testing.expect(t, !open, "read never creates or advances delivery progress")
	for body in ([]string{"{\"params\":{\"limit\":0}}","{\"params\":{\"limit\":51}}","{\"params\":{\"limit\":\"1\"}}","{\"params\":{\"limit\":1.5}}"}) do testing.expect_value(t, bot_channel_read(c,body).status, 400)
}
@(test)
test_channel_send_only_paired_chat :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := bot_channel_fixture(t); defer bot_channel_destroy(c)
	resp := bot_channel_send(c, "{\"params\":{\"text\":\"hi\",\"chat_id\":\"attacker\",\"external_chat_id\":\"attacker\"}}")
	testing.expectf(t, resp.status == 200, "%s", resp.body)
	testing.expect_value(t, c.sent_chat, "111")
	bot, _, _ := iface.bot_get_by_owner(&c.f.bot_repo, string(c.f.wire.owner))
	rows, _ := iface.messages_history(&c.f.bot_repo, bot.bot_id, -1)
	testing.expect(t, len(rows) == 1 && rows[0].send_state == .Sent && rows[0].binding_id == "chb_a")
	unpaired := bot_channel_fixture(t, paired = false); defer bot_channel_destroy(unpaired)
	for handler in ([]Handler_Proc{bot_agent_channel_read_handler, bot_agent_channel_send_handler, bot_agent_channel_history_handler}) {
		r := handler(&unpaired.h, bot_channel_req(unpaired,"send","{}"))
		testing.expect(t, r.status == 409 && strings.contains(r.body,"channel_not_paired"))
	}
}
@(test)
test_channel_send_marks_replied_and_acts_delivery :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := bot_channel_fixture(t); defer bot_channel_destroy(c)
	bot, _, _ := iface.bot_get_by_owner(&c.f.bot_repo, string(c.f.wire.owner))
	bot_channel_inbound(t, c, "chm_1")
	testing.expect_value(t, bots.delivery_on_inbound(&c.f.service, bot.bot_id, 1794916800000).code, domain.Error_Code.None)
	d, _, _ := iface.delivery_get_open(&c.f.bot_repo, bot.bot_id)
	dispatched := d; dispatched.state = .Dispatched
	_, _ = iface.delivery_update(&c.f.bot_repo, dispatched, .Pending)
	testing.expect_value(t, iface.attempt_insert(&c.f.bot_repo, {attempt_id = "bda_reply", delivery_id = d.delivery_id, round = 1, bridge_id = c.f.wire.bridge_pin, state = .Accepted, report_json = "{\"phase\":\"read\"}"}).code, domain.Error_Code.None)
	testing.expect_value(t, bot_channel_read(c).status, 200)
	bot_channel_inbound(t, c, "chm_2") // unread next batch survives this reply
	testing.expect_value(t, bot_channel_send(c).status, 200)
	done, _, _ := iface.delivery_get(&c.f.bot_repo, d.delivery_id)
	a, _, _ := iface.attempt_get(&c.f.bot_repo, "bda_reply")
	testing.expect(t, done.state == .Acted && done.finish_reason == "acted" && done.finished_at != "")
	testing.expect(t, a.state == .Acted && a.report_json == "{\"phase\":\"read\"}")
	pending, _ := iface.messages_pending(&c.f.bot_repo, bot.bot_id, -1)
	testing.expect(t, len(pending) == 1 && pending[0].message_id == "chm_2" && pending[0].read_at == "")
	next, open, _ := iface.delivery_get_open(&c.f.bot_repo, bot.bot_id)
	testing.expect(t, open && next.state == .Pending && next.through_message_id == "chm_2" && next.delivery_id != d.delivery_id)

	_ = bot_channel_read(c)
	c.fail_send = true
	failed := bot_channel_send(c)
	testing.expect(t, failed.status == 503 && strings.contains(failed.body,"channel_send_failed"))
	still_pending, _ := iface.messages_pending(&c.f.bot_repo, bot.bot_id, -1)
	testing.expect_value(t, len(still_pending), 1)
	still_open, open_after, _ := iface.delivery_get_open(&c.f.bot_repo, bot.bot_id)
	testing.expect(t, open_after && still_open.state == .Pending)
}
@(test)
test_channel_routes_not_a_bot :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := bot_channel_fixture(t, is_bot = false); defer bot_channel_destroy(c)
	for handler in ([]Handler_Proc{bot_agent_channel_read_handler, bot_agent_channel_send_handler, bot_agent_channel_history_handler}) {
		r := handler(&c.h, bot_channel_req(c,"send","{}"))
		testing.expect(t, r.status == 403 && strings.contains(r.body,"not_a_bot"))
	}
	_, _ = iface.experiment_set(&c.f.experiments, {owner_user_id = string(c.f.wire.owner), key = "bots", enabled = false})
	for handler in ([]Handler_Proc{bot_agent_channel_read_handler, bot_agent_channel_send_handler, bot_agent_channel_history_handler}) {
		r := handler(&c.h, bot_channel_req(c,"send","{}"))
		testing.expect(t, r.status == 403 && strings.contains(r.body,"experimental_feature_disabled"))
		unauth := handler(&c.h, {method = "POST", body = "{}"})
		testing.expect_value(t, unauth.status, 401)
	}
}
@(test)
test_channel_send_splits_4000_bytes_utf8 :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := bot_channel_fixture(t); defer bot_channel_destroy(c)
	text := strings.repeat("🌏", 2300, context.temp_allocator)
	input, _ := json.marshal(struct {params: struct {text: string}}{{text}}, allocator = context.temp_allocator)
	r := bot_channel_send(c,string(input))
	testing.expectf(t, r.status == 200, "%s", r.body)
	wire: struct {data: struct {message_ids: []string, chunks: int}}
	_ = json.unmarshal(transmute([]u8)r.body, &wire, allocator = context.temp_allocator)
	testing.expect(t, wire.data.chunks == 3 && len(wire.data.message_ids) == 3 && len(c.sent) == 3)
	pos := 0
	for chunk in c.sent {
		testing.expect(t, len(chunk) <= 4000 && utf8.valid_string(chunk))
		testing.expect_value(t, chunk, text[pos:pos+len(chunk)])
		pos += len(chunk)
	}
	testing.expect_value(t, pos, len(text))
	for body in ([]string{"{}","{\"params\":{\"text\":\"\"}}","{\"params\":{\"text\":123}}","{\"params\":{\"text\":null}}"}) {
		response := bot_channel_send(c,body)
		testing.expect(t, response.status == 400 && strings.contains(response.body,"text_invalid"))
	}
	huge := strings.repeat("a",16385,context.temp_allocator)
	large, _ := json.marshal(struct {params: struct {text: string}}{{huge}}, allocator = context.temp_allocator)
	testing.expect_value(t, bot_channel_send(c,string(large)).status, 400)
}
@(test)
test_channel_history_omits_purged_and_limits :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := bot_channel_fixture(t); defer bot_channel_destroy(c)
	bot_channel_inbound(t, c, "chm_1")
	bot_channel_inbound(t, c, "chm_2")
	r := bot_agent_channel_history_handler(&c.h, bot_channel_req(c,"history","{\"params\":{\"limit\":1}}"))
	wire: struct {data: struct {messages: []Bot_Channel_History_Message}}
	_ = json.unmarshal(transmute([]u8)r.body, &wire, allocator = context.temp_allocator)
	testing.expect(t, r.status == 200 && len(wire.data.messages) == 1 && wire.data.messages[0].message_id == "chm_2")
	_ = iface.messages_purge_binding(&c.f.bot_repo, "chb_a")
	purged := bot_agent_channel_history_handler(&c.h, bot_channel_req(c,"history","{}"))
	_ = json.unmarshal(transmute([]u8)purged.body, &wire, allocator = context.temp_allocator)
	testing.expect(t, purged.status == 200 && len(wire.data.messages) == 0)
}

bot_channel_test_identity :: proc(ctx: rawptr) -> (channel.Identity, channel.Channel_Error) {return {bot_user_id = "1", bot_username = "test_bot"}, {}}
bot_channel_test_pairing_url :: proc(ctx: rawptr, identity: channel.Identity, code: string, allocator := context.allocator) -> string {
	return strings.concatenate({"https://t.me/",identity.bot_username,"?start=",code}, allocator)
}

@(test)
test_bot_pairing_disconnect_and_messages_routes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := bot_channel_fixture(t, paired = false); defer bot_channel_destroy(c)
	c.adapter.identity = bot_channel_test_identity
	c.adapter.pairing_url = bot_channel_test_pairing_url
	link := bot_pairing_handler(&c.f.handlers, bot_http_request(c.f,"POST","/api/v1/bots/me/channels/telegram/pairing","{}"))
	wire: struct {data: bots.Bot_Pairing_Link}
	testing.expect_value(t, link.status, 201)
	testing.expect_value(t, json.unmarshal(transmute([]u8)link.body, &wire, allocator = context.temp_allocator), nil)
	testing.expect(t, strings.has_prefix(wire.data.pairing_url,"https://t.me/test_bot?start=") && len(wire.data.expires_at) == 20)
	missing := bot_disconnect_handler(&c.f.handlers, bot_http_request(c.f,"DELETE","/api/v1/bots/me/channels/telegram",""))
	error_wire: struct {error: struct {details: struct {code: string}}}
	testing.expect_value(t, json.unmarshal(transmute([]u8)missing.body, &error_wire, allocator = context.temp_allocator), nil)
	testing.expect(t, missing.status == 404 && error_wire.error.details.code == "binding_not_found")
	c.f.service.adapter = nil
	no_adapter := bot_pairing_handler(&c.f.handlers, bot_http_request(c.f,"POST","/api/v1/bots/me/channels/telegram/pairing","{}"))
	testing.expect_value(t, no_adapter.status, 503)
	testing.expect(t, strings.contains(no_adapter.body,"channel_not_configured"))

	paired := bot_channel_fixture(t); defer bot_channel_destroy(paired)
	bot_channel_inbound(t, paired, "chm_1")
	bot_channel_inbound(t, paired, "chm_2")
	req := bot_http_request(paired.f,"GET","/api/v1/bots/me/channels/telegram/messages","")
	req.query = "limit=1"
	messages := bot_messages_handler(&paired.f.handlers,req)
	history: struct {data: struct {messages: []struct {message_id, direction, body: string, body_purged: bool, send_state, created_at, read_at, replied_at: string}}}
	testing.expect_value(t, json.unmarshal(transmute([]u8)messages.body, &history, allocator = context.temp_allocator), nil)
	testing.expect(t, messages.status == 200 && len(history.data.messages) == 1 && history.data.messages[0].message_id == "chm_2")
	for query in ([]string{"limit=0","limit=201","limit=garbage","limit="}) {
		req.query = query
		testing.expect_value(t, bot_messages_handler(&paired.f.handlers,req).status, 400)
	}
	disconnected := bot_disconnect_handler(&paired.f.handlers, bot_http_request(paired.f,"DELETE","/api/v1/bots/me/channels/telegram",""))
	testing.expect_value(t, disconnected.status, 200)
	testing.expect(t, strings.contains(disconnected.body,"\"disconnected\":true") && paired.sent[len(paired.sent)-1] == bots.COPY_DISCONNECTED)
	req.query = ""
	purged := bot_messages_handler(&paired.f.handlers,req)
	_ = json.unmarshal(transmute([]u8)purged.body, &history, allocator = context.temp_allocator)
	testing.expect(t, len(history.data.messages) == 2 && history.data.messages[0].body_purged && history.data.messages[0].body == "")
	bot, _, _ := iface.bot_get_by_owner(&paired.f.bot_repo,string(paired.f.wire.owner))
	_ = iface.bot_delete(&paired.f.bot_repo,bot.bot_id)
	for handler in ([]Handler_Proc{bot_pairing_handler,bot_disconnect_handler,bot_messages_handler}) {
		r := handler(&paired.f.handlers,req)
		testing.expect(t, r.status == 404 && strings.contains(r.body,"bot_not_found"))
	}
}

bot_channel_whatsapp :: proc(t: ^testing.T, c: ^Bot_Channel_Fixture, last := "2026-11-17T12:00:00Z") {
	bot, found, err := iface.bot_get_by_owner(&c.f.bot_repo, string(c.f.wire.owner))
	defer domain.bot_destroy(&bot)
	testing.expect(t, found && err.code == .None)
	c.whatsapp = {ctx = c, provider = "whatsapp", send_text = bot_channel_test_send, reply_window_ms = 86_400_000}
	c.f.service.whatsapp = &c.whatsapp
	testing.expect_value(t, iface.pairing_insert(&c.f.bot_repo, {code_hash = "wa_hash", owner_user_id = bot.owner_user_id, bot_id = bot.bot_id, provider = "whatsapp", expires_at = "9999"}).code, domain.Error_Code.None)
	prev, _, e := iface.binding_activate(&c.f.bot_repo, {binding_id = "chb_wa", owner_user_id = bot.owner_user_id, bot_id = bot.bot_id, provider = "whatsapp", external_chat_id = "333", external_user_id = "444", external_display = "Alice WA", state = .Active, last_inbound_at = last}, "wa_hash", "2026-11-17T12:00:00Z")
	domain.channel_binding_destroy(&prev)
	testing.expect_value(t, e.code, domain.Error_Code.None)
}
bot_channel_wa_inbound :: proc(t: ^testing.T, c: ^Bot_Channel_Fixture) {
	bot, _, _ := iface.bot_get_by_owner(&c.f.bot_repo, string(c.f.wire.owner)); defer domain.bot_destroy(&bot)
	ids, err := iface.inbound_store_batch(&c.f.bot_repo, "whatsapp", {{
		message_id = "chm_wa", binding_id = "chb_wa", owner_user_id = bot.owner_user_id, bot_id = bot.bot_id,
		direction = .Inbound, provider_update_key = "wa:1", body = "hello wa", created_at = "2026-11-17T11:00:00Z",
	}}, "", "2026-11-17T12:00:00Z")
	defer {for id in ids do delete(id); delete(ids)}
	testing.expect_value(t, err.code, domain.Error_Code.None)
}
@(test)
test_channel_read_returns_channel_field :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := bot_channel_fixture(t); defer bot_channel_destroy(c)
	bot_channel_whatsapp(t, c)
	bot_channel_wa_inbound(t, c)
	bot_channel_inbound(t, c, "chm_tg")
	r := bot_channel_read(c)
	wire: struct {data: struct {messages: []Bot_Channel_Read_Message, pending_total: int}}
	testing.expect_value(t, r.status, 200)
	testing.expect_value(t, json.unmarshal(transmute([]u8)r.body, &wire, allocator = context.temp_allocator), nil)
	testing.expect(t, len(wire.data.messages) == 1 && wire.data.messages[0].channel == "whatsapp" && wire.data.messages[0].sender == "Alice WA" && wire.data.pending_total == 2)
}
@(private = "file")
bot_channel_origin_now :: proc(ctx: rawptr) -> string { return "2026-11-17T12:00:00Z" }

@(test)
test_channel_send_reply_goes_to_origin :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := bot_channel_fixture(t); defer bot_channel_destroy(c)
	// Keep the origin-routing fixture inside its fixed inbound reply window.
	clock := platform.Clock{now=bot_channel_origin_now}
	c.f.service.clock = &clock
	bot_channel_whatsapp(t, c)
	bot_channel_wa_inbound(t, c)
	bot_channel_inbound(t, c, "chm_tg")
	testing.expect_value(t, bot_channel_read(c).status, 200)
	r := bot_channel_send(c)
	wire: struct {data: struct {channel: string, held: bool}}
	testing.expect_value(t, r.status, 200)
	testing.expect_value(t, json.unmarshal(transmute([]u8)r.body, &wire, allocator = context.temp_allocator), nil)
	testing.expect(t, wire.data.channel == "whatsapp" && !wire.data.held && c.sent_chat == "333")
	r = bot_channel_read(c)
	read: struct {data: struct {messages: []Bot_Channel_Read_Message}}
	_ = json.unmarshal(transmute([]u8)r.body, &read, allocator = context.temp_allocator)
	testing.expect(t, r.status == 200 && len(read.data.messages) == 1 && read.data.messages[0].channel == "telegram")
	testing.expect_value(t, bot_channel_send(c).status, 200)
	testing.expect_value(t, c.sent_chat, "111")
}
@(test)
test_channel_send_held_response :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := bot_channel_fixture(t, paired = false); defer bot_channel_destroy(c)
	bot_channel_whatsapp(t, c, "2000-01-01T00:00:00Z")
	bot_channel_wa_inbound(t, c)
	testing.expect_value(t, bot_channel_read(c).status, 200)
	r := bot_channel_send(c)
	wire: struct {data: struct {message_ids: []string, chunks: int, channel: string, held: bool}}
	testing.expect_value(t, r.status, 200)
	testing.expect_value(t, json.unmarshal(transmute([]u8)r.body, &wire, allocator = context.temp_allocator), nil)
	testing.expect(t, wire.data.held && wire.data.channel == "whatsapp" && wire.data.chunks == 1 && len(wire.data.message_ids) == 1 && len(c.sent) == 0)
	bot, _, _ := iface.bot_get_by_owner(&c.f.bot_repo, string(c.f.wire.owner))
	pending, _ := iface.messages_pending(&c.f.bot_repo, bot.bot_id, -1)
	testing.expect_value(t, len(pending), 0)
	held, _ := iface.messages_held(&c.f.bot_repo, "chb_wa")
	testing.expect(t, len(held) == 1 && held[0].body == "answer")
}
@(test)
test_channel_history_channel_field :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := bot_channel_fixture(t); defer bot_channel_destroy(c)
	bot_channel_whatsapp(t, c)
	bot_channel_wa_inbound(t, c)
	bot_channel_inbound(t, c, "chm_tg")
	r := bot_agent_channel_history_handler(&c.h, bot_channel_req(c, "history", "{}"))
	wire: struct {data: struct {messages: []Bot_Channel_History_Message}}
	testing.expect_value(t, r.status, 200)
	_ = json.unmarshal(transmute([]u8)r.body, &wire, allocator = context.temp_allocator)
	testing.expect(t, len(wire.data.messages) == 2 && wire.data.messages[0].channel == "telegram" && wire.data.messages[1].channel == "whatsapp")
	_ = iface.binding_revoke(&c.f.bot_repo, "chb_wa", "now")
	r = bot_agent_channel_history_handler(&c.h, bot_channel_req(c, "history", "{}"))
	_ = json.unmarshal(transmute([]u8)r.body, &wire, allocator = context.temp_allocator)
	testing.expect(t, r.status == 200 && len(wire.data.messages) == 1 && wire.data.messages[0].channel == "telegram")
}
@(test)
test_channel_routes_not_paired_without_bindings :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := bot_channel_fixture(t, paired = false); defer bot_channel_destroy(c)
	for handler in ([]Handler_Proc{bot_agent_channel_read_handler, bot_agent_channel_send_handler, bot_agent_channel_history_handler}) {
		r := handler(&c.h, bot_channel_req(c, "read", "{}"))
		testing.expect(t, r.status == 409 && strings.contains(r.body, "channel_not_paired"))
	}
}

bot_media_http_fetch :: proc(ctx: rawptr, ref: string, max_bytes: i64, allocator := context.allocator) -> (channel.Fetched_Media, channel.Channel_Error) {
		c := (^Bot_Channel_Fixture)(ctx)
	if c.media_fetch_error != .None do return {}, {kind = c.media_fetch_error}
	bytes := make([]byte,3,allocator); copy(bytes,transmute([]byte)string("abc"))
	return {bytes,strings.clone("application/pdf",allocator)}, {}
}
bot_media_http_send :: proc(ctx: rawptr, chat: string, media: channel.Outbound_Media, timeout_ms: int) -> (string,channel.Channel_Error) {return strings.clone("native_id"),{}}
bot_media_http_slow_send :: proc(ctx: rawptr, chat: string, media: channel.Outbound_Media, timeout_ms: int) -> (string,channel.Channel_Error) {
	time.sleep(560*time.Millisecond)
	return strings.clone("native_id"),{}
}
bot_media_http_setup :: proc(t: ^testing.T, c: ^Bot_Channel_Fixture) {
	c.adapter.media_fetch = bot_media_http_fetch
	c.adapter.send_media = bot_media_http_send
	c.adapter.media = {fetch_max_bytes=10000,caption_max_runes=100,send_rules=make([]channel.Media_Send_Rule,1,context.temp_allocator)}
	c.adapter.media.send_rules[0] = {kind=.Document,max_bytes=10000,caption=true}
}
bot_media_http_inbound :: proc(t: ^testing.T,c: ^Bot_Channel_Fixture) {
	bot,_,_ := iface.bot_get_by_owner(&c.f.bot_repo,string(c.f.wire.owner)); defer domain.bot_destroy(&bot)
	ids,e := iface.inbound_store_batch(&c.f.bot_repo,"telegram",{{
		message_id="chm_media",binding_id="chb_a",owner_user_id=bot.owner_user_id,bot_id=bot.bot_id,direction=.Inbound,
		body="caption",provider_update_key="media_update",created_at="2026-11-17T12:00:00Z",
		attachment={attachment_id="cha_media",kind=.Document,file_ref="never-on-wire",name="invoice.pdf",mime="application/pdf",size_bytes=3,state=.Pending},
	}},"3","2026-11-17T12:00:00Z")
	defer {for id in ids do delete(id); delete(ids)}
	testing.expect_value(t,e.code,domain.Error_Code.None)
}
bot_media_http_artifact :: proc(t: ^testing.T,c: ^Bot_Channel_Fixture,id,owner: string,deleted := "") {
	a,ok,e := iface.content_save_artifact(&c.f.content_repo,{artifact_id=id,owner_user_id=domain.User_ID(owner),kind="file",name="file",content_type="text/plain",content="sealed",size_bytes=6,deleted_at=deleted,created_at="now",updated_at="now"})
	defer domain.artifact_destroy(&a)
	testing.expect(t,ok && e.code == .None)
}
bot_media_http_route :: proc(c: ^Bot_Channel_Fixture, handler: Handler_Proc, body: string) -> Response {
	return handler(&c.h,bot_channel_req(c,"media",body))
}
@(test)
test_channel_read_returns_attachments :: proc(t: ^testing.T) {
	context.allocator=context.temp_allocator
	c := bot_channel_fixture(t); defer bot_channel_destroy(c)
	bot_media_http_inbound(t,c)
	resp := bot_channel_read(c)
	testing.expectf(t,resp.status==200,"%s",resp.body)
	wire: struct{data:struct{messages:[]Bot_Channel_Read_Message}}
	_ = json.unmarshal(transmute([]byte)resp.body,&wire,allocator=context.temp_allocator)
	testing.expect(t,len(wire.data.messages)==1 && len(wire.data.messages[0].attachments)==1)
	if len(wire.data.messages)==1 && len(wire.data.messages[0].attachments)==1 {
		a := wire.data.messages[0].attachments[0]
		testing.expect(t,a.attachment_id=="cha_media" && a.name=="invoice.pdf" && a.mime=="application/pdf" && a.size==3 && a.artifact_id=="" && a.state=="pending" && a.kind=="document")
	}
	testing.expect(t,!strings.contains(resp.body,"never-on-wire"))
}
@(test)
test_channel_read_text_only_shape_unchanged :: proc(t: ^testing.T) {
	context.allocator=context.temp_allocator
	c := bot_channel_fixture(t); defer bot_channel_destroy(c); bot_channel_inbound(t,c,"text")
	resp := bot_channel_read(c)
	testing.expect(t,resp.status==200 && !strings.contains(resp.body,"attachments"))
}
@(test)
test_channel_history_attachments_both_directions :: proc(t: ^testing.T) {
	context.allocator=context.temp_allocator
	c := bot_channel_fixture(t); defer bot_channel_destroy(c)
	bot_media_http_inbound(t,c)
	bot,_,_ := iface.bot_get_by_owner(&c.f.bot_repo,string(c.f.wire.owner))
	e := iface.message_insert_outbound(&c.f.bot_repo,{message_id="chm_out",binding_id="chb_a",owner_user_id=bot.owner_user_id,bot_id=bot.bot_id,direction=.Outbound,body="link",
		send_state=.Sent,created_at="2026-11-17T12:00:01Z",attachment={attachment_id="cha_out",kind=.Image,name="photo.png",mime="image/png",size_bytes=12,artifact_id="art_out",state=.Native}})
	testing.expect_value(t,e.code,domain.Error_Code.None)
	resp := bot_media_http_route(c,bot_agent_channel_history_handler,`{"params":{}}`)
	wire: struct{data:struct{messages:[]Bot_Channel_History_Message}}
	_ = json.unmarshal(transmute([]byte)resp.body,&wire,allocator=context.temp_allocator)
	testing.expect(t,resp.status==200 && len(wire.data.messages)==2)
	for m in wire.data.messages {
		if !testing.expect_value(t,len(m.attachments),1) do continue
		testing.expect_value(t,m.attachments[0].state,"native" if m.direction=="outbound" else "pending")
	}
}
@(test)
test_media_fetch_route_outcomes :: proc(t: ^testing.T) {
	context.allocator=context.temp_allocator
	c := bot_channel_fixture(t); defer bot_channel_destroy(c)
	bot_media_http_setup(t,c); bot_media_http_inbound(t,c)
	resp := bot_media_http_route(c,bot_agent_media_fetch_handler,`{"attachment_id":"cha_media"}`)
	testing.expectf(t,resp.status==200 && strings.contains(resp.body,`"content_base64":"YWJj"`) && strings.contains(resp.body,`"size":3`),"%s",resp.body)
	for state in ([]string{"too_large","unavailable","stored"}) {
		testing.expect(t,sqlite.exec(&c.f.wire.conn,fmt.tprintf("UPDATE channel_attachments SET state='%s',artifact_id='art_file';",state)))
		resp=bot_media_http_route(c,bot_agent_media_fetch_handler,`{"attachment_id":"cha_media"}`)
		testing.expectf(t,resp.status==200 && strings.contains(resp.body,fmt.tprintf(`"outcome":"%s"`,state)) && !strings.contains(resp.body,"content_base64") && !strings.contains(resp.body,`"size"`),"%s",resp.body)
	}
	testing.expect(t,sqlite.exec(&c.f.wire.conn,"UPDATE channel_attachments SET state='pending',artifact_id='';"))
	c.media_fetch_error = .Transient
	resp=bot_media_http_route(c,bot_agent_media_fetch_handler,`{"attachment_id":"cha_media"}`)
	testing.expect(t,resp.status==200 && strings.contains(resp.body,`"outcome":"failed"`) && strings.contains(resp.body,`"error":"Transient"`) && !strings.contains(resp.body,"content_base64"))
	c.adapter.media_fetch = nil
	resp=bot_media_http_route(c,bot_agent_media_fetch_handler,`{"attachment_id":"cha_media"}`)
	testing.expect(t,resp.status==503 && strings.contains(resp.body,"channel_not_configured"))
	for body in ([]string{`{}`,`{"attachment_id":1}`,"["}) {
		resp=bot_media_http_route(c,bot_agent_media_fetch_handler,body)
		testing.expect(t,resp.status==400 && strings.contains(resp.body,"attachment_id_invalid"))
	}
}
@(test)
test_media_fetch_route_requires_bot_and_owner :: proc(t: ^testing.T) {
	context.allocator=context.temp_allocator
	for handler in ([]Handler_Proc{bot_agent_media_fetch_handler,bot_agent_media_stored_handler,bot_agent_media_plan_handler}) {
		c := bot_channel_fixture(t,is_bot=false)
		resp:=bot_media_http_route(c,handler,`{}`)
		testing.expect(t,resp.status==403 && strings.contains(resp.body,"not_a_bot"));bot_channel_destroy(c)
		c=bot_channel_fixture(t,paired=false)
		resp=bot_media_http_route(c,handler,`{}`)
		testing.expect(t,resp.status==409 && strings.contains(resp.body,"channel_not_paired"));bot_channel_destroy(c)
		c=bot_channel_fixture(t)
		_,_=iface.experiment_set(&c.f.experiments,{owner_user_id=string(c.f.wire.owner),key="bots",enabled=false})
		resp=bot_media_http_route(c,handler,`{}`)
		testing.expect(t,resp.status==403 && strings.contains(resp.body,"experimental_feature_disabled"))
		testing.expect_value(t,handler(&c.h,{method="POST",body="{}"}).status,401)
		bot_channel_destroy(c)
	}
	c:=bot_channel_fixture(t);defer bot_channel_destroy(c);bot_media_http_inbound(t,c)
	testing.expect(t,sqlite.exec(&c.f.wire.conn,"UPDATE channel_bindings SET owner_user_id='foreign';"))
	resp:=bot_media_http_route(c,bot_agent_media_fetch_handler,`{"attachment_id":"cha_media"}`)
	// The common auth gate can reject before attachment ownership validation.
	testing.expect(t,resp.status==409 || resp.status==404)
}
@(test)
test_media_stored_route_checks_artifact_owner :: proc(t: ^testing.T) {
	context.allocator=context.temp_allocator
	c:=bot_channel_fixture(t);defer bot_channel_destroy(c);bot_media_http_inbound(t,c)
	bot_media_http_artifact(t,c,"art_own",string(c.f.wire.owner))
	bot_media_http_artifact(t,c,"art_foreign","foreign")
	bot_media_http_artifact(t,c,"art_deleted",string(c.f.wire.owner),"gone")
	for id in ([]string{"art_foreign","art_deleted","art_missing"}) {
		body:=strings.concatenate({`{"attachment_id":"cha_media","artifact_id":"`,id,`"}`},context.temp_allocator)
		r:=bot_media_http_route(c,bot_agent_media_stored_handler,body)
		testing.expectf(t,r.status==404 && strings.contains(r.body,"artifact_not_found"),"%s",r.body)
	}
	r:=bot_media_http_route(c,bot_agent_media_stored_handler,`{"attachment_id":"cha_media","artifact_id":"art_own"}`)
	testing.expectf(t,r.status==200 && strings.contains(r.body,`"artifact_id":"art_own"`),"%s",r.body)
}
@(test)
test_media_plan_route :: proc(t: ^testing.T) {
	context.allocator=context.temp_allocator
	c:=bot_channel_fixture(t);defer bot_channel_destroy(c);bot_media_http_setup(t,c)
	r:=bot_media_http_route(c,bot_agent_media_plan_handler,`{"mime":"application/pdf","size":3}`)
	testing.expectf(t,r.status==200 && strings.contains(r.body,`"mode":"native"`) && strings.contains(r.body,`"kind":"document"`),"%s",r.body)
	c.adapter.send_media=nil
	r=bot_media_http_route(c,bot_agent_media_plan_handler,`{"mime":"application/pdf","size":3}`)
	testing.expect(t,r.status==200 && strings.contains(r.body,`"mode":"link"`) && strings.contains(r.body,"no_native_media"))
	for body in ([]string{`{"mime":"image/png","size":0}`,`{"mime":"image/png","size":15728641}`,`{"mime":"image/png","size":1.5}`,`{"mime":"image/png","size":"3"}`,`{"mime":3,"size":3}`}) {
		r=bot_media_http_route(c,bot_agent_media_plan_handler,body);testing.expect(t,r.status==400 && strings.contains(r.body,"media_invalid"))
	}
}
@(test)
test_channel_send_media_validation :: proc(t: ^testing.T) {
	context.allocator=context.temp_allocator
	c:=bot_channel_fixture(t);defer bot_channel_destroy(c)
	for test in ([]struct{params,code:string}{
		{`{"text":"a","media":{}}`,"media_invalid"},
		{`{"artifact_id":1}`,"media_invalid"},
		{`{"artifact_id":""}`,"media_invalid"},
		{`{"artifact_id":"art/bad"}`,"media_invalid"},
		{`{"artifact_id":"art_ok","text":1}`,"text_invalid"},
		{strings.concatenate({`{"artifact_id":"art_ok","text":"`,strings.repeat("x",16385,context.temp_allocator),`"}`},context.temp_allocator),"text_invalid"},
		{`{"artifact_id":"art_ok"}`,"media_invalid"},
		{`{"artifact_id":"art_ok","media":[]}`,"media_invalid"},
		{`{"artifact_id":"art_ok","media":{"name":1,"mime":"image/png","size":1}}`,"media_invalid"},
		{`{"artifact_id":"art_ok","media":{"name":"a","mime":1,"size":1}}`,"media_invalid"},
		{`{"artifact_id":"art_ok","media":{"name":"a","mime":"image/png","size":0}}`,"media_invalid"},
		{`{"artifact_id":"art_ok","media":{"name":"a","mime":"image/png","size":15728641}}`,"media_invalid"},
		{`{"artifact_id":"art_ok","media":{"name":"a","mime":"image/png","size":1.5}}`,"media_invalid"},
		{`{"artifact_id":"art_ok","media":{"name":"a","mime":"image/png","size":1,"content_base64":1}}`,"media_invalid"},
		{`{"artifact_id":"art_ok","media":{"name":"a","mime":"image/png","size":1,"content_base64":"!!!="}}`,"media_invalid"},
		{`{"artifact_id":"art_ok","media":{"name":"a","mime":"image/png","size":1,"content_base64":"YWJj"}}`,"media_invalid"},
	}) {
		r:=bot_channel_send(c,strings.concatenate({`{"params":`,test.params,"}"},context.temp_allocator))
		testing.expectf(t,r.status==400 && strings.contains(r.body,test.code),"%s => %s",test.params,r.body)
	}
	r:=bot_channel_send(c,`{"params":{"artifact_id":"art_missing","media":{"name":"a","mime":"image/png","size":3}}}`)
	testing.expect(t,r.status==404 && strings.contains(r.body,"artifact_not_found"))
	testing.expect_value(t,len(c.sent),0)
}
@(test)
test_channel_send_media_response_sent_as :: proc(t: ^testing.T) {
	context.allocator=context.temp_allocator
	c:=bot_channel_fixture(t);defer bot_channel_destroy(c);bot_media_http_setup(t,c)
	bot_media_http_artifact(t,c,"art_ok",string(c.f.wire.owner))
	body:=`{"params":{"artifact_id":"art_ok","text":"caption","media":{"name":"a.pdf","mime":"application/pdf","size":3,"content_base64":"YWJj"}}}`
	r:=bot_channel_send(c,body)
	testing.expectf(t,r.status==200 && strings.contains(r.body,`"sent_as":"native"`) && !strings.contains(r.body,"unsent_chunks"),"%s",r.body)
	c.adapter.send_media=bot_media_http_slow_send;c.adapter.media.send_rules[0].caption=false
	c.f.service.media_send_budget_ms=600;c.f.service.media_min_call_ms=50
	r=bot_channel_send(c,body)
	testing.expectf(t,r.status==200 && strings.contains(r.body,`"sent_as":"native"`) && strings.contains(r.body,`"unsent_chunks":1`),"%s",r.body)
	c.adapter.send_media=nil
	r=bot_channel_send(c,`{"params":{"artifact_id":"art_ok","media":{"name":"a.pdf","mime":"application/pdf","size":3}}}`)
	testing.expectf(t,r.status==200 && strings.contains(r.body,`"sent_as":"link"`),"%s",r.body)
}
@(test)
test_channel_require_returns_auth :: proc(t: ^testing.T) {
	context.allocator=context.temp_allocator
	c:=bot_channel_fixture(t);defer bot_channel_destroy(c)
	bot,auth,ok,_:=bot_channel_require(&c.h,bot_channel_req(c,"read","{}"))
	defer domain.bot_destroy(&bot)
	testing.expect(t,ok && auth.user_id==string(c.f.wire.owner))
}
@(test)
test_channel_send_text_response_unchanged :: proc(t: ^testing.T) {
	context.allocator=context.temp_allocator
	c:=bot_channel_fixture(t);defer bot_channel_destroy(c)
	r:=bot_channel_send(c)
	testing.expect(t,r.status==200 && !strings.contains(r.body,"sent_as") && !strings.contains(r.body,"unsent_chunks"))
}


@(test)
test_channel_web_action_refs_route_and_persist :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := bot_channel_fixture(t)
	defer bot_channel_destroy(c)
	card_impl: sqlite.Card_Repo_SQLite
	card_repo := sqlite.new_card_repository(&card_impl, &c.f.wire.conn)
	cards := card_service.Card_Service{cards = &card_repo}
	c.f.wire.ah.cards = &cards
	c.f.handlers.cards = &card_repo
	for row in ([]domain.Card{
		{card_id = "crd_own", owner_user_id = c.f.wire.owner, title = "Review", status = "pending"},
		{card_id = "crd_foreign", owner_user_id = "other", title = "Private", status = "pending"},
	}) {
		_, saved, err := iface.card_create(&card_repo, row)
		testing.expectf(t, saved && err.code == .None, "%v", err)
	}
	action_reply := `{"params":{"text":"answer","action_ids":["crd_own"]}}`
	bot_channel_inbound(t, c, "chm_telegram")
	testing.expect_value(t, bot_channel_read(c).status, 200)
	// Telegram wins normal reply routing. No text or action data leaks into it.
	testing.expect_value(t, bot_channel_send(c, action_reply).status, 409)
	testing.expect_value(t, len(c.sent), 0)
	testing.expect_value(t, bot_channel_send(c).status, 200)
	testing.expect_value(t, len(c.sent), 1)

	inbound, _, err := bots.bots_web_send(&c.f.service, string(c.f.wire.owner), "web question", "web-action-key")
	defer domain.channel_message_destroy(&inbound)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, bot_channel_read(c).status, 200)
	for id in ([]string{"crd_foreign", "crd_missing"}) {
		body := fmt.tprintf(`{{"params":{{"text":"answer","action_ids":["%s"]}}}}`, id)
		testing.expect_value(t, bot_channel_send(c, body).status, 404)
	}
	testing.expect_value(t, bot_channel_send(c, `{"params":{"text":"answer","action_ids":["crd_own","crd_own"]}}`).status, 400)
	sent := bot_channel_send(c, action_reply)
	testing.expectf(t, sent.status == 200, "%s", sent.body)
	testing.expect(t, strings.contains(sent.body, `"channel":"web"`))
	testing.expect_value(t, len(c.sent), 1)

	request := bot_http_request(c.f, "GET", "/api/v1/bots/me/messages", "")
	page := bot_unified_messages_handler(&c.f.handlers, request)
	testing.expectf(t, page.status == 200, "%s", page.body)
	wire: struct {data: struct {messages: []Bot_History_Message}}
	testing.expect_value(t, json.unmarshal(transmute([]u8)page.body, &wire), nil)
	metadata_rows := 0
	for row in wire.data.messages {
		ids, has_ids := row.metadata["action_ids"].(json.Array)
		if !has_ids do continue
		metadata_rows += 1
		testing.expect_value(t, row.provider, "web")
		testing.expect_value(t, row.binding_id, inbound.binding_id)
		testing.expect_value(t, row.direction, "outbound")
		testing.expect_value(t, len(ids), 1)
		if len(ids) == 1 do testing.expect_value(t, string(ids[0].(json.String)), "crd_own")
	}
	testing.expect_value(t, metadata_rows, 1)
	_, deleted_err := iface.card_delete(&card_repo, "crd_own")
	testing.expect_value(t, deleted_err.code, domain.Error_Code.None)
	page = bot_unified_messages_handler(&c.f.handlers, request)
	testing.expect_value(t, page.status, 200)
	testing.expect(t, !strings.contains(page.body, `"metadata"`))
	testing.expect_value(t, iface.messages_purge_binding(&c.f.bot_repo, inbound.binding_id).code, domain.Error_Code.None)
	rows, list_err := iface.messages_page(&c.f.bot_repo, string(c.f.wire.owner), inbound.bot_id, "", 10)
	defer {for &row in rows do domain.channel_message_destroy(&row); delete(rows)}
	testing.expect_value(t, list_err.code, domain.Error_Code.None)
	for row in rows do testing.expect_value(t, row.action_ids_json, "")
}

@(test)
test_legacy_channel_http_refused_after_fresh_web_cutover :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := bot_channel_fixture(t)
	defer bot_channel_destroy(c)
	f := c.f
	owner := string(f.wire.owner)
	bot, found, lookup_err := iface.bot_get_by_owner(&f.bot_repo, owner)
	defer domain.bot_destroy(&bot)
	if !testing.expect(t, found && lookup_err.code == .None) do return

	old_message :: "old_private_channel_message"
	bot_channel_inbound(t, c, old_message)
	held_text :: "old_private_held_reply"
	testing.expect_value(t, iface.pairing_insert(&f.bot_repo, {
		code_hash = "wa_legacy", owner_user_id = owner, bot_id = bot.bot_id, provider = "whatsapp", expires_at = "9999",
	}).code, domain.Error_Code.None)
	previous, _, pair_err := iface.binding_activate(&f.bot_repo, {
		binding_id = "chb_old_wa", owner_user_id = owner, bot_id = bot.bot_id,
		provider = "whatsapp", external_chat_id = "15550100123", external_user_id = "15550100123", state = .Active,
	}, "wa_legacy", "2026-11-17T12:00:00Z")
	defer domain.channel_binding_destroy(&previous)
	if !testing.expect_value(t, pair_err.code, domain.Error_Code.None) do return
	testing.expect_value(t, iface.message_insert_outbound(&f.bot_repo, {
		message_id = "chm_old_held", binding_id = "chb_old_wa", owner_user_id = owner, bot_id = bot.bot_id,
		direction = .Outbound, send_state = .Held, body = held_text, created_at = "now",
	}).code, domain.Error_Code.None)
	me := bot_http_request(f, "GET", "/api/v1/bots/me", "")
	before := bot_me_handler(&f.handlers, me)
	testing.expect(t, before.status == 200 && strings.contains(before.body, held_text), before.body)
	unified := bot_http_request(f, "GET", "/api/v1/bots/me/messages", "")
	telegram := bot_http_request(f, "GET", "/api/v1/bots/me/channels/telegram/messages", "")
	agent_history := bot_channel_req(c, "history", `{"params":{}}`)
	for response in ([]Response{
		bot_unified_messages_handler(&f.handlers, unified),
		bot_messages_handler(&f.handlers, telegram),
		bot_agent_channel_history_handler(&c.h, agent_history),
	}) {
		testing.expect(t, response.status == 200 && strings.contains(response.body, old_message), response.body)
	}

	// The fresh identity has a different instance id. Reuse exactly the old
	// authenticated requests below, including their still-valid instance token.
	state := domain.Bot_Web_Activation{
		owner_user_id = owner, bot_id = bot.bot_id, agent_instance_id = "inst_fresh",
		conversation_id = "chat_fresh", enabled = true, generation = 1,
	}
	if !testing.expect_value(t, iface.bot_web_activation_insert(&f.bot_repo, state).code, domain.Error_Code.None) do return
	for generation in 1..=3 {
		after := bot_me_handler(&f.handlers, me)
		testing.expect(t, after.status == 200 && !strings.contains(after.body, held_text), after.body)
		testing.expect(t, !strings.contains(after.body, f.wire.instance_id), after.body)
		for response in ([]Response{
			bot_unified_messages_handler(&f.handlers, unified),
			bot_messages_handler(&f.handlers, telegram),
			bot_agent_channel_history_handler(&c.h, agent_history),
			bot_channel_read(c),
			bot_channel_send(c),
			bot_web_messages_handler(&f.handlers, bot_http_request(f, "POST", "/api/v1/bots/me/messages",
				`{"text":"stale web text","idempotency_key":"legacy-http-key"}`)),
		}) {
			testing.expect(t, response.status == 409 && strings.contains(response.body, "bot_generation_inactive"), response.body)
			testing.expect(t, !strings.contains(response.body, old_message), response.body)
		}
		if generation < 3 {
			changed, err := iface.bot_web_activation_set_enabled(&f.bot_repo, owner, generation == 2, i64(generation))
			testing.expect(t, changed && err.code == .None)
		}
	}
	testing.expect_value(t, len(c.sent), 0)
	rows, history_err := iface.messages_history(&f.bot_repo, bot.bot_id, -1)
	defer {for &row in rows do domain.channel_message_destroy(&row); delete(rows)}
	if !testing.expect(t, history_err.code == .None && len(rows) == 2) do return
	inbound, held := rows[0], rows[1]
	if inbound.message_id != old_message do inbound, held = held, inbound
	testing.expect_value(t, inbound.body, old_message)
	testing.expect_value(t, inbound.read_at, "")
	testing.expect_value(t, inbound.replied_at, "")
	testing.expect_value(t, held.body, held_text)
	testing.expect_value(t, held.send_state, domain.Channel_Send_State.Held)
}
