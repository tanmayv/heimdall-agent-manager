package bridgesvc

// Service-file rendering (systemd unit, launchd plist, runit run file, Scheduled
// Task XML) — the same arguments and environment scripts/install.sh render_service
// and install.ps1 New-TaskXml produce, so `ham-bridge setup` re-rendering over an
// installer-made service is a no-op apart from fixes. setup re-renders on every run.

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:slice"
import "core:strings"

Render_Input :: struct {
	hub:           string,
	profile:       string,
	path_env:      string, // PATH to append after bin_dir
	termux_version: string,
	// Windows: the account (DOMAIN\\user) the logon task belongs to. Without it
	// the LogonTrigger means "at log on of ANY user", which only an
	// administrator may register (schtasks /Create: Access is denied).
	windows_user:  string,
	bridge_port:   int,
	endpoint_port: int,
	// Converted layout (conversion spec §7, §8.1, §10; engine §17): the service starts
	// <data>/launcher/ham-launcher instead of bin/ham-bridge. The zero value renders the
	// legacy layout byte-for-byte, so unconverted instances never change.
	converted:     bool,
	// converted only: C6 variant (conversion spec §10.1). While setup runs, the unit keeps
	// KillMode=process: setup and the legacy worker live in the unit's cgroup and a
	// control-group stop would kill the transaction. C9 renders with converting=false.
	converting:    bool,
	// converted only, Windows: the task name hash input (conversion spec §10.3).
	instance_id:   string,
	windows_sid:   string,
}

// Launcher entry point and file names of the converted layout.
LAUNCHER_DIR      :: "launcher"
LAUNCHER_STOP_REQUEST :: "launcher-stop.request" // under <data>/supervisor (engine §7.3)
LAUNCHER_STOP_EVENT_PREFIX :: `Local\heimdall-launcher-stop-` // engine §7.3
LAUNCHD_EXIT_TIMEOUT :: 40 // conversion spec §10.2

launcher_path :: proc(host: Host, l: Layout) -> string {
	return pjoin(l.data_dir, LAUNCHER_DIR, exe_name(host, "ham-launcher"))
}

exe_name :: proc(host: Host, base: string) -> string {
	return strings.concatenate({base, ".exe"}, context.temp_allocator) if host.os == .Windows else base
}

// service_args: the bridge command line every backend runs (temp-allocated).
service_args :: proc(host: Host, l: Layout, in_: Render_Input) -> []string {
	a := make([dynamic]string, context.temp_allocator)
	if in_.converted {
		// Conversion spec §7: --state-root is the profile's state dir (config.toml,
		// bridge-token, ports.json), the value the supervisor reads them from.
		append(&a, launcher_path(host, l), "--instance-root", l.data_dir, "--state-root", l.state_dir)
		return a[:]
	}
	append(&a, pjoin(l.bin_dir, exe_name(host, "ham-bridge")), "--hub", in_.hub,
		"--config", pjoin(l.state_dir, CONFIG_FILE), "--bridge-token-file", pjoin(l.state_dir, TOKEN_FILE),
		"--data-dir", l.data_dir, "--bind-host", "127.0.0.1", "--port", fmt.tprintf("%d", in_.bridge_port),
		"--local-endpoint-port", fmt.tprintf("%d", in_.endpoint_port), "--local-run-dir", pjoin(l.data_dir, "run"))
	return a[:]
}

