// heimdall start/stop/restart/logs: lifecycle of the heimdall-bridge user
// service, matching the service identity used by nix/home-manager.nix and
// scripts/install.sh (systemd user unit "heimdall-bridge" on Linux, launchd
// agent "works.earendil.heimdall-bridge" on macOS).
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

Manager_Service_State :: struct {
	loaded: bool, // unit/agent is known to the service manager
	active: bool, // currently running
	pid:    int,
	since:  string, // activation timestamp (Linux) when known
	detail: string, // raw state word(s) for the report
}

// ---- argv plans (pure; the platform/loaded state is injected so both Linux
// and macOS behavior are unit-testable from one host) ----

manager_service_verb_argv :: proc(verb, unit, label, plist_path: string, platform: Manager_Platform, uid: int, loaded: bool) -> []string {
	switch platform {
	case .Linux:
		// Only the three lifecycle verbs are valid; anything else must produce
		// no command rather than a bogus `systemctl --user <verb>` invocation.
		switch verb {
		case "start", "stop", "restart":
		case:
			return nil
		}
		argv := make([dynamic]string, 0, 4)
		append(&argv, "systemctl", "--user", verb, unit)
		return argv[:]
	case .Darwin:
		domain := fmt.tprintf("gui/%d", uid)
		service := fmt.tprintf("%s/%s", domain, label)
		switch verb {
		case "start", "restart":
			// kickstart -k restarts an already-loaded agent in place; a
			// never-loaded agent must be bootstrapped from its plist first.
			argv := make([dynamic]string, 0, 4)
			if loaded {
				append(&argv, "launchctl", "kickstart", "-k", service)
			} else {
				append(&argv, "launchctl", "bootstrap", domain, plist_path)
			}
			return argv[:]
		case "stop":
			argv := make([dynamic]string, 0, 3)
			append(&argv, "launchctl", "bootout", service)
			return argv[:]
		}
		return nil
	case .Unsupported:
		return nil
	}
	return nil
}

manager_logs_argv :: proc(unit: string, platform: Manager_Platform, lines: int, follow: bool) -> []string {
	n := fmt.tprintf("%d", lines)
	switch platform {
	case .Linux:
		argv := make([dynamic]string, 0, 7)
		append(&argv, "journalctl", "--user", "-u", unit, "-n", n)
		if follow do append(&argv, "-f")
		return argv[:]
	case .Darwin:
		argv := make([dynamic]string, 0, 8)
		append(&argv, "tail", "-n", n)
		if follow do append(&argv, "-f")
		append(&argv, manager_macos_log_path(unit, "out"), manager_macos_log_path(unit, "err"))
		return argv[:]
	case .Unsupported:
		return nil
	}
	return nil
}

manager_macos_log_path :: proc(unit, stream: string) -> string {
	// home-manager renders ${logDir}/heimdall-bridge.out.log with logDir
	// defaulting to /tmp/heimdall-logs (nix/home-manager.nix); install.sh
	// renders the same paths into the plist.
	return fmt.tprintf("%s/%s.%s.log", MANAGER_MACOS_LOG_DIR, unit, stream)
}

manager_launchd_plist_path :: proc() -> string {
	home := os.get_env_alloc("HOME", context.allocator)
	return fmt.tprintf("%s/Library/LaunchAgents/%s.plist", home, MANAGER_LAUNCHD_LABEL)
}

manager_current_uid :: proc() -> int {
	when ODIN_OS == .Linux || ODIN_OS == .Darwin {
		return int(posix.getuid())
	}
	return 0
}

// ---- service state queries + parsers (pure parsers for tests) ----

manager_service_state :: proc(platform: Manager_Platform, unit, label, plist_path: string) -> Manager_Service_State {
	switch platform {
	case .Linux:
		out, _, ok := manager_run_capture({"systemctl", "--user", "show", unit, "--property=LoadState,ActiveState,SubState,MainPID,ActiveEnterTimestamp"})
		return manager_parse_systemctl_show(out, ok)
	case .Darwin:
		domain := fmt.tprintf("gui/%d", manager_current_uid())
		out, _, ok := manager_run_capture({"launchctl", "print", fmt.tprintf("%s/%s", domain, label)})
		return manager_parse_launchctl_print(out, ok)
	case .Unsupported:
		return Manager_Service_State{detail = "unsupported platform"}
	}
	return Manager_Service_State{detail = "unsupported platform"}
}

