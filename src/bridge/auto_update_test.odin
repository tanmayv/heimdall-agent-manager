package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import cfg_lib "odin_test:lib/config"
import httpc "odin_test:lib/httpc"

@(test)
test_auto_update_schedule_and_backoff :: proc(t: ^testing.T) {
	for failures in 0..<10 {
		low := bridge_auto_update_delay(failures, 0)
		high := bridge_auto_update_delay(failures, u64((low / 9) * 2))
		testing.expect(t, low >= BRIDGE_AUTO_UPDATE_INTERVAL * 9 / 10)
		testing.expect(t, high <= BRIDGE_AUTO_UPDATE_INTERVAL * 16 * 11 / 10)
		if failures > 1 do testing.expect(t, low >= bridge_auto_update_delay(failures - 1, 0))
	}
	testing.expect(t, bridge_auto_update_delay(0, 0) != bridge_auto_update_delay(0, 123456), "profiles get different jitter")
	testing.expect_value(t, bridge_auto_update_delay(50, 0), bridge_auto_update_delay(5, 0))
	testing.expect(t, bridge_auto_update_newer("v2.0.0", "1.99.99"))
	testing.expect(t, !bridge_auto_update_newer("v1.2.3", "1.2.3"))
	testing.expect(t, !bridge_auto_update_newer("1.2.2", "1.2.3"))
	testing.expect(t, !bridge_auto_update_newer("../v9", "1.0"))
}

@(test)
test_auto_update_config_preserves_profile_settings :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	for original in ([]string{
		"[daemon]\ndaemon_id = \"account-a\"\n",
		"[bridge]\nfs_root = \"/work\"\n[wrapper]\ndaemon_url = \"https://example.test\"\n",
		"[bridge]\nauto_update_enabled = true # comment\n[wrapper]\nauto_update_enabled = true\n",
		"[bridge] # a commented table heading\nauto_update_enabled = true\n",
	}) {
		updated := bridge_auto_update_config_text(original, false)
		if strings.contains(original, "[bridge]") do testing.expect_value(t, strings.count(updated, "[bridge]"), 1)
		cfg: cfg_lib.Config
		cfg_lib.parse_config(updated, &cfg)
		testing.expect(t, cfg.bridge.auto_update_configured && !cfg.bridge.auto_update_enabled)
		if strings.contains(original, "account-a") do testing.expect_value(t, cfg.daemon.daemon_id, "account-a")
		if strings.contains(original, "fs_root") do testing.expect_value(t, cfg.bridge.fs_root, "/work")
		if strings.contains(original, "[wrapper]\nauto_update_enabled") do testing.expect(t, strings.contains(updated, "[wrapper]\nauto_update_enabled = true"))
		cfg_lib.parse_config(bridge_auto_update_config_text(updated, true), &cfg)
		testing.expect(t, cfg.bridge.auto_update_enabled)
	}
}

auto_test_version: string
auto_test_spawns: int
auto_test_busy: bool
auto_test_busy_during_lookup: bool
auto_test_service: string
auto_test_mutex: sync.Mutex

auto_test_resolve :: proc() -> string {
	if auto_test_busy_during_lookup do auto_test_busy = true
	return strings.clone(auto_test_version)
}
auto_test_quiet :: proc(reserve: bool) -> bool {return !auto_test_busy}
auto_test_spawn :: proc(argv: []string) -> bool {
	auto_test_spawns += 1
	auto_test_service = strings.clone(argv[5], context.temp_allocator)
	return true
}

