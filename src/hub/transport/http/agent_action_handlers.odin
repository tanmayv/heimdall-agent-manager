package http

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import agent_service "odin_test:hub/service/agent"
import bridge_service "odin_test:hub/service/bridge"
import content_service "odin_test:hub/service/content"
import taskchain_service "odin_test:hub/service/taskchain"

Agent_Action_Handlers :: struct {
	agents: ^agent_service.Agent_Service,
	bridges: ^bridge_service.Bridge_Service,
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

agent_action_chat_fetch_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	limit := json_int(params, "limit", 50)
	cursor := json_string(params, "cursor")
	conv, conv_ok, conv_err := content_service.get_conversation_by_instance(h.content, auth, inst.agent_instance_id)
	if !conv_ok do return respond_error(conv_err, req.request_id)
	rows, err := content_service.list_messages(h.content, auth, conv.conversation_id, limit, cursor)
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make()
	strings.write_string(&b, "{\"conversation\":")
	write_chat_json(&b, conv)
	strings.write_string(&b, ",\"messages\":[")
	next := ""
	for msg, i in rows { if i > 0 do strings.write_byte(&b, ','); write_message_json(&b, msg, h.content); next = msg.created_at }
	strings.write_string(&b, "],\"next_cursor\":\""); write_handler_json_string(&b, next); strings.write_string(&b, "\",\"has_more\":"); strings.write_string(&b, "true" if len(rows) >= limit else "false"); strings.write_byte(&b, '}')
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

agent_action_chat_read_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	conv, conv_ok, conv_err := content_service.get_conversation_by_instance(h.content, auth, inst.agent_instance_id)
	if !conv_ok do return respond_error(conv_err, req.request_id)
	// Direction-safe v1 acknowledgement: Chat_Conversation.unread_count is the
	// human user's unread agent->user badge, so an agent-side read must not call
	// content_service.mark_read() or mutate that counter.
	b := strings.builder_make()
	strings.write_string(&b, "{\"accepted\":true,\"conversation\":")
	write_chat_json(&b, conv)
	strings.write_byte(&b, '}')
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

agent_action_context_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	conv, conv_ok, _ := content_service.get_conversation_by_instance(h.content, auth, inst.agent_instance_id)
	b := strings.builder_make()
	strings.write_string(&b, "{\"agent_instance_id\":\""); write_handler_json_string(&b, inst.agent_instance_id)
	strings.write_string(&b, "\",\"agent_id\":\""); write_handler_json_string(&b, inst.agent_id)
	strings.write_string(&b, "\",\"bridge_id\":\""); write_handler_json_string(&b, inst.bridge_id)
	strings.write_string(&b, "\",\"chain_id\":\""); write_handler_json_string(&b, inst.chain_id)
	strings.write_string(&b, "\",\"conversation_id\":\""); if conv_ok { write_handler_json_string(&b, conv.conversation_id) } else { write_handler_json_string(&b, inst.conversation_id) }
	strings.write_string(&b, "\",\"project_id\":\""); write_handler_json_string(&b, string(inst.project_id))
	strings.write_string(&b, "\",\"runtime\":{\"provider\":\""); write_handler_json_string(&b, inst.provider)
	strings.write_string(&b, "\",\"tier\":\""); write_handler_json_string(&b, inst.tier)
	strings.write_string(&b, "\",\"runtime_status\":\""); write_handler_json_string(&b, inst.runtime_status)
	strings.write_string(&b, "\",\"startup_status\":\""); write_handler_json_string(&b, inst.startup_status)
	strings.write_string(&b, "\"},\"unread_summary\":{\"conversation_unread_count\":")
	if conv_ok { strings.write_string(&b, fmt.tprintf("%d", conv.unread_count)) } else { strings.write_string(&b, "0") }
	strings.write_string(&b, "},\"current_task\":")
	write_agent_current_task_json(&b, h, auth, inst)
	strings.write_byte(&b, '}')
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
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
	bridge_token, has_token := bearer_token(req)
	if !has_token do return contracts.Auth_Context{}, domain.Agent_Instance{}, false, respond_error(domain.domain_error(.Unauthenticated, "bridge bearer token is required"), req.request_id)
	bridge_auth, bridge_ok, bridge_err := bridge_service.verify_bridge_token(h.bridges, bridge_token)
	if !bridge_ok do return contracts.Auth_Context{}, domain.Agent_Instance{}, false, respond_error(bridge_err, req.request_id)
	body_instance := json_string(req.body, "agent_instance_id")
	if body_instance == "" do return contracts.Auth_Context{}, domain.Agent_Instance{}, false, respond_error(domain.domain_error(.Validation_Failed, "agent_instance_id is required"), req.request_id)
	inst, inst_ok, inst_err := agent_service.get_instance(h.agents, bridge_auth, body_instance)
	if !inst_ok do return contracts.Auth_Context{}, domain.Agent_Instance{}, false, respond_error(inst_err, req.request_id)
	if inst.bridge_id != bridge_auth.bridge_id do return contracts.Auth_Context{}, domain.Agent_Instance{}, false, respond_error(domain.domain_error(.Forbidden, "bridge cannot act for an instance it does not own"), req.request_id)
	relay_token := header_value(req.headers, "X-Heimdall-Instance-Token")
	expected_relay_token := strings.concatenate({"hit_", inst.agent_instance_id})
	if relay_token != expected_relay_token do return contracts.Auth_Context{}, domain.Agent_Instance{}, false, respond_error(domain.domain_error(.Forbidden, "bridge instance assertion token is invalid"), req.request_id)
	auth := contracts.Auth_Context{kind = .Instance_Token, user_id = string(inst.owner_user_id), agent_instance_id = inst.agent_instance_id, bridge_id = inst.bridge_id}
	return auth, inst, true, Response{}
}

write_agent_current_task_json :: proc(b: ^strings.Builder, h: ^Agent_Action_Handlers, auth: contracts.Auth_Context, inst: domain.Agent_Instance) {
	if h.taskchains == nil || inst.chain_id == "" { strings.write_string(b, "null"); return }
	tasks, err := taskchain_service.list_tasks(h.taskchains, auth, domain.Task_Chain_ID(inst.chain_id))
	if err.code != .None { strings.write_string(b, "null"); return }
	for task in tasks {
		if strings.contains(task.assignee_ref_json, inst.agent_instance_id) && (task.status == .In_Progress || task.status == .Assigned) {
			write_task_json(b, task)
			return
		}
	}
	strings.write_string(b, "null")
}
