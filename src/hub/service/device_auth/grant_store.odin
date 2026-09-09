// In-memory device-authorization grant store (ELDA-1).
//
// Holds pending/approved/denied device grants keyed by device_code, plus the
// per-source-IP authorize rate limiter. All mutations are serialized under a
// single mutex so concurrent device/authorize and token-poll threads see a
// consistent snapshot.
//
// Lifecycle:
//   pending  -> approved | denied   (set by the browser verify handler, task 2)
//   approved -> token minted        (token poll hands out minted_token, task 3)
//
// A background GC sweeper evicts grants whose requested_at + expires_in has
// passed, so the map cannot grow unbounded from abandoned flows. The store is
// purely in-memory (no DB) by design: device grants are short-lived ephemeral
// state, and task 3 persists the resulting user/bridge tokens elsewhere.

package device_auth

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:time"

// The grant store outlives the requests that populate it, so it owns every string
// it retains on the persistent heap — never on a caller's per-request arena.
// Ownership rule: the `grants` map owns each Grant's string fields; the
// `by_user_code` index only aliases them (its key/value point into the owning
// grant), so it is never freed independently.
grant_clone_strings :: proc(g: Grant, heap: runtime.Allocator) -> Grant {
	c := g
	c.device_code = strings.clone(g.device_code, heap)
	c.user_code = strings.clone(g.user_code, heap)
	c.verification_uri = strings.clone(g.verification_uri, heap)
	c.owner_user_id = strings.clone(g.owner_user_id, heap)
	c.device_label = strings.clone(g.device_label, heap)
	c.os = strings.clone(g.os, heap)
	c.app_version = strings.clone(g.app_version, heap)
	c.client = strings.clone(g.client, heap)
	c.request_ip = strings.clone(g.request_ip, heap)
	c.minted_token = strings.clone(g.minted_token, heap)
	c.minted_token_id = strings.clone(g.minted_token_id, heap)
	c.approver_ip = strings.clone(g.approver_ip, heap)
	c.approver_ua = strings.clone(g.approver_ua, heap)
	return c
}

grant_free_strings :: proc(g: Grant, heap: runtime.Allocator) {
	delete(g.device_code, heap)
	delete(g.user_code, heap)
	delete(g.verification_uri, heap)
	delete(g.owner_user_id, heap)
	delete(g.device_label, heap)
	delete(g.os, heap)
	delete(g.app_version, heap)
	delete(g.client, heap)
	delete(g.request_ip, heap)
	delete(g.minted_token, heap)
	delete(g.minted_token_id, heap)
	delete(g.approver_ip, heap)
	delete(g.approver_ua, heap)
}

// Grant_Status models the device-authorization grant lifecycle.
Grant_Status :: enum {
	Pending,
	Approved,
	Denied,
	Expired,
	Used, // token handed out on first successful poll (single-use, ELDA-3)
}

// Grant is one device-authorization flow. Fields populated over time:
//   - requested_at (creation), approver_* / decided_at (task 2 verify),
//     minted_token (task 3 token mint). owner_user_id is empty until the user
//     approves in the browser (task 2).
Grant :: struct {
	device_code:    string,
	user_code:      string,
	verification_uri: string,
	owner_user_id:  string,
	device_label:   string,
	os:             string,
	app_version:    string,
	client:         string,
	request_ip:     string,
	requested_at:   i64,   // unix seconds
	expires_at:     i64,   // unix seconds
	status:         Grant_Status,
	minted_token:   string,
	minted_token_id: string,
	approver_ip:    string,
	approver_ua:    string,
	decided_at:     i64,
	last_poll_at:   i64, // unix seconds of the last /device/token poll (slow_down gating)
}

// Authorize_Input is the public /device/authorize request body (ELDA-1).
Authorize_Input :: struct {
	client:     string,
	device_label: string,
	os:         string,
	app_version: string,
}

// Authorize_Result is what /device/authorize hands back to the device (ELDA-1).
Authorize_Result :: struct {
	device_code:    string,
	user_code:      string,
	verification_uri: string,
	interval:       int,
	expires_in:     int,
}

// Monotonic_Clock provides unix-second timestamps so expiry/rate-limit math is
// deterministic in tests. The real implementation reads wall-clock time.
Monotonic_Clock :: struct {
	now:    proc() -> i64,
}

real_monotonic_clock :: proc() -> Monotonic_Clock {
	return Monotonic_Clock{now = real_unix_seconds}
}

real_unix_seconds :: proc() -> i64 {
	return time.to_unix_seconds(time.now())
}

