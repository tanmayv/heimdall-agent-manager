// heimdall enroll: one-shot node enrollment against a Hub.
//
// Wire format mirrors ham-bridge enroll (src/bridge/main.odin): POST
// {hub}/api/v1/bridges/enroll with the one-time enrollment token as Bearer
// auth and a machine descriptor body. On success the returned bridge token is
// persisted to the token file (0600) — the same file the heimdall-bridge
// service is started with (scripts/install.sh ExecStart --bridge-token-file) —
// and config.toml gets [wrapper] daemon_url plus [daemon] daemon_id so
// ham-ctl/ham-bridge also resolve the Hub without extra flags. The bridge
// token is intentionally NOT duplicated into config.toml on this path.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import http "odin_test:lib/http_client"

MANAGER_ENROLL_VALUE_FLAGS :: []string{"--hub", "--enrollment-token", "--config", "--token-file"}

manager_enroll_command :: proc(args: []string) -> bool {
	hub_url := strings.trim_right(manager_option_value(args, "--hub", ""), "/")
	token := manager_option_value(args, "--enrollment-token", "")
	if token == "" do token = manager_first_positional(args, MANAGER_ENROLL_VALUE_FLAGS)
	if strings.trim_space(hub_url) == "" {
		fmt.eprintln("heimdall enroll requires --hub <url>")
		return false
	}
	if strings.trim_space(token) == "" {
		fmt.eprintln("heimdall enroll requires the one-time enrollment token: heimdall enroll hbe_... --hub <url>")
		return false
	}
	if !manager_hub_url_supported(hub_url) {
		fmt.eprintln("heimdall enroll --hub must be an http:// or https:// base URL")
		return false
	}
	config_path := manager_config_path(args)
	token_path := manager_token_path(args, config_path)

	body_b := strings.builder_make()
	strings.write_string(&body_b, "{\"hub_url\":\"")
	manager_json_write_string(&body_b, hub_url)
	strings.write_string(&body_b, "\",\"machine\":{\"hostname\":\"")
	manager_json_write_string(&body_b, manager_hostname())
	strings.write_string(&body_b, "\",\"os\":\"")
	manager_json_write_string(&body_b, manager_os_string())
	strings.write_string(&body_b, "\",\"arch\":\"")
	manager_json_write_string(&body_b, manager_arch_string())
	strings.write_string(&body_b, "\"}}")
	body := strings.to_string(body_b)

	// Log a token PREVIEW only (never the full secret).
	token_preview := token[:min(8, len(token))]
	fmt.printfln("heimdall enroll: POST %s/api/v1/bridges/enroll (enrollment_token=%s..., len=%d)", hub_url, token_preview, len(token))
	headers := [?]http.Header{{name = "Authorization", value = strings.concatenate({"Bearer ", token})}}
	resp, ok := http.request_with_headers_timeout("POST", hub_url, "/api/v1/bridges/enroll", body, headers[:], http.DEFAULT_TIMEOUT_MS)
	if !ok {
		fmt.eprintfln("heimdall enroll FAILED: could not reach the Hub at %s — check the proxy/tunnel is up and --hub is correct (transport error, no HTTP response)", hub_url)
		return false
	}
	if resp.status != 201 {
		fmt.eprintfln("heimdall enroll FAILED: Hub returned HTTP %d — %s", resp.status, resp.body)
		if resp.status == 401 || resp.status == 403 do fmt.eprintln("  hint: the enrollment token is invalid, already used, or expired — create a fresh one on the Hub ('ham-ctl bridge enroll-token --new').")
		if resp.status == 404 do fmt.eprintln("  hint: the enrollment token was not found (invalid/expired — create a fresh one), OR the proxy isn't rewriting Host to the Hub / --hub points at the wrong base URL.")
		return false
	}
	fmt.println("heimdall enroll: Hub accepted (HTTP 201)")
	bridge_token := manager_extract_json_string(resp.body, "bridge_token", "")
	bridge_id := manager_extract_json_string(resp.body, "bridge_id", "")
	persisted_hub_url := manager_extract_json_string(resp.body, "hub_url", hub_url)
	if strings.trim_space(bridge_token) == "" {
		fmt.eprintln("heimdall enroll FAILED: Hub accepted the enrollment but returned no bridge_token — cannot persist credentials")
		return false
	}
	if !manager_write_token_file(token_path, bridge_token) {
		fmt.eprintfln("heimdall enroll FAILED: could not write bridge token file %s", token_path)
		return false
	}
	if !manager_write_enrolled_config(config_path, persisted_hub_url, bridge_id) {
		fmt.eprintfln("warning: bridge token was saved, but %s could not be updated; the service reads the Hub URL from its unit, so the node still works", config_path)
	} else {
		fmt.printfln("heimdall enroll: updated %s", config_path)
	}
	fmt.printfln("heimdall enroll SUCCESS: enrolled as bridge_id=%s hub_url=%s", bridge_id, persisted_hub_url)
	fmt.printfln("  bridge token: %s (mode 0600)", token_path)
	fmt.println("  next: start the bridge service — heimdall start")
	return true
}

