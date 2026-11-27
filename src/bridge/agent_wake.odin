package main

import "core:fmt"
import "base:runtime"
import "core:encoding/json"
import "core:time"
import "core:math/rand"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:mem/virtual"
import httpc "odin_test:lib/httpc"

// Bridge-side agent wake machinery. The hub pushes work (leases, notices) to the
// bridge via wake_agent / notify frames; when the target instance is not live
// the bridge launches it through the same path as a hub launch_agent, subject to
// coalescing, retriable-failure backoff and parking (see Bridge_Wake_State).
//
// Task System v2 note: the former bridge-side task scheduler (periodic poll of
// GET /api/v1/bridge/actionable-tasks + auto-nudge) was removed; the bridge no
// longer polls the hub for work. Only the wake state machine remains.

BRIDGE_WAKE_COALESCE_MS :: i64(30_000)
// Retriable wake failures back off 1m, 2m, 4m ... capped at 30m (+-20% jitter).
BRIDGE_WAKE_BACKOFF :: Bridge_Backoff_Policy{base_ms = 60_000, max_ms = 1_800_000, jitter_pct = 20}
// A parked wake re-checks its LOCAL unpark probe (provider resolvable on PATH) at
// most this often; the probe may scan PATH, so it is not run on every tick.
BRIDGE_WAKE_PARK_PROBE_MS :: i64(300_000)

bridge_wake_mutex: sync.Mutex
bridge_agent_wake: map[string]Bridge_Wake_State // agent_instance_id -> wake state

bridge_wake_once: sync.Once
// Persistent leaves share the map's stable allocator: heap in production,
// and the tracking allocator of an isolated ownership-test map.
bridge_wake_owned_allocator :: proc() -> runtime.Allocator {
    if bridge_agent_wake.allocator.procedure != nil do return bridge_agent_wake.allocator
    return runtime.heap_allocator()
}

// bridge_agent_wake_init allocates the wake state exactly once. It is idempotent
// and never replaces the mutex or the map, because launch paths
// (bridge_task_wake_note_launched) can run as soon as the hub worker starts. main
// calls it before bridge_hub_runtime_start; every entry point also calls it, so
// no call order can touch nil state.
bridge_agent_wake_init :: proc() {
	sync.once_do(&bridge_wake_once, proc() {
		bridge_agent_wake = make(map[string]Bridge_Wake_State, bridge_wake_owned_allocator())
	})
}

// bridge_agent_wake_reset empties the wake state in place (tests).
bridge_agent_wake_reset :: proc() {
	bridge_agent_wake_init()
	sync.mutex_lock(&bridge_wake_mutex)
	defer sync.mutex_unlock(&bridge_wake_mutex)
	for key, &st in bridge_agent_wake {
        bridge_wake_state_free(&st)
        delete(st.ref, bridge_wake_owned_allocator())
        delete(key, bridge_wake_owned_allocator())
    }
	clear(&bridge_agent_wake)
}

// bridge_task_status_notify_wake_local wakes a non-live target in response to a
// hub notify frame (task_status_changed_notify, notify_*_nudge, ...). The
// Hub routes each notify ONLY to the bridge that hosts the target instance, so a
// target that arrives here is authoritative — we must not gate on the bridge's
// in-memory runtime registry, which is empty right after a bridge restart (the
// exact orphan-recovery case). We therefore trust the Hub's routing and attempt
// the wake directly; the launch path itself validates whether the instance can
// run locally (provider/tmux). Wakes remain coalesced within
// BRIDGE_WAKE_COALESCE_MS. Returns true when a wake was requested.
bridge_task_status_notify_wake_local :: proc(instance_id: string) -> bool {
	return bridge_task_wake_if_needed(instance_id, bridge_runtime_now_ms())
}

// Per-instance wake state. The error class of the last failed wake decides what
// happens next (see contracts.bridge_error_classify):
//   retriable   -> exponential backoff (BRIDGE_WAKE_BACKOFF); never parks.
//   recoverable -> PARKED: no backoff retries. Unparks when the provider catalog
//                  changes; for provider_missing / missing_binary when the provider
//                  becomes resolvable locally; for vault_locked when the vault is
//                  unsealed; for any other cause on a slow re-check at the backoff cap.
//   fatal       -> PARKED until a launch of this instance succeeds by another path
//                  (e.g. a hub launch_agent) or the bridge restarts.
// Any successful launch resets the state (bridge_task_wake_note_launched).
Bridge_Wake_State :: struct {
    ref: string, // owned, stable through retriable failures of one wake
    live_row_retry_at_ms: i64,
    live_row_retries: int,

	last_wake_ms:  i64, // last attempt; wakes within BRIDGE_WAKE_COALESCE_MS coalesce
	failures:      int, // consecutive retriable failures
	next_at_ms:    i64, // earliest next attempt after a retriable failure
	parked:        bool,
	err:           Bridge_Error, // last failure
	probe_at_ms:   i64,    // parked: last local unpark probe
	catalog_etag:  string, // parked: provider catalog etag at park time (owned)
	provider:      string, // parked: for the local unpark probe (owned)
	model:         string, // (owned)
	generation:    u64,    // bumped by every successful launch; a wake result is
	                       // applied only if the generation it started under is current
}

