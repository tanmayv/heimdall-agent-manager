package channel

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"
import httpc "odin_test:lib/httpc"

Telegram_Adapter :: struct {
	token, api_base: string, // borrowed configuration, never included in diagnostics
	mutex: sync.Mutex,
	cached_identity: Identity,
}

telegram_adapter :: proc(t: ^Telegram_Adapter) -> Channel_Adapter {
	return {ctx = t, provider = "telegram", poll = telegram_poll, send_text = telegram_send_text, react = telegram_react, identity = telegram_identity, pairing_url = telegram_pairing_url,
		media = {TELEGRAM_MEDIA_FETCH_MAX_BYTES, TELEGRAM_MEDIA_CAPTION_MAX_RUNES, TELEGRAM_MEDIA_SEND_RULES[:]},
		media_fetch = telegram_media_fetch, send_media = telegram_send_media, send_text_within = telegram_send_text_within}
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
		delete(row.provider_time, allocator)
		delete(row.media.file_ref, allocator)
		delete(row.media.name, allocator)
		delete(row.media.mime, allocator)
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
		media: Inbound_Media
		if private && !has_text {
			text, _ = m["caption"].(string)
			media = telegram_inbound_media(m, allocator)
			if media.file_ref != "" do kind = .Media
		}
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
			kind = kind, text = strings.clone(text, allocator), media = media,
		})
	}
	if highest >= 0 && highest < max(i64) do next = fmt.tprintf("%d", highest+1)
	shrink(&rows)
	return rows[:], strings.clone(next, allocator), {}
}

telegram_send_text :: proc(ctx: rawptr, external_chat_id: string, text: string) -> (string, Channel_Error) {
	return telegram_send_text_within(ctx, external_chat_id, text, 15_000)
}

telegram_send_text_within :: proc(ctx: rawptr, external_chat_id, text: string, timeout_ms: int) -> (string, Channel_Error) {
	chat_id, valid := strconv.parse_i64(external_chat_id)
	if !valid || len(text) > 4000 || !utf8.valid_string(text) do return "", {kind = .Invalid_Request, message = "invalid telegram message"}
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return "", {kind = .Transient, message = "telegram allocation failed"}
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	body := httpc.json_body(struct {chat_id: i64, text: string, disable_web_page_preview: bool}{chat_id, text, false}, allocator = context.temp_allocator)
	resp, err := telegram_request((^Telegram_Adapter)(ctx), "sendMessage", .POST, nil, body, clamp(timeout_ms, 1, MEDIA_PROVIDER_BUDGET_MS))
	defer httpc.response_destroy(&resp)
	if err.kind != .None do return "", err
	data: struct {result: struct {message_id: i64}}
	if json.unmarshal(resp.body, &data, allocator = context.temp_allocator) != nil do return "", {kind = .Transient, message = "invalid telegram message response"}
	return strings.clone(fmt.tprintf("%d", data.result.message_id)), {}
}

telegram_pairing_url :: proc(ctx: rawptr, identity: Identity, code: string, allocator := context.allocator) -> string {
	return fmt.aprintf("https://t.me/%s?start=%s", identity.bot_username, code, allocator = allocator)
}

// Read reactions must not stall the agent read route behind a slow provider.
TELEGRAM_REACTION_TIMEOUT_MS :: 1000

// Feedback requests use the same request path and safe errors as text.
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
	resp, err := telegram_request((^Telegram_Adapter)(ctx), "setMessageReaction", .POST, nil, body, TELEGRAM_REACTION_TIMEOUT_MS)
	defer httpc.response_destroy(&resp)
	return err
}

TELEGRAM_MEDIA_FETCH_MAX_BYTES :: 20_000_000
TELEGRAM_MEDIA_CAPTION_MAX_RUNES :: 1024

TELEGRAM_MEDIA_SEND_RULES := [?]Media_Send_Rule{
	{.Image, {"image/jpeg", "image/png"}, 10_000_000, true},
	{.Voice, {"audio/ogg"}, 50_000_000, true},
	{.Audio, {"audio/mpeg", "audio/mp4"}, 50_000_000, true},
	{.Document, nil, 50_000_000, true},
}

// Presence decides precedence, even when the selected field is malformed.
// Only the final selected file owns allocations in the batch allocator.
telegram_inbound_media :: proc(m: json.Object, allocator: mem.Allocator) -> Inbound_Media {
	file: json.Object
	kind: Media_Kind
	default_mime := ""
	selected := ""
	for field in ([]string{"photo", "document", "voice", "audio", "video", "video_note"}) {
		value, present := m[field]
		if !present do continue
		selected = field
		switch field {
		case "photo":
			photos, _ := value.(json.Array)
			largest: i64 = -1
			for photo in photos {
				obj, _ := photo.(json.Object)
				width, _ := obj["width"].(json.Integer)
				height, _ := obj["height"].(json.Integer)
				// Telegram dimensions are positive; avoid overflow on malformed input.
				if width < 0 || height < 0 || (height > 0 && width > max(i64)/height) do continue
				area := width*height
				if area >= largest { largest = area; file = obj }
			}
			kind = .Image; default_mime = "image/jpeg"
		case "document": file, _ = value.(json.Object); kind = .Document
		case "voice": file, _ = value.(json.Object); kind = .Voice; default_mime = "audio/ogg"
		case "audio": file, _ = value.(json.Object); kind = .Audio
		case "video": file, _ = value.(json.Object); kind = .Document; default_mime = "video/mp4"
		case "video_note": file, _ = value.(json.Object); kind = .Document; default_mime = "video/mp4"
		}
		break
	}
	ref, _ := file["file_id"].(string)
	if ref == "" do return {}
	name, _ := file["file_name"].(string)
	mime, _ := file["mime_type"].(string)
	if kind == .Image { name = ""; mime = "image/jpeg" }
	if selected == "voice" do name = ""
	if selected == "video_note" { name = ""; mime = "video/mp4" }
	if semi := strings.index(mime, ";"); semi >= 0 do mime = mime[:semi]
	mime = strings.to_lower(strings.trim_space(mime), context.temp_allocator)
	if mime == "" do mime = default_mime
	size, _ := file["file_size"].(json.Integer)
	return {kind, strings.clone(ref, allocator), strings.clone(name, allocator), strings.clone(mime, allocator), size}
}

