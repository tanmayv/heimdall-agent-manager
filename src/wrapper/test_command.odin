package main

import "base:intrinsics"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import cfg_lib "odin_test:lib/config"
import tmux "odin_test:lib/tmux"

TEST_STARTER_PROMPT :: "You are a test agent. Your only task: use your shell tool to run `touch test_file` in the current working directory. After the command succeeds, you may stop. Do not perform any other action, do not read files, do not write other files."
TEST_STALE_SECONDS :: 24 * 60 * 60

g_test_abort: bool

@(private)
_test_sig_handler :: proc "c" (sig: posix.Signal) {
	intrinsics.atomic_store(&g_test_abort, true)
}

Test_State :: struct {
	run_id:           string,
	cwd:              string,
	session:          string,
	pane_id:          string,
	keep:             string,
	step_failed:      bool,
	start_ns:         i64,
	verbose:          bool,
	timeout_sec:      int,
	step_timeout:     int,
}

run_test_command :: proc(args: []string) -> int {
	config_path := cfg_lib.config_path_from_args(args)
	provider    := option_value(args, "--provider", "")
	tier        := option_value(args, "--tier", "normal")
	keep        := option_value(args, "--keep", "on-failure")
	timeout_sec := 120
	if s := option_value(args, "--timeout", ""); s != "" {
		if n, ok := strconv.parse_int(s); ok { timeout_sec = n }
	}
	step_timeout := 30
	if s := option_value(args, "--step-timeout", ""); s != "" {
		if n, ok := strconv.parse_int(s); ok { step_timeout = n }
	}
	strict_tier := !has_flag(args, "--no-strict-tier")
	verbose     := has_flag(args, "--verbose")
	dry_run     := has_flag(args, "--dry-run")
	manual_verify := has_flag(args, "--manual-verify")
	if manual_verify {
		// Manual verification implies preserving the session so the user can attach.
		keep = "always"
	}

	if provider == "" {
		fmt.fprintln(os.stderr, "ham-wrapper test: --provider is required")
		return 2
	}
	if tier != "cheap" && tier != "normal" && tier != "smart" {
		fmt.fprintf(os.stderr, "ham-wrapper test: invalid --tier; expected cheap|normal|smart, got: %s\n", tier)
		return 2
	}
	if keep != "on-failure" && keep != "always" && keep != "never" {
		fmt.fprintf(os.stderr, "ham-wrapper test: invalid --keep; expected on-failure|always|never, got: %s\n", keep)
		return 2
	}

	// Seed RNG to avoid run_id collisions on same-second invocations.
	rand.reset(u64(time.to_unix_nanoseconds(time.now())))

	posix.signal(.SIGINT, _test_sig_handler)
	posix.signal(.SIGTERM, _test_sig_handler)

	run_id      := generate_run_id()
	rand_suffix := run_id[len(run_id)-4:]
	cwd         := fmt.tprintf("/tmp/ham-wrapper-test-%s", run_id)
	session     := fmt.tprintf("ham-test-%s", rand_suffix)

	state := Test_State{
		run_id       = run_id,
		cwd          = cwd,
		session      = session,
		keep         = keep,
		verbose      = verbose,
		timeout_sec  = timeout_sec,
		step_timeout = step_timeout,
		start_ns     = time.to_unix_nanoseconds(time.now()),
	}

	sweep_stale_test_runs()

	fmt.printf("ham-wrapper test  run_id=%s\n", run_id)
	fmt.printf("              cwd=%s\n", cwd)
	fmt.printf("              tmux=%s:smoke\n", session)
	fmt.println()

	loaded, load_ok := cfg_lib.load(config_path)
	if !load_ok {
		print_step_line(1, 7, "config parse", false, fmt.tprintf("could not load config: %s", config_path))
		return 2
	}
	cfg := loaded.config.wrapper

	// Step 1
	s1ok, s1detail, s1fail, tier_skipped, agent_cmd, agent_cmd_ok := step1_config(cfg, provider, tier, strict_tier)
	print_step_line(1, 6, "config parse", s1ok, s1detail)
	if !s1ok {
		state.step_failed = true
		print_failure_summary(&state, 1, s1fail)
		do_cleanup(&state)
		return 1
	}

	// Step 2
	s2ok, s2detail, s2fail, s2exit := step2_tmux(&state)
	print_step_line(2, 6, "tmux available + functional", s2ok, s2detail)
	if !s2ok {
		state.step_failed = true
		print_failure_summary(&state, 2, s2fail)
		do_cleanup(&state)
		return s2exit
	}

	if dry_run {
		fmt.println("[dry-run] steps 1-2 complete; skipping process spawn")
		fmt.printf("\nPASS  total %.1fs  (dry-run)\n", elapsed_seconds(state.start_ns))
		return 0
	}

	// Step 3
	s3ok, s3detail, s3fail := step3_launch(&state, cfg, agent_cmd, agent_cmd_ok, tier, tier_skipped)
	print_step_line(3, 6, "launch agent process", s3ok, s3detail)
	if !s3ok {
		state.step_failed = true
		print_failure_summary(&state, 3, s3fail)
		do_cleanup(&state)
		return 1
	}
	if intrinsics.atomic_load(&g_test_abort) { return test_abort_cleanup(&state) }

	// Step 4
	s4ok, s4detail, s4fail := step4_restart_with_prompt(&state, cfg, agent_cmd, agent_cmd_ok, tier, tier_skipped)
	print_step_line(4, 6, "restart with combined starter+test prompt", s4ok, s4detail)
	if !s4ok {
		state.step_failed = true
		print_failure_summary(&state, 4, s4fail)
		do_cleanup(&state)
		return 1
	}
	if intrinsics.atomic_load(&g_test_abort) { return test_abort_cleanup(&state) }

	// Step 5
	s5ok, s5detail, s5fail, s5hard := step5_startup(&state, agent_cmd)
	print_step_line(5, 6, "startup detection", s5ok, s5detail)
	if s5hard {
		state.step_failed = true
		print_failure_summary(&state, 5, s5fail)
		do_cleanup(&state)
		return 1
	}
	if !s5ok {
		fmt.printf("  (soft fail: %s; continuing)\n", s5fail)
	}
	if intrinsics.atomic_load(&g_test_abort) { return test_abort_cleanup(&state) }

	if manual_verify {
		fmt.printf("[6/6] manual verification                          OK    session preserved; attach with: tmux attach -t %s\n", state.session)
		fmt.printf("\nPASS  total %.1fs (manual)\n", elapsed_seconds(state.start_ns))
		fmt.printf("  cwd=%s\n", state.cwd)
		fmt.printf("  When you're done, clean up with: tmux kill-session -t %s && rm -rf %s\n", state.session, state.cwd)
		return 0
	}

	// Step 6
	s6ok, s6detail, s6fail := step6_verify_file(&state)
	print_step_line(6, 6, "verify test_file created on disk", s6ok, s6detail)
	if !s6ok {
		state.step_failed = true
		print_failure_summary(&state, 6, s6fail)
		do_cleanup(&state)
		return 1
	}

	fmt.printf("\nPASS  total %.1fs\n", elapsed_seconds(state.start_ns))
	do_cleanup(&state)
	fmt.println("cleanup OK")
	return 0
}

