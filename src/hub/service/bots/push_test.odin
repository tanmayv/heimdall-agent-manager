package bots
import "core:testing"
import "core:sync"
import "core:thread"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import channel "odin_test:hub/service/channel"

push_test_parse :: proc(ctx: rawptr, signature_header, raw_body: string, allocator := context.allocator) -> ([]channel.Inbound, channel.Push_Verdict) {
	batch := make([]channel.Inbound, 1, allocator)
	batch[0] = {update_key = "whatsapp:test", external_chat_id = "111", external_user_id = "222",
	external_message_id = "mid", kind = .Text, chat_is_private = true, text = "hello", provider_time = "2026-11-17T12:00:01Z"}
	return batch, .Accepted
}
push_test_enqueue :: proc(t: ^testing.T, f: ^Pairing_Fixture, kind := domain.Channel_Push_Kind.Text, key := "event") {
	n, e := iface.push_events_insert(&f.repo, []domain.Channel_Push_Event{{provider = "whatsapp", event_key = key, kind = kind,
	external_chat_id = "111", external_user_id = "222", external_message_id = "mid", body = "hello",
	provider_time = "2026-11-17T12:00:01Z", received_at = pairing_test_clock(nil)}})
	testing.expect(t, n == 1 && e.code == .None)
}
@(test)
test_push_receive_dedupes_redelivery :: proc(t: ^testing.T) {
	f := wa_pairing_fixture(t); defer pairing_fixture_destroy(f)
	f.adapter.push_parse = push_test_parse
	for i in 0..<2 {
		result, events, inserted := bots_push_receive(&f.service, "whatsapp", "", "")
		testing.expect(t, result == .Stored && events == 1 && inserted == 1-i)
	}
}
@(test)
test_intake_processes_once_and_blanks_body :: proc(t: ^testing.T) {
	f := wa_pairing_fixture(t); defer pairing_fixture_destroy(f)
	wa_test_bind(t, f)
	push_test_enqueue(t, f)
	rt := Bots_Runtime{service = &f.service}
	more, delay := bots_push_intake_iteration(&rt)
	testing.expect(t, !more && delay == 0)
	pending, e := iface.push_events_pending(&f.repo, "whatsapp", 50)
	defer {for &p in pending do domain.channel_push_event_destroy(&p); delete(pending)}
	testing.expect(t, e.code == .None && len(pending) == 0)
	stmt, err := sqlite.bot_repo_prepare(&f.conn, "SELECT body,processed_at FROM channel_push_events;", nil)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	defer sqlite.sqlite3_finalize(stmt)
	testing.expect_value(t, sqlite.sqlite3_step(stmt), sqlite.SQLITE_ROW)
	testing.expect_value(t, sqlite.column_text_unowned(stmt, 0), "")
	testing.expect(t, sqlite.column_text_unowned(stmt, 1) != "")
	_, _ = bots_push_intake_iteration(&rt)
	messages, me := iface.messages_history(&f.repo, "bot_a", -1)
	defer {for &m in messages do domain.channel_message_destroy(&m); delete(messages)}
	testing.expect(t, me.code == .None && len(messages) == 1)
}
@(test)
test_intake_commit_failure_retries_same_events :: proc(t: ^testing.T) {
	f := wa_pairing_fixture(t); defer pairing_fixture_destroy(f)
	wa_test_bind(t, f); push_test_enqueue(t, f)
	testing.expect(t, sqlite.exec(&f.conn, "CREATE TRIGGER fail_push BEFORE UPDATE ON channel_push_events BEGIN SELECT RAISE(ABORT,'injected'); END;"))
	rt := Bots_Runtime{service = &f.service}
	_, delay := bots_push_intake_iteration(&rt)
	testing.expect_value(t, delay, BOT_PUSH_INTAKE_RETRY)
	pending, e := iface.push_events_pending(&f.repo, "whatsapp", 50)
	defer {for &p in pending do domain.channel_push_event_destroy(&p); delete(pending)}
	testing.expect(t, e.code == .None && len(pending) == 1 && pending[0].body == "hello")
	b, _, _ := iface.binding_get_active_by_owner(&f.repo, "alice", "whatsapp")
	defer domain.channel_binding_destroy(&b)
	testing.expect_value(t, b.last_inbound_at, pairing_test_clock(nil))
	testing.expect(t, sqlite.exec(&f.conn, "DROP TRIGGER fail_push;"))
	_, delay = bots_push_intake_iteration(&rt)
	testing.expect_value(t, delay, time.Duration(0))
}
@(test)
test_intake_touches_last_inbound_at :: proc(t: ^testing.T) {
	f := wa_pairing_fixture(t); defer pairing_fixture_destroy(f)
	wa_test_bind(t, f); push_test_enqueue(t, f, .Unsupported)
	rt := Bots_Runtime{service = &f.service}
	_, _ = bots_push_intake_iteration(&rt)
	b, found, e := iface.binding_get_active_by_owner(&f.repo, "alice", "whatsapp")
	defer domain.channel_binding_destroy(&b)
	testing.expect(t, found && e.code == .None && b.last_inbound_at == "2026-11-17T12:00:01Z")
}
@(test)
test_intake_release_before_side_effects :: proc(t: ^testing.T) {
	s: Window_Test_State; window_test_setup(t, &s); defer window_test_destroy(&s)
	window_test_close(&s)
	b := window_test_binding(&s); defer domain.channel_binding_destroy(&b)
	ids, held, err := channel_send(&s.f.service, b, "held answer", true)
	defer window_test_ids_free(ids)
	testing.expect(t, held && err.code == .None)
	// Unsupported messages generate a notice; it must follow the released answer.
	push_test_enqueue(t, s.f, .Unsupported)
	rt := Bots_Runtime{service = &s.f.service}
	_, _ = bots_push_intake_iteration(&rt)
	testing.expect(t, len(s.sent) >= 2)
	if len(s.sent) >= 2 do testing.expect_value(t, s.sent[0], "held answer")
}
@(test)
test_runtime_starts_intake_only_with_whatsapp_and_experiment :: proc(t: ^testing.T) {
	exp := Runtime_Test_Experiments{}
	exps := iface.Experiment_Repository{ctx = &exp, count_enabled = runtime_test_count}
	adapter := channel.Channel_Adapter{}
	service := Bots_Service{experiments = &exps}
	rt := Bots_Runtime{service = &service}; defer bots_runtime_stop(&rt)
	bots_runtime_reconcile(&rt)
	testing.expect(t, !rt.intake_running)
	service.whatsapp = &adapter
	bots_runtime_reconcile(&rt)
	testing.expect(t, !rt.intake_running)
	exp.enabled = 1
	runtime_test_reconcile_in_scratch(&rt)
	testing.expect(t, rt.intake_running && rt.supervisor_running)
	bots_runtime_reconcile(&rt)
	service.whatsapp = nil
	bots_runtime_reconcile(&rt)
	testing.expect(t, !rt.intake_running && rt.supervisor_running)
	service.whatsapp = &adapter
	bots_runtime_reconcile(&rt)
	exp.fail = true
	bots_runtime_reconcile(&rt)
	testing.expect(t, !rt.intake_running && !rt.supervisor_running)
}
push_test_wake :: proc(data: rawptr) {
	rt := (^Bots_Runtime)(data)
	time.sleep(20*time.Millisecond)
	bots_runtime_signal_intake(rt)
}
@(test)
test_intake_signal_wakes_promptly :: proc(t: ^testing.T) {
	rt: Bots_Runtime
	// A signal before waiting must not be lost.
	bots_runtime_signal_intake(&rt)
	started := time.tick_now()
	testing.expect(t, !bots_intake_wait(&rt, 5*time.Second))
	testing.expect(t, time.tick_since(started) < time.Second && !rt.intake_signal)
	// thread-spawn: test helper joined before stack/runtime teardown
	worker := thread.create_and_start_with_data(&rt, push_test_wake)
	defer thread.destroy(worker)
	started = time.tick_now()
	testing.expect(t, !bots_intake_wait(&rt, 5*time.Second))
	thread.join(worker)
	testing.expect(t, time.tick_since(started) < time.Second)
	sync.atomic_store(&rt.intake_stop, true)
	testing.expect(t, bots_intake_wait(&rt, 5*time.Second))
}