// service_env: KEY=VALUE pairs, in install.sh order.
service_env :: proc(host: Host, l: Layout, in_: Render_Input) -> []string {
	sep := ";" if host.os == .Windows else ":"
	service_env_name: string
	#partial switch l.backend {
	case .Runit:    service_env_name = l.service_name
	case .Launchd, .Schtasks: service_env_name = l.service_name
	case:           service_env_name = strings.concatenate({l.service_name, ".service"}, context.temp_allocator)
	}
	e := make([dynamic]string, context.temp_allocator)
	if in_.converted {
		// Conversion spec §8.1: nothing points into the legacy bin/. The supervisor sets
		// PATH (prepended), HEIMDALL_HAM_PTY_HOST_BIN and HEIMDALL_HAM_CTL_BIN per tree.
		if p := path_without(in_.path_env, l.bin_dir, sep); p != "" {
			append(&e, strings.concatenate({"PATH=", p}, context.temp_allocator))
		}
		append(&e, "HEIMDALL_BRIDGE_PTY_HOST=true",
			fmt.tprintf("HEIMDALL_BRIDGE_ENDPOINT=tcp:127.0.0.1:%d", in_.endpoint_port),
			strings.concatenate({"HEIMDALL_BRIDGE_SERVICE_NAME=", service_env_name}, context.temp_allocator))
		return e[:]
	}
	path := l.bin_dir if in_.path_env == "" else strings.concatenate({l.bin_dir, sep, in_.path_env}, context.temp_allocator)
	append(&e, strings.concatenate({"PATH=", path}, context.temp_allocator),
		strings.concatenate({"HEIMDALL_HAM_PTY_HOST_BIN=", pjoin(l.bin_dir, exe_name(host, "ham-pty-host"))}, context.temp_allocator),
		"HEIMDALL_BRIDGE_PTY_HOST=true",
		// The ham-ctl binary setup installs into bin/ (BRIDGE_SETUP_BINARIES), never
		// the ham-ctl-<service> wrapper: the bridge execs this from every agent's
		// run-dir shim, which sets the endpoint and token itself.
		strings.concatenate({"HEIMDALL_HAM_CTL_BIN=", pjoin(l.bin_dir, exe_name(host, "ham-ctl"))}, context.temp_allocator),
		fmt.tprintf("HEIMDALL_BRIDGE_ENDPOINT=tcp:127.0.0.1:%d", in_.endpoint_port),
		strings.concatenate({"HEIMDALL_BRIDGE_SERVICE_NAME=", service_env_name}, context.temp_allocator))
	return e[:]
}

// path_without drops every segment equal to `dir` (slash and case-insensitive on
// trailing separators) from a PATH value and empty segments (temp-allocated).
path_without :: proc(path, dir, sep: string) -> string {
	want := strings.trim_right(dir, "/\\")
	out := make([dynamic]string, context.temp_allocator)
	rest := path
	for len(rest) > 0 {
		seg: string
		if i := strings.index(rest, sep); i >= 0 {
			seg, rest = rest[:i], rest[i + len(sep):]
		} else {
			seg, rest = rest, ""
		}
		if seg == "" || strings.trim_right(seg, "/\\") == want do continue
		append(&out, seg)
	}
	return strings.join(out[:], sep, context.temp_allocator)
}

// windows_task_name is the converted instance's task: "<service>-<h12>", h12 = first 12
// lowercase hex of SHA-256("heimdall-task-v1" 0x00 <SID> 0x00 <instance_id>) (conversion
// spec §10.3, engine §17). No leading backslash; the TN argument adds it.
windows_task_name :: proc(service_name, sid, instance_id: string) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]byte)string("heimdall-task-v1"))
	zero := [1]byte{0}
	sha2.update(&ctx, zero[:])
	sha2.update(&ctx, transmute([]byte)sid)
	sha2.update(&ctx, zero[:])
	sha2.update(&ctx, transmute([]byte)instance_id)
	digest: [32]byte
	sha2.final(&ctx, digest[:])
	h := hex.encode(digest[:6], context.temp_allocator)
	return strings.concatenate({service_name, "-", string(h)}, context.temp_allocator)
}

// Windows converted-layout file names (conversion spec §10.3). They sit beside the
// legacy run.cmd/run.vbs/task.xml, which stay for rollback.
windows_launcher_cmd_path :: proc(l: Layout) -> string {return pjoin(l.data_dir, "run-launcher.cmd")}
windows_launcher_vbs_path :: proc(l: Layout) -> string {return pjoin(l.data_dir, "run-launcher.vbs")}
windows_launcher_task_xml_path :: proc(l: Layout) -> string {return pjoin(l.data_dir, "task-launcher.xml")}

// windows_stop_event_name: the launcher's graceful-stop event (engine §7.3).
windows_stop_event_name :: proc(instance_id: string) -> string {
	return strings.concatenate({LAUNCHER_STOP_EVENT_PREFIX, instance_id}, context.temp_allocator)
}

// launcher_stop_request_path / render_launcher_stop_request: the any-session stop
// request (engine §7.3). The caller writes it with temp file + rename.
launcher_stop_request_path :: proc(l: Layout) -> string {return pjoin(l.data_dir, "supervisor", LAUNCHER_STOP_REQUEST)}

