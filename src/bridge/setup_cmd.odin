package main

// `ham-bridge setup --hub <url> [--profile P] [--new-bridge|--reuse-bridge ID] [--reenroll]
// [--separate-account | --replace-other-account] [--version V [--allow-downgrade]]
// [--keep-version] [--reinstall] [--headless] [--no-tray] [--json-progress]`: install this bridge
// from the bundle the running binary ships in, transactionally (F6, F9). The step
// order, retry/remediation and rollback live in bridgesvc.run_setup; this file
// supplies the real side effects. It is idempotent (installer contract,
// docs/specs/bridge-installer-contract.md §3): after the lock, the instance is
// classified (bridgesvc.classify_install) and only what that row needs is done. A
// healthy instance is left untouched (S2), a missing or refused credential is
// re-enrolled keeping binaries and data (S3/S4), a missing or stopped service is
// re-registered (S6), an interrupted install is finished (S7). By default the
// bundle's binaries replace different installed ones (`ham-bridge update` runs this);
// --keep-version (the installer scripts) keeps them (S8a); --reinstall (update) re-runs
// the whole transaction even for an identical bundle. Exit codes: contract §4.
// An existing per-Hub install (same service name, state and data dirs as install.sh
// / install.ps1) is adopted in place. Progress protocol: docs/bridge-setup-progress.md.
// Several Ninjy accounts share a machine with one profile each: --separate-account
// installs into a profile no account has enrolled yet (account-2, account-3, ...)
// when the requested one already belongs to an account; a setup that would enroll
// a new bridge into an enrolled profile offers the same on a terminal and does it
// headless (bridge_setup_wants_separate_account). Multi-account installs:
// docs/bridge-multi-account.md.

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"
import bridgesvc "odin_test:lib/bridgesvc"

// Binaries a release bundle carries next to ham-bridge; only ham-bridge is required.
BRIDGE_SETUP_BINARIES :: [?]string{"ham-bridge", "ham-pty-host", "ham-ctl", "ham-wrapper"}
BRIDGE_SETUP_VERIFY_TIMEOUT :: 45 * time.Second

Bridge_Setup :: struct {
	host:           bridgesvc.Host,
	profile:        bridgesvc.Profile,
	layout:         bridgesvc.Layout,
	args:           []string,
	json_progress:  bool,
	bundle_dir:     string,
	staging:        string,
	lock_path:      string,
	pid:            int,
	// Taken once, by the first Stage run: a remediation that re-stages after
	// stopping the service must not forget that the previous install was running.
	snapshot_taken: bool,
	was_installed:  bool,
	was_running:    bool,
	stopped_for_setup: bool,
	binary_backup: string,
	rollback_failed: bool,
	rollback_message: string,
	copy_binaries:  bool,
	// Snapshots for rollback: nil = the file did not exist.
	backups:        map[string]Maybe(string),
	ports:          [2]int,
	enrolled_now:   bool,
	// Set by every (re)start: Verify only trusts runtime status written after it,
	// by a process other than the bridge that was running before.
	restart_at:     i64,
	stale_pid:      int,
	tray_stopped:   bool, // Binaries stopped a running tray; finish restarts it
	// Classification (Lock): what is installed and the minimal action.
	facts:          bridgesvc.Install_Facts,
	plan:           bridgesvc.Install_Plan,
	exit_code:      int, // a refusal's or busy lock's code; 0 = derive from the outcome
	refusal:        string, // the [ERROR] line of a refusal / busy lock
	recovered:      [dynamic]string, // S7 repairs: lock broken, staging discarded, ...
	service_action: string, // "registered" when the service definition was (re)written
	not_enrolled:   string, // S1a: why enrollment did not complete (exit 4)
	not_connected:  bool, // S2: running but not connected after the wait (warning)
}

BRIDGE_SETUP_USAGE :: "usage: ham-bridge setup --hub <url> [--profile P] [--new-bridge | --reuse-bridge BRIDGE_ID] [--reenroll] [--separate-account | --replace-other-account] [--version V [--allow-downgrade]] [--keep-version] [--reinstall] [--headless] [--no-tray] [--json-progress]"

// bridge_setup_command returns the process exit code (contract §4).
bridge_setup_command :: proc(args: []string) -> int {
	hub := strings.trim_space(option_value(args, "--hub", ""))
	profile_name := strings.trim_space(option_value(args, "--profile", ""))
	if hub == "" {
		fmt.eprintln(BRIDGE_SETUP_USAGE)
		return bridgesvc.EXIT_USAGE
	}
	profile, ok := bridgesvc.profile_from(hub, profile_name, context.temp_allocator)
	if !ok {
		fmt.eprintfln("ham-bridge setup: invalid --hub %q or --profile %q (profile: [a-z0-9][a-z0-9-]{{0,30}})", hub, profile_name)
		return bridgesvc.EXIT_USAGE
	}
	host := bridge_service_host()
	if has_flag(args, BRIDGE_SETUP_SEPARATE_ACCOUNT_FLAG) && has_flag(args, BRIDGE_ENROLL_REPLACE_ACCOUNT_FLAG) {
		fmt.eprintln("ham-bridge setup: --separate-account and --replace-other-account are mutually exclusive")
		return bridgesvc.EXIT_USAGE
	}
	if has_flag(args, "--version") && strings.trim_space(option_value(args, "--version", "")) == "" {
		fmt.eprintln(BRIDGE_SETUP_USAGE)
		return bridgesvc.EXIT_USAGE
	}
	if bridge_setup_wants_separate_account(host, args, profile) {
		separate, found := bridgesvc.separate_account_profile(host, profile.hub_name, profile.profile)
		if !found {
			fmt.eprintfln("ham-bridge setup: every account profile for %s is enrolled; pass --profile P for a new one", profile.hub_url)
			return bridgesvc.EXIT_REFUSED
		}
		if separate != profile.profile {
			profile, _ = bridgesvc.profile_from(hub, separate, context.temp_allocator)
			if !has_flag(args, "--json-progress") do fmt.printfln("Installing this Ninjy account as a separate profile %q (service %s); the existing one is left as is.", separate, profile.service_name)
		}
	}
	s := Bridge_Setup {
		host          = host,
		profile       = profile,
		args          = args,
		json_progress = has_flag(args, "--json-progress"),
		pid           = os.get_pid(),
		backups       = make(map[string]Maybe(string), context.temp_allocator),
		recovered     = make([dynamic]string, context.temp_allocator),
	}
	s.layout = bridgesvc.layout_for(s.host, profile.service_name)
	if s.layout.backend == .None {
		fmt.eprintln("ham-bridge setup: no supported service manager on this platform")
		return bridgesvc.EXIT_FAILED
	}
	exe, _ := os.get_executable_path(context.temp_allocator)
	if exe == "" && len(os.args) > 0 do exe = os.args[0]
	s.bundle_dir = bridgesvc.pdir(exe)
	s.staging = bridgesvc.pjoin(s.layout.data_dir, ".staging")
	s.lock_path = bridgesvc.pjoin(s.layout.state_dir, bridgesvc.LOCK_FILE)
	s.copy_binaries = bridgesvc.path_key(s.bundle_dir) != bridgesvc.path_key(s.layout.bin_dir)

	ops := bridgesvc.Setup_Ops {
		data      = &s,
		run       = bridge_setup_run,
		remediate = bridge_setup_remediate,
		undo      = bridge_setup_undo,
		rollback_status = bridge_setup_rollback_status,
		emit      = bridge_setup_emit,
		finish    = bridge_setup_finish,
		summary   = bridge_setup_summary,
	}
	done, failed := bridgesvc.run_setup(ops)
	code := bridge_setup_exit_code(&s, done)
	if !done && !s.json_progress {
		switch {
		case s.refusal != "": fmt.printfln("[ERROR] %s", s.refusal)
		case s.rollback_failed: fmt.printfln("ham-bridge setup FAILED at step %q; rollback incomplete: %s.", bridgesvc.STEP_NAMES[failed], s.rollback_message)
		case: fmt.printfln("ham-bridge setup FAILED at step %q; the previous install was restored%s.", bridgesvc.STEP_NAMES[failed], " and restarted" if s.was_running && s.stopped_for_setup else "")
		}
	}
	return code
}