push_media_parse :: proc(ctx: rawptr, signature_header, raw_body: string, allocator := context.allocator) -> ([]channel.Inbound, channel.Push_Verdict) {
	batch, verdict := push_test_parse(ctx, signature_header, raw_body, allocator)
	batch[0].kind = .Media
	batch[0].media = {.Document, "secret-media-ref", "invoice.pdf", "application/pdf", 3}
	return batch, verdict
}
push_media_fetch :: proc(ctx: rawptr, ref: string, max_bytes: i64, allocator := context.allocator) -> (channel.Fetched_Media, channel.Channel_Error) {return {}, {kind = .Media_Unavailable}}
@(test)
test_push_receive_and_intake_carry_media :: proc(t: ^testing.T) {
	f := wa_pairing_fixture(t); defer pairing_fixture_destroy(f)
	wa_test_bind(t,f)
	f.adapter.push_parse = push_media_parse
	f.adapter.media_fetch = push_media_fetch
	f.adapter.media.fetch_max_bytes = 10000
	result, events, inserted := bots_push_receive(&f.service,"whatsapp","","")
	testing.expect(t,result == .Stored && events == 1 && inserted == 1)
	pending, e := iface.push_events_pending(&f.repo,"whatsapp",50)
	defer {for &p in pending do domain.channel_push_event_destroy(&p); delete(pending)}
	testing.expect(t,e.code == .None && len(pending)==1 && pending[0].media_ref=="secret-media-ref" && pending[0].media_size==3)
	rt := Bots_Runtime{service=&f.service}
	_, delay := bots_push_intake_iteration(&rt)
	testing.expect_value(t,delay,time.Duration(0))
	messages, me := iface.messages_history(&f.repo,"bot_a",-1)
	defer {for &m in messages do domain.channel_message_destroy(&m); delete(messages)}
	testing.expect(t,me.code == .None && len(messages)==1)
	if len(messages)!=1 do return
	attachments, ae := iface.attachments_for_messages(&f.repo,{messages[0].message_id})
	defer {for &a in attachments do domain.channel_attachment_destroy(&a); delete(attachments)}
	testing.expect(t,ae.code == .None && len(attachments)==1 && attachments[0].name=="invoice.pdf" && attachments[0].mime=="application/pdf" && attachments[0].file_ref=="secret-media-ref" && attachments[0].size_bytes==3)
	stmt, se := sqlite.bot_repo_prepare(&f.conn,"SELECT media_ref,media_name FROM channel_push_events;",nil)
	defer sqlite.sqlite3_finalize(stmt)
	testing.expect(t,se.code == .None && sqlite.sqlite3_step(stmt)==sqlite.SQLITE_ROW && sqlite.column_text_unowned(stmt,0)=="" && sqlite.column_text_unowned(stmt,1)=="")
}
@(test)
test_intake_media_touches_window_and_releases_held :: proc(t: ^testing.T) {
	s: Window_Test_State; window_test_setup(t,&s); defer window_test_destroy(&s)
	window_test_close(&s)
	b := window_test_binding(&s); defer domain.channel_binding_destroy(&b)
	ids, held, e := channel_send(&s.f.service,b,"held media link",true); defer window_test_ids_free(ids)
	testing.expect(t,e.code == .None && held)
	s.f.adapter.media_fetch = push_media_fetch
	s.f.adapter.media.fetch_max_bytes = 10000
	s.f.adapter.push_parse = push_media_parse
	_,_,_ = bots_push_receive(&s.f.service,"whatsapp","","")
	rt := Bots_Runtime{service=&s.f.service}
	_, _ = bots_push_intake_iteration(&rt)
	testing.expect(t,len(s.sent)==1 && s.sent[0]=="held media link")
	updated := window_test_binding(&s); defer domain.channel_binding_destroy(&updated)
	testing.expect_value(t,updated.last_inbound_at,"2026-11-17T12:00:01Z")
}
