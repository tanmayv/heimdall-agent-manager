package channel

import "base:runtime"
import "core:crypto"
import "core:crypto/hmac"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:strconv"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"
import platform "odin_test:hub/platform"
import httpc "odin_test:lib/httpc"

WHATSAPP_GRAPH_VERSION :: "v27.0"
WHATSAPP_DEFAULT_API_BASE :: "https://graph.facebook.com"
WHATSAPP_REENGAGE_TEMPLATE_NAME :: "ninjy_reply_waiting"
WHATSAPP_REENGAGE_TEMPLATE_LANGUAGE :: "en"
WHATSAPP_PAIRING_PREFIX :: "Connect Ninjy"
WHATSAPP_REPLY_WINDOW_MS :: 86_400_000
WHATSAPP_FEEDBACK_TIMEOUT_MS :: 1000
WHATSAPP_MEDIA_FETCH_MAX_BYTES :: 100_000_000
WHATSAPP_MEDIA_CAPTION_MAX_RUNES :: 1024
WHATSAPP_MEDIA_UPLOAD_TIMEOUT_MS :: 12_000
WHATSAPP_MEDIA_SEND_RULES := [?]Media_Send_Rule{
	{.Image, {"image/jpeg", "image/png", "image/webp"}, 5_000_000, true},
	{.Voice, {"audio/ogg"}, 16_000_000, false},
	{.Audio, {"audio/aac", "audio/amr", "audio/mpeg", "audio/mp4"}, 16_000_000, false},
	{.Document, {"text/plain", "application/pdf", "application/msword",
		"application/vnd.openxmlformats-officedocument.wordprocessingml.document",
		"application/vnd.ms-excel", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
		"application/vnd.ms-powerpoint", "application/vnd.openxmlformats-officedocument.presentationml.presentation"}, 100_000_000, true},
}
WHATSAPP_SEND_TIMEOUT_MS :: 15_000
WHATSAPP_IDENTITY_TIMEOUT_MS :: 10_000
WHATSAPP_PAIR_RATE_RETRY_MS :: 6000
WHATSAPP_THROUGHPUT_RETRY_MS :: 5000

WhatsApp_Adapter :: struct {
	access_token, app_secret, verify_token: string, // borrowed; never in diagnostics
	phone_number_id, business_account_id:   string,
	api_base:                               string,
	mutex:                                  sync.Mutex,
	cached_identity:                        Identity, // heap-owned
}

whatsapp_adapter :: proc(w: ^WhatsApp_Adapter) -> Channel_Adapter {
	return {
		media = {WHATSAPP_MEDIA_FETCH_MAX_BYTES, WHATSAPP_MEDIA_CAPTION_MAX_RUNES, WHATSAPP_MEDIA_SEND_RULES[:]},
		media_fetch = whatsapp_media_fetch,
		send_media = whatsapp_send_media,
		send_text_within = whatsapp_send_text_within,
		ctx = w,
		provider = "whatsapp",
		send_text = whatsapp_send_text,
		react = whatsapp_react,
		identity = whatsapp_identity,
		pairing_url = whatsapp_pairing_url,
		pairing_text = whatsapp_pairing_text,
		push_challenge = whatsapp_push_challenge,
		push_parse = whatsapp_push_parse,
		mark_read = whatsapp_mark_read,
		send_reengage = whatsapp_send_reengage,
		failure_kind = whatsapp_failure_kind,
		reply_window_ms = WHATSAPP_REPLY_WINDOW_MS,
	}
}

// Stop all adapter users before destroying the identity cache.
whatsapp_destroy :: proc(w: ^WhatsApp_Adapter) {
	delete(w.cached_identity.bot_user_id, runtime.heap_allocator())
	delete(w.cached_identity.bot_username, runtime.heap_allocator())
	w.cached_identity = {}
}

