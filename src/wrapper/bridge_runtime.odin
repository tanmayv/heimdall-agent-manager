package main

import "core:c"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:thread"
import "core:time"
import tmux "odin_test:lib/tmux"

Bridge_Runtime_Config :: struct {
	bridge_endpoint: string,
	wrapper_token: string,
	child_agent_token: string,
	agent_instance_id: string,
	working_dir: string,
	provider: string,
	tier: string,
	pane_id: string,
	agent_argv: []string,
	liveness_interval_ms: int,
	activity_interval_ms: int,
	antigravity_hooks_path: string,
	// Harness-agnostic pane-capture activity detection. When enabled, the wrapper
	// periodically snapshots the agent's tmux pane and classifies working/idle via
	// pane_activity.odin, reporting with source "pane_diff". Off by default; intended
	// for harnesses without a native activity extension.
	pane_activity_enabled: bool,
	pane_activity_interval_ms: int,
}

wrapper_bridge_runtime_main :: proc(args: []string) -> bool {
	cfg := wrapper_bridge_runtime_config_from_args(args)
	if strings.trim_space(cfg.bridge_endpoint) == "" || strings.trim_space(cfg.wrapper_token) == "" || strings.trim_space(cfg.agent_instance_id) == "" || len(cfg.agent_argv) == 0 {
		fmt.eprintln("ham-wrapper bridge-runtime requires --bridge-endpoint, --agent-token, --agent-instance-id, and child command after --")
		return false
	}
	if strings.trim_space(cfg.child_agent_token) == "" do cfg.child_agent_token = cfg.wrapper_token
	if strings.trim_space(cfg.working_dir) == "" do cfg.working_dir = os.get_env_alloc("PWD", context.allocator)
	if strings.trim_space(cfg.pane_id) == "" do cfg.pane_id = os.get_env_alloc("TMUX_PANE", context.allocator)
	_ = os.make_directory_all(cfg.working_dir)
	// WRP-1: the wrapper materializes the run_dir itself from the bridge socket
	// (list -> per-file fetch -> place), before launching the agent. The bridge no
	// longer needs to pre-write the run_dir; this is the authoritative materializer.
	// A bootstrap failure is fatal — the agent must not start without AGENTS.md +
	// the ham-ctl shim.
	if !wrapper_bridge_materialize_bootstrap(cfg) {
		_ = wrapper_bridge_report_startup(cfg, "startup_failed", "bootstrap materialization failed")
		return false
	}
	// NOTE: the Heimdall pi activity extension has been removed. The harness-agnostic
	// pane-capture detector (source=pane_diff) is now the SOLE activity source for
	// every provider (incl. pi), which eliminated the source-priority conflict where
	// a fresh pi_extension 'active' suppressed a correct pane_diff 'idle' (the stuck
	// 'working · settling' bug). pane_diff is on by default (see
	// wrapper_bridge_pane_activity_default); pi agents launch in tmux so they get a
	// pane_id and the detector runs.
	// Antigravity (agy) hook overlay generation. Opt-in via HEIMDALL_ANTIGRAVITY_HOOKS=1
	// because the exact hooks.json discovery/overlay path on a managed (read-only
	// nix-symlinked ~/.gemini) machine still needs a runtime smoke-test before we
	// auto-wire the launch. When enabled, we write the Heimdall hook script + hooks.json
	// overlay and export HEIMDALL_ANTIGRAVITY_HOOKS_CONFIG so an operator/launcher can
	// point agy at it. See antigravity_adapter.odin + antigravity-hook-decision-spike.md.
	if wrapper_bridge_should_load_antigravity(cfg) && os.get_env_alloc("HEIMDALL_ANTIGRAVITY_HOOKS", context.allocator) == "1" {
		if hooks_path, ok := wrapper_bridge_write_antigravity_hooks(cfg); ok {
			cfg.antigravity_hooks_path = hooks_path
			fmt.eprintln(wrapper_bridge_antigravity_summary(hooks_path))
		} else {
			fmt.eprintln("warning: failed to write Heimdall Antigravity hooks overlay; continuing without hooks")
		}
	}
	_ = wrapper_bridge_report_startup(cfg, "starting", "ham-wrapper bridge runtime starting")

	notify_cfg := new(Bridge_Runtime_Config)
	notify_cfg^ = cfg
	thread.run_with_data(rawptr(notify_cfg), wrapper_bridge_notifications_thread)

	child_env := wrapper_bridge_child_env(cfg)
	process, err := os.process_start(os.Process_Desc{command = cfg.agent_argv, working_dir = cfg.working_dir, env = child_env, stdin = os.stdin, stdout = os.stdout, stderr = os.stderr})
	if err != nil {
		_ = wrapper_bridge_report_startup(cfg, "startup_failed", "agent process launch failed")
		return false
	}
	_ = wrapper_bridge_report_startup(cfg, "ready", "agent child process launched")
	last_liveness := time.to_unix_nanoseconds(time.now())
	last_activity := last_liveness
	pane_cfg := pane_activity_default_config()
	last_pane_cycle := last_liveness
	last_reported_status := ""
	// Env-gated pane-activity debug logging. Read ONCE here (no per-cycle getenv):
	// HEIMDALL_PANE_DEBUG in {1,true,yes,on} => level 1 (structured per-cycle line);
	// {2,verbose} => level 2 (also dumps normalized frame[0] tail). 0/unset => off,
	// zero output and zero behavior change.
	pane_debug_level := wrapper_bridge_pane_debug_level()
	for {
		state, wait_err := os.process_wait(process, 0)
		if wait_err == nil && state.exited {
			_ = wrapper_bridge_local_call(cfg, "wrapper.exited", "{\"reason\":\"child_exited\"}")
			return true
		}
		if strings.trim_space(cfg.pane_id) != "" && !tmux.pane_exists(cfg.pane_id) {
			_ = wrapper_bridge_local_call(cfg, "wrapper.exited", "{\"reason\":\"pane_exited\"}")
			return true
		}
		now := time.to_unix_nanoseconds(time.now())
		if now - last_liveness >= i64(time.Duration(cfg.liveness_interval_ms) * time.Millisecond) {
			// H7 restart-reap: read the bridge's response to the liveness ping. If our
			// local token was invalidated (the bridge relaunched this instance, or the
			// hub reported it running on another bridge), the bridge answers with an
			// auth failure. A superseded old runtime must reap ITSELF: kill the child
			// agent process and exit, so no orphaned ham-wrapper/agent survives a
			// restart regardless of tmux/host/bridge.
			if resp, got := wrapper_bridge_local_call_response(cfg, "wrapper.liveness.ping", "{}"); got && wrapper_bridge_response_is_auth_failure(resp) {
				fmt.eprintln("ham-wrapper: local token invalidated (superseded runtime); terminating child and exiting", cfg.agent_instance_id)
				_ = os.process_kill(process)
				_, _ = os.process_wait(process, 0)
				// Close our own tmux pane so the window disappears as a direct
				// consequence of THIS wrapper self-reaping (e.g. after an operator
				// stop invalidates the token). Without this the login shell that
				// hosts us lingers on its "Agent exited. Press Enter to close..."
				// read, leaving an empty window behind. This is wrapper-side cleanup
				// of its OWN pane — the bridge still issues no tmux/kill commands.
				if strings.trim_space(cfg.pane_id) != "" do _ = tmux.kill_pane(cfg.pane_id)
				return true
			}
			last_liveness = now
		}
		if cfg.pane_activity_enabled && strings.trim_space(cfg.pane_id) != "" {
			// Harness-agnostic path: STATELESS burst detector. Once per cycle
			// (~pane_activity_interval_ms, aligned with the ~2s keepalive) capture a
			// burst of 3 pane-tail snapshots a few hundred ms apart, classify them,
			// and report on status change or on the keepalive so the bridge activity
			// TTL does not expire. No detector state carries across cycles.
			interval := cfg.pane_activity_interval_ms
			if interval <= 0 do interval = 2000
			if now - last_pane_cycle >= i64(time.Duration(interval) * time.Millisecond) {
				last_pane_cycle = now
				samples := pane_cfg.burst_samples
				if samples <= 0 do samples = 3
				frames := make([dynamic]string, 0, samples)
				for s in 0..<samples {
					if raw, ok := tmux.capture_pane_text(cfg.pane_id, pane_cfg.line_limit); ok {
						append(&frames, raw)
					}
					// Gap between snapshots (skip after the final one).
					if s + 1 < samples && pane_cfg.burst_gap_ms > 0 {
						time.sleep(time.Duration(pane_cfg.burst_gap_ms) * time.Millisecond)
					}
				}
				if len(frames) > 0 {
					sample := pane_activity_burst_status(frames[:])
					status := pane_activity_status_string(sample.status)
					keepalive_due := now - last_activity >= i64(time.Duration(cfg.activity_interval_ms) * time.Millisecond)
					// Capture the reporting decision + inputs BEFORE mutating state so the
					// debug logger sees the pre-report last_reported_status and the true
					// ms-since-last-activity that drove the keepalive.
					prev_reported := last_reported_status
					ms_since_activity := (now - last_activity) / i64(time.Millisecond)
					report_sent := false
					reason := "suppressed"
					if status == "unknown" {
						reason = "unknown_status"
					} else if status != last_reported_status {
						reason = "status_changed"
					} else if keepalive_due {
						reason = "keepalive_due"
					}
					if status != "unknown" && (status != last_reported_status || keepalive_due) {
						_ = wrapper_bridge_local_call(cfg, "wrapper.activity.report", wrapper_bridge_pane_activity_report_json(status))
						last_reported_status = status
						last_activity = now
						report_sent = true
					}
					if pane_debug_level > 0 {
						wrapper_bridge_pane_debug_log(cfg, pane_debug_level, sample, report_sent, reason, prev_reported, ms_since_activity, frames[:])
					}
				}
				for f in frames do delete(f)
				delete(frames)
			}
		} else if now - last_activity >= i64(time.Duration(cfg.activity_interval_ms) * time.Millisecond) {
			_ = wrapper_bridge_local_call(cfg, "wrapper.activity.report", "{\"status\":\"idle\"}")
			last_activity = now
		}
		time.sleep(250 * time.Millisecond)
	}
}

