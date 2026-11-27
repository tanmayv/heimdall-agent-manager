package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import virtual "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import httpc "odin_test:lib/httpc"
import contracts "odin_test:contracts"

Fallback_Test :: struct {
    t: ^testing.T,
    owned: runtime.Allocator,
    now: i64,
    posts, gets, launches, live_answers: int,
    status: int,
    body, last_ref, first_ref, launched, report: string,
    snap: Bridge_Runtime_Instance,
    has, local_after_post, bot: bool,
    worker_mode, worker_done: bool,
    retained: string,
    retained_allocator: runtime.Allocator,
}
fallback_test: ^Fallback_Test
FALLBACK_LAUNCH :: "{ \"type\":\"launch_agent\", \"command_id\":\"sb_test\", \"agent_instance_id\":\"inst_fb\", \"run_count\":6, \"extra\":{\"escaped\":\"a\\\"b\"} }"
fallback_test_snapshot :: proc(id: string) -> (Bridge_Runtime_Instance, bool) { return fallback_test.snap, fallback_test.has }
fallback_test_now :: proc() -> i64 { return fallback_test.now }
fallback_test_sleep :: proc(ms: i64) { fallback_test.now += ms }
fallback_test_record :: proc(id: string) -> (Bridge_Runtime_Launch, bool) { return {}, false }
fallback_test_rollover :: proc(id: string) -> bool { return false }
fallback_test_report :: proc(text: string) -> bool {
    delete(fallback_test.report, fallback_test.owned)
    fallback_test.report = strings.clone(text, fallback_test.owned)
    return true
}
fallback_test_switch :: proc(id: string, c: contracts.Bot_Candidate_Wire) -> (int, bool, string) { return 200, false, "" }
fallback_test_runnable :: proc(provider, model: string) -> bool { return true }
fallback_test_busy :: proc() -> (bool, bool, bool) { return false, false, true }
fallback_test_http :: proc(req: httpc.Request) -> (httpc.Response, httpc.Error) {
    f := fallback_test
    testing.expect_value(f.t, req.path[len(req.path)-2], "inst_fb")
    status, body := f.status, f.body
    if req.method == .GET {
        f.gets += 1
        testing.expect_value(f.t, req.path[len(req.path)-1], "bootstrap")
        testing.expect_value(f.t, len(req.query), 1)
        body = "{\"data\":{\"instance\":{\"agent_id\":\"agt_fb\",\"provider\":\"codex\",\"model\":\"m\",\"run_count\":5}}}"
        status = 200
    } else {
        f.posts += 1
        testing.expect_value(f.t, req.method, httpc.Method.POST)
        testing.expect_value(f.t, req.path[len(req.path)-1], "start-begin")
        raw, ok := req.body.(httpc.Raw_Body)
        testing.expect(f.t, ok)
        ref := extract_json_string(string(raw.bytes), "ref", "", context.temp_allocator)
        testing.expect(f.t, strings.has_prefix(ref, "bot_") if f.bot else strings.has_prefix(ref, "fb_inst_fb_"))
        if f.first_ref == "" do f.first_ref = strings.clone(ref, f.owned)
        delete(f.last_ref, f.owned); f.last_ref = strings.clone(ref, f.owned)
        if f.posts <= f.live_answers {
            status, body = 409, "{\"error\":{\"code\":\"conflict\",\"details\":{\"code\":\"already_running\"}}}"
        }
        if f.local_after_post { f.has = true; f.snap = {runtime_status = "starting", pty_process_alive = true} }
    }
    return {status = status, body = transmute([]byte)strings.clone(body)}, .None
}
fallback_test_launch :: proc(id, text: string, deadline: i64) -> (bool, string, Bridge_Error) {
    f := fallback_test
    f.launches += 1
    if f.worker_mode {
        // Model agent_token_issue: this default-allocator clone is retained
        // outside the worker pass, not a temporary parse buffer.
        f.retained_allocator = context.allocator
        f.retained = strings.clone(text)
    }
    if sync.atomic_load(&bridge_hub_start_begin_supported) {
        testing.expect_value(f.t, text, FALLBACK_LAUNCH)
        testing.expect_value(f.t, id, "sb_test")
        testing.expect(f.t, extract_json_int(text, "run_count", 0) > 0)
    } else {
        testing.expect_value(f.t, extract_json_int(text, "run_count", -1), 5 if f.bot else 0)
        if f.bot do testing.expect_value(f.t, id, "botl_att_test_0")
    }
    delete(f.launched, f.owned); f.launched = strings.clone(text, f.owned)
    bridge_task_wake_note_launched("inst_fb", f.now)
    if f.worker_mode do sync.atomic_store(&f.worker_done, true)
    return true, "", {}
}
fallback_test_attempt :: proc() -> Bridge_Wake_Result {
    return bridge_wake_attempt("inst_fb", fallback_test.now, time.to_unix_nanoseconds(time.now()) + i64(10*time.Second))
}
fallback_test_run :: proc(t: ^testing.T, name: string) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    bridge_agent_wake_init()
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator); defer mem.tracking_allocator_destroy(&track)
    context.allocator = mem.tracking_allocator(&track)
    {
        arena: virtual.Arena
        assert(virtual.arena_init_growing(&arena) == nil)
        // The default stays on the tracker. Only temporary parsing uses an
        // arena; otherwise the ownership assertions would observe no activity.
        context.temp_allocator = virtual.arena_allocator(&arena)
        defer virtual.arena_destroy(&arena)
        f := Fallback_Test{t=t, owned=context.allocator, now=1_000_000, status=200, body=fmt.tprintf("%s%s%s", "{\"data\":{\"launch\":", FALLBACK_LAUNCH, "}}")}
        fallback_test = &f
        config, cred, flag := bridge_config, g_bridge_cred, sync.atomic_load(&bridge_hub_start_begin_supported)
        saved_map := bridge_agent_wake
        saved_bot_backoff := bridge_bot_backoff
        bridge_bot_backoff = make(map[string]Bridge_Bot_Backoff, runtime.heap_allocator())
        snap, proof, launch, http, begin := bridge_wake_snapshot_proc, bridge_wake_probe_proc, bridge_wake_launch_proc, bridge_wake_http_proc, bridge_wake_start_begin_proc
        bridge_wake_probe_proc = proc(id: string) -> Bridge_Instance_Probe_Result {
            snap, found := fallback_test_snapshot(id)
            live := found && bridge_runtime_status_active(snap.runtime_status)
            return {agent_instance_id=id,state="alive" if live else "absent"}
        }
        defer bridge_wake_probe_proc = proof
        bot_snap, bot_launch, bot_now, bot_sleep, bot_record, bot_rollover := bridge_bot_snapshot_proc, bridge_bot_runtime_launch_proc, bridge_bot_now_proc, bridge_bot_sleep_proc, bridge_bot_launch_record_proc, bridge_bot_rollover_proc
        old_worker, old_bot_proc := bridge_bot_current_worker, bridge_bot_launch_proc
        old_report, old_switch, old_runnable, old_busy := bridge_bot_report_proc, bridge_bot_switch_proc, bridge_bot_runnable_proc, bridge_bot_busy_inputs_proc
        bridge_config.daemon_url, bridge_config.bridge_token, g_bridge_cred = "https://hub.test", "hba_test", {}
        sync.atomic_store(&bridge_hub_start_begin_supported, true)
        bridge_agent_wake = make(map[string]Bridge_Wake_State, context.allocator)
        bridge_wake_snapshot_proc, bridge_wake_launch_proc, bridge_wake_http_proc = fallback_test_snapshot, fallback_test_launch, fallback_test_http
        bridge_wake_start_begin_proc = bridge_wake_start_begin
        bridge_bot_snapshot_proc, bridge_bot_runtime_launch_proc, bridge_bot_now_proc = fallback_test_snapshot, fallback_test_launch, fallback_test_now
        bridge_bot_sleep_proc, bridge_bot_launch_record_proc, bridge_bot_rollover_proc = fallback_test_sleep, fallback_test_record, fallback_test_rollover
        bridge_bot_launch_proc = bridge_bot_launch_via_start_begin
        bridge_bot_current_worker = nil
        bridge_bot_report_proc, bridge_bot_switch_proc = fallback_test_report, fallback_test_switch
        bridge_bot_runnable_proc, bridge_bot_busy_inputs_proc = fallback_test_runnable, fallback_test_busy
        defer {
            bridge_agent_wake_reset(); delete(bridge_agent_wake)
            bridge_agent_wake = saved_map
            for key in bridge_bot_backoff do delete(key, runtime.heap_allocator())
            delete(bridge_bot_backoff)
            bridge_bot_backoff = saved_bot_backoff
            bridge_config, g_bridge_cred = config, cred
            sync.atomic_store(&bridge_hub_start_begin_supported, flag)
            bridge_wake_snapshot_proc, bridge_wake_launch_proc, bridge_wake_http_proc, bridge_wake_start_begin_proc = snap, launch, http, begin
            bridge_bot_snapshot_proc, bridge_bot_runtime_launch_proc, bridge_bot_now_proc = bot_snap, bot_launch, bot_now
            bridge_bot_sleep_proc, bridge_bot_launch_record_proc, bridge_bot_rollover_proc = bot_sleep, bot_record, bot_rollover
            bridge_bot_current_worker, bridge_bot_launch_proc = old_worker, old_bot_proc
            bridge_bot_report_proc, bridge_bot_switch_proc, bridge_bot_runnable_proc, bridge_bot_busy_inputs_proc = old_report, old_switch, old_runnable, old_busy
            delete(f.report, f.owned); delete(f.first_ref, f.owned); delete(f.last_ref, f.owned); delete(f.launched, f.owned)
        }
        switch name {
        case "launch":
            testing.expect_value(t, fallback_test_attempt().outcome, Bridge_Wake_Outcome.Launched)
            testing.expect_value(t, f.posts, 1); testing.expect_value(t, f.gets, 0)
        case "worker":
            f.live_answers = 1
            _ = fallback_test_attempt()
            sync.mutex_lock(&bridge_wake_mutex)
            state := &bridge_agent_wake["inst_fb"]
            state.last_wake_ms = 0
            state.live_row_retry_at_ms = bridge_runtime_now_ms()-1
            sync.mutex_unlock(&bridge_wake_mutex)
            f.worker_mode = true
            worker := bridge_wake_retry_start()
            bridge_wake_retry_tick(bridge_runtime_now_ms())
            started := time.tick_now()
            for !sync.atomic_load(&f.worker_done) && time.tick_since(started) < 5*time.Second do time.sleep(time.Millisecond)
            bridge_wake_retry_stop(worker)
            testing.expect(t, sync.atomic_load(&f.worker_done), "periodic tick must wake the retry worker")
            testing.expect_value(t, f.posts, 2)
            testing.expect_value(t, f.launches, 1)
            heap := runtime.heap_allocator()
            uses_heap := f.retained_allocator.procedure == heap.procedure && f.retained_allocator.data == heap.data
            testing.expect(t, uses_heap, "launch default allocations must survive worker arena reset and shutdown")
            if uses_heap {
                testing.expect_value(t, f.retained, FALLBACK_LAUNCH)
                delete(f.retained, f.retained_allocator)
            }
            // Pin the production periodic-loop call site as well as exercising
            // tick -> condition -> worker -> launch -> stop above.
            source := #load("hub_runtime_client.odin", string)
            start := strings.index(source, "bridge_hub_runtime_loop :: proc(")
            end := strings.index(source, "Bridge_Nudge_Record :: struct")
            if testing.expect(t, start >= 0 && end > start) do testing.expect(t, strings.contains(source[start:end], "bridge_wake_retry_tick(bridge_runtime_now_ms())"))
        case "recover":
            f.live_answers = 3
            _ = fallback_test_attempt()
            testing.expect(t, rawptr(raw_data(bridge_agent_wake["inst_fb"].ref)) in track.allocation_map, "pending ref must be owned and tracked")
            for i in 1..=3 {
                f.now = 1_000_000 + i64(i)*30_000
                bridge_wake_retry_due(f.now-1)
                testing.expect_value(t, f.posts, i)
                allocations_before := len(track.allocation_map)
                bridge_wake_retry_due(f.now)
                if i < 3 do testing.expect_value(t, len(track.allocation_map), allocations_before)
                testing.expect_value(t, f.posts, i+1)
                testing.expect_value(t, f.last_ref, f.first_ref)
                testing.expect_value(t, bridge_agent_wake["inst_fb"].failures, 0)
                testing.expect(t, !bridge_agent_wake["inst_fb"].parked)
            }
            testing.expect_value(t, f.launches, 1)
            testing.expect_value(t, bridge_agent_wake["inst_fb"].live_row_retry_at_ms, 0)
        case "bounded":
            f.live_answers = 100
            _ = fallback_test_attempt()
            for i in 1..=5 { f.now += 30_000; bridge_wake_retry_due(f.now) }
            testing.expect_value(t, f.posts, 6)
            testing.expect_value(t, bridge_agent_wake["inst_fb"].failures, 1)
            testing.expect_value(t, bridge_agent_wake["inst_fb"].live_row_retry_at_ms, 0)
            // A new accepted wake supersedes the old pending reference.
            bridge_agent_wake_reset(); f.now += 100_000
            _ = fallback_test_attempt()
            old := strings.clone(f.last_ref)
            f.now += 30_000
            _ = fallback_test_attempt()
            testing.expect(t, f.last_ref != old); delete(old)
            f.has, f.snap = true, Bridge_Runtime_Instance{runtime_status="running", pty_process_alive=true}
            f.now += 30_000; before := f.posts
            bridge_wake_retry_due(f.now)
            testing.expect_value(t, f.posts, before)
            testing.expect_value(t, bridge_agent_wake["inst_fb"].live_row_retry_at_ms, 0)
            // Shutdown clears pending retries as well.
            f.has = false; f.now += 100_000
            _ = fallback_test_attempt()
            bridge_wake_retry_stop(nil)
            testing.expect_value(t, bridge_agent_wake["inst_fb"].live_row_retry_at_ms, 0)
        case "local":
            f.live_answers, f.local_after_post = 100, true
            testing.expect_value(t, fallback_test_attempt().outcome, Bridge_Wake_Outcome.Already_Active)
            testing.expect_value(t, f.launches, 0)
            testing.expect_value(t, bridge_agent_wake["inst_fb"].failures, 0)
            testing.expect_value(t, bridge_agent_wake["inst_fb"].live_row_retry_at_ms, 0)
        case "refs":
            f.status, f.body = 429, "{}"
            _ = fallback_test_attempt()
            first := strings.clone(f.last_ref)
            f.now += 2_000_000
            _ = fallback_test_attempt()
            testing.expect_value(t, f.last_ref, first)
            f.status, f.body = 200, fmt.tprintf("%s%s%s", "{\"data\":{\"launch\":", FALLBACK_LAUNCH, "}}")
            f.now += 2_000_000; _ = fallback_test_attempt()
            f.now += 30_001; _ = fallback_test_attempt()
            testing.expect(t, f.last_ref != first); delete(first)
        case "classes", "404":
            for status in ([]int{0, 401, 403, 409, 423, 429, 500, 404, 400, 422, 200}) {
                bridge_agent_wake_reset(); f.now += 2_000_000
                f.status, f.body = status, "{\"error\":{\"code\":\"missing\"}}"
                _ = fallback_test_attempt()
                st := bridge_agent_wake["inst_fb"]
                retry := status == 0 || status == 401 || status == 403 || status == 409 || status == 423 || status == 429 || status == 500
                testing.expect_value(t, st.failures, 1 if retry else 0)
                testing.expect_value(t, st.parked, !retry)
            }
            for body in ([]string{"", "<html>404</html>"}) {
                bridge_agent_wake_reset(); f.now += 2_000_000
                f.status, f.body = 404, body
                _ = fallback_test_attempt()
                testing.expect_value(t, bridge_agent_wake["inst_fb"].failures, 1)
                testing.expect(t, !bridge_agent_wake["inst_fb"].parked)
            }
        case "legacy", "reconnect":
            bridge_hub_apply_ready_settings("{\"start_begin\":true}")
            testing.expect(t, sync.atomic_load(&bridge_hub_start_begin_supported))
            bridge_hub_reset_heartbeat_negotiation()
            bridge_hub_apply_ready_settings("{}")
            testing.expect(t, !sync.atomic_load(&bridge_hub_start_begin_supported))
            testing.expect_value(t, fallback_test_attempt().outcome, Bridge_Wake_Outcome.Launched)
            testing.expect_value(t, f.gets, 1); testing.expect_value(t, f.posts, 0)
        case "bot", "bot_legacy", "bot_timeout", "bot_refused":
            f.bot = true
            if name == "bot_legacy" do sync.atomic_store(&bridge_hub_start_begin_supported, false)
            w := Bridge_Bot_Worker{frame={agent_instance_id="inst_fb",attempt_id="att_test"}, ready_deadline_ms=f.now+120_000}
            bridge_bot_current_worker = &w
            if name == "bot_timeout" do f.live_answers = 100
            if name == "bot_refused" { f.status, f.body = 400, "{\"error\":{\"code\":\"bad\"}}" }
            if name == "bot_timeout" || name == "bot_refused" {
                w.frame.candidates = {{provider="codex",model="m"}}
                w.frame.timers = {launch_ready_ms=120_000,progress_interval_ms=10_000}
                bridge_bot_run(&w)
                testing.expect(t, strings.contains(f.report, "launch_timeout") if name == "bot_timeout" else strings.contains(f.report, "launch_failed"))
                testing.expect(t, strings.contains(f.report, "exhausted"))
                testing.expect_value(t, w.live_row_retry_at_ms, 0)
                testing.expect_value(t, f.launches, 0)
                if name == "bot_timeout" {
                    testing.expect_value(t, f.now, w.ready_deadline_ms)
                    testing.expect_value(t, f.posts, 4)
                    testing.expect_value(t, f.last_ref, f.first_ref)
                } else {
                    testing.expect(t, strings.contains(f.report, "fatal"))
                }
            } else {
                ok, _, _ := bridge_bot_launch_via_start_begin("inst_fb", "att_test")
                testing.expect(t, ok)
                if name == "bot" {
                    testing.expect_value(t, f.last_ref, "bot_att_test")
                    testing.expect_value(t, f.posts, 1); testing.expect_value(t, f.gets, 0)
                } else {
                    testing.expect_value(t, f.posts, 0); testing.expect_value(t, f.gets, 1)
                }
            }
            for o in w.outcomes { delete(o.provider, runtime.heap_allocator()); delete(o.model, runtime.heap_allocator()); delete(o.outcome, runtime.heap_allocator()); delete(o.detail, runtime.heap_allocator()) }
            delete(w.outcomes)
            delete(w.terminal_json, runtime.heap_allocator())
            for value in w.pending_reports do delete(value, runtime.heap_allocator())
            delete(w.pending_reports)
        }
    }
    testing.expect(t, track.total_allocation_count > 0, "ownership tracking must actually observe allocations")
    testing.expect_value(t, len(track.allocation_map), 0)
    testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test) test_fallback_calls_start_begin_with_ref :: proc(t:^testing.T) {fallback_test_run(t,"launch")}
