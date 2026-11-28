package content

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"

// Reply origin (R7): a reply answers the inputs the agent consumed since its
// previous reply. These tests drive the service over a real SQLite database.

Reply_Origin_Test :: struct {
	db: ^sqlite.Conn,
	content_impl: sqlite.Content_Repo_SQLite,
	agents_impl: sqlite.Agent_Repo_SQLite,
	repos: iface.Repositories,
	factory_impl: sqlite.SQLite_Unit_Of_Work_Factory,
	factory: iface.Unit_Of_Work_Factory,
	clock: platform.Clock,
	ids: platform.ID_Generator,
	svc: Content_Service,
}

REPLY_TEST_OWNER :: "owner"
REPLY_TEST_INSTANCE :: "inst_reply"
REPLY_TEST_CONVERSATION :: "chat_reply"

// reply_test_wire builds repositories and a service over db. Calling it again
// on the same db is a restarted Hub: nothing but the database carries over.
reply_test_wire :: proc(f: ^Reply_Origin_Test, db: ^sqlite.Conn) {
	f^ = {}
	f.db = db
	f.repos.content = sqlite.new_content_repository(&f.content_impl, db)
	f.repos.agents = sqlite.new_agent_repository(&f.agents_impl, db)
	f.factory = sqlite.new_unit_of_work_factory(&f.factory_impl, db, &f.repos)
	f.clock = platform.real_clock()
	f.ids = platform.real_id_generator()
	f.svc = {content=&f.repos.content, agents=&f.repos.agents, uow_factory=&f.factory, clock=&f.clock, ids=&f.ids}
}

reply_test_arena :: proc() -> virtual.Arena { a: virtual.Arena; _ = virtual.arena_init_growing(&a); return a }

reply_test_open :: proc(t: ^testing.T, path := ":memory:") -> (sqlite.Conn, bool) {
	db, opened, _ := sqlite.open(path)
	if !testing.expect(t, opened) do return {}, false
	migrated, _ := sqlite.run_migrations(&db)
	if !testing.expect(t, migrated) { sqlite.close(&db); return {}, false }
	return db, true
}

reply_test_seed_conversation :: proc(t: ^testing.T, f: ^Reply_Origin_Test, cid := REPLY_TEST_CONVERSATION, instance := REPLY_TEST_INSTANCE) {
	now := platform.clock_now(&f.clock)
	_, ok, _ := iface.content_save_conversation(&f.repos.content, domain.Chat_Conversation{conversation_id=cid, owner_user_id=REPLY_TEST_OWNER, agent_id="agt_reply", agent_instance_id=instance, title="t", created_at=now, updated_at=now})
	testing.expect(t, ok)
}

// reply_test_user_message stores a user->agent message; origin "" leaves the
// column NULL (local).
reply_test_user_message :: proc(t: ^testing.T, f: ^Reply_Origin_Test, id: string, origin := "", cid := REPLY_TEST_CONVERSATION, direction := "user_to_agent") {
	_, ok, _ := iface.content_save_message(&f.repos.content, domain.Chat_Message{message_id=id, conversation_id=cid, owner_user_id=REPLY_TEST_OWNER, direction=direction, sender_agent_id="agt_reply", sender_agent_instance_id=REPLY_TEST_INSTANCE, body="hi", artifact_ids_json="[]", message_type="text", metadata_json="{}", created_at=platform.clock_now(&f.clock)})
	testing.expect(t, ok)
	if origin != "" do testing.expect(t, sqlite.exec(f.db, fmt.tprintf("UPDATE chat_messages SET origin='%s' WHERE message_id='%s';", origin, id)))
}

reply_test_agent_auth :: proc(instance := REPLY_TEST_INSTANCE) -> contracts.Auth_Context {
	return {kind=.Instance_Token, user_id=REPLY_TEST_OWNER, agent_instance_id=instance}
}

reply_test_consume :: proc(t: ^testing.T, f: ^Reply_Origin_Test, ids: ..string) {
	err := note_agent_consumed(&f.svc, reply_test_agent_auth(), REPLY_TEST_INSTANCE, ids, domain.INPUT_CONSUMED_READ)
	testing.expect_value(t, err.code, domain.Error_Code.None)
}