// manager_write_enrolled_config updates [wrapper] daemon_url and [daemon]
// daemon_id in config.toml, preserving every other line and section verbatim
// (existing keys, comments and unknown sections survive re-enrollment). When a
// section is missing it is appended.
manager_write_enrolled_config :: proc(path, hub_url, bridge_id: string) -> bool {
	if strings.trim_space(path) == "" || strings.trim_space(hub_url) == "" do return false
	existing := ""
	if data, err := os.read_entire_file(path, context.allocator); err == nil {
		existing = string(data)
	}
	b := strings.builder_make()
	strings.write_string(&b, manager_config_merge(existing, hub_url, bridge_id))
	manager_make_parent_dirs(path)
	return os.write_entire_file(path, strings.to_string(b)) == nil
}

// manager_config_merge returns the merged config content. Kept pure so the
// merge (replace-vs-insert, preservation) is unit-testable.
manager_config_merge :: proc(existing, hub_url, bridge_id: string) -> string {
	b := strings.builder_make()
	section := ""
	wrapper_written := false
	daemon_written := false
	text := existing
	for line in strings.split_lines_iterator(&text) {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "[") && strings.has_suffix(trimmed, "]") {
			section = trimmed
		}
		key := manager_config_line_key(trimmed)
		if section == "[wrapper]" && key == "daemon_url" {
			manager_config_write_assignment(&b, "daemon_url", hub_url)
			wrapper_written = true
			strings.write_byte(&b, '\n')
			continue
		}
		if section == "[daemon]" && key == "daemon_id" {
			manager_config_write_assignment(&b, "daemon_id", bridge_id)
			daemon_written = true
			strings.write_byte(&b, '\n')
			continue
		}
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
	}
	if !wrapper_written {
		if strings.builder_len(b) > 0 do strings.write_byte(&b, '\n')
		strings.write_string(&b, "[wrapper]\n")
		manager_config_write_assignment(&b, "daemon_url", hub_url)
		strings.write_byte(&b, '\n')
	}
	if !daemon_written {
		if strings.builder_len(b) > 0 do strings.write_byte(&b, '\n')
		strings.write_string(&b, "[daemon]\n")
		manager_config_write_assignment(&b, "daemon_id", bridge_id)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// manager_config_line_key extracts the bare key from an `key = value` line
// ("" when the line is not an assignment).
manager_config_line_key :: proc(trimmed_line: string) -> string {
	eq := strings.index_byte(trimmed_line, '=')
	if eq <= 0 do return ""
	return strings.trim_space(trimmed_line[:eq])
}

manager_config_write_assignment :: proc(b: ^strings.Builder, key, value: string) {
	strings.write_string(b, key)
	strings.write_string(b, " = \"")
	manager_json_write_string(b, value)
	strings.write_string(b, "\"")
}
