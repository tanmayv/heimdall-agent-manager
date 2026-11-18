package bots

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "core:unicode/utf8"
import domain "odin_test:hub/domain"
import agent_service "odin_test:hub/service/agent"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import platform "odin_test:hub/platform"
import channel "odin_test:hub/service/channel"
import events "odin_test:hub/service/events"
import httpc "odin_test:lib/httpc"

Pairing_Test_Sent :: struct {chat, text: string}
Pairing_Fixture :: struct {
	conn: sqlite.Conn,
	impl: sqlite.Bot_Repo_SQLite,
	exp_impl: sqlite.Experiment_Repo_SQLite,
	repo: iface.Bot_Repository,
	experiments: iface.Experiment_Repository,
	uow_impl: sqlite.SQLite_Unit_Of_Work_Factory,
	uow: iface.Unit_Of_Work_Factory,
	clock: platform.Clock,
	ids: platform.ID_Generator,
	adapter: channel.Channel_Adapter,
	service: Bots_Service,
	sent: [dynamic]Pairing_Test_Sent,
	sequence: int,
	event_bus: events.User_Event_Bus,
}
pairing_test_clock :: proc(ctx: rawptr) -> string {return "2026-11-17T12:00:00Z"}
pairing_test_id :: proc(ctx: rawptr, prefix: string) -> string {
	f := (^Pairing_Fixture)(ctx)
	f.sequence += 1
	return fmt.tprintf("%s%08d", prefix, f.sequence)
}
pairing_test_send :: proc(ctx: rawptr, chat, text: string) -> (string, channel.Channel_Error) {
	f := (^Pairing_Fixture)(ctx)
	append(&f.sent, Pairing_Test_Sent{strings.clone(chat), strings.clone(text)})
	return strings.clone("sent"), {}
}
pairing_test_identity :: proc(ctx: rawptr) -> (channel.Identity, channel.Channel_Error) {
	return {bot_user_id = "1", bot_username = "fake"}, {}
}
pairing_test_url :: proc(ctx: rawptr, identity: channel.Identity, code: string, allocator := context.allocator) -> string {
	return strings.concatenate({"https://t.me/",identity.bot_username,"?start=",code}, allocator)
}
pairing_fixture :: proc(t: ^testing.T) -> ^Pairing_Fixture {
	f := new(Pairing_Fixture)
	f.conn, _, _ = sqlite.open(":memory:")
	ok, err := sqlite.run_migrations(&f.conn)
	testing.expect(t, ok && err.code == .None)
	f.repo = sqlite.new_bot_repository(&f.impl, &f.conn)
	f.experiments = sqlite.new_experiment_repository(&f.exp_impl, &f.conn)
	f.uow = sqlite.new_unit_of_work_factory(&f.uow_impl, &f.conn, nil)
	f.clock = {now = pairing_test_clock}
	f.ids = {ctx = f, generate = pairing_test_id}
	f.adapter = {ctx = f, provider = "telegram", send_text = pairing_test_send, identity = pairing_test_identity, pairing_url = pairing_test_url}
	f.service = {repo = &f.repo, experiments = &f.experiments, uow_factory = &f.uow, event_bus = &f.event_bus, clock = &f.clock, ids = &f.ids, adapter = &f.adapter, timers = default_bot_timer_config()}
	testing.expect_value(t, iface.bot_insert(&f.repo, {bot_id = "bot_a", owner_user_id = "alice", agent_id = "agt_a", created_at = "now", updated_at = "now"}).code, domain.Error_Code.None)
	_, e := iface.experiment_set(&f.experiments, {owner_user_id = "alice", key = "bots", enabled = true, updated_at = "now"})
	testing.expect_value(t, e.code, domain.Error_Code.None)
	return f
}
pairing_fixture_destroy :: proc(f: ^Pairing_Fixture) {
	for m in f.sent {delete(m.chat); delete(m.text)}
	delete(f.sent)
	sqlite.close(&f.conn)
	free(f)
}
pairing_test_code :: proc(t: ^testing.T, f: ^Pairing_Fixture, code := "valid", owner := "alice", expiry := "2026-11-17T12:10:00Z", consumed := "") {
	testing.expect_value(t, iface.pairing_insert(&f.repo, {code_hash = bots_pairing_hash(code), owner_user_id = owner, bot_id = "bot_a", provider = "telegram", created_at = "2026-11-17T12:00:00Z", expires_at = expiry, consumed_at = consumed}).code, domain.Error_Code.None)
}
pairing_test_update :: proc(payload := "valid", chat := "111") -> channel.Inbound {
	return {update_key = "telegram:1:1", external_chat_id = chat, external_user_id = "222", chat_is_private = true, sender_display = "@alice", kind = .Start, text = payload}
}
pairing_test_start :: proc(t: ^testing.T, f: ^Pairing_Fixture, payload := "valid", chat := "111") {
	testing.expect_value(t, bots_pairing_start(&f.service, &f.adapter, pairing_test_update(payload, chat), pairing_test_clock(nil)).code, domain.Error_Code.None)
}
pairing_test_bound :: proc(t: ^testing.T, f: ^Pairing_Fixture, chat := "111") {
	pairing_test_code(t, f)
	pairing_test_start(t, f, chat = chat)
}
pairing_test_last :: proc(t: ^testing.T, f: ^Pairing_Fixture, expected: string) {
	if testing.expect(t, len(f.sent) > 0) do testing.expect_value(t, f.sent[len(f.sent)-1].text, expected)
}

