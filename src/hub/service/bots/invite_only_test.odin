package bots

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"

// REQ-WAI-2: WhatsApp invite-only enforcement. The lookup stands in for the
// billing service's effective value (override else plan), covered by the
// billing repository tests.
Invite_Test_Lookup :: struct {
	whatsapp_enabled: bool,
	fail: bool,
	calls: int,
}

invite_test_lookup :: proc(ctx: rawptr, user_id: string) -> (domain.User_Entitlements, domain.Domain_Error) {
	l := (^Invite_Test_Lookup)(ctx)
	l.calls += 1
	if l.fail do return {}, domain.domain_error(.Internal_Error, "entitlements unavailable")
	return {whatsapp_enabled = l.whatsapp_enabled}, {}
}

invite_test_attach :: proc(f: ^Pairing_Fixture, l: ^Invite_Test_Lookup) {
	f.service.entitlements = {ctx = l, lookup = invite_test_lookup}
}

invite_test_count :: proc(f: ^Pairing_Fixture, text: string) -> int {
	n := 0
	for m in f.sent do if m.text == text do n += 1
	return n
}

invite_test_messages :: proc(t: ^testing.T, f: ^Pairing_Fixture) -> int {
	messages, err := iface.messages_history(&f.repo, "bot_a", -1)
	defer {for &m in messages do domain.channel_message_destroy(&m); delete(messages)}
	testing.expect_value(t, err.code, domain.Error_Code.None)
	return len(messages)
}

invite_test_bound :: proc(f: ^Pairing_Fixture) -> bool {
	b, found, _ := iface.binding_get_active_by_owner(&f.repo, "alice", "whatsapp")
	domain.channel_binding_destroy(&b)
	return found
}

@(test)
test_whatsapp_pairing_link_refused_when_invite_only :: proc(t: ^testing.T) {
	f := wa_pairing_fixture(t); defer pairing_fixture_destroy(f)
	lookup := Invite_Test_Lookup{}
	invite_test_attach(f, &lookup)
	link, err := bots_pairing_create(&f.service, "alice", "whatsapp")
	testing.expect_value(t, err.code, domain.Error_Code.Forbidden)
	testing.expect(t, strings.contains(err.details_json, `"code":"whatsapp_invite_only"`))
	testing.expect(t, link.pairing_url == "" && link.expires_at == "")
	stmt, prep_err := sqlite.bot_repo_prepare(&f.conn, "SELECT COUNT(*) FROM channel_pairings;", nil)
	testing.expect_value(t, prep_err.code, domain.Error_Code.None)
	testing.expect_value(t, sqlite.sqlite3_step(stmt), sqlite.SQLITE_ROW)
	testing.expect_value(t, sqlite.column_text_unowned(stmt, 0), "0")
	sqlite.sqlite3_finalize(stmt)

	lookup.whatsapp_enabled = true
	allowed, allowed_err := bots_pairing_create(&f.service, "alice", "whatsapp")
	defer {delete(allowed.pairing_url); delete(allowed.pairing_text); delete(allowed.expires_at)}
	testing.expect_value(t, allowed_err.code, domain.Error_Code.None)
	testing.expect(t, allowed.pairing_url != "")

	lookup.fail = true
	_, failed := bots_pairing_create(&f.service, "alice", "whatsapp")
	testing.expect_value(t, failed.code, domain.Error_Code.Internal_Error)
}

@(test)
test_telegram_pairing_ignores_whatsapp_entitlement :: proc(t: ^testing.T) {
	f := pairing_fixture(t); defer pairing_fixture_destroy(f)
	lookup := Invite_Test_Lookup{}
	invite_test_attach(f, &lookup)
	link, err := bots_pairing_create(&f.service, "alice", "telegram")
	defer {delete(link.pairing_url); delete(link.pairing_text); delete(link.expires_at)}
	testing.expect_value(t, err.code, domain.Error_Code.None)
	pairing_test_bound(t, f)
	pairing_test_last(t, f, COPY_PAIRED)
	testing.expect_value(t, lookup.calls, 0)
}

@(test)
test_whatsapp_code_issued_before_disable_does_not_pair :: proc(t: ^testing.T) {
	f := wa_pairing_fixture(t); defer pairing_fixture_destroy(f)
	lookup := Invite_Test_Lookup{}
	invite_test_attach(f, &lookup)
	wa_test_bind(t, f)
	pairing_test_last(t, f, COPY_WA_INVITE_ONLY)
	testing.expect(t, !invite_test_bound(f))
	lookup.whatsapp_enabled = true
	wa_test_bind(t, f, code = "second")
	pairing_test_last(t, f, COPY_WA_PAIRED)
	testing.expect(t, invite_test_bound(f))
}

@(test)
test_whatsapp_inbound_routed_when_enabled :: proc(t: ^testing.T) {
	f := wa_pairing_fixture(t); defer pairing_fixture_destroy(f)
	lookup := Invite_Test_Lookup{whatsapp_enabled = true}
	invite_test_attach(f, &lookup)
	wa_test_bind(t, f)
	push_test_enqueue(t, f)
	rt := Bots_Runtime{service = &f.service}
	_, _ = bots_push_intake_iteration(&rt)
	testing.expect_value(t, invite_test_messages(t, f), 1)
	testing.expect(t, invite_test_bound(f))
	testing.expect_value(t, invite_test_count(f, COPY_WA_INVITE_ONLY), 0)
}

