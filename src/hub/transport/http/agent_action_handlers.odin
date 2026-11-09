package http

import "core:fmt"
import "core:log"
import "core:time"
import "core:strings"
import "core:strconv"
import "core:sync"
import "core:unicode/utf8"
import internal_b64 "core:encoding/base64"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import auth_service "odin_test:hub/service/auth"
import agent_service "odin_test:hub/service/agent"
import bridge_service "odin_test:hub/service/bridge"
import content_service "odin_test:hub/service/content"
import search_service "odin_test:hub/service/search"
import events "odin_test:hub/service/events"
import push_service "odin_test:hub/service/push"
import provider_service "odin_test:hub/service/provider"
import card_service "odin_test:hub/service/card"
import "core:encoding/json"

Agent_Action_Handlers :: struct {
	auth: ^auth_service.Auth_Service,
	agents: ^agent_service.Agent_Service,
	bridges: ^bridge_service.Bridge_Service,
	content: ^content_service.Content_Service,
	search: ^search_service.Search_Service,
	cards: ^card_service.Card_Service,
	event_bus: ^events.User_Event_Bus,
	// Web Push (WP-SEND): background delivery of OS notifications when the user's
	// PWA is closed/backgrounded. public_app_origin builds the absolute click href.
	push: ^push_service.Push_Service,
	public_app_origin: string,
	providers: ^provider_service.Provider_Service,
	// experiments: the owner's flag/setting store; read for
	// auto_approve_agent_memories. nil → proposals stay pending.
	experiments: ^iface.Experiment_Repository,
}

// agent_memory_proposal_status: "active" (approved) when the owner's
// auto_approve_agent_memories setting is on (default on, F1) AND the memory
// targets only the proposing agent itself (every agent_ids entry is that
// agent; other dimensions only narrow it further). A memory that would reach
// other agents, or every agent, stays "pending" for the user. A missing or
// failing store keeps the safe pending default.
agent_memory_proposal_status :: proc(repo: ^iface.Experiment_Repository, owner_user_id: string, proposer_agent_id := "", agent_ids: []string = nil) -> string {
	if repo == nil || owner_user_id == "" || proposer_agent_id == "" || len(agent_ids) == 0 do return "pending"
	for id in agent_ids do if id != proposer_agent_id do return "pending"
	exps, err := iface.experiment_list_by_owner(repo, owner_user_id)
	defer {
		for exp in exps {
			delete(exp.owner_user_id)
			delete(exp.key)
			delete(exp.updated_at)
		}
		delete(exps)
	}
	if err.code != .None do return "pending"
	return "active" if domain.experiment_enabled_in(exps[:], domain.AUTO_APPROVE_AGENT_MEMORIES_KEY) else "pending"
}

