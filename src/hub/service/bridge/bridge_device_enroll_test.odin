// Tests for the "attach to an existing bridge" device-enrolment path
// (rotate_bridge_for_device_grant), as opposed to the default "mint a new
// bridge" path (enroll_bridge_from_device_grant's existing body, covered by
// bridge_token_service_test.odin's enrol_one-based tests).
//
// Mirrors bridge_token_service_test.odin's fixture shape on purpose: a real
// sqlite repository (ownership and the token-revoke write are real SQL, not
// re-implemented by a fake), a fake connection-closer that records intent
// (the REAL socket teardown is proven on a real socket in
// src/hub/transport/http/bridge_revocation_ws_test.odin -- same split that
// file documents, for the same reason).
package bridge

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"

@(private = "file")
attach_test_counter: int = 0

@(private = "file")
Attach_Fixture :: struct {
	db_path:           string,
	conn:              sqlite.Conn,
	impl:              sqlite.Bridge_Repo_SQLite,
	repo:              iface.Bridge_Repository,
	clock:             platform.Clock,
	ids:               platform.ID_Generator,
	svc:               Bridge_Service,
	closed_bridge_ids: [dynamic]string,
}

@(private = "file")
attach_fixture_closer :: proc(ctx: rawptr, bridge_id: string) -> bool {
	f := (^Attach_Fixture)(ctx)
	append(&f.closed_bridge_ids, strings.clone(bridge_id))
	return true
}

