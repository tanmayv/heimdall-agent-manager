package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

TEAM_DB_USER_VERSION :: 3

Team_DB :: struct {
	data_dir: string,
	teams_dir: string,
	db_path: string,
}

Team_Record :: struct {
	team_id: string,
	project_id: string,
	kind: string,
	status: string,
	created_unix_ms: i64,
	updated_unix_ms: i64,
	chain_id: string,
}

Team_Member_Record :: struct {
	team_member_id: string,
	team_id: string,
	role_key: string,
	role_index: int,
	agent_instance_id: string,
	agent_record_id: string,
	is_user_proxy: bool,
	route_to: string,
}

team_db_init :: proc(data_dir: string) -> (Team_DB, bool) {
	db := Team_DB{
		data_dir = strings.clone(data_dir),
		teams_dir = strings.clone(fmt.tprintf("%s/teams", data_dir)),
		db_path = strings.clone(fmt.tprintf("%s/teams/teams.db", data_dir)),
	}
	_ = os.make_directory_all(db.teams_dir)
	return db, team_db_migrate(db.db_path)
}

team_db_migrate :: proc(db_path: string) -> bool {
	version := team_db_user_version(db_path)
	if version < 1 {
		if !team_db_exec(db_path, `
CREATE TABLE IF NOT EXISTS teams (
	team_id TEXT PRIMARY KEY,
	project_id TEXT,
	kind TEXT,
	status TEXT,
	created_unix_ms INTEGER,
	updated_unix_ms INTEGER,
	chain_id TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS team_members (
	team_member_id TEXT,
	team_id TEXT,
	role_key TEXT,
	role_index INTEGER,
	agent_instance_id TEXT,
	agent_record_id TEXT,
	is_user_proxy INTEGER DEFAULT 0,
	route_to TEXT,
	PRIMARY KEY (team_id, role_key, role_index)
);
PRAGMA user_version = 1;
`) {
			return false
		}
	}

	if version < 2 {
		if !team_db_exec(db_path, `CREATE UNIQUE INDEX IF NOT EXISTS idx_teams_chain_id ON teams(chain_id);`) do return false
	}
	if version < 3 {
		if !team_db_has_column(db_path, "team_members", "is_user_proxy") {
			if !team_db_exec(db_path, `ALTER TABLE team_members ADD COLUMN is_user_proxy INTEGER DEFAULT 0;`) do return false
		}
		if !team_db_has_column(db_path, "team_members", "route_to") {
			if !team_db_exec(db_path, `ALTER TABLE team_members ADD COLUMN route_to TEXT;`) do return false
		}
		if !team_db_has_column(db_path, "team_members", "team_member_id") {
			if !team_db_exec(db_path, `ALTER TABLE team_members ADD COLUMN team_member_id TEXT NOT NULL DEFAULT '';`) do return false
		}
		if !team_db_has_column(db_path, "team_members", "agent_instance_id") {
			if !team_db_exec(db_path, `ALTER TABLE team_members ADD COLUMN agent_instance_id TEXT NOT NULL DEFAULT '';`) do return false
		}
		if !team_db_exec(db_path, `UPDATE team_members SET team_member_id = team_id || ':' || role_key || ':' || role_index WHERE team_member_id = '';`) do return false
		if !team_db_exec(db_path, `UPDATE team_members SET agent_instance_id = role_key || '-' || (role_index + 1) || '@' || team_id WHERE agent_instance_id = '' AND is_user_proxy = 0;`) do return false
	}

	if !team_db_has_column(db_path, "teams", "chain_id") {
		if !team_db_exec(db_path, `ALTER TABLE teams ADD COLUMN chain_id TEXT NOT NULL DEFAULT '';`) do return false
	}
	if !team_db_has_column(db_path, "team_members", "is_user_proxy") {
		if !team_db_exec(db_path, `ALTER TABLE team_members ADD COLUMN is_user_proxy INTEGER DEFAULT 0;`) do return false
	}
	if !team_db_has_column(db_path, "team_members", "route_to") {
		if !team_db_exec(db_path, `ALTER TABLE team_members ADD COLUMN route_to TEXT;`) do return false
	}
	if !team_db_has_column(db_path, "team_members", "team_member_id") {
		if !team_db_exec(db_path, `ALTER TABLE team_members ADD COLUMN team_member_id TEXT NOT NULL DEFAULT '';`) do return false
	}
	if !team_db_has_column(db_path, "team_members", "agent_instance_id") {
		if !team_db_exec(db_path, `ALTER TABLE team_members ADD COLUMN agent_instance_id TEXT NOT NULL DEFAULT '';`) do return false
	}
	if !team_db_exec(db_path, `CREATE UNIQUE INDEX IF NOT EXISTS idx_teams_chain_id ON teams(chain_id);`) do return false
	if !team_db_exec(db_path, `CREATE UNIQUE INDEX IF NOT EXISTS idx_team_members_member_id ON team_members(team_member_id);`) do return false
	if !team_db_exec(db_path, `CREATE UNIQUE INDEX IF NOT EXISTS idx_team_members_agent_instance_id ON team_members(agent_instance_id) WHERE agent_instance_id != '';`) do return false
	return team_db_exec(db_path, fmt.tprintf("PRAGMA user_version = %d;", TEAM_DB_USER_VERSION))
}