@(test)
test_auto_update_tick_quiet_profile_backoff_optout :: proc(t: ^testing.T) {
	sync.mutex_lock(&auto_test_mutex)
	defer sync.mutex_unlock(&auto_test_mutex)
	dir := fmt.tprintf("%s/auto-update-%d", os.temp_dir(context.temp_allocator), time.to_unix_nanoseconds(time.now()))
	_ = bridge_make_directory_all(dir)
	defer os.remove_all(dir)
	path, config := fmt.tprintf("%s/auto.json", dir), fmt.tprintf("%s/config.toml", dir)
	testing.expect(t, os.write_entire_file(config, transmute([]byte)string("[bridge]\n")) == nil)
	testing.expect(t, bridge_auto_update_enabled(config), "default on for existing profiles")
	testing.expect(t, !bridge_auto_update_enabled(fmt.tprintf("%s/absent", dir)))
	auto_test_spawns = 0
	auto_test_version = "v999.0.0"
	auto_test_busy = false
	auto_test_busy_during_lookup = false
	quiet: i64
	bridge_auto_update_tick("profile-a", config, path, &quiet, 1000, auto_test_resolve, auto_test_spawn, auto_test_quiet)
	state := bridge_auto_update_read(path)
	testing.expect(t, state.next_check_ms > 1000)
	testing.expect_value(t, auto_test_spawns, 0)
	now := state.next_check_ms
	auto_test_busy = true
	bridge_auto_update_tick("profile-a", config, path, &quiet, now, auto_test_resolve, auto_test_spawn, auto_test_quiet)
	testing.expect_value(t, quiet, i64(0))
	auto_test_busy = false
	bridge_auto_update_tick("profile-a", config, path, &quiet, now + 1, auto_test_resolve, auto_test_spawn, auto_test_quiet)
	bridge_auto_update_tick("profile-a", config, path, &quiet, now + 30_000, auto_test_resolve, auto_test_spawn, auto_test_quiet)
	testing.expect_value(t, auto_test_spawns, 0)
	bridge_auto_update_tick("profile-a", config, path, &quiet, now + 60_001, auto_test_resolve, auto_test_spawn, auto_test_quiet)
	testing.expect_value(t, auto_test_spawns, 1)
	testing.expect_value(t, auto_test_service, "profile-a")
	state = bridge_auto_update_read(path)
	testing.expect_value(t, state.failures, 1)
	testing.expect_value(t, state.pending_version, "v999.0.0")
	// A crashed/rolled-back worker leaves a durable future retry and failed attempt.
	quiet = now
	bridge_auto_update_tick("profile-a", config, path, &quiet, state.next_check_ms - 1, auto_test_resolve, auto_test_spawn, auto_test_quiet)
	testing.expect_value(t, auto_test_spawns, 1)
	now = state.next_check_ms
	quiet = now - 60_000
	bridge_auto_update_tick("profile-a", config, path, &quiet, now, auto_test_resolve, auto_test_spawn, auto_test_quiet)
	state = bridge_auto_update_read(path)
	testing.expect_value(t, state.failures, 2)
	testing.expect(t, state.next_check_ms - now >= BRIDGE_AUTO_UPDATE_INTERVAL * 18 / 10)
	// An equal or older target never spawns an updater, even after the quiet window.
	for version in ([]string{contracts.APP_VERSION, "v0.0.0"}) {
		auto_test_version = version
		now = state.next_check_ms
		quiet = now - 60_000
		bridge_auto_update_tick("profile-a", config, path, &quiet, now, auto_test_resolve, auto_test_spawn, auto_test_quiet)
		state = bridge_auto_update_read(path)
		testing.expect_value(t, auto_test_spawns, 2)
	}
	auto_test_version = "v999.0.0"
	auto_test_busy_during_lookup = true
	now = state.next_check_ms
	quiet = now - 60_000
	bridge_auto_update_tick("profile-a", config, path, &quiet, now, auto_test_resolve, auto_test_spawn, auto_test_quiet)
	testing.expect_value(t, auto_test_spawns, 2)
	testing.expect(t, bridge_auto_update_read(path).next_check_ms == now, "a new agent during lookup does not incur failure backoff")
	auto_test_busy_during_lookup = false
	auto_test_busy = false
	testing.expect(t, os.write_entire_file(config, transmute([]byte)string("[bridge]\nauto_update_enabled = false\n")) == nil)
	now = state.next_check_ms
	quiet = now - 60_000
	bridge_auto_update_tick("profile-a", config, path, &quiet, now, auto_test_resolve, auto_test_spawn, auto_test_quiet)
	testing.expect_value(t, auto_test_spawns, 2)
	testing.expect_value(t, quiet, i64(0))
	// Failed verification/rollback keeps the persisted failure count; success
	// resets it only after the setup transaction returns successfully.
	state.failures = 3
	state.pending_version = "v999.0.0"
	testing.expect(t, bridge_auto_update_write(path, state))
	bridge_auto_update_finish_at(path, false, now, 0)
	state = bridge_auto_update_read(path)
	testing.expect_value(t, state.failures, 3)
	testing.expect_value(t, state.pending_version, "")
	testing.expect(t, state.next_check_ms - now > BRIDGE_AUTO_UPDATE_INTERVAL * 3)
	bridge_auto_update_finish_at(path, true, now, 0)
	testing.expect_value(t, bridge_auto_update_read(path).failures, 0)
}

@(test)
test_auto_update_resolve_hub_catalog :: proc(t: ^testing.T) {
	version := bridge_auto_update_resolve(proc(req: httpc.Request) -> (httpc.Response, httpc.Error) {
		return hub_test_response(200, `{"data":{"latest_version":"v999.0.0","artifact_available":true}}`), .None
	}, proc(url: string) -> (string, bool, string) {return "", false, "GitHub must not be used"})
	defer delete(version)
	testing.expect_value(t, version, "v999.0.0")
}

@(test)
test_auto_update_resolve_github_fallback :: proc(t: ^testing.T) {
	target, blocked := bridge_release_target()
	testing.expectf(t, !blocked, "fixture target %s must permit updates", target)
	version := bridge_auto_update_resolve(proc(req: httpc.Request) -> (httpc.Response, httpc.Error) {
		return hub_test_response(503, "unavailable"), .None
	}, proc(url: string) -> (string, bool, string) {
		// Only /releases/latest is read: a page of the list could hold only prereleases (F9).
		if url != BRIDGE_RELEASE_LATEST_URL do return "", false, "HTTP 404"
		target, _ := bridge_release_target()
		bundle := bridge_release_bundle_name(target, "v999.0.0")
		doc := strings.concatenate({`{"tag_name":"v999.0.0","draft":false,"prerelease":false,"assets":[{"name":"SHA256SUMS"},{"name":"`, bundle, `"}]}`}, context.temp_allocator)
		return doc, true, ""
	})
	defer delete(version)
	testing.expect_value(t, version, "v999.0.0")
}