whatsapp_failure_kind :: proc(provider_code: int) -> Channel_Error_Kind {
	switch provider_code {
	case 131047:
		return .Window_Closed
	case 132001, 132015, 132016:
		return .Template_Unavailable
	case 131056, 130429:
		return .Rate_Limited
	case 190, 368:
		return .Unauthorized
	case 131026, 131030:
		return .Chat_Unavailable
	case 0:
		return .Transient
	case:
		return .Invalid_Request
	}
}

whatsapp_error :: proc(status: int, transport: httpc.Error, code: int) -> Channel_Error {
	if transport == .Aborted do return {kind = .Aborted, message = "whatsapp request aborted"}
	if transport != .None do return {kind = .Transient, message = "whatsapp transport failed"}
	kind := whatsapp_failure_kind(code)
	// HTTP status takes precedence only at the positions specified in 8.5.
	switch {
	case status >= 500:
		kind = .Transient
	case code == 131047, code == 132001 || code == 132015 || code == 132016, code == 131056:
	case code == 130429 || status == 429:
		kind = .Rate_Limited
	case code == 190 || code == 368 || status == 401:
		kind = .Unauthorized
	case code == 131026 || code == 131030:
		kind = .Chat_Unavailable
	case status >= 400 && status < 500:
		kind = .Invalid_Request
	case:
		kind = .Transient
	}
	wait: i64
	if kind == .Rate_Limited do wait = WHATSAPP_PAIR_RATE_RETRY_MS if code == 131056 else WHATSAPP_THROUGHPUT_RETRY_MS
	return {kind = kind, retry_after_ms = wait, provider_code = code, message = "whatsapp request failed"}
}

// All provider descriptions and transport details are untrusted. Only fixed
// messages leave this helper; response bodies and URLs never enter diagnostics.
whatsapp_request :: proc(
	w: ^WhatsApp_Adapter,
	verb: httpc.Method,
	segments: []string,
	query: []httpc.Query_Param,
	body: httpc.Body,
	timeout_ms: int,
	cancel: ^bool = nil,
) -> (
	httpc.Response,
	Channel_Error,
) {
	if cancel != nil && sync.atomic_load(cancel) do return {}, whatsapp_error(0, .Aborted, 0)
	api_base := w.api_base if w.api_base != "" else WHATSAPP_DEFAULT_API_BASE
	base, parse_err := httpc.parse_url(api_base)
	if parse_err != .None do return {}, {kind = .Invalid_Request, message = "whatsapp request failed"}
	resp, transport := httpc.send(
		{
			method = verb,
			url = base,
			path = segments,
			query = query,
			body = body,
			headers = {{"Authorization", fmt.tprintf("Bearer %s", w.access_token)}},
			timeout_ms = timeout_ms,
			max_response_bytes = 1 << 20,
			cancel = cancel,
		},
	)
	if transport != .None do return resp, whatsapp_error(0, transport, 0)
	envelope: struct {
		error: struct {
			code: int,
		},
	}
	_ = json.unmarshal(resp.body, &envelope, allocator = context.temp_allocator)
	if resp.status < 200 || resp.status >= 300 || envelope.error.code != 0 do return resp, whatsapp_error(resp.status, .None, envelope.error.code)
	return resp, {}
}

whatsapp_invalid_response :: proc() -> Channel_Error {
	return {kind = .Transient, message = "invalid whatsapp response"}
}