// bridge_setup_exit_code maps the outcome onto contract §4.
bridge_setup_exit_code :: proc(s: ^Bridge_Setup, done: bool) -> int {
	if done do return bridgesvc.EXIT_NOT_ENROLLED if s.not_enrolled != "" else bridgesvc.EXIT_OK
	if s.rollback_failed do return bridgesvc.EXIT_ROLLBACK_INCOMPLETE
	if s.exit_code != 0 do return s.exit_code
	return bridgesvc.EXIT_FAILED
}

// bridge_setup_wants_separate_account: --separate-account, or a run that would
// enroll a new bridge into a profile an account already enrolled, with neither
// account flag. Headless (installers, Electron) nobody can confirm a replace, so
// such a run defaults to a separate profile and the enrolled one (its service,
// ports and credential) is left as is; --reenroll re-pairs the profile's own
// bridge and stays put. On a terminal the user is asked. Updates of an enrolled
// profile never ask.
bridge_setup_wants_separate_account :: proc(host: bridgesvc.Host, args: []string, profile: bridgesvc.Profile) -> bool {
	if has_flag(args, BRIDGE_SETUP_SEPARATE_ACCOUNT_FLAG) do return true
	if has_flag(args, BRIDGE_ENROLL_REPLACE_ACCOUNT_FLAG) do return false
	l := bridgesvc.layout_for(host, profile.service_name)
	current := bridgesvc.credential_bridge_id(bridgesvc.read_first_line(bridgesvc.pjoin(l.state_dir, bridgesvc.TOKEN_FILE)))
	if current == "" || !bridge_setup_enroll_needed(args, current) do return false
	if !bridge_stdin_is_terminal(args) do return !has_flag(args, "--reenroll")
	fmt.printfln("Profile %s is enrolled as bridge %s.", profile.service_name, current)
	fmt.print("  Are you enrolling a DIFFERENT Ninjy account? Install it as a separate profile (the existing one keeps running) [y/N] ")
	if !bridge_stdin_wait_readable(BRIDGE_ENROLL_PROMPT_TIMEOUT_MS) {
		fmt.println("")
		return false
	}
	buf: [64]byte
	n, rerr := os.read(os.stdin, buf[:])
	if rerr != nil || n <= 0 do return false
	answer := strings.to_lower(strings.trim_space(string(buf[:n])), context.temp_allocator)
	return answer == "y" || answer == "yes"
}

// bridge_setup_enroll_needed: an enrolled profile skips the enroll step, unless
// --new-bridge, --reenroll (re-pair the same bridge, e.g. after its credential was
// revoked), or --reuse-bridge naming another bridge than the current credential's.
bridge_setup_enroll_needed :: proc(args: []string, current_bridge_id: string) -> bool {
	if current_bridge_id == "" || has_flag(args, "--new-bridge") || has_flag(args, "--reenroll") do return true
	reuse := strings.trim_space(option_value(args, "--reuse-bridge", ""))
	return reuse != "" && reuse != current_bridge_id
}

bridge_setup_emit :: proc(data: rawptr, ev: bridgesvc.Event) {
	s := (^Bridge_Setup)(data)
	if s.json_progress {
		fmt.println(bridgesvc.event_json(ev, context.temp_allocator))
		return
	}
	switch ev.state {
	case "start": fmt.printf("[%3d%%] %-10s ...", ev.pct, ev.step)
	case "progress": fmt.printfln("\n        %s", ev.message)
	case "ok", "skipped": fmt.printfln(" %s%s%s", ev.state, " — " if ev.message != "" && ev.message != "skipped" else "", ev.message if ev.message != "skipped" else "")
	case "retry": fmt.printfln(" retry (attempt %d): %s", ev.attempt, ev.message)
	case "failed": fmt.printfln(" FAILED: %s", ev.message)
	case "warning": fmt.printfln(" warning: %s", ev.message)
	case "rollback": fmt.printfln("        rollback %s", ev.step)
	case "done": fmt.printfln("[100%%] %s", ev.message)
	}
}

// ---- snapshots ---------------------------------------------------------------

bridge_setup_backup :: proc(s: ^Bridge_Setup, path: string) {
	if path == "" || path in s.backups do return
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	s.backups[path] = string(data) if err == nil else nil
}

bridge_setup_restore :: proc(s: ^Bridge_Setup, path: string) {
	prev, had := s.backups[path]
	if !had do return
	if text, existed := prev.?; existed {
		_ = os.write_entire_file_from_string(path, text, {.Read_User, .Write_User})
	} else {
		_ = os.remove(path)
	}
}

bridge_setup_port_busy :: proc(port: int) -> bool {
	sock, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = port}, 1)
	if err != nil do return true
	net.close(sock)
	return false
}

bridge_setup_exec_inherit :: proc(argv: []string) -> bool {
	p, err := bridge_os_start_hidden(os.Process_Desc{command = argv, stdin = os.stdin, stdout = os.stdout, stderr = os.stderr})
	if err != nil do return false
	state, werr := os.process_wait(p)
	// core:os on Windows reports success for every exited process (dev-2026-09/10
	// _process_wait sets success = true), so the exit code decides.
	return werr == nil && state.success && state.exit_code == 0
}

