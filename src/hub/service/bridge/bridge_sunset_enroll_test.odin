// REQ-3: "register this machine as NEW and sunset one of mine" through the bridge
// service (enroll_bridge_from_device_grant with sunset_bridge_id, and the
// rollback_pending_enrollment that a failed vault commit runs). A real sqlite
// repository holds the rows so the assertions read what was actually written; the
// connection closer is a recorder (the real socket teardown is covered in
// src/hub/transport/http/bridge_revocation_ws_test.odin).
package bridge

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"

@(private = "file")
sunset_test_counter: int = 0

@(private = "file")
Sunset_Fixture :: struct {
	db_path: string,
	conn:    sqlite.Conn,
	impl:    sqlite.Bridge_Repo_SQLite,
	repo:    iface.Bridge_Repository,
	clock:   platform.Clock,
	ids:     platform.ID_Generator,
	svc:     Bridge_Service,
	limit:   int,
	closed:  [dynamic]string,
}

@(private = "file")
sunset_closer :: proc(ctx: rawptr, bridge_id: string) -> bool {
	f := (^Sunset_Fixture)(ctx)
	append(&f.closed, strings.clone(bridge_id))
	return true
}

@(private = "file")
sunset_lookup :: proc(ctx: rawptr, user_id: string) -> (domain.User_Entitlements, domain.Domain_Error) {
	entitlements := domain.unlimited_entitlements()
	entitlements.max_bridges = (^Sunset_Fixture)(ctx).limit
	return entitlements, {}
}

@(private = "file")
sunset_fixture_open :: proc(t: ^testing.T, tag: string, limit: int) -> ^Sunset_Fixture {
	f := new(Sunset_Fixture)
	seq := sync.atomic_add(&sunset_test_counter, 1)
	f.db_path = fmt.tprintf("/tmp/test_bridge_sunset_%s_%d_%d_%d.db", tag, os.get_pid(), time.now()._nsec, seq)
	os.remove(f.db_path)
	conn, ok, _ := sqlite.open(f.db_path)
	testing.expect(t, ok, "sqlite open ok")
	f.conn = conn
	mig_ok, _ := sqlite.run_migrations(&f.conn)
	testing.expect(t, mig_ok, "migrations ok")
	f.repo = sqlite.new_bridge_repository(&f.impl, &f.conn)
	f.clock = platform.real_clock()
	f.ids = platform.real_id_generator()
	f.svc = new_bridge_service(&f.repo, &f.clock, &f.ids)
	f.limit = limit
	f.svc.entitlements = {ctx = rawptr(f), lookup = sunset_lookup}
	f.closed = make([dynamic]string)
	with_connection_closer(&f.svc, Bridge_Connection_Closer{ctx = rawptr(f), close_bridge_connection = sunset_closer})
	return f
}

@(private = "file")
sunset_fixture_close :: proc(f: ^Sunset_Fixture) {
	sqlite.close(&f.conn)
	os.remove(f.db_path)
	for s in f.closed do delete(s)
	delete(f.closed)
	free(f)
}

@(private = "file")
sunset_input :: proc(owner: string, pending: bool, sunset := "", target := "") -> Device_Enroll_Input {
	return Device_Enroll_Input{
		owner_user_id = owner,
		bridge_public_key = "04aabbccdd",
		bridge_key_fingerprint = "aaaa bbbb cccc dddd",
		os_user = "tanmay",
		machine_hostname = "sunset-host",
		machine_os = "linux",
		target_bridge_id = target,
		sunset_bridge_id = sunset,
		pending = pending,
	}
}

// enrol_live: an enrolled (committed) bridge for owner; returns its id and family.
@(private = "file")
enrol_live :: proc(t: ^testing.T, f: ^Sunset_Fixture, owner: string) -> (bridge_id, family_id: string) {
	result, ok, err := enroll_bridge_from_device_grant(&f.svc, sunset_input(owner, false))
	testing.expect(t, ok, err.message)
	return strings.clone(result.bridge.bridge_id, context.temp_allocator), strings.clone(result.family_id, context.temp_allocator)
}

@(private = "file")
live_family_tokens :: proc(f: ^Sunset_Fixture, family_id: string) -> int {
	tokens, _ := iface.bridge_list_tokens_by_family(&f.repo, family_id)
	defer free_bridge_tokens(tokens)
	n := 0
	for tok in tokens do if tok.revoked_at == "" do n += 1
	return n
}

@(private = "file")
bridge_state :: proc(f: ^Sunset_Fixture, bridge_id: string) -> (found: bool, status: domain.Bridge_Status) {
	b, ok, _ := iface.bridge_get_bridge(&f.repo, bridge_id)
	if !ok do return false, {}
	defer domain.bridge_destroy(&b)
	return true, b.status
}

@(private = "file")
was_closed :: proc(f: ^Sunset_Fixture, bridge_id: string) -> bool {
	for id in f.closed do if id == bridge_id do return true
	return false
}

@(test)
test_sunset_with_target_bridge_id_is_refused_before_touching_anything :: proc(t: ^testing.T) {
	f := sunset_fixture_open(t, "exclusive", -1)
	defer sunset_fixture_close(f)
	target, target_family := enrol_live(t, f, "sx_owner")
	other, other_family := enrol_live(t, f, "sx_owner")

	result, ok, err := enroll_bridge_from_device_grant(&f.svc, sunset_input("sx_owner", true, sunset = other, target = target))
	defer iface.bridge_sunset_receipt_destroy(&result.sunset)
	testing.expect(t, !ok, "attach + sunset refused")
	testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)
	// Neither the attach (credential rotation) nor the sunset happened.
	testing.expect_value(t, live_family_tokens(f, target_family), 2)
	testing.expect_value(t, live_family_tokens(f, other_family), 2)
	_, other_status := bridge_state(f, other)
	testing.expect(t, other_status != .Revoked, "sunset bridge not revoked")
	testing.expect_value(t, len(f.closed), 0)
}

