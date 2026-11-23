package main

// Predecessor bridges (T4b, iss_18eab23e79e956c8): a same-account re-enrollment onto
// a new bridge id wipes the previous bridge's local secrets after the enrollment
// succeeded; uninstall --purge wipes recorded predecessors too.
//   odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_NAMES=main.test_enroll_predecessor_policy,...

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import bridgesvc "odin_test:lib/bridgesvc"
import vault "odin_test:lib/vault"

@(private = "file")
PRED_HUB :: "http://127.0.0.1:9"

@(private = "file")
Pred_Fixture :: struct {
	dir, config, token_file: string,
	old_id, new_id:          string,
}

// pred_fixture_open: bridge old_id (account usr_alice) enrolled on this machine with
// a persisted vault key, identity and per-scope directory; new_id enrolled by the
// same account and holding the in-memory vault key, sharing the explicit credential
// file (--bridge-token-file) with old_id. Hold both test mutexes.
@(private = "file")
pred_fixture_open :: proc(t: ^testing.T, label: string) -> (f: Pred_Fixture, ok: bool) {
	f.old_id, f.new_id = keystore_test_bridge_ids()
	testing.expect(t, bridge_keystore_set_hub(PRED_HUB))
	f.dir = fmt.tprintf("/tmp/enroll-pred-%s-%d", label, os.get_pid())
	_ = os.remove_all(f.dir)
	if os.make_directory_all(f.dir) != nil do return f, false
	f.config = strings.concatenate({f.dir, "/config.toml"}, context.temp_allocator)
	f.token_file = strings.concatenate({f.dir, "/bridge-token"}, context.temp_allocator)
	_ = os.write_entire_file_from_string(f.config, "")

	if !test_provision_identity(f.old_id, "usr_alice") do return f, false
	bridge_unseal_forget_identity()
	kr := test_keyring_from_hex(TEST_VAULT_KEY_HEX, 1)
	defer vault.keyring_wipe(&kr)
	if stored, _ := keystore_store_vault_keyring(f.old_id, test_keyring_bytes(&kr)); !stored do return f, false
	if scope, scoped := keystore_scope_name(f.old_id); scoped {
		if dir, dir_ok := bridge_vault_bridge_dir(scope, context.temp_allocator); dir_ok {
			_ = os.make_directory_all(dir)
			_ = os.write_entire_file_from_string(strings.concatenate({dir, "/marker"}, context.temp_allocator), "x")
		}
	}
	if !test_provision_identity(f.new_id, "usr_alice") do return f, false
	bridge_unseal_forget_identity()
	if !keystore_store_in_memory_vault_keyring(f.new_id, test_keyring_bytes(&kr)) do return f, false
	if !bridge_write_credential_file(f.token_file, PRED_HUB, f.new_id, "hbt_new.secret") do return f, false
	return f, true
}

@(private = "file")
pred_fixture_close :: proc(f: ^Pred_Fixture) {
	for id in ([2]string{f.old_id, f.new_id}) {
		keystore_lock_and_purge(id)
		_ = keystore_delete_identity_key(id)
		if scope, scoped := keystore_scope_name(id); scoped {
			if dir, ok := bridge_vault_bridge_dir(scope, context.temp_allocator); ok do _ = os.remove_all(dir)
		}
	}
	bridge_unseal_forget_identity()
	_ = bridge_keystore_set_hub("")
	_ = os.remove_all(f.dir)
}

@(private = "file")
pred_identity_present :: proc(id: string) -> bool {
	rec: Bridge_Identity_Record
	return keystore_read_identity(id, &rec) == .Found
}

@(private = "file")
pred_keyring_present :: proc(id: string) -> bool {
	kr, ok := keystore_read_persisted_vault_keyring(id)
	vault.keyring_wipe(&kr)
	return ok
}

@(private = "file")
pred_scope_dir_present :: proc(id: string) -> bool {
	scope, scoped := keystore_scope_name(id)
	if !scoped do return false
	dir, ok := bridge_vault_bridge_dir(scope, context.temp_allocator)
	return ok && os.exists(dir)
}

