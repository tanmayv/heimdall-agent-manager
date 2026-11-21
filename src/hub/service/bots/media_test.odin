package bots
import "core:testing"
import "core:strings"
import "core:os"
import "core:sync"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import channel "odin_test:hub/service/channel"

Media_Test_State :: struct {
	t: ^testing.T,
	f: ^Pairing_Fixture,
	rules: [2]channel.Media_Send_Rule,
	errors: []channel.Channel_Error_Kind,
	captions, texts: [dynamic]string,
	kinds: [dynamic]channel.Media_Kind,
	timeouts: [dynamic]int,
	fetch_error: channel.Channel_Error_Kind,
	fetch_calls: int,
	sleep_ms: int,
	sleep_timeout: bool,
	text_error: channel.Channel_Error_Kind,
}
media_test_io :: proc(s: ^Media_Test_State) {
	if sync.mutex_try_lock(&s.f.service.mutex) {sync.mutex_unlock(&s.f.service.mutex)} else {testing.expect(s.t, false, "provider called under service lock")}
	// A provider must not run under a write transaction.
	if testing.expect(s.t, sqlite.exec(&s.f.conn, "BEGIN IMMEDIATE;")) do testing.expect(s.t, sqlite.exec(&s.f.conn, "ROLLBACK;"))
}
media_test_fetch :: proc(ctx: rawptr, ref: string, limit: i64, allocator := context.allocator) -> (channel.Fetched_Media, channel.Channel_Error) {
	s := (^Media_Test_State)(ctx); media_test_io(s)
	s.fetch_calls += 1
	if s.fetch_error != .None do return {}, {kind = s.fetch_error}
	b := make([]byte, 8, allocator)
	copy(b, []byte{0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a})
	return {b, strings.clone("image/jpeg", allocator)}, {}
}
media_test_send :: proc(ctx: rawptr, chat: string, m: channel.Outbound_Media, timeout_ms: int) -> (string, channel.Channel_Error) {
	s := (^Media_Test_State)(ctx); media_test_io(s)
	i := len(s.kinds)
	append(&s.kinds, m.kind); append(&s.captions, strings.clone(m.caption)); append(&s.timeouts, timeout_ms)
	rows, e := iface.messages_history(&s.f.repo, "bot_a", -1)
	defer {for &row in rows do domain.channel_message_destroy(&row); delete(rows)}
	testing.expect(s.t, e.code == .None && len(rows) > 0, "persist rows before provider call")
	if s.sleep_timeout {time.sleep(time.Duration(timeout_ms)*time.Millisecond)} else if s.sleep_ms > 0 {time.sleep(time.Duration(s.sleep_ms)*time.Millisecond)}
	if i < len(s.errors) && s.errors[i] != .None do return "", {kind = s.errors[i]}
	return strings.clone("media_sent"), {}
}
media_test_text :: proc(ctx: rawptr, chat, text: string) -> (string, channel.Channel_Error) {
	s := (^Media_Test_State)(ctx); media_test_io(s)
	append(&s.texts, strings.clone(text))
	if s.text_error != .None do return "", {kind = s.text_error}
	return strings.clone("text_sent"), {}
}
media_test_text_within :: proc(ctx: rawptr, chat, text: string, timeout_ms: int) -> (string, channel.Channel_Error) {
	s := (^Media_Test_State)(ctx)
	append(&s.timeouts, timeout_ms)
	return media_test_text(ctx, chat, text)
}
media_test_setup :: proc(t: ^testing.T, s: ^Media_Test_State) {
	s.t, s.f = t, pairing_fixture(t)
	pairing_test_bound(t, s.f)
	s.f.adapter.ctx = s
	s.f.adapter.send_text = media_test_text
	s.f.adapter.media_fetch = media_test_fetch
	s.f.adapter.send_media = media_test_send
	s.rules = {{kind = .Image, max_bytes = 10000, caption = true}, {kind = .Document, max_bytes = 20000, caption = true}}
	s.f.adapter.media = {fetch_max_bytes = 10000, caption_max_runes = 100, send_rules = s.rules[:]}
}
media_test_destroy :: proc(s: ^Media_Test_State) {
	for c in s.captions do delete(c)
	for c in s.texts do delete(c)
	delete(s.captions); delete(s.texts); delete(s.kinds); delete(s.timeouts)
	pairing_fixture_destroy(s.f)
}
media_test_binding :: proc(s: ^Media_Test_State) -> domain.Channel_Binding {
	b, found, e := iface.binding_get_active_by_owner(&s.f.repo, "alice", "telegram")
	testing.expect(s.t, found && e.code == .None)
	return b
}
media_test_out :: proc(upload := true) -> Bot_Outbound_Media {
	return {artifact_id = "art_file", name = "photo.png", mime = "image/png", size = 3, bytes = transmute([]byte)string("abc") if upload else nil}
}
media_test_inbound :: proc(s: ^Media_Test_State, size: i64 = 8, caption := "", user := "222") -> []domain.Channel_Message {
	rows, e := bots_inbound_rows(&s.f.service, &s.f.adapter, {{kind = .Media, external_chat_id = "111", external_user_id = user,
		chat_is_private = true, update_key = "update", text = caption, media = {.Image, "private-ref", "", "image/jpeg", size}}}, pairing_test_clock(nil))
	testing.expect_value(s.t, e.code, domain.Error_Code.None)
	return rows
}
media_test_store :: proc(s: ^Media_Test_State, size: i64 = 8) -> string {
	rows := media_test_inbound(s, size)
	ids, e := iface.inbound_store_batch(&s.f.repo, "telegram", rows, "1", pairing_test_clock(nil))
	defer {for id in ids do delete(id); delete(ids)}
	testing.expect_value(s.t, e.code, domain.Error_Code.None)
	return rows[0].attachment.attachment_id
}
media_test_bot :: proc() -> domain.Bot {return {bot_id = "bot_a", owner_user_id = "alice"}}
media_test_rows :: proc(s: ^Media_Test_State, ids: []string) -> []domain.Channel_Message {
	rows, e := iface.messages_history(&s.f.repo, "bot_a", -1)
	testing.expect_value(s.t, e.code, domain.Error_Code.None)
	testing.expect_value(s.t, len(rows), len(ids))
	attachments, ae := iface.attachments_for_messages(&s.f.repo, ids)
	defer {for &a in attachments do domain.channel_attachment_destroy(&a); delete(attachments)}
	testing.expect_value(s.t, ae.code, domain.Error_Code.None)
	for &row in rows do for &a in attachments do if a.message_id == row.message_id {row.attachment = a; a = {}}
	return rows
}
media_test_free_rows :: proc(rows: []domain.Channel_Message) {for &row in rows do domain.channel_message_destroy(&row); delete(rows)}

