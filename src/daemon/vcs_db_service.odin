package main

import "core:fmt"
import "core:os"
import "core:strings"
import vcs "odin_test:lib/vcs"

Vcs_Workspace_Record :: struct {
	workspace_id:     string,
	chain_id:         string,
	project_id:       string,
	vcs_kind:         string,
	path:             string,
	branch_or_change: string,
	base_ref:         string,
	status:           string,
	keep_on_archive:  bool,
	created_unix_ms:  i64,
	updated_unix_ms:  i64,
}

vcs_db_path: string

vcs_db_init :: proc(data_dir: string) -> bool {
	dir := fmt.tprintf("%s/vcs", data_dir)
	_ = os.make_directory_all(dir)
	vcs_db_path = strings.clone(fmt.tprintf("%s/vcs.db", dir))
	return vcs_db_exec(`CREATE TABLE IF NOT EXISTS vcs_workspaces (
		workspace_id TEXT PRIMARY KEY,
		chain_id TEXT NOT NULL,
		project_id TEXT NOT NULL,
		vcs_kind TEXT NOT NULL,
		path TEXT NOT NULL,
		branch_or_change TEXT NOT NULL,
		base_ref TEXT NOT NULL,
		status TEXT NOT NULL,
		keep_on_archive INTEGER NOT NULL DEFAULT 0,
		created_unix_ms INTEGER NOT NULL,
		updated_unix_ms INTEGER NOT NULL
	);
	CREATE INDEX IF NOT EXISTS idx_vcs_workspaces_chain ON vcs_workspaces(chain_id);
	CREATE INDEX IF NOT EXISTS idx_vcs_workspaces_project ON vcs_workspaces(project_id);`)
}

vcs_db_exec :: proc(sql: string) -> bool {
	_, ok := vcs_db_query(sql)
	return ok
}

vcs_db_query :: proc(sql: string) -> (string, bool) {
	cmd := []string{"sqlite3", vcs_db_path, sql}
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
	if err != nil || !state.success do return "", false
	return string(stdout), true
}

vcs_db_insert_workspace :: proc(rec: Vcs_Workspace_Record) -> bool {
	q := fmt.tprintf(`INSERT OR REPLACE INTO vcs_workspaces (workspace_id, chain_id, project_id, vcs_kind, path, branch_or_change, base_ref, status, keep_on_archive, created_unix_ms, updated_unix_ms) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%d,%d,%d);`, sql_text(rec.workspace_id), sql_text(rec.chain_id), sql_text(rec.project_id), sql_text(rec.vcs_kind), sql_text(rec.path), sql_text(rec.branch_or_change), sql_text(rec.base_ref), sql_text(rec.status), 1 if rec.keep_on_archive else 0, rec.created_unix_ms, rec.updated_unix_ms)
	return vcs_db_exec(q)
}

vcs_db_workspace_for_chain :: proc(chain_id: string) -> (Vcs_Workspace_Record, bool) {
	out, ok := vcs_db_query(fmt.tprintf("SELECT workspace_id,chain_id,project_id,vcs_kind,path,branch_or_change,base_ref,status,keep_on_archive,created_unix_ms,updated_unix_ms FROM vcs_workspaces WHERE chain_id=%s LIMIT 1;", sql_text(chain_id)))
	if !ok || strings.trim_space(out) == "" do return Vcs_Workspace_Record{}, false
	parts := strings.split(strings.trim_space(out), "|")
	if len(parts) < 11 do return Vcs_Workspace_Record{}, false
	return Vcs_Workspace_Record{workspace_id=strings.clone(parts[0]), chain_id=strings.clone(parts[1]), project_id=strings.clone(parts[2]), vcs_kind=strings.clone(parts[3]), path=strings.clone(parts[4]), branch_or_change=strings.clone(parts[5]), base_ref=strings.clone(parts[6]), status=strings.clone(parts[7]), keep_on_archive=parts[8] == "1", created_unix_ms=i64(extract_int(parts[9])), updated_unix_ms=i64(extract_int(parts[10]))}, true
}

