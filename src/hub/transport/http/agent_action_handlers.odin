package http

import "core:fmt"
import "core:strings"
import internal_b64 "core:encoding/base64"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import auth_service "odin_test:hub/service/auth"
import agent_service "odin_test:hub/service/agent"
import bridge_service "odin_test:hub/service/bridge"
import content_service "odin_test:hub/service/content"
import taskchain_service "odin_test:hub/service/taskchain"
import events "odin_test:hub/service/events"

Agent_Action_Handlers :: struct {
	auth: ^auth_service.Auth_Service,
	agents: ^agent_service.Agent_Service,
	bridges: ^bridge_service.Bridge_Service,
	content: ^content_service.Content_Service,
	taskchains: ^taskchain_service.Taskchain_Service,
	event_bus: ^events.User_Event_Bus,
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

agent_action_chat_send_to_agent_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, _, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	target := json_string(params, "to_instance")
	if target == "" do target = json_string(params, "target_agent_instance_id")
	msg, saved, err := content_service.send_agent_to_agent(h.content, auth, target, content_service.Message_Input{body = json_string(params, "body"), artifact_ids_json = json_array_optional(params, "artifact_ids")})
	if !saved do return respond_error(err, req.request_id)
	b := strings.builder_make()
	write_message_json(&b, msg, h.content)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

agent_action_chat_fetch_handler :: proc(ctx: rawptr, req: Request) -> Response {
	return process_agent_chat_fetch_or_read(ctx, req, false)
}

agent_action_chat_read_handler :: proc(ctx: rawptr, req: Request) -> Response {
	return process_agent_chat_fetch_or_read(ctx, req, true)
}

process_agent_chat_fetch_or_read :: proc(ctx: rawptr, req: Request, default_mark_read: bool) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	limit := json_int(params, "limit", 50)
	cursor := json_string(params, "cursor")
	conv, conv_ok, conv_err := content_service.get_conversation_by_instance(h.content, auth, inst.agent_instance_id)
	if !conv_ok do return respond_error(conv_err, req.request_id)
	
	unread_only := !strings.contains(params, "\"unread_only\":false") && !strings.contains(params, "\"unread_only\": false")
	receiver_only := !strings.contains(params, "\"receiver_only\":false") && !strings.contains(params, "\"receiver_only\": false")
	include_outgoing := strings.contains(params, "\"include_outgoing\":true") || strings.contains(params, "\"include_outgoing\": true")
	include_debug := strings.contains(params, "\"include_debug\":true") || strings.contains(params, "\"include_debug\": true")
	mark_read := default_mark_read ? (!strings.contains(params, "\"mark_read\":false") && !strings.contains(params, "\"mark_read\": false")) : (strings.contains(params, "\"mark_read\":true") || strings.contains(params, "\"mark_read\": true"))

	filter := content_service.Agent_Inbox_Filter{
		agent_instance_id=inst.agent_instance_id, 
		unread_only=unread_only, 
		receiver_only=receiver_only, 
		include_outgoing=include_outgoing, 
		include_debug=include_debug, 
		limit=limit, 
		cursor=cursor,
	}

	rows, err := content_service.list_agent_inbox_messages(h.content, auth, filter)
	if err.code != .None do return respond_error(err, req.request_id)
	
	unread_count_before := 0
	for row in rows { if row.read_at == "" do unread_count_before += 1 }

	marked_count := 0
	through_message_id := ""
	through_created_at := ""
	
	if mark_read && len(rows) > 0 && unread_count_before > 0 {
		ids := make([dynamic]string)
		defer delete(ids)
		for row in rows { if row.read_at == "" do append(&ids, row.message_id) }
		marked_count, _ = content_service.mark_messages_read_by_ids(h.content, auth, ids[:])
		through_message_id = rows[len(rows)-1].message_id
		through_created_at = rows[len(rows)-1].created_at
		// Notify the conversation owner (the human) that their agent read these
		// messages, so the UI can show read receipts on the user's sent bubbles.
		if marked_count > 0 {
			publish_agent_messages_read(h, string(conv.owner_user_id), conv, ids[:], inst.agent_instance_id)
		}
	}

	b := strings.builder_make()
	mode_str := unread_only ? "inbox_unread" : "history"
	
	fmt.sbprintf(&b, "{{\"conversation\":{{\"conversation_id\":\"%s\",\"agent_instance_id\":\"%s\",\"unread_count_before\":%d,\"unread_count_after\":%d}},\"mode\":\"%s\",\"filters\":{{\"receiver_agent_instance_id\":\"%s\",\"unread_only\":%t,\"receiver_only\":%t,\"include_outgoing\":%t,\"include_debug\":%t,\"mark_read\":%t}},\"messages\":[",
		conv.conversation_id, inst.agent_instance_id, unread_count_before, unread_count_before - marked_count, mode_str,
		inst.agent_instance_id, unread_only, receiver_only, include_outgoing, include_debug, mark_read)

	next := ""
	for msg, i in rows { if i > 0 do strings.write_byte(&b, ','); write_message_json(&b, msg, h.content); next = msg.created_at }
	
	fmt.sbprintf(&b, "],\"page\":{{\"limit\":%d,\"next_cursor\":\"%s\",\"has_more\":%t}}", limit, next, len(rows) >= limit)
	
	fmt.sbprintf(&b, ",\"read\":{{\"marked\":%t,\"marked_count\":%d,\"through_message_id\":\"%s\",\"through_created_at\":\"%s\"}}}}",
	    mark_read, marked_count, through_message_id, through_created_at)

	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

// Publish a `messages_read` event when an AGENT reads the user's messages, so
// the human's UI can show read receipts. Reuses messages_read_event_json from
// content_handlers (same package). No-op without an event bus (test wiring).
publish_agent_messages_read :: proc(h:^Agent_Action_Handlers, owner_user_id:string, c:domain.Chat_Conversation, message_ids:[]string, reader_instance_id:string){
	if h==nil || h.event_bus==nil || owner_user_id=="" || len(message_ids)==0 do return
	events.publish_raw_to_user(h.event_bus, owner_user_id, messages_read_event_json(c, message_ids, reader_instance_id))
}

agent_action_agents_live_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, _, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	instances, err := agent_service.list_instances_filtered(h.agents, auth, agent_service.List_Instances_Filter{runtime_status = "live"})
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for inst, i in instances { if i > 0 do strings.write_byte(&b, ','); write_agent_instance_json(&b, inst) }
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
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
	strings.write_string(&b, ",\"next_cursor\":\""); write_handler_json_string(&b, auth_ctx_server_time(req)); strings.write_string(&b, "\"")
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
	strings.write_string(&b, `{"task_id":"`)
	write_handler_json_string(&b, string(nudge.task_id))
	strings.write_string(&b, `","nudge_id":"`)
	write_handler_json_string(&b, nudge.nudge_id)
	strings.write_string(&b, `","delivery_state":"`)
	write_handler_json_string(&b, nudge.delivery_state)
	strings.write_string(&b, `","live_delivered":`)
	strings.write_string(&b, fmt.tprintf("%d", nudge.live_delivered))
	strings.write_string(&b, `,"durable_queued":`)
	strings.write_string(&b, fmt.tprintf("%d", nudge.durable_queued))
	strings.write_string(&b, `,"failed":`)
	strings.write_string(&b, fmt.tprintf("%d", nudge.failed))
	strings.write_string(&b, `,"target_role":"`)
	write_handler_json_string(&b, taskchain_service.target_string(nudge.target))
	strings.write_string(&b, `","created_at":"`)
	write_handler_json_string(&b, nudge.created_at)
	strings.write_string(&b, `","targets":`)
	strings.write_string(&b, nudge.targets_json)
	strings.write_string(&b, `}`)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 202)
}