Bridge_Wake_Decision :: enum {
	Wake,
	Coalesced,
	Backing_Off,
	Parked,
}

Bridge_Wake_Transition :: enum {
	None,
	Recovered,
	Backoff,
	Parked,
}

bridge_wake_state_free :: proc(st: ^Bridge_Wake_State) {
	delete(st.catalog_etag, bridge_wake_owned_allocator())
	delete(st.provider, bridge_wake_owned_allocator())
	delete(st.model, bridge_wake_owned_allocator())
	st.catalog_etag, st.provider, st.model = "", "", ""
}

// bridge_wake_gate is the pure wake decision. `unpark` is the parked instance's
// trigger check, evaluated by the caller only while parked.
bridge_wake_gate :: proc(st: Bridge_Wake_State, has: bool, now_ms: i64, unpark := false) -> Bridge_Wake_Decision {
	if !has do return .Wake
	if st.parked do return .Wake if unpark else .Parked
	if now_ms - st.last_wake_ms < BRIDGE_WAKE_COALESCE_MS do return .Coalesced
	if st.next_at_ms > now_ms do return .Backing_Off
	return .Wake
}

// bridge_wake_record applies one wake outcome to `st` and reports the transition
// to log. It never touches the owned park strings; the caller sets them on .Parked.
bridge_wake_record :: proc(st: ^Bridge_Wake_State, ok: bool, err: Bridge_Error, now_ms: i64, jitter_seed: u64 = 0) -> Bridge_Wake_Transition {
	st.last_wake_ms = now_ms
	if ok {
		was_failing := st.parked || st.failures > 0
		st.parked, st.failures, st.next_at_ms, st.err = false, 0, 0, {}
		return .Recovered if was_failing else .None
	}
	st.err = err
	switch err.class {
	case .retriable:
		st.parked = false
		st.failures += 1
		st.next_at_ms = bridge_backoff_next_at_ms(BRIDGE_WAKE_BACKOFF, st.failures, now_ms, err, jitter_seed)
		return .Backoff
	case .recoverable, .fatal:
		was_parked := st.parked
		st.parked, st.failures, st.next_at_ms, st.probe_at_ms = true, 0, 0, now_ms
		return .None if was_parked else .Parked
	}
	return .None
}

// bridge_provider_runnable reports whether (provider, model) could be spawned on
// this bridge right now: known to the catalog and the binary resolvable. Local
// only; no hub call.
bridge_provider_runnable :: proc(provider, model: string) -> bool {
	if strings.trim_space(provider) == "" || strings.trim_space(model) == "" do return false
	if !bridge_provider_catalog_has_model(provider, model) do return false
	if _, ok := bridge_provider_catalog_profile(provider); !ok do return false
	path, path_ok := bridge_provider_resolve_path(provider)
	if !path_ok do return false
	delete(path)
	return true
}

// bridge_wake_unpark_trigger evaluates a parked instance's resume triggers and
// returns a non-empty trigger name when it should be retried. Called under the
// wake mutex; updates probe_at_ms.
bridge_wake_unpark_trigger :: proc(st: ^Bridge_Wake_State, now_ms: i64) -> string {
	if st.err.class == .fatal do return ""
	etag := bridge_provider_catalog_current_etag()
	defer delete(etag)
	if etag != st.catalog_etag do return "provider_catalog_changed"
	provider_problem := st.err.code == .provider_missing || st.err.reason == .missing_binary || st.err.reason == .not_executable
	if provider_problem || st.err.code == .vault_locked {
		if now_ms - st.probe_at_ms < BRIDGE_WAKE_PARK_PROBE_MS do return ""
		st.probe_at_ms = now_ms
		if provider_problem && bridge_provider_runnable(st.provider, st.model) do return "provider_runnable"
		if st.err.code == .vault_locked && bridge_vault_status() == .Unlocked do return "vault_unsealed"
		return ""
	}
	// Any other recoverable cause (a refused bootstrap token, hub-side config) has no
	// local signal to watch: re-check it at the retriable backoff cap, so a fix made
	// elsewhere is picked up without user action and without a retry storm.
	if now_ms - st.last_wake_ms >= BRIDGE_WAKE_BACKOFF.max_ms do return "periodic_recheck"
	return ""
}