// Returned identity is borrowed from the cache.
whatsapp_identity :: proc(ctx: rawptr) -> (Identity, Channel_Error) {
	w := (^WhatsApp_Adapter)(ctx)
	sync.mutex_lock(&w.mutex)
	defer sync.mutex_unlock(&w.mutex)
	if w.cached_identity.bot_user_id != "" do return w.cached_identity, {}
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return {}, whatsapp_invalid_response()
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	resp, err := whatsapp_request(
		w,
		.GET,
		{WHATSAPP_GRAPH_VERSION, w.phone_number_id},
		{{"fields", "display_phone_number,verified_name"}},
		nil,
		WHATSAPP_IDENTITY_TIMEOUT_MS,
	)
	defer httpc.response_destroy(&resp)
	if err.kind != .None do return {}, err
	data: struct {
		display_phone_number: string,
	}
	if json.unmarshal(resp.body, &data, allocator = context.temp_allocator) != nil do return {}, whatsapp_invalid_response()
	digits := make([dynamic]byte, 0, len(data.display_phone_number), context.temp_allocator)
	for c in transmute([]byte)data.display_phone_number {
		if c >= '0' && c <= '9' do append(&digits, c)
	}
	if len(digits) == 0 do return {}, {kind = .Transient, message = "invalid whatsapp identity"}
	w.cached_identity = {
		strings.clone(w.phone_number_id, runtime.heap_allocator()),
		strings.clone(string(digits[:]), runtime.heap_allocator()),
	}
	return w.cached_identity, {}
}

whatsapp_digits :: proc(s: string) -> bool {
	if len(s) == 0 do return false
	for c in transmute([]byte)s {
		if c < '0' || c > '9' do return false
	}
	return true
}

// Object and any formatted address are scoped to the caller's scratch arena.
whatsapp_address :: proc(chat_id: string) -> json.Object {
	o := make(json.Object, context.temp_allocator)
	o["messaging_product"] = "whatsapp"
	o["recipient_type"] = "individual"
	if whatsapp_digits(chat_id) do o["to"] = fmt.tprintf("+%s", chat_id)
	else do o["recipient"] = chat_id
	return o
}

whatsapp_send_body :: proc(
	w: ^WhatsApp_Adapter,
	body: json.Object,
	timeout: int,
	read := false,
) -> (
	string,
	Channel_Error,
) {
	resp, err := whatsapp_request(
		w,
		.POST,
		{WHATSAPP_GRAPH_VERSION, w.phone_number_id, "messages"},
		nil,
		httpc.json_body(body, allocator = context.temp_allocator),
		timeout,
	)
	defer httpc.response_destroy(&resp)
	if err.kind != .None do return "", err
	data: struct {
		success:  bool,
		messages: []struct {
			id: string,
		},
	}
	if json.unmarshal(resp.body, &data, allocator = context.temp_allocator) != nil do return "", whatsapp_invalid_response()
	if read {
		if !data.success do return "", whatsapp_invalid_response()
		return "", {}
	}
	if len(data.messages) == 0 || data.messages[0].id == "" do return "", whatsapp_invalid_response()
	return strings.clone(data.messages[0].id), {}
}

whatsapp_send_text :: proc(ctx: rawptr, external_chat_id: string, text: string) -> (string, Channel_Error) {
	return whatsapp_send_text_within(ctx, external_chat_id, text, WHATSAPP_SEND_TIMEOUT_MS)
}

whatsapp_send_text_within :: proc(ctx: rawptr, external_chat_id, text: string, timeout_ms: int) -> (string, Channel_Error) {
	if text == "" || len(text) > 4000 || !utf8.valid_string(text) do return "", {kind = .Invalid_Request, message = "invalid whatsapp message"}
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return "", whatsapp_invalid_response()
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	body := whatsapp_address(external_chat_id)
	body["type"] = "text"
	nested := make(json.Object, context.temp_allocator)
	nested["preview_url"] = false
	nested["body"] = text
	body["text"] = nested
	return whatsapp_send_body((^WhatsApp_Adapter)(ctx), body, clamp(timeout_ms, 1, WHATSAPP_SEND_TIMEOUT_MS))
}

whatsapp_send_reengage :: proc(ctx: rawptr, external_chat_id: string) -> (string, Channel_Error) {
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return "", whatsapp_invalid_response()
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	body := whatsapp_address(external_chat_id)
	body["type"] = "template"
	template := make(json.Object, context.temp_allocator)
	language := make(json.Object, context.temp_allocator)
	language["code"] = WHATSAPP_REENGAGE_TEMPLATE_LANGUAGE
	template["name"] = WHATSAPP_REENGAGE_TEMPLATE_NAME
	template["language"] = language
	body["template"] = template
	return whatsapp_send_body((^WhatsApp_Adapter)(ctx), body, WHATSAPP_SEND_TIMEOUT_MS)
}

