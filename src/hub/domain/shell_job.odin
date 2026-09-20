package domain

// RETIRED: replaced by Shell_Session in T1/T5. Shell_Job is kept as a stub so
// existing handlers that reference domain.Shell_Job continue to compile until T5
// completes the full migration.
Shell_Job :: struct {
	exec_id:           string,
	owner_user_id:     string,
	agent_instance_id: string,
	cmd:               string,
	status:            string,
	started_at:        string,
	finished_at:       string,
	created_at:        string,
	exit_code:         int,
	exit_code_set:     bool,
}
