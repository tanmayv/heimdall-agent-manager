package bots

import "core:testing"
import channel "odin_test:hub/service/channel"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"

routing_test_expect :: proc(t: ^testing.T, f: ^Pairing_Fixture, provider: string) {
	b, found, err := bots_reply_binding(&f.service, "alice", "bot_a")
	defer domain.channel_binding_destroy(&b)
	testing.expect(t, found && err.code == .None && b.provider == provider)
}
@(test)
test_reply_binding_read_pending_history_and_active_fallback :: proc(t: ^testing.T) {
	f := pairing_fixture(t); defer pairing_fixture_destroy(f)
	none, missing, err := bots_reply_binding(&f.service, "alice", "bot_a")
	defer domain.channel_binding_destroy(&none)
	testing.expect(t, !missing && err.code == .None)
	pairing_test_bound(t, f)
	wa: channel.Channel_Adapter
	wa_test_second_channel(t, f, &wa)
	routing_test_expect(t, f, "telegram")
	tg, _, _ := iface.binding_get_active_by_owner(&f.repo, "alice", "telegram")
	wab, _, _ := iface.binding_get_active_by_owner(&f.repo, "alice", "whatsapp")
	defer {domain.channel_binding_destroy(&tg); domain.channel_binding_destroy(&wab)}
	ids, store_err := iface.inbound_store_batch(&f.repo, "whatsapp", {
		{message_id = "chm_old", binding_id = wab.binding_id, owner_user_id = "alice", bot_id = "bot_a", direction = .Inbound, provider_update_key = "wa:old", body = "wa", created_at = "2026-11-17T12:00:00Z"},
		{message_id = "chm_new", binding_id = tg.binding_id, owner_user_id = "alice", bot_id = "bot_a", direction = .Inbound, provider_update_key = "tg:new", body = "tg", created_at = "2026-11-17T12:01:00Z"},
	}, "", pairing_test_clock(nil))
	defer {for id in ids do delete(id); delete(ids)}
	testing.expect_value(t, store_err.code, domain.Error_Code.None)
	// Without read pending rows, newest eligible history wins.
	routing_test_expect(t, f, "telegram")
	testing.expect_value(t, iface.messages_mark_read(&f.repo, "bot_a", {"chm_old", "chm_new"}, pairing_test_clock(nil)).code, domain.Error_Code.None)
	routing_test_expect(t, f, "whatsapp")
	// through_message_id beats the pending reply target for notices.
	n, found, e := bots_notice_binding(&f.service, "alice", "bot_a", "chm_new")
	defer domain.channel_binding_destroy(&n)
	testing.expect(t, found && e.code == .None && n.provider == "telegram")
	testing.expect(t, sqlite.exec(&f.conn, "UPDATE channel_messages SET body_purged=1,body='' WHERE message_id='chm_old';"))
	routing_test_expect(t, f, "telegram")
	testing.expect_value(t, iface.binding_revoke(&f.repo, tg.binding_id, pairing_test_clock(nil)).code, domain.Error_Code.None)
	// Revoked origin falls back to the sole active provider.
	fallback, ok, fallback_err := bots_notice_binding(&f.service, "alice", "bot_a", "chm_new")
	defer domain.channel_binding_destroy(&fallback)
	testing.expect(t, ok && fallback_err.code == .None && fallback.provider == "whatsapp")
}

