package main

import "base:runtime"
import "core:encoding/json"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import contracts "odin_test:contracts"
import agent_runtime "odin_test:lib/agent_runtime"

@(private = "file") startup_test_deliveries: int
@(private = "file") startup_test_relays: int
@(private = "file") startup_test_delivery_ok: bool
@(private = "file") startup_test_relay_ok: bool

@(private = "file")
startup_test_launch :: proc(id, token: string, now: i64 = 1000, expected := true) -> Bridge_Local_Agent_Token_Record {
	context.allocator = runtime.heap_allocator()
	rec := Bridge_Local_Agent_Token_Record{agent_instance_id = id, token_hash = token, instance_token = token, role = .Agent, issued_at_unix_ms = now}
	sync.mutex_lock(&bridge_local_token_mutex)
	// Token-store roundtrip tests replace this process-global container using
	// their own tracking allocator. Give this hermetic launch a heap-owned store
	// instead of appending to a container whose test context has already ended.
	bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record)
	append(&bridge_local_token_records, rec)
	sync.mutex_unlock(&bridge_local_token_mutex)
	sync.mutex_lock(&bridge_runtime_mutex)
	bridge_startup_begin_locked(rec, now)
	for &inst in bridge_runtime_instances {
		if inst.agent_instance_id == id {
			inst.startup.armed_at_ms = now
			inst.startup.extension_expected = expected
			inst.pty_process_alive = true
		}
	}
	sync.mutex_unlock(&bridge_runtime_mutex)
	bridge_retry_journal = {}
	startup_test_deliveries = 0
	startup_test_relays = 0
	startup_test_delivery_ok = true
	startup_test_relay_ok = true
	return rec
}

@(private = "file")
startup_test_deliver :: proc(id: string, timeout_ms: int) -> bool {
	// Taking both registry locks here proves tick releases them around I/O.
	sync.mutex_lock(&bridge_runtime_mutex); sync.mutex_unlock(&bridge_runtime_mutex)
	sync.mutex_lock(&bridge_ext_mutex); sync.mutex_unlock(&bridge_ext_mutex)
	startup_test_deliveries += 1
	return startup_test_delivery_ok
}

@(private = "file")
startup_test_relay :: proc(rec: Bridge_Local_Agent_Token_Record, timeout_ms: int) -> Bridge_Startup_Relay_Result {
	sync.mutex_lock(&bridge_runtime_mutex); sync.mutex_unlock(&bridge_runtime_mutex)
	startup_test_relays += 1
	return {ok = startup_test_relay_ok, error = contracts.wire_error(.Bridge_Timeout)}
}

@(private = "file")
startup_test_tick :: proc(id: string, now: i64) {
	bridge_startup_tick(now, startup_test_relay, startup_test_deliver, id)
}

@(private = "file")
startup_test_event :: proc(event: string, extra := "") -> string {
	return strings.concatenate({`{"schema":"ham.ext.v1","provider":"future-provider","ext_version":"1.0","event":"`, event, `","session_id":"s"`, extra, `}`}, context.temp_allocator)
}

@(test)
startup_activation_is_catalog_driven :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = context.temp_allocator
	provider: Bridge_Catalog_Provider
	err := json.unmarshal_string(`{"provider":"future-provider","base_args":["--load","/repo/extensions/native"],"starter_prompt":"First, run: {ctl_bin} agent start-success. Then read AGENTS.md for context.","extension":{"load_args":["--load"],"load_path_suffix":"extensions/native"}}`, &provider)
	testing.expect(t, err == nil)
	profile := bridge_provider_profile_from_catalog(provider)
	testing.expect(t, bridge_provider_extension_expected(profile, "absent"), "explicit catalog loader predicts extension")
	profile.base_args = nil
	testing.expect(t, bridge_provider_extension_expected(profile, "present"), "discovered present extension predicts startup")
	for state in ([]string{"", "unknown", "absent", "disabled", "outdated", "error", "unsupported"}) {
		testing.expect(t, !bridge_provider_extension_expected(profile, state), "no activation evidence keeps startup instruction")
	}
	profile.extension_expected = true
	out := agent_runtime.render_starter_prompt_for_agent(bridge_agent_runtime_profile(profile), "", "tok", "inst")
	testing.expect(t, !strings.contains(out, "start-success") && strings.contains(out, "AGENTS.md"), "expectation reaches runtime profile")
}