@(test)
test_enroll_predecessor_policy :: proc(t: ^testing.T) {
	// Same account, new id: the previous bridge is a predecessor.
	testing.expect(t, bridge_enroll_predecessor_to_wipe("brg_x", "brg_y", true, false))
	// Same id: a re-enrollment, nothing to wipe.
	testing.expect(t, !bridge_enroll_predecessor_to_wipe("brg_x", "brg_x", true, false))
	testing.expect(t, !bridge_enroll_predecessor_to_wipe(" brg_x", "brg_x ", true, false))
	// Other account: the replace path already wiped (and revoked) it.
	testing.expect(t, !bridge_enroll_predecessor_to_wipe("brg_x", "brg_y", true, true))
	// Other account, refused: nothing was written, nothing is wiped.
	testing.expect(t, !bridge_enroll_predecessor_to_wipe("brg_x", "brg_y", false, false))
	// A fresh enrollment has no predecessor.
	testing.expect(t, !bridge_enroll_predecessor_to_wipe("", "brg_y", true, false))
}

// Same account, new id, enrollment succeeded: the predecessor's vault key, identity
// and per-scope directory go; the live bridge, its in-memory key and the shared
// credential file stay; the record is gone.
@(test)
test_enroll_predecessor_same_account_new_id_wiped_after_success :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f, ok := pred_fixture_open(t, "success")
	defer pred_fixture_close(&f)
	if !testing.expect(t, ok, "fixture") do return

	args := []string{"ham-bridge", "enroll", "--hub", PRED_HUB, "--config", f.config, "--bridge-token-file", f.token_file, "--headless"}
	p := bridge_enroll_predecessor_for(args, PRED_HUB, "", f.old_id, f.token_file)
	testing.expect_value(t, p.token_file, "") // the shared explicit file is the live one
	testing.expect(t, bridge_predecessor_record(f.config, p))
	testing.expect(t, bridge_predecessor_record(f.config, p), "recording twice keeps one entry")
	testing.expect_value(t, len(bridge_predecessors_read(f.config)), 1)

	wiped, failed := bridge_predecessors_sweep(f.config, f.new_id, f.token_file)
	testing.expectf(t, len(failed) == 0, "nothing left behind (%v)", failed[:])
	testing.expect_value(t, len(wiped), 1)
	testing.expect(t, !pred_identity_present(f.old_id), "predecessor identity deleted")
	testing.expect(t, !pred_keyring_present(f.old_id), "predecessor vault key deleted")
	testing.expect(t, !pred_scope_dir_present(f.old_id), "predecessor per-scope directory deleted")
	testing.expect(t, pred_identity_present(f.new_id), "live identity kept")
	kr, in_mem := keystore_read_in_memory_vault_keyring(f.new_id)
	vault.keyring_wipe(&kr)
	testing.expect(t, in_mem, "live in-memory vault key kept")
	testing.expect(t, os.exists(f.token_file), "the live (shared) credential file kept")
	testing.expect(t, !os.exists(bridge_predecessors_path(f.config)), "record removed once wiped")
}

// An entry naming the live bridge (a re-enrollment of the same id) is dropped, never wiped.
@(test)
test_enroll_predecessor_same_id_never_wiped :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f, ok := pred_fixture_open(t, "sameid")
	defer pred_fixture_close(&f)
	if !testing.expect(t, ok, "fixture") do return

	testing.expect(t, bridge_predecessor_record(f.config, {bridge_id = f.new_id, hub = PRED_HUB}))
	wiped, failed := bridge_predecessors_sweep(f.config, f.new_id, f.token_file)
	testing.expect_value(t, len(wiped), 0)
	testing.expect_value(t, len(failed), 0)
	testing.expect(t, pred_identity_present(f.new_id), "live identity kept")
	testing.expect(t, pred_identity_present(f.old_id), "an unrecorded bridge is not touched")
	testing.expect(t, !os.exists(bridge_predecessors_path(f.config)), "entry of the live bridge dropped")
}

