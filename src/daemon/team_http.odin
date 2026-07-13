package main

import "core:fmt"
import "core:net"
import "core:strings"

TEAM_MAX_FOCUS_EVENTS :: 1024

Team_Focus_Event :: struct {
	chain_id: string,
	created_unix_ms: i64,
}

team_focus_events: [TEAM_MAX_FOCUS_EVENTS]Team_Focus_Event
team_focus_event_count: int

handle_teams_request :: proc(client: net.TCP_Socket, request: string) -> bool {
	method, target := http_method_target(request)
	if method == "POST" && (target == "/teams/add-member" || target == "/teams/add-member/") {
		handle_team_add_member(client, request_body(request))
		return true
	}
	if method == "GET" && (target == "/teams" || strings.has_prefix(target, "/teams?")) {
		project_id := query_value(target, "project_id")
		status := query_value(target, "status")
		write_response(client, 200, "OK", teams_list_json(team_service_list(project_id, status)))
		return true
	}

	if method == "GET" && strings.has_prefix(target, "/teams/") {
		path := path_without_query(target)
		suffix := path[len("/teams/"):]
		if strings.has_suffix(suffix, "/members") {
			team_id := suffix[:len(suffix) - len("/members")]
			shown := team_service_show(team_id)
			if shown.team.team_id == "" {
				write_response(client, 404, "Not Found", `{"ok":false,"message":"team not found"}`)
				return true
			}
			write_response(client, 200, "OK", team_members_json(shown.members))
			return true
		}

		shown := team_service_show(suffix)
		if shown.team.team_id == "" {
			write_response(client, 404, "Not Found", `{"ok":false,"message":"team not found"}`)
			return true
		}
		write_response(client, 200, "OK", team_with_members_json(shown))
		return true
	}

	if method == "POST" && strings.has_prefix(target, "/task-chains/") && strings.has_suffix(path_without_query(target), "/focus") {
		path := path_without_query(target)
		chain_id := path[len("/task-chains/"):len(path) - len("/focus")]
		team, ok := team_db_get_team_by_chain_id(team_service_db, chain_id)
		if !ok {
			write_response(client, 404, "Not Found", `{"ok":false,"message":"team not found for chain"}`)
			return true
		}
		action := "noop"
		reason := "team_not_bootable"
		if team.status == "latent" || team.status == "idle" {
			team_focus_record(chain_id)
			action = "recorded"
			reason = "warm_on_focus"
		} else if team.status == "live" {
			reason = "team_live"
		}
		if team.status == "latent" || team.status == "idle" {
			if task_autoscaler_ensure_chain_coordinator(chain_id, "chain_focus_low_priority", "low") {
				action = "boot_requested"
				reason = "coordinator_warm_on_focus_low_priority"
			}
		}
		write_response(client, 200, "OK", team_focus_response_json(chain_id, team.team_id, team.status, action, reason))
		return true
	}

	return false
}

team_focus_record :: proc(chain_id: string) {
	if team_focus_event_count >= TEAM_MAX_FOCUS_EVENTS do return
	team_focus_events[team_focus_event_count] = Team_Focus_Event{chain_id = strings.clone(chain_id), created_unix_ms = router_now_unix_ms()}
	team_focus_event_count += 1
}

http_method_target :: proc(request: string) -> (string, string) {
	line_end := strings.index(request, "\r\n")
	if line_end < 0 do return "", ""
	line := request[:line_end]
	first := strings.index_byte(line, ' ')
	if first < 0 do return "", ""
	second := strings.index_byte(line[first + 1:], ' ')
	if second < 0 do return "", ""
	return line[:first], line[first + 1:first + 1 + second]
}

path_without_query :: proc(target: string) -> string {
	idx := strings.index_byte(target, '?')
	if idx < 0 do return target
	return target[:idx]
}

query_value :: proc(target, name: string) -> string {
	idx := strings.index_byte(target, '?')
	if idx < 0 do return ""
	query := target[idx + 1:]
	for part in strings.split(query, "&") {
		eq := strings.index_byte(part, '=')
		if eq < 0 do continue
		if part[:eq] == name do return part[eq + 1:]
	}
	return ""
}

teams_list_json :: proc(teams: []Team_Record) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"teams":[`)
	for team, i in teams {
		if i > 0 do strings.write_byte(&builder, ',')
		write_team_json(&builder, team)
	}
	strings.write_string(&builder, `]}`)
	return strings.to_string(builder)
}

team_with_members_json :: proc(shown: Team_With_Members) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"team":`)
	write_team_json(&builder, shown.team)
	strings.write_string(&builder, `,"members":`)
	write_members_json(&builder, shown.members)
	strings.write_byte(&builder, '}')
	return strings.to_string(builder)
}

