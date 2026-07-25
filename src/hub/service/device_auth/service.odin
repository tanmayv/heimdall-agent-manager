// Device-authorization service (ELDA-1 / ELDA-6 orchestration).
//
// Device_Auth_Service wires the grant store, trusted-XFF IP resolver, and the
// per-IP authorize rate limit together behind a testable API. The HTTP layer
// (transport/http/device_auth_handlers.odin) is a thin adapter over this.
//
// authorize() is the only public entry point in task 1:
//   1. validate input (client is required),
//   2. resolve the real client IP (trusted-XFF when behind a trusted proxy),
//   3. enforce the per-IP rate limit BEFORE touching the store's grant map,
//   4. mint a grant with unlinkable device_code + user_code, capture request_ip,
//   5. return the device-poll contract {device_code, user_code, verification_uri,
//      interval, expires_in}.
//
// Failures map to domain errors: Rate_Limited (429), Validation_Failed (400),
// Provider_Unavailable (503) when the OS CSPRNG is unavailable.

package device_auth

import "core:sync"
import domain "odin_test:hub/domain"

// Device_Auth_Service is the orchestrator. All fields are read-only after
// construction except `store`, which carries its own mutex.
Device_Auth_Service :: struct {
	store:           ^Grant_Store,
	clock:           Monotonic_Clock,
	trusted_cidrs:   []string,
	// minter pre-mints a token on approve (task 3 owns the real issuer; task 2
	// defines the boundary and stores the plaintext on the grant for the first
	// poll). May be nil — approve then leaves minted_token empty and task 3's
	// poll path mints lazily.
	minter:          Token_Minter,
}

// Token_Minter issues a long-lived token for the bound owner the moment a
// grant is approved. Task 3 provides the real implementation (user/bridge
// token issuance); tests inject a fake. Returns (token, true) on success.
Token_Minter :: proc(user_id, client, device_label: string) -> (string, bool)

new_device_auth_service :: proc(store: ^Grant_Store, clock: Monotonic_Clock, trusted_cidrs: []string) -> Device_Auth_Service {
	return Device_Auth_Service{store = store, clock = clock, trusted_cidrs = trusted_cidrs}
}

// with_token_minter attaches the task-3 token issuer so approve can pre-mint.
// Called by app wiring once task 3 ships the real minter; tests inject a fake.
with_token_minter :: proc(service: ^Device_Auth_Service, minter: Token_Minter) {
	service.minter = minter
}

// authorize creates a device grant for the given input + request provenance.
// `remote_addr` is the TCP peer; `xff_header` is the raw X-Forwarded-For value.
// Returns (result, true, {}) on success or (_, false, err) on failure.
authorize :: proc(service: ^Device_Auth_Service, input: Authorize_Input, remote_addr, xff_header: string) -> (Authorize_Result, bool, domain.Domain_Error) {
	// Validate input: client is required (identifies the calling app).
	if input.client == "" {
		return Authorize_Result{}, false, domain.domain_error(.Validation_Failed, "client is required")
	}
	// Resolve the effective client IP (trusted-XFF only behind a trusted proxy).
	request_ip := resolve_client_ip(remote_addr, xff_header, service.trusted_cidrs)
	// Rate limit BEFORE grant creation to avoid store-filling DoS (ELDA-1).
	now := service.clock.now()
	sync.mutex_lock(&service.store.mutex)
	allowed := allow_authorize(service.store, request_ip, now)
	sync.mutex_unlock(&service.store.mutex)
	if !allowed {
		return Authorize_Result{}, false, domain.domain_error(.Rate_Limited, "too many device authorize requests from this IP")
	}
	// Mint the grant (independent CSPRNG draws => unlinkable codes).
	result, ok := create_grant(service.store, input, request_ip, service.clock)
	if !ok {
		return Authorize_Result{}, false, domain.domain_error(.Provider_Unavailable, "could not generate secure codes; try again")
	}
	return result, true, domain.Domain_Error{}
}

// Device_Info is the subset of a grant shown on the browser verify page. It
// deliberately EXCLUDES secrets (device_code, user_code, minted_token) and the
// owner/approver fields (not yet bound at verify time).
Device_Info :: struct {
	device_label: string,
	os:           string,
	app_version:  string,
	client:       string,
	request_ip:   string,
	requested_at: i64,
}