// bridge_setup_service_path is the PATH baked into the service. A service
// manager (launchd above all) starts the bridge with a minimal PATH, and setup
// often runs where PATH is just as minimal: the desktop app opened from the
// Dock/Finder, or the .pkg postinstall. Provider CLIs in the user's PATH
// (Homebrew, npm, ~/.local/bin, Nix profiles) were then invisible to the
// bridge. So the service gets, in order and without duplicates: this process's
// PATH, the user's login-shell PATH, then well-known per-user and system bin
// directories that exist. Windows services already see the user's PATH.
bridge_setup_service_path :: proc(current, login_path, home, user: string, exists: proc(path: string) -> bool) -> string {
	seen := make(map[string]bool, 32, context.temp_allocator)
	out := make([dynamic]string, context.temp_allocator)
	add :: proc(seen: ^map[string]bool, out: ^[dynamic]string, dir: string) {
		d := strings.trim_space(dir)
		if d == "" || seen[d] do return
		seen[d] = true
		append(out, d)
	}
	for list in ([]string{current, login_path}) {
		for d in strings.split(list, ":", context.temp_allocator) do add(&seen, &out, d)
	}
	known := make([dynamic]string, context.temp_allocator)
	if home != "" {
		for rel in ([]string{".local/bin", "bin", ".claude/local", ".npm-global/bin", ".bun/bin", ".volta/bin", ".cargo/bin", ".deno/bin", ".nix-profile/bin", ".local/state/nix/profile/bin"}) {
			append(&known, strings.concatenate({home, "/", rel}, context.temp_allocator))
		}
	}
	if user != "" do append(&known, strings.concatenate({"/etc/profiles/per-user/", user, "/bin"}, context.temp_allocator))
	for d in ([]string{"/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/run/current-system/sw/bin", "/nix/var/nix/profiles/default/bin"}) do append(&known, d)
	for d in known do if exists(d) do add(&seen, &out, d)
	for d in ([]string{"/usr/bin", "/bin", "/usr/sbin", "/sbin"}) do add(&seen, &out, d)
	return strings.join(out[:], ":", context.temp_allocator)
}

BRIDGE_SETUP_PATH_MARK :: "__HAM_SETUP_PATH__"

// bridge_setup_login_shell_path asks the user's login shell for its PATH
// (interactive too: zsh users commonly extend PATH in .zshrc). Output around
// the markers is ignored (motd, prompts); any failure or timeout yields "".
bridge_setup_login_shell_path :: proc() -> string {
	shell, _ := os.lookup_env("SHELL", context.temp_allocator)
	if shell == "" || !os.exists(shell) do return ""
	script := "printf '" + BRIDGE_SETUP_PATH_MARK + "%s" + BRIDGE_SETUP_PATH_MARK + "' \"$PATH\""
	stdout, stderr, ok, _ := bridge_process_run_capture({shell, "-ilc", script}, 5 * time.Second)
	defer {delete(stdout); delete(stderr)}
	if !ok do return ""
	return bridge_setup_extract_marked_path(stdout)
}

bridge_setup_extract_marked_path :: proc(stdout: string) -> string {
	start := strings.index(stdout, BRIDGE_SETUP_PATH_MARK)
	if start < 0 do return ""
	rest := stdout[start + len(BRIDGE_SETUP_PATH_MARK):]
	end := strings.index(rest, BRIDGE_SETUP_PATH_MARK)
	if end < 0 do return ""
	return strings.clone(rest[:end], context.temp_allocator)
}

bridge_setup_dir_exists :: proc(path: string) -> bool { return os.is_dir(path) }

// bridge_setup_windows_user names the account the logon task is for
// (bridgesvc.Render_Input.windows_user), as install.ps1 did with the identity name.
bridge_setup_windows_user :: proc(domain, name: string) -> string {
	n := strings.trim_space(name)
	if n == "" do return ""
	d := strings.trim_space(domain)
	return n if d == "" else strings.concatenate({d, "\\", n}, context.temp_allocator)
}

bridge_setup_render_input :: proc(s: ^Bridge_Setup) -> bridgesvc.Render_Input {
	path, _ := os.lookup_env("PATH", context.temp_allocator)
	when ODIN_OS != .Windows {
		home, _ := os.lookup_env("HOME", context.temp_allocator)
		user, _ := os.lookup_env("USER", context.temp_allocator)
		path = bridge_setup_service_path(path, bridge_setup_login_shell_path(), home, user, bridge_setup_dir_exists)
	}
	tv, _ := os.lookup_env("TERMUX_VERSION", context.temp_allocator)
	windows_user := ""
	if s.host.os == .Windows {
		domain, _ := os.lookup_env("USERDOMAIN", context.temp_allocator)
		name, _ := os.lookup_env("USERNAME", context.temp_allocator)
		windows_user = bridge_setup_windows_user(domain, name)
	}
	return {hub = s.profile.hub_url, profile = s.profile.profile, path_env = path, termux_version = tv, windows_user = windows_user, bridge_port = s.ports[0], endpoint_port = s.ports[1]}
}

// ---- steps -------------------------------------------------------------------

// Hub names are sanitized for service names; distinct origins can therefore
// collide. Check the saved owner before any stop, staging, or binary mutation.
bridge_setup_check_owner :: proc(s: ^Bridge_Setup) -> bridgesvc.Step_Result {
	existing := bridgesvc.read_first_line(bridgesvc.pjoin(s.layout.state_dir, bridgesvc.HUB_URL_FILE))
	if existing == "" do existing = bridgesvc.hub_from_config(bridgesvc.pjoin(s.layout.state_dir, bridgesvc.CONFIG_FILE))
	if existing != "" {
		canonical, _, valid := bridgesvc.canonical_hub(existing, context.temp_allocator)
		if !valid || canonical != s.profile.hub_url do return {failure = .Fatal, message = fmt.tprintf("profile belongs to hub %s, not %s; choose another profile name", existing, s.profile.hub_url)}
	}
	return {ok = true}
}

bridge_setup_saved_hub :: proc(s: ^Bridge_Setup) -> string {
	existing := bridgesvc.read_first_line(bridgesvc.pjoin(s.layout.state_dir, bridgesvc.HUB_URL_FILE))
	if existing == "" do existing = bridgesvc.hub_from_config(bridgesvc.pjoin(s.layout.state_dir, bridgesvc.CONFIG_FILE))
	return existing
}