manager_parse_systemctl_show :: proc(out: string, ok: bool) -> Manager_Service_State {
	state := Manager_Service_State{detail = "unknown"}
	if !ok {
		state.detail = "unavailable"
		return state
	}
	state.detail = "inactive"
	text := out
	for line in strings.split_lines_iterator(&text) {
		eq := strings.index_byte(line, '=')
		if eq <= 0 do continue
		key := strings.trim_space(line[:eq])
		value := strings.trim_space(line[eq+1:])
		switch key {
		case "LoadState":
			state.loaded = value == "loaded"
		case "ActiveState":
			state.active = value == "active"
			if value != "" do state.detail = value
		case "MainPID":
			if pid, pid_ok := strconv.parse_int(value); pid_ok do state.pid = int(pid)
		case "ActiveEnterTimestamp":
			state.since = value
		}
	}
	return state
}

manager_parse_launchctl_print :: proc(out: string, ok: bool) -> Manager_Service_State {
	if !ok do return Manager_Service_State{detail = "not loaded"}
	state := Manager_Service_State{loaded = true, detail = "loaded"}
	text := out
	for line in strings.split_lines_iterator(&text) {
		trimmed := strings.trim_space(line)
		eq := strings.index_byte(trimmed, '=')
		if eq <= 0 do continue
		key := strings.trim_space(trimmed[:eq])
		value := strings.trim_space(trimmed[eq+1:])
		switch key {
		case "state":
			state.detail = value
			state.active = value == "running"
		case "pid":
			if pid, pid_ok := strconv.parse_int(value); pid_ok do state.pid = int(pid)
		}
	}
	return state
}

// ---- command entry points ----

manager_service_verb_command :: proc(verb: string, args: []string) -> int {
	platform := manager_host_platform()
	if platform == .Unsupported {
		fmt.eprintln("heimdall: service management is only supported on Linux and macOS")
		return 1
	}
	unit := MANAGER_SERVICE_UNIT
	plist_path := manager_launchd_plist_path()
	state := manager_service_state(platform, unit, MANAGER_LAUNCHD_LABEL, plist_path)
	if verb == "start" && state.active {
		fmt.printfln("heimdall-bridge is already running (pid %d)", state.pid)
		return 0
	}
	if verb == "stop" && state.loaded && !state.active {
		fmt.println("heimdall-bridge is already stopped")
		return 0
	}
	argv := manager_service_verb_argv(verb, unit, MANAGER_LAUNCHD_LABEL, plist_path, platform, manager_current_uid(), state.loaded)
	if len(argv) == 0 {
		fmt.eprintfln("heimdall: no service command for %q on this platform", verb)
		return 1
	}
	fmt.printfln("heimdall-bridge: %s (%s)", verb, strings.join(argv, " "))
	if _, found := manager_bin_on_path(argv[0]); !found {
		fmt.eprintfln("heimdall: %s not found on PATH", argv[0])
		return 1
	}
	return manager_run_inherit(argv)
}

manager_logs_command :: proc(args: []string) -> int {
	platform := manager_host_platform()
	if platform == .Unsupported {
		fmt.eprintln("heimdall: logs are only supported on Linux and macOS")
		return 1
	}
	raw_lines := manager_option_value(args, "-n", manager_option_value(args, "--lines", ""))
	lines := manager_parse_line_number(raw_lines, 200)
	follow := manager_has_flag(args, "-f") || manager_has_flag(args, "--follow")
	argv := manager_logs_argv(MANAGER_SERVICE_UNIT, platform, lines, follow)
	if len(argv) == 0 do return 1
	if _, found := manager_bin_on_path(argv[0]); !found {
		fmt.eprintfln("heimdall: %s not found on PATH", argv[0])
		return 1
	}
	return manager_run_inherit(argv)
}
