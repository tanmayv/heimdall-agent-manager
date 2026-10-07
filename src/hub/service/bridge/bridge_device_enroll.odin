// Bridge enrollment via the device-authorization grant (REQ-IMPL-2).
//
// This is the mint side of the browser-approval flow. The Hub's existing RFC
// 8628 device grant (src/hub/service/device_auth/) now accepts a bridge public
// key at /device/authorize; when a signed-in human approves that grant, this
// proc creates the machine's identity.
//
// WHAT MAKES THIS DIFFERENT FROM THE PRE-EXISTING DEVICE MINTER, and why the
// difference is the whole point: the Electron path mints a USER API token whose
// only identity is owner_user_id, with the machine carried as a free-text label
// (src/hub/app/wiring.odin device_minter -> issue_device_authorization_token).
// Two bridges owned by one user therefore hold tokens that are
// indistinguishable in authority, and nothing stops one from acting for the
// other. A credential minted here resolves to exactly one `brg_` through
// verify_bridge_token (bridge_service.odin), and resolve_bridge_instance_auth
// then rejects any attempt to act for an instance that bridge does not own
// (src/hub/service/auth/auth_service.odin "bridge cannot act for an instance it
// does not own"). That per-machine scoping is what the user approved, so it is
// what the credential must carry.
//
// THERE IS NO ENROLLMENT TOKEN HERE. enroll_bridge() consumes a pre-shared
// `hbe_` secret a human had to carry to the machine; this path replaces that
// secret with a human's approval in a browser, so there is nothing to carry and
// nothing to leak in transit. The one-time `hbe_` flow is deleted by REQ-IMPL-6.
//
// Lives in its own file rather than in bridge_service.odin so REQ-IMPL-1 could
// replace the credential machinery underneath it without a merge conflict. That
// has now landed: the old unsalted `hash_token` placeholder is DELETED, and this
// proc mints through `issue_credential` (bridge_credential.odin) — a 256-bit
// CSPRNG secret, stored as `sha256:v1:<salt_hex>:<digest_hex>`. Nothing on this
// path may derive a secret from `platform.generate_id`, which is
// prefix + unix-nanoseconds and therefore enumerable from the enrollment time;
// `generate_id` is used here ONLY for the non-secret `brg_` id.

package bridge

import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// Device_Enroll_Input is the approved grant's content, as forwarded by the
// device_auth service's bridge minter.
//
// owner_user_id MUST come from the approving user's Auth_Context. The device
// grant binds it there (device_auth.approve takes it as an argument and never
// reads it from the request body) and this proc refuses an empty one, so an
// unauthenticated approval cannot produce an owned bridge.
Device_Enroll_Input :: struct {
	owner_user_id:          string,
	bridge_public_key:      string, // host-asserted, confirmed by the approving human
	bridge_key_fingerprint: string, // hub-computed from the key above
	os_user:                string, // host-asserted
	machine_hostname:       string,
	machine_os:             string,
	bridge_version:         string,
}

