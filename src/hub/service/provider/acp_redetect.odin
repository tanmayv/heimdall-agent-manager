package provider

import "base:runtime"
import "core:encoding/json"
import "core:strings"
import "core:sync"
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

ACP_Redetect_Kind :: enum u8 { Discover, Recheck }

// Sends the tracked command and returns at once (the transport layer).
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
}

acp_redetector_init :: proc(r: ^ACP_Redetector, dispatch: ACP_Redetect_Dispatcher, ctx: rawptr) {
	sync.mutex_lock(&r.mutex); defer sync.mutex_unlock(&r.mutex)
	r.dispatch, r.ctx = dispatch, ctx
}

// acp_redetector_destroy stops dispatching and frees the window.
acp_redetector_destroy :: proc(r: ^ACP_Redetector) {
	if r == nil do return
	sync.mutex_lock(&r.mutex); defer sync.mutex_unlock(&r.mutex)
	r.dispatch, r.ctx = nil, nil
	for key in r.last do delete(key, runtime.default_allocator())
	delete(r.last); r.last = nil
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
	key := strings.concatenate({bridge_id, "\x1f", provider}, context.temp_allocator)
	if last, seen := r.last[key]; seen {
		if time.diff(last, now) < ACP_REDETECT_MIN_INTERVAL { sync.mutex_unlock(&r.mutex); return false }
		old, _ := delete_key(&r.last, key)
		delete(old, runtime.default_allocator())
	}
	r.last[strings.clone(key, runtime.default_allocator())] = now
	sync.mutex_unlock(&r.mutex)
	dispatch(ctx, bridge_id, provider, kind)
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

// acp_report_stale is true for a report whose checked_at is older than
// ACP_STATUS_STALE_AFTER (or unreadable). No report is not stale: provider
// scans create the first one.
acp_report_stale :: proc(adapter_json: string, now: time.Time) -> bool {
	if adapter_json == "" do return false
	value, err := json.parse_string(adapter_json, allocator = context.temp_allocator)
	if err != nil do return true
	obj, ok := value.(json.Object)
	if !ok do return true
	checked, cok := obj["checked_at"].(json.String)
	if !cok do return true
	at, consumed := time.rfc3339_to_time_utc(string(checked))
	if consumed == 0 do return true
	return time.diff(at, now) > ACP_STATUS_STALE_AFTER
}

// acp_read_redetect is the provider-status read's request for one provider
// row: an ACP-capable, online bridge with a stale report is re-detected.
acp_read_redetect :: proc(r: ^ACP_Redetector, bridge: domain.Bridge, provider, transports_json, recipe_json, adapter_json: string, now: time.Time) -> bool {
	if bridge.status != .Online || !contracts.bridge_supports_acp_runtime(bridge.capabilities_json) do return false
	if !contracts.provider_supports_transport(transports_json, "acp") || !contracts.acp_provider_recipe_valid(provider, recipe_json) do return false
	if !acp_report_stale(adapter_json, now) do return false
	return acp_request_redetect(r, bridge.bridge_id, provider, acp_redetect_kind(provider, adapter_json), now)
}
