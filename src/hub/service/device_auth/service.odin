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
}

new_device_auth_service :: proc(store: ^Grant_Store, clock: Monotonic_Clock, trusted_cidrs: []string) -> Device_Auth_Service {
	return Device_Auth_Service{store = store, clock = clock, trusted_cidrs = trusted_cidrs}
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