// enroll_bridge_from_device_grant mints the per-machine identity + credential
// for an approved bridge-enrollment grant. Returns the saved bridge and the
// PLAINTEXT token, which the caller hands to the bridge exactly once (the grant
// is single-use). The Hub never stores that plaintext: `issue_credential` returns
// the salted digest to persist instead, and only the secret half of
// `hbr_<bridge_id>.<secret>` is hashed — the id half is the lookup key.
enroll_bridge_from_device_grant :: proc(service: ^Bridge_Service, input: Device_Enroll_Input) -> (Enroll_Bridge_Result, bool, domain.Domain_Error) {
	// Fail closed on a missing owner. Reaching here without one would mean the
	// approval path lost the Auth_Context binding, and an unowned bridge row is
	// worse than a failed enrollment: ownership is what every later
	// authorization check reads.
	owner := strings.trim_space(input.owner_user_id)
	if owner == "" {
		return Enroll_Bridge_Result{}, false, domain.domain_error(.Unauthenticated, "an approving user is required to enroll a bridge")
	}
	if input.bridge_public_key == "" {
		return Enroll_Bridge_Result{}, false, domain.domain_error(.Validation_Failed, "bridge_public_key is required")
	}
	hostname := strings.trim_space(input.machine_hostname)
	if hostname == "" do hostname = "unknown-host"
	now := platform.clock_now(service.clock)
	// ===== SEAM: REQ-IMPL-3 OWNS THE RE-SHAPE OF THE NEXT FOUR LINES =====
	// The credential minted here is NON-EXPIRING BY DESIGN IN THIS TASK. There is
	// deliberately no TTL, no rotation, no refresh token and no `bridge_token`
	// table: that is one design surface and it belongs to REQ-IMPL-3 in full,
	// rather than being half-built twice. REQ-IMPL-2's job is the identity (one
	// `brg_` per approved machine); REQ-IMPL-3 replaces the mint-and-store below
	// with the `hba_`/`hbf_` pair from design §7.2.
	//
	// Generation and storage are kept in this ONE proc on purpose, so the next
	// re-shape is one call site. REQ-IMPL-1's `issue_credential` has already
	// landed underneath this and replaced the old `hash_token` placeholder: the
	// token is now `hbr_<bridge_id>.<secret>` and only the secret is hashed, with
	// a per-credential salt.
	// The credential embeds the record it belongs to (`hbr_<bridge_id>.<secret>`,
	// REQ-IMPL-1's issue_credential), so the id has to exist before the token.
	bridge_id := platform.generate_id(service.ids, "brg_")
	bridge_token, token_hash, cred_ok := issue_credential(BRIDGE_TOKEN_PREFIX, bridge_id)
	// Fail closed when the OS entropy source is unavailable. Issuing a weaker
	// credential, or an empty one, would be worse than failing the enrollment —
	// an empty stored hash is the case verify_credential documents as
	// authorising nothing, and the operator can simply approve again.
	if !cred_ok {
		return Enroll_Bridge_Result{}, false, domain.domain_error(.Provider_Unavailable, "could not generate a bridge credential; try again")
	}
	bridge := domain.Bridge{
		bridge_id = bridge_id,
		owner_user_id = domain.User_ID(owner),
		// The label starts as the machine's own hostname and is NOT marked
		// user-customized: the operator never typed it, the host asserted it, and
		// a later rename is what sets that flag (see patch_bridge/rename_bridge).
		label = hostname,
		label_is_user_customized = false,
		machine_hostname = hostname,
		machine_os = input.machine_os,
		capabilities_json = device_enroll_capabilities_json(input),
		status = .Offline,
		bridge_token_hash = token_hash,
		version = input.bridge_version,
		created_at = now,
		updated_at = now,
		last_seen_at = now,
	}
	saved, ok, err := iface.bridge_save_bridge(service.repo, bridge)
	if !ok do return Enroll_Bridge_Result{}, false, err
	return Enroll_Bridge_Result{bridge = saved, bridge_token = bridge_token}, true, domain.Domain_Error{}
}

// device_enroll_capabilities_json records the approved key on the bridge row,
// which is design §11.4 step 4's "bind by record": the triple
// (brg_, bridge_public_key, token_hash) is written in one place, so a later
// reader can say which machine's key the approving human actually confirmed.
//
// `public_key` is the existing key name in capabilities_json — the Hub already
// falls back to it when the live runtime registry has no entry
// (src/hub/transport/http/bridge_handlers.odin:397, :2229), so
// GET /api/v1/bridges/<id>/public-key returns the APPROVED key from the moment
// of enrollment, before the bridge has ever connected. That precedence is the
// right way round and is deliberate: the registry value comes from the current
// bridge_hello, and the bridge's ECDH keypair is ephemeral — regenerated every
// process (src/bridge/unseal_protocol.odin) — so the live key wins for
// encryption while this one remains the record of what was approved.
//
// `enrollment_key_fingerprint` is the hub-computed fingerprint, kept alongside
// so an audit does not have to re-derive it, and `os_user` is retained as the
// host-asserted value the approver saw.
device_enroll_capabilities_json :: proc(input: Device_Enroll_Input) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"public_key\":\"")
	write_service_json_string(&b, input.bridge_public_key)
	strings.write_string(&b, "\",\"enrollment_public_key\":\"")
	write_service_json_string(&b, input.bridge_public_key)
	strings.write_string(&b, "\",\"enrollment_key_fingerprint\":\"")
	write_service_json_string(&b, input.bridge_key_fingerprint)
	strings.write_string(&b, "\",\"os_user\":\"")
	write_service_json_string(&b, input.os_user)
	strings.write_string(&b, "\",\"enrolled_via\":\"device_authorization\"}")
	return strings.to_string(b)
}