step1_config :: proc(cfg: cfg_lib.Wrapper_Config, provider, tier: string, strict_tier: bool) -> (ok: bool, detail: string, failure: string, tier_skipped: bool, agent_cmd: cfg_lib.Agent_Command_Config, agent_cmd_ok: bool) {
	found := false
	for ac in cfg.agent_commands {
		if ac.name == provider {
			agent_cmd = ac
			agent_cmd_ok = true
			found = true
			break
		}
	}
	if !found {
		names := make([dynamic]string)
		defer delete(names)
		for ac in cfg.agent_commands { append(&names, ac.name) }
		available := "(none configured)"
		if len(names) > 0 { available = strings.join(names[:], ", ") }
		failure = fmt.tprintf("provider '%s' not found; available: %s", provider, available)
		return false, "", failure, false, {}, false
	}

	cmd := agent_cmd.command
	if len(cmd) == 0 { cmd = cfg.command }
	if len(cmd) == 0 || cmd[0] == "" {
		return false, "", "command is empty", false, agent_cmd, true
	}
	if agent_cmd.starter_prompt == "" {
		return false, "", "starter_prompt is empty", false, agent_cmd, true
	}

	// Templating dry-run: expand starter_prompt with placeholder values
	expanded := template_string(agent_cmd.starter_prompt, "http://test-daemon:49322", "test@default", "Test Agent", "conv-test", "tok-test", "task-test")
	if expanded == "" {
		return false, "", "starter_prompt expanded to empty string", false, agent_cmd, true
	}

	// Resolve tier
	tier_val    := ""
	tier_reason := ""
	if agent_cmd.models.flag == "" {
		tier_reason = "models.flag is empty"
		tier_skipped = true
	} else {
		tier_val = cfg_lib.resolve_model_value(agent_cmd.models, tier)
		if tier_val == "" {
			tier_reason = fmt.tprintf("models.%s is empty", tier)
			tier_skipped = true
		}
	}

	if tier_skipped && strict_tier {
		return false, "", fmt.tprintf("--strict-tier: %s", tier_reason), true, agent_cmd, true
	}

	model_str := tier_val
	if tier_skipped { model_str = fmt.tprintf("tier_skipped: %s", tier_reason) }

	detail = fmt.tprintf("%d agent-cmds; tier=%s → %s; prompt=%d chars", len(cfg.agent_commands), tier, model_str, len(expanded))
	return true, detail, "", tier_skipped, agent_cmd, true
}

