package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import tmux "odin_test:lib/tmux"
import ws "odin_test:lib/ws"

Bridge_Runtime_Instance :: struct {
	agent_instance_id: string,
	state_seq: int,
	runtime_status: string,
	activity_status: string,
}

Bridge_Runtime_Command_Result :: struct {
	command_id: string,
	result_json: string,
}

Bridge_Runtime_Launch :: struct {
	agent_instance_id: string,
	command_id: string,
	run_dir: string,
	tmux_session: string,
	tmux_window: string,
	pane_id: string,
	wrapper_token: string,
	agent_token: string,
}

Bridge_Provider_Test :: struct {
	test_id: string,
	provider: string,
	tier: string,
	agent_instance_id: string,
	status: string,
	message: string,
	pane_id: string,
	tmux_session: string,
	tmux_window: string,
	frame_seq: int,
}

bridge_runtime_mutex: sync.Mutex
bridge_runtime_instances: [dynamic]Bridge_Runtime_Instance
bridge_runtime_results: [dynamic]Bridge_Runtime_Command_Result
bridge_runtime_launches: [dynamic]Bridge_Runtime_Launch
bridge_provider_tests: [dynamic]Bridge_Provider_Test
bridge_runtime_local_endpoint_started: bool
bridge_runtime_local_endpoint_unix_started: bool
bridge_runtime_local_endpoint_loopback_started: bool
bridge_runtime_local_endpoint_descriptor: string

bridge_hub_runtime_init :: proc() {
	bridge_runtime_mutex = sync.Mutex{}
	bridge_runtime_instances = make([dynamic]Bridge_Runtime_Instance)
	bridge_runtime_results = make([dynamic]Bridge_Runtime_Command_Result)
	bridge_runtime_launches = make([dynamic]Bridge_Runtime_Launch)
	bridge_provider_tests = make([dynamic]Bridge_Provider_Test)
}

bridge_hub_runtime_worker :: proc() {
	if strings.trim_space(bridge_config.daemon_url) == "" || strings.trim_space(bridge_config.bridge_token) == "" do return
	for {
		ws_url := bridge_hub_ws_url(bridge_config.daemon_url)
		if ws_url == "" {
			fmt.println("bridge hub runtime disabled: daemon_url must be an http:// or https:// base URL")
			return
		}
		conn, ok := ws.connect_with_bearer(ws_url, bridge_config.bridge_token)
		if !ok {
			time.sleep(500 * time.Millisecond)
			continue
		}
		hello := bridge_hub_hello_json()
		if !ws.send_text(&conn, hello) {
			ws.close(&conn)
			time.sleep(500 * time.Millisecond)
			continue
		}
		ready_deadline := time.to_unix_nanoseconds(time.now()) + i64(5 * time.Second)
		ready := false
		for time.to_unix_nanoseconds(time.now()) < ready_deadline {
			if text, got := ws.poll_text(&conn); got {
				if extract_json_string(text, "type", "") == "bridge_ready" { ready = true; break }
				if extract_json_string(text, "type", "") == "bridge_error" do break
			}
			time.sleep(25 * time.Millisecond)
		}
		if ready {
			fmt.println("bridge hub runtime ready")
			bridge_hub_runtime_loop(&conn)
		}
		ws.close(&conn)
		time.sleep(500 * time.Millisecond)
	}
}

bridge_hub_runtime_loop :: proc(conn: ^ws.Connection) {
	last_heartbeat := time.to_unix_nanoseconds(time.now())
	for conn.connected {
		if text, got := ws.poll_text(conn); got do bridge_hub_handle_command(conn, text)
		now := time.to_unix_nanoseconds(time.now())
		if now - last_heartbeat >= i64(2 * time.Second) {
			_ = ws.send_text(conn, bridge_hub_heartbeat_json())
			last_heartbeat = now
		}
		time.sleep(25 * time.Millisecond)
	}
}

bridge_hub_handle_command :: proc(conn: ^ws.Connection, text: string) {
	type := extract_json_string(text, "type", "")
	if type == "launch_agent" {
		fmt.println("bridge hub runtime command launch_agent")
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return }
		accepted := bridge_command_result_json(command_id, "accepted", "")
		bridge_runtime_cache_command(command_id, accepted)
		_ = ws.send_text(conn, accepted)
		ok, detail := bridge_runtime_launch_agent(command_id, text)
		instance_id := extract_json_string(text, "agent_instance_id", "")
		_ = ws.send_text(conn, bridge_instance_status_json(instance_id))
		final_status := "succeeded" if ok else "failed"
		final_runtime := "starting" if ok else "failed"
		final := bridge_command_result_json(command_id, final_status, final_runtime)
		if !ok do fmt.println("bridge launch_agent failed", detail)
		bridge_runtime_cache_command(command_id, final)
		_ = ws.send_text(conn, final)
		return
	}
	if type == "stop_agent" {
		fmt.println("bridge hub runtime command stop_agent")
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return }
		accepted := bridge_command_result_json(command_id, "accepted", "")
		bridge_runtime_cache_command(command_id, accepted)
		_ = ws.send_text(conn, accepted)
		instance_id := extract_json_string(text, "agent_instance_id", "")
		ok := bridge_runtime_stop_agent(instance_id)
		_ = ws.send_text(conn, bridge_instance_status_json(instance_id))
		final := bridge_command_result_json(command_id, "succeeded" if ok else "failed", "stopped" if ok else "failed")
		bridge_runtime_cache_command(command_id, final)
		_ = ws.send_text(conn, final)
		return
	}
	if type == "notify_agent_message" {
		command_id := extract_json_string(text, "command_id", "")
		instance_id := extract_json_string(text, "agent_instance_id", "")
		ok := bridge_wrapper_push(instance_id, text)
		if command_id != "" do _ = ws.send_text(conn, bridge_command_result_json(command_id, "succeeded" if ok else "accepted", ""))
		return
	}
	if bridge_hub_handle_provider_command(conn, type, text) do return
}

