package domain

// Shell_Session is the hub-side record for a bridge-managed shell session
// (PTY host, interactive terminal, or transient command). Replaces Shell_Job
// as the unified session concept per REQ-SH-CONTRACT §1.
Shell_Session_ID :: distinct string

Shell_Session_Kind :: enum {
	Agent,
	Interactive,
	Server,
	Command,
}

shell_session_kind_string := [Shell_Session_Kind]string{
	.Agent       = "agent",
	.Interactive = "interactive",
	.Server      = "server",
	.Command     = "command",
}

Shell_Session_Status_Starting :: "starting"
Shell_Session_Status_Running  :: "running"
Shell_Session_Status_Exited   :: "exited"
Shell_Session_Status_Killed   :: "killed"
Shell_Session_Status_Failed   :: "failed"

Shell_Session :: struct {
	session_id:          string,
	owner_user_id:       string,
	bridge_id:           string,
	project_id:          string,
	chain_id:            string,
	agent_instance_id:   string,
	kind:                string, // "agent" | "interactive" | "server" | "command"
	label:               string,
	cmd:                 string,
	cwd:                 string,
	status:              string, // "starting" | "running" | "exited" | "killed" | "failed"
	exit_code:           int,
	exit_code_set:       bool,
	pid:                 int,
	server_port:         int,
	preview_enabled:     bool,
	started_at:          string,
	finished_at:         string,
	created_at:          string,
	last_activity_at:    string,
}

shell_session_is_terminal :: proc(s: Shell_Session) -> bool {
	return s.status == Shell_Session_Status_Exited ||
	       s.status == Shell_Session_Status_Killed ||
	       s.status == Shell_Session_Status_Failed
}

shell_session_destroy :: proc(s: Shell_Session) {
	delete(s.session_id)
	delete(s.owner_user_id)
	delete(s.bridge_id)
	delete(s.project_id)
	delete(s.chain_id)
	delete(s.agent_instance_id)
	delete(s.kind)
	delete(s.label)
	delete(s.cmd)
	delete(s.cwd)
	delete(s.status)
	delete(s.started_at)
	delete(s.finished_at)
	delete(s.created_at)
	delete(s.last_activity_at)
}

shell_sessions_destroy :: proc(sessions: [dynamic]Shell_Session) {
	for s in sessions do shell_session_destroy(s)
	delete(sessions)
}