@(test)
test_whatsapp_inbound_disabled_unbinds_with_one_notice :: proc(t: ^testing.T) {
	f := wa_pairing_fixture(t); defer pairing_fixture_destroy(f)
	lookup := Invite_Test_Lookup{whatsapp_enabled = true}
	invite_test_attach(f, &lookup)
	wa_test_bind(t, f)
	b, _, _ := iface.binding_get_active_by_owner(&f.repo, "alice", "whatsapp")
	defer domain.channel_binding_destroy(&b)
	pairing_test_inbound(t, f, b, "chm_old", "whatsapp:old")
	testing.expect_value(t, delivery_on_inbound(&f.service, "bot_a", 1794916800000).code, domain.Error_Code.None)
	d, open, _ := iface.delivery_get_open(&f.repo, "bot_a"); defer domain.bot_delivery_destroy(&d)
	testing.expect(t, open)

	// The admin turns WhatsApp off; the next messages are read per request.
	lookup.whatsapp_enabled = false
	push_test_enqueue(t, f, key = "e1")
	push_test_enqueue(t, f, key = "e2")
	rt := Bots_Runtime{service = &f.service}
	_, _ = bots_push_intake_iteration(&rt)
	testing.expect(t, !invite_test_bound(f))
	// Only the message stored before the switch exists, purged by the unbind.
	testing.expect_value(t, invite_test_messages(t, f), 1)
	testing.expect_value(t, invite_test_count(f, COPY_WA_INVITE_ONLY), 1)
	testing.expect_value(t, invite_test_count(f, COPY_WA_NOT_CONNECTED), 0)
	done, _, _ := iface.delivery_get(&f.repo, d.delivery_id); defer domain.bot_delivery_destroy(&done)
	testing.expect(t, done.state == .Abandoned && done.finish_reason == BOTS_WHATSAPP_INVITE_ONLY_REASON)
	pending, e := iface.push_events_pending(&f.repo, "whatsapp", 50)
	defer {for &p in pending do domain.channel_push_event_destroy(&p); delete(pending)}
	testing.expect(t, e.code == .None && len(pending) == 0)

	// The invite-only notice is not repeated per message; an unbound sender
	// now gets the ordinary not-connected copy.
	push_test_enqueue(t, f, key = "e3")
	_, _ = bots_push_intake_iteration(&rt)
	testing.expect_value(t, invite_test_count(f, COPY_WA_INVITE_ONLY), 1)
	testing.expect_value(t, invite_test_messages(t, f), 1)
}

@(test)
test_whatsapp_inbound_lookup_failure_retries_without_unbinding :: proc(t: ^testing.T) {
	f := wa_pairing_fixture(t); defer pairing_fixture_destroy(f)
	lookup := Invite_Test_Lookup{whatsapp_enabled = true}
	invite_test_attach(f, &lookup)
	wa_test_bind(t, f)
	sent := len(f.sent)
	lookup.fail = true
	push_test_enqueue(t, f)
	rt := Bots_Runtime{service = &f.service}
	_, delay := bots_push_intake_iteration(&rt)
	testing.expect_value(t, delay, BOT_PUSH_INTAKE_RETRY)
	testing.expect(t, invite_test_bound(f))
	testing.expect_value(t, len(f.sent), sent)
	lookup.fail = false
	_, _ = bots_push_intake_iteration(&rt)
	testing.expect_value(t, invite_test_messages(t, f), 1)
}

@(test)
test_whatsapp_sweep_unbinds_disabled_owner_once :: proc(t: ^testing.T) {
	f := wa_pairing_fixture(t); defer pairing_fixture_destroy(f)
	lookup := Invite_Test_Lookup{whatsapp_enabled = true}
	invite_test_attach(f, &lookup)
	wa_test_bind(t, f)
	bots_whatsapp_entitlement_sweep(&f.service)
	testing.expect(t, invite_test_bound(f))
	lookup.whatsapp_enabled = false
	bots_whatsapp_entitlement_sweep(&f.service)
	testing.expect(t, !invite_test_bound(f))
	testing.expect_value(t, invite_test_count(f, COPY_WA_INVITE_ONLY), 1)
	bots_whatsapp_entitlement_sweep(&f.service)
	testing.expect_value(t, invite_test_count(f, COPY_WA_INVITE_ONLY), 1)
}

@(test)
test_telegram_inbound_ignores_whatsapp_entitlement :: proc(t: ^testing.T) {
	f := pairing_fixture(t); defer pairing_fixture_destroy(f)
	lookup := Invite_Test_Lookup{}
	invite_test_attach(f, &lookup)
	pairing_test_bound(t, f)
	update := pairing_test_update("hello")
	update.kind = .Text
	rows, err := bots_inbound_rows(&f.service, &f.adapter, {update}, pairing_test_clock(nil))
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, bots_inbound_side_effect(&f.service, &f.adapter, update, pairing_test_clock(nil)).code, domain.Error_Code.None)
	b, found, _ := iface.binding_get_active_by_chat(&f.repo, "telegram", "111")
	defer domain.channel_binding_destroy(&b)
	testing.expect(t, found)
	testing.expect_value(t, lookup.calls, 0)
}
