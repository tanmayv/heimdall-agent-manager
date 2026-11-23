package launcher_core

// Launcher tests. Unit tests cover record parsing and the §7.2 start decision.
// Integration tests run the real launcher loop in a child process against a test
// instance root: the test binary re-executes itself in two roles, selected in
// @(init) before the test runner starts:
//   - launcher role (env HAM_LAUNCHER_TEST_ROLE=launcher): run() with short timeouts;
//   - fake supervisor (the binary copied to releases/<T>/ham-supervisor[.exe]):
//     follows the script in releases/<T>/fake.txt and logs to <data>/fake.log.

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

TEST_ROLE_ENV :: "HAM_LAUNCHER_TEST_ROLE"

TEST_TIMEOUTS :: Timeouts {
	ready         = 8 * time.Second, // generous: first exec of a copied binary is scanned on Windows/macOS
	commit        = 14 * time.Second,
	known_good    = 200 * time.Millisecond,
	stop_grace    = 3 * time.Second,
	refuse_wait   = 300 * time.Millisecond,
	backoff_min   = 100 * time.Millisecond,
	backoff_max   = 800 * time.Millisecond,
	healthy_reset = 60 * time.Second,
	session_end   = 2 * time.Second,
	tick          = 20 * time.Millisecond,
}

@(init)
launcher_test_dispatch :: proc "contextless" () {
	context = runtime.default_context()
	exe := os.args[0] if len(os.args) > 0 else ""
	base := strings.to_lower(filepath_base(exe), context.temp_allocator)
	if base == "ham-supervisor" || base == "ham-supervisor.exe" {
		os.exit(fake_supervisor_main(os.args[1:]))
	}
	if role, found := os.lookup_env(TEST_ROLE_ENV, context.temp_allocator); found && role == "launcher" {
		cfg := Config{timeouts = TEST_TIMEOUTS}
		for i := 1; i + 1 < len(os.args); i += 2 {
			switch os.args[i] {
			case "--instance-root":
				cfg.instance_root = os.args[i + 1]
			case "--state-root":
				cfg.state_root = os.args[i + 1]
			}
		}
		os.exit(run(cfg))
	}
}

cat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts, context.temp_allocator)
}

filepath_base :: proc(p: string) -> string {
	i := strings.last_index_any(p, "/\\")
	return p[i + 1:] if i >= 0 else p
}

// ---------------------------------------------------------------- unit tests

@(test)
test_parse_tree_name :: proc(t: ^testing.T) {
	tn, ok := parse_tree_name("0.5.75-9f8e7d6c5b4a")
	testing.expect(t, ok && tn.version == "0.5.75" && tn.d12 == "9f8e7d6c5b4a" && tn.repair == 0)
	tn, ok = parse_tree_name("0.6.0-rc.1-9f8e7d6c5b4a-r2")
	testing.expect(t, ok && tn.version == "0.6.0-rc.1" && tn.d12 == "9f8e7d6c5b4a" && tn.repair == 2)
	for bad in ([]string{"", "0.5.75", "0.5.75-9F8E7D6C5B4A", "0.5.75-9f8e7d6c5b4", "0.5.75-9f8e7d6c5b4a-r0", "0.5.75-9f8e7d6c5b4a-r01", "x-9f8e7d6c5b4a", "../0.5.75-9f8e7d6c5b4a", "0.5.75-9f8e7d6c5b4a/x", "-9f8e7d6c5b4a"}) {
		_, bad_ok := parse_tree_name(bad)
		testing.expectf(t, !bad_ok, "accepted bad tree name %q", bad)
	}
}

@(test)
test_pointer_record_roundtrip :: proc(t: ^testing.T) {
	rec := Pointer_Record{tree = "0.5.75-9f8e7d6c5b4a", op_id = "op_01JAAAAAAAAAAAAAAAAAAAAAAA", seq = 7}
	encoded := pointer_record_encode(rec, context.temp_allocator)
	tree, ok := pointer_record_decode(transmute([]byte)encoded)
	testing.expect(t, ok && tree == rec.tree, encoded)
	// Member order and whitespace do not matter to readers; the crc covers values.
	reordered := strings.concatenate({`{ "seq": 7, "crc32": "`, encoded[len(encoded) - 11:len(encoded) - 3], `", "op_id": "op_01JAAAAAAAAAAAAAAAAAAAAAAA", "tree": "0.5.75-9f8e7d6c5b4a" }`}, context.temp_allocator)
	_, ok = pointer_record_decode(transmute([]byte)reordered)
	testing.expect(t, ok, reordered)
	tampered, _ := strings.replace(encoded, `"seq":7`, `"seq":8`, 1, context.temp_allocator)
	_, ok = pointer_record_decode(transmute([]byte)tampered)
	testing.expect(t, !ok, "crc mismatch accepted")
	for bad in ([]string{"", "{", "[]", `{"tree":"a","op_id":"b","seq":1}`, encoded[:len(encoded) / 2]}) {
		_, bad_ok := pointer_record_decode(transmute([]byte)bad)
		testing.expectf(t, !bad_ok, "accepted bad record %q", bad)
	}
}

