package main

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"

TEAMS_V1_MARKER_FILE :: "teams-v1.complete"

teams_v1_migration_maybe_run :: proc(data_dir: string) {
	if os.get_env_alloc("HEIMDALL_MIGRATE_V1", context.allocator) != "1" do return
	if !teams_v1_migration_needs_run(data_dir) do return
	migrations_dir := fmt.tprintf("%s/migrations", data_dir)
	_ = os.make_directory_all(migrations_dir)
	report_path := fmt.tprintf("%s/teams-v1-%d.report.md", migrations_dir, router_now_unix_ms())
	map_db_path := fmt.tprintf("%s/teams-v1-memory-map.db", migrations_dir)
	report := strings.builder_make()
	strings.write_string(&report, "# Teams v1 migration report\n\n")
	backup_path := fmt.tprintf("%s.pre-teams-v1", data_dir)
	backup_ok := teams_v1_copy_dir_if_missing(data_dir, backup_path)
	strings.write_string(&report, "## Backup\n")
	strings.write_string(&report, fmt.tprintf("- source: `%s`\n- backup: `%s`\n- created_or_reused: `%t`\n\n", data_dir, backup_path, backup_ok))
	if !backup_ok {
		teams_v1_migration_fail(data_dir, backup_path, report_path, &report, "backup creation failed")
		return
	}
	if os.get_env_alloc("HEIMDALL_MIGRATE_V1_FAIL_AFTER_BACKUP", context.allocator) == "1" {
		teams_v1_migration_fail(data_dir, backup_path, report_path, &report, "forced failure after backup for restore-path validation")
		return
	}
	strings.write_string(&report, "## 9.1 Agent-instance sweep -> legacy solo teams\n")
	solo_created := teams_v1_migrate_agents_to_legacy_solo(&report)
	strings.write_string(&report, fmt.tprintf("- created_or_updated: %d\n\n", solo_created))
	strings.write_string(&report, "## 9.2 swe-team preservation\n")
	swe_count := teams_v1_migrate_swe_team_legacy(&report)
	strings.write_string(&report, fmt.tprintf("- created_or_updated_members: %d\n\n", swe_count))
	strings.write_string(&report, "## 9.3 Task chain back-fill\n")
	chain_count := teams_v1_backfill_task_chain_team_ids(&report)
	strings.write_string(&report, fmt.tprintf("- chains_backfilled: %d\n\n", chain_count))
	strings.write_string(&report, "## 9.4 Memory rewrite\n")
	memory_count := teams_v1_migrate_memory_scope(&report, map_db_path)
	strings.write_string(&report, fmt.tprintf("- memory_rows_rewritten: %d\n- mapping_table: `%s`\n\n", memory_count, map_db_path))
	strings.write_string(&report, "## 9.5 Anchor migration\n")
	anchor_count := project_migrate_anchors_into_report(&report)
	strings.write_string(&report, fmt.tprintf("- anchors_rewritten: %d\n\n", anchor_count))
	strings.write_string(&report, "## 9.6 VCS workspace pre-provisioning\n- no workspaces provisioned during migration\n\n")
	strings.write_string(&report, "## Rollback\n- If migration fails, the daemon restores from `<data_dir>.pre-teams-v1`, removes generated `teams.db` / `vcs.db`, writes failure details here, and exits non-zero.\n\n")
	_ = os.write_entire_file(report_path, strings.to_string(report))
	_ = os.write_entire_file(fmt.tprintf("%s/%s", migrations_dir, TEAMS_V1_MARKER_FILE), report_path)
}

teams_v1_migration_needs_run :: proc(data_dir: string) -> bool {
	marker_path := fmt.tprintf("%s/migrations/%s", data_dir, TEAMS_V1_MARKER_FILE)
	marker, err := os.read_entire_file(marker_path, context.allocator)
	if err != nil do return true
	report_path := strings.trim_space(string(marker))
	if report_path == "" do return true
	if _, report_err := os.read_entire_file(report_path, context.allocator); report_err != nil do return true
	if teams_v1_has_unmigrated_agents() do return true
	if teams_v1_has_unmigrated_task_chains() do return true
	if teams_v1_has_unmigrated_memory() do return true
	if teams_v1_has_invalid_project_anchors() do return true
	return false
}

teams_v1_has_unmigrated_agents :: proc() -> bool {
	for i in 0..<agent_instance_record_count {
		rec := agent_instance_records[i]
		if rec.agent_instance_id == "" || rec.archived_at_unix_ms != 0 do continue
		if !teams_v1_agent_has_team(rec) do return true
	}
	return false
}

teams_v1_agent_has_team :: proc(rec: Agent_Instance_Record) -> bool {
	if strings.has_suffix(rec.agent_instance_id, "@swe-team") {
		if _, ok := team_db_get_team(team_service_db, "swe-team-legacy"); ok do return true
	}
	team_id := fmt.tprintf("legacy-%s", rec.agent_instance_id)
	team, ok := team_db_get_team(team_service_db, team_id)
	if !ok do return false
	members := team_db_list_members(team_service_db, team.team_id)
	for member in members {
		if member.agent_record_id == rec.agent_record_id do return true
	}
	return false
}