// T16d: a launch record left by a dead (stopped/failed) agent must not hold the
// quiet window; a live one still does and its instance id is named in the log text.
@(test)
test_auto_update_quiet_ignores_dead_launch_records :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&auto_test_mutex)
	defer sync.mutex_unlock(&auto_test_mutex)
	dead, live := "inst_t16d_dead", "inst_t16d_live"
	bridge_runtime_record_launch({agent_instance_id = dead})
	bridge_runtime_record_launch({agent_instance_id = live})
	defer { bridge_runtime_remove_launch(dead); bridge_runtime_remove_launch(live) }
	fixture_confirm_child_failure(dead)
	// Reintroduce the stale record this compatibility case is exercising.
	bridge_runtime_record_launch({agent_instance_id = dead})
	bridge_runtime_set_status(live, "running", "idle")
	testing.expect(t, !bridge_auto_update_quiet_with_host(false, auto_update_test_empty_host), "a live record blocks")
	text := bridge_auto_update_busy_text()
	testing.expect(t, strings.contains(text, live) && !strings.contains(text, dead), text)
	testing.expect(t, strings.has_prefix(text, "1 agent launch(es)"), text)
	bridge_runtime_set_status(live, "stopped", "idle")
	testing.expect(t, bridge_auto_update_quiet_with_host(false, auto_update_test_empty_host), "dead records do not block")
}

@(test)
test_auto_update_quiet_admission :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	// Tick tests clear bridge_auto_update_reserved_until; keep them out.
	sync.mutex_lock(&auto_test_mutex)
	defer sync.mutex_unlock(&auto_test_mutex)
	defer {
		sync.mutex_lock(&bridge_auto_update_mutex)
		bridge_auto_update_reserved_until = 0
		sync.mutex_unlock(&bridge_auto_update_mutex)
	}
	testing.expect(t, bridge_auto_update_launch_enter())
	testing.expect(t, !bridge_auto_update_quiet_with_host(false, auto_update_test_empty_host), "a preparing launch prevents update admission")
	bridge_auto_update_launch_leave()
	if !bridge_auto_update_quiet_with_host(false, auto_update_test_empty_host) { testing.expect(t, false, "fixture unexpectedly has running launches"); return }
	testing.expect(t, bridge_auto_update_quiet_with_host(true, auto_update_test_empty_host))
	testing.expect(t, !bridge_auto_update_launch_enter(), "new agents cannot race the detached updater")
	launched, _, err := bridge_runtime_launch_agent("auto-update-test", `{"agent_instance_id":"auto-update-test"}`)
	testing.expect(t, !launched)
	testing.expect_value(t, err.class, contracts.Bridge_Error_Class.retriable)
	testing.expect_value(t, err.retry_after_ms, i64(30_000))
}

auto_update_test_empty_host :: proc(socket: string) -> (Pty_Host_Reply, bool) {
	return {kind = .Agent_List}, true
}

@(test)
test_auto_update_quiet_preserved_pty_agent :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	// Tick tests clear bridge_auto_update_reserved_until; keep them out.
	sync.mutex_lock(&auto_test_mutex)
	defer sync.mutex_unlock(&auto_test_mutex)
	// No current-process launch exists, as after a bridge restart.
	sync.mutex_lock(&bridge_runtime_mutex)
	count := len(bridge_runtime_launches)
	sync.mutex_unlock(&bridge_runtime_mutex)
	testing.expect_value(t, count, 0)
	testing.expect(t, !bridge_auto_update_quiet_with_host(true, proc(socket: string) -> (Pty_Host_Reply, bool) {
		reply := Pty_Host_Reply{kind = .Agent_List}
		reply.agents = make([]Pty_Host_Agent_Info, 1)
		reply.agents[0] = {instance_id = strings.clone("preserved-agent"), alive = true}
		return reply, true
	}), "a preserved PTY agent prevents update admission")
	testing.expect(t, !bridge_auto_update_quiet_with_host(true, proc(socket: string) -> (Pty_Host_Reply, bool) {
		return {}, false
	}), "failed PTY listing prevents update admission")
	testing.expect_value(t, bridge_auto_update_busy, Bridge_Auto_Update_Busy.Host_Unlisted)
	testing.expect(t, bridge_auto_update_launch_enter(), "busy or unavailable host must not reserve admission")
	bridge_auto_update_launch_leave()
}

// T16b: the PTY host keeps exited agents and `ham-ctl shell` runs registered
// (alive = false) until they are closed. dawnstar listed two exited shell runs,
// riverwood three exited agents, and neither bridge ever found a quiet window.
@(test)
test_auto_update_quiet_ignores_exited_pty_entries :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&auto_test_mutex)
	defer sync.mutex_unlock(&auto_test_mutex)
	defer {
		sync.mutex_lock(&bridge_auto_update_mutex)
		bridge_auto_update_reserved_until = 0
		sync.mutex_unlock(&bridge_auto_update_mutex)
	}
	exited :: proc(socket: string) -> (Pty_Host_Reply, bool) {
		reply := Pty_Host_Reply{kind = .Agent_List}
		reply.agents = make([]Pty_Host_Agent_Info, 3)
		reply.agents[0] = {instance_id = strings.clone("sh_72984ce9a102bdc903cb78f104b3bc41"), program = strings.clone("sh"), alive = false, has_exit_code = true}
		reply.agents[1] = {instance_id = strings.clone("inst_exited_sigterm"), alive = false, has_exit_code = true, exit_code = 143}
		reply.agents[2] = {instance_id = strings.clone("inst_exited_error"), alive = false, has_exit_code = true, exit_code = 1}
		return reply, true
	}
	testing.expect(t, bridge_auto_update_quiet_with_host(false, exited), "exited PTY entries leave the bridge quiet")
	mixed :: proc(socket: string) -> (Pty_Host_Reply, bool) {
		reply := Pty_Host_Reply{kind = .Agent_List}
		reply.agents = make([]Pty_Host_Agent_Info, 3)
		reply.agents[0] = {instance_id = strings.clone("inst_exited"), alive = false, has_exit_code = true}
		reply.agents[1] = {instance_id = strings.clone("inst_running"), alive = true}
		reply.agents[2] = {instance_id = strings.clone("sh_running"), alive = true}
		return reply, true
	}
	testing.expect(t, !bridge_auto_update_quiet_with_host(false, mixed), "a running PTY entry still prevents update admission")
	testing.expect_value(t, bridge_auto_update_busy, Bridge_Auto_Update_Busy.Running_On_Host)
	testing.expect_value(t, bridge_auto_update_busy_count, 2)
	testing.expect_value(t, bridge_auto_update_busy_text(), "2 running agent(s) or shell session(s) on the PTY host")
}