step2_tmux :: proc(state: ^Test_State) -> (ok: bool, detail: string, failure: string, exit_code: int) {
	ver, ver_ok := tmux.version()
	if !ver_ok {
		return false, "", "tmux not found or returned non-zero", 3
	}

	probe_name := fmt.tprintf("ham-test-probe-%s", state.run_id[len(state.run_id)-4:])
	t0 := time.to_unix_nanoseconds(time.now())
	if !tmux.create_throwaway_session(probe_name) {
		return false, "", fmt.tprintf("could not create probe session %s", probe_name), 3
	}
	killed := tmux.kill_session(probe_name)
	elapsed_ms := (time.to_unix_nanoseconds(time.now()) - t0) / 1_000_000

	detail = fmt.tprintf("%s; session create/kill round-trip %dms", ver, elapsed_ms)
	if state.verbose && !killed {
		fmt.fprintf(os.stderr, "[verbose] probe session kill returned false\n")
	}
	return true, detail, "", 0
}

step3_launch :: proc(state: ^Test_State, cfg: cfg_lib.Wrapper_Config, agent_cmd: cfg_lib.Agent_Command_Config, agent_cmd_ok: bool, tier: string, tier_skipped: bool) -> (ok: bool, detail: string, failure: string) {
	if err := os.make_directory_all(state.cwd); err != nil {
		return false, "", fmt.tprintf("mkdir %s failed", state.cwd)
	}

	argv := build_test_argv(cfg, agent_cmd, agent_cmd_ok, tier, tier_skipped, "")
	fmt.printf("agent command (initial): %s\n", shell_join_argv(argv))
	launch, launch_ok := tmux.ensure_agent_window(state.session, "smoke", state.cwd, argv)
	if !launch_ok {
		return false, "", "tmux.ensure_agent_window failed"
	}
	state.pane_id = launch.pane_id

	// Stayed-up check is blackbox: we only check whether the pane still exists.
	// Pane text inspection is reserved for startup detection (step 5).
	time.sleep(2 * time.Second)
	if !tmux.pane_exists(state.pane_id) {
		return false, "", "pane exited within 2s (process died on launch)"
	}

	model_str := "no-model"
	if !tier_skipped && agent_cmd_ok {
		model_str = cfg_lib.resolve_model_value(agent_cmd.models, tier)
	}
	detail = fmt.tprintf("pane=%s model=%s stayed-up 2.0s", state.pane_id, model_str)
	return true, detail, ""
}

step4_restart_with_prompt :: proc(state: ^Test_State, cfg: cfg_lib.Wrapper_Config, agent_cmd: cfg_lib.Agent_Command_Config, agent_cmd_ok: bool, tier: string, tier_skipped: bool) -> (ok: bool, detail: string, failure: string) {
	_ = tmux.kill_pane(state.pane_id)
	state.pane_id = ""

	argv := build_test_argv(cfg, agent_cmd, agent_cmd_ok, tier, tier_skipped, TEST_STARTER_PROMPT)
	fmt.printf("agent command (with test prompt): %s\n", shell_join_argv(argv))
	launch, launch_ok := tmux.ensure_agent_window(state.session, "smoke", state.cwd, argv)
	if !launch_ok {
		return false, "", "tmux.ensure_agent_window failed on restart"
	}
	state.pane_id = launch.pane_id

	detail = fmt.tprintf("pane=%s prompt=%d chars (passed as positional arg via agent_cmd.prompt_flags + final positional)", state.pane_id, len(TEST_STARTER_PROMPT))
	return true, detail, ""
}