// bridge_setup_gather_facts reads the classification inputs (contract §3,
// "Detection inputs"). Read-only; runs under the instance lock.
bridge_setup_gather_facts :: proc(s: ^Bridge_Setup) -> bridgesvc.Install_Facts {
	l := s.layout
	f: bridgesvc.Install_Facts
	f.service_registered = bridge_service_registered(s.host, l.service_name)
	f.running = bridge_service_running(s.host, l) || bridge_service_runtime_pid(s.host, l) > 0
	installed_exe := bridgesvc.pjoin(l.bin_dir, bridgesvc.exe_name(s.host, "ham-bridge"))
	f.bin_present = os.is_file(installed_exe)
	f.staging_left = os.exists(s.staging)
	f.config_present = os.is_file(bridgesvc.pjoin(l.state_dir, bridgesvc.CONFIG_FILE)) && bridge_setup_saved_hub(s) != ""
	_, f.ports_present = bridgesvc.read_ports(l.state_dir)
	f.bridge_id = bridgesvc.credential_bridge_id(bridgesvc.read_first_line(bridgesvc.pjoin(l.state_dir, bridgesvc.TOKEN_FILE)))
	if m, ok := bridgesvc.read_reenroll_marker(l.state_dir); ok && bridgesvc.reenroll_marker_applies(m, f.bridge_id != "", f.bridge_id) {
		f.marker, f.marker_present = m, true
	}
	f.copy_binaries = s.copy_binaries
	f.bundle_version = contracts.APP_VERSION
	if !s.copy_binaries {
		f.binaries_match = true
		f.installed_version = contracts.APP_VERSION
	} else if f.bin_present {
		f.binaries_match = bridgesvc.files_identical(bridgesvc.pjoin(s.bundle_dir, bridgesvc.exe_name(s.host, "ham-bridge")), installed_exe)
		if f.binaries_match {
			f.installed_version = contracts.APP_VERSION
		} else {
			out, errout, ran, _ := bridge_process_run_capture({installed_exe, "--version"}, 5 * time.Second)
			if ran do f.installed_version = bridgesvc.parse_version_output(out)
			delete(out)
			delete(errout)
			if f.installed_version == "" {
				if rt, ok := bridgesvc.read_runtime_status(l.state_dir); ok do f.installed_version = rt.version
			}
		}
	}
	f.requested_version = strings.trim_space(option_value(s.args, "--version", ""))
	f.keep_version = has_flag(s.args, bridgesvc.KEEP_VERSION_FLAG)
	f.allow_downgrade = has_flag(s.args, bridgesvc.ALLOW_DOWNGRADE_FLAG)
	f.reinstall = has_flag(s.args, bridgesvc.REINSTALL_FLAG)
	f.reenroll = has_flag(s.args, "--reenroll")
	f.new_bridge = has_flag(s.args, "--new-bridge")
	f.reuse_bridge = strings.trim_space(option_value(s.args, "--reuse-bridge", ""))
	return f
}

// bridge_setup_enroll_argv: `bin/ham-bridge enroll` for the plan. Without a terminal
// (or with --headless / --json-progress) it is always --headless: no browser and no
// prompt on the machine being installed (contract §6).
bridge_setup_enroll_argv :: proc(s: ^Bridge_Setup, token: string) -> []string {
	l := s.layout
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, bridgesvc.pjoin(l.bin_dir, bridgesvc.exe_name(s.host, "ham-bridge")), "enroll", "--hub", s.profile.hub_url,
		"--config", bridgesvc.pjoin(l.state_dir, bridgesvc.CONFIG_FILE), "--bridge-token-file", token)
	if has_flag(s.args, "--headless") || !bridge_stdin_is_terminal(s.args) do append(&argv, "--headless")
	if has_flag(s.args, "--new-bridge") do append(&argv, "--new-bridge")
	if s.plan.reuse_bridge != "" do append(&argv, "--reuse-bridge", s.plan.reuse_bridge)
	// F1: a machine enrolled by another account is replaced only when the
	// caller (the desktop wizard after the user confirmed) says so.
	if has_flag(s.args, "--replace-other-account") do append(&argv, "--replace-other-account")
	return argv[:]
}

// bridge_setup_verify_readonly (S2): wait for connected without touching anything.
// Re-installing cannot fix a hub outage, so not connected is a warning, not a failure.
bridge_setup_verify_readonly :: proc(s: ^Bridge_Setup) -> bridgesvc.Step_Result {
	deadline := time.time_add(time.now(), BRIDGE_SETUP_VERIFY_TIMEOUT)
	for {
		st := bridge_service_status(s.host, s.layout.service_name)
		if st.running && st.connected do return {ok = true, message = fmt.tprintf("connected to %s (vault %s); nothing changed", st.hub, st.vault)}
		if time.diff(time.now(), deadline) <= 0 do break
		time.sleep(500 * time.Millisecond)
	}
	s.not_connected = true
	message := fmt.tprintf("running but not connected to %s (hub unreachable?); nothing changed", s.profile.hub_url)
	bridge_setup_emit(s, bridgesvc.Event{step = "verify", state = "warning", pct = bridgesvc.step_pct(.Verify, false), message = message, attempt = 1})
	return {ok = true, message = message}
}

// bridge_setup_summary is the final line (contract §3, "Final line").
bridge_setup_summary :: proc(data: rawptr) -> string {
	s := (^Bridge_Setup)(data)
	return bridge_setup_final_line(s.plan, s.facts, bridge_setup_final_state(s))
}

Bridge_Setup_Final :: struct {
	service:       string,
	hub:           string,
	bridge_id:     string,
	recovered:     []string,
	service_action: string,
	not_enrolled:  string,
	not_connected: bool,
}

bridge_setup_final_state :: proc(s: ^Bridge_Setup) -> Bridge_Setup_Final {
	return {
		service = s.layout.service_name,
		hub = s.profile.hub_url,
		bridge_id = bridgesvc.credential_bridge_id(bridgesvc.read_first_line(bridgesvc.pjoin(s.layout.state_dir, bridgesvc.TOKEN_FILE))),
		recovered = s.recovered[:],
		service_action = s.service_action,
		not_enrolled = s.not_enrolled,
		not_connected = s.not_connected,
	}
}

// bridge_setup_final_line builds the row's final line; pure for tests.
bridge_setup_final_line :: proc(p: bridgesvc.Install_Plan, f: bridgesvc.Install_Facts, o: Bridge_Setup_Final) -> string {
	version := bridgesvc.normalize_version(f.bundle_version if p.replace_binaries || f.installed_version == "" else f.installed_version)
	prefix := ""
	if len(o.recovered) > 0 do prefix = fmt.tprintf("Recovered an interrupted install of %s: %s; ", o.service, strings.join(o.recovered, ", ", context.temp_allocator))
	if o.not_enrolled != "" {
		return fmt.tprintf("%sInstalled %s v%s but not enrolled: %s. Run the same command again to enroll.", prefix, o.service, version, o.not_enrolled)
	}
	if p.noop {
		line := fmt.tprintf("%s v%s is already installed, enrolled as %s and connected; nothing changed.", o.service, version, o.bridge_id)
		if o.not_connected do line = fmt.tprintf("%s v%s is already installed and enrolled as %s, running but not connected to %s (hub unreachable?); nothing changed.", o.service, version, o.bridge_id, o.hub)
		if .S8a_Version_Kept in p.rows {
			line = fmt.tprintf("%s (installed v%s; this installer carried v%s; updates are not done by the installer)", line, bridgesvc.normalize_version(f.installed_version), bridgesvc.normalize_version(f.bundle_version))
		}
		return line
	}
	switch {
	case .S1_Fresh in p.rows:
		return fmt.tprintf("%sInstalled %s v%s, enrolled as %s, connected to %s.", prefix, o.service, version, o.bridge_id, o.hub)
	case .S4_Enrollment_Invalid in p.rows:
		return fmt.tprintf("%sRe-enrolled %s (was %s, reason %s) as %s; connected.", prefix, o.service, f.bridge_id, p.reenroll_reason, o.bridge_id)
	case .S3_Not_Enrolled in p.rows:
		return fmt.tprintf("%sEnrolled %s as %s; connected to %s.", prefix, o.service, o.bridge_id, o.hub)
	case .S8b_Version_Change in p.rows && p.reinstall && (f.installed_version == "" || bridgesvc.version_compare(f.installed_version, f.bundle_version) == 0):
		return fmt.tprintf("%sReinstalled %s v%s; connected.", prefix, o.service, version)
	case .S8b_Version_Change in p.rows:
		return fmt.tprintf("%sUpdated %s v%s → v%s; connected.", prefix, o.service, bridgesvc.normalize_version(f.installed_version) if f.installed_version != "" else "?", version)
	case .S6_Service in p.rows:
		what := o.service_action if o.service_action != "" else "started"
		return fmt.tprintf("%sRepaired %s (service %s); connected to %s.", prefix, o.service, what, o.hub)
	}
	return fmt.tprintf("%s%s v%s is installed, enrolled as %s and connected to %s.", prefix, o.service, version, o.bridge_id, o.hub)
}

