package main

import "core:fmt"
import "core:strings"

CHAT_APPROVAL_DEFAULT_TTL_MS :: i64(30 * 60 * 1000) // 30 minutes
CHAT_APPROVAL_MAX_TTL_MS     :: i64(24 * 60 * 60 * 1000)
CHAT_APPROVAL_MIN_TTL_MS     :: i64(60 * 1000)

Chat_Approval_Detect_Result :: struct {
	matched:      bool,
	kind:         string,
	title:        string,
	body:         string,
	options_json: string,
	free_form:    bool,
	ttl_ms:       i64,
}

// Recognizes agent-authored payloads that look like approval prompts.
// Accepted shapes (subset of what the UI already renders):
//   {"type":"smart_answer","body":"...","suggested_replies":[ ... ], "expires_in_ms": 60000?}
//   {"type":"questions","body":"...","options":[ ... ], "free_form": true?}
//   {"type":"multi_question","title":"...","questions":[{"question":"...","options":["..."]}]}
//   {"type":"approval_request","title":"...","body":"...","suggested_replies":[ ... ]}
chat_approval_detect_payload :: proc(payload: string) -> Chat_Approval_Detect_Result {
	res := Chat_Approval_Detect_Result{}
	trimmed := strings.trim_space(payload)
	if trimmed == "" || trimmed[0] != '{' do return res
	kind := extract_json_string(trimmed, "type", "")
	if kind != "smart_answer" && kind != "questions" && kind != "multi_question" && kind != "approval_request" do return res
	options := extract_json_string(trimmed, "suggested_replies", "")
	if options == "" do options = chat_approval_extract_raw_json_value(trimmed, "suggested_replies")
	if options == "" do options = extract_json_string(trimmed, "options", "")
	if options == "" do options = chat_approval_extract_raw_json_value(trimmed, "options")
	if kind == "multi_question" {
		questions := chat_approval_extract_raw_json_value(trimmed, "questions")
		if questions == "" do return res
		options = questions
	}
	free_form := extract_json_bool(trimmed, "free_form", false)
	if options == "" && !(kind == "questions" && free_form) do return res
	res.matched = true
	res.kind = kind
	res.title = extract_json_string(trimmed, "title", "")
	res.body = extract_json_string(trimmed, "body", "")
	if res.body == "" && kind == "multi_question" do res.body = "Please answer the questions below."
	res.options_json = options
	res.free_form = free_form || kind == "questions" || kind == "multi_question"
	ttl := i64(extract_json_int(trimmed, "expires_in_ms", 0))
	if ttl <= 0 do ttl = CHAT_APPROVAL_DEFAULT_TTL_MS
	if ttl < CHAT_APPROVAL_MIN_TTL_MS do ttl = CHAT_APPROVAL_MIN_TTL_MS
	if ttl > CHAT_APPROVAL_MAX_TTL_MS do ttl = CHAT_APPROVAL_MAX_TTL_MS
	res.ttl_ms = ttl
	return res
}

chat_approval_invalid_type_error :: proc(payload: string) -> string {
	trimmed := strings.trim_space(payload)
	if trimmed == "" || trimmed[0] != '{' do return ""
	kind := extract_json_string(trimmed, "type", "")
	if kind == "smartanswer" {
		return `{"ok":false,"error":"invalid_approval_type","message":"invalid approval type 'smartanswer'; use canonical type 'smart_answer'"}`
	}
	return ""
}

chat_approval_extract_raw_json_value :: proc(body, key: string) -> string {
	start := json_value_start(body, key)
	if start < 0 || start >= len(body) do return ""
	open := body[start]
	if open != '[' && open != '{' do return ""
	close: u8 = ']'
	if open == '{' do close = '}'
	depth := 0
	escaped := false
	in_string := false
	for pos := start; pos < len(body); pos += 1 {
		ch := body[pos]
		if in_string {
			if escaped {
				escaped = false
			} else if ch == '\\' {
				escaped = true
			} else if ch == '"' {
				in_string = false
			}
			continue
		}
		if ch == '"' {
			in_string = true
			continue
		}
		if ch == open {
			depth += 1
		} else if ch == close {
			depth -= 1
			if depth == 0 do return body[start:pos + 1]
		}
	}
	return ""
}

