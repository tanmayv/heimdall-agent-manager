package sqlite

import "core:fmt"
import "core:os"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// REQ-BVS-1: migration 056 adds bridges.vault_status, and the column round-trips
// through bind_bridge/bridge_from_stmt.
//
// The "" case is tested explicitly because the DEFAULT is the part that can silently
// go wrong: the neighbouring columns telemetry_enabled and update_status both
// substitute a default word for "" on both the write and the read path, and doing that
// here would make every bridge that predates this migration report a vault state it
// never reported.
@(test)
test_bridge_vault_status_repo_roundtrip :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_bridge_vault_status_repo_%d.db", os.get_pid())
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
	testing.expect(t, table_column_exists(&conn, "bridges", "vault_status"), "migration 056 created bridges.vault_status")

	repo_impl := Bridge_Repo_SQLite{conn = &conn}
	repo := new_bridge_repository(&repo_impl, &conn)

	base := domain.Bridge{
		bridge_id = "brg_vault_status_repo",
		owner_user_id = domain.User_ID("user_bvs_repo"),
		label = "Vault Status Bridge",
		machine_hostname = "test-box",
		machine_os = "linux",
		machine_arch = "amd64",
		capabilities_json = "{}",
		hub_url = "http://127.0.0.1:8080",
		status = .Online,
		bridge_token_hash = "token_hash_bvs",
		created_at = "2026-10-04T10:00:00Z",
		updated_at = "2026-10-04T10:00:00Z",
		last_seen_at = "2026-10-04T10:00:00Z",
	}

	// 1. Unreported stays unreported across a save/load cycle.
	_, save_ok, save_err := iface.bridge_save_bridge(&repo, base)
	testing.expect(t, save_ok, "unreported bridge saved")
	testing.expect_value(t, save_err.code, domain.Error_Code.None)

	loaded, get_ok, _ := iface.bridge_get_bridge(&repo, base.bridge_id)
	defer { b := loaded; domain.bridge_destroy(&b) }
	testing.expect(t, get_ok, "unreported bridge loaded")
	testing.expect_value(t, loaded.vault_status, "")

	// 2. Each legal value round-trips verbatim.
	for value in ([3]string{"unlocked", "locked", "disabled"}) {
		updated := base
		updated.vault_status = value
		_, ok, _ := iface.bridge_save_bridge(&repo, updated)
		testing.expect(t, ok, fmt.tprintf("bridge saved with vault_status=%s", value))

		back, back_ok, _ := iface.bridge_get_bridge(&repo, base.bridge_id)
		defer { b := back; domain.bridge_destroy(&b) }
		testing.expect(t, back_ok, "bridge loaded")
		testing.expect_value(t, back.vault_status, value)
	}

	// 3. The listing path reads the same column (it has its own SELECT list, which is
	// exactly how a new column gets added to one query and forgotten in the other).
	listed, list_err := iface.bridge_list_by_owner(&repo, base.owner_user_id)
	defer {
		for br in listed {
			b := br; domain.bridge_destroy(&b)
		}
		delete(listed)
	}
	testing.expect_value(t, list_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(listed), 1)
	if len(listed) == 1 {
		testing.expect_value(t, listed[0].vault_status, "disabled")
	}
}