auto_test_log: [dynamic]string

auto_test_log_sink :: proc(line: string) {
	append(&auto_test_log, strings.clone(line, context.temp_allocator))
}

auto_test_log_count :: proc(prefix: string) -> int {
	n := 0
	for line in auto_test_log do if strings.has_prefix(line, prefix) do n += 1
	return n
}

// Each check outcome is logged; the 30 s wait for a quiet window is logged once
// per change, not on every tick.
@(test)
test_auto_update_tick_logs_outcomes :: proc(t: ^testing.T) {
	sync.mutex_lock(&auto_test_mutex)
	defer sync.mutex_unlock(&auto_test_mutex)
	auto_test_log = make([dynamic]string, context.temp_allocator)
	bridge_auto_update_log_sink = auto_test_log_sink
	defer bridge_auto_update_log_sink = nil
	bridge_auto_update_clear_wait()
	defer bridge_auto_update_clear_wait()
	dir, path, config := auto_test_fixture(t, "[bridge]\n", 0)
	defer os.remove_all(dir)
	auto_test_spawns = 0
	auto_test_version = contracts.APP_VERSION
	auto_test_busy, auto_test_busy_during_lookup = true, false
	quiet: i64
	bridge_auto_update_tick("profile-a", config, path, &quiet, 1000, auto_test_resolve, auto_test_spawn, auto_test_quiet)
	testing.expect_value(t, auto_test_log_count("first check scheduled (next check in "), 1)
	now := bridge_auto_update_read(path).next_check_ms
	for i in 0..<5 do bridge_auto_update_tick("profile-a", config, path, &quiet, now + i64(i) * 30_000, auto_test_resolve, auto_test_spawn, auto_test_quiet)
	testing.expect_value(t, auto_test_log_count("check due; waiting for a quiet window: "), 1)
	auto_test_busy = false
	bridge_auto_update_tick("profile-a", config, path, &quiet, now + 150_000, auto_test_resolve, auto_test_spawn, auto_test_quiet)
	bridge_auto_update_tick("profile-a", config, path, &quiet, now + 180_000, auto_test_resolve, auto_test_spawn, auto_test_quiet)
	testing.expect_value(t, auto_test_log_count("check due; no agents running"), 1)
	bridge_auto_update_tick("profile-a", config, path, &quiet, now + 210_001, auto_test_resolve, auto_test_spawn, auto_test_quiet)
	testing.expect_value(t, auto_test_log_count("check: up to date ("), 1)
	// Lookup failure.
	auto_test_version = ""
	now = bridge_auto_update_read(path).next_check_ms
	quiet = now - 60_000
	bridge_auto_update_tick("profile-a", config, path, &quiet, now, auto_test_resolve, auto_test_spawn, auto_test_quiet)
	testing.expect_value(t, auto_test_log_count("check failed: could not look up the latest release (failures 1; "), 1)
	// Newer release: the updater is started.
	auto_test_version = "v999.0.0"
	now = bridge_auto_update_read(path).next_check_ms
	quiet = now - 60_000
	bridge_auto_update_tick("profile-a", config, path, &quiet, now, auto_test_resolve, auto_test_spawn, auto_test_quiet)
	testing.expect_value(t, auto_test_spawns, 1)
	testing.expect_value(t, auto_test_log_count(fmt.tprintf("check: updating %s -> v999.0.0", contracts.APP_VERSION)), 1)
	// Turned off: logged once, however many ticks.
	testing.expect(t, os.write_entire_file(config, transmute([]byte)string("[bridge]\nauto_update_enabled = false\n")) == nil)
	for i in 0..<3 do bridge_auto_update_tick("profile-a", config, path, &quiet, now + i64(i) * 30_000, auto_test_resolve, auto_test_spawn, auto_test_quiet)
	testing.expect_value(t, auto_test_log_count("automatic updates are turned off"), 1)
	testing.expect_value(t, bridge_auto_update_due_text(0, 5), "first check not scheduled yet")
	testing.expect_value(t, bridge_auto_update_due_text(1000, 1000 + 3 * 60_000), "check overdue by 3 min")
	testing.expect_value(t, bridge_auto_update_due_text(1000 + 60_001, 1000), "next check in 2 min")
}

// ---- REQ-AUP-3..6: forcing an update that stays overdue ----

auto_test_stops: int
auto_test_stop_ok: bool
auto_test_reserve_ok: bool
auto_test_releases: int
auto_test_stages: [dynamic]string
auto_test_messages: [dynamic]string
auto_test_argv: string