bridge_setup_rollback_status :: proc(data: rawptr) -> (bool, string) {
	s := (^Bridge_Setup)(data)
	return !s.rollback_failed, s.rollback_message
}

bridge_setup_rollback_fail :: proc(s: ^Bridge_Setup, message: string) {
	if s.rollback_failed do return
	s.rollback_failed, s.rollback_message = true, strings.clone(message, context.temp_allocator)
	fmt.eprintln("ham-bridge rollback incomplete:", message)
	bridge_setup_emit(s, bridgesvc.Event{step = "setup", state = "warning", message = fmt.tprintf("rollback incomplete: %s", message)})
}

bridge_setup_stop_for_rollback :: proc(s: ^Bridge_Setup) -> (bool, string) {
	if !bridge_service_running(s.host, s.layout) && bridge_service_runtime_pid(s.host, s.layout) <= 0 do return true, "already stopped"
	return bridge_service_action(s.host, s.layout.service_name, .Stop)
}

bridge_setup_run :: proc(data: rawptr, step: bridgesvc.Step) -> bridgesvc.Step_Result {
	s := (^Bridge_Setup)(data)
	l := s.layout
	switch step {
	case .Lock:
		if err := os.make_directory_all(l.state_dir); err != nil && !os.is_dir(l.state_dir) do return {failure = .Fatal, message = fmt.tprintf("cannot create %s: %v", l.state_dir, err)}
		locked := bridgesvc.lock_acquire(s.lock_path, s.pid, time.now(), bridge_os_pid_alive)
		if !locked.ok {
			if locked.failure == .Fatal {
				// S7a: a live setup/update owns the instance.
				owner, _, _ := bridgesvc.lock_read(s.lock_path)
				s.exit_code = bridgesvc.EXIT_BUSY
				s.refusal = fmt.tprintf("Another setup or update of %s is running (pid %d); try again when it finishes.", l.service_name, owner)
			}
			return locked
		}
		// S5b before anything else is read or written.
		if ownership := bridge_setup_check_owner(s); !ownership.ok {
			s.exit_code = bridgesvc.EXIT_REFUSED
			s.refusal = fmt.tprintf("Profile %s belongs to hub %s, not %s; pass --profile <name> to install a separate profile.", l.service_name, bridge_setup_saved_hub(s), s.profile.hub_url)
			return ownership
		}
		s.facts = bridge_setup_gather_facts(s)
		s.plan = bridgesvc.classify_install(s.facts)
		if s.plan.refuse {
			s.exit_code = s.plan.exit_code
			s.refusal = fmt.tprintf("%s %s", l.service_name, s.plan.message)
			return {failure = .Fatal, message = s.plan.message}
		}
		bridge_setup_emit(s, bridgesvc.Event{step = "detect", state = "ok", pct = bridgesvc.step_pct(.Lock, false), message = bridgesvc.install_rows_label(s.plan.rows), attempt = 1})
		return {ok = true}

	case .Stage:
		if ownership := bridge_setup_check_owner(s); !ownership.ok do return ownership
		if !s.snapshot_taken {
			s.snapshot_taken = true
			s.was_installed = bridge_service_registered(s.host, l.service_name)
			s.was_running = bridge_service_running(s.host, l) || bridge_service_runtime_pid(s.host, l) > 0
		}
		if !s.plan.replace_binaries {
			// S7: a leftover staging dir is discarded even when bin/ is kept.
			if !s.plan.noop && os.exists(s.staging) {
				if err := os.remove_all(s.staging); err != nil do return {failure = .Fatal, message = fmt.tprintf("cannot remove leftover %s: %v", s.staging, err)}
				append(&s.recovered, "discarded the leftover staging dir")
			}
			return {ok = true, message = "skipped"}
		}
		if os.exists(s.staging) {
			return {failure = .Partial_Install, message = fmt.tprintf("leftover staging dir %s from an interrupted setup", s.staging)}
		}
		if err := os.make_directory_all(s.staging); err != nil && !os.is_dir(s.staging) do return {failure = .Fatal, message = fmt.tprintf("cannot create %s: %v", s.staging, err)}
		for base in BRIDGE_SETUP_BINARIES {
			name := bridgesvc.exe_name(s.host, base)
			src := bridgesvc.pjoin(s.bundle_dir, name)
			if !os.exists(src) {
				if base == "ham-bridge" do return {failure = .Fatal, message = fmt.tprintf("bundle %s has no %s", s.bundle_dir, name)}
				continue
			}
			dst := bridgesvc.pjoin(s.staging, name)
			if err := os.copy_file(dst, src); err != nil do return {failure = .Partial_Install, message = fmt.tprintf("copy %s: %v", src, err)}
			_ = os.chmod(dst, {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})
		}
		return {ok = true, message = fmt.tprintf("staged from %s", s.bundle_dir)}

	case .Binaries:
		if s.plan.noop do return {ok = true, message = "skipped"}
		// Quiesce before touching bin/, even on platforms that permit renaming
		// running executables; a repair (enroll, service, config) restarts it too.
		if s.was_running && !s.stopped_for_setup {
			if ok, msg := bridge_setup_stop_for_rollback(s); !ok {
				return {failure = .Fatal, message = fmt.tprintf("cannot stop the previous Bridge before updating: %s", msg)}
			}
			s.stopped_for_setup = true
		}
		if !s.plan.replace_binaries do return {ok = true, message = "skipped"}
		// The PTY host daemon outlives the service. An idle one is stopped so it does
		// not keep running the old ham-pty-host from bin.bak*; one hosting agents
		// stays alive and the new bridge replaces it later (setup_pty_host.odin).
		bridge_setup_quiesce_pty_host(s)
		bak := strings.concatenate({l.bin_dir, ".bak"}, context.temp_allocator)
		if os.exists(bak) {
			// A live PTY daemon may still execute from an earlier backup. Keep
			// that directory intact and give this transaction its own backup.
			bak = fmt.tprintf("%s.bak-%d-%d", l.bin_dir, s.pid, time.to_unix_nanoseconds(time.now()))
		}
		if os.exists(l.bin_dir) {
			// A running tray executes bin/ham-bridge too. Windows keeps bin/ busy:
			// stop it there; finish starts it again from the new binaries. On
			// Linux/macOS the rename works under it and the tray relaunches itself
			// once it sees the new binary, staying in the user's login session.
			if s.host.os == .Windows && bridge_tray_stop(s.host, l) do s.tray_stopped = true
			if err := os.rename(l.bin_dir, bak); err != nil {
				// Windows: a running bridge keeps its executable's directory busy.
				return {failure = .Stale_Service, message = fmt.tprintf("cannot move %s aside (in use?): %v", l.bin_dir, err)}
			}
			s.binary_backup = strings.clone(bak, context.temp_allocator)
		}
		if err := os.rename(s.staging, l.bin_dir); err != nil {
			if os.exists(bak) && !os.exists(l.bin_dir) {
				if restored := os.rename(bak, l.bin_dir); restored != nil {
					bridge_setup_rollback_fail(s, fmt.tprintf("cannot restore %s: %v", bak, restored))
				} else {
					s.binary_backup = ""
				}
			}
			return {failure = .Partial_Install, message = fmt.tprintf("cannot install %s: %v", l.bin_dir, err)}
		}
		return {ok = true, message = fmt.tprintf("installed into %s (previous kept as bin.bak)", l.bin_dir)}

	case .Config:
		if s.plan.noop do return {ok = true, message = "skipped"}
		if ownership := bridge_setup_check_owner(s); !ownership.ok do return ownership
		cfg := bridgesvc.pjoin(l.state_dir, bridgesvc.CONFIG_FILE)
		hub_file := bridgesvc.pjoin(l.state_dir, bridgesvc.HUB_URL_FILE)
		profile_file := bridgesvc.pjoin(l.state_dir, bridgesvc.PROFILE_FILE)
		for p in ([?]string{cfg, hub_file, profile_file}) do bridge_setup_backup(s, p)
		existing := bridgesvc.read_first_line(hub_file)
		if existing == "" do existing = bridgesvc.hub_from_config(cfg)
		if existing != "" {
			if canon, _, ok := bridgesvc.canonical_hub(existing, context.temp_allocator); ok && canon != s.profile.hub_url {
				return {failure = .Fatal, message = fmt.tprintf("%s belongs to hub %s, not %s", l.state_dir, canon, s.profile.hub_url)}
			}
		}
		migrated := "kept"
		if !os.exists(cfg) {
			if os.write_entire_file_from_string(cfg, bridgesvc.default_config_toml(s.profile.hub_url, l.data_dir), {.Read_User, .Write_User}) != nil do return {failure = .Fatal, message = "cannot write config.toml"}
			migrated = "written"
		}
		_ = os.write_entire_file_from_string(hub_file, strings.concatenate({s.profile.hub_url, "\n"}, context.temp_allocator))
		if s.profile.profile != "" do _ = os.write_entire_file_from_string(profile_file, strings.concatenate({s.profile.profile, "\n"}, context.temp_allocator))
		return {ok = true, message = fmt.tprintf("config.toml %s", migrated)}

	case .Ports:
		if s.plan.noop do return {ok = true, message = "skipped"}
		bridge_setup_backup(s, bridgesvc.pjoin(l.state_dir, bridgesvc.PORTS_FILE))
		// The old process has exited. Any remaining listener is unrelated and
		// must be avoided, even when this profile was running before setup.
		ports, reused, ok := bridgesvc.allocate_ports(l.state_root, l.state_dir, bridge_setup_port_busy)
		if !ok do return {failure = .Fatal, message = "no free loopback ports"}
		s.ports = ports
		return {ok = true, message = fmt.tprintf("bridge %d, endpoint %d%s", ports[0], ports[1], " (kept)" if reused else "")}

	case .Service:
		if s.plan.noop do return {ok = true, message = "skipped"}
		return bridge_setup_register(s, force = s.plan.reinstall)

	case .Enroll:
		if s.plan.noop || !s.plan.enroll do return {ok = true, message = "skipped"}
		token := bridgesvc.pjoin(l.state_dir, bridgesvc.TOKEN_FILE)
		current := bridgesvc.credential_bridge_id(bridgesvc.read_first_line(token))
		argv := bridge_setup_enroll_argv(s, token)
		if !bridge_setup_exec_inherit(argv) {
			// S1a: keep what is installed, do not start it; a re-run continues at S3/S4.
			s.not_enrolled = "enrollment was not approved or did not complete"
			return {halt = true, message = fmt.tprintf("not enrolled: %s", s.not_enrolled)}
		}
		s.enrolled_now = true
		if s.plan.clear_marker do bridgesvc.clear_reenroll_marker(l.state_dir)
		if current != "" do return {ok = true, message = fmt.tprintf("re-enrolled (was %s)", current)}
		return {ok = true, message = "enrolled"}

	case .Extensions:
		if s.plan.noop || !s.plan.extensions do return {ok = true, message = "skipped"}
		return bridge_setup_extensions(s)

	case .Start:
		if s.plan.noop do return {ok = true, message = "skipped"}
		return bridge_setup_start(s)

	case .Verify:
		if s.plan.noop do return bridge_setup_verify_readonly(s)
		deadline := time.time_add(time.now(), BRIDGE_SETUP_VERIFY_TIMEOUT)
		for time.diff(time.now(), deadline) > 0 {
			st := bridge_service_status(s.host, l.service_name, s.restart_at, s.stale_pid)
			if st.running && st.connected do return {ok = true, message = fmt.tprintf("connected to %s (vault %s)", st.hub, st.vault)}
			// The restarted bridge found its credential refused and parked (S4 next run).
			if m, ok := bridgesvc.read_reenroll_marker(l.state_dir); ok && m.at >= s.restart_at && bridgesvc.reenroll_marker_applies(m, st.enrolled, bridgesvc.credential_bridge_id(bridgesvc.read_first_line(bridgesvc.pjoin(l.state_dir, bridgesvc.TOKEN_FILE)))) {
				return {failure = .Fatal, message = fmt.tprintf("the hub refused this bridge's credential (%s); run the same command again to re-enroll", m.reason)}
			}
			time.sleep(500 * time.Millisecond)
		}
		st := bridge_service_status(s.host, l.service_name, s.restart_at, s.stale_pid)
		log := bridgesvc.pjoin(l.data_dir, "logs", "bridge.err.log")
		if !st.running {
			if bridge_setup_port_busy(s.ports[0]) do return {failure = .Port_In_Use, message = fmt.tprintf("service is not running and port %d is held by another process", s.ports[0]), log = log}
			return {failure = .Stale_Service, message = "service is not running", log = log}
		}
		return {failure = .Fatal, message = "service runs but did not connect to the hub in time", log = log}
	}
	return {failure = .Fatal, message = "unknown step"}
}

