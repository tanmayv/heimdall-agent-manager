package main

// Automatic updates prefer a quiet window (no running or starting agents). One
// that stays overdue for auto_update_max_defer_hours (default 24; 0 = never) is
// forced: the hub is told first, and BRIDGE_AUTO_UPDATE_FORCE_NOTICE_MS later the
// PTY host and its agents are stopped and the same --auto-worker update runs.
// The detached supervisor holds an OS-user-wide kernel lock until setup's
// verification (or rollback) completes, independently of the service it restarts.
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import cfg_lib "odin_test:lib/config"
import contracts "odin_test:contracts"
import bridgesvc "odin_test:lib/bridgesvc"
import httpc "odin_test:lib/httpc"
import ws "odin_test:lib/ws"

BRIDGE_AUTO_UPDATE_INTERVAL :: i64(6 * 60 * 60 * 1000)
BRIDGE_AUTO_UPDATE_QUIET_MS :: i64(60_000)
BRIDGE_AUTO_UPDATE_DEFAULT_MAX_DEFER_HOURS :: 24
// REQ-AUP-5: lead time between the hub-visible notice and the forced stop. Kept
// short: the update is already max_defer overdue; this only gives whoever is
// watching a moment to save work.
BRIDGE_AUTO_UPDATE_FORCE_NOTICE_MS :: i64(2 * 60_000)
BRIDGE_AUTO_UPDATE_FORCE_STALE_MS :: i64(10 * 60_000)

Bridge_Auto_Update_State :: struct {
	next_check_ms: i64,
	failures: int,
	pending_version: string,
	// A forced update announced to the hub, due at force_at_ms (REQ-AUP-5).
	force_at_ms: i64,
	force_version: string,
	// A forced update handed to the --auto-worker. Its outcome is reported to the
	// hub once the worker has finished (pending_version cleared).
	forced_version: string,
	// The --auto-worker's outcome ("update to vX succeeded" / "update to vX
	// failed: <reason>"). That process runs detached with stdio on /dev/null, so
	// it records the outcome here and the bridge's worker logs it once (T16c).
	last_result: string,
}

// Seams of the forced path; a zero field means the real implementation.
Bridge_Auto_Update_Force_Hooks :: struct {
	agents:  proc() -> int,                        // agents the PTY host runs now
	reserve: proc() -> bool,                       // close launch admission; false while a launch is being prepared
	release: proc(),                               // reopen launch admission
	stop:    proc() -> (ok: bool, detail: string), // stop the PTY host and its agents
	notify:  proc(version, stage: string, percent: int, message: string),
}

bridge_auto_update_mutex: sync.Mutex
bridge_auto_update_launches: int
bridge_auto_update_reserved_until: i64
// Why the last quiet check failed (set under bridge_auto_update_mutex), for the log.
Bridge_Auto_Update_Busy :: enum {
	None,
	Launch_Preparing,
	Recorded_Launches,
	Host_Unlisted,
	Running_On_Host,
}
bridge_auto_update_busy: Bridge_Auto_Update_Busy
bridge_auto_update_busy_count: int
// Instance ids behind Recorded_Launches (comma separated, heap-owned), for the log.
bridge_auto_update_busy_ids: string

bridge_auto_update_busy_text :: proc() -> string {
	sync.mutex_lock(&bridge_auto_update_mutex)
	busy, count := bridge_auto_update_busy, bridge_auto_update_busy_count
	ids := strings.clone(bridge_auto_update_busy_ids, context.temp_allocator)
	sync.mutex_unlock(&bridge_auto_update_mutex)
	switch busy {
	case .None:              return "agents are running"
	case .Launch_Preparing:  return "an agent launch is being prepared"
	case .Recorded_Launches: return fmt.tprintf("%d agent launch(es) recorded by this bridge: %s", count, ids)
	case .Host_Unlisted:     return "cannot list the PTY host's agents"
	case .Running_On_Host:   return fmt.tprintf("%d running agent(s) or shell session(s) on the PTY host", count)
	}
	return ""
}