agent_action_chat_send_to_user_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	metadata_json := ""
	options := json_array_optional(params, "options")
	action_ids := json_array_optional(params, "action_ids")
	if action_ids == "" do action_ids = json_array_optional(params, "actions")
	if options != "" && action_ids != "" {
		metadata_json = fmt.tprintf("{{\"options\":%s,\"action_ids\":%s}}", options, action_ids)
	} else if options != "" {
		metadata_json = fmt.tprintf("{{\"options\":%s}}", options)
	} else if action_ids != "" {
		metadata_json = fmt.tprintf("{{\"action_ids\":%s}}", action_ids)
	} else if meta_obj := json_object_raw(params, "metadata"); meta_obj != "" {
		metadata_json = meta_obj
	} else if meta_str := json_string(params, "metadata_json"); meta_str != "" {
		metadata_json = meta_str
	}
	msg, saved, err := content_service.send_agent_message(h.content, auth, inst.agent_instance_id, content_service.Message_Input{body = json_string(params, "body"), artifact_ids_json = json_array_optional(params, "artifact_ids"), message_type = json_string(params, "message_type"), metadata_json = metadata_json})
	if !saved do return respond_error(err, req.request_id)
	// Notify the human's UI so it can toast + raise an OS notification. This is a
	// metadata event with a SHORT body preview (<=140 chars) — the full body is
	// still fetched durably via REST (fetch_required). System messages
	// (e.g. start-success banners) are not user-actionable, so skip their preview.
	if h.event_bus != nil && msg.message_type != "system" {
		events.publish_owned(h.event_bus, string(inst.owner_user_id), agent_to_user_chat_event_json(inst, msg))
	} else if h.event_bus != nil {
		// System rows still move last_message_at/unread_count: id-only hint, no toast.
		if conv, conv_ok, _ := content_service.get_conversation_by_instance(h.content, auth, inst.agent_instance_id); conv_ok do publish_chat_message_created(h.event_bus, conv, msg)
	}
	// Web Push (WP-SEND-2): also deliver an OS notification for backgrounded/
	// closed PWAs. Mirrors the client notify policy (chat only, never system):
	// same choke-point + preview as the WS chat_event above. Non-blocking so it
	// never stalls the response; a no-op when push is unconfigured.
	if h.push != nil && msg.message_type != "system" {
		content := push_service.build_chat_notification(msg.conversation_id, inst.agent_instance_id, msg.message_type, msg.body)
		defer push_service.free_notification_content(content)
		payload := push_service.build_push_payload_json(content, h.public_app_origin)
		defer delete(payload)
		push_service.send_to_user_async(h.push, inst.owner_user_id, payload)
	}
	// Ephemeral activity bubble (skip non-actionable system banners).
	if msg.message_type != "system" do publish_agent_action(h, inst, "chat_send", "sent a message")
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
	if domain.contains_vault_token(trimmed) {
		return collapsed
	}
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
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	target := json_string(params, "to_instance")
	if target == "" do target = json_string(params, "target_agent_instance_id")
	metadata_json := ""
	options := json_array_optional(params, "options")
	action_ids := json_array_optional(params, "action_ids")
	if action_ids == "" do action_ids = json_array_optional(params, "actions")
	if options != "" && action_ids != "" {
		metadata_json = fmt.tprintf("{{\"options\":%s,\"action_ids\":%s}}", options, action_ids)
	} else if options != "" {
		metadata_json = fmt.tprintf("{{\"options\":%s}}", options)
	} else if action_ids != "" {
		metadata_json = fmt.tprintf("{{\"action_ids\":%s}}", action_ids)
	} else if meta_obj := json_object_raw(params, "metadata"); meta_obj != "" {
		metadata_json = meta_obj
	} else if meta_str := json_string(params, "metadata_json"); meta_str != "" {
		metadata_json = meta_str
	}
	msg, saved, err := content_service.send_agent_to_agent(h.content, auth, target, content_service.Message_Input{body = json_string(params, "body"), artifact_ids_json = json_array_optional(params, "artifact_ids"), message_type = json_string(params, "message_type"), metadata_json = metadata_json})
	if !saved do return respond_error(err, req.request_id)
	// E3: the row lands in the TARGET's conversation and moves its preview and
	// last_message_at; id-only hint from the re-read row (no body, no toast).
	if h.event_bus != nil {
		if conv, conv_ok, _ := content_service.get_conversation(h.content, contracts.Auth_Context{kind = .Internal_User, user_id = string(inst.owner_user_id)}, msg.conversation_id); conv_ok do publish_chat_message_created(h.event_bus, conv, msg)
	}
	// Q3: id-free plain phrase (never resolve the target's name in the emit path).
	publish_agent_action(h, inst, "chat_send_agent", "messaged another agent")
	b := strings.builder_make()
	write_message_json(&b, msg, h.content)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