// bridge_setup_extensions installs the bundle's provider extensions into the
// data dir and ensures them for every detected provider, one progress event
// per provider. A provider that still fails after self-healing is reported in
// the step's message but does not roll back the install.
bridge_setup_extensions :: proc(s: ^Bridge_Setup) -> bridgesvc.Step_Result {
	l := s.layout
	src := bridge_extensions_bundle_source(s.bundle_dir)
	copied := "skipped"
	if src != "" {
		ok, msg := bridge_extensions_install_bundle(src, l.data_dir)
		if !ok do return {failure = .Fatal, message = msg}
		copied = msg
	}
	ext_root := bridgesvc.pjoin(l.data_dir, "extensions")
	if !os.is_dir(ext_root) do return {ok = true, message = "skipped"}
	on_line := proc(data: rawptr, line: Bridge_Extension_Sync_Line) {
		bridge_setup_emit(data, bridgesvc.Event{step = "extensions", state = "progress",
			pct = bridgesvc.step_pct(.Extensions, false), message = line.line, attempt = 1})
	}
	lines, failures, registered_from := bridge_extensions_sync_installed(l.data_dir, on_line, s)
	installed := 0
	for line in lines do if line.ok && !line.skipped do installed += 1
	msg := fmt.tprintf("%d provider extension(s) ready, %d failed (bundle: %s; registered from %s)", installed, failures, copied, registered_from)
	return {ok = true, message = msg}
}