// Worker log lines. A due check repeats every 30 s while it waits for a quiet
// window, so the waiting line is logged only when its text changes; every other
// outcome is logged as it happens. Tests swap the sink.
bridge_auto_update_log_sink: proc(line: string)
bridge_auto_update_last_wait: string

bridge_auto_update_log :: proc(format: string, args: ..any) {
	line := fmt.tprintf(format, ..args)
	if bridge_auto_update_log_sink != nil do bridge_auto_update_log_sink(line)
	else do fmt.eprintfln("bridge auto-update: %s", line)
}

bridge_auto_update_log_wait :: proc(line: string) {
	if line == bridge_auto_update_last_wait do return
	delete(bridge_auto_update_last_wait, runtime.heap_allocator())
	bridge_auto_update_last_wait = strings.clone(line, runtime.heap_allocator())
	bridge_auto_update_log("%s", line)
}

bridge_auto_update_clear_wait :: proc() {
	delete(bridge_auto_update_last_wait, runtime.heap_allocator())
	bridge_auto_update_last_wait = ""
}

bridge_auto_update_delay :: proc(failures: int, entropy: u64) -> i64 {
	return bridge_backoff_delay_ms({base_ms = BRIDGE_AUTO_UPDATE_INTERVAL, max_ms = BRIDGE_AUTO_UPDATE_INTERVAL * 16, jitter_pct = 10}, max(1, failures), entropy)
}

bridge_auto_update_enabled :: proc(path: string) -> bool {
	context.allocator = context.temp_allocator
	loaded, ok := cfg_lib.load(path)
	if !ok do return false // an unreadable config must not authorize an update
	return !loaded.config.bridge.auto_update_configured || loaded.config.bridge.auto_update_enabled
}

// bridge_auto_update_max_defer_ms: how long an overdue update may wait for a quiet
// window before it is forced; 0 = never force (REQ-AUP-3).
bridge_auto_update_max_defer_ms :: proc(path: string) -> i64 {
	context.allocator = context.temp_allocator
	hours := BRIDGE_AUTO_UPDATE_DEFAULT_MAX_DEFER_HOURS
	if loaded, ok := cfg_lib.load(path); ok && loaded.config.bridge.auto_update_max_defer_configured {
		hours = loaded.config.bridge.auto_update_max_defer_hours
	}
	return i64(hours) * 60 * 60 * 1000
}

bridge_auto_update_state_path :: proc(service: string) -> string {
	l := bridgesvc.layout_for(bridge_service_host(), service)
	return bridgesvc.pjoin(l.state_dir, "auto-update.json")
}

bridge_auto_update_read :: proc(path: string) -> Bridge_Auto_Update_State {
	state: Bridge_Auto_Update_State
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err == nil do _ = json.unmarshal(data, &state, allocator = context.temp_allocator)
	return state
}

bridge_auto_update_write :: proc(path: string, state: Bridge_Auto_Update_State) -> bool {
	data, err := json.marshal(state, allocator = context.temp_allocator)
	return err == nil && bridge_retry_atomic_write(path, data)
}

bridge_auto_update_newer :: proc(candidate, current: string) -> bool {
	return bridge_release_tag_valid(candidate) && bridge_provider_extension_version_compare(candidate, current) > 0
}