agent_action_task_create_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	chain_id := json_string(params, "chain_id")
	if chain_id == "" do chain_id = inst.chain_id
	if chain, chain_ok, _ := taskchain_service.get_chain(h.taskchains, auth, domain.Task_Chain_ID(chain_id)); chain_ok {
		if chain.coordinator_agent_instance_id != "" && chain.coordinator_agent_instance_id != inst.agent_instance_id {
			return respond_error(domain.domain_error(.Forbidden, "only chain coordinator can create tasks"), req.request_id)
		}
	}
	task, created, err := taskchain_service.create_task(h.taskchains, auth, taskchain_service.Create_Task_Input{
		chain_id = domain.Task_Chain_ID(chain_id),
		title = json_string(params, "title"),
		description = json_string(params, "description"),
		assignee_ref_json = json_object_or_empty(params, "assignee_ref"),
		reviewer_refs_json = json_array_optional(params, "reviewer_refs"),
	})
	if !created do return respond_error(err, req.request_id)
	b := strings.builder_make()
	write_task_json(&b, task)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

agent_action_task_depend_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	task_id := domain.Task_ID(json_string(params, "task_id"))
	depends_on_task_id := domain.Task_ID(json_string(params, "depends_on_task_id"))
	if depends_on_task_id == "" do depends_on_task_id = domain.Task_ID(json_string(params, "on"))
	if task, task_ok, _ := taskchain_service.get_task(h.taskchains, auth, task_id); task_ok {
		if chain, chain_ok, _ := taskchain_service.get_chain(h.taskchains, auth, task.chain_id); chain_ok {
			if chain.coordinator_agent_instance_id != "" && chain.coordinator_agent_instance_id != inst.agent_instance_id {
				return respond_error(domain.domain_error(.Forbidden, "only chain coordinator can add task dependencies"), req.request_id)
			}
		}
	}
	dep, added, err := taskchain_service.add_task_dependency(h.taskchains, auth, task_id, depends_on_task_id)
	if !added do return respond_error(err, req.request_id)
	b := strings.builder_make()
	strings.write_string(&b, "{\"task_id\":\""); write_handler_json_string(&b, string(dep.task_id)); strings.write_string(&b, "\",\"depends_on_task_id\":\""); write_handler_json_string(&b, string(dep.depends_on_task_id)); strings.write_string(&b, "\"}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

agent_action_task_vote_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, _, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	task_id := domain.Task_ID(json_string(params, "task_id"))
	result := json_string(params, "result")
	if result == "" do result = json_string(params, "vote")
	comment := json_string(params, "comment")
	vote, recorded, err := taskchain_service.record_task_vote(h.taskchains, auth, taskchain_service.Vote_Input{task_id = task_id, vote = result, comment = comment})
	if !recorded do return respond_error(err, req.request_id)
	b := strings.builder_make()
	write_task_vote_json(&b, vote)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}