// bridge_setup_start (re)starts the service and records what Verify must not
// mistake for the new bridge: the old bridge's runtime-status.json (it has no
// SIGTERM handler, so it never writes connected=false) and anything older.
bridge_setup_start :: proc(s: ^Bridge_Setup) -> bridgesvc.Step_Result {
	l := s.layout
	s.stale_pid = 0
	if rt, ok := bridgesvc.read_runtime_status(l.state_dir); ok do s.stale_pid = rt.pid
	s.restart_at = time.to_unix_seconds(time.now())
	action: bridgesvc.Action = .Restart if bridge_service_running(s.host, l) else .Start
	ok, out := bridge_service_action(s.host, l.service_name, action)
	if !ok do return {failure = .Stale_Service, message = fmt.tprintf("service %s failed: %s", bridgesvc.backend_name(l.backend), out)}
	return {ok = true}
}

// bridge_setup_file_is :: the file exists and holds exactly text.
bridge_setup_file_is :: proc(path, text: string) -> bool {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	return err == nil && string(data) == text
}

// bridge_setup_register renders the service definition and registers it. Unless
// forced (a remediation), a registered service whose rendered files are unchanged
// is left alone: no write, no daemon-reload, no schtasks /Create (S3/S4 repairs).
bridge_setup_register :: proc(s: ^Bridge_Setup, force: bool) -> bridgesvc.Step_Result {
	l := s.layout
	in_ := bridge_setup_render_input(s)
	_ = os.make_directory_all(bridgesvc.pjoin(l.data_dir, "logs"))
	_ = os.make_directory_all(bridgesvc.pjoin(l.data_dir, "run"))
	if r := bridge_setup_write_ctl_wrapper(s, in_); !r.ok do return r
	if !force && s.facts.service_registered {
		unchanged := false
		#partial switch l.backend {
		case .Systemd, .Launchd, .Runit:
			unchanged = bridge_setup_file_is(l.service_file, bridgesvc.render_service_file(s.host, l, in_))
		case .Schtasks:
			unchanged = bridge_setup_file_is(bridgesvc.windows_run_cmd_path(l), bridgesvc.render_windows_run_cmd(s.host, l, in_)) &&
				bridge_setup_file_is(bridgesvc.windows_launcher_path(l), bridgesvc.render_windows_launcher(l)) &&
				bridge_setup_file_is(bridgesvc.pjoin(l.data_dir, "task.xml"), bridgesvc.render_service_file(s.host, l, in_))
		}
		if unchanged do return {ok = true, message = fmt.tprintf("%s unchanged", bridgesvc.backend_name(l.backend))}
	}
	s.service_action = "registered"
	switch l.backend {
	case .None:
		return {failure = .Fatal, message = "no service manager"}
	case .Systemd, .Launchd, .Runit:
		bridge_setup_backup(s, l.service_file)
		_ = os.make_directory_all(bridgesvc.pdir(l.service_file))
		mode: os.Permissions = {.Read_User, .Write_User, .Read_Group, .Read_Other}
		if l.backend == .Runit do mode += {.Execute_User, .Execute_Group, .Execute_Other}
		if err := os.write_entire_file_from_string(l.service_file, bridgesvc.render_service_file(s.host, l, in_), mode); err != nil {
			return {failure = .Fatal, message = fmt.tprintf("cannot write %s: %v", l.service_file, err)}
		}
		if l.backend == .Systemd {
			if ok, out := bridge_service_exec({"systemctl", "--user", "daemon-reload"}); !ok do return {failure = .Stale_Service, message = fmt.tprintf("systemctl daemon-reload: %s", out)}
			_, _ = bridge_service_exec({"systemctl", "--user", "enable", strings.concatenate({l.service_name, ".service"}, context.temp_allocator)})
		}
	case .Schtasks:
		run_cmd := bridgesvc.windows_run_cmd_path(l)
		bridge_setup_backup(s, run_cmd)
		if err := os.write_entire_file_from_string(run_cmd, bridgesvc.render_windows_run_cmd(s.host, l, in_)); err != nil do return {failure = .Fatal, message = fmt.tprintf("cannot write %s: %v", run_cmd, err)}
		launcher := bridgesvc.windows_launcher_path(l)
		bridge_setup_backup(s, launcher)
		if err := os.write_entire_file_from_string(launcher, bridgesvc.render_windows_launcher(l)); err != nil do return {failure = .Fatal, message = fmt.tprintf("cannot write %s: %v", launcher, err)}
		xml := bridgesvc.pjoin(l.data_dir, "task.xml")
		_ = os.write_entire_file_from_string(xml, bridgesvc.render_service_file(s.host, l, in_))
		tn := strings.concatenate({"\\", l.service_name}, context.temp_allocator)
		if ok, out := bridge_service_exec({"schtasks", "/Create", "/TN", tn, "/XML", xml, "/F"}); !ok do return {failure = .Stale_Service, message = fmt.tprintf("schtasks /Create: %s", out)}
	}
	return {ok = true, message = fmt.tprintf("%s rendered", bridgesvc.backend_name(l.backend))}
}