bridge_auto_update_resolve :: proc(fetch: Bridge_Hub_Fetch = bridge_hub_http_send, get: Bridge_Release_Get = bridge_release_http_get) -> string {
	credential := bridge_credential_snapshot()
	defer delete(credential)
	resp, err := fetch({method = .GET, url = bridge_hub_url(), path = {"api", "v1", "bridge", "update-catalog"}, headers = {httpc.bearer(credential)}, timeout_ms = 60_000, connect_timeout_ms = 15_000})
	defer httpc.response_destroy(&resp)
	if err == .None && resp.status == 200 {
		// The Hub resolves the promoted catalog for this authenticated bridge.
		body := httpc.text(resp)
		version := extract_json_string(body, "latest_version", "")
		defer delete(version)
		available := extract_json_bool(body, "artifact_available", false)
		// The catalog carries the bare SemVer (the hub trims the tag's "v");
		// `update --version` looks the GitHub release up by its tag (T16c).
		if available && bridge_release_tag_valid(version) do return bridge_release_tag_for(version, context.allocator)
	}
	target, blocked := bridge_release_target()
	if blocked do return ""
	doc, ok, _ := get(BRIDGE_RELEASE_LATEST_URL)
	if !ok do return ""
	version, detail := bridge_release_select(doc, target, "latest")
	if detail != "" do return ""
	return strings.clone(version)
}

// Both a launch in preparation and a recorded live child prevent a quiet window.
// Reservation and launch admission use the same mutex, closing the check/spawn race.
bridge_auto_update_launch_enter :: proc() -> bool {
	sync.mutex_lock(&bridge_auto_update_mutex)
	defer sync.mutex_unlock(&bridge_auto_update_mutex)
	if bridge_runtime_now_ms() < bridge_auto_update_reserved_until do return false
	// The supervisor's agent gate closed admission before an activation (supervisor_gate.odin).
	if bridge_gate_admission_closed do return false
	bridge_auto_update_launches += 1
	return true
}

bridge_auto_update_launch_leave :: proc() {
	sync.mutex_lock(&bridge_auto_update_mutex)
	bridge_auto_update_launches -= 1
	sync.mutex_unlock(&bridge_auto_update_mutex)
}

bridge_auto_update_quiet :: proc(reserve := false) -> bool {
	return bridge_auto_update_quiet_with_host(reserve)
}

// The PTY host survives bridge restarts; the current process launch map does not.
// Inspect the own-profile socket without starting or replacing its daemon.
// Only RUNNING PTY entries count: the daemon keeps an exited agent or shell
// session registered (alive = false, with its exit code) until it is closed, and
// counting those kept a bridge from ever finding a quiet window (T16b: dawnstar's
// two exited `ham-ctl shell` runs, riverwood's three exited agents).
bridge_auto_update_quiet_with_host :: proc(
	reserve := false,
	list: proc(socket: string) -> (Pty_Host_Reply, bool) = bridge_pty_host_list,
) -> bool {
	sync.mutex_lock(&bridge_auto_update_mutex)
	defer sync.mutex_unlock(&bridge_auto_update_mutex)
	bridge_auto_update_busy, bridge_auto_update_busy_count = .None, 0
	if bridge_auto_update_launches > 0 {
		bridge_auto_update_busy = .Launch_Preparing
		return false
	}
	// A record whose instance is already stopped/failed is a dead agent's leftover
	// (T16d): it must not hold the window. Anything else blocks, named in the log.
	delete(bridge_auto_update_busy_ids, runtime.heap_allocator())
	bridge_auto_update_busy_ids = ""
	sync.mutex_lock(&bridge_runtime_mutex)
	live_ids := make([dynamic]string, context.temp_allocator)
	for launch in bridge_runtime_launches {
		dead := false
		for inst in bridge_runtime_instances {
			if inst.agent_instance_id == launch.agent_instance_id {
				dead = inst.runtime_status == "stopped" || inst.runtime_status == "failed"
				break
			}
		}
		if !dead do append(&live_ids, launch.agent_instance_id)
	}
	sync.mutex_unlock(&bridge_runtime_mutex)
	if len(live_ids) != 0 {
		bridge_auto_update_busy, bridge_auto_update_busy_count = .Recorded_Launches, len(live_ids)
		bridge_auto_update_busy_ids = strings.clone(strings.join(live_ids[:], ", ", context.temp_allocator), runtime.heap_allocator())
		return false
	}
	socket := pty_host_socket_path()
	defer delete(socket)
	reply, ok := list(socket)
	if !ok {
		// Unavailable live state cannot authorize a restart.
		bridge_auto_update_busy = .Host_Unlisted
		return false
	}
	defer pty_host_reply_delete(reply)
	if running := pty_host_running_agent_count(reply.agents); running != 0 {
		bridge_auto_update_busy, bridge_auto_update_busy_count = .Running_On_Host, running
		return false
	}
	if reserve do bridge_auto_update_reserved_until = bridge_runtime_now_ms() + 30 * 60_000
	return true
}