render_launcher_stop_request :: proc(instance_id: string, requested_at: i64) -> string {
	return strings.concatenate({`{"instance_id":"`, instance_id, `","requested_at":`, fmt.tprintf("%d", requested_at), "}"}, context.temp_allocator)
}

xml_escape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in s {
		switch r {
		case '&':  strings.write_string(&b, "&amp;")
		case '<':  strings.write_string(&b, "&lt;")
		case '>':  strings.write_string(&b, "&gt;")
		case '"':  strings.write_string(&b, "&quot;")
		case '\'': strings.write_string(&b, "&apos;")
		case:      strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}

sh_quote :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "'", `'\''`, context.temp_allocator)
	return strings.concatenate({"'", out, "'"}, context.temp_allocator)
}

// systemd_exec_quote quotes one ExecStart word (and escapes % specifiers / $).
systemd_exec_quote :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '"')
	for r in s {
		switch r {
		case '"', '\\': strings.write_byte(&b, '\\'); strings.write_rune(&b, r)
		case '%':       strings.write_string(&b, "%%")
		case '$':       strings.write_string(&b, "$$")
		case:           strings.write_rune(&b, r)
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

// render_service_file returns the service definition text for l.backend
// (temp-allocated); "" for Backend.None.
render_service_file :: proc(host: Host, l: Layout, in_: Render_Input) -> string {
	args := service_args(host, l, in_)
	env := service_env(host, l, in_)
	b := strings.builder_make(context.temp_allocator)
	switch l.backend {
	case .None:
		return ""
	case .Systemd:
		fmt.sbprintf(&b, "[Unit]\nDescription=Ninjy Bridge %s", in_.hub)
		if in_.profile != "" do fmt.sbprintf(&b, " (profile %s)", in_.profile)
		strings.write_string(&b, "\nAfter=network-online.target\n\n[Service]\nType=simple\nExecStart=")
		for a, i in args {
			if i > 0 do strings.write_byte(&b, ' ')
			strings.write_string(&b, systemd_exec_quote(a))
		}
		strings.write_byte(&b, '\n')
		for e in env do fmt.sbprintf(&b, "Environment=%s\n", systemd_exec_quote(e))
		kill_mode := "process" if !in_.converted || in_.converting else "control-group"
		fmt.sbprintf(&b, "Restart=on-failure\nRestartSec=5\nKillMode=%s\n\n[Install]\nWantedBy=default.target\n", kill_mode)
	case .Launchd:
		sorted := slice.clone(env, context.temp_allocator)
		sort_strings(sorted)
		strings.write_string(&b, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n")
		fmt.sbprintf(&b, "<plist version=\"1.0\">\n<dict>\n\t<key>AbandonProcessGroup</key>\n\t<%s/>\n", "false" if in_.converted else "true")
		strings.write_string(&b, "\t<key>EnvironmentVariables</key>\n\t<dict>\n")
		for e in sorted {
			eq := strings.index_byte(e, '=')
			fmt.sbprintf(&b, "\t\t<key>%s</key>\n\t\t<string>%s</string>\n", e[:eq], xml_escape(e[eq + 1:]))
		}
		strings.write_string(&b, "\t</dict>\n")
		// Keys stay alphabetical, as in the legacy plist.
		if in_.converted do fmt.sbprintf(&b, "\t<key>ExitTimeOut</key>\n\t<integer>%d</integer>\n", LAUNCHD_EXIT_TIMEOUT)
		strings.write_string(&b, "\t<key>KeepAlive</key>\n\t<dict>\n\t\t<key>SuccessfulExit</key>\n\t\t<false/>\n\t</dict>\n")
		fmt.sbprintf(&b, "\t<key>Label</key>\n\t<string>%s</string>\n\t<key>ProgramArguments</key>\n\t<array>\n", xml_escape(l.service_name))
		for a in args do fmt.sbprintf(&b, "\t\t<string>%s</string>\n", xml_escape(a))
		strings.write_string(&b, "\t</array>\n\t<key>RunAtLoad</key>\n\t<true/>\n")
		fmt.sbprintf(&b, "\t<key>StandardErrorPath</key>\n\t<string>%s</string>\n", xml_escape(pjoin(l.data_dir, "logs", "bridge.err.log")))
		fmt.sbprintf(&b, "\t<key>StandardOutPath</key>\n\t<string>%s</string>\n", xml_escape(pjoin(l.data_dir, "logs", "bridge.out.log")))
		strings.write_string(&b, "\t<key>ThrottleInterval</key>\n\t<integer>5</integer>\n</dict>\n</plist>\n")
	case .Runit:
		fmt.sbprintf(&b, "#!%s/bin/sh\nexec 2>&1\n", host.prefix)
		fmt.sbprintf(&b, "export PREFIX=%s\n", sh_quote(host.prefix))
		fmt.sbprintf(&b, "export TERMUX_VERSION=%s\n", sh_quote(in_.termux_version if in_.termux_version != "" else "installed"))
		fmt.sbprintf(&b, "export TMPDIR=%s\n", sh_quote(pjoin(host.prefix, "tmp")))
		for e in env {
			eq := strings.index_byte(e, '=')
			fmt.sbprintf(&b, "export %s=%s\n", e[:eq], sh_quote(e[eq + 1:]))
		}
		strings.write_string(&b, "exec")
		for a in args do fmt.sbprintf(&b, " %s", sh_quote(a))
		strings.write_byte(&b, '\n')
	case .Schtasks:
		// Per-user logon task running a hidden, synchronous launcher, which
		// carries the environment the other backends set inline, like install.ps1.
		strings.write_string(&b, "<?xml version=\"1.0\" encoding=\"UTF-16\"?>\n<Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\">\n")
		fmt.sbprintf(&b, "  <RegistrationInfo><Description>Ninjy Bridge %s</Description></RegistrationInfo>\n", xml_escape(in_.hub))
		user_id := in_.windows_user == "" ? "" : fmt.tprintf("<UserId>%s</UserId>", xml_escape(in_.windows_user))
		fmt.sbprintf(&b, "  <Triggers><LogonTrigger><Enabled>true</Enabled>%s</LogonTrigger></Triggers>\n", user_id)
		fmt.sbprintf(&b, "  <Principals><Principal id=\"Author\">%s<LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>\n", user_id)
		strings.write_string(&b, "  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><RestartOnFailure><Interval>PT1M</Interval><Count>999</Count></RestartOnFailure></Settings>\n")
		strings.write_string(&b, "  <Actions Context=\"Author\"><Exec>\n    <Command>wscript.exe</Command>\n")
		vbs := windows_launcher_vbs_path(l) if in_.converted else windows_launcher_path(l)
		fmt.sbprintf(&b, "    <Arguments>//B //NoLogo \"%s\"</Arguments>\n", xml_escape(vbs))
		strings.write_string(&b, "  </Exec></Actions>\n</Task>\n")
	}
	return strings.to_string(b)
}

// default_config_toml is written only when config.toml is missing (existing
// configs are migrated, never replaced).
default_config_toml :: proc(hub, data_dir: string) -> string {
	esc :: proc(s: string) -> string {
		a, _ := strings.replace_all(s, "\\", "\\\\", context.temp_allocator)
		b, _ := strings.replace_all(a, "\"", "\\\"", context.temp_allocator)
		return b
	}
	return fmt.tprintf("[daemon]\ndaemon_url = \"%s\"\ndata_dir = \"%s\"\n\n[wrapper]\ndaemon_url = \"%s\"\n", esc(hub), esc(data_dir), esc(hub))
}

windows_run_cmd_path :: proc(l: Layout) -> string {return pjoin(l.data_dir, "run.cmd")}

// ctl_wrapper_path: the per-profile CLI a person runs to talk to this bridge,
// bin/ham-ctl-<service> (.cmd on Windows). setup writes it on every run, after
// the bin/ swap, so it survives installs and updates.
ctl_wrapper_path :: proc(host: Host, l: Layout) -> string {
	name := strings.concatenate({"ham-ctl-", l.service_name}, context.temp_allocator)
	if host.os == .Windows do name = strings.concatenate({name, ".cmd"}, context.temp_allocator)
	return pjoin(l.bin_dir, name)
}

// render_ctl_wrapper: bin/ham-ctl with this profile's config and, unless the
// caller set one, this profile's local endpoint (the service env's value).
render_ctl_wrapper :: proc(host: Host, l: Layout, in_: Render_Input) -> string {
	return render_ctl_wrapper_for_tree(host, l, in_, pjoin(l.bin_dir, exe_name(host, "ham-ctl")))
}

// render_ctl_wrapper_for_tree: the wrapper exec'ing `ctl` (a converted instance points it
// into the active release tree, conversion spec §8.3).
render_ctl_wrapper_for_tree :: proc(host: Host, l: Layout, in_: Render_Input, ctl: string) -> string {
	endpoint := fmt.tprintf("tcp:127.0.0.1:%d", in_.endpoint_port)
	config := pjoin(l.state_dir, CONFIG_FILE)
	b := strings.builder_make(context.temp_allocator)
	if host.os == .Windows {
		cmdq :: proc(s: string) -> string {
			out, _ := strings.replace_all(s, "%", "%%", context.temp_allocator)
			return out
		}
		fmt.sbprintf(&b, "@echo off\r\nif not defined HEIMDALL_BRIDGE_ENDPOINT set \"HEIMDALL_BRIDGE_ENDPOINT=%s\"\r\n", endpoint)
		fmt.sbprintf(&b, "\"%s\" --config \"%s\" %%*\r\n", cmdq(ctl), cmdq(config))
	} else {
		// Not fmt: it reads `{` as an argument index, and the shell default needs ${...}.
		strings.write_string(&b, strings.concatenate({"#!/bin/sh\n: \"${HEIMDALL_BRIDGE_ENDPOINT:=", endpoint, "}\"\nexport HEIMDALL_BRIDGE_ENDPOINT\n"}, context.temp_allocator))
		strings.write_string(&b, strings.concatenate({"exec ", sh_quote(ctl), " --config ", sh_quote(config), " \"$@\"\n"}, context.temp_allocator))
	}
	return strings.to_string(b)
}

// render_windows_run_cmd: the batch file the Scheduled Task runs (CRLF).
render_windows_run_cmd :: proc(host: Host, l: Layout, in_: Render_Input) -> string {
	cmdq :: proc(s: string) -> string {
		out, _ := strings.replace_all(s, "%", "%%", context.temp_allocator)
		return out
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "@echo off\r\nrem Ninjy bridge for %s (generated by ham-bridge setup)\r\nsetlocal DisableDelayedExpansion\r\n", cmdq(in_.hub))
	for e in service_env(host, l, in_) do fmt.sbprintf(&b, "set \"%s\"\r\n", cmdq(e))
	args := service_args(host, l, in_)
	fmt.sbprintf(&b, "\"%s\"", cmdq(args[0]))
	for a in args[1:] do fmt.sbprintf(&b, " \"%s\"", cmdq(a))
	// Redirection can fail before the executable runs without setting ERRORLEVEL.
	// Make that failure visible to Task Scheduler rather than reporting success.
	fmt.sbprintf(&b, " 1>>\"%s\" 2>>\"%s\" || exit /b 1\r\nexit /b %%ERRORLEVEL%%\r\n", cmdq(pjoin(l.data_dir, "logs", "bridge.out.log")), cmdq(pjoin(l.data_dir, "logs", "bridge.err.log")))
	return strings.to_string(b)
}

// WScript has no console. Wait for cmd/Bridge and return its status so Task
// Scheduler supervises the whole lifetime and applies RestartOnFailure.
windows_launcher_path :: proc(l: Layout) -> string {return pjoin(l.data_dir, "run.vbs")}

render_windows_launcher :: proc(l: Layout) -> string {
	return render_windows_launcher_for(windows_run_cmd_path(l))
}

// render_windows_launcher_converted: run-launcher.vbs, running run-launcher.cmd.
render_windows_launcher_converted :: proc(l: Layout) -> string {
	return render_windows_launcher_for(windows_launcher_cmd_path(l))
}

render_windows_launcher_for :: proc(cmd_path: string) -> string {
	path, _ := strings.replace_all(cmd_path, "\"", "\"\"", context.temp_allocator)
	return fmt.tprintf("Option Explicit\r\nDim shell, result\r\nSet shell = CreateObject(\"WScript.Shell\")\r\nresult = shell.Run(\"cmd.exe /d /s /c \"\"\"\"%s\"\"\"\"\", 0, True)\r\nWScript.Quit result\r\n", path)
}
