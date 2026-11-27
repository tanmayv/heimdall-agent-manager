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

@(private = "file") acp_redetect_dispatcher: ACP_Redetect_Dispatcher
@(private = "file") acp_redetect_ctx: rawptr
@(private = "file") acp_redetect_mutex: sync.Mutex
@(private = "file") acp_redetect_last: map[string]time.Time

// Registered once by the Hub wiring; without it no re-detection is requested.
acp_redetect_register :: proc(dispatcher: ACP_Redetect_Dispatcher, ctx: rawptr) {
	sync.mutex_lock(&acp_redetect_mutex); defer sync.mutex_unlock(&acp_redetect_mutex)
	acp_redetect_dispatcher, acp_redetect_ctx = dispatcher, ctx
}

// Clears the dedupe window (tests).
acp_redetect_reset :: proc() {
	sync.mutex_lock(&acp_redetect_mutex); defer sync.mutex_unlock(&acp_redetect_mutex)
	for key in acp_redetect_last do delete(key, runtime.default_allocator())
	clear(&acp_redetect_last)
}

// acp_redetect_kind picks the request for a provider's current report.
acp_redetect_kind :: proc(provider, adapter_json: string) -> ACP_Redetect_Kind {
	d, known := contracts.acp_provider_descriptor(provider)
	if known && d.launch == .System && acp_adapter_state(adapter_json) != "ready" do return .Recheck
	return .Discover
}

// acp_request_redetect dispatches one re-detection unless one was requested
// for this bridge + provider within ACP_REDETECT_MIN_INTERVAL. Returns whether
// it dispatched.
acp_request_redetect :: proc(bridge_id, provider: string, kind: ACP_Redetect_Kind, now: time.Time) -> bool {
	sync.mutex_lock(&acp_redetect_mutex)
	dispatcher, ctx := acp_redetect_dispatcher, acp_redetect_ctx
	if dispatcher == nil { sync.mutex_unlock(&acp_redetect_mutex); return false }
	key := strings.concatenate({bridge_id, "\x1f", provider}, context.temp_allocator)
	if last, seen := acp_redetect_last[key]; seen && time.diff(last, now) < ACP_REDETECT_MIN_INTERVAL {
		sync.mutex_unlock(&acp_redetect_mutex)
		return false
	}
	if acp_redetect_last == nil do acp_redetect_last = make(map[string]time.Time, allocator = runtime.default_allocator())
	if _, seen := acp_redetect_last[key]; seen {
		old, _ := delete_key(&acp_redetect_last, key)
		delete(old, runtime.default_allocator())
	}
	acp_redetect_last[strings.clone(key, runtime.default_allocator())] = now
	sync.mutex_unlock(&acp_redetect_mutex)
	dispatcher(ctx, bridge_id, provider, kind)
	return true
}

// acp_gate_redetect is the launch/reconfiguration gate's request: a report the
// bridge could act on that is not ready is re-detected.
acp_gate_redetect :: proc(bridge: domain.Bridge, provider, adapter_json: string, verdict: contracts.ACP_Availability, now: time.Time) -> bool {
	if bridge.status != .Online do return false
	switch verdict.reason {
	case .Ready, .No_Recipe, .Unsupported_Bridge, .Installing: return false
	case .Adapter_Missing, .Adapter_Outdated, .Adapter_Missing_Node, .Adapter_Missing_Npm, .Adapter_Error, .Not_Checked:
	}
	return acp_request_redetect(bridge.bridge_id, provider, acp_redetect_kind(provider, adapter_json), now)
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
acp_read_redetect :: proc(bridge: domain.Bridge, provider, transports_json, recipe_json, adapter_json: string, now: time.Time) -> bool {
	if bridge.status != .Online || !contracts.bridge_supports_acp_runtime(bridge.capabilities_json) do return false
	if !contracts.provider_supports_transport(transports_json, "acp") || !contracts.acp_provider_recipe_valid(provider, recipe_json) do return false
	if !acp_report_stale(adapter_json, now) do return false
	return acp_request_redetect(bridge.bridge_id, provider, acp_redetect_kind(provider, adapter_json), now)
}