// agent_action_chat_previous_context_handler stores the rollover handoff the
// bridge forwards on an instance's behalf (identity is the verified instance
// auth, never the payload). The row is inbound and unread in the caller's own
// conversation and is NOT notified to the agent; only the owner's UI gets the
// message_created hint. Idempotent on params.request_id: a retry returns the
// original message with created=false.
agent_action_chat_previous_context_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	input := content_service.Previous_Context_Input{
		request_id = json_string(params, "request_id"),
		body = json_string(params, "body"),
		metadata_json = json_object_raw(params, "metadata"),
	}
	msg, created, err := content_service.store_previous_context(h.content, auth, inst.agent_instance_id, input)
	if err.code != .None do return respond_error(err, req.request_id)
	if created && h.event_bus != nil {
		if conv, conv_ok, _ := content_service.get_conversation_by_instance(h.content, auth, inst.agent_instance_id); conv_ok do publish_chat_message_created(h.event_bus, conv, msg)
	}
	b := strings.builder_make()
	strings.write_string(&b, "{\"accepted\":true,\"created\":")
	strings.write_string(&b, "true" if created else "false")
	strings.write_string(&b, ",\"message_id\":\"")
	contracts.write_json_string(&b, msg.message_id)
	strings.write_string(&b, "\",\"conversation_id\":\"")
	contracts.write_json_string(&b, msg.conversation_id)
	strings.write_string(&b, "\",\"message_type\":\"")
	contracts.write_json_string(&b, msg.message_type)
	strings.write_string(&b, "\",\"created_at\":\"")
	contracts.write_json_string(&b, msg.created_at)
	strings.write_string(&b, "\"}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201 if created else 200)
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
	publish_agent_action(h, inst, "conversation_title", "renamed the conversation")
	publish_conversation_changed(h.event_bus, c, "updated")
	b := strings.builder_make()
	write_chat_json(&b, c)
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
	// Optional cross-agent read: a curator (same owner user) may read another
	// agent's conversation by passing target_instance_id. get_conversation_by_instance
	// scopes by auth.user_id, so cross-user access is blocked automatically — no extra
	// ownership check is needed. Absent target_id falls back to the caller's own inbox.
	target_id := json_string(params, "target_instance_id")
	effective_instance_id := target_id != "" ? target_id : inst.agent_instance_id
	conv, conv_ok, conv_err := content_service.get_conversation_by_instance(h.content, auth, effective_instance_id)
	if !conv_ok do return respond_error(conv_err, req.request_id)
	
	unread_only := !strings.contains(params, "\"unread_only\":false") && !strings.contains(params, "\"unread_only\": false")
	receiver_only := !strings.contains(params, "\"receiver_only\":false") && !strings.contains(params, "\"receiver_only\": false")
	include_outgoing := strings.contains(params, "\"include_outgoing\":true") || strings.contains(params, "\"include_outgoing\": true")
	include_debug := strings.contains(params, "\"include_debug\":true") || strings.contains(params, "\"include_debug\": true")
	mark_read := default_mark_read ? (!strings.contains(params, "\"mark_read\":false") && !strings.contains(params, "\"mark_read\": false")) : (strings.contains(params, "\"mark_read\":true") || strings.contains(params, "\"mark_read\": true"))

	filter := content_service.Agent_Inbox_Filter{
		agent_instance_id=effective_instance_id,
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
		read_at := ""
		marked_count, read_at, _ = content_service.mark_messages_read_by_ids_at(h.content, auth, ids[:])
		// E4: the rows were listed before the mark; report the committed receipt.
		if marked_count > 0 {
			for &row in rows { if row.read_at == "" do row.read_at = read_at }
		}
		through_message_id = rows[len(rows)-1].message_id
		through_created_at = rows[len(rows)-1].created_at
		// Notify the conversation owner (the human) that their agent read these
		// messages, so the UI can show read receipts on the user's sent bubbles.
		if marked_count > 0 {
			publish_agent_messages_read(h, string(conv.owner_user_id), conv, ids[:], inst.agent_instance_id, read_at)
		}
	}

	b := strings.builder_make()
	mode_str := unread_only ? "inbox_unread" : "history"
	
	fmt.sbprintf(&b, "{{\"conversation\":{{\"conversation_id\":\"%s\",\"agent_instance_id\":\"%s\",\"unread_count_before\":%d,\"unread_count_after\":%d}},\"mode\":\"%s\",\"filters\":{{\"receiver_agent_instance_id\":\"%s\",\"unread_only\":%t,\"receiver_only\":%t,\"include_outgoing\":%t,\"include_debug\":%t,\"mark_read\":%t}},\"messages\":[",
		conv.conversation_id, effective_instance_id, unread_count_before, unread_count_before - marked_count, mode_str,
		effective_instance_id, unread_only, receiver_only, include_outgoing, include_debug, mark_read)

	next := ""
	for msg, i in rows { if i > 0 do strings.write_byte(&b, ','); write_message_json(&b, msg, h.content); next = msg.created_at }
	
	fmt.sbprintf(&b, "],\"page\":{{\"limit\":%d,\"next_cursor\":\"%s\",\"has_more\":%t}}", limit, next, len(rows) >= limit)
	
	fmt.sbprintf(&b, ",\"read\":{{\"marked\":%t,\"marked_count\":%d,\"through_message_id\":\"%s\",\"through_created_at\":\"%s\"}}}}",
	    mark_read, marked_count, through_message_id, through_created_at)

	// Human-readable activity bubble: 'read inbox (N new)' vs 'checked messages'.
	if default_mark_read {
		act := target_id != "" ? fmt.tprintf("read inbox of %s (%d new)", target_id, unread_count_before) : fmt.tprintf("read inbox (%d new)", unread_count_before)
		publish_agent_action(h, inst, "chat_read", act)
	} else {
		act := target_id != "" ? fmt.tprintf("checked messages of %s", target_id) : "checked messages"
		publish_agent_action(h, inst, "chat_fetch", act)
	}
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

// Publish a `messages_read` event when an AGENT reads the user's messages, so
// the human's UI can show read receipts. Reuses messages_read_event_json from
// content_handlers (same package). No-op without an event bus (test wiring).
publish_agent_messages_read :: proc(h:^Agent_Action_Handlers, owner_user_id:string, c:domain.Chat_Conversation, message_ids:[]string, reader_instance_id:string, read_at:string){
	if h==nil || h.event_bus==nil || owner_user_id=="" || len(message_ids)==0 do return
	events.publish_owned(h.event_bus, owner_user_id, messages_read_event_json(c, message_ids, reader_instance_id, read_at))
}

// publish_agent_action emits a lean, ephemeral "agent_action" event to the acting
// instance's OWNER connection so the dashboard can show a transient activity
// bubble of what the agent is doing right now. Best-effort and non-blocking:
// a no-op without an event bus (test wiring) or an owner. The caller composes a
// short, human-readable, id-FREE summary; agent_action_event_json clips it
// (rune-safe) and frames it. Never affects the HTTP response.
publish_agent_action :: proc(h: ^Agent_Action_Handlers, inst: domain.Agent_Instance, action, summary: string) {
	if h == nil || h.event_bus == nil do return
	owner := string(inst.owner_user_id)
	if owner == "" || inst.agent_instance_id == "" do return
	event := agent_action_event_json(inst.agent_instance_id, action, summary)
	defer delete(event)
	events.publish_raw_to_user(h.event_bus, owner, event)
}

// Max runes for an activity-bubble summary (matches the client's ~40-60 char cap).
AGENT_ACTION_SUMMARY_MAX :: 60

// agent_action_event_json builds the ephemeral {"type":"agent_action",...} frame.
// Split out from publish_agent_action so a unit test can assert the payload shape
// and id-free summary without a live event bus. summary is clipped rune-safe to
// AGENT_ACTION_SUMMARY_MAX runes (reusing chat_event_preview) so a long preview
// can't bloat the frame. ts is hub unix-ms (the client uses it for the replay window).
agent_action_event_json :: proc(agent_instance_id, action, summary: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"type":"agent_action","instance_id":"`)
	write_handler_json_string(&b, agent_instance_id)
	strings.write_string(&b, `","action":"`)
	write_handler_json_string(&b, action)
	strings.write_string(&b, `","summary":"`)
	clipped := chat_event_preview(summary, AGENT_ACTION_SUMMARY_MAX)
	defer delete(clipped)
	write_handler_json_string(&b, clipped)
	strings.write_string(&b, `","ts":`)
	strings.write_string(&b, fmt.tprintf("%d", time.to_unix_nanoseconds(time.now()) / 1_000_000))
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

agent_action_agents_live_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	instances, err := agent_service.list_instances_filtered(h.agents, auth, agent_service.List_Instances_Filter{runtime_status = "live"})
	if err.code != .None do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "agents_live", "listed live agents")
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
	strings.write_string(&b, "\",\"model\":\""); write_handler_json_string(&b, inst.model)
	strings.write_string(&b, "\",\"runtime_status\":\""); write_handler_json_string(&b, inst.runtime_status)
	strings.write_string(&b, "\",\"startup_status\":\""); write_handler_json_string(&b, inst.startup_status)
	strings.write_string(&b, "\"},\"unread_summary\":{\"conversation_unread_count\":")
	if conv_ok { strings.write_string(&b, fmt.tprintf("%d", conv.unread_count)) } else { strings.write_string(&b, "0") }
	// Hub tasks are removed; an owner-chain task is read through the Bridge.
	strings.write_string(&b, "},\"current_task\":null")
	strings.write_string(&b, ",\"next_cursor\":\""); write_handler_json_string(&b, auth_ctx_server_time(req)); strings.write_string(&b, "\"")
	strings.write_byte(&b, '}')
	publish_agent_action(h, inst, "context", "refreshed context")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

agent_action_artifact_create_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	if size_err, too_large := artifact_request_too_large(req); too_large do return respond_error(size_err, req.request_id)
	params := json_object_raw(req.body, "params")
	content := json_string(params, "content")
	b64 := json_string(params, "content_base64")
	if b64 == "" do b64 = json_string(params, "inline_bytes")
	if b64 != "" {
		dec, _ := internal_b64.decode(b64, allocator = context.temp_allocator)
		if len(dec) > 0 do content = string(dec)
	}
	// Task attribution comes from the authenticated instance's native lease
	// binding, never a caller-supplied task/chain or actor override.
	artifact, saved, err := content_service.create_artifact(h.content, auth, content_service.Artifact_Input{kind = json_string(params, "kind"), name = json_string(params, "name"), description = json_string(params, "description"), content_type = json_string(params, "content_type"), content = content, filename = json_string(params, "filename"), agent_id = inst.agent_id, agent_instance_id = inst.agent_instance_id, chain_id = inst.chain_id, task_id = string(inst.current_task_id), project_id = inst.project_id})
	if !saved do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "artifact_create", fmt.tprintf("created artifact \"%s\"", artifact.name))
	b := strings.builder_make()
	write_artifact_json(&b, artifact, false)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

