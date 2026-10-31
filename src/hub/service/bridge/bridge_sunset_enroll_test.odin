// REQ-3: "register this machine as NEW and sunset one of mine" through the bridge
// service (enroll_bridge_from_device_grant with sunset_bridge_id), and EVERY way the
// pending replacement can roll back afterwards: the approval's vault-commit failure,
// the replacement's credential mint failing, cancel (operator / committed:false),
// both sweep sources -- each must give the sunset bridge back -- versus a commit,
// after which nothing may, and a revoke-all cancel, which must not. A real sqlite
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
	// lookup_fails makes the entitlement lookup error (a rollback must fail closed).
	lookup_fails: bool,
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
	f := (^Sunset_Fixture)(ctx)
	if f.lookup_fails do return {}, domain.domain_error(.Internal_Error, "billing unavailable")
	entitlements := domain.unlimited_entitlements()
	entitlements.max_bridges = f.limit
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

	_, ok, err := enroll_bridge_from_device_grant(&f.svc, sunset_input("sx_owner", true, sunset = other, target = target))
	testing.expect(t, !ok, "attach + sunset refused")
	testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)
	// Neither the attach (credential rotation) nor the sunset happened.
	testing.expect_value(t, live_family_tokens(f, target_family), 2)
	testing.expect_value(t, live_family_tokens(f, other_family), 2)
	_, other_status := bridge_state(f, other)
	testing.expect(t, other_status != .Revoked, "sunset bridge not revoked")
	testing.expect_value(t, len(f.closed), 0)
}

// sunset_replace enrolls a live bridge for owner on a full one-bridge plan, then
// approves a pending replacement that sunsets it. Returns the ids and families.
@(private = "file")
Sunset_Case :: struct {
	old_id, old_family, new_id, new_family: string,
}

@(private = "file")
sunset_replace :: proc(t: ^testing.T, f: ^Sunset_Fixture, owner: string) -> (c: Sunset_Case, ok: bool) {
	c.old_id, c.old_family = enrol_live(t, f, owner)
	enrolled, enroll_ok, err := enroll_bridge_from_device_grant(&f.svc, sunset_input(owner, true, sunset = c.old_id))
	testing.expect(t, enroll_ok, err.message)
	if !enroll_ok do return c, false
	c.new_id = strings.clone(enrolled.bridge.bridge_id, context.temp_allocator)
	c.new_family = strings.clone(enrolled.family_id, context.temp_allocator)
	_, old_status := bridge_state(f, c.old_id)
	testing.expect_value(t, old_status, domain.Bridge_Status.Revoked)
	testing.expect_value(t, live_family_tokens(f, c.old_family), 0)
	return c, true
}

// expect_restored: the replacement is gone, and the sunset bridge and exactly its
// credentials are live again, within the one-bridge plan.
@(private = "file")
expect_restored :: proc(t: ^testing.T, f: ^Sunset_Fixture, c: Sunset_Case, owner: string, loc := #caller_location) {
	new_found, _ := bridge_state(f, c.new_id)
	testing.expect(t, !new_found, "replacement deleted", loc = loc)
	found, status := bridge_state(f, c.old_id)
	testing.expect(t, found, "sunset bridge exists", loc = loc)
	testing.expect_value(t, status, domain.Bridge_Status.Offline, loc = loc)
	testing.expect_value(t, live_family_tokens(f, c.old_family), 2, loc = loc)
	testing.expect_value(t, live_family_tokens(f, c.new_family), 0, loc = loc)
	count, _ := iface.bridge_count_active_by_owner(&f.repo, domain.User_ID(owner))
	testing.expect_value(t, count, 1, loc = loc)
}

@(private = "file")
expect_still_sunset :: proc(t: ^testing.T, f: ^Sunset_Fixture, c: Sunset_Case, loc := #caller_location) {
	_, status := bridge_state(f, c.old_id)
	testing.expect_value(t, status, domain.Bridge_Status.Revoked, loc = loc)
	testing.expect_value(t, live_family_tokens(f, c.old_family), 0, loc = loc)
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
	testing.expect(t, ok, err.message)
	if !ok do return
	c := Sunset_Case{old_id = old, old_family = old_family, new_id = enrolled.bridge.bridge_id, new_family = enrolled.family_id}
	testing.expect_value(t, live_family_tokens(f, old_family), 0)
	testing.expect(t, was_closed(f, old), "the sunset bridge's socket is dropped")
	count, _ := iface.bridge_count_active_by_owner(&f.repo, domain.User_ID("sf_owner"))
	testing.expect_value(t, count, 1)

	// The vault commit fails: the wiring rolls back exactly the minted family. No
	// receipt is passed: it is durable.
	rolled_back, removed, rb_err := rollback_pending_enrollment(&f.svc, c.new_id, c.new_family)
	testing.expect_value(t, rb_err.code, domain.Error_Code.None)
	testing.expect(t, rolled_back, "pending enrollment rolled back")
	testing.expect(t, removed, "replacement row deleted")
	new_found, _ := bridge_state(f, c.new_id)
	testing.expect(t, !new_found, "replacement gone")
	expect_restored(t, f, c, "sf_owner")
}

