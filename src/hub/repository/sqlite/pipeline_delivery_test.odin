package sqlite

import "core:mem"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
test_pipeline_delivery_repo_round_trip :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	pipeline_repo_scenario(t)
	testing.expect_value(t, len(track.allocation_map), 0)
}

pipeline_repo_scenario :: proc(t: ^testing.T) {
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	ok, _ := run_migrations(&conn)
	if !testing.expect(t, ok) do return
	impl: Pipeline_Delivery_Repo_SQLite
	repo := new_pipeline_delivery_repository(&impl, &conn)
	repos := iface.Repositories {
		pipeline_deliveries = repo,
	}
	factory_impl: SQLite_Unit_Of_Work_Factory
	factory := new_unit_of_work_factory(&factory_impl, &conn, &repos)
	d := domain.Pipeline_Delivery {
		delivery_id           = "dlv_one",
		owner_user_id         = "alice",
		kind                  = "prompt",
		bridge_id             = "brg_one",
		agent_instance_id     = "inst_one",
		ref                   = "run:one",
		message_id            = "msg_one",
		state                 = "routed",
		excluded_bridges_json = "[]",
		expires_at            = "2026-11-22T01:00:00Z",
		created_at            = "2026-11-22T00:00:00Z",
		updated_at            = "2026-11-22T00:00:00Z",
	}
	err := repo.insert(repo.ctx, d)
	testing.expect(t, err.code != .None, "all repository operations require UoW")
	uow, began, _ := iface.unit_of_work_begin(&factory)
	if !testing.expect(t, began) do return
	defer {iface.unit_of_work_rollback(&uow)}
	testing.expect_value(t, repo.insert(repo.ctx, d).code, domain.Error_Code.None)
	got, found, e := repo.get(repo.ctx, d.delivery_id)
	testing.expect(t, found && e.code == .None)
	testing.expect_value(t, got.ref, d.ref)
	testing.expect_value(t, got.excluded_bridges_json, "[]")
	domain.pipeline_delivery_destroy(&got)
	d.state = "forwarded"; d.attempt = 2; d.ack_reply = "reply"; d.stream_sequence = 42; d.forwarded_at = d.updated_at
	changed, e2 := repo.transition(repo.ctx, d, "failed")
	testing.expect(t, !changed && e2.code == .None, "wrong from_state is a no-op")
	changed, e2 = repo.transition(repo.ctx, d, "routed")
	testing.expect(t, changed && e2.code == .None)
	got, found, e = repo.open_by_ref(repo.ctx, d.ref)
	testing.expect(t, found && e.code == .None)
	testing.expect_value(t, got.state, "forwarded")
	testing.expect_value(t, got.attempt, 2)
	testing.expect_value(t, got.stream_sequence, i64(42))
	testing.expect_value(t, got.ack_reply, "reply")
	domain.pipeline_delivery_destroy(&got)
	rows, e3 := repo.open_for_bridge(repo.ctx, "brg_one", "", 10)
	testing.expect(t, e3.code == .None && len(rows) == 1)
	domain.pipeline_deliveries_destroy(rows)
	rows, e3 = repo.open_for_bridge(repo.ctx, "brg_one", "routed", 10)
	testing.expect(t, e3.code == .None && len(rows) == 0)
	domain.pipeline_deliveries_destroy(rows)
	n, e4 := repo.in_flight(repo.ctx, "brg_one", "2026-11-21T00:00:00Z")
	testing.expect(t, e4.code == .None && n == 1)
	n, e4 = repo.in_flight(repo.ctx, "brg_one", d.updated_at)
	testing.expect(t, e4.code == .None && n == 0, "stale rows do not occupy a slot")
	d.retry_at = "2026-11-22T00:00:10Z"
	changed, e2 = repo.transition(repo.ctx, d, "forwarded")
	testing.expect(t, changed && e2.code == .None)
	n, e4 = repo.in_flight(repo.ctx, "brg_one", "2026-11-21T00:00:00Z")
	testing.expect(t, e4.code == .None && n == 0, "delayed retries do not occupy a slot")
	got, found, e = repo.get(repo.ctx, d.delivery_id)
	testing.expect(t, found && e.code == .None && got.retry_at == d.retry_at)
	domain.pipeline_delivery_destroy(&got)
	rows, e3 = repo.expired(repo.ctx, d.expires_at, 10)
	testing.expect(t, e3.code == .None && len(rows) == 1, "expiry includes equality")
	domain.pipeline_deliveries_destroy(rows)
	testing.expect_value(t, repo.prune(repo.ctx, "2027-01-01T00:00:00Z").code, domain.Error_Code.None)
	got, found, e = repo.get(repo.ctx, d.delivery_id)
	testing.expect(t, found && e.code == .None, "prune preserves old open rows")
	domain.pipeline_delivery_destroy(&got)
	d.state = "done"; d.outcome = "started"
	changed, e2 = repo.transition(repo.ctx, d, "forwarded")
	testing.expect(t, changed && e2.code == .None)
	testing.expect_value(t, repo.prune(repo.ctx, d.updated_at).code, domain.Error_Code.None)
	got, found, e = repo.get(repo.ctx, d.delivery_id)
	testing.expect(t, found && e.code == .None, "cutoff is exclusive")
	domain.pipeline_delivery_destroy(&got)
	testing.expect_value(t, repo.prune(repo.ctx, "2027-01-01T00:00:00Z").code, domain.Error_Code.None)
	got, found, e = repo.get(repo.ctx, d.delivery_id)
	testing.expect(t, !found && e.code == .None)
	domain.pipeline_delivery_destroy(&got)
}