@(private = "file")
setup_attach_fixture :: proc(t: ^testing.T, tag: string) -> ^Attach_Fixture {
	f := new(Attach_Fixture)
	seq := sync.atomic_add(&attach_test_counter, 1)
	f.db_path = fmt.tprintf("/tmp/test_bridge_attach_%s_%d_%d_%d.db", tag, os.get_pid(), time.now()._nsec, seq)
	os.remove(f.db_path)
	conn, open_ok, _ := sqlite.open(f.db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	f.conn = conn
	mig_ok, mig_err := sqlite.run_migrations(&f.conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)
	f.repo = sqlite.new_bridge_repository(&f.impl, &f.conn)
	f.clock = platform.real_clock()
	f.ids = platform.real_id_generator()
	f.svc = new_bridge_service(&f.repo, &f.clock, &f.ids)
	f.closed_bridge_ids = make([dynamic]string)
	with_connection_closer(&f.svc, Bridge_Connection_Closer{ctx = rawptr(f), close_bridge_connection = attach_fixture_closer})
	return f
}

@(private = "file")
teardown_attach_fixture :: proc(f: ^Attach_Fixture) {
	if f == nil do return
	sqlite.close(&f.conn)
	os.remove(f.db_path)
	for s in f.closed_bridge_ids do delete(s)
	delete(f.closed_bridge_ids)
	free(f)
}

@(private = "file")
attach_enrol :: proc(t: ^testing.T, f: ^Attach_Fixture, owner, hostname: string) -> Enroll_Bridge_Result {
	result, ok, err := enroll_bridge_from_device_grant(&f.svc, Device_Enroll_Input{
		owner_user_id = owner,
		bridge_public_key = "04aabbccdd",
		bridge_key_fingerprint = "aaaa bbbb cccc dddd",
		os_user = "tanmay",
		machine_hostname = hostname,
		machine_os = "linux",
	})
	testing.expect(t, ok, err.message)
	return result
}

// THE CORE PROPERTY: approving with target_bridge_id set revokes the old
// credential family, keeps the row ALIVE under the SAME bridge_id (not
// .Revoked -- that is rotate's whole distinction from revoke_bridge), and the
// new device's credential authenticates as that same bridge going forward.
@(test)
test_rotate_for_device_grant_reuses_bridge_id_and_revokes_old_credential :: proc(t: ^testing.T) {
	f := setup_attach_fixture(t, "reuse")
	defer teardown_attach_fixture(f)

	old := attach_enrol(t, f, "approving-human", "old-nix-managed-host")
	old_bridge_id := strings.clone(old.bridge.bridge_id); defer delete(old_bridge_id)
	old_token := strings.clone(old.bridge_token); defer delete(old_token)

	_, pre_ok, _ := verify_bridge_token(&f.svc, old_token)
	testing.expect(t, pre_ok, "the old credential authenticates before the attach")

	attached, ok, err := enroll_bridge_from_device_grant(&f.svc, Device_Enroll_Input{
		owner_user_id = "approving-human",
		bridge_public_key = "04eeff0011",
		bridge_key_fingerprint = "eeee ffff 0000 1111",
		os_user = "tanmay",
		machine_hostname = "new-install-sh-host",
		machine_os = "linux",
		target_bridge_id = old_bridge_id,
	})
	testing.expect(t, ok, err.message)

	testing.expect_value(t, attached.bridge.bridge_id, old_bridge_id)
	testing.expect_value(t, attached.bridge.machine_hostname, "new-install-sh-host")
	testing.expect(t, attached.bridge.status != .Revoked, "attaching must not revoke the bridge -- that is the entire point versus revoke+re-enroll")

	// The old credential is dead...
	_, post_ok, post_err := verify_bridge_token(&f.svc, old_token)
	testing.expect(t, !post_ok, "the old credential no longer authenticates after the attach")
	testing.expect(t, post_err.code == .Forbidden, "a revoked credential is rejected as forbidden, not merely invalid")

	// ...and the NEW one resolves to the SAME bridge_id.
	new_auth, new_ok, new_err := verify_bridge_token(&f.svc, attached.bridge_token)
	testing.expect(t, new_ok, new_err.message)
	testing.expect_value(t, new_auth.bridge_id, old_bridge_id)

	// The live connection was asked to close.
	closed := false
	for id in f.closed_bridge_ids do if id == old_bridge_id do closed = true
	testing.expect(t, closed, "the target bridge's live connection was asked to close")
}

// ANTI-ENUMERATION: a target_bridge_id the approving user does not own must be
// rejected exactly like get_bridge/revoke_bridge reject one -- .Not_Found, not
// .Forbidden -- and must touch NOTHING: no revoked tokens, no closed socket,
// no row mutation. A target_bridge_id is attacker-controlled input (it rides
// in the approve POST body), so this is the one check standing between "pick
// your own stale bridge to attach to" and "take over anyone's bridge by
// guessing or enumerating its id".
@(test)
test_rotate_for_device_grant_rejects_unowned_target :: proc(t: ^testing.T) {
	f := setup_attach_fixture(t, "unowned")
	defer teardown_attach_fixture(f)

	alices := attach_enrol(t, f, "alice", "alices-host")
	alices_bridge_id := strings.clone(alices.bridge.bridge_id); defer delete(alices_bridge_id)
	alices_token := strings.clone(alices.bridge_token); defer delete(alices_token)

	_, ok, err := enroll_bridge_from_device_grant(&f.svc, Device_Enroll_Input{
		owner_user_id = "bob", // NOT the owner of alices_bridge_id
		bridge_public_key = "04112233",
		bridge_key_fingerprint = "1111 2222 3333 4444",
		os_user = "bob",
		machine_hostname = "bobs-host",
		machine_os = "linux",
		target_bridge_id = alices_bridge_id,
	})
	testing.expect(t, !ok, "attaching to a bridge the approver does not own must be refused")
	testing.expect(t, err.code == .Not_Found, "refused as not-found, the same anti-enumeration shape get_bridge/revoke_bridge use -- never .Forbidden, which would confirm the id exists")

	// Nothing touched: Alice's credential still works, and the closer was
	// never invoked.
	_, still_ok, still_err := verify_bridge_token(&f.svc, alices_token)
	testing.expect(t, still_ok, still_err.message)
	testing.expect_value(t, len(f.closed_bridge_ids), 0)
}

// A REVOKED bridge is an administrative end, not a parking lot to resurrect
// from. The approval page's <select> excludes revoked bridges, but that is
// client-side convenience -- target_bridge_id rides in a plain JSON body, so
// this asserts the SERVER refuses a revoked target even when nothing client-
// side stopped the request from naming one. Refused with the same
// anti-enumeration shape as an unowned target (.Not_Found), and the revoked
// row must stay exactly as revoke_bridge left it: still .Revoked, no new
// credential issued, connection-closer not invoked a second time.
@(test)
test_rotate_for_device_grant_rejects_revoked_target :: proc(t: ^testing.T) {
	f := setup_attach_fixture(t, "revoked")
	defer teardown_attach_fixture(f)

	owned := attach_enrol(t, f, "approving-human", "already-revoked-host")
	owned_bridge_id := strings.clone(owned.bridge.bridge_id); defer delete(owned_bridge_id)

	owner_auth := contracts.Auth_Context{kind = .User_Token, user_id = "approving-human"}
	revoked, revoke_ok, revoke_err := revoke_bridge(&f.svc, owner_auth, owned_bridge_id)
	testing.expect(t, revoke_ok, revoke_err.message)
	testing.expect_value(t, revoked.status, domain.Bridge_Status.Revoked)
	clear(&f.closed_bridge_ids) // revoke_bridge itself closes the connection; isolate what happens next

	_, ok, err := enroll_bridge_from_device_grant(&f.svc, Device_Enroll_Input{
		owner_user_id = "approving-human", // the OWNER, not an impersonator -- status alone must still refuse this
		bridge_public_key = "04998877",
		bridge_key_fingerprint = "9999 8888 7777 6666",
		os_user = "tanmay",
		machine_hostname = "resurrecting-host",
		machine_os = "linux",
		target_bridge_id = owned_bridge_id,
	})
	testing.expect(t, !ok, "attaching to the approver's OWN revoked bridge must still be refused")
	testing.expect(t, err.code == .Not_Found, "refused as not-found, the same anti-enumeration shape as an unowned target")
	testing.expect_value(t, len(f.closed_bridge_ids), 0)

	still_revoked, get_ok, get_err := get_bridge(&f.svc, owner_auth, owned_bridge_id)
	testing.expect(t, get_ok, get_err.message)
	testing.expect_value(t, still_revoked.status, domain.Bridge_Status.Revoked)
}

// REGRESSION GUARD: omitting target_bridge_id is byte-for-byte today's
// existing behaviour -- every enrolment, with or without this feature's code
// present, mints its own distinct bridge.
@(test)
test_enroll_without_target_bridge_id_mints_distinct_bridges :: proc(t: ^testing.T) {
	f := setup_attach_fixture(t, "distinct")
	defer teardown_attach_fixture(f)

	a := attach_enrol(t, f, "approving-human", "host-a")
	b := attach_enrol(t, f, "approving-human", "host-b")
	testing.expect(t, a.bridge.bridge_id != b.bridge.bridge_id, "two enrolments with no target_bridge_id are two distinct bridges")
	testing.expect_value(t, a.bridge.status, domain.Bridge_Status.Offline)
	testing.expect_value(t, b.bridge.status, domain.Bridge_Status.Offline)
}

@(test)
test_new_device_enrollment_uses_operator_bridge_label :: proc(t: ^testing.T) {
	f := setup_attach_fixture(t, "custom-label")
	defer teardown_attach_fixture(f)

	result, ok, err := enroll_bridge_from_device_grant(&f.svc, Device_Enroll_Input{
		owner_user_id = "approving-human",
		bridge_public_key = "04112233",
		bridge_key_fingerprint = "1111 2222 3333 4444",
		os_user = "tanmay",
		machine_hostname = "dawnstar",
		machine_os = "linux",
		new_bridge_label = "dawnstar-2",
	})
	testing.expect(t, ok, err.message)
	testing.expect_value(t, result.bridge.label, "dawnstar-2")
	testing.expect(t, result.bridge.label_is_user_customized, "operator-entered enrollment label must survive runtime hostname updates")
	testing.expect_value(t, result.bridge.machine_hostname, "dawnstar")
}