@(test)
test_sunset_is_restored_when_the_sweep_expires_the_enrollment :: proc(t: ^testing.T) {
	f := sunset_fixture_open(t, "sweep_family", 1)
	defer sunset_fixture_close(f)
	c, ok := sunset_replace(t, f, "sw_owner")
	if !ok do return
	// The new machine never received its vault key: the enroll family ages out.
	testing.expect(t, sqlite.exec(&f.conn, fmt.tprintf("UPDATE bridge_tokens SET issued_at = '2000-01-01T00:00:00Z' WHERE family_id = '%s';", c.new_family)), "family aged")
	rolled := sweep_expired_enrollments(&f.svc)
	defer rolled_back_enrollments_destroy(rolled)
	testing.expect_value(t, len(rolled), 1)
	expect_restored(t, f, c, "sw_owner")
}

@(test)
test_sunset_is_restored_when_the_sweep_removes_an_expired_row_without_credential :: proc(t: ^testing.T) {
	f := sunset_fixture_open(t, "sweep_row", 1)
	defer sunset_fixture_close(f)
	c, ok := sunset_replace(t, f, "sr_owner")
	if !ok do return
	// The sweep's second source: a pending row past its deadline whose credential is
	// already gone (rolled back with no family to judge by).
	testing.expect(t, sqlite.exec(&f.conn, fmt.tprintf("UPDATE bridge_tokens SET revoked_at = '2000-01-01T00:00:00Z' WHERE family_id = '%s'; UPDATE bridges SET enrollment_pending_until = '2000-01-01T00:00:00Z' WHERE bridge_id = '%s';", c.new_family, c.new_id)), "row aged")
	rolled := sweep_expired_enrollments(&f.svc)
	defer rolled_back_enrollments_destroy(rolled)
	testing.expect_value(t, len(rolled), 1)
	expect_restored(t, f, c, "sr_owner")
}

@(test)
test_sunset_is_restored_when_the_enrollment_is_cancelled :: proc(t: ^testing.T) {
	f := sunset_fixture_open(t, "cancel", 1)
	defer sunset_fixture_close(f)
	c, ok := sunset_replace(t, f, "sk_owner")
	if !ok do return
	// The operator's cancel; the bridge's committed:false reaches the same rollback.
	rolled_back, removed, err := cancel_pending_enrollment(&f.svc, c.new_id)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect(t, rolled_back && removed, "cancel rolled the replacement back")
	expect_restored(t, f, c, "sk_owner")
}

@(test)
test_sunset_stays_revoked_when_a_revoke_all_cancels_the_replacement :: proc(t: ^testing.T) {
	f := sunset_fixture_open(t, "keep_revoked", 1)
	defer sunset_fixture_close(f)
	c, ok := sunset_replace(t, f, "sk2_owner")
	if !ok do return
	rolled_back, removed, err := cancel_pending_enrollment(&f.svc, c.new_id, .Keep_Revoked)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect(t, rolled_back && removed, "replacement rolled back")
	expect_still_sunset(t, f, c)
	// And the receipt was consumed: a later sweep cannot revive it either.
	rolled := sweep_expired_enrollments(&f.svc)
	defer rolled_back_enrollments_destroy(rolled)
	expect_still_sunset(t, f, c)
}