// bridge_task_wake_note_launched resets an instance's wake state after ANY
// successful launch (hub launch_agent, wake_agent, action scheduler), which is the
// universal unpark trigger.
//
// The entry is created when absent, so a wake that registers AFTER this success
// (it read a stale "not active" snapshot) still sees the bumped generation and a
// fresh last_wake_ms, which coalesces it away.
bridge_task_wake_note_launched :: proc(instance_id: string, now_ms: i64 = 0) {
	bridge_agent_wake_init()
	sync.mutex_lock(&bridge_wake_mutex)
	defer sync.mutex_unlock(&bridge_wake_mutex)
	if instance_id not_in bridge_agent_wake do bridge_agent_wake[strings.clone(instance_id, bridge_wake_owned_allocator())] = Bridge_Wake_State{}
	st := &bridge_agent_wake[instance_id]
	st.last_wake_ms = now_ms if now_ms > 0 else bridge_runtime_now_ms()
	if st.parked || st.failures > 0 do fmt.println("bridge wake RECOVERED (launched)", instance_id)
	bridge_wake_state_free(st)
	st.parked, st.failures, st.next_at_ms, st.err = false, 0, 0, {}
	// Invalidate any wake attempt still in flight: its (older) result must not
	// re-park or back off an instance that has since launched.
	st.generation += 1
    delete(st.ref, bridge_wake_owned_allocator()); st.ref = ""
    st.live_row_retry_at_ms, st.live_row_retries = 0, 0
}

