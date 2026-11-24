package agent

import "core:strings"
import "core:encoding/json"
import virtual "core:mem/virtual"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import placement "odin_test:hub/service/placement"
import project_service "odin_test:hub/service/project"
import jsonx "odin_test:lib/jsonx"

Start_Lease :: struct { task_id, role, lease_id, pack_json, permission_mode: string }
Start_Run_Entry :: struct { bridge_id, deliver, launch_json: string, lease_id: string }

// launch_json is already a complete launch frame. Embed its bytes verbatim.
// The caller owns the returned text.
start_command_json :: proc(command_id, chain_id: string, run: []Start_Run_Entry, stop: []string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"start_agent\",\"protocol_version\":1,\"command_id\":\"")
	write_service_json_string(&b, command_id)
	strings.write_string(&b, "\",\"chain_id\":\"")
	write_service_json_string(&b, chain_id)
	strings.write_byte(&b, '"')
	if len(run) == 1 && len(stop) == 0 {
		id := jsonx.extract_string(run[0].launch_json, "agent_instance_id")
		defer delete(id)
		strings.write_string(&b, ",\"agent_instance_id\":\"")
		write_service_json_string(&b, id)
		strings.write_byte(&b, '"')
	}
	strings.write_string(&b, ",\"payload\":{\"run\":[")
	for entry, i in run {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, "{\"deliver\":\"")
		write_service_json_string(&b, entry.deliver)
		strings.write_string(&b, "\",\"launch\":")
		strings.write_string(&b, entry.launch_json)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "],\"stop\":[")
	for id, i in stop {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_byte(&b, '"'); write_service_json_string(&b, id); strings.write_byte(&b, '"')
	}
	strings.write_string(&b, "]}}")
	return strings.to_string(b)
}

// Convert only at the old-bridge boundary; wake_agent_command_json remains the
// authority for legacy field ordering and omission rules.
start_legacy_run :: proc(entry: Start_Run_Entry) -> Wake_Agent_Run_Entry {
	j := entry.launch_json
	s :: jsonx.extract_string
	pack := start_launch_pack_view(j)
	return {
		agent_instance_id=s(j,"agent_instance_id"), task_id=s(j,"task_id"), role=s(j,"role"),
		provider=s(j,"provider"), provider_profile=s(j,"provider_profile"), model=s(j,"model"),
		effective_transport=s(j,"effective_transport"), catalog_etag=s(j,"catalog_etag"), launch_epoch=s(j,"launch_epoch"),
		agent_id=s(j,"agent_id"), agent_name=s(j,"agent_name"), chain_id=s(j,"chain_id"), chain_title=s(j,"chain_title"),
		coordinator_id=s(j,"coordinator_agent_instance_id"), project_id=s(j,"project_id"), project_path=s(j,"project_path"),
		lease_id=s(j,"lease_id"), pack_json=pack, permission_mode=s(j,"permission_mode"),
		run_count=jsonx.extract_int(j,"run_count",0), deliver="nudge" if entry.deliver == contracts.START_DELIVER_NUDGE else "",
	}
}

// A launch frame has its lease pack in payload. Return that object's original
// text: extract_raw_object reserializes it and changes legacy wake bytes.
start_launch_pack_view :: proc(text: string) -> string {
	depth := 0
	for i := 0; i < len(text); i += 1 {
		if text[i] == '{' || text[i] == '[' { depth += 1; continue }
		if text[i] == '}' || text[i] == ']' { depth -= 1; continue }
		if text[i] != '"' do continue
		begin := i
		i += 1
		for i < len(text) {
			if text[i] == '\\' { i += 2; continue }
			if text[i] == '"' do break
			i += 1
		}
		if i >= len(text) do return ""
		if depth != 2 do continue
		key: string
		if json.unmarshal_string(text[begin:i+1], &key) != nil || key != "pack" do continue
		j := i + 1
		for j < len(text) && (text[j] == ' ' || text[j] == 9 || text[j] == 10 || text[j] == 13) do j += 1
		if j >= len(text) || text[j] != ':' do continue
		j += 1
		for j < len(text) && (text[j] == ' ' || text[j] == 9 || text[j] == 10 || text[j] == 13) do j += 1
		if j >= len(text) || text[j] != '{' do return ""
		start, nested := j, 0
		quoted := false
		for j < len(text) {
			c := text[j]
			if quoted {
				if c == '\\' { j += 2; continue }
				if c == '"' do quoted = false
			} else {
				if c == '"' { quoted = true }
				else if c == '{' { nested += 1 }
				else if c == '}' {
					nested -= 1
					if nested == 0 do return text[start:j+1]
				}
			}
			j += 1
		}
		return ""
	}
	return ""
}

start_command_send :: proc(service: ^Agent_Service, bridge_id, command_id, chain_id: string, run: []Start_Run_Entry, stop: []string) -> (sent: bool, err: domain.Domain_Error) {
	// Conversion scratch is private. The sink runs in the caller's context and
	// receives request-lifetime bytes, as the legacy runtime sender did. Some
	// sinks retain Runtime_Command views until the request has finished.
	saved_context := context
	defer context = saved_context
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return false, domain.domain_error(.Internal_Error,"start command allocation failed")
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	bridge, found, read_err := iface.bridge_get_bridge(service.bridges, bridge_id)
	if read_err.code != .None do return false, read_err
	if !found do return false, domain.domain_error(.Not_Found,"bridge not found")
	body: string
	if placement.bridge_has_feature(bridge, contracts.BRIDGE_FEATURE_START_AGENT_V1) {
		body = start_command_json(command_id, chain_id, run, stop)
	} else if len(run) == 1 && len(stop) == 0 && run[0].deliver == contracts.START_DELIVER_LAUNCH && run[0].lease_id == "" && !jsonx.has_key(run[0].launch_json,"lease_id") && !jsonx.has_key(run[0].launch_json,"task_id") {
		body = run[0].launch_json
	} else {
		legacy := make([]Wake_Agent_Run_Entry, len(run))
		for entry, i in run do legacy[i] = start_legacy_run(entry)
		body = wake_agent_command_json(command_id, chain_id, legacy, stop)
	}
	body = strings.clone(body, saved_context.temp_allocator)
	context = saved_context
	return project_service.bridge_command_send_runtime(service.bridge_command_sink, {bridge_id=bridge_id,command_id=command_id,body_json=body})
}
