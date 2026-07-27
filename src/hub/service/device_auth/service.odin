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

import "core:strings"
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
	minter_ctx:      rawptr,
}

// Token_Minter issues a long-lived token for the bound owner the moment a
// grant is approved. Task 3 provides the real implementation (user/bridge
// token issuance); tests inject a fake. Returns (plaintext, token_id, true) on success.
// `ctx` is opaque state the concrete minter casts back to its service graph.
Token_Minter :: proc(ctx: rawptr, user_id, client, device_label: string) -> (string, string, bool)

new_device_auth_service :: proc(store: ^Grant_Store, clock: Monotonic_Clock, trusted_cidrs: []string) -> Device_Auth_Service {
	// Own a stable copy of the trusted CIDR strings. Callers often pass config or
	// test-local slices; holding those slice headers directly can leave the
	// long-lived service pointing at stack/temporary memory after construction.
	owned_cidrs := make([]string, len(trusted_cidrs))
	for i in 0..<len(trusted_cidrs) {
		owned_cidrs[i] = strings.clone(trusted_cidrs[i])
	}
	return Device_Auth_Service{store = store, clock = clock, trusted_cidrs = owned_cidrs}
}

// with_token_minter attaches the task-3 token issuer so approve can pre-mint.
// `ctx` is forwarded to the minter on each call (the app wiring passes the
// App_Graph; tests pass their fake's state). Called by app wiring once task 3
// ships the real minter; tests inject a fake.
with_token_minter :: proc(service: ^Device_Auth_Service, minter: Token_Minter, minter_ctx: rawptr = nil) {
	service.minter = minter
	service.minter_ctx = minter_ctx
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
	return verify_with_ip(service, user_code, "")
}

// verify_with_ip adds ELDA-6 brute-force protection for the short user_code.
// The HTTP handler passes the trusted-XFF-resolved browser IP; service tests may
// call verify() directly when they do not need rate limiting.
verify_with_ip :: proc(service: ^Device_Auth_Service, user_code, request_ip: string) -> (Device_Info, bool, domain.Domain_Error) {
	now := service.clock.now()
	if request_ip != "" {
		sync.mutex_lock(&service.store.mutex)
		allowed := verify_rate_allow(service.store, request_ip, now)
		sync.mutex_unlock(&service.store.mutex)
		if !allowed do return Device_Info{}, false, domain.domain_error(.Rate_Limited, "too many device verification attempts from this IP")
	}
	device_code, grant, ok := grant_by_user_code(service.store, user_code)
	if !ok do return Device_Info{}, false, GENERIC_UNKNOWN_CODE_ERROR()
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
		// Pre-mint the token so the first /device/token poll can return it (task 3).
		// If the wired minter cannot issue, do not mark the grant approved; otherwise
		// the device would poll forever without a token.
		if service.minter != nil {
			token, token_id, tok_ok := service.minter(service.minter_ctx, owner_user_id, grant.client, grant.device_label)
			if !tok_ok do return false, domain.domain_error(.Internal_Error, "could not issue device authorization token")
			grant.minted_token = token
			grant.minted_token_id = token_id
		}
		grant.status = .Approved
	} else {
		grant.status = .Denied
	}
	set_grant(service.store, grant.device_code, grant)
	return true, domain.Domain_Error{}
}

// Poll_Status is the device-poll response status (ELDA-3).
Poll_Status :: enum {
	Pending,
	Approved,
	Denied,
	Expired,
	Slow_Down,
}

// Poll_Result is the /device/token response body shape (ELDA-3).
Poll_Result :: struct {
	status:       Poll_Status,
	access_token: string, // plaintext token; only set on first approved poll
	token_id:     string, // token id; only set on first approved poll
	expires_in:   int,    // seconds until the grant's token/flow expires; 0 if n/a
}