auto_test_force_hooks :: Bridge_Auto_Update_Force_Hooks{
	agents  = proc() -> int {return 3},
	reserve = proc() -> bool {return auto_test_reserve_ok},
	release = proc() {auto_test_releases += 1},
	stop    = proc() -> (bool, string) {
		auto_test_stops += 1
		if auto_test_stop_ok do return true, ""
		return false, "pid 42 survived SIGKILL"
	},
	notify  = proc(version, stage: string, percent: int, message: string) {
		append(&auto_test_stages, strings.clone(stage, context.temp_allocator))
		append(&auto_test_messages, strings.clone(message, context.temp_allocator))
	},
}

auto_test_spawn_argv :: proc(argv: []string) -> bool {
	auto_test_spawns += 1
	auto_test_argv = strings.join(argv[1:], " ", context.temp_allocator)
	return true
}

auto_test_force_reset :: proc() {
	auto_test_spawns, auto_test_stops, auto_test_releases = 0, 0, 0
	auto_test_stop_ok, auto_test_reserve_ok = true, true
	auto_test_version = "v999.0.0"
	auto_test_busy, auto_test_busy_during_lookup = true, false
	auto_test_argv = ""
	// Per-test temp arrays: the tracking allocator would report heap ones as leaks.
	auto_test_stages = make([dynamic]string, context.temp_allocator)
	auto_test_messages = make([dynamic]string, context.temp_allocator)
}

auto_test_last_stage :: proc() -> string {
	return auto_test_stages[len(auto_test_stages) - 1] if len(auto_test_stages) > 0 else ""
}

auto_test_fixture :: proc(t: ^testing.T, config_text: string, next_check_ms: i64) -> (dir, path, config: string) {
	dir = fmt.tprintf("%s/auto-update-force-%d", os.temp_dir(context.temp_allocator), time.to_unix_nanoseconds(time.now()))
	_ = bridge_make_directory_all(dir)
	path, config = fmt.tprintf("%s/auto.json", dir), fmt.tprintf("%s/config.toml", dir)
	testing.expect(t, os.write_entire_file(config, transmute([]byte)config_text) == nil)
	testing.expect(t, bridge_auto_update_write(path, {next_check_ms = next_check_ms}))
	return
}

HOUR_MS :: i64(60 * 60 * 1000)

@(test)
test_auto_update_max_defer_config :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fmt.tprintf("%s/auto-update-defer-%d", os.temp_dir(context.temp_allocator), time.to_unix_nanoseconds(time.now()))
	_ = bridge_make_directory_all(dir)
	defer os.remove_all(dir)
	config := fmt.tprintf("%s/config.toml", dir)
	cases := []struct {text: string, hours: i64}{
		{"[bridge]\n", 24},
		{"[bridge]\nauto_update_max_defer_hours = 6\n", 6},
		{"[bridge]\nauto_update_max_defer_hours = 0 # never force\n", 0},
		{"[bridge]\nauto_update_max_defer_hours = -3\n", 24},
		{"[wrapper]\nauto_update_max_defer_hours = 1\n", 24},
	}
	for c in cases {
		testing.expect(t, os.write_entire_file(config, transmute([]byte)c.text) == nil)
		testing.expect_value(t, bridge_auto_update_max_defer_ms(config), c.hours * HOUR_MS)
	}
}