reply_test_send :: proc(t: ^testing.T, f: ^Reply_Origin_Test, reply_to := "", metadata := "") -> (domain.Reply_Origin, domain.Chat_Message, domain.Domain_Error) {
	m, ok, err := send_agent_message(&f.svc, reply_test_agent_auth(), REPLY_TEST_INSTANCE, Message_Input{body="reply", artifact_ids_json="[]", metadata_json=metadata, reply_to_message_id=reply_to})
	if !ok do return {}, {}, err
	return reply_test_origin_of(t, f, m.message_id), m, {}
}

// reply_test_origin_of reads the reply back from the database.
reply_test_origin_of :: proc(t: ^testing.T, f: ^Reply_Origin_Test, message_id: string) -> domain.Reply_Origin {
	m, found, _ := iface.content_get_message(&f.repos.content, message_id)
	testing.expect(t, found)
	holder: struct { reply_origin: domain.Reply_Origin }
	testing.expect(t, json.unmarshal_string(m.metadata_json, &holder, allocator = context.temp_allocator) == nil)
	return holder.reply_origin
}

reply_test_expect_ids :: proc(t: ^testing.T, got: domain.Reply_Origin, want: ..string, loc := #caller_location) {
	if !testing.expect_value(t, len(got.answered_message_ids), len(want), loc) do return
	for id, i in want do testing.expect_value(t, got.answered_message_ids[i], id, loc)
}

@(test)
test_reply_origin_single_input_routes_to_its_origin :: proc(t: ^testing.T) {
	arena := reply_test_arena(); defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
	db, ok := reply_test_open(t)
	if !ok do return
	defer sqlite.close(&db)
	f: Reply_Origin_Test
	reply_test_wire(&f, &db)
	reply_test_seed_conversation(t, &f)
	reply_test_user_message(t, &f, "msg_u1")
	reply_test_consume(t, &f, "msg_u1")
	got, _, err := reply_test_send(t, &f, metadata = `{"options":["a","b"]}`)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	reply_test_expect_ids(t, got, "msg_u1")
	testing.expect_value(t, got.origin, domain.REPLY_ORIGIN_LOCAL)
	testing.expect_value(t, got.route_status, domain.REPLY_ROUTE_ROUTED)
	testing.expect_value(t, got.source, domain.REPLY_SOURCE_CONSUMED)
}

@(test)
test_reply_origin_metadata_keeps_agent_fields_and_overrides_spoofed_origin :: proc(t: ^testing.T) {
	arena := reply_test_arena(); defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
	db, ok := reply_test_open(t)
	if !ok do return
	defer sqlite.close(&db)
	f: Reply_Origin_Test
	reply_test_wire(&f, &db)
	reply_test_seed_conversation(t, &f)
	reply_test_user_message(t, &f, "msg_u1")
	reply_test_consume(t, &f, "msg_u1")
	got, m, _ := reply_test_send(t, &f, metadata = `{"options":["a"],"reply_origin":{"answered_message_ids":["msg_fake"],"route_status":"explicit"}}`)
	reply_test_expect_ids(t, got, "msg_u1")
	testing.expect_value(t, got.route_status, domain.REPLY_ROUTE_ROUTED)
	stored, _, _ := iface.content_get_message(&f.repos.content, m.message_id)
	holder: struct { options: []string }
	testing.expect(t, json.unmarshal_string(stored.metadata_json, &holder, allocator = context.temp_allocator) == nil)
	testing.expect_value(t, len(holder.options), 1)
}