@(test)
test_pairing_start_empty_payload :: proc(t: ^testing.T) {
	f := pairing_fixture(t); defer pairing_fixture_destroy(f)
	pairing_test_start(t, f, "")
	pairing_test_last(t, f, COPY_NOT_CONNECTED)
	pairing_test_bound(t, f)
	count := len(f.sent)
	pairing_test_start(t, f, "")
	testing.expect_value(t, len(f.sent), count)
}
@(test)
test_pairing_start_invalid_consumed_expired :: proc(t: ^testing.T) {
	f := pairing_fixture(t); defer pairing_fixture_destroy(f)
	pairing_test_code(t, f, "used", consumed = "2026-11-17T11:00:00Z")
	pairing_test_code(t, f, "expired", expiry = "2026-11-17T12:00:00Z")
	for payload in ([]string{"unknown","used","expired"}) {
		pairing_test_start(t, f, payload)
		pairing_test_last(t, f, COPY_PAIR_INVALID)
	}
}
@(test)
test_pairing_start_experiment_off :: proc(t: ^testing.T) {
	f := pairing_fixture(t); defer pairing_fixture_destroy(f)
	pairing_test_code(t, f)
	_, _ = iface.experiment_set(&f.experiments, {owner_user_id = "alice", key = "bots", enabled = false})
	pairing_test_start(t, f)
	pairing_test_last(t, f, COPY_PAIR_NOT_ENABLED)
	p, _, _ := iface.pairing_get(&f.repo, bots_pairing_hash("valid")); defer domain.channel_pairing_destroy(&p)
	testing.expect_value(t, p.consumed_at, "")
}
@(test)
test_pairing_start_no_bot :: proc(t: ^testing.T) {
	f := pairing_fixture(t); defer pairing_fixture_destroy(f)
	pairing_test_code(t, f)
	_ = iface.bot_delete(&f.repo, "bot_a")
	pairing_test_start(t, f)
	pairing_test_last(t, f, COPY_PAIR_NO_BOT)
}
@(test)
test_pairing_start_chat_taken :: proc(t: ^testing.T) {
	f := pairing_fixture(t); defer pairing_fixture_destroy(f)
	pairing_test_bound(t, f)
	_, _ = iface.experiment_set(&f.experiments, {owner_user_id = "bob", key = "bots", enabled = true})
	testing.expect_value(t, iface.bot_insert(&f.repo, {bot_id = "bot_b", owner_user_id = "bob", agent_id = "agt_b"}).code, domain.Error_Code.None)
	testing.expect_value(t, iface.pairing_insert(&f.repo, {code_hash = bots_pairing_hash("bob"), owner_user_id = "bob", bot_id = "bot_b", provider = "telegram", expires_at = "2026-11-17T12:10:00Z"}).code, domain.Error_Code.None)
	pairing_test_start(t, f, "bob")
	pairing_test_last(t, f, COPY_PAIR_CHAT_TAKEN)
	p, _, _ := iface.pairing_get(&f.repo, bots_pairing_hash("bob")); defer domain.channel_pairing_destroy(&p)
	testing.expect_value(t, p.consumed_at, "")
}
@(test)
test_pairing_start_same_owner_consumes :: proc(t: ^testing.T) {
	f := pairing_fixture(t); defer pairing_fixture_destroy(f)
	pairing_test_bound(t, f)
	before, _, _ := iface.binding_get_active_by_chat(&f.repo, "telegram", "111"); defer domain.channel_binding_destroy(&before)
	pairing_test_code(t, f, "again")
	pairing_test_start(t, f, "again")
	pairing_test_last(t, f, COPY_PAIRED)
	after, _, _ := iface.binding_get_active_by_chat(&f.repo, "telegram", "111"); defer domain.channel_binding_destroy(&after)
	testing.expect_value(t, before.binding_id, after.binding_id)
	p, _, _ := iface.pairing_get(&f.repo, bots_pairing_hash("again")); defer domain.channel_pairing_destroy(&p)
	testing.expect_value(t, p.consumed_at, pairing_test_clock(nil))
}
@(test)
test_pairing_start_activates_and_replaces :: proc(t: ^testing.T) {
	f := pairing_fixture(t); defer pairing_fixture_destroy(f)
	pairing_test_bound(t, f)
	b, _, _ := iface.binding_get_active_by_chat(&f.repo, "telegram", "111"); defer domain.channel_binding_destroy(&b)
	pairing_test_inbound(t, f, b, "chm_old", "telegram:1:old")
	testing.expect_value(t, delivery_on_inbound(&f.service, "bot_a", 1794916800000).code, domain.Error_Code.None)
	pairing_test_code(t, f, "new")
	pairing_test_start(t, f, "new", "333")
	pairing_test_last(t, f, COPY_REPLACED)
	testing.expect_value(t, f.sent[len(f.sent)-2].text, COPY_PAIRED)
	old, old_found, _ := iface.binding_get_active_by_chat(&f.repo, "telegram", "111"); defer domain.channel_binding_destroy(&old)
	active, found, _ := iface.binding_get_active_by_chat(&f.repo, "telegram", "333"); defer domain.channel_binding_destroy(&active)
	testing.expect(t, !old_found && found)
	testing.expect_value(t, active.external_display, "@alice")
	messages, _ := iface.messages_history(&f.repo, "bot_a", -1)
	defer {for &m in messages do domain.channel_message_destroy(&m); delete(messages)}
	testing.expect(t, len(messages) == 1 && messages[0].body_purged && messages[0].body == "")
}
pairing_test_inbound :: proc(t: ^testing.T, f: ^Pairing_Fixture, binding: domain.Channel_Binding, id, key: string) {
	ids, err := iface.inbound_store_batch(&f.repo, "telegram", {{message_id = id, binding_id = binding.binding_id, owner_user_id = binding.owner_user_id, bot_id = binding.bot_id, direction = .Inbound, provider_update_key = key, body = "hello", created_at = pairing_test_clock(nil)}}, "2", pairing_test_clock(nil))
	defer {for id in ids do delete(id); delete(ids)}
	testing.expect_value(t, err.code, domain.Error_Code.None)
}
@(test)
test_disconnect_purges_and_abandons :: proc(t: ^testing.T) {
	f := pairing_fixture(t); defer pairing_fixture_destroy(f)
	pairing_test_bound(t, f)
	b, _, _ := iface.binding_get_active_by_chat(&f.repo, "telegram", "111"); defer domain.channel_binding_destroy(&b)
	pairing_test_inbound(t, f, b, "chm_1", "telegram:1:1")
	testing.expect_value(t, delivery_on_inbound(&f.service, "bot_a", 1794916800000).code, domain.Error_Code.None)
	d, found, _ := iface.delivery_get_open(&f.repo, "bot_a"); defer domain.bot_delivery_destroy(&d)
	testing.expect(t, found && d.state == .Pending && d.through_message_id == "chm_1")
	testing.expect_value(t, iface.attempt_insert(&f.repo, {attempt_id = "bda_1", delivery_id = d.delivery_id, round = 1, bridge_id = "brg_a", state = .Accepted}).code, domain.Error_Code.None)
	testing.expect_value(t, bots_disconnect(&f.service, "alice", "telegram", true).code, domain.Error_Code.None)
	pairing_test_last(t, f, COPY_DISCONNECTED)
	done, _, _ := iface.delivery_get(&f.repo, d.delivery_id); defer domain.bot_delivery_destroy(&done)
	a, _, _ := iface.attempt_get(&f.repo, "bda_1"); defer domain.bot_delivery_attempt_destroy(&a)
	testing.expect(t, done.state == .Abandoned && done.finish_reason == "binding_revoked" && a.state == .Cancelled)
	messages, _ := iface.messages_history(&f.repo, "bot_a", -1)
	defer {for &m in messages do domain.channel_message_destroy(&m); delete(messages)}
	testing.expect(t, len(messages) == 1 && messages[0].body == "" && messages[0].body_purged)
	testing.expect_value(t, bots_disconnect(&f.service, "alice", "telegram", true).code, domain.Error_Code.Not_Found)
}
@(test)
test_inbound_rules_table :: proc(t: ^testing.T) {
	// One fresh binding for each row so disconnect cannot affect the others.
	for row in 1..=8 {
		f := pairing_fixture(t)
		pairing_test_bound(t, f)
		batch := []channel.Inbound{pairing_test_update()}
		u := &batch[0]
		u.kind, u.text = .Text, "hello"
		expected_rows, expected_notice := 0, ""
		switch row {
		case 1: u.chat_is_private = false; expected_notice = COPY_PRIVATE_ONLY
		case 2: u.kind, u.text = .Start, ""; // already connected: no reply
		case 3: u.external_chat_id = "999"; expected_notice = COPY_NOT_CONNECTED
		case 4: _, _ = iface.experiment_set(&f.experiments, {owner_user_id = "alice", key = "bots", enabled = false})
		case 5: u.kind = .Disconnect; expected_notice = COPY_DISCONNECTED
		case 6: u.kind = .Unsupported; expected_notice = COPY_UNSUPPORTED
		case 7: u.external_user_id = "999"
		case 8: expected_rows = 1
		}
		prior := len(f.sent)
		rows, map_err := bots_inbound_rows(&f.service, &f.adapter, batch, pairing_test_clock(nil))
		testing.expect_value(t, map_err.code, domain.Error_Code.None)
		testing.expect_value(t, len(rows), expected_rows)
		testing.expect_value(t, bots_inbound_side_effect(&f.service, &f.adapter, u^, pairing_test_clock(nil)).code, domain.Error_Code.None)
		testing.expect_value(t, len(f.sent)-prior, 1 if expected_notice != "" else 0)
		if expected_notice != "" do pairing_test_last(t, f, expected_notice)
		pairing_fixture_destroy(f)
	}
}
@(test)
test_inbound_truncation_and_delivery_transitions :: proc(t: ^testing.T) {
	f := pairing_fixture(t); defer pairing_fixture_destroy(f)
	pairing_test_bound(t, f)
	u := pairing_test_update()
	u.kind = .Text
	u.text = strings.repeat("🌏", 5000, context.temp_allocator)
	rows, _ := bots_inbound_rows(&f.service, &f.adapter, {u}, pairing_test_clock(nil))
	testing.expect(t, len(rows) == 1 && len(rows[0].body) == 16384 + len("\n[truncated]") && utf8.valid_string(rows[0].body))
	ids, err := iface.inbound_store_batch(&f.repo, "telegram", rows, "2", pairing_test_clock(nil))
	defer {for id in ids do delete(id); delete(ids)}
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, delivery_on_inbound(&f.service, "bot_a", 1794916800000).code, domain.Error_Code.None)
	d, _, _ := iface.delivery_get_open(&f.repo, "bot_a"); defer domain.bot_delivery_destroy(&d)
	testing.expect(t, d.state == .Pending && d.round == 1 && d.through_message_id == rows[0].message_id)
	u.update_key = "telegram:1:2"
	rows2, _ := bots_inbound_rows(&f.service, &f.adapter, {u}, pairing_test_clock(nil))
	ids2, _ := iface.inbound_store_batch(&f.repo, "telegram", rows2, "3", pairing_test_clock(nil))
	defer {for id in ids2 do delete(id); delete(ids2)}
	_ = delivery_on_inbound(&f.service, "bot_a", 1794916800000)
	unchanged, _, _ := iface.delivery_get_open(&f.repo, "bot_a"); defer domain.bot_delivery_destroy(&unchanged)
	testing.expect_value(t, unchanged.through_message_id, d.through_message_id)
	updated := d; updated.state, updated.waiting_reason = .Waiting, "no_bridge"
	_, _ = iface.delivery_update(&f.repo, updated, .Pending)
	_ = delivery_on_inbound(&f.service, "bot_a", 1794916800000)
	waiting, _, _ := iface.delivery_get_open(&f.repo, "bot_a"); defer domain.bot_delivery_destroy(&waiting)
	testing.expect(t, waiting.state == .Waiting && waiting.through_message_id == rows2[0].message_id)
}