// Busy for max_defer past the scheduled check: announce, wait out the notice,
// stop the PTY host, then hand off to the unchanged --auto-worker. The outcome
// is reported once the worker has finished.
@(test)
test_auto_update_tick_forced_after_max_defer :: proc(t: ^testing.T) {
	sync.mutex_lock(&auto_test_mutex)
	defer sync.mutex_unlock(&auto_test_mutex)
	defer bridge_auto_update_release_admission()
	auto_test_force_reset()
	CHECK :: i64(1_000_000)
	dir, path, config := auto_test_fixture(t, "[bridge]\n", CHECK)
	defer os.remove_all(dir)
	quiet: i64
	tick :: proc(path, config: string, quiet: ^i64, now: i64) {
		bridge_auto_update_tick("profile-f", config, path, quiet, now, auto_test_resolve, auto_test_spawn_argv, auto_test_quiet, auto_test_force_hooks)
	}

	// Overdue but within the default 24 h: keep waiting for a quiet window.
	tick(path, config, &quiet, CHECK + 23 * HOUR_MS)
	testing.expect_value(t, len(auto_test_stages), 0)
	testing.expect_value(t, auto_test_stops, 0)

	// 24 h overdue: announce first, stop nothing yet.
	now := CHECK + 24 * HOUR_MS
	tick(path, config, &quiet, now)
	state := bridge_auto_update_read(path)
	testing.expect_value(t, auto_test_last_stage(), "preparing")
	if len(auto_test_messages) > 0 {
		testing.expectf(t, strings.contains(auto_test_messages[0], "auto-update to v999.0.0 forcing in ~2 min; 3 agents will be stopped"), "notice: %s", auto_test_messages[0])
	}
	testing.expect_value(t, state.force_at_ms, now + BRIDGE_AUTO_UPDATE_FORCE_NOTICE_MS)
	testing.expect_value(t, state.force_version, "v999.0.0")
	testing.expect_value(t, auto_test_stops, 0)
	testing.expect_value(t, auto_test_spawns, 0)

	// A notice that fell due while the bridge was down is announced again.
	state.force_at_ms = now - BRIDGE_AUTO_UPDATE_FORCE_STALE_MS - BRIDGE_AUTO_UPDATE_FORCE_NOTICE_MS - 1
	testing.expect(t, bridge_auto_update_write(path, state))
	tick(path, config, &quiet, now)
	testing.expect_value(t, auto_test_stops, 0)
	testing.expect_value(t, len(auto_test_stages), 2)
	testing.expect_value(t, auto_test_last_stage(), "preparing")
	state = bridge_auto_update_read(path)
	testing.expect_value(t, state.force_at_ms, now + BRIDGE_AUTO_UPDATE_FORCE_NOTICE_MS)
	clear(&auto_test_stages)
	append(&auto_test_stages, "preparing")

	// During the notice nothing more happens.
	tick(path, config, &quiet, now + 60_000)
	testing.expect_value(t, len(auto_test_stages), 1)
	// A launch being prepared holds the force off.
	auto_test_reserve_ok = false
	tick(path, config, &quiet, state.force_at_ms)
	testing.expect_value(t, auto_test_stops, 0)
	testing.expect_value(t, bridge_auto_update_read(path).force_at_ms, state.force_at_ms)

	// Due: stop the PTY host BEFORE spawning the existing auto worker.
	auto_test_reserve_ok = true
	forced_at := state.force_at_ms
	tick(path, config, &quiet, forced_at)
	testing.expect_value(t, auto_test_stops, 1)
	testing.expect_value(t, auto_test_spawns, 1)
	testing.expect_value(t, auto_test_argv, "update --version v999.0.0 --service profile-f --auto-worker")
	testing.expectf(t, len(auto_test_stages) == 4 && auto_test_stages[1] == "stopping_pty_host" && auto_test_stages[2] == "pty_host_stopped" && auto_test_stages[3] == "restarting", "stages %v", auto_test_stages)
	state = bridge_auto_update_read(path)
	testing.expect_value(t, state.pending_version, "v999.0.0")
	testing.expect_value(t, state.forced_version, "v999.0.0")
	testing.expect_value(t, state.force_at_ms, i64(0))
	testing.expect_value(t, state.failures, 1)
	testing.expect(t, state.next_check_ms - forced_at >= BRIDGE_AUTO_UPDATE_INTERVAL * 9 / 10, "conservative backoff persisted before detaching")

	// While the worker runs nothing is reported; once it finished without
	// restarting into v999 (refused or rolled back), the failure is reported.
	tick(path, config, &quiet, forced_at + 1000)
	testing.expect_value(t, len(auto_test_stages), 4)
	bridge_auto_update_finish_at(path, false, forced_at + 2000, 0)
	tick(path, config, &quiet, forced_at + 3000)
	testing.expect_value(t, auto_test_last_stage(), "failed")
	testing.expect_value(t, bridge_auto_update_read(path).forced_version, "")
	tick(path, config, &quiet, forced_at + 4000)
	testing.expect_value(t, len(auto_test_stages), 5)

	// A process running the forced version reports success.
	state = bridge_auto_update_read(path)
	state.forced_version = "v0.0.1"
	testing.expect(t, bridge_auto_update_write(path, state))
	tick(path, config, &quiet, forced_at + 5000)
	testing.expect_value(t, auto_test_last_stage(), "succeeded")

	// A PTY host that cannot be stopped aborts before anything is spawned.
	state = bridge_auto_update_read(path)
	now = state.next_check_ms + 24 * HOUR_MS
	tick(path, config, &quiet, now)
	testing.expect_value(t, auto_test_last_stage(), "preparing")
	auto_test_stop_ok = false
	releases := auto_test_releases
	tick(path, config, &quiet, now + BRIDGE_AUTO_UPDATE_FORCE_NOTICE_MS)
	testing.expect_value(t, auto_test_last_stage(), "failed")
	testing.expect_value(t, auto_test_spawns, 1)
	testing.expect_value(t, auto_test_releases, releases + 1)
	after := bridge_auto_update_read(path)
	testing.expect_value(t, after.failures, state.failures + 1)
	testing.expect_value(t, after.pending_version, "")
	testing.expect_value(t, after.force_at_ms, i64(0))
}

// auto_update_max_defer_hours = 0 keeps the old behaviour: wait for quiet forever.
// An announced force is withdrawn when forcing is turned off.
@(test)
test_auto_update_tick_max_defer_zero_never_forces :: proc(t: ^testing.T) {
	sync.mutex_lock(&auto_test_mutex)
	defer sync.mutex_unlock(&auto_test_mutex)
	auto_test_force_reset()
	CHECK :: i64(1_000_000)
	dir, path, config := auto_test_fixture(t, "[bridge]\nauto_update_max_defer_hours = 0\n", CHECK)
	defer os.remove_all(dir)
	quiet: i64
	for now in ([]i64{CHECK, CHECK + 24 * HOUR_MS, CHECK + 1000 * HOUR_MS}) {
		bridge_auto_update_tick("profile-z", config, path, &quiet, now, auto_test_resolve, auto_test_spawn_argv, auto_test_quiet, auto_test_force_hooks)
	}
	testing.expect_value(t, len(auto_test_stages), 0)
	testing.expect_value(t, auto_test_stops, 0)
	testing.expect_value(t, auto_test_spawns, 0)
	testing.expect_value(t, bridge_auto_update_read(path).next_check_ms, CHECK)

	testing.expect(t, bridge_auto_update_write(path, {next_check_ms = CHECK, force_at_ms = CHECK + 25 * HOUR_MS, force_version = "v999.0.0"}))
	bridge_auto_update_tick("profile-z", config, path, &quiet, CHECK + 25 * HOUR_MS, auto_test_resolve, auto_test_spawn_argv, auto_test_quiet, auto_test_force_hooks)
	testing.expect_value(t, auto_test_last_stage(), "failed")
	testing.expectf(t, strings.contains(auto_test_messages[len(auto_test_messages) - 1], "= 0"), "cancel reason: %s", auto_test_messages[len(auto_test_messages) - 1])
	testing.expect_value(t, auto_test_stops, 0)
	testing.expect_value(t, bridge_auto_update_read(path).force_at_ms, i64(0))

	// Raising the setting (not zeroing it) withdraws the force without blaming "= 0".
	testing.expect(t, os.write_entire_file(config, transmute([]byte)string("[bridge]\nauto_update_max_defer_hours = 48\n")) == nil)
	testing.expect(t, bridge_auto_update_write(path, {next_check_ms = CHECK, force_at_ms = CHECK + 25 * HOUR_MS, force_version = "v999.0.0"}))
	bridge_auto_update_tick("profile-z", config, path, &quiet, CHECK + 25 * HOUR_MS, auto_test_resolve, auto_test_spawn_argv, auto_test_quiet, auto_test_force_hooks)
	testing.expect_value(t, auto_test_last_stage(), "failed")
	last := auto_test_messages[len(auto_test_messages) - 1]
	testing.expectf(t, strings.contains(last, "was raised") && !strings.contains(last, "= 0"), "cancel reason: %s", last)
	testing.expect_value(t, auto_test_stops, 0)
	testing.expect_value(t, bridge_auto_update_read(path).force_at_ms, i64(0))
}

