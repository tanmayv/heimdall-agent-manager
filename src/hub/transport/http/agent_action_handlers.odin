package http

import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import agent_service "odin_test:hub/service/agent"
import content_service "odin_test:hub/service/content"
import taskchain_service "odin_test:hub/service/taskchain"

Agent_Action_Handlers :: struct {
	agents: ^agent_service.Agent_Service,
	content: ^content_service.Content_Service,
	taskchains: ^taskchain_service.Taskchain_Service,
}

agent_action_chat_send_to_user_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	msg, saved, err := content_service.send_agent_message(h.content, auth, inst.agent_instance_id, content_service.Message_Input{body = json_string(params, "body"), artifact_ids_json = json_array_optional(params, "artifact_ids")})
	if !saved do return respond_error(err, req.request_id)
	b := strings.builder_make()
	write_message_json(&b, msg, h.content)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

agent_action_task_comment_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, _, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	comment, saved, err := taskchain_service.comment_task(h.taskchains, auth, taskchain_service.Task_Comment_Input{task_id = domain.Task_ID(json_string(params, "task_id")), body = json_string(params, "body")})
	if !saved do return respond_error(err, req.request_id)
	b := strings.builder_make()
	write_task_comment_json(&b, comment)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

agent_action_task_status_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, _, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	status, status_ok := task_status_from_http(json_string(params, "status"))
	if !status_ok do return respond_error(domain.domain_error(.Validation_Failed, "task status is invalid"), req.request_id)
	task, changed, err := taskchain_service.change_task_status(h.taskchains, auth, domain.Task_ID(json_string(params, "task_id")), status)
	if !changed do return respond_error(err, req.request_id)
	b := strings.builder_make()
	write_task_json(&b, task)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

agent_action_task_nudge_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, _, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	message := json_string(params, "message")
	if message == "" do message = json_string(params, "body")
	nudge, sent, err := taskchain_service.manual_nudge(h.taskchains, auth, domain.Task_ID(json_string(params, "task_id")), message)
	if !sent do return respond_error(err, req.request_id)
	b := strings.builder_make()
	strings.write_string(&b, "{\"task_id\":\""); write_handler_json_string(&b, string(nudge.task_id)); strings.write_string(&b, "\",\"target\":\""); write_handler_json_string(&b, nudge_target_string(nudge.target)); strings.write_string(&b, "\"}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 202)
}

agent_action_task_vote_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, _, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	result := json_string(params, "result")
	status: domain.Task_Status = .Validated_Good
	if result == "not_good" || result == "ngtm" do status = .Validated_Not_Good
	task, changed, err := taskchain_service.change_task_status(h.taskchains, auth, domain.Task_ID(json_string(params, "task_id")), status)
	if !changed do return respond_error(err, req.request_id)
	b := strings.builder_make()
	write_task_json(&b, task)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}


agent_action_artifact_create_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	content := json_string(params, "inline_bytes")
	if content == "" do content = json_string(params, "content")
	artifact, saved, err := content_service.create_artifact(h.content, auth, content_service.Artifact_Input{kind = json_string(params, "kind"), name = json_string(params, "name"), description = json_string(params, "description"), content_type = json_string(params, "content_type"), content = content, filename = json_string(params, "filename"), agent_id = inst.agent_id, agent_instance_id = inst.agent_instance_id, chain_id = inst.chain_id, project_id = inst.project_id})
	if !saved do return respond_error(err, req.request_id)
	b := strings.builder_make()
	write_artifact_json(&b, artifact, false)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

agent_action_memory_propose_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	mem, saved, err := content_service.create_memory(h.content, auth, content_service.Memory_Input{agent_id = inst.agent_id, type = json_string(params, "type"), title = json_string(params, "title"), body = json_string(params, "body"), evidence = json_string(params, "evidence"), status = "pending"})
	if !saved do return respond_error(err, req.request_id)
	b := strings.builder_make()
	write_memory_json(&b, mem, false)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

write_task_comment_json :: proc(b: ^strings.Builder, c: domain.Task_Comment) {
	strings.write_string(b, "{\"comment_id\":\""); write_handler_json_string(b, c.comment_id)
	strings.write_string(b, "\",\"task_id\":\""); write_handler_json_string(b, string(c.task_id))
	strings.write_string(b, "\",\"chain_id\":\""); write_handler_json_string(b, string(c.chain_id))
	strings.write_string(b, "\",\"author_agent_instance_id\":\""); write_handler_json_string(b, c.author_agent_instance_id)
	strings.write_string(b, "\",\"body\":\""); write_handler_json_string(b, c.body)
	strings.write_string(b, "\",\"created_at\":\""); write_handler_json_string(b, c.created_at)
	strings.write_string(b, "\"}")
}

agent_action_start_success_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, _, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	inst, saved, err := agent_service.mark_instance_start_success(h.agents, auth)
	if !saved do return respond_error(err, req.request_id)
	b := strings.builder_make()
	write_agent_instance_json(&b, inst)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

agent_action_accepted_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	b := strings.builder_make()
	_ = auth
	strings.write_string(&b, "{\"accepted\":true,\"agent_instance_id\":\""); write_handler_json_string(&b, inst.agent_instance_id); strings.write_string(&b, "\",\"auth_kind\":\"instance_token\"}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 202)
}

require_instance_action_auth :: proc(h: ^Agent_Action_Handlers, req: Request) -> (contracts.Auth_Context, domain.Agent_Instance, bool, Response) {
	if rejected, resp := reject_query_or_body_token(req); rejected do return contracts.Auth_Context{}, domain.Agent_Instance{}, false, resp
	token, has_token := bearer_token(req)
	if !has_token do return contracts.Auth_Context{}, domain.Agent_Instance{}, false, respond_error(domain.domain_error(.Unauthenticated, "bearer token is required"), req.request_id)
	auth, inst, verified, err := agent_service.verify_instance_token(h.agents, token)
	if !verified do return contracts.Auth_Context{}, domain.Agent_Instance{}, false, respond_error(err, req.request_id)
	body_instance := json_string(req.body, "agent_instance_id")
	if body_instance != inst.agent_instance_id do return contracts.Auth_Context{}, domain.Agent_Instance{}, false, respond_error(domain.domain_error(.Forbidden, "agent instance token cannot act for a different instance"), req.request_id)
	return auth, inst, true, Response{}
}