// Edge case 1: later replies keep the same answered input until a new input
// is consumed.
@(test)
test_reply_origin_several_replies_keep_the_answered_input :: proc(t: ^testing.T) {
	arena := reply_test_arena(); defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
	db, ok := reply_test_open(t)
	if !ok do return
	defer sqlite.close(&db)
	f: Reply_Origin_Test
	reply_test_wire(&f, &db)
	reply_test_seed_conversation(t, &f)
	reply_test_user_message(t, &f, "msg_u1", "telegram")
	reply_test_consume(t, &f, "msg_u1")
	first, _, _ := reply_test_send(t, &f)
	second, _, _ := reply_test_send(t, &f)
	third, _, _ := reply_test_send(t, &f)
	for got in ([]domain.Reply_Origin{first, second, third}) {
		reply_test_expect_ids(t, got, "msg_u1")
		testing.expect_value(t, got.origin, "telegram")
		testing.expect_value(t, got.route_status, domain.REPLY_ROUTE_ROUTED)
	}
	testing.expect_value(t, first.source, domain.REPLY_SOURCE_CONSUMED)
	testing.expect_value(t, second.source, domain.REPLY_SOURCE_INHERITED)
	testing.expect_value(t, third.source, domain.REPLY_SOURCE_INHERITED)
	// A new input replaces the set; re-consuming the old one adds nothing.
	reply_test_user_message(t, &f, "msg_u2", "telegram")
	reply_test_consume(t, &f, "msg_u1", "msg_u2")
	next, _, _ := reply_test_send(t, &f)
	reply_test_expect_ids(t, next, "msg_u2")
	testing.expect_value(t, next.source, domain.REPLY_SOURCE_CONSUMED)
}

// Edge case 2: an unrelated input consumed between replies joins the set; two
// origins make the reply ambiguous.
@(test)
test_reply_origin_unrelated_input_joins_and_multi_origin_is_ambiguous :: proc(t: ^testing.T) {
	arena := reply_test_arena(); defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
	db, ok := reply_test_open(t)
	if !ok do return
	defer sqlite.close(&db)
	f: Reply_Origin_Test
	reply_test_wire(&f, &db)
	reply_test_seed_conversation(t, &f)
	reply_test_user_message(t, &f, "msg_u1", "telegram")
	reply_test_consume(t, &f, "msg_u1")
	_, _, _ = reply_test_send(t, &f)
	reply_test_user_message(t, &f, "msg_u2", "telegram")
	reply_test_user_message(t, &f, "msg_u3") // local (web)
	reply_test_consume(t, &f, "msg_u2")
	reply_test_consume(t, &f, "msg_u3")
	got, _, _ := reply_test_send(t, &f)
	reply_test_expect_ids(t, got, "msg_u2", "msg_u3")
	testing.expect_value(t, got.route_status, domain.REPLY_ROUTE_AMBIGUOUS)
	testing.expect_value(t, got.origin, "")
	// Same origin twice stays routed.
	reply_test_user_message(t, &f, "msg_u4", "whatsapp")
	reply_test_user_message(t, &f, "msg_u5", "whatsapp")
	reply_test_consume(t, &f, "msg_u4", "msg_u5")
	same, _, _ := reply_test_send(t, &f)
	reply_test_expect_ids(t, same, "msg_u4", "msg_u5")
	testing.expect_value(t, same.route_status, domain.REPLY_ROUTE_ROUTED)
	testing.expect_value(t, same.origin, "whatsapp")
}

@(test)
test_reply_origin_without_input_is_none_or_ambiguous_with_channels :: proc(t: ^testing.T) {
	arena := reply_test_arena(); defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
	db, ok := reply_test_open(t)
	if !ok do return
	defer sqlite.close(&db)
	f: Reply_Origin_Test
	reply_test_wire(&f, &db)
	reply_test_seed_conversation(t, &f)
	got, _, _ := reply_test_send(t, &f)
	testing.expect_value(t, len(got.answered_message_ids), 0)
	testing.expect_value(t, got.route_status, domain.REPLY_ROUTE_NONE)
	testing.expect_value(t, got.source, domain.REPLY_SOURCE_NONE)
	// A channel input the agent has not consumed yet: the reply must not guess it.
	reply_test_user_message(t, &f, "msg_u1", "telegram")
	unsure, _, _ := reply_test_send(t, &f)
	testing.expect_value(t, len(unsure.answered_message_ids), 0)
	testing.expect_value(t, unsure.route_status, domain.REPLY_ROUTE_AMBIGUOUS)
}