// Quiet is still preferred: an overdue profile that becomes quiet updates
// through the quiet window, without stopping anything. One that had already
// announced a force still gets its outcome reported.
@(test)
test_auto_update_tick_quiet_preferred_over_force :: proc(t: ^testing.T) {
	sync.mutex_lock(&auto_test_mutex)
	defer sync.mutex_unlock(&auto_test_mutex)
	defer bridge_auto_update_release_admission()
	auto_test_force_reset()
	auto_test_busy = false
	CHECK :: i64(1_000_000)
	dir, path, config := auto_test_fixture(t, "[bridge]\n", CHECK)
	defer os.remove_all(dir)
	quiet: i64
	now := CHECK + 48 * HOUR_MS
	bridge_auto_update_tick("profile-q", config, path, &quiet, now, auto_test_resolve, auto_test_spawn_argv, auto_test_quiet, auto_test_force_hooks)
	bridge_auto_update_tick("profile-q", config, path, &quiet, now + BRIDGE_AUTO_UPDATE_QUIET_MS, auto_test_resolve, auto_test_spawn_argv, auto_test_quiet, auto_test_force_hooks)
	testing.expect_value(t, auto_test_spawns, 1)
	testing.expect_value(t, auto_test_stops, 0)
	testing.expect_value(t, len(auto_test_stages), 0)
	testing.expect_value(t, bridge_auto_update_read(path).forced_version, "")

	// Announced, then the agents finished: the quiet path takes over.
	testing.expect(t, bridge_auto_update_write(path, {next_check_ms = CHECK, force_at_ms = now + HOUR_MS, force_version = "v999.0.0"}))
	quiet = 0
	bridge_auto_update_tick("profile-q", config, path, &quiet, now, auto_test_resolve, auto_test_spawn_argv, auto_test_quiet, auto_test_force_hooks)
	bridge_auto_update_tick("profile-q", config, path, &quiet, now + BRIDGE_AUTO_UPDATE_QUIET_MS, auto_test_resolve, auto_test_spawn_argv, auto_test_quiet, auto_test_force_hooks)
	testing.expect_value(t, auto_test_spawns, 2)
	testing.expect_value(t, auto_test_stops, 0)
	state := bridge_auto_update_read(path)
	testing.expect_value(t, state.force_at_ms, i64(0))
	testing.expect_value(t, state.forced_version, "v999.0.0")
}

// ---- T16c: the hub catalog's bare version must reach the GitHub release tag ----

auto_test_release_urls: [dynamic]string

auto_test_release_get :: proc(url: string) -> (string, bool, string) {
	append(&auto_test_release_urls, strings.clone(url, context.temp_allocator))
	target, _ := bridge_release_target()
	bundle := bridge_release_bundle_name(target, "v999.0.0")
	if strings.has_suffix(url, "/SHA256SUMS") {
		return strings.concatenate({strings.repeat("0", 64, context.temp_allocator), "  ", bundle, "\n"}, context.temp_allocator), true, ""
	}
	// GitHub knows only the v-prefixed tag: /releases/tags/999.0.0 is a 404.
	if url != "https://api.github.com/repos/" + BRIDGE_RELEASE_REPO + "/releases/tags/v999.0.0" do return "", false, "HTTP 404"
	return strings.concatenate({`{"tag_name":"v999.0.0","draft":false,"prerelease":false,"assets":[{"name":"SHA256SUMS"},{"name":"`, bundle, `"}]}`}, context.temp_allocator), true, ""
}

auto_test_release_download :: proc(req: httpc.Request, dest: string) -> (int, httpc.Error) {
	append(&auto_test_release_urls, strings.clone(httpc.url_string(req.url), context.temp_allocator))
	_ = os.write_entire_file(dest, transmute([]byte)string("tampered"))
	return 200, .None
}

