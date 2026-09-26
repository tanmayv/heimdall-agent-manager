package sqlite

import "core:fmt"
import "core:os"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// REQ-TB-1: tasks.bridge_id roundtrip (empty = inherit, preset pin, clear via
// re-save) and populated-db-safe migration (guarded ALTER, rerunnable).
@(test)
test_task_bridge_id_sqlite_roundtrip :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_task_bridge_%d.db", os.get_pid())
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

	// The migration must have added the column.
	testing.expect(t, table_column_exists(&conn, "tasks", "bridge_id"), "tasks.bridge_id column exists")

	repo_impl := Taskchain_Repo_SQLite{conn = &conn}
	repo := new_taskchain_repository(&repo_impl, &conn)

	owner := domain.User_ID("user_tb_repo")
	cid := domain.Task_Chain_ID("chain_tb_repo")

	chain := domain.Task_Chain{
		chain_id      = cid,
		owner_user_id = owner,
		title         = "Task Bridge Chain",
		publish_state = .Draft,
		status        = .Active,
		kind          = "tb_test",
		created_at    = "2026-09-25T10:00:00Z",
		updated_at    = "2026-09-25T10:00:00Z",
	}
	_, save_chain_ok, save_chain_err := iface.taskchain_save_chain(&repo, chain)
	testing.expect(t, save_chain_ok, "save chain ok")
	testing.expect_value(t, save_chain_err.code, domain.Error_Code.None)

	// 1. Save with an empty bridge_id (inherit) — reads back empty.
	task_empty := domain.Task{
		task_id            = "task_tb_empty",
		chain_id           = cid,
		owner_user_id      = owner,
		title              = "Inherit Task",
		publish_state      = .Draft,
		status             = .Assigned,
		priority           = .P2,
		assignee_ref_json  = `{}`,
		reviewer_refs_json = `[]`,
		bridge_id          = "",
		created_at         = "2026-09-25T10:01:00Z",
		updated_at         = "2026-09-25T10:01:00Z",
	}
	_, e_ok, e_err := iface.taskchain_save_task(&repo, task_empty)
	testing.expect(t, e_ok, "save inherit task ok")
	testing.expect_value(t, e_err.code, domain.Error_Code.None)

	got_empty, g_ok, g_err := iface.taskchain_get_task(&repo, "task_tb_empty")
	testing.expect(t, g_ok, "get inherit task ok")
	testing.expect_value(t, g_err.code, domain.Error_Code.None)
	testing.expect_value(t, got_empty.bridge_id, "")

	// 2. Save with a preset bridge pin — roundtrips through save AND list.
	task_pinned := domain.Task{
		task_id            = "task_tb_pinned",
		chain_id           = cid,
		owner_user_id      = owner,
		title              = "Pinned Task",
		publish_state      = .Draft,
		status             = .Assigned,
		priority           = .P1,
		assignee_ref_json  = `{}`,
		reviewer_refs_json = `[]`,
		bridge_id          = "brg_pin",
		created_at         = "2026-09-25T10:02:00Z",
		updated_at         = "2026-09-25T10:02:00Z",
	}
	_, p_ok, p_err := iface.taskchain_save_task(&repo, task_pinned)
	testing.expect(t, p_ok, "save pinned task ok")
	testing.expect_value(t, p_err.code, domain.Error_Code.None)

	got_pinned, pg_ok, _ := iface.taskchain_get_task(&repo, "task_tb_pinned")
	testing.expect(t, pg_ok, "get pinned task ok")
	testing.expect_value(t, got_pinned.bridge_id, "brg_pin")

	listed, l_err := iface.taskchain_list_tasks_by_chain(&repo, cid, owner)
	testing.expect_value(t, l_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(listed), 2)
	for task in listed {
		if string(task.task_id) == "task_tb_pinned" do testing.expect_value(t, task.bridge_id, "brg_pin")
		if string(task.task_id) == "task_tb_empty" do testing.expect_value(t, task.bridge_id, "")
	}

	// 3. Clear via re-save (UPSERT path) — pin drops back to inherit.
	got_pinned.bridge_id = ""
	got_pinned.updated_at = "2026-09-25T10:03:00Z"
	_, c_ok, c_err := iface.taskchain_save_task(&repo, got_pinned)
	testing.expect(t, c_ok, "re-save cleared task ok")
	testing.expect_value(t, c_err.code, domain.Error_Code.None)
	got_cleared, cg_ok, _ := iface.taskchain_get_task(&repo, "task_tb_pinned")
	testing.expect(t, cg_ok, "get cleared task ok")
	testing.expect_value(t, got_cleared.bridge_id, "")

	// Restore the pin for the migration checks below.
	got_cleared.bridge_id = "brg_pin"
	got_cleared.updated_at = "2026-09-25T10:04:00Z"
	_, _, _ = iface.taskchain_save_task(&repo, got_cleared)

	// 4. Populated-DB safety, the migrations.odin:735-752 way: re-running
	// migrations on a populated DB succeeds and preserves the data.
	mig_again_ok, mig_again_err := run_migrations(&conn)
	testing.expect(t, mig_again_ok, "re-run migrations ok")
	testing.expect_value(t, mig_again_err.code, domain.Error_Code.None)
	got_after, ga_ok, _ := iface.taskchain_get_task(&repo, "task_tb_pinned")
	testing.expect(t, ga_ok, "get task after re-migration ok")
	testing.expect_value(t, got_after.bridge_id, "brg_pin")

	// 5. Stronger populated-DB check: simulate a pre-upgrade DB by dropping the
	// column with rows present, then re-migrate — the guarded ALTER must re-add
	// it and the surviving rows must keep their data.
	if exec(&conn, "ALTER TABLE tasks DROP COLUMN bridge_id;") {
		testing.expect(t, !table_column_exists(&conn, "tasks", "bridge_id"), "column dropped for pre-upgrade simulation")
		mig_upgrade_ok, mig_upgrade_err := run_migrations(&conn)
		testing.expect(t, mig_upgrade_ok, "re-migrate pre-upgrade populated db ok")
		testing.expect_value(t, mig_upgrade_err.code, domain.Error_Code.None)
		testing.expect(t, table_column_exists(&conn, "tasks", "bridge_id"), "column re-added by upgrade")
		got_upgraded, gu_ok, _ := iface.taskchain_get_task(&repo, "task_tb_pinned")
		testing.expect(t, gu_ok, "get task after column upgrade ok")
		testing.expect_value(t, got_upgraded.bridge_id, "")
	} else {
		fmt.println("SKIP: sqlite cannot DROP COLUMN bridge_id; guarded re-run check above still applies")
	}
}
