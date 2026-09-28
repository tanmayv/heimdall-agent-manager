package sqlite

import "core:fmt"
import "core:os"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

free_subscription :: proc(sub: ^domain.Task_Subscription) {
	delete(sub.subscription_id)
	delete(string(sub.owner_user_id))
	delete(sub.subscriber_agent_instance_id)
	delete(string(sub.chain_id))
	delete(string(sub.task_id))
	delete(sub.event_type)
	delete(sub.created_at)
}

free_subscriptions :: proc(subs: []domain.Task_Subscription) {
	for &sub in subs {
		free_subscription(&sub)
	}
	delete(subs)
}

@(test)
test_taskchain_subscription_sqlite_lifecycle :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_taskchain_sub_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := open(db_path)
	testing.expect(t, open_ok, "db open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer close(&conn)

	mig_ok, mig_err := run_migrations(&conn)
	if !mig_ok do fmt.println("MIG ERR:", mig_err.message)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	// Verify table and indexes exist
	testing.expect(t, sqlite_object_exists(&conn, "task_subscriptions"), "task_subscriptions table exists")
	testing.expect(t, sqlite_object_exists(&conn, "idx_task_sub_chain"), "idx_task_sub_chain index exists")
	testing.expect(t, sqlite_object_exists(&conn, "idx_task_sub_task"), "idx_task_sub_task index exists")

	repo_impl := Taskchain_Repo_SQLite{conn = &conn}
	repo := new_taskchain_repository(&repo_impl, &conn)

	owner := domain.User_ID("user_sub_tester")
	cid := domain.Task_Chain_ID("chain_sub_test")
	tid1 := domain.Task_ID("task_sub_test_1")
	tid2 := domain.Task_ID("task_sub_test_2")
	inst1 := "inst_worker_1"
	inst2 := "inst_worker_2"

	// 1. Initial list queries return empty slices
	subs0, err0 := iface.taskchain_list_subscriptions_by_chain(&repo, cid, owner)
	testing.expect_value(t, err0.code, domain.Error_Code.None)
	testing.expect_value(t, len(subs0), 0)
	free_subscriptions(subs0)

	subs_task0, err_task0 := iface.taskchain_list_subscriptions_by_task(&repo, tid1, owner)
	testing.expect_value(t, err_task0.code, domain.Error_Code.None)
	testing.expect_value(t, len(subs_task0), 0)
	free_subscriptions(subs_task0)

	subs_inst0, err_inst0 := iface.taskchain_list_subscriptions_by_instance(&repo, inst1, owner)
	testing.expect_value(t, err_inst0.code, domain.Error_Code.None)
	testing.expect_value(t, len(subs_inst0), 0)
	free_subscriptions(subs_inst0)

	// 2. Save chain-level subscription
	sub1 := domain.Task_Subscription{
		subscription_id              = "sub_1",
		owner_user_id                = owner,
		subscriber_agent_instance_id = inst1,
		chain_id                     = cid,
		task_id                      = "",
		event_type                   = "chain_status_changed",
		created_at                   = "2026-09-28T10:00:00Z",
	}
	saved1, ok1, s_err1 := iface.taskchain_save_subscription(&repo, sub1)
	testing.expect(t, ok1, "save sub1 ok")
	testing.expect_value(t, s_err1.code, domain.Error_Code.None)
	testing.expect_value(t, saved1.subscription_id, "sub_1")

	// 3. Save task-level subscription for same instance
	sub2 := domain.Task_Subscription{
		subscription_id              = "sub_2",
		owner_user_id                = owner,
		subscriber_agent_instance_id = inst1,
		chain_id                     = cid,
		task_id                      = tid1,
		event_type                   = "task_status_changed",
		created_at                   = "2026-09-28T10:01:00Z",
	}
	saved2, ok2, s_err2 := iface.taskchain_save_subscription(&repo, sub2)
	testing.expect(t, ok2, "save sub2 ok")
	testing.expect_value(t, s_err2.code, domain.Error_Code.None)
	testing.expect_value(t, saved2.subscription_id, "sub_2")

	// 4. Save task-level subscription for different instance (inst2) on task2
	sub3 := domain.Task_Subscription{
		subscription_id              = "sub_3",
		owner_user_id                = owner,
		subscriber_agent_instance_id = inst2,
		chain_id                     = cid,
		task_id                      = tid2,
		event_type                   = "task_status_changed",
		created_at                   = "2026-09-28T10:02:00Z",
	}
	saved3, ok3, s_err3 := iface.taskchain_save_subscription(&repo, sub3)
	testing.expect(t, ok3, "save sub3 ok")
	testing.expect_value(t, s_err3.code, domain.Error_Code.None)
	testing.expect_value(t, saved3.subscription_id, "sub_3")

	// 5. Query list by chain: should return all 3 subscriptions for chain cid
	chain_subs, c_err := iface.taskchain_list_subscriptions_by_chain(&repo, cid, owner)
	testing.expect_value(t, c_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(chain_subs), 3)
	if len(chain_subs) == 3 {
		testing.expect_value(t, chain_subs[0].subscription_id, "sub_1")
		testing.expect_value(t, chain_subs[1].subscription_id, "sub_2")
		testing.expect_value(t, chain_subs[2].subscription_id, "sub_3")
	}
	free_subscriptions(chain_subs)

	// 6. Query list by task
	task1_subs, t_err1 := iface.taskchain_list_subscriptions_by_task(&repo, tid1, owner)
	testing.expect_value(t, t_err1.code, domain.Error_Code.None)
	testing.expect_value(t, len(task1_subs), 1)
	if len(task1_subs) == 1 {
		testing.expect_value(t, task1_subs[0].subscription_id, "sub_2")
		testing.expect_value(t, task1_subs[0].subscriber_agent_instance_id, inst1)
		testing.expect_value(t, string(task1_subs[0].task_id), string(tid1))
	}
	free_subscriptions(task1_subs)

	task2_subs, t_err2 := iface.taskchain_list_subscriptions_by_task(&repo, tid2, owner)
	testing.expect_value(t, t_err2.code, domain.Error_Code.None)
	testing.expect_value(t, len(task2_subs), 1)
	if len(task2_subs) == 1 {
		testing.expect_value(t, task2_subs[0].subscription_id, "sub_3")
		testing.expect_value(t, task2_subs[0].subscriber_agent_instance_id, inst2)
		testing.expect_value(t, string(task2_subs[0].task_id), string(tid2))
	}
	free_subscriptions(task2_subs)

	// 7. Query list by instance
	inst1_subs, i_err1 := iface.taskchain_list_subscriptions_by_instance(&repo, inst1, owner)
	testing.expect_value(t, i_err1.code, domain.Error_Code.None)
	testing.expect_value(t, len(inst1_subs), 2)
	if len(inst1_subs) == 2 {
		testing.expect_value(t, inst1_subs[0].subscription_id, "sub_1")
		testing.expect_value(t, inst1_subs[1].subscription_id, "sub_2")
	}
	free_subscriptions(inst1_subs)

	inst2_subs, i_err2 := iface.taskchain_list_subscriptions_by_instance(&repo, inst2, owner)
	testing.expect_value(t, i_err2.code, domain.Error_Code.None)
	testing.expect_value(t, len(inst2_subs), 1)
	if len(inst2_subs) == 1 {
		testing.expect_value(t, inst2_subs[0].subscription_id, "sub_3")
	}
	free_subscriptions(inst2_subs)

	// 8. Test owner isolation: other user query returns empty
	other_owner := domain.User_ID("user_other")
	other_subs, o_err := iface.taskchain_list_subscriptions_by_chain(&repo, cid, other_owner)
	testing.expect_value(t, o_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(other_subs), 0)
	free_subscriptions(other_subs)

	// 9. Upsert on conflict: duplicate subscriber + chain + task + event_type updates subscription_id and created_at
	sub1_dup := domain.Task_Subscription{
		subscription_id              = "sub_1_updated",
		owner_user_id                = owner,
		subscriber_agent_instance_id = inst1,
		chain_id                     = cid,
		task_id                      = "",
		event_type                   = "chain_status_changed",
		created_at                   = "2026-09-28T10:05:00Z",
	}
	_, ok_dup, dup_err := iface.taskchain_save_subscription(&repo, sub1_dup)
	testing.expect(t, ok_dup, "save sub1_dup ok")
	testing.expect_value(t, dup_err.code, domain.Error_Code.None)

	// Total count for chain cid should still be 3 (not 4)
	chain_subs_after, c_err_after := iface.taskchain_list_subscriptions_by_chain(&repo, cid, owner)
	testing.expect_value(t, c_err_after.code, domain.Error_Code.None)
	testing.expect_value(t, len(chain_subs_after), 3)
	free_subscriptions(chain_subs_after)

	// 10. Remove subscription
	rem_ok, rem_err := iface.taskchain_remove_subscription(&repo, "sub_2", owner)
	testing.expect(t, rem_ok, "remove sub_2 ok")
	testing.expect_value(t, rem_err.code, domain.Error_Code.None)

	// Verify sub_2 removed from task1
	task1_subs_rem, _ := iface.taskchain_list_subscriptions_by_task(&repo, tid1, owner)
	testing.expect_value(t, len(task1_subs_rem), 0)
	free_subscriptions(task1_subs_rem)

	// Verify inst1 now only has 1 subscription
	inst1_subs_rem, _ := iface.taskchain_list_subscriptions_by_instance(&repo, inst1, owner)
	testing.expect_value(t, len(inst1_subs_rem), 1)
	free_subscriptions(inst1_subs_rem)

	// Removing non-existent returns false
	rem_fake_ok, rem_fake_err := iface.taskchain_remove_subscription(&repo, "non_existent_sub", owner)
	testing.expect(t, !rem_fake_ok, "remove non-existent returns false")
	testing.expect_value(t, rem_fake_err.code, domain.Error_Code.None)

	// Removing with wrong owner returns false
	rem_wrong_ok, rem_wrong_err := iface.taskchain_remove_subscription(&repo, "sub_3", other_owner)
	testing.expect(t, !rem_wrong_ok, "remove with wrong owner returns false")
	testing.expect_value(t, rem_wrong_err.code, domain.Error_Code.None)
}