@(test)
startup_activation_rejects_unrelated_or_partial_arguments :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	profile := Bridge_Provider_Profile{extension = Bridge_Catalog_Extension{load_args = []string{"--load"}, load_path_suffix = "extensions/native"}}
	cases := [][]string{
		{"--loader", "/repo/extensions/native"}, {"prefix--load", "/repo/extensions/native"},
		{"--load=/repo/extensions/native"}, {"--load"}, {"--load", ""},
		{"--load", "/repo/extensions/other"}, {"--load", "/repo/extensions/native-other"},
		{"--load", "/repo/myextensions/native"},
	}
	for args in cases {
		profile.base_args = args
		testing.expect(t, !bridge_provider_extension_expected(profile, "absent"), "exact loader/path components required")
	}
	profile.extension = {}
	profile.base_args = []string{"--load", "/repo/extensions/native"}
	testing.expect(t, !bridge_provider_extension_expected(profile, "absent"), "old catalog stays conservative")
}

@(test)
startup_profile_reaches_pty_argv_and_launch_fence :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = context.temp_allocator
	profile := Bridge_Provider_Profile{
		name = "startup-profile", command = []string{"/fake/provider"}, model_flag = "--model",
		prompt_delivery = "flag-injection", prompt_flags = []string{"--prompt"},
		starter_prompt = "First, run: {ctl_bin} agent start-success. Then read AGENTS.md for context.",
		extension_expected = true,
	}
	req, ok := bridge_pty_host_build_spawn_for_profile("startup_profile_spawn", "/managed/run", profile, "model", "agent-secret", []string{"A=B"})
	if !testing.expect(t, ok) do return
	defer bridge_pty_host_untrack_instance_provider("startup_profile_spawn")
	prompt := req.argv[len(req.argv) - 1]
	testing.expect(t, strings.contains(prompt, "AGENTS.md") && strings.contains(prompt, "HEIMDALL_AGENT_TOKEN"), "bootstrap/runtime text reaches PTY spawn")
	testing.expect(t, !strings.contains(prompt, "start-success"), "expected extension omits startup instruction in actual argv")
	key := bridge_local_hash_token("agent-secret")
	saw_key, saw_original_env := false, false
	for pair in req.env {
		if pair[0] == "HEIMDALL_STARTUP_KEY" do saw_key = pair[1] == key
		if pair[0] == "A" && pair[1] == "B" do saw_original_env = true
	}
	testing.expect(t, saw_key && saw_original_env, "launch fence augments existing spawn environment")
	profile.extension_expected = false
	legacy, legacy_ok := bridge_pty_host_build_spawn_for_profile("startup_profile_legacy", "/managed/run", profile, "model", "agent-secret", nil)
	defer bridge_pty_host_untrack_instance_provider("startup_profile_legacy")
	testing.expect(t, legacy_ok && strings.contains(legacy.argv[len(legacy.argv) - 1], "ham-ctl agent start-success"), "unknown extension retains command through PTY spawn")
}

@(test)
startup_wake_launch_preserves_generation_and_legacy_default :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = context.temp_allocator
	command := bridge_wake_launch_command_json("cmd", "inst", "task", "worker", "future", "model", "agent", "name", "chain", "title", "coordinator", "project", "/project", run_count = 4)
	count, found := bridge_provider_json_extract_int(command, "run_count")
	testing.expect(t, found && count == 4, "wake synthetic launch carries hub generation")
	legacy := bridge_wake_launch_command_json("cmd", "inst", "task", "worker", "future", "model", "agent", "name", "chain", "title", "coordinator", "project", "/project")
	count, _ = bridge_provider_json_extract_int(legacy, "run_count")
	testing.expect_value(t, count, 0)
}

@(test)
startup_only_main_hello_or_session_start :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	cases := []struct {event, extra: string, want: bool}{
		{"hello", "", true}, {"session", `,"payload":{"phase":"start"}`, true},
		{"session", `,"payload":{"phase":"end"}`, false}, {"session", "", false},
		{"activity", `,"payload":{"state":"active"}`, false}, {"subagent.start", "", false},
		{"hello", `,"agent":{"id":"sub","type":"Explore"}`, false},
		{"hello", `,"agent":{"type":"unknown"}`, false},
		{"session", `,"agent":{"id":"sub"},"payload":{"phase":"start"}`, false},
	}
	for c in cases {
		ev, err := contracts.ext_parse_event(startup_test_event(c.event, c.extra))
		testing.expect_value(t, err, contracts.Ext_Error.None)
		testing.expect_value(t, bridge_startup_event(ev), c.want)
		contracts.ext_event_destroy(&ev)
	}
	ev, _ := contracts.ext_parse_event(`{"schema":"ham.ext.v1","provider":"x","event":"hello"}`)
	testing.expect(t, !bridge_startup_event(ev), "unknown session cannot establish startup")
	contracts.ext_event_destroy(&ev)
}