telegram_media_fetch :: proc(ctx: rawptr, file_ref: string, max_bytes: i64, allocator := context.allocator) -> (Fetched_Media, Channel_Error) {
	started := time.tick_now()
	if max_bytes < 0 || max_bytes >= i64(max(int)) do return {}, {kind = .Invalid_Request, message = "invalid telegram media limit"}
	t := (^Telegram_Adapter)(ctx)
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return {}, {kind = .Transient, message = "telegram allocation failed"}
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	body := httpc.json_body(struct {file_id: string}{file_ref}, allocator = context.temp_allocator)
	meta, err := telegram_request(t, "getFile", .POST, nil, body, 5_000)
	defer httpc.response_destroy(&meta)
	if meta.status == 400 do return {}, {kind = .Media_Unavailable, message = "telegram file unavailable"}
	if err.kind != .None do return {}, err
	data: struct {result: struct {file_path: string, file_size: i64}}
	if json.unmarshal(meta.body, &data, allocator = context.temp_allocator) != nil do return {}, {kind = .Transient, message = "invalid telegram file response"}
	if data.result.file_path == "" do return {}, {kind = .Media_Unavailable, message = "telegram file unavailable"}
	if data.result.file_size > max_bytes do return {}, {kind = .Media_Too_Large, message = "telegram file too large"}
	remaining := MEDIA_PROVIDER_BUDGET_MS - int(time.tick_since(started)/time.Millisecond)
	if remaining < 1_000 do return {}, {kind = .Transient, message = "telegram media budget exhausted"}
	base, base_err := httpc.parse_url(t.api_base)
	if base_err != .None do return {}, {kind = .Invalid_Request, message = "invalid telegram API base"}
	path := make([dynamic]string, 0, 8, context.temp_allocator)
	append(&path, "file", fmt.tprintf("bot%s", t.token))
	for segment in strings.split(data.result.file_path, "/", context.temp_allocator) do append(&path, segment)
	resp, transport := httpc.send({url = base, path = path[:], timeout_ms = remaining, max_response_bytes = int(max_bytes+1)})
	defer httpc.response_destroy(&resp)
	if transport == .Too_Large || i64(len(resp.body)) > max_bytes do return {}, {kind = .Media_Too_Large, message = "telegram file too large"}
	if resp.status == 404 do return {}, {kind = .Media_Unavailable, message = "telegram file unavailable"}
	if transport != .None || resp.status < 200 || resp.status >= 300 do return {}, {kind = .Transient, message = "telegram download failed"}
	bytes := make([]byte, len(resp.body), allocator)
	copy(bytes, resp.body)
	return {bytes = bytes}, {}
}

telegram_send_media :: proc(ctx: rawptr, external_chat_id: string, media: Outbound_Media, timeout_ms: int) -> (string, Channel_Error) {
	chat_id, valid := strconv.parse_i64(external_chat_id)
	if !valid do return "", {kind = .Invalid_Request, message = "invalid telegram chat"}
	method, field: string
	switch media.kind {
	case .Image: method = "sendPhoto"; field = "photo"
	case .Document: method = "sendDocument"; field = "document"
	case .Voice: method = "sendVoice"; field = "voice"
	case .Audio: method = "sendAudio"; field = "audio"
	case .None: return "", {kind = .Invalid_Request, message = "invalid telegram media"}
	}
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return "", {kind = .Transient, message = "telegram allocation failed"}
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	chat := fmt.tprintf("%d", chat_id)
	parts := [3]httpc.Multipart_Part{
		{name = "chat_id", value = transmute([]byte)chat},
		{name = field, filename = media.name, content_type = media.mime, value = media.bytes},
		{name = "caption", value = transmute([]byte)media.caption},
	}
	count := 3 if media.caption != "" else 2
	body := httpc.multipart_body(parts[:count], allocator = context.temp_allocator)
	resp, err := telegram_request((^Telegram_Adapter)(ctx), method, .POST, nil, body, clamp(timeout_ms, 1, MEDIA_PROVIDER_BUDGET_MS))
	defer httpc.response_destroy(&resp)
	if err.kind != .None do return "", err
	data: struct {result: struct {message_id: i64}}
	if json.unmarshal(resp.body, &data, allocator = context.temp_allocator) != nil do return "", {kind = .Transient, message = "invalid telegram message response"}
	return strings.clone(fmt.tprintf("%d", data.result.message_id)), {}
}