wrapper_bridge_pane_activity_report_json :: proc(status: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"status\":\"")
	strings.write_string(&b, status)
	strings.write_string(&b, "\",\"source\":\"pane_diff\"}")
	return strings.to_string(b)
}

// wrapper_bridge_pane_debug_level reads HEIMDALL_PANE_DEBUG ONCE and maps it to a
// verbosity level: 0 = off (default), 1 = per-cycle structured line, 2 = verbose
// (also dump normalized frame[0] tail). Accepts 1/true/yes/on => 1; 2/verbose => 2.
wrapper_bridge_pane_debug_level :: proc() -> int {
	v := strings.to_lower(strings.trim_space(os.get_env_alloc("HEIMDALL_PANE_DEBUG", context.allocator)))
	switch v {
	case "2", "verbose":            return 2
	case "1", "true", "yes", "on": return 1
	}
	return 0
}

// wrapper_bridge_pane_debug_log appends one structured line (Level 1) — and, at
// Level 2, the last `line_limit` NORMALIZED lines of frame[0] — to
// <run-dir>/.heimdall/pane-activity.log. All failures are SILENT: the detection
// loop must never crash or block on logging. Raw pane text is never written at
// Level 1 (hashes only); Level 2's dump is normalized (timers/counters/spinners
// already masked) and size-guarded.
wrapper_bridge_pane_debug_log :: proc(
	cfg: Bridge_Runtime_Config,
	level: int,
	sample: Pane_Activity_Sample,
	report_sent: bool,
	reason: string,
	last_reported_status: string,
	ms_since_last_activity: i64,
	raw_frames: []string,
) {
	if level <= 0 do return
	dir := strings.concatenate({strings.trim_right(cfg.working_dir, "/"), "/.heimdall"})
	_ = os.make_directory_all(dir)
	path := strings.concatenate({dir, "/pane-activity.log"})
	ts := wrapper_bridge_now_iso8601_utc()
	line := pane_activity_debug_line(ts, cfg.agent_instance_id, cfg.pane_id, sample, report_sent, reason, last_reported_status, ms_since_last_activity)
	b := strings.builder_make()
	strings.write_string(&b, line)
	strings.write_byte(&b, '\n')
	if level >= 2 && len(raw_frames) > 0 {
		// Verbose: dump the normalized tail of frame[0] (already masked, size-guarded).
		normalized, _ := pane_normalize(raw_frames[0])
		defer delete(normalized)
		dump := normalized
		if len(dump) > 8192 do dump = dump[:8192]
		strings.write_string(&b, "  frame0_normalized:\n")
		lines := strings.split(dump, "\n")
		defer delete(lines)
		for l in lines {
			strings.write_string(&b, "    | ")
			strings.write_string(&b, l)
			strings.write_byte(&b, '\n')
		}
	}
	file, err := os.open(path, os.O_CREATE | os.O_APPEND | os.O_WRONLY)
	if err != nil do return
	defer os.close(file)
	_, _ = os.write_string(file, strings.to_string(b))
}

