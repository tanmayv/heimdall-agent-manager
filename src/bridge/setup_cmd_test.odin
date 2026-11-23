package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import bridgesvc "odin_test:lib/bridgesvc"

@(test)
test_setup_rejects_colliding_hub_owner_before_stopping_or_staging :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/bridge-owner-preflight-%d", os.temp_dir(context.temp_allocator), os.get_pid())
	defer os.remove_all(root)
	host := bridgesvc.Host{os = .Linux, home = root, uid = 1000}
	a, a_ok := bridgesvc.profile_from("https://a.b", "work", context.temp_allocator)
	b, b_ok := bridgesvc.profile_from("https://a-b", "work", context.temp_allocator)
	testing.expect(t, a_ok && b_ok)
	testing.expect_value(t, a.service_name, b.service_name)
	l := bridgesvc.layout_for(host, a.service_name)
	testing.expect(t, os.make_directory_all(l.state_dir) == nil)
	testing.expect(t, os.write_entire_file_from_string(bridgesvc.pjoin(l.state_dir, bridgesvc.HUB_URL_FILE), a.hub_url) == nil)
	s := Bridge_Setup{host = host, profile = b, layout = l, copy_binaries = true, staging = bridgesvc.pjoin(l.data_dir, ".staging")}
	result := bridge_setup_run(&s, .Stage)
	testing.expect(t, !result.ok && result.failure == .Fatal)
	testing.expect(t, !s.snapshot_taken && !s.stopped_for_setup, "ownership must be checked before service discovery or stop")
	testing.expect(t, !os.exists(s.staging), "another Hub's profile must not be staged over")
}

@(test)
test_bridge_setup_enroll_needed :: proc(t: ^testing.T) {
	base := []string{"setup", "--hub", "https://hub.example.com"}
	testing.expect(t, bridge_setup_enroll_needed(base, ""), "no credential: enroll")
	testing.expect(t, !bridge_setup_enroll_needed(base, "brg_current"), "enrolled: skip")
	testing.expect(t, !bridge_setup_enroll_needed([]string{"setup", "--reuse-bridge", "brg_current"}, "brg_current"), "reuse of the current bridge: skip")
	testing.expect(t, bridge_setup_enroll_needed([]string{"setup", "--reuse-bridge", "brg_other"}, "brg_current"), "reuse of another bridge: enroll")
	testing.expect(t, bridge_setup_enroll_needed([]string{"setup", "--new-bridge"}, "brg_current"), "--new-bridge: enroll")
	testing.expect(t, bridge_setup_enroll_needed([]string{"setup", "--reenroll"}, "brg_current"), "--reenroll: enroll the same bridge again")
	testing.expect(t, bridge_setup_enroll_needed([]string{"setup", "--reenroll", "--reuse-bridge", "brg_current"}, "brg_current"), "--reenroll wins over a matching --reuse-bridge")
}

@(test)
test_bridge_setup_service_path_merges_login_shell_and_known_dirs :: proc(t: ^testing.T) {
	exists :: proc(path: string) -> bool {
		return path == "/Users/u/.local/bin" || path == "/opt/homebrew/bin" || path == "/etc/profiles/per-user/u/bin"
	}
	// A GUI/launchd PATH plus the login shell's: the order is kept, duplicates
	// dropped, existing well-known dirs added, the system dirs always last.
	got := bridge_setup_service_path("/usr/bin:/bin", "/opt/homebrew/bin:/Users/u/.npm/bin:/usr/bin", "/Users/u", "u", exists)
	testing.expect_value(t, got, "/usr/bin:/bin:/opt/homebrew/bin:/Users/u/.npm/bin:/Users/u/.local/bin:/etc/profiles/per-user/u/bin:/usr/sbin:/sbin")
	// No login shell: the known dirs still make Homebrew and ~/.local/bin visible.
	got = bridge_setup_service_path("/usr/bin:/bin:/usr/sbin:/sbin", "", "/Users/u", "u", exists)
	testing.expect_value(t, got, "/usr/bin:/bin:/usr/sbin:/sbin:/Users/u/.local/bin:/etc/profiles/per-user/u/bin:/opt/homebrew/bin")
}