@(test)
test_sunset_on_full_plan_then_vault_rollback_restores_the_old_bridge :: proc(t: ^testing.T) {
	f := sunset_fixture_open(t, "full_rollback", 1)
	defer sunset_fixture_close(f)
	old, old_family := enrol_live(t, f, "sf_owner")

	// Without a sunset the full plan refuses a second bridge...
	_, plain_ok, plain_err := enroll_bridge_from_device_grant(&f.svc, sunset_input("sf_owner", true))
	testing.expect(t, !plain_ok, "full plan refuses without sunset")
	testing.expect_value(t, plain_err.code, domain.Error_Code.Plan_Limit_Reached)
	_, untouched := bridge_state(f, old)
	testing.expect(t, untouched != .Revoked, "a refused approval never revokes anything")

	// ...and admits it when the approval sunsets the old one, atomically.
	enrolled, ok, err := enroll_bridge_from_device_grant(&f.svc, sunset_input("sf_owner", true, sunset = old))
	defer iface.bridge_sunset_receipt_destroy(&enrolled.sunset)
	testing.expect(t, ok, err.message)
	if !ok do return
	new_id := strings.clone(enrolled.bridge.bridge_id, context.temp_allocator)
	testing.expect_value(t, enrolled.sunset.bridge_id, old)
	testing.expect_value(t, len(enrolled.sunset.token_ids), 2)
	_, old_status := bridge_state(f, old)
	testing.expect_value(t, old_status, domain.Bridge_Status.Revoked)
	testing.expect_value(t, live_family_tokens(f, old_family), 0)
	testing.expect(t, was_closed(f, old), "the sunset bridge's socket is dropped")
	count, _ := iface.bridge_count_active_by_owner(&f.repo, domain.User_ID("sf_owner"))
	testing.expect_value(t, count, 1)

	// The vault commit fails: the wiring rolls back with the receipt.
	rolled_back, removed, rb_err := rollback_pending_enrollment(&f.svc, new_id, enrolled.family_id, &enrolled.sunset)
	testing.expect_value(t, rb_err.code, domain.Error_Code.None)
	testing.expect(t, rolled_back, "pending enrollment rolled back")
	testing.expect(t, removed, "replacement row deleted")
	new_found, _ := bridge_state(f, new_id)
	testing.expect(t, !new_found, "replacement gone")
	restored_found, restored_status := bridge_state(f, old)
	testing.expect(t, restored_found, "old bridge still exists")
	testing.expect_value(t, restored_status, domain.Bridge_Status.Offline)
	testing.expect_value(t, live_family_tokens(f, old_family), 2)
	testing.expect_value(t, live_family_tokens(f, enrolled.family_id), 0)
	count_after, _ := iface.bridge_count_active_by_owner(&f.repo, domain.User_ID("sf_owner"))
	testing.expect_value(t, count_after, 1)
}

@(test)
test_sunset_rollback_after_commit_keeps_the_sunset_final :: proc(t: ^testing.T) {
	f := sunset_fixture_open(t, "commit_then_rb", 1)
	defer sunset_fixture_close(f)
	old, old_family := enrol_live(t, f, "sc_owner")
	enrolled, ok, err := enroll_bridge_from_device_grant(&f.svc, sunset_input("sc_owner", true, sunset = old))
	defer iface.bridge_sunset_receipt_destroy(&enrolled.sunset)
	testing.expect(t, ok, err.message)
	if !ok do return
	new_id := strings.clone(enrolled.bridge.bridge_id, context.temp_allocator)
	committed, commit_ok, _ := commit_pending_enrollment(&f.svc, Pending_Commit_Input{bridge_id = new_id, family_id = enrolled.family_id})
	defer domain.bridge_destroy(&committed)
	testing.expect(t, commit_ok, "replacement committed")

	// A late rollback (the commit won the race) must not resurrect the old bridge.
	rolled_back, removed, rb_err := rollback_pending_enrollment(&f.svc, new_id, enrolled.family_id, &enrolled.sunset)
	testing.expect_value(t, rb_err.code, domain.Error_Code.None)
	testing.expect(t, !rolled_back, "committed enrollment is not rolled back")
	testing.expect(t, !removed, "committed replacement kept")
	_, old_status := bridge_state(f, old)
	testing.expect_value(t, old_status, domain.Bridge_Status.Revoked)
	testing.expect_value(t, live_family_tokens(f, old_family), 0)
	new_found, _ := bridge_state(f, new_id)
	testing.expect(t, new_found, "replacement kept")
}

@(test)
test_sunset_of_another_owners_bridge_is_refused_without_side_effects :: proc(t: ^testing.T) {
	f := sunset_fixture_open(t, "foreign", -1)
	defer sunset_fixture_close(f)
	victim, victim_family := enrol_live(t, f, "sv_victim")

	result, ok, err := enroll_bridge_from_device_grant(&f.svc, sunset_input("sv_attacker", true, sunset = victim))
	defer iface.bridge_sunset_receipt_destroy(&result.sunset)
	testing.expect(t, !ok, "foreign sunset refused")
	testing.expect_value(t, err.code, domain.Error_Code.Not_Found)
	_, victim_status := bridge_state(f, victim)
	testing.expect(t, victim_status != .Revoked, "victim not revoked")
	testing.expect_value(t, live_family_tokens(f, victim_family), 2)
	testing.expect(t, !was_closed(f, victim), "victim socket untouched")
	count, _ := iface.bridge_count_active_by_owner(&f.repo, domain.User_ID("sv_attacker"))
	testing.expect_value(t, count, 0)
}