bridge_auto_update_start :: proc() {
	service, refusal := bridge_update_via_ham_bridge(contracts.APP_VERSION)
	if refusal != "" {
		bridge_auto_update_log("worker not started: %s", refusal)
		return
	}
	path := bridge_auto_update_state_path(service)
	state := bridge_auto_update_read(path)
	enabled := bridge_auto_update_enabled(cfg_lib.config_path_from_args(os.args))
	bridge_auto_update_log("worker started for %s (version %s, %s, state %s, %s)", service, contracts.APP_VERSION,
		"enabled" if enabled else "disabled by config", path, bridge_auto_update_due_text(state.next_check_ms, bridge_runtime_now_ms()))
	thread.run(bridge_auto_update_worker)
}

// bridge_auto_update_due_text describes when the next check is due, for the log.
bridge_auto_update_due_text :: proc(next_check_ms, now: i64) -> string {
	if next_check_ms == 0 do return "first check not scheduled yet"
	if now >= next_check_ms do return fmt.tprintf("check overdue by %d min", (now - next_check_ms) / 60_000)
	return fmt.tprintf("next check in %d min", (next_check_ms - now + 59_999) / 60_000)
}

bridge_auto_update_worker :: proc() {
	service, _ := bridge_update_via_ham_bridge(contracts.APP_VERSION)
	path := strings.clone(bridge_auto_update_state_path(service))
	defer delete(path)
	config := strings.clone(cfg_lib.config_path_from_args(os.args))
	defer delete(config)
	quiet_since: i64
	for {
		bridge_auto_update_tick(service, config, path, &quiet_since, bridge_runtime_now_ms())
		free_all(context.temp_allocator)
		time.sleep(30 * time.Second)
	}
}

bridge_auto_update_latest :: proc() -> string { return bridge_auto_update_resolve() }