// Insert a chat approval row bound to the given chain + message. Returns the
// approval_id on success. Caller must have already validated chain_id.
chat_approval_service_record :: proc(det: Chat_Approval_Detect_Result, message_id, chain_id, user_id, agent_instance_id: string) -> (string, bool) {
	if !det.matched || chain_id == "" || message_id == "" do return "", false
	now := router_now_unix_ms()
	approval_id := fmt.tprintf("cappr_%d", now)
	rec := Chat_Approval_Record{
		approval_id        = strings.clone(approval_id),
		message_id         = strings.clone(message_id),
		chain_id           = strings.clone(chain_id),
		user_id            = strings.clone(user_id),
		agent_instance_id  = strings.clone(agent_instance_id),
		kind               = strings.clone(det.kind),
		title              = strings.clone(det.title),
		body               = strings.clone(det.body),
		options_json       = strings.clone(det.options_json),
		free_form          = det.free_form,
		expires_at_unix_ms = now + det.ttl_ms,
		state              = strings.clone("open"),
		created_unix_ms    = now,
	}
	if !chat_approval_db_insert(rec) do return "", false
	chat_approval_ws_emit(rec, "chat_approval_created")
	return rec.approval_id, true
}

// Answer, dismiss, cancel, supersede, expire all funnel through this helper so
// UI state stays consistent and idempotent.
Chat_Approval_Terminal_Result :: struct {
	ok:             bool,
	status_code:    int,
	message:        string,
	record:         Chat_Approval_Record,
	previous_state: string,
}

chat_approval_service_terminal :: proc(approval_id, new_state, reply, actor, reason, superseded_by_message_id: string) -> Chat_Approval_Terminal_Result {
	if approval_id == "" do return Chat_Approval_Terminal_Result{status_code = 400, message = `{"ok":false,"message":"approval_id required"}`}
	if new_state != "answered" && new_state != "dismissed" && new_state != "cancelled" && new_state != "superseded" && new_state != "expired" {
		return Chat_Approval_Terminal_Result{status_code = 400, message = `{"ok":false,"message":"invalid target state"}`}
	}
	rec, found := chat_approval_db_get(approval_id)
	if !found do return Chat_Approval_Terminal_Result{status_code = 404, message = `{"ok":false,"message":"approval not found"}`}
	if rec.state != "open" {
		body := fmt.tprintf(`{{"ok":false,"message":"approval already %s","current_state":"%s","approval_id":"%s"}}`, rec.state, rec.state, approval_id)
		return Chat_Approval_Terminal_Result{status_code = 409, message = body, record = rec, previous_state = rec.state}
	}
	now := router_now_unix_ms()
	prev, moved := chat_approval_db_terminal_transition(approval_id, new_state, reply, actor, reason, superseded_by_message_id, now)
	if !moved {
		// Lost the race with another writer.
		refreshed, exists := chat_approval_db_get(approval_id)
		if !exists do return Chat_Approval_Terminal_Result{status_code = 404, message = `{"ok":false,"message":"approval disappeared"}`}
		body := fmt.tprintf(`{{"ok":false,"message":"approval already %s","current_state":"%s","approval_id":"%s"}}`, refreshed.state, refreshed.state, approval_id)
		return Chat_Approval_Terminal_Result{status_code = 409, message = body, record = refreshed, previous_state = prev}
	}
	final, exists := chat_approval_db_get(approval_id)
	if !exists do return Chat_Approval_Terminal_Result{status_code = 500, message = `{"ok":false,"message":"post-transition read failed"}`}
	chat_approval_ws_emit(final, chat_approval_ws_event_for_state(final.state))
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"approval_id":"`); json_write_string(&b, final.approval_id)
	strings.write_string(&b, `","state":"`); json_write_string(&b, final.state)
	strings.write_string(&b, `","previous_state":"`); json_write_string(&b, prev)
	strings.write_string(&b, `","chain_id":"`); json_write_string(&b, final.chain_id)
	strings.write_string(&b, `"}`)
	return Chat_Approval_Terminal_Result{ok = true, status_code = 200, message = strings.to_string(b), record = final, previous_state = prev}
}

chat_approval_ws_event_for_state :: proc(state: string) -> string {
	switch state {
	case "answered": return "chat_approval_answered"
	case "dismissed": return "chat_approval_dismissed"
	case "cancelled": return "chat_approval_cancelled"
	case "superseded": return "chat_approval_superseded"
	case "expired": return "chat_approval_expired"
	}
	return "chat_approval_updated"
}

chat_approval_ws_emit :: proc(rec: Chat_Approval_Record, event: string) {
	b := strings.builder_make()
	strings.write_string(&b, `{"type":"chat_approval","event":"`)
	json_write_string(&b, event)
	strings.write_string(&b, `","approval":`)
	chat_approval_write_json(&b, rec)
	strings.write_string(&b, `}`)
	user_client_fanout_ws_text(rec.user_id, strings.to_string(b))
}