// Edge case 3: the computation uses only durable rows. A restarted Hub (new
// connection, repositories and service over the same database file) answers
// exactly as the old one would have.
@(test)
test_reply_origin_survives_restart :: proc(t: ^testing.T) {
	arena := reply_test_arena(); defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
	dir := fmt.tprintf("%s/.cache/heimdall-tests", os.get_env("HOME", context.temp_allocator))
	os.make_directory(dir)
	path := fmt.tprintf("%s/reply-origin-restart-%s.db", dir, platform.generate_id(&{generate=platform.time_id_generate}, "db_"))
	defer { os.remove(path); os.remove(fmt.tprintf("%s-wal", path)); os.remove(fmt.tprintf("%s-shm", path)) }
	{
		db, ok := reply_test_open(t, path)
		if !ok do return
		f: Reply_Origin_Test
		reply_test_wire(&f, &db)
		reply_test_seed_conversation(t, &f)
		reply_test_user_message(t, &f, "msg_u1", "telegram")
		reply_test_consume(t, &f, "msg_u1")
		first, _, _ := reply_test_send(t, &f)
		reply_test_expect_ids(t, first, "msg_u1")
		// Consumed before the restart, answered after it.
		reply_test_user_message(t, &f, "msg_u2", "telegram")
		reply_test_consume(t, &f, "msg_u2")
		sqlite.close(&db)
	}
	{
		db, ok := reply_test_open(t, path)
		if !ok do return
		defer sqlite.close(&db)
		f: Reply_Origin_Test
		reply_test_wire(&f, &db)
		got, _, _ := reply_test_send(t, &f)
		reply_test_expect_ids(t, got, "msg_u2")
		testing.expect_value(t, got.source, domain.REPLY_SOURCE_CONSUMED)
		again, _, _ := reply_test_send(t, &f)
		reply_test_expect_ids(t, again, "msg_u2")
		testing.expect_value(t, again.source, domain.REPLY_SOURCE_INHERITED)
	}
}

Reply_Race :: struct {
	f: ^Reply_Origin_Test,
	start: sync.Barrier,
	message_ids: [2]string,
	errors: [2]domain.Error_Code,
}

// Edge case 4: two replies racing on one consumption. Each reply's unit of
// work reads and advances the watermark atomically, so exactly one claims the
// input and the other inherits it; the watermark ends at the consumption.
@(test)
test_reply_origin_concurrent_replies_claim_once :: proc(t: ^testing.T) {
	arena := reply_test_arena(); defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
	db, ok := reply_test_open(t)
	if !ok do return
	defer sqlite.close(&db)
	f: Reply_Origin_Test
	reply_test_wire(&f, &db)
	reply_test_seed_conversation(t, &f)
	reply_test_user_message(t, &f, "msg_u1")
	reply_test_consume(t, &f, "msg_u1")
	race := Reply_Race{f=&f}
	sync.barrier_init(&race.start, 2)
	worker :: proc(th: ^thread.Thread) {
		race := (^Reply_Race)(th.data)
		slot := th.user_index
		sync.barrier_wait(&race.start)
		m, ok, err := send_agent_message(&race.f.svc, reply_test_agent_auth(), REPLY_TEST_INSTANCE, Message_Input{body="racing", artifact_ids_json="[]"})
		race.errors[slot] = err.code
		if ok do race.message_ids[slot] = m.message_id
	}
	threads: [2]^thread.Thread
	for i in 0..<2 {
		threads[i] = thread.create(worker)
		threads[i].data = &race
		threads[i].user_index = i
		thread.start(threads[i])
	}
	for th in threads { thread.join(th); thread.destroy(th) }
	consumed, inherited := 0, 0
	for i in 0..<2 {
		testing.expect_value(t, race.errors[i], domain.Error_Code.None)
		if race.message_ids[i] == "" do continue
		got := reply_test_origin_of(t, &f, race.message_ids[i])
		reply_test_expect_ids(t, got, "msg_u1")
		if got.source == domain.REPLY_SOURCE_CONSUMED do consumed += 1
		if got.source == domain.REPLY_SOURCE_INHERITED do inherited += 1
	}
	testing.expect_value(t, consumed, 1)
	testing.expect_value(t, inherited, 1)
	w, found, _ := iface.content_get_reply_watermark(&f.repos.content, REPLY_TEST_OWNER, REPLY_TEST_CONVERSATION)
	testing.expect(t, found)
	rows, _ := iface.content_list_input_consumptions(&f.repos.content, REPLY_TEST_OWNER, REPLY_TEST_CONVERSATION, 0)
	if testing.expect_value(t, len(rows), 1) do testing.expect_value(t, w.through_seq, rows[0].seq)
}

