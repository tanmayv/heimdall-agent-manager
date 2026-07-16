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

team_service_create_for_chain :: proc(project_id, chain_id, kind_key, name, coordinator_agent_instance_id: string) -> string {
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
			member := Team_Member_Record{team_member_id = team_service_member_id(team_id, role.role_key, idx), team_id = team_id, role_key = role.role_key, role_index = idx, agent_instance_id = team_service_member_agent_instance_id(project_id, chain_id, team_id, role.role_key, idx)}
			if role.role_key == "user_proxy" {
				member.is_user_proxy = true
				member.route_to = HUMAN_RECIPIENT_ID
				member.agent_instance_id = ""
			} else if role.role_key == "coordinator" && idx == 0 && coordinator_agent_instance_id != "" {
				member.route_to = coordinator_agent_instance_id
				if rec_idx := agent_record_index_by_instance(coordinator_agent_instance_id); rec_idx >= 0 {
					member.agent_record_id = agent_instance_records[rec_idx].agent_record_id
				}
			} else {
				resolved_instance_id, rec_id, provision_ok := team_service_provision_member_agent(member.agent_instance_id, project_id, role.role_key, role.agent_template_id, role.default_provider, role.default_tier)
				if !provision_ok {
					fmt.println("team_service_create_for_chain failed to provision agent identity", team_id, member.agent_instance_id)
					return ""
				}
				member.route_to = resolved_instance_id
				member.agent_record_id = rec_id
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

team_service_add_member :: proc(team_id, role_key, agent_instance_id: string) -> (Team_Member_Record, bool, string) {
	if !team_service_ready do return Team_Member_Record{}, false, "team service not ready"
	if team_id == "" || role_key == "" || agent_instance_id == "" do return Team_Member_Record{}, false, "team_id, role, and agent_instance_id are required"
	if _, ok := team_db_get_team(team_service_db, team_id); !ok do return Team_Member_Record{}, false, "team not found"
	members := team_db_list_members(team_service_db, team_id)
	next_index := 0
	for member in members {
		if member.route_to == agent_instance_id || member.agent_instance_id == agent_instance_id do return member, true, "already member"
		if member.role_key == role_key && member.role_index >= next_index do next_index = member.role_index + 1
	}
	team, _ := team_db_get_team(team_service_db, team_id)
	member := Team_Member_Record{team_member_id = team_service_member_id(team_id, role_key, next_index), team_id = team_id, role_key = role_key, role_index = next_index, agent_instance_id = team_service_member_agent_instance_id(team.project_id, team.chain_id, team_id, role_key, next_index), route_to = agent_instance_id}
	if rec_idx := agent_record_index_by_instance(agent_instance_id); rec_idx >= 0 {
		member.agent_record_id = agent_instance_records[rec_idx].agent_record_id
	}
	if !team_db_insert_member(team_service_db, member) do return Team_Member_Record{}, false, "add member failed"
	return member, true, "added"
}

team_service_provision_member_agent :: proc(slot_agent_instance_id, project_id, role_key, template_id, provider_profile, model_tier: string) -> (string, string, bool) {
	if slot_agent_instance_id == "" do return "", "", true
	durable_agent_id := team_service_role_durable_agent_id(role_key, template_id)
	template := template_id
	if template == "" do template = derive_agent_class(durable_agent_id)
	tier := model_tier
	if tier == "" do tier = "normal"
	concrete_agent_instance_id := agent_instance_id_new(durable_agent_id)
	if !valid_agent_instance_id(concrete_agent_instance_id) do return "", "", false
	// Ensure a simple reusable durable identity exists, but do not overwrite its
	// project defaults from team-slot resolution. The concrete instance stores the
	// chain/project association authoritatively.
	if agent_id_index(durable_agent_id) < 0 {
		_ = agent_id_upsert(durable_agent_id, durable_agent_id, template, provider_profile, tier, "", "team", role_key)
	}
	rec_id, _, ok := agent_record_upsert(concrete_agent_instance_id, slot_agent_instance_id, template, provider_profile, project_id, "", tier, AGENT_IDENTITY_STATE_PROVISIONED, AGENT_SCOPE_GENERATED_CHAIN, role_key)
	return concrete_agent_instance_id, rec_id, ok
}

team_service_ensure_member_route :: proc(member: Team_Member_Record) -> (string, bool) {
	if member.is_user_proxy {
		if member.route_to != "" do return member.route_to, true
		return "user_proxy", true
	}
	if member.route_to != "" do return member.route_to, true
	// Legacy team rows stored the concrete agent instance directly in the slot
	// field. Preserve exact-instance routing for those records until state cleanup
	// removes stale indexed durable ids.
	if member.agent_instance_id != "" {
		if idx := agent_record_index_by_instance(member.agent_instance_id); idx >= 0 && agent_instance_records[idx].archived_at_unix_ms == 0 {
			return member.agent_instance_id, true
		}
	}
	team, ok := team_db_get_team(team_service_db, member.team_id)
	if !ok do return "", false
	template_id, provider, tier := team_service_role_defaults(team.kind, member.role_key)
	resolved_instance_id, rec_id, provision_ok := team_service_provision_member_agent(member.agent_instance_id, team.project_id, member.role_key, template_id, provider, tier)
	if !provision_ok || resolved_instance_id == "" do return "", false
	updated := member
	updated.route_to = resolved_instance_id
	updated.agent_record_id = rec_id
	if !team_db_insert_member(team_service_db, updated) do return "", false
	return resolved_instance_id, true
}

team_service_role_durable_agent_id :: proc(role_key, template_id: string) -> string {
	role_part := safe_agent_id_part(role_key)
	if role_part != "" && role_part != "unnamed" do return role_part
	template_part := safe_agent_id_part(template_id)
	if template_part != "" && template_part != "unnamed" do return template_part
	return "agent"
}

team_service_member_slot_label :: proc(role_key: string, role_index: int) -> string {
	role_part := safe_team_id_part(role_key)
	return fmt.tprintf("%s-%d", role_part, role_index + 1)
}

team_service_role_defaults :: proc(kind_key, role_key: string) -> (string, string, string) {
	kind := team_kind_get(kind_key)
	if kind == nil do return "", "", "normal"
	for role in kind.roles {
		if role.role_key == role_key do return role.agent_template_id, role.default_provider, role.default_tier
	}
	return "", "", "normal"
}

team_service_member_id :: proc(team_id, role_key: string, role_index: int) -> string {
	return fmt.tprintf("%s:%s:%d", team_id, role_key, role_index)
}

team_service_member_agent_instance_id :: proc(project_id, chain_id, team_id, role_key: string, role_index: int) -> string {
	scope := team_service_agent_scope(project_id, chain_id, team_id)
	role_part := safe_team_id_part(role_key)
	if role_key == "coordinator" && role_index == 0 {
		return fmt.tprintf("coordinator@%s", scope)
	}
	return fmt.tprintf("%s-%d@%s", role_part, role_index + 1, scope)
}

team_service_agent_scope :: proc(project_id, chain_id, fallback_team_id: string) -> string {
	project_part := safe_team_id_part(project_id)
	if pidx := project_index(project_id); pidx >= 0 {
		project := project_records[pidx]
		dir := project_anchor_value(project, "directory", "")
		base := team_service_path_basename(dir)
		if base != "" do project_part = safe_team_id_part(base)
		if project_part == "" && project.name != "" do project_part = safe_team_id_part(project.name)
	}
	chain_part := safe_team_id_part(chain_id)
	if project_part != "" && chain_part != "" do return fmt.tprintf("%s-%s", project_part, chain_part)
	if chain_part != "" do return chain_part
	return safe_team_id_part(fallback_team_id)
}

team_service_path_basename :: proc(path: string) -> string {
	trimmed := strings.trim_right(path, "/")
	if trimmed == "" do return ""
	idx := strings.last_index_byte(trimmed, '/')
	if idx >= 0 && idx + 1 < len(trimmed) do return trimmed[idx + 1:]
	return trimmed
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
