package team_db_service_test

import "core:fmt"
import "core:os"
import daemon "odin_test:daemon"

main :: proc() {
	data_dir := "/tmp/heimdall-team-db-service-test"
	if len(os.args) > 1 do data_dir = os.args[1]
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"rm", "-rf", fmt.tprintf("%s/teams", data_dir)}}, context.allocator)

	db, ok := daemon.team_db_init(data_dir)
	check(ok, "fresh team_db_init failed")
	check(file_exists(db.db_path), "fresh init did not create teams.db")
	check(daemon.team_db_user_version(db.db_path) == 1, "fresh init did not set user_version")
	check(daemon.db_has_column(db.db_path, "teams", "chain_id"), "teams.chain_id missing")
	check(daemon.db_has_column(db.db_path, "team_members", "is_user_proxy"), "team_members.is_user_proxy missing")
	check(daemon.db_has_column(db.db_path, "team_members", "route_to"), "team_members.route_to missing")

	check(daemon.team_db_insert_team(db, daemon.Team_Record{team_id = "team-test", project_id = "proj", kind = "solo", status = "idle", created_unix_ms = 1, updated_unix_ms = 2, chain_id = "chain-test"}), "insert team failed")
	check(daemon.team_db_insert_member(db, daemon.Team_Member_Record{team_id = "team-test", role_key = "user_proxy", role_index = 0, is_user_proxy = true, route_to = "operator@local"}), "insert member failed")

	reopened, reopened_ok := daemon.team_db_init(data_dir)
	check(reopened_ok, "reopen team_db_init failed")
	check(daemon.team_db_user_version(reopened.db_path) == 1, "reopen changed user_version")
	check(daemon.team_db_count_teams(reopened) == 1, "reopen did not preserve team row")
	check(daemon.team_db_count_members(reopened) == 1, "reopen did not preserve member row")

	rerun, rerun_ok := daemon.team_db_init(data_dir)
	check(rerun_ok, "idempotent rerun failed")
	check(daemon.team_db_count_teams(rerun) == 1, "rerun duplicated team rows")
	check(daemon.team_db_count_members(rerun) == 1, "rerun duplicated member rows")
}

file_exists :: proc(path: string) -> bool {
	_, ok := os.stat(path, context.allocator)
	return ok == nil
}

check :: proc(ok: bool, message: string) {
	if ok do return
	fmt.eprintln(message)
	os.exit(1)
}