bridge_hub_handle_provider_command :: proc(conn: ^ws.Connection, type, text: string) -> bool {
	switch type {
	case "list_providers":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return true }
		result := bridge_provider_profiles_report_json(bridge_config.daemon_id)
		report := bridge_providers_report_json(command_id, result)
		bridge_runtime_cache_command(command_id, report)
		_ = ws.send_text(conn, report)
		_ = ws.send_text(conn, bridge_command_result_payload_json(command_id, "succeeded", "{}"))
		return true
	case "upsert_provider":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return true }
		payload := bridge_provider_payload_object(text)
		name := bridge_provider_json_extract_string(payload, "name", "")
		profile_json, profile_ok := bridge_provider_json_extract_object(payload, "profile")
		if !profile_ok do profile_json = "{}"
		profile, ok, message := bridge_provider_upsert_override_json(name, profile_json)
		result_b := strings.builder_make()
		if ok { strings.write_string(&result_b, "{\"provider\":"); bridge_provider_write_profile_json(&result_b, profile); strings.write_byte(&result_b, '}') } else { strings.write_string(&result_b, "{\"error\":\""); bridge_runtime_write_json_string(&result_b, message); strings.write_string(&result_b, "\"}") }
		final := bridge_command_result_payload_json(command_id, "succeeded" if ok else "failed", strings.to_string(result_b))
		bridge_runtime_cache_command(command_id, final)
		_ = ws.send_text(conn, final)
		return true
	case "delete_provider":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return true }
		payload := bridge_provider_payload_object(text)
		name := bridge_provider_json_extract_string(payload, "name", "")
		deleted, message := bridge_provider_delete_override(name)
		result := "{\"deleted\":true}" if deleted else strings.concatenate({"{\"deleted\":false,\"error\":\"", bridge_runtime_json_escaped(message), "\"}"})
		final := bridge_command_result_payload_json(command_id, "succeeded" if deleted else "failed", result)
		bridge_runtime_cache_command(command_id, final)
		_ = ws.send_text(conn, final)
		return true
	case "test_provider":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return true }
		result := bridge_runtime_run_provider_test(conn, command_id, text)
		final := bridge_command_result_payload_json(command_id, "succeeded", result)
		bridge_runtime_cache_command(command_id, final)
		_ = ws.send_text(conn, final)
		return true
	case "refresh_capabilities":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return true }
		result := strings.concatenate({"{\"capabilities\":", bridge_provider_capabilities_json(), "}"})
		final := bridge_command_result_payload_json(command_id, "succeeded", result)
		bridge_runtime_cache_command(command_id, final)
		_ = ws.send_text(conn, strings.concatenate({"{\"type\":\"capability_report\",\"protocol_version\":1,\"capabilities\":", bridge_provider_capabilities_json(), "}"}))
		_ = ws.send_text(conn, final)
		return true
	}
	return false
}

bridge_runtime_launch_agent :: proc(command_id, command_json: string) -> (bool, string) {
	instance_id := extract_json_string(command_json, "agent_instance_id", "")
	if strings.trim_space(instance_id) == "" do return false, "missing agent_instance_id"
	if existing, ok := bridge_runtime_get_launch(instance_id); ok {
		_ = tmux.kill_window(existing.tmux_session, existing.tmux_window)
	}
	run_dir := extract_json_string(command_json, "project_path", "")
	if strings.trim_space(run_dir) == "" do run_dir = bridge_runtime_default_run_dir(instance_id)
	if !bridge_bootstrap_fetch_and_materialize(bridge_config.daemon_url, bridge_config.bridge_token, instance_id, run_dir) do return false, "bootstrap fetch/materialization failed"
	endpoint, endpoint_ok := bridge_runtime_ensure_local_endpoint()
	if !endpoint_ok do return false, "local endpoint unavailable"
	bridge_runtime_set_status(instance_id, "starting", "active")
	instance_token := strings.concatenate({"hit_", instance_id})
	wrapper_issue := bridge_agent_token_issue(instance_id, instance_token, .Wrapper)
	agent_issue := bridge_agent_token_issue(instance_id, instance_token, .Agent)
	session := bridge_runtime_tmux_session()
	window := bridge_runtime_tmux_window(instance_id)
	provider, tier := bridge_runtime_provider_tier(command_json)
	bridge_runtime_record_launch(Bridge_Runtime_Launch{agent_instance_id = strings.clone(instance_id), command_id = strings.clone(command_id), run_dir = strings.clone(run_dir), tmux_session = strings.clone(session), tmux_window = strings.clone(window), wrapper_token = strings.clone(wrapper_issue.plaintext_token), agent_token = strings.clone(agent_issue.plaintext_token)})
	wrapper_args := bridge_runtime_wrapper_supervisor_argv(endpoint, wrapper_issue.plaintext_token, agent_issue.plaintext_token, instance_id, run_dir, session, window, provider, tier)
	_, wrapper_err := os.process_start(os.Process_Desc{command = wrapper_args, working_dir = run_dir})
	if wrapper_err != nil {
		bridge_runtime_remove_launch(instance_id)
		bridge_runtime_set_status(instance_id, "failed", "idle")
		return false, "wrapper supervisor launch failed"
	}
	return true, ""
}