@(test)
test_symlink_target_tree :: proc(t: ^testing.T) {
	tree, ok := symlink_target_tree("releases/0.5.75-9f8e7d6c5b4a")
	testing.expect(t, ok && tree == "0.5.75-9f8e7d6c5b4a")
	for bad in ([]string{"/abs/releases/x", "releases/", "releases/..", "releases/a/b", "../releases/x", "x"}) {
		_, bad_ok := symlink_target_tree(bad)
		testing.expectf(t, !bad_ok, "accepted bad symlink target %q", bad)
	}
}

@(test)
test_decide :: proc(t: ^testing.T) {
	A, B := "0.5.74-aaaaaaaaaaaa", "0.5.75-bbbbbbbbbbbb"
	d := decide(false, {current = A, previous = A, known_good = A})
	testing.expect(t, d.tree == A && d.mode == .Normal && !d.unproven)
	d = decide(false, {current = B, previous = A, known_good = A})
	testing.expect(t, d.tree == B && d.mode == .Normal && d.unproven)
	d = decide(true, {current = B, previous = A, known_good = A})
	testing.expect(t, d.tree == A && d.mode == .Fallback, "fallback flag must start P")
	d = decide(false, {current = "", previous = A, known_good = A})
	testing.expect(t, d.tree == A && d.mode == .Fallback, "C none starts P in fallback")
	d = decide(false, {current = "", previous = "", known_good = A})
	testing.expect(t, d.tree == A && d.mode == .Normal, "C, P none starts K normal")
	d = decide(false, {})
	testing.expect(t, d.refuse == "no_valid_tree")
	d = decide(false, {current = B, previous = "", known_good = ""})
	testing.expect(t, d.tree == B && d.unproven, "fresh install without known-good is unproven")
}

@(test)
test_check_ready_line :: proc(t: ^testing.T) {
	testing.expect(t, check_ready_line("READY 0.5.75-bbbbbbbbbbbb 1 1", "0.5.75-bbbbbbbbbbbb"))
	testing.expect(t, check_ready_line("READY 0.5.75-bbbbbbbbbbbb 1 1 extra", "0.5.75-bbbbbbbbbbbb"), "extra trailing fields are allowed (spec §8)")
	testing.expect(t, !check_ready_line("READY 0.5.74-aaaaaaaaaaaa 1 1", "0.5.75-bbbbbbbbbbbb"))
	testing.expect(t, !check_ready_line("READY 0.5.75-bbbbbbbbbbbb x 1", "0.5.75-bbbbbbbbbbbb"))
	testing.expect(t, !check_ready_line("READY 0.5.75-bbbbbbbbbbbb", "0.5.75-bbbbbbbbbbbb"))
}

@(test)
test_backoff :: proc(t: ^testing.T) {
	testing.expect_value(t, backoff(DEFAULT_TIMEOUTS, 1), time.Second)
	testing.expect_value(t, backoff(DEFAULT_TIMEOUTS, 2), 2 * time.Second)
	testing.expect_value(t, backoff(DEFAULT_TIMEOUTS, 30), 5 * time.Minute)
}

// ---------------------------------------------------------------- fixture

Fixture :: struct {
	base:  string,
	data:  string,
	state: string,
	id:    string,
	trees: int,
	ok:    ^bool,
}

test_base_dir :: proc() -> string {
	if dir, found := os.lookup_env("HAM_LAUNCHER_TEST_DIR", context.temp_allocator); found && dir != "" do return dir
	when ODIN_OS == .Windows {
		if dir, found := os.lookup_env("TEMP", context.temp_allocator); found do return join_alloc(dir, "heimdall-launcher-tests")
		return `C:\Windows\Temp\heimdall-launcher-tests`
	} else {
		// Never /tmp: managed hosts SIGKILL fresh binaries there (AGENTS.md §7).
		home, _ := os.lookup_env("HOME", context.temp_allocator)
		return join_alloc(home, ".cache", "heimdall-tests", "launcher")
	}
}

join_alloc :: proc(parts: ..string) -> string {
	out, _ := os.join_path(parts, context.temp_allocator)
	return out
}

@(private = "file")
fixture_counter: int

// mkdir_all tolerates a parallel test creating a shared parent at the same moment.
mkdir_all :: proc(path: string) -> bool {
	for _ in 0 ..< 5 {
		if os.make_directory_all(path) == nil || os.is_directory(path) do return true
		time.sleep(10 * time.Millisecond)
	}
	return os.is_directory(path)
}