// bridge_task_wake_if_needed wakes a local instance if it is not currently live,
// subject to coalescing (BRIDGE_WAKE_COALESCE_MS), retriable-failure backoff and
// parking (see Bridge_Wake_State). Returns true if a wake was requested and the
// launch succeeded.
Bridge_Wake_Outcome :: enum { Launched, Already_Active, Coalesced, Backing_Off, Parked, Failed }
Bridge_Wake_Result :: struct { outcome: Bridge_Wake_Outcome, err: Bridge_Error, retry_after_ms: i64 }
BRIDGE_LIVE_ROW_RETRY_MS :: i64(30_000)
BRIDGE_LIVE_ROW_RETRIES :: 5
bridge_wake_snapshot_proc: proc(instance_id: string) -> (Bridge_Runtime_Instance, bool) = bridge_runtime_instance_snapshot
bridge_wake_probe_proc: proc(instance_id: string) -> Bridge_Instance_Probe_Result = bridge_instance_probe
bridge_wake_launch_proc: proc(command_id, command_json: string, deadline_ns: i64) -> (bool, string, Bridge_Error) = bridge_wake_launch
bridge_wake_start_begin_proc: proc(instance_id, ref: string, deadline_ns: i64) -> (string, string, Bridge_Error, bool) = bridge_wake_start_begin
bridge_wake_manifest_proc: proc(instance_id, command_id: string, deadline_ns: i64) -> (string, Bridge_Error, bool) = bridge_wake_legacy_manifest
// The single legacy manifest call site, shared by fallback and bots.
bridge_wake_manifest :: proc(instance_id, command_id: string, deadline_ns: i64, bot_delivery := false) -> (string, Bridge_Error, bool) {
    if !sync.atomic_load(&bridge_hub_start_begin_supported) {
        return bridge_wake_fetch_enriched_launch_json(instance_id, command_id, deadline_ns, use_manifest_run_count = bot_delivery)
    }
    return "", bridge_error(.hub_rejected, .other, 409), false
}
bridge_wake_legacy_manifest :: proc(instance_id, command_id: string, deadline_ns: i64) -> (string, Bridge_Error, bool) {
    return bridge_wake_manifest(instance_id, command_id, deadline_ns)
}
bridge_wake_http_proc: proc(req: httpc.Request) -> (httpc.Response, httpc.Error) = bridge_hub_http_send
bridge_wake_launch :: proc(command_id, command_json: string, deadline_ns: i64) -> (bool, string, Bridge_Error) {
    return bridge_runtime_launch_agent(command_id, command_json, deadline_ns)
}
bridge_task_wake_if_needed :: proc(instance_id: string, now: i64, deadline_ns: i64 = 0) -> bool {
    return bridge_wake_attempt(instance_id, now, deadline_ns).outcome == .Launched
}
bridge_wake_attempt :: proc(instance_id: string, now: i64, deadline_ns: i64 = 0, delivery_id: string = "", pending_ref: string = "") -> Bridge_Wake_Result {
	bridge_agent_wake_init()
	// Daemon calls and the Hub's start-begin decision must run outside the
	// wake mutex. A concurrent launch invalidates the wake generation.
	proof := bridge_wake_probe_proc(instance_id)
	sync.mutex_lock(&bridge_wake_mutex)
    if pending_ref != "" {
        if st, has := bridge_agent_wake[instance_id]; !has || st.ref != pending_ref {
            sync.mutex_unlock(&bridge_wake_mutex)
            return {.Coalesced, {}, 0}
        }
    }
	inst, found := bridge_wake_snapshot_proc(instance_id)
	if proof.state == "alive" && (delivery_id == "" || !found || inst.stopped_intent_unix_ms == 0) {
        if st, has := &bridge_agent_wake[instance_id]; has do st.live_row_retry_at_ms = 0
		sync.mutex_unlock(&bridge_wake_mutex)
		return {.Already_Active, {}, 0}
	}
	st, has := bridge_agent_wake[instance_id]
	trigger := ""
	if has && st.parked {
		trigger = bridge_wake_unpark_trigger(&bridge_agent_wake[instance_id], now)
		st = bridge_agent_wake[instance_id]
	}
	gate := bridge_wake_gate(st, has, now, trigger != "")
	if gate != .Wake {
		sync.mutex_unlock(&bridge_wake_mutex)
		switch gate {
        case .Coalesced: return {.Coalesced, {}, max(0, st.last_wake_ms + BRIDGE_WAKE_COALESCE_MS - now)}
        case .Backing_Off: return {.Backing_Off, st.err, max(0, st.next_at_ms - now)}
        case .Parked: return {.Parked, st.err, 0}
        case .Wake:
        }
	}
	if !has do bridge_agent_wake[strings.clone(instance_id, bridge_wake_owned_allocator())] = Bridge_Wake_State{}
	slot := &bridge_agent_wake[instance_id]
    if delivery_id == "" && sync.atomic_load(&bridge_hub_start_begin_supported) {
        // An accepted fresh notice supersedes a pending stale-row wake.
        if pending_ref == "" && slot.live_row_retry_at_ms != 0 {
            delete(slot.ref, bridge_wake_owned_allocator()); slot.ref = ""
            slot.live_row_retries = 0
            slot.generation += 1
        }
        if slot.ref == "" {
            bridge_wake_ref_counter = max(bridge_wake_ref_counter + 1, time.to_unix_nanoseconds(time.now()))
            slot.ref = fmt.aprintf("fb_%s_%d", instance_id, bridge_wake_ref_counter, allocator = bridge_wake_owned_allocator())
        }
    }
    ref := strings.clone(slot.ref)
    defer delete(ref)
    slot.live_row_retry_at_ms = 0
	slot.last_wake_ms = now
	generation := slot.generation
	sync.mutex_unlock(&bridge_wake_mutex)
	if trigger != "" do fmt.println("bridge wake UNPARKED", instance_id, "trigger=", trigger)

    command_id := fmt.aprintf("sched_wake_%s_%d", instance_id, now)
    command_json: string
    enrich_err: Bridge_Error
    enrich_ok: bool
    use_start_begin := delivery_id != "" || sync.atomic_load(&bridge_hub_start_begin_supported)
    if use_start_begin {
        delete(command_id)
        command_json, command_id, enrich_err, enrich_ok = bridge_wake_start_begin_proc(instance_id, delivery_id if delivery_id != "" else ref, deadline_ns)
    } else {
        command_json, enrich_err, enrich_ok = bridge_wake_manifest_proc(instance_id, command_id, deadline_ns)
    }
    defer delete(command_id)
    defer delete(command_json)
    if use_start_begin && !enrich_ok && bridge_wake_is_live_row(enrich_err) {
        snap, found := bridge_wake_snapshot_proc(instance_id)
        if bridge_wake_probe_proc(instance_id).state == "alive" && (!found || snap.stopped_intent_unix_ms == 0) {
            sync.mutex_lock(&bridge_wake_mutex)
            if current, has := &bridge_agent_wake[instance_id]; has && current.generation == generation do current.live_row_retry_at_ms = 0
            sync.mutex_unlock(&bridge_wake_mutex)
            return {.Already_Active, {}, 0}
        }
        if delivery_id != "" do return {.Failed, enrich_err, BRIDGE_LIVE_ROW_RETRY_MS}
        sync.mutex_lock(&bridge_wake_mutex)
        current, has := &bridge_agent_wake[instance_id]
        scheduled := has && current.generation == generation && current.live_row_retries < BRIDGE_LIVE_ROW_RETRIES
        if scheduled {
            current.live_row_retries += 1
            current.live_row_retry_at_ms = now + BRIDGE_LIVE_ROW_RETRY_MS
        }
        sync.mutex_unlock(&bridge_wake_mutex)
        if scheduled do return {.Failed, enrich_err, BRIDGE_LIVE_ROW_RETRY_MS}
        enrich_err.retry_after_ms = 0
    }
	ok, detail, err := false, "", enrich_err
	if enrich_ok {
		ok, detail, err = bridge_wake_launch_proc(command_id, command_json, deadline_ns)
	} else {
		detail = "could not fetch start-begin launch" if use_start_begin else "could not fetch enriched descriptor (agent_id)"
	}
	bridge_task_wake_record_result(instance_id, generation, ok, detail, err, command_json, now)
	retry := err.retry_after_ms
    sync.mutex_lock(&bridge_wake_mutex)
    if state, found := bridge_agent_wake[instance_id]; found do retry = max(retry, state.next_at_ms - now)
    sync.mutex_unlock(&bridge_wake_mutex)
    return {.Launched if ok else .Failed, err, max(0, retry)}
}