bridge_runtime_stop_agent :: proc(instance_id: string) -> bool {
	if strings.trim_space(instance_id) == "" do return false
	bridge_runtime_set_status(instance_id, "stopping", "idle")
	stopped := false
	if launch, ok := bridge_runtime_get_launch(instance_id); ok {
		stopped = tmux.kill_window(launch.tmux_session, launch.tmux_window)
		bridge_runtime_remove_launch(instance_id)
	} else {
		stopped = true
	}
	bridge_runtime_set_status(instance_id, "stopped", "idle")
	return stopped
}

bridge_runtime_run_provider_test :: proc(conn: ^ws.Connection, command_id, command_json: string) -> string {
	payload := bridge_provider_payload_object(command_json)
	provider := bridge_provider_json_extract_string(payload, "name", "")
	tier := bridge_provider_json_extract_string(payload, "tier", "")
	test_id := bridge_provider_json_extract_string(payload, "test_id", "")
	if test_id == "" do test_id = fmt.tprintf("ptest_%d", time.to_unix_nanoseconds(time.now()))
	instance_id := bridge_provider_json_extract_string(payload, "test_instance_id", "")
	if instance_id == "" do instance_id = strings.concatenate({"inst_", test_id})
	capture_frames := strings.contains(payload, "\"capture_frames\":true")
	launch_deadline_ms := bridge_runtime_provider_test_int(payload, "launch_deadline_ms", 20000, 1000, 300000)
	start_deadline_ms := bridge_runtime_provider_test_int(payload, "start_success_deadline_ms", 60000, 1000, 300000)
	hard_deadline_ms := bridge_runtime_provider_test_int(payload, "hard_deadline_ms", 90000, start_deadline_ms, 300000)
	frame_interval_ms := bridge_runtime_provider_test_int(payload, "frame_interval_ms", 500, 200, 5000)
	if profile, profile_ok := bridge_provider_by_name_or_default(provider); !profile_ok || !profile.enabled || len(profile.command) == 0 {
		msg := "provider has no runnable command"
		_ = ws.send_text(conn, bridge_provider_test_status_json(test_id, "failed", "done", msg, ""))
		return bridge_provider_test_result_json(test_id, provider, "failed", msg, "")
	}
	endpoint, endpoint_ok := bridge_runtime_ensure_local_endpoint()
	if !endpoint_ok {
		msg := "local endpoint unavailable"
		_ = ws.send_text(conn, bridge_provider_test_status_json(test_id, "failed", "done", msg, ""))
		return bridge_provider_test_result_json(test_id, provider, "failed", msg, "")
	}
	_ = bridge_provider_test_cancel_provider(provider)
	run_dir := bridge_runtime_default_run_dir(instance_id)
	_ = os.make_directory_all(run_dir)
	instance_token := strings.concatenate({"hit_", instance_id})
	wrapper_issue := bridge_agent_token_issue(instance_id, instance_token, .Wrapper)
	agent_issue := bridge_agent_token_issue(instance_id, instance_token, .Agent)
	session := "heimdall-bridge-test"
	window := strings.concatenate({"ptest-", bridge_runtime_safe_part(test_id)})
	_ = ws.send_text(conn, bridge_provider_test_status_json(test_id, "launching", "launching", "launching provider test", ""))
	test_start_ns := time.to_unix_nanoseconds(time.now())
	hard_deadline_abs_ns := test_start_ns + i64(time.Duration(hard_deadline_ms) * time.Millisecond)
	launch_deadline_ns := test_start_ns + i64(time.Duration(launch_deadline_ms) * time.Millisecond)
	if launch_deadline_ns > hard_deadline_abs_ns do launch_deadline_ns = hard_deadline_abs_ns
	bridge_runtime_record_launch(Bridge_Runtime_Launch{agent_instance_id = strings.clone(instance_id), command_id = strings.clone(command_id), run_dir = strings.clone(run_dir), tmux_session = strings.clone(session), tmux_window = strings.clone(window), wrapper_token = strings.clone(wrapper_issue.plaintext_token), agent_token = strings.clone(agent_issue.plaintext_token)})
	wrapper_args := bridge_runtime_wrapper_supervisor_argv(endpoint, wrapper_issue.plaintext_token, agent_issue.plaintext_token, instance_id, run_dir, session, window, provider, tier)
	_, wrapper_err := os.process_start(os.Process_Desc{command = wrapper_args, working_dir = run_dir})
	if wrapper_err != nil {
		msg := "wrapper supervisor launch failed"
		_ = ws.send_text(conn, bridge_provider_test_status_json(test_id, "failed", "done", msg, ""))
		_ = tmux.kill_window(session, window)
		bridge_runtime_remove_launch(instance_id)
		bridge_runtime_set_status(instance_id, "stopped", "idle")
		return bridge_provider_test_result_json(test_id, provider, "failed", msg, "")
	}
	startup_seen := false
	startup_failed := false
	startup_message := ""
	pane_id := ""
	last_launch_status_ns := test_start_ns
	for time.to_unix_nanoseconds(time.now()) < launch_deadline_ns {
		now_launch := time.to_unix_nanoseconds(time.now())
		if launch, launch_ok := bridge_runtime_get_launch(instance_id); launch_ok && strings.trim_space(launch.pane_id) != "" do pane_id = launch.pane_id
		if inst, inst_ok := bridge_runtime_instance_snapshot(instance_id); inst_ok {
			if inst.runtime_status == "failed" || inst.runtime_status == "stopped" { startup_failed = true; startup_message = strings.concatenate({"provider process ", inst.runtime_status}); break }
			if pane_id != "" { startup_seen = true; break }
		}
		if now_launch - last_launch_status_ns >= i64(15 * time.Second) {
			_ = ws.send_text(conn, bridge_provider_test_status_json(test_id, "launching", "launching", "launching provider test", ""))
			last_launch_status_ns = now_launch
		}
		time.sleep(100 * time.Millisecond)
	}
	if startup_failed || !startup_seen || pane_id == "" {
		msg := startup_message
		if msg == "" do msg = "provider launch deadline exceeded"
		_ = ws.send_text(conn, bridge_provider_test_status_json(test_id, "failed", "done", msg, ""))
		_ = tmux.kill_window(session, window)
		bridge_runtime_remove_launch(instance_id)
		bridge_runtime_set_status(instance_id, "stopped", "idle")
		return bridge_provider_test_result_json(test_id, provider, "failed", msg, "")
	}
	bridge_provider_test_record(Bridge_Provider_Test{test_id = strings.clone(test_id), provider = strings.clone(provider), tier = strings.clone(tier), agent_instance_id = strings.clone(instance_id), status = "in_progress", message = "awaiting start-success", pane_id = strings.clone(pane_id), tmux_session = strings.clone(session), tmux_window = strings.clone(window)})
	_ = ws.send_text(conn, bridge_provider_test_status_json(test_id, "in_progress", "awaiting_start_success", "awaiting start-success", ""))
	start_ns := time.to_unix_nanoseconds(time.now())
	deadline_ns := start_ns + i64(time.Duration(start_deadline_ms) * time.Millisecond)
	if deadline_ns > hard_deadline_abs_ns do deadline_ns = hard_deadline_abs_ns
	hard_deadline_ns := hard_deadline_abs_ns
	last_frame_ns := i64(0)
	last_status_ns := start_ns
	last_frame := ""
	status := "timeout"
	message := "provider did not report start-success before deadline"
	for time.to_unix_nanoseconds(time.now()) < hard_deadline_ns {
		now := time.to_unix_nanoseconds(time.now())
		if test, ok := bridge_provider_test_get(test_id); ok {
			if test.status == "passed" { status = "passed"; message = test.message; break }
			if test.status == "failed" { status = "failed"; message = test.message; break }
		}
		if inst, inst_ok := bridge_runtime_instance_snapshot(instance_id); inst_ok {
			if inst.runtime_status == "failed" || inst.runtime_status == "stopped" { status = "failed"; message = strings.concatenate({"provider process ", inst.runtime_status}); break }
		}
		if now >= deadline_ns { status = "timeout"; break }
		if now - last_status_ns >= i64(15 * time.Second) {
			_ = ws.send_text(conn, bridge_provider_test_status_json(test_id, "in_progress", "awaiting_start_success", "awaiting start-success", ""))
			last_status_ns = now
		}
		if capture_frames && now - last_frame_ns >= i64(time.Duration(frame_interval_ms) * time.Millisecond) {
			if frame, frame_ok := tmux.capture_pane_text(pane_id, 80); frame_ok && frame != last_frame {
				last_frame = frame
				last_frame_ns = now
				_ = ws.send_text(conn, bridge_provider_test_frame_json(test_id, frame))
			}
		}
		time.sleep(100 * time.Millisecond)
	}
	diagnostics, _ := tmux.capture_pane_text(pane_id, 30)
	if status == "passed" do message = "agent booted and reported start-success"
	_ = ws.send_text(conn, bridge_provider_test_status_json(test_id, status, "done", message, diagnostics))
	_ = tmux.kill_window(session, window)
	bridge_runtime_remove_launch(instance_id)
	bridge_runtime_set_status(instance_id, "stopped", "idle")
	bridge_provider_test_remove(test_id)
	return bridge_provider_test_result_json(test_id, provider, status, message, diagnostics)
}