@(test) test_fallback_never_generation_zero :: proc(t:^testing.T) {fallback_test_run(t,"launch")}
@(test) test_fallback_stale_row_recovers_after_reaper :: proc(t:^testing.T) {fallback_test_run(t,"recover")}
@(test) test_fallback_ref_stable_across_retries :: proc(t:^testing.T) {fallback_test_run(t,"refs")}
@(test) test_fallback_failure_classes :: proc(t:^testing.T) {fallback_test_run(t,"classes")}
@(test) test_fallback_already_running_with_local_process :: proc(t:^testing.T) {fallback_test_run(t,"local")}
@(test) test_fallback_stale_row_retry_is_bounded :: proc(t:^testing.T) {fallback_test_run(t,"bounded")}
@(test) test_fallback_legacy_hub_uses_manifest :: proc(t:^testing.T) {fallback_test_run(t,"legacy")}
@(test) test_start_begin_flag_reset_on_reconnect :: proc(t:^testing.T) {fallback_test_run(t,"reconnect")}
@(test) test_start_begin_404_without_error_body_is_retriable :: proc(t:^testing.T) {fallback_test_run(t,"404")}
@(test) test_bot_launch_calls_start_begin :: proc(t:^testing.T) {fallback_test_run(t,"bot")}
@(test) test_bot_launch_legacy_hub_uses_manifest :: proc(t:^testing.T) {fallback_test_run(t,"bot_legacy")}
@(test) test_bot_launch_refused_reports_attempt :: proc(t:^testing.T) {fallback_test_run(t,"bot_refused")}
@(test) test_bot_stale_row_retry_keeps_ready_deadline :: proc(t:^testing.T) {fallback_test_run(t,"bot_timeout")}

@(test) test_fallback_retry_worker_preserves_launch_allocations :: proc(t:^testing.T) {fallback_test_run(t,"worker")}