@(test)
test_pairing_fake_telegram_end_to_end :: proc(t: ^testing.T) {
	ok, init_message := httpc.init()
	if !testing.expect(t, ok, init_message) do return
	f := pairing_fixture(t); defer pairing_fixture_destroy(f)
	ready := fmt.aprintf("%s/.cache/heimdall-tests/a5-pair-%d-%d.ready", os.get_env("HOME", context.temp_allocator), os.get_pid(), time.tick_now())
	defer delete(ready); defer os.remove(ready)
	child, child_err := os.process_start({command = {"node","tools/fake_telegram/server.mjs","--port","0","--ready-file",ready}})
	if !testing.expect(t, child_err == nil) do return
	defer {_ = os.process_kill(child); _, _ = os.process_wait(child)}
	base_text := ""
	for _ in 0..<250 {
		bytes, read_err := os.read_entire_file(ready, context.allocator)
		if read_err == nil {base_text = string(bytes); break}
		time.sleep(20 * time.Millisecond)
	}
	defer delete(base_text)
	if !testing.expect(t, base_text != "") do return
	telegram := channel.Telegram_Adapter{token = "TEST:FAKE", api_base = base_text}
	defer channel.telegram_destroy(&telegram)
	f.adapter = channel.telegram_adapter(&telegram)
	link, link_err := bots_pairing_create(&f.service, "alice", "telegram")
	defer {delete(link.pairing_url); delete(link.expires_at)}
	if !testing.expect_value(t, link_err.code, domain.Error_Code.None) do return
	code := link.pairing_url[strings.index(link.pairing_url, "?start=")+7:]
	testing.expect(t, len(code) == 32)
	pairing, present, _ := iface.pairing_get(&f.repo, bots_pairing_hash(code))
	defer domain.channel_pairing_destroy(&pairing)
	testing.expect(t, present && pairing.code_hash != code && len(pairing.code_hash) == 64 && pairing.expires_at == link.expires_at)
	base, _ := httpc.parse_url(base_text)
	resp, send_err := httpc.send({method = .POST, url = base, path = {"_control","inject"},
		body = httpc.json_body(struct {chat_id, from_id: int, username, text, chat_type: string}{111,222,"alice",fmt.tprintf("/start %s",code),"private"})})
	testing.expect(t, send_err == .None && resp.status == 200)
	httpc.response_destroy(&resp)
	rt := Bots_Runtime{service = &f.service}
	backoff := time.Second
	_, _ = bots_poller_iteration(&rt, &backoff)
	binding, bound, binding_err := iface.binding_get_active_by_chat(&f.repo, "telegram", "111")
	defer domain.channel_binding_destroy(&binding)
	testing.expect(t, bound && binding_err.code == .None && binding.external_user_id == "222")
	sent, sent_err := httpc.send({url = base, path = {"_control","sent"}, query = {{"chat_id","111"}}})
	defer httpc.response_destroy(&sent)
	wire: struct {messages: []struct {text: string}}
	_ = json.unmarshal(sent.body, &wire, allocator = context.temp_allocator)
	testing.expect(t, sent_err == .None && len(wire.messages) == 1 && wire.messages[0].text == COPY_PAIRED)

	text_resp, _ := httpc.send({method = .POST, url = base, path = {"_control","inject"},
		body = httpc.json_body(struct {chat_id, from_id: int, text: string}{111,222,"hello from Telegram"})})
	httpc.response_destroy(&text_resp)
	_, _ = bots_poller_iteration(&rt, &backoff)
	d, open, delivery_err := iface.delivery_get_open(&f.repo, "bot_a")
	defer domain.bot_delivery_destroy(&d)
	testing.expect(t, open && delivery_err.code == .None && d.state == .Pending && d.round == 1)
	messages, _ := iface.messages_pending(&f.repo, "bot_a", -1)
	defer {for &m in messages do domain.channel_message_destroy(&m); delete(messages)}
	testing.expect(t, len(messages) == 1 && messages[0].body == "hello from Telegram" && messages[0].message_id == d.through_message_id)
	attempts, _ := iface.attempt_list_for_delivery(&f.repo, d.delivery_id)
	defer {for &a in attempts do domain.bot_delivery_attempt_destroy(&a); delete(attempts)}
	testing.expect_value(t, len(attempts), 0)
}

