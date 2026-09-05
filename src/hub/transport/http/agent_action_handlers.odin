package http

import "core:fmt"
import "core:strings"
import "core:strconv"
import "core:unicode/utf8"
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
	// Notify the human's UI so it can toast + raise an OS notification. This is a
	// metadata event with a SHORT body preview (<=140 chars) — the full body is
	// still fetched durably via REST (fetch_required). System messages
	// (e.g. start-success banners) are not user-actionable, so skip their preview.
	if h.event_bus != nil && msg.message_type != "system" {
		events.publish_raw_to_user(h.event_bus, string(inst.owner_user_id), agent_to_user_chat_event_json(inst, msg))
	}
	b := strings.builder_make()
	write_message_json(&b, msg, h.content)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

// agent_to_user_chat_event_json builds the user-WS chat_event for a fresh
// agent->user message. Carries a truncated body_preview for the toast/OS
// notification while keeping the full body behind a durable REST fetch.
agent_to_user_chat_event_json :: proc(inst: domain.Agent_Instance, m: domain.Chat_Message) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"chat_event\",\"event\":\"chat_updated\",\"direction\":\"agent_to_user\",\"conversation_id\":\"")
	write_handler_json_string(&b, m.conversation_id)
	strings.write_string(&b, "\",\"agent_instance_id\":\"")
	write_handler_json_string(&b, inst.agent_instance_id)
	strings.write_string(&b, "\",\"message_id\":\"")
	write_handler_json_string(&b, m.message_id)
	strings.write_string(&b, "\",\"message_type\":\"")
	write_handler_json_string(&b, m.message_type)
	strings.write_string(&b, "\",\"body_preview\":\"")
	write_handler_json_string(&b, chat_event_preview(m.body, 140))
	strings.write_string(&b, "\",\"fetch_required\":true,\"fetch_kind\":\"chat_message\",\"fetch_id\":\"")
	write_handler_json_string(&b, m.message_id)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// chat_event_preview collapses whitespace and truncates to max_len runes,