// bridge_task_wake_record_result applies a wake outcome and logs only state
// TRANSITIONS (first failure / each backoff step, parked, recovered), never one
// line per tick.
// A result whose `generation` is stale (a launch succeeded while this attempt was
// in flight) is dropped.
bridge_task_wake_record_result :: proc(instance_id: string, generation: u64, ok: bool, detail: string, err: Bridge_Error, command_json: string, now: i64) {
	sync.mutex_lock(&bridge_wake_mutex)
	defer sync.mutex_unlock(&bridge_wake_mutex)
	st, has := &bridge_agent_wake[instance_id]
	if !has || st.generation != generation do return
	transition := bridge_wake_record(st, ok, err, now, rand.uint64())
	if st.parked {
		// Snapshot the trigger baselines on EVERY parked failure, including a failed
		// unpark attempt: otherwise a changed catalog etag would re-trigger each tick.
		bridge_wake_state_free(st)
		etag := bridge_provider_catalog_current_etag()
        st.catalog_etag = strings.clone(etag, bridge_wake_owned_allocator())
        delete(etag)
        provider, model := bridge_runtime_provider_model(command_json)
        st.provider, st.model = strings.clone(provider, bridge_wake_owned_allocator()), strings.clone(model, bridge_wake_owned_allocator())
        delete(provider); delete(model)
	}
	switch transition {
	case .None:
	case .Recovered:
		fmt.println("bridge wake RECOVERED", instance_id)
	case .Backoff:
		fmt.printfln("bridge wake failed %s %s: %s; retry %d in %ds", instance_id, detail, bridge_error_string(err), st.failures, (st.next_at_ms - now) / 1000)
	case .Parked:
		fmt.printfln("bridge wake PARKED %s %s: %s; no timer retries until a resume trigger", instance_id, detail, bridge_error_string(err))
	}
}