bridge_auto_update_tick :: proc(
    service, config, path: string, quiet_since: ^i64, now: i64,
    resolve: proc() -> string = bridge_auto_update_latest,
    spawn: proc(argv: []string) -> bool = bridge_os_spawn_new_session,
    quiet: proc(reserve: bool) -> bool = bridge_auto_update_quiet,
    force: Bridge_Auto_Update_Force_Hooks = {},
) {
	hooks := bridge_auto_update_force_hooks(force)
	state := bridge_auto_update_read(path)
	bridge_auto_update_report_result(path, &state)
	bridge_auto_update_report_forced(path, &state, hooks)
	if !bridge_auto_update_enabled(config) {
		quiet_since^ = 0
		bridge_auto_update_log_wait("automatic updates are turned off in the config; not checking")
		bridge_auto_update_cancel_force(path, &state, hooks, "automatic updates were turned off")
	} else if state.next_check_ms == 0 {
		state.next_check_ms = now + bridge_auto_update_delay(0, rand.uint64())
		_ = bridge_auto_update_write(path, state)
		bridge_auto_update_log("first check scheduled (%s)", bridge_auto_update_due_text(state.next_check_ms, now))
	} else if now >= state.next_check_ms {
		if !quiet(false) {
			quiet_since^ = 0
			bridge_auto_update_log_wait(fmt.tprintf("check due; waiting for a quiet window: %s", bridge_auto_update_busy_text()))
			// REQ-AUP-3: still preferring quiet, but not forever.
			max_defer := bridge_auto_update_max_defer_ms(config)
			if max_defer > 0 && now >= state.next_check_ms + max_defer {
				bridge_auto_update_force_step(service, path, &state, now, resolve, spawn, hooks)
			} else {
				// Not forcing now: either forcing is off, or auto_update_max_defer_hours
				// was raised so the update is no longer overdue enough.
				reason := "forcing was turned off (auto_update_max_defer_hours = 0)"
				if max_defer > 0 do reason = "auto_update_max_defer_hours was raised, so the update is not overdue yet"
				bridge_auto_update_cancel_force(path, &state, hooks, reason)
			}
		} else if quiet_since^ == 0 {
			quiet_since^ = now
			bridge_auto_update_log_wait("check due; no agents running, checking once quiet for 60 s")
		} else if now - quiet_since^ >= BRIDGE_AUTO_UPDATE_QUIET_MS {
			bridge_auto_update_clear_wait()
			version := resolve()
			newer := bridge_auto_update_newer(version, contracts.APP_VERSION)
			// Network lookup can take a while. If an agent started in that time,
			// wait for another quiet window without counting an update failure.
			if newer && (!bridge_auto_update_enabled(config) || !quiet(true)) {
				bridge_auto_update_log("check: %s is available, but an agent started (or updates were turned off) during the lookup; waiting for another quiet window", version)
				delete(version)
				quiet_since^ = 0
				return
			}
			// A forced update announced earlier is overtaken by this quiet one;
			// its outcome is still reported, as the hub was told it would happen.
			announced := state.force_version
			state.force_at_ms, state.force_version = 0, ""
			// Persist conservative backoff BEFORE detaching. A crashed or rolled
			// back supervisor cannot create a restart/update loop.
			if version == "" || newer do state.failures += 1
			else do state.failures = 0
			state.next_check_ms = now + bridge_auto_update_delay(state.failures, rand.uint64())
			state.pending_version = strings.clone(version, context.temp_allocator) if newer else ""
			if newer && announced != "" do state.forced_version = state.pending_version
			persisted := bridge_auto_update_write(path, state)
			next := bridge_auto_update_due_text(state.next_check_ms, now)
			switch {
			case version == "":
				bridge_auto_update_log("check failed: could not look up the latest release (failures %d; %s)", state.failures, next)
			case !newer:
				bridge_auto_update_log("check: up to date (%s, latest %s; %s)", contracts.APP_VERSION, version, next)
			case !persisted:
				bridge_auto_update_log("check: %s is available, but the state file %s cannot be written; not updating", version, path)
			}
			if persisted && newer && bridge_auto_update_enabled(config) {
				exe, _ := os.get_executable_path(context.temp_allocator)
				if spawn({exe, "update", "--version", version, "--service", service, "--auto-worker"}) {
					bridge_auto_update_log("check: updating %s -> %s (detached ham-bridge update --auto-worker)", contracts.APP_VERSION, version)
				} else {
					bridge_auto_update_log("check: %s is available, but ham-bridge update could not be started (failures %d; %s)", version, state.failures, next)
					bridge_auto_update_release_admission()
				}
			} else if newer {
				bridge_auto_update_release_admission()
			} else if announced != "" {
				hooks.notify(announced, "failed", 0, fmt.tprintf("Forced auto-update to %s cancelled: no newer release is available now.", announced))
			}
			delete(version)
			quiet_since^ = 0
		}
	}
	// A supervisor that failed before restarting the bridge clears pending.
	if state.pending_version == "" do bridge_auto_update_release_admission()
}

bridge_auto_update_release_admission :: proc() {
	sync.mutex_lock(&bridge_auto_update_mutex)
	bridge_auto_update_reserved_until = 0
	sync.mutex_unlock(&bridge_auto_update_mutex)
}

