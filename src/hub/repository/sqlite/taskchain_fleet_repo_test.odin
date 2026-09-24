package sqlite

import "core:fmt"
import "core:os"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
test_taskchain_fleet_sqlite_lifecycle :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_taskchain_fleet_%d.db", os.get_pid())
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

	// Verify table exists
	testing.expect(t, sqlite_object_exists(&conn, "task_chain_fleets"), "task_chain_fleets table exists")

	repo_impl := Taskchain_Repo_SQLite{conn = &conn}
	repo := new_taskchain_repository(&repo_impl, &conn)

	owner := domain.User_ID("user_fleet_tester")
	cid := domain.Task_Chain_ID("chain_fleet_test")

	// Create parent task chain for foreign key
	chain := domain.Task_Chain{
		chain_id                      = cid,
		owner_user_id                 = owner,
		title                         = "Fleet Test Chain",
		description                   = "desc",
		publish_state                 = .Published,
		status                        = .Active,
		kind                          = "fleet_testing",
		coordinator_agent_instance_id = "inst_c",
		default_reviewer_refs_json    = "[]",
		created_at                    = "2026-09-23T10:00:00Z",
		updated_at                    = "2026-09-23T10:00:00Z",
	}
	_, save_ok, save_err := iface.taskchain_save_chain(&repo, chain)
	testing.expect(t, save_ok, "save chain ok")
	testing.expect_value(t, save_err.code, domain.Error_Code.None)

	// 1. Initial list is empty
	fleets0, f_err0 := iface.taskchain_list_fleets_by_chain(&repo, cid, owner)
	testing.expect_value(t, f_err0.code, domain.Error_Code.None)
	testing.expect_value(t, len(fleets0), 0)

	// 2. Upsert fleet
	fleet1 := domain.Task_Chain_Fleet{
		task_chain_id    = cid,
		agent_id         = "agt_worker",
		capacity         = 3,
		min_warm         = 1,
		idle_ttl_seconds = 300,
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:00:00Z",
	}
	saved1, s_err1 := iface.taskchain_upsert_fleet(&repo, fleet1)
	testing.expect_value(t, s_err1.code, domain.Error_Code.None)
	testing.expect_value(t, saved1.capacity, 3)
	testing.expect_value(t, saved1.min_warm, 1)

	// 3. List fleets
	fleets1, f_err1 := iface.taskchain_list_fleets_by_chain(&repo, cid, owner)
	testing.expect_value(t, f_err1.code, domain.Error_Code.None)
	testing.expect_value(t, len(fleets1), 1)
	if len(fleets1) == 1 {
		testing.expect_value(t, string(fleets1[0].task_chain_id), string(cid))
		testing.expect_value(t, fleets1[0].agent_id, "agt_worker")
		testing.expect_value(t, fleets1[0].capacity, 3)
		testing.expect_value(t, fleets1[0].min_warm, 1)
		testing.expect_value(t, fleets1[0].idle_ttl_seconds, 300)
	}

	// 4. Upsert (update) existing fleet
	fleet1_updated := domain.Task_Chain_Fleet{
		task_chain_id    = cid,
		agent_id         = "agt_worker",
		capacity         = 5,
		min_warm         = 2,
		idle_ttl_seconds = 900,
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:10:00Z",
	}
	saved_up, sup_err := iface.taskchain_upsert_fleet(&repo, fleet1_updated)
	testing.expect_value(t, sup_err.code, domain.Error_Code.None)
	testing.expect_value(t, saved_up.capacity, 5)

	fleets2, f_err2 := iface.taskchain_list_fleets_by_chain(&repo, cid, owner)
	testing.expect_value(t, f_err2.code, domain.Error_Code.None)
	testing.expect_value(t, len(fleets2), 1)
	if len(fleets2) == 1 {
		testing.expect_value(t, fleets2[0].capacity, 5)
		testing.expect_value(t, fleets2[0].min_warm, 2)
		testing.expect_value(t, fleets2[0].idle_ttl_seconds, 900)
	}

	// 5. Delete fleet
	del_ok, del_err := iface.taskchain_delete_fleet(&repo, cid, "agt_worker", owner)
	testing.expect_value(t, del_err.code, domain.Error_Code.None)
	testing.expect(t, del_ok, "fleet deleted")

	// 6. List fleets is now empty
	fleets3, f_err3 := iface.taskchain_list_fleets_by_chain(&repo, cid, owner)
	testing.expect_value(t, f_err3.code, domain.Error_Code.None)
	testing.expect_value(t, len(fleets3), 0)

	// 7. Delete non-existent fleet returns false
	del_ok2, del_err2 := iface.taskchain_delete_fleet(&repo, cid, "agt_worker", owner)
	testing.expect_value(t, del_err2.code, domain.Error_Code.None)
	testing.expect(t, !del_ok2, "non-existent fleet returns false")
}
