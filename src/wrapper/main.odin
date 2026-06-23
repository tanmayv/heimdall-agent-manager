package main

import "core:fmt"
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
	window_name := wrapper_window_name(cfg.tmux_window_prefix, agent_instance_id)
	cwd := resolve_agent_run_dir(cfg, agent_cmd, agent_cmd_ok, selected_agent, agent_instance_id)

	overwrite := has_flag(os.args, "--overwrite")
	if !handle_existing_agent_window(cfg.tmux_session, window_name, overwrite) {
		return
	}

	display_name := option_value(os.args, "--display-name", template_display_name(cfg.display_name, agent_class, agent_instance_id, selected_agent))

	response, health_ok := http.get(cfg.daemon_url, contracts.ROUTE_HEALTH)
	if !health_ok || response.status != 200 {
		fmt.println("daemon is not reachable; start ham-daemon first")
		return
	}

	register_body := register_request_json(agent_class, agent_instance_id, display_name, requested_agent_token)
	register_response, register_ok := http.post(cfg.daemon_url, contracts.ROUTE_REGISTER, register_body)
	if !register_ok || register_response.status != 200 {
		fmt.println("registration failed")
		if register_ok {
			fmt.println("registration_status", register_response.status)
			fmt.println("registration_response", register_response.body)
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
	template_instructions := extract_json_string(register_response.body, "template_instructions", "")
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

	fmt.println("starting tmux agent")
	fmt.println("tmux_session", cfg.tmux_session)
	fmt.println("tmux_window", window_name)
	fmt.println("working_dir", cwd)

	if !is_test_token(agent_token) {
		// Daemon passes the agent record's actual project_id via --project-id so
		// the bootstrap reflects the *current* project, not the per-provider
		// default in config.toml.
		if override_project_id != "" {
			agent_cmd.project = override_project_id
			cfg.project = override_project_id
		}
		generate_bootstrap_files(cwd, loaded.path, cfg, agent_cmd, selected_agent, registered_instance_id, display_name, cfg.daemon_url, agent_token, template_instructions)
	}

	stop_message := cfg.stop_message
	if agent_cmd.stop_message != "" do stop_message = agent_cmd.stop_message
	if stop_message == "" do stop_message = "Agent stop requested. You have {time} seconds to complete your current work and checkpoint before shutdown."

	command := build_agent_command(cfg, selected_agent, cfg.daemon_url, registered_instance_id, display_name, conversation_id, agent_token, model_tier)
	launch, launch_ok := tmux.ensure_agent_window(cfg.tmux_session, window_name, cwd, command)
	if !launch_ok {
		fmt.println("failed to launch or find tmux window")
		return
	}
	fmt.println("tmux_pane", launch.pane_id)
	startup_status := "ready"
	startup_reason_code := "launch_success"
	startup_safe_diagnostic := "Startup detection disabled; assuming ready"


	report_startup_status(cfg.daemon_url, registered_instance_id, "starting", "launch", "Agent process launched in tmux", selected_agent, cwd, launch.pane_id)
	result := startup_probe_agent(agent_cmd.startup_detection, launch.pane_id)
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

	ws_conn, ws_ok := ws.connect(ws_url)
	if ws_ok {
		fmt.println("ws connected", ws_url)
	} else {
		fmt.println("ws connection failed", ws_url)
	}

	initial_exec_state := "running"
	heartbeat_loop(cfg.daemon_url, agent_class, registered_instance_id, display_name, agent_token, launch.pane_id, stop_message, selected_agent, model_tier, override_project_id, cwd, initial_exec_state, startup_status, startup_reason_code, startup_safe_diagnostic, cfg.tmux_session, window_name, &ws_conn)
}

Startup_Probe_Result :: struct {
	status: string,
	reason_code: string,
	safe_diagnostic: string,
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
					pre_cmd := []string{"tmux", "send-keys", "-t", pane_id, pre_key}
					_, _, _, _ = os.process_exec(os.Process_Desc{command = pre_cmd}, context.allocator)
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
	builder := strings.builder_make()
	strings.write_string(&builder, `{"agent_instance_id":"`); json_write_string(&builder, agent_instance_id)
	strings.write_string(&builder, `","startup_status":"`); json_write_string(&builder, status)
	strings.write_string(&builder, `","reason_code":"`); json_write_string(&builder, reason_code)
	strings.write_string(&builder, `","safe_diagnostic":"`); json_write_string(&builder, safe_diagnostic)
	strings.write_string(&builder, `","provider_profile":"`); json_write_string(&builder, provider_profile)
	strings.write_string(&builder, `","run_dir":"`); json_write_string(&builder, run_dir)
	strings.write_string(&builder, `","tmux_pane":"`); json_write_string(&builder, tmux_pane)
	strings.write_string(&builder, `"}`)
	_, _ = http.post(daemon_url, "/startup", strings.to_string(builder))
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

heartbeat_loop :: proc(daemon_url, agent_class, agent_instance_id, display_name, agent_token, tmux_pane, stop_message, provider_profile, provider_tier, project_id, run_dir, initial_exec_state, initial_startup_status, initial_startup_reason_code, initial_startup_safe_diagnostic, tmux_session, window_name: string, ws_conn: ^ws.Connection) {
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

	for {
		if !tmux.pane_exists(tmux_pane) {
			fmt.println("agent tmux pane missing; stopping wrapper", tmux_pane)
			return
		}

		// Self-healing WebSocket reconnection: if the WebSocket connection was severed
		// (e.g. due to daemon restart), re-register and reconnect immediately!
		if !ws_conn.connected {
			fmt.println("WebSocket disconnected; attempting to reconnect...", agent_instance_id)
			if new_ws_url, new_token, reconnected := reregister_and_reconnect_ws(daemon_url, agent_class, agent_instance_id, display_name, current_token, ws_conn); reconnected {
				fmt.println("WebSocket successfully reconnected!", agent_instance_id, new_ws_url)
				current_token = new_token
				failed_heartbeats = 0
				notify_agent_token_refreshed(tmux_pane, daemon_url, new_token, agent_instance_id)
			} else {
				fmt.println("WebSocket reconnection attempt failed; will retry", agent_instance_id)
			}
		}

		body := heartbeat_request_json(agent_instance_id, current_token, display_name, provider_profile, provider_tier, project_id, tmux_pane, run_dir, exec_state, "", current_startup_status, current_startup_reason_code, current_startup_safe_diagnostic, pid, exec_state_since)
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
			// Token not found in registry (daemon restarted). Re-register fresh to
			// get the token back into the daemon's in-memory registry.
			fmt.println("heartbeat token_not_found; re-registering", agent_instance_id)
			if new_ws_url, new_token, reconnected := reregister_and_reconnect_ws(daemon_url, agent_class, agent_instance_id, display_name, current_token, ws_conn); reconnected {
				fmt.println("re-registered", agent_instance_id, new_ws_url)
				current_token = new_token
				failed_heartbeats = 0
				notify_agent_token_refreshed(tmux_pane, daemon_url, new_token, agent_instance_id)
			} else {
				fmt.println("re-register failed", agent_instance_id)
				failed_heartbeats += 1
			}
		} else if ok && response.status == 400 {
			// Distinguish project_not_found / missing_required so operator sees it.
			fmt.println("heartbeat rejected", agent_instance_id, response.body)
			failed_heartbeats += 1
		} else {
			failed_heartbeats += 1
			fmt.println("heartbeat failed", agent_instance_id)
		}

		if failed_heartbeats >= 3 {
			fmt.println("heartbeat failed repeatedly; re-registering", agent_instance_id)
			if new_ws_url, new_token, reconnected := reregister_and_reconnect_ws(daemon_url, agent_class, agent_instance_id, display_name, current_token, ws_conn); reconnected {
				fmt.println("reconnected", agent_instance_id, new_ws_url)
				current_token = new_token
				failed_heartbeats = 0
				notify_agent_token_refreshed(tmux_pane, daemon_url, new_token, agent_instance_id)
			} else {
				fmt.println("reconnect attempt failed", agent_instance_id)
			}
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
		time.sleep(10 * time.Second)
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

handle_task_event :: proc(text, tmux_pane, agent_instance_id: string) {
	task_id := extract_json_string(text, "task_id", "unknown")
	status := extract_json_string(text, "status", "updated")
	changed_by := extract_json_string(text, "changed_by", "unknown")
	if changed_by == agent_instance_id {
		fmt.println("suppressed self-authored task event", task_id, status, changed_by)
		return
	}
	body := extract_json_string(text, "body", "")
	
	template_str := active_live_prefs.msg_task_updated if body != "" else active_live_prefs.msg_task_updated_empty
	interrupt_val := active_live_prefs.msg_task_updated_int if body != "" else active_live_prefs.msg_task_updated_empty_int

	line := template_live_message(
		template_str,
		0, "",
		task_id, status, changed_by, body, "", "", "", "", "", "", 0,
	)
	defer delete(line)

	escape_prefix := interrupt_val || strings.index(text, `"send_escape_prefix":true`) >= 0 || strings.index(body, "delivery=escape_prefixed_pane_or_ws") >= 0

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
	subject_agent := extract_json_string(text, "subject_agent", "")
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
		"", "", changed_by, "", target_id, event, subject_agent, "", "", "", 0,
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

	line := template_live_message(
		active_live_prefs.msg_user_chat,
		pending_count, "",
		"", "", "", "", "", "", "", user_id, "", "", 0,
	)
	defer delete(line)

	if tmux.send_line_with_escape(tmux_pane, line, active_live_prefs.msg_user_chat_int) {
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

reregister_and_reconnect_ws :: proc(daemon_url, agent_class, agent_instance_id, display_name, agent_token: string, ws_conn: ^ws.Connection) -> (new_ws_url: string, new_token: string, ok: bool) {
	response, health_ok := http.get(daemon_url, contracts.ROUTE_HEALTH)
	if !health_ok || response.status != 200 do return "", "", false

	register_body := register_request_json(agent_class, agent_instance_id, display_name, agent_token)
	register_response, register_ok := http.post(daemon_url, contracts.ROUTE_REGISTER, register_body)
	if !register_ok || register_response.status != 200 {
		if register_ok {
			fmt.println("re-registration failed", register_response.status, register_response.body)
		}
		return "", "", false
	}

	ws_url := extract_json_string(register_response.body, "ws_url", "")
	token  := extract_json_string(register_response.body, "agent_token", agent_token)
	prefs_obj := extract_json_object(register_response.body, "preferences")
	defer if prefs_obj != "" do delete(prefs_obj)
	apply_preferences_json(prefs_obj)
	if ws_url == "" do return "", "", false

	ws.close(ws_conn)
	new_conn, ws_ok := ws.connect(ws_url)
	if !ws_ok do return ws_url, token, false
	ws_conn^ = new_conn
	return ws_url, token, true
}

heartbeat_request_json :: proc(agent_instance_id, agent_token, display_name, provider_profile, provider_tier, project_id, tmux_pane, run_dir, exec_state, blocked_reason, startup_status, startup_reason_code, startup_safe_diagnostic: string, pid: int, exec_state_since_unix_ms: i64) -> string {
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
	strings.write_string(&b, `","pid":`); strings.write_string(&b, fmt.tprintf("%d", pid))
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
	escaped := false
	for ch in value {
		if escaped {
			switch ch {
			case 'n': strings.write_rune(&builder, '\n')
			case 'r': strings.write_rune(&builder, '\r')
			case 't': strings.write_rune(&builder, '\t')
			case '"': strings.write_rune(&builder, '"')
			case '\\': strings.write_rune(&builder, '\\')
			case: strings.write_rune(&builder, ch)
			}
			escaped = false
		} else if ch == '\\' {
			escaped = true
		} else {
			strings.write_rune(&builder, ch)
		}
	}
	if escaped do strings.write_rune(&builder, '\\')
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
	fmt.println("usage: ham-wrapper [--config <path>] [--agent <name>] [--agent-token <token>] [--detach] [--version] [--help] [agent|agent@suffix]")
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
	cwd := join_path3(base, safe_slug(project), safe_slug(agent_name))
	_ = os.make_directory_all(cwd)
	return cwd
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
	scope:                 string,
	is_configured_template: bool,
}

fetch_all_active_memories :: proc(daemon_url, agent_token, agent_instance_id: string, memory_templates: []string) -> [dynamic]Memory_Record {
	result := make([dynamic]Memory_Record)
	configured_ids := make(map[string]bool)

	if len(memory_templates) > 0 {
		req := strings.builder_make()
		strings.write_string(&req, `{"agent_token":"`); json_write_string(&req, agent_token)
		strings.write_string(&req, `","action":"memory_list","status":"active"}`)
		resp, ok := http.post(daemon_url, contracts.ROUTE_AGENT_RPC, strings.to_string(req))
		if ok && resp.status == 200 {
			parse_into_memory_records(resp.body, memory_templates, true, &result, &configured_ids)
		}
	}

	req2 := strings.builder_make()
	strings.write_string(&req2, `{"agent_token":"`); json_write_string(&req2, agent_token)
	strings.write_string(&req2, `","action":"memory_list","subject_agent":"`); json_write_string(&req2, agent_instance_id)
	strings.write_string(&req2, `","status":"active"}`)
	resp2, ok2 := http.post(daemon_url, contracts.ROUTE_AGENT_RPC, strings.to_string(req2))
	if ok2 && resp2.status == 200 {
		parse_into_memory_records(resp2.body, memory_templates, false, &result, &configured_ids)
	}

	return result
}

parse_into_memory_records :: proc(body: string, memory_templates: []string, templates_only: bool, result: ^[dynamic]Memory_Record, configured_ids: ^map[string]bool) {
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
		scope := extract_json_string(object, "scope", "")
		is_configured_template := type_text == "template" && memory_template_matches(object, memory_templates)

		if templates_only {
			if !is_configured_template { idx = end; continue }
			configured_ids^[memory_id] = true
			append(result, Memory_Record{memory_id = memory_id, type_text = type_text, title = title, body = body_text, scope = scope, is_configured_template = true})
		} else {
			if _, seen := configured_ids^[memory_id]; seen { idx = end; continue }
			append(result, Memory_Record{memory_id = memory_id, type_text = type_text, title = title, body = body_text, scope = scope, is_configured_template = false})
		}
		idx = end
	}
}

generate_bootstrap_files :: proc(cwd, config_path: string, cfg: cfg_lib.Wrapper_Config, agent_cmd: cfg_lib.Agent_Command_Config, selected_agent, agent_instance_id, display_name, daemon_url, agent_token, template_instructions: string) {
	profile := bootstrap_profile(agent_cmd, selected_agent)
	memory_templates := agent_cmd.memory_templates
	if len(memory_templates) == 0 do memory_templates = cfg.memory_templates
	project_context := project_bootstrap_context(daemon_url, agent_token, cfg, agent_cmd)
	memories := fetch_all_active_memories(daemon_url, agent_token, agent_instance_id, memory_templates)

	written := make([dynamic]string)

	// AGENTS_MD (CLAUDE.md for claude profile, AGENTS.md otherwise)
	{
		fc := agent_cmd.bootstrap.features["AGENTS_MD"]
		name := fc.name
		if name == "" {
			if profile == "claude" { name = "CLAUDE.md" } else { name = "AGENTS.md" }
		}
		content_sections := fc.content
		if len(content_sections) == 0 {
			content_sections = []string{"IDENTITY", "GUIDANCE", "PROJECT", "MEMORY"}
		}
		path := join_path(cwd, name)
		if can_write_managed_file(path) {
			text := build_agents_md(name, profile, content_sections, selected_agent, agent_instance_id, display_name, daemon_url, agent_token, config_path, memories[:], project_context, true, template_instructions)
			write_managed_file(path, text)
			append(&written, name)
		}
	}

	// MEMORY_MD
	{
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

	cleanup_removed_bootstrap_files(cwd, written[:])
	write_manifest(cwd, written[:])
}

content_section_enabled :: proc(sections: []string, section: string) -> bool {
	if len(sections) == 0 do return true
	for item in sections {
		if item == section || item == "ALL" || item == "all" do return true
	}
	return false
}

build_agents_md :: proc(name, profile: string, content_sections: []string, selected_agent, agent_instance_id, display_name, daemon_url, agent_token, config_path: string, memories: []Memory_Record, project_context: string, has_memory_md: bool, template_instructions: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, active_live_prefs.bootstrap_header); strings.write_string(&b, "\n")
	strings.write_string(&b, bootstrap_title(name, profile)); strings.write_string(&b, "\n\n")
	if content_section_enabled(content_sections, "IDENTITY") {
		strings.write_string(&b, "FIRST RUN: `")
		strings.write_string(&b, effective_ctl_bin())
		strings.write_string(&b, " --daemon-url ")
		strings.write_string(&b, daemon_url)
		strings.write_string(&b, " --token ")
		strings.write_string(&b, agent_token)
		strings.write_string(&b, " start-success` — this tells Heimdall you are alive. Do this before anything else. (No --config needed; ham-ctl finds it at ~/.config/heimdall/config.toml. Run this command verbatim from any directory.)\n\n")
		strings.write_string(&b, "- Display name: "); strings.write_string(&b, display_name); strings.write_string(&b, "\n")
		strings.write_string(&b, "- Agent instance: "); strings.write_string(&b, agent_instance_id); strings.write_string(&b, "\n")
		strings.write_string(&b, "- Provider/profile: "); strings.write_string(&b, selected_agent); strings.write_string(&b, " / "); strings.write_string(&b, profile); strings.write_string(&b, "\n")
		strings.write_string(&b, "- Daemon URL: "); strings.write_string(&b, daemon_url); strings.write_string(&b, "\n")
		strings.write_string(&b, "- This file is generated by Heimdall and is overwritten on agent start. Unmanaged files are preserved.\n")
		if template_instructions != "" {
			strings.write_string(&b, "\n# Template Instructions\n")
			strings.write_string(&b, template_instructions)
			strings.write_string(&b, "\n")
		}
	}
	if content_section_enabled(content_sections, "GUIDANCE") {
		templated_guidance := template_guidance_string(active_live_prefs.bootstrap_profile_guidance, profile, name, agent_instance_id)
		strings.write_string(&b, templated_guidance)
		delete(templated_guidance)
	}
	if content_section_enabled(content_sections, "PROJECT") && project_context != "" {
		strings.write_string(&b, project_context)
	}
	if content_section_enabled(content_sections, "MEMORY") {
		mem_str := render_memory_for_agents_md(memories, has_memory_md)
		if mem_str != "" do strings.write_string(&b, mem_str)
	}
	return strings.to_string(b)
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
			content_b := strings.builder_make()
			strings.write_string(&content_b, active_live_prefs.bootstrap_header); strings.write_string(&content_b, "\n")
			strings.write_string(&content_b, m.body); strings.write_string(&content_b, "\n")
			write_managed_file(file_abs, strings.to_string(content_b))
			append(&written, file_rel)
		}
	}
	return written[:]
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
	return strings.has_prefix(string(data), BOOTSTRAP_HEADER) || strings.has_prefix(string(data), active_live_prefs.bootstrap_header)
}

file_has_managed_header :: proc(path: string) -> bool {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return false
	return strings.has_prefix(string(data), BOOTSTRAP_HEADER) || strings.has_prefix(string(data), active_live_prefs.bootstrap_header)
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

bootstrap_profile_guidance :: proc(profile, file_name: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "\n# Heimdall Tooling\n")
	strings.write_string(&builder, "- Use repo-local `")
	strings.write_string(&builder, effective_ctl_bin())
	strings.write_string(&builder, " --config ./config.toml ...` for Heimdall task, chat, project, and memory workflows when available.\n")
	strings.write_string(&builder, "- Track non-trivial/verifiable work in Heimdall tasks; keep status current and request review when complete.\n")
	if profile == "claude" {
		strings.write_string(&builder, "- Claude profile: this generated `CLAUDE.md` is the primary local instruction file. Keep tool/reference notes concise and fetch details through Heimdall CLI/RPC when needed.\n")
	} else if profile == "codex" {
		strings.write_string(&builder, "- Codex profile: this generated `AGENTS.md` follows repository-agent instruction conventions. Prefer scoped, auditable edits and run relevant validation before handoff.\n")
	} else {
		strings.write_string(&builder, "- Pi profile: this generated `AGENTS.md` is the primary run-directory instruction file. Read inbox/task state before beginning new work.\n")
	}
	strings.write_string(&builder, "\n# Agent Operating Rules\n")
	strings.write_string(&builder, "These rules govern how you work. Follow them every session.\n\n")
	strings.write_string(&builder, "## 1. Always track work in Heimdall tasks\n")
	strings.write_string(&builder, "Every non-trivial unit of work must be tracked in a Heimdall task. On startup:\n")
	strings.write_string(&builder, "- Run `tasks next` to claim your assigned work. If a task is already `in_progress` for you, continue it.\n")
	strings.write_string(&builder, "- Check `inbox` for pending messages before starting anything new.\n")
	strings.write_string(&builder, "- Do not start new work without a task to anchor it.\n\n")
	strings.write_string(&builder, "## 2. Ad-hoc work goes in the ad-hoc chain\n")
	strings.write_string(&builder, "If a user asks you to do something that is not part of your current assigned task chain, create or reuse a chain called `ad-hoc-<your-agent-instance-id>` (e.g. `ad-hoc-myagent@default`). Create a task in that chain, do the work, and mark it complete. This keeps all work auditable.\n\n")
	strings.write_string(&builder, "## 3. Always reply to user@operator messages\n")
	strings.write_string(&builder, "When you receive a message from `user@operator` (or any user), always send a reply via `chat send-to-user`. Never leave a user message unanswered. Acknowledge receipt even if you need time to complete the work.\n")
	strings.write_string(&builder, "* **CRITICAL INSTRUCTION**: User chat messages always need to be responded to by using the ham-ctl chat subcommand. Consider them as an extension of the user.\n\n")
	strings.write_string(&builder, "## 4. Confirm before acting on unverified requests\n")
	strings.write_string(&builder, "If a user asks you to do something and you have no task evidence or memory that this was previously planned and approved:\n")
	strings.write_string(&builder, "1. Do NOT start the work.\n")
	strings.write_string(&builder, "2. Send the user a plan of action via `chat send-to-user` describing what you will do and why.\n")
	strings.write_string(&builder, "3. Wait for confirmation before proceeding.\n")
	strings.write_string(&builder, "This prevents unauthorized work and keeps the user in control.\n\n")
	strings.write_string(&builder, "## 5. Document Artifacts and Follow-up in Tasks\n")
	strings.write_string(&builder, "To keep specs and guidelines auditable and clear for future agents:\n")
	strings.write_string(&builder, "1. Chain-wide artifacts, specifications, and plans must be captured in the task chain description. On startup, agents must read this description via `task-chains show` to align on goals (Chain-level Specifications).\n")
	strings.write_string(&builder, "2. Task-specific specifications must be captured in the task description.\n")
	strings.write_string(&builder, "3. Follow-up items, notes, git commit hashes, and progress updates must be captured in task comments. Do not rely on local conversation history; task comments serve as the source of truth if the agent process restarts (Continuous Progress Logging).\n")
	strings.write_string(&builder, "4. Tasks with unresolved comments cannot be marked as done.\n")
	strings.write_string(&builder, "5. Reviewer LGTM and NGTM votes automatically post resolved/unresolved comments on the task. To resubmit, the assignee must first resolve all unresolved comments using `comment-resolve`.\n")
	strings.write_string(&builder, "6. To request updates or redo an approved task, reviewers/users must add an unresolved comment, which automatically reverts the task to ready.\n")
	strings.write_string(&builder, "7. On boot/restart, agents must run `task-chains show` and inspect the status/comments of all preceding tasks in the chain to build a full picture of what has been built and what is pending (Chain History Auditing).\n")
	strings.write_string(&builder, "8. Querying specialist agents: when you require information, reviews, code changes, or assistance from another agent, create a task in the chain assigned to that specialist agent and add yourself as a participant with the `lgtm_required` role (asker-as-reviewer pattern). This ensures structured tracking of the query.\n")
	strings.write_string(&builder, "9. Direct messages/nudges are not reliable: direct chat messages or task nudges are not guaranteed to be delivered or handled reliably for blocked communication. Always use formal task assignments, status updates, and comments to communicate blockage or requests for action.\n")
	strings.write_string(&builder, "\n# Ham-ctl CLI Reference\n")
	strings.write_string(&builder, "All commands use: `")
	strings.write_string(&builder, effective_ctl_bin())
	strings.write_string(&builder, " --config ./config.toml <command> --token <your-token> [flags]`\n")
	strings.write_string(&builder, "\n## List and start agents\n")
	strings.write_string(&builder, "```\n")
	strings.write_string(&builder, "# List all known/connected agents\n")
	strings.write_string(&builder, "agents list\n")
	strings.write_string(&builder, "# => {\"agents\":[{\"agent_instance_id\":\"coder@project-123\",\"connected\":true,...}]}\n")
	strings.write_string(&builder, "\n")
	strings.write_string(&builder, "# Start an agent in a detached tmux window\n")
	strings.write_string(&builder, "agents start <agent-instance-id> --agent claude --detached\n")
	strings.write_string(&builder, "# => {\"ok\":true,\"mode\":\"detached\",\"agent_token\":\"agt_...\",\"wrapper_log\":\"/path/to/log\"}\n")
	strings.write_string(&builder, "```\n")
	strings.write_string(&builder, "\n## Create a task chain and tasks\n")
	strings.write_string(&builder, "```\n")
	strings.write_string(&builder, "# 1. Create a task chain in planning state (design doc goes in description)\n")
	strings.write_string(&builder, "task-chains create --title \"Implement feature X\" \\\n")
	strings.write_string(&builder, "  --description \"Goal: ...\nScope: ...\nApproach: ...\nAcceptance: ...\" \\\n")
	strings.write_string(&builder, "  --coordinator <coordinator-agent-instance-id>\n")
	strings.write_string(&builder, "# => {\"ok\":true,\"chain_id\":\"chain-abc123\",\"status\":\"planning\"}\n")
	strings.write_string(&builder, "\n")
	strings.write_string(&builder, "# 2. Create tasks with dependencies (task_id is always daemon-generated)\n")
	strings.write_string(&builder, "tasks create --chain-id <chain-id> --title \"Write unit tests\" \\\n")
	strings.write_string(&builder, "  --description \"Add test coverage for feature X\" \\\n")
	strings.write_string(&builder, "  --assignee <assignee-agent-instance-id> \\\n")
	strings.write_string(&builder, "  --coordinator <coordinator-agent-instance-id> \\\n")
	strings.write_string(&builder, "  --depends-on <task-id-of-predecessor>\n")
	strings.write_string(&builder, "# => {\"ok\":true,\"task_id\":\"task-def456\",\"chain_id\":\"chain-abc123\"}\n")
	strings.write_string(&builder, "\n")
	strings.write_string(&builder, "# 3. Add reviewers to a task (lgtm_required gates approval; lgtm_optional is informational)\n")
	strings.write_string(&builder, "tasks participant --task-id <task-id> --agent-instance-id <reviewer> --role lgtm_required\n")
	strings.write_string(&builder, "tasks participant --task-id <task-id> --agent-instance-id <watcher> --role lgtm_optional\n")
	strings.write_string(&builder, "\n")
	strings.write_string(&builder, "# 4. Activate the chain — tasks auto-promote and assignees are notified\n")
	strings.write_string(&builder, "task-chains activate --chain-id <chain-id>\n")
	strings.write_string(&builder, "# => {\"ok\":true,\"chain_id\":\"chain-abc123\",\"status\":\"in_progress\"}\n")
	strings.write_string(&builder, "\n")
	strings.write_string(&builder, "# Ad-hoc work: use a chain named ad-hoc-<your-agent-instance-id>\n")
	strings.write_string(&builder, "task-chains create --title \"Ad-hoc: <brief description>\" --description \"...\" \\\n")
	strings.write_string(&builder, "  --coordinator <your-agent-instance-id>\n")
	strings.write_string(&builder, "```\n")
	strings.write_string(&builder, "\n## Work a task to completion\n")
	strings.write_string(&builder, "```\n")
	strings.write_string(&builder, "# Claim the next ready task assigned to you\n")
	strings.write_string(&builder, "tasks next\n")
	strings.write_string(&builder, "\n")
	strings.write_string(&builder, "# Inspect a task\n")
	strings.write_string(&builder, "tasks show --task-id <task-id>\n")
	strings.write_string(&builder, "\n")
	strings.write_string(&builder, "# Fetch unresolved comments before responding to a nudge\n")
	strings.write_string(&builder, "tasks comments --task-id <task-id> --unresolved\n")
	strings.write_string(&builder, "\n")
	strings.write_string(&builder, "# Log progress with git commits for audit trail\n")
	strings.write_string(&builder, "tasks comment --task-id <task-id> --chain-id <chain-id> --body \\\n")
	strings.write_string(&builder, "  \"Progress: implemented X\n\nCommits:\n- abc1234: add X\n\nDecisions:\n- chose Y over Z because ...\n\nNext: submit for review\"\n")
	strings.write_string(&builder, "\n")
	strings.write_string(&builder, "# Update status using intent subcommands\n")
	strings.write_string(&builder, "tasks done --task-id <task-id> --chain-id <chain-id> --comment \"All tests written and passing\"\n")
	strings.write_string(&builder, "tasks blocked --task-id <task-id> --chain-id <chain-id> --reason \"Waiting on external API key\"\n")
	strings.write_string(&builder, "tasks later --task-id <task-id> --chain-id <chain-id> --reason \"Postponing for now\"\n")
	strings.write_string(&builder, "\n")
	strings.write_string(&builder, "# Resolve a comment once addressed\n")
	strings.write_string(&builder, "tasks comment-resolve --task-id <task-id> --comment-id <cmt-id>\n")
	strings.write_string(&builder, "\n")
	strings.write_string(&builder, "# Reviewer votes (lgtm approves, ngtm rejects and returns task to in_progress)\n")
	strings.write_string(&builder, "tasks vote --task-id <task-id> --chain-id <chain-id> --result lgtm --comment \"Looks good\"\n")
	strings.write_string(&builder, "tasks vote --task-id <task-id> --chain-id <chain-id> --result ngtm --comment \"auth.odin:47 — fix error handling\"\n")
	strings.write_string(&builder, "\n")
	strings.write_string(&builder, "# Chain completes automatically when all tasks are approved\n")
	strings.write_string(&builder, "# To complete manually with a summary:\n")
	strings.write_string(&builder, "task-chains complete --chain-id <chain-id> --summary \"Feature X delivered and reviewed\"\n")
	strings.write_string(&builder, "# => {\"ok\":true,\"archive_ok\":true}\n")
	strings.write_string(&builder, "```\n")
	strings.write_string(&builder, "\n## Messages\n")
	strings.write_string(&builder, "```\n")
	strings.write_string(&builder, "# Read your agent inbox\n")
	strings.write_string(&builder, "inbox\n")
	strings.write_string(&builder, "\n")
	strings.write_string(&builder, "# Send a message to another agent\n")
	strings.write_string(&builder, "send --to <agent-instance-id> --body \"Please review task-def456\"\n")
	strings.write_string(&builder, "\n")
	strings.write_string(&builder, "# Read chat messages from a user\n")
	strings.write_string(&builder, "chat fetch-user --user-id user@operator\n")
	strings.write_string(&builder, "\n")
	strings.write_string(&builder, "# Reply to a user (ALWAYS do this after receiving a message)\n")
	strings.write_string(&builder, "chat send-to-user --user-id user@operator --body \"Acknowledged. Here is my plan: ...\"\n")
	strings.write_string(&builder, "```\n")
	strings.write_string(&builder, "\n## Memory\n")
	strings.write_string(&builder, "```\n")
	strings.write_string(&builder, "# Propose a new memory item (type: fact | habit | episode | expertise | skill | template)\n")
	strings.write_string(&builder, "memory propose new --subject-agent <agent-instance-id> --type fact \\\n")
	strings.write_string(&builder, "  --title \"Prefers concise PR descriptions\" \\\n")
	strings.write_string(&builder, "  --body \"Agent prefers short, bullet-point PR descriptions over long prose.\" \\\n")
	strings.write_string(&builder, "  --reason \"Observed during code review\" --evidence <task-id>\n")
	strings.write_string(&builder, "# => {\"ok\":true,\"memory_id\":\"mem_123\",\"proposal_id\":\"proposal_123\"}\n")
	strings.write_string(&builder, "\n")
	strings.write_string(&builder, "# List pending proposals\n")
	strings.write_string(&builder, "memory list --status pending\n")
	strings.write_string(&builder, "\n")
	strings.write_string(&builder, "# Approve or reject a proposal\n")
	strings.write_string(&builder, "memory decide --proposal-id <proposal-id> --decision approve|reject\n")
	strings.write_string(&builder, "\n")
	strings.write_string(&builder, "# Edit an existing memory (use --expected-version to prevent conflicts)\n")
	strings.write_string(&builder, "memory propose edit --memory-id <id> --expected-version 1 \\\n")
	strings.write_string(&builder, "  --title <new-title> --body <new-body> --reason <why> --evidence <source>\n")
	strings.write_string(&builder, "```\n")
	return strings.to_string(builder)
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

build_agent_command :: proc(cfg: cfg_lib.Wrapper_Config, selected_agent, daemon_url, agent_instance_id, display_name, conversation_id, agent_token, model_tier: string) -> []string {
	agent_command_name := selected_agent
	if agent_command_name == "" do agent_command_name = command_name_for_agent(cfg.command, cfg.agent_name)
	for agent_cmd in cfg.agent_commands {
		if agent_cmd.name == agent_command_name {
			base := agent_cmd.command
			if len(base) == 0 do base = cfg.command
			count := len(base) + len(agent_cmd.yolo_flags) + len(agent_cmd.prompt_flags)
			if active_live_prefs.starter_prompt != "" do count += 1
			result := make([dynamic]string, 0, count)
			append_templated_args(&result, base, daemon_url, agent_instance_id, display_name, conversation_id, agent_token)
			append_templated_args(&result, agent_cmd.yolo_flags, daemon_url, agent_instance_id, display_name, conversation_id, agent_token)
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
			append_templated_args(&result, agent_cmd.prompt_flags, daemon_url, agent_instance_id, display_name, conversation_id, agent_token)
			if is_test_token(agent_token) {
				// Test agents get a minimal one-shot prompt; skip memory guidance.
				prompt := template_string(TEST_AGENT_STARTER_PROMPT, daemon_url, agent_instance_id, display_name, conversation_id, agent_token)
				append(&result, prompt)
			} else if active_live_prefs.starter_prompt != "" {
				prompt := template_string(active_live_prefs.starter_prompt, daemon_url, agent_instance_id, display_name, conversation_id, agent_token)
				append(&result, prompt)
			}
			return result[:]
		}
	}
	return template_command(cfg.command, daemon_url, agent_instance_id, display_name, conversation_id, agent_token)
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
	strings.write_string(&builder, " --subject-agent <agent> --type fact|habit|episode|expertise|skill|template --title <title> --body <body> --reason <why> --evidence <task-or-source>; ")
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

active_memory_bootstrap :: proc(daemon_url, agent_token, agent_instance_id: string, memory_templates: []string) -> string {
	builder := strings.builder_make()
	if len(memory_templates) > 0 {
		all_request := strings.builder_make()
		strings.write_string(&all_request, `{"agent_token":"`); json_write_string(&all_request, agent_token)
		strings.write_string(&all_request, `","action":"memory_list","status":"active"}`)
		all_response, all_ok := http.post(daemon_url, contracts.ROUTE_AGENT_RPC, strings.to_string(all_request))
		if all_ok && all_response.status == 200 {
			strings.write_string(&builder, format_active_memory_bootstrap(all_response.body, memory_templates, true))
		}
	}
	request := strings.builder_make()
	strings.write_string(&request, `{"agent_token":"`); json_write_string(&request, agent_token)
	strings.write_string(&request, `","action":"memory_list","subject_agent":"`); json_write_string(&request, agent_instance_id)
	strings.write_string(&request, `","status":"active"}`)
	response, ok := http.post(daemon_url, contracts.ROUTE_AGENT_RPC, strings.to_string(request))
	if ok && response.status == 200 do strings.write_string(&builder, format_active_memory_bootstrap(response.body, memory_templates, false))
	return strings.to_string(builder)
}

format_active_memory_bootstrap :: proc(body: string, memory_templates: []string, templates_only: bool) -> string {
	builder := strings.builder_make()
	wrote_header := false
	wrote_skills := false
	idx := 0
	for {
		start_rel := strings.index(body[idx:], `{"memory_id":"`)
		if start_rel < 0 do break
		start := idx + start_rel
		end := json_object_end(body, start)
		if end <= start do break
		object := body[start:end]
		status := extract_json_string(object, "status", "")
		type_text := extract_json_string(object, "type", "fact")
		// When templates_only=false, skip template memories already shown in the templates section
		already_shown_as_template := !templates_only && type_text == "template" && len(memory_templates) > 0 && memory_template_matches(object, memory_templates)
		if status == "active" && !already_shown_as_template && (!templates_only || (type_text == "template" && memory_template_matches(object, memory_templates))) {
			if !wrote_header {
				if templates_only {
					strings.write_string(&builder, "\n\n# Active Approved Memory Templates\nOnly configured, approved active template memories are included here; pending, rejected, and archived templates are excluded.\n")
				} else {
					strings.write_string(&builder, "\n\n# Active Approved Memory\nOnly active approved memory is included here; pending, rejected, and archived proposals are excluded.\n")
				}
				wrote_header = true
			}
			title := extract_json_string(object, "title", "")
			memory_body := extract_json_string(object, "body", "")
			if type_text == "skill" {
				if !wrote_skills {
					strings.write_string(&builder, "\n## Skills\n")
					wrote_skills = true
				}
				strings.write_string(&builder, "\n### "); strings.write_string(&builder, title); strings.write_string(&builder, "\n")
				strings.write_string(&builder, memory_body); strings.write_string(&builder, "\n")
			} else {
				strings.write_string(&builder, "\n- "); strings.write_string(&builder, type_text); strings.write_string(&builder, ": ")
				if title != "" { strings.write_string(&builder, title); strings.write_string(&builder, " — ") }
				strings.write_string(&builder, memory_body); strings.write_string(&builder, "\n")
			}
		}
		idx = end
	}
	if !wrote_header do return ""
	return strings.to_string(builder)
}

memory_template_matches :: proc(object: string, memory_templates: []string) -> bool {
	memory_id := extract_json_string(object, "memory_id", "")
	title := extract_json_string(object, "title", "")
	scope := extract_json_string(object, "scope", "")
	for item in memory_templates {
		if item == memory_id || item == title || item == scope do return true
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

append_templated_args :: proc(result: ^[dynamic]string, args: []string, daemon_url, agent_instance_id, display_name, conversation_id, agent_token: string) {
	for arg in args {
		append(result, template_string(arg, daemon_url, agent_instance_id, display_name, conversation_id, agent_token))
	}
}

template_command :: proc(command: []string, daemon_url, agent_instance_id, display_name, conversation_id, agent_token: string) -> []string {
	result := make([]string, len(command))
	for i in 0..<len(command) {
		result[i] = template_string(command[i], daemon_url, agent_instance_id, display_name, conversation_id, agent_token)
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

template_string :: proc(value, daemon_url, agent_instance_id, display_name, conversation_id, agent_token: string) -> string {
	ctl_bin := effective_ctl_bin()
	templated := replace_all(value, "{daemon_url}", daemon_url)
	templated = replace_all(templated, "{agent_instance_id}", agent_instance_id)
	templated = replace_all(templated, "{display_name}", display_name)
	templated = replace_all(templated, "{instance}", agent_instance_id)
	templated = replace_all(templated, "{conversation_id}", conversation_id)
	templated = replace_all(templated, "{agent_token}", agent_token)
	templated = replace_all(templated, "{token}", agent_token)
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
		if args[i] == cfg_lib.CONFIG_PATH_FLAG || args[i] == "--agent" || args[i] == "--agent-token" || args[i] == "--display-name" || args[i] == "--tier" || args[i] == "--project-id" {
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
	active_live_prefs.bootstrap_profile_guidance = "# Default Guidance..."
	active_live_prefs.msg_agent_message = "{pending_count} Unread Messages from {from_agent_id}."
	active_live_prefs.msg_agent_message_int = false
	active_live_prefs.msg_task_updated = "Task {task_id} {status} by {changed_by}: {body}"
	active_live_prefs.msg_task_updated_int = false
	active_live_prefs.msg_task_updated_empty = "Task {task_id} {status} by {changed_by}."
	active_live_prefs.msg_task_updated_empty_int = false
	active_live_prefs.msg_memory_updated = "Memory {memory_id} {event} by {changed_by} for {subject_agent} ({status}). Fetch details with: {ctl_bin} memory show --token <your token> --memory-id {memory_id}"
	active_live_prefs.msg_memory_updated_int = false
	active_live_prefs.msg_memory_proposal_updated = "Memory proposal {proposal_id} {event} by {changed_by} for {subject_agent}. Review with: {ctl_bin} memory history --token <your token> --memory-id {memory_id}"
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

template_live_message :: proc(template_str: string, pending_count: int, from_agent_id, task_id, status, changed_by, body, memory_id, event, subject_agent, user_id, new_token, daemon_url: string, time_val: int, allocator := context.allocator) -> string {
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
	res = replace_all(res, "{subject_agent}", subject_agent)
	res = replace_all(res, "{user_id}", user_id)
	res = replace_all(res, "{new_token}", new_token)
	res = replace_all(res, "{daemon_url}", daemon_url)
	res = replace_all(res, "{time}", fmt.tprintf("%d", time_val))
	res = replace_all(res, "{ctl_bin}", effective_ctl_bin())
	
	return strings.clone(res, allocator)
}