// GENERIC_UNKNOWN_CODE_ERROR is the single error returned for an unknown,
// expired, OR otherwise-unverifiable code so callers cannot enumerate valid
// codes by distinguishing responses (ELDA-2). Terminal grants use a distinct
// 410/409 (AC5) since the acting user already knows the code was valid.
GENERIC_UNKNOWN_CODE_ERROR :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Not_Found, "invalid or expired code")
}

// verify resolves a grant by its short user_code and returns the device info
// captured at authorize time, for display on the browser confirm page.
//   - unknown code  -> Not_Found generic (no enumeration)
//   - expired code  -> Not_Found generic (no enumeration), grant evicted
//   - terminal code -> Gone (410) "code already used" (AC5)
//   - pending valid -> Device_Info (AC3)
// Caller MUST have already passed trusted-proxy auth (handler enforces it).
verify :: proc(service: ^Device_Auth_Service, user_code: string) -> (Device_Info, bool, domain.Domain_Error) {
	device_code, grant, ok := grant_by_user_code(service.store, user_code)
	if !ok do return Device_Info{}, false, GENERIC_UNKNOWN_CODE_ERROR()
	now := service.clock.now()
	if is_expired(grant, now) {
		// Evict quietly; report generic error (do not distinguish from unknown).
		sweep(service.store, now)
		return Device_Info{}, false, GENERIC_UNKNOWN_CODE_ERROR()
	}
	if grant.status != .Pending {
		// Terminal: the acting user already decided; reveal "already used" (AC5).
		return Device_Info{}, false, domain.domain_error(.Gone, "code already used")
	}
	_ = device_code
	return Device_Info{
		device_label = grant.device_label,
		os = grant.os,
		app_version = grant.app_version,
		client = grant.client,
		request_ip = grant.request_ip,
		requested_at = grant.requested_at,
	}, true, domain.Domain_Error{}
}

// Approve_Input is the approve request body. owner_user_id is INTENTIONALLY
// absent: the owner is bound from Auth_Context only (ELDA-6); any client-
// supplied owner field in the raw body is ignored by the handler.
Approve_Input :: struct {
	user_code: string,
	approve:   bool,
}

// approve records the user's terminal decision on a grant.
//   - owner_user_id is taken from Auth_Context ONLY (never the body) (ELDA-6/AC4)
//   - approver_ip via trusted-XFF, approver_ua from the request (ELDA-7/AC6)
//   - on approve, pre-mint the token via the task-3 minter and hold plaintext
//   - terminal grant -> Conflict (409) "code already used" (AC5)
//   - unknown/expired -> generic Not_Found (no enumeration)
approve :: proc(service: ^Device_Auth_Service, input: Approve_Input, owner_user_id, approver_ip, approver_ua: string) -> (bool, domain.Domain_Error) {
	if input.user_code == "" do return false, GENERIC_UNKNOWN_CODE_ERROR()
	_, grant, ok := grant_by_user_code(service.store, input.user_code)
	if !ok do return false, GENERIC_UNKNOWN_CODE_ERROR()
	now := service.clock.now()
	if is_expired(grant, now) {
		sweep(service.store, now)
		return false, GENERIC_UNKNOWN_CODE_ERROR()
	}
	if grant.status != .Pending {
		return false, domain.domain_error(.Conflict, "code already used")
	}
	// Bind owner from Auth_Context ONLY (ELDA-6). Ignore any body owner field.
	grant.owner_user_id = owner_user_id
	grant.approver_ip = approver_ip
	grant.approver_ua = approver_ua
	grant.decided_at = now
	if input.approve {
		grant.status = .Approved
		// Pre-mint the token so the first /device/token poll can return it (task 3).
		// If no minter is wired (task 3 not yet integrated), leave it empty; task 3's
		// poll path will mint lazily on the approved grant.
		if service.minter != nil {
			token, tok_ok := service.minter(owner_user_id, grant.client, grant.device_label)
			if tok_ok do grant.minted_token = token
		}
	} else {
		grant.status = .Denied
	}
	set_grant(service.store, grant.device_code, grant)
	return true, domain.Domain_Error{}
}