// ISO-8601 / RFC3339 UTC timestamp (YYYY-MM-DDTHH:MM:SSZ) for the debug log.
wrapper_bridge_now_iso8601_utc :: proc() -> string {
	now := time.now()
	year, month, day := time.date(now)
	hour, minute, second := time.clock(now)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", year, int(month), day, hour, minute, second)
}

wrapper_bridge_runtime_config_from_args :: proc(args: []string) -> Bridge_Runtime_Config {
	cfg := Bridge_Runtime_Config{
		bridge_endpoint = option_value(args, "--bridge-endpoint", os.get_env_alloc("HEIMDALL_BRIDGE_ENDPOINT", context.allocator)),
		wrapper_token = option_value(args, "--agent-token", os.get_env_alloc("HEIMDALL_WRAPPER_TOKEN", context.allocator)),
		child_agent_token = option_value(args, "--child-agent-token", os.get_env_alloc("HEIMDALL_AGENT_TOKEN", context.allocator)),
		agent_instance_id = option_value(args, "--agent-instance-id", os.get_env_alloc("HEIMDALL_AGENT_INSTANCE_ID", context.allocator)),
		working_dir = option_value(args, "--run-dir", option_value(args, "--cwd", os.get_env_alloc("PWD", context.allocator))),
		provider = option_value(args, "--provider", ""),
		tier = option_value(args, "--tier", ""),
		pane_id = option_value(args, "--pane-id", os.get_env_alloc("TMUX_PANE", context.allocator)),
		liveness_interval_ms = wrapper_bridge_int_arg(args, "--liveness-interval-ms", 1000),
		activity_interval_ms = wrapper_bridge_int_arg(args, "--activity-interval-ms", 2000),
		// Harness-agnostic pane-capture activity detection is ON by default for all
		// harnesses (incl. pi). Where a harness also has a native activity extension,
		// the extension outranks pane_diff (see bridge activity source ranking), so
		// this acts as a complementary fallback. Opt out with --no-pane-activity or
		// HEIMDALL_WRAPPER_PANE_ACTIVITY=0.
		pane_activity_enabled = wrapper_bridge_pane_activity_default(args),
		pane_activity_interval_ms = wrapper_bridge_int_arg(args, "--pane-activity-interval-ms", 2000),
	}
	if sep := wrapper_bridge_command_separator(args); sep >= 0 && sep + 1 < len(args) {
		cmd := make([dynamic]string)
		for i := sep + 1; i < len(args); i += 1 do append(&cmd, strings.clone(args[i]))
		cfg.agent_argv = cmd[:]
	}
	return cfg
}