// bridge_wake_fetch_enriched_launch_json builds a fully-enriched launch_agent
// command for the wake path (REQ-37 B1). The wake path only knows the
// instance_id locally (the bridge launch record + runtime snapshot carry no
// agent_id/chain data), so it GETs the hub instance bootstrap endpoint, which
// returns the per-instance descriptor (agent_id, agent_name, role, chain_id,
// chain_title, coordinator, project). Those are forwarded into the synthetic launch
// payload so the launch takes the full agent-keyed template bootstrap instead of the
// header-only fallback. Returns ("", err, false) when the hub is unreachable
// (retriable), rejects the fetch (classified by HTTP status) or the descriptor lacks
// agent_id (recoverable), so the caller fails the wake with that class rather than
// materialize a degraded, header-only CLAUDE.md. Transient extracted strings
// follow the same no-free convention as bridge_hub_handle_wake_agent.
bridge_wake_fetch_enriched_launch_json :: proc(instance_id, command_id: string, deadline_ns: i64 = 0, use_manifest_run_count := false) -> (string, Bridge_Error, bool) {
	credential_snapshot_298 := bridge_credential_snapshot()
	defer delete(credential_snapshot_298)
	if strings.trim_space(bridge_config.daemon_url) == "" || strings.trim_space(credential_snapshot_298) == "" do return "", bridge_error(.hub_connect_failed, .config), false
	credential_snapshot_301 := bridge_credential_snapshot()
	defer delete(credential_snapshot_301)
	headers := [?]httpc.Header{httpc.bearer(credential_snapshot_301)}
	req := httpc.Request{
		method = .GET, url = bridge_hub_url(), path = {"api", "v1", "bridge", "agent-instances", instance_id, "bootstrap"},
		query = {{"format", "manifest"}}, headers = headers[:],
	}
	resp: httpc.Response
    http_err: httpc.Error
    if deadline_ns != 0 {
        left := (deadline_ns - time.to_unix_nanoseconds(time.now())) / i64(time.Millisecond)
        if left <= 0 do return "", bridge_error(.hub_connect_failed, .transport), false
        req.timeout_ms = int(min(10_000, left))
        resp, http_err = bridge_wake_http_proc(req)
    } else {
        resp, http_err = bridge_http_request_retry(req, fetch = bridge_wake_http_proc)
    }
	defer httpc.response_destroy(&resp)
	ok := http_err == .None
	if !ok || resp.status != 200 {
		if !ok || resp.status == 0 do return "", bridge_error(.hub_connect_failed, .transport), false
		return "", bridge_error(.hub_rejected, .other, resp.status), false
	}
    // The legacy object extractor serializes a new caller-owned string.
	data_obj, data_ok := bridge_provider_json_extract_object(httpc.text(resp), "data")
    defer delete(data_obj)
	if !data_ok do return "", bridge_error(.agent_bootstrap_invalid), false
	inst_obj, inst_ok := bridge_provider_json_extract_object(data_obj, "instance")
    defer delete(inst_obj)
	if !inst_ok do return "", bridge_error(.agent_bootstrap_invalid), false
	agent_id := extract_json_string(inst_obj, "agent_id", "")
    defer delete(agent_id)
	if strings.trim_space(agent_id) == "" do return "", bridge_error(.agent_bootstrap_invalid), false
	agent_name     := extract_json_string(inst_obj, "agent_name", "")
	role           := extract_json_string(inst_obj, "role", "")
	chain_id       := extract_json_string(inst_obj, "chain_id", "")
	chain_title    := extract_json_string(inst_obj, "chain_title", "")
	coordinator_id           := extract_json_string(inst_obj, "coordinator_agent_instance_id", "")
	coordinator_display_name := extract_json_string(inst_obj, "coordinator_display_name", "")
	project_id               := extract_json_string(inst_obj, "project_id", "")
	project_path             := extract_json_string(inst_obj, "project_path", "")
    defer {
        for value in ([]string{agent_name, role, chain_id, chain_title, coordinator_id, coordinator_display_name, project_id, project_path}) do delete(value)
    }
	// REQ-ERR-6: provider/model come from the descriptor. The launch path has no
	// fallback for them, so an older hub that omits them still yields
	// provider_missing, which now parks the wake instead of looping. task_id stays
	// unknown: the agent resolves its current task after boot via reconcile.
	provider := extract_json_string(inst_obj, "provider", "")
	defer delete(provider)
	model    := extract_json_string(inst_obj, "model", "")
	defer delete(model)
	provider_profile:=extract_json_string(inst_obj,"provider_profile","");defer delete(provider_profile)
	permission_mode := extract_json_string(inst_obj, "permission_mode", "")
	defer delete(permission_mode)
	effective_transport := extract_json_string(inst_obj, "effective_transport", "pty")
	catalog_etag := extract_json_string(inst_obj, "catalog_etag", "")
	launch_epoch := extract_json_string(inst_obj, "launch_epoch", "")
	defer delete(effective_transport)
	defer delete(catalog_etag)
	defer delete(launch_epoch)
	run_count := 0
	if use_manifest_run_count do run_count, _ = bridge_provider_json_extract_int(inst_obj, "run_count")
	return bridge_wake_launch_command_json(command_id, instance_id, "", role, provider, model, agent_id, agent_name, chain_id, chain_title, coordinator_id, project_id, project_path, coordinator_display_name, "", "", permission_mode,run_count=run_count,provider_profile=provider_profile,effective_transport=effective_transport,catalog_etag=catalog_etag,launch_epoch=launch_epoch, bot_idle_restart=use_manifest_run_count && extract_json_bool(inst_obj, "bot_idle_restart", false)), {}, true
}

