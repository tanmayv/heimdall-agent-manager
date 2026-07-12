package main

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "odin_test:contracts"
import cfg_lib "odin_test:lib/config"
import http "odin_test:lib/http_client"
import tmux "odin_test:lib/tmux"
import ws "odin_test:lib/ws"

// Test agents use a minimal one-shot prompt. The prompt uses the same {ctl_bin},
// {daemon_url}, and {token} substitutions as the normal starter_prompt template.
TEST_AGENT_STARTER_PROMPT :: "You are a Heimdall test agent. Your only task:\n\nRun exactly this shell command:\n{ctl_bin} --daemon-url {daemon_url} --token {token} start-success\n\nIf the command exits 0, you are done — say \"TEST OK\" and stop.\nIf it errors, print the error verbatim and stop.\nDo not perform any other action. Do not write files. Do not read files."

is_test_token :: proc(token: string) -> bool {
	return strings.has_prefix(token, "agt_test_")
}

main :: proc() {
	initialize_default_preferences()
	if len(os.args) > 1 && os.args[1] == "test" {
		os.exit(run_test_command(os.args))
	}
	if has_flag(os.args, "--version") {
		fmt.println("ham-wrapper", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION)
		return
	}
	if has_flag(os.args, "--help") || has_flag(os.args, "-h") {
		print_usage()
		return
	}

	if has_flag(os.args, "--detach") {
		start_detached(os.args)
		return
	}

	config_path := cfg_lib.config_path_from_args(os.args)
	loaded, ok := cfg_lib.load(config_path)
	if !ok {
		fmt.println("failed to load config", config_path)
		return
	}

	cfg := loaded.config.wrapper
	if cfg.ham_ctl_bin != "" do g_ctl_bin = cfg.ham_ctl_bin
	selected_agent := option_value(os.args, "--agent", cfg.default_agent)
	if selected_agent == "" do selected_agent = cfg.agent_name
	requested_agent_token := option_value(os.args, "--agent-token", "")
	raw_agent_identity := agent_identity_from_args(os.args, cfg.agent_name)
	agent_class, agent_instance_id, identity_ok := parse_agent_identity(raw_agent_identity)
	if !identity_ok {
		fmt.println("invalid agent identity; use class or class@suffix with only letters, numbers, and dash in each part")
		return
	}

	override_project_id := option_value(os.args, "--project-id", "")
	current_task_id := option_value(os.args, "--current-task-id", "")
	model_tier := option_value(os.args, "--tier", "normal")
	if model_tier != "cheap" && model_tier != "normal" && model_tier != "smart" {
		fmt.println("invalid --tier value; expected cheap, normal, or smart; got:", model_tier)
		return
	}

	agent_cmd, agent_cmd_ok := selected_agent_command(cfg, selected_agent)
	if !agent_cmd_ok {
		fmt.println("error: no agent-cmd config found for agent", selected_agent)
		fmt.printfln("hint: add [wrapper.agent-cmd.%s] to your config, or pass --agent <configured-name>", selected_agent)
		return
	}
	effective_project_id := override_project_id
	if effective_project_id == "" do effective_project_id = agent_cmd.project
	if effective_project_id == "" do effective_project_id = cfg.project
	if effective_project_id != "" {
		agent_cmd.project = effective_project_id
		cfg.project = effective_project_id
	}
	window_name := wrapper_window_name(cfg.tmux_window_prefix, agent_instance_id)
	cwd := resolve_agent_run_dir(cfg, agent_cmd, agent_cmd_ok, selected_agent, agent_instance_id)
	launch_start_ms := wrapper_now_unix_ms()
	wrapper_launch_log("start", agent_instance_id, launch_start_ms)
	fmt.printfln("WRAPPER_LAUNCH ts_unix_ms=%d elapsed_ms=0 stage=identity_resolved agent=%s class=%s selected_agent=%s project=%s tier=%s session=%s window=%s cwd=%s", launch_start_ms, agent_instance_id, agent_class, selected_agent, effective_project_id, model_tier, cfg.tmux_session, window_name, cwd)

	overwrite := has_flag(os.args, "--overwrite")
	if !handle_existing_agent_window(cfg.tmux_session, window_name, overwrite) {
		wrapper_launch_log("existing_window_abort", agent_instance_id, launch_start_ms)
		return
	}
	wrapper_launch_log("existing_window_checked", agent_instance_id, launch_start_ms)

	display_name := option_value(os.args, "--display-name", template_display_name(cfg.display_name, agent_class, agent_instance_id, selected_agent))

	wrapper_launch_log("daemon_health_begin", agent_instance_id, launch_start_ms)
	response, health_ok := http.get(cfg.daemon_url, contracts.ROUTE_HEALTH)
	fmt.printfln("WRAPPER_LAUNCH ts_unix_ms=%d elapsed_ms=%d stage=daemon_health_done agent=%s ok=%t status=%d", wrapper_now_unix_ms(), wrapper_now_unix_ms() - launch_start_ms, agent_instance_id, health_ok, response.status)
	if !health_ok || response.status != 200 {
		fmt.println("daemon is not reachable; start ham-daemon first")
		return
	}

	register_body := register_request_json(agent_class, agent_instance_id, display_name, requested_agent_token)
	wrapper_launch_log("register_begin", agent_instance_id, launch_start_ms)
	register_response, register_ok := http.post(cfg.daemon_url, contracts.ROUTE_REGISTER, register_body)
	fmt.printfln("WRAPPER_LAUNCH ts_unix_ms=%d elapsed_ms=%d stage=register_done agent=%s ok=%t status=%d response_bytes=%d", wrapper_now_unix_ms(), wrapper_now_unix_ms() - launch_start_ms, agent_instance_id, register_ok, register_response.status, len(register_response.body))
	if !register_ok || register_response.status != 200 {
		fmt.println("registration failed")
		if register_ok {
			fmt.println("registration_status", register_response.status)
			fmt.println("registration_response", register_response.body)
			if register_response.status == 401 {
				fmt.println("fatal: registration unauthorized; stopping wrapper", agent_instance_id, register_response.body)
			}
		}
		return
	}

	fmt.println("ham-wrapper", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION)
	fmt.println("config", loaded.path)
	fmt.println("daemon_url", cfg.daemon_url)
	fmt.println("agent_class", agent_class)
	fmt.println("agent_instance_id", agent_instance_id)
	fmt.println("selected_agent", selected_agent)
	fmt.println("display_name", display_name)
	fmt.println("model_tier", model_tier)
	fmt.println("daemon_health", response.body)
	fmt.println("registered", register_response.body)

	registered_instance_id := extract_json_string(register_response.body, "agent_instance_id", "")
	conversation_id := extract_json_string(register_response.body, "conversation_id", "")
	ws_url := extract_json_string(register_response.body, "ws_url", "")
	agent_token := extract_json_string(register_response.body, "agent_token", "")
	template_persona := extract_json_string(register_response.body, "template_persona", "")
	template_instructions := extract_json_string(register_response.body, "template_instructions", "")
	team_id := extract_json_string(register_response.body, "team_id", "")
	role_key := extract_json_string(register_response.body, "role_key", "")
	role_index := extract_json_int(register_response.body, "role_index", 0)
	prefs_obj := extract_json_object(register_response.body, "preferences")
	defer if prefs_obj != "" do delete(prefs_obj)
	apply_preferences_json(prefs_obj)
	if registered_instance_id == "" {
		fmt.println("registration response missing agent_instance_id")
		return
	}
	if ws_url == "" {
		fmt.println("registration response missing ws_url")
		return
	}
	if effective_project_id != "" {
		wrapper_launch_log("project_validate_begin", registered_instance_id, launch_start_ms)
		if !validate_project_exists(cfg.daemon_url, agent_token, effective_project_id) {
			fmt.println("invalid project_id", effective_project_id)
			fmt.println("wrapper startup aborted before tmux launch; create the project first or remove --project-id / wrapper.project")
			return
		}
		wrapper_launch_log("project_validate_done", registered_instance_id, launch_start_ms)
	}

	fmt.println("starting tmux agent")
	fmt.println("tmux_session", cfg.tmux_session)
	fmt.println("tmux_window", window_name)
	fmt.println("working_dir", cwd)

	if !is_test_token(agent_token) {
		wrapper_launch_log("bootstrap_files_begin", registered_instance_id, launch_start_ms)
		generate_bootstrap_files(cwd, loaded.path, cfg, agent_cmd, selected_agent, registered_instance_id, display_name, cfg.daemon_url, agent_token, current_task_id, template_persona, template_instructions, team_id, role_key, role_index)
		wrapper_launch_log("bootstrap_files_done", registered_instance_id, launch_start_ms)
	}

	stop_message := cfg.stop_message
	if agent_cmd.stop_message != "" do stop_message = agent_cmd.stop_message
	if stop_message == "" do stop_message = "Agent stop requested. You have {time} seconds to complete your current work and checkpoint before shutdown."

	command := build_agent_command(cfg, selected_agent, cfg.daemon_url, registered_instance_id, display_name, conversation_id, agent_token, current_task_id, model_tier)
	wrapper_launch_log("agent_command_built", registered_instance_id, launch_start_ms)
	wrapper_launch_log("tmux_ensure_begin", registered_instance_id, launch_start_ms)
	launch, launch_ok := tmux.ensure_agent_window(cfg.tmux_session, window_name, cwd, command)
	fmt.printfln("WRAPPER_LAUNCH ts_unix_ms=%d elapsed_ms=%d stage=tmux_ensure_done agent=%s ok=%t pane=%s", wrapper_now_unix_ms(), wrapper_now_unix_ms() - launch_start_ms, registered_instance_id, launch_ok, launch.pane_id)
	if !launch_ok {
		fmt.println("failed to launch or find tmux window")
		report_startup_status(cfg.daemon_url, registered_instance_id, "startup_failed", "tmux_launch_failed", "failed to launch or find tmux window", selected_agent, cwd, "")
		return
	}
	fmt.println("tmux_pane", launch.pane_id)
	startup_status := "ready"
	startup_reason_code := "launch_success"
	startup_safe_diagnostic := "Startup detection disabled; assuming ready"


	startup_report_begin := wrapper_now_unix_ms()
	report_startup_status(cfg.daemon_url, registered_instance_id, "starting", "launch", "Agent process launched in tmux", selected_agent, cwd, launch.pane_id)
	fmt.printfln("WRAPPER_LAUNCH ts_unix_ms=%d elapsed_ms=%d stage=startup_report_starting_done agent=%s report_ms=%d", wrapper_now_unix_ms(), wrapper_now_unix_ms() - launch_start_ms, registered_instance_id, wrapper_now_unix_ms() - startup_report_begin)
	wrapper_launch_log("starter_prompt_begin", registered_instance_id, launch_start_ms)
	deliver_tmux_starter_prompt(agent_cmd, cfg.daemon_url, registered_instance_id, display_name, conversation_id, agent_token, current_task_id, launch.pane_id)
	wrapper_launch_log("starter_prompt_done", registered_instance_id, launch_start_ms)
	wrapper_launch_log("startup_probe_begin", registered_instance_id, launch_start_ms)
	result := startup_probe_agent(agent_cmd.startup_detection, launch.pane_id)
	wrapper_launch_log("startup_probe_done", registered_instance_id, launch_start_ms)
	if result.status != "disabled" {
		startup_status = result.status
		startup_reason_code = result.reason_code
		startup_safe_diagnostic = result.safe_diagnostic
		fmt.println("startup_status", result.status)
		if result.reason_code != "" do fmt.println("startup_reason_code", result.reason_code)
		if result.safe_diagnostic != "" do fmt.println("startup_diagnostic", result.safe_diagnostic)
		report_startup_status(cfg.daemon_url, registered_instance_id, result.status, result.reason_code, result.safe_diagnostic, selected_agent, cwd, launch.pane_id)
		if result.status == "startup_blocked" {
			_ = tmux.rename_window_for_pane(launch.pane_id, fmt.tprintf("[Blocked] %s", window_name))
		} else {
			_ = tmux.rename_window_for_pane(launch.pane_id, window_name)
		}
	} else {
		_ = tmux.rename_window_for_pane(launch.pane_id, window_name)
	}

	wrapper_launch_log("ws_connect_begin", registered_instance_id, launch_start_ms)
	ws_conn, ws_ok := ws.connect(ws_url)
	fmt.printfln("WRAPPER_LAUNCH ts_unix_ms=%d elapsed_ms=%d stage=ws_connect_done agent=%s ok=%t", wrapper_now_unix_ms(), wrapper_now_unix_ms() - launch_start_ms, registered_instance_id, ws_ok)
	if ws_ok {
		fmt.println("ws connected", ws_url)
	} else {
		fmt.println("ws connection failed", ws_url)
	}

	initial_exec_state := "running"
	wrapper_launch_log("heartbeat_loop_enter", registered_instance_id, launch_start_ms)
	heartbeat_loop(cfg.daemon_url, agent_class, registered_instance_id, display_name, agent_token, launch.pane_id, stop_message, selected_agent, model_tier, effective_project_id, cwd, initial_exec_state, startup_status, startup_reason_code, startup_safe_diagnostic, agent_cmd.activity_detection, cfg.tmux_session, window_name, &ws_conn)
}

Startup_Probe_Result :: struct {
	status: string,
	reason_code: string,
	safe_diagnostic: string,
}

Activity_Status_Snapshot :: struct {
	status: string,
	checked_unix_ms: i64,
	source: string,
}

ACTIVITY_STATUS_SOURCE :: "tmux_pane_sampler"
ACTIVITY_SAMPLE_COUNT :: 3
HEARTBEAT_INTERVAL_MS :: i64(10_000)
ACTIVITY_LOOP_SLEEP_MS :: time.Duration(250)

activity_detection_effective :: proc(cfg: cfg_lib.Activity_Detection_Config) -> cfg_lib.Activity_Detection_Config {
	effective := cfg
	if effective.sample_line_count <= 0 do effective.sample_line_count = 20
	if effective.ignore_bottom_lines < 0 do effective.ignore_bottom_lines = 0
	if effective.ignore_bottom_lines >= effective.sample_line_count do effective.ignore_bottom_lines = effective.sample_line_count - 1
	if effective.check_interval_seconds <= 0 do effective.check_interval_seconds = 15
	if effective.min_gap_ms <= 0 do effective.min_gap_ms = 100
	if effective.max_gap_ms <= 0 do effective.max_gap_ms = 500
	if effective.min_gap_ms > effective.max_gap_ms {
		tmp := effective.min_gap_ms
		effective.min_gap_ms = effective.max_gap_ms
		effective.max_gap_ms = tmp
	}
	return effective
}

