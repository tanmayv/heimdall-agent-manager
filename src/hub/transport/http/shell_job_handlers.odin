package http

// User-facing (session-authed) shell-job listing for the desktop UI (REQ-16). The
// agent-actions/shell-cmd/* endpoints are agent-token authed; the UI authenticates
// as the user, so it needs this owner-scoped REST view. Reuses the same
// shell_job_service.list_shell_jobs (owner-scoped by the authed user) — a user only
// ever sees jobs they own for the given instance. Output is never stored or returned.

import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import auth_service "odin_test:hub/service/auth"
import shell_job_service "odin_test:hub/service/shell_job"

Shell_Job_Handlers :: struct {
	auth:       ^auth_service.Auth_Service,
	shell_jobs: ^shell_job_service.Shell_Job_Service,
}

// GET /api/v1/agent-instances/<instance-id>/shell-jobs?status=&limit=
list_instance_shell_jobs_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Job_Handlers)(ctx)
	auth, ok, resp := require_auth(h.auth, req)
	if !ok do return resp

	instance_id := path_part(req.path, 4)
	if strings.trim_space(instance_id) == "" {
		return respond_error(domain.domain_error(.Validation_Failed, "agent-instance id is required"), req.request_id)
	}

	limit := query_int(req.query, "limit", 50)
	if limit <= 0 do limit = 50
	if limit > 200 do limit = 200

	input := shell_job_service.Shell_Job_List_Input{
		agent_instance_id = instance_id,
		status            = query_value(req.query, "status"),
		cursor            = query_value(req.query, "cursor"),
		limit             = limit,
	}
	jobs, err := shell_job_service.list_shell_jobs(h.shell_jobs, auth, input)
	if err.code != .None do return respond_error(err, req.request_id)
	defer delete(jobs)

	has_more := len(jobs) >= limit
	next_cursor := ""
	if has_more && len(jobs) > 0 do next_cursor = jobs[len(jobs)-1].exec_id

	b := strings.builder_make()
	strings.write_string(&b, "{\"data\":[")
	for job, i in jobs {
		if i > 0 do strings.write_byte(&b, ',')
		write_shell_job_json(&b, job)
	}
	strings.write_string(&b, "],\"next_cursor\":\"")
	contracts.write_json_string(&b, next_cursor)
	strings.write_string(&b, "\",\"has_more\":")
	strings.write_string(&b, "true" if has_more else "false")
	strings.write_byte(&b, '}')
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

// GET /api/v1/agent-instances/<instance-id>/shell-jobs/<exec-id>/output
get_instance_shell_job_output_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Job_Handlers)(ctx)
	auth, ok, resp := require_auth(h.auth, req)
	if !ok do return resp

	instance_id := path_part(req.path, 4)
	exec_id := path_part(req.path, 6)
	if strings.trim_space(instance_id) == "" {
		return respond_error(domain.domain_error(.Validation_Failed, "agent-instance id is required"), req.request_id)
	}
	if strings.trim_space(exec_id) == "" {
		return respond_error(domain.domain_error(.Validation_Failed, "exec_id is required"), req.request_id)
	}

	output, truncated, err := shell_job_service.get_shell_output(h.shell_jobs, auth, instance_id, exec_id)
	if err.code != .None do return respond_error(err, req.request_id)

	b := strings.builder_make()
	strings.write_string(&b, "{\"output\":\"")
	contracts.write_json_string(&b, output)
	strings.write_string(&b, "\",\"truncated\":")
	strings.write_string(&b, "true" if truncated else "false")
	strings.write_string(&b, ",\"exec_id\":\"")
	contracts.write_json_string(&b, exec_id)
	strings.write_byte(&b, '"')
	strings.write_byte(&b, '}')
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}