chat_approval_write_json :: proc(b: ^strings.Builder, rec: Chat_Approval_Record) {
	strings.write_string(b, `{"approval_id":"`); json_write_string(b, rec.approval_id)
	strings.write_string(b, `","message_id":"`); json_write_string(b, rec.message_id)
	strings.write_string(b, `","chain_id":"`); json_write_string(b, rec.chain_id)
	strings.write_string(b, `","user_id":"`); json_write_string(b, rec.user_id)
	strings.write_string(b, `","agent_instance_id":"`); json_write_string(b, rec.agent_instance_id)
	strings.write_string(b, `","kind":"`); json_write_string(b, rec.kind)
	strings.write_string(b, `","title":"`); json_write_string(b, rec.title)
	strings.write_string(b, `","body":"`); json_write_string(b, rec.body)
	strings.write_string(b, `","options_json":`)
	if rec.options_json == "" {
		strings.write_string(b, `""`)
	} else {
		// Encode as JSON string to keep the response schema stable, even though
		// options_json itself is valid JSON. UI parses it lazily.
		strings.write_string(b, `"`)
		json_write_string(b, rec.options_json)
		strings.write_string(b, `"`)
	}
	strings.write_string(b, `,"free_form":`); strings.write_string(b, "true" if rec.free_form else "false")
	strings.write_string(b, `,"expires_at_unix_ms":`); strings.write_string(b, fmt.tprintf("%d", rec.expires_at_unix_ms))
	strings.write_string(b, `,"state":"`); json_write_string(b, rec.state)
	strings.write_string(b, `","answered_reply":"`); json_write_string(b, rec.answered_reply)
	strings.write_string(b, `","answered_at_unix_ms":`); strings.write_string(b, fmt.tprintf("%d", rec.answered_at_unix_ms))
	strings.write_string(b, `,"dismissed_by":"`); json_write_string(b, rec.dismissed_by)
	strings.write_string(b, `","dismiss_reason":"`); json_write_string(b, rec.dismiss_reason)
	strings.write_string(b, `","dismissed_at_unix_ms":`); strings.write_string(b, fmt.tprintf("%d", rec.dismissed_at_unix_ms))
	strings.write_string(b, `,"superseded_by_message_id":"`); json_write_string(b, rec.superseded_by_message_id)
	strings.write_string(b, `","created_unix_ms":`); strings.write_string(b, fmt.tprintf("%d", rec.created_unix_ms))
	strings.write_string(b, `}`)
}

chat_approval_list_pending_json :: proc(user_id: string) -> string {
	now := router_now_unix_ms()
	rows := chat_approval_db_list_open_for_user(user_id, now)
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"approvals":[`)
	for rec, idx in rows {
		if idx > 0 do strings.write_string(&b, `,`)
		chat_approval_write_json(&b, rec)
	}
	strings.write_string(&b, `]}`)
	return strings.to_string(b)
}

// Runs a batch of state='open' expired rows -> 'expired'. Bounded to keep the
// scheduler tick cheap.
chat_approval_sweep_expired :: proc() -> int {
	now := router_now_unix_ms()
	rows := chat_approval_db_list_expired(now, 32)
	changed := 0
	for rec in rows {
		result := chat_approval_service_terminal(rec.approval_id, "expired", "", "system-sweeper", "ttl_reached", "")
		if result.ok do changed += 1
	}
	return changed
}

// Called from the user->agent chat path so an off-topic reply on a chain closes
// its open approvals. reply_body is compared against options_json to skip the
// obvious explicit-answer case. Returns count of approvals superseded.
chat_approval_supersede_for_chain :: proc(chain_id, reply_body, superseded_by_message_id: string, actor: string) -> int {
	if chain_id == "" do return 0
	rows := chat_approval_db_list_open_for_chain(chain_id)
	changed := 0
	for rec in rows {
		if chat_approval_reply_matches_option(rec, reply_body) do continue
		result := chat_approval_service_terminal(rec.approval_id, "superseded", "", actor, "off_topic_reply", superseded_by_message_id)
		if result.ok do changed += 1
	}
	return changed
}

chat_approval_reply_matches_option :: proc(rec: Chat_Approval_Record, reply_body: string) -> bool {
	if rec.options_json == "" do return false
	// Cheap substring match: suggested_replies are stored as raw JSON, so if the
	// full reply body appears inside options_json we assume the operator picked one.
	trimmed := strings.trim_space(reply_body)
	if trimmed == "" do return false
	return strings.contains(rec.options_json, trimmed)
}