bridge_runtime_ensure_local_endpoint :: proc() -> (string, bool) {
	if bridge_config.local_endpoint_port == 0 do bridge_config.local_endpoint_port = 49324
	local_config := bridge_local_endpoint_config_default(bridge_config.local_endpoint_run_dir, bridge_config.local_endpoint_port)
	if !bridge_runtime_local_endpoint_started {
		bridge_runtime_local_endpoint_unix_started = bridge_local_endpoint_start_unix(local_config)
		bridge_runtime_local_endpoint_loopback_started = bridge_local_endpoint_start_loopback(local_config)
		bridge_runtime_local_endpoint_started = bridge_runtime_local_endpoint_unix_started || bridge_runtime_local_endpoint_loopback_started
		if bridge_runtime_local_endpoint_started {
			bridge_runtime_local_endpoint_descriptor = bridge_runtime_select_endpoint(local_config)
		}
	}
	if !bridge_runtime_local_endpoint_started do return "", false
	if bridge_runtime_local_endpoint_descriptor == "" do bridge_runtime_local_endpoint_descriptor = bridge_runtime_select_endpoint(local_config)
	return bridge_runtime_local_endpoint_descriptor, bridge_runtime_local_endpoint_descriptor != ""
}

bridge_runtime_select_endpoint :: proc(local_config: Bridge_Local_Endpoint_Config) -> string {
	// §12.0.2 contract: Unix-domain socket 0600 is primary; loopback TCP is fallback.
	// Only return a descriptor for a transport that actually started listening.
	if bridge_runtime_local_endpoint_unix_started do return bridge_local_endpoint_env_value(local_config, true)
	if bridge_runtime_local_endpoint_loopback_started do return bridge_local_endpoint_env_value(local_config, false)
	return ""
}