step5_startup :: proc(state: ^Test_State, agent_cmd: cfg_lib.Agent_Command_Config) -> (ok: bool, detail: string, failure: string, hard_fail: bool) {
	sd := agent_cmd.startup_detection

	if !sd.enabled {
		detail = "disabled by config"
		return true, detail, "", false
	}

	// Cap probe time to step_timeout
	if sd.startup_probe_seconds <= 0 { sd.startup_probe_seconds = 15 }
	if state.step_timeout > 0 && state.step_timeout < sd.startup_probe_seconds {
		sd.startup_probe_seconds = state.step_timeout
	}

	t0 := time.to_unix_nanoseconds(time.now())
	// Use production probe extended with abort_flag; pane_exited is already surfaced there.
	result := startup_probe_agent(sd, state.pane_id, &g_test_abort)
	elapsed := elapsed_seconds(t0)

	switch result.status {
	case "ready":
		detail = fmt.tprintf("matched '%s' after %.1fs", result.reason_code, elapsed)
		return true, detail, "", false
	case "disabled":
		return true, "disabled by config", "", false
	case "startup_failed":
		if result.reason_code == "pane_exited" {
			last := capture_last_lines(state.pane_id, 30)
			return false, "", fmt.tprintf("pane exited during startup:\n%s", last), true
		}
		return false, "", fmt.tprintf("%s: %s", result.reason_code, result.safe_diagnostic), true
	case:
		failure = fmt.tprintf("%s: %s", result.reason_code, result.safe_diagnostic)
		detail  = fmt.tprintf("soft-fail: %s after %.1fs", result.status, elapsed)
		return false, detail, failure, false
	}
}

// step6_verify_file: blackbox verification. Poll the filesystem for the file
// the agent was asked to create in its starter prompt. No tmux capture, no
// send-keys, no marker scraping — the file's existence on disk is the only
// success signal.
step6_verify_file :: proc(state: ^Test_State) -> (ok: bool, detail: string, failure: string) {
	test_file_path := fmt.tprintf("%s/test_file", state.cwd)
	t0 := time.to_unix_nanoseconds(time.now())
	deadline := t0 + 60*i64(time.Second)
	if state.timeout_sec > 0 {
		overall_remaining := state.start_ns + i64(state.timeout_sec)*i64(time.Second) - t0
		if overall_remaining > 0 && overall_remaining < 60*i64(time.Second) {
			deadline = t0 + overall_remaining
		}
	}

	for time.to_unix_nanoseconds(time.now()) < deadline {
		if intrinsics.atomic_load(&g_test_abort) { break }
		time.sleep(1 * time.Second)

		if !tmux.pane_exists(state.pane_id) {
			// Agent process died before producing the file. Check disk once more
			// (race: file might have been created in the last instant) then fail.
			if os.is_file(test_file_path) { break }
			return false, "", "agent pane exited before test_file was created"
		}

		if os.is_file(test_file_path) { break }
	}

	if !os.is_file(test_file_path) {
		return false, "", fmt.tprintf("timeout: test_file not found at %s", test_file_path)
	}

	elapsed := elapsed_seconds(t0)
	file_size := i64(0)
	if fi, stat_err := os.stat(test_file_path, context.allocator); stat_err == nil {
		file_size = fi.size
	}
	return true, fmt.tprintf("%s (%d bytes) after %.1fs", test_file_path, file_size, elapsed), ""
}

build_test_argv :: proc(cfg: cfg_lib.Wrapper_Config, agent_cmd: cfg_lib.Agent_Command_Config, agent_cmd_ok: bool, tier: string, tier_skipped: bool, starter_prompt: string) -> []string {
	result := make([dynamic]string)
	base := agent_cmd.command
	if len(base) == 0 { base = cfg.command }
	for arg in base { append(&result, arg) }
	for flag in agent_cmd.yolo_flags { append(&result, flag) }
	if !tier_skipped && agent_cmd_ok && agent_cmd.models.flag != "" {
		model_val := cfg_lib.resolve_model_value(agent_cmd.models, tier)
		if model_val != "" {
			append(&result, agent_cmd.models.flag)
			append(&result, model_val)
		}
	}
	if starter_prompt != "" {
		for flag in agent_cmd.prompt_flags { append(&result, flag) }
		append(&result, starter_prompt)
	}
	return result[:]
}

