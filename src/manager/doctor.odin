// heimdall doctor: read-only diagnostics for this node. Verifies the pieces
// that must line up for the heimdall-bridge service to run: enrollment files,
// filesystem permissions, the loopback endpoint (:49323), the local endpoint
// port (:49324), the service unit, and the coding harnesses the bridge can
// launch. Exits 1 iff any check FAILs; warnings never fail the run.
package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import http "odin_test:lib/http_client"
import cfg_lib "odin_test:lib/config"

Manager_Check_Status :: enum {
	Ok,
	Warn,
	Fail,
}

Manager_Check :: struct {
	name:   string,
	status: Manager_Check_Status,
	detail: string,
}

Manager_Loopback_Probe :: enum {
	Not_Listening,
	Heimdall_Ok,
	Heimdall_Unauthorized,
	Heimdall_Responding,
	Other_Service,
}

Manager_Harness :: struct {
	name: string, // harness label, as reported by ham-ctl setup
	bin:  string, // command to detect on PATH
}

// The harness set mirrors ham-ctl setup (src/ctl/setup.odin): the companions a
// bridge can launch.
MANAGER_DOCTOR_HARNESSES :: []Manager_Harness {
	{name = "pi", bin = "pi"},
	{name = "antigravity", bin = "agy"},
	{name = "claude", bin = "claude"},
	{name = "codex", bin = "codex"},
}

manager_tcp_probe :: proc(port: int) -> bool {
	socket, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = port})
	if err != nil do return false
	net.close(socket)
	return true
}

// manager_probe_bridge_loopback probes the given loopback port and, when the
// port answers, asks /bridge/health who is listening. Returns the
// classification and a short human-readable detail for the report.
manager_probe_bridge_loopback :: proc(port: int, token: string) -> (Manager_Loopback_Probe, string) {
	if !manager_tcp_probe(port) {
		return .Not_Listening, "not listening"
	}
	base_url := fmt.tprintf("http://127.0.0.1:%d", port)
	resp: http.Response
	ok: bool
	if strings.trim_space(token) != "" {
		headers := [?]http.Header{{name = "Authorization", value = strings.concatenate({"Bearer ", token})}}
		resp, ok = http.request_with_headers_timeout("GET", base_url, "/bridge/health", "", headers[:], MANAGER_PROBE_TIMEOUT_MS)
	} else {
		resp, ok = http.request_with_timeout("GET", base_url, "/bridge/health", "", MANAGER_PROBE_TIMEOUT_MS)
	}
	probe := manager_classify_loopback_probe(true, ok, resp.status, resp.body)
	switch probe {
	case .Heimdall_Ok:
		return probe, strings.concatenate({"healthy (", manager_health_summary(resp.body), ")"})
	case .Heimdall_Unauthorized:
		return probe, fmt.tprintf("heimdall bridge responding (HTTP %d, token required)", resp.status)
	case .Heimdall_Responding:
		return probe, fmt.tprintf("heimdall bridge responding (HTTP %d)", resp.status)
	case .Other_Service:
		if !ok do return probe, "port open but not an HTTP service"
		return probe, fmt.tprintf("HTTP %d from a non-heimdall service", resp.status)
	case .Not_Listening:
		return probe, "not listening"
	}
	return probe, ""
}

manager_classify_loopback_probe :: proc(port_open, http_ok: bool, status: int, body: string) -> Manager_Loopback_Probe {
	if !port_open do return .Not_Listening
	if !http_ok do return .Other_Service
	if status == 200 && strings.contains(body, "\"ok\":true") do return .Heimdall_Ok
	if status == 401 || strings.contains(body, "bridge loopback unauthorized") do return .Heimdall_Unauthorized
	if strings.contains(body, "contract_version") || strings.contains(body, "unsupported_route") do return .Heimdall_Responding
	return .Other_Service
}

manager_health_summary :: proc(body: string) -> string {
	contract := manager_extract_json_string(body, "contract_version", "")
	frame := manager_extract_json_string(body, "ws_frame_version", "")
	if contract == "" do return "ok"
	return fmt.tprintf("contract %s, ws frame %s", contract, frame)
}

// manager_unit_present_argv / manager_unit_present report whether the service
// manager knows the unit (systemd) or the LaunchAgent plist is installed.
manager_unit_present :: proc(platform: Manager_Platform, unit, plist_path: string) -> bool {
	switch platform {
	case .Linux:
		_, _, ok := manager_run_capture({"systemctl", "--user", "cat", unit})
		return ok
	case .Darwin:
		return manager_path_exists(plist_path)
	case .Unsupported:
		return false
	}
	return false
}

