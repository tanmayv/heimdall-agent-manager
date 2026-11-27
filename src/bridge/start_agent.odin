package main

import "core:encoding/json"
import "core:strings"
import virtual "core:mem/virtual"
import contracts "odin_test:contracts"
import ws "odin_test:lib/ws"

// Seams keep process/network effects replaceable in compatibility tests.
bridge_start_launch_proc: proc(command_id, text: string, deadline: i64) -> (bool, string, Bridge_Error) = bridge_start_launch
bridge_start_nudge_proc := bridge_wake_nudge_live_child
bridge_start_stop_proc := bridge_runtime_stop_agent
bridge_start_send_proc := bridge_hub_send
bridge_start_status_proc := bridge_wake_report_failed_status
bridge_start_capture_proc := bridge_ext_token_capture_final

bridge_start_launch :: proc(command_id, text: string, deadline: i64) -> (bool, string, Bridge_Error) {
	return bridge_runtime_launch_agent(command_id, text, deadline)
}

// Input is validated before this lexical walk. Return views, preserving all
// whitespace, ordering and escaping inside entry.launch (AST reserialization
// cannot preserve that wire contract).
bridge_start_run_views :: proc(payload: string) -> []string {
	entries := make([dynamic]string)
	depth, begin := 0, -1
	in_string, escaped, in_run := false, false, false
	for i := 0; i < len(payload); i += 1 {
		c := payload[i]
		if in_string {
			if escaped { escaped = false; continue }
			if c == '\\' { escaped = true; continue }
			if c == '"' do in_string = false
			continue
		}
		if c == '"' {
			if depth == 1 {
				end := i + 1
				for end < len(payload) {
					if payload[end] == '\\' { end += 2; continue }
					if payload[end] == '"' do break
					end += 1
				}
				key: string
				if json.unmarshal_string(payload[i:end+1], &key) == nil {
					j := end + 1
					for j < len(payload) && (payload[j] == ' ' || payload[j] == 9 || payload[j] == 10 || payload[j] == 13) do j += 1
					if j < len(payload) && payload[j] == ':' do in_run = key == "run"
				}
			}
			in_string = true
			continue
		}
		if c == '{' || c == '[' {
			if in_run && depth == 2 && c == '{' do begin = i
			depth += 1
		} else if c == '}' || c == ']' {
			depth -= 1
			if in_run && depth == 2 && c == '}' && begin >= 0 {
				append(&entries, payload[begin:i+1]); begin = -1
			}
		}
	}
	return entries[:]
}

// Apply without a command_result, including when called by the delivery
// executor with conn=nil. All entries run even after the first failed launch.
bridge_start_agent_apply :: proc(conn: ^ws.Connection, text: string, deadline_ns: i64) -> (ok: bool, err: Bridge_Error) {
	return bridge_start_agent_apply_detail(conn, text, deadline_ns, nil)
}

// The legacy launch adapter also needs the launcher's original detail text.
// A non-nil detail lets that adapter send its one status frame on either result.
bridge_start_agent_apply_detail :: proc(conn: ^ws.Connection, text: string, deadline_ns: i64, failure_detail: ^string) -> (ok: bool, err: Bridge_Error) {
	result_allocator := context.allocator
	saved_context := context
	defer context = saved_context
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return false, bridge_error(.agent_launch_failed, .other)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	scratch_context := context
	root, parse_err := json.parse_string(text)
	if parse_err != .None do return false, bridge_error(.agent_launch_failed, .unsupported)
	if _, valid := root.(json.Object); !valid do return false, bridge_error(.agent_launch_failed, .unsupported)
	payload, has_payload := bridge_wake_object_text(text, "payload")
	if !has_payload do return false, bridge_error(.agent_launch_failed, .unsupported)
	coordinator_ids := make(map[string]bool)
	ok = true
	for entry in bridge_start_run_views(payload) {
		context = scratch_context
		launch, has_launch := bridge_wake_object_text(entry, "launch")
		if !has_launch {
			if ok do err = bridge_error(.agent_launch_failed, .unsupported)
			ok = false
			continue
		}
		id := extract_json_string(launch, "agent_instance_id", "")
		role := extract_json_string(launch, "role", "")
		if role == "coordinator" do coordinator_ids[id] = true
		if strings.trim_space(id) == "" {
			if ok do err = bridge_error(.agent_launch_failed, .unsupported)
			ok = false
			continue
		}
		deliver := extract_json_string(entry, "deliver", "")
		if deliver != contracts.START_DELIVER_LAUNCH && deliver != contracts.START_DELIVER_NUDGE {
			if ok do err = bridge_error(.agent_launch_failed, .unsupported)
			ok = false
			continue
		}
		pack, _ := bridge_wake_object_text(launch, "payload")
		pack, _ = bridge_wake_object_text(pack, "pack")
		task_id := extract_json_string(launch,"task_id","")
		lease_id := extract_json_string(launch,"lease_id","")
		run_count := extract_json_int(launch,"run_count",0)
		entry_id := extract_json_string(launch, "command_id", "")
		// Parsing views remain alive until this apply returns. Persistent launch,
		// token, startup and wake state must use the caller's heap context, never
		// the private scratch arena (including its temporary allocator).
		context = saved_context
		if deliver == contracts.START_DELIVER_NUDGE {
			switch bridge_start_nudge_proc(id, task_id, role, lease_id, run_count, pack) {
			case .Delivered:
				bridge_runtime_set_launch_role(id, role)
				continue
			case .Delivery_Failed:
				if ok do err = bridge_error(.agent_launch_failed, .other)
				ok = false
				continue
			case .Unavailable:
				// The launcher must independently verify inventory before spawn.
			}
		}
		launched, detail, launch_err := bridge_start_launch_proc(entry_id, launch, deadline_ns)
		if launched {
			bridge_runtime_set_launch_role(id, role)
		} else {
			if failure_detail == nil do bridge_start_status_proc(conn, id)
			if ok {
				err = launch_err
				if failure_detail != nil do failure_detail^ = strings.clone(detail, result_allocator)
			}
			ok = false
		}
	}
	context = scratch_context
	if stop_ids, has_stop := bridge_provider_json_extract_string_array(payload, "stop"); has_stop {
		context = saved_context
		for id in stop_ids {
			if strings.trim_space(id) == "" || coordinator_ids[id] do continue
			if launch, has := bridge_runtime_get_launch(id); has && launch.role == "coordinator" do continue
			if bridge_start_stop_proc(id) do _ = bridge_start_capture_proc(id, bridge_agent_instance_run_count(id))
		}
	}
	return
}

bridge_start_wrap_launch :: proc(text: string) -> string {
	return strings.concatenate({"{\"payload\":{\"run\":[{\"deliver\":\"launch\",\"launch\":",text,"}],\"stop\":[]}}"})
}

bridge_hub_handle_start_agent :: proc(conn: ^ws.Connection, text: string) {
	command_id := extract_json_string(text,"command_id","")
	defer delete(command_id)
	ok, err := bridge_start_agent_apply(conn, text, bridge_command_worker_deadline_ns(conn))
	final := bridge_command_result_json(command_id,"succeeded","") if ok else bridge_command_failed_json(command_id,bridge_error_wire(err,""),"failed")
	defer delete(final)
	_ = bridge_start_send_proc(conn, final)
}