shell_join_argv :: proc(argv: []string) -> string {
	builder := strings.builder_make()
	for i := 0; i < len(argv); i += 1 {
		arg := argv[i]
		if i > 0 do strings.write_string(&builder, " ")
		if arg == "" {
			strings.write_string(&builder, "''")
			continue
		}

		has_space := false
		has_quote := false
		for ch in arg {
			switch ch {
			case ' ', '\t', '\n':
				has_space = true
			case '\'', '"', '\\':
				has_quote = true
			}
		}

		if has_space || has_quote {
			strings.write_string(&builder, "'")
			for ch in arg {
				switch ch {
				case '\'':
					strings.write_string(&builder, "'\\''")
				case '\\':
					strings.write_string(&builder, "\\\\")
				case '\n':
					strings.write_string(&builder, "\\n")
				case '\t':
					strings.write_string(&builder, "\\t")
				case '\r':
					strings.write_string(&builder, "\\r")
				case:
					strings.write_rune(&builder, ch)
				}
			}
			strings.write_string(&builder, "'")
		} else {
			strings.write_string(&builder, arg)
		}
	}
	return strings.to_string(builder)
}

generate_run_id :: proc() -> string {
	now := time.now()
	y, mo, d  := time.date(now)
	h, mi, s  := time.clock_from_time(now)
	ns        := time.to_unix_nanoseconds(now)
	cc        := (ns / 10_000_000) % 100
	rng       := rand.uint32()
	hex       := "0123456789abcdef"
	r0 := hex[(rng >>  0) & 0xf]
	r1 := hex[(rng >>  4) & 0xf]
	r2 := hex[(rng >>  8) & 0xf]
	r3 := hex[(rng >> 12) & 0xf]
	return fmt.tprintf("t-%04d%02d%02d%02d%02d%02d%02d-%c%c%c%c",
		y, int(mo), d, h, mi, s, cc, r0, r1, r2, r3)
}

print_step_line :: proc(step, total: int, label: string, ok: bool, detail: string) {
	status := "OK  "
	if !ok { status = "FAIL" }
	// Labels are always short (<44 chars); pad is guaranteed positive for current labels.
	pad := 44 - len(label)
	if pad < 1 { pad = 1 }
	spaces := "                                              "
	if pad > len(spaces) { pad = len(spaces) }
	fmt.printf("[%d/%d] %s%s %s  %s\n", step, total, label, spaces[:pad], status, detail)
}

print_failure_summary :: proc(state: ^Test_State, failed_step: int, reason: string) {
	fmt.printf("  %s\n", reason)
	if should_keep(state) {
		fmt.printf("  run_id=%s preserved\n", state.run_id)
		fmt.printf("  cwd=%s\n", state.cwd)
		fmt.printf("  tmux=%s:smoke   (attach: `tmux attach -t %s` to inspect the agent pane manually)\n", state.session, state.session)
	}
	fmt.printf("\nFAIL  total %.1fs\n", elapsed_seconds(state.start_ns))
}

do_cleanup :: proc(state: ^Test_State) {
	if should_keep(state) { return }
	_ = tmux.kill_session(state.session)
	_ = os.remove_all(state.cwd)
}

should_keep :: proc(state: ^Test_State) -> bool {
	switch state.keep {
	case "always":     return true
	case "never":      return false
	case "on-failure": return state.step_failed
	}
	return state.step_failed
}

test_abort_cleanup :: proc(state: ^Test_State) -> int {
	fmt.fprintln(os.stderr, "ham-wrapper test: interrupted")
	state.step_failed = true
	do_cleanup(state)
	return 1
}

sweep_stale_test_runs :: proc() {
	infos, read_err := os.read_directory_by_path("/tmp", -1, context.allocator)
	if read_err != nil { return }
	now_ns       := time.to_unix_nanoseconds(time.now())
	threshold_ns := now_ns - TEST_STALE_SECONDS*i64(time.Second)
	for info in infos {
		if !strings.has_prefix(info.name, "ham-wrapper-test-t-") { continue }
		mod_ns := time.to_unix_nanoseconds(info.modification_time)
		if mod_ns > threshold_ns { continue }
		path := fmt.tprintf("/tmp/%s", info.name)
		_ = os.remove_all(path)
		if len(info.name) >= 4 {
			suffix := info.name[len(info.name)-4:]
			_ = tmux.kill_session(fmt.tprintf("ham-test-%s", suffix))
		}
	}
}

capture_last_lines :: proc(pane_id: string, n: int) -> string {
	if pane_id == "" { return "(pane gone)" }
	text, ok := tmux.capture_pane_text(pane_id, n)
	if !ok { return "(capture failed)" }
	return text
}

elapsed_seconds :: proc(start_ns: i64) -> f64 {
	return f64(time.to_unix_nanoseconds(time.now()) - start_ns) / f64(time.Second)
}