// Rate_Limit_Entry tracks per-IP authorize counts inside the rolling window.
Rate_Limit_Entry :: struct {
	window_start: i64,
	count:        int,
}

// Grant_Store is the thread-safe in-memory grant store + rate limiter.
// `config` is treated as read-only after construction.
Grant_Store :: struct {
	config:   Grant_Store_Config,
	mutex:    sync.Mutex,
	grants:   map[string]Grant,        // keyed by device_code
	by_user_code: map[string]string,   // user_code -> device_code (for browser verify lookup, task 2)
	rate:     map[string]Rate_Limit_Entry, // keyed by source IP
}

// Grant_Store_Config tunes TTL, polling interval, rate limit, and the
// verification_uri base the device should open in a browser.
Grant_Store_Config :: struct {
	verification_uri: string,   // browser/outpost device URL (NOT the API URL)
	expires_in:       int,      // grant lifetime in seconds (<=600, ELDA-1)
	interval:         int,      // polling interval the device should use (seconds)
	rate_limit:       int,      // max authorize calls per IP per window
	rate_window:      int,      // rate-limit window in seconds
}

default_grant_store_config :: proc() -> Grant_Store_Config {
	return Grant_Store_Config{
		verification_uri = "https://auth.example.com/application/o/heimdall/device/",
		expires_in = 600,
		interval = 5,
		rate_limit = 10,
		rate_window = 60,
	}
}

new_grant_store :: proc(config: Grant_Store_Config) -> Grant_Store {
	return Grant_Store{
		config = config,
		grants = make(map[string]Grant),
		by_user_code = make(map[string]string),
		rate = make(map[string]Rate_Limit_Entry),
	}
}

grant_store_free :: proc(store: ^Grant_Store) {
	heap := runtime.heap_allocator()
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)
	// Free each grant's owned strings (by_user_code only aliases them) and each
	// heap-owned rate-limit key, then drop the maps themselves. Iterating without
	// delete_key is safe; the maps are deleted wholesale afterwards.
	for _, grant in store.grants do grant_free_strings(grant, heap)
	for ip in store.rate do delete(ip, heap)
	delete(store.grants)
	delete(store.by_user_code)
	delete(store.rate)
}

// allow_authorize enforces the per-source-IP authorize rate limit BEFORE any
// grant is created (store-filling DoS protection, ELDA-1). Returns true if the
// caller is under the limit (and increments the counter); false otherwise.
// MUST be called under the store mutex.
allow_authorize :: proc(store: ^Grant_Store, ip: string, now: i64) -> bool {
	if ip == "" do return true // cannot attribute; allow (handler still validates input)
	if store.config.rate_limit <= 0 do return true // limit disabled
	entry, has := store.rate[ip]
	window := i64(store.config.rate_window)
	if window <= 0 do window = 60
	if !has || now - entry.window_start >= window {
		// Map string keys keep the string header/data; clone request-derived IPs so
		// rate-limit entries never point at temporary request buffers.
		store.rate[strings.clone(ip, runtime.heap_allocator())] = Rate_Limit_Entry{window_start = now, count = 1}
		return true
	}
	if entry.count >= store.config.rate_limit do return false
	entry.count += 1
	store.rate[ip] = entry
	return true
}

// create_grant mints a new device grant. Caller MUST have already passed the
// rate-limit check (allow_authorize) and validated input. Generates fresh,
// unlinkable device_code + user_code (AC2). Returns ("", false) only if the OS
// CSPRNG is unavailable (caller fails closed with 503).
create_grant :: proc(store: ^Grant_Store, input: Authorize_Input, request_ip: string, clock: Monotonic_Clock) -> (Authorize_Result, bool) {
	device_code, ok := generate_device_code()
	if !ok do return Authorize_Result{}, false
	user_code, uok := generate_user_code()
	if !uok do return Authorize_Result{}, false
	now := clock.now()
	expires_in := store.config.expires_in
	if expires_in <= 0 || expires_in > 600 do expires_in = 600 // ELDA-1 hard cap
	grant := Grant{
		device_code = device_code,
		user_code = user_code,
		verification_uri = store.config.verification_uri,
		device_label = input.device_label,
		os = input.os,
		app_version = input.app_version,
		client = input.client,
		request_ip = request_ip,
		requested_at = now,
		expires_at = now + i64(expires_in),
		status = .Pending,
	}
	heap := runtime.heap_allocator()
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)
	// NOTE: device_code collisions are astronomically unlikely (256-bit CSPRNG);
	// map insertion is idempotent for dups, so no explicit guard is needed.
	// Persist heap-owned copies: `grant`'s request-derived fields (device_label,
	// os, app_version, client, request_ip) live on the per-request arena.
	stored := grant_clone_strings(grant, heap)
	store.grants[stored.device_code] = stored
	store.by_user_code[stored.user_code] = stored.device_code
	return Authorize_Result{
		device_code = device_code,
		user_code = user_code,
		verification_uri = store.config.verification_uri,
		interval = store.config.interval,
		expires_in = expires_in,
	}, true
}