@(test)
test_sunset_rollback_after_commit_keeps_the_sunset_final :: proc(t: ^testing.T) {
	f := sunset_fixture_open(t, "commit_then_rb", 1)
	defer sunset_fixture_close(f)
	c, ok := sunset_replace(t, f, "sc_owner")
	if !ok do return
	committed, commit_ok, _ := commit_pending_enrollment(&f.svc, Pending_Commit_Input{bridge_id = c.new_id, family_id = c.new_family})
	defer domain.bridge_destroy(&committed)
	testing.expect(t, commit_ok, "replacement committed")

	// A late rollback (the commit won the race) must not resurrect the old bridge...
	rolled_back, removed, rb_err := rollback_pending_enrollment(&f.svc, c.new_id, c.new_family)
	testing.expect_value(t, rb_err.code, domain.Error_Code.None)
	testing.expect(t, !rolled_back, "committed enrollment is not rolled back")
	testing.expect(t, !removed, "committed replacement kept")
	// ...and neither may a late sweep, even with the family's issue time long past.
	testing.expect(t, sqlite.exec(&f.conn, fmt.tprintf("UPDATE bridge_tokens SET issued_at = '2000-01-01T00:00:00Z' WHERE family_id = '%s';", c.new_family)), "family aged")
	rolled := sweep_expired_enrollments(&f.svc)
	defer rolled_back_enrollments_destroy(rolled)
	testing.expect_value(t, len(rolled), 0)
	expect_still_sunset(t, f, c)
	new_found, _ := bridge_state(f, c.new_id)
	testing.expect(t, new_found, "replacement kept")
}

@(test)
test_sunset_is_restored_when_the_replacement_credential_cannot_be_minted :: proc(t: ^testing.T) {
	f := sunset_fixture_open(t, "pair_fail", 1)
	defer sunset_fixture_close(f)
	old, old_family := enrol_live(t, f, "sp_owner")
	// issue_bridge_token_pair fails AFTER the admission transaction committed the
	// sunset and the pending row: its first token INSERT is refused.
	testing.expect(t, sqlite.exec(&f.conn, "CREATE TRIGGER sunset_fail_pair BEFORE INSERT ON bridge_tokens WHEN NEW.scope = 'bridge:enroll' BEGIN SELECT RAISE(ABORT, 'mint refused'); END;"), "trigger installed")
	_, ok, err := enroll_bridge_from_device_grant(&f.svc, sunset_input("sp_owner", true, sunset = old))
	testing.expect(t, !ok, "approval fails")
	testing.expect(t, err.code != .None, "error reported")
	bridges, _ := iface.bridge_list_by_owner(&f.repo, domain.User_ID("sp_owner"))
	defer {
		for &b in bridges do domain.bridge_destroy(&b)
		delete(bridges)
	}
	// Only the old bridge is left, live again with its own credentials.
	testing.expect_value(t, len(bridges), 1)
	found, status := bridge_state(f, old)
	testing.expect(t, found, "old bridge exists")
	testing.expect_value(t, status, domain.Bridge_Status.Offline)
	testing.expect_value(t, live_family_tokens(f, old_family), 2)
}

@(test)
test_sunset_fails_closed_when_the_plan_cannot_be_read_at_rollback :: proc(t: ^testing.T) {
	f := sunset_fixture_open(t, "plan_unreadable", 1)
	defer sunset_fixture_close(f)
	c, ok := sunset_replace(t, f, "su_owner")
	if !ok do return
	f.lookup_fails = true
	rolled_back, removed, err := rollback_pending_enrollment(&f.svc, c.new_id, c.new_family)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect(t, rolled_back && removed, "the replacement is still rolled back")
	new_found, _ := bridge_state(f, c.new_id)
	testing.expect(t, !new_found, "replacement deleted, not left for the sweep")
	// Restoring without knowing the plan could exceed it: left revoked.
	expect_still_sunset(t, f, c)
}

@(test)
test_sunset_of_another_owners_bridge_is_refused_without_side_effects :: proc(t: ^testing.T) {
	f := sunset_fixture_open(t, "foreign", -1)
	defer sunset_fixture_close(f)
	victim, victim_family := enrol_live(t, f, "sv_victim")

	_, ok, err := enroll_bridge_from_device_grant(&f.svc, sunset_input("sv_attacker", true, sunset = victim))
	testing.expect(t, !ok, "foreign sunset refused")
	testing.expect_value(t, err.code, domain.Error_Code.Not_Found)
	_, victim_status := bridge_state(f, victim)
	testing.expect(t, victim_status != .Revoked, "victim not revoked")
	testing.expect_value(t, live_family_tokens(f, victim_family), 2)
	testing.expect(t, !was_closed(f, victim), "victim socket untouched")
	count, _ := iface.bridge_count_active_by_owner(&f.repo, domain.User_ID("sv_attacker"))
	testing.expect_value(t, count, 0)
}