teams_v1_has_unmigrated_task_chains :: proc() -> bool {
	for chain in store_all_chains() {
		if chain.team_id == "" do return true
	}
	return false
}

teams_v1_has_unmigrated_memory :: proc() -> bool {
	return false
}

teams_v1_migration_fail :: proc(data_dir, backup_path, report_path: string, report: ^strings.Builder, reason: string) {
	restored := teams_v1_restore_backup(data_dir, backup_path)
	strings.write_string(report, "## Failure\n")
	strings.write_string(report, fmt.tprintf("- reason: %s\n- restore_attempted: true\n- restore_ok: %t\n", reason, restored))
	_ = os.write_entire_file(report_path, strings.to_string(report^))
	os.exit(1)
}

teams_v1_restore_backup :: proc(data_dir, backup_path: string) -> bool {
	_ = os.remove(fmt.tprintf("%s/teams/teams.db", data_dir))
	_ = os.remove(fmt.tprintf("%s/vcs/vcs.db", data_dir))
	_ = os.remove_all(data_dir)
	return teams_v1_copy_dir(backup_path, data_dir)
}

teams_v1_has_invalid_project_anchors :: proc() -> bool {
	for i in 0..<project_record_count {
		if project_first_invalid_anchor(project_records[i].anchors[:], project_records[i].anchor_count) != "" do return true
	}
	return false
}

teams_v1_copy_dir_if_missing :: proc(src, dst: string) -> bool {
	if os.is_dir(dst) do return true
	return teams_v1_copy_dir(src, dst)
}

teams_v1_copy_dir :: proc(src, dst: string) -> bool {
	if err := os.make_directory_all(dst); err != nil do return false
	entries, err := os.read_directory_by_path(src, -1, context.allocator)
	if err != 0 do return false
	for entry in entries {
		src_path := fmt.tprintf("%s/%s", src, entry.name)
		dst_path := fmt.tprintf("%s/%s", dst, entry.name)
		if os.is_dir(src_path) {
			if !teams_v1_copy_dir(src_path, dst_path) do return false
			continue
		}
		data, read_err := os.read_entire_file(src_path, context.allocator)
		if read_err != nil do return false
		if os.write_entire_file(dst_path, data) != nil do return false
	}
	return true
}

teams_v1_migrate_agents_to_legacy_solo :: proc(report: ^strings.Builder) -> int {
	changed := 0
	for i in 0..<agent_instance_record_count {
		rec := agent_instance_records[i]
		if rec.agent_instance_id == "" || rec.archived_at_unix_ms != 0 do continue
		team_id := fmt.tprintf("legacy-%s", rec.agent_instance_id)
		team, ok := team_db_get_team(team_service_db, team_id)
		if !ok {
			team = Team_Record{team_id = team_id, kind = "solo", project_id = rec.project_id if rec.project_id != "" else "_orphan", status = "idle", created_unix_ms = rec.created_unix_ms if rec.created_unix_ms != 0 else router_now_unix_ms(), updated_unix_ms = router_now_unix_ms(), chain_id = team_id}
			if team_db_insert_team(team_service_db, team) {
				worker_ok := team_db_insert_member(team_service_db, Team_Member_Record{team_id = team_id, role_key = "worker", role_index = 0, agent_record_id = rec.agent_record_id})
				proxy_ok := team_db_insert_member(team_service_db, Team_Member_Record{team_id = team_id, role_key = "user_proxy", role_index = 0, is_user_proxy = true, route_to = "operator@local"})
				if worker_ok && proxy_ok {
					changed += 1
					strings.write_string(report, fmt.tprintf("- created `%s` for `%s`\n", team_id, rec.agent_instance_id))
				} else {
					strings.write_string(report, fmt.tprintf("- failed member insert for `%s`\n", team_id))
				}
			}
			continue
		}
		worker_ok := team_db_insert_member(team_service_db, Team_Member_Record{team_id = team_id, role_key = "worker", role_index = 0, agent_record_id = rec.agent_record_id})
		proxy_ok := team_db_insert_member(team_service_db, Team_Member_Record{team_id = team_id, role_key = "user_proxy", role_index = 0, is_user_proxy = true, route_to = "operator@local"})
		if !worker_ok || !proxy_ok do strings.write_string(report, fmt.tprintf("- failed member update for `%s`\n", team_id))
	}
	if changed == 0 do strings.write_string(report, "- no changes\n")
	return changed
}

