package bots

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import channel "odin_test:hub/service/channel"

Window_Test_State :: struct {
	t: ^testing.T,
	f: ^Pairing_Fixture,
	sequence: []channel.Channel_Error_Kind,
	sent: [dynamic]string,
	reminders: int,
	reminder_error: channel.Channel_Error_Kind,
}
window_test_io :: proc(s: ^Window_Test_State) {
	testing.expect(s.t, sync.mutex_try_lock(&s.f.service.mutex), "I/O outside service mutex")
	sync.mutex_unlock(&s.f.service.mutex)
	if testing.expect(s.t, sqlite.exec(&s.f.conn, "BEGIN IMMEDIATE;")) do testing.expect(s.t, sqlite.exec(&s.f.conn, "ROLLBACK;"))
}
window_test_send :: proc(ctx: rawptr, chat, text: string) -> (string, channel.Channel_Error) {
	s := (^Window_Test_State)(ctx)
	window_test_io(s)
	testing.expect_value(s.t, chat, "111")
	i := len(s.sent)
	append(&s.sent, strings.clone(text))
	if i < len(s.sequence) && s.sequence[i] != .None do return "", {kind = s.sequence[i]}
	return strings.clone(fmt.tprintf("out_%d", i)), {}
}
window_test_remind :: proc(ctx: rawptr, chat: string) -> (string, channel.Channel_Error) {
	s := (^Window_Test_State)(ctx)
	window_test_io(s)
	s.reminders += 1
	return strings.clone("reminder"), {kind = s.reminder_error}
}
window_test_setup :: proc(t: ^testing.T, s: ^Window_Test_State) {
	s.t, s.f = t, wa_pairing_fixture(t)
	wa_test_bind(t, s.f)
	s.f.adapter.ctx = s
	s.f.adapter.send_text = window_test_send
	s.f.adapter.send_reengage = window_test_remind
}
window_test_destroy :: proc(s: ^Window_Test_State) {
	for text in s.sent do delete(text)
	delete(s.sent)
	pairing_fixture_destroy(s.f)
}
window_test_binding :: proc(s: ^Window_Test_State) -> domain.Channel_Binding {
	b, found, err := iface.binding_get_active_by_owner(&s.f.repo, "alice", "whatsapp")
	testing.expect(s.t, found && err.code == .None)
	return b
}
window_test_close :: proc(s: ^Window_Test_State) {
	testing.expect(s.t, sqlite.exec(&s.f.conn, "UPDATE channel_bindings SET last_inbound_at='2000-01-01T00:00:00Z';"))
}
window_test_ids_free :: proc(ids: []string) {
	for id in ids do delete(id)
	delete(ids)
}
window_test_rows :: proc(s: ^Window_Test_State, states: []domain.Channel_Send_State) {
	rows, err := iface.messages_history(&s.f.repo, "bot_a", -1)
	defer {for &m in rows do domain.channel_message_destroy(&m); delete(rows)}
	testing.expect_value(s.t, err.code, domain.Error_Code.None)
	if !testing.expect_value(s.t, len(rows), len(states)) do return
	for row, i in rows do testing.expect_value(s.t, row.send_state, states[len(states)-1-i])
}
@(test)
test_window_closed_margin :: proc(t: ^testing.T) {
	a := channel.Channel_Adapter{reply_window_ms = 86_400_000}
	b := domain.Channel_Binding{last_inbound_at = pairing_test_clock(nil)}
	last := bots_stamp_ms(b.last_inbound_at)
	testing.expect(t, !bots_window_closed(&a, b, last+86_400_000-BOT_REPLY_WINDOW_MARGIN_MS-1))
	testing.expect(t, bots_window_closed(&a, b, last+86_400_000-BOT_REPLY_WINDOW_MARGIN_MS))
	testing.expect(t, bots_window_closed(&a, {}, last))
	testing.expect(t, !bots_window_closed(nil, {}, last))
	a.reply_window_ms = 0
	testing.expect(t, !bots_window_closed(&a, {}, last))
}
@(test)
test_send_holds_when_window_closed :: proc(t: ^testing.T) {
	s: Window_Test_State; window_test_setup(t, &s); defer window_test_destroy(&s)
	window_test_close(&s)
	b := window_test_binding(&s); defer domain.channel_binding_destroy(&b)
	ids, held, err := channel_send(&s.f.service, b, strings.repeat("x", 4500, context.temp_allocator), true)
	defer window_test_ids_free(ids)
	testing.expect(t, err.code == .None && held && len(ids) == 2 && len(s.sent) == 0 && s.reminders == 1)
	window_test_rows(&s, {.Held, .Held})
}
@(test)
test_send_holds_rest_on_window_closed_error :: proc(t: ^testing.T) {
	s: Window_Test_State; window_test_setup(t, &s); defer window_test_destroy(&s)
	s.sequence = {.None, .Window_Closed}
	b := window_test_binding(&s); defer domain.channel_binding_destroy(&b)
	ids, held, err := channel_send(&s.f.service, b, strings.repeat("x", 8500, context.temp_allocator), true)
	defer window_test_ids_free(ids)
	testing.expect(t, err.code == .None && held && len(ids) == 3 && len(s.sent) == 2 && s.reminders == 1)
	window_test_rows(&s, {.Sent, .Held, .Held})
}
@(test)
test_notice_not_held_when_window_closed :: proc(t: ^testing.T) {
	s: Window_Test_State; window_test_setup(t, &s); defer window_test_destroy(&s)
	window_test_close(&s)
	b := window_test_binding(&s); defer domain.channel_binding_destroy(&b)
	ids, held, err := channel_send(&s.f.service, b, "notice", false)
	defer window_test_ids_free(ids)
	testing.expect(t, err.code == .Provider_Unavailable && !held && len(ids) == 0 && len(s.sent) == 0 && s.reminders == 0)
	testing.expect(t, strings.contains(err.details_json, "Window_Closed"))
	window_test_rows(&s, {})
}
@(test)
test_reengage_once_per_closed_window :: proc(t: ^testing.T) {
	s: Window_Test_State; window_test_setup(t, &s); defer window_test_destroy(&s)
	window_test_close(&s)
	b := window_test_binding(&s); defer domain.channel_binding_destroy(&b)
	for _ in 0..<2 {
		ids, held, err := channel_send(&s.f.service, b, "answer", true)
		window_test_ids_free(ids)
		testing.expect(t, held && err.code == .None)
	}
	testing.expect_value(t, s.reminders, 1)
	fresh := window_test_binding(&s); defer domain.channel_binding_destroy(&fresh)
	testing.expect(t, fresh.reengage_sent_at != "" && fresh.reengage_error == "")
	_, e := iface.push_batch_commit(&s.f.repo, nil, {{binding_id = b.binding_id, at = pairing_test_clock(nil)}}, nil, pairing_test_clock(nil))
	testing.expect_value(t, e.code, domain.Error_Code.None)
	window_test_close(&s)
	bots_reengage(&s.f.service, b.binding_id)
	testing.expect_value(t, s.reminders, 2)
	_, _ = iface.experiment_set(&s.f.experiments, {owner_user_id = "alice", key = "bots", enabled = false})
	_ = iface.binding_set_reengage(&s.f.repo, b.binding_id, "", "")
	bots_reengage(&s.f.service, b.binding_id)
	testing.expect_value(t, s.reminders, 2)
}
window_test_reengage_error :: proc(t: ^testing.T, kind: channel.Channel_Error_Kind, expected: string) {
	s: Window_Test_State; window_test_setup(t, &s); defer window_test_destroy(&s)
	window_test_close(&s); s.reminder_error = kind
	b := window_test_binding(&s); defer domain.channel_binding_destroy(&b)
	for _ in 0..<2 {
		ids, held, err := channel_send(&s.f.service, b, "answer", true)
		window_test_ids_free(ids)
		testing.expect(t, held && err.code == .None)
	}
	fresh := window_test_binding(&s); defer domain.channel_binding_destroy(&fresh)
	testing.expect(t, s.reminders == 2 && fresh.reengage_sent_at == "" && fresh.reengage_error == expected)
	window_test_rows(&s, {.Held, .Held})
}
@(test)
test_reengage_template_unavailable_sets_error :: proc(t: ^testing.T) {window_test_reengage_error(t, .Template_Unavailable, "template_unavailable")}
@(test)
test_reengage_other_error_sets_send_failed :: proc(t: ^testing.T) {window_test_reengage_error(t, .Unauthorized, "send_failed")}
@(test)
test_release_held_in_order_and_stops_on_window_closed :: proc(t: ^testing.T) {
	s: Window_Test_State; window_test_setup(t, &s); defer window_test_destroy(&s)
	window_test_close(&s)
	b := window_test_binding(&s); defer domain.channel_binding_destroy(&b)
	text := strings.concatenate({strings.repeat("a", 4000, context.temp_allocator), strings.repeat("b", 4000, context.temp_allocator), "c"}, context.temp_allocator)
	ids, held, err := channel_send(&s.f.service, b, text, true)
	defer window_test_ids_free(ids)
	testing.expect(t, held && err.code == .None)
	bots_release_held(&s.f.service, b.binding_id)
	testing.expect_value(t, len(s.sent), 0)
	testing.expect(t, sqlite.exec(&s.f.conn, "UPDATE channel_bindings SET last_inbound_at='2026-11-17T12:00:00Z';"))
	s.sequence = {.None, .Window_Closed}
	bots_release_held(&s.f.service, b.binding_id)
	testing.expect_value(t, len(s.sent), 2)
	testing.expect(t, s.sent[0] == text[:4000] && s.sent[1] == text[4000:8000])
	window_test_rows(&s, {.Sent, .Held, .Held})
	s.sequence = {.None, .Window_Closed, .Chat_Unavailable, .None}
	bots_release_held(&s.f.service, b.binding_id)
	testing.expect_value(t, len(s.sent), 4)
	testing.expect(t, s.sent[2] == text[4000:8000] && s.sent[3] == "c")
	window_test_rows(&s, {.Sent, .Failed, .Sent})
	rows, _ := iface.messages_history(&s.f.repo, "bot_a", -1)
	defer {for &m in rows do domain.channel_message_destroy(&m); delete(rows)}
	for row in rows do testing.expect_value(t, row.created_at, pairing_test_clock(nil))
}
window_test_failure_kind :: proc(code: int) -> channel.Channel_Error_Kind {
	if code == 131047 do return .Window_Closed
	return .Chat_Unavailable
}
window_test_async :: proc(t: ^testing.T, code: int, expected: domain.Channel_Send_State) {
	s: Window_Test_State; window_test_setup(t, &s); defer window_test_destroy(&s)
	b := window_test_binding(&s); defer domain.channel_binding_destroy(&b)
	ids, held, err := channel_send(&s.f.service, b, "answer", true)
	defer window_test_ids_free(ids)
	testing.expect(t, !held && err.code == .None)
	s.f.adapter.failure_kind = window_test_failure_kind
	u := channel.Inbound{external_chat_id = "111", external_message_id = "out_0", provider_code = code}
	bots_on_delivery_failed(&s.f.service, &s.f.adapter, u)
	bots_on_delivery_failed(&s.f.service, &s.f.adapter, u)
	window_test_rows(&s, {expected})
	testing.expect_value(t, s.reminders, 1 if expected == .Held else 0)
	rows, _ := iface.messages_history(&s.f.repo, "bot_a", -1)
	defer {for &m in rows do domain.channel_message_destroy(&m); delete(rows)}
	if testing.expect_value(t, len(rows), 1) {
		testing.expect_value(t, rows[0].external_message_id, "" if expected == .Held else "out_0")
		testing.expect_value(t, rows[0].send_error, "" if expected == .Held else "Chat_Unavailable")
	}
	// Notices and unknown outbound IDs cannot produce saved replies.
	u.external_message_id = "notice"
	bots_on_delivery_failed(&s.f.service, &s.f.adapter, u)
	window_test_rows(&s, {expected})
}
@(test)
test_delivery_failed_window_marks_held_and_reengages :: proc(t: ^testing.T) {window_test_async(t, 131047, .Held)}
@(test)
test_delivery_failed_other_marks_failed :: proc(t: ^testing.T) {window_test_async(t, 131026, .Failed)}
@(test)
test_telegram_never_holds :: proc(t: ^testing.T) {
	s: Window_Test_State; window_test_setup(t, &s); defer window_test_destroy(&s)
	window_test_close(&s)
	b := window_test_binding(&s); defer domain.channel_binding_destroy(&b)
	delete(b.provider)
	b.provider = strings.clone("telegram")
	s.f.service.adapter = &s.f.adapter
	s.f.adapter.reply_window_ms = 0
	ids, held, err := channel_send(&s.f.service, b, "answer", true)
	defer window_test_ids_free(ids)
	testing.expect(t, err.code == .None && !held && len(s.sent) == 1 && s.reminders == 0)
	window_test_rows(&s, {.Sent})
}