activity_gap_ms :: proc(cfg: cfg_lib.Activity_Detection_Config) -> int {
	if cfg.max_gap_ms <= cfg.min_gap_ms do return cfg.min_gap_ms
	range := cfg.max_gap_ms - cfg.min_gap_ms + 1
	return cfg.min_gap_ms + int(rand.uint32() % u32(range))
}

normalize_activity_capture :: proc(text: string, ignore_bottom_lines: int) -> string {
	lines := strings.split(text, "\n")
	defer delete(lines)
	end := len(lines)
	for end > 0 && lines[end - 1] == "" do end -= 1
	if ignore_bottom_lines > 0 {
		end -= ignore_bottom_lines
		if end < 1 do end = 1
	}
	if end <= 0 do return ""
	builder := strings.builder_make()
	for i in 0..<end {
		if i > 0 do strings.write_byte(&builder, '\n')
		strings.write_string(&builder, lines[i])
	}
	return strings.to_string(builder)
}

classify_activity_captures :: proc(captures: []string, cfg: cfg_lib.Activity_Detection_Config) -> string {
	if len(captures) <= 1 do return "idle"
	reference := normalize_activity_capture(captures[0], cfg.ignore_bottom_lines)
	for i in 1..<len(captures) {
		if normalize_activity_capture(captures[i], cfg.ignore_bottom_lines) != reference {
			return "active"
		}
	}
	return "idle"
}

sample_activity_status :: proc(agent_instance_id, pane_id: string, cfg: cfg_lib.Activity_Detection_Config) -> Activity_Status_Snapshot {
	now := wrapper_now_unix_ms()
	if !cfg.enabled {
		return Activity_Status_Snapshot{status = "unknown", checked_unix_ms = now, source = ACTIVITY_STATUS_SOURCE}
	}
	if pane_id == "" || !tmux.pane_exists(pane_id) {
		return Activity_Status_Snapshot{status = "unknown", checked_unix_ms = now, source = ACTIVITY_STATUS_SOURCE}
	}
	capture_lines := cfg.sample_line_count + cfg.ignore_bottom_lines
	if capture_lines <= 0 do capture_lines = cfg.sample_line_count
	captures: [ACTIVITY_SAMPLE_COUNT]string
	for i in 0..<ACTIVITY_SAMPLE_COUNT {
		capture, ok := tmux.capture_pane_text(pane_id, capture_lines)
		if !ok {
			fmt.printfln("WRAPPER_ACTIVITY ts_unix_ms=%d agent=%s status=unknown reason=capture_failed", wrapper_now_unix_ms(), agent_instance_id)
			return Activity_Status_Snapshot{status = "unknown", checked_unix_ms = wrapper_now_unix_ms(), source = ACTIVITY_STATUS_SOURCE}
		}
		captures[i] = capture
		if i + 1 < ACTIVITY_SAMPLE_COUNT {
			time.sleep(time.Duration(activity_gap_ms(cfg)) * time.Millisecond)
		}
	}
	status := classify_activity_captures(captures[:], cfg)
	checked := wrapper_now_unix_ms()
	fmt.printfln("WRAPPER_ACTIVITY ts_unix_ms=%d agent=%s status=%s", checked, agent_instance_id, status)
	return Activity_Status_Snapshot{status = status, checked_unix_ms = checked, source = ACTIVITY_STATUS_SOURCE}
}

wrapper_now_unix_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

wrapper_launch_log :: proc(stage, agent_instance_id: string, start_ms: i64 = 0) {
	now := wrapper_now_unix_ms()
	if start_ms > 0 {
		fmt.printfln("WRAPPER_LAUNCH ts_unix_ms=%d elapsed_ms=%d stage=%s agent=%s", now, now - start_ms, stage, agent_instance_id)
	} else {
		fmt.printfln("WRAPPER_LAUNCH ts_unix_ms=%d stage=%s agent=%s", now, stage, agent_instance_id)
	}
}

startup_probe_agent :: proc(cfg: cfg_lib.Startup_Detection_Config, pane_id: string, abort_flag: ^bool = nil) -> Startup_Probe_Result {
	if !cfg.enabled {
		return Startup_Probe_Result{status = "disabled"}
	}
	if pane_id == "" do return Startup_Probe_Result{status = "startup_failed", reason_code = "missing_pane", safe_diagnostic = "tmux pane was not available for startup detection"}

	probe_seconds := cfg.startup_probe_seconds
	if probe_seconds <= 0 do probe_seconds = 15
	interval_ms := cfg.capture_interval_ms
	if interval_ms <= 0 do interval_ms = 500
	probe_window_ns := i64(probe_seconds) * i64(time.Second)
	deadline := time.to_unix_nanoseconds(time.now()) + probe_window_ns
	auto_enter_cooldown_until: i64 = 0
	iteration := 0
	fmt.println("startup_probe begin pane", pane_id, "probe_seconds", probe_seconds, "interval_ms", interval_ms, "auto_enter_patterns", len(cfg.auto_enter_patterns), "blocked_patterns", len(cfg.blocked_patterns))
	for p, i in cfg.auto_enter_patterns {
		pk := ""
		if i < len(cfg.auto_enter_pre_keys) do pk = cfg.auto_enter_pre_keys[i]
		fmt.printf("  auto_enter[%d]=%q pre_key=%q\n", i, p, pk)
	}
	for p, i in cfg.blocked_patterns do fmt.printf("  blocked[%d]=%q\n", i, p)

	for time.to_unix_nanoseconds(time.now()) <= deadline {
		if abort_flag != nil && abort_flag^ do break
		if !tmux.pane_exists(pane_id) do return Startup_Probe_Result{status = "startup_failed", reason_code = "pane_exited", safe_diagnostic = "tmux pane exited during startup detection"}
		pane_text, ok := tmux.capture_pane_text(pane_id, 80)
		if !ok do return Startup_Probe_Result{status = "startup_failed", reason_code = "capture_failed", safe_diagnostic = "tmux pane capture failed during startup detection"}
		iteration += 1
		if iteration == 1 || iteration % 10 == 0 {
			preview_len := len(pane_text)
			if preview_len > 400 do preview_len = 400
			fmt.printf("startup_probe iter=%d pane_text_len=%d tail=%q\n", iteration, len(pane_text), pane_text[len(pane_text)-preview_len:])
		}
		now_ns := time.to_unix_nanoseconds(time.now())
		if now_ns >= auto_enter_cooldown_until {
			if idx := first_matching_pattern(pane_text, cfg.auto_enter_patterns); idx >= 0 {
				pre_key := ""
				if idx < len(cfg.auto_enter_pre_keys) do pre_key = cfg.auto_enter_pre_keys[idx]
				fmt.println("startup auto_enter matched idx", idx, "pattern", cfg.auto_enter_patterns[idx], "pre_key", pre_key)
				if pre_key != "" {
					// Support multi-key pre-sequences like "Tab Tab" or "Down Down".
					// tmux send-keys accepts multiple key tokens as separate argv
					// entries (e.g. `send-keys Tab Tab`) but not as a single
					// space-joined argument, so we split here and pass each token
					// on the argv. This lets config-authors express multi-step nav
					// without escaping.
					tokens := strings.fields(pre_key)
					defer delete(tokens)
					pre_cmd := make([dynamic]string, 0, len(tokens) + 4)
					defer delete(pre_cmd)
					append(&pre_cmd, "tmux", "send-keys", "-t", pane_id)
					for tok in tokens do append(&pre_cmd, tok)
					_, _, _, _ = os.process_exec(os.Process_Desc{command = pre_cmd[:]}, context.allocator)
					// Tiny pause so the TUI registers the navigation before Enter
					time.sleep(150 * time.Millisecond)
				}
				enter_cmd := []string{"tmux", "send-keys", "-t", pane_id, "Enter"}
				_, _, _, _ = os.process_exec(os.Process_Desc{command = enter_cmd}, context.allocator)
				// Cool down so the same buffered prompt text doesn't retrigger
				// before the TUI repaints. Extend deadline by the original probe
				// window so dismissing a prompt doesn't eat the ready budget.
				if pre_key != "" {
					fmt.println("startup auto_enter sent pre_key", pre_key)
				}
				fmt.println("startup auto_enter sent Enter; cooldown 2s; deadline extended by", probe_seconds, "s")
				auto_enter_cooldown_until = now_ns + i64(2) * i64(time.Second)
				deadline = now_ns + probe_window_ns
				time.sleep(time.Duration(interval_ms) * time.Millisecond)
				continue
			}
		}
		if idx := first_matching_pattern(pane_text, cfg.blocked_patterns); idx >= 0 {
			fmt.println("startup blocked matched idx", idx, "pattern", cfg.blocked_patterns[idx])
			return Startup_Probe_Result{status = "startup_blocked", reason_code = startup_reason_code("blocked", idx, cfg.blocked_patterns[idx]), safe_diagnostic = startup_safe_diagnostic(cfg, idx, "Startup blocked by configured provider prompt")}
		}
		time.sleep(time.Duration(interval_ms) * time.Millisecond)
	}

	fmt.println("startup_probe timeout after", iteration, "iterations; no pattern matched")
	status := "startup_unknown"
	if cfg.startup_unknown_is_blocked do status = "startup_blocked"
	return Startup_Probe_Result{status = status, reason_code = "no_pattern_matched", safe_diagnostic = "No configured startup pattern matched before timeout"}
}

first_matching_pattern :: proc(text: string, patterns: []string) -> int {
	for pattern, i in patterns {
		if pattern == "" do continue
		if strings.index(text, pattern) >= 0 do return i
	}
	return -1
}

startup_reason_code :: proc(prefix: string, idx: int, pattern: string) -> string {
	code := strings.builder_make()
	strings.write_string(&code, prefix)
	strings.write_string(&code, "_")
	strings.write_string(&code, fmt.tprintf("%d", idx))
	for ch in pattern {
		switch ch {
		case 'a'..='z', 'A'..='Z', '0'..='9':
			strings.write_rune(&code, ch)
		case ' ', '-', '_':
			strings.write_string(&code, "_")
		case:
		}
	}
	return strings.to_string(code)
}

startup_safe_diagnostic :: proc(cfg: cfg_lib.Startup_Detection_Config, idx: int, fallback: string) -> string {
	if idx >= 0 && idx < len(cfg.sanitized_reason_mapping) {
		entry := cfg.sanitized_reason_mapping[idx]
		if eq := strings.index_byte(entry, '='); eq >= 0 && eq < len(entry) - 1 do return entry[eq + 1:]
		if entry != "" do return entry
	}
	return fallback
}

report_startup_status :: proc(daemon_url, agent_instance_id, status, reason_code, safe_diagnostic, provider_profile, run_dir, tmux_pane: string) {
	start_ms := wrapper_now_unix_ms()
	fmt.printfln("WRAPPER_LAUNCH ts_unix_ms=%d stage=startup_report_post_begin agent=%s status=%s reason=%s pane=%s", start_ms, agent_instance_id, status, reason_code, tmux_pane)
	builder := strings.builder_make()
	strings.write_string(&builder, `{"agent_instance_id":"`); json_write_string(&builder, agent_instance_id)
	strings.write_string(&builder, `","startup_status":"`); json_write_string(&builder, status)
	strings.write_string(&builder, `","reason_code":"`); json_write_string(&builder, reason_code)
	strings.write_string(&builder, `","safe_diagnostic":"`); json_write_string(&builder, safe_diagnostic)
	strings.write_string(&builder, `","provider_profile":"`); json_write_string(&builder, provider_profile)
	strings.write_string(&builder, `","run_dir":"`); json_write_string(&builder, run_dir)
	strings.write_string(&builder, `","tmux_pane":"`); json_write_string(&builder, tmux_pane)
	strings.write_string(&builder, `"}`)
	response, ok := http.post(daemon_url, "/startup", strings.to_string(builder))
	fmt.printfln("WRAPPER_LAUNCH ts_unix_ms=%d elapsed_ms=%d stage=startup_report_post_done agent=%s status=%s ok=%t http_status=%d", wrapper_now_unix_ms(), wrapper_now_unix_ms() - start_ms, agent_instance_id, status, ok, response.status)
}

handle_existing_agent_window :: proc(tmux_session, window_name: string, overwrite: bool) -> bool {
	existing_pane := tmux.pane_for_window(tmux_session, window_name)
	if existing_pane == "" do return true

	fmt.println("agent tmux window already exists")
	fmt.println("tmux_session", tmux_session)
	fmt.println("tmux_window", window_name)
	fmt.println("tmux_target", fmt.tprintf("%s:%s", tmux_session, window_name))
	fmt.println("tmux_pane", existing_pane)
	fmt.println("close_command", fmt.tprintf("tmux kill-window -t '%s:%s'", tmux_session, window_name))

	if overwrite {
		fmt.println("overwrite flag present; closing existing tmux window and continuing")
		if !tmux.kill_window(tmux_session, window_name) {
			fmt.println("failed to close existing tmux window; aborting before registration")
			return false
		}
		return true
	}

	fmt.print("Close existing tmux window and continue? [y/N]: ")

	if !read_yes_from_stdin() {
		fmt.println("not closing existing window; aborting before registration")
		return false
	}

	if !tmux.kill_window(tmux_session, window_name) {
		fmt.println("failed to close existing tmux window; aborting before registration")
		return false
	}

	fmt.println("closed existing tmux window; continuing")
	return true
}

read_yes_from_stdin :: proc() -> bool {
	buf: [16]byte
	n, err := os.read(os.stdin, buf[:])
	if err != nil || n == 0 do return false
	answer := strings.trim_space(string(buf[:n]))
	return answer == "y" || answer == "Y" || answer == "yes" || answer == "YES"
}

