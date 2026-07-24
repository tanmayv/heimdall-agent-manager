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

bridge_runtime_mutex: sync.Mutex
bridge_runtime_instances: [dynamic]Bridge_Runtime_Instance
bridge_runtime_results: [dynamic]Bridge_Runtime_Command_Result
bridge_runtime_launches: [dynamic]Bridge_Runtime_Launch
bridge_runtime_local_endpoint_started: bool
bridge_runtime_local_endpoint_unix_started: bool
bridge_runtime_local_endpoint_loopback_started: bool
bridge_runtime_local_endpoint_descriptor: string

bridge_hub_runtime_init :: proc() {
	bridge_runtime_mutex = sync.Mutex{}
	bridge_runtime_instances = make([dynamic]Bridge_Runtime_Instance)
	bridge_runtime_results = make([dynamic]Bridge_Runtime_Command_Result)
	bridge_runtime_launches = make([dynamic]Bridge_Runtime_Launch)
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
	agent_command := bridge_runtime_agent_command(command_json)
	session := bridge_runtime_tmux_session()
	window := bridge_runtime_tmux_window(instance_id)
	wrapper_args := bridge_runtime_wrapper_supervisor_argv(endpoint, wrapper_issue.plaintext_token, agent_issue.plaintext_token, instance_id, run_dir, agent_command)
	launch, launch_ok := tmux.ensure_agent_window(session, window, run_dir, wrapper_args)
	if !launch_ok || strings.trim_space(launch.pane_id) == "" {
		bridge_runtime_set_status(instance_id, "failed", "idle")
		return false, "tmux wrapper launch failed"
	}
	bridge_runtime_record_launch(Bridge_Runtime_Launch{agent_instance_id = strings.clone(instance_id), command_id = strings.clone(command_id), run_dir = strings.clone(run_dir), tmux_session = strings.clone(session), tmux_window = strings.clone(window), pane_id = strings.clone(launch.pane_id), wrapper_token = strings.clone(wrapper_issue.plaintext_token), agent_token = strings.clone(agent_issue.plaintext_token)})
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

bridge_runtime_agent_command :: proc(command_json: string) -> string {
	if cmd := os.get_env_alloc("HEIMDALL_BRIDGE_AGENT_COMMAND", context.allocator); strings.trim_space(cmd) != "" do return cmd
	if strings.trim_space(bridge_config.agent_command) != "" do return bridge_config.agent_command
	provider := extract_json_string(command_json, "provider", "")
	if provider == "test" do return "sleep 3600"
	return "sleep 3600"
}

bridge_runtime_wrapper_supervisor_argv :: proc(endpoint, wrapper_token, agent_token, instance_id, run_dir, agent_command: string) -> []string {
	out := make([dynamic]string)
	append(&out, bridge_runtime_wrapper_bin(), "wrapper-supervisor", "--bridge-endpoint", endpoint, "--agent-token", wrapper_token, "--child-agent-token", agent_token, "--agent-instance-id", instance_id, "--cwd", run_dir, "--agent-command", agent_command)
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
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"bridge_heartbeat\",\"protocol_version\":1,\"instances\":[")
	first := true
	for inst in bridge_runtime_instances {
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

bridge_hub_hello_json :: proc() -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"bridge_hello\",\"protocol_version\":1,\"hostname\":\"")
	bridge_runtime_write_json_string(&b, bridge_config.daemon_id)
	strings.write_string(&b, "\",\"capabilities\":[{\"provider\":\"claude\",\"tiers\":[\"normal\"],\"default_tier\":\"normal\"}],\"active_instance_ids\":[")
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
