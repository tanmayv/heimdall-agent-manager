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
 repos := iface.Repositories{event_subscriptions = repo}
 factory_impl: SQLite_Unit_Of_Work_Factory
 factory := new_unit_of_work_factory(&factory_impl, &conn, &repos)
 row := domain.Event_Subscription{
  subscription_id = "sub_1", owner_user_id = "alice",
  subscriber_agent_id = "agt_1", chain_id = "chain_1",
  source = "explicit", filter_subjects = "[\"ev.alice.chain.chain_1.state\"]",
  wake_policy = "catalog", consumer_name = "sub_1", created_at = "2026-11-19T00:00:00Z",
 }
 testing.expect(t, repo.put(repo.ctx, row).code != .None, "UoW is required")
 uow, began, _ := iface.unit_of_work_begin(&factory)
 if !testing.expect(t, began) do return
 testing.expect_value(t, repo.put(repo.ctx, row).code, domain.Error_Code.None)
 iface.unit_of_work_rollback(&uow)
 uow, began, _ = iface.unit_of_work_begin(&factory)
 if !testing.expect(t, began) do return
 rows, err := repo.list(repo.ctx, "alice", "agt_1")
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
 rows, err = repo.list(repo.ctx, "alice", "agt_1")
 testing.expect(t, err.code == .None && len(rows) == 1, "scope is idempotent")
 if len(rows) == 1 {
  testing.expect_value(t, rows[0].subscription_id, "sub_1")
  testing.expect_value(t, rows[0].task_id, "")
  testing.expect_value(t, rows[0].consumer_name, "sub_1")
 }
 for &r in rows do domain.event_subscription_destroy(&r)
 delete(rows)
 rows, err = repo.list(repo.ctx, "mallory", "agt_1")
 testing.expect(t, err.code == .None && len(rows) == 0, "tenant isolation")
 delete(rows)
 rows, err = repo.list(repo.ctx, "alice", "agt_other")
 testing.expect(t, err.code == .None && len(rows) == 0, "agent isolation")
 delete(rows)
 testing.expect_value(t, repo.remove(repo.ctx, "mallory", "agt_1", "sub_1").code, domain.Error_Code.None)
 testing.expect_value(t, repo.remove(repo.ctx, "alice", "agt_other", "sub_1").code, domain.Error_Code.None)
 rows, err = repo.list(repo.ctx, "alice", "agt_1")
 testing.expect(t, err.code == .None && len(rows) == 1, "foreign remove has no effect")
 for &r in rows do domain.event_subscription_destroy(&r)
 delete(rows)
 testing.expect_value(t, repo.remove(repo.ctx, "alice", "agt_1", "sub_1").code, domain.Error_Code.None)
 rows, err = repo.list(repo.ctx, "alice", "agt_1")
 testing.expect(t, err.code == .None && len(rows) == 0, "owner removes subscription")
 delete(rows)
}
