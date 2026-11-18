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