whatsapp_mark_read :: proc(ctx: rawptr, external_chat_id, external_message_id: string) -> Channel_Error {
	if external_message_id == "" do return {kind = .Invalid_Request, message = "invalid whatsapp message"}
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return whatsapp_invalid_response()
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	body := make(json.Object, context.temp_allocator)
	body["messaging_product"] = "whatsapp"
	body["status"] = "read"
	body["message_id"] = external_message_id
	id, err := whatsapp_send_body((^WhatsApp_Adapter)(ctx), body, WHATSAPP_FEEDBACK_TIMEOUT_MS, true)
	delete(id)
	return err
}

whatsapp_react :: proc(ctx: rawptr, external_chat_id, external_message_id, emoji: string) -> Channel_Error {
	if external_message_id == "" do return {kind = .Invalid_Request, message = "invalid whatsapp message"}
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return whatsapp_invalid_response()
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	body := whatsapp_address(external_chat_id)
	body["type"] = "reaction"
	reaction := make(json.Object, context.temp_allocator)
	reaction["message_id"] = external_message_id
	reaction["emoji"] = emoji
	body["reaction"] = reaction
	id, err := whatsapp_send_body((^WhatsApp_Adapter)(ctx), body, WHATSAPP_FEEDBACK_TIMEOUT_MS)
	delete(id)
	return err
}

whatsapp_pairing_text :: proc(ctx: rawptr, code: string, allocator := context.allocator) -> string {
	return fmt.aprintf("%s %s", WHATSAPP_PAIRING_PREFIX, code, allocator = allocator)
}

whatsapp_pairing_url :: proc(ctx: rawptr, identity: Identity, code: string, allocator := context.allocator) -> string {
	return fmt.aprintf(
		"https://wa.me/%s?text=Connect%%20Ninjy%%20%s",
		identity.bot_username,
		code,
		allocator = allocator,
	)
}

whatsapp_push_challenge :: proc(ctx: rawptr, mode, verify_token: string) -> bool {
	w := (^WhatsApp_Adapter)(ctx)
	return(
		mode == "subscribe" &&
		len(verify_token) == len(w.verify_token) &&
		crypto.compare_constant_time(transmute([]byte)verify_token, transmute([]byte)w.verify_token) == 1 \
	)
}

whatsapp_object :: proc(v: json.Value) -> json.Object {
	o, _ := v.(json.Object)
	return o
}
whatsapp_array :: proc(v: json.Value) -> json.Array {
	a, _ := v.(json.Array)
	return a
}
whatsapp_string :: proc(v: json.Value) -> string {
	s, _ := v.(string)
	return s
}

whatsapp_provider_time :: proc(v: json.Value) -> string {
	s := whatsapp_string(v)
	seconds, ok := strconv.parse_i64(s)
	// Avoid overflowing the pinned time.Time nanosecond representation.
	if !ok || seconds > max(i64) / i64(time.Second) || seconds < min(i64) / i64(time.Second) do return ""
	return platform.format_rfc3339_utc(time.unix(seconds, 0))
}

