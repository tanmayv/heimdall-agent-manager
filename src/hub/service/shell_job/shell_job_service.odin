package shell_job

// RETIRED: replaced by shell_session in T1/T5. Stubs kept so agent_action_handlers
// continues to compile until T5 completes the migration.

import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import contracts "odin_test:contracts"
import project "odin_test:hub/service/project"

Shell_Job_Service :: struct {
	shell_jobs:          ^iface.Shell_Job_Repository,
	bridge_command_sink: project.Bridge_Command_Sink,
	agents:              ^iface.Agent_Repository,
	clock:               ^platform.Clock,
	ids:                 ^platform.ID_Generator,
}

new_shell_job_service :: proc(
	shell_jobs:          ^iface.Shell_Job_Repository,
	bridge_command_sink: project.Bridge_Command_Sink,
	clock:               ^platform.Clock = nil,
	ids:                 ^platform.ID_Generator = nil,
	agents:              ^iface.Agent_Repository = nil,
) -> Shell_Job_Service {
	return Shell_Job_Service{}
}

Shell_Job_Report_Input :: struct {
	exec_id:           string,
	status:            string,
	cmd:               string,
	started_at:        string,
	exit_code:         int,
	exit_code_set:     bool,
	agent_instance_id: string,
	bridge_id:         string,
}

Shell_Job_List_Input :: struct {
	agent_instance_id: string,
	status:            string,
	cursor:            string,
	limit:             int,
}

report_shell_job :: proc(s: ^Shell_Job_Service, auth: contracts.Auth_Context, input: Shell_Job_Report_Input) -> (domain.Shell_Job, bool, domain.Domain_Error) {
	return domain.Shell_Job{}, false, domain.domain_error(.Internal_Error, "shell_job retired — use shell_session")
}

list_shell_jobs :: proc(s: ^Shell_Job_Service, auth: contracts.Auth_Context, input: Shell_Job_List_Input) -> ([]domain.Shell_Job, domain.Domain_Error) {
	return nil, domain.Domain_Error{}
}

get_shell_output :: proc(s: ^Shell_Job_Service, auth: contracts.Auth_Context, instance_id, exec_id: string) -> (output: string, truncated: bool, err: domain.Domain_Error) {
	return "", false, domain.domain_error(.Internal_Error, "shell_job retired — use shell_session")
}