teams_v1_migrate_swe_team_legacy :: proc(report: ^strings.Builder) -> int {
	team_id := "swe-team-legacy"
	team, ok := team_db_get_team(team_service_db, team_id)
	if !ok {
		team = Team_Record{team_id = team_id, kind = "coding", project_id = "swe-team", status = "idle", created_unix_ms = router_now_unix_ms(), updated_unix_ms = router_now_unix_ms(), chain_id = team_id}
		if !team_db_insert_team(team_service_db, team) {
			strings.write_string(report, "- failed to create swe-team-legacy\n")
			return 0
		}
	}
	changed := 0
	members := [dynamic]Team_Member_Record{}
	append(&members, teams_v1_swe_member(team_id, "principal@swe-team", "coordinator", 0))
	append(&members, teams_v1_swe_member(team_id, "coder@swe-team", "coder", 0))
	append(&members, teams_v1_swe_member(team_id, "reviewer@swe-team", "reviewer", 0))
	append(&members, teams_v1_swe_member(team_id, "tester@swe-team", "tester", 0))
	append(&members, teams_v1_swe_member(team_id, "planner@swe-team", "specialist", 0))
	append(&members, teams_v1_swe_member(team_id, "researcher@swe-team", "specialist", 1))
	append(&members, teams_v1_swe_member(team_id, "risk-analyst@swe-team", "specialist", 2))
	for member in members {
		if team_db_insert_member(team_service_db, member) {
			changed += 1
			strings.write_string(report, fmt.tprintf("- ensured `%s` as `%s[%d]`\n", teams_v1_member_instance_id(member.agent_record_id), member.role_key, member.role_index))
		} else {
			strings.write_string(report, fmt.tprintf("- failed to ensure `%s` as `%s[%d]`\n", teams_v1_member_instance_id(member.agent_record_id), member.role_key, member.role_index))
		}
	}
	delete(members)
	if changed == 0 do strings.write_string(report, "- no changes\n")
	return changed
}

teams_v1_member_instance_id :: proc(agent_record_id: string) -> string {
	if idx := agent_record_index(agent_record_id); idx >= 0 do return agent_instance_records[idx].agent_instance_id
	return agent_record_id
}

teams_v1_swe_member :: proc(team_id, agent_instance_id, role_key: string, role_index: int) -> Team_Member_Record {
	agent_record_id := ""
	if idx := agent_record_index_by_instance(agent_instance_id); idx >= 0 do agent_record_id = agent_instance_records[idx].agent_record_id
	return Team_Member_Record{team_id = team_id, role_key = role_key, role_index = role_index, agent_record_id = agent_record_id}
}

teams_v1_backfill_task_chain_team_ids :: proc(report: ^strings.Builder) -> int {
	changed := 0
	for existing in store_all_chains() {
		if existing.team_id != "" do continue
		chain := existing
		chain.team_id = strings.clone(task_chain_effective_team_id(chain))
		_ = store_upsert_chain(chain)
		if task_db_ready && task_db_save_chain(chain) {
			changed += 1
			strings.write_string(report, fmt.tprintf("- `%s` -> `%s`\n", chain.chain_id, chain.team_id))
		}
	}
	if changed == 0 do strings.write_string(report, "- no changes\n")
	return changed
}

teams_v1_migrate_memory_scope :: proc(report: ^strings.Builder, map_db_path: string) -> int {
	_ = teams_v1_memory_map_init(map_db_path)
	strings.write_string(report, "- skipped: memory targeting now uses target_team_kind/target_role/target_project_id only; legacy memory migration is intentionally disabled\n")
	return 0
}

teams_v1_memory_target :: proc(rec: contracts.Memory_Record) -> (string, string) {
	_ = rec
	return "", ""
}

teams_v1_resolve_team_for_agent :: proc(agent_instance_id: string) -> string {
	if strings.has_suffix(agent_instance_id, "@swe-team") do return "swe-team-legacy"
	return fmt.tprintf("legacy-%s", agent_instance_id)
}

teams_v1_slug :: proc(value: string) -> string {
	builder := strings.builder_make()
	for ch in strings.to_lower(value) {
		if (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') {
			strings.write_rune(&builder, ch)
		} else if ch == ' ' || ch == '-' || ch == '_' || ch == '@' || ch == '/' || ch == '.' {
			strings.write_byte(&builder, '-')
		}
	}
	out := strings.trim(strings.to_string(builder), "-")
	if out == "" do return "unknown"
	return out
}

teams_v1_memory_map_init :: proc(db_path: string) -> bool {
	sql := "CREATE TABLE IF NOT EXISTS memory_migration_map (memory_id TEXT PRIMARY KEY, old_scope TEXT, old_subject TEXT, new_scope TEXT, new_subject_key TEXT);"
	return teams_v1_sqlite_exec(db_path, sql)
}

teams_v1_memory_map_insert :: proc(db_path, memory_id, old_scope, old_subject, new_scope, new_subject_key: string) -> bool {
	sql := fmt.tprintf("INSERT OR REPLACE INTO memory_migration_map (memory_id, old_scope, old_subject, new_scope, new_subject_key) VALUES (%s, %s, %s, %s, %s);", sql_text(memory_id), sql_text(old_scope), sql_text(old_subject), sql_text(new_scope), sql_text(new_subject_key))
	return teams_v1_sqlite_exec(db_path, sql)
}

teams_v1_sqlite_exec :: proc(db_path, sql: string) -> bool {
	cmd := []string{"sqlite3", db_path, sql}
	state, _, _, err := os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
	return err == nil && state.success
}