agent_action_artifact_list_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp

	params := json_object_raw(req.body, "params")
	if params == "" do params = req.body

	project_id := json_string(params, "project_id")
	agent_instance_id := json_string(params, "agent_instance_id")
	agent_id := json_string(params, "agent_id")
	chain_id := json_string(params, "chain_id")
	task_id := json_string(params, "task_id")
	kind := json_string(params, "kind")
	since := json_string(params, "since")
	until := json_string(params, "until")
	include_deleted := json_bool(params, "include_deleted")
	sort := json_string(params, "sort")
	if sort == "" do sort = json_string(params, "sort_field")
	order := json_string(params, "order")
	if order == "" do order = json_string(params, "sort_order")
	limit := json_int(params, "limit", 50)
	cursor := json_string(params, "cursor")

	filter := domain.Artifact_List_Filter{
		project_id        = domain.Project_ID(project_id),
		agent_instance_id = agent_instance_id,
		agent_id          = agent_id,
		chain_id          = chain_id,
		task_id           = task_id,
		kind              = kind,
		since             = since,
		until             = until,
		include_deleted   = include_deleted,
		sort_field        = sort,
		sort_order        = order,
		limit             = limit,
		cursor            = cursor,
	}

	rows, err := content_service.list_artifacts(h.content, auth, filter)
	if err.code != .None do return respond_error(err, req.request_id)
	defer domain.artifacts_destroy(rows)

	publish_agent_action(h, inst, "artifact_list", "listed artifacts")

	eff_limit := limit
	if eff_limit <= 0 do eff_limit = 50
	if eff_limit > 200 do eff_limit = 200

	has_more := len(rows) > eff_limit
	page_count := len(rows)
	if page_count > eff_limit do page_count = eff_limit

	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for i in 0..<page_count {
		if i > 0 do strings.write_byte(&b, ',')
		write_artifact_json(&b, rows[i], false)
	}
	strings.write_byte(&b, ']')

	next_cursor := ""
	if has_more && page_count > 0 {
		next_cursor = artifact_page_cursor(rows[page_count - 1], filter.sort_field)
	}

	return respond_list(strings.to_string(b), contracts.API_Page{limit = eff_limit, next_cursor = next_cursor, has_more = has_more}, req.request_id, auth_ctx_server_time(req))
}