wrapper_bridge_command_separator :: proc(args: []string) -> int {
	for arg, i in args { if arg == "--" do return i }
	return -1
}

wrapper_bridge_int_arg :: proc(args: []string, key: string, fallback: int) -> int {
	value := option_value(args, key, "")
	if value == "" do return fallback
	parsed, ok := strconv.parse_int(value)
	if !ok do return fallback
	return int(parsed)
}

wrapper_bridge_env_flag :: proc(name: string) -> bool {
	v := strings.to_lower(strings.trim_space(os.get_env_alloc(name, context.allocator)))
	return v == "1" || v == "true" || v == "yes" || v == "on"
}

// Pane-activity detection defaults ON. Explicit opt-out wins over opt-in:
//   --no-pane-activity or HEIMDALL_WRAPPER_PANE_ACTIVITY in {0,false,no,off}.
wrapper_bridge_pane_activity_default :: proc(args: []string) -> bool {
	if has_flag(args, "--no-pane-activity") do return false
	env := strings.to_lower(strings.trim_space(os.get_env_alloc("HEIMDALL_WRAPPER_PANE_ACTIVITY", context.allocator)))
	if env == "0" || env == "false" || env == "no" || env == "off" do return false
	return true
}

wrapper_bridge_child_env :: proc(cfg: Bridge_Runtime_Config) -> []string {
	env, err := os.environ(context.allocator)
	if err != nil do env = make([]string, 0)
	defer {
		for item in env do delete(item)
		delete(env)
	}
	out := make([dynamic]string)
	for item in env {
		if strings.has_prefix(item, "HEIMDALL_BRIDGE_ENDPOINT=") || strings.has_prefix(item, "HEIMDALL_AGENT_TOKEN=") || strings.has_prefix(item, "HEIMDALL_AGENT_INSTANCE_ID=") || strings.has_prefix(item, "HEIMDALL_CTL_BIN=") do continue
		append(&out, strings.clone(item))
	}
	append(&out, strings.concatenate({"HEIMDALL_BRIDGE_ENDPOINT=", cfg.bridge_endpoint}))
	append(&out, strings.concatenate({"HEIMDALL_AGENT_TOKEN=", cfg.child_agent_token}))
	append(&out, strings.concatenate({"HEIMDALL_AGENT_INSTANCE_ID=", cfg.agent_instance_id}))
	append(&out, strings.concatenate({"HEIMDALL_CTL_BIN=", strings.trim_right(cfg.working_dir, "/"), "/.heimdall/bin/ham-ctl"}))
	if strings.trim_space(cfg.antigravity_hooks_path) != "" {
		append(&out, strings.concatenate({"HEIMDALL_ANTIGRAVITY_HOOKS_CONFIG=", cfg.antigravity_hooks_path}))
	}
	return out[:]
}

wrapper_bridge_report_startup :: proc(cfg: Bridge_Runtime_Config, phase, detail: string) -> bool {
	b := strings.builder_make()
	strings.write_string(&b, "{\"phase\":\""); json_write_string(&b, phase)
	strings.write_string(&b, "\",\"detail\":\""); json_write_string(&b, detail)
	if strings.trim_space(cfg.pane_id) != "" { strings.write_string(&b, "\",\"pane_id\":\""); json_write_string(&b, cfg.pane_id) }
	strings.write_string(&b, "\"}")
	return wrapper_bridge_local_call(cfg, "wrapper.startup.report", strings.to_string(b))
}

