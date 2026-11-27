package provider

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"

// G5: installing or upgrading a provider CLI, adapter, Node.js or npm is picked
// up without a bridge restart or a manual Re-check. When the Hub reads a
// report that cannot be trusted as current, it asks the online bridge to
// re-detect that one provider, without waiting for the answer:
//   - the launch/reconfiguration gate (require_acp_ready) finds a non-ready
//     report: the launch still fails with its current error, and a retry sees
//     the fresh report;
//   - a provider-status read finds a report older than ACP_STATUS_STALE_AFTER.
// A not-ready System runtime gets the probe Re-check (install_acp_adapter,
// which also re-reports the provider); everything else gets a provider-scoped
// discover. Requests for the same bridge + provider are deduplicated for
// ACP_REDETECT_MIN_INTERVAL, so reads and launch retries never spam the bridge.
ACP_REDETECT_MIN_INTERVAL :: 30 * time.Second
ACP_STATUS_STALE_AFTER :: 10 * time.Minute
// A re-detection without a result after this long is treated as lost: it no
// longer suppresses new requests, and a lost Re-check command is failed.
ACP_REDETECT_INFLIGHT_TTL :: 2 * time.Minute

// One re-detection in flight for a bridge + provider. Discover requests are
// never persisted: their command id lives only here until the report arrives.
ACP_Redetect_Pending :: struct {
	command_id: string, // heap
	kind: ACP_Redetect_Kind,
	sent_at: time.Time,
}

ACP_Redetect_Kind :: enum u8 { Discover, Recheck }

// Creates and sends the command (the transport layer). It runs on a worker
// thread the redetector owns, never on the gate or read that asked.
ACP_Redetect_Dispatcher :: proc(ctx: rawptr, bridge_id, provider: string, kind: ACP_Redetect_Kind)

// ACP_Redetector owns the dispatcher and the dedupe window. It lives on the
// Hub graph (or a test) and is shared by pointer: Provider_Service.redetector
// and Agent_Service.acp_redetector. There is no process-wide state, so
// parallel services and tests never share a window or a dispatcher.
ACP_Redetector :: struct {
	mutex: sync.Mutex,
	dispatch: ACP_Redetect_Dispatcher,
	ctx: rawptr,
	last: map[string]time.Time, // bridge \x1f provider -> last request (heap)
	pending: map[string]ACP_Redetect_Pending, // bridge \x1f provider -> in flight (heap)
	// Every dispatch runs on a worker counted here; destroy joins them all, so
	// no worker outlives the handlers it uses. inline runs dispatches on the
	// caller instead (unit tests).
	workers: sync.Wait_Group,
	inline: bool,
	// Test seam: starts a worker thread; nil uses core:thread. Returns false
	// when no thread could be created.
	start_worker: proc(data: rawptr, fn: proc(data: rawptr)) -> bool,
}

@(private = "file")
acp_redetect_start_thread :: proc(data: rawptr, fn: proc(data: rawptr)) -> bool {
	context.allocator = runtime.heap_allocator() // the Thread record must outlive a per-request arena
	return thread.create_and_start_with_data(data, fn, self_cleanup = true) != nil
}

@(private = "file")
ACP_Redetect_Job :: struct {
	r: ^ACP_Redetector,
	dispatch: ACP_Redetect_Dispatcher,
	ctx: rawptr,
	bridge_id, provider: string,
	kind: ACP_Redetect_Kind,
}

@(private = "file")
acp_redetect_worker :: proc(data: rawptr) {
	job := (^ACP_Redetect_Job)(data)
	heap := runtime.heap_allocator()
	defer {
		r := job.r
		delete(job.bridge_id, heap); delete(job.provider, heap); free(job, heap)
		free_all(context.temp_allocator)
		sync.wait_group_done(&r.workers)
	}
	job.dispatch(job.ctx, job.bridge_id, job.provider, job.kind)
}

acp_redetector_init :: proc(r: ^ACP_Redetector, dispatch: ACP_Redetect_Dispatcher, ctx: rawptr) {
	sync.mutex_lock(&r.mutex); defer sync.mutex_unlock(&r.mutex)
	r.dispatch, r.ctx = dispatch, ctx
}