@(test)
startup_both_events_and_cli_share_one_ready_relay :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	for event, i in ([]string{"hello", "session"}) {
		id := "startup_both_hello" if i == 0 else "startup_both_session"
		rec := startup_test_launch(id, id)
		bridge_runtime_set_pty_process_alive(id, false)
		extra := "" if event == "hello" else `,"payload":{"phase":"start"}`
		result := bridge_ext_ingest(rec, startup_test_event(event, extra), 1001)
		testing.expect_value(t, result.accepted, 1)
		bridge_ext_ingest_result_destroy(&result)
		snap, _ := bridge_runtime_instance_snapshot(id)
		testing.expect(t, snap.start_success_seen && snap.runtime_status == "running", "event before spawn reply establishes readiness")
		accepted, first := bridge_startup_accept(rec, 1002)
		testing.expect(t, accepted && !first, "explicit CLI duplicate is idempotent")
		duplicate := bridge_ext_ingest(rec, startup_test_event("hello"), 1003)
		bridge_ext_ingest_result_destroy(&duplicate)
		startup_test_tick(id, 1004)
		startup_test_tick(id, 50000)
		testing.expect_value(t, startup_test_relays, 1)
		testing.expect_value(t, startup_test_deliveries, 0)
	}
}

@(test)
startup_concurrent_cli_hello_session_claim_once :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	rec := startup_test_launch("startup_race", "startup_race")
	Race :: struct { rec: Bridge_Local_Agent_Token_Record, event: string, first: bool }
	races := [3]Race{{rec = rec}, {rec = rec, event = "hello"}, {rec = rec, event = "session"}}
	workers: [3]^thread.Thread
	for &race, i in races {
		workers[i] = bridge_thread_start_with_data(rawptr(&race), proc(data: rawptr) {
			r := (^Race)(data)
			if r.event == "" {
				_, r.first = bridge_startup_accept(r.rec, 1001)
			} else {
				extra := "" if r.event == "hello" else `,"payload":{"phase":"start"}`
				res := bridge_ext_ingest(r.rec, startup_test_event(r.event, extra), 1001)
				bridge_ext_ingest_result_destroy(&res)
			}
		})
	}
	for w in workers { thread.join(w); thread.destroy(w) }
	startup_test_tick(rec.agent_instance_id, 1002)
	testing.expect_value(t, startup_test_relays, 1)
}

@(test)
startup_fallback_quiet_missing_or_broken_extension :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	for expected, i in ([]bool{false, true}) {
		id := "startup_missing" if i == 0 else "startup_broken"
		_ = startup_test_launch(id, id, 1000, expected)
		startup_test_tick(id, 30999)
		testing.expect_value(t, startup_test_deliveries, 0)
		startup_test_delivery_ok = false
		startup_test_tick(id, 31000)
		snap, _ := bridge_runtime_instance_snapshot(id)
		testing.expect(t, !snap.startup.fallback_delivered, "failed delivery remains retryable")
		startup_test_delivery_ok = true
		startup_test_tick(id, 31500)
		testing.expect_value(t, startup_test_deliveries, 1)
		startup_test_tick(id, 32000)
		startup_test_tick(id, 95000)
		testing.expect_value(t, startup_test_deliveries, 2)
		snap, _ = bridge_runtime_instance_snapshot(id)
		testing.expect(t, snap.startup.fallback_delivered, "successful delivery happens once")
		input := bridge_startup_fallback_input(id)
		testing.expect(t, strings.contains(input, "ham-ctl agent start-success") && strings.has_suffix(input, "\r"), "actual PTY input includes command and submit")
		delete(input)
	}
}

