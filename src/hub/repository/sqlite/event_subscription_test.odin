package sqlite

import "core:mem"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
test_event_subscription_transactions_and_identity :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	subscription_transaction_scenario(t)
	testing.expect_value(t, len(track.allocation_map), 0)
}

subscription_transaction_scenario :: proc(t: ^testing.T) {
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated) do return
	migrated, _ = run_migrations(&conn)
	testing.expect(t, migrated, "migration is idempotent")
	impl: Event_Subscription_Repo_SQLite
	repo := new_event_subscription_repository(&impl, &conn)
	repos := iface.Repositories {
		event_subscriptions = repo,
	}
	factory_impl: SQLite_Unit_Of_Work_Factory
	factory := new_unit_of_work_factory(&factory_impl, &conn, &repos)
	row := domain.Event_Subscription {
		subscription_id     = "sub_1",
		owner_user_id       = "alice",
		subscriber_instance_id = "inst_1",
		chain_id            = "chain_1",
		source              = "explicit",
		filter_subjects     = "[\"ev.alice.chain.chain_1.state\"]",
		wake_policy         = "catalog",
		consumer_name       = "sub_1",
		created_at          = "2026-11-19T00:00:00Z",
	}
	testing.expect(t, repo.put(repo.ctx, row).code != .None, "UoW is required")
	uow, began, _ := iface.unit_of_work_begin(&factory)
	if !testing.expect(t, began) do return
	testing.expect_value(t, repo.put(repo.ctx, row).code, domain.Error_Code.None)
	iface.unit_of_work_rollback(&uow)
	uow, began, _ = iface.unit_of_work_begin(&factory)
	if !testing.expect(t, began) do return
	rows, err := repo.list(repo.ctx, "alice", "inst_1")
	testing.expect(t, err.code == .None && len(rows) == 0, "rollback removes subscription")
	delete(rows)
	testing.expect_value(t, repo.put(repo.ctx, row).code, domain.Error_Code.None)
	duplicate := row
	duplicate.subscription_id = "sub_duplicate"
	duplicate.consumer_name = "sub_duplicate"
	testing.expect_value(t, repo.put(repo.ctx, duplicate).code, domain.Error_Code.None)
	committed, _ := iface.unit_of_work_commit(&uow)
	testing.expect(t, committed)
	uow, began, _ = iface.unit_of_work_begin(&factory)
	if !testing.expect(t, began) do return
	defer iface.unit_of_work_rollback(&uow)
	rows, err = repo.list(repo.ctx, "alice", "inst_1")
	testing.expect(t, err.code == .None && len(rows) == 1, "scope is idempotent")
	if len(rows) == 1 {
		testing.expect_value(t, rows[0].subscription_id, "sub_1")
		testing.expect_value(t, rows[0].task_id, "")
		testing.expect_value(t, rows[0].consumer_name, "sub_1")
	}
	for &r in rows do domain.event_subscription_destroy(&r)
	delete(rows)
	rows, err = repo.list(repo.ctx, "mallory", "inst_1")
	testing.expect(t, err.code == .None && len(rows) == 0, "tenant isolation")
	delete(rows)
	rows, err = repo.list(repo.ctx, "alice", "inst_other")
	testing.expect(t, err.code == .None && len(rows) == 0, "instance isolation")
	delete(rows)
	testing.expect_value(t, repo.remove(repo.ctx, "mallory", "inst_1", "sub_1").code, domain.Error_Code.None)
	testing.expect_value(t, repo.remove(repo.ctx, "alice", "inst_other", "sub_1").code, domain.Error_Code.None)
	rows, err = repo.list(repo.ctx, "alice", "inst_1")
	testing.expect(t, err.code == .None && len(rows) == 1, "foreign remove has no effect")
	for &r in rows do domain.event_subscription_destroy(&r)
	delete(rows)
	testing.expect_value(t, repo.remove(repo.ctx, "alice", "inst_1", "sub_1").code, domain.Error_Code.None)
	rows, err = repo.list(repo.ctx, "alice", "inst_1")
	testing.expect(t, err.code == .None && len(rows) == 0, "owner removes subscription")
	delete(rows)
}