// Start-begin returns a hub-authored launch object; do not rebuild its fields.
bridge_wake_start_begin :: proc(instance_id, ref: string, deadline_ns: i64 = 0) -> (launch_json, command_id: string, err: Bridge_Error, ok: bool) {
    if !sync.atomic_load(&bridge_hub_start_begin_supported) {
        e := bridge_error(.hub_rejected, .other, 400); e.class = .fatal
        return "", "", e, false
    }
    credential := bridge_credential_snapshot()
    defer delete(credential)
    if strings.trim_space(bridge_config.daemon_url) == "" || strings.trim_space(credential) == "" {
        return "", "", bridge_error(.hub_connect_failed, .transport), false
    }
    body, _ := json.marshal(struct {ref: string}{ref})
    defer delete(body)
    headers := [?]httpc.Header{httpc.bearer(credential)}
    req := httpc.Request{method = .POST, url = bridge_hub_url(),
        path = {"api", "v1", "bridge", "agent-instances", instance_id, "start-begin"},
        headers = headers[:], body = httpc.raw_body(httpc.CONTENT_TYPE_JSON, body)}
    resp: httpc.Response
    http_err: httpc.Error
    if deadline_ns != 0 {
        left := (deadline_ns - time.to_unix_nanoseconds(time.now())) / i64(time.Millisecond)
        if left <= 0 do return "", "", bridge_error(.hub_connect_failed, .transport), false
        req.timeout_ms = int(min(10_000, left))
        resp, http_err = bridge_wake_http_proc(req)
    } else {
        resp, http_err = bridge_http_request_retry(req, fetch = bridge_wake_http_proc)
    }
    defer httpc.response_destroy(&resp)
    if http_err != .None || resp.status == 0 do return "", "", bridge_error(.hub_connect_failed, .transport), false
    if resp.status != 200 {
        e := bridge_error(.hub_rejected, .other, resp.status)
        value: json.Value
        parse_err := json.unmarshal(resp.body, &value, allocator = context.temp_allocator)
        already_running := bridge_wake_error_is_live(value)
        e.class = .fatal
        if resp.status == 409 || resp.status == 423 || resp.status == 401 || resp.status == 403 || resp.status == 429 || resp.status >= 500 do e.class = .retriable
        if resp.status == 409 && already_running do e.retry_after_ms = BRIDGE_LIVE_ROW_RETRY_MS
        if resp.status == 404 {
            obj, has := bridge_wake_object_text(httpc.text(resp), "error")
            if parse_err != nil || !has || extract_json_string(obj, "code", "", context.temp_allocator) == "" do e.class = .retriable
        }
        return "", "", e, false
    }
    value: json.Value
    if json.unmarshal(resp.body, &value, allocator = context.temp_allocator) != nil {
        e := bridge_error(.hub_rejected, .other, 200); e.class = .fatal
        return "", "", e, false
    }
    data, data_ok := bridge_wake_object_text(httpc.text(resp), "data")
    launch, launch_ok := bridge_wake_object_text(data, "launch")
    if !data_ok || !launch_ok {
        e := bridge_error(.hub_rejected, .other, 200); e.class = .fatal
        return "", "", e, false
    }
    id := extract_json_string(launch, "command_id", "")
    if id == "" || extract_json_int(launch, "run_count", 0) <= 0 {
        delete(id)
        e := bridge_error(.hub_rejected, .other, 200); e.class = .fatal
        return "", "", e, false
    }
    return strings.clone(launch), id, {}, true
}

// Search details at any depth; the outer error.code is usually "conflict".
bridge_wake_error_is_live :: proc(value: json.Value) -> bool {
    #partial switch v in value {
    case json.Object:
        for key, item in v {
            if text, ok := item.(json.String); ok && key == "code" && string(text) == "already_running" do return true
            if bridge_wake_error_is_live(item) do return true
        }
    case json.Array:
        for item in v do if bridge_wake_error_is_live(item) do return true
    }
    return false
}


// Returns a view of an object field without reserializing it. The enclosing
// response is JSON-validated first. Strings and nested containers are skipped
// lexically, preserving whitespace, member order and escaped launch values.
bridge_wake_object_text :: proc(body, key: string) -> (string, bool) {
    depth := 0
    i := 0
    for i < len(body) {
        ch := body[i]
        if ch == '"' {
            begin := i
            i += 1
            for i < len(body) {
                if body[i] == '\\' { i += 2; continue }
                if body[i] == '"' do break
                i += 1
            }
            if i >= len(body) do return "", false
            end := i
            i += 1
            if depth != 1 do continue
            j := i
            for j < len(body) && (body[j] == ' ' || body[j] == 10 || body[j] == 13 || body[j] == 9) do j += 1
            if j >= len(body) || body[j] != ':' do continue
            field: string
            if json.unmarshal_string(body[begin:end+1], &field, allocator = context.temp_allocator) != nil || field != key do continue
            j += 1
            for j < len(body) && (body[j] == ' ' || body[j] == 10 || body[j] == 13 || body[j] == 9) do j += 1
            if j >= len(body) || body[j] != '{' do return "", false
            start := j
            nested := 0
            quoted := false
            for j < len(body) {
                c := body[j]
                if quoted {
                    if c == '\\' { j += 2; continue }
                    if c == '"' do quoted = false
                } else {
                    if c == '"' { quoted = true }
                    else if c == '{' { nested += 1 }
                    else if c == '}' {
                        nested -= 1
                        if nested == 0 do return body[start:j+1], true
                    }
                }
                j += 1
            }
            return "", false
        }
        if ch == '{' || ch == '[' do depth += 1
        if ch == '}' || ch == ']' do depth -= 1
        i += 1
    }
    return "", false
}

