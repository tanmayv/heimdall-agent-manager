package http

import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import iface "odin_test:hub/repository/iface"

// The bridge's agent_notice_typed report moves the conversation's message
// high-water mark, exposed by GET send-now; owner-bridge only and monotonic.

an_field :: proc(t: ^testing.T, body, field: string) -> string {
	key := fmt.tprintf(`"%s":"`, field)
	i := strings.index(body, key)
	if !testing.expect(t, i >= 0, body) do return "<missing>"
	rest := body[i+len(key):]
	return rest[:strings.index_byte(rest, '"')]
}

an_through :: proc(t: ^testing.T, f: ^ACP_Chat_Fixture) -> (string, string) {
	g := get_send_now_handler(&f.mq.handlers, mq_http_req(f.mq.base, "/api/v1/chats/chat_mq/send-now", ""))
	testing.expect(t, g.status == 200, g.body)
	return an_field(t, g.body, contracts.SEND_NOW_NOTIFIED_THROUGH_MESSAGE_ID_FIELD), an_field(t, g.body, contracts.SEND_NOW_NOTIFIED_THROUGH_CREATED_AT_FIELD)
}

an_frame :: proc(instance, message_id: string) -> string {
	return fmt.tprintf(`{{"type":"%s","agent_instance_id":"%s","last_message_id":"%s"}}`, contracts.AGENT_NOTICE_TYPED_FRAME, instance, message_id)
}

@(test)
test_agent_notice_typed_moves_the_high_water_mark_and_is_exposed :: proc(t: ^testing.T) {
	arena := ad_arena(); defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
	f: ACP_Chat_Fixture; ad_open(t, &f); defer mq_http_base_close(f.mq.base)
	h := Bridge_Handlers{content = &f.mq.svc}
	id, at := an_through(t, &f)
	testing.expect_value(t, id, "") // never notified
	testing.expect_value(t, at, "")
	a := ad_send(t, &f, "a")
	b := ad_send(t, &f, "b")
	bridge_ws_agent_notice_typed(&h, f.mq.base.bridge_id, an_frame("inst_mq", a))
	id, at = an_through(t, &f)
	testing.expect_value(t, id, a)
	m, _, _ := iface.content_get_message(&f.mq.repo, a)
	testing.expect_value(t, at, m.created_at)
	bridge_ws_agent_notice_typed(&h, f.mq.base.bridge_id, an_frame("inst_mq", b))
	id, _ = an_through(t, &f)
	testing.expect_value(t, id, b)
	// Idempotent, and an earlier message never moves it back.
	bridge_ws_agent_notice_typed(&h, f.mq.base.bridge_id, an_frame("inst_mq", b))
	bridge_ws_agent_notice_typed(&h, f.mq.base.bridge_id, an_frame("inst_mq", a))
	id, _ = an_through(t, &f)
	testing.expect_value(t, id, b)
	// Another bridge, unknown ids and junk frames are dropped.
	c := ad_send(t, &f, "c")
	bridge_ws_agent_notice_typed(&h, "brg_other", an_frame("inst_mq", c))
	bridge_ws_agent_notice_typed(&h, f.mq.base.bridge_id, an_frame("inst_mq", "msg_unknown"))
	bridge_ws_agent_notice_typed(&h, f.mq.base.bridge_id, an_frame("inst_unknown", c))
	bridge_ws_agent_notice_typed(&h, f.mq.base.bridge_id, `{"type":"agent_notice_typed","agent_instance_id":`)
	id, _ = an_through(t, &f)
	testing.expect_value(t, id, b)
}

// A delivered notice Send now (the user's Interrupt) stamps the latest
// user->agent message; a refused one stamps nothing.
@(test)
test_agent_notified_by_delivered_notice_send_now :: proc(t: ^testing.T) {
	arena := ad_arena(); defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
	f: ACP_Chat_Fixture; ad_open(t, &f); defer mq_http_base_close(f.mq.base)
	f.mq.svc.bridge_command_sink.send_runtime_command_wait = ad_sink_wait
	inst, _, _ := iface.agent_get_instance(&f.mq.base.ag_repo, "inst_mq")
	inst.runtime_transport = "pty"; inst.run_count += 1; _, _, _ = iface.agent_save_instance(&f.mq.base.ag_repo, inst)
	_ = ad_send(t, &f, "a")
	latest := ad_send(t, &f, "b")
	f.delivery_sink.refuse = true
	r := ad_send_now(&f, "req_refused"); testing.expect_value(t, r.status, 503)
	id, _ := an_through(t, &f)
	testing.expect_value(t, id, "") // a refused notice notifies nobody
	f.delivery_sink.refuse = false
	r = ad_send_now(&f, "req_ok"); testing.expect(t, r.status == 200, r.body)
	id, _ = an_through(t, &f)
	testing.expect_value(t, id, latest)
}