@(test)
startup_producer_serializes_physical_write_and_releases_network_relay :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    saved_id:=bridge_cfg().daemon_id
    bridge_cfg().daemon_id="" // Pre-enrollment fixture, never a coverage claim.
    defer bridge_cfg().daemon_id=saved_id
    id:="startup_gate_order"
    rec:=startup_test_launch(id,id)
    bridge_startup_tick(31000,deliver=proc(_:string,_:int)->bool {
        all_held:=true
        for gate in ([]^sync.Mutex{&bridge_executor_mutex,&bridge_startup_io_mutex,&bridge_legacy_physical_mutex}) {
            if sync.mutex_try_lock(gate) {all_held=false;sync.mutex_unlock(gate)}
        }
        reader_free:=sync.mutex_try_lock(&bridge_dispatch_mu)
        if reader_free do sync.mutex_unlock(&bridge_dispatch_mu)
        return all_held && reader_free
    },only_instance=id,kind=.Fallback)
    fallback,_:=bridge_runtime_instance_snapshot(id)
    testing.expect(t,fallback.startup.fallback_delivered,"physical delivery holds the established gate order while leaving dispatcher reader free")
    accepted,_:=bridge_startup_accept(rec,32000)
    testing.expect(t,accepted)
    bridge_startup_tick(32001,relay=proc(_:Bridge_Local_Agent_Token_Record,_:int)->Bridge_Startup_Relay_Result {
        all_free:=true
        for gate in ([]^sync.Mutex{&bridge_executor_mutex,&bridge_startup_io_mutex,&bridge_legacy_physical_mutex}) {
            if sync.mutex_try_lock(gate) {sync.mutex_unlock(gate)} else {all_free=false}
        }
        return {ok=all_free,error=contracts.wire_error(.Bridge_Timeout)}
    },only_instance=id,kind=.Readiness)
    ready,_:=bridge_runtime_instance_snapshot(id)
    testing.expect(t,ready.startup.ready_delivered,"readiness network callback holds none of the application/startup/physical gates")
}

@(test)
startup_relay_failure_retries_without_fallback :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	rec := startup_test_launch("startup_relay_retry", "startup_relay_retry")
	_, _ = bridge_startup_accept(rec, 1001)
	startup_test_relay_ok = false
	startup_test_tick(rec.agent_instance_id, 1002)
	startup_test_relay_ok = true
	startup_test_tick(rec.agent_instance_id, 1500)
	testing.expect_value(t, startup_test_relays, 1)
	startup_test_tick(rec.agent_instance_id, 2002)
	startup_test_tick(rec.agent_instance_id, 50000)
	testing.expect_value(t, startup_test_relays, 2)
	testing.expect_value(t, startup_test_deliveries, 0)
}

@(test)
startup_stop_relaunch_and_revocation_are_fenced :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	old := startup_test_launch("startup_replace", "startup_old")
	bridge_runtime_mark_stop_intent(old.agent_instance_id)
	bridge_runtime_set_status(old.agent_instance_id, "stopped", "idle")
	valid, _ := bridge_startup_accept(old, 20000)
	testing.expect(t, !valid, "late startup after stop cannot resurrect")
	startup_test_tick(old.agent_instance_id, 32000)
	testing.expect_value(t, startup_test_deliveries, 0)
	current := startup_test_launch(old.agent_instance_id, "startup_new", 50000)
	valid, _ = bridge_startup_accept(old, 50001)
	testing.expect(t, !valid, "already-authenticated old request is rejected after launch reset")
	startup_test_tick(current.agent_instance_id, 79999)
	testing.expect_value(t, startup_test_deliveries, 0)
	startup_test_tick(current.agent_instance_id, 80000)
	testing.expect_value(t, startup_test_deliveries, 1)
	sync.mutex_lock(&bridge_local_token_mutex)
	for &rec in bridge_local_token_records {
		if rec.token_hash == current.token_hash do rec.invalidated_at_unix_ms = 80001
	}
	sync.mutex_unlock(&bridge_local_token_mutex)
	valid, _ = bridge_startup_accept(current, 80002)
	testing.expect(t, !valid, "revoked token rejected even after endpoint authentication")
}

