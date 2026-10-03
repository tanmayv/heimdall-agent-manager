package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import http "odin_test:lib/http_client"

@(private = "file")
_bridge_agent_reconcile_running: bool
@(private = "file")
_bridge_agent_reconcile_mu: sync.Mutex

// bridge_agent_instance_extract_active_ids parses the JSON response from Hub GET /api/v1/agent-instances
// and returns a set of active instance IDs where runtime_status is "running", "launching", or "starting".
// Caller owns the returned map and its string keys (use bridge_agent_instance_delete_active_ids).
bridge_agent_instance_extract_active_ids :: proc(
	body: string,
	allocator := context.allocator,
) -> (map[string]bool, bool) {
	parsed, err := json.parse_string(body, json.DEFAULT_SPECIFICATION, false, allocator)
	if err != .None do return nil, false
	defer json.destroy_value(parsed, allocator)

	data_arr: json.Array
	if root_arr, is_arr := parsed.(json.Array); is_arr {
		data_arr = root_arr
	} else if root_obj, is_obj := parsed.(json.Object); is_obj {
		data_val, has_data := root_obj["data"]
		if !has_data do return nil, false
		arr, arr_ok := data_val.(json.Array)
		if !arr_ok do return nil, false
		data_arr = arr
	} else {
		return nil, false
	}

	active_ids := make(map[string]bool, 0, allocator)
	for item in data_arr {
		item_obj, is_obj := item.(json.Object)
		if !is_obj do continue

		id_val, has_id := item_obj["agent_instance_id"]
		if !has_id do continue
		id_str, id_is_str := id_val.(json.String)
		if !id_is_str do continue

		status_val, has_status := item_obj["runtime_status"]
		if !has_status do continue
		status_str, status_is_str := status_val.(json.String)
		if !status_is_str do continue

		if status_str == "running" || status_str == "launching" || status_str == "starting" {
			id := string(id_str)
			if !(id in active_ids) {
				active_ids[strings.clone(id, allocator)] = true
			}
		}
	}
	return active_ids, true
}

// bridge_agent_instance_delete_active_ids frees the keys and map returned by bridge_agent_instance_extract_active_ids.
bridge_agent_instance_delete_active_ids :: proc(active_ids: ^map[string]bool, allocator := context.allocator) {
	if active_ids == nil do return
	for k in active_ids {
		delete(k, allocator)
	}
	delete(active_ids^)
}

// bridge_agent_instance_find_orphans compares live sessions on pty-host against the Hub active set.
// Only sessions starting with "inst_" and alive == true that are absent from active_hub_ids are returned.
// Non-inst_ sessions (e.g. "sh_") and dead sessions are strictly ignored.
// Caller owns the returned dynamic array and its string elements.
bridge_agent_instance_find_orphans :: proc(
	pty_agents: []Pty_Host_Agent_Info,
	active_hub_ids: map[string]bool,
	allocator := context.allocator,
) -> [dynamic]string {
	orphans := make([dynamic]string, allocator)
	for a in pty_agents {
		if !a.alive do continue
		if !strings.has_prefix(a.instance_id, "inst_") do continue
		if a.instance_id in active_hub_ids do continue
		append(&orphans, strings.clone(a.instance_id, allocator))
	}
	return orphans
}

// bridge_agent_instance_reconcile_now reconciles surviving agent instances on ham-pty-host against
// the Hub's active instance list upon bridge connection / restart (REQ-REAP-STARTUP-1..5).
// Single-flight execution guarded by sync.Mutex.
bridge_agent_instance_reconcile_now :: proc() {
	sync.mutex_lock(&_bridge_agent_reconcile_mu)
	if _bridge_agent_reconcile_running {
		sync.mutex_unlock(&_bridge_agent_reconcile_mu)
		return
	}
	_bridge_agent_reconcile_running = true
	sync.mutex_unlock(&_bridge_agent_reconcile_mu)
	defer {
		sync.mutex_lock(&_bridge_agent_reconcile_mu)
		_bridge_agent_reconcile_running = false
		sync.mutex_unlock(&_bridge_agent_reconcile_mu)
	}

	if strings.trim_space(bridge_config.daemon_url) == "" || strings.trim_space(bridge_config.bridge_token) == "" {
		return
	}

	socket, sock_ok := bridge_pty_host_ensure_daemon()
	if !sock_ok do return

	reply, list_ok := bridge_pty_host_list(socket)
	if !list_ok do return
	defer pty_host_reply_delete(reply)

	headers := make([dynamic]http.Header)
	defer delete(headers)
	auth_header := strings.concatenate({"Bearer ", bridge_config.bridge_token})
	defer delete(auth_header)
	append(&headers, http.Header{name = "Authorization", value = auth_header})

	path := fmt.tprintf("/api/v1/agent-instances?bridge_id=%s", bridge_config.daemon_id)
	resp, ok := bridge_http_request_retry("GET", bridge_config.daemon_url, path, "", headers[:], http.DEFAULT_TIMEOUT_MS)
	if !ok do return
	defer delete(resp.body)

	// If HTTP request fails or returns non-200, return early without reaping (fail-safe)
	if resp.status != 200 do return

	active_hub_ids, parse_ok := bridge_agent_instance_extract_active_ids(resp.body)
	if !parse_ok do return
	defer bridge_agent_instance_delete_active_ids(&active_hub_ids)

	orphans := bridge_agent_instance_find_orphans(reply.agents, active_hub_ids)
	defer {
		for id in orphans do delete(id)
		delete(orphans)
	}

	for orphan_id in orphans {
		if bridge_pty_host_close(socket, orphan_id) {
			fmt.println("bridge agent reconcile: reaped orphan instance", orphan_id)
		}
		bridge_agent_token_invalidate_instance(orphan_id)
	}
}