bridge_runtime_provider_tier :: proc(command_json: string) -> (string, string) {
	provider := extract_json_string(command_json, "provider", "")
	tier := extract_json_string(command_json, "tier", "")
	if provider == "" || tier == "" {
		payload := bridge_provider_payload_object(command_json)
		if provider == "" do provider = bridge_provider_json_extract_string(payload, "name", "")
		if tier == "" do tier = bridge_provider_json_extract_string(payload, "tier", "")
	}
	return provider, tier
}

bridge_runtime_agent_command :: proc(command_json, agent_token, agent_instance_id: string) -> string {
	if cmd := os.get_env_alloc("HEIMDALL_BRIDGE_AGENT_COMMAND", context.allocator); strings.trim_space(cmd) != "" do return cmd
	provider, tier := bridge_runtime_provider_tier(command_json)
	if profile, ok := bridge_provider_by_name_or_default(provider); ok && profile.enabled && len(profile.command) > 0 {
		return bridge_runtime_shell_command_for_profile(profile, tier, agent_token, agent_instance_id)
	}
	if strings.trim_space(bridge_config.agent_command) != "" do return bridge_config.agent_command
	return "sleep 3600"
}

bridge_runtime_wrapper_supervisor_argv :: proc(endpoint, wrapper_token, agent_token, instance_id, run_dir, session, window, provider, tier: string) -> []string {
	out := make([dynamic]string)
	append(&out, bridge_runtime_wrapper_bin(), "wrapper-supervisor", "--bridge-endpoint", endpoint, "--agent-token", wrapper_token, "--child-agent-token", agent_token, "--agent-instance-id", instance_id, "--run-dir", run_dir, "--tmux-session", session, "--tmux-window", window)
	if provider != "" do append(&out, "--provider", provider)
	if tier != "" do append(&out, "--tier", tier)
	return out[:]
}

bridge_runtime_wrapper_bin :: proc() -> string {
	if v := os.get_env_alloc("HEIMDALL_BRIDGE_WRAPPER_BIN", context.allocator); strings.trim_space(v) != "" do return v
	if len(os.args) > 0 && strings.trim_space(os.args[0]) != "" do return os.args[0]
	return "ham-bridge"
}

bridge_runtime_default_run_dir :: proc(instance_id: string) -> string {
	base := strings.trim_right(bridge_config.local_endpoint_run_dir, "/")
	if base == "" do base = "/tmp/heimdall-bridge-local"
	return strings.concatenate({base, "/instances/", bridge_runtime_safe_part(instance_id)})
}

bridge_runtime_tmux_session :: proc() -> string { return "heimdall-bridge" }
bridge_runtime_tmux_window :: proc(instance_id: string) -> string { return strings.concatenate({"agent-", bridge_runtime_safe_part(instance_id)}) }

bridge_runtime_safe_part :: proc(value: string) -> string {
	b := strings.builder_make()
	for ch in value {
		switch ch {
		case 'a'..='z', 'A'..='Z', '0'..='9', '_', '-', '@', '.': strings.write_rune(&b, ch)
		case: strings.write_string(&b, "_")
		}
	}
	return strings.to_string(b)
}