whatsapp_push_parse :: proc(
	ctx: rawptr,
	signature_header, raw_body: string,
	allocator := context.allocator,
) -> (
	batch: []Inbound,
	verdict: Push_Verdict,
) {
	w := (^WhatsApp_Adapter)(ctx)
	if len(signature_header) != 71 || !strings.has_prefix(signature_header, "sha256=") do return nil, .Bad_Signature
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return nil, .Bad_Payload
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	tag, valid := hex.decode(transmute([]byte)signature_header[7:], context.temp_allocator)
	if !valid || len(tag) != 32 || !hmac.verify(.SHA256, tag, transmute([]byte)raw_body, transmute([]byte)w.app_secret) do return nil, .Bad_Signature
	value, parse_err := json.parse(raw_body, allocator = context.temp_allocator, parse_integers = false)
	root := whatsapp_object(value)
	if parse_err != .None || whatsapp_string(root["object"]) != "whatsapp_business_account" do return nil, .Bad_Payload
	rows := make([dynamic]Inbound, 0, 0, allocator)
	foreign_id := false
	for entry in whatsapp_array(root["entry"]) {
		e := whatsapp_object(entry)
		if whatsapp_string(e["id"]) != w.business_account_id {foreign_id = true; continue}
		for change in whatsapp_array(e["changes"]) {
			c := whatsapp_object(change)
			if whatsapp_string(c["field"]) != "messages" do continue
			v := whatsapp_object(c["value"])
			metadata := whatsapp_object(v["metadata"])
			if whatsapp_string(metadata["phone_number_id"]) != w.phone_number_id {foreign_id = true; continue}
			for message in whatsapp_array(v["messages"]) {
				m := whatsapp_object(message)
				chat, user := whatsapp_string(m["from"]), whatsapp_string(m["from_user_id"])
				if chat == "" do chat = user
				if user == "" do user = chat
				id := whatsapp_string(m["id"])
				if chat == "" || id == "" do continue
				kind: Inbound_Kind = .Unsupported
				text := ""
				media: Inbound_Media
				switch whatsapp_string(m["type"]) {
				case "reaction", "system", "edit", "revoke", "group":
					continue
				case "image", "document", "audio", "video":
					typ := whatsapp_string(m["type"])
					o := whatsapp_object(m[typ])
					ref := whatsapp_string(o["id"])
					if ref != "" {
						kind = .Media
						media.kind = .Document
						if typ == "image" do media.kind = .Image
						if typ == "audio" {
							voice, _ := o["voice"].(bool)
							media.kind = .Voice if voice else .Audio
						} else do text = whatsapp_string(o["caption"])
						media.file_ref = strings.clone(ref, allocator)
						if typ == "document" do media.name = strings.clone(whatsapp_string(o["filename"]), allocator)
						media.mime = strings.clone(whatsapp_media_mime(whatsapp_string(o["mime_type"])), allocator)
					}
				case "text":
					text = whatsapp_string(whatsapp_object(m["text"])["body"])
					trimmed := strings.trim_space(text)
					lower := strings.to_lower(trimmed, context.temp_allocator)
					prefix := "connect ninjy"
					is_start := lower == prefix
					if strings.has_prefix(lower, prefix) && len(lower) > len(prefix) {
						remainder := lower[len(prefix):]
						is_start = len(strings.trim_left_space(remainder)) < len(remainder)
					}
					if is_start {
						kind = .Start
						text = strings.trim_space(lower[len(prefix):])
					} else if lower == "disconnect" || lower == "/disconnect" {
						kind = .Disconnect; text = ""
					} else do kind = .Text
				}
				display := ""
				for contact in whatsapp_array(v["contacts"]) {
					co := whatsapp_object(contact)
					if whatsapp_string(co["user_id"]) != user && whatsapp_string(co["wa_id"]) != chat do continue
					profile := whatsapp_object(co["profile"])
					display = whatsapp_string(profile["name"])
					if display == "" do display = whatsapp_string(profile["username"])
					if display != "" do break
				}
				if display == "" do display = fmt.tprintf("+%s", chat) if whatsapp_digits(chat) else "WhatsApp user"
				append(
					&rows,
					Inbound {
						update_key = strings.clone(fmt.tprintf("whatsapp:%s:%s", w.phone_number_id, id), allocator),
						external_chat_id = strings.clone(chat, allocator),
						external_user_id = strings.clone(user, allocator),
						external_message_id = strings.clone(id, allocator),
						chat_is_private = true,
						sender_display = strings.clone(display, allocator),
						kind = kind,
						media = media,
						text = strings.clone(text, allocator),
						provider_time = strings.clone(whatsapp_provider_time(m["timestamp"]), allocator),
					},
				)
			}
			for status in whatsapp_array(v["statuses"]) {
				s := whatsapp_object(status)
				if whatsapp_string(s["status"]) != "failed" do continue
				id := whatsapp_string(s["id"])
				chat := whatsapp_string(s["recipient_id"])
				if chat == "" do chat = whatsapp_string(s["recipient_user_id"])
				errors := whatsapp_array(s["errors"])
				code: int
				if len(errors) > 0 {
					n, _ := whatsapp_object(errors[0])["code"].(json.Float)
					if n >= 0 && n <= f64(max(i32)) do code = int(n)
				}
				append(
					&rows,
					Inbound {
						kind = .Delivery_Failed,
						update_key = strings.clone(
							fmt.tprintf("whatsapp:%s:failed:%s", w.phone_number_id, id),
							allocator,
						),
						external_message_id = strings.clone(id, allocator),
						external_chat_id = strings.clone(chat, allocator),
						provider_code = code,
						provider_time = strings.clone(whatsapp_provider_time(s["timestamp"]), allocator),
					},
				)
			}
		}
	}
	if len(rows) == 0 {
		delete(rows)
		return nil, .Foreign_Account if foreign_id else .Accepted
	}
	shrink(&rows)
	return rows[:], .Accepted
}

