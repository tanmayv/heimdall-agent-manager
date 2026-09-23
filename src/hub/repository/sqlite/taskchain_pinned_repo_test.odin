package sqlite

import "core:fmt"
import "core:os"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
test_taskchain_pinned_sqlite_lifecycle :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_taskchain_pinned_%d.db", os.get_pid())
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

	// Verify columns exist
	testing.expect(t, table_column_exists(&conn, "task_chains", "is_pinned"), "is_pinned column exists")
	testing.expect(t, table_column_exists(&conn, "task_chains", "pinned_at"), "pinned_at column exists")

	repo_impl := Taskchain_Repo_SQLite{conn = &conn}
	repo := new_taskchain_repository(&repo_impl, &conn)

	owner := domain.User_ID("user_pin_tester")

	// Initially count of pinned is 0
	count0, c_err0 := iface.taskchain_count_pinned_chains(&repo, owner)
	testing.expect_value(t, c_err0.code, domain.Error_Code.None)
	testing.expect_value(t, count0, 0)

	// Create and pin 10 chains
	for i in 1..=10 {
		cid := fmt.tprintf("chain_test_%02d", i)
		c := domain.Task_Chain{
			chain_id                      = domain.Task_Chain_ID(cid),
			owner_user_id                 = owner,
			title                         = fmt.tprintf("Chain %d", i),
			description                   = "desc",
			publish_state                 = .Published,
			status                        = .Active,
			kind                          = "team_work",
			coordinator_agent_instance_id = "inst_c",
			default_reviewer_refs_json    = "[]",
			created_at                    = fmt.tprintf("2026-09-21T10:%02d:00Z", i),
			updated_at                    = fmt.tprintf("2026-09-21T10:%02d:00Z", i),
			is_pinned                     = true,
			pinned_at                     = fmt.tprintf("2026-09-21T10:%02d:00Z", i),
		}
		saved, sok, serr := iface.taskchain_save_chain(&repo, c)
		testing.expect(t, sok, "save chain ok")
		testing.expect_value(t, serr.code, domain.Error_Code.None)
		testing.expect(t, saved.is_pinned, "is_pinned saved as true")
	}

	// Verify count is 10
	count10, c_err10 := iface.taskchain_count_pinned_chains(&repo, owner)
	testing.expect_value(t, c_err10.code, domain.Error_Code.None)
	testing.expect_value(t, count10, 10)

	// List pinned chains, verify count 10 and ordered pinned_at DESC (10 down to 1)
	pinned_list, l_err := iface.taskchain_list_pinned_chains(&repo, owner)
	defer delete(pinned_list)
	testing.expect_value(t, l_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(pinned_list), 10)
	if len(pinned_list) == 10 {
		testing.expect_value(t, string(pinned_list[0].chain_id), "chain_test_10")
		testing.expect_value(t, string(pinned_list[9].chain_id), "chain_test_01")
	}

	// Unpin chain 10
	c10, got10, g_err10 := iface.taskchain_get_chain(&repo, domain.Task_Chain_ID("chain_test_10"))
	testing.expect(t, got10, "got chain 10")
	testing.expect_value(t, g_err10.code, domain.Error_Code.None)
	c10.is_pinned = false
	c10.pinned_at = ""
	_, u_ok, u_err := iface.taskchain_save_chain(&repo, c10)
	testing.expect(t, u_ok, "unpin save ok")
	testing.expect_value(t, u_err.code, domain.Error_Code.None)

	// Verify count dropped to 9
	count9, c_err9 := iface.taskchain_count_pinned_chains(&repo, owner)
	testing.expect_value(t, c_err9.code, domain.Error_Code.None)
	testing.expect_value(t, count9, 9)

	// List pinned chains again
	pinned_list9, l_err9 := iface.taskchain_list_pinned_chains(&repo, owner)
	defer delete(pinned_list9)
	testing.expect_value(t, l_err9.code, domain.Error_Code.None)
	testing.expect_value(t, len(pinned_list9), 9)
	if len(pinned_list9) == 9 {
		testing.expect_value(t, string(pinned_list9[0].chain_id), "chain_test_09")
	}
}