// appending an ellipsis when clipped. Rune-safe so we never split a UTF-8
// codepoint mid-preview.
chat_event_preview :: proc(body: string, max_len: int) -> string {
	trimmed := strings.trim_space(body)
	if trimmed == "" do return ""
	// Collapse internal whitespace runs to single spaces.
	fields := strings.fields(trimmed)
	defer delete(fields)
	collapsed := strings.join(fields, " ")
	runes := utf8.rune_count_in_string(collapsed)
	if runes <= max_len {
		return collapsed
	}
	defer delete(collapsed)
	// Take the first (max_len-1) runes then add an ellipsis.
	count := 0
	end := len(collapsed)
	for i := 0; i < len(collapsed); {
		if count >= max_len - 1 { end = i; break }
		_, w := utf8.decode_rune_in_string(collapsed[i:])
		i += w
		count += 1
	}
	return strings.concatenate({collapsed[:end], "…"})
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

// agent_action_conversation_set_title_handler lets an agent rename ITS OWN bound
// conversation (T3/REQ-3). Marks title_source="agent" so the nudge engine stops.
agent_action_conversation_set_title_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	c, saved, err := content_service.set_own_conversation_title(h.content, auth, inst.agent_instance_id, json_string(params, "title"))
	if !saved do return respond_error(err, req.request_id)
	b := strings.builder_make()
	write_chat_json(&b, c)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

// agent_action_chain_set_title_handler lets an agent rename the task chain it
// belongs to (T3/REQ-3). Marks title_source="agent" so the nudge engine stops.
agent_action_chain_set_title_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	chain_id := json_string(params, "chain_id")
	if strings.trim_space(chain_id) == "" do chain_id = inst.chain_id
	if strings.trim_space(chain_id) == "" do return respond_error(domain.domain_error(.Validation_Failed, "chain_id is required"), req.request_id)
	chain, saved, err := taskchain_service.set_own_chain_title(h.taskchains, auth, chain_id, json_string(params, "title"))
	if !saved do return respond_error(err, req.request_id)
	b := strings.builder_make()
	write_chain_json(&b, chain)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
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

// publish_current_task_changed emits a live resource_changed event on an agent
// instance's current task pointer so the dashboard updates its work-vs-review
// banner without a manual refresh (CT-9). Fire-and-forget; no-op without a bus.
publish_current_task_changed :: proc(h: ^Agent_Action_Handlers, owner_user_id, agent_instance_id, current_task_id, current_task_role: string) {
	if h == nil || h.event_bus == nil || owner_user_id == "" do return
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `{"agent_instance_id":"`); write_handler_json_string(&b, agent_instance_id)
	strings.write_string(&b, `","current_task_id":"`); write_handler_json_string(&b, current_task_id)
	strings.write_string(&b, `","current_task_role":"`); write_handler_json_string(&b, current_task_role)
	strings.write_string(&b, `"}`)
	events.publish_resource_changed(h.event_bus, owner_user_id, "agent_instance", agent_instance_id, "current_task_changed", strings.to_string(b))
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

// agent_action_task_show_handler returns slim task detail by task_id ALONE — the
// chain is derived server-side from the task (get_task resolves + authorizes).
// No client chain_id is required (task ids are globally unique). Reuses the
// shared write_task_detail_json via a lightweight Taskchain_Handlers view.
agent_action_task_show_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, _, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	task_id := domain.Task_ID(json_string(params, "task_id"))
	if strings.trim_space(string(task_id)) == "" do return respond_error(domain.domain_error(.Validation_Failed, "task_id is required"), req.request_id)
	task, got, err := taskchain_service.get_task(h.taskchains, auth, task_id)
	if !got do return respond_error(err, req.request_id)
	deps, _ := taskchain_service.list_chain_dependencies(h.taskchains, auth, task.chain_id)
	tch := Taskchain_Handlers{auth = h.auth, taskchains = h.taskchains, agents = h.agents, event_bus = h.event_bus}
	b := strings.builder_make()
	write_task_detail_json(&b, &tch, auth, task, deps)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

// agent_action_task_comments_handler returns the newest N comments for a task by
// task_id alone (chain derived server-side). ?last is passed as a param.
agent_action_task_comments_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, _, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	task_id := domain.Task_ID(json_string(params, "task_id"))
	if strings.trim_space(string(task_id)) == "" do return respond_error(domain.domain_error(.Validation_Failed, "task_id is required"), req.request_id)
	last := 0
	if v := strings.trim_space(json_string(params, "last")); v != "" { if n, parsed := strconv.parse_int(v); parsed { last = n } }
	if last > TASK_COMMENTS_LAST_MAX do last = TASK_COMMENTS_LAST_MAX
	comments, cerr := taskchain_service.list_recent_task_comments(h.taskchains, auth, task_id, last)
	if cerr.code != .None do return respond_error(cerr, req.request_id)
	b := strings.builder_make(); strings.write_byte(&b, '[')
	for c, i in comments { if i > 0 do strings.write_byte(&b, ','); write_task_comment_json(&b, c) }
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

// agent_action_task_list_handler lists tasks for a chain. chain_id is optional:
// when omitted it defaults to the caller instance's own chain, so agents never
// need to know/pass a chain id.
agent_action_task_list_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	chain_id := strings.trim_space(json_string(params, "chain_id"))
	if chain_id == "" do chain_id = inst.chain_id
	if strings.trim_space(chain_id) == "" do return respond_error(domain.domain_error(.Validation_Failed, "no chain for this instance; pass chain_id"), req.request_id)
	tasks, err := taskchain_service.list_tasks(h.taskchains, auth, domain.Task_Chain_ID(chain_id))
	if err.code != .None do return respond_error(err, req.request_id)
	deps, _ := taskchain_service.list_chain_dependencies(h.taskchains, auth, domain.Task_Chain_ID(chain_id))
	tch := Taskchain_Handlers{auth = h.auth, taskchains = h.taskchains, agents = h.agents, event_bus = h.event_bus}
	b := strings.builder_make(); strings.write_byte(&b, '[')
	for task, i in tasks { if i > 0 do strings.write_byte(&b, ','); write_task_detail_json(&b, &tch, auth, task, deps) }
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

agent_action_task_comment_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, _, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	notify := json_array_of_strings_raw(params, "notify")
	comment, notified, saved, err := taskchain_service.comment_task(h.taskchains, auth, taskchain_service.Task_Comment_Input{task_id = domain.Task_ID(json_string(params, "task_id")), body = json_string(params, "body"), notify = notify})
	if !saved do return respond_error(err, req.request_id)
	b := strings.builder_make()
	write_task_comment_response_json(&b, comment, notified)
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

// agent_action_task_set_current_handler lets an agent set its OWN current task
// (CT-9 self-service focus switch). The instance is taken from the authenticated
// token, so an agent can only move its own pointer. The service validates that the
// agent is the task's assignee/reviewer and that the task is actionable, persists
// the pointer, notifies (R8 action label), and we emit a live event.
agent_action_task_set_current_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	task_id := domain.Task_ID(json_string(params, "task_id"))
	if strings.trim_space(string(task_id)) == "" do return respond_error(domain.domain_error(.Validation_Failed, "task_id is required"), req.request_id)
	saved, set_ok, err := taskchain_service.set_instance_current_task(h.taskchains, auth, inst.agent_instance_id, task_id)
	if !set_ok do return respond_error(err, req.request_id)
	publish_current_task_changed(h, string(saved.owner_user_id), saved.agent_instance_id, saved.current_task_id, domain.current_task_role_string(saved.current_task_role))
	b := strings.builder_make()
	strings.write_string(&b, `{"agent_instance_id":"`)
	write_handler_json_string(&b, saved.agent_instance_id)
	strings.write_string(&b, `","current_task_id":"`)
	write_handler_json_string(&b, saved.current_task_id)
	strings.write_string(&b, `","current_task_role":"`)
	write_handler_json_string(&b, domain.current_task_role_string(saved.current_task_role))
	strings.write_string(&b, `"}`)
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

// agent_action_task_update_handler edits an already-created task: title,
// description, priority, assignee, reviewers, and dependencies. Mirrors the
// user-mode PATCH (update_task) but authed by instance token and gated to the
// chain coordinator (same authority model as create/depend). Only the fields
// present in params are changed; reviewer_refs/depends_on REPLACE the whole list
// when present (has_* flags distinguish "absent" from "cleared").
agent_action_task_update_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	task_id := domain.Task_ID(json_string(params, "task_id"))
	if strings.trim_space(string(task_id)) == "" do return respond_error(domain.domain_error(.Validation_Failed, "task_id is required"), req.request_id)
	// Coordinator-only, matching create/depend: resolve the task's chain and check
	// the caller is its coordinator (when one is set).
	if task, task_ok, _ := taskchain_service.get_task(h.taskchains, auth, task_id); task_ok {
		if chain, chain_ok, _ := taskchain_service.get_chain(h.taskchains, auth, task.chain_id); chain_ok {
			if chain.coordinator_agent_instance_id != "" && chain.coordinator_agent_instance_id != inst.agent_instance_id {
				return respond_error(domain.domain_error(.Forbidden, "only chain coordinator can update tasks"), req.request_id)
			}
		}
	}
	has_deps := strings.contains(params, "\"depends_on\"")
	deps := json_array_of_strings(params, "depends_on")
	has_priority := strings.contains(params, "\"priority\"")
	priority := domain.task_priority_from_string(json_string(params, "priority"))
	task, updated, err := taskchain_service.update_task(h.taskchains, auth, task_id, taskchain_service.Update_Task_Input{
		title = json_string(params, "title"),
		description = json_string(params, "description"),
		assignee_ref_json = json_object_or_empty(params, "assignee_ref"),
		reviewer_refs_json = json_array_optional(params, "reviewer_refs"),
		priority = priority,
		has_priority = has_priority,
		depends_on = deps,
		has_depends_on = has_deps,
	})
	if !updated do return respond_error(err, req.request_id)
	b := strings.builder_make()
	write_task_json(&b, task)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
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
	startup_note, note_saved, _ := content_service.send_agent_message(h.content, auth, inst.agent_instance_id, content_service.Message_Input{body = "Agent has started and is ready.", artifact_ids_json = "[]", message_type = "system"})
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

// write_agent_current_task_json serializes the instance's SERVER-AUTHORITATIVE
// current task (CT-8/CT-9): it resolves the persisted current_task_id to the task
// and emits it with the persisted role (work|review), rather than inferring from
// status. Falls back to null when the pointer is unset or the task is gone.
write_agent_current_task_json :: proc(b: ^strings.Builder, h: ^Agent_Action_Handlers, auth: contracts.Auth_Context, inst: domain.Agent_Instance) {
	if h.taskchains == nil || inst.chain_id == "" || inst.current_task_id == "" { strings.write_string(b, "null"); return }
	// Serializer guard (read-only): emit null if the persisted pointer no longer
	// resolves to an actionable role for this instance, so a stale pointer never
	// surfaces a task the agent should not act on between reconciles.
	if !taskchain_service.current_task_pointer_valid(h.taskchains, auth, inst) { strings.write_string(b, "null"); return }
	tasks, err := taskchain_service.list_tasks(h.taskchains, auth, domain.Task_Chain_ID(inst.chain_id))
	if err.code != .None { strings.write_string(b, "null"); return }
	for task in tasks {
		if string(task.task_id) == inst.current_task_id {
			summary, _ := taskchain_service.task_comment_summary(h.taskchains, auth, task.task_id)
			write_current_task_json(b, task, inst.current_task_role, summary)
			return
		}
	}
	strings.write_string(b, "null")
}

// write_current_task_json emits a task with its work-vs-review role + priority so
// the agent/UI can render the current-task banner unambiguously (R8). It also
// carries the comment_summary so the snapshot shows fresh discussion without
// shipping bodies (agents fetch the thread with `task comments <id> --last N`).
write_current_task_json :: proc(b: ^strings.Builder, task: domain.Task, role: domain.Current_Task_Role, summary: domain.Task_Comment_Summary) {
	strings.write_string(b, "{\"task_id\":\""); write_handler_json_string(b, string(task.task_id))
	strings.write_string(b, "\",\"chain_id\":\""); write_handler_json_string(b, string(task.chain_id))
	strings.write_string(b, "\",\"title\":\""); write_handler_json_string(b, task.title)
	strings.write_string(b, "\",\"status\":\""); write_handler_json_string(b, task_status_http(task.status))
	strings.write_string(b, "\",\"priority\":\""); write_handler_json_string(b, domain.task_priority_string(task.priority))
	strings.write_string(b, "\",\"role\":\""); write_handler_json_string(b, domain.current_task_role_string(role))
	strings.write_string(b, "\",\"comment_summary\":")
	write_task_comment_summary_json(b, summary)
	strings.write_string(b, "}")
}
