package shell_job

// Shell job tracking service (REQ-15). Persists STATUS/metadata for bridge-executed
// shell commands (never output) and, on completion, delivers a TRANSIENT nudge to the
// agent over the same hub->bridge WS path used by task nudges — it never inserts a
// chat/conversation message.

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"
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
	return Shell_Job_Service{
		shell_jobs          = shell_jobs,
		bridge_command_sink = bridge_command_sink,
		agents              = agents,
		clock               = clock,
		ids                 = ids,
	}
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

shell_job_status_valid :: proc(status: string) -> bool {
	return status == "running" || status == "completed" || status == "failed"
}

// report_shell_job upserts the job row for the calling instance and, on a terminal
// status, fires a transient completion nudge. Output is never accepted or stored.
report_shell_job :: proc(s: ^Shell_Job_Service, auth: contracts.Auth_Context, input: Shell_Job_Report_Input) -> (domain.Shell_Job, bool, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return domain.Shell_Job{}, false, err

	exec_id := strings.trim_space(input.exec_id)
	if exec_id == "" do return domain.Shell_Job{}, false, domain.domain_error(.Validation_Failed, "shell job exec_id is required")
	status := strings.trim_space(input.status)
	if !shell_job_status_valid(status) do return domain.Shell_Job{}, false, domain.domain_error(.Validation_Failed, "shell job status must be running, completed, or failed")

	now := ""
	if s.clock != nil do now = platform.clock_now(s.clock)

	job := domain.Shell_Job{
		exec_id           = exec_id,
		owner_user_id     = string(owner),
		agent_instance_id = input.agent_instance_id,
		cmd               = input.cmd,
		status            = status,
		started_at        = input.started_at,
		created_at        = now,
		exit_code         = input.exit_code,
		exit_code_set     = input.exit_code_set,
	}
	if job.started_at == "" do job.started_at = now
	if status == "completed" || status == "failed" do job.finished_at = now

	saved, serr := iface.shell_job_upsert(s.shell_jobs, job)
	if !saved do return domain.Shell_Job{}, false, serr

	if status == "completed" || status == "failed" {
		shell_job_notify_complete(s, input.agent_instance_id, input.bridge_id, job)
	}
	return job, true, domain.Domain_Error{}
}

list_shell_jobs :: proc(s: ^Shell_Job_Service, auth: contracts.Auth_Context, input: Shell_Job_List_Input) -> ([]domain.Shell_Job, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err
	limit := input.limit
	if limit <= 0 do limit = 50
	if limit > 200 do limit = 200
	return iface.shell_job_list_by_instance(s.shell_jobs, string(owner), input.agent_instance_id, input.status, input.cursor, limit)
}

// get_shell_output fetches the output of a completed (or in-progress) shell job
// by sending a get_shell_output WS command to the bridge that holds the .out file.
// The hub never stores output; this round-trips to the bridge on every call.
get_shell_output :: proc(s: ^Shell_Job_Service, auth: contracts.Auth_Context, instance_id, exec_id: string) -> (output: string, truncated: bool, err: domain.Domain_Error) {
	owner, ok, oerr := ownership.owner_from_auth(auth)
	if !ok do return "", false, oerr

	if strings.trim_space(exec_id) == "" do return "", false, domain.domain_error(.Validation_Failed, "exec_id is required")
	if strings.trim_space(instance_id) == "" do return "", false, domain.domain_error(.Validation_Failed, "instance_id is required")

	_, found, ferr := iface.shell_job_get_by_exec_id(s.shell_jobs, string(owner), instance_id, exec_id)
	if ferr.code != .None do return "", false, ferr
	if !found do return "", false, domain.domain_error(.Not_Found, "shell job not found")

	if s.agents == nil do return "", false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	inst, inst_ok, _ := iface.agent_get_instance(s.agents, instance_id)
	if !inst_ok || inst.owner_user_id != owner do return "", false, domain.domain_error(.Not_Found, "agent instance not found")
	bridge_id := inst.bridge_id
	if strings.trim_space(bridge_id) == "" do return "", false, domain.domain_error(.Bridge_Offline, "agent instance has no bridge")

	if s.bridge_command_sink.send_runtime_command_wait == nil do return "", false, domain.domain_error(.Bridge_Offline, "bridge command sink is not connected")

	cmd_id := ""
	if s.ids != nil do cmd_id = platform.generate_id(s.ids, "cmd_")

	body_b := strings.builder_make()
	strings.write_string(&body_b, "{\"type\":\"get_shell_output\",\"command_id\":\"")
	contracts.write_json_string(&body_b, cmd_id)
	strings.write_string(&body_b, "\",\"exec_id\":\"")
	contracts.write_json_string(&body_b, exec_id)
	strings.write_string(&body_b, "\"}")

	reply, reply_ok, reply_err := project.bridge_command_send_runtime_wait(s.bridge_command_sink, project.Runtime_Command{bridge_id = bridge_id, command_id = cmd_id, body_json = strings.to_string(body_b)}, 10000)
	if !reply_ok do return "", false, domain.domain_error(.Bridge_Offline, fmt.tprintf("shell output fetch timed out: %s", reply_err.message))

	if !shell_job_reply_bool(reply, "ok") {
		return "", false, domain.domain_error(.Internal_Error, "bridge returned error for shell output request")
	}
	return shell_job_reply_string(reply, "output"), shell_job_reply_bool(reply, "truncated"), domain.Domain_Error{}
}