// bridge_auto_update_force_step advances a forced update (REQ-AUP-4/5). First
// call: resolve the release and, when it is newer, announce the force to the hub
// and persist force_at_ms. Once force_at_ms has passed: close launch admission,
// stop the PTY host and its agents (bridge_update_stop_pty_host, which reaps
// them), then hand off exactly as a quiet update does: persist backoff and
// pending_version, spawn `ham-bridge update --auto-worker`. Lock, verify,
// rollback and backoff are the --auto-worker's, unchanged.
bridge_auto_update_force_step :: proc(
	service, path: string, state: ^Bridge_Auto_Update_State, now: i64,
	resolve: proc() -> string, spawn: proc(argv: []string) -> bool, hooks: Bridge_Auto_Update_Force_Hooks,
) {
	// A notice from long ago (this bridge was down when it fell due) no longer
	// warns anyone: announce again rather than force at once.
	if state.force_at_ms != 0 && now - state.force_at_ms > BRIDGE_AUTO_UPDATE_FORCE_STALE_MS do state.force_at_ms = 0
	if state.force_at_ms == 0 {
		version := resolve()
		defer delete(version)
		if !bridge_auto_update_newer(version, contracts.APP_VERSION) {
			// Nothing to force: the same bookkeeping as a quiet check that found
			// no newer release (or could not look one up).
			if version == "" do state.failures += 1
			else do state.failures = 0
			state.next_check_ms = now + bridge_auto_update_delay(state.failures, rand.uint64())
			_ = bridge_auto_update_write(path, state^)
			bridge_auto_update_clear_wait()
			if version == "" do bridge_auto_update_log("overdue check failed: could not look up the latest release (failures %d; %s)", state.failures, bridge_auto_update_due_text(state.next_check_ms, now))
			else do bridge_auto_update_log("overdue check: up to date (%s, latest %s; %s)", contracts.APP_VERSION, version, bridge_auto_update_due_text(state.next_check_ms, now))
			return
		}
		state.force_at_ms = now + BRIDGE_AUTO_UPDATE_FORCE_NOTICE_MS
		state.force_version = strings.clone(version, context.temp_allocator)
		if !bridge_auto_update_write(path, state^) do return // announce only what will happen
		hooks.notify(version, "preparing", 5, fmt.tprintf(
			"auto-update to %s forcing in ~%d min; %d agents will be stopped (no quiet window for %d h past the scheduled check)",
			version, BRIDGE_AUTO_UPDATE_FORCE_NOTICE_MS / 60_000, hooks.agents(), (now - state.next_check_ms) / (60 * 60 * 1000)))
		return
	}
	if now < state.force_at_ms do return
	if !hooks.reserve() do return // a launch is being prepared; the next tick retries
	version := state.force_version
	hooks.notify(version, "stopping_pty_host", 82, fmt.tprintf("Auto-update to %s: stopping the PTY host and %d agents...", version, hooks.agents()))
	state.force_at_ms, state.force_version = 0, ""
	stopped, detail := hooks.stop()
	if !stopped {
		hooks.release()
		state.failures += 1
		state.next_check_ms = now + bridge_auto_update_delay(state.failures, rand.uint64())
		_ = bridge_auto_update_write(path, state^)
		hooks.notify(version, "failed", 0, fmt.tprintf("Forced auto-update to %s aborted: %s", version, detail))
		return
	}
	hooks.notify(version, "pty_host_stopped", 88, "PTY host and agent processes stopped; stopped agents do not restart on their own.")
	// Persist conservative backoff BEFORE detaching, as the quiet path does.
	state.failures += 1
	state.next_check_ms = now + bridge_auto_update_delay(state.failures, rand.uint64())
	state.pending_version = version
	state.forced_version = version
	failure := ""
	if !bridge_auto_update_write(path, state^) {
		failure = "cannot persist the auto-update state"
	} else {
		exe, _ := os.get_executable_path(context.temp_allocator)
		if !spawn({exe, "update", "--version", version, "--service", service, "--auto-worker"}) do failure = "cannot start ham-bridge update"
	}
	if failure != "" {
		hooks.release()
		state.pending_version, state.forced_version = "", ""
		_ = bridge_auto_update_write(path, state^)
		hooks.notify(version, "failed", 0, fmt.tprintf("Forced auto-update to %s failed: %s; the install was not changed, but the PTY host and its agents were stopped.", version, failure))
		return
	}
	hooks.notify(version, "restarting", 95, "PTY host stopped. Handing off to ham-bridge update...")
}