@(test)
test_event_role_subscriptions_lifecycle :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	role_subscription_scenario(t)
	testing.expect_value(t, len(track.allocation_map), 0)
}
role_subscription_scenario :: proc(t: ^testing.T) {
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated) do return
	impl: Event_Subscription_Repo_SQLite
	repo := new_event_subscription_repository(&impl, &conn)
	repos := iface.Repositories {
		event_subscriptions = repo,
	}
	factory_impl: SQLite_Unit_Of_Work_Factory
	factory := new_unit_of_work_factory(&factory_impl, &conn, &repos)
	testing.expect(
		t,
		exec(
			&conn,
			"INSERT INTO agent_instances(agent_instance_id,owner_user_id,agent_id,bridge_id,runtime_status,created_at,updated_at) VALUES('inst_worker','alice','agt_worker','bridge','idle','now','now');",
		),
	)
	uow, began, _ := iface.unit_of_work_begin(&factory)
	if !testing.expect(t, began) do return
	testing.expect(
		t,
		exec(
			&conn,
			"INSERT INTO task_chain_members(chain_id,agent_instance_id,agent_id,owner_user_id,role,created_at) VALUES('chain','inst_coord','agt_coord','alice','coordinator','now');",
		),
	)
	testing.expect(
		t,
		exec(
			&conn,
			"INSERT INTO task_leases(lease_id,task_id,chain_id,owner_user_id,attempt_no,holder_instance_id,kind,granted_at,expires_at,hard_deadline_at,delivery) VALUES('lease','task','chain','alice',1,'inst_worker','work','now','','','wake');",
		),
	)
	rows, err := repo.list(repo.ctx, "alice", "inst_coord")
	testing.expect(t, err.code == .None && len(rows) == 1, "membership creates coordinator scope")
	if len(rows) > 0 do testing.expect(t, rows[0].task_id == "" && rows[0].source == "role_default")
	for &row in rows do domain.event_subscription_destroy(&row)
	delete(rows)
	rows, err = repo.list(repo.ctx, "alice", "inst_worker")
	testing.expect(t, err.code == .None && len(rows) == 1, "grant creates exact worker task scope")
	if len(rows) > 0 {
		testing.expect_value(t, rows[0].task_id, "task")
		testing.expect_value(t, rows[0].filter_subjects, "[\"ev.alice.chain.chain.task.task.requirements_changed\"]")
	}
	for &row in rows do domain.event_subscription_destroy(&row)
	delete(rows)
	// SQLite propagates an outer UPSERT conflict policy into trigger writes.
	// Repeated saves must preserve subscription identity without a UNIQUE failure.
	testing.expect(
		t,
		exec(
			&conn,
			"INSERT INTO task_leases(lease_id,task_id,chain_id,owner_user_id,attempt_no,holder_instance_id,kind,granted_at,expires_at,hard_deadline_at,delivery) VALUES('lease','task','chain','alice',1,'inst_worker','work','now','','','wake') ON CONFLICT(lease_id) DO UPDATE SET phase='waiting';",
		),
	)
	testing.expect(
		t,
		exec(
			&conn,
			"INSERT INTO task_chain_members(chain_id,agent_instance_id,agent_id,owner_user_id,role,created_at) VALUES('chain','inst_coord','agt_coord','alice','coordinator','now') ON CONFLICT(chain_id,agent_instance_id) DO UPDATE SET role=excluded.role;",
		),
	)
	rows, err = repo.list(repo.ctx, "alice", "inst_worker")
	testing.expect(t, err.code == .None && len(rows) == 1, "waiting retains durable ownership")
	for &row in rows do domain.event_subscription_destroy(&row)
	delete(rows)
	iface.unit_of_work_rollback(&uow)
	uow, began, _ = iface.unit_of_work_begin(&factory)
	if !testing.expect(t, began) do return
	defer iface.unit_of_work_rollback(&uow)
	rows, err = repo.all(repo.ctx)
	testing.expect(t, err.code == .None && len(rows) == 0, "rollback removes every default")
	for &row in rows do domain.event_subscription_destroy(&row)
	delete(rows)
	testing.expect(
		t,
		exec(
			&conn,
			"INSERT INTO task_chain_members(chain_id,agent_instance_id,agent_id,owner_user_id,role,created_at) VALUES('chain','inst_coord','agt_coord','alice','coordinator','now');",
		),
	)
	testing.expect(
		t,
		exec(
			&conn,
			"INSERT INTO task_leases(lease_id,task_id,chain_id,owner_user_id,attempt_no,holder_instance_id,kind,granted_at,expires_at,hard_deadline_at,delivery) VALUES('lease','task','chain','alice',1,'inst_worker','work','now','','','wake');",
		),
	)
	testing.expect_value(
		t,
		repo.put(repo.ctx, domain.Event_Subscription{subscription_id = "explicit", owner_user_id = "alice", subscriber_instance_id = "inst_coord", chain_id = "chain", source = "explicit", filter_subjects = "[]", wake_policy = "catalog", consumer_name = "explicit", created_at = "now"}).code,
		domain.Error_Code.None,
	)
	testing.expect(t, exec(&conn, "DELETE FROM task_leases WHERE lease_id='lease';"))
	testing.expect(t, exec(&conn, "UPDATE task_chain_members SET role='worker' WHERE agent_instance_id='inst_coord';"))
	rows, err = repo.all(repo.ctx)
	testing.expect(
		t,
		err.code == .None && len(rows) == 1,
		"lease end and coordinator role removal retire only defaults",
	)
	if len(rows) > 0 do testing.expect_value(t, rows[0].subscription_id, "explicit")
	for &row in rows do domain.event_subscription_destroy(&row)
	delete(rows)
	deleted, del_err := repo.deletions(repo.ctx)
	testing.expect(t, del_err.code == .None && len(deleted) == 2, "consumer deletion is durable and transactional")
	for name in deleted do delete(name)
	delete(deleted)
}