routing_insert :: proc(t: ^testing.T, f: ^Pairing_Fixture, binding: domain.Channel_Binding, id, at: string, read := false) {
	ids, err := iface.inbound_store_batch(&f.repo, binding.provider, {{
		message_id = id, binding_id = binding.binding_id, owner_user_id = binding.owner_user_id,
		bot_id = binding.bot_id, direction = .Inbound, provider_update_key = id, body = id, created_at = at,
	}}, "", pairing_test_clock(nil))
	defer {for id in ids do delete(id); delete(ids)}
	testing.expect_value(t, err.code, domain.Error_Code.None)
	if read do testing.expect_value(t, iface.messages_mark_read(&f.repo, binding.bot_id, {id}, pairing_test_clock(nil)).code, domain.Error_Code.None)
}
routing_read_expect :: proc(t: ^testing.T, f: ^Pairing_Fixture, provider: string) {
	b, found, err := bots_read_binding(&f.service, "alice", "bot_a")
	defer domain.channel_binding_destroy(&b)
	testing.expect(t, err.code == .None && found == (provider != "") && b.provider == provider)
}
@(test)
test_read_binding_rules :: proc(t: ^testing.T) {
	f := pairing_fixture(t); defer pairing_fixture_destroy(f)
	routing_read_expect(t, f, "")
	pairing_test_bound(t, f)
	wa: channel.Channel_Adapter; wa_test_second_channel(t, f, &wa)
	routing_read_expect(t, f, "telegram")
	b, _, _ := iface.binding_get_active_by_owner(&f.repo, "alice", "whatsapp"); defer domain.channel_binding_destroy(&b)
	tg, _, _ := iface.binding_get_active_by_owner(&f.repo, "alice", "telegram"); defer domain.channel_binding_destroy(&tg)
	routing_insert(t, f, b, "chm_wa", "2026-11-17T11:00:00Z")
	routing_insert(t, f, tg, "chm_tg", "2026-11-17T11:01:00Z")
	routing_read_expect(t, f, "whatsapp")
	testing.expect(t, sqlite.exec(&f.conn, "UPDATE channel_messages SET body='',body_purged=1 WHERE message_id='chm_wa';"))
	routing_read_expect(t, f, "telegram")
	// A purged or inactive row must not win selection.
	testing.expect(t, sqlite.exec(&f.conn, "UPDATE channel_messages SET body='wa',body_purged=0 WHERE message_id='chm_wa';"))
	_ = iface.binding_revoke(&f.repo, b.binding_id, pairing_test_clock(nil))
	routing_read_expect(t, f, "telegram")
}
@(test)
test_reply_binding_rules :: proc(t: ^testing.T) {
	test_reply_binding_read_pending_history_and_active_fallback(t)
}
@(test)
test_send_marks_replied_only_target_binding :: proc(t: ^testing.T) {
	f := pairing_fixture(t); defer pairing_fixture_destroy(f)
	pairing_test_bound(t, f)
	wa: channel.Channel_Adapter; wa_test_second_channel(t, f, &wa)
	tg, _, _ := iface.binding_get_active_by_owner(&f.repo, "alice", "telegram"); defer domain.channel_binding_destroy(&tg)
	b, _, _ := iface.binding_get_active_by_owner(&f.repo, "alice", "whatsapp"); defer domain.channel_binding_destroy(&b)
	routing_insert(t, f, b, "chm_wa", "2026-11-17T11:00:00Z", true)
	routing_insert(t, f, tg, "chm_tg", "2026-11-17T11:01:00Z", true)
	ids, held, err := channel_send(&f.service, b, "answer", true)
	defer window_test_ids_free(ids)
	testing.expect(t, err.code == .None && !held)
	testing.expect_value(t, bots_channel_replied(&f.service, "bot_a", b.binding_id).code, domain.Error_Code.None)
	pending, e := iface.messages_pending(&f.repo, "bot_a", -1)
	defer {for &m in pending do domain.channel_message_destroy(&m); delete(pending)}
	testing.expect(t, e.code == .None && len(pending) == 1 && pending[0].binding_id == tg.binding_id && pending[0].read_at != "")
}
@(test)
test_other_channel_stays_pending_and_redelivers :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	wa: channel.Channel_Adapter
	// Use the pairing fixture's sender while pairing the second channel.
	original := f.pair.adapter
	f.pair.adapter.ctx, f.pair.adapter.send_text = f.pair, pairing_test_send
	wa_test_second_channel(t, f.pair, &wa)
	f.pair.adapter = original
	tg, _, _ := iface.binding_get_active_by_owner(&f.pair.repo, "alice", "telegram"); defer domain.channel_binding_destroy(&tg)
	b, _, _ := iface.binding_get_active_by_owner(&f.pair.repo, "alice", "whatsapp"); defer domain.channel_binding_destroy(&b)
	routing_insert(t, f.pair, b, "chm_wa", "2026-11-17T11:00:00Z", true)
	routing_insert(t, f.pair, tg, "chm_tg", "2026-11-17T11:01:00Z", true)
	testing.expect_value(t, delivery_on_inbound(&f.pair.service, "bot_a", f.ms).code, domain.Error_Code.None)
	old, found, e := iface.delivery_get_open(&f.pair.repo, "bot_a"); defer domain.bot_delivery_destroy(&old)
	testing.expect(t, found && e.code == .None && old.through_message_id == "chm_tg")
	// Answer the through-message channel first: R2 closes the old delivery, R3 opens one for WhatsApp.
	testing.expect_value(t, bots_channel_replied(&f.pair.service, "bot_a", tg.binding_id).code, domain.Error_Code.None)
	next, open, next_err := iface.delivery_get_open(&f.pair.repo, "bot_a"); defer domain.bot_delivery_destroy(&next)
	testing.expect(t, open && next_err.code == .None && next.delivery_id != old.delivery_id && next.through_message_id == "chm_wa" && next.state == .Pending)
	pending, _ := iface.messages_pending(&f.pair.repo, "bot_a", -1)
	defer {for &m in pending do domain.channel_message_destroy(&m); delete(pending)}
	testing.expect(t, len(pending) == 1 && pending[0].binding_id == b.binding_id)
}
@(test)
test_pending_total_counts_all_channels :: proc(t: ^testing.T) {
	f := pairing_fixture(t); defer pairing_fixture_destroy(f)
	pairing_test_bound(t, f)
	wa: channel.Channel_Adapter; wa_test_second_channel(t, f, &wa)
	tg, _, _ := iface.binding_get_active_by_owner(&f.repo, "alice", "telegram"); defer domain.channel_binding_destroy(&tg)
	b, _, _ := iface.binding_get_active_by_owner(&f.repo, "alice", "whatsapp"); defer domain.channel_binding_destroy(&b)
	routing_insert(t, f, b, "chm_wa", "2026-11-17T11:00:00Z")
	routing_insert(t, f, tg, "chm_tg", "2026-11-17T11:01:00Z")
	rows, total, err := bots_channel_read(&f.service, "bot_a", b, 50)
	defer {for &m in rows do domain.channel_message_destroy(&m); delete(rows)}
	testing.expect(t, err.code == .None && total == 2 && len(rows) == 1 && rows[0].binding_id == b.binding_id)
	pending, _ := iface.messages_pending(&f.repo, "bot_a", -1)
	defer {for &m in pending do domain.channel_message_destroy(&m); delete(pending)}
	testing.expect(t, len(pending) == 2 && pending[0].read_at != "" && pending[1].read_at == "")
}