// A failed enrollment forgets the entry: the bridge it named is still this profile's
// live one and keeps every secret. Without a known live bridge nothing is wiped.
@(test)
test_enroll_predecessor_failed_enroll_keeps_live_bridge :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f, ok := pred_fixture_open(t, "failed")
	defer pred_fixture_close(&f)
	if !testing.expect(t, ok, "fixture") do return

	testing.expect(t, bridge_predecessor_record(f.config, {bridge_id = f.old_id, hub = PRED_HUB}))
	wiped, _ := bridge_predecessors_sweep(f.config, "", f.token_file)
	testing.expect_value(t, len(wiped), 0)
	testing.expect(t, pred_identity_present(f.old_id) && pred_keyring_present(f.old_id), "no live bridge known: nothing wiped")

	bridge_predecessor_forget(f.config, f.old_id)
	testing.expect(t, !os.exists(bridge_predecessors_path(f.config)), "the failed enrollment's entry is gone")
	wiped, _ = bridge_predecessors_sweep(f.config, f.new_id, f.token_file)
	testing.expect_value(t, len(wiped), 0)
	testing.expect(t, pred_identity_present(f.old_id) && pred_keyring_present(f.old_id) && pred_scope_dir_present(f.old_id), "the live bridge keeps every secret")
}

// A predecessor of another hub is not wiped under this hub's scope; it stays
// recorded for the uninstall.
@(test)
test_enroll_predecessor_other_hub_stays_recorded :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f, ok := pred_fixture_open(t, "otherhub")
	defer pred_fixture_close(&f)
	if !testing.expect(t, ok, "fixture") do return

	testing.expect(t, bridge_predecessor_record(f.config, {bridge_id = f.old_id, hub = "https://elsewhere.example.com"}))
	wiped, failed := bridge_predecessors_sweep(f.config, f.new_id, f.token_file)
	testing.expect_value(t, len(wiped), 0)
	testing.expect_value(t, len(failed), 0)
	testing.expect_value(t, len(bridge_predecessors_read(f.config)), 1)
}

// uninstall --purge wipes recorded predecessors and those a stale marker names,
// besides the credential's own bridge.
@(test)
test_uninstall_purge_wipes_recorded_predecessors :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f, ok := pred_fixture_open(t, "uninstall")
	defer pred_fixture_close(&f)
	if !testing.expect(t, ok, "fixture") do return

	testing.expect(t, bridge_predecessor_record(f.config, {bridge_id = f.old_id, hub = PRED_HUB}))
	// A marker naming the same predecessor is merged with the record (wiped once).
	testing.expect(t, bridgesvc.write_reenroll_marker(f.dir, {bridge_id = f.old_id, hub = PRED_HUB, reason = "revoked"}))
	u := Bridge_Uninstall{layout = bridgesvc.Layout{state_dir = f.dir}, config_path = f.config, hub = PRED_HUB, bridge_id = f.new_id}
	bridge_uninstall_collect_predecessors(&u)
	testing.expect_value(t, len(u.predecessors), 1)
	if len(u.predecessors) == 1 do testing.expect_value(t, u.predecessors[0].bridge_id, f.old_id)

	still := make([dynamic]string, context.temp_allocator)
	testing.expect_value(t, bridge_uninstall_wipe_predecessors(&u, &still), 1)
	testing.expectf(t, len(still) == 0, "nothing left (%v)", still[:])
	testing.expect(t, !pred_identity_present(f.old_id) && !pred_keyring_present(f.old_id) && !pred_scope_dir_present(f.old_id), "predecessor wiped")
	testing.expect(t, pred_identity_present(f.new_id), "the credential's bridge is left to the regular secrets step")
	testing.expect_value(t, bridge_keystore_hub(), "http://127.0.0.1:9")
}
