package http

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:time"
import "core:testing"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import events "odin_test:hub/service/events"

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
	// ID lookups share history ownership and never page into neighboring rows.
	by_id := bot_http_request(f, "GET", "/api/v1/bots/me/messages", "")
	by_id.query = "message_ids=%5B%22web-inbound%22%2C%22other-owner%22%2C%22missing%22%5D"
	selected := bot_unified_messages_handler(&f.handlers, by_id)
	targeted: struct {data: struct {messages: []Bot_History_Message, next_cursor: string}}
	_ = json.unmarshal(transmute([]u8)selected.body, &targeted, allocator = context.temp_allocator)
	testing.expect(t, selected.status == 200 && targeted.data.next_cursor == "")
	if testing.expect_value(t, len(targeted.data.messages), 1) {
		testing.expect_value(t, targeted.data.messages[0].message_id, "web-inbound")
	}
	for query in ([]string{"message_ids=", "message_ids=%5B1%5D", "message_ids=%5B%22web-inbound%22%5D&cursor=web-outbound"}) {
		by_id.query = query
		testing.expect_value(t, bot_unified_messages_handler(&f.handlers, by_id).status, 400)
	}
	// No messages is a normal terminal page.
	testing.expect(t, sqlite.exec(&f.wire.conn, "DELETE FROM channel_messages;"))
	empty := bot_unified_messages_handler(&f.handlers, bot_http_request(f, "GET", "/api/v1/bots/me/messages", ""))
	testing.expect(t, empty.status == 200 && strings.contains(empty.body, `"next_cursor":""`))
}

