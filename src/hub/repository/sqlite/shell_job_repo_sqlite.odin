package sqlite

import "core:strconv"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Shell_Job_Repo_SQLite :: struct {
	conn: ^Conn,
}

new_shell_job_repository :: proc(impl: ^Shell_Job_Repo_SQLite, conn: ^Conn) -> iface.Shell_Job_Repository {
	impl.conn = conn
	return iface.Shell_Job_Repository{
		ctx              = rawptr(impl),
		upsert           = shell_job_upsert_sqlite,
		list_by_instance = shell_job_list_by_instance_sqlite,
		get_by_exec_id   = shell_job_get_by_exec_id_sqlite,
	}
}

shell_job_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Shell_Job {
	job: domain.Shell_Job
	job.exec_id = column_text(stmt, 0)
	job.owner_user_id = column_text(stmt, 1)
	job.agent_instance_id = column_text(stmt, 2)
	job.cmd = column_text(stmt, 3)
	job.status = column_text(stmt, 4)
	// exit_code is stored as text: "" means "no exit code yet" (still running); any
	// value (incl. negative sentinels) means the job has an exit code.
	ec := column_text(stmt, 5)
	if ec != "" {
		if v, ok := strconv.parse_int(ec); ok {
			job.exit_code = int(v)
			job.exit_code_set = true
		}
	}
	job.started_at = column_text(stmt, 6)
	job.finished_at = column_text(stmt, 7)
	job.created_at = column_text(stmt, 8)
	return job
}

shell_job_upsert_sqlite :: proc(ctx: rawptr, job: domain.Shell_Job) -> (bool, domain.Domain_Error) {
	impl := (^Shell_Job_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	// Upsert keyed on exec_id. On conflict we keep the original created_at/owner and
	// only advance mutable fields; empty incoming values do not clobber existing ones
	// (so a completion report keeps the cmd/started_at from the first report).
	query := `INSERT INTO shell_jobs (
		exec_id, owner_user_id, agent_instance_id, cmd, status, exit_code, started_at, finished_at, created_at
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
	ON CONFLICT(exec_id) DO UPDATE SET
		status = excluded.status,
		exit_code = CASE WHEN excluded.exit_code != '' THEN excluded.exit_code ELSE shell_jobs.exit_code END,
		finished_at = CASE WHEN excluded.finished_at != '' THEN excluded.finished_at ELSE shell_jobs.finished_at END,
		cmd = CASE WHEN excluded.cmd != '' THEN excluded.cmd ELSE shell_jobs.cmd END,
		started_at = CASE WHEN excluded.started_at != '' THEN excluded.started_at ELSE shell_jobs.started_at END;`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare shell job upsert")
	}
	defer sqlite3_finalize(stmt)

	exit_code_s := ""
	if job.exit_code_set do exit_code_s = int_s(job.exit_code)

	bind_text(stmt, 1, job.exec_id)
	bind_text(stmt, 2, job.owner_user_id)
	bind_text(stmt, 3, job.agent_instance_id)
	bind_text(stmt, 4, job.cmd)
	bind_text(stmt, 5, job.status)
	bind_text(stmt, 6, exit_code_s)
	bind_text(stmt, 7, job.started_at)
	bind_text(stmt, 8, job.finished_at)
	bind_text(stmt, 9, job.created_at)

	if sqlite3_step(stmt) != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "failed to upsert shell job")
	}
	return true, domain.Domain_Error{}
}

shell_job_list_by_instance_sqlite :: proc(ctx: rawptr, owner_user_id, agent_instance_id, status_filter, cursor: string, limit: int) -> ([]domain.Shell_Job, domain.Domain_Error) {
	impl := (^Shell_Job_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return nil, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	lim := limit
	if lim <= 0 do lim = 50

	stmt: sqlite3_stmt = nil
	query := ""
	has_status := status_filter != ""
	has_cursor := cursor != ""
	switch {
	case has_status && has_cursor:
		query = "SELECT exec_id, owner_user_id, agent_instance_id, cmd, status, exit_code, started_at, finished_at, created_at FROM shell_jobs WHERE owner_user_id = ? AND agent_instance_id = ? AND status = ? AND exec_id < ? ORDER BY started_at DESC, exec_id DESC LIMIT ?;"
	case has_status:
		query = "SELECT exec_id, owner_user_id, agent_instance_id, cmd, status, exit_code, started_at, finished_at, created_at FROM shell_jobs WHERE owner_user_id = ? AND agent_instance_id = ? AND status = ? ORDER BY started_at DESC, exec_id DESC LIMIT ?;"
	case has_cursor:
		query = "SELECT exec_id, owner_user_id, agent_instance_id, cmd, status, exit_code, started_at, finished_at, created_at FROM shell_jobs WHERE owner_user_id = ? AND agent_instance_id = ? AND exec_id < ? ORDER BY started_at DESC, exec_id DESC LIMIT ?;"
	case:
		query = "SELECT exec_id, owner_user_id, agent_instance_id, cmd, status, exit_code, started_at, finished_at, created_at FROM shell_jobs WHERE owner_user_id = ? AND agent_instance_id = ? ORDER BY started_at DESC, exec_id DESC LIMIT ?;"
	}
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare shell job list")
	}
	defer sqlite3_finalize(stmt)

	bind_text(stmt, 1, owner_user_id)
	bind_text(stmt, 2, agent_instance_id)
	p := 3
	if has_status { bind_text(stmt, p, status_filter); p += 1 }
	if has_cursor { bind_text(stmt, p, cursor); p += 1 }
	bind_text(stmt, p, int_s(lim))

	items := make([dynamic]domain.Shell_Job)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&items, shell_job_from_stmt(stmt))
	}
	return items[:], domain.Domain_Error{}
}

shell_job_get_by_exec_id_sqlite :: proc(ctx: rawptr, owner_user_id, agent_instance_id, exec_id: string) -> (domain.Shell_Job, bool, domain.Domain_Error) {
	impl := (^Shell_Job_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return domain.Shell_Job{}, false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "SELECT exec_id, owner_user_id, agent_instance_id, cmd, status, exit_code, started_at, finished_at, created_at FROM shell_jobs WHERE exec_id = ? AND owner_user_id = ? AND agent_instance_id = ? LIMIT 1;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return domain.Shell_Job{}, false, domain.domain_error(.Internal_Error, "failed to prepare shell job get")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, exec_id)
	bind_text(stmt, 2, owner_user_id)
	bind_text(stmt, 3, agent_instance_id)
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Shell_Job{}, false, domain.Domain_Error{}
	return shell_job_from_stmt(stmt), true, domain.Domain_Error{}
}