@(test)
startup_watchdog_still_expires_after_fallback :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	rec := startup_test_launch("startup_watchdog", "startup_watchdog")
	startup_test_tick(rec.agent_instance_id, 31000)
	testing.expect_value(t, startup_test_deliveries, 1)
	sync.mutex_lock(&bridge_runtime_mutex)
	for &inst in bridge_runtime_instances {
		if inst.agent_instance_id == rec.agent_instance_id do inst.last_seen_unix_ms = 121000
	}
	bridge_runtime_expire_stale_locked(121000)
	sync.mutex_unlock(&bridge_runtime_mutex)
	// task_18e70f303f8384fe: the process is alive, so the watchdog keeps it
	// running (never an orphaned 'failed' live agent) and injects nothing more.
	snap, _ := bridge_runtime_instance_snapshot(rec.agent_instance_id)
	testing.expect_value(t, snap.runtime_status, "running")
	startup_test_tick(rec.agent_instance_id, 121001)
	testing.expect_value(t, startup_test_deliveries, 1)
	// A launch whose process is gone still expires to failed.
	dead := startup_test_launch("startup_watchdog_dead", "startup_watchdog_dead")
	startup_test_tick(dead.agent_instance_id, 31000)
	sync.mutex_lock(&bridge_runtime_mutex)
	for &inst in bridge_runtime_instances {
		if inst.agent_instance_id == dead.agent_instance_id { inst.last_seen_unix_ms = 121000; inst.pty_process_alive = false }
	}
	bridge_runtime_expire_stale_locked(121000)
	sync.mutex_unlock(&bridge_runtime_mutex)
	gone, _ := bridge_runtime_instance_snapshot(dead.agent_instance_id)
	testing.expect_value(t, gone.runtime_status, "failed")
}

@(test)
startup_exhausted_relay_rearms_in_background :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    rec := startup_test_launch("startup_finite", "startup_finite")
    accepted, _ := bridge_startup_accept(rec, 1001)
    testing.expect(t, accepted)
    startup_test_relay_ok = false
    for now: i64 = 1002; now < 3_601_002; now += 1000 {
        // Duplicate signals neither reset the budget nor add relays.
        bridge_startup_accept(rec, now)
        startup_test_tick(rec.agent_instance_id, now)
    }
    // An exhausted budget is re-armed after a cool-down, never parked: the
    // relay keeps retrying in the background at a bounded rate.
    testing.expect(t, startup_test_relays > 6, "exhausted relay is re-armed")
    testing.expect(t, startup_test_relays <= 6 * (3_600_000 / BRIDGE_START_SUCCESS_REARM_MS + 1), "re-arm respects the cool-down")
    key := bridge_startup_receipt_key(rec)
    defer delete(key)
    state := bridge_retry_status(key).state
    testing.expect(t, state != .Waiting_Repair && state != .Exhausted, "relay is never left terminal")
    startup_test_relay_ok = true
    for now: i64 = 3_601_002; now < 3_800_002; now += 1000 do startup_test_tick(rec.agent_instance_id, now)
    snap, _ := bridge_runtime_instance_snapshot(rec.agent_instance_id)
    testing.expect(t, snap.startup.ready_delivered, "a recovered hub receives readiness")
    rotated := rec
    rotated.token_hash = "rotated-local-token"
    testing.expect_value(t, bridge_startup_receipt_key(rotated), key)
}

startup_test_failure_class: contracts.Bridge_Error_Class
startup_typed_reject :: proc(rec: Bridge_Local_Agent_Token_Record, timeout_ms: int) -> Bridge_Startup_Relay_Result {
    startup_test_relays += 1
    err := contracts.wire_error(.Conflict)
    err.class = startup_test_failure_class
    return {error = err}
}
startup_stop_before_response :: proc(rec: Bridge_Local_Agent_Token_Record, timeout_ms: int) -> Bridge_Startup_Relay_Result {
    startup_test_relays += 1
    bridge_runtime_mark_stop_intent(rec.agent_instance_id)
    return {ok = true}
}
@(test)
startup_typed_rejection_rearms_slowly_and_late_stop_does_not_complete :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    context.allocator = runtime.heap_allocator()
    for class in ([]contracts.Bridge_Error_Class{.fatal, .recoverable}) {
        rec := startup_test_launch("typed-startup", "typed-startup")
        bridge_startup_accept(rec, 1001)
        startup_test_failure_class = class
        for now: i64 = 1002; now < 3_601_002; now += 1000 {
            bridge_startup_tick(now, startup_typed_reject, startup_test_deliver, rec.agent_instance_id)
        }
        // A typed rejection is not retried on the fast schedule, but it is not
        // parked either: the relay is re-armed after each cool-down.
        testing.expect(t, startup_test_relays > 1 && startup_test_relays <= 3_600_000 / BRIDGE_START_SUCCESS_REARM_MS + 1, "typed rejection is re-armed at the cool-down rate")
        key := bridge_startup_receipt_key(rec)
        testing.expect(t, bridge_retry_status(key).state != .Waiting_Repair, "typed rejection is not parked")
        delete(key)
    }
    rec := startup_test_launch("stopped-startup", "stopped-startup")
    bridge_startup_accept(rec, 1001)
    bridge_startup_tick(1002, startup_stop_before_response, startup_test_deliver, rec.agent_instance_id)
    current, exists := bridge_runtime_instance_snapshot(rec.agent_instance_id)
    testing.expect(t, exists && !current.startup.ready_delivered)
    key := bridge_startup_receipt_key(rec)
    defer delete(key)
    testing.expect_value(t, bridge_retry_status(key).state, Bridge_Operation_State.Cancelled)
}