agent_action_artifact_show_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	artifact_id := json_string(params, "artifact_id")
	if artifact_id == "" do artifact_id = json_string(params, "artifact")
	if artifact_id == "" do return respond_error(domain.domain_error(.Validation_Failed, "artifact_id is required"), req.request_id)
	artifact, got, err := content_service.get_artifact(h.content, auth, artifact_id)
	if !got do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "artifact_show", "opened an artifact")
	with_content := strings.contains(params, "\"with_content\":true")
	b := strings.builder_make()
	write_artifact_json(&b, artifact, with_content)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

agent_action_artifact_content_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	artifact_id := json_string(params, "artifact_id")
	if artifact_id == "" do artifact_id = json_string(params, "artifact")
	if artifact_id == "" do return respond_error(domain.domain_error(.Validation_Failed, "artifact_id is required"), req.request_id)
	artifact, got, err := content_service.get_artifact(h.content, auth, artifact_id)
	if !got do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "artifact_content", "read an artifact")
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

// agent_action_search_handler is the agent.search RPC (SEARCH-7): the same global
// search as the REST GET /api/v1/search, over an instance token. Owner scoping is
// derived from the instance auth (ownership.owner_from_auth in the service), so an
// agent can only ever search its owner's data. Uses the typed SEARCH-8 contract
// (scopes + task/chain/project/conversation ids + negations + exclude) and returns
// the identical grouped hit shape as REST.
agent_action_search_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	input := search_service.Search_Input{
		q = json_string(params, "query"),
		types_csv = agent_action_csv_field(params, "scopes"),
		limit = json_int(params, "limit", 0),
		cursor = json_string(params, "cursor"),
		task_ids = agent_action_csv_field(params, "task_ids"),
		chain_ids = agent_action_csv_field(params, "chain_ids"),
		project_ids = agent_action_csv_field(params, "project_ids"),
		conversation_ids = agent_action_csv_field(params, "conversation_ids"),
		not_in_task_ids = agent_action_csv_field(params, "not_in_task_ids"),
		not_in_chain_ids = agent_action_csv_field(params, "not_in_chain_ids"),
		not_in_project_ids = agent_action_csv_field(params, "not_in_project_ids"),
		not_in_conversation_ids = agent_action_csv_field(params, "not_in_conversation_ids"),
		exclude = json_string(params, "exclude"),
	}
	result, searched, err := search_service.search_resources(h.search, auth, input)
	if !searched do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "search", "searched")
	page_limit := input.limit
	if page_limit <= 0 do page_limit = search_service.DEFAULT_SEARCH_LIMIT
	if page_limit > search_service.MAX_SEARCH_LIMIT do page_limit = search_service.MAX_SEARCH_LIMIT
	data_json := search_groups_json(result.hits)
	return respond_search(data_json, contracts.API_Page{limit = page_limit, next_cursor = result.next_cursor, has_more = result.has_more}, req.request_id, auth_ctx_server_time(req))
}

// agent_action_csv_field reads a params field as either a JSON string array
// (joined to CSV) or a plain CSV string, so agents can send arrays naturally
// while the service consumes the same CSV shape as the REST query params.
agent_action_csv_field :: proc(params, key: string) -> string {
	arr := json_string_array(params, key)
	if len(arr) > 0 do return strings.join(arr, ",")
	return json_string(params, key)
}