agent_action_artifact_create_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	content := json_string(params, "content")
	b64 := json_string(params, "content_base64")
	if b64 == "" do b64 = json_string(params, "inline_bytes")
	if b64 != "" {
		dec, _ := internal_b64.decode(b64, allocator = context.temp_allocator)
		if len(dec) > 0 do content = string(dec)
	}
	artifact, saved, err := content_service.create_artifact(h.content, auth, content_service.Artifact_Input{kind = json_string(params, "kind"), name = json_string(params, "name"), description = json_string(params, "description"), content_type = json_string(params, "content_type"), content = content, filename = json_string(params, "filename"), agent_id = inst.agent_id, agent_instance_id = inst.agent_instance_id, chain_id = inst.chain_id, project_id = inst.project_id})
	if !saved do return respond_error(err, req.request_id)
	b := strings.builder_make()
	write_artifact_json(&b, artifact, false)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

agent_action_artifact_list_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, _, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	rows, err := content_service.list_artifacts(h.content, auth)
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for artifact, i in rows { if i > 0 do strings.write_byte(&b, ','); write_artifact_json(&b, artifact, false) }
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

agent_action_artifact_show_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, _, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	artifact_id := json_string(params, "artifact_id")
	if artifact_id == "" do artifact_id = json_string(params, "artifact")
	if artifact_id == "" do return respond_error(domain.domain_error(.Validation_Failed, "artifact_id is required"), req.request_id)
	artifact, got, err := content_service.get_artifact(h.content, auth, artifact_id)
	if !got do return respond_error(err, req.request_id)
	with_content := strings.contains(params, "\"with_content\":true")
	b := strings.builder_make()
	write_artifact_json(&b, artifact, with_content)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