// A receipt parked by an older Bridge (or a non-retriable reject) is re-armed
// when the agent repeats start_success; stopped launches stay cancelled.
@(test)
startup_parked_relay_is_rearmed_not_reported :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    context.allocator = runtime.heap_allocator()
    rec := startup_test_launch("startup_parked", "startup_parked")
    accepted, _ := bridge_startup_accept(rec, 1001)
    testing.expect(t, accepted)
    key := bridge_startup_receipt_key(rec)
    defer delete(key)
    bridge_retry_reserve(key, 1002)
    bridge_retry_finish(key, 1003, false, contracts.wire_error(.Conflict), park_on_failure = true)
    testing.expect_value(t, bridge_retry_status(key).state, Bridge_Operation_State.Waiting_Repair)
    testing.expect(t, bridge_startup_relay_rearm(rec, 0, 0), "parked relay re-armed")
    testing.expect_value(t, bridge_retry_status(key).state, Bridge_Operation_State.Pending)
    snap, _ := bridge_runtime_instance_snapshot(rec.agent_instance_id)
    testing.expect(t, snap.startup.ready_pending && snap.startup.relay_state == .Pending)
    startup_test_tick(rec.agent_instance_id, 2000)
    testing.expect_value(t, startup_test_relays, 1)
    snap, _ = bridge_runtime_instance_snapshot(rec.agent_instance_id)
    testing.expect(t, snap.startup.ready_delivered, "re-armed relay delivers readiness")

    bridge_retry_cancel(key)
    bridge_runtime_mark_stop_intent(rec.agent_instance_id)
    testing.expect(t, !bridge_startup_relay_rearm(rec, 0, 0), "a stopped launch is not re-armed")
}

