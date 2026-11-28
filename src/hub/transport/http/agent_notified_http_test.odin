package http

import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// R7 rev 6: the bridge's agent_notice_typed report stamps the conversation's
// agent_notified_at, exposed by GET send-now; monotonic and owner-bridge only.

an_notified_at :: proc(t: ^testing.T, f: ^ACP_Chat_Fixture) -> string {
	g := get_send_now_handler(&f.mq.handlers, mq_http_req(f.mq.base, "/api/v1/chats/chat_mq/send-now", ""))
	testing.expect(t, g.status == 200, g.body)
	key := `"agent_notified_at":"`
	i := strings.index(g.body, key)
	if !testing.expect(t, i >= 0, g.body) do return "<missing>"
	rest := g.body[i+len(key):]
	return rest[:strings.index_byte(rest, '"')]
}

an_frame :: proc(instance: string, typed_at_ms: i64) -> string {
	return fmt.tprintf(`{{"type":"%s","agent_instance_id":"%s","typed_at_ms":%d}}`, contracts.AGENT_NOTICE_TYPED_FRAME, instance, typed_at_ms)
}

an_ms :: proc(rfc: string) -> i64 { ms, _ := platform.rfc3339_to_unix_ms(rfc); return ms }

@(test)
test_agent_notice_typed_is_stored_monotonic_and_exposed :: proc(t: ^testing.T) {
	arena := ad_arena(); defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
	f: ACP_Chat_Fixture; ad_open(t, &f); defer mq_http_base_close(f.mq.base)
	h := Bridge_Handlers{content = &f.mq.svc}
	testing.expect_value(t, an_notified_at(t, &f), "") // never notified
	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000
	t1 := platform.format_rfc3339_utc(time.unix(0, (now_ms - 60_000) * 1_000_000))
	bridge_ws_agent_notice_typed(&h, f.mq.base.bridge_id, an_frame("inst_mq", an_ms(t1)))
	testing.expect_value(t, an_notified_at(t, &f), t1)
	// Idempotent, and an older report never moves it back.
	bridge_ws_agent_notice_typed(&h, f.mq.base.bridge_id, an_frame("inst_mq", an_ms(t1)))
	bridge_ws_agent_notice_typed(&h, f.mq.base.bridge_id, an_frame("inst_mq", an_ms(t1) - 30_000))
	testing.expect_value(t, an_notified_at(t, &f), t1)
	// Another bridge cannot report for this instance; junk frames are dropped.
	bridge_ws_agent_notice_typed(&h, "brg_other", an_frame("inst_mq", now_ms))
	bridge_ws_agent_notice_typed(&h, f.mq.base.bridge_id, `{"type":"agent_notice_typed","agent_instance_id":`)
	bridge_ws_agent_notice_typed(&h, f.mq.base.bridge_id, an_frame("inst_unknown", now_ms))
	testing.expect_value(t, an_notified_at(t, &f), t1)
	// A bridge clock ahead of the Hub is clamped to the Hub's receipt.
	bridge_ws_agent_notice_typed(&h, f.mq.base.bridge_id, an_frame("inst_mq", now_ms + 3_600_000))
	stamped := an_notified_at(t, &f)
	testing.expect(t, stamped > t1 && an_ms(stamped) <= time.to_unix_nanoseconds(time.now()) / 1_000_000, stamped)
}

// A delivered notice Send now (the user's Interrupt) also notifies the agent.
@(test)
test_agent_notified_by_delivered_notice_send_now :: proc(t: ^testing.T) {
	arena := ad_arena(); defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
	f: ACP_Chat_Fixture; ad_open(t, &f); defer mq_http_base_close(f.mq.base)
	f.mq.svc.bridge_command_sink.send_runtime_command_wait = ad_sink_wait
	inst, _, _ := iface.agent_get_instance(&f.mq.base.ag_repo, "inst_mq")
	inst.runtime_transport = "pty"; inst.run_count += 1; _, _, _ = iface.agent_save_instance(&f.mq.base.ag_repo, inst)
	_ = ad_send(t, &f, "a")
	f.delivery_sink.refuse = true
	r := ad_send_now(&f, "req_refused"); testing.expect_value(t, r.status, 503)
	testing.expect_value(t, an_notified_at(t, &f), "") // a refused notice notifies nobody
	f.delivery_sink.refuse = false
	r = ad_send_now(&f, "req_ok"); testing.expect(t, r.status == 200, r.body)
	testing.expect(t, an_notified_at(t, &f) != "")
}