@(test)
test_web_artifacts_validation_atomicity_history_and_agent_read :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := bot_channel_fixture(t, paired = false); defer bot_channel_destroy(c)
	f := c.f
	bot_media_http_artifact(t,c,"art_first",string(f.wire.owner))
	bot_media_http_artifact(t,c,"art_second",string(f.wire.owner))
	bot_media_http_artifact(t,c,"art_foreign","foreign")
	bot_media_http_artifact(t,c,"art_deleted",string(f.wire.owner),"gone")
	path := "/api/v1/bots/me/channels/web/messages"
	for tc in ([]struct {ids: string, status: int}{
		{`null`,400},{`{}`,400},{`[1]`,400},{`[""]`,400},{`["art_first","art_first"]`,400},
		{`["art_foreign"]`,404},{`["art_missing"]`,404},{`["art_deleted"]`,404},
		{`["art_first","art_foreign"]`,404},
	}) {
		body := strings.concatenate({`{"text":"","idempotency_key":"invalid","artifact_ids":`,tc.ids,"}"},context.temp_allocator)
		r := bot_web_messages_handler(&f.handlers,bot_http_request(f,"POST",path,body))
		testing.expectf(t,r.status==tc.status,"%s: %d %s",body,r.status,r.body)
	}
	many := make([]string,21,context.temp_allocator)
	for &id in many do id="art_first"
	encoded,_ := json.marshal(many,allocator=context.temp_allocator)
	bad := strings.concatenate({`{"text":"","idempotency_key":"many","artifact_ids":`,string(encoded),"}"},context.temp_allocator)
	testing.expect_value(t,bot_web_messages_handler(&f.handlers,bot_http_request(f,"POST",path,bad)).status,400)
	body := `{"text":"","idempotency_key":"upload","artifact_ids":["art_first","art_second"]}`
	// Attachment write failure rolls back the message and on-demand binding.
	testing.expect(t,sqlite.exec(&f.wire.conn,"CREATE TRIGGER reject_upload BEFORE INSERT ON channel_attachments BEGIN SELECT RAISE(ABORT,'injected'); END;"))
	rejected := bot_web_messages_handler(&f.handlers,bot_http_request(f,"POST",path,body))
	testing.expect(t,rejected.status>=400)
	b,found,_ := iface.binding_get_active_by_owner(&f.bot_repo,string(f.wire.owner),"web")
	defer domain.channel_binding_destroy(&b)
	testing.expect(t,!found)
	testing.expect(t,sqlite.exec(&f.wire.conn,"DROP TRIGGER reject_upload;"))
	first := bot_web_messages_handler(&f.handlers,bot_http_request(f,"POST",path,body))
	testing.expectf(t,first.status==201,"%s",first.body)
	testing.expect_value(t,bot_web_messages_handler(&f.handlers,bot_http_request(f,"POST",path,body)).status,200)
	conflict := `{"text":"","idempotency_key":"upload","artifact_ids":["art_second","art_first"]}`
	testing.expect_value(t,bot_web_messages_handler(&f.handlers,bot_http_request(f,"POST",path,conflict)).status,409)
	// A text-only body equal to the attachment payload encoding is still a conflict.
	encoded_payload,_ := json.marshal([]string{"","art_first","art_second"},allocator=context.temp_allocator)
	collision,_ := json.marshal(struct {text,idempotency_key: string}{string(encoded_payload),"upload"},allocator=context.temp_allocator)
	testing.expect_value(t,bot_web_messages_handler(&f.handlers,bot_http_request(f,"POST",path,string(collision))).status,409)
	history := bot_unified_messages_handler(&f.handlers,bot_http_request(f,"GET","/api/v1/bots/me/messages",""))
	wire: struct {data: struct {messages: []Bot_History_Message}}
	_ = json.unmarshal(transmute([]byte)history.body,&wire,allocator=context.temp_allocator)
	testing.expect(t,history.status==200 && len(wire.data.messages)==1)
	if len(wire.data.messages)!=1 do return
	m := wire.data.messages[0]
	testing.expect(t,m.provider=="web" && m.body=="" && len(m.attachments)==2)
	for a in m.attachments do testing.expect(t,a.state=="stored" && a.artifact_id!="" && a.name=="file" && a.size==6)
	// Subscribe after intake so the only possible event is a read receipt.
	bus := new(events.User_Event_Bus)
	f.service.event_bus = bus
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if !testing.expect(t, listen_err == nil) do return
	defer net.close(listener)
	bound, bound_err := net.bound_endpoint(listener)
	if !testing.expect(t, bound_err == nil) do return
	peer, dial_err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if !testing.expect(t, dial_err == nil) do return
	defer net.close(peer)
	socket, _, accept_err := net.accept_tcp(listener)
	if !testing.expect(t, accept_err == nil) do return
	defer net.close(socket)
	_ = net.set_option(peer, .Receive_Timeout, time.Second)
	owner_slot := events.user_ws_add(bus, string(f.wire.owner), socket)
	defer events.user_ws_remove(bus, owner_slot)
	other_slot := events.user_ws_add(bus, "foreign", socket)
	defer events.user_ws_remove(bus, other_slot)

	// The failed write transaction must leave the row unread and publish nothing.
	testing.expect(t, sqlite.exec(&f.wire.conn, `CREATE TRIGGER reject_read BEFORE UPDATE OF read_at ON channel_messages BEGIN SELECT RAISE(ABORT,'injected'); END;`))
	testing.expect(t, bot_channel_read(c).status >= 400)
	testing.expect_value(t, bus.stream_seqs[owner_slot], u64(0))
	testing.expect(t, sqlite.exec(&f.wire.conn, "DROP TRIGGER reject_read;"))

	// The write commits even though the read handler later fails to load attachments.
	attachments_for_messages := f.bot_repo.attachments_for_messages
	f.bot_repo.attachments_for_messages = proc(_: rawptr, _: []string) -> ([]domain.Channel_Attachment, domain.Domain_Error) {
		return nil, domain.domain_error(.Internal_Error, "injected attachment lookup failure")
	}
	testing.expect(t, bot_channel_read(c).status >= 500)
	f.bot_repo.attachments_for_messages = attachments_for_messages
	buffer: [2048]byte
	n, recv_err := net.recv_tcp(peer, buffer[:])
	testing.expect(t, recv_err == nil && n > 0 && strings.contains(string(buffer[:n]), "bot_changed"))
	testing.expect_value(t, bus.stream_seqs[owner_slot], u64(1))
	testing.expect_value(t, bus.stream_seqs[other_slot], u64(0))

	history = bot_unified_messages_handler(&f.handlers, bot_http_request(f, "GET", "/api/v1/bots/me/messages", ""))
	_ = json.unmarshal(transmute([]byte)history.body, &wire, allocator = context.temp_allocator)
	if !testing.expect(t, history.status == 200 && len(wire.data.messages) == 1) do return
	receipt := wire.data.messages[0].read_at
	testing.expect(t, receipt != "" && wire.data.messages[0].replied_at == "")

	read := bot_channel_read(c)
	testing.expectf(t,read.status==200 && strings.contains(read.body,"art_first") && strings.contains(read.body,"art_second"),"%s",read.body)
	testing.expect_value(t, bus.stream_seqs[owner_slot], u64(1))
	history = bot_unified_messages_handler(&f.handlers, bot_http_request(f, "GET", "/api/v1/bots/me/messages", ""))
	_ = json.unmarshal(transmute([]byte)history.body, &wire, allocator = context.temp_allocator)
	if !testing.expect(t, history.status == 200 && len(wire.data.messages) == 1) do return
	testing.expect_value(t, wire.data.messages[0].read_at, receipt)
	agent_history := bot_agent_channel_history_handler(&c.h,bot_channel_req(c,"history",`{"params":{}}`))
	testing.expect(t,agent_history.status==200 && strings.contains(agent_history.body,"art_first"))
	// Normal agent artifact fetch can retrieve the attached bytes.
	fetch_req := wire_agent_request(f.wire,"artifact_content",`{"params":{"artifact_id":"art_first"}}`)
	fetched := agent_action_artifact_content_handler(&f.wire.ah,fetch_req)
	testing.expectf(t,fetched.status==200 && strings.contains(fetched.body,"sealed"),"%s",fetched.body)
	testing.expect_value(t,iface.messages_purge_binding(&f.bot_repo,m.binding_id).code,domain.Error_Code.None)
	purged := bot_unified_messages_handler(&f.handlers,bot_http_request(f,"GET","/api/v1/bots/me/messages",""))
	testing.expect(t,purged.status==200 && !strings.contains(purged.body,"art_first"))
	testing.expect_value(t, bot_channel_read(c).status, 200)
	testing.expect_value(t, bus.stream_seqs[owner_slot], u64(1))
}