agent_action_memory_propose_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	// Targeting is read as JSON string arrays agent_ids/project_ids/template_ids/
	// bridge_ids (empty/omitted = applies to all). When the proposer supplies no
	// agent targeting at all, default to its own durable agent so self-proposed
	// memories stay scoped to that agent (matching the prior scalar behavior).
	agent_ids := json_string_array(params, "agent_ids")
	if len(agent_ids) == 0 do agent_ids = []string{inst.agent_id}
	project_ids := json_project_id_array(params, "project_ids")
	template_ids := json_string_array(params, "template_ids")
	bridge_ids := json_string_array(params, "bridge_ids")
	status := agent_memory_proposal_status(h.experiments, string(inst.owner_user_id), inst.agent_id, agent_ids)
	mem, saved, err := content_service.create_memory(h.content, auth, content_service.Memory_Input{auto_approved = status == "active", agent_ids = agent_ids, project_ids = project_ids, template_ids = template_ids, bridge_ids = bridge_ids, type = domain.memory_type_from_string(json_string(params, "type")), title = json_string(params, "title"), description = json_string(params, "description"), body = json_string(params, "body"), evidence = json_string(params, "evidence"), status = status, expires_at = json_string(params, "expires_at"), proposed_by_instance_id = inst.agent_instance_id, proposed_in_chain_id = inst.chain_id})
	if !saved do return respond_error(err, req.request_id)
	if mem.auto_approved_at != "" {
		log.infof("memory %s auto-approved (auto_approve_agent_memories) for agent %s, proposed by %s", mem.memory_id, inst.agent_id, inst.agent_instance_id)
	}
	publish_agent_action(h, inst, "memory_propose", fmt.tprintf("proposed memory \"%s\"", mem.title))
	b := strings.builder_make()
	write_memory_json(&b, mem, false)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

write_memory_metadata_json :: proc(b: ^strings.Builder, m: domain.Memory) {
	typ := domain.memory_type_string(m.type)
	strings.write_string(b, "{\"memory_id\":\"")
	write_handler_json_string(b, m.memory_id)
	strings.write_string(b, "\",\"type\":\"")
	write_handler_json_string(b, typ)
	strings.write_string(b, "\",\"status\":\"")
	write_handler_json_string(b, m.status)
	strings.write_string(b, "\",\"title\":\"")
	write_handler_json_string(b, m.title)
	strings.write_string(b, "\",\"description\":\"")
	write_handler_json_string(b, m.description)
	strings.write_string(b, "\",\"agent_ids\":")
	write_memory_id_array(b, m.agent_ids)
	strings.write_string(b, ",\"project_ids\":")
	write_memory_project_array(b, m.project_ids)
	strings.write_string(b, ",\"template_ids\":")
	write_memory_id_array(b, m.template_ids)
	strings.write_string(b, ",\"bridge_ids\":")
	write_memory_id_array(b, m.bridge_ids)
	strings.write_string(b, ",\"expires_at\":\"")
	write_handler_json_string(b, m.expires_at)
	strings.write_string(b, "\",\"created_at\":\"")
	write_handler_json_string(b, m.created_at)
	strings.write_string(b, "\",\"updated_at\":\"")
	write_handler_json_string(b, m.updated_at)
	strings.write_string(b, "\"}")
}

agent_action_memory_filter_value :: proc(params, plural_key, singular_key: string) -> string {
	arr := json_string_array(params, plural_key)
	defer delete(arr)
	for item in arr {
		trimmed := strings.trim_space(item)
		if trimmed != "" do return trimmed
	}
	raw := json_string(params, plural_key)
	if raw == "" do raw = json_string(params, singular_key)
	raw = strings.trim_space(raw)
	if comma := strings.index_byte(raw, ','); comma >= 0 do return strings.trim_space(raw[:comma])
	return raw
}

agent_action_memory_list_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	limit := json_int(params, "limit", 50)
	if limit <= 0 do limit = 50
	if limit > 200 do limit = 200
	status := json_string(params, "status")
	type_str := json_string(params, "type")
	agent_id := agent_action_memory_filter_value(params, "agent_ids", "agent_id")
	project_id := agent_action_memory_filter_value(params, "project_ids", "project_id")
	bridge_id := agent_action_memory_filter_value(params, "bridge_ids", "bridge_id")
	template_id := agent_action_memory_filter_value(params, "template_ids", "template_id")
	filter := content_service.Memory_Filter{
		status      = status,
		type        = type_str,
		agent_id    = agent_id,
		project_id  = domain.Project_ID(project_id),
		bridge_id   = bridge_id,
		template_id = template_id,
	}
	rows, err := content_service.list_memories(h.content, auth, filter, limit)
	if err.code != .None do return respond_error(err, req.request_id)
	defer delete(rows)
	publish_agent_action(h, inst, "memory_list", "listed memories")
	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for mem, i in rows {
		if i > 0 do strings.write_byte(&b, ',')
		write_memory_metadata_json(&b, mem)
	}
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = limit, has_more = len(rows) >= limit}, req.request_id, auth_ctx_server_time(req))
}