bridge_wake_ref_counter: i64
bridge_wake_is_live_row :: proc(err: Bridge_Error) -> bool {
    return err.hub_status == 409 && err.retry_after_ms == BRIDGE_LIVE_ROW_RETRY_MS
}

// One worker for all fallback retries. The WS loop only signals it: HTTP and
// process launch never block the reader. No thread or sleep per retry.
bridge_wake_retry_cond: sync.Cond
bridge_wake_retry_mu: sync.Mutex
bridge_wake_retry_requested, bridge_wake_retry_stopping: bool
bridge_wake_retry_tick :: proc(now: i64) {
    bridge_agent_wake_init()
    due := false
    sync.mutex_lock(&bridge_wake_mutex)
    for _, st in bridge_agent_wake {
        if st.live_row_retry_at_ms != 0 && st.live_row_retry_at_ms <= now { due = true; break }
    }
    sync.mutex_unlock(&bridge_wake_mutex)
    if !due do return
    sync.mutex_lock(&bridge_wake_retry_mu)
    bridge_wake_retry_requested = true
    sync.cond_signal(&bridge_wake_retry_cond)
    sync.mutex_unlock(&bridge_wake_retry_mu)
}
bridge_wake_retry_due :: proc(now: i64) {
    Pending :: struct {instance, ref: string}
    pending := make([dynamic]Pending)
    defer { for p in pending { delete(p.instance); delete(p.ref) }; delete(pending) }
    sync.mutex_lock(&bridge_wake_mutex)
    for id, st in bridge_agent_wake {
        if st.live_row_retry_at_ms != 0 && st.live_row_retry_at_ms <= now {
            append(&pending, Pending{strings.clone(id), strings.clone(st.ref)})
        }
    }
    sync.mutex_unlock(&bridge_wake_mutex)
    for p in pending do _ = bridge_wake_attempt(p.instance, now, pending_ref = p.ref)
}
bridge_wake_retry_worker :: proc() {
    arena: virtual.Arena
    if virtual.arena_init_growing(&arena) != nil do return
    defer virtual.arena_destroy(&arena)
    // The launcher retains default-allocator token records and runtime state.
    // Only parsing/scratch storage may be reset after each worker pass.
    context.allocator = runtime.heap_allocator()
    context.temp_allocator = virtual.arena_allocator(&arena)
    for {
        sync.mutex_lock(&bridge_wake_retry_mu)
        for !bridge_wake_retry_requested && !bridge_wake_retry_stopping do sync.cond_wait(&bridge_wake_retry_cond, &bridge_wake_retry_mu)
        stop := bridge_wake_retry_stopping
        bridge_wake_retry_requested = false
        sync.mutex_unlock(&bridge_wake_retry_mu)
        if stop do return
        bridge_wake_retry_due(bridge_runtime_now_ms())
        free_all(context.temp_allocator)
    }
}
bridge_wake_retry_start :: proc() -> ^thread.Thread {
    bridge_agent_wake_init()
    sync.mutex_lock(&bridge_wake_retry_mu)
    bridge_wake_retry_stopping, bridge_wake_retry_requested = false, false
    sync.mutex_unlock(&bridge_wake_retry_mu)
    context.allocator = runtime.heap_allocator()
    return thread.create_and_start(bridge_wake_retry_worker)
}
bridge_wake_retry_stop :: proc(worker: ^thread.Thread) {
    sync.mutex_lock(&bridge_wake_retry_mu)
    bridge_wake_retry_stopping = true
    sync.cond_signal(&bridge_wake_retry_cond)
    sync.mutex_unlock(&bridge_wake_retry_mu)
    if worker != nil { thread.join(worker); thread.destroy(worker) }
    sync.mutex_lock(&bridge_wake_mutex)
    for _, &st in bridge_agent_wake do st.live_row_retry_at_ms = 0
    sync.mutex_unlock(&bridge_wake_mutex)
}

// Bot starts share the bridge-initiated launcher boundary and retain bot admission.
bridge_bot_runtime_launch :: proc(command_id, command_json: string, deadline_ns: i64) -> (bool, string, Bridge_Error) {
    return bridge_runtime_launch_agent(command_id, command_json, deadline_ns, bot_delivery = true)
}
