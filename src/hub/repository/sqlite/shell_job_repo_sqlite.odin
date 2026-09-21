package sqlite

// RETIRED: replaced by shell_session_repo_sqlite.odin in T1/T5.
// Stubs kept so wiring.odin (which still references new_shell_job_repository
// transitionally) and the iface.Shell_Job_Repository type continue to compile.

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Shell_Job_Repo_SQLite :: struct {
	conn: ^Conn,
}

new_shell_job_repository :: proc(impl: ^Shell_Job_Repo_SQLite, conn: ^Conn) -> iface.Shell_Job_Repository {
	return iface.Shell_Job_Repository{}
}
