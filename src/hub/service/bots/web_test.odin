package bots

import "core:net"
import "core:strings"
import "core:testing"
import "core:time"
import channel "odin_test:hub/service/channel"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import events "odin_test:hub/service/events"

@(test)
test_web_send_idempotency_gating_and_local_reply :: proc(t: ^testing.T) {
	f := pairing_fixture(t); defer pairing_fixture_destroy(f)
	lookup := Invite_Test_Lookup{fail = true}
	invite_test_attach(f, &lookup)
	first, fresh, err := bots_web_send(&f.service, "alice", "hello", "request-1")
	defer domain.channel_message_destroy(&first)
	testing.expect(t, fresh && err.code == .None && first.direction == .Inbound)
	testing.expect_value(t, lookup.calls, 0)
	binding, found, e := iface.binding_get_active_by_owner(&f.repo, "alice", "web")
	defer domain.channel_binding_destroy(&binding)
	testing.expect(t, found && e.code == .None && first.binding_id == binding.binding_id)
	d, open, de := iface.delivery_get_open(&f.repo, "bot_a")
	defer domain.bot_delivery_destroy(&d)
	testing.expect(t, open && de.code == .None && d.state == .Pending && d.through_message_id == first.message_id)
	replay, again, re := bots_web_send(&f.service, "alice", "hello", "request-1")
	defer domain.channel_message_destroy(&replay)
	testing.expect(t, !again && re.code == .None && replay.message_id == first.message_id)
	conflict, _, ce := bots_web_send(&f.service, "alice", "changed", "request-1")
	defer domain.channel_message_destroy(&conflict)
	testing.expect_value(t, ce.code, domain.Error_Code.Conflict)
	// Payload hashes survive retention; keys remain safe to retry.
	testing.expect_value(t, iface.messages_purge_binding(&f.repo, binding.binding_id).code, domain.Error_Code.None)
	purged, _, pe := bots_web_send(&f.service, "alice", "hello", "request-1")
	defer domain.channel_message_destroy(&purged)
	testing.expect(t, pe.code == .None && purged.body_purged)
	ids, held, send_err := channel_send(&f.service, binding, "local answer", true)
	defer window_test_ids_free(ids)
	testing.expect(t, send_err.code == .None && !held && len(ids) == 1)
	testing.expect_value(t, len(f.sent), 0)
	history, he := iface.messages_history(&f.repo, "bot_a", -1)
	defer {for &m in history do domain.channel_message_destroy(&m); delete(history)}
	testing.expect(t, he.code == .None && len(history) == 2 && history[0].send_state == .Sent && history[0].binding_id == binding.binding_id)
	_, _ = iface.experiment_set(&f.experiments, {owner_user_id = "alice", key = "bots", enabled = false})
	denied, _, gate_err := bots_web_send(&f.service, "alice", "hello", "request-2")
	defer domain.channel_message_destroy(&denied)
	testing.expect_value(t, gate_err.code, domain.Error_Code.Forbidden)
}

@(test)
test_web_intake_rollback_and_delivery_retry :: proc(t: ^testing.T) {
	f := pairing_fixture(t); defer pairing_fixture_destroy(f)
	testing.expect(t, sqlite.exec(&f.conn, "CREATE TRIGGER fail_web BEFORE INSERT ON channel_messages BEGIN SELECT RAISE(ABORT,'injected'); END;"))
	failed, _, e := bots_web_send(&f.service, "alice", "hello", "retry")
	defer domain.channel_message_destroy(&failed)
	testing.expect(t, e.code != .None)
	binding, found, _ := iface.binding_get_active_by_owner(&f.repo, "alice", "web")
	defer domain.channel_binding_destroy(&binding)
	testing.expect(t, !found, "binding rolls back with intake failure")
	testing.expect(t, sqlite.exec(&f.conn, "DROP TRIGGER fail_web; CREATE TRIGGER fail_delivery BEFORE INSERT ON bot_deliveries BEGIN SELECT RAISE(ABORT,'injected'); END;"))
	stored, fresh, delivery_err := bots_web_send(&f.service, "alice", "hello", "retry")
	defer domain.channel_message_destroy(&stored)
	testing.expect(t, fresh && stored.message_id != "" && delivery_err.code != .None)
	testing.expect(t, sqlite.exec(&f.conn, "DROP TRIGGER fail_delivery;"))
	replay, again, retry_err := bots_web_send(&f.service, "alice", "hello", "retry")
	defer domain.channel_message_destroy(&replay)
	testing.expect(t, retry_err.code == .None && !again && replay.message_id == stored.message_id)
	d, open, de := iface.delivery_get_open(&f.repo, "bot_a")
	defer domain.bot_delivery_destroy(&d)
	testing.expect(t, open && de.code == .None && d.through_message_id == stored.message_id)
}