// acp_redetector_destroy stops new dispatches, joins the workers in flight,
// then frees the window. Call it before the dispatcher's context goes away.
acp_redetector_destroy :: proc(r: ^ACP_Redetector) {
	if r == nil do return
	sync.mutex_lock(&r.mutex)
	r.dispatch, r.ctx = nil, nil
	sync.mutex_unlock(&r.mutex)
	sync.wait_group_wait(&r.workers)
	sync.mutex_lock(&r.mutex); defer sync.mutex_unlock(&r.mutex)
	for key in r.last do delete(key, runtime.default_allocator())
	delete(r.last); r.last = nil
	for key, p in r.pending { delete(key, runtime.default_allocator()); delete(p.command_id, runtime.default_allocator()) }
	delete(r.pending); r.pending = nil
}

@(private = "file")
acp_redetect_key :: proc(bridge_id, provider: string) -> string {
	return strings.concatenate({bridge_id, "\x1f", provider}, context.temp_allocator)
}

// Caller holds r.mutex.
@(private = "file")
acp_redetect_pending_remove_locked :: proc(r: ^ACP_Redetector, key: string) {
	if _, present := r.pending[key]; !present do return
	old_key, old := delete_key(&r.pending, key)
	delete(old_key, runtime.default_allocator()); delete(old.command_id, runtime.default_allocator())
}

// acp_redetect_pending_set records the command now in flight for a provider.
acp_redetect_pending_set :: proc(r: ^ACP_Redetector, bridge_id, provider, command_id: string, kind: ACP_Redetect_Kind, now: time.Time) {
	if r == nil do return
	sync.mutex_lock(&r.mutex); defer sync.mutex_unlock(&r.mutex)
	if r.pending == nil do r.pending = make(map[string]ACP_Redetect_Pending, allocator = runtime.default_allocator())
	key := acp_redetect_key(bridge_id, provider)
	acp_redetect_pending_remove_locked(r, key)
	r.pending[strings.clone(key, runtime.default_allocator())] = {command_id = strings.clone(command_id, runtime.default_allocator()), kind = kind, sent_at = now}
}

// acp_redetect_pending_clear ends whatever is in flight for a provider (its
// result arrived, or sending failed).
acp_redetect_pending_clear :: proc(r: ^ACP_Redetector, bridge_id, provider: string) {
	if r == nil do return
	sync.mutex_lock(&r.mutex); defer sync.mutex_unlock(&r.mutex)
	acp_redetect_pending_remove_locked(r, acp_redetect_key(bridge_id, provider))
}

// acp_redetect_pending_take matches a Discover report to its request: only an
// id this redetector sent to this bridge, then forgets it. Returns the
// provider (temp) that was re-detected.
acp_redetect_pending_take :: proc(r: ^ACP_Redetector, bridge_id, command_id: string) -> (string, bool) {
	if r == nil || command_id == "" do return "", false
	sync.mutex_lock(&r.mutex); defer sync.mutex_unlock(&r.mutex)
	prefix := strings.concatenate({bridge_id, "\x1f"}, context.temp_allocator)
	for key, p in r.pending {
		if p.kind != .Discover || p.command_id != command_id || !strings.has_prefix(key, prefix) do continue
		provider := strings.clone(key[len(prefix):], context.temp_allocator)
		acp_redetect_pending_remove_locked(r, key)
		return provider, true
	}
	return "", false
}

// acp_redetect_pending_expired is the id of a request for this provider that
// got no result within ACP_REDETECT_INFLIGHT_TTL (temp), "" otherwise.
acp_redetect_pending_expired :: proc(r: ^ACP_Redetector, bridge_id, provider: string, now: time.Time) -> string {
	if r == nil do return ""
	sync.mutex_lock(&r.mutex); defer sync.mutex_unlock(&r.mutex)
	p, present := r.pending[acp_redetect_key(bridge_id, provider)]
	if !present || time.diff(p.sent_at, now) < ACP_REDETECT_INFLIGHT_TTL do return ""
	return strings.clone(p.command_id, context.temp_allocator)
}

// acp_redetector_clear_window forgets the dedupe window (tests; a request
// after it behaves as if the window had passed).
acp_redetector_clear_window :: proc(r: ^ACP_Redetector) {
	sync.mutex_lock(&r.mutex); defer sync.mutex_unlock(&r.mutex)
	for key in r.last do delete(key, runtime.default_allocator())
	clear(&r.last)
}

// acp_redetect_kind picks the request for a provider's current report.
acp_redetect_kind :: proc(provider, adapter_json: string) -> ACP_Redetect_Kind {
	d, known := contracts.acp_provider_descriptor(provider)
	if known && d.launch == .System && acp_adapter_state(adapter_json) != "ready" do return .Recheck
	return .Discover
}