@(test)
test_bridge_setup_extract_marked_path_ignores_shell_noise :: proc(t: ^testing.T) {
	out := "Last login: today\nwelcome!\n" + BRIDGE_SETUP_PATH_MARK + "/a:/b" + BRIDGE_SETUP_PATH_MARK + "\n% "
	testing.expect_value(t, bridge_setup_extract_marked_path(out), "/a:/b")
	testing.expect_value(t, bridge_setup_extract_marked_path("no markers"), "")
	testing.expect_value(t, bridge_setup_extract_marked_path(BRIDGE_SETUP_PATH_MARK + "/a"), "")
}

@(test)
test_bridge_setup_windows_user :: proc(t: ^testing.T) {
	testing.expect_value(t, bridge_setup_windows_user("CORP", "ann"), "CORP\\ann")
	testing.expect_value(t, bridge_setup_windows_user("", "ann"), "ann")
	testing.expect_value(t, bridge_setup_windows_user("CORP", " "), "")
}

// --separate-account always asks for a profile of its own; without it a
// non-interactive setup (installers, --headless) never prompts and keeps the
// requested profile, and --replace-other-account keeps it too.
@(test)
test_bridge_setup_wants_separate_account :: proc(t: ^testing.T) {
	host := bridgesvc.Host{os = .Linux, home = "/nonexistent-ham-home", uid = 1000}
	profile, ok := bridgesvc.profile_from("https://hub.example.com", "", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect(t, bridge_setup_wants_separate_account(host, []string{"setup", "--separate-account"}, profile))
	testing.expect(t, !bridge_setup_wants_separate_account(host, []string{"setup", "--headless", "--new-bridge"}, profile))
	testing.expect(t, !bridge_setup_wants_separate_account(host, []string{"setup", "--replace-other-account"}, profile))
	// Nothing enrolled: the requested profile is used as is.
	selected_1, found_1 := bridgesvc.separate_account_profile(host, profile.hub_name, "")
	testing.expect(t, found_1)
	testing.expect_value(t, selected_1, "")
	selected_2, found_2 := bridgesvc.separate_account_profile(host, profile.hub_name, "work")
	testing.expect(t, found_2)
	testing.expect_value(t, selected_2, "work")
}

// Headless (installers, Electron) nobody can confirm a replace: a run that would
// enroll a new bridge into another account's enrolled profile goes to a separate
// profile, and the enrolled one is left alone.
@(test)
test_bridge_setup_headless_enrolled_profile_defaults_to_separate :: proc(t: ^testing.T) {
	home := fmt.aprintf("%s/.cache/heimdall-tests/setup-separate-%d", os.get_env("HOME", context.temp_allocator), os.get_pid())
	defer delete(home)
	_ = os.remove_all(home)
	defer os.remove_all(home)
	host := bridgesvc.Host{os = .Linux, home = home, uid = 1000}
	profile, ok := bridgesvc.profile_from("https://hub.example.com", "", context.temp_allocator)
	testing.expect(t, ok)
	l := bridgesvc.layout_for(host, profile.service_name)
	testing.expect(t, os.make_directory_all(l.state_dir) == nil)
	credential := strings.concatenate({bridgesvc.CREDENTIAL_HEADER, "secret brg_account_a\n"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file_from_string(bridgesvc.pjoin(l.state_dir, bridgesvc.TOKEN_FILE), credential) == nil)

	headless := []string{"setup", "--hub", "https://hub.example.com", "--headless", "--json-progress"}
	with :: proc(base: []string, extra: ..string) -> []string {
		out := make([dynamic]string, context.temp_allocator)
		append(&out, ..base)
		append(&out, ..extra)
		return out[:]
	}
	testing.expect(t, bridge_setup_wants_separate_account(host, with(headless, "--new-bridge"), profile), "new bridge into an enrolled profile: separate")
	testing.expect(t, bridge_setup_wants_separate_account(host, with(headless, "--reuse-bridge", "brg_other"), profile), "another bridge into an enrolled profile: separate")
	testing.expect(t, !bridge_setup_wants_separate_account(host, headless, profile), "update of the enrolled profile stays in place")
	testing.expect(t, !bridge_setup_wants_separate_account(host, with(headless, "--reuse-bridge", "brg_account_a"), profile), "reuse of the current bridge stays in place")
	testing.expect(t, !bridge_setup_wants_separate_account(host, with(headless, "--reenroll"), profile), "re-pairing its own bridge stays in place")
	testing.expect(t, !bridge_setup_wants_separate_account(host, with(headless, "--new-bridge", "--replace-other-account"), profile), "an explicit replace is honoured")
	// The separate profile is a fresh one; the enrolled default is never chosen.
	selected_3, found_3 := bridgesvc.separate_account_profile(host, profile.hub_name, "")
	testing.expect(t, found_3)
	testing.expect_value(t, selected_3, "account-2")
}

// ---- installer contract state table (docs/specs/bridge-installer-contract.md §3) ----

@(private = "file")
setup_test_home :: proc(name: string) -> string {
	home := fmt.tprintf("%s/.cache/heimdall-tests/%s-%d", os.get_env("HOME", context.temp_allocator), name, os.get_pid())
	_ = os.remove_all(home)
	return home
}

@(private = "file")
setup_test_make :: proc(home: string, args: []string) -> Bridge_Setup {
	host := bridgesvc.Host{os = .Linux, home = home, uid = 1000}
	profile, _ := bridgesvc.profile_from("https://hub.example.com", "", context.temp_allocator)
	l := bridgesvc.layout_for(host, profile.service_name)
	_ = os.make_directory_all(l.state_dir)
	_ = os.make_directory_all(l.data_dir)
	return Bridge_Setup {
		host = host, profile = profile, layout = l, args = args, json_progress = true, pid = os.get_pid(),
		copy_binaries = true, staging = bridgesvc.pjoin(l.data_dir, ".staging"),
		lock_path = bridgesvc.pjoin(l.state_dir, bridgesvc.LOCK_FILE),
		backups = make(map[string]Maybe(string), context.temp_allocator),
		recovered = make([dynamic]string, context.temp_allocator),
	}
}

// S2: a healthy instance is not touched by any step: no stop, no file, no restart.
@(test)
test_setup_s2_noop_plan_skips_every_mutating_step :: proc(t: ^testing.T) {
	home := setup_test_home("setup-s2-noop")
	defer os.remove_all(home)
	s := setup_test_make(home, []string{"setup", "--hub", "https://hub.example.com", "--headless", "--json-progress"})
	l := s.layout
	cfg := bridgesvc.pjoin(l.state_dir, bridgesvc.CONFIG_FILE)
	testing.expect(t, os.write_entire_file_from_string(cfg, "# kept as is\n") == nil)
	testing.expect(t, os.write_entire_file_from_string(bridgesvc.pjoin(l.state_dir, bridgesvc.HUB_URL_FILE), "https://hub.example.com\n") == nil)
	s.plan = {noop = true, rows = {.S2_Healthy}}
	s.snapshot_taken = true // was_running = false: proves nothing is stopped either way
	for step in ([]bridgesvc.Step{.Stage, .Binaries, .Config, .Ports, .Service, .Enroll, .Extensions, .Start}) {
		r := bridge_setup_run(&s, step)
		testing.expectf(t, r.ok && r.message == "skipped", "%v must be skipped, got ok=%v %q", step, r.ok, r.message)
	}
	testing.expect(t, !s.stopped_for_setup)
	testing.expect(t, !os.exists(s.staging) && !os.exists(l.bin_dir) && !os.exists(l.service_file))
	testing.expect(t, !os.exists(bridgesvc.pjoin(l.state_dir, bridgesvc.PORTS_FILE)))
	data, _ := os.read_entire_file_from_path(cfg, context.temp_allocator)
	testing.expect_value(t, string(data), "# kept as is\n")
}

// S7 with bin/ kept: a leftover staging dir is discarded and reported.
@(test)
test_setup_s7_leftover_staging_discarded_when_binaries_kept :: proc(t: ^testing.T) {
	home := setup_test_home("setup-s7-staging")
	defer os.remove_all(home)
	s := setup_test_make(home, []string{"setup", "--hub", "https://hub.example.com", "--headless"})
	testing.expect(t, os.make_directory_all(s.staging) == nil)
	_ = os.write_entire_file_from_string(bridgesvc.pjoin(s.staging, "ham-bridge"), "half")
	s.plan = {rows = {.S7_Partial}}
	s.snapshot_taken = true
	r := bridge_setup_run(&s, .Stage)
	testing.expect(t, r.ok && r.message == "skipped")
	testing.expect(t, !os.exists(s.staging))
	testing.expect_value(t, len(s.recovered), 1)
}

// S7a: a lock held by a live process is busy (exit 6), never broken.
@(test)
test_setup_s7a_live_lock_is_busy :: proc(t: ^testing.T) {
	home := setup_test_home("setup-s7a-busy")
	defer os.remove_all(home)
	s := setup_test_make(home, []string{"setup", "--hub", "https://hub.example.com"})
	other := s.pid
	s.pid = other + 1 // this setup; the lock belongs to `other` (alive: this test process)
	testing.expect(t, bridgesvc.lock_acquire(s.lock_path, other, time.now(), bridge_os_pid_alive).ok)
	r := bridge_setup_run(&s, .Lock)
	testing.expect(t, !r.ok && r.failure == .Fatal)
	testing.expect_value(t, s.exit_code, bridgesvc.EXIT_BUSY)
	testing.expect(t, strings.contains(s.refusal, "Another setup or update"))
	owner, _, _ := bridgesvc.lock_read(s.lock_path)
	testing.expect_value(t, owner, other)
	testing.expect_value(t, bridge_setup_exit_code(&s, false), bridgesvc.EXIT_BUSY)
}

// S5b: a profile saved for another hub is refused (exit 5) before detection.
@(test)
test_setup_s5b_collision_refused_at_lock :: proc(t: ^testing.T) {
	home := setup_test_home("setup-s5b")
	defer os.remove_all(home)
	s := setup_test_make(home, []string{"setup", "--hub", "https://hub.example.com"})
	_ = os.write_entire_file_from_string(bridgesvc.pjoin(s.layout.state_dir, bridgesvc.HUB_URL_FILE), "https://other.example.com\n")
	r := bridge_setup_run(&s, .Lock)
	testing.expect(t, !r.ok)
	testing.expect_value(t, s.exit_code, bridgesvc.EXIT_REFUSED)
	testing.expect(t, strings.contains(s.refusal, "belongs to hub https://other.example.com"))
	testing.expect(t, s.plan == {} && s.facts == {}, "nothing is classified for another hub's profile")
	bridgesvc.lock_release(s.lock_path, s.pid)
}

// S1 detection under the lock: a fresh profile classifies as S1 and is not refused.
@(test)
test_setup_lock_classifies_a_fresh_instance :: proc(t: ^testing.T) {
	home := setup_test_home("setup-s1-detect")
	defer os.remove_all(home)
	s := setup_test_make(home, []string{"setup", "--hub", "https://hub.example.com", "--json-progress"})
	r := bridge_setup_run(&s, .Lock)
	defer bridgesvc.lock_release(s.lock_path, s.pid)
	testing.expect(t, r.ok)
	testing.expect(t, .S1_Fresh in s.plan.rows && s.plan.enroll && !s.plan.noop)
	testing.expect_value(t, s.facts.bundle_version, contracts.APP_VERSION)
}

// S8c through the real Lock step: refused with exit 5, the instance untouched.
@(test)
test_setup_s8c_downgrade_refused_at_lock :: proc(t: ^testing.T) {
	home := setup_test_home("setup-s8c")
	defer os.remove_all(home)
	s := setup_test_make(home, []string{"setup", "--hub", "https://hub.example.com", "--version", contracts.APP_VERSION})
	_ = os.make_directory_all(s.layout.bin_dir)
	// An installed binary that reports a much newer version.
	script := "#!/bin/sh\necho ham-bridge 99.0.0\n"
	exe := bridgesvc.pjoin(s.layout.bin_dir, "ham-bridge")
	testing.expect(t, os.write_entire_file_from_string(exe, script, {.Read_User, .Write_User, .Execute_User}) == nil)
	s.bundle_dir = bridgesvc.pjoin(home, "bundle")
	// Where the binary cannot run (Windows: no shebang; a busy process slot under the
	// parallel test runner) the version comes from runtime-status.json instead.
	_ = os.write_entire_file_from_string(bridgesvc.pjoin(s.layout.state_dir, bridgesvc.RUNTIME_STATUS_FILE), `{"version":"99.0.0"}`)
	r := bridge_setup_run(&s, .Lock)
	defer bridgesvc.lock_release(s.lock_path, s.pid)
	testing.expect(t, !r.ok)
	testing.expect_value(t, s.exit_code, bridgesvc.EXIT_REFUSED)
	testing.expect(t, strings.contains(s.refusal, "--allow-downgrade"))
}

// Enrollment never prompts without a terminal and keeps the identity it is given.
@(test)
test_setup_enroll_argv_headless_and_reuse :: proc(t: ^testing.T) {
	home := setup_test_home("setup-enroll-argv")
	defer os.remove_all(home)
	s := setup_test_make(home, []string{"setup", "--hub", "https://hub.example.com", "--json-progress"})
	s.plan = {enroll = true, reuse_bridge = "brg_a", rows = {.S4_Enrollment_Invalid}}
	argv := bridge_setup_enroll_argv(&s, "tok")
	joined := strings.join(argv, " ", context.temp_allocator)
	testing.expect(t, strings.contains(joined, " enroll --hub https://hub.example.com "))
	testing.expect(t, strings.contains(joined, "--headless"), "no terminal (json-progress): --headless")
	testing.expect(t, strings.contains(joined, "--reuse-bridge brg_a"))
	testing.expect(t, !strings.contains(joined, "--new-bridge"))
	s.args = []string{"setup", "--hub", "https://hub.example.com", "--headless", "--new-bridge"}
	s.plan = {enroll = true}
	joined = strings.join(bridge_setup_enroll_argv(&s, "tok"), " ", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "--headless") && strings.contains(joined, "--new-bridge") && !strings.contains(joined, "--reuse-bridge"))
}

// A registered service whose rendered definition is unchanged is not rewritten.
// Fixed render input: the live one reads PATH, which other tests may change.
@(test)
test_setup_service_unchanged_detection :: proc(t: ^testing.T) {
	home := setup_test_home("setup-service-unchanged")
	defer os.remove_all(home)
	for backend_os in ([]bridgesvc.Target_OS{.Linux, .Windows}) {
		host := bridgesvc.Host{os = backend_os, home = home, appdata = home, local_appdata = home, uid = 1000}
		l := bridgesvc.layout_for(host, "heimdall-bridge-hub-example-com")
		in_ := bridgesvc.Render_Input{hub = "https://hub.example.com", path_env = "/usr/bin:/bin", windows_user = "D\\u", bridge_port = 49400, endpoint_port = 49401}
		testing.expectf(t, !bridge_setup_service_unchanged(host, l, in_), "%v: nothing written yet", backend_os)
		_ = os.make_directory_all(l.data_dir)
		if l.service_file != "" do _ = os.make_directory_all(bridgesvc.pdir(l.service_file))
		if backend_os == .Windows {
			_ = os.write_entire_file_from_string(bridgesvc.windows_run_cmd_path(l), bridgesvc.render_windows_run_cmd(host, l, in_))
			_ = os.write_entire_file_from_string(bridgesvc.windows_launcher_path(l), bridgesvc.render_windows_launcher(l))
			_ = os.write_entire_file_from_string(bridgesvc.pjoin(l.data_dir, "task.xml"), bridgesvc.render_service_file(host, l, in_))
		} else {
			_ = os.write_entire_file_from_string(l.service_file, bridgesvc.render_service_file(host, l, in_))
		}
		testing.expectf(t, bridge_setup_service_unchanged(host, l, in_), "%v: same render is unchanged", backend_os)
		moved := in_
		moved.bridge_port = 49500
		testing.expectf(t, !bridge_setup_service_unchanged(host, l, moved), "%v: other ports are a change", backend_os)
	}
}

@(test)
test_setup_exit_codes :: proc(t: ^testing.T) {
	s: Bridge_Setup
	testing.expect_value(t, bridge_setup_exit_code(&s, true), 0)
	s.not_enrolled = "denied"
	testing.expect_value(t, bridge_setup_exit_code(&s, true), 4)
	s = {}
	testing.expect_value(t, bridge_setup_exit_code(&s, false), 1)
	s.exit_code = bridgesvc.EXIT_REFUSED
	testing.expect_value(t, bridge_setup_exit_code(&s, false), 5)
	s.rollback_failed = true
	testing.expect_value(t, bridge_setup_exit_code(&s, false), 7)
}

@(test)
test_setup_final_lines_per_row :: proc(t: ^testing.T) {
	f := bridgesvc.Install_Facts{bridge_id = "brg_old", installed_version = "0.5.74", bundle_version = "0.5.75"}
	o := Bridge_Setup_Final{service = "svc", hub = "https://h", bridge_id = "brg_new"}
	line :: proc(rows: bridgesvc.Install_Rows, f: bridgesvc.Install_Facts, o: Bridge_Setup_Final, noop := false, replace := false) -> string {
		return bridge_setup_final_line({rows = rows, noop = noop, replace_binaries = replace, reenroll_reason = "revoked"}, f, o)
	}
	testing.expect_value(t, line({.S1_Fresh}, f, o, replace = true), "Installed svc v0.5.75, enrolled as brg_new, connected to https://h.")
	testing.expect_value(t, line({.S2_Healthy}, f, o, noop = true), "svc v0.5.74 is already installed, enrolled as brg_new and connected; nothing changed.")
	nc := o
	nc.not_connected = true
	testing.expect(t, strings.contains(line({.S2_Healthy}, f, nc, noop = true), "running but not connected to https://h (hub unreachable?); nothing changed."))
	testing.expect_value(t, line({.S3_Not_Enrolled}, f, o), "Enrolled svc as brg_new; connected to https://h.")
	testing.expect_value(t, line({.S4_Enrollment_Invalid, .S6_Service}, f, o), "Re-enrolled svc (was brg_old, reason revoked) as brg_new; connected.")
	sv := o
	sv.service_action = "registered"
	testing.expect_value(t, line({.S6_Service}, f, sv), "Repaired svc (service registered); connected to https://h.")
	testing.expect_value(t, line({.S6_Service}, f, o), "Repaired svc (service started); connected to https://h.")
	rec := o
	rec.recovered = []string{"discarded the partial install"}
	testing.expect_value(t, line({.S7_Partial, .S6_Service}, f, rec, replace = true), "Recovered an interrupted install of svc: discarded the partial install; Repaired svc (service started); connected to https://h.")
	testing.expect_value(t, line({.S8a_Version_Kept, .S2_Healthy}, f, o, noop = true), "svc v0.5.74 is already installed, enrolled as brg_new and connected; nothing changed. (installed v0.5.74; this installer carried v0.5.75; updates are not done by the installer)")
	testing.expect_value(t, line({.S8b_Version_Change}, f, o, replace = true), "Updated svc v0.5.74 → v0.5.75; connected.")
	ne := o
	ne.not_enrolled = "denied"
	testing.expect_value(t, line({.S1_Fresh}, f, ne, replace = true), "Installed svc v0.5.75 but not enrolled: denied. Run the same command again to enroll.")
}