// The watermark is a compare-and-swap: a writer that read a stale point loses.
@(test)
test_reply_watermark_advance_rejects_a_stale_point :: proc(t: ^testing.T) {
	arena := reply_test_arena(); defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
	db, ok := reply_test_open(t)
	if !ok do return
	defer sqlite.close(&db)
	f: Reply_Origin_Test
	reply_test_wire(&f, &db)
	w := domain.Reply_Watermark{conversation_id=REPLY_TEST_CONVERSATION, owner_user_id=REPLY_TEST_OWNER, through_seq=3, reply_message_id="msg_a", updated_at="2026-01-01T00:00:00Z"}
	testing.expect_value(t, iface.content_advance_reply_watermark(&f.repos.content, w, 0).code, domain.Error_Code.None)
	w.through_seq = 5; w.reply_message_id = "msg_b"
	testing.expect_value(t, iface.content_advance_reply_watermark(&f.repos.content, w, 0).code, domain.Error_Code.Conflict)
	testing.expect_value(t, iface.content_advance_reply_watermark(&f.repos.content, w, 3).code, domain.Error_Code.None)
	stale := w; stale.owner_user_id = "intruder"
	testing.expect_value(t, iface.content_advance_reply_watermark(&f.repos.content, stale, 5).code, domain.Error_Code.Conflict)
	got, _, _ := iface.content_get_reply_watermark(&f.repos.content, REPLY_TEST_OWNER, REPLY_TEST_CONVERSATION)
	testing.expect_value(t, got.through_seq, 5)
	testing.expect_value(t, got.reply_message_id, "msg_b")
}

// Only user->agent rows of the instance's own conversation are consumption,
// and only their first consumption counts.
@(test)
test_reply_origin_consumption_ignores_foreign_and_outgoing_rows :: proc(t: ^testing.T) {
	arena := reply_test_arena(); defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
	db, ok := reply_test_open(t)
	if !ok do return
	defer sqlite.close(&db)
	f: Reply_Origin_Test
	reply_test_wire(&f, &db)
	reply_test_seed_conversation(t, &f)
	reply_test_seed_conversation(t, &f, "chat_other", "inst_other")
	reply_test_user_message(t, &f, "msg_u1")
	reply_test_user_message(t, &f, "msg_other", cid = "chat_other")
	reply_test_user_message(t, &f, "msg_out", direction = "agent_to_user")
	reply_test_user_message(t, &f, "msg_peer", direction = "agent_to_agent")
	reply_test_consume(t, &f, "msg_other", "msg_out", "msg_peer", "msg_unknown", "msg_u1", "msg_u1")
	rows, _ := iface.content_list_input_consumptions(&f.repos.content, REPLY_TEST_OWNER, REPLY_TEST_CONVERSATION, 0)
	if testing.expect_value(t, len(rows), 1) do testing.expect_value(t, rows[0].message_id, "msg_u1")
	// A non-instance caller cannot record consumption.
	err := note_agent_consumed(&f.svc, {kind=.Session, user_id=REPLY_TEST_OWNER}, REPLY_TEST_INSTANCE, {"msg_u1"}, domain.INPUT_CONSUMED_READ)
	testing.expect_value(t, err.code, domain.Error_Code.Forbidden)
}