// task_18e70e699c82f77b (REQ-E2E-1): a coordinator that never ran
// start-success was failed by the start-success reaper and then refused every
// owner verb ('current launched child required'). Any authenticated agent call
// now counts as readiness, and a launch failed ONLY by that timeout is recovered
// by its own current token while the pty-host still runs that exact launch.
// An exited launch, a stale token and other failures stay failed.
@(test)
startup_any_agent_call_is_readiness_and_recovers_a_timed_out_launch :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	live_launch :: proc(instance, launch_key: string) -> bool { return instance != "startup_implicit_exited" }
	bridge_startup_live_launch_hook = live_launch
	defer bridge_startup_live_launch_hook = nil
	expire :: proc(now: i64) {
		sync.mutex_lock(&bridge_runtime_mutex)
		bridge_runtime_expire_stale_locked(now)
		sync.mutex_unlock(&bridge_runtime_mutex)
	}
	status :: proc(id: string) -> string {
		snap, _ := bridge_runtime_instance_snapshot(id)
		return snap.runtime_status
	}
	// 0. task_18e70f303f8384fe: no start-success but the process is alive at the
	// deadline: kept running (never orphaned as failed), shown as running.
	alive := startup_test_launch("startup_timeout_alive", "startup_timeout_alive")
	sync.mutex_lock(&bridge_runtime_mutex)
	for &inst in bridge_runtime_instances do if inst.agent_instance_id == alive.agent_instance_id { inst.runtime_status = "starting"; inst.start_deadline_unix_ms = 1000 + BRIDGE_START_SUCCESS_TIMEOUT_MS; inst.last_seen_unix_ms = 1000 + BRIDGE_START_SUCCESS_TIMEOUT_MS }
	sync.mutex_unlock(&bridge_runtime_mutex)
	expire(1000 + BRIDGE_START_SUCCESS_TIMEOUT_MS + 1)
	testing.expect_value(t, status(alive.agent_instance_id), "running")
	// 1. Implicit readiness before the deadline: never failed.
	rec := startup_test_launch("startup_implicit_early", "startup_implicit_early")
	bridge_startup_implicit_ready(rec)
	testing.expect_value(t, status(rec.agent_instance_id), "running")
	expire(1000 + BRIDGE_START_SUCCESS_TIMEOUT_MS + 1)
	testing.expect_value(t, status(rec.agent_instance_id), "running")
	// 2. Failed by the timeout, still running its launch: the next call recovers it.
	late := startup_test_launch("startup_implicit_late", "startup_implicit_late")
	sync.mutex_lock(&bridge_runtime_mutex)
	for &inst in bridge_runtime_instances do if inst.agent_instance_id == late.agent_instance_id { inst.runtime_status = "starting"; inst.start_deadline_unix_ms = 1000 + BRIDGE_START_SUCCESS_TIMEOUT_MS; inst.last_seen_unix_ms = 1000 + BRIDGE_START_SUCCESS_TIMEOUT_MS; inst.pty_process_alive = false }
	sync.mutex_unlock(&bridge_runtime_mutex)
	expire(1000 + BRIDGE_START_SUCCESS_TIMEOUT_MS + 1)
	if !testing.expect_value(t, status(late.agent_instance_id), "failed") do return
	bridge_startup_implicit_ready(late)
	testing.expect_value(t, status(late.agent_instance_id), "running")
	// 3. A stale token for the same launch does not recover it.
	stale := startup_test_launch("startup_implicit_stale", "startup_implicit_stale")
	sync.mutex_lock(&bridge_runtime_mutex)
	for &inst in bridge_runtime_instances do if inst.agent_instance_id == stale.agent_instance_id { inst.runtime_status = "starting"; inst.start_deadline_unix_ms = 1000 + BRIDGE_START_SUCCESS_TIMEOUT_MS; inst.last_seen_unix_ms = 1000 + BRIDGE_START_SUCCESS_TIMEOUT_MS; inst.pty_process_alive = false }
	sync.mutex_unlock(&bridge_runtime_mutex)
	expire(1000 + BRIDGE_START_SUCCESS_TIMEOUT_MS + 1)
	wrong := stale
	wrong.token_hash = "another_token"
	accepted, _ := bridge_startup_accept(wrong, 1000 + BRIDGE_START_SUCCESS_TIMEOUT_MS + 2)
	testing.expect(t, !accepted, "a token that is not this launch's is refused")
	testing.expect_value(t, status(stale.agent_instance_id), "failed")
	// 4. The launch's process is gone: stays failed.
	gone := startup_test_launch("startup_implicit_exited", "startup_implicit_exited")
	sync.mutex_lock(&bridge_runtime_mutex)
	for &inst in bridge_runtime_instances do if inst.agent_instance_id == gone.agent_instance_id { inst.runtime_status = "starting"; inst.start_deadline_unix_ms = 1000 + BRIDGE_START_SUCCESS_TIMEOUT_MS; inst.last_seen_unix_ms = 1000 + BRIDGE_START_SUCCESS_TIMEOUT_MS; inst.pty_process_alive = false }
	sync.mutex_unlock(&bridge_runtime_mutex)
	expire(1000 + BRIDGE_START_SUCCESS_TIMEOUT_MS + 1)
	bridge_startup_implicit_ready(gone)
	testing.expect_value(t, status(gone.agent_instance_id), "failed")
	// 5. Another failure (not the start-success timeout) is never revived.
	other := startup_test_launch("startup_implicit_other", "startup_implicit_other")
	sync.mutex_lock(&bridge_runtime_mutex)
	for &inst in bridge_runtime_instances do if inst.agent_instance_id == other.agent_instance_id { inst.runtime_status = "failed"; inst.has_last_error = true; inst.last_error = bridge_error(.agent_launch_failed, .other) }
	sync.mutex_unlock(&bridge_runtime_mutex)
	bridge_startup_implicit_ready(other)
	testing.expect_value(t, status(other.agent_instance_id), "failed")
}