// get_grant returns the live grant for a device_code (or false if absent). The
// returned grant is a snapshot copy; mutations go through the mutator procs.
get_grant :: proc(store: ^Grant_Store, device_code: string) -> (Grant, bool) {
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)
	grant, ok := store.grants[device_code]
	return grant, ok
}

// set_grant replaces the grant for a device_code under the mutex (used by
// approve to write the terminal decision + audit fields atomically).
set_grant :: proc(store: ^Grant_Store, device_code: string, grant: Grant) {
	heap := runtime.heap_allocator()
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)
	// Clone onto the heap so the entry never points at the caller's per-request
	// arena. The previous entry's strings are intentionally NOT freed here: the
	// store hands out borrowed snapshots (get_grant / grant_by_user_code return a
	// value copy whose string fields alias the stored heap strings), and a caller
	// may still be using one — e.g. approve passes grant.client to the token minter
	// in the same call that then set_grants. So grant strings are treated as
	// immortal (exactly as the original store did) and reclaimed only at
	// grant_store_free; the residual is bounded by the grant's short TTL. Overwrite
	// reuses the existing map keys (Odin keeps the key on assignment to an existing
	// entry), so no key churn.
	store.grants[device_code] = grant_clone_strings(grant, heap)
	store.by_user_code[grant.user_code] = device_code
}

// grant_by_user_code looks up a grant by its short user_code (for the browser
// verify flow, task 2). Returns the device_code + grant snapshot.
grant_by_user_code :: proc(store: ^Grant_Store, user_code: string) -> (string, Grant, bool) {
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)
	device_code, ok := store.by_user_code[user_code]
	if !ok do return "", Grant{}, false
	grant, gok := store.grants[device_code]
	if !gok do return "", Grant{}, false
	return device_code, grant, true
}

// is_expired reports whether a grant's TTL has elapsed at `now`.
is_expired :: proc(grant: Grant, now: i64) -> bool {
	return now >= grant.expires_at
}

// sweep evicts expired grants (status -> .Expired, then removed). Called by the
// GC loop and safe to call from tests with a controlled clock.
sweep :: proc(store: ^Grant_Store, now: i64) -> int {
	heap := runtime.heap_allocator()
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)
	removed := 0
	// Collect expired codes first — deleting during a map range is unsafe.
	expired: [dynamic]string
	expired.allocator = context.temp_allocator
	defer delete(expired)
	for code, grant in store.grants {
		if now >= grant.expires_at do append(&expired, code)
	}
	for code in expired {
		if grant, ok := store.grants[code]; ok {
			delete_key(&store.grants, code)
			delete_key(&store.by_user_code, grant.user_code)
			// Grant strings are NOT freed here: they may be aliased by a borrowed
			// snapshot a concurrent request is still using (get_grant releases the
			// mutex before the caller reads the snapshot). They are heap-owned and
			// reclaimed at grant_store_free; the residual is TTL-bounded.
			removed += 1
		}
	}
	// Evict stale rate-limit entries; the per-IP rate map previously grew
	// monotonically with unique source IPs. An entry whose window has fully elapsed
	// is safe to drop (the next request re-seeds it via allow_authorize/verify/poll).
	window := i64(store.config.rate_window)
	if window <= 0 do window = 60
	stale: [dynamic]string
	stale.allocator = context.temp_allocator
	defer delete(stale)
	for ip, entry in store.rate {
		if now - entry.window_start >= window do append(&stale, ip)
	}
	for ip in stale {
		delete_key(&store.rate, ip)
		delete(ip, heap)
	}
	return removed
}

// gc_loop runs sweep on a fixed cadence forever; intended to be launched in
// its own thread by the app wiring (process-scoped, like server.serve). The
// cadence is min(expires_in, 120s)/2 so grants are reaped within ~half a TTL.
gc_loop :: proc(store: ^Grant_Store) {
	cadence := store.config.expires_in
	if cadence <= 0 || cadence > 120 do cadence = 60
	cadence = max(cadence / 2, 5)
	for {
		time.sleep(time.Duration(cadence) * time.Second)
		sweep(store, real_unix_seconds())
	}
}