// MIME strings below borrow their input or the current scratch arena.
whatsapp_media_mime :: proc(value: string) -> string {
	end := strings.index_byte(value, ';')
	base := value[:end] if end >= 0 else value
	return strings.to_lower(strings.trim_space(base), context.temp_allocator)
}

// Input is an httpc-validated absolute URL (no credentials or fragments).
// Normalize default ports before comparing API origins.
whatsapp_media_origin :: proc(u: httpc.Url) -> (scheme, authority, host: string) {
	raw := strings.to_lower(httpc.url_string(u), context.temp_allocator)
	split := strings.index(raw, "://")
	if split < 0 do return
	scheme = raw[:split]
	rest := raw[split+3:]
	end := len(rest)
	for c, i in rest { if c == '/' || c == '?' { end = i; break } }
	authority = rest[:end]
	default_port := ":443" if scheme == "https" else ":80"
	if strings.has_suffix(authority, default_port) do authority = authority[:len(authority)-len(default_port)]
	host = authority
	// IPv6 authorities can only match the configured API origin.
	if !strings.has_prefix(host, "[") {
		colon := strings.index_byte(host, ':')
		if colon >= 0 do host = host[:colon]
	}
	return
}

whatsapp_media_url_allowed :: proc(w: ^WhatsApp_Adapter, target: httpc.Url) -> bool {
	base_text := w.api_base if w.api_base != "" else WHATSAPP_DEFAULT_API_BASE
	base, err := httpc.parse_url(base_text)
	if err != .None do return false
	scheme, authority, host := whatsapp_media_origin(target)
	base_scheme, base_authority, _ := whatsapp_media_origin(base)
	if scheme == base_scheme && authority == base_authority do return true
	if scheme != "https" do return false
	for suffix in ([]string{".fbsbx.com", ".facebook.com", ".whatsapp.net"}) {
		if strings.has_suffix(host, suffix) do return true
	}
	return false
}

whatsapp_media_remaining :: proc(start: time.Tick, total: int) -> int {
	return total - int(time.duration_milliseconds(time.tick_since(start)))
}