@(test)
test_auto_update_hub_bare_version_reaches_release_tag :: proc(t: ^testing.T) {
	sync.mutex_lock(&auto_test_mutex)
	defer sync.mutex_unlock(&auto_test_mutex)
	target, blocked := bridge_release_target()
	testing.expectf(t, !blocked, "fixture target %s must permit updates", target)
	// 1. The hub catalog carries the bare SemVer (bridge_promoted_release.odin trims "v").
	version := bridge_auto_update_resolve(proc(req: httpc.Request) -> (httpc.Response, httpc.Error) {
		return hub_test_response(200, `{"data":{"latest_version":"999.0.0","artifact_available":true}}`), .None
	}, proc(url: string) -> (string, bool, string) {return "", false, "GitHub must not be used"})
	testing.expect_value(t, version, "v999.0.0")
	auto_test_version = version
	delete(version)
	// 2. The quiet check hands that tag to the detached updater.
	auto_test_force_reset()
	auto_test_version = "v999.0.0"
	auto_test_busy = false
	dir, path, config := auto_test_fixture(t, "[bridge]\n", 1000)
	defer os.remove_all(dir)
	quiet := i64(1000 - BRIDGE_AUTO_UPDATE_QUIET_MS)
	bridge_auto_update_tick("profile-t", config, path, &quiet, 1000, auto_test_resolve, auto_test_spawn_argv, auto_test_quiet, auto_test_force_hooks)
	testing.expect_value(t, auto_test_spawns, 1)
	testing.expect_value(t, auto_test_argv, "update --version v999.0.0 --service profile-t --auto-worker")
	testing.expect_value(t, bridge_auto_update_read(path).pending_version, "v999.0.0")
	// 3. `update --version` looks the release up by its v-tag, for the new argv
	// and for a bare one (an older bridge's timer, or a user typing 999.0.0).
	work := fmt.tprintf("%s/work", dir)
	_ = bridge_make_directory_all(work)
	for want in ([]string{"v999.0.0", "999.0.0"}) {
		auto_test_release_urls = make([dynamic]string, context.temp_allocator)
		_, tag, err := bridge_release_fetch(want, target, work, auto_test_release_get, auto_test_release_download)
		testing.expectf(t, tag == "v999.0.0", "%s: tag %q", want, tag)
		testing.expectf(t, strings.contains(err, "SHA-256 mismatch"), "%s: the fake bundle must reach verification, got %q", want, err)
		BASE :: "https://github.com/" + BRIDGE_RELEASE_REPO + "/releases/download/v999.0.0/"
		testing.expectf(t, len(auto_test_release_urls) == 3, "%s: %v", want, auto_test_release_urls[:])
		if len(auto_test_release_urls) == 3 {
			testing.expect_value(t, auto_test_release_urls[0], "https://api.github.com/repos/" + BRIDGE_RELEASE_REPO + "/releases/tags/v999.0.0")
			testing.expect_value(t, auto_test_release_urls[1], BASE + "SHA256SUMS")
			testing.expect_value(t, auto_test_release_urls[2], strings.concatenate({BASE, bridge_release_bundle_name(target, "v999.0.0")}, context.temp_allocator))
		}
	}
	testing.expect_value(t, bridge_release_tag_for("0.5.81"), "v0.5.81")
	testing.expect_value(t, bridge_release_tag_for("v0.5.81"), "v0.5.81")
	testing.expect_value(t, bridge_release_tag_for("latest"), "latest")
}

@(test)
test_auto_update_tick_logs_worker_result :: proc(t: ^testing.T) {
	sync.mutex_lock(&auto_test_mutex)
	defer sync.mutex_unlock(&auto_test_mutex)
	auto_test_log = make([dynamic]string, context.temp_allocator)
	bridge_auto_update_log_sink = auto_test_log_sink
	defer bridge_auto_update_log_sink = nil
	auto_test_force_reset()
	dir, path, config := auto_test_fixture(t, "[bridge]\n", 0)
	defer os.remove_all(dir)
	now := i64(10 * HOUR_MS)
	// The updater is still running: nothing to report yet.
	testing.expect(t, bridge_auto_update_write(path, {next_check_ms = now + HOUR_MS, pending_version = "v999.0.0", last_result = "stale"}))
	quiet: i64
	bridge_auto_update_tick("profile-r", config, path, &quiet, now, auto_test_resolve, auto_test_spawn_argv, auto_test_quiet, auto_test_force_hooks)
	testing.expect_value(t, auto_test_log_count("stale"), 0)
	// It failed: finish records why; the bridge's worker logs it exactly once.
	bridge_auto_update_finish_at(path, false, now, 0, "update to v999.0.0 failed: release v999.0.0 not found; nothing was changed")
	for i in 0..<3 do bridge_auto_update_tick("profile-r", config, path, &quiet, now + i64(i) * 30_000, auto_test_resolve, auto_test_spawn_argv, auto_test_quiet, auto_test_force_hooks)
	testing.expect_value(t, auto_test_log_count("update to v999.0.0 failed: release v999.0.0 not found; nothing was changed (running "), 1)
	testing.expect_value(t, bridge_auto_update_read(path).last_result, "")
	testing.expect_value(t, bridge_auto_update_read(path).failures, 1)
	// A success is reported the same way.
	bridge_auto_update_finish_at(path, true, now, 0, "update to v999.0.0 succeeded")
	bridge_auto_update_tick("profile-r", config, path, &quiet, now, auto_test_resolve, auto_test_spawn_argv, auto_test_quiet, auto_test_force_hooks)
	testing.expect_value(t, auto_test_log_count("update to v999.0.0 succeeded (running "), 1)
	testing.expect_value(t, auto_test_spawns, 0)
}
