package http

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Reply origin (R7) over the agent-action HTTP API: which reads and deliveries
// count as consumption, and the reply's metadata.reply_origin in the
// send-to-user response and the user's message list.

ro_agent_req :: proc(f: ^ACP_Chat_Fixture, path, params: string) -> Request {
	req := mq_http_req(f.mq.base, path, fmt.tprintf(`{{"agent_instance_id":"inst_mq","params":%s}}`, params))
	headers := make([]contracts.HTTP_Header, 2, context.temp_allocator) // outlives this frame
	headers[0] = {name = "Authorization", value = fmt.tprintf("Bearer %s", f.mq.base.bridge_token)}
	headers[1] = {name = "X-Heimdall-Instance-Token", value = "hit_inst_mq~epoch"}
	req.headers = headers
	return req
}

ro_read :: proc(t: ^testing.T, f: ^ACP_Chat_Fixture, params: string, loc := #caller_location) {
	r := agent_action_chat_read_handler(&f.mq.agent_handlers, ro_agent_req(f, "/api/v1/agent-actions/chat/read", params))
	testing.expect(t, r.status == 200, r.body, loc = loc)
}

Ro_Reply :: struct { data: struct { message_id: string, metadata: struct { reply_origin: domain.Reply_Origin } } }

ro_reply :: proc(t: ^testing.T, f: ^ACP_Chat_Fixture, reply_to := "", loc := #caller_location) -> (Response, domain.Reply_Origin) {
	params := `{"body":"reply"}` if reply_to == "" else fmt.tprintf(`{{"body":"reply","reply_to":"%s"}}`, reply_to)
	r := agent_action_chat_send_to_user_handler(&f.mq.agent_handlers, ro_agent_req(f, "/api/v1/agent-actions/chat/send-to-user", params))
	parsed: Ro_Reply
	if r.status == 201 do testing.expect(t, json.unmarshal_string(r.body, &parsed, allocator = context.temp_allocator) == nil, r.body, loc = loc)
	return r, parsed.data.metadata.reply_origin
}

ro_pty :: proc(f: ^ACP_Chat_Fixture) {
	inst, _, _ := iface.agent_get_instance(&f.mq.base.ag_repo, "inst_mq")
	inst.runtime_transport = "pty"; inst.run_count += 1
	_, _, _ = iface.agent_save_instance(&f.mq.base.ag_repo, inst)
}

ro_expect_ids :: proc(t: ^testing.T, got: domain.Reply_Origin, want: ..string, loc := #caller_location) {
	if !testing.expect_value(t, len(got.answered_message_ids), len(want), loc) do return
	for id, i in want do testing.expect_value(t, got.answered_message_ids[i], id, loc)
}

// Edge case 5 (PTY): include-read, transcript and mark_read=false reads are
// not consumption; the agent's own marking read is.
@(test)
test_reply_origin_http_pty_only_marking_unread_read_consumes :: proc(t: ^testing.T) {
	arena := ad_arena(); defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
	f: ACP_Chat_Fixture; ad_open(t, &f); defer mq_http_base_close(f.mq.base)
	ro_pty(&f)
	id := ad_send(t, &f, "question")
	ro_read(t, &f, `{"unread_only":true,"mark_read":false}`)                 // chat fetch
	ro_read(t, &f, `{"unread_only":false,"mark_read":true}`)                 // --include-read
	ro_read(t, &f, `{"unread_only":false,"receiver_only":false,"include_outgoing":true,"mark_read":false}`) // --transcript
	r, got := ro_reply(t, &f)
	testing.expect(t, r.status == 201, r.body)
	testing.expect_value(t, len(got.answered_message_ids), 0)
	testing.expect_value(t, got.route_status, domain.REPLY_ROUTE_NONE)
	// --include-read marked the row read, so it is no longer unread: a fresh
	// input shows the plain `chat read` path.
	id2 := ad_send(t, &f, "second")
	ro_read(t, &f, `{"unread_only":true,"mark_read":true}`)
	r, got = ro_reply(t, &f)
	testing.expect(t, r.status == 201, r.body)
	ro_expect_ids(t, got, id2)
	testing.expect_value(t, got.origin, domain.REPLY_ORIGIN_LOCAL)
	testing.expect_value(t, got.route_status, domain.REPLY_ROUTE_ROUTED)
	_ = id
	// The user's message list exposes the same metadata.
	list := list_chat_messages_handler(&f.mq.handlers, mq_http_req(f.mq.base, "/api/v1/chats/chat_mq/messages", ""))
	testing.expect(t, strings.contains(list.body, `"reply_origin":{"answered_message_ids":["`), list.body)
}

