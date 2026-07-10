package main

import "core:fmt"
import "core:strings"

Team_With_Members :: struct {
	team: Team_Record,
	members: []Team_Member_Record,
}

team_service_db: Team_DB
team_service_ready: bool

team_service_init :: proc(data_dir: string) -> bool {
	db, ok := team_db_init(data_dir)
	if !ok do return false
	team_service_db = db
	team_service_ready = true
	return true
}

team_service_create_for_chain :: proc(project_id, chain_id, kind_key, name: string) -> string {
	if !team_service_ready do return ""
	kind := team_kind_get(kind_key)
	if kind == nil do return ""

	existing, exists := team_db_get_team_by_chain_id(team_service_db, chain_id)
	if exists do return existing.team_id

	team_id := team_service_team_id(chain_id, name)
	now := router_now_unix_ms()
	team := Team_Record{team_id = team_id, project_id = project_id, kind = kind_key, status = "latent", created_unix_ms = now, updated_unix_ms = now, chain_id = chain_id}
	members := [dynamic]Team_Member_Record{}

	for role in kind.roles {
		for idx in 0..<role.count {
			member := Team_Member_Record{team_id = team_id, role_key = role.role_key, role_index = idx}
			if role.role_key == "user_proxy" {
				member.is_user_proxy = true
				member.route_to = "operator@local"
			}
			append(&members, member)
		}
	}
	if !team_db_create_team_with_members(team_service_db, team, members[:]) {
		fmt.println("team_service_create_for_chain failed", team_id, kind_key, chain_id)
		return ""
	}
	return team_id
}

team_service_list :: proc(project_id, status: string) -> []Team_Record {
	if !team_service_ready do return nil
	return team_db_list_teams(team_service_db, project_id, status)
}

team_service_show :: proc(team_id: string) -> Team_With_Members {
	if !team_service_ready do return Team_With_Members{}
	team, ok := team_db_get_team(team_service_db, team_id)
	if !ok do return Team_With_Members{}
	return Team_With_Members{team = team, members = team_db_list_members(team_service_db, team_id)}
}

team_service_archive :: proc(team_id, reason: string) -> bool {
	if !team_service_ready do return false
	ok := team_db_update_team_status(team_service_db, team_id, "archived")
	if !ok do fmt.println("team_service_archive failed", team_id, reason)
	return ok
}

team_service_team_id :: proc(chain_id, name: string) -> string {
	if name != "" do return fmt.tprintf("team-%s-%s", safe_team_id_part(chain_id), safe_team_id_part(name))
	return fmt.tprintf("team-%s", safe_team_id_part(chain_id))
}

safe_team_id_part :: proc(value: string) -> string {
	builder := strings.builder_make()
	for ch in value {
		if (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '-' {
			strings.write_rune(&builder, ch)
		} else {
			strings.write_byte(&builder, '-')
		}
	}
	out := strings.to_string(builder)
	if out == "" do return "unnamed"
	return out
}