team_db_has_column :: proc(db_path, table_name, column_name: string) -> bool {
	out, ok := team_db_query(db_path, fmt.tprintf("PRAGMA table_info(%s);", table_name))
	if !ok do return false
	needle := fmt.tprintf("|%s|", column_name)
	return strings.contains(out, needle)
}

team_db_insert_team :: proc(db: Team_DB, team: Team_Record) -> bool {
	return team_db_exec(db.db_path, team_db_insert_team_sql(team))
}

team_db_insert_team_sql :: proc(team: Team_Record) -> string {
	return fmt.tprintf(
		"INSERT OR REPLACE INTO teams (team_id, project_id, kind, status, created_unix_ms, updated_unix_ms, chain_id) VALUES (%s, %s, %s, %s, %d, %d, %s);",
		sql_text(team.team_id), sql_text(team.project_id), sql_text(team.kind), sql_text(team.status), team.created_unix_ms, team.updated_unix_ms, sql_text(team.chain_id),
	)
}

team_db_create_team_sql :: proc(team: Team_Record) -> string {
	return fmt.tprintf(
		"INSERT INTO teams (team_id, project_id, kind, status, created_unix_ms, updated_unix_ms, chain_id) VALUES (%s, %s, %s, %s, %d, %d, %s);",
		sql_text(team.team_id), sql_text(team.project_id), sql_text(team.kind), sql_text(team.status), team.created_unix_ms, team.updated_unix_ms, sql_text(team.chain_id),
	)
}

team_db_insert_member :: proc(db: Team_DB, member: Team_Member_Record) -> bool {
	return team_db_exec(db.db_path, team_db_insert_member_sql(member))
}

team_db_create_team_with_members :: proc(db: Team_DB, team: Team_Record, members: []Team_Member_Record) -> bool {
	builder := strings.builder_make()
	strings.write_string(&builder, "BEGIN IMMEDIATE;\n")
	strings.write_string(&builder, team_db_create_team_sql(team))
	strings.write_byte(&builder, '\n')
	for member in members {
		strings.write_string(&builder, team_db_insert_member_sql(member))
		strings.write_byte(&builder, '\n')
	}
	strings.write_string(&builder, "COMMIT;")
	return team_db_exec(db.db_path, strings.to_string(builder))
}

team_db_insert_member_sql :: proc(member: Team_Member_Record) -> string {
	m := team_member_with_identity_defaults(member)
	user_proxy := 0
	if m.is_user_proxy do user_proxy = 1
	return fmt.tprintf(
		"INSERT OR REPLACE INTO team_members (team_member_id, team_id, role_key, role_index, agent_instance_id, agent_record_id, is_user_proxy, route_to) VALUES (%s, %s, %s, %d, %s, %s, %d, %s);",
		sql_text(m.team_member_id), sql_text(m.team_id), sql_text(m.role_key), m.role_index, sql_text(m.agent_instance_id), sql_nullable_text(m.agent_record_id), user_proxy, sql_text(m.route_to),
	)
}

team_member_with_identity_defaults :: proc(member: Team_Member_Record) -> Team_Member_Record {
	m := member
	if m.team_member_id == "" do m.team_member_id = team_service_member_id(m.team_id, m.role_key, m.role_index)
	if m.agent_instance_id == "" && !m.is_user_proxy {
		if idx := agent_record_index(m.agent_record_id); idx >= 0 {
			m.agent_instance_id = agent_instance_records[idx].agent_instance_id
		} else {
			m.agent_instance_id = team_service_member_agent_instance_id(m.team_id, m.role_key, m.role_index)
		}
	}
	return m
}

team_db_get_team :: proc(db: Team_DB, team_id: string) -> (Team_Record, bool) {
	out, ok := team_db_query(db.db_path, fmt.tprintf("SELECT team_id, project_id, kind, status, created_unix_ms, updated_unix_ms, chain_id FROM teams WHERE team_id = %s;", sql_text(team_id)))
	if !ok do return Team_Record{}, false
	return team_record_from_line(strings.trim_space(out))
}

team_db_get_team_by_chain_id :: proc(db: Team_DB, chain_id: string) -> (Team_Record, bool) {
	out, ok := team_db_query(db.db_path, fmt.tprintf("SELECT team_id, project_id, kind, status, created_unix_ms, updated_unix_ms, chain_id FROM teams WHERE chain_id = %s;", sql_text(chain_id)))
	if !ok do return Team_Record{}, false
	return team_record_from_line(strings.trim_space(out))
}