// Edge case 6: --reply-to overrides the consumed set and is validated.
@(test)
test_reply_origin_reply_to_override_and_validation :: proc(t: ^testing.T) {
	arena := reply_test_arena(); defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
	db, ok := reply_test_open(t)
	if !ok do return
	defer sqlite.close(&db)
	f: Reply_Origin_Test
	reply_test_wire(&f, &db)
	reply_test_seed_conversation(t, &f)
	reply_test_seed_conversation(t, &f, "chat_other", "inst_other")
	reply_test_user_message(t, &f, "msg_u1", "telegram")
	reply_test_user_message(t, &f, "msg_u2")
	reply_test_user_message(t, &f, "msg_other", cid = "chat_other")
	reply_test_user_message(t, &f, "msg_out", direction = "agent_to_user")
	reply_test_consume(t, &f, "msg_u1", "msg_u2")

	_, _, unknown := reply_test_send(t, &f, reply_to = "msg_missing")
	testing.expect_value(t, unknown.code, domain.Error_Code.Not_Found)
	testing.expect_value(t, unknown.message, "reply-to message not found")
	_, _, other_conv := reply_test_send(t, &f, reply_to = "msg_other")
	testing.expect_value(t, other_conv.code, domain.Error_Code.Validation_Failed)
	testing.expect_value(t, other_conv.message, "reply-to message belongs to another conversation")
	_, _, outgoing := reply_test_send(t, &f, reply_to = "msg_out")
	testing.expect_value(t, outgoing.code, domain.Error_Code.Validation_Failed)
	testing.expect_value(t, outgoing.message, "reply-to must name a message the user sent to this agent")
	// A rejected reply stores nothing and leaves the watermark alone.
	_, found, _ := iface.content_get_reply_watermark(&f.repos.content, REPLY_TEST_OWNER, REPLY_TEST_CONVERSATION)
	testing.expect(t, !found)

	got, _, err := reply_test_send(t, &f, reply_to = "msg_u1")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	reply_test_expect_ids(t, got, "msg_u1")
	testing.expect_value(t, got.origin, "telegram")
	testing.expect_value(t, got.route_status, domain.REPLY_ROUTE_EXPLICIT)
	testing.expect_value(t, got.source, domain.REPLY_SOURCE_REPLY_TO)
	// The explicit reply moved the watermark past both consumptions.
	next, _, _ := reply_test_send(t, &f)
	reply_test_expect_ids(t, next, "msg_u1")
	testing.expect_value(t, next.source, domain.REPLY_SOURCE_INHERITED)
	testing.expect_value(t, next.route_status, domain.REPLY_ROUTE_EXPLICIT)
}

// Start-success banners are not replies: no origin, watermark untouched.
@(test)
test_reply_origin_skips_system_messages :: proc(t: ^testing.T) {
	arena := reply_test_arena(); defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
	db, ok := reply_test_open(t)
	if !ok do return
	defer sqlite.close(&db)
	f: Reply_Origin_Test
	reply_test_wire(&f, &db)
	reply_test_seed_conversation(t, &f)
	reply_test_user_message(t, &f, "msg_u1")
	reply_test_consume(t, &f, "msg_u1")
	m, sent, _ := send_agent_message(&f.svc, reply_test_agent_auth(), REPLY_TEST_INSTANCE, Message_Input{body="ready", artifact_ids_json="[]", message_type="system"})
	testing.expect(t, sent)
	testing.expect(t, !strings.contains(m.metadata_json, "reply_origin"))
	_, found, _ := iface.content_get_reply_watermark(&f.repos.content, REPLY_TEST_OWNER, REPLY_TEST_CONVERSATION)
	testing.expect(t, !found)
	got, _, _ := reply_test_send(t, &f)
	reply_test_expect_ids(t, got, "msg_u1")
}

@(test)
test_reply_origin_resolve_rule :: proc(t: ^testing.T) {
	arena := reply_test_arena(); defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
	none := reply_origin_resolve(nil, {}, false, false)
	testing.expect_value(t, none.route_status, domain.REPLY_ROUTE_NONE)
	ambiguous := reply_origin_resolve(nil, {}, false, true)
	testing.expect_value(t, ambiguous.route_status, domain.REPLY_ROUTE_AMBIGUOUS)
	previous := domain.Reply_Origin{answered_message_ids={"msg_a"}, origin="telegram", route_status=domain.REPLY_ROUTE_ROUTED, source=domain.REPLY_SOURCE_CONSUMED}
	inherited := reply_origin_resolve(nil, previous, true, true)
	testing.expect_value(t, inherited.source, domain.REPLY_SOURCE_INHERITED)
	testing.expect_value(t, inherited.origin, "telegram")
	rows := []domain.Input_Consumption{{seq=1, message_id="msg_b", origin="local"}, {seq=2, message_id="msg_c", origin="telegram"}}
	mixed := reply_origin_resolve(rows, previous, true, true)
	testing.expect_value(t, mixed.route_status, domain.REPLY_ROUTE_AMBIGUOUS)
	testing.expect_value(t, len(mixed.answered_message_ids), 2)
}
