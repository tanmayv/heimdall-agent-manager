package main

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
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

bridge_runtime_mutex: sync.Mutex
bridge_runtime_instances: [dynamic]Bridge_Runtime_Instance
bridge_runtime_results: [dynamic]Bridge_Runtime_Command_Result

bridge_hub_runtime_init :: proc() {
	bridge_runtime_mutex = sync.Mutex{}
	bridge_runtime_instances = make([dynamic]Bridge_Runtime_Instance)
	bridge_runtime_results = make([dynamic]Bridge_Runtime_Command_Result)
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
		instance_id := extract_json_string(text, "agent_instance_id", "")
		accepted := bridge_command_result_json(command_id, "accepted", "")
		bridge_runtime_cache_command(command_id, accepted)
		_ = ws.send_text(conn, accepted)
		time.sleep(50 * time.Millisecond)
		bridge_runtime_set_status(instance_id, "starting", "active")
		_ = ws.send_text(conn, bridge_instance_status_json(instance_id))
		time.sleep(50 * time.Millisecond)
		// M4/v1 smoke runner: no production wrapper supervision yet; report ready/running
		// once bootstrap materialization has been requested by launch command.
		bridge_runtime_set_status(instance_id, "running", "idle")
		_ = ws.send_text(conn, bridge_instance_status_json(instance_id))
		return
	}
	if type == "stop_agent" {
		fmt.println("bridge hub runtime command stop_agent")
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return }
		instance_id := extract_json_string(text, "agent_instance_id", "")
		accepted := bridge_command_result_json(command_id, "accepted", "")
		bridge_runtime_cache_command(command_id, accepted)
		_ = ws.send_text(conn, accepted)
		time.sleep(50 * time.Millisecond)
		bridge_runtime_set_status(instance_id, "stopping", "idle")
		_ = ws.send_text(conn, bridge_instance_status_json(instance_id))
		time.sleep(50 * time.Millisecond)
		bridge_runtime_set_status(instance_id, "stopped", "idle")
		_ = ws.send_text(conn, bridge_instance_status_json(instance_id))
		return
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
	for result in bridge_runtime_results { if result.command_id == command_id do return }
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
	strings.write_string(&b, "\",\"capabilities\":[{\"provider\":\"claude\",\"tiers\":[\"normal\"],\"default_tier\":\"normal\"}],\"active_instance_ids\":[]}")
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
