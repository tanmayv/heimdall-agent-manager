package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"

handle_agents_start :: proc(client: net.TCP_Socket, body: string) {
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	selected_agent := extract_json_string(body, "agent", "")
	config_path := extract_json_string(body, "config_path", server_config_path)
	if agent_instance_id == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"missing agent_instance_id"}`)
		return
	}
	if !valid_agent_instance_id(agent_instance_id) {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid agent_instance_id"}`)
		return
	}

	log_path := wrapper_log_path(agent_instance_id)
	agent_token := generate_agent_token()
	registry_add_pending_agent_token(agent_instance_id, agent_token)
	ok := launch_wrapper_detached(agent_instance_id, selected_agent, config_path, log_path, agent_token)
	if !ok {
		write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to start wrapper"}`)
		return
	}

	builder := strings.builder_make()
	strings.write_string(&builder, "{\"ok\":true,\"mode\":\"remote_detached\",\"agent_instance_id\":\"")
	json_write_string(&builder, agent_instance_id)
	strings.write_string(&builder, "\",\"conversation_id\":\"")
	json_write_string(&builder, conversation_id_for_instance(agent_instance_id))
	strings.write_string(&builder, "\",\"agent_token\":\"")
	json_write_string(&builder, agent_token)
	strings.write_string(&builder, "\",\"wrapper_log\":\"")
	json_write_string(&builder, log_path)
	strings.write_string(&builder, "\"}")
	write_response(client, 200, "OK", strings.to_string(builder))
}

launch_wrapper_detached :: proc(agent_instance_id, selected_agent, config_path, log_path, agent_token: string) -> bool {
	_ = os.make_directory_all(parent_dir(log_path))
	wrapper_bin := default_wrapper_bin()

	builder := strings.builder_make()
	strings.write_string(&builder, "nohup ")
	strings.write_string(&builder, shell_quote(wrapper_bin))
	strings.write_string(&builder, " --config ")
	strings.write_string(&builder, shell_quote(config_path))
	if selected_agent != "" {
		strings.write_string(&builder, " --agent ")
		strings.write_string(&builder, shell_quote(selected_agent))
	}
	if agent_token != "" {
		strings.write_string(&builder, " --agent-token ")
		strings.write_string(&builder, shell_quote(agent_token))
	}
	strings.write_string(&builder, " ")
	strings.write_string(&builder, shell_quote(agent_instance_id))
	strings.write_string(&builder, " > ")
	strings.write_string(&builder, shell_quote(log_path))
	strings.write_string(&builder, " 2>&1 < /dev/null &")

	process, err := os.process_start(os.Process_Desc{command = []string{"sh", "-c", strings.to_string(builder)}})
	if err != nil {
		fmt.println("wrapper launch failed")
		return false
	}
	_ = process
	return true
}

default_wrapper_bin :: proc() -> string {
	if len(os.args) > 0 {
		exe := os.args[0]
		slash := strings.last_index_byte(exe, '/')
		if slash >= 0 do return fmt.tprintf("%s/bc-agent-wrapper", exe[:slash])
	}
	return "bc-agent-wrapper"
}

wrapper_log_path :: proc(agent_instance_id: string) -> string {
	data_dir := expand_home(server_data_dir)
	return fmt.tprintf("%s/logs/wrapper-%s.log", data_dir, safe_path_part(agent_instance_id))
}

parent_dir :: proc(path: string) -> string {
	slash := strings.last_index_byte(path, '/')
	if slash <= 0 do return "."
	return path[:slash]
}

expand_home :: proc(path: string) -> string {
	if path == "~" {
		home := os.get_env_alloc("HOME", context.allocator)
		if home != "" do return home
	}
	if strings.has_prefix(path, "~/") {
		home := os.get_env_alloc("HOME", context.allocator)
		if home != "" do return fmt.tprintf("%s/%s", home, path[2:])
	}
	return path
}

safe_path_part :: proc(value: string) -> string {
	builder := strings.builder_make()
	for ch in value {
		switch ch {
		case 'a'..='z', 'A'..='Z', '0'..='9', '_', '-', '@', '.': strings.write_rune(&builder, ch)
		case: strings.write_string(&builder, "_")
		}
	}
	return strings.to_string(builder)
}

shell_quote :: proc(value: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "'")
	for ch in value {
		if ch == '\'' {
			strings.write_string(&builder, "'\\''")
		} else {
			strings.write_rune(&builder, ch)
		}
	}
	strings.write_string(&builder, "'")
	return strings.to_string(builder)
}