bridge_runtime_get_launch :: proc(instance_id: string) -> (Bridge_Runtime_Launch, bool) {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for launch in bridge_runtime_launches { if launch.agent_instance_id == instance_id do return launch, true }
	return {}, false
}

bridge_runtime_record_launch :: proc(launch: Bridge_Runtime_Launch) {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_runtime_launches) {
		if bridge_runtime_launches[i].agent_instance_id == launch.agent_instance_id { bridge_runtime_launches[i] = launch; return }
	}
	append(&bridge_runtime_launches, launch)
}

bridge_runtime_remove_launch :: proc(instance_id: string) {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_runtime_launches) {
		if bridge_runtime_launches[i].agent_instance_id == instance_id { unordered_remove(&bridge_runtime_launches, i); return }
	}
}

bridge_runtime_update_launch_pane :: proc(instance_id, pane_id: string) {
	if strings.trim_space(instance_id) == "" || strings.trim_space(pane_id) == "" do return
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_runtime_launches) {
		if bridge_runtime_launches[i].agent_instance_id == instance_id {
			bridge_runtime_launches[i].pane_id = strings.clone(pane_id)
			break
		}
	}
	for i in 0..<len(bridge_provider_tests) {
		if bridge_provider_tests[i].agent_instance_id == instance_id {
			bridge_provider_tests[i].pane_id = strings.clone(pane_id)
		}
	}
}

bridge_provider_test_record :: proc(test: Bridge_Provider_Test) {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_provider_tests) {
		if bridge_provider_tests[i].test_id == test.test_id { bridge_provider_tests[i] = test; return }
	}
	append(&bridge_provider_tests, test)
}

bridge_provider_test_get :: proc(test_id: string) -> (Bridge_Provider_Test, bool) {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for test in bridge_provider_tests { if test.test_id == test_id do return test, true }
	return {}, false
}

bridge_provider_test_remove :: proc(test_id: string) {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_provider_tests) { if bridge_provider_tests[i].test_id == test_id { unordered_remove(&bridge_provider_tests, i); return } }
}

bridge_provider_test_mark_start_success :: proc(instance_id: string) -> bool {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_provider_tests) {
		if bridge_provider_tests[i].agent_instance_id == instance_id {
			bridge_provider_tests[i].status = "passed"
			bridge_provider_tests[i].message = "agent reported start-success"
			return true
		}
	}
	return false
}

bridge_provider_test_cancel_provider :: proc(provider: string) -> bool {
	sync.mutex_lock(&bridge_runtime_mutex)
	to_kill_session := ""
	to_kill_window := ""
	to_remove_test := ""
	to_remove_instance := ""
	for i in 0..<len(bridge_provider_tests) {
		if bridge_provider_tests[i].provider == provider {
			to_kill_session = bridge_provider_tests[i].tmux_session
			to_kill_window = bridge_provider_tests[i].tmux_window
			to_remove_test = bridge_provider_tests[i].test_id
			to_remove_instance = bridge_provider_tests[i].agent_instance_id
			break
		}
	}
	sync.mutex_unlock(&bridge_runtime_mutex)
	if to_kill_session != "" && to_kill_window != "" do _ = tmux.kill_window(to_kill_session, to_kill_window)
	if to_remove_instance != "" do bridge_runtime_remove_launch(to_remove_instance)
	if to_remove_test != "" do bridge_provider_test_remove(to_remove_test)
	return to_remove_test != ""
}

bridge_runtime_set_status :: proc(instance_id, runtime_status, activity_status: string) {
	if strings.trim_space(instance_id) == "" do return
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_runtime_instances) {
		if bridge_runtime_instances[i].agent_instance_id == instance_id {
			if bridge_runtime_instances[i].runtime_status != runtime_status || bridge_runtime_instances[i].activity_status != activity_status {
				bridge_runtime_instances[i].state_seq += 1
				bridge_runtime_instances[i].runtime_status = runtime_status
				bridge_runtime_instances[i].activity_status = activity_status
			}
			return
		}
	}
	append(&bridge_runtime_instances, Bridge_Runtime_Instance{agent_instance_id = strings.clone(instance_id), state_seq = 1, runtime_status = strings.clone(runtime_status), activity_status = strings.clone(activity_status)})
}

bridge_runtime_instance_snapshot :: proc(instance_id: string) -> (Bridge_Runtime_Instance, bool) {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	return bridge_runtime_instance_snapshot_locked(instance_id)
}

bridge_runtime_instance_snapshot_locked :: proc(instance_id: string) -> (Bridge_Runtime_Instance, bool) {
	for inst in bridge_runtime_instances { if inst.agent_instance_id == instance_id do return inst, true }
	return {}, false
}

bridge_instance_status_json :: proc(instance_id: string) -> string {
	inst, ok := bridge_runtime_instance_snapshot(instance_id)
	if !ok do return "{}"
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"agent_instance_status\",\"protocol_version\":1,\"agent_instance_id\":\"")
	bridge_runtime_write_json_string(&b, inst.agent_instance_id)
	strings.write_string(&b, "\",\"state_seq\":")
	strings.write_string(&b, fmt.tprintf("%d", inst.state_seq))
	strings.write_string(&b, ",\"runtime_status\":\"")
	bridge_runtime_write_json_string(&b, inst.runtime_status)
	strings.write_string(&b, "\",\"activity_status\":\"")
	bridge_runtime_write_json_string(&b, inst.activity_status)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