team_db_list_teams :: proc(db: Team_DB, project_id, status: string) -> []Team_Record {
	sql := "SELECT team_id, project_id, kind, status, created_unix_ms, updated_unix_ms, chain_id FROM teams"
	where_clause := ""
	if project_id != "" do where_clause = fmt.tprintf("project_id = %s", sql_text(project_id))
	if status != "" {
		if where_clause != "" do where_clause = fmt.tprintf("%s AND ", where_clause)
		where_clause = fmt.tprintf("%sstatus = %s", where_clause, sql_text(status))
	}
	if where_clause != "" do sql = fmt.tprintf("%s WHERE %s", sql, where_clause)
	out, ok := team_db_query(db.db_path, fmt.tprintf("%s ORDER BY team_id;", sql))
	if !ok do return nil
	rows := [dynamic]Team_Record{}
	for line in strings.split(out, "\n") {
		trimmed := strings.trim_space(line)
		if trimmed == "" do continue
		record, parsed := team_record_from_line(trimmed)
		if parsed do append(&rows, record)
	}
	return rows[:]
}

team_db_list_members :: proc(db: Team_DB, team_id: string) -> []Team_Member_Record {
	out, ok := team_db_query(db.db_path, fmt.tprintf("SELECT COALESCE(team_member_id, ''), team_id, role_key, role_index, COALESCE(agent_instance_id, ''), COALESCE(agent_record_id, ''), is_user_proxy, COALESCE(route_to, '') FROM team_members WHERE team_id = %s ORDER BY role_key, role_index;", sql_text(team_id)))
	if !ok do return nil
	rows := [dynamic]Team_Member_Record{}
	for line in strings.split(out, "\n") {
		trimmed := strings.trim_space(line)
		if trimmed == "" do continue
		record, parsed := team_member_from_line(trimmed)
		if parsed do append(&rows, record)
	}
	return rows[:]
}

team_db_update_team_status :: proc(db: Team_DB, team_id, status: string) -> bool {
	out, ok := team_db_query(db.db_path, fmt.tprintf("UPDATE teams SET status = %s, updated_unix_ms = %d WHERE team_id = %s; SELECT changes();", sql_text(status), router_now_unix_ms(), sql_text(team_id)))
	if !ok do return false
	changed, parsed := strconv.parse_int(strings.trim_space(out))
	return parsed && changed > 0
}

team_db_count_teams :: proc(db: Team_DB) -> int {
	return team_db_count(db.db_path, "teams")
}

team_db_count_members :: proc(db: Team_DB) -> int {
	return team_db_count(db.db_path, "team_members")
}

team_db_count :: proc(db_path, table_name: string) -> int {
	out, ok := team_db_query(db_path, fmt.tprintf("SELECT COUNT(*) FROM %s;", table_name))
	if !ok do return -1
	value, parsed_ok := strconv.parse_int(strings.trim_space(out))
	if !parsed_ok do return -1
	return int(value)
}

team_db_user_version :: proc(db_path: string) -> int {
	out, ok := team_db_query(db_path, "PRAGMA user_version;")
	if !ok do return 0
	value, parsed_ok := strconv.parse_int(strings.trim_space(out))
	if !parsed_ok do return 0
	return int(value)
}

team_record_from_line :: proc(line: string) -> (Team_Record, bool) {
	parts := strings.split(line, "|")
	if len(parts) < 7 do return Team_Record{}, false
	created, ok_created := strconv.parse_int(parts[4])
	updated, ok_updated := strconv.parse_int(parts[5])
	if !ok_created || !ok_updated do return Team_Record{}, false
	return Team_Record{team_id = strings.clone(parts[0]), project_id = strings.clone(parts[1]), kind = strings.clone(parts[2]), status = strings.clone(parts[3]), created_unix_ms = i64(created), updated_unix_ms = i64(updated), chain_id = strings.clone(parts[6])}, true
}

team_member_from_line :: proc(line: string) -> (Team_Member_Record, bool) {
	parts := strings.split(line, "|")
	if len(parts) < 8 do return Team_Member_Record{}, false
	role_index, ok_index := strconv.parse_int(parts[3])
	is_user_proxy, ok_proxy := strconv.parse_int(parts[6])
	if !ok_index || !ok_proxy do return Team_Member_Record{}, false
	return Team_Member_Record{team_member_id = strings.clone(parts[0]), team_id = strings.clone(parts[1]), role_key = strings.clone(parts[2]), role_index = int(role_index), agent_instance_id = strings.clone(parts[4]), agent_record_id = strings.clone(parts[5]), is_user_proxy = is_user_proxy != 0, route_to = strings.clone(parts[7])}, true
}

team_db_exec :: proc(db_path, sql: string) -> bool {
	_, ok := team_db_query(db_path, sql)
	return ok
}

team_db_query :: proc(db_path, sql: string) -> (string, bool) {
	cmd := []string{"sqlite3", db_path, sql}
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
	if err != nil || !state.success do return "", false
	return string(stdout), true
}

sql_nullable_text :: proc(value: string) -> string {
	if value == "" do return "NULL"
	return sql_text(value)
}

sql_text :: proc(value: string) -> string {
	builder := strings.builder_make()
	strings.write_byte(&builder, '\'')
	for ch in value {
		if ch == '\'' do strings.write_byte(&builder, '\'')
		strings.write_rune(&builder, ch)
	}
	strings.write_byte(&builder, '\'')
	return strings.to_string(builder)
}
