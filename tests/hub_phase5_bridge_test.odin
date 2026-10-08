// Service-level bridge ownership, scoping, labelling and revocation.
//
// ===== WHY THIS FILE WAS REWRITTEN RATHER THAN DELETED (REQ-ENROLL-9) =====
//
// It used to drive the deleted one-time-token flow: `create_enrollment` for an
// `hbe_` secret, `enroll_bridge` to exchange it, plus assertions that the token was
// single-use and that an expired one was refused. All of that is gone with the flow.
//
// It was ALSO already failing at pristine HEAD, before this chain started, with
// "enrollment token is invalid" — the credential rework (REQ-IMPL-1) changed the
// stored hash format underneath it and this binary was never updated. So deleting
// it would have cost nothing measurable, which is precisely why deleting it would
// have been the wrong call: everything it asserts BESIDES enrollment is real,
// unasserted-anywhere-else behaviour that was silently uncovered the whole time.
//
// WHAT IS KEPT, and it is the majority of the file's value:
//   - a bridge belongs to the approving user, and only that user can list or read it
//   - a cross-user read is a 404-shaped miss, not a 403 (it must not confirm the id)
//   - the default label follows the hostname and is NOT marked user-customized
//   - renaming marks it customized, and a later hostname refresh must NOT clobber it
//   - revoking flips the row AND kills the credential
//
// WHAT CHANGED STRUCTURALLY. It used a hand-rolled fake repository. That is no longer
// viable: the device flow mints an EXPIRING PAIR through `bridge_tokens`, so a fake
// would have to implement the whole token repo surface to get a usable credential. A
// real sqlite database in a temp file is both less code and a far better test — the
// credential, its hashing and its lookup are the production ones.
package hub_phase5_bridge_test

import "core:fmt"
import "core:os"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import bridge_service "odin_test:hub/service/bridge"

// A valid-shaped uncompressed P-256 point. The SHAPE is all the Hub checks; only
// the approving human's comparison gives a key meaning.
TEST_PUBLIC_KEY :: "040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40"

main :: proc() {
	db_path := "/tmp/heimdall-hub-phase5-bridge-test.db"
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)

	conn, open_ok, _ := sqlite.open(db_path)
	check(open_ok, "sqlite open")
	defer sqlite.close(&conn)
	mig_ok, mig_err := sqlite.run_migrations(&conn)
	check(mig_ok && mig_err.code == .None, mig_err.message)

	repo_impl: sqlite.Bridge_Repo_SQLite
	repo := sqlite.new_bridge_repository(&repo_impl, &conn)
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	service := bridge_service.new_bridge_service(&repo, &clock, &ids)

	auth_a := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = "alice"}
	auth_b := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = "bob"}

	// Enrollment is browser-approved. `owner_user_id` is the APPROVING USER, which is
	// what makes ownership below meaningful: it comes from the approver's
	// Auth_Context, never from anything the host asserted.
	enrolled, enroll_ok, enroll_err := bridge_service.enroll_bridge_from_device_grant(&service, bridge_service.Device_Enroll_Input{
		owner_user_id          = "alice",
		bridge_public_key      = TEST_PUBLIC_KEY,
		bridge_key_fingerprint = "aaaa bbbb cccc dddd",
		os_user                = "tanmay",
		machine_hostname       = "host-a",
		machine_os             = "darwin",
	})
	check(enroll_ok, enroll_err.message)
	check(enrolled.bridge.owner_user_id == domain.User_ID("alice"), "bridge must belong to the approving user")
	check(enrolled.bridge.label == "host-a" && !enrolled.bridge.label_is_user_customized, "default label must follow the hostname and not be marked user-customized")

	// The credential is an EXPIRING PAIR now, not a single non-expiring token. This
	// is asserted because the deleted path returned an empty refresh token, so every
	// consumer treated it as optional; on this path it is always present.
	check(enrolled.bridge_token != "", "enrollment must return an access token")
	check(enrolled.refresh_token != "", "enrollment must return a refresh token")
	check(enrolled.expires_in > 0 && enrolled.refresh_expires_in > enrolled.expires_in, "the access token must expire sooner than its refresh token")

	// ===== OWNERSHIP AND SCOPING =====
	list_a, list_a_err := bridge_service.list_bridges(&service, auth_a)
	check(list_a_err.code == .None && len(list_a) == 1, "the owner must list their own bridge")
	list_b, list_b_err := bridge_service.list_bridges(&service, auth_b)
	check(list_b_err.code == .None && len(list_b) == 0, "another user must not list someone else's bridge")
	_, b_get_ok, b_get_err := bridge_service.get_bridge(&service, auth_b, enrolled.bridge.bridge_id)
	// NOT_FOUND rather than FORBIDDEN on purpose: a Forbidden would confirm that this
	// bridge id exists, which hands an enumerating attacker the thing the id was
	// hiding. The miss and the refusal must be indistinguishable.
	check(!b_get_ok && b_get_err.code == .Not_Found, "a cross-user bridge read must be hidden as Not_Found, not refused as Forbidden")

	// ===== THE CREDENTIAL AUTHENTICATES, AND SAYS WHO =====
	ctx, token_ok, token_err := bridge_service.verify_bridge_token(&service, enrolled.bridge_token)
	check(token_ok, token_err.message)
	check(ctx.kind == .Bridge_Token && ctx.user_id == "alice" && ctx.bridge_id == enrolled.bridge.bridge_id, "the credential must resolve to its own bridge and owner")

	// ===== LABELLING: a human rename must survive a hostname change =====
	renamed, rename_ok, rename_err := bridge_service.rename_bridge(&service, auth_a, enrolled.bridge.bridge_id, "custom")
	check(rename_ok, rename_err.message)
	check(renamed.label_is_user_customized && renamed.label == "custom", "renaming must set the label and mark it user-customized")
	refreshed := bridge_service.refresh_hostname(&service, renamed, "new-host")
	check(refreshed.label == "custom", "a user-customized label must NOT be overwritten when the hostname changes")
	plain := bridge_service.refresh_hostname(&service, enrolled.bridge, "new-host")
	check(plain.label == "new-host", "a label that was never customized should follow the hostname")

	// ===== REVOCATION KILLS THE CREDENTIAL, NOT JUST THE ROW =====
	// Asserting only the status flip would pass even if the token kept working,
	// which is the failure mode that matters.
	revoked, revoke_ok, revoke_err := bridge_service.revoke_bridge(&service, auth_a, enrolled.bridge.bridge_id)
	check(revoke_ok, revoke_err.message)
	check(revoked.status == .Revoked, "revoke must flip the bridge row to Revoked")
	_, post_ok, _ := bridge_service.verify_bridge_token(&service, enrolled.bridge_token)
	check(!post_ok, "a revoked bridge's access token must stop authenticating")

	// A non-owner must not be able to revoke someone else's bridge.
	other, other_ok, _ := bridge_service.enroll_bridge_from_device_grant(&service, bridge_service.Device_Enroll_Input{
		owner_user_id = "alice", bridge_public_key = TEST_PUBLIC_KEY, machine_hostname = "host-b",
	})
	check(other_ok, "second bridge enrolled")
	_, bob_revoke_ok, _ := bridge_service.revoke_bridge(&service, auth_b, other.bridge.bridge_id)
	check(!bob_revoke_ok, "a non-owner must not be able to revoke another user's bridge")
	_, still_ok, _ := bridge_service.verify_bridge_token(&service, other.bridge_token)
	check(still_ok, "a refused revocation must leave the credential working")

	fmt.println("PASS: hub phase5 bridge")
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln(message); os.exit(1) }