agent_action_memory_show_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	memory_id := json_string(params, "memory_id")
	if memory_id == "" do memory_id = json_string(params, "memory")
	if memory_id == "" do memory_id = json_string(params, "id")
	if memory_id == "" do return respond_error(domain.domain_error(.Validation_Failed, "memory_id is required"), req.request_id)
	mem, got, err := content_service.get_memory(h.content, auth, memory_id)
	if !got do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "memory_show", fmt.tprintf("opened memory \"%s\"", mem.title))
	b := strings.builder_make()
	write_memory_json(&b, mem, false)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

agent_action_memory_content_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	memory_id := json_string(params, "memory_id")
	if memory_id == "" do memory_id = json_string(params, "memory")
	if memory_id == "" do memory_id = json_string(params, "id")
	if memory_id == "" do return respond_error(domain.domain_error(.Validation_Failed, "memory_id is required"), req.request_id)
	mem, got, err := content_service.get_memory(h.content, auth, memory_id)
	if !got do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "memory_content", fmt.tprintf("read memory \"%s\"", mem.title))
	b := strings.builder_make()
	strings.write_string(&b, "{\"memory_id\":\""); write_handler_json_string(&b, mem.memory_id)
	strings.write_string(&b, "\",\"content\":\""); write_handler_json_string(&b, mem.body)
	strings.write_string(&b, "\"}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

agent_start_success_mutex: sync.Mutex

agent_action_start_success_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	// Authenticate after serialization so a queued request is rechecked against
	// the current launch assertion. Duplicate retries must not rerun ready hooks.
	// start_success is a lenient indicator: a valid instance token is sufficient,
	// so a stale or missing run_count and an inactive status never 409.
	sync.mutex_lock(&agent_start_success_mutex)
	defer sync.mutex_unlock(&agent_start_success_mutex)
	auth, current, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	if current.kind != "provider_test" {
		note, exists, read_err := content_service.get_agent_startup_message(h.content, auth, current)
		if read_err.code != .None && read_err.code != .Not_Found do return respond_error(read_err, req.request_id)
		if exists {
			// This generation's ready hooks already ran. If the instance was
			// since marked inactive, record readiness again without rerunning them.
			if !agent_service.instance_start_success_is_noop(current) {
				revived, changed, revived_ok, revive_err := agent_service.mark_instance_start_success(h.agents, auth, fire_hooks = false)
				if !revived_ok do return respond_error(revive_err, req.request_id)
				if changed do publish_instance_changed(h.event_bus, revived, "status_changed")
				current = revived
			}
			b := strings.builder_make()
			strings.write_string(&b, "{\"instance\":"); write_agent_instance_json(&b, current)
			strings.write_string(&b, ",\"startup_message\":"); write_message_json(&b, note, h.content)
			strings.write_byte(&b, '}')
			return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
		}
	}
	inst, changed, saved, err := agent_service.mark_instance_start_success(h.agents, auth)
	if !saved do return respond_error(err, req.request_id)
	if !changed {
		// Already running/ready: acknowledge without rerunning ready hooks.
		b := strings.builder_make(); strings.write_string(&b, "{\"instance\":"); write_agent_instance_json(&b, inst); strings.write_byte(&b, '}')
		return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
	}
	// running/ready was written: tell the owner's UI, and let an in-flight
	// reconfiguration observe readiness now rather than on the next reaper pass.
	publish_instance_changed(h.event_bus, inst, "status_changed")
	agent_service.reconcile_instance_reconfigurations(h.agents, inst.bridge_id, resend = false)
	if inst.kind == "provider_test" {
		if h.providers != nil do provider_service.provider_test_mark_instance_ready(h.providers, inst.agent_instance_id)
		b := strings.builder_make(); strings.write_string(&b, "{\"instance\":"); write_agent_instance_json(&b, inst); strings.write_byte(&b, '}')
		return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
	}
	startup_note, note_saved, note_err := content_service.send_agent_startup_message(h.content, auth, inst)
	if note_err.code != .None do return respond_error(note_err, req.request_id)
	conv, conv_ok, _ := content_service.get_conversation_by_instance(h.content, auth, inst.agent_instance_id)
	// The system banner moves last_message_at/unread_count; it gets the id-only
	// message_created hint (no preview, no toast) so sidebars stay current.
	if conv_ok && note_saved do publish_chat_message_created(h.event_bus, conv, startup_note)
	if conv_ok && note_saved {
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
				// A previous_context handoff is the agent's own note, read via the
				// rollover prompt; announcing it as "from User" would be false.
				if msg.direction == "user_to_agent" && msg.read_at == "" && msg.message_type != content_service.MESSAGE_TYPE_PREVIOUS_CONTEXT {
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
	write_message_json(&b, startup_note, h.content)
	strings.write_byte(&b, '}')
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

agent_action_card_create_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp

	params := json_object_raw(req.body, "params")

	project_id := domain.Project_ID(json_string(params, "project_id"))
	if project_id == "" do project_id = domain.Project_ID(inst.project_id)

	provider := json_string(params, "provider")
	if provider == "" do provider = domain.CARD_PROVIDER_CURATOR_LLM

	raw_refs, _ := json_raw_field(params, "source_refs")
	raw_ops, _ := json_raw_field(params, "operations")
	raw_guard, _ := json_raw_field(params, "guard")

	input := card_service.Card_Input{
		project_id       = project_id,
		title            = json_string(params, "title"),
		rationale        = json_string(params, "rationale"),
		scope            = json_string(params, "scope"),
		provider         = provider,
		confidence       = json_f32(params, "confidence", 1.0),
		source_refs_json = raw_refs,
		status           = json_string(params, "status"),
		operations_json  = raw_ops,
		guard_json       = raw_guard,
		snooze_until     = json_string(params, "snooze_until"),
		ttl_at           = json_string(params, "ttl_at"),
	}

	card, saved, err := card_service.create_card(h.cards, auth, input)
	if !saved do return respond_error(err, req.request_id)

	publish_agent_action(h, inst, "card_create", fmt.tprintf("created card \"%s\"", card.title))

	b := strings.builder_make()
	write_card_json(&b, card)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

agent_action_card_list_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp

	params := json_object_raw(req.body, "params")
	limit := json_int(params, "limit", 50)
	if limit <= 0 do limit = 50
	if limit > 200 do limit = 200

	project_id := json_string(params, "project_id")
	filter := card_service.Card_Filter{
		status     = json_string(params, "status"),
		scope      = json_string(params, "scope"),
		provider   = json_string(params, "provider"),
		project_id = domain.Project_ID(project_id),
	}

	cards, err := card_service.list_cards(h.cards, auth, filter, limit)
	if err.code != .None do return respond_error(err, req.request_id)
	defer delete(cards)

	publish_agent_action(h, inst, "card_list", "listed cards")

	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for c, i in cards {
		if i > 0 do strings.write_byte(&b, ',')
		write_card_json(&b, c)
	}
	strings.write_byte(&b, ']')

	return respond_list(strings.to_string(b), contracts.API_Page{limit = limit, has_more = len(cards) >= limit}, req.request_id, auth_ctx_server_time(req))
}

agent_action_card_show_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp

	params := json_object_raw(req.body, "params")
	card_id := json_string(params, "card_id")
	if card_id == "" do card_id = json_string(params, "action_id")
	if card_id == "" do card_id = json_string(params, "card")
	if card_id == "" do card_id = json_string(params, "id")
	if card_id == "" do return respond_error(domain.domain_error(.Validation_Failed, "card_id is required"), req.request_id)

	card, got, err := card_service.get_card(h.cards, auth, domain.Card_ID(card_id))
	if !got do return respond_error(err, req.request_id)

	publish_agent_action(h, inst, "card_show", fmt.tprintf("opened card \"%s\"", card.title))

	b := strings.builder_make()
	write_card_json(&b, card)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

agent_action_card_discard_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp

	params := json_object_raw(req.body, "params")
	card_id := json_string(params, "card_id")
	if card_id == "" do card_id = json_string(params, "action_id")
	if card_id == "" do card_id = json_string(params, "card")
	if card_id == "" do card_id = json_string(params, "id")
	if card_id == "" do return respond_error(domain.domain_error(.Validation_Failed, "card_id is required"), req.request_id)

	card, discarded, err := card_service.discard_card(h.cards, auth, domain.Card_ID(card_id))
	if !discarded do return respond_error(err, req.request_id)

	publish_agent_action(h, inst, "card_discard", fmt.tprintf("discarded card \"%s\"", card.title))

	b := strings.builder_make()
	write_card_json(&b, card)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

agent_action_card_accept_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp

	params := json_object_raw(req.body, "params")
	card_id := json_string(params, "card_id")
	if card_id == "" do card_id = json_string(params, "action_id")
	if card_id == "" do card_id = json_string(params, "card")
	if card_id == "" do card_id = json_string(params, "id")
	if card_id == "" do return respond_error(domain.domain_error(.Validation_Failed, "card_id is required"), req.request_id)

	card, accepted, err := card_service.accept_card(h.cards, auth, domain.Card_ID(card_id))
	if !accepted do return respond_error(err, req.request_id)

	publish_agent_action(h, inst, "card_accept", fmt.tprintf("accepted card \"%s\"", card.title))

	b := strings.builder_make()
	write_card_json(&b, card)
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

// POST /api/v1/agent-actions/lease/next. An instance's leases live on its
// chain's owner Bridge, which answers lease next for any instance bound there;
// the Bridge forwards only callers it holds nothing for. Hub task chains are
// removed, so the Hub has no work to offer: status none (not an error, so an
// idle agent's habitual `lease next` stays quiet).
agent_action_lease_next_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	_, _, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	return respond_success(`{"lease":null,"pack":null,"status":"none","task":null}`, req.request_id, auth_ctx_server_time(req), 200)
}
