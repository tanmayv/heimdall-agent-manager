package domain

// Shell_Job is the hub-side record for a bridge-executed shell command (REQ-15).
// The hub stores STATUS/metadata only — the command output is written and kept on
// the bridge host and is never sent to or stored by the hub. exit_code_set
// distinguishes "no exit code yet" (job still running) from an actual exit code of
// 0, since exit_code is a plain int.
Shell_Job :: struct {
	exec_id:           string,
	owner_user_id:     string,
	agent_instance_id: string,
	cmd:               string,
	status:            string, // "running" | "completed" | "failed"
	started_at:        string,
	finished_at:       string,
	created_at:        string,
	exit_code:         int,
	exit_code_set:     bool,
}