fixture_new :: proc(t: ^testing.T, name: string) -> Fixture {
	f: Fixture
	n := intrinsics.atomic_add(&fixture_counter, 1) + 1
	f.base = join_alloc(test_base_dir(), fmt.tprintf("%s-%d-%d-%d", name, os.get_pid(), n, time.time_to_unix_nano(time.now())))
	f.data = join_alloc(f.base, "data")
	f.state = join_alloc(f.base, "state")
	testing.expect(t, mkdir_all(join_alloc(f.data, "releases")))
	testing.expect(t, mkdir_all(join_alloc(f.data, "supervisor")))
	testing.expect(t, mkdir_all(f.state))
	f.id = fmt.tprintf("ins_%032x", u128(time.time_to_unix_nano(time.now())) * 7919 + u128(n))
	write_instance(t, &f, owner_json())
	return f
}

write_instance :: proc(t: ^testing.T, f: ^Fixture, owner: string) {
	esc :: proc(s: string) -> string {
		out, _ := strings.replace_all(s, `\`, `\\`, context.temp_allocator)
		return out
	}
	body := fmt.tprintf(`{{"schema":1,"instance_id":"%s","service_name":"heimdall-bridge-test","owner":%s,"data_root":"%s","state_root":"%s","layout":1,"created_at":1795400000}}`, f.id, owner, esc(f.data), esc(f.state))
	testing.expect(t, os.write_entire_file(join_alloc(f.data, "instance.json"), body) == nil)
}

owner_json :: proc() -> string {
	when ODIN_OS == .Windows {
		sid, _ := current_user_sid()
		return fmt.tprintf(`{{"sid":"%s"}}`, sid)
	} else {
		return fmt.tprintf(`{{"uid":%d}}`, test_current_uid())
	}
}

// add_tree creates a valid release tree whose supervisor follows `script` (one
// behaviour per start; the last line repeats).
add_tree :: proc(t: ^testing.T, f: ^Fixture, version: string, script: ..string) -> string {
	f.trees += 1
	digest := fmt.tprintf("%012x%052d", 0xabc000000000 + u64(f.trees), 0)
	tree := fmt.tprintf("%s-%s", version, digest[:12])
	dir := join_alloc(f.data, "releases", tree)
	testing.expect(t, mkdir_all(dir))
	release := fmt.tprintf(`{{"kind":"heimdall-release-manifest","schema":1,"tag":"v%s","version":"%s","targets":{{"%s":{{"asset":"x","size":1,"sha256":"%s"}}}}}}`, version, version, TARGET, digest)
	testing.expect(t, os.write_entire_file(join_alloc(dir, "release.json"), release) == nil)
	testing.expect(t, os.copy_file(join_alloc(dir, SUPERVISOR_EXE), os.args[0]) == nil, "copy test binary")
	when ODIN_OS != .Windows do os.change_mode(join_alloc(dir, SUPERVISOR_EXE), os.perm_number(0o755))
	testing.expect(t, os.write_entire_file(join_alloc(dir, "fake.txt"), strings.join(script, "\n", context.temp_allocator)) == nil)
	testing.expect(t, os.write_entire_file(join_alloc(dir, ".complete"), "") == nil)
	return tree
}

set_known_good :: proc(t: ^testing.T, f: ^Fixture, tree: string) {
	body := fmt.tprintf(`{{"tree":"%s","committed_op":"op_test","at":1795400000}}`, tree)
	testing.expect(t, os.write_entire_file(join_alloc(f.data, "known-good.json"), body) == nil)
}

Launch :: struct {
	process: os.Process,
	log:     ^os.File,
}

launch :: proc(t: ^testing.T, f: ^Fixture) -> Launch {
	env, _ := os.environ(context.temp_allocator)
	full := make([dynamic]string, context.temp_allocator)
	for e in env do if !strings.has_prefix(e, TEST_ROLE_ENV + "=") && !strings.has_prefix(e, "ODIN_TEST") do append(&full, e)
	append(&full, TEST_ROLE_ENV + "=launcher")
	logf, lerr := os.create(join_alloc(f.base, "launcher.log"))
	testing.expect(t, lerr == nil)
	p, err := os.process_start({command = {os.args[0], "--instance-root", f.data, "--state-root", f.state}, env = full[:], stderr = logf, stdout = logf})
	testing.expectf(t, err == nil, "process_start: %v", err)
	return {process = p, log = logf}
}

// finish waits for the launcher; returns its exit code (-1 on timeout, after killing it).
finish :: proc(t: ^testing.T, f: ^Fixture, l: ^Launch, timeout: time.Duration) -> int {
	state, err := os.process_wait(l.process, timeout)
	code := -1
	if err == nil && state.exited {
		code = state.exit_code
	} else {
		testing.expectf(t, false, "launcher did not exit within %v (err %v); log in %s", timeout, err, f.base)
		_ = os.process_kill(l.process)
		_, _ = os.process_wait(l.process, 5 * time.Second)
	}
	os.close(l.log)
	// Every fake start checked its process group / inherited handles / job (spec §2).
	for line in fake_log(f) do testing.expectf(t, !strings.has_prefix(line, "check-fail"), "supervisor environment check failed: %s", line)
	return code
}

fake_log :: proc(f: ^Fixture) -> []string {
	data, err := os.read_entire_file(join_alloc(f.data, "fake.log"), context.temp_allocator)
	if err != nil do return nil
	lines := strings.split_lines(strings.trim_space(string(data)), context.temp_allocator)
	return lines
}

count_lines :: proc(lines: []string, prefix: string) -> int {
	n := 0
	for l in lines do if strings.has_prefix(l, prefix) do n += 1
	return n
}

wait_lines :: proc(f: ^Fixture, prefix: string, n: int, timeout: time.Duration) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < timeout {
		if count_lines(fake_log(f), prefix) >= n do return true
		time.sleep(50 * time.Millisecond)
	}
	return false
}

request_stop_file :: proc(t: ^testing.T, f: ^Fixture) {
	body := fmt.tprintf(`{{"instance_id":"%s","requested_at":%d}}`, f.id, time.time_to_unix(time.now()))
	tmp := join_alloc(f.data, "supervisor", "launcher-stop.request.tmp")
	testing.expect(t, os.write_entire_file(tmp, body) == nil)
	testing.expect(t, os.rename(tmp, join_alloc(f.data, "supervisor", STOP_REQUEST_FILE)) == nil)
}

dump_on_failure :: proc(t: ^testing.T, f: ^Fixture) {
	if testing.failed(t) {
		logtext, _ := os.read_entire_file(join_alloc(f.base, "launcher.log"), context.temp_allocator)
		status, _ := os.read_entire_file(join_alloc(f.data, "launcher-status.json"), context.temp_allocator)
		fmt.eprintfln("---- %s\nlauncher.log:\n%s\nfake.log:\n%s\nstatus: %s", f.base, string(logtext), strings.join(fake_log(f), "\n", context.temp_allocator), string(status))
	} else {
		os.remove_all(f.base)
	}
}

expect_status_state :: proc(t: ^testing.T, f: ^Fixture, want: string) {
	status, err := os.read_entire_file(join_alloc(f.data, "launcher-status.json"), context.temp_allocator)
	testing.expectf(t, err == nil && strings.contains(string(status), fmt.tprintf(`"state":"%s"`, want)), "status %q, want state %q", string(status), want)
}

@(test)
test_instance_record_check :: proc(t: ^testing.T) {
	f := fixture_new(t, "instance-check")
	defer dump_on_failure(t, &f)
	testing.expect(t, same_path(f.data, f.data))
	testing.expectf(t, same_path(cat(f.data, "/"), f.data), "trailing separator: %q vs %q", normalize_path(cat(f.data, "/")), normalize_path(f.data))
	rec, reason := read_instance_record(f.data, context.temp_allocator)
	testing.expectf(t, reason == "", "read_instance_record: %s", reason)
	testing.expectf(t, owner_matches(rec.owner), "owner %v does not match (uid %d)", rec.owner, test_current_uid())
	testing.expectf(t, same_path(rec.data_root, f.data), "data_root %q (%q) vs %q (%q)", rec.data_root, normalize_path(rec.data_root), f.data, normalize_path(f.data))
	testing.expectf(t, check_instance_record(rec, f.data, f.state) == "", "check: %s", check_instance_record(rec, f.data, f.state))
	other := rec
	other.data_root = cat(f.data, "-other")
	testing.expect(t, check_instance_record(other, f.data, f.state) == "ownership_mismatch data_root")
}

// ---------------------------------------------------------------- integration

@(test)
test_known_good_runs_and_stops_gracefully :: proc(t: ^testing.T) {
	f := fixture_new(t, "healthy")
	defer dump_on_failure(t, &f)
	A := add_tree(t, &f, "0.5.74", "ready")
	set_pointer(t, &f, POINTER_CURRENT, A)
	set_pointer(t, &f, POINTER_PREVIOUS, A)
	set_known_good(t, &f, A)
	l := launch(t, &f)
	testing.expect(t, wait_lines(&f, cat("ready ", A), 1, 20 * time.Second), "supervisor never READY")
	request_stop_file(t, &f)
	testing.expect_value(t, finish(t, &f, &l, 20 * time.Second), 0)
	lines := fake_log(&f)
	testing.expect_value(t, count_lines(lines, cat("start ", A, " normal")), 1)
	testing.expect_value(t, count_lines(lines, cat("graceful ", A)), 1)
	testing.expect_value(t, count_lines(lines, "check-fail"), 0)
	expect_status_state(t, &f, "stopped")
}

@(test)
test_stale_stop_request_is_ignored :: proc(t: ^testing.T) {
	f := fixture_new(t, "stale-stop")
	defer dump_on_failure(t, &f)
	A := add_tree(t, &f, "0.5.74", "ready")
	set_pointer(t, &f, POINTER_CURRENT, A)
	set_known_good(t, &f, A)
	body := fmt.tprintf(`{{"instance_id":"%s","requested_at":%d}}`, f.id, time.time_to_unix(time.now()) - 3600)
	testing.expect(t, os.write_entire_file(join_alloc(f.data, "supervisor", STOP_REQUEST_FILE), body) == nil)
	l := launch(t, &f)
	testing.expect(t, wait_lines(&f, cat("ready ", A), 1, 20 * time.Second), "a stale stop request stopped the launcher")
	testing.expect(t, !os.exists(join_alloc(f.data, "supervisor", STOP_REQUEST_FILE)), "stale request not discarded")
	request_stop_file(t, &f)
	testing.expect_value(t, finish(t, &f, &l, 20 * time.Second), 0)
}

@(test)
test_current_missing_falls_back_to_previous :: proc(t: ^testing.T) {
	f := fixture_new(t, "current-missing")
	defer dump_on_failure(t, &f)
	A := add_tree(t, &f, "0.5.74", "ready")
	set_pointer(t, &f, POINTER_PREVIOUS, A)
	set_known_good(t, &f, A)
	l := launch(t, &f)
	testing.expect(t, wait_lines(&f, cat("start ", A, " fallback"), 1, 20 * time.Second), "previous not started in fallback mode")
	request_stop_file(t, &f)
	testing.expect_value(t, finish(t, &f, &l, 20 * time.Second), 0)
}

Corruption :: enum {
	Names_Missing_Tree,
	Tree_Incomplete,
	Version_Mismatch,
	Digest_Mismatch,
	Pointer_Garbage, // POSIX: regular file instead of a symlink; Windows: bad JSON
	Pointer_Escape, // POSIX: absolute / ".." target; Windows: crc mismatch
}

@(test)
test_current_corrupt_falls_back_to_previous :: proc(t: ^testing.T) {
	for kind in Corruption {
		f := fixture_new(t, fmt.tprintf("corrupt-%v", kind))
		A := add_tree(t, &f, "0.5.74", "ready")
		B := add_tree(t, &f, "0.5.75", "ready")
		set_pointer(t, &f, POINTER_PREVIOUS, A)
		set_known_good(t, &f, A)
		bdir := join_alloc(f.data, "releases", B)
		switch kind {
		case .Names_Missing_Tree:
			set_pointer(t, &f, POINTER_CURRENT, "0.5.76-ddddddddddd0")
		case .Tree_Incomplete:
			set_pointer(t, &f, POINTER_CURRENT, B)
			os.remove(join_alloc(bdir, ".complete"))
		case .Version_Mismatch:
			set_pointer(t, &f, POINTER_CURRENT, B)
			data, _ := os.read_entire_file(join_alloc(bdir, "release.json"), context.temp_allocator)
			patched, _ := strings.replace_all(string(data), `"version":"0.5.75"`, `"version":"0.5.99"`, context.temp_allocator)
			testing.expect(t, os.write_entire_file(join_alloc(bdir, "release.json"), patched) == nil)
		case .Digest_Mismatch:
			set_pointer(t, &f, POINTER_CURRENT, B)
			data, _ := os.read_entire_file(join_alloc(bdir, "release.json"), context.temp_allocator)
			patched, _ := strings.replace_all(string(data), `"sha256":"abc`, `"sha256":"fff`, context.temp_allocator)
			testing.expect(t, os.write_entire_file(join_alloc(bdir, "release.json"), patched) == nil)
		case .Pointer_Garbage, .Pointer_Escape:
			corrupt_pointer(t, &f, POINTER_CURRENT, B, kind == .Pointer_Escape)
		}
		l := launch(t, &f)
		testing.expectf(t, wait_lines(&f, cat("start ", A, " fallback"), 1, 20 * time.Second), "%v: previous not started in fallback mode", kind)
		request_stop_file(t, &f)
		testing.expect_value(t, finish(t, &f, &l, 20 * time.Second), 0)
		testing.expectf(t, count_lines(fake_log(&f), cat("start ", B)) == 0, "%v: corrupt current was started", kind)
		dump_on_failure(t, &f)
	}
}

@(test)
test_current_crashes_on_start_falls_back_and_never_alternates :: proc(t: ^testing.T) {
	f := fixture_new(t, "crash-on-start")
	defer dump_on_failure(t, &f)
	A := add_tree(t, &f, "0.5.74", "crash", "crash", "ready") // fallback A crashes twice, then runs
	B := add_tree(t, &f, "0.5.75", "crash")
	set_pointer(t, &f, POINTER_CURRENT, B)
	set_pointer(t, &f, POINTER_PREVIOUS, A)
	set_known_good(t, &f, A)
	l := launch(t, &f)
	testing.expect(t, wait_lines(&f, cat("ready ", A), 1, 30 * time.Second), "fallback A never READY")
	request_stop_file(t, &f)
	testing.expect_value(t, finish(t, &f, &l, 20 * time.Second), 0)
	lines := fake_log(&f)
	testing.expect_value(t, count_lines(lines, cat("start ", B, " normal")), 1)
	testing.expect_value(t, count_lines(lines, cat("start ", A, " fallback")), 3)
	testing.expect_value(t, count_lines(lines, cat("start ", A, " normal")), 0)
	// Order: B first, then only A.
	testing.expect(t, len(lines) > 0 && strings.has_prefix(lines[0], cat("start ", B)))
}

@(test)
test_supervisor_executable_missing_falls_back :: proc(t: ^testing.T) {
	f := fixture_new(t, "exe-missing")
	defer dump_on_failure(t, &f)
	A := add_tree(t, &f, "0.5.74", "ready")
	B := add_tree(t, &f, "0.5.75", "ready")
	testing.expect(t, os.remove(join_alloc(f.data, "releases", B, SUPERVISOR_EXE)) == nil)
	set_pointer(t, &f, POINTER_CURRENT, B)
	set_pointer(t, &f, POINTER_PREVIOUS, A)
	set_known_good(t, &f, A)
	l := launch(t, &f)
	testing.expect(t, wait_lines(&f, cat("start ", A, " fallback"), 1, 20 * time.Second))
	request_stop_file(t, &f)
	testing.expect_value(t, finish(t, &f, &l, 20 * time.Second), 0)
}

@(test)
test_no_ready_within_t_ready_falls_back :: proc(t: ^testing.T) {
	f := fixture_new(t, "ready-timeout")
	defer dump_on_failure(t, &f)
	A := add_tree(t, &f, "0.5.74", "ready")
	B := add_tree(t, &f, "0.5.75", "hang")
	set_pointer(t, &f, POINTER_CURRENT, B)
	set_pointer(t, &f, POINTER_PREVIOUS, A)
	set_known_good(t, &f, A)
	l := launch(t, &f)
	testing.expect(t, wait_lines(&f, cat("start ", A, " fallback"), 1, 30 * time.Second))
	request_stop_file(t, &f)
	testing.expect_value(t, finish(t, &f, &l, 20 * time.Second), 0)
}

@(test)
test_wrong_ready_line_is_not_ready :: proc(t: ^testing.T) {
	f := fixture_new(t, "bad-ready")
	defer dump_on_failure(t, &f)
	A := add_tree(t, &f, "0.5.74", "ready")
	B := add_tree(t, &f, "0.5.75", "bad-ready")
	set_pointer(t, &f, POINTER_CURRENT, B)
	set_pointer(t, &f, POINTER_PREVIOUS, A)
	set_known_good(t, &f, A)
	l := launch(t, &f)
	testing.expect(t, wait_lines(&f, cat("start ", A, " fallback"), 1, 30 * time.Second))
	request_stop_file(t, &f)
	testing.expect_value(t, finish(t, &f, &l, 20 * time.Second), 0)
}

@(test)
test_unproven_past_t_commit_falls_back :: proc(t: ^testing.T) {
	f := fixture_new(t, "commit-deadline")
	defer dump_on_failure(t, &f)
	A := add_tree(t, &f, "0.5.74", "ready")
	B := add_tree(t, &f, "0.5.75", "ready") // READY but never commits (hang after READY)
	set_pointer(t, &f, POINTER_CURRENT, B)
	set_pointer(t, &f, POINTER_PREVIOUS, A)
	set_known_good(t, &f, A)
	l := launch(t, &f)
	testing.expect(t, wait_lines(&f, cat("ready ", B), 1, 20 * time.Second))
	testing.expect(t, wait_lines(&f, cat("start ", A, " fallback"), 1, 40 * time.Second), "no fallback after T_commit")
	request_stop_file(t, &f)
	testing.expect_value(t, finish(t, &f, &l, 20 * time.Second), 0)
}

@(test)
test_commit_makes_current_proven :: proc(t: ^testing.T) {
	f := fixture_new(t, "commit")
	defer dump_on_failure(t, &f)
	A := add_tree(t, &f, "0.5.74", "ready")
	B := add_tree(t, &f, "0.5.75", "commit")
	set_pointer(t, &f, POINTER_CURRENT, B)
	set_pointer(t, &f, POINTER_PREVIOUS, A)
	set_known_good(t, &f, A)
	l := launch(t, &f)
	testing.expect(t, wait_lines(&f, cat("committed ", B), 1, 20 * time.Second))
	// Past T_commit: a proven tree is never failed by the deadline.
	time.sleep(TEST_TIMEOUTS.commit + 2 * time.Second)
	request_stop_file(t, &f)
	testing.expect_value(t, finish(t, &f, &l, 20 * time.Second), 0)
	lines := fake_log(&f)
	testing.expect_value(t, count_lines(lines, cat("start ", A)), 0)
	testing.expect_value(t, count_lines(lines, cat("start ", B)), 1)
	testing.expect_value(t, count_lines(lines, cat("graceful ", B)), 1)
}

@(test)
test_handover_exit_75_starts_new_current :: proc(t: ^testing.T) {
	f := fixture_new(t, "handover")
	defer dump_on_failure(t, &f)
	A := add_tree(t, &f, "0.5.74", "handover")
	B := add_tree(t, &f, "0.5.75", "commit")
	testing.expect(t, os.write_entire_file(join_alloc(f.data, "releases", A, "handover-to"), B) == nil)
	set_pointer(t, &f, POINTER_CURRENT, A)
	set_pointer(t, &f, POINTER_PREVIOUS, A)
	set_known_good(t, &f, A)
	l := launch(t, &f)
	testing.expect(t, wait_lines(&f, cat("committed ", B), 1, 20 * time.Second))
	request_stop_file(t, &f)
	testing.expect_value(t, finish(t, &f, &l, 20 * time.Second), 0)
	lines := fake_log(&f)
	testing.expect_value(t, count_lines(lines, cat("start ", A, " normal")), 1)
	testing.expect_value(t, count_lines(lines, cat("start ", B, " normal")), 1)
}

@(test)
test_exit_78_while_known_good_exits_78 :: proc(t: ^testing.T) {
	f := fixture_new(t, "refuse")
	defer dump_on_failure(t, &f)
	A := add_tree(t, &f, "0.5.74", "refuse")
	set_pointer(t, &f, POINTER_CURRENT, A)
	set_known_good(t, &f, A)
	l := launch(t, &f)
	testing.expect_value(t, finish(t, &f, &l, 20 * time.Second), EXIT_REFUSE)
	testing.expect_value(t, count_lines(fake_log(&f), cat("start ", A)), 1)
	expect_status_state(t, &f, "refused")
}

@(test)
test_exit_78_of_unproven_current_falls_back :: proc(t: ^testing.T) {
	f := fixture_new(t, "refuse-unproven")
	defer dump_on_failure(t, &f)
	A := add_tree(t, &f, "0.5.74", "ready")
	B := add_tree(t, &f, "0.5.75", "refuse")
	set_pointer(t, &f, POINTER_CURRENT, B)
	set_pointer(t, &f, POINTER_PREVIOUS, A)
	set_known_good(t, &f, A)
	l := launch(t, &f)
	testing.expect(t, wait_lines(&f, cat("start ", A, " fallback"), 1, 20 * time.Second))
	request_stop_file(t, &f)
	testing.expect_value(t, finish(t, &f, &l, 20 * time.Second), 0)
}

@(test)
test_no_valid_tree_exits_78 :: proc(t: ^testing.T) {
	f := fixture_new(t, "nothing")
	defer dump_on_failure(t, &f)
	l := launch(t, &f)
	testing.expect_value(t, finish(t, &f, &l, 20 * time.Second), EXIT_REFUSE)
	expect_status_state(t, &f, "refused")
}

@(test)
test_ownership_mismatch_refuses :: proc(t: ^testing.T) {
	f := fixture_new(t, "owner")
	defer dump_on_failure(t, &f)
	A := add_tree(t, &f, "0.5.74", "ready")
	set_pointer(t, &f, POINTER_CURRENT, A)
	set_known_good(t, &f, A)
	when ODIN_OS == .Windows {
		write_instance(t, &f, `{"sid":"S-1-5-21-1-2-3-4242"}`)
	} else {
		write_instance(t, &f, fmt.tprintf(`{{"uid":%d}}`, test_current_uid() + 1))
	}
	l := launch(t, &f)
	testing.expect_value(t, finish(t, &f, &l, 20 * time.Second), EXIT_REFUSE)
	testing.expect_value(t, count_lines(fake_log(&f), "start"), 0)
	expect_status_state(t, &f, "refused")
}

@(test)
test_known_good_crash_loop_restarts_with_backoff :: proc(t: ^testing.T) {
	f := fixture_new(t, "crash-loop")
	defer dump_on_failure(t, &f)
	A := add_tree(t, &f, "0.5.74", "ready-crash")
	set_pointer(t, &f, POINTER_CURRENT, A)
	set_pointer(t, &f, POINTER_PREVIOUS, A)
	set_known_good(t, &f, A)
	l := launch(t, &f)
	testing.expect(t, wait_lines(&f, cat("start ", A, " normal"), 4, 30 * time.Second), "known-good not restarted after crashes")
	request_stop_file(t, &f)
	testing.expect_value(t, finish(t, &f, &l, 20 * time.Second), 0)
	testing.expect_value(t, count_lines(fake_log(&f), cat("start ", A, " fallback")), 0)
}

@(test)
test_supervisor_ignoring_stop_is_killed :: proc(t: ^testing.T) {
	f := fixture_new(t, "stop-ignored")
	defer dump_on_failure(t, &f)
	A := add_tree(t, &f, "0.5.74", "ready-ignore-stop")
	set_pointer(t, &f, POINTER_CURRENT, A)
	set_known_good(t, &f, A)
	l := launch(t, &f)
	testing.expect(t, wait_lines(&f, cat("ready ", A), 1, 20 * time.Second))
	request_stop_file(t, &f)
	testing.expect_value(t, finish(t, &f, &l, 20 * time.Second), 0)
	testing.expect_value(t, count_lines(fake_log(&f), "graceful"), 0)
}

@(test)
test_os_stop_is_forwarded :: proc(t: ^testing.T) {
	// POSIX: SIGTERM to the launcher. Windows: the named launcher stop event.
	f := fixture_new(t, "os-stop")
	defer dump_on_failure(t, &f)
	A := add_tree(t, &f, "0.5.74", "ready")
	set_pointer(t, &f, POINTER_CURRENT, A)
	set_known_good(t, &f, A)
	l := launch(t, &f)
	testing.expect(t, wait_lines(&f, cat("ready ", A), 1, 20 * time.Second))
	send_os_stop(t, &f, l.process)
	testing.expect_value(t, finish(t, &f, &l, 20 * time.Second), 0)
	testing.expect_value(t, count_lines(fake_log(&f), cat("graceful ", A)), 1)
}

// ---------------------------------------------------------------- fake supervisor

fake_supervisor_main :: proc(args: []string) -> int {
	root, state, tree, mode, ready_fd: string
	for i := 1; i + 1 < len(args); i += 2 {
		switch args[i] {
		case "--instance-root": root = args[i + 1]
		case "--state-root": state = args[i + 1]
		case "--launched-tree": tree = args[i + 1]
		case "--launch-mode": mode = args[i + 1]
		case "--ready-fd": ready_fd = args[i + 1]
		}
	}
	if len(args) == 0 || args[0] != "run" || root == "" || state == "" || tree == "" || ready_fd == "" do return 64
	logpath := join_alloc(root, "fake.log")
	note :: proc(path, line: string) {
		f, err := os.open(path, {.Write, .Create, .Append}, os.perm_number(0o644))
		if err != nil do return
		os.write_string(f, line)
		os.write_string(f, "\n")
		os.close(f)
	}
	prior := 0
	if data, err := os.read_entire_file(logpath, context.temp_allocator); err == nil {
		for line in strings.split_lines(string(data), context.temp_allocator) do if strings.has_prefix(line, fmt.tprintf("start %s ", tree)) do prior += 1
	}
	checks := fake_platform_checks()
	note(logpath, fmt.tprintf("start %s %s", tree, mode))
	if checks != "" do note(logpath, fmt.tprintf("check-fail %s %s", tree, checks))
	script_data, _ := os.read_entire_file(join_alloc(root, "releases", tree, "fake.txt"), context.temp_allocator)
	script := strings.split_lines(strings.trim_space(string(script_data)), context.temp_allocator)
	behaviour := script[min(prior, len(script) - 1)] if len(script) > 0 else "ready"
	id := ""
	if rec, reason := read_instance_record(root); reason == "" do id = rec.instance_id
	fake_install_stop(id)

	ready :: proc(fd, tree, logpath: string) {
		fake_write_ready(fd, fmt.tprintf("READY %s 1 1\n", tree))
		note(logpath, fmt.tprintf("ready %s", tree))
	}
	wait_stop :: proc(logpath, tree: string, honour: bool) -> int {
		start := time.tick_now()
		for time.tick_since(start) < 90 * time.Second {
			if fake_parent_gone() do return 1
			if honour && fake_stop_requested() {
				note(logpath, fmt.tprintf("graceful %s", tree))
				return 0
			}
			time.sleep(20 * time.Millisecond)
		}
		return 1
	}
	switch behaviour {
	case "ready":
		ready(ready_fd, tree, logpath)
		return wait_stop(logpath, tree, true)
	case "commit":
		ready(ready_fd, tree, logpath)
		_ = os.write_entire_file(join_alloc(root, "known-good.json.tmp"), fmt.tprintf(`{{"tree":"%s","committed_op":"op_fake","at":1}}`, tree))
		replace_file(join_alloc(root, "known-good.json.tmp"), join_alloc(root, "known-good.json"))
		note(logpath, fmt.tprintf("committed %s", tree))
		return wait_stop(logpath, tree, true)
	case "crash":
		return 3
	case "ready-crash":
		ready(ready_fd, tree, logpath)
		time.sleep(200 * time.Millisecond)
		return 3
	case "hang":
		return wait_stop(logpath, tree, false)
	case "ready-ignore-stop":
		ready(ready_fd, tree, logpath)
		return wait_stop(logpath, tree, false)
	case "bad-ready":
		fake_write_ready(ready_fd, "READY 9.9.9-999999999999 1 1\n")
		return wait_stop(logpath, tree, true)
	case "refuse":
		return EXIT_REFUSE
	case "handover":
		to, _ := os.read_entire_file(join_alloc(root, "releases", tree, "handover-to"), context.temp_allocator)
		fake_set_pointer(root, POINTER_CURRENT, strings.trim_space(string(to)))
		return EXIT_HANDOVER
	}
	return 99
}