wrapper_bridge_jsonl_request :: proc(token, method, params_json: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"v\":1,\"id\":\"ham-wrapper-bridge-runtime\",\"token\":\"")
	json_write_string(&b, token)
	strings.write_string(&b, "\",\"method\":\"")
	json_write_string(&b, method)
	strings.write_string(&b, "\",\"params\":")
	if strings.trim_space(params_json) == "" { strings.write_string(&b, "{}") } else { strings.write_string(&b, params_json) }
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

wrapper_bridge_local_call :: proc(cfg: Bridge_Runtime_Config, method, params_json: string) -> bool {
	request := wrapper_bridge_jsonl_request(cfg.wrapper_token, method, params_json)
	if strings.has_prefix(cfg.bridge_endpoint, "tcp:") do return wrapper_bridge_send_tcp(cfg.bridge_endpoint, request)
	if strings.has_prefix(cfg.bridge_endpoint, "unix:") do return wrapper_bridge_send_unix(cfg.bridge_endpoint, request)
	return false
}

// wrapper_bridge_local_call_response performs a local-endpoint call and RETURNS
// the bridge's response line (not just fire-and-forget). Used by the liveness
// ping so the wrapper can detect that its token was invalidated (H7 restart-reap):
// on a superseded old runtime the bridge answers with an auth-failure error and
// the wrapper self-terminates. Returns (response, true) on a completed round-trip.
wrapper_bridge_local_call_response :: proc(cfg: Bridge_Runtime_Config, method, params_json: string) -> (string, bool) {
	request := wrapper_bridge_jsonl_request(cfg.wrapper_token, method, params_json)
	if strings.has_prefix(cfg.bridge_endpoint, "tcp:") do return wrapper_bridge_send_tcp_response(cfg.bridge_endpoint, request)
	if strings.has_prefix(cfg.bridge_endpoint, "unix:") do return wrapper_bridge_send_unix_response(cfg.bridge_endpoint, request)
	return "", false
}

// wrapper_bridge_response_is_auth_failure classifies a bridge local-endpoint
// response as an authentication failure => this runtime has been superseded and
// must self-terminate. The bridge emits {"ok":false,...,"error":{"code":"..."}}
// where code is "unauthenticated" (token invalid/rotated) or "forbidden". Pure
// string classifier so it is unit-testable without a live bridge. A blank or
// transport-failed response (ok=false at the call site) is NOT treated as an auth
// failure here — only an explicit auth error code triggers termination, so a
// transient bridge hiccup never kills a healthy agent.
wrapper_bridge_response_is_auth_failure :: proc(response: string) -> bool {
	if strings.trim_space(response) == "" do return false
	if !strings.contains(response, "\"ok\":false") do return false
	return strings.contains(response, "\"unauthenticated\"") || strings.contains(response, "\"code\":\"forbidden\"")
}

wrapper_bridge_send_tcp :: proc(endpoint, request: string) -> bool {
	parts := strings.split(endpoint, ":")
	defer delete(parts)
	if len(parts) < 3 do return false
	port := wrapper_bridge_int_string(parts[2])
	address := net.IP4_Loopback
	if parsed, ok := net.parse_ip4_address(parts[1]); ok do address = parsed
	conn, err := net.dial_tcp(address, port)
	if err != nil do return false
	defer net.close(conn)
	_, send_err := net.send_tcp(conn, transmute([]byte)request)
	return send_err == nil
}

wrapper_bridge_send_unix :: proc(endpoint, request: string) -> bool {
	path := strings.trim_prefix(endpoint, "unix:")
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return false
	defer posix.close(fd)
	addr: posix.sockaddr_un
	when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD || ODIN_OS == .Haiku { addr.sun_len = c.uchar(size_of(addr)) }
	addr.sun_family = .UNIX
	for i in 0..<len(path) do addr.sun_path[i] = c.char(path[i])
	addr.sun_path[len(path)] = 0
	if posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK do return false
	bytes := transmute([]byte)request
	return posix.send(fd, raw_data(bytes), c.size_t(len(bytes)), {}) >= 0
}

