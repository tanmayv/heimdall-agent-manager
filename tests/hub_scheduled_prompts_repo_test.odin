package hub_scheduled_prompts_repo_test

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
	db_path := "/tmp/sp_repo_test.db"
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	check(open_ok, fmt.tprintf("open db: %s", open_err.message))
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok, fmt.tprintf("run_migrations: %s", mig_err.message))

	// Setup agent instances for bridge testing
	check(sqlite.exec(&conn, "INSERT INTO bridges (bridge_id, owner_user_id, status, created_at, updated_at) VALUES ('brg_1', 'usr_1', 'online', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');"), "bridge insert")
	check(sqlite.exec(&conn, "INSERT INTO agent_instances (agent_instance_id, owner_user_id, agent_id, bridge_id, runtime_status, created_at, updated_at) VALUES ('inst_1', 'usr_1', 'agt_1', 'brg_1', 'running', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');"), "agent instance insert")

	repo_impl: sqlite.Scheduled_Prompt_Repo_SQLite
	repo := sqlite.new_scheduled_prompt_repository(&repo_impl, &conn)

	// 1. Create (Save)
	prompt := domain.Scheduled_Prompt{
		id = domain.Scheduled_Prompt_ID("sp_1"),
		owner_user_id = domain.User_ID("usr_1"),
		target_instance_id = domain.Agent_Instance_ID("inst_1"),
		prompt_text = "hello world",
		target_run_at = "2026-01-01T12:00:00Z",
		interval = "1h",
		state = .Active,
		in_flight = false,
		created_at = "2026-01-01T10:00:00Z",
		updated_at = "2026-01-01T10:00:00Z",
	}
	saved, ok_save, err_save := repo.save(repo.ctx, prompt)
	check(ok_save, fmt.tprintf("save prompt: %s", err_save.message))

	// 2. Read (Get)
	got, ok_get, err_get := repo.get(repo.ctx, domain.Scheduled_Prompt_ID("sp_1"))
	check(ok_get, fmt.tprintf("get prompt: %s", err_get.message))
	check(got.prompt_text == "hello world", "prompt text mismatch")
	check(got.interval == "1h", "interval mismatch")

	// 3. CAS Lease Update
	// Should fail if target_run_at > now
	cas_fail, _ := repo.cas_lease(repo.ctx, domain.Scheduled_Prompt_ID("sp_1"), "2026-01-01T11:00:00Z", "2026-01-01T11:00:00Z")
	check(!cas_fail, "CAS lease should fail before target_run_at")

	// Should succeed if target_run_at <= now
	cas_ok, _ := repo.cas_lease(repo.ctx, domain.Scheduled_Prompt_ID("sp_1"), "2026-01-01T12:00:00Z", "2026-01-01T12:00:00Z")
	check(cas_ok, "CAS lease should succeed at or after target_run_at")

	// Second CAS should fail because in_flight = 1
	cas_fail2, _ := repo.cas_lease(repo.ctx, domain.Scheduled_Prompt_ID("sp_1"), "2026-01-01T12:00:00Z", "2026-01-01T12:00:00Z")
	check(!cas_fail2, "CAS lease should fail if already in flight")

	// Verify in-flight
	got_leased, _, _ := repo.get(repo.ctx, domain.Scheduled_Prompt_ID("sp_1"))
	check(got_leased.in_flight == true, "prompt should be in flight")
	check(got_leased.state == .In_Flight, "prompt state should be in_flight")

	// 4. Max updated_at for bridge
	max_up, _ := repo.max_updated_at_for_bridge(repo.ctx, domain.Bridge_ID("brg_1"))
	check(max_up == "2026-01-01T12:00:00Z", fmt.tprintf("max updated_at mismatch: got %s", max_up))

	// 5. Delete (Soft delete)
	del_ok, _ := repo.delete_prompt(repo.ctx, domain.Scheduled_Prompt_ID("sp_1"))
	check(del_ok, "delete should succeed")

	// Read after delete should return not found
	_, ok_get_del, _ := repo.get(repo.ctx, domain.Scheduled_Prompt_ID("sp_1"))
	check(!ok_get_del, "deleted prompt should not be retrieved via get")

	// But max updated_at for bridge should STILL reflect the soft-delete updated_at
	max_up_del, _ := repo.max_updated_at_for_bridge(repo.ctx, domain.Bridge_ID("brg_1"))
	check(max_up_del != "", "max updated_at should reflect soft-deleted record")

	fmt.println("ALL SCHEDULED PROMPT REPO TESTS PASSED")
}