// ACP: bridge admission ack is not consumption; inline delivery is.
@(test)
test_reply_origin_http_acp_delivery_consumes_admission_does_not :: proc(t: ^testing.T) {
	arena := ad_arena(); defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
	f: ACP_Chat_Fixture; ad_open(t, &f); defer mq_http_base_close(f.mq.base)
	id := ad_send(t, &f, "hello")
	ro_read(t, &f, fmt.tprintf(`{{"ack_message_ids":["%s"]}}`, id))
	r := ad_queued(&f, 1, id); testing.expect(t, r.status == 200, r.body)
	_, before := ro_reply(t, &f)
	testing.expect_value(t, len(before.answered_message_ids), 0)
	r = ad_report(&f, {launch_epoch = "epoch", report_seq = 2, inputs = {{message_id = id, state = "delivered", mode = "prompt", turn_id = "ham:epoch:1"}}})
	testing.expect(t, r.status == 200, r.body)
	_, after := ro_reply(t, &f)
	ro_expect_ids(t, after, id)
	testing.expect_value(t, after.source, domain.REPLY_SOURCE_CONSUMED)
	// ACP agent's own `chat read` also consumes an input that never reached a turn.
	held := ad_send(t, &f, "held")
	ro_read(t, &f, `{"unread_only":true,"mark_read":true}`)
	_, read := ro_reply(t, &f)
	ro_expect_ids(t, read, held)
}

// Edge case 6 over HTTP: --reply-to accepted, and rejected with a clear error.
@(test)
test_reply_origin_http_reply_to :: proc(t: ^testing.T) {
	arena := ad_arena(); defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
	f: ACP_Chat_Fixture; ad_open(t, &f); defer mq_http_base_close(f.mq.base)
	ro_pty(&f)
	id := ad_send(t, &f, "question")
	r, got := ro_reply(t, &f, reply_to = id)
	testing.expect(t, r.status == 201, r.body)
	ro_expect_ids(t, got, id)
	testing.expect_value(t, got.route_status, domain.REPLY_ROUTE_EXPLICIT)
	reply_id := jsonx_reply_id(r.body)
	r, _ = ro_reply(t, &f, reply_to = reply_id)
	testing.expect(t, r.status == 400 && strings.contains(r.body, "reply-to must name a message the user sent to this agent"), r.body)
	r, _ = ro_reply(t, &f, reply_to = "msg_nope")
	testing.expect(t, r.status == 404 && strings.contains(r.body, "reply-to message not found"), r.body)
	_, saved, _ := iface.content_save_message(&f.mq.repo, domain.Chat_Message{message_id = "msg_elsewhere", conversation_id = "chat_other", owner_user_id = domain.User_ID(f.mq.base.owner_user_id), direction = "user_to_agent", body = "x", artifact_ids_json = "[]", message_type = "text", created_at = "2026-10-22T10:00:00Z"})
	testing.expect(t, saved)
	r, _ = ro_reply(t, &f, reply_to = "msg_elsewhere")
	testing.expect(t, r.status == 400 && strings.contains(r.body, "reply-to message belongs to another conversation"), r.body)
}

jsonx_reply_id :: proc(body: string) -> string {
	parsed: Ro_Reply
	_ = json.unmarshal_string(body, &parsed, allocator = context.temp_allocator)
	return parsed.data.message_id
}
