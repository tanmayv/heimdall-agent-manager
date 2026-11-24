package content

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"

Memory_Event_Test :: struct {
	db: sqlite.Conn,
	content_impl: sqlite.Content_Repo_SQLite,
	agents_impl: sqlite.Agent_Repo_SQLite,
	outbox_impl: sqlite.Event_Outbox_Repo_SQLite,
	repos: iface.Repositories,
	factory_impl: sqlite.SQLite_Unit_Of_Work_Factory,
	factory: iface.Unit_Of_Work_Factory,
	clock: platform.Clock,
	ids: platform.ID_Generator,
	svc: Content_Service,
	notifications: int,
	outside_tx: bool,
}
memory_event_case :: proc(t: ^testing.T, scenario: proc(^testing.T, ^Memory_Event_Test)) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	{
		arena: virtual.Arena
		if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
		defer virtual.arena_destroy(&arena)
		context.allocator = virtual.arena_allocator(&arena)
		context.temp_allocator = context.allocator
		f: Memory_Event_Test
		opened: bool
		f.db, opened, _ = sqlite.open(":memory:")
		if !testing.expect(t, opened) do return
		defer sqlite.close(&f.db)
		migrated, _ := sqlite.run_migrations(&f.db)
		if !testing.expect(t, migrated) do return
		f.repos.content = sqlite.new_content_repository(&f.content_impl, &f.db)
		f.repos.agents = sqlite.new_agent_repository(&f.agents_impl, &f.db)
		f.repos.event_outbox = sqlite.new_event_outbox_repository(&f.outbox_impl, &f.db)
		f.factory = sqlite.new_unit_of_work_factory(&f.factory_impl, &f.db, &f.repos)
		f.clock = platform.real_clock()
		f.ids = platform.real_id_generator()
		notifier := contracts.Attention_Notifier{ctx=&f, notify=memory_event_notify}
		f.svc = {content=&f.repos.content, agents=&f.repos.agents, uow_factory=&f.factory, clock=&f.clock, ids=&f.ids, attention=&notifier}
		f.outside_tx = true
		scenario(t, &f)
	}
	testing.expect_value(t, len(track.allocation_map), 0)
}
memory_event_notify :: proc(ctx: rawptr, owner, kind, id: string) {
	f := (^Memory_Event_Test)(ctx)
	f.notifications += 1
	uow, begun, _ := iface.unit_of_work_begin(&f.factory)
	f.outside_tx = f.outside_tx && begun && !uow.nested
	if begun do iface.unit_of_work_rollback(&uow)
}
memory_event_auth :: proc() -> contracts.Auth_Context { return {kind=.Session, user_id="owner"} }
memory_event_expect :: proc(t: ^testing.T, f: ^Memory_Event_Test, id, status, previous: string, version: i64, actor := "user") {
	uow, begun, _ := iface.unit_of_work_begin(&f.factory)
	if !testing.expect(t, begun) do return
	defer iface.unit_of_work_rollback(&uow)
	repo := &uow.repos.event_outbox
	row, found, err := repo.next(repo.ctx)
	if !testing.expect(t, found && err.code == .None) do return
	testing.expect_value(t, row.subject, fmt.tprintf("ev.owner.memory.%s.state", id))
	value: json.Value
	testing.expect(t, json.unmarshal(transmute([]u8)row.envelope_json, &value) == nil)
	object, _ := value.(json.Object)
	entity, _ := object["entity"].(json.Object)
	data, _ := object["data"].(json.Object)
	testing.expect_value(t, entity["kind"].(string), "memory")
	testing.expect_value(t, entity["id"].(string), id)
	testing.expect_value(t, object["type"].(string), "memory.state")
	testing.expect_value(t, object["class"].(string), "state")
	testing.expect_value(t, object["owner_user_id"].(string), "owner")
	testing.expect_value(t, object["actor"].(string), actor)
	testing.expect_value(t, i64(object["entity_version"].(json.Integer)), version)
	testing.expect_value(t, data["status"].(string), status)
	testing.expect_value(t, data["previous_status"].(string), previous)
	testing.expect_value(t, data["memory_type"].(string), "fact")
	testing.expect_value(t, len(data), 5)
	for key in ([]string{"title", "body", "description", "evidence", "agent_ids", "project_ids"}) {
		_, present := data[key]
		testing.expect(t, !present)
	}
	matches, head_err := repo.state_head_matches(repo.ctx, "owner", "memory", id, "memory.state", row.event_id)
	testing.expect(t, matches && head_err.code == .None)
	testing.expect_value(t, repo.mark_published(repo.ctx, row.outbox_seq, row.created_at).code, domain.Error_Code.None)
	committed, _ := iface.unit_of_work_commit(&uow)
	uow.ctx = nil
	testing.expect(t, committed)
}
memory_event_empty :: proc(t: ^testing.T, f: ^Memory_Event_Test) {
	uow, begun, _ := iface.unit_of_work_begin(&f.factory)
	if !testing.expect(t, begun) do return
	defer iface.unit_of_work_rollback(&uow)
	count, err := uow.repos.event_outbox.backlog(uow.repos.event_outbox.ctx)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, count, 0)
}
@(test)
test_memory_state_create_transitions_and_quiet_edits :: proc(t: ^testing.T) { memory_event_case(t, memory_event_transitions) }
memory_event_transitions :: proc(t: ^testing.T, f: ^Memory_Event_Test) {
	m, ok, err := create_memory(&f.svc, memory_event_auth(), {type=.Fact, body="secret", title="secret", evidence="secret"})
	if !testing.expect(t, ok && err.code == .None) do return
	memory_event_expect(t, f, m.memory_id, "pending", "", 1)
	_, ok, err = update_memory(&f.svc, memory_event_auth(), m.memory_id, {has_body=true, body="edited secret"})
	testing.expect(t, ok && err.code == .None)
	memory_event_empty(t, f)
	_, ok, err = approve_memory(&f.svc, memory_event_auth(), m.memory_id, {has_title=true, title="approved title"}, true)
	testing.expect(t, ok && err.code == .None)
	memory_event_expect(t, f, m.memory_id, "active", "pending", 2)
	_, ok, err = approve_memory(&f.svc, memory_event_auth(), m.memory_id)
	testing.expect(t, ok && err.code == .None)
	memory_event_empty(t, f)
	_, ok, err = reject_memory(&f.svc, memory_event_auth(), m.memory_id)
	testing.expect(t, ok && err.code == .None)
	memory_event_expect(t, f, m.memory_id, "rejected", "active", 3)
	_, ok, err = archive_memory(&f.svc, memory_event_auth(), m.memory_id)
	testing.expect(t, ok && err.code == .None)
	memory_event_expect(t, f, m.memory_id, "archived", "rejected", 4)
	memory_event_empty(t, f)
	testing.expect_value(t, f.notifications, 6)
	testing.expect(t, f.outside_tx)
}
@(test)
test_memory_state_system_and_actor_metadata :: proc(t: ^testing.T) { memory_event_case(t, memory_event_actors) }
memory_event_actors :: proc(t: ^testing.T, f: ^Memory_Event_Test) {
	_, ok, err := save_memory(&f.svc, {memory_id="mem_system", owner_user_id="system", status="active", type=.Fact}, memory_event_auth())
	testing.expect(t, ok && err.code == .None)
	memory_event_empty(t, f)
	testing.expect(t, sqlite.exec(&f.db, "PRAGMA foreign_keys=OFF;"))
	_, ok, err = iface.agent_save_instance(&f.repos.agents, {agent_instance_id="inst_proposer", owner_user_id="owner", agent_id="agt_proposer", bridge_id="bridge"})
	testing.expect(t, ok && err.code == .None)
	auth := contracts.Auth_Context{kind=.Instance_Token, user_id="owner", agent_instance_id="inst_proposer"}
	m, saved, e := create_memory(&f.svc, auth, {type=.Fact, body="secret", proposed_by_instance_id="inst_proposer", proposed_in_chain_id="chain_proposal"})
	if !testing.expect(t, saved && e.code == .None) do return
	// Check provenance on the real producer payload.
	uow, begun, _ := iface.unit_of_work_begin(&f.factory)
	if !testing.expect(t, begun) do return
	row, found, _ := uow.repos.event_outbox.next(uow.repos.event_outbox.ctx)
	testing.expect(t, found)
	value: json.Value
	_ = json.unmarshal(transmute([]u8)row.envelope_json, &value)
	object := value.(json.Object); data := object["data"].(json.Object)
	testing.expect_value(t, data["proposed_by_instance_id"].(string), "inst_proposer")
	testing.expect_value(t, data["proposed_in_chain_id"].(string), "chain_proposal")
	iface.unit_of_work_rollback(&uow)
	memory_event_expect(t, f, m.memory_id, "pending", "", 1, "agt_proposer")
	auth.agent_instance_id = "missing"
	m, saved, e = create_memory(&f.svc, auth, {type=.Fact, body="secret"})
	testing.expect(t, saved && e.code == .None)
	memory_event_expect(t, f, m.memory_id, "pending", "", 1, "hub")
}
@(test)
test_memory_state_outer_rollback_discards_event_and_attention :: proc(t: ^testing.T) { memory_event_case(t, memory_event_rollback) }
memory_event_rollback :: proc(t: ^testing.T, f: ^Memory_Event_Test) {
	outer, begun, _ := iface.unit_of_work_begin(&f.factory)
	if !testing.expect(t, begun) do return
	m, ok, err := create_memory(&f.svc, memory_event_auth(), {type=.Fact, body="secret"})
	testing.expect(t, ok && err.code == .None)
	testing.expect_value(t, f.notifications, 0)
	iface.unit_of_work_rollback(&outer)
	_, found, _ := iface.content_get_memory(&f.repos.content, m.memory_id)
	testing.expect(t, !found)
	memory_event_empty(t, f)
	testing.expect_value(t, f.notifications, 0)
	// A new write starts at version one: head/version changes rolled back too.
	m, ok, err = save_memory(&f.svc, m, memory_event_auth())
	testing.expect(t, ok && err.code == .None)
	memory_event_expect(t, f, m.memory_id, "pending", "", 1)
	outer, begun, _ = iface.unit_of_work_begin(&f.factory)
	if !testing.expect(t, begun) do return
	_, ok, err = approve_memory(&f.svc, memory_event_auth(), m.memory_id)
	testing.expect(t, ok && err.code == .None)
	testing.expect_value(t, f.notifications, 1)
	committed, _ := iface.unit_of_work_commit(&outer)
	testing.expect(t, committed)
	testing.expect_value(t, f.notifications, 2)
	testing.expect(t, f.outside_tx)
	memory_event_expect(t, f, m.memory_id, "active", "pending", 2)
}
@(test)
test_memory_state_outbox_failure_rolls_back_memory :: proc(t: ^testing.T) { memory_event_case(t, memory_event_failure) }
memory_event_failure :: proc(t: ^testing.T, f: ^Memory_Event_Test) {
	testing.expect(t, sqlite.exec(&f.db, "CREATE TRIGGER fail_memory_event BEFORE INSERT ON event_outbox BEGIN SELECT RAISE(ABORT, 'forced outbox failure'); END;"))
	_, ok, err := save_memory(&f.svc, {memory_id="mem_failure", owner_user_id="owner", type=.Fact, status="pending"}, memory_event_auth())
	testing.expect(t, !ok && err.code != .None)
	_, found, _ := iface.content_get_memory(&f.repos.content, "mem_failure")
	testing.expect(t, !found)
	memory_event_empty(t, f)
	testing.expect_value(t, f.notifications, 0)
}