// bridge_auto_update_cancel_force withdraws an announced force that will not
// happen, so the hub does not keep showing it as imminent.
bridge_auto_update_cancel_force :: proc(path: string, state: ^Bridge_Auto_Update_State, hooks: Bridge_Auto_Update_Force_Hooks, reason: string) {
	if state.force_at_ms == 0 do return
	version := state.force_version
	state.force_at_ms, state.force_version = 0, ""
	_ = bridge_auto_update_write(path, state^)
	hooks.notify(version, "failed", 0, fmt.tprintf("Forced auto-update to %s cancelled: %s.", version, reason))
}

// bridge_auto_update_report_forced reports a forced update's outcome once its
// --auto-worker has finished (bridge_auto_update_finish clears pending_version).
// Setup only restarts the bridge on success, so this process runs the forced
// version iff the update went through; otherwise it was refused or rolled back.
bridge_auto_update_report_forced :: proc(path: string, state: ^Bridge_Auto_Update_State, hooks: Bridge_Auto_Update_Force_Hooks) {
	if state.forced_version == "" || state.pending_version != "" do return
	version := state.forced_version
	if bridge_auto_update_newer(version, contracts.APP_VERSION) {
		hooks.notify(version, "failed", 0, fmt.tprintf("Forced auto-update to %s failed or was rolled back; this bridge still runs %s and retries after backoff.", version, contracts.APP_VERSION))
	} else {
		hooks.notify(version, "succeeded", 100, fmt.tprintf("Forced auto-update to %s succeeded.", version))
	}
	state.forced_version = ""
	_ = bridge_auto_update_write(path, state^)
}

// bridge_auto_update_report_result logs the --auto-worker's recorded outcome
// once it has finished (pending_version cleared in the same write).
bridge_auto_update_report_result :: proc(path: string, state: ^Bridge_Auto_Update_State) {
	if state.last_result == "" || state.pending_version != "" do return
	bridge_auto_update_log("%s (running %s; failures %d; %s)", state.last_result, contracts.APP_VERSION, state.failures,
		bridge_auto_update_due_text(state.next_check_ms, bridge_runtime_now_ms()))
	state.last_result = ""
	_ = bridge_auto_update_write(path, state^)
}

bridge_auto_update_force_hooks :: proc(h: Bridge_Auto_Update_Force_Hooks) -> Bridge_Auto_Update_Force_Hooks {
	out := h
	if out.agents == nil do out.agents = bridge_auto_update_host_agent_count
	if out.reserve == nil do out.reserve = bridge_auto_update_reserve_forced
	if out.release == nil do out.release = bridge_auto_update_release_admission
	if out.stop == nil do out.stop = bridge_auto_update_stop_host
	if out.notify == nil do out.notify = bridge_auto_update_notify
	return out
}

bridge_auto_update_host_agent_count :: proc() -> int {
	socket := pty_host_socket_path()
	defer delete(socket)
	reply, ok := bridge_pty_host_list(socket)
	if !ok do return 0
	defer pty_host_reply_delete(reply)
	return pty_host_running_agent_count(reply.agents) // exited entries have nothing to stop
}

// bridge_auto_update_reserve_forced closes launch admission for the forced
// update regardless of running agents; a launch already being prepared is let
// finish first (it would otherwise start a PTY host beside the update).
bridge_auto_update_reserve_forced :: proc() -> bool {
	sync.mutex_lock(&bridge_auto_update_mutex)
	defer sync.mutex_unlock(&bridge_auto_update_mutex)
	if bridge_auto_update_launches > 0 do return false
	bridge_auto_update_reserved_until = bridge_runtime_now_ms() + 30 * 60_000
	return true
}