agent_action_artifact_content_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, _, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	artifact_id := json_string(params, "artifact_id")
	if artifact_id == "" do artifact_id = json_string(params, "artifact")
	if artifact_id == "" do return respond_error(domain.domain_error(.Validation_Failed, "artifact_id is required"), req.request_id)
	artifact, got, err := content_service.get_artifact(h.content, auth, artifact_id)
	if !got do return respond_error(err, req.request_id)
	b := strings.builder_make()
	strings.write_string(&b, "{\"artifact_id\":\""); write_handler_json_string(&b, artifact.artifact_id)
	strings.write_string(&b, "\",\"name\":\""); write_handler_json_string(&b, artifact.name)
	strings.write_string(&b, "\",\"content_type\":\""); write_handler_json_string(&b, artifact.content_type)
	strings.write_string(&b, "\",\"mime\":\""); write_handler_json_string(&b, artifact.mime)
	strings.write_string(&b, "\",\"size_bytes\":"); strings.write_string(&b, fmt.tprintf("%d", artifact.size_bytes))
	strings.write_string(&b, ",\"content\":\""); write_handler_json_string(&b, artifact.content)
	strings.write_string(&b, "\"}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

agent_action_memory_propose_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	agent_id := json_string(params, "target_agent_id"); if agent_id == "" do agent_id = json_string(params, "agent_id"); if agent_id == "" do agent_id = inst.agent_id
	project_id := json_string(params, "target_project_id"); if project_id == "" do project_id = json_string(params, "project_id")
	template_id := json_string(params, "target_template_id"); if template_id == "" do template_id = json_string(params, "template_id")
	bridge_id := json_string(params, "target_bridge_id"); if bridge_id == "" do bridge_id = json_string(params, "bridge_id")
	mem, saved, err := content_service.create_memory(h.content, auth, content_service.Memory_Input{agent_id = agent_id, project_id = domain.Project_ID(project_id), template_id = template_id, bridge_id = bridge_id, type = domain.memory_type_from_string(json_string(params, "type")), title = json_string(params, "title"), body = json_string(params, "body"), evidence = json_string(params, "evidence"), status = "pending"})
	if !saved do return respond_error(err, req.request_id)
	b := strings.builder_make()
	write_memory_json(&b, mem, false)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

agent_action_start_success_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, _, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	inst, saved, err := agent_service.mark_instance_start_success(h.agents, auth)
	if !saved do return respond_error(err, req.request_id)
	startup_note, note_saved, _ := content_service.send_agent_message(h.content, auth, inst.agent_instance_id, content_service.Message_Input{body = "Agent has started and is ready.", artifact_ids_json = "[]"})
	conv, conv_ok, _ := content_service.get_conversation_by_instance(h.content, auth, inst.agent_instance_id)
	if conv_ok {
		// Only re-notify for genuinely unread inbound messages. Scanning all recent
		// messages and notifying for the first user_to_agent row (regardless of read
		// state) produced false "New message from user" notifications on every
		// start-success, even when the inbox was empty/already read.
		inbox_filter := content_service.Agent_Inbox_Filter{
			agent_instance_id = inst.agent_instance_id,
			unread_only       = true,
			receiver_only     = true,
			include_outgoing  = false,
			include_debug     = false,
			limit             = 50,
		}
		unread, unread_err := content_service.list_agent_inbox_messages(h.content, auth, inbox_filter)
		if unread_err.code == .None {
			for msg in unread {
				if msg.direction == "user_to_agent" && msg.read_at == "" {
					content_service.notify_agent_message(h.content, conv, "user_to_agent", "user", msg.message_id)
					break
				}
			}
		}
	}
	b := strings.builder_make()
	strings.write_string(&b, "{\"instance\":")
	write_agent_instance_json(&b, inst)
	strings.write_string(&b, ",\"startup_message\":")
	if note_saved { write_message_json(&b, startup_note, h.content) } else { strings.write_string(&b, "null") }
	strings.write_byte(&b, '}')
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
	auth, ok, err := auth_service.resolve_bridge_instance_auth(h.auth, auth_service.Auth_Request{
		remote_addr = req.remote_addr,
		query = req.query,
		body = req.body,
		headers = req.headers,
	})
	if !ok do return contracts.Auth_Context{}, domain.Agent_Instance{}, false, respond_error(err, req.request_id)
	inst, inst_ok, inst_err := agent_service.get_instance(h.agents, contracts.Auth_Context{kind = .Bridge_Token, bridge_id = auth.bridge_id, user_id = auth.user_id}, auth.agent_instance_id)
	if !inst_ok do return contracts.Auth_Context{}, domain.Agent_Instance{}, false, respond_error(inst_err, req.request_id)
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