// poll implements the device token-poll lifecycle (ELDA-3):
//   - unknown device_code  -> Pending  (anti-enumeration: NOT 404)
//   - too-fast poll (< interval since last poll) -> Slow_Down (handler: 429 + Retry-After)
//   - approved grant       -> hand out the pre-minted plaintext token ONCE, then
//                             mark the grant Used; subsequent polls -> Expired
//   - denied grant         -> Denied
//   - expired/used grant   -> Expired
//   - pending grant        -> Pending
// `request_ip` is used for the per-IP poll rate limit (distinct from authorize).
poll :: proc(service: ^Device_Auth_Service, device_code, request_ip: string) -> (Poll_Result, domain.Domain_Error) {
	now := service.clock.now()
	// Per-IP poll rate limit (separate bucket from authorize). Checked first so
	// a flood of polls cannot pin the mutex. Returns Slow_Down + Rate_Limited.
	sync.mutex_lock(&service.store.mutex)
	poll_allowed := poll_rate_allow(service.store, request_ip, now)
	sync.mutex_unlock(&service.store.mutex)
	if !poll_allowed {
		return Poll_Result{status = .Slow_Down}, domain.domain_error(.Rate_Limited, "slow_down")
	}
	grant, ok := get_grant(service.store, device_code)
	if !ok {
		// Anti-enumeration: unknown device_code looks exactly like a pending grant.
		return Poll_Result{status = .Pending}, domain.Domain_Error{}
	}
	// Expired TTL -> Expired.
	if is_expired(grant, now) {
		set_grant_status(service.store, device_code, .Expired, &grant)
		return Poll_Result{status = .Expired}, domain.Domain_Error{}
	}
	// Terminal grants are not subject to slow_down; replaying a used grant must
	// return expired immediately to enforce single-use (ELDA-3/AC3).
	#partial switch grant.status {
	case .Denied:
		return Poll_Result{status = .Denied}, domain.Domain_Error{}
	case .Used, .Expired:
		grant.minted_token = ""
		set_grant(service.store, device_code, grant)
		return Poll_Result{status = .Expired}, domain.Domain_Error{}
	case:
	}
	interval := service.store.config.interval
	if interval <= 0 do interval = 5
	if grant.last_poll_at > 0 && now - grant.last_poll_at < i64(interval) {
		return Poll_Result{status = .Slow_Down}, domain.domain_error(.Rate_Limited, "slow_down")
	}
	// Record this accepted pending/approved poll for slow_down gating on the NEXT call.
	grant.last_poll_at = now
	#partial switch grant.status {
	case .Approved:
		// Single-use: hand out the token, then mark Used so the next poll is Expired.
		token := grant.minted_token
		tid := grant.minted_token_id
		grant.status = .Used
		grant.minted_token = ""
		set_grant(service.store, device_code, grant)
		if token == "" {
			// No pre-minted token (minter not wired). Surface as Pending so the
			// device keeps polling until task-3 lazy mint supplies one; do NOT
			// mark Used. (Approved-without-token is a wiring gap, not a terminal.)
			grant.status = .Approved
			set_grant(service.store, device_code, grant)
			return Poll_Result{status = .Pending}, domain.Domain_Error{}
		}
		return Poll_Result{status = .Approved, access_token = token, token_id = tid, expires_in = service.store.config.expires_in}, domain.Domain_Error{}
	case: // .Pending (covers Pending only; exhaustiveness)
		set_grant(service.store, device_code, grant)
	}
	return Poll_Result{status = .Pending}, domain.Domain_Error{}
}

// set_grant_status is a thin helper used by poll to update status + fields.
set_grant_status :: proc(store: ^Grant_Store, device_code: string, status: Grant_Status, grant: ^Grant) {
	grant.status = status
	set_grant(store, device_code, grant^)
}

// verify_rate_allow enforces per-IP brute-force protection for the short
// user_code. It uses its own key namespace so authorize/token budgets are
// independent. MUST be called under the store mutex.
verify_rate_allow :: proc(store: ^Grant_Store, ip: string, now: i64) -> bool {
	if ip == "" do return true
	if store.config.rate_limit <= 0 do return true
	key := strings.concatenate({"verify:", ip})
	defer delete(key)
	window := i64(store.config.rate_window)
	if window <= 0 do window = 60
	entry, has := store.rate[key]
	if !has || now - entry.window_start >= window {
		store.rate[strings.clone(key)] = Rate_Limit_Entry{window_start = now, count = 1}
		return true
	}
	if entry.count >= store.config.rate_limit do return false
	entry.count += 1
	store.rate[key] = entry
	return true
}

// poll_rate_allow enforces a per-IP poll rate limit using the store's rate map
// under a `poll:` key namespace, so it is independent of the authorize budget.
// Conservative default: 60 polls/min/IP (one every second) — well above the
// device's nominal interval but stops a single IP from hammering the endpoint.
poll_rate_allow :: proc(store: ^Grant_Store, ip: string, now: i64) -> bool {
	if ip == "" do return true
	key := strings.concatenate({"poll:", ip})
	defer delete(key)
	limit := 60
	window := 60
	if store.config.rate_limit > 0 {
		// Reuse the configured rate_limit as the poll budget too (per window).
		limit = store.config.rate_limit * 6
	}
	entry, has := store.rate[key]
	if !has || now - entry.window_start >= i64(window) {
		// Map string keys keep the string header/data; clone the temporary key on
		// insertion so the stored key remains valid after this proc returns.
		store.rate[strings.clone(key)] = Rate_Limit_Entry{window_start = now, count = 1}
		return true
	}
	if entry.count >= limit do return false
	entry.count += 1
	store.rate[key] = entry
	return true
}
