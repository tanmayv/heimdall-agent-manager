package content

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import iface "odin_test:hub/repository/iface"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"

@(test)
test_content_service_memory_default_expiry_24h :: proc(t: ^testing.T) {
	db_path := "/tmp/test_content_service_memory_expiry.db"
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, _ := sqlite.open(db_path)
	testing.expect(t, open_ok, "db open ok")
	defer sqlite.close(&conn)

	mig_ok, _ := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")

	content_impl := sqlite.Content_Repo_SQLite{conn = &conn}
	content_repo := sqlite.new_content_repository(&content_impl, &conn)

	clock := platform.real_clock()
	ids := platform.real_id_generator()

	svc := new_content_service(&content_repo, nil, nil, nil, nil, &clock, &ids)
	outbox_impl: sqlite.Event_Outbox_Repo_SQLite
	agent_impl: sqlite.Agent_Repo_SQLite
	repos := iface.Repositories{content=content_repo, event_outbox=sqlite.new_event_outbox_repository(&outbox_impl, &conn), agents=sqlite.new_agent_repository(&agent_impl, &conn)}
	factory_impl: sqlite.SQLite_Unit_Of_Work_Factory
	factory := sqlite.new_unit_of_work_factory(&factory_impl, &conn, &repos)
	svc.uow_factory = &factory
	auth := contracts.Auth_Context{user_id = "test_user"}

	// 1. Create memory without explicit expires_at -> should default to roughly now + 24h
	now_str := platform.clock_now(&clock)
	now_t, parse_ok := platform.parse_rfc3339_utc(now_str)
	testing.expect(t, parse_ok, "parse current time ok")

	in1 := Memory_Input{
		title = "Test Memory 1",
		body = "Body 1",
		type = .Fact,
		status = "pending",
	}
	mem1, ok1, err1 := create_memory(&svc, auth, in1)
	testing.expect(t, ok1, "create memory 1 ok")
	testing.expect_value(t, err1.code, domain.Error_Code.None)
	testing.expect(t, mem1.expires_at != "", "expires_at should not be empty")

	exp_t, exp_ok := platform.parse_rfc3339_utc(mem1.expires_at)
	testing.expect(t, exp_ok, "parse expires_at ok")
	diff := time.diff(now_t, exp_t)
	hours := time.duration_hours(diff)
	testing.expect(t, hours >= 23.99 && hours <= 24.01, "expires_at should be ~24h in the future")

	// 2. Create memory with explicit expires_at -> should be preserved
	in2 := Memory_Input{
		title = "Test Memory 2",
		body = "Body 2",
		type = .Fact,
		status = "pending",
		expires_at = "2030-01-01T00:00:00Z",
	}
	mem2, ok2, err2 := create_memory(&svc, auth, in2)
	testing.expect(t, ok2, "create memory 2 ok")
	testing.expect_value(t, err2.code, domain.Error_Code.None)
	testing.expect_value(t, mem2.expires_at, "2030-01-01T00:00:00Z")

	// 3. Verify get_memory returns expires_at from DB
	fetched, get_ok, _ := get_memory(&svc, auth, mem1.memory_id)
	testing.expect(t, get_ok, "get_memory ok")
	testing.expect_value(t, fetched.expires_at, mem1.expires_at)
}

// C1: use an isolated in-memory DB and the same service path for each status.
memory_expiry_case :: proc(t: ^testing.T, status: string) {
	context.allocator = context.temp_allocator
	conn, opened, _ := sqlite.open(":memory:")
	if !testing.expect(t, opened) do return
	defer sqlite.close(&conn)
	migrated, _ := sqlite.run_migrations(&conn)
	if !testing.expect(t, migrated) do return
	impl: sqlite.Content_Repo_SQLite
	repo := sqlite.new_content_repository(&impl, &conn)
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	svc := new_content_service(&repo, nil, nil, nil, nil, &clock, &ids)
	outbox_impl: sqlite.Event_Outbox_Repo_SQLite
	agent_impl: sqlite.Agent_Repo_SQLite
	repos := iface.Repositories{content=repo, event_outbox=sqlite.new_event_outbox_repository(&outbox_impl, &conn), agents=sqlite.new_agent_repository(&agent_impl, &conn)}
	factory_impl: sqlite.SQLite_Unit_Of_Work_Factory
	factory := sqlite.new_unit_of_work_factory(&factory_impl, &conn, &repos)
	svc.uow_factory = &factory
	auth := contracts.Auth_Context {
		kind              = .Instance_Token,
		user_id           = "expiry_owner",
		agent_instance_id = "expiry_actor",
	}
	m, ok, err := create_memory(&svc, auth, {type = .Fact, body = "test", status = status})
	testing.expect_value(t, err.code, domain.Error_Code.None)
	if !testing.expect(t, ok) do return
	if status == "active" {
		testing.expect_value(t, m.status, "active"); testing.expect_value(t, m.expires_at, "")
	} else {
		testing.expect_value(t, m.status, "pending")
		now, _ := platform.parse_rfc3339_utc(m.created_at); expiry, parsed := platform.parse_rfc3339_utc(m.expires_at)
		testing.expect(t, parsed); testing.expect_value(t, time.diff(now, expiry), 24 * time.Hour)
	}
	persisted, found, _ := get_memory(
		&svc,
		auth,
		m.memory_id,
	); testing.expect(t, found); testing.expect_value(t, persisted.expires_at, m.expires_at)
	explicit, explicit_ok, _ := create_memory(
		&svc,
		auth,
		{type = .Fact, body = "test", status = status, expires_at = "2030-01-01T00:00:00Z"},
	)
	testing.expect(t, explicit_ok); testing.expect_value(t, explicit.expires_at, "2030-01-01T00:00:00Z")
}
@(test)
test_create_memory_active_has_no_default_expiry :: proc(t: ^testing.T) {memory_expiry_case(t, "active")}
@(test)
test_create_memory_pending_keeps_24h_expiry :: proc(t: ^testing.T) {memory_expiry_case(t, ""); memory_expiry_case(
		t,
		"pending",
	)}