whatsapp_media_fetch :: proc(ctx: rawptr, file_ref: string, max_bytes: i64, allocator := context.allocator) -> (Fetched_Media, Channel_Error) {
	w := (^WhatsApp_Adapter)(ctx)
	start := time.tick_now()
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return {}, whatsapp_invalid_response()
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	// Clamp before adding one to the bounded response; never overflow an int.
	limit := int(clamp(max_bytes, 0, WHATSAPP_MEDIA_FETCH_MAX_BYTES))
	resp, err := whatsapp_request(w, .GET, {WHATSAPP_GRAPH_VERSION, file_ref}, {{"phone_number_id", w.phone_number_id}}, nil, 5000)
	defer httpc.response_destroy(&resp)
	if err.kind != .None {
		if err.provider_code == 100 || (err.provider_code == 0 && (resp.status == 400 || resp.status == 404)) {
			return {}, {kind = .Media_Unavailable, message = "whatsapp media unavailable"}
		}
		return {}, err
	}
	metadata: struct { url, mime_type: string, file_size: i64 }
	if json.unmarshal(resp.body, &metadata, allocator = context.temp_allocator) != nil do return {}, whatsapp_invalid_response()
	if metadata.file_size > i64(limit) do return {}, {kind = .Media_Too_Large, message = "whatsapp media too large"}
	url, url_err := httpc.parse_url(metadata.url)
	if url_err != .None || !whatsapp_media_url_allowed(w, url) do return {}, {kind = .Invalid_Request, message = "whatsapp media url refused"}
	remaining := whatsapp_media_remaining(start, MEDIA_PROVIDER_BUDGET_MS)
	if remaining < 1000 do return {}, {kind = .Transient, message = "whatsapp media budget exhausted"}
	download, transport := httpc.send({url = url,
		headers = {{"Authorization", fmt.tprintf("Bearer %s", w.access_token)}},
		max_redirects = 0, max_response_bytes = limit + 1, timeout_ms = remaining})
	defer httpc.response_destroy(&download)
	if transport == .Too_Large || len(download.body) > limit do return {}, {kind = .Media_Too_Large, message = "whatsapp media too large"}
	if download.status == 404 do return {}, {kind = .Media_Unavailable, message = "whatsapp media unavailable"}
	if transport != .None || download.status < 200 || download.status >= 300 do return {}, {kind = .Transient, message = "whatsapp media download failed"}
	return {bytes = slice.clone(download.body, allocator), mime = strings.clone(whatsapp_media_mime(metadata.mime_type), allocator)}, {}
}

whatsapp_send_media :: proc(ctx: rawptr, external_chat_id: string, media: Outbound_Media, timeout_ms: int) -> (string, Channel_Error) {
	w := (^WhatsApp_Adapter)(ctx)
	total := clamp(timeout_ms, 1, MEDIA_PROVIDER_BUDGET_MS)
	start := time.tick_now()
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return "", whatsapp_invalid_response()
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	typ: string
	switch media.kind {
	case .Image: typ = "image"
	case .Document: typ = "document"
	case .Voice, .Audio: typ = "audio"
	case .None: return "", {kind = .Invalid_Request, message = "invalid whatsapp media"}
	}
	upload := httpc.multipart_body({
		{name = "messaging_product", value = transmute([]byte)string("whatsapp")},
		{name = "file", filename = media.name, content_type = media.mime, value = media.bytes},
	})
	resp, err := whatsapp_request(w, .POST, {WHATSAPP_GRAPH_VERSION, w.phone_number_id, "media"}, nil, upload,
		max(1, min(WHATSAPP_MEDIA_UPLOAD_TIMEOUT_MS, total - 1000)))
	defer httpc.response_destroy(&resp)
	if err.kind != .None do return "", err
	data: struct { id: string }
	if json.unmarshal(resp.body, &data, allocator = context.temp_allocator) != nil || data.id == "" do return "", whatsapp_invalid_response()
	remaining := whatsapp_media_remaining(start, total)
	if remaining < 1000 do return "", {kind = .Transient, message = "whatsapp media budget exhausted"}
	body := whatsapp_address(external_chat_id)
	body["type"] = typ
	nested := make(json.Object, context.temp_allocator)
	nested["id"] = data.id
	if media.kind == .Document do nested["filename"] = media.name
	if media.kind == .Voice do nested["voice"] = true
	if (media.kind == .Image || media.kind == .Document) && media.caption != "" do nested["caption"] = media.caption
	body[typ] = nested
	return whatsapp_send_body(w, body, remaining)
}