vcs_db_merge_pending_workspaces :: proc() -> []Vcs_Workspace_Record {
	out, ok := vcs_db_query("SELECT workspace_id,chain_id,project_id,vcs_kind,path,branch_or_change,base_ref,status,keep_on_archive,created_unix_ms,updated_unix_ms FROM vcs_workspaces WHERE status='merge_pending' ORDER BY updated_unix_ms;")
	if !ok do return nil
	recs := make([dynamic]Vcs_Workspace_Record)
	for line in strings.split(strings.trim_space(out), "\n") {
		if strings.trim_space(line) == "" do continue
		parts := strings.split(line, "|")
		if len(parts) < 11 do continue
		append(&recs, Vcs_Workspace_Record{workspace_id=strings.clone(parts[0]), chain_id=strings.clone(parts[1]), project_id=strings.clone(parts[2]), vcs_kind=strings.clone(parts[3]), path=strings.clone(parts[4]), branch_or_change=strings.clone(parts[5]), base_ref=strings.clone(parts[6]), status=strings.clone(parts[7]), keep_on_archive=parts[8] == "1", created_unix_ms=i64(extract_int(parts[9])), updated_unix_ms=i64(extract_int(parts[10]))})
	}
	return recs[:]
}

vcs_db_update_status :: proc(chain_id, status: string) -> bool {
	return vcs_db_exec(fmt.tprintf("UPDATE vcs_workspaces SET status=%s, updated_unix_ms=%d WHERE chain_id=%s;", sql_text(status), router_now_unix_ms(), sql_text(chain_id)))
}

vcs_db_delete_workspace :: proc(chain_id: string) -> bool {
	return vcs_db_exec(fmt.tprintf("DELETE FROM vcs_workspaces WHERE chain_id=%s;", sql_text(chain_id)))
}

vcs_handle_from_record :: proc(rec: Vcs_Workspace_Record) -> vcs.Vcs_Workspace_Handle {
	kind := vcs.Vcs_Kind.Git
	if rec.vcs_kind == "jj" do kind = .Jj
	return vcs.Vcs_Workspace_Handle{path=rec.path, branch_or_change=rec.branch_or_change, base_ref=rec.base_ref, kind=kind}
}

vcs_write_workspace_json :: proc(b: ^strings.Builder, rec: Vcs_Workspace_Record, status: vcs.Vcs_Status) {
	strings.write_string(b, `{"workspace_id":"`); json_write_string(b, rec.workspace_id)
	strings.write_string(b, `","chain_id":"`); json_write_string(b, rec.chain_id)
	strings.write_string(b, `","project_id":"`); json_write_string(b, rec.project_id)
	strings.write_string(b, `","vcs_kind":"`); json_write_string(b, rec.vcs_kind)
	strings.write_string(b, `","path":"`); json_write_string(b, rec.path)
	strings.write_string(b, `","branch_or_change":"`); json_write_string(b, rec.branch_or_change)
	strings.write_string(b, `","base_ref":"`); json_write_string(b, rec.base_ref)
	strings.write_string(b, `","status":"`); json_write_string(b, rec.status)
	strings.write_string(b, `","summary_line":"`); json_write_string(b, status.summary_line)
	strings.write_string(b, `","ahead_commits":`); strings.write_string(b, fmt.tprintf("%d", status.ahead_commits))
	strings.write_string(b, `,"behind_commits":`); strings.write_string(b, fmt.tprintf("%d", status.behind_commits))
	strings.write_string(b, `,"is_conflicted":`); strings.write_string(b, "true" if status.is_conflicted else "false")
	strings.write_string(b, `,"files":[`)
	for i in 0..<len(status.files) { if i > 0 do strings.write_string(b, `,`); f := status.files[i]; strings.write_string(b, `{"path":"`); json_write_string(b, f.path); strings.write_string(b, `","status":"`); json_write_string(b, f.status); strings.write_string(b, `","adds":`); strings.write_string(b, fmt.tprintf("%d", f.adds)); strings.write_string(b, `,"dels":`); strings.write_string(b, fmt.tprintf("%d", f.dels)); strings.write_string(b, `}`) }
	strings.write_string(b, `]}`)
}

extract_int :: proc(s: string) -> int {
	out := 0
	for r in s { if r < '0' || r > '9' do break; out = out*10 + int(r-'0') }
	return out
}