shell_job_reply_string :: proc(body, key: string) -> string {
	needle := strings.concatenate({"\"", key, "\":"})
	defer delete(needle)
	idx := strings.index(body, needle)
	if idx < 0 do return ""
	rest := strings.trim_space(body[idx + len(needle):])
	if len(rest) == 0 || rest[0] != '"' do return ""
	b := strings.builder_make()
	escaped := false
	for i := 1; i < len(rest); i += 1 {
		ch := rest[i]
		if escaped {
			switch ch {
			case 'n': strings.write_byte(&b, '\n')
			case 'r': strings.write_byte(&b, '\r')
			case 't': strings.write_byte(&b, '\t')
			case '"': strings.write_byte(&b, '"')
			case '\\': strings.write_byte(&b, '\\')
			case: strings.write_byte(&b, ch)
			}
			escaped = false
			continue
		}
		if ch == '\\' { escaped = true; continue }
		if ch == '"' do return strings.to_string(b)
		strings.write_byte(&b, ch)
	}
	return ""
}

shell_job_reply_bool :: proc(body, key: string) -> bool {
	needle := strings.concatenate({"\"", key, "\":"})
	defer delete(needle)
	idx := strings.index(body, needle)
	if idx < 0 do return false
	rest := strings.trim_space(body[idx + len(needle):])
	return strings.has_prefix(rest, "true")
}

// shell_job_notify_complete sends a transient, non-persistent completion notice to
// the agent. It reuses the existing "notify_task_nudge" WS frame (no bridge protocol
// change): the exec_id rides in the task_id field so the bridge's per-(instance,
// task_id) nudge debounce stays unique per job, and the human-readable text rides in
// human_message, which the bridge injects straight into the agent — nothing is stored
// in any conversation/message table.
shell_job_notify_complete :: proc(s: ^Shell_Job_Service, agent_instance_id, bridge_id: string, job: domain.Shell_Job) {
	if strings.trim_space(bridge_id) == "" || strings.trim_space(agent_instance_id) == "" do return

	cmd_id := ""
	if s.ids != nil do cmd_id = platform.generate_id(s.ids, "cmd_")

	exit_str := "n/a"
	if job.exit_code_set do exit_str = fmt.tprintf("%d", job.exit_code)
	msg := strings.concatenate({"Shell job ", job.exec_id, " finished with status ", job.status, " (exit: ", exit_str, ")"})
	defer delete(msg)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `{"type":"notify_task_nudge","command_id":"`)
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, `","agent_instance_id":"`)
	contracts.write_json_string(&b, agent_instance_id)
	strings.write_string(&b, `","task_id":"`)
	contracts.write_json_string(&b, job.exec_id)
	strings.write_string(&b, `","chain_id":"","nudge_id":"","target_role":"worker","action":"shell_job","task_status":"`)
	contracts.write_json_string(&b, job.status)
	strings.write_string(&b, `","body":"`)
	contracts.write_json_string(&b, msg)
	strings.write_string(&b, `","human_message":"`)
	contracts.write_json_string(&b, msg)
	strings.write_string(&b, `","created_at":"`)
	contracts.write_json_string(&b, job.finished_at)
	strings.write_string(&b, `"}`)

	command := project.Runtime_Command{bridge_id = bridge_id, command_id = cmd_id, body_json = strings.to_string(b)}
	if s.bridge_command_sink.send_runtime_command_wait != nil {
		_, _, _ = project.bridge_command_send_runtime_wait(s.bridge_command_sink, command, 1000)
	} else if s.bridge_command_sink.send_runtime_command != nil {
		_, _ = project.bridge_command_send_runtime(s.bridge_command_sink, command)
	}
}