// wrapper_bridge_send_tcp_response sends a request and reads the single-line
// response from the bridge local endpoint (one request -> one response line).
wrapper_bridge_send_tcp_response :: proc(endpoint, request: string) -> (string, bool) {
	parts := strings.split(endpoint, ":")
	defer delete(parts)
	if len(parts) < 3 do return "", false
	port := wrapper_bridge_int_string(parts[2])
	address := net.IP4_Loopback
	if parsed, ok := net.parse_ip4_address(parts[1]); ok do address = parsed
	conn, err := net.dial_tcp(address, port)
	if err != nil do return "", false
	defer net.close(conn)
	if _, send_err := net.send_tcp(conn, transmute([]byte)request); send_err != nil do return "", false
	buf: [8192]byte
	pending := ""
	for {
		n, recv_err := net.recv_tcp(conn, buf[:])
		if n > 0 do pending = strings.concatenate({pending, string(buf[:n])})
		if idx := strings.index_byte(pending, '\n'); idx >= 0 do return strings.trim_space(pending[:idx]), true
		if recv_err != nil || n <= 0 {
			if strings.trim_space(pending) != "" do return strings.trim_space(pending), true
			return "", false
		}
	}
}

// wrapper_bridge_send_unix_response is the Unix-socket analog of the above.
wrapper_bridge_send_unix_response :: proc(endpoint, request: string) -> (string, bool) {
	path := strings.trim_prefix(endpoint, "unix:")
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return "", false
	defer posix.close(fd)
	addr: posix.sockaddr_un
	when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD || ODIN_OS == .Haiku { addr.sun_len = c.uchar(size_of(addr)) }
	addr.sun_family = .UNIX
	for i in 0..<len(path) do addr.sun_path[i] = c.char(path[i])
	addr.sun_path[len(path)] = 0
	if posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK do return "", false
	bytes := transmute([]byte)request
	if posix.send(fd, raw_data(bytes), c.size_t(len(bytes)), {}) < 0 do return "", false
	buf: [8192]byte
	pending := ""
	for {
		n := posix.recv(fd, raw_data(buf[:]), c.size_t(len(buf)), {})
		if n > 0 do pending = strings.concatenate({pending, string(buf[:int(n)])})
		if idx := strings.index_byte(pending, '\n'); idx >= 0 do return strings.trim_space(pending[:idx]), true
		if n <= 0 {
			if strings.trim_space(pending) != "" do return strings.trim_space(pending), true
			return "", false
		}
	}
}

wrapper_bridge_int_string :: proc(value: string) -> int {
	parsed, ok := strconv.parse_int(strings.trim_space(value))
	if !ok do return 0
	return int(parsed)
}

wrapper_bridge_notifications_thread :: proc(data: rawptr) {
	if data == nil do return
	cfg := (^Bridge_Runtime_Config)(data)^
	backoff_ms := 250
	for {
		if strings.trim_space(cfg.pane_id) != "" && !tmux.pane_exists(cfg.pane_id) do return
		connected := wrapper_bridge_notifications_subscribe_loop(cfg)
		if connected { backoff_ms = 250 } else if backoff_ms < 30000 { backoff_ms *= 2 }
		time.sleep(time.Duration(backoff_ms) * time.Millisecond)
	}
}

wrapper_bridge_notifications_subscribe_loop :: proc(cfg: Bridge_Runtime_Config) -> bool {
	request := wrapper_bridge_jsonl_request(cfg.wrapper_token, "wrapper.notifications.subscribe", "{}")
	if strings.has_prefix(cfg.bridge_endpoint, "tcp:") do return wrapper_bridge_subscribe_tcp(cfg, request)
	if strings.has_prefix(cfg.bridge_endpoint, "unix:") do return wrapper_bridge_subscribe_unix(cfg, request)
	return false
}

wrapper_bridge_subscribe_tcp :: proc(cfg: Bridge_Runtime_Config, request: string) -> bool {
	parts := strings.split(cfg.bridge_endpoint, ":")
	defer delete(parts)
	if len(parts) < 3 do return false
	port := wrapper_bridge_int_string(parts[2])
	address := net.IP4_Loopback
	if parsed, ok := net.parse_ip4_address(parts[1]); ok do address = parsed
	conn, err := net.dial_tcp(address, port)
	if err != nil do return false
	defer net.close(conn)
	_, send_err := net.send_tcp(conn, transmute([]byte)request)
	if send_err != nil do return false
	buf: [8192]byte
	pending := ""
	subscribed := false
	for {
		n, recv_err := net.recv_tcp(conn, buf[:])
		if recv_err != nil || n <= 0 do return subscribed
		subscribed = true
		pending = strings.concatenate({pending, string(buf[:n])})
		wrapper_bridge_dispatch_push_lines(cfg, &pending)
	}
}