bridge_hub_heartbeat_json :: proc() -> string {
	caps := bridge_provider_capabilities_json()
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"bridge_heartbeat\",\"protocol_version\":1,\"capabilities\":")
	strings.write_string(&b, caps)
	strings.write_string(&b, ",\"active_instance_ids\":[")
	first_active := true
	for launch in bridge_runtime_launches {
		if !first_active do strings.write_byte(&b, ',')
		first_active = false
		strings.write_byte(&b, '"')
		bridge_runtime_write_json_string(&b, launch.agent_instance_id)
		strings.write_byte(&b, '"')
	}
	strings.write_string(&b, "],\"instances\":[")
	first := true
	for launch in bridge_runtime_launches {
		inst, inst_ok := bridge_runtime_instance_snapshot_locked(launch.agent_instance_id)
		if !inst_ok do continue
		if !first do strings.write_byte(&b, ',')
		first = false
		strings.write_string(&b, "{\"agent_instance_id\":\"")
		bridge_runtime_write_json_string(&b, inst.agent_instance_id)
		strings.write_string(&b, "\",\"state_seq\":")
		strings.write_string(&b, fmt.tprintf("%d", inst.state_seq))
		strings.write_string(&b, ",\"runtime_status\":\"")
		bridge_runtime_write_json_string(&b, inst.runtime_status)
		strings.write_string(&b, "\",\"activity_status\":\"")
		bridge_runtime_write_json_string(&b, inst.activity_status)
		strings.write_string(&b, "\"}")
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

bridge_runtime_cached_command :: proc(command_id: string) -> (string, bool) {
	if command_id == "" do return "", false
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for result in bridge_runtime_results { if result.command_id == command_id do return result.result_json, true }
	return "", false
}

bridge_runtime_cache_command :: proc(command_id, result_json: string) {
	if command_id == "" do return
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_runtime_results) { if bridge_runtime_results[i].command_id == command_id { bridge_runtime_results[i].result_json = strings.clone(result_json); return } }
	append(&bridge_runtime_results, Bridge_Runtime_Command_Result{command_id = strings.clone(command_id), result_json = strings.clone(result_json)})
}

bridge_command_result_json :: proc(command_id, status, runtime_status: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"command_result\",\"protocol_version\":1,\"command_id\":\"")
	bridge_runtime_write_json_string(&b, command_id)
	strings.write_string(&b, "\",\"payload\":{\"status\":\"")
	bridge_runtime_write_json_string(&b, status)
	strings.write_string(&b, "\"")
	if runtime_status != "" {
		strings.write_string(&b, ",\"result\":{\"runtime_status\":\"")
		bridge_runtime_write_json_string(&b, runtime_status)
		strings.write_string(&b, "\"}")
	}
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}

bridge_command_result_payload_json :: proc(command_id, status, result_json: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"command_result\",\"protocol_version\":1,\"command_id\":\"")
	bridge_runtime_write_json_string(&b, command_id)
	strings.write_string(&b, "\",\"payload\":{\"status\":\"")
	bridge_runtime_write_json_string(&b, status)
	strings.write_string(&b, "\",\"result\":")
	if strings.trim_space(result_json) == "" { strings.write_string(&b, "{}") } else { strings.write_string(&b, result_json) }
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}

bridge_providers_report_json :: proc(command_id, payload_json: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"providers_report\",\"protocol_version\":1,\"command_id\":\"")
	bridge_runtime_write_json_string(&b, command_id)
	strings.write_string(&b, "\",\"payload\":")
	if strings.trim_space(payload_json) == "" { strings.write_string(&b, "{}") } else { strings.write_string(&b, payload_json) }
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

bridge_provider_test_status_json :: proc(test_id, status, phase, message, diagnostics: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"provider_test_status\",\"protocol_version\":1,\"payload\":{\"test_id\":\"")
	bridge_runtime_write_json_string(&b, test_id)
	strings.write_string(&b, "\",\"status\":\""); bridge_runtime_write_json_string(&b, status)
	strings.write_string(&b, "\",\"phase\":\""); bridge_runtime_write_json_string(&b, phase)
	strings.write_string(&b, "\",\"message\":\""); bridge_runtime_write_json_string(&b, message)
	if diagnostics != "" { strings.write_string(&b, "\",\"diagnostics\":\""); bridge_runtime_write_json_string(&b, bridge_provider_test_sanitize_diagnostics(diagnostics)) }
	strings.write_string(&b, "\",\"at\":\""); strings.write_string(&b, fmt.tprintf("%d", time.to_unix_nanoseconds(time.now())))
	strings.write_string(&b, "\"}}")
	return strings.to_string(b)
}