heartbeat_loop :: proc(daemon_url, agent_class, agent_instance_id, display_name, agent_token, tmux_pane, stop_message, provider_profile, provider_tier, project_id, run_dir, initial_exec_state, initial_startup_status, initial_startup_reason_code, initial_startup_safe_diagnostic: string, activity_cfg: cfg_lib.Activity_Detection_Config, tmux_session, window_name: string, ws_conn: ^ws.Connection) {
	fmt.println("heartbeat started", agent_instance_id)
	current_token := agent_token
	failed_heartbeats := 0
	exec_state := initial_exec_state
	if exec_state == "" do exec_state = "running"
	exec_state_since := time.to_unix_nanoseconds(time.now()) / 1_000_000
	pid := os.get_pid()

	current_startup_status := initial_startup_status
	current_startup_reason_code := initial_startup_reason_code
	current_startup_safe_diagnostic := initial_startup_safe_diagnostic
	effective_activity_cfg := activity_detection_effective(activity_cfg)
	latest_activity := Activity_Status_Snapshot{status = "unknown", checked_unix_ms = 0, source = ACTIVITY_STATUS_SOURCE}
	next_heartbeat_unix_ms := wrapper_now_unix_ms()
	next_activity_check_unix_ms := wrapper_now_unix_ms()
	if !effective_activity_cfg.enabled do next_activity_check_unix_ms = -1

	for {
		now := wrapper_now_unix_ms()
		if !tmux.pane_exists(tmux_pane) {
			fmt.println("agent tmux pane missing; stopping wrapper", tmux_pane)
			return
		}

		if next_activity_check_unix_ms >= 0 && now >= next_activity_check_unix_ms {
			latest_activity = sample_activity_status(agent_instance_id, tmux_pane, effective_activity_cfg)
			next_activity_check_unix_ms = wrapper_now_unix_ms() + i64(effective_activity_cfg.check_interval_seconds) * 1_000
		}

		// Self-healing WebSocket reconnection: if the WebSocket connection was severed
		// (e.g. due to daemon restart), re-register and reconnect immediately!
		if !ws_conn.connected {
			fmt.println("WebSocket disconnected; attempting to reconnect...", agent_instance_id)
			if new_ws_url, new_token, terminal_auth_failure, reconnected := reregister_and_reconnect_ws(daemon_url, agent_class, agent_instance_id, display_name, current_token, ws_conn); reconnected {
				fmt.println("WebSocket successfully reconnected!", agent_instance_id, new_ws_url)
				current_token = new_token
				failed_heartbeats = 0
				notify_agent_token_refreshed(tmux_pane, daemon_url, new_token, agent_instance_id)
			} else if terminal_auth_failure {
				close_wrapper_after_auth_failure(agent_instance_id, "ws_reconnect_register_401", "daemon rejected re-registration while WS was disconnected", ws_conn)
				return
			} else {
				fmt.println("WebSocket reconnection attempt failed; will retry", agent_instance_id)
			}
		}

		if now >= next_heartbeat_unix_ms {
			body := heartbeat_request_json(agent_instance_id, current_token, display_name, provider_profile, provider_tier, project_id, tmux_pane, run_dir, exec_state, "", current_startup_status, current_startup_reason_code, current_startup_safe_diagnostic, latest_activity, pid, exec_state_since)
			response, ok := http.post(daemon_url, contracts.ROUTE_HEARTBEAT, body)
			if ok && response.status == 200 {
				failed_heartbeats = 0
				fmt.println("heartbeat ok", agent_instance_id)
				log_heartbeat_corrections(response.body, agent_instance_id)

				// Parse corrections to dynamically capture startup status overrides from the daemon
				if corr_idx := strings.index(response.body, `"corrections":{`); corr_idx >= 0 {
					corr_block := response.body[corr_idx:]
					if new_status := extract_json_string(corr_block, "startup_status", ""); new_status != "" {
						fmt.println("HEARTBEAT CORRECTION: startup_status corrected to", new_status)
						current_startup_status = strings.clone(new_status)
						if new_reason := extract_json_string(corr_block, "startup_reason_code", ""); new_reason != "" {
							current_startup_reason_code = strings.clone(new_reason)
						}
						if new_diag := extract_json_string(corr_block, "startup_safe_diagnostic", ""); new_diag != "" {
							current_startup_safe_diagnostic = strings.clone(new_diag)
						}
					}
				}
			} else if ok && response.status == 401 {
				fmt.println("heartbeat unauthorized; closing wrapper", agent_instance_id, response.body)
				close_wrapper_after_auth_failure(agent_instance_id, "heartbeat_401", response.body, ws_conn)
				return
			} else if ok && response.status == 409 {
				fmt.println("fatal: heartbeat conflict; stopping wrapper", agent_instance_id, response.body)
				return
			} else if ok && response.status == 400 {
				fmt.println("heartbeat rejected", agent_instance_id, response.body)
				failed_heartbeats += 1
			} else {
				failed_heartbeats += 1
				if ok {
					fmt.println("heartbeat failed", agent_instance_id, "status", response.status, "body", response.body)
				} else {
					fmt.println("heartbeat failed", agent_instance_id, "request_failed")
				}
			}

			if failed_heartbeats >= 3 {
				fmt.println("heartbeat failed repeatedly; re-registering", agent_instance_id)
				if new_ws_url, new_token, terminal_auth_failure, reconnected := reregister_and_reconnect_ws(daemon_url, agent_class, agent_instance_id, display_name, current_token, ws_conn); reconnected {
					fmt.println("reconnected", agent_instance_id, new_ws_url)
					current_token = new_token
					failed_heartbeats = 0
					notify_agent_token_refreshed(tmux_pane, daemon_url, new_token, agent_instance_id)
				} else if terminal_auth_failure {
					close_wrapper_after_auth_failure(agent_instance_id, "heartbeat_retry_register_401", "daemon rejected re-registration after repeated heartbeat failures", ws_conn)
					return
				} else {
					fmt.println("reconnect attempt failed", agent_instance_id)
				}
			}
			next_heartbeat_unix_ms = wrapper_now_unix_ms() + HEARTBEAT_INTERVAL_MS
		}

		if text, got_message := ws.poll_text(ws_conn); got_message {
			if strings.index(text, `"type":"duplicate_check"`) >= 0 {
				// internal control message; do not surface as an agent message
			} else if strings.index(text, `"type":"stop_event"`) >= 0 {
				fmt.println("stop event", text)
				handle_stop_event(text, tmux_pane, tmux_session, window_name, agent_instance_id, stop_message, ws_conn)
				return
			} else if strings.index(text, `"type":"message_event"`) >= 0 {
				fmt.println("message event", text)
				handle_message_event(text, tmux_pane)
			} else if strings.index(text, `"type":"task_event"`) >= 0 {
				fmt.println("task event", text)
				handle_task_event(text, tmux_pane, agent_instance_id)
			} else if strings.index(text, `"type":"memory_event"`) >= 0 {
				fmt.println("memory event", text)
				handle_memory_event(text, tmux_pane, agent_instance_id)
			} else if strings.index(text, `"type":"user_chat_event"`) >= 0 {
				fmt.println("user chat event", text)
				handle_user_chat_event(text, tmux_pane)
			} else {
				fmt.println("ws message", text)
			}
		}
		time.sleep(ACTIVITY_LOOP_SLEEP_MS * time.Millisecond)
	}
}

handle_message_event :: proc(text, tmux_pane: string) {
	if strings.index(text, `"event":"messages_available"`) < 0 do return

	pending_count := extract_json_int(text, "pending_count", 1)
	from_agent_instance_id := extract_json_string(text, "from_agent_instance_id", "unknown")
	if pending_count <= 0 do pending_count = 1

	line := template_live_message(
		active_live_prefs.msg_agent_message,
		pending_count, from_agent_instance_id,
		"", "", "", "", "", "", "", "", "", "", 0,
	)
	defer delete(line)

	if tmux.send_line_with_escape(tmux_pane, line, active_live_prefs.msg_agent_message_int) {
		fmt.println("notified agent pane", line)
	} else {
		fmt.println("failed to notify agent pane", line)
	}
}

// Wrapper-side task-event filtering was removed as part of chain-19f4b3d0617
// closeout. The daemon is now the sole authority on whether a task event is
// generated and who receives it (source-side routing). The wrapper delivers
// every task_event it receives to the agent pane, except events it authored
// itself (self-authored suppression stays: an agent should not be notified
// of its own actions).

handle_task_event :: proc(text, tmux_pane, agent_instance_id: string) {
	task_id := extract_json_string(text, "task_id", "unknown")
	status := extract_json_string(text, "status", "updated")
	changed_by := extract_json_string(text, "changed_by", "unknown")
	body := extract_json_string(text, "body", "")
	event_kind := extract_json_string(text, "event", "")
	if changed_by == agent_instance_id {
		fmt.println("suppressed self-authored task event", task_id, status, changed_by)
		return
	}
	
	template_str := active_live_prefs.msg_task_updated if body != "" else active_live_prefs.msg_task_updated_empty
	interrupt_val := active_live_prefs.msg_task_updated_int if body != "" else active_live_prefs.msg_task_updated_empty_int

	line := template_live_message(
		template_str,
		0, "",
		task_id, status, changed_by, body, "", "", "", "", "", "", 0,
	)
	defer delete(line)

	// Task notifications can be high volume (auto-claims, status changes, nudges).
	// Keep ordinary task updates non-interrupting, but let explicit nudges break
	// through an active agent generation so they are not silently buried.
	escape_prefix := false
	if event_kind == "Task_Nudged" {
		escape_prefix = extract_json_bool(text, "interrupt", false) || extract_json_bool(text, "send_escape_prefix", false)
	}

	if tmux.send_line_with_escape(tmux_pane, line, escape_prefix) {
		fmt.println("notified agent pane", line)
	} else {
		fmt.println("failed to notify agent pane", line)
	}
}

handle_memory_event :: proc(text, tmux_pane, agent_instance_id: string) {
	changed_by := extract_json_string(text, "changed_by", "unknown")
	if changed_by == agent_instance_id {
		fmt.println("suppressed self-authored memory event", extract_json_string(text, "memory_id", ""), changed_by)
		return
	}
	event := extract_json_string(text, "event", "memory_updated")
	memory_id := extract_json_string(text, "memory_id", "unknown")
	proposal_id := extract_json_string(text, "proposal_id", "")
	target := extract_json_string(text, "target", "")
	status := extract_json_string(text, "status", "")

	template_str := active_live_prefs.msg_memory_updated
	interrupt_val := active_live_prefs.msg_memory_updated_int
	target_id := memory_id

	if proposal_id != "" && (status == "pending" || strings.index(event, "Proposed") >= 0) {
		template_str = active_live_prefs.msg_memory_proposal_updated
		interrupt_val = active_live_prefs.msg_memory_proposal_updated_int
		target_id = proposal_id
	}

	line := template_live_message(
		template_str,
		0, "",
		"", "", changed_by, "", target_id, event, target, "", "", "", 0,
	)
	defer delete(line)

	if tmux.send_line_with_escape(tmux_pane, line, interrupt_val) {
		fmt.println("notified agent pane", line)
	} else {
		fmt.println("failed to notify agent pane", line)
	}
}

handle_user_chat_event :: proc(text, tmux_pane: string) {
	user_id := extract_json_string(text, "user_id", "unknown")
	pending_count := extract_json_int(text, "pending_count", 1)
	if pending_count <= 0 do pending_count = 1
	send_escape := extract_json_bool(text, "interrupt", false) || extract_json_bool(text, "send_escape_prefix", false)

	line := template_live_message(
		active_live_prefs.msg_user_chat,
		pending_count, "",
		"", "", "", "", "", "", "", user_id, "", "", 0,
	)
	defer delete(line)

	escape_prefix := send_escape || active_live_prefs.msg_user_chat_int
	if tmux.send_line_with_escape(tmux_pane, line, escape_prefix) {
		fmt.println("notified agent pane", line)
	} else {
		fmt.println("failed to notify agent pane", line)
	}
}

notify_agent_token_refreshed :: proc(tmux_pane, daemon_url, new_token, agent_instance_id: string) {
	line := template_live_message(
		active_live_prefs.msg_token_refreshed,
		0, "",
		"", "", "", "", "", "", "", "", new_token, daemon_url, 0,
	)
	defer delete(line)

	fmt.println("token_refreshed: notifying agent pane", tmux_pane)
	_ = tmux.send_line_with_escape(tmux_pane, line, active_live_prefs.msg_token_refreshed_int)
}

handle_stop_event :: proc(text, tmux_pane, tmux_session, window_name, agent_instance_id, stop_message: string, ws_conn: ^ws.Connection) {
	time_in_sec := extract_json_int(text, "time_in_sec", 30)
	
	line := template_live_message(
		active_live_prefs.msg_stop_requested,
		0, "",
		"", "", "", "", "", "", "", "", "", "", time_in_sec,
	)
	defer delete(line)

	fmt.println("stop: sending escape and message to pane", tmux_pane)
	_ = tmux.send_line_with_escape(tmux_pane, line, active_live_prefs.msg_stop_requested_int)
	fmt.println("stop: waiting", time_in_sec, "seconds")
	time.sleep(time.Duration(time_in_sec) * time.Second)
	fmt.println("stop: killing pane", tmux_pane)
	_ = tmux.kill_pane(tmux_pane)
	fmt.println("stop: killing window", tmux_session, window_name)
	_ = tmux.kill_window(tmux_session, window_name)
	fmt.println("stop: sending stop_done via WS")
	report_stop_done(ws_conn, agent_instance_id)
	fmt.println("stop: done, wrapper exiting")
}

report_stop_done :: proc(ws_conn: ^ws.Connection, agent_instance_id: string) {
	b := strings.builder_make()
	strings.write_string(&b, `{"type":"stop_done","agent_instance_id":"`)
	json_write_string(&b, agent_instance_id)
	strings.write_string(&b, `"}`)
	_ = ws.send_text(ws_conn, strings.to_string(b))
}

close_wrapper_after_auth_failure :: proc(agent_instance_id, reason, detail: string, ws_conn: ^ws.Connection) {
	fmt.println("AUTH FAILURE: closing wrapper", agent_instance_id, reason)
	if detail != "" do fmt.println("auth_failure_detail", detail)
	ws.close(ws_conn)
}

reregister_and_reconnect_ws :: proc(daemon_url, agent_class, agent_instance_id, display_name, agent_token: string, ws_conn: ^ws.Connection) -> (new_ws_url: string, new_token: string, terminal_auth_failure: bool, ok: bool) {
	response, health_ok := http.get(daemon_url, contracts.ROUTE_HEALTH)
	if !health_ok || response.status != 200 do return "", "", false, false

	register_body := register_request_json(agent_class, agent_instance_id, display_name, agent_token)
	register_response, register_ok := http.post(daemon_url, contracts.ROUTE_REGISTER, register_body)
	if !register_ok || register_response.status != 200 {
		if register_ok {
			fmt.println("re-registration failed", register_response.status, register_response.body)
			if register_response.status == 401 {
				fmt.println("fatal: re-registration unauthorized; wrapper will stop", agent_instance_id, register_response.body)
				return "", "", true, false
			}
		} else {
			fmt.println("re-registration request failed", agent_instance_id)
		}
		return "", "", false, false
	}

	ws_url := extract_json_string(register_response.body, "ws_url", "")
	token  := extract_json_string(register_response.body, "agent_token", agent_token)
	prefs_obj := extract_json_object(register_response.body, "preferences")
	defer if prefs_obj != "" do delete(prefs_obj)
	apply_preferences_json(prefs_obj)
	if ws_url == "" do return "", "", false, false

	ws.close(ws_conn)
	new_conn, ws_ok := ws.connect(ws_url)
	if !ws_ok do return ws_url, token, false, false
	ws_conn^ = new_conn
	return ws_url, token, false, true
}

