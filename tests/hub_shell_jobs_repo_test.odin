package hub_shell_jobs_repo_test

import "core:fmt"
import "core:os"
import domain "odin_test:hub/domain"
import sqlite "odin_test:hub/repository/sqlite"

check :: proc(ok: bool, msg: string) {
	if ok do return
	fmt.eprintln("FAIL:", msg)
	os.exit(1)
}

main :: proc() {
	db_path := "/tmp/shell_jobs_repo_test.db"
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	check(open_ok, fmt.tprintf("open db: %s", open_err.message))
	defer sqlite.close(&conn)

	// Migration 039 creates shell_jobs; run twice to prove idempotency.
	mig_ok, mig_err := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok, fmt.tprintf("run_migrations: %s", mig_err.message))
	mig_ok2, mig_err2 := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok2, fmt.tprintf("run_migrations 2nd run: %s", mig_err2.message))

	repo_impl: sqlite.Shell_Job_Repo_SQLite
	repo := sqlite.new_shell_job_repository(&repo_impl, &conn)

	// Test 1: insert a "running" job (no exit code yet).
	running := domain.Shell_Job{
		exec_id           = "sexc_1",
		owner_user_id     = "usr_1",
		agent_instance_id = "inst_a",
		cmd               = "sleep 60",
		status            = "running",
		started_at        = "2026-09-15T00:00:00Z",
		created_at        = "2026-09-15T00:00:00Z",
	}
	ok1, err1 := repo.upsert(repo.ctx, running)
	check(ok1, fmt.tprintf("upsert running: %s", err1.message))

	got1, err_l1 := repo.list_by_instance(repo.ctx, "usr_1", "inst_a", "", 50)
	check(err_l1.message == "", "list after running")
	check(len(got1) == 1, fmt.tprintf("expected 1 job, got %d", len(got1)))
	check(got1[0].status == "running", "status running")
	check(!got1[0].exit_code_set, "running job has no exit code set")
	check(got1[0].cmd == "sleep 60", "cmd preserved")

	// Test 2: complete the SAME job (exit 0). created_at + cmd must be preserved,
	// finished_at + exit_code set, status advanced.
	completed := domain.Shell_Job{
		exec_id           = "sexc_1",
		owner_user_id     = "usr_1",
		agent_instance_id = "inst_a",
		cmd               = "", // empty: must NOT clobber the stored cmd
		status            = "completed",
		started_at        = "", // empty: must NOT clobber
		finished_at       = "2026-09-15T00:00:20Z",
		created_at        = "2026-09-15T09:99:99Z", // ignored on conflict
		exit_code         = 0,
		exit_code_set     = true,
	}
	ok2, err2 := repo.upsert(repo.ctx, completed)
	check(ok2, fmt.tprintf("upsert completed: %s", err2.message))

	got2, _ := repo.list_by_instance(repo.ctx, "usr_1", "inst_a", "", 50)
	check(len(got2) == 1, "still one row after completion (upsert, not insert)")
	check(got2[0].status == "completed", "status completed")
	check(got2[0].exit_code_set && got2[0].exit_code == 0, "exit_code 0 is set (distinct from running)")
	check(got2[0].cmd == "sleep 60", "cmd preserved across completion report")
	check(got2[0].started_at == "2026-09-15T00:00:00Z", "started_at preserved")
	check(got2[0].finished_at == "2026-09-15T00:00:20Z", "finished_at set")
	check(got2[0].created_at == "2026-09-15T00:00:00Z", "created_at preserved (not clobbered)")

	// Test 3: a failed job with a negative sentinel exit code round-trips.
	failed := domain.Shell_Job{
		exec_id           = "sexc_2",
		owner_user_id     = "usr_1",
		agent_instance_id = "inst_a",
		cmd               = "run-forever",
		status            = "failed",
		started_at        = "2026-09-15T00:01:00Z",
		finished_at       = "2026-09-15T00:31:00Z",
		created_at        = "2026-09-15T00:01:00Z",
		exit_code         = -1,
		exit_code_set     = true,
	}
	ok3, err3 := repo.upsert(repo.ctx, failed)
	check(ok3, fmt.tprintf("upsert failed: %s", err3.message))
	got3, _ := repo.list_by_instance(repo.ctx, "usr_1", "inst_a", "failed", 50)
	check(len(got3) == 1, fmt.tprintf("status filter 'failed' returns 1, got %d", len(got3)))
	check(got3[0].exec_id == "sexc_2", "failed job exec_id")
	check(got3[0].exit_code == -1, "negative exit code round-trips")

	// Test 4: owner + instance scoping. Another owner's job on another instance is
	// never returned to usr_1/inst_a.
	other := domain.Shell_Job{
		exec_id = "sexc_3", owner_user_id = "usr_2", agent_instance_id = "inst_b",
		cmd = "echo hi", status = "completed", started_at = "2026-09-15T00:02:00Z",
		finished_at = "2026-09-15T00:02:01Z", created_at = "2026-09-15T00:02:00Z",
		exit_code = 0, exit_code_set = true,
	}
	ok4, _ := repo.upsert(repo.ctx, other)
	check(ok4, "upsert other owner")

	scoped, _ := repo.list_by_instance(repo.ctx, "usr_1", "inst_a", "", 50)
	check(len(scoped) == 2, fmt.tprintf("usr_1/inst_a sees only its 2 jobs, got %d", len(scoped)))
	for j in scoped {
		check(j.owner_user_id == "usr_1" && j.agent_instance_id == "inst_a", "no cross-owner/instance leakage")
	}
	// Ordered by created_at DESC: sexc_2 (00:01) before sexc_1 (00:00).
	check(scoped[0].exec_id == "sexc_2", "list ordered created_at DESC [0]")
	check(scoped[1].exec_id == "sexc_1", "list ordered created_at DESC [1]")

	other_owner, _ := repo.list_by_instance(repo.ctx, "usr_2", "inst_b", "", 50)
	check(len(other_owner) == 1, "usr_2/inst_b sees only its own job")
	check(other_owner[0].exec_id == "sexc_3", "other owner job")

	// Test 5: status filter that matches nothing.
	none, _ := repo.list_by_instance(repo.ctx, "usr_1", "inst_a", "running", 50)
	check(len(none) == 0, "no running jobs remain for usr_1/inst_a")

	fmt.println("ALL SHELL JOBS REPO TESTS PASSED")
}