wrapper_bridge_subscribe_unix :: proc(cfg: Bridge_Runtime_Config, request: string) -> bool {
	path := strings.trim_prefix(cfg.bridge_endpoint, "unix:")
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return false
	defer posix.close(fd)
	addr: posix.sockaddr_un
	when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD || ODIN_OS == .Haiku { addr.sun_len = c.uchar(size_of(addr)) }
	addr.sun_family = .UNIX
	for i in 0..<len(path) do addr.sun_path[i] = c.char(path[i])
	addr.sun_path[len(path)] = 0
	if posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK do return false
	bytes := transmute([]byte)request
	if posix.send(fd, raw_data(bytes), c.size_t(len(bytes)), {}) < 0 do return false
	buf: [8192]byte
	pending := ""
	subscribed := false
	for {
		n := posix.recv(fd, raw_data(buf[:]), c.size_t(len(buf)), {})
		if n <= 0 do return subscribed
		subscribed = true
		pending = strings.concatenate({pending, string(buf[:int(n)])})
		wrapper_bridge_dispatch_push_lines(cfg, &pending)
	}
}

wrapper_bridge_dispatch_push_lines :: proc(cfg: Bridge_Runtime_Config, pending: ^string) {
	for {
		idx := strings.index_byte(pending^, '\n')
		if idx < 0 do return
		line := strings.trim_space((pending^)[:idx])
		pending^ = (pending^)[idx + 1:]
		if line == "" do continue
		if strings.contains(line, "\"push\":\"startup_prompt\"") {
			wrapper_bridge_deliver_startup_prompt(cfg)
			continue
		}
		if strings.contains(line, "\"push\":\"pane_capture_request\"") {
			wrapper_bridge_handle_pane_capture_request(cfg, line)
			continue
		}
		if strings.contains(line, "\"push\":\"permission_request\"") { wrapper_bridge_deliver_permission_request_push(cfg, line); continue }
		if strings.contains(line, "\"push\":\"permission_reply\"") { wrapper_bridge_deliver_permission_reply_push(cfg, line); continue }
		if strings.contains(line, "\"push\":\"agent_message\"") do wrapper_bridge_deliver_message_push(cfg, line)
		if strings.contains(line, "\"push\":\"task_nudge\"") do wrapper_bridge_deliver_task_nudge_push(cfg, line)
	}
}

// Permission relay pushes are primarily consumed by the Pi extension's own blocking
// socket round-trip (the gate). The wrapper mirrors them to the TTY so a local user
// sees the pending approval and how it resolved (observe + mirror), matching the
// Antigravity reference pattern.
wrapper_bridge_deliver_permission_request_push :: proc(cfg: Bridge_Runtime_Config, line: string) {
	request_id := extract_json_string(line, "request_id", "")
	tool := extract_json_string(line, "tool", "tool")
	risk := extract_json_string(line, "risk", "unknown")
	pane := wrapper_bridge_prompt_pane(cfg)
	if strings.trim_space(pane) == "" do return
	msg := strings.concatenate({"Permission requested: ", tool, " (risk=", risk, ", request_id=", request_id, "). Answer via ham-ctl agent permission reply or the Heimdall UI."})
	_ = tmux.send_text(pane, msg, true)
}

wrapper_bridge_deliver_permission_reply_push :: proc(cfg: Bridge_Runtime_Config, line: string) {
	request_id := extract_json_string(line, "request_id", "")
	decision := extract_json_string(line, "decision", "deny")
	pane := wrapper_bridge_prompt_pane(cfg)
	if strings.trim_space(pane) == "" do return
	msg := strings.concatenate({"Permission ", decision, " for request_id=", request_id, "."})
	_ = tmux.send_text(pane, msg, true)
}

wrapper_bridge_handle_pane_capture_request :: proc(cfg: Bridge_Runtime_Config, line: string) {
	command_id := extract_json_string(line,"command_id","")
	req_id := extract_json_string(line,"pane_capture_request_id","")
	message_id := extract_json_string(line,"message_id","")
	if extract_json_int(line,"protocol_version",0) != 1 { _ = wrapper_bridge_pane_capture_failure(cfg,command_id,req_id,message_id,"unsupported_capture_agent_pane","The pane capture request protocol is not supported."); return }
	width := wrapper_bridge_clamp_int(extract_json_int(line,"width",80),40,200)
	settle_ms := wrapper_bridge_clamp_int(extract_json_int(line,"settle_ms",3000),500,10000)
	line_limit := wrapper_bridge_clamp_int(extract_json_int(line,"line_limit",120),20,300)
	pane := wrapper_bridge_prompt_pane(cfg)
	if strings.trim_space(pane)=="" || !tmux.pane_exists(pane) { _ = wrapper_bridge_pane_capture_failure(cfg,command_id,req_id,message_id,"pane_not_running","The agent tmux pane is no longer running."); return }
	if !tmux.resize_pane_width(pane,width) { _ = wrapper_bridge_pane_capture_failure(cfg,command_id,req_id,message_id,"resize_failed","The agent pane could not be resized before capture."); return }
	time.sleep(time.Duration(settle_ms) * time.Millisecond)
	output,captured := tmux.capture_pane_text(pane,line_limit)
	if !captured { _ = wrapper_bridge_pane_capture_failure(cfg,command_id,req_id,message_id,"capture_failed","The agent pane could not be captured."); return }
	sanitized,line_count,truncated := wrapper_bridge_sanitize_capture(output,48000)
	b:=strings.builder_make(); strings.write_string(&b,"{\"command_id\":\""); json_write_string(&b,command_id); strings.write_string(&b,"\",\"pane_capture_request_id\":\""); json_write_string(&b,req_id); strings.write_string(&b,"\",\"message_id\":\""); json_write_string(&b,message_id); strings.write_string(&b,"\",\"ok\":true,\"output\":\""); json_write_string(&b,sanitized); strings.write_string(&b,"\",\"width\":"); strings.write_string(&b,fmt.tprintf("%d",width)); strings.write_string(&b,",\"line_count\":"); strings.write_string(&b,fmt.tprintf("%d",line_count)); strings.write_string(&b,",\"truncated\":"); strings.write_string(&b,"true" if truncated else "false"); strings.write_string(&b,"}")
	_ = wrapper_bridge_local_call(cfg,"wrapper.pane_capture.result",strings.to_string(b))
}