heartbeat_request_json :: proc(agent_instance_id, agent_token, display_name, provider_profile, provider_tier, project_id, tmux_pane, run_dir, exec_state, blocked_reason, startup_status, startup_reason_code, startup_safe_diagnostic: string, activity: Activity_Status_Snapshot, pid: int, exec_state_since_unix_ms: i64) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"agent_instance_id":"`); json_write_string(&b, agent_instance_id)
	strings.write_string(&b, `","agent_token":"`); json_write_string(&b, agent_token)
	strings.write_string(&b, `","display_name":"`); json_write_string(&b, display_name)
	strings.write_string(&b, `","provider_profile":"`); json_write_string(&b, provider_profile)
	strings.write_string(&b, `","provider_tier":"`); json_write_string(&b, provider_tier)
	strings.write_string(&b, `","project_id":"`); json_write_string(&b, project_id)
	strings.write_string(&b, `","tmux_pane":"`); json_write_string(&b, tmux_pane)
	strings.write_string(&b, `","run_dir":"`); json_write_string(&b, run_dir)
	strings.write_string(&b, `","exec_state":"`); json_write_string(&b, exec_state)
	strings.write_string(&b, `","blocked_reason":"`); json_write_string(&b, blocked_reason)
	strings.write_string(&b, `","startup_status":"`); json_write_string(&b, startup_status)
	strings.write_string(&b, `","startup_reason_code":"`); json_write_string(&b, startup_reason_code)
	strings.write_string(&b, `","startup_safe_diagnostic":"`); json_write_string(&b, startup_safe_diagnostic)
	strings.write_string(&b, `","activity_status":"`); json_write_string(&b, activity.status)
	strings.write_string(&b, `","activity_source":"`); json_write_string(&b, activity.source)
	strings.write_string(&b, `","activity_checked_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", activity.checked_unix_ms))
	strings.write_string(&b, `,"pid":`); strings.write_string(&b, fmt.tprintf("%d", pid))
	strings.write_string(&b, `,"exec_state_since_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", exec_state_since_unix_ms))
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

// log_heartbeat_corrections prints any fields the daemon corrected. For now we
// only log — applying corrections to running wrapper state is deferred.
log_heartbeat_corrections :: proc(body, agent_instance_id: string) {
	idx := strings.index(body, `"corrections":{`)
	if idx < 0 do return
	start := idx + len(`"corrections":{`)
	end := strings.index_byte(body[start:], '}')
	if end <= 0 do return
	contents := body[start:start + end]
	if strings.trim_space(contents) == "" do return
	fmt.println("heartbeat corrections", agent_instance_id, contents)
}

extract_json_string :: proc(body, key, fallback: string) -> string {
	pattern := fmt.tprintf("\"%s\":\"", key)
	idx := strings.index(body, pattern)
	if idx < 0 do return fallback

	start := idx + len(pattern)
	end := start
	escaped := false
	for end < len(body) {
		ch := body[end]
		if escaped {
			escaped = false
		} else if ch == '\\' {
			escaped = true
		} else if ch == '"' {
			return json_unescape(body[start:end])
		}
		end += 1
	}

	return fallback
}

json_unescape :: proc(value: string) -> string {
	builder := strings.builder_make()
	i := 0
	for i < len(value) {
		ch := value[i]
		if ch == '\\' {
			if i + 1 < len(value) {
				next_ch := value[i + 1]
				switch next_ch {
				case 'n': strings.write_byte(&builder, '\n')
				case 'r': strings.write_byte(&builder, '\r')
				case 't': strings.write_byte(&builder, '\t')
				case '"': strings.write_byte(&builder, '"')
				case '\\': strings.write_byte(&builder, '\\')
				case 'u':
					if i + 5 < len(value) {
						hex_str := value[i + 2 : i + 6]
						val, ok := strconv.parse_int(hex_str, 16)
						if ok {
							strings.write_rune(&builder, rune(val))
							i += 6
							continue
						}
					}
					strings.write_byte(&builder, 'u')
				case:
					strings.write_byte(&builder, next_ch)
				}
				i += 2
			} else {
				strings.write_byte(&builder, '\\')
				i += 1
			}
		} else {
			strings.write_byte(&builder, ch)
			i += 1
		}
	}
	return strings.to_string(builder)
}

json_write_string :: proc(builder: ^strings.Builder, value: string) {
	for ch in value {
		switch ch {
		case '\\': strings.write_string(builder, "\\\\")
		case '"': strings.write_string(builder, "\\\"")
		case '\n': strings.write_string(builder, "\\n")
		case '\r': strings.write_string(builder, "\\r")
		case '\t': strings.write_string(builder, "\\t")
		case: strings.write_rune(builder, ch)
		}
	}
}

extract_json_int :: proc(body, key: string, fallback: int) -> int {
	pattern := fmt.tprintf("\"%s\":", key)
	idx := strings.index(body, pattern)
	if idx < 0 do return fallback
	start := idx + len(pattern)
	end := start
	for end < len(body) {
		ch := body[end]
		if ch < '0' || ch > '9' do break
		end += 1
	}
	if end == start do return fallback
	parsed, ok := strconv.parse_int(body[start:end])
	if !ok do return fallback
	return int(parsed)
}

extract_json_bool :: proc(body, key: string, fallback: bool) -> bool {
	pattern := fmt.tprintf("\"%s\":", key)
	idx := strings.index(body, pattern)
	if idx < 0 do return fallback
	start := idx + len(pattern)
	val_str := strings.trim_space(body[start:])
	if strings.has_prefix(val_str, "true") do return true
	if strings.has_prefix(val_str, "false") do return false
	return fallback
}

start_detached :: proc(args: []string) {
	child_args := make([dynamic]string)
	append(&child_args, args[0])
	for i := 1; i < len(args); i += 1 {
		if args[i] == "--detach" do continue
		append(&child_args, args[i])
	}

	process, err := os.process_start(os.Process_Desc{command = child_args[:]})
	if err != nil {
		fmt.println("failed to detach wrapper")
		return
	}
	fmt.println("detached ham-wrapper pid", process.handle)
}

has_flag :: proc(args: []string, flag: string) -> bool {
	for arg in args {
		if arg == flag do return true
	}
	return false
}

print_usage :: proc() {
	fmt.println("ham-wrapper", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION)
	fmt.println("usage: ham-wrapper [--config <path>] [--agent <name>] [--agent-token <token>] [--project-id <id>] [--current-task-id <id>] [--detach] [--version] [--help] [agent|agent@suffix]")
}

resolve_working_dir :: proc(path: string) -> string {
	expanded := cfg_lib.expand_home(path)
	absolute, err := os.get_absolute_path(expanded, context.allocator)
	if err != nil do return expanded
	return absolute
}

selected_agent_command :: proc(cfg: cfg_lib.Wrapper_Config, selected_agent: string) -> (cfg_lib.Agent_Command_Config, bool) {
	name := selected_agent
	if name == "" do name = command_name_for_agent(cfg.command, cfg.agent_name)
	for agent_cmd in cfg.agent_commands {
		if agent_cmd.name == name do return agent_cmd, true
	}
	return cfg_lib.Agent_Command_Config{}, false
}

resolve_agent_run_dir :: proc(cfg: cfg_lib.Wrapper_Config, agent_cmd: cfg_lib.Agent_Command_Config, agent_cmd_ok: bool, selected_agent, agent_instance_id: string) -> string {
	root := cfg.agent_run_dir
	if agent_cmd_ok && agent_cmd.agent_run_dir != "" do root = agent_cmd.agent_run_dir
	if root == "" do return resolve_working_dir(".")

	project := cfg.project
	if agent_cmd_ok && agent_cmd.project != "" do project = agent_cmd.project
	if project == "" do project = "default"

	agent_name := agent_instance_id
	if agent_name == "" do agent_name = selected_agent
	if agent_name == "" do agent_name = cfg.agent_name

	base := resolve_working_dir(root)
	project_dir := join_path(base, safe_slug(project))
	_ = os.make_directory_all(project_dir)

	use_random_dir := cfg.use_random_dir
	if agent_cmd_ok && agent_cmd.use_random_dir_set do use_random_dir = agent_cmd.use_random_dir
	if use_random_dir {
		for attempt in 0..<16 {
			name := random_run_dir_name()
			cwd := join_path(project_dir, name)
			if !os.exists(cwd) {
				_ = os.make_directory_all(cwd)
				return cwd
			}
			_ = attempt
		}
	}

	ts := time.to_unix_nanoseconds(time.now()) / 1_000_000
	agent_name_with_ts := fmt.tprintf("%s-%d", agent_name, ts)
	cwd := join_path(project_dir, safe_slug(agent_name_with_ts))
	_ = os.make_directory_all(cwd)
	return cwd
}

random_run_dir_name :: proc() -> string {
	bytes: [8]byte
	if rand.read(bytes[:]) != len(bytes) {
		now := u64(time.to_unix_nanoseconds(time.now()))
		for i in 0..<len(bytes) {
			bytes[i] = byte((now >> uint((i % 8) * 8)) & 0xff)
		}
	}
	builder := strings.builder_make()
	strings.write_string(&builder, "run-")
	for b in bytes do hex_write_byte(&builder, b)
	return strings.to_string(builder)
}

hex_write_byte :: proc(builder: ^strings.Builder, b: byte) {
	digits := "0123456789abcdef"
	strings.write_byte(builder, digits[int((b >> 4) & 0x0f)])
	strings.write_byte(builder, digits[int(b & 0x0f)])
}

join_path3 :: proc(a, b, c: string) -> string {
	sep := "/"
	left := a
	if strings.has_suffix(left, "/") do sep = ""
	return strings.concatenate({left, sep, b, "/", c})
}