// acp_request_redetect dispatches one re-detection unless one was requested
// for this bridge + provider within ACP_REDETECT_MIN_INTERVAL. Returns whether
// it dispatched. A nil redetector (no wiring) never dispatches.
acp_request_redetect :: proc(r: ^ACP_Redetector, bridge_id, provider: string, kind: ACP_Redetect_Kind, now: time.Time) -> bool {
	if r == nil do return false
	sync.mutex_lock(&r.mutex)
	dispatch, ctx := r.dispatch, r.ctx
	if dispatch == nil { sync.mutex_unlock(&r.mutex); return false }
	if r.last == nil do r.last = make(map[string]time.Time, allocator = runtime.default_allocator())
	key := acp_redetect_key(bridge_id, provider)
	// One re-detection in flight per provider, until its result or the TTL.
	if p, busy := r.pending[key]; busy && time.diff(p.sent_at, now) < ACP_REDETECT_INFLIGHT_TTL { sync.mutex_unlock(&r.mutex); return false }
	if last, seen := r.last[key]; seen {
		if time.diff(last, now) < ACP_REDETECT_MIN_INTERVAL { sync.mutex_unlock(&r.mutex); return false }
		old, _ := delete_key(&r.last, key)
		delete(old, runtime.default_allocator())
	}
	r.last[strings.clone(key, runtime.default_allocator())] = now
	inline := r.inline
	// Counted under the lock, so destroy cannot miss a worker being started.
	if !inline do sync.wait_group_add(&r.workers, 1)
	sync.mutex_unlock(&r.mutex)
	if inline { dispatch(ctx, bridge_id, provider, kind); return true }
	heap := runtime.heap_allocator()
	job := new(ACP_Redetect_Job, heap)
	job^ = {r = r, dispatch = dispatch, ctx = ctx, bridge_id = strings.clone(bridge_id, heap), provider = strings.clone(provider, heap), kind = kind}
	context.allocator = heap // the Thread record must outlive a per-request arena
	start := r.start_worker if r.start_worker != nil else acp_redetect_start_thread
	if !start(rawptr(job), acp_redetect_worker) {
		// No worker: undo the count so destroy never waits for it, and free the job.
		delete(job.bridge_id, heap); delete(job.provider, heap); free(job, heap)
		sync.wait_group_done(&r.workers)
		return false
	}
	return true
}

// acp_gate_redetect is the launch/reconfiguration gate's request: a report the
// bridge could act on that is not ready is re-detected.
acp_gate_redetect :: proc(r: ^ACP_Redetector, bridge: domain.Bridge, provider, adapter_json: string, verdict: contracts.ACP_Availability, now: time.Time) -> bool {
	if bridge.status != .Online do return false
	switch verdict.reason {
	case .Ready, .No_Recipe, .Unsupported_Bridge, .Installing: return false
	case .Adapter_Missing, .Adapter_Outdated, .Adapter_Missing_Node, .Adapter_Missing_Npm, .Adapter_Error, .Not_Checked:
	}
	return acp_request_redetect(r, bridge.bridge_id, provider, acp_redetect_kind(provider, adapter_json), now)
}

// acp_report_stale is true for a report the Hub received more than
// ACP_STATUS_STALE_AFTER ago, judged by received_at (the Hub's clock, set on
// upsert), never the bridge-reported checked_at, which can be skewed. A report
// with no receipt time (stored before it was recorded, or unreadable) is
// stale. No report is not stale: provider scans create the first one.
acp_report_stale :: proc(adapter_json, received_at: string, now: time.Time) -> bool {
	if adapter_json == "" do return false
	at, consumed := time.rfc3339_to_time_utc(received_at)
	if consumed == 0 do return true
	return time.diff(at, now) > ACP_STATUS_STALE_AFTER
}

// acp_read_redetect is the provider-status read's request for one provider
// row: an ACP-capable, online bridge with a stale report is re-detected.
acp_read_redetect :: proc(r: ^ACP_Redetector, bridge: domain.Bridge, provider, transports_json, recipe_json, adapter_json, received_at: string, now: time.Time) -> bool {
	if bridge.status != .Online || !contracts.bridge_supports_acp_runtime(bridge.capabilities_json) do return false
	if !contracts.provider_supports_transport(transports_json, "acp") || !contracts.acp_provider_recipe_valid(provider, recipe_json) do return false
	if !acp_report_stale(adapter_json, received_at, now) do return false
	return acp_request_redetect(r, bridge.bridge_id, provider, acp_redetect_kind(provider, adapter_json), now)
}