@(test)
test_media_plan_rules :: proc(t: ^testing.T) {
	s: Media_Test_State; media_test_setup(t, &s); defer media_test_destroy(&s)
	a := &s.f.adapter
	testing.expect_value(t, bots_media_plan(nil, {}, "", 1, 0).reason, "no_native_media")
	saved := a.send_media; a.send_media = nil
	testing.expect_value(t, bots_media_plan(a, {}, "", 1, 0).reason, "no_native_media"); a.send_media = saved
	a.reply_window_ms = 1000
	testing.expect_value(t, bots_media_plan(a, {}, "", 1, 0).reason, "window_closed"); a.reply_window_ms = 0
	s.rules[0].mimes = {"image/png"}; s.rules[1].mimes = {"application/pdf"}
	testing.expect_value(t, bots_media_plan(a, {}, "text/plain", 1, 0).reason, "unsupported_type")
	testing.expect_value(t, bots_media_plan(a, {}, "image/png", 10001, 0).reason, "too_large")
	p := bots_media_plan(a, {}, "image/png", 10000, 0)
	testing.expect(t, p.mode == .Native && len(p.rules) == 1 && p.rules[0].kind == .Image)
	s.rules[1].mimes = nil
	p = bots_media_plan(a, {}, "image/png", 10000, 0)
	testing.expect(t, p.mode == .Native && len(p.rules) == 2)
	a.media.send_rules = nil
	testing.expect_value(t, bots_media_plan(a, {}, "", 1, 0).reason, "no_native_media")
}
@(test)
test_inbound_media_row_pending :: proc(t: ^testing.T) {
	s: Media_Test_State; media_test_setup(t, &s); defer media_test_destroy(&s)
	rows := media_test_inbound(&s)
	testing.expect(t, len(rows) == 1 && rows[0].body == "" && rows[0].attachment.state == .Pending && rows[0].attachment.name == "photo.jpg" && rows[0].attachment.file_ref == "private-ref")
}
media_test_large_inbound :: proc(t: ^testing.T, caption: string) {
	s: Media_Test_State; media_test_setup(t, &s); defer media_test_destroy(&s)
	rows := media_test_inbound(&s, 10001, caption)
	testing.expect_value(t, len(rows), 1 if caption != "" else 0)
	if len(rows)>0 do testing.expect(t, rows[0].body == caption && rows[0].attachment.state == .Too_Large)
	e := bots_inbound_side_effect(&s.f.service, &s.f.adapter, {kind = .Media, external_chat_id = "111", external_user_id = "222", chat_is_private = true, text = caption, media = {size = 10001}}, pairing_test_clock(nil))
	testing.expect(t, e.code == .None && len(s.texts) == 1 && s.texts[0] == COPY_MEDIA_TOO_LARGE && s.fetch_calls == 0)
}
@(test) test_inbound_media_too_large_with_caption_stores_and_notices :: proc(t: ^testing.T) {media_test_large_inbound(t, "caption")}
@(test) test_inbound_media_too_large_without_caption_notice_only :: proc(t: ^testing.T) {media_test_large_inbound(t, "")}
@(test)
test_inbound_media_without_fetch_is_unsupported :: proc(t: ^testing.T) {
	s: Media_Test_State; media_test_setup(t, &s); defer media_test_destroy(&s)
	s.f.adapter.media_fetch = nil
	testing.expect_value(t, len(media_test_inbound(&s)), 0)
	_ = bots_inbound_side_effect(&s.f.service, &s.f.adapter, {kind = .Media, external_chat_id = "111", external_user_id = "222", chat_is_private = true}, pairing_test_clock(nil))
	testing.expect(t, len(s.texts) == 1 && s.texts[0] == COPY_UNSUPPORTED)
}
@(test)
test_inbound_media_wrong_user_ignored :: proc(t: ^testing.T) {
	s: Media_Test_State; media_test_setup(t, &s); defer media_test_destroy(&s)
	testing.expect_value(t, len(media_test_inbound(&s, 10001, "caption", "stranger")), 0)
	_ = bots_inbound_side_effect(&s.f.service, &s.f.adapter, {kind = .Media, external_chat_id = "111", external_user_id = "stranger", chat_is_private = true, media = {size = 10001}}, pairing_test_clock(nil))
	testing.expect_value(t, len(s.texts), 0)
}
@(test)
test_media_fetch_outcomes :: proc(t: ^testing.T) {
	for kind in ([]channel.Channel_Error_Kind{.None, .Media_Too_Large, .Media_Unavailable, .Transient}) {
		s: Media_Test_State; media_test_setup(t, &s)
		id := media_test_store(&s); s.fetch_error = kind
		for _ in 0..<2 {
			f, e := bots_media_fetch(&s.f.service, media_test_bot(), id)
			testing.expect_value(t, e.code, domain.Error_Code.None)
			#partial switch kind {
			case .None: testing.expect(t, f.outcome == "fetched" && len(f.bytes) == 8)
			case .Media_Too_Large: testing.expect_value(t, f.outcome, "too_large")
			case .Media_Unavailable: testing.expect_value(t, f.outcome, "unavailable")
			case .Transient: testing.expect(t, f.outcome == "failed" && f.error_kind == "Transient" && f.attachment.state == .Pending)
			}
			bot_media_fetch_destroy(&f)
		}
		if kind == .Media_Too_Large do testing.expect_value(t, len(s.texts), 1)
		media_test_destroy(&s)
	}
	s: Media_Test_State; media_test_setup(t, &s); defer media_test_destroy(&s)
	id := media_test_store(&s)
	recorded, _ := bots_media_stored(&s.f.service, media_test_bot(), id, "art_first"); delete(recorded)
	f, e := bots_media_fetch(&s.f.service, media_test_bot(), id); defer bot_media_fetch_destroy(&f)
	testing.expect(t, e.code == .None && f.outcome == "stored" && f.attachment.artifact_id == "art_first" && s.fetch_calls == 0)
}
@(test)
test_media_fetch_refuses_other_bot_outbound_and_revoked_binding :: proc(t: ^testing.T) {
	s: Media_Test_State; media_test_setup(t, &s); defer media_test_destroy(&s)
	id := media_test_store(&s)
	bot := media_test_bot(); bot.bot_id = "other"
	f, e := bots_media_fetch(&s.f.service, bot, id); bot_media_fetch_destroy(&f)
	testing.expect_value(t, e.code, domain.Error_Code.Not_Found)
	testing.expect(t, sqlite.exec(&s.f.conn, "UPDATE channel_attachments SET direction='outbound';"))
	f, e = bots_media_fetch(&s.f.service, media_test_bot(), id); bot_media_fetch_destroy(&f)
	testing.expect_value(t, e.code, domain.Error_Code.Not_Found)
	testing.expect(t, sqlite.exec(&s.f.conn, "UPDATE channel_attachments SET direction='inbound'; UPDATE channel_bindings SET state='revoked';"))
	f, e = bots_media_fetch(&s.f.service, media_test_bot(), id); bot_media_fetch_destroy(&f)
	testing.expect_value(t, e.code, domain.Error_Code.Not_Found)
	testing.expect_value(t, s.fetch_calls, 0)
}
@(test)
test_media_fetch_sniffs_image_mime :: proc(t: ^testing.T) {
	s: Media_Test_State; media_test_setup(t, &s); defer media_test_destroy(&s)
	id := media_test_store(&s)
	f, e := bots_media_fetch(&s.f.service, media_test_bot(), id); defer bot_media_fetch_destroy(&f)
	testing.expect(t, e.code == .None && f.mime == "image/png")
}
@(test)
test_media_stored_first_writer_wins :: proc(t: ^testing.T) {
	s: Media_Test_State; media_test_setup(t, &s); defer media_test_destroy(&s)
	id := media_test_store(&s)
	for artifact in ([]string{"art_first", "art_second"}) {
		recorded, e := bots_media_stored(&s.f.service, media_test_bot(), id, artifact); defer delete(recorded)
		testing.expect(t, e.code == .None && recorded == "art_first")
	}
}
@(test)
test_media_stored_not_pending_conflict :: proc(t: ^testing.T) {
	s: Media_Test_State; media_test_setup(t, &s); defer media_test_destroy(&s)
	id := media_test_store(&s)
	_, _ = iface.attachment_set_state(&s.f.repo, id, .Pending, .Unavailable, pairing_test_clock(nil))
	recorded, e := bots_media_stored(&s.f.service, media_test_bot(), id, "art_file"); defer delete(recorded)
	testing.expect_value(t, e.code, domain.Error_Code.Conflict)
}
media_test_send_caption :: proc(t: ^testing.T, caption: string, support: bool) {
	s: Media_Test_State; media_test_setup(t, &s); defer media_test_destroy(&s)
	s.rules[0].caption = support
	b := media_test_binding(&s); defer domain.channel_binding_destroy(&b)
	ids, held, sent_as, unsent, e := channel_send_media(&s.f.service, b, caption, media_test_out()); defer window_test_ids_free(ids)
	separate := !support || len(caption)>100
	testing.expect(t, e.code == .None && !held && sent_as == "native" && unsent == 0 && len(ids) == (2 if separate else 1))
	testing.expect(t, len(s.captions) == 1 && s.captions[0] == ("" if separate else caption))
	if separate do testing.expect(t, len(s.texts) == 1 && s.texts[0] == caption)
	rows := media_test_rows(&s, ids); defer media_test_free_rows(rows)
	for row in rows do testing.expect_value(t, row.send_state, domain.Channel_Send_State.Sent)
}
@(test) test_send_media_native_with_caption :: proc(t: ^testing.T) {media_test_send_caption(t, "caption", true)}
@(test) test_send_media_caption_separate_when_rule_has_no_caption :: proc(t: ^testing.T) {media_test_send_caption(t, "caption", false)}
@(test) test_send_media_caption_over_limit_sent_after :: proc(t: ^testing.T) {media_test_send_caption(t, strings.repeat("x",101,context.temp_allocator),true)}
@(test)
test_send_media_refused_tries_next_rule_then_link :: proc(t: ^testing.T) {
	for second in ([]channel.Channel_Error_Kind{.None,.Invalid_Request}) {
		s: Media_Test_State; media_test_setup(t, &s)
		errors := [2]channel.Channel_Error_Kind{.Invalid_Request, second}; s.errors = errors[:]
		b := media_test_binding(&s)
		ids, _, as, _, e := channel_send_media(&s.f.service, b, "caption", media_test_out())
		testing.expect(t, e.code == .None && len(s.kinds) == 2 && s.kinds[0] == .Image && s.kinds[1] == .Document)
		testing.expect_value(t, as, "native" if second == .None else "link")
		if second != .None do testing.expect(t, len(s.texts) == 1 && strings.contains(s.texts[0],"art_file"))
		rows := media_test_rows(&s, ids)
		testing.expect(t, rows[0].attachment.state == (.Native if second == .None else .Link))
		media_test_free_rows(rows); window_test_ids_free(ids); domain.channel_binding_destroy(&b); media_test_destroy(&s)
	}
}
media_test_link_send :: proc(t: ^testing.T, upload, no_native, closed: bool) {
	s: Media_Test_State; media_test_setup(t, &s); defer media_test_destroy(&s)
	if no_native do s.f.adapter.send_media = nil
	if closed {s.f.adapter.reply_window_ms = 1000}
	b := media_test_binding(&s); defer domain.channel_binding_destroy(&b)
	ids, held, as, _, e := channel_send_media(&s.f.service, b, "caption", media_test_out(upload)); defer window_test_ids_free(ids)
	testing.expect(t, e.code == .None && as == "link" && held == closed && len(s.kinds) == 0)
	rows := media_test_rows(&s,ids); defer media_test_free_rows(rows)
	testing.expect(t, rows[0].attachment.state == .Link && strings.contains(rows[0].body,"art_file"))
}
@(test) test_send_media_link_mode_records_link_attachment :: proc(t: ^testing.T) {media_test_link_send(t, true, true, false)}
@(test) test_send_media_window_closed_holds_link_text :: proc(t: ^testing.T) {media_test_link_send(t, true, false, true)}
@(test) test_send_media_not_uploaded_is_link :: proc(t: ^testing.T) {media_test_link_send(t, false, false, false)}
@(test)
test_send_media_total_budget_bounded :: proc(t: ^testing.T) {
	s: Media_Test_State; media_test_setup(t,&s); defer media_test_destroy(&s)
	s.f.service.media_send_budget_ms = 600; s.f.service.media_min_call_ms = 50
	s.sleep_timeout = true
	s.errors = {.Invalid_Request,.Invalid_Request}
	s.rules[1].caption = false
	b := media_test_binding(&s); defer domain.channel_binding_destroy(&b)
	start := time.tick_now()
	ids, _, _, _, e := channel_send_media(&s.f.service,b,"caption",media_test_out()); defer window_test_ids_free(ids)
	testing.expect(t, time.tick_since(start) < 800*time.Millisecond && e.code == .Provider_Unavailable && strings.contains(e.details_json,"Budget_Exhausted"))
	rows := media_test_rows(&s,ids); defer media_test_free_rows(rows)
	for row in rows {
		testing.expect_value(t,row.send_state,domain.Channel_Send_State.Failed)
		testing.expect_value(t,row.send_error,"budget_exhausted" if row.attachment.attachment_id != "" else "not_sent")
	}
}
@(test)
test_send_media_budget_leaves_caption_unsent :: proc(t: ^testing.T) {
	s: Media_Test_State; media_test_setup(t,&s); defer media_test_destroy(&s)
	s.f.service.media_send_budget_ms = 600; s.f.service.media_min_call_ms = 50; s.sleep_ms = 560
	s.rules[1].caption = false
	b := media_test_binding(&s); defer domain.channel_binding_destroy(&b)
	ids, held, as, unsent, e := channel_send_media(&s.f.service,b,"caption",media_test_out()); defer window_test_ids_free(ids)
	testing.expect(t,e.code == .None && !held && as == "native" && unsent == 1 && len(s.texts)==0)
	rows := media_test_rows(&s,ids); defer media_test_free_rows(rows)
	for row in rows do if row.attachment.attachment_id == "" do testing.expect(t,row.send_state == .Failed && row.send_error == "not_sent")
}
@(test)
test_send_media_separate_decided_once :: proc(t: ^testing.T) {
	s: Media_Test_State; media_test_setup(t,&s); defer media_test_destroy(&s)
	s.errors = {.Invalid_Request}; s.rules[1].caption = false
	b := media_test_binding(&s); defer domain.channel_binding_destroy(&b)
	ids, _, as, _, e := channel_send_media(&s.f.service,b,"caption",media_test_out()); defer window_test_ids_free(ids)
	testing.expect(t,e.code == .None && as == "native" && len(ids)==2 && len(s.captions)==2 && s.captions[0]=="" && s.captions[1]=="" && len(s.texts)==1)
}
@(test)
test_send_media_uses_send_text_within :: proc(t: ^testing.T) {
	s: Media_Test_State; media_test_setup(t,&s); defer media_test_destroy(&s)
	s.f.adapter.send_text_within = media_test_text_within; s.rules[1].caption = false
	s.f.service.media_send_budget_ms = 600; s.f.service.media_min_call_ms = 50
	b := media_test_binding(&s); defer domain.channel_binding_destroy(&b)
	ids, _, _, _, e := channel_send_media(&s.f.service,b,"caption",media_test_out()); defer window_test_ids_free(ids)
	testing.expect(t,e.code == .None && len(s.timeouts)==2 && s.timeouts[1] <= s.timeouts[0] && s.timeouts[1]>0 && s.timeouts[0]<=600)
}
@(test)
test_held_media_release_sends_link_text :: proc(t: ^testing.T) {
	s: Media_Test_State; media_test_setup(t,&s); defer media_test_destroy(&s)
	s.f.adapter.reply_window_ms = 1000
	b := media_test_binding(&s); defer domain.channel_binding_destroy(&b)
	ids, held, _, _, e := channel_send_media(&s.f.service,b,"caption",media_test_out()); defer window_test_ids_free(ids)
	testing.expect(t,e.code == .None && held)
	s.f.adapter.reply_window_ms = 0; bots_release_held(&s.f.service,b.binding_id)
	testing.expect(t,len(s.texts)==1 && strings.contains(s.texts[0],"art_file") && len(s.kinds)==0)
}
media_test_failure_kind :: proc(code: int) -> channel.Channel_Error_Kind {return .Window_Closed}
@(test)
test_delivery_failed_native_media_marks_held :: proc(t: ^testing.T) {
	s: Media_Test_State; media_test_setup(t,&s); defer media_test_destroy(&s)
	b := media_test_binding(&s); defer domain.channel_binding_destroy(&b)
	ids, _, _, _, e := channel_send_media(&s.f.service,b,"",media_test_out()); defer window_test_ids_free(ids)
	testing.expect_value(t,e.code,domain.Error_Code.None)
	s.f.adapter.failure_kind = media_test_failure_kind
	bots_on_delivery_failed(&s.f.service,&s.f.adapter,{external_chat_id="111",external_message_id="media_sent",provider_code=1})
	rows := media_test_rows(&s,ids); defer media_test_free_rows(rows)
	testing.expect(t,rows[0].send_state == .Held && strings.contains(rows[0].body,"art_file"))
}
@(test)
test_link_text_with_and_without_ui_origin :: proc(t: ^testing.T) {
	s := Bots_Service{ui_origin="https://ninjy.example///"}
	testing.expect_value(t,bots_media_link_text(&s,"caption","doc","art_1"),"caption\n\n📎 doc: https://ninjy.example/#/library/artifacts/art_1\nOpens after you sign in to Ninjy.")
	s.ui_origin=""
	testing.expect_value(t,bots_media_link_text(&s,"","","art_1"),"📎 File: open Ninjy, go to Library and find artifact art_1.")
}
@(test)
test_media_name_and_mime_cleaning :: proc(t: ^testing.T) {
	testing.expect_value(t,bots_media_mime(.Voice," Audio/OGG; codecs=opus "),"audio/ogg")
	for mime in ([]string{"", "image", "/jpg","image/","image/a/b","image/a b",strings.repeat("x",128,context.temp_allocator)}) do testing.expect_value(t,bots_media_mime(.Image,mime),"image/jpeg")
	testing.expect_value(t,bots_media_mime(.Audio,""),"audio/mpeg")
	testing.expect_value(t,bots_media_mime(.Document,""),"application/octet-stream")
	testing.expect_value(t,bots_media_name(.Image," ../a\\b\x01\x7f. ","image/png"),"_a_b__")
	testing.expect_value(t,bots_media_name(.Image,"..","image/png"),"photo.png")
	testing.expect_value(t,bots_media_name(.Voice,"\xff","audio/ogg"),"voice.ogg")
	testing.expect_value(t,bots_media_name(.Document,"","video/mp4"),"video.mp4")
	name := bots_media_name(.Document,strings.repeat("é",150,context.temp_allocator),"text/plain")
	testing.expect_value(t,len(name),200)
	for pair in ([]struct{mime,ext:string}{{"image/jpeg",".jpg"},{"image/png",".png"},{"image/webp",".webp"},{"image/gif",".gif"},{"audio/ogg",".ogg"},{"audio/mpeg",".mp3"},{"audio/mp4",".m4a"},{"audio/aac",".aac"},{"audio/amr",".amr"},{"video/mp4",".mp4"},{"video/3gpp",".3gp"},{"video/quicktime",".mov"},{"application/pdf",".pdf"},{"text/plain",".txt"},{"unknown/type",""}}) do testing.expect(t,strings.has_suffix(bots_media_name(.Document,"",pair.mime),pair.ext))
	for test in ([]struct{bytes,mime:string}{{"GIF89","image/gif"},{"RIFF1234WEBP","image/webp"},{"other","fallback"}}) do testing.expect_value(t,bots_media_sniff_image(transmute([]byte)test.bytes,"fallback"),test.mime)
}
@(test)
test_bots_media_code_is_provider_neutral :: proc(t: ^testing.T) {
	bytes, ok := os.read_entire_file("media.odin",context.temp_allocator)
	if ok != nil do bytes,ok = os.read_entire_file("src/hub/service/bots/media.odin",context.temp_allocator)
	if !testing.expect(t,ok == nil) do return
	lower := strings.to_lower(string(bytes),context.temp_allocator)
	for word in ([]string{"telegram","whatsapp","sendphoto","graph.facebook","131"}) do testing.expectf(t,!strings.contains(lower,word),"provider-specific token %s",word)
}