safe_slug :: proc(value: string) -> string {
	builder := strings.builder_make()
	last_dash := false
	for i in 0..<len(value) {
		ch := value[i]
		valid := (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')
		if valid {
			strings.write_byte(&builder, ch)
			last_dash = false
		} else if !last_dash {
			strings.write_byte(&builder, '-')
			last_dash = true
		}
	}
	slug := strings.to_string(builder)
	slug = strings.trim(slug, "-")
	if slug == "" do return "unnamed"
	if slug == "." || slug == ".." do return "unnamed"
	return slug
}

BOOTSTRAP_HEADER :: "<!-- HEIMDALL-MANAGED-BOOTSTRAP v1: safe to overwrite -->"
BOOTSTRAP_MANIFEST :: ".heimdall-bootstrap-manifest"

Memory_Record :: struct {
	memory_id:             string,
	type_text:             string,
	title:                 string,
	body:                  string,
	target:                string,
	is_configured_template: bool,
}

fetch_all_active_memories :: proc(daemon_url, agent_token, team_kind, project_id, role_key: string, memory_templates: []string) -> [dynamic]Memory_Record {
	result := make([dynamic]Memory_Record)
	if agent_token == "" do return result

	req := strings.builder_make()
	strings.write_string(&req, `{"agent_token":"`); json_write_string(&req, agent_token); strings.write_string(&req, `"`)
	if team_kind != "" { strings.write_string(&req, `,"target_team_kind":"`); json_write_string(&req, team_kind); strings.write_string(&req, `"`) }
	if project_id != "" { strings.write_string(&req, `,"target_project_id":"`); json_write_string(&req, project_id); strings.write_string(&req, `"`) }
	if role_key != "" { strings.write_string(&req, `,"target_role":"`); json_write_string(&req, role_key); strings.write_string(&req, `"`) }
	strings.write_string(&req, `}`)
	resp, ok := http.post(daemon_url, "/memory/applicable", strings.to_string(req))
	if ok && resp.status == 200 {
		parse_into_memory_records(resp.body, memory_templates, &result)
	}

	return result
}

parse_into_memory_records :: proc(body: string, memory_templates: []string, result: ^[dynamic]Memory_Record) {
	idx := 0
	for {
		start_rel := strings.index(body[idx:], `{"memory_id":"`)
		if start_rel < 0 do break
		start := idx + start_rel
		end := json_object_end(body, start)
		if end <= start do break
		object := body[start:end]

		status := extract_json_string(object, "status", "")
		if status != "active" { idx = end; continue }

		type_text := extract_json_string(object, "type", "fact")
		memory_id := extract_json_string(object, "memory_id", "")
		title := extract_json_string(object, "title", "")
		body_text := extract_json_string(object, "body", "")
		target := extract_json_string(object, "target", "")
		is_configured_template := type_text == "template" && memory_template_matches(object, memory_templates)
		append(result, Memory_Record{memory_id = memory_id, type_text = type_text, title = title, body = body_text, target = target, is_configured_template = is_configured_template})
		idx = end
	}
}

generate_bootstrap_files :: proc(cwd, config_path: string, cfg: cfg_lib.Wrapper_Config, agent_cmd: cfg_lib.Agent_Command_Config, selected_agent, agent_instance_id, display_name, daemon_url, agent_token, current_task_id, template_persona, template_instructions, team_id, role_key: string, role_index: int) {
	profile := bootstrap_profile(agent_cmd, selected_agent)
	memory_templates := agent_cmd.memory_templates
	if len(memory_templates) == 0 do memory_templates = cfg.memory_templates
	project_id := agent_cmd.project
	if project_id == "" do project_id = cfg.project
	project_context := project_bootstrap_context(daemon_url, agent_token, cfg, agent_cmd)
	team_context, chain_id, team_kind := team_bootstrap_context(daemon_url, team_id)
	chain_context, workspace_context := task_chain_bootstrap_context(daemon_url, agent_token, chain_id)
	memories := fetch_all_active_memories(daemon_url, agent_token, team_kind, project_id, role_key, memory_templates)

	written := make([dynamic]string)

	// AGENTS_MD (CLAUDE.md for claude profile, AGENTS.md otherwise)
	{
		fc := agent_cmd.bootstrap.features["AGENTS_MD"]
		name := fc.name
		if name == "" {
			if profile == "claude" { name = "CLAUDE.md" } else { name = "AGENTS.md" }
		}
		path := join_path(cwd, name)
		if can_write_managed_file(path) {
			text := build_agents_md(name, profile, selected_agent, agent_instance_id, display_name, daemon_url, agent_token, config_path, memories[:], project_context, chain_context, team_context, workspace_context, has_reference_memories(memories[:]), current_task_id, template_persona, template_instructions, team_id, role_key, role_index)
			write_managed_file(path, text)
			append(&written, name)
		}
	}

	// MEMORY_MD only when Fact/Episode references exist.
	if has_reference_memories(memories[:]) {
		fc := agent_cmd.bootstrap.features["MEMORY_MD"]
		name := fc.name
		if name == "" do name = "MEMORY.md"
		path := join_path(cwd, name)
		if can_write_managed_file(path) {
			text := build_memory_md(memories[:])
			write_managed_file(path, text)
			append(&written, name)
		}
	}

	// SKILLS
	{
		fc := agent_cmd.bootstrap.features["SKILLS"]
		rel_dir := fc.relative_dir
		if rel_dir == "" do rel_dir = "skills"
		filename := fc.filename
		if filename == "" do filename = "SKILL.md"
		skill_paths := write_skills(cwd, rel_dir, filename, memories[:])
		for p in skill_paths {
			append(&written, p)
		}
	}

	// Guide-only product handbook. This is intentionally a concrete file in the
	// guide run directory so the singleton guide can read stable Heimdall-specific
	// operating guidance without giving that context to ordinary project agents.
	if agent_instance_id == "guide@heimdall" {
		name := "guide-agent.md"
		path := join_path(cwd, name)
		if can_write_managed_file(path) {
			write_managed_file(path, strings.trim_space(#load("../prompts/guide-agent.md", string)))
			append(&written, name)
		}
	}

	cleanup_removed_bootstrap_files(cwd, written[:])
	write_manifest(cwd, written[:])
}

team_bootstrap_context :: proc(daemon_url, team_id: string) -> (string, string, string) {
	if team_id == "" do return "", "", ""
	response, ok := http.get(daemon_url, fmt.tprintf("/teams/%s", team_id))
	if !ok || response.status != 200 do return "", "", ""
	chain_id := extract_json_string(response.body, "chain_id", "")
	team_kind := extract_json_string(response.body, "kind", "")
	b := strings.builder_make()
	strings.write_string(&b, "- team_id: "); strings.write_string(&b, extract_json_string(response.body, "team_id", team_id)); strings.write_string(&b, "\n")
	strings.write_string(&b, "- kind: "); strings.write_string(&b, team_kind); strings.write_string(&b, "\n")
	strings.write_string(&b, "- status: "); strings.write_string(&b, extract_json_string(response.body, "status", "")); strings.write_string(&b, "\n")
	strings.write_string(&b, "- Roster:\n")
	idx := 0
	for {
		start_rel := strings.index(response.body[idx:], `{"team_id":"`)
		if start_rel < 0 do break
		start := idx + start_rel
		end := json_object_end(response.body, start)
		if end <= start do break
		object := response.body[start:end]
		if extract_json_string(object, "role_key", "") != "" {
			strings.write_string(&b, "  - "); strings.write_string(&b, extract_json_string(object, "role_key", ""))
			strings.write_string(&b, "["); strings.write_string(&b, fmt.tprintf("%d", extract_json_int(object, "role_index", 0))); strings.write_string(&b, "] ")
			strings.write_string(&b, extract_json_string(object, "lifecycle_status", "idle")); strings.write_string(&b, "\n")
		}
		idx = end
	}
	return strings.to_string(b), chain_id, team_kind
}

task_chain_bootstrap_context :: proc(daemon_url, agent_token, chain_id: string) -> (string, string) {
	if chain_id == "" do return "", ""
	body := strings.builder_make()
	strings.write_string(&body, `{"agent_token":"`); json_write_string(&body, agent_token)
	strings.write_string(&body, `","chain_id":"`); json_write_string(&body, chain_id)
	strings.write_string(&body, `"}`)
	response, ok := http.post(daemon_url, "/task-chains/show", strings.to_string(body))
	if !ok || response.status != 200 do return "", ""
	b := strings.builder_make()
	strings.write_string(&b, "- chain_id: "); strings.write_string(&b, extract_json_string(response.body, "chain_id", chain_id)); strings.write_string(&b, "\n")
	strings.write_string(&b, "- title: "); strings.write_string(&b, extract_json_string(response.body, "title", "")); strings.write_string(&b, "\n")
	strings.write_string(&b, "- description: "); strings.write_string(&b, extract_json_string(response.body, "description", "")); strings.write_string(&b, "\n")
	strings.write_string(&b, "- coordinator: "); strings.write_string(&b, extract_json_string(response.body, "coordinator_agent_instance_id", "")); strings.write_string(&b, "\n")
	strings.write_string(&b, "- default_reviewer: "); strings.write_string(&b, extract_json_string(response.body, "default_reviewer_agent_instance_id", "")); strings.write_string(&b, "\n")
	tasks_response, tasks_ok := http.get(daemon_url, fmt.tprintf("/task-chains/%s/tasks", chain_id))
	if tasks_ok && tasks_response.status == 200 {
		strings.write_string(&b, "- Task counts: planning="); strings.write_string(&b, fmt.tprintf("%d", count_json_status(tasks_response.body, "planning")))
		strings.write_string(&b, " ready="); strings.write_string(&b, fmt.tprintf("%d", count_json_status(tasks_response.body, "queued") + count_json_status(tasks_response.body, "ready")))
		strings.write_string(&b, " in-progress="); strings.write_string(&b, fmt.tprintf("%d", count_json_status(tasks_response.body, "in_progress")))
		strings.write_string(&b, " review-ready="); strings.write_string(&b, fmt.tprintf("%d", count_json_status(tasks_response.body, "review_ready")))
		strings.write_string(&b, " done="); strings.write_string(&b, fmt.tprintf("%d", count_json_status(tasks_response.body, "approved") + count_json_status(tasks_response.body, "completed")))
		strings.write_string(&b, "\n")
	}
	return strings.to_string(b), workspace_bootstrap_context(response.body)
}

workspace_bootstrap_context :: proc(chain_body: string) -> string {
	workspace_id := extract_json_string(chain_body, "vcs_workspace_id", "")
	if workspace_id == "" do return ""
	b := strings.builder_make()
	strings.write_string(&b, "- workspace_id: "); strings.write_string(&b, workspace_id); strings.write_string(&b, "\n")
	strings.write_string(&b, "- path: "); strings.write_string(&b, extract_json_string(chain_body, "path", "")); strings.write_string(&b, "\n")
	strings.write_string(&b, "- vcs_kind: "); strings.write_string(&b, extract_json_string(chain_body, "vcs_kind", "")); strings.write_string(&b, "\n")
	strings.write_string(&b, "- branch_or_change: "); strings.write_string(&b, extract_json_string(chain_body, "branch_or_change", "")); strings.write_string(&b, "\n")
	strings.write_string(&b, "- base_ref: "); strings.write_string(&b, extract_json_string(chain_body, "base_ref", "")); strings.write_string(&b, "\n")
	strings.write_string(&b, "- Do not cd outside this workspace. Do not push; merge is user-approved. Use `ham-ctl workspace pull` to sync base.\n")
	return strings.to_string(b)
}

count_json_status :: proc(body, status: string) -> int {
	count := 0
	needle := fmt.tprintf(`"status":"%s"`, status)
	idx := 0
	for {
		rel := strings.index(body[idx:], needle)
		if rel < 0 do break
		count += 1
		idx += rel + len(needle)
	}
	return count
}

content_section_enabled :: proc(sections: []string, section: string) -> bool {
	if len(sections) == 0 do return true
	for item in sections {
		if item == section || item == "ALL" || item == "all" do return true
	}
	return false
}

build_agents_md :: proc(name, profile: string, selected_agent, agent_instance_id, display_name, daemon_url, agent_token, config_path: string, memories: []Memory_Record, project_context, chain_context, team_context, workspace_context: string, has_memory_md: bool, current_task_id, template_persona, template_instructions, team_id, role_key: string, role_index: int) -> string {
	b := strings.builder_make()
	is_team_member := team_id != "" || role_key != ""
	is_coordinator := !is_team_member || role_key == "coordinator"
	strings.write_string(&b, active_live_prefs.bootstrap_header); strings.write_string(&b, "\n")
	strings.write_string(&b, bootstrap_title(name, profile)); strings.write_string(&b, "\n\n")

	strings.write_string(&b, "# You\n")
	strings.write_string(&b, "- display_name: "); strings.write_string(&b, display_name); strings.write_string(&b, "\n")
	strings.write_string(&b, "- agent_instance_id: "); strings.write_string(&b, agent_instance_id); strings.write_string(&b, "\n")
	if role_key != "" { strings.write_string(&b, "- role_key: "); strings.write_string(&b, role_key); strings.write_string(&b, "\n") }
	strings.write_string(&b, "- role_index: "); strings.write_string(&b, fmt.tprintf("%d", role_index)); strings.write_string(&b, "\n")
	strings.write_string(&b, "- provider/profile: "); strings.write_string(&b, selected_agent); strings.write_string(&b, " / "); strings.write_string(&b, profile); strings.write_string(&b, "\n")
	strings.write_string(&b, "- agent_token: "); strings.write_string(&b, agent_token); strings.write_string(&b, "\n")
	strings.write_string(&b, "- start-success: `"); strings.write_string(&b, effective_ctl_bin()); strings.write_string(&b, " --daemon-url "); strings.write_string(&b, daemon_url); strings.write_string(&b, " --token "); strings.write_string(&b, agent_token); strings.write_string(&b, " start-success`\n")
	if agent_instance_id == "guide@heimdall" {
		strings.write_string(&b, "- guide handbook: read `guide-agent.md` after start-success; it is the guide-only Heimdall product/runbook context.\n")
	}
	strings.write_string(&b, "\n")

	strings.write_string(&b, "# Project\n")
	if project_context != "" { strings.write_string(&b, project_context); strings.write_string(&b, "\n") } else { strings.write_string(&b, "- project_id: unknown\n- VCS bindings: none\n\n") }

	strings.write_string(&b, "# Task Chain\n")
	if chain_context != "" { strings.write_string(&b, chain_context) } else { strings.write_string(&b, "- chain_id: unknown\n") }
	if current_task_id != "" {
		strings.write_string(&b, "- Current task: `")
		strings.write_string(&b, current_task_id)
		strings.write_string(&b, "` (already auto-claimed for this launch). After `start-success`, inspect it with `")
		strings.write_string(&b, effective_ctl_bin())
		strings.write_string(&b, " tasks show --token <token> --task-id ")
		strings.write_string(&b, current_task_id)
		strings.write_string(&b, "` and begin work. Use `")
		strings.write_string(&b, effective_ctl_bin())
		strings.write_string(&b, " tasks next --token <token>` if you need to claim/resume assigned work from task state.\n")
	} else {
		strings.write_string(&b, "- Current task: use `ham-ctl tasks next --token <token>` to claim assigned work.\n")
	}
	strings.write_string(&b, "\n")

	strings.write_string(&b, "# Team\n")
	if team_context != "" { strings.write_string(&b, team_context) } else if team_id != "" { strings.write_string(&b, "- team_id: "); strings.write_string(&b, team_id); strings.write_string(&b, "\n") }
	if is_coordinator {
		strings.write_string(&b, "- You are the coordinator for free-form user contact: summarize/forward team needs to the operator when needed.\n")
		strings.write_string(&b, "- Use chain-scoped user replies (`chat send-to-user --chain-id <chain_id>`) when the reply belongs to a task chain, so it appears in coordinator chat and direct chat.\n")
		strings.write_string(&b, "- Team members route user-facing decisions through you; consolidate, resolve locally when possible, and ask the user only when necessary.\n")
	} else {
		strings.write_string(&b, "- Coordinator owns user-facing decisions; route free-form user communication through the coordinator.\n")
		strings.write_string(&b, "- Do not use direct `chat send-to-user` for normal user contact. Use task comments or coordinator-directed chat instead; chain-context sends are redirected to the coordinator, not the user.\n")
	}
	strings.write_string(&b, "- Structured Needs attention prompts remain allowed for product-modeled approvals/actions such as user_proxy review and merge decisions.\n")
	strings.write_string(&b, "- Agents shut down after 30 minutes idle unless task, mention, or nudge keeps them alive.\n\n")

	// Base operating rules shared by every agent (task management, REQ-IDs,
	// routing table, CLI cheatsheet). Sourced from prompts/bootstrap_profile_guidance.md.
	strings.write_string(&b, "# Agent Operating Rules\n")
	strings.write_string(&b, strings.trim_space(#load("../prompts/bootstrap_profile_guidance.md", string)))
	strings.write_string(&b, "\n\n")

	if is_coordinator {
		strings.write_string(&b, "# Coordinator Instructions\n")
		strings.write_string(&b, strings.trim_space(#load("../prompts/coordinator_instructions.md", string)))
		strings.write_string(&b, "\n\n")
	}

	// Role persona + instructions come from the agent template stored in the
	// daemon DB (planner/coder/reviewer/tester/specialist/etc.). Emitting them
	// here makes them visible inside AGENTS.md alongside the shared rules and
	// keeps the whole agent context reproducible from the run directory.
	if tp := strings.trim_space(template_persona); tp != "" {
		strings.write_string(&b, "# Role Persona\n")
		strings.write_string(&b, tp)
		strings.write_string(&b, "\n\n")
	}
	if ti := strings.trim_space(template_instructions); ti != "" {
		strings.write_string(&b, "# Role Instructions\n")
		strings.write_string(&b, ti)
		strings.write_string(&b, "\n\n")
	}

	if workspace_context != "" {
		strings.write_string(&b, "# Workspace\n")
		strings.write_string(&b, workspace_context)
		strings.write_string(&b, "\n")
	}

	mem_str := render_memory_for_agents_md(memories, has_memory_md)
	if mem_str != "" {
		strings.write_string(&b, "# Memory\nOnly active approved memory is included. Pending/rejected/archived are excluded.\n")
		strings.write_string(&b, mem_str)
		strings.write_string(&b, "\n")
	}

	strings.write_string(&b, "# Tools\n")
	strings.write_string(&b, "- `ham-ctl tasks next|show|comment|done --token <token>` for task work.\n")
	if is_coordinator {
		strings.write_string(&b, "- `ham-ctl chat send-to-user --token <token> --user-id operator@local --chain-id <chain_id> --body <text>` for coordinator-owned chain replies.\n")
	} else {
		strings.write_string(&b, "- For user-facing questions, comment/nudge the coordinator; the coordinator owns free-form user replies.\n")
	}
	strings.write_string(&b, "- Structured Needs attention approval/action prompts are allowed when the product models them durably.\n")
	strings.write_string(&b, "- `ham-ctl teams show --team <team_id>` and `ham-ctl chains focus --chain <chain_id>` for team context.\n")
	strings.write_string(&b, "- Full workflow guide: `ham-ctl help work-guide`.\n")
	return strings.to_string(b)
}

has_reference_memories :: proc(memories: []Memory_Record) -> bool {
	for m in memories {
		if m.type_text == "fact" || m.type_text == "episode" do return true
	}
	return false
}

render_memory_for_agents_md :: proc(memories: []Memory_Record, has_memory_md: bool) -> string {
	b := strings.builder_make()

	// Configured template memories
	wrote_tpl := false
	for m in memories {
		if !m.is_configured_template do continue
		if !wrote_tpl {
			strings.write_string(&b, "\n\n# Active Approved Memory Templates\nOnly configured, approved active template memories are included here; pending, rejected, and archived templates are excluded.\n")
			wrote_tpl = true
		}
		strings.write_string(&b, "\n- template: ")
		if m.title != "" { strings.write_string(&b, m.title); strings.write_string(&b, " — ") }
		strings.write_string(&b, m.body); strings.write_string(&b, "\n")
	}

	// Active memory section — inline types (EXPERTISE, HABIT) and reference types (FACT, EPISODE)
	wrote_active := false

	inline_types := []string{"expertise", "habit"}
	for type_name in inline_types {
		for m in memories {
			if m.is_configured_template do continue
			if m.type_text != type_name do continue
			if !wrote_active {
				strings.write_string(&b, "\n\n# Active Approved Memory\nOnly active approved memory is included here; pending, rejected, and archived proposals are excluded.\n")
				wrote_active = true
			}
			strings.write_string(&b, "\n- "); strings.write_string(&b, type_name); strings.write_string(&b, ": ")
			if m.title != "" { strings.write_string(&b, m.title); strings.write_string(&b, " — ") }
			strings.write_string(&b, m.body); strings.write_string(&b, "\n")
		}
	}

	ref_types := []string{"fact", "episode"}
	for type_name in ref_types {
		for m in memories {
			if m.is_configured_template do continue
			if m.type_text != type_name do continue
			if !wrote_active {
				strings.write_string(&b, "\n\n# Active Approved Memory\nOnly active approved memory is included here; pending, rejected, and archived proposals are excluded.\n")
				wrote_active = true
			}
			if has_memory_md {
				slug := safe_slug(m.title)
				strings.write_string(&b, "\n- "); strings.write_string(&b, type_name); strings.write_string(&b, ": ")
				strings.write_string(&b, m.title)
				strings.write_string(&b, " — see [MEMORY.md#"); strings.write_string(&b, slug)
				strings.write_string(&b, "](MEMORY.md#"); strings.write_string(&b, slug); strings.write_string(&b, ")\n")
			} else {
				strings.write_string(&b, "\n- "); strings.write_string(&b, type_name); strings.write_string(&b, ": ")
				if m.title != "" { strings.write_string(&b, m.title); strings.write_string(&b, " — ") }
				strings.write_string(&b, m.body); strings.write_string(&b, "\n")
			}
		}
	}

	if !wrote_tpl && !wrote_active do return ""
	return strings.to_string(b)
}

build_memory_md :: proc(memories: []Memory_Record) -> string {
	b := strings.builder_make()
	strings.write_string(&b, active_live_prefs.bootstrap_header); strings.write_string(&b, "\n")
	strings.write_string(&b, "# Memory\n\n")
	strings.write_string(&b, "Full bodies of FACT and EPISODE memories. Regenerated each agent start.\n")
	wrote_any := false
	for m in memories {
		if m.type_text != "fact" && m.type_text != "episode" do continue
		if m.is_configured_template do continue
		slug := safe_slug(m.title)
		strings.write_string(&b, "\n## "); strings.write_string(&b, m.title)
		strings.write_string(&b, " {#"); strings.write_string(&b, slug); strings.write_string(&b, "}\n\n")
		strings.write_string(&b, m.body); strings.write_string(&b, "\n")
		wrote_any = true
	}
	if !wrote_any {
		strings.write_string(&b, "\n_(No fact or episode memories active.)_\n")
	}
	return strings.to_string(b)
}

write_skills :: proc(cwd, rel_dir, filename: string, memories: []Memory_Record) -> []string {
	written := make([dynamic]string)
	for m in memories {
		if m.type_text != "skill" do continue
		slug := safe_slug(m.title)
		skill_dir_rel := join_path(rel_dir, slug)
		skill_dir_abs := join_path(cwd, skill_dir_rel)
		_ = os.make_directory_all(skill_dir_abs)
		file_rel := join_path(skill_dir_rel, filename)
		file_abs := join_path(skill_dir_abs, filename)
		if can_write_managed_file(file_abs) {
			content := render_skill_file(slug, m.title, m.body)
			write_managed_file(file_abs, content)
			append(&written, file_rel)
		}
	}
	return written[:]
}

// render_skill_file produces a Claude Code / codex compatible SKILL.md.
//
// The first line must be `---` (YAML frontmatter start) so provider skill
// discovery can parse `name:` and `description:` from the header. Two shapes of
// memory body are supported:
//
//   1. Body already carries a `---`-delimited frontmatter block. We copy it
//      verbatim after guaranteeing `heimdall_managed: true` is present inside
//      the block so ownership can be detected on the next boot.
//   2. Body is a mix of `key: value` lines and free markdown. We split the
//      leading `key: value` lines into the frontmatter and the rest into the
//      body. Missing `name`/`description` are backfilled from the memory's
//      slug/title so the file is always valid.
render_skill_file :: proc(slug, title, body: string) -> string {
	trimmed := strings.trim_space(body)
	if strings.has_prefix(trimmed, "---\n") || strings.has_prefix(trimmed, "---\r\n") {
		after := trimmed[4:] if strings.has_prefix(trimmed, "---\n") else trimmed[5:]
		close_rel := strings.index(after, "\n---")
		if close_rel >= 0 {
			front := after[:close_rel]
			rest := after[close_rel+len("\n---"):]
			return build_skill_file(front, rest, slug, title, /*already_frontmatter*/ true)
		}
	}
	front, rest := split_leading_yaml_lines(trimmed)
	return build_skill_file(front, rest, slug, title, /*already_frontmatter*/ false)
}

split_leading_yaml_lines :: proc(text: string) -> (front: string, rest: string) {
	lines := strings.split(text, "\n")
	defer delete(lines)
	split_idx := 0
	for i in 0..<len(lines) {
		line := strings.trim_right(lines[i], "\r")
		if line == "" {
			split_idx = i + 1
			break
		}
		colon := strings.index(line, ":")
		if colon <= 0 {
			break
		}
		key := strings.trim_space(line[:colon])
		if !skill_yaml_key_valid(key) do break
		split_idx = i + 1
	}
	if split_idx == 0 {
		return "", text
	}
	fb := strings.builder_make()
	for i in 0..<split_idx {
		line := strings.trim_right(lines[i], "\r")
		if line == "" do continue
		strings.write_string(&fb, line); strings.write_string(&fb, "\n")
	}
	rb := strings.builder_make()
	for i in split_idx..<len(lines) {
		if i > split_idx do strings.write_string(&rb, "\n")
		strings.write_string(&rb, lines[i])
	}
	return strings.to_string(fb), strings.to_string(rb)
}

skill_yaml_key_valid :: proc(key: string) -> bool {
	if key == "" do return false
	for i in 0..<len(key) {
		ch := key[i]
		valid := (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '-' || ch == '_'
		if !valid do return false
	}
	return true
}

skill_yaml_get :: proc(front, key: string) -> string {
	lines := strings.split(front, "\n")
	defer delete(lines)
	for line in lines {
		trimmed := strings.trim_right(strings.trim_left(line, " \t"), "\r")
		colon := strings.index(trimmed, ":")
		if colon <= 0 do continue
		if strings.trim_space(trimmed[:colon]) != key do continue
		return strings.trim_space(trimmed[colon+1:])
	}
	return ""
}

skill_yaml_has :: proc(front, key: string) -> bool {
	return skill_yaml_get(front, key) != ""
}

build_skill_file :: proc(front, rest, slug, title: string, already_frontmatter: bool) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "---\n")
	if !skill_yaml_has(front, "name") {
		strings.write_string(&b, "name: "); strings.write_string(&b, slug); strings.write_string(&b, "\n")
	}
	if !skill_yaml_has(front, "description") {
		strings.write_string(&b, "description: "); strings.write_string(&b, yaml_scalar_line(title)); strings.write_string(&b, "\n")
	}
	front_trimmed := strings.trim_space(front)
	if front_trimmed != "" {
		strings.write_string(&b, front_trimmed); strings.write_string(&b, "\n")
	}
	if !strings.contains(front, MANAGED_YAML_MARKER) {
		strings.write_string(&b, MANAGED_YAML_MARKER); strings.write_string(&b, "\n")
	}
	strings.write_string(&b, "---\n")
	body := strings.trim_left(rest, "\n\r")
	if body != "" {
		strings.write_string(&b, "\n"); strings.write_string(&b, body)
		if !strings.has_suffix(body, "\n") do strings.write_string(&b, "\n")
	}
	return strings.to_string(b)
}

// yaml_scalar_line makes a single-line YAML scalar safe: it collapses embedded
// newlines to spaces so an accidental multi-line title cannot break the header.
yaml_scalar_line :: proc(value: string) -> string {
	flat := replace_all(value, "\r\n", " ")
	flat = replace_all(flat, "\n", " ")
	return strings.trim_space(flat)
}

cleanup_removed_bootstrap_files :: proc(cwd: string, files: []string) {
	manifest_path := join_path(cwd, BOOTSTRAP_MANIFEST)
	data, err := os.read_entire_file(manifest_path, context.allocator)
	if err != nil do return
	lines := strings.split(string(data), "\n")
	for line in lines {
		name := strings.trim_space(line)
		if name == "" || name == BOOTSTRAP_HEADER do continue
		if !safe_relative_path(name) do continue
		keep := false
		for file_name in files {
			if file_name == name { keep = true; break }
		}
		if keep do continue
		path := join_path(cwd, name)
		if file_has_managed_header(path) {
			_ = os.remove(path)
		}
	}
}

write_manifest :: proc(cwd: string, files: []string) {
	builder := strings.builder_make()
	strings.write_string(&builder, active_live_prefs.bootstrap_header); strings.write_string(&builder, "\n")
	for file_name in files {
		if safe_relative_path(file_name) {
			strings.write_string(&builder, file_name); strings.write_string(&builder, "\n")
		}
	}
	write_managed_file(join_path(cwd, BOOTSTRAP_MANIFEST), strings.to_string(builder))
}

can_write_managed_file :: proc(path: string) -> bool {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return true
	return data_has_managed_marker(string(data))
}

file_has_managed_header :: proc(path: string) -> bool {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return false
	return data_has_managed_marker(string(data))
}

// data_has_managed_marker recognises files this wrapper owns.
// The classic marker is the HTML comment header used on plain markdown outputs.
// Skill files must start with a YAML frontmatter block for Claude Code / codex
// skill discovery to work, so they instead carry `heimdall_managed: true`
// inside the frontmatter itself and this function accepts either form.
MANAGED_YAML_MARKER :: "heimdall_managed: true"
data_has_managed_marker :: proc(data: string) -> bool {
	if strings.has_prefix(data, BOOTSTRAP_HEADER) do return true
	if active_live_prefs.bootstrap_header != "" && strings.has_prefix(data, active_live_prefs.bootstrap_header) do return true
	if strings.has_prefix(data, "---\n") || strings.has_prefix(data, "---\r\n") {
		after := data[4:] if strings.has_prefix(data, "---\n") else data[5:]
		close_rel := strings.index(after, "\n---")
		if close_rel >= 0 {
			front := after[:close_rel]
			if strings.contains(front, MANAGED_YAML_MARKER) do return true
		}
	}
	return false
}

write_managed_file :: proc(path, content: string) {
	parent := parent_dir(path)
	if parent != "" do _ = os.make_directory_all(parent)
	tmp := strings.concatenate({path, ".tmp"})
	if os.write_entire_file(tmp, content) == nil {
		_ = os.rename(tmp, path)
	}
}

bootstrap_profile :: proc(agent_cmd: cfg_lib.Agent_Command_Config, selected_agent: string) -> string {
	name := selected_agent
	if name == "" do name = agent_cmd.name
	if name == "claude" || strings.has_prefix(name, "claude-") do return "claude"
	if name == "codex" || strings.has_prefix(name, "codex-") do return "codex"
	return "pi"
}

bootstrap_title :: proc(file_name, profile: string) -> string {
	if active_live_prefs.bootstrap_title != "" && active_live_prefs.bootstrap_title != "# Agent bootstrap for Heimdall AI Manager" {
		return active_live_prefs.bootstrap_title
	}
	if strings.has_suffix(file_name, "CLAUDE.md") || profile == "claude" do return "# Claude bootstrap for Heimdall AI Manager"
	if profile == "codex" do return "# Codex AGENTS.md bootstrap for Heimdall AI Manager"
	return "# Agent bootstrap for Heimdall AI Manager"
}

template_guidance_string :: proc(raw: string, profile, file_name, agent_instance_id: string) -> string {
	res := replace_all(raw, "{ctl_bin}", effective_ctl_bin())
	res = replace_all(res, "{profile}", profile)
	res = replace_all(res, "{file_name}", file_name)
	res = replace_all(res, "{instance}", agent_instance_id)
	return res
}

default_bootstrap_profile_guidance :: proc(profile: string) -> string {
	profile_desc := "- Pi profile: this generated `AGENTS.md` is the primary run-directory instruction file. Read inbox/task state before beginning new work.\n"
	if profile == "claude" {
		profile_desc = "- Claude profile: this generated `CLAUDE.md` is the primary local instruction file. Keep tool/reference notes concise and fetch details through Heimdall CLI/RPC when needed.\n"
	} else if profile == "codex" {
		profile_desc = "- Codex profile: this generated `AGENTS.md` follows repository-agent instruction conventions. Prefer scoped, auditable edits and run relevant validation before handoff.\n"
	}
	return fmt.tprintf(strings.trim_space(#load("../prompts/bootstrap_profile_guidance.md", string)), profile_desc)
}

validate_project_exists :: proc(daemon_url, agent_token, project_id: string) -> bool {
	if project_id == "" do return true
	request := strings.builder_make()
	strings.write_string(&request, `{"agent_token":"`); json_write_string(&request, agent_token)
	strings.write_string(&request, `","project_id":"`); json_write_string(&request, project_id)
	strings.write_string(&request, `"}`)
	response, ok := http.post(daemon_url, "/projects/show", strings.to_string(request))
	return ok && response.status == 200
}

project_bootstrap_context :: proc(daemon_url, agent_token: string, cfg: cfg_lib.Wrapper_Config, agent_cmd: cfg_lib.Agent_Command_Config) -> string {
	project_id := agent_cmd.project
	if project_id == "" do project_id = cfg.project
	if project_id == "" do return ""
	request := strings.builder_make()
	strings.write_string(&request, `{"agent_token":"`); json_write_string(&request, agent_token)
	strings.write_string(&request, `","project_id":"`); json_write_string(&request, project_id)
	strings.write_string(&request, `"}`)
	response, ok := http.post(daemon_url, "/projects/show", strings.to_string(request))
	project_context := ""
	if ok && response.status == 200 {
		project_context = format_project_bootstrap(response.body)
	}

	agents_context := ""
	agents_response, agents_ok := http.get(daemon_url, fmt.tprintf("/agents?project_id=%s", project_id))
	if agents_ok && agents_response.status == 200 {
		agents_context = format_project_agents_bootstrap(agents_response.body)
	}

	if project_context != "" && agents_context != "" {
		return strings.concatenate({project_context, "\n", agents_context})
	} else if project_context != "" {
		return project_context
	}
	return ""
}

format_project_agents_bootstrap :: proc(body: string) -> string {
	start_arr := strings.index(body, `"agents":[`)
	if start_arr < 0 do return ""
	idx := start_arr + len(`"agents":[`)
	
	Agent_Bootstrap_Item :: struct {
		instance_id: string,
		role: string,
		order: int,
	}
	
	items: [dynamic]Agent_Bootstrap_Item
	defer {
		for item in items {
			delete(item.instance_id)
			delete(item.role)
		}
		delete(items)
	}
	
	for {
		start_obj_rel := strings.index_byte(body[idx:], '{')
		if start_obj_rel < 0 do break
		obj_start := idx + start_obj_rel
		obj_end := json_object_end(body, obj_start)
		if obj_end <= obj_start do break
		
		object := body[obj_start:obj_end]
		
		inst_id := extract_json_string(object, "agent_instance_id", "")
		role := extract_json_string(object, "template_id", "")
		order := extract_json_int(object, "order", 0)
		
		if inst_id != "" {
			append(&items, Agent_Bootstrap_Item{
				instance_id = strings.clone(inst_id),
				role = strings.clone(role),
				order = order,
			})
		}
		
		idx = obj_end
	}
	
	if len(items) == 0 do return ""
	
	// Sort items by order ascending
	for i in 0..<len(items) {
		for j in i+1..<len(items) {
			if items[i].order > items[j].order {
				temp := items[i]
				items[i] = items[j]
				items[j] = temp
			}
		}
	}
	
	builder := strings.builder_make()
	strings.write_string(&builder, "Agents:\n")
	for item in items {
		strings.write_string(&builder, "- ")
		strings.write_string(&builder, item.instance_id)
		if item.role != "" {
			strings.write_string(&builder, " (role: ")
			strings.write_string(&builder, item.role)
			strings.write_string(&builder, ")")
		}
		strings.write_string(&builder, "\n")
	}
	
	return strings.to_string(builder)
}

format_project_bootstrap :: proc(body: string) -> string {
	start := strings.index(body, `"project":`)
	if start < 0 do return ""
	obj_start_rel := strings.index(body[start:], `{`)
	if obj_start_rel < 0 do return ""
	obj_start := start + obj_start_rel
	obj_end := json_object_end(body, obj_start)
	if obj_end <= obj_start do return ""
	object := body[obj_start:obj_end]
	project_id := extract_json_string(object, "project_id", "")
	name := extract_json_string(object, "name", "")
	description := extract_json_string(object, "description", "")
	builder := strings.builder_make()
	strings.write_string(&builder, "\n\n# Project Context\n")
	if name != "" { strings.write_string(&builder, "Project: "); strings.write_string(&builder, name); strings.write_string(&builder, "\n") }
	if project_id != "" { strings.write_string(&builder, "Project ID: "); strings.write_string(&builder, project_id); strings.write_string(&builder, "\n") }
	if description != "" { strings.write_string(&builder, "Description: "); strings.write_string(&builder, description); strings.write_string(&builder, "\n") }
	strings.write_string(&builder, "Anchors are loose metadata only; do not over-interpret them as mandatory cwd/git/agent links.\n")
	idx := 0
	wrote_anchors := false
	for {
		start_rel := strings.index(object[idx:], `{"type":"`)
		if start_rel < 0 do break
		anchor_start := idx + start_rel
		anchor_end := json_object_end(object, anchor_start)
		if anchor_end <= anchor_start do break
		anchor := object[anchor_start:anchor_end]
		if !wrote_anchors { strings.write_string(&builder, "Anchors:\n"); wrote_anchors = true }
		strings.write_string(&builder, "- "); strings.write_string(&builder, extract_json_string(anchor, "type", "anchor")); strings.write_string(&builder, ": "); strings.write_string(&builder, extract_json_string(anchor, "value", ""))
		note := extract_json_string(anchor, "note", "")
		if note != "" { strings.write_string(&builder, " — "); strings.write_string(&builder, note) }
		strings.write_string(&builder, "\n")
		idx = anchor_end
	}
	return strings.to_string(builder)
}

safe_relative_path :: proc(path: string) -> bool {
	if path == "" do return false
	if strings.has_prefix(path, "/") do return false
	parts := strings.split(path, "/")
	for part in parts {
		if part == "" || part == "." || part == ".." do return false
	}
	return true
}

join_path :: proc(a, b: string) -> string {
	if strings.has_suffix(a, "/") do return strings.concatenate({a, b})
	return strings.concatenate({a, "/", b})
}

parent_dir :: proc(path: string) -> string {
	last := -1
	for i in 0..<len(path) {
		if path[i] == '/' do last = i
	}
	if last <= 0 do return ""
	return path[:last]
}

wrapper_window_name :: proc(prefix, agent_instance_id: string) -> string {
	if prefix == "" do return agent_instance_id
	return fmt.aprintf("%s-%s", prefix, agent_instance_id)
}

template_display_name :: proc(display_name, agent_class, agent_instance_id, selected_agent: string) -> string {
	if display_name == "" do return agent_instance_id
	templated := replace_all(display_name, "{agent_class}", agent_class)
	templated = replace_all(templated, "{agent}", selected_agent)
	templated = replace_all(templated, "{agent_instance_id}", agent_instance_id)
	templated = replace_all(templated, "{instance}", agent_instance_id)
	return templated
}

prompt_delivery_for_agent :: proc(agent_cmd: cfg_lib.Agent_Command_Config) -> string {
	delivery := agent_cmd.prompt_delivery
	if delivery == "tmux" || delivery == "none" || delivery == "flag-injection" do return delivery
	return "flag-injection"
}

prompt_tmux_delay_for_agent :: proc(agent_cmd: cfg_lib.Agent_Command_Config) -> int {
	if agent_cmd.prompt_tmux_delay_ms > 0 do return agent_cmd.prompt_tmux_delay_ms
	return 1500
}

prompt_tmux_enter_for_agent :: proc(agent_cmd: cfg_lib.Agent_Command_Config) -> bool {
	if agent_cmd.prompt_tmux_enter_set do return agent_cmd.prompt_tmux_enter
	return true
}

starter_prompt_template_for_agent :: proc(agent_cmd: cfg_lib.Agent_Command_Config, agent_token: string) -> string {
	if is_test_token(agent_token) do return TEST_AGENT_STARTER_PROMPT
	if agent_cmd.starter_prompt != "" do return agent_cmd.starter_prompt
	return active_live_prefs.starter_prompt
}

render_starter_prompt_for_agent :: proc(agent_cmd: cfg_lib.Agent_Command_Config, daemon_url, agent_instance_id, display_name, conversation_id, agent_token, current_task_id: string) -> string {
	template := starter_prompt_template_for_agent(agent_cmd, agent_token)
	if template == "" do return ""
	if current_task_id != "" {
		template = strings.concatenate({
			strings.trim_space(template),
			"\n\nAfter start-success, inspect and begin your assigned task {task_id}: `{ctl_bin} tasks show --token {token} --task-id {task_id}`. If you need to claim or resume assigned work from task state, run `{ctl_bin} tasks next --token {token}`.",
		})
	}
	return template_string(template, daemon_url, agent_instance_id, display_name, conversation_id, agent_token, current_task_id)
}

deliver_tmux_starter_prompt :: proc(agent_cmd: cfg_lib.Agent_Command_Config, daemon_url, agent_instance_id, display_name, conversation_id, agent_token, current_task_id, pane_id: string) {
	if prompt_delivery_for_agent(agent_cmd) != "tmux" do return
	prompt := render_starter_prompt_for_agent(agent_cmd, daemon_url, agent_instance_id, display_name, conversation_id, agent_token, current_task_id)
	if prompt == "" do return
	delay_ms := prompt_tmux_delay_for_agent(agent_cmd)
	if delay_ms > 0 do time.sleep(time.Duration(delay_ms) * time.Millisecond)
	enter := prompt_tmux_enter_for_agent(agent_cmd)
	if tmux.send_text(pane_id, prompt, enter) {
		fmt.println("tmux prompt delivery sent pane", pane_id, "enter", enter)
	} else {
		fmt.println("tmux prompt delivery failed pane", pane_id)
	}
}

build_agent_command :: proc(cfg: cfg_lib.Wrapper_Config, selected_agent, daemon_url, agent_instance_id, display_name, conversation_id, agent_token, current_task_id, model_tier: string) -> []string {
	agent_command_name := selected_agent
	if agent_command_name == "" do agent_command_name = command_name_for_agent(cfg.command, cfg.agent_name)
	for agent_cmd in cfg.agent_commands {
		if agent_cmd.name == agent_command_name {
			base := agent_cmd.command
			if len(base) == 0 do base = cfg.command
			delivery := prompt_delivery_for_agent(agent_cmd)
			inject_prompt_via_flags := delivery == "flag-injection"
			count := len(base) + len(agent_cmd.yolo_flags)
			if inject_prompt_via_flags {
				count += len(agent_cmd.prompt_flags)
				if starter_prompt_template_for_agent(agent_cmd, agent_token) != "" do count += 1
			}
			result := make([dynamic]string, 0, count)
			append_templated_args(&result, base, daemon_url, agent_instance_id, display_name, conversation_id, agent_token, current_task_id)
			append_templated_args(&result, agent_cmd.yolo_flags, daemon_url, agent_instance_id, display_name, conversation_id, agent_token, current_task_id)
			// Model tier flag
			if agent_cmd.models.flag != "" {
				model_value := cfg_lib.resolve_model_value(agent_cmd.models, model_tier)
				if model_value != "" {
					append(&result, agent_cmd.models.flag)
					append(&result, model_value)
					fmt.println("model_value", model_value)
				} else {
					fmt.println("model_tier_unavailable tier", model_tier, "has no mapping for", agent_command_name)
				}
			} else if model_tier != "" {
				fmt.println("model_flag_missing no models.flag configured for", agent_command_name)
			}
			if inject_prompt_via_flags {
				append_templated_args(&result, agent_cmd.prompt_flags, daemon_url, agent_instance_id, display_name, conversation_id, agent_token, current_task_id)
				prompt := render_starter_prompt_for_agent(agent_cmd, daemon_url, agent_instance_id, display_name, conversation_id, agent_token, current_task_id)
				if prompt != "" do append(&result, prompt)
			}
			return result[:]
		}
	}
	return template_command(cfg.command, daemon_url, agent_instance_id, display_name, conversation_id, agent_token, current_task_id)
}

memory_cli_guidance :: proc(agent_token: string) -> string {
	builder := strings.builder_make()
	bin := effective_ctl_bin()
	write_ctl :: proc(b: ^strings.Builder, bin, suffix: string) {
		strings.write_string(b, bin)
		strings.write_string(b, suffix)
	}
	strings.write_string(&builder, "\n\n# Memory CLI\n")
	strings.write_string(&builder, "Use the absolute `")
	strings.write_string(&builder, bin)
	strings.write_string(&builder, "` memory commands with your token for durable memory proposals and review. Approved active memory is what affects runtime behavior; pending, rejected, and archived proposals do not. Template memories are reusable starter memory for configured agents/roles and follow the same propose/approve/version/archive/rollback lifecycle. Proposal reason/evidence are proposal-only review metadata and should not be copied into runtime memory bodies. Skill memories must use structured body text with at least name: and description:.\n")
	strings.write_string(&builder, "Examples: ")
	write_ctl(&builder, bin, " memory propose new --token ")
	strings.write_string(&builder, agent_token)
	strings.write_string(&builder, " --target-team-kind <kind> --target-role <role> --target-project-id <project_id> --type fact|habit|episode|expertise|skill|template --title <title> --body <body> --reason <why> --evidence <task-or-source>; ")
	write_ctl(&builder, bin, " memory propose edit --token ")
	strings.write_string(&builder, agent_token)
	strings.write_string(&builder, " --memory-id <id> --expected-version <n> --title <title> --body <body> --reason <why> --evidence <source>; ")
	write_ctl(&builder, bin, " memory propose archive --token ")
	strings.write_string(&builder, agent_token)
	strings.write_string(&builder, " --memory-id <id> --expected-version <n> --reason <why> --evidence <source>; ")
	write_ctl(&builder, bin, " memory propose rollback --token ")
	strings.write_string(&builder, agent_token)
	strings.write_string(&builder, " --memory-id <id> --expected-version <n> --reason <why> --evidence <source>.\n")
	strings.write_string(&builder, "Review/query: ")
	write_ctl(&builder, bin, " memory decide --token ")
	strings.write_string(&builder, agent_token)
	strings.write_string(&builder, " --proposal-id <proposal_id> --decision approve|reject; ")
	write_ctl(&builder, bin, " memory list --token ")
	strings.write_string(&builder, agent_token)
	strings.write_string(&builder, " --status active|pending|archived|rejected|all; ")
	write_ctl(&builder, bin, " memory show --token ")
	strings.write_string(&builder, agent_token)
	strings.write_string(&builder, " --memory-id <id>; ")
	write_ctl(&builder, bin, " memory history --token ")
	strings.write_string(&builder, agent_token)
	strings.write_string(&builder, " --memory-id <id>.\n")
	return strings.to_string(builder)
}

memory_template_matches :: proc(object: string, memory_templates: []string) -> bool {
	memory_id := extract_json_string(object, "memory_id", "")
	title := extract_json_string(object, "title", "")
	target := extract_json_string(object, "target", "")
	for item in memory_templates {
		if item == memory_id || item == title || item == target do return true
	}
	return false
}

json_object_end :: proc(body: string, start: int) -> int {
	depth := 0
	in_string := false
	escaped := false
	for i := start; i < len(body); i += 1 {
		ch := body[i]
		if in_string {
			if escaped { escaped = false; continue }
			if ch == '\\' { escaped = true; continue }
			if ch == '"' do in_string = false
			continue
		}
		if ch == '"' { in_string = true; continue }
		if ch == '{' do depth += 1
		if ch == '}' {
			depth -= 1
			if depth == 0 do return i + 1
		}
	}
	return -1
}

command_name_for_agent :: proc(command: []string, agent_class: string) -> string {
	if len(command) > 0 do return command[0]
	if strings.has_suffix(agent_class, "-agent") do return agent_class[:len(agent_class) - len("-agent")]
	return agent_class
}

append_templated_args :: proc(result: ^[dynamic]string, args: []string, daemon_url, agent_instance_id, display_name, conversation_id, agent_token, current_task_id: string) {
	for arg in args {
		append(result, template_string(arg, daemon_url, agent_instance_id, display_name, conversation_id, agent_token, current_task_id))
	}
}

template_command :: proc(command: []string, daemon_url, agent_instance_id, display_name, conversation_id, agent_token, current_task_id: string) -> []string {
	result := make([]string, len(command))
	for i in 0..<len(command) {
		result[i] = template_string(command[i], daemon_url, agent_instance_id, display_name, conversation_id, agent_token, current_task_id)
	}
	return result
}

// Compile-time fallback path for ham-ctl. Set ham_ctl_bin in config.toml to override at runtime.
HAM_CTL_BIN :: "ham-ctl"

// Runtime ctl bin path resolved from config at startup. Falls back to HAM_CTL_BIN when empty.
g_ctl_bin: string

effective_ctl_bin :: proc() -> string {
	if g_ctl_bin != "" do return g_ctl_bin
	return HAM_CTL_BIN
}

template_string :: proc(value, daemon_url, agent_instance_id, display_name, conversation_id, agent_token, current_task_id: string) -> string {
	ctl_bin := effective_ctl_bin()
	templated := replace_all(value, "{daemon_url}", daemon_url)
	templated = replace_all(templated, "{agent_instance_id}", agent_instance_id)
	templated = replace_all(templated, "{display_name}", display_name)
	templated = replace_all(templated, "{instance}", agent_instance_id)
	templated = replace_all(templated, "{conversation_id}", conversation_id)
	templated = replace_all(templated, "{agent_token}", agent_token)
	templated = replace_all(templated, "{token}", agent_token)
	templated = replace_all(templated, "{task_id}", current_task_id)
	templated = replace_all(templated, "{ctl_bin}", ctl_bin)
	return templated
}

replace_all :: proc(value, needle, replacement: string) -> string {
	if needle == "" do return strings.clone(value)
	builder := strings.builder_make()
	start := 0
	for {
		idx := strings.index(value[start:], needle)
		if idx < 0 do break
		strings.write_string(&builder, value[start:start + idx])
		strings.write_string(&builder, replacement)
		start = start + idx + len(needle)
	}
	strings.write_string(&builder, value[start:])
	return strings.to_string(builder)
}

register_request_json :: proc(agent_class, agent_instance_id, display_name: string, agent_token := "") -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "{\"protocol_version\":1")
	strings.write_string(&builder, ",\"agent_class\":\"")
	strings.write_string(&builder, agent_class)
	strings.write_string(&builder, "\",\"agent_instance_id\":\"")
	strings.write_string(&builder, agent_instance_id)
	strings.write_string(&builder, "\",\"display_name\":\"")
	strings.write_string(&builder, display_name)
	if agent_token != "" {
		strings.write_string(&builder, "\",\"agent_token\":\"")
		strings.write_string(&builder, agent_token)
	}
	strings.write_string(&builder, "\"}")
	return strings.to_string(builder)
}

parse_agent_identity :: proc(raw: string) -> (agent_class: string, agent_instance_id: string, ok: bool) {
	at := strings.index_byte(raw, '@')
	class := raw
	suffix := "default"
	if at >= 0 {
		class = raw[:at]
		suffix = raw[at + 1:]
	}

	if !valid_agent_id_part(class) || !valid_agent_id_part(suffix) {
		return "", "", false
	}

	return strings.clone(class), fmt.aprintf("%s@%s", class, suffix), true
}

valid_agent_id_part :: proc(id: string) -> bool {
	if len(id) == 0 do return false
	for ch in id {
		switch ch {
		case 'a'..='z', 'A'..='Z', '0'..='9', '-':
			continue
		case:
			return false
		}
	}
	return true
}

option_value :: proc(args: []string, name, fallback: string) -> string {
	for i := 0; i + 1 < len(args); i += 1 {
		if args[i] == name do return args[i + 1]
	}
	return fallback
}

agent_identity_from_args :: proc(args: []string, fallback: string) -> string {
	for i := 1; i < len(args); i += 1 {
		if args[i] == cfg_lib.CONFIG_PATH_FLAG || args[i] == "--agent" || args[i] == "--agent-token" || args[i] == "--display-name" || args[i] == "--tier" || args[i] == "--project-id" || args[i] == "--current-task-id" {
			i += 1
			continue
		}
		if args[i] == "--detach" || args[i] == "--overwrite" do continue
		return args[i]
	}
	return fallback
}

Live_Preferences :: struct {
	starter_prompt:                  string,
	bootstrap_header:                string,
	bootstrap_title:                 string,
	bootstrap_profile_guidance:      string,
	msg_agent_message:               string,
	msg_agent_message_int:           bool,
	msg_task_updated:                string,
	msg_task_updated_int:            bool,
	msg_task_updated_empty:          string,
	msg_task_updated_empty_int:      bool,
	msg_memory_updated:              string,
	msg_memory_updated_int:          bool,
	msg_memory_proposal_updated:     string,
	msg_memory_proposal_updated_int: bool,
	msg_user_chat:                   string,
	msg_user_chat_int:               bool,
	msg_token_refreshed:             string,
	msg_token_refreshed_int:         bool,
	msg_stop_requested:              string,
	msg_stop_requested_int:          bool,
}

active_live_prefs: Live_Preferences

initialize_default_preferences :: proc() {
	active_live_prefs.starter_prompt = "First, run: {ctl_bin} --token {token} start-success. Then read your bootstrap file (AGENTS.md or CLAUDE.md) for context, identity, and what you can do."
	active_live_prefs.bootstrap_header = "<!-- HEIMDALL-MANAGED-BOOTSTRAP v1: safe to overwrite -->"
	active_live_prefs.bootstrap_title = "# Agent bootstrap for Heimdall AI Manager"
	active_live_prefs.bootstrap_profile_guidance = default_bootstrap_profile_guidance("pi")
	active_live_prefs.msg_agent_message = "{pending_count} Unread Messages from {from_agent_id}."
	active_live_prefs.msg_agent_message_int = false
	active_live_prefs.msg_task_updated = "Task {task_id} {status} by {changed_by}: {body}"
	active_live_prefs.msg_task_updated_int = false
	active_live_prefs.msg_task_updated_empty = "Task {task_id} {status} by {changed_by}."
	active_live_prefs.msg_task_updated_empty_int = false
	active_live_prefs.msg_memory_updated = "Memory {memory_id} {event} by {changed_by} for {target} ({status}). Fetch details with: {ctl_bin} memory show --token <your token> --memory-id {memory_id}"
	active_live_prefs.msg_memory_updated_int = false
	active_live_prefs.msg_memory_proposal_updated = "Memory proposal {proposal_id} {event} by {changed_by} for {target}. Review with: {ctl_bin} memory history --token <your token> --memory-id {memory_id}"
	active_live_prefs.msg_memory_proposal_updated_int = false
	active_live_prefs.msg_user_chat = "{pending_count} User Chat Messages from {user_id}. Read with: {ctl_bin} chat fetch-user --token <your token> --user-id {user_id}"
	active_live_prefs.msg_user_chat_int = true
	active_live_prefs.msg_token_refreshed = "SYSTEM: Heimdall daemon restarted and issued a new agent token. Your previous token is invalid. New token: {new_token} — update all pending ham-ctl commands to use this token. Run: {ctl_bin} --daemon-url {daemon_url} --token {new_token} start-success"
	active_live_prefs.msg_token_refreshed_int = true
	active_live_prefs.msg_stop_requested = "SYSTEM: Stop requested. You have {time} seconds to save your work."
	active_live_prefs.msg_stop_requested_int = true
}

apply_preferences_json :: proc(prefs_json: string) {
	if prefs_json == "" do return

	update_pref_string :: proc(field: ^string, prefs_json, key, fallback: string) {
		val := extract_json_string(prefs_json, key, "")
		if val != "" {
			field^ = strings.clone(val)
		}
	}

	update_pref_bool :: proc(field: ^bool, prefs_json, key: string, fallback: bool) {
		pattern := fmt.tprintf("\"%s\":", key)
		idx := strings.index(prefs_json, pattern)
		if idx >= 0 {
			start := idx + len(pattern)
			if strings.has_prefix(prefs_json[start:], "true") {
				field^ = true
			} else if strings.has_prefix(prefs_json[start:], "false") {
				field^ = false
			}
		}
	}

	update_pref_string(&active_live_prefs.starter_prompt, prefs_json, "starter_prompt", active_live_prefs.starter_prompt)
	update_pref_string(&active_live_prefs.bootstrap_header, prefs_json, "bootstrap_header", active_live_prefs.bootstrap_header)
	update_pref_string(&active_live_prefs.bootstrap_title, prefs_json, "bootstrap_title", active_live_prefs.bootstrap_title)
	update_pref_string(&active_live_prefs.bootstrap_profile_guidance, prefs_json, "bootstrap_profile_guidance", active_live_prefs.bootstrap_profile_guidance)
	
	update_pref_string(&active_live_prefs.msg_agent_message, prefs_json, "msg_agent_message", active_live_prefs.msg_agent_message)
	update_pref_bool(&active_live_prefs.msg_agent_message_int, prefs_json, "msg_agent_message_interrupt", active_live_prefs.msg_agent_message_int)
	
	update_pref_string(&active_live_prefs.msg_task_updated, prefs_json, "msg_task_updated", active_live_prefs.msg_task_updated)
	update_pref_bool(&active_live_prefs.msg_task_updated_int, prefs_json, "msg_task_updated_interrupt", active_live_prefs.msg_task_updated_int)
	
	update_pref_string(&active_live_prefs.msg_task_updated_empty, prefs_json, "msg_task_updated_empty", active_live_prefs.msg_task_updated_empty)
	update_pref_bool(&active_live_prefs.msg_task_updated_empty_int, prefs_json, "msg_task_updated_empty_interrupt", active_live_prefs.msg_task_updated_empty_int)
	
	update_pref_string(&active_live_prefs.msg_memory_updated, prefs_json, "msg_memory_updated", active_live_prefs.msg_memory_updated)
	update_pref_bool(&active_live_prefs.msg_memory_updated_int, prefs_json, "msg_memory_updated_interrupt", active_live_prefs.msg_memory_updated_int)
	
	update_pref_string(&active_live_prefs.msg_memory_proposal_updated, prefs_json, "msg_memory_proposal_updated", active_live_prefs.msg_memory_proposal_updated)
	update_pref_bool(&active_live_prefs.msg_memory_proposal_updated_int, prefs_json, "msg_memory_proposal_updated_interrupt", active_live_prefs.msg_memory_proposal_updated_int)
	
	update_pref_string(&active_live_prefs.msg_user_chat, prefs_json, "msg_user_chat", active_live_prefs.msg_user_chat)
	update_pref_bool(&active_live_prefs.msg_user_chat_int, prefs_json, "msg_user_chat_interrupt", active_live_prefs.msg_user_chat_int)
	
	update_pref_string(&active_live_prefs.msg_token_refreshed, prefs_json, "msg_token_refreshed", active_live_prefs.msg_token_refreshed)
	update_pref_bool(&active_live_prefs.msg_token_refreshed_int, prefs_json, "msg_token_refreshed_interrupt", active_live_prefs.msg_token_refreshed_int)
	
	update_pref_string(&active_live_prefs.msg_stop_requested, prefs_json, "msg_stop_requested", active_live_prefs.msg_stop_requested)
	update_pref_bool(&active_live_prefs.msg_stop_requested_int, prefs_json, "msg_stop_requested_interrupt", active_live_prefs.msg_stop_requested_int)
}

extract_json_object :: proc(body, key: string) -> string {
	pattern := fmt.tprintf("\"%s\":", key)
	idx := strings.index(body, pattern)
	if idx < 0 do return ""

	start := idx + len(pattern)
	brace_count := 0
	in_string := false
	escaped := false
	
	i := start
	for i < len(body) {
		ch := body[i]
		if escaped {
			escaped = false
			i += 1
			continue
		}
		if ch == '\\' && in_string {
			escaped = true
			i += 1
			continue
		}
		if ch == '"' {
			in_string = !in_string
		}
		
		if !in_string {
			if ch == '{' {
				brace_count += 1
			} else if ch == '}' {
				brace_count -= 1
				if brace_count == 0 {
					return strings.clone(body[start : i + 1])
				}
			}
		}
		i += 1
	}
	return ""
}

template_live_message :: proc(template_str: string, pending_count: int, from_agent_id, task_id, status, changed_by, body, memory_id, event, target, user_id, new_token, daemon_url: string, time_val: int, allocator := context.allocator) -> string {
	context.allocator = context.temp_allocator
	
	res := replace_all(template_str, "{pending_count}", fmt.tprintf("%d", pending_count))
	res = replace_all(res, "{from_agent_id}", from_agent_id)
	res = replace_all(res, "{task_id}", task_id)
	res = replace_all(res, "{status}", status)
	res = replace_all(res, "{changed_by}", changed_by)
	res = replace_all(res, "{body}", body)
	res = replace_all(res, "{memory_id}", memory_id)
	res = replace_all(res, "{proposal_id}", memory_id)
	res = replace_all(res, "{event}", event)
	res = replace_all(res, "{target}", target)
	res = replace_all(res, "{subject_agent}", target)
	res = replace_all(res, "{user_id}", user_id)
	res = replace_all(res, "{new_token}", new_token)
	res = replace_all(res, "{daemon_url}", daemon_url)
	res = replace_all(res, "{time}", fmt.tprintf("%d", time_val))
	res = replace_all(res, "{ctl_bin}", effective_ctl_bin())
	
	return strings.clone(res, allocator)
}