@(test)
test_notice_bound_closed_window_still_suppressed :: proc(t: ^testing.T) {
	s: Window_Test_State; window_test_setup(t, &s); defer window_test_destroy(&s)
	bots_notice(&s.f.service, "whatsapp", "111", "open notice")
	testing.expect_value(t, len(s.sent), 1)
	window_test_close(&s)
	bots_notice(&s.f.service, "whatsapp", "111", "closed notice")
	testing.expect(t, len(s.sent) == 1 && s.reminders == 0)
	window_test_rows(&s, {})
}

@(test)
test_bots_window_closed_margin_and_invalid_timestamp :: proc(t: ^testing.T) {
	a := channel.Channel_Adapter{reply_window_ms = 86_400_000}
	b := domain.Channel_Binding{last_inbound_at = "2026-11-17T12:00:00Z"}
	last := bots_stamp_ms(b.last_inbound_at)
	testing.expect(t, !bots_window_closed(&a, b, last + 85_799_999))
	testing.expect(t, bots_window_closed(&a, b, last + 85_800_000))
	testing.expect(t, bots_window_closed(&a, {}, last))
	a.reply_window_ms = 0
	testing.expect(t, !bots_window_closed(&a, {}, last))
	testing.expect(t, !bots_window_closed(nil, {}, last))
}
