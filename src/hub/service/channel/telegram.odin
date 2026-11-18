package channel

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:unicode/utf8"
import httpc "odin_test:lib/httpc"

Telegram_Adapter :: struct {
	token, api_base: string, // borrowed configuration, never included in diagnostics
	mutex: sync.Mutex,
	cached_identity: Identity,
}

telegram_adapter :: proc(t: ^Telegram_Adapter) -> Channel_Adapter {
	return {ctx = t, provider = "telegram", poll = telegram_poll, send_text = telegram_send_text, react = telegram_react, identity = telegram_identity, pairing_url = telegram_pairing_url}
}

// Stop all adapter users before destroying the process-lifetime identity cache.
telegram_destroy :: proc(t: ^Telegram_Adapter) {
	delete(t.cached_identity.bot_user_id, runtime.heap_allocator())
	delete(t.cached_identity.bot_username, runtime.heap_allocator())
	t.cached_identity = {}
}

// All provider and transport descriptions are untrusted: return only fixed safe
// messages, never a URL, response body, token, or httpc response.detail.
telegram_error :: proc(status: int, transport: httpc.Error, code: int, description: string, retry_after: i64) -> Channel_Error {
	if transport == .Aborted do return {kind = .Aborted, message = "telegram request aborted"}
	if transport != .None do return {kind = .Transient, message = "telegram transport failed"}
	kind: Channel_Error_Kind
	switch {
	case status >= 500: kind = .Transient
	case status == 429: kind = .Rate_Limited
	case status == 401 || status == 404: kind = .Unauthorized
	case status == 403 || (status == 400 && strings.contains(strings.to_lower(description, context.temp_allocator), "chat not found")): kind = .Chat_Unavailable
	case status >= 400: kind = .Invalid_Request
	case: kind = .Transient
	}
	wait := clamp(retry_after, 0, max(i64)/1000) * 1000
	return {kind = kind, retry_after_ms = wait if kind == .Rate_Limited else 0, provider_code = code, message = "telegram request failed"}
}

Telegram_Envelope :: struct {
	ok: bool,
	error_code: int,
	description: string,
	parameters: struct {retry_after: i64},
}

telegram_request :: proc(t: ^Telegram_Adapter, method: string, verb: httpc.Method, query: []httpc.Query_Param, body: httpc.Body, timeout: int, cancel: ^bool = nil) -> (httpc.Response, Channel_Error) {
	if cancel != nil && sync.atomic_load(cancel) do return {}, {kind = .Aborted, message = "telegram request aborted"}
	base, url_err := httpc.parse_url(t.api_base)
	if url_err != .None do return {}, {kind = .Invalid_Request, message = "invalid telegram API base"}
	path := [2]string{fmt.tprintf("bot%s", t.token), method}
	resp, err := httpc.send({method = verb, url = base, path = path[:], query = query, body = body, timeout_ms = timeout, max_response_bytes = 4 << 20, cancel = cancel})
	if err != .None do return resp, telegram_error(0, err, 0, "", 0)
	env: Telegram_Envelope
	decode := json.unmarshal(resp.body, &env, allocator = context.temp_allocator)
	if resp.status < 200 || resp.status >= 300 || !env.ok {
		status := resp.status
		if status >= 200 && status < 300 && env.error_code > 0 do status = env.error_code
		return resp, telegram_error(status, .None, env.error_code, env.description, env.parameters.retry_after)
	}
	if decode != nil do return resp, {kind = .Transient, message = "invalid telegram response"}
	return resp, {}
}

// Returned Identity is borrowed from the cache; do not delete its fields.
telegram_identity :: proc(ctx: rawptr) -> (Identity, Channel_Error) {
	t := (^Telegram_Adapter)(ctx)
	sync.mutex_lock(&t.mutex)
	defer sync.mutex_unlock(&t.mutex)
	if t.cached_identity.bot_user_id != "" do return t.cached_identity, {}
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return {}, {kind = .Transient, message = "telegram allocation failed"}
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	resp, err := telegram_request(t, "getMe", .GET, nil, nil, 10_000)
	defer httpc.response_destroy(&resp)
	if err.kind != .None do return {}, err
	data: struct {result: struct {id: i64, username: string}}
	if json.unmarshal(resp.body, &data, allocator = context.temp_allocator) != nil || data.result.id == 0 || data.result.username == "" do return {}, {kind = .Transient, message = "invalid telegram identity"}
	t.cached_identity = {strings.clone(fmt.tprintf("%d", data.result.id), runtime.heap_allocator()), strings.clone(data.result.username, runtime.heap_allocator())}
	return t.cached_identity, {}
}

// Returned batch fields and next_cursor belong to allocator. inbound_destroy_batch
// releases them even when a poll returns an empty batch.
inbound_destroy_batch :: proc(batch: []Inbound, allocator := context.allocator) {
	for row in batch {
		delete(row.update_key, allocator); delete(row.external_chat_id, allocator)
		delete(row.external_message_id, allocator)
		delete(row.external_user_id, allocator); delete(row.sender_display, allocator)
		delete(row.text, allocator)
	}
	delete(batch, allocator)
}

