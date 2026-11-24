package service

// `ham-supervisor run`: the process the launcher starts (spec §7.1).
//
//   ham-supervisor run --instance-root <data> --state-root <state>
//                      --launched-tree <T> --launch-mode normal|fallback --ready-fd <fd>
//
// READY <T> <engine_version> <journal_schema> is written once the instance lock is held, J0
// has run and the §7.6 decision is taken (engine.start), as the only line on the pipe.
// The main loop resets temporary memory every iteration (§7.1 long-lived loops).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "../engine"
import "../fetch"

VERSION :: #config(HAM_APP_VERSION, "0.0.0-dev")
LOOP_INTERVAL :: time.Second

Run_Args :: struct {
	instance_root: string,
	state_root:    string,
	launched:      string,
	mode:          engine.Mode,
	ready_fd:      string,
	net:           Net, // the binary's libcurl transport (src/supervisor/net.odin)
	key_pins:      []fetch.Public_Key, // nil = the embedded release keys
}

stderr_log :: proc(msg: string) {
	t := time.now()
	fmt.eprintfln("%d ham-supervisor: %s", time.time_to_unix(t), msg)
}

// run_supervisor is `ham-supervisor run`; returns the exit code.
run_supervisor :: proc(a: Run_Args) -> int {
	if a.ready_fd != "" do mark_ready_fd_cloexec(a.ready_fd)
	// Tune for tests only (HEIMDALL_SUPERVISOR_TEST builds): shorter probation, gate wait
	// and first timer check, so the e2e suite runs in minutes. Release builds ignore it.
	cfg: engine.Config
	first_check: i64 = -1
	when TEST_BUILD {
		cfg.probation_s = env_int("HEIMDALL_SUPERVISOR_TEST_PROBATION_S", 0)
		cfg.ready_timeout_s = env_int("HEIMDALL_SUPERVISOR_TEST_READY_S", 0)
		cfg.gate_wait_s = env_int("HEIMDALL_SUPERVISOR_TEST_GATE_WAIT_S", 0)
		first_check = env_int("HEIMDALL_SUPERVISOR_TEST_FIRST_CHECK_S", -1)
	}

	// T15 failure injection, test builds only: bin/supervisor-behaviour.txt next to the exe
	// makes this supervisor a failing candidate (spec §18, §7.2):
	//   "noready"  never writes READY (the launcher's T_ready fallback)
	//   "exit78"   exits 78 two seconds after READY, during probation
	test_behaviour := ""
	when TEST_BUILD {
		test_behaviour = test_supervisor_behaviour()
		if test_behaviour == "noready" {
			stderr_log("test behaviour noready: never READY")
			for !stop_requested_flag() do time.sleep(LOOP_INTERVAL)
			return EXIT_STOP
		}
	}

	h: Host_Ctx
	h.log = stderr_log
	h.stop_flag = stop_requested_flag
	host_init(&h, a.instance_root, a.state_root, "")
	defer host_destroy(&h)

	opts := Options {
		instance_root = a.instance_root,
		state_root    = a.state_root,
		launched      = a.launched,
		mode          = a.mode,
		host          = engine_host(&h),
		net           = a.net,
		key_pins      = a.key_pins,
		engine_cfg    = cfg,
		rand          = rand_unit,
		first_check_s = first_check,
		log           = stderr_log,
	}
	s: Service
	defer close(&s)
	if code, reason := open(&s, opts); code >= 0 {
		stderr_log(fmt.tprintf("refusing to run: %s", reason))
		if a.ready_fd != "" do close_ready_fd(a.ready_fd)
		return code
	}
	delete(h.instance_id)
	h.instance_id = strings.clone(s.instance.instance_id)
	stop_init(s.instance.instance_id)

	x, err := start(&s)
	if code := exit_of(x, err); code >= 0 || err != nil {
		if err != nil do stderr_log(fmt.tprintf("start: %s", engine.error_detail(err)))
		if a.ready_fd != "" do close_ready_fd(a.ready_fd)
		return code if code >= 0 else EXIT_FATAL
	}
	if a.ready_fd != "" {
		line := fmt.tprintf("READY %s %d %d\n", a.launched, engine.ENGINE_VERSION, engine.JOURNAL_SCHEMA)
		if !write_ready(a.ready_fd, line) do stderr_log("cannot write READY")
	}
	stderr_log(fmt.tprintf("running %s (%v)", a.launched, a.mode))
	if test_behaviour == "exit78" {
		time.sleep(2 * time.Second)
		stderr_log("test behaviour exit78: exiting 78 during probation")
		return EXIT_REFUSE
	}

	for {
		free_all(context.temp_allocator)
		if stop_requested_flag() do break
		x, err = step(&s)
		if err != nil && engine.fatal(err) {
			stderr_log(fmt.tprintf("fatal: %s %s", engine.error_code(err), engine.error_detail(err)))
			return EXIT_FATAL
		}
		if x != .Run do return exit_of(x, nil)
		if stop_requested_flag() do break
		time.sleep(LOOP_INTERVAL)
	}
	stderr_log("stop requested")
	x, err = shutdown(&s)
	if err != nil && engine.fatal(err) {
		stderr_log(fmt.tprintf("stop: %s", engine.error_detail(err)))
		return EXIT_FATAL
	}
	return EXIT_STOP
}

// test_supervisor_behaviour: bin/supervisor-behaviour.txt next to the executable (test
// builds only; "" when absent).
test_supervisor_behaviour :: proc() -> string {
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil do return ""
	data, rerr := os.read_entire_file(engine.join(os.dir(exe), "supervisor-behaviour.txt"), context.temp_allocator)
	if rerr != nil do return ""
	return strings.trim_space(string(data))
}

env_int :: proc(name: string, def: i64) -> i64 {
	v := os.get_env(name, context.temp_allocator)
	if v == "" do return def
	n := i64(0)
	for c in transmute([]byte)v {
		if c < '0' || c > '9' do return def
		n = n * 10 + i64(c - '0')
	}
	return n
}

@(private)
rand_unit :: proc() -> f64 {
	t := time.now()
	x := u64(time.time_to_unix_nano(t)) ~ u64(os.get_pid()) * 0x9E3779B97F4A7C15
	x ~= x >> 33
	x *= 0xff51afd7ed558ccd
	x ~= x >> 33
	return f64(x >> 11) / f64(u64(1) << 53)
}