@(test)
test_migration_pipeline_001 :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	pipeline_migration_scenario(t)
	testing.expect_value(t, len(track.allocation_map), 0)
}

pipeline_migration_scenario :: proc(t: ^testing.T) {
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	ok, _ := run_migrations(&conn)
	if !testing.expect(t, ok) do return
	stmt: sqlite3_stmt
	testing.expect_value(
		t,
		sqlite3_prepare_v2(
			conn.db,
			"SELECT count(*) FROM sqlite_master WHERE (type='table' AND name IN ('pipeline_deliveries','event_deliveries')) OR (type='index' AND name IN ('pipeline_deliveries_open','pipeline_deliveries_ref','pipeline_deliveries_expiry','pipeline_deliveries_closed'));",
			-1,
			&stmt,
			nil,
		),
		SQLITE_OK,
	)
	testing.expect_value(t, sqlite3_step(stmt), SQLITE_ROW)
	testing.expect_value(t, sqlite3_column_int64(stmt, 0), i64(6))
	sqlite3_finalize(stmt)
	// The inbox receipt schema remains a separate table, not renamed/reused.
	testing.expect_value(
		t,
		sqlite3_prepare_v2(
			conn.db,
			"SELECT subscription_id,event_id,ack_reply FROM event_deliveries LIMIT 1;",
			-1,
			&stmt,
			nil,
		),
		SQLITE_OK,
	)
	sqlite3_finalize(stmt)
	ok, _ = run_migrations(&conn)
	testing.expect(t, ok, "idempotent migration")
}

@(test)
test_event_path_queries_use_indexes :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	pipeline_query_plans_scenario(t)
	actions_query_plans_scenario(t)
	testing.expect_value(t, len(track.allocation_map), 0)
}

pipeline_query_plans_scenario :: proc(t: ^testing.T) {
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	ok, _ := run_migrations(&conn)
	if !testing.expect(t, ok) do return
	queries := []string {
		PIPELINE_IN_FLIGHT_SQL,
		PIPELINE_GET_SQL,
		PIPELINE_TRANSITION_SQL,
		PIPELINE_OPEN_REF_SQL,
		PIPELINE_OPEN_BRIDGE_SQL,
		PIPELINE_EXPIRED_SQL,
		PIPELINE_PRUNE_SQL,
	}
	for query in queries {
		text := strings.concatenate({"EXPLAIN QUERY PLAN ", query})
		stmt: sqlite3_stmt
		ctext := strings.clone_to_cstring(text)
		rc := sqlite3_prepare_v2(conn.db, ctext, -1, &stmt, nil)
		delete(ctext)
		delete(text)
		if !testing.expect_value(t, rc, SQLITE_OK) do continue
		for sqlite3_step(stmt) == SQLITE_ROW {
			detail := column_text(stmt, 3)
			testing.expect(
				t,
				!strings.contains(detail, "SCAN pipeline_deliveries") ||
				strings.contains(detail, "USING INDEX") ||
				strings.contains(detail, "USING COVERING INDEX"),
				detail,
			)
			delete(detail)
		}
		sqlite3_finalize(stmt)
	}
}