bridge_auto_update_stop_host :: proc() -> (bool, string) {
	socket := pty_host_socket_path()
	defer delete(socket)
	return bridge_update_stop_pty_host(socket)
}

// bridge_auto_update_notify logs the line and reports it to the hub as a
// bridge_update_progress frame, the same frame hub-triggered updates send (the
// hub shows it as this bridge's update status). The auto worker owns no hub
// connection, so the frame goes through the runtime loop's outgoing queue; one
// queued while disconnected is sent after the next connect.
bridge_auto_update_notify :: proc(version, stage: string, percent: int, message: string) {
	fmt.eprintfln("bridge auto-update: %s", message)
	context.allocator = runtime.heap_allocator() // the queue frees it on the heap
	bridge_proxy_enqueue(bridge_update_progress_json(fmt.tprintf("auto_update_%s", version), bridge_config.daemon_id, stage, percent, message))
}

// Shared across all hubs/accounts/profiles of the OS user. Kernel ownership
// survives the service stop and is released even when the supervisor crashes.
bridge_auto_update_lock_path :: proc() -> string {
	return bridgesvc.pjoin(bridge_service_host().home, ".heimdall-auto-update.lock")
}

bridge_auto_update_finish :: proc(service: string, success: bool, result := "") {
	path := bridge_auto_update_state_path(service)
	bridge_auto_update_finish_at(path, success, bridge_runtime_now_ms(), rand.uint64(), result)
}

bridge_auto_update_finish_at :: proc(path: string, success: bool, now: i64, entropy: u64, result := "") {
	state := bridge_auto_update_read(path)
	state.pending_version = ""
	state.last_result = result
	if success do state.failures = 0
	else do state.failures = max(1, state.failures)
	state.next_check_ms = now + bridge_auto_update_delay(state.failures, entropy)
	_ = bridge_auto_update_write(path, state)
}

// Update only the bridge section, preserving other settings and comments.
bridge_auto_update_config_text :: proc(text: string, enabled: bool) -> string {
	b := strings.builder_make(allocator = context.temp_allocator)
	inside, seen := false, false
	rest := text
	line_value := "auto_update_enabled = true\n" if enabled else "auto_update_enabled = false\n"
	for line in strings.split_lines_iterator(&rest) {
		trim := strings.trim_space(cfg_lib.strip_comment(line))
		if strings.has_prefix(trim, "[") {
			if inside && !seen {strings.write_string(&b, line_value); seen = true}
			inside = trim == "[bridge]"
		}
		if inside && strings.trim_space(strings.split(trim, "=", context.temp_allocator)[0]) == "auto_update_enabled" {
			if !seen do strings.write_string(&b, line_value)
			seen = true
			continue
		}
		strings.write_string(&b, line); strings.write_byte(&b, '\n')
	}
	if !seen {
		if !inside do strings.write_string(&b, "\n[bridge]\n")
		strings.write_string(&b, line_value)
	}
	return strings.to_string(b)
}

bridge_auto_update_handle_config :: proc(conn: ^ws.Connection, text: string) {
	id := extract_json_string(text, "command_id", "")
	defer delete(id)
	path := cfg_lib.expand_home(cfg_lib.config_path_from_args(os.args))
	ok := true
	if extract_json_bool(text, "write", false) {
		bytes, err := os.read_entire_file(path, context.temp_allocator)
		ok = err == nil
		if ok {
			updated := bridge_auto_update_config_text(string(bytes), extract_json_bool(text, "enabled", true))
			ok = bridge_retry_atomic_write(path, transmute([]byte)updated)
		}
	}
	data, _ := json.marshal(struct {type, command_id: string, ok, enabled: bool}{"auto_update_config_result", id, ok, bridge_auto_update_enabled(path)}, allocator = context.temp_allocator)
	_ = bridge_hub_send(conn, string(data))
}