wrapper_bridge_pane_capture_failure :: proc(cfg:Bridge_Runtime_Config,command_id,req_id,message_id,error_code,message:string)->bool{ b:=strings.builder_make(); strings.write_string(&b,"{\"command_id\":\""); json_write_string(&b,command_id); strings.write_string(&b,"\",\"pane_capture_request_id\":\""); json_write_string(&b,req_id); strings.write_string(&b,"\",\"message_id\":\""); json_write_string(&b,message_id); strings.write_string(&b,"\",\"ok\":false,\"error_code\":\""); json_write_string(&b,error_code); strings.write_string(&b,"\",\"message\":\""); json_write_string(&b,message); strings.write_string(&b,"\"}"); return wrapper_bridge_local_call(cfg,"wrapper.pane_capture.result",strings.to_string(b)) }

wrapper_bridge_clamp_int :: proc(v,min,max:int)->int{ out:=v; if out<min do out=min; if out>max do out=max; return out }
wrapper_bridge_sanitize_capture :: proc(value:string,max_bytes:int)->(string,int,bool){ b:=strings.builder_make(); line_count:=0; last_newline:=true; truncated:=false; esc:=false; for i:=0; i<len(value); i+=1 { ch:=value[i]; if esc { if ch>='@' && ch<='~' do esc=false; continue }; if ch==0x1b { esc=true; continue }; if ch<32 && ch!='\n' && ch!='\r' && ch!='\t' do continue; if strings.builder_len(b)>=max_bytes { truncated=true; break }; if ch=='\r' do continue; strings.write_byte(&b,ch); if ch=='\n' { line_count+=1; last_newline=true } else { last_newline=false } }; if !last_newline do line_count+=1; return strings.to_string(b),line_count,truncated }

wrapper_bridge_deliver_message_push :: proc(cfg: Bridge_Runtime_Config, line: string) {
	sender := extract_json_string(line, "sender_agent_instance_id", extract_json_string(line, "sender", "user"))
	if strings.trim_space(sender) == "" do sender = "user"
	pane := wrapper_bridge_prompt_pane(cfg)
	if strings.trim_space(pane) == "" do return
	msg := strings.concatenate({"New message from ", sender, " — run './.heimdall/bin/ham-ctl agent chat read' to view."})
	_ = tmux.send_text(pane, msg, true)
}

wrapper_bridge_deliver_task_nudge_push :: proc(cfg: Bridge_Runtime_Config, line: string) {
	task_id := extract_json_string(line, "task_id", "unknown")
	target_role := extract_json_string(line, "target_role", "participant")
	pane := wrapper_bridge_prompt_pane(cfg)
	if strings.trim_space(pane) == "" do return
	msg := strings.concatenate({"Nudge: you have been nudged on ", task_id, " (", target_role, "). Run './.heimdall/bin/ham-ctl tasks list' and complete your assignment."})
	_ = tmux.send_text(pane, msg, true)
}
wrapper_bridge_deliver_startup_prompt :: proc(cfg: Bridge_Runtime_Config) {
	pane := wrapper_bridge_prompt_pane(cfg)
	if strings.trim_space(pane) == "" do return
	msg := "Heimdall is still waiting for startup acknowledgement. If you are ready, run './.heimdall/bin/ham-ctl agent start-success'."
	_ = tmux.send_text(pane, msg, true)
}

wrapper_bridge_prompt_pane :: proc(cfg: Bridge_Runtime_Config) -> string {
	pane := cfg.pane_id
	if strings.trim_space(pane) == "" do pane = os.get_env_alloc("TMUX_PANE", context.allocator)
	return pane
}