telegram_poll :: proc(ctx: rawptr, cursor: string, cancel: ^bool, allocator := context.allocator) -> (batch: []Inbound, next_cursor: string, err: Channel_Error) {
	t := (^Telegram_Adapter)(ctx)
	if cancel != nil && sync.atomic_load(cancel) do return nil, "", {kind = .Aborted, message = "telegram request aborted"}
	id, id_err := telegram_identity(ctx)
	if id_err.kind != .None do return nil, "", id_err
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return nil, "", {kind = .Transient, message = "telegram allocation failed"}
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	query := [3]httpc.Query_Param{{"timeout", "30"}, {"allowed_updates", "[\"message\"]"}, {"offset", cursor}}
	qs := query[:] if cursor != "" else query[:2]
	resp, req_err := telegram_request(t, "getUpdates", .GET, qs, nil, 40_000, cancel)
	defer httpc.response_destroy(&resp)
	if req_err.kind != .None do return nil, "", req_err
	value, decode := json.parse(string(resp.body), allocator = context.temp_allocator, parse_integers = true)
	if decode != .None do return nil, "", {kind = .Transient, message = "invalid telegram updates"}
	root, root_ok := value.(json.Object)
	updates, updates_ok := root["result"].(json.Array)
	if !root_ok || !updates_ok do return nil, "", {kind = .Transient, message = "invalid telegram updates"}
	rows := make([dynamic]Inbound, 0, len(updates), allocator)
	next := cursor
	highest: i64 = -1
	for update in updates {
		u, _ := update.(json.Object)
		update_id, _ := u["update_id"].(json.Integer)
		highest = max(highest, update_id)
		m, has_message := u["message"].(json.Object)
		if !has_message do continue
		chat, _ := m["chat"].(json.Object)
		from, _ := m["from"].(json.Object)
		chat_type, _ := chat["type"].(string)
		message_id, _ := m["message_id"].(json.Integer)
		chat_id, _ := chat["id"].(json.Integer)
		user_id, _ := from["id"].(json.Integer)
		username, _ := from["username"].(string)
		first_name, _ := from["first_name"].(string)
		private := chat_type == "private"
		kind: Inbound_Kind = .Unsupported
		text := ""
		message_text, has_text := m["text"].(string)
		if private && has_text {
			text = message_text
			switch {
			case strings.has_prefix(text, "/start"):
				kind = .Start
				text = strings.trim_space(text[len("/start "):]) if strings.has_prefix(text, "/start ") else ""
			case text == "/disconnect": kind = .Disconnect
			case: kind = .Text
			}
		}
		display := fmt.tprintf("@%s", username) if username != "" else first_name
		append(&rows, Inbound{
			update_key = strings.clone(fmt.tprintf("telegram:%s:%d", id.bot_user_id, update_id), allocator),
			external_chat_id = strings.clone(fmt.tprintf("%d", chat_id), allocator),
			external_message_id = strings.clone(fmt.tprintf("%d", message_id), allocator),
			external_user_id = strings.clone(fmt.tprintf("%d", user_id), allocator),
			chat_is_private = private, sender_display = strings.clone(display, allocator),
			kind = kind, text = strings.clone(text, allocator),
		})
	}
	if highest >= 0 && highest < max(i64) do next = fmt.tprintf("%d", highest+1)
	shrink(&rows)
	return rows[:], strings.clone(next, allocator), {}
}

telegram_send_text :: proc(ctx: rawptr, external_chat_id: string, text: string) -> (string, Channel_Error) {
	chat_id, valid := strconv.parse_i64(external_chat_id)
	if !valid || len(text) > 4000 || !utf8.valid_string(text) do return "", {kind = .Invalid_Request, message = "invalid telegram message"}
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return "", {kind = .Transient, message = "telegram allocation failed"}
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	body := httpc.json_body(struct {chat_id: i64, text: string, disable_web_page_preview: bool}{chat_id, text, false}, allocator = context.temp_allocator)
	resp, err := telegram_request((^Telegram_Adapter)(ctx), "sendMessage", .POST, nil, body, 15_000)
	defer httpc.response_destroy(&resp)
	if err.kind != .None do return "", err
	data: struct {result: struct {message_id: i64}}
	if json.unmarshal(resp.body, &data, allocator = context.temp_allocator) != nil do return "", {kind = .Transient, message = "invalid telegram message response"}
	return strings.clone(fmt.tprintf("%d", data.result.message_id)), {}
}

telegram_pairing_url :: proc(ctx: rawptr, identity: Identity, code: string, allocator := context.allocator) -> string {
	return fmt.aprintf("https://t.me/%s?start=%s", identity.bot_username, code, allocator = allocator)
}

// Feedback requests use the same bounded request path and safe errors as text.
// JSON and request scratch are scoped to the call; no caller-owned data escapes.
telegram_react :: proc(ctx: rawptr, external_chat_id, external_message_id, emoji: string) -> Channel_Error {
	chat_id, valid_chat := strconv.parse_i64(external_chat_id)
	message_id, valid_message := strconv.parse_i64(external_message_id)
	if !valid_chat || !valid_message || message_id <= 0 || emoji == "" || !utf8.valid_string(emoji) do return {kind = .Invalid_Request, message = "invalid telegram reaction"}
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return {kind = .Transient, message = "telegram allocation failed"}
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	body := httpc.json_body(struct {
		chat_id, message_id: i64,
		reaction: [1]struct {type, emoji: string},
	}{chat_id, message_id, {{"emoji", emoji}}}, allocator = context.temp_allocator)
	resp, err := telegram_request((^Telegram_Adapter)(ctx), "setMessageReaction", .POST, nil, body, 15_000)
	defer httpc.response_destroy(&resp)
	return err
}