@(test)
test_send_media_failures_and_partial_results :: proc(t: ^testing.T) {
	for failure in ([]channel.Channel_Error_Kind{.Window_Closed,.Chat_Unavailable}) {
		s: Media_Test_State; media_test_setup(t,&s)
		s.errors={failure}; s.rules[1].caption=false
		b:=media_test_binding(&s)
		ids,held,as,_,e:=channel_send_media(&s.f.service,b,"caption",media_test_out())
		rows:=media_test_rows(&s,ids)
		if failure==.Window_Closed {
			testing.expect(t,e.code==.None && held && as=="link")
			for row in rows do testing.expect_value(t,row.send_state,domain.Channel_Send_State.Held)
		} else {
			testing.expect(t,e.code==.Provider_Unavailable && !held)
			for row in rows do testing.expect_value(t,row.send_state,domain.Channel_Send_State.Failed)
		}
		media_test_free_rows(rows);window_test_ids_free(ids);domain.channel_binding_destroy(&b);media_test_destroy(&s)
	}
	for failure in ([]channel.Channel_Error_Kind{.Window_Closed,.Chat_Unavailable}) {
		s: Media_Test_State; media_test_setup(t,&s)
		s.text_error=failure;s.rules[1].caption=false
		b:=media_test_binding(&s)
		ids,held,as,unsent,e:=channel_send_media(&s.f.service,b,"caption",media_test_out())
		testing.expect(t,e.code==.None && held==(failure==.Window_Closed) && as=="native" && unsent==(1 if failure==.Chat_Unavailable else 0))
		rows:=media_test_rows(&s,ids)
		for row in rows do if row.message_id==ids[1] do testing.expect_value(t,row.send_state,domain.Channel_Send_State.Held if held else domain.Channel_Send_State.Failed)
		media_test_free_rows(rows);window_test_ids_free(ids);domain.channel_binding_destroy(&b);media_test_destroy(&s)
	}
}