bridge_provider_test_frame_json :: proc(test_id, content: string) -> string {
	b := strings.builder_make()
	seq := 0
	if test, ok := bridge_provider_test_get(test_id); ok {
		seq = test.frame_seq + 1
		test.frame_seq = seq
		bridge_provider_test_record(test)
	}
	strings.write_string(&b, "{\"type\":\"provider_test_frame\",\"protocol_version\":1,\"payload\":{\"test_id\":\"")
	bridge_runtime_write_json_string(&b, test_id)
	strings.write_string(&b, "\",\"seq\":"); strings.write_string(&b, fmt.tprintf("%d", seq))
	strings.write_string(&b, ",\"at\":\""); strings.write_string(&b, fmt.tprintf("%d", time.to_unix_nanoseconds(time.now())))
	strings.write_string(&b, "\",\"rows\":80,\"cols\":0,\"format\":\"text\",\"content\":\"")
	bridge_runtime_write_json_string(&b, bridge_provider_test_truncate(content, 12000))
	strings.write_string(&b, "\"}}")
	return strings.to_string(b)
}

bridge_provider_test_result_json :: proc(test_id, provider, status, message, diagnostics: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"test_id\":\""); bridge_runtime_write_json_string(&b, test_id)
	strings.write_string(&b, "\",\"name\":\""); bridge_runtime_write_json_string(&b, provider)
	strings.write_string(&b, "\",\"provider\":\""); bridge_runtime_write_json_string(&b, provider)
	strings.write_string(&b, "\",\"status\":\""); bridge_runtime_write_json_string(&b, status)
	strings.write_string(&b, "\",\"tested_at\":\""); strings.write_string(&b, fmt.tprintf("%d", time.to_unix_nanoseconds(time.now())))
	strings.write_string(&b, "\",\"message\":\""); bridge_runtime_write_json_string(&b, message)
	if diagnostics != "" { strings.write_string(&b, "\",\"diagnostics\":\""); bridge_runtime_write_json_string(&b, bridge_provider_test_sanitize_diagnostics(diagnostics)) }
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

bridge_provider_payload_object :: proc(text: string) -> string {
	if payload, ok := bridge_provider_json_extract_object(text, "payload"); ok do return payload
	return "{}"
}

bridge_runtime_json_escaped :: proc(value: string) -> string {
	b := strings.builder_make()
	bridge_runtime_write_json_string(&b, value)
	return strings.to_string(b)
}

bridge_runtime_provider_test_int :: proc(json, key: string, fallback, min, max: int) -> int {
	value := extract_json_int(json, key, fallback)
	if value < min do return min
	if value > max do return max
	return value
}

bridge_provider_test_truncate :: proc(value: string, max_len: int) -> string {
	if max_len <= 0 || len(value) <= max_len do return value
	return value[len(value) - max_len:]
}

bridge_provider_test_sanitize_diagnostics :: proc(value: string) -> string {
	out := bridge_provider_test_truncate(value, 4000)
	out, _ = strings.replace_all(out, bridge_config.bridge_token, "[redacted]")
	return out
}

bridge_hub_hello_json :: proc() -> string {
	caps := bridge_provider_capabilities_json()
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"bridge_hello\",\"protocol_version\":1,\"bridge_id\":\"")
	bridge_runtime_write_json_string(&b, bridge_config.daemon_id)
	strings.write_string(&b, "\",\"hostname\":\"")
	bridge_runtime_write_json_string(&b, bridge_config.daemon_id)
	strings.write_string(&b, "\",\"capabilities\":")
	strings.write_string(&b, caps)
	strings.write_string(&b, ",\"active_instance_ids\":[")
	sync.mutex_lock(&bridge_runtime_mutex)
	first := true
	for launch in bridge_runtime_launches {
		if !first do strings.write_byte(&b, ',')
		first = false
		strings.write_byte(&b, '"')
		bridge_runtime_write_json_string(&b, launch.agent_instance_id)
		strings.write_byte(&b, '"')
	}
	sync.mutex_unlock(&bridge_runtime_mutex)
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

bridge_runtime_write_json_string :: proc(b: ^strings.Builder, value: string) {
	for ch in value {
		switch ch {
		case '\\': strings.write_string(b, "\\\\")
		case '"': strings.write_string(b, "\\\"")
		case '\n': strings.write_string(b, "\\n")
		case '\r': strings.write_string(b, "\\r")
		case '\t': strings.write_string(b, "\\t")
		case: strings.write_rune(b, ch)
		}
	}
}

bridge_hub_ws_url :: proc(base_url: string) -> string {
	trimmed := bridge_hub_base_url_for_runtime(base_url)
	if strings.has_prefix(trimmed, "http://") do return strings.concatenate({"ws://", trimmed[len("http://"):], "/api/v1/bridge-ws"})
	if strings.has_prefix(trimmed, "https://") do return strings.concatenate({"wss://", trimmed[len("https://"):], "/api/v1/bridge-ws"})
	return ""
}

bridge_hub_base_url_for_runtime :: proc(base_url: string) -> string {
	return strings.trim_right(strings.trim_space(base_url), "/")
}

bridge_hub_runtime_start :: proc() {
	bridge_hub_runtime_init()
	if strings.trim_space(bridge_config.bridge_token) != "" && strings.trim_space(bridge_config.daemon_url) != "" {
		thread.run(bridge_hub_runtime_worker)
	}
}