team_members_json :: proc(members: []Team_Member_Record) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"members":`)
	write_members_json(&builder, members)
	strings.write_byte(&builder, '}')
	return strings.to_string(builder)
}

write_members_json :: proc(builder: ^strings.Builder, members: []Team_Member_Record) {
	strings.write_byte(builder, '[')
	for member, i in members {
		if i > 0 do strings.write_byte(builder, ',')
		write_member_json(builder, member)
	}
	strings.write_byte(builder, ']')
}

write_team_json :: proc(builder: ^strings.Builder, team: Team_Record) {
	strings.write_string(builder, `{"team_id":"`); json_write_string(builder, team.team_id)
	strings.write_string(builder, `","project_id":"`); json_write_string(builder, team.project_id)
	strings.write_string(builder, `","kind":"`); json_write_string(builder, team.kind)
	strings.write_string(builder, `","status":"`); json_write_string(builder, team.status)
	strings.write_string(builder, `","chain_id":"`); json_write_string(builder, team.chain_id)
	strings.write_string(builder, fmt.tprintf(`","created_unix_ms":%d,"updated_unix_ms":%d}`, team.created_unix_ms, team.updated_unix_ms))
}

team_focus_response_json :: proc(chain_id, team_id, team_status, action, reason: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"chain_id":"`); json_write_string(&builder, chain_id)
	strings.write_string(&builder, `","team_id":"`); json_write_string(&builder, team_id)
	strings.write_string(&builder, `","team_status":"`); json_write_string(&builder, team_status)
	strings.write_string(&builder, `","action":"`); json_write_string(&builder, action)
	strings.write_string(&builder, `","reason":"`); json_write_string(&builder, reason)
	strings.write_string(&builder, `"}`)
	return strings.to_string(builder)
}

write_member_json :: proc(builder: ^strings.Builder, member: Team_Member_Record) {
	strings.write_string(builder, `{"team_member_id":"`); json_write_string(builder, member.team_member_id)
	strings.write_string(builder, `","team_id":"`); json_write_string(builder, member.team_id)
	strings.write_string(builder, `","role_key":"`); json_write_string(builder, member.role_key)
	strings.write_string(builder, fmt.tprintf(`","role_index":%d,"agent_record_id":`, member.role_index))
	if member.agent_record_id == "" {
		strings.write_string(builder, "null")
	} else {
		strings.write_byte(builder, '"'); json_write_string(builder, member.agent_record_id); strings.write_byte(builder, '"')
	}
	strings.write_string(builder, `,"agent_instance_id":`)
	member_agent_instance_id := team_member_agent_instance_id(member)
	if member_agent_instance_id != "" {
		strings.write_byte(builder, '"'); json_write_string(builder, member_agent_instance_id); strings.write_byte(builder, '"')
	} else {
		strings.write_string(builder, "null")
	}
	strings.write_string(builder, fmt.tprintf(`,"is_user_proxy":%v,"route_to":"`, member.is_user_proxy))
	json_write_string(builder, member.route_to)
	strings.write_string(builder, `","lifecycle_status":"`)
	json_write_string(builder, member_lifecycle_status(member))
	strings.write_string(builder, `"}`)
}

handle_team_add_member :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok || author == "" do return
	member, add_ok, message := team_service_add_member(extract_json_string(body, "team_id", extract_json_string(body, "team", "")), extract_json_string(body, "role_key", extract_json_string(body, "role", "")), extract_json_string(body, "agent_instance_id", ""))
	if !add_ok {
		write_response(client, 400, "Bad Request", team_error_json(message))
		return
	}
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"message":"`); json_write_string(&builder, message)
	strings.write_string(&builder, `","member":`)
	write_member_json(&builder, member)
	strings.write_string(&builder, `}`)
	write_response(client, 200, "OK", strings.to_string(builder))
}

team_error_json :: proc(message: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":false,"message":"`); json_write_string(&builder, message); strings.write_string(&builder, `"}`)
	return strings.to_string(builder)
}

team_member_agent_instance_id :: proc(member: Team_Member_Record) -> string {
	if member.route_to != "" && !member.is_user_proxy do return member.route_to
	if member.agent_instance_id != "" do return member.agent_instance_id
	if idx := agent_record_index(member.agent_record_id); idx >= 0 do return agent_instance_records[idx].agent_instance_id
	if member.role_key == "coordinator" {
		for chain in store_all_chains() {
			if chain.team_id == member.team_id do return chain.coordinator_agent_instance_id
		}
	}
	return ""
}

member_lifecycle_status :: proc(member: Team_Member_Record) -> string {
	agent_instance_id := team_member_agent_instance_id(member)
	if agent_instance_id == "" do return "missing"
	return agent_runtime_tracker_lifecycle_status(agent_instance_id)
}
