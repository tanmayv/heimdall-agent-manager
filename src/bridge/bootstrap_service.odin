package main

import "core:os"
import "core:strings"
import http "odin_test:lib/http_client"

bridge_bootstrap_fetch_and_materialize :: proc(hub_url, bridge_token, instance_id, run_dir: string) -> bool {
	if strings.trim_space(hub_url) == "" || strings.trim_space(bridge_token) == "" || strings.trim_space(instance_id) == "" || strings.trim_space(run_dir) == "" do return false
	path := strings.concatenate({"/api/v1/bridge/agent-instances/", instance_id, "/bootstrap"})
	headers := [?]http.Header{{name = "Authorization", value = strings.concatenate({"Bearer ", bridge_token})}}
	resp, ok := http.request_with_headers_timeout("GET", hub_url, path, "", headers[:], http.DEFAULT_TIMEOUT_MS)
	if !ok || resp.status != 200 do return false
	_ = os.make_directory_all(run_dir)
	content := extract_json_string(resp.body, "content", strings.concatenate({"# Agent bootstrap\n\nInstance: ", instance_id, "\n"}))
	if os.write_entire_file(strings.concatenate({run_dir, "/AGENTS.md"}), content) != nil do return false
	manifest := strings.concatenate({"{\"agent_instance_id\":\"", instance_id, "\",\"managed_files\":[{\"relative_path\":\"AGENTS.md\",\"kind\":\"AGENTS_MD\"}]}"})
	if os.write_entire_file(strings.concatenate({run_dir, "/heimdall-bootstrap-manifest.json"}), manifest) != nil do return false
	return true
}