@(test)
test_pairing_link_rotates_and_stores_hash_only :: proc(t: ^testing.T) {
	f := pairing_fixture(t); defer pairing_fixture_destroy(f)
	testing.expect_value(t, bots_pairing_hash("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
	first, first_err := bots_pairing_create(&f.service, "alice", "telegram")
	defer {delete(first.pairing_url); delete(first.expires_at)}
	testing.expect_value(t, first_err.code, domain.Error_Code.None)
	code := first.pairing_url[strings.index(first.pairing_url,"?start=")+7:]
	testing.expect_value(t, len(code), 32)
	for c in code do testing.expect(t, (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
	testing.expect_value(t, first.expires_at, "2026-11-17T12:10:00Z")
	second, second_err := bots_pairing_create(&f.service, "alice", "telegram")
	defer {delete(second.pairing_url); delete(second.expires_at)}
	testing.expect_value(t, second_err.code, domain.Error_Code.None)
	old, old_found, _ := iface.pairing_get(&f.repo,bots_pairing_hash(code)); defer domain.channel_pairing_destroy(&old)
	testing.expect(t, !old_found && first.pairing_url != second.pairing_url)
	plaintext, plaintext_found, _ := iface.pairing_get(&f.repo,code); defer domain.channel_pairing_destroy(&plaintext)
	testing.expect(t, !plaintext_found)
}
@(test)
test_disconnect_rolls_back_on_delivery_write_failure :: proc(t: ^testing.T) {
	f := pairing_fixture(t); defer pairing_fixture_destroy(f)
	pairing_test_bound(t,f)
	b, _, _ := iface.binding_get_active_by_chat(&f.repo,"telegram","111"); defer domain.channel_binding_destroy(&b)
	pairing_test_inbound(t,f,b,"chm_1","telegram:1:1")
	_ = delivery_on_inbound(&f.service,"bot_a",1794916800000)
	testing.expect(t,sqlite.exec(&f.conn,"CREATE TRIGGER fail_disconnect BEFORE UPDATE ON bot_deliveries BEGIN SELECT RAISE(ABORT, 'test failure'); END;"))
	prior := len(f.sent)
	testing.expect(t,bots_disconnect(&f.service,"alice", "telegram",true).code != .None)
	binding, found, _ := iface.binding_get_active_by_chat(&f.repo,"telegram","111"); defer domain.channel_binding_destroy(&binding)
	messages, _ := iface.messages_history(&f.repo,"bot_a",-1)
	defer {for &m in messages do domain.channel_message_destroy(&m); delete(messages)}
	testing.expect(t,found && len(messages)==1 && !messages[0].body_purged && messages[0].body=="hello" && len(f.sent)==prior)
}

// In-process WhatsApp adapter: no external provider or live runtime.
wa_pairing_fixture :: proc(t: ^testing.T) -> ^Pairing_Fixture {
	f := pairing_fixture(t)
	f.adapter.provider = "whatsapp"
	f.adapter.identity = wa_pairing_identity
	f.adapter.pairing_url = wa_pairing_url
	f.adapter.pairing_text = wa_pairing_text
	f.adapter.reply_window_ms = 86_400_000
	f.service.whatsapp, f.service.adapter = &f.adapter, nil
	return f
}
wa_pairing_identity :: proc(ctx: rawptr) -> (channel.Identity, channel.Channel_Error) {
	return {bot_user_id = "phone_fake", bot_username = "15550100001"}, {}
}
wa_pairing_text :: proc(ctx: rawptr, code: string, allocator := context.allocator) -> string {
	return strings.concatenate({"Connect Ninjy ", code}, allocator)
}
wa_pairing_url :: proc(ctx: rawptr, identity: channel.Identity, code: string, allocator := context.allocator) -> string {
	return strings.concatenate({"https://wa.me/", identity.bot_username, "?text=Connect%20Ninjy%20", code}, allocator)
}
wa_test_code :: proc(t: ^testing.T, f: ^Pairing_Fixture, code := "valid", owner := "alice", expiry := "2026-11-17T12:10:00Z", consumed := "") {
	testing.expect_value(t, iface.pairing_insert(&f.repo, {code_hash = bots_pairing_hash(code), owner_user_id = owner, bot_id = "bot_a", provider = "whatsapp", created_at = pairing_test_clock(nil), expires_at = expiry, consumed_at = consumed}).code, domain.Error_Code.None)
}
wa_test_bind :: proc(t: ^testing.T, f: ^Pairing_Fixture, code := "valid", chat := "111", user := "222") {
	wa_test_code(t, f, code)
	u := pairing_test_update(code, chat)
	u.external_user_id = user
	testing.expect_value(t, bots_pairing_start(&f.service, &f.adapter, u, pairing_test_clock(nil)).code, domain.Error_Code.None)
}
@(test)
test_whatsapp_pairing_link_and_text :: proc(t: ^testing.T) {
	f := wa_pairing_fixture(t); defer pairing_fixture_destroy(f)
	link, err := bots_pairing_create(&f.service, "alice", "whatsapp")
	defer {delete(link.pairing_url); delete(link.pairing_text); delete(link.expires_at)}
	if !testing.expect_value(t, err.code, domain.Error_Code.None) do return
	code := link.pairing_text[len("Connect Ninjy "):]
	testing.expect_value(t, len(code), 32)
	testing.expect_value(t, link.pairing_url, strings.concatenate({"https://wa.me/15550100001?text=Connect%20Ninjy%20", code}, context.temp_allocator))
	testing.expect_value(t, link.expires_at, "2026-11-17T12:10:00Z")
	pairing, found, get_err := iface.pairing_get(&f.repo, bots_pairing_hash(code))
	defer domain.channel_pairing_destroy(&pairing)
	testing.expect(t, found && get_err.code == .None && pairing.provider == "whatsapp" && pairing.code_hash != code)
}
@(test)
test_whatsapp_pairing_rules_use_whatsapp_copy :: proc(t: ^testing.T) {
	// All seven pairing rules, plus consumed/expired and empty-bound variants.
	for row in 1..=11 {
		f := wa_pairing_fixture(t)
		u := pairing_test_update()
		expected := COPY_WA_PAIRED
		wa_test_code(t, f)
		switch row {
		case 1: u.text = ""; expected = COPY_WA_NOT_CONNECTED
		case 2: u.text = "missing"; expected = COPY_WA_PAIR_INVALID
		case 3: wa_test_code(t, f, "used", consumed = pairing_test_clock(nil)); u.text = "used"; expected = COPY_WA_PAIR_INVALID
		case 4: wa_test_code(t, f, "expired", expiry = pairing_test_clock(nil)); u.text = "expired"; expected = COPY_WA_PAIR_INVALID
		case 5:
			_, _ = iface.experiment_set(&f.experiments, {owner_user_id = "alice", key = "bots", enabled = false})
			expected = COPY_PAIR_NOT_ENABLED
		case 6: _ = iface.bot_delete(&f.repo, "bot_a"); expected = COPY_PAIR_NO_BOT
		case 7:
			testing.expect(t, sqlite.exec(&f.conn, "INSERT INTO channel_bindings(binding_id,owner_user_id,bot_id,provider,external_chat_id,external_user_id,state,created_at,last_inbound_at) VALUES('chb_bob','bob','bot_b','whatsapp','111','222','active','2026-11-17T12:00:00Z','2026-11-17T12:00:00Z');"))
			expected = COPY_WA_CHAT_TAKEN
		case 8: wa_test_bind(t, f, "first")
		case 9: // first connection
		case 10: wa_test_bind(t, f, "old", "333", "444"); expected = COPY_WA_REPLACED
		case 11: wa_test_bind(t, f, "first"); u.text = ""; expected = ""
		}
		before := len(f.sent)
		testing.expect_value(t, bots_pairing_start(&f.service, &f.adapter, u, pairing_test_clock(nil)).code, domain.Error_Code.None)
		testing.expect_value(t, len(f.sent)-before, 0 if expected == "" else (2 if row == 10 else 1))
		if expected != "" do pairing_test_last(t, f, expected)
		if row == 7 {
			code, _, _ := iface.pairing_get(&f.repo, bots_pairing_hash("valid"))
			testing.expect_value(t, code.consumed_at, "")
			domain.channel_pairing_destroy(&code)
		}
		if row == 8 || row == 9 || row == 10 {
			b, found, _ := iface.binding_get_active_by_owner(&f.repo, "alice", "whatsapp")
			testing.expect(t, found && b.external_chat_id == "111")
			domain.channel_binding_destroy(&b)
		}
		pairing_fixture_destroy(f)
	}
}
@(test)
test_pairing_sets_last_inbound_at :: proc(t: ^testing.T) {
	for provider_time in ([]string{"", "2026-11-17T11:59:00Z"}) {
		f := wa_pairing_fixture(t)
		wa_test_code(t, f)
		u := pairing_test_update()
		u.provider_time = provider_time
		testing.expect_value(t, bots_pairing_start(&f.service, &f.adapter, u, pairing_test_clock(nil)).code, domain.Error_Code.None)
		b, found, _ := iface.binding_get_active_by_owner(&f.repo, "alice", "whatsapp")
		testing.expect(t, found)
		testing.expect_value(t, b.last_inbound_at, provider_time if provider_time != "" else pairing_test_clock(nil))
		testing.expect_value(t, b.external_display, "@alice")
		domain.channel_binding_destroy(&b)
		pairing_fixture_destroy(f)
	}
}
@(test)
test_inbound_lookup_falls_back_to_user_id :: proc(t: ^testing.T) {
	f := wa_pairing_fixture(t); defer pairing_fixture_destroy(f)
	wa_test_bind(t, f)
	b, found, err := bots_find_binding(&f.service, "whatsapp", "new-chat", "222")
	defer domain.channel_binding_destroy(&b)
	testing.expect(t, found && err.code == .None && b.external_chat_id == "111")
	none, missing, _ := bots_find_binding(&f.service, "whatsapp", "new-chat", "")
	defer domain.channel_binding_destroy(&none)
	testing.expect(t, !missing)
	tg := pairing_fixture(t); defer pairing_fixture_destroy(tg)
	pairing_test_bound(t, tg)
	other, tg_found, tg_err := bots_find_binding(&tg.service, "telegram", "new-chat", "222")
	defer domain.channel_binding_destroy(&other)
	testing.expect(t, !tg_found && tg_err.code == .None)
	u := pairing_test_update()
	u.kind, u.external_chat_id = .Text, "new-chat"
	rows, rows_err := bots_inbound_rows(&f.service, &f.adapter, {u}, pairing_test_clock(nil))
	testing.expect(t, rows_err.code == .None && len(rows) == 1 && rows[0].binding_id == b.binding_id)
}
wa_test_second_channel :: proc(t: ^testing.T, f: ^Pairing_Fixture, a: ^channel.Channel_Adapter) {
	a^ = f.adapter
	a.provider = "whatsapp"
	f.service.whatsapp = a
	wa_test_code(t, f, "wa-second")
	testing.expect_value(t, bots_pairing_start(&f.service, a, pairing_test_update("wa-second", "333"), pairing_test_clock(nil)).code, domain.Error_Code.None)
}
@(test)
test_disconnect_is_provider_scoped :: proc(t: ^testing.T) {
	f := pairing_fixture(t); defer pairing_fixture_destroy(f)
	pairing_test_bound(t, f)
	wa: channel.Channel_Adapter
	wa_test_second_channel(t, f, &wa)
	testing.expect_value(t, bots_disconnect(&f.service, "alice", "whatsapp", true).code, domain.Error_Code.None)
	tg, tg_found, _ := iface.binding_get_active_by_owner(&f.repo, "alice", "telegram")
	wab, wa_found, _ := iface.binding_get_active_by_owner(&f.repo, "alice", "whatsapp")
	defer {domain.channel_binding_destroy(&tg); domain.channel_binding_destroy(&wab)}
	testing.expect(t, tg_found && !wa_found)
}
wa_test_owned_send :: proc(ctx: rawptr, chat, text: string) -> (string, channel.Channel_Error) {
	f := (^Pairing_Fixture)(ctx)
	allocator := f.sent.allocator
	append(&f.sent, Pairing_Test_Sent{strings.clone(chat, allocator), strings.clone(text, allocator)})
	return strings.clone("sent"), {}
}
pairing_delete_agent_get :: proc(ctx: rawptr, id: string) -> (domain.Agent, bool, domain.Domain_Error) {
	return {agent_id = "agt_a", owner_user_id = "alice"}, true, {}
}
pairing_delete_agent_save :: proc(ctx: rawptr, agent: domain.Agent) -> (domain.Agent, bool, domain.Domain_Error) {
	assert(agent.state == .Archived)
	return agent, true, {}
}
@(test)
test_delete_bot_disconnects_both_providers :: proc(t: ^testing.T) {
	f := pairing_fixture(t); defer pairing_fixture_destroy(f)
	pairing_test_bound(t, f)
	wa: channel.Channel_Adapter
	wa_test_second_channel(t, f, &wa)
	f.adapter.send_text, wa.send_text = wa_test_owned_send, wa_test_owned_send
	agents := iface.Agent_Repository{get = pairing_delete_agent_get, save = pairing_delete_agent_save}
	agent_svc := agent_service.Agent_Service{agents = &agents, clock = &f.clock}
	f.service.agents = &agent_svc
	wa_test_code(t, f, "pending-wa")
	pairing_test_code(t, f, "pending-tg")
	testing.expect_value(t, bots_delete(&f.service, {kind = .Internal_User, user_id = "alice"}).code, domain.Error_Code.None)
	for provider in ([]string{"telegram", "whatsapp"}) {
		b, found, _ := iface.binding_get_active_by_owner(&f.repo, "alice", provider)
		domain.channel_binding_destroy(&b)
		testing.expect(t, !found)
	}
	for code in ([]string{"pending-wa", "pending-tg"}) {
		pairing, found, _ := iface.pairing_get(&f.repo, bots_pairing_hash(code))
		domain.channel_pairing_destroy(&pairing)
		testing.expect(t, !found)
	}
}
@(test)
test_notice_goes_to_origin_channel :: proc(t: ^testing.T) {
	f := pairing_fixture(t); defer pairing_fixture_destroy(f)
	pairing_test_bound(t, f)
	wa: channel.Channel_Adapter
	wa_test_second_channel(t, f, &wa)
	wa.reply_window_ms = 86_400_000
	wa.send_text, f.adapter.send_text = wa_test_owned_send, wa_test_owned_send
	defer bots_service_destroy(&f.service)
	b, _, _ := iface.binding_get_active_by_owner(&f.repo, "alice", "whatsapp")
	defer domain.channel_binding_destroy(&b)
	ids, insert_err := iface.inbound_store_batch(&f.repo, "whatsapp", {{message_id = "chm_wa_origin", binding_id = b.binding_id, owner_user_id = "alice", bot_id = "bot_a", direction = .Inbound, provider_update_key = "wa:origin", body = "hello", created_at = pairing_test_clock(nil)}}, "", pairing_test_clock(nil))
	defer {for id in ids do delete(id); delete(ids)}
	testing.expect_value(t, insert_err.code, domain.Error_Code.None)
	target, found, err := bots_notice_binding(&f.service, "alice", "bot_a", "chm_wa_origin")
	defer domain.channel_binding_destroy(&target)
	testing.expect(t, found && err.code == .None && target.provider == "whatsapp")
	testing.expect_value(t, iface.delivery_insert(&f.repo, {delivery_id = "bdl_wa_notice", owner_user_id = "alice", bot_id = "bot_a", through_message_id = "chm_wa_origin", state = .Waiting, round = 1, waiting_reason = "relocation_stranded", created_at = pairing_test_clock(nil), updated_at = pairing_test_clock(nil)}).code, domain.Error_Code.None)
	before_tick := len(f.sent)
	bots_supervisor_tick(&f.service)
	testing.expect(t, len(f.sent) == before_tick + 1 && f.sent[len(f.sent)-1].chat == "333" && f.sent[len(f.sent)-1].text == COPY_NO_MACHINE)
	bots_queue_gave_up_locked(&f.service, "alice", "bot_a", "chm_wa_origin")
	before_tick = len(f.sent)
	bots_supervisor_tick(&f.service)
	testing.expect(t, len(f.sent) == before_tick + 1 && f.sent[len(f.sent)-1].chat == "333" && f.sent[len(f.sent)-1].text == COPY_GAVE_UP)
	before := len(f.sent)
	bots_notice(&f.service, target.provider, target.external_chat_id, COPY_NO_MACHINE)
	testing.expect(t, len(f.sent) == before + 1 && f.sent[len(f.sent)-1].chat == "333")
	testing.expect(t, sqlite.exec(&f.conn, "UPDATE channel_bindings SET last_inbound_at='2026-11-15T00:00:00Z' WHERE provider='whatsapp';"))
	before = len(f.sent)
	bots_notice(&f.service, target.provider, target.external_chat_id, COPY_GAVE_UP)
	testing.expect_value(t, len(f.sent), before)
}
@(test)
test_telegram_inbound_rules_unchanged :: proc(t: ^testing.T) {
	test_inbound_rules_table(t)
}

@(test)
test_closed_window_disconnect_notice_is_not_sent_or_held :: proc(t: ^testing.T) {
	f := wa_pairing_fixture(t); defer pairing_fixture_destroy(f)
	wa_test_bind(t, f)
	testing.expect(t, sqlite.exec(&f.conn, "UPDATE channel_bindings SET last_inbound_at='2000-01-01T00:00:00Z';"))
	before := len(f.sent)
	testing.expect_value(t, bots_disconnect(&f.service, "alice", "whatsapp", true).code, domain.Error_Code.None)
	testing.expect_value(t, len(f.sent), before)
	messages, err := iface.messages_history(&f.repo, "bot_a", -1)
	defer {for &m in messages do domain.channel_message_destroy(&m); delete(messages)}
	testing.expect(t, err.code == .None && len(messages) == 0)
}