manager_doctor_command :: proc(args: []string) -> int {
	platform := manager_host_platform()
	config_path := manager_config_path(args)
	load_result, config_loaded := cfg_lib.load(config_path)
	hub_url := ""
	bridge_id := ""
	config_token := ""
	data_dir := ""
	if config_loaded {
		hub_url = load_result.config.wrapper.daemon_url
		if hub_url == "" do hub_url = load_result.config.ctl.daemon_url
		bridge_id = load_result.config.daemon.daemon_id
		config_token = load_result.config.daemon.bridge_token
		data_dir = load_result.config.daemon.data_dir
	}
	token_path := manager_token_path(args, config_path)
	token := manager_read_token_file(token_path)
	token_from_file := token != ""
	if !token_from_file do token = config_token

	checks := make([dynamic]Manager_Check, 0, 16)
	defer delete(checks)

	// Enrollment.
	if hub_url != "" && bridge_id != "" {
		append(&checks, Manager_Check{name = "enrollment", status = .Ok, detail = fmt.tprintf("enrolled as %s (hub %s)", bridge_id, hub_url)})
	} else {
		append(&checks, Manager_Check{name = "enrollment", status = .Warn, detail = "not enrolled — run: heimdall enroll hbe_... --hub <url>"})
	}

	// Bridge token file and its permissions.
	if token_from_file {
		fi, stat_err := os.stat(token_path, context.allocator)
		if stat_err == nil {
			mode := manager_permissions_mode(fi.mode)
			os.file_info_delete(fi, context.allocator)
			if mode & 0o077 == 0 {
				append(&checks, Manager_Check{name = "token file", status = .Ok, detail = fmt.tprintf("%s (mode %s)", token_path, manager_mode_string(mode))})
			} else {
				append(&checks, Manager_Check{name = "token file", status = .Fail, detail = fmt.tprintf("%s has insecure mode %s (group/other bits set) — fix: chmod 600 %s", token_path, manager_mode_string(mode), token_path)})
			}
		}
	} else if strings.trim_space(config_token) != "" {
		append(&checks, Manager_Check{name = "token file", status = .Warn, detail = fmt.tprintf("no token file at %s; using [daemon] bridge_token from config.toml (service units expect the file)", token_path)})
	} else {
		append(&checks, Manager_Check{name = "token file", status = .Warn, detail = fmt.tprintf("no bridge token at %s — enroll this node", token_path)})
	}

	// Config directory writability (enroll rewrites config.toml + token here).
	config_dir := manager_dir_of(config_path)
	if manager_is_dir(config_dir) {
		if manager_write_probe(config_dir) {
			append(&checks, Manager_Check{name = "config dir", status = .Ok, detail = fmt.tprintf("%s writable", config_dir)})
		} else {
			append(&checks, Manager_Check{name = "config dir", status = .Fail, detail = fmt.tprintf("%s is not writable", config_dir)})
		}
	} else {
		append(&checks, Manager_Check{name = "config dir", status = .Warn, detail = fmt.tprintf("%s missing (created by heimdall enroll)", config_dir)})
	}

	// Data directory writability (bridge writes bootstrap cache/artifacts here).
	// The config default carries a literal "~", so always expand first.
	raw_data_dir := data_dir if data_dir != "" else MANAGER_DEFAULT_DATA_DIR
	effective_data_dir := cfg_lib.expand_home(raw_data_dir)
	if manager_is_dir(effective_data_dir) {
		if manager_write_probe(effective_data_dir) {
			append(&checks, Manager_Check{name = "data dir", status = .Ok, detail = fmt.tprintf("%s writable", effective_data_dir)})
		} else {
			append(&checks, Manager_Check{name = "data dir", status = .Fail, detail = fmt.tprintf("%s is not writable — the bridge cannot persist its cache", effective_data_dir)})
		}
	} else {
		parent := manager_nearest_existing_dir(effective_data_dir)
		if parent == "" || !manager_write_probe(parent) {
			append(&checks, Manager_Check{name = "data dir", status = .Fail, detail = fmt.tprintf("%s cannot be created (no writable parent)", effective_data_dir)})
		} else {
			append(&checks, Manager_Check{name = "data dir", status = .Ok, detail = fmt.tprintf("%s absent — created on first bridge run", effective_data_dir)})
		}
	}

	// Bridge loopback endpoint (the service's health contract).
	probe, probe_detail := manager_probe_bridge_loopback(MANAGER_LOOPBACK_PORT, token)
	switch probe {
	case .Heimdall_Ok, .Heimdall_Responding:
		append(&checks, Manager_Check{name = fmt.tprintf("bridge :%d", MANAGER_LOOPBACK_PORT), status = .Ok, detail = probe_detail})
	case .Heimdall_Unauthorized:
		if token != "" {
			append(&checks, Manager_Check{name = fmt.tprintf("bridge :%d", MANAGER_LOOPBACK_PORT), status = .Fail, detail = "bridge rejected the stored token (401) — re-run: heimdall enroll <hbe_...> --hub <url>"})
		} else {
			append(&checks, Manager_Check{name = fmt.tprintf("bridge :%d", MANAGER_LOOPBACK_PORT), status = .Ok, detail = probe_detail})
		}
	case .Other_Service:
		append(&checks, Manager_Check{name = fmt.tprintf("bridge :%d", MANAGER_LOOPBACK_PORT), status = .Fail, detail = fmt.tprintf("port %d is held by another service — free it for heimdall-bridge", MANAGER_LOOPBACK_PORT)})
	case .Not_Listening:
		append(&checks, Manager_Check{name = fmt.tprintf("bridge :%d", MANAGER_LOOPBACK_PORT), status = .Fail, detail = "bridge is not listening — start it: heimdall start"})
	}

	// Local endpoint port: the bridge prefers a unix socket and only falls back
	// to TCP here, so "not listening" is normal and never a failure.
	if manager_tcp_probe(MANAGER_LOCAL_ENDPOINT_PORT) {
		append(&checks, Manager_Check{name = fmt.tprintf("local endpoint :%d", MANAGER_LOCAL_ENDPOINT_PORT), status = .Ok, detail = "listening (proxy/shell input fallback)"})
	} else {
		append(&checks, Manager_Check{name = fmt.tprintf("local endpoint :%d", MANAGER_LOCAL_ENDPOINT_PORT), status = .Ok, detail = "not listening (unix socket mode is the default; fallback only)"})
	}

	// Service unit / agent presence.
	plist_path := manager_launchd_plist_path()
	if platform == .Unsupported {
		append(&checks, Manager_Check{name = "service unit", status = .Fail, detail = "unsupported platform (service management requires Linux or macOS)"})
	} else if manager_unit_present(platform, MANAGER_SERVICE_UNIT, plist_path) {
		location := MANAGER_SERVICE_UNIT if platform == .Linux else plist_path
		append(&checks, Manager_Check{name = "service unit", status = .Ok, detail = fmt.tprintf("%s present", location)})
	} else if platform == .Linux {
		append(&checks, Manager_Check{name = "service unit", status = .Fail, detail = fmt.tprintf("systemd user unit %s not found — install it (nix/home-manager or scripts/install.sh)", MANAGER_SERVICE_UNIT)})
	} else {
		append(&checks, Manager_Check{name = "service unit", status = .Fail, detail = fmt.tprintf("%s not found — install it (nix/home-manager or scripts/install.sh)", plist_path)})
	}

	// Coding harnesses are optional: report, never fail.
	for harness in MANAGER_DOCTOR_HARNESSES {
		if path, found := manager_bin_on_path(harness.bin); found {
			append(&checks, Manager_Check{name = fmt.tprintf("harness %s", harness.name), status = .Ok, detail = path})
		} else {
			append(&checks, Manager_Check{name = fmt.tprintf("harness %s", harness.name), status = .Warn, detail = fmt.tprintf("%s not found on PATH (harness optional)", harness.bin)})
		}
	}

	fmt.printfln("heimdall doctor — %s (%s/%s)", config_path, manager_os_string(), manager_arch_string())
	ok_count, warn_count, fail_count := 0, 0, 0
	for check in checks {
		label := "ok"
		switch check.status {
		case .Ok: ok_count += 1
		case .Warn:
			label = "warn"
			warn_count += 1
		case .Fail:
			label = "FAIL"
			fail_count += 1
		}
		fmt.printfln("  %-4s %s: %s", label, check.name, check.detail)
	}
	fmt.printfln("doctor: %d ok, %d warnings, %d failures", ok_count, warn_count, fail_count)
	if fail_count > 0 do return 1
	return 0
}