@(test)
test_bot_runtime_identity_requires_current_owned_agent :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := bot_http_fixture(t)
	defer bot_http_destroy(f)
	bot := bot_http_create(t, f)
	defer domain.bot_destroy(&bot)
	id := f.wire.instance_id
	testing.expect_value(t, iface.bot_set_instance(&f.bot_repo, bot.bot_id, id, "now").code, domain.Error_Code.None)
	req := bot_http_request(f, "GET", "/api/v1/bots/me", "")
	before := bot_me_handler(&f.handlers, req)
	testing.expect_value(t, before.status, 200)
	testing.expect(t, !strings.contains(before.body, id))
	testing.expect(t, sqlite.exec(&f.wire.conn, fmt.tprintf("UPDATE agent_instances SET agent_id = '%s', conversation_id = 'chat_bot_runtime' WHERE agent_instance_id = '%s';", bot.agent_id, id)))
	after := bot_me_handler(&f.handlers, req)
	testing.expect_value(t, after.status, 200)
	testing.expect(t, strings.contains(after.body, id) && strings.contains(after.body, `"conversation_id":"chat_bot_runtime"`))
	_, saved, err := iface.agent_save_instance(&f.wire.ag_repo, {
		agent_instance_id = "inst_foreign_bot", owner_user_id = "wire_foreign_owner",
		agent_id = bot.agent_id, bridge_id = f.wire.bridge_foreign, conversation_id = "chat_foreign_bot",
		runtime_status = "running", created_at = "now", updated_at = "now",
	})
	testing.expectf(t, saved && err.code == .None, "%v", err)
	testing.expect_value(t, iface.bot_set_instance(&f.bot_repo, bot.bot_id, "inst_foreign_bot", "now").code, domain.Error_Code.None)
	foreign_response := bot_me_handler(&f.handlers, req)
	testing.expect_value(t, foreign_response.status, 200)
	testing.expect(t, !strings.contains(foreign_response.body, "inst_foreign_bot") && !strings.contains(foreign_response.body, "chat_foreign_bot"))
}