@(test)
test_web_delivery_wakes_existing_bot_and_routes_back_then_telegram :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	s := &f.pair.service
	message, fresh, err := bots_web_send(s, "alice", "from web", "wake-web")
	defer domain.channel_message_destroy(&message)
	testing.expect(t, fresh && err.code == .None)
	bots_supervisor_tick(s)
	delivery_expect(t, f, .Dispatched)
	delivery_attempt_expect(t, f, .Sent)
	testing.expect(t, len(f.frames) > 0 && strings.contains(f.frames[0], "bot_deliver") && strings.contains(f.frames[0], "inst_a"))
	routing_test_expect(t, f.pair, "web")
	binding, _, _ := iface.binding_get_active_by_owner(s.repo, "alice", "web")
	defer domain.channel_binding_destroy(&binding)
	testing.expect_value(t, iface.messages_mark_read(s.repo, "bot_a", {message.message_id}, delivery_clock(f)).code, domain.Error_Code.None)
	ids, held, send_err := channel_send(s, binding, "web answer", true)
	defer window_test_ids_free(ids)
	testing.expect(t, send_err.code == .None && !held)
	testing.expect_value(t, bots_channel_replied(s, "bot_a", binding.binding_id).code, domain.Error_Code.None)
	f.ms += 1000
	delivery_inbound(t, f, "chm_later_telegram")
	routing_test_expect(t, f.pair, "telegram")
	tg, _, _ := bots_reply_binding(s, "alice", "bot_a")
	defer domain.channel_binding_destroy(&tg)
	tg_ids, _, tg_err := channel_send(s, tg, "telegram answer", true)
	defer window_test_ids_free(tg_ids)
	testing.expect_value(t, tg_err.code, domain.Error_Code.None)
	rows, he := iface.messages_history(s.repo, "bot_a", -1)
	defer {for &m in rows do domain.channel_message_destroy(&m); delete(rows)}
	testing.expect(t, he.code == .None && rows[0].binding_id == tg.binding_id)
}

@(test)
test_web_message_events_reach_only_owner_stream :: proc(t: ^testing.T) {
	f := pairing_fixture(t); defer pairing_fixture_destroy(f)
	listener, le := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if !testing.expect(t, le == nil) do return
	defer net.close(listener)
	bound, be := net.bound_endpoint(listener)
	if !testing.expect(t, be == nil) do return
	peer, pe := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if !testing.expect(t, pe == nil) do return
	defer net.close(peer)
	hub, _, ae := net.accept_tcp(listener)
	if !testing.expect(t, ae == nil) do return
	defer net.close(hub)
	_ = net.set_option(peer, .Receive_Timeout, time.Second)
	slot := events.user_ws_add(&f.event_bus, "alice", hub)
	defer events.user_ws_remove(&f.event_bus, slot)
	message, _, e := bots_web_send(&f.service, "alice", "stream me", "stream")
	defer domain.channel_message_destroy(&message)
	testing.expect_value(t, e.code, domain.Error_Code.None)
	buffer: [2048]byte
	n, read_err := net.recv_tcp(peer, buffer[:])
	testing.expect(t, read_err == nil && n > 0 && strings.contains(string(buffer[:n]), "bot_changed") && strings.contains(string(buffer[:n]), "bot_a"))
	testing.expect_value(t, f.event_bus.stream_seqs[slot], u64(1))
	binding, _, _ := iface.binding_get_active_by_owner(&f.repo, "alice", "web")
	defer domain.channel_binding_destroy(&binding)
	ids, _, send_err := channel_send(&f.service, binding, "stream answer", true)
	defer window_test_ids_free(ids)
	testing.expect_value(t, send_err.code, domain.Error_Code.None)
	n, read_err = net.recv_tcp(peer, buffer[:])
	testing.expect(t, read_err == nil && n > 0 && strings.contains(string(buffer[:n]), "bot_changed"))
	testing.expect_value(t, f.event_bus.stream_seqs[slot], u64(2))
	events.user_ws_remove(&f.event_bus, slot)
	other := events.user_ws_add(&f.event_bus, "bob", hub)
	defer events.user_ws_remove(&f.event_bus, other)
	next, _, next_err := bots_web_send(&f.service, "alice", "private", "stream-2")
	defer domain.channel_message_destroy(&next)
	testing.expect_value(t, next_err.code, domain.Error_Code.None)
	testing.expect_value(t, f.event_bus.stream_seqs[other], u64(0))
}