// bridge_setup_write_ctl_wrapper (re)writes bin/ham-ctl-<service>, the profile's
// CLI for people. Written here rather than staged because it needs the profile's
// ports, and on every run so a bin/ swap (install or update) never drops it.
bridge_setup_write_ctl_wrapper :: proc(s: ^Bridge_Setup, in_: bridgesvc.Render_Input) -> bridgesvc.Step_Result {
	l := s.layout
	path := bridgesvc.ctl_wrapper_path(s.host, l)
	// No bridge_setup_backup: rollback restores bin/ from bin.bak, and the
	// generic restore would rewrite the wrapper without its execute bit.
	_ = os.make_directory_all(l.bin_dir)
	mode: os.Permissions = {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other}
	text := bridgesvc.render_ctl_wrapper(s.host, l, in_)
	if bridge_setup_file_is(path, text) do return {ok = true}
	if err := os.write_entire_file_from_string(path, text, mode); err != nil {
		return {failure = .Fatal, message = fmt.tprintf("cannot write %s: %v", path, err)}
	}
	_ = os.chmod(path, mode) // an existing file keeps its old mode on write
	return {ok = true}
}

// bridge_setup_remediate executes bridgesvc.remediation_plan for a known failure.
bridge_setup_remediate :: proc(data: rawptr, step: bridgesvc.Step, failure: bridgesvc.Failure) -> (bool, string) {
	s := (^Bridge_Setup)(data)
	l := s.layout
	plan := bridgesvc.remediation_plan(step, failure)
	if plan == {} do return false, "no remediation"
	bak := s.binary_backup
	did := make([dynamic]string, context.temp_allocator)
	for r in plan {
		switch r {
		case .Break_Lock:
			if !bridgesvc.lock_break(s.lock_path) do return false, "cannot remove the dead owner's install lock"
			append(&did, "removed the dead owner's install lock")
			append(&s.recovered, "removed a dead setup's lock")
		case .Discard_Staging:
			_ = os.remove_all(s.staging)
			if bak != "" && !os.exists(l.bin_dir) && os.exists(bak) {
				if err := os.rename(bak, l.bin_dir); err != nil do return false, fmt.tprintf("cannot restore backup: %v", err)
				s.binary_backup = ""
			}
			append(&did, "discarded the partial install")
			append(&s.recovered, "discarded the partial install")
		case .Restage:
			if res := bridge_setup_run(data, .Stage); !res.ok do return false, fmt.tprintf("re-staging failed: %s", res.message)
			append(&did, "re-staged the bundle")
		case .Stop_Service:
			if ok, msg := bridge_service_action(s.host, l.service_name, .Stop); !ok do return false, msg
			if s.was_running do s.stopped_for_setup = true
			append(&did, "stopped the service")
		case .Reallocate_Ports:
			ports, _, ok := bridgesvc.allocate_ports(l.state_root, l.state_dir, bridge_setup_port_busy)
			if !ok do return false, "no free loopback ports"
			s.ports = ports
			append(&did, fmt.tprintf("moved to ports %d/%d", ports[0], ports[1]))
		case .Register:
			if res := bridge_setup_register(s, force = true); !res.ok do return false, fmt.tprintf("re-registering failed: %s", res.message)
			append(&did, "re-rendered and re-registered the service")
		case .Start_Service:
			if res := bridge_setup_start(s); !res.ok do return false, res.message
			append(&did, "started it again")
		}
	}
	return true, strings.join(did[:], ", ", context.temp_allocator)
}

bridge_setup_undo :: proc(data: rawptr, step: bridgesvc.Step) {
	s := (^Bridge_Setup)(data)
	if s.rollback_failed do return
	l := s.layout
	switch step {
	case .Lock: // released in finish
	case .Stage:
		_ = os.remove_all(s.staging)
	case .Binaries:
		if !s.copy_binaries do return
		bak := s.binary_backup
		if bak != "" && os.exists(bak) {
			if ok, msg := bridge_setup_stop_for_rollback(s); !ok {
				bridge_setup_rollback_fail(s, fmt.tprintf("cannot stop replacement before restoring binaries: %s", msg)); return
			}
			if os.exists(l.bin_dir) {
				if err := os.remove_all(l.bin_dir); err != nil {
					bridge_setup_rollback_fail(s, fmt.tprintf("cannot remove replacement binaries: %v", err)); return
				}
			}
			if err := os.rename(bak, l.bin_dir); err != nil {
				bridge_setup_rollback_fail(s, fmt.tprintf("cannot restore %s: %v", bak, err)); return
			}
			s.binary_backup = ""
		}
	case .Config:
		for p in ([?]string{bridgesvc.CONFIG_FILE, bridgesvc.HUB_URL_FILE, bridgesvc.PROFILE_FILE}) do bridge_setup_restore(s, bridgesvc.pjoin(l.state_dir, p))
	case .Ports:
		bridge_setup_restore(s, bridgesvc.pjoin(l.state_dir, bridgesvc.PORTS_FILE))
	case .Service:
		#partial switch l.backend {
		case .Schtasks:
			bridge_setup_restore(s, bridgesvc.windows_run_cmd_path(l))
			bridge_setup_restore(s, bridgesvc.windows_launcher_path(l))
			if !s.was_installed do _, _ = bridge_service_exec({"schtasks", "/Delete", "/TN", strings.concatenate({"\\", l.service_name}, context.temp_allocator), "/F"})
		case:
			bridge_setup_restore(s, l.service_file)
			if l.backend == .Systemd do _, _ = bridge_service_exec({"systemctl", "--user", "daemon-reload"})
		}
	case .Extensions:
		// Provider registrations are left as repaired; only the bundle copy is undone.
		bridge_extensions_restore(l.data_dir)
	case .Enroll:
		// An enrollment that completed is kept: the credential is valid for this hub
		// and re-running setup reuses it instead of creating another bridge.
	case .Start, .Verify:
		if ok, msg := bridge_setup_stop_for_rollback(s); !ok do bridge_setup_rollback_fail(s, msg)
	}
}

bridge_setup_finish :: proc(data: rawptr, ok: bool) {
	s := (^Bridge_Setup)(data)
	if !ok && s.tray_stopped && !s.rollback_failed do _ = bridge_tray_spawn(bridgesvc.tray_launch_argv(s.host, s.layout), nil)
	if !ok && s.was_running && s.stopped_for_setup && !s.rollback_failed {
		// Leave the previous install running, as it was before setup.
		if started, msg := bridge_service_action(s.host, s.layout.service_name, .Start); !started do bridge_setup_rollback_fail(s, fmt.tprintf("previous Bridge could not be restarted: %s", msg))
	}
	if ok && s.plan.noop {
		// S2: nothing was written, the tray included.
	} else if ok {
		_ = os.remove_all(s.staging)
		// The tray is a convenience: it is reported, never a reason to roll back.
		bridge_setup_emit(data, bridgesvc.Event{step = "tray", state = "start", pct = 100, attempt = 1})
		tok, msg := bridge_tray_install(s.host, s.layout, s.args, force_start = s.tray_stopped)
		state := "ok" if tok else "warning"
		if tok && strings.has_prefix(msg, "skipped") do state = "skipped"
		bridge_setup_emit(data, bridgesvc.Event{step = "tray", state = state, pct = 100, message = msg, attempt = 1})
	}
	bridgesvc.lock_release(s.lock_path, s.pid)
}
