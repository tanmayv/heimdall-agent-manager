package bots

import "core:fmt"
import "core:log"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import channel "odin_test:hub/service/channel"

BOT_MEDIA_NAME_MAX_BYTES :: 200
BOT_MEDIA_MIME_MAX_BYTES :: 127
MEDIA_SEND_REQUEST_BUDGET_MS :: 17_000
MEDIA_SEND_MIN_CALL_MS :: 1_000
// The web UI is hash-routed: the artifact viewer lives at <ui_origin>/#/library/artifacts/<id>.
ARTIFACT_UI_ROUTE_PREFIX :: "/#/library/artifacts/"

bots_media_limit :: proc(a: ^channel.Channel_Adapter) -> i64 {
	if a == nil || a.media_fetch == nil do return 0
	return max(0, min(a.media.fetch_max_bytes, i64(contracts.ARTIFACT_MAX_CONTENT_BYTES)))
}

bots_media_mime :: proc(kind: channel.Media_Kind, mime: string) -> string {
	base := mime
	for c, i in mime do if c == ';' {base = mime[:i]; break}
	normalized := strings.to_lower(strings.trim_space(base), context.temp_allocator)
	slash := -1
	valid := len(normalized) > 0 && len(normalized) <= BOT_MEDIA_MIME_MAX_BYTES
	for c, i in transmute([]byte)normalized {
		if c == '/' {
			if slash >= 0 || i == 0 || i == len(normalized)-1 {valid = false; break}
			slash = i
			continue
		}
		alnum := c >= 'a' && c <= 'z' || c >= '0' && c <= '9'
		if i == 0 || i == slash+1 {
			if !alnum do valid = false
		} else if !alnum && !strings.contains_rune("!#$&^_.+-", rune(c)) do valid = false
	}
	if valid && slash > 0 do return normalized
	#partial switch kind {
	case .Image: return "image/jpeg"
	case .Voice: return "audio/ogg"
	case .Audio: return "audio/mpeg"
	}
	return "application/octet-stream"
}

bots_media_name :: proc(kind: channel.Media_Kind, name, mime: string) -> string {
	if utf8.valid_string(name) {
		bytes := make([]byte, len(name), context.temp_allocator)
		copy(bytes, transmute([]byte)name)
		for &c in bytes do if c == '/' || c == '\\' || c < 0x20 || c == 0x7f do c = '_'
		clean := strings.trim(string(bytes), " .")
		if len(clean) > BOT_MEDIA_NAME_MAX_BYTES {
			cut := BOT_MEDIA_NAME_MAX_BYTES
			for cut > 0 && (clean[cut] & 0xc0) == 0x80 do cut -= 1
			clean = clean[:cut]
		}
		if clean != "" do return clean
	}
	base := "file"
	#partial switch kind {
	case .Image: base = "photo"
	case .Voice: base = "voice"
	case .Audio: base = "audio"
	case .Document: if strings.has_prefix(mime, "video/") do base = "video"
	}
	ext := ""
	switch mime {
	case "image/jpeg": ext = ".jpg"
	case "image/png": ext = ".png"
	case "image/webp": ext = ".webp"
	case "image/gif": ext = ".gif"
	case "audio/ogg": ext = ".ogg"
	case "audio/mpeg": ext = ".mp3"
	case "audio/mp4": ext = ".m4a"
	case "audio/aac": ext = ".aac"
	case "audio/amr": ext = ".amr"
	case "video/mp4": ext = ".mp4"
	case "video/3gpp": ext = ".3gp"
	case "video/quicktime": ext = ".mov"
	case "application/pdf": ext = ".pdf"
	case "text/plain": ext = ".txt"
	}
	return strings.concatenate({base, ext}, context.temp_allocator)
}

bots_media_sniff_image :: proc(bytes: []byte, fallback: string) -> string {
	if len(bytes) >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff do return "image/jpeg"
	if len(bytes) >= 8 && string(bytes[:8]) == "\x89PNG\r\n\x1a\n" do return "image/png"
	if len(bytes) >= 12 && string(bytes[:4]) == "RIFF" && string(bytes[8:12]) == "WEBP" do return "image/webp"
	if len(bytes) >= 4 && string(bytes[:4]) == "GIF8" do return "image/gif"
	return fallback
}

bots_media_kind_for_mime :: proc(mime: string) -> channel.Media_Kind {
	if strings.has_prefix(mime, "image/") do return .Image
	if mime == "audio/ogg" do return .Voice
	if strings.has_prefix(mime, "audio/") do return .Audio
	return .Document
}

Bot_Media_Mode :: enum { Native, Link }
Bot_Media_Plan :: struct {mode: Bot_Media_Mode, rules: [dynamic]channel.Media_Send_Rule, reason: string}
bots_media_plan :: proc(a: ^channel.Channel_Adapter, binding: domain.Channel_Binding, mime: string, size: i64, now_ms: i64) -> Bot_Media_Plan {
	if a == nil || a.send_media == nil || len(a.media.send_rules) == 0 do return {mode = .Link, reason = "no_native_media"}
	if bots_window_closed(a, binding, now_ms) do return {mode = .Link, reason = "window_closed"}
	rules := make([dynamic]channel.Media_Send_Rule, context.temp_allocator)
	type_matches := false
	for rule in a.media.send_rules {
		matches := rule.mimes == nil
		for m in rule.mimes do if m == mime do matches = true
		if !matches do continue
		type_matches = true
		if size <= rule.max_bytes do append(&rules, rule)
	}
	if len(rules) == 0 do return {mode = .Link, reason = "too_large" if type_matches else "unsupported_type"}
	return {mode = .Native, rules = rules}
}

Bot_Media_Fetch :: struct {
	outcome: string,
	attachment: domain.Channel_Attachment,
	bytes: []byte,
	mime: string,
	error_kind: string,
}
bot_media_fetch_destroy :: proc(f: ^Bot_Media_Fetch) {
	domain.channel_attachment_destroy(&f.attachment)
	delete(f.bytes)
	delete(f.mime)
	delete(f.error_kind)
	f^ = {}
}

// Returns owned snapshots. Validation is shared with storing an artifact.
bots_media_attachment :: proc(s: ^Bots_Service, bot: domain.Bot, id: string) -> (domain.Channel_Attachment, domain.Channel_Binding, domain.Domain_Error) {
	if fence := bots_legacy_guard(s, bot.owner_user_id); fence.code != .None do return {}, {}, fence
	att, found, err := iface.attachment_get(s.repo, id)
	if err.code != .None do return att, {}, err
	if !found || att.bot_id != bot.bot_id || att.direction != .Inbound do return att, {}, bots_detail_error(.Not_Found, "media_not_found")
	binding, paired, be := iface.binding_get(s.repo, att.binding_id)
	if be.code != .None do return att, binding, be
	if !paired || binding.state != .Active || binding.owner_user_id != bot.owner_user_id do return att, binding, bots_detail_error(.Not_Found, "media_not_found")
	return att, binding, {}
}

bots_media_fetch :: proc(s: ^Bots_Service, bot: domain.Bot, attachment_id: string) -> (Bot_Media_Fetch, domain.Domain_Error) {
	att, binding, err := bots_media_attachment(s, bot, attachment_id)
	defer domain.channel_binding_destroy(&binding)
	result := Bot_Media_Fetch{attachment = att}
	if err.code != .None do return result, err
	#partial switch att.state {
	case .Stored: result.outcome = "stored"; return result, {}
	case .Too_Large: result.outcome = "too_large"; return result, {}
	case .Unavailable: result.outcome = "unavailable"; return result, {}
	}
	a := bots_adapter(s, binding.provider)
	limit := bots_media_limit(a)
	if limit == 0 do return result, domain.domain_error(.Provider_Unavailable, fmt.tprintf("%s is not configured on this hub", binding.provider), `{"code":"channel_not_configured"}`)
	f: channel.Fetched_Media
	e: channel.Channel_Error
	if att.size_bytes > limit {
		e.kind = .Media_Too_Large
	} else {
		if !bots_legacy_provider_admit(s, binding.owner_user_id) do return result, bots_detail_error(.Conflict, "bot_generation_inactive")
		f, e = a.media_fetch(a.ctx, att.file_ref, limit)
	}
	defer {delete(f.bytes); delete(f.mime)}
	#partial switch e.kind {
	case .None:
		result.outcome = "fetched"
		// Transfer bytes without copying; response destruction frees them exactly once.
		result.bytes = f.bytes; f.bytes = nil
		mime := bots_media_mime(channel.Media_Kind(att.kind), f.mime if f.mime != "" else att.mime)
		if att.kind == .Image do mime = bots_media_sniff_image(result.bytes, mime)
		result.mime = strings.clone(mime)
		log.info(fmt.tprintf("bots: media fetched attachment=%s kind=%s bytes=%d", attachment_id, domain.channel_media_kind_text(att.kind), len(result.bytes)))
	case .Media_Too_Large, .Media_Unavailable:
		state: domain.Channel_Attachment_State = .Too_Large if e.kind == .Media_Too_Large else .Unavailable
		changed, se := iface.attachment_set_state(s.repo, attachment_id, .Pending, state, platform.clock_now(s.clock))
		if se.code != .None do return result, se
		result.attachment.state = state
		result.outcome = "too_large" if state == .Too_Large else "unavailable"
		if changed && state == .Too_Large do bots_notice(s, binding.provider, binding.external_chat_id, COPY_MEDIA_TOO_LARGE, binding.owner_user_id)
	case:
		result.outcome = "failed"
		result.error_kind = strings.clone(fmt.tprintf("%v", e.kind))
		log.info(fmt.tprintf("bots: media fetch failed attachment=%s kind=%v", attachment_id, e.kind))
	}
	return result, {}
}

bots_media_stored :: proc(s: ^Bots_Service, bot: domain.Bot, attachment_id, artifact_id: string) -> (string, domain.Domain_Error) {
	att, binding, err := bots_media_attachment(s, bot, attachment_id)
	defer domain.channel_attachment_destroy(&att)
	defer domain.channel_binding_destroy(&binding)
	if err.code != .None do return "", err
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	if fence := bots_legacy_guard(s, bot.owner_user_id); fence.code != .None do return "", fence
	id, se := iface.attachment_store_artifact(s.repo, attachment_id, artifact_id, platform.clock_now(s.clock))
	if se.code != .None do return id, se
	if id == "" do return id, bots_detail_error(.Conflict, "media_not_pending")
	return id, {}
}

bots_media_link_text :: proc(s: ^Bots_Service, caption, name, artifact_id: string) -> string {
	label := name if name != "" else COPY_MEDIA_DEFAULT_LINK_NAME
	origin := strings.trim_right(s.ui_origin, "/")
	line := ""
	if origin != "" {
		url := strings.concatenate({origin, ARTIFACT_UI_ROUTE_PREFIX, artifact_id}, context.temp_allocator)
		line = fmt.tprintf(COPY_MEDIA_LINK_FORMAT, label, url)
	} else {line = fmt.tprintf(COPY_MEDIA_LINK_NO_ORIGIN_FORMAT, label, artifact_id)}
	if caption == "" do return line
	return strings.concatenate({caption, "\n\n", line}, context.temp_allocator)
}

Bot_Outbound_Media :: struct {artifact_id, name, mime: string, size: i64, bytes: []byte}
bots_media_send_text :: proc(a: ^channel.Channel_Adapter, chat, text: string, timeout_ms: int) -> (string, channel.Channel_Error) {
	if a.send_text_within != nil do return a.send_text_within(a.ctx, chat, text, timeout_ms)
	return a.send_text(a.ctx, chat, text)
}
bots_media_budget_error :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Provider_Unavailable, "channel send failed", `{"code":"channel_send_failed","kind":"Budget_Exhausted"}`)
}

channel_send_media :: proc(s: ^Bots_Service, binding: domain.Channel_Binding, caption: string, media: Bot_Outbound_Media) -> (message_ids: []string, held: bool, sent_as: string, unsent: int, err: domain.Domain_Error) {
	if fence := bots_legacy_guard(s, binding.owner_user_id); fence.code != .None do return nil, false, "", 0, fence
	budget := s.media_send_budget_ms
	if budget == 0 do budget = MEDIA_SEND_REQUEST_BUDGET_MS
	min_call := s.media_min_call_ms
	if min_call == 0 do min_call = MEDIA_SEND_MIN_CALL_MS
	started := time.tick_now()
	a := bots_adapter(s, binding.provider)
	if a == nil do return nil, false, "", 0, domain.domain_error(.Provider_Unavailable, fmt.tprintf("%s is not configured on this hub", binding.provider), `{"code":"channel_not_configured"}`)
	if !utf8.valid_string(caption) do return nil, false, "", 0, bots_detail_error(.Validation_Failed, "text_invalid")
	plan := bots_media_plan(a, binding, media.mime, media.size, bots_now_ms(s))
	if media.bytes == nil && plan.mode == .Native {plan.mode = .Link; plan.reason = "not_uploaded"}
	separate := false
	if caption != "" {
		separate = utf8.rune_count(caption) > a.media.caption_max_runes
		for rule in plan.rules do if !rule.caption do separate = true
	}
	kind := bots_media_kind_for_mime(media.mime)
	link := bots_media_link_text(s, caption, media.name, media.artifact_id)
	bodies := make([dynamic]string, context.temp_allocator)
	if plan.mode == .Link {
		chunks := channel_text_chunks(link); defer delete(chunks)
		append(&bodies, ..chunks)
	} else {
		append(&bodies, bots_media_link_text(s, "" if separate else caption, media.name, media.artifact_id))
		if separate {
			chunks := channel_text_chunks(caption); defer delete(chunks)
			append(&bodies, ..chunks)
		}
	}
	ids := make([]string, len(bodies))
	message_ids = ids
	defer bots_publish_changed(s, binding.owner_user_id, binding.bot_id)
	{
		sync.mutex_lock(&s.mutex)
		defer sync.mutex_unlock(&s.mutex)
		if fence := bots_legacy_guard(s, binding.owner_user_id); fence.code != .None {delete(ids); return nil, false, "", 0, fence}
		recorded := 0
		for body, i in bodies {
			id := strings.clone(platform.generate_id(s.ids, "chm_"))
			att: domain.Channel_Attachment
			if plan.mode == .Native && i == 0 || plan.mode == .Link && i == len(bodies)-1 {
				att = {attachment_id = platform.generate_id(s.ids, "cha_"), kind = domain.Channel_Media_Kind(kind),
					name = media.name, mime = media.mime, size_bytes = media.size, artifact_id = media.artifact_id,
					state = .Native if plan.mode == .Native else .Link}
			}
			e := iface.message_insert_outbound(s.repo, {
				message_id = id, binding_id = binding.binding_id, owner_user_id = binding.owner_user_id,
				bot_id = binding.bot_id, direction = .Outbound, body = body, attachment = att,
				send_state = .Held if plan.reason == "window_closed" else .Pending, created_at = platform.clock_now(s.clock)})
			if e.code != .None {
				delete(id)
				for previous in ids[:recorded] do _ = iface.message_set_send_result(s.repo, previous, .Failed, "", "not_sent")
				// Keep the returned allocation's exact length for the caller's delete.
				for previous in ids[:recorded] do delete(previous)
				delete(ids)
				return nil, false, "", 0, e
			}
			ids[i] = id
			recorded += 1
		}
	}
	if plan.reason == "window_closed" {
		log.info(fmt.tprintf("bots: reply held binding=%s chunks=%d", binding.binding_id, len(ids)))
		log.info(fmt.tprintf("bots: media sent as link binding=%s kind=%s reason=window_closed", binding.binding_id, domain.channel_media_kind_text(domain.Channel_Media_Kind(kind))))
		bots_reengage(s, binding.binding_id)
		return ids, true, "link", 0, {}
	}
	native := false
	text_start := 0
	if plan.mode == .Native {
		refused := true
		for rule in plan.rules {
			left := int(budget - i64(time.tick_since(started) / time.Millisecond))
			if i64(left) < min_call {refused = false; break}
			id: string
			e: channel.Channel_Error = {kind = .Aborted}
			if bots_legacy_provider_admit(s, binding.owner_user_id) {
				id, e = a.send_media(a.ctx, binding.external_chat_id, {rule.kind, media.name, media.mime, media.bytes, "" if separate else caption}, left)
			}
			defer delete(id)
			if e.kind == .None {
				if se := iface.message_set_send_result(s.repo, ids[0], .Sent, id, ""); se.code != .None do return ids, false, "", 0, se
				native = true
				text_start = 1
				log.info(fmt.tprintf("bots: media sent binding=%s kind=%s as=native", binding.binding_id, domain.channel_media_kind_text(domain.Channel_Media_Kind(kind))))
				break
			}
			if e.kind == .Invalid_Request do continue
			if e.kind == .Window_Closed {
				for row_id in ids {
					if se := iface.message_set_send_result(s.repo, row_id, .Held, "", ""); se.code != .None do return ids, false, "", 0, se
				}
				log.info(fmt.tprintf("bots: reply held binding=%s chunks=%d", binding.binding_id, len(ids)))
				bots_reengage(s, binding.binding_id)
				return ids, true, "link", 0, {}
			}
			_ = iface.message_set_send_result(s.repo, ids[0], .Failed, "", fmt.tprintf("%v", e.kind))
			for row_id in ids[1:] do _ = iface.message_set_send_result(s.repo, row_id, .Failed, "", "not_sent")
			return ids, false, "", 0, bots_send_error(e.kind)
		}
		if !native {
			if !refused {
				_ = iface.message_set_send_result(s.repo, ids[0], .Failed, "", "budget_exhausted")
				for row_id in ids[1:] do _ = iface.message_set_send_result(s.repo, row_id, .Failed, "", "not_sent")
				return ids, false, "", 0, bots_media_budget_error()
			}
			attachments, ae := iface.attachments_for_messages(s.repo, ids[:1])
			defer {for &att in attachments do domain.channel_attachment_destroy(&att); delete(attachments)}
			if ae.code != .None do return ids, false, "", 0, ae
			for att in attachments {
				if _, se := iface.attachment_set_state(s.repo, att.attachment_id, .Native, .Link, platform.clock_now(s.clock)); se.code != .None do return ids, false, "", 0, se
			}
			plan.reason = "refused"
		}
	}
	delivered := 1 if native else 0
	first_error: domain.Domain_Error
	for i := text_start; i < len(ids); i += 1 {
		left := int(budget - i64(time.tick_since(started) / time.Millisecond))
		if i64(left) < min_call {
			for row_id in ids[i:] do _ = iface.message_set_send_result(s.repo, row_id, .Failed, "", "not_sent")
			unsent = len(ids)-i
			first_error = bots_media_budget_error()
			break
		}
		id: string
		e: channel.Channel_Error = {kind = .Aborted}
		if bots_legacy_provider_admit(s, binding.owner_user_id) {
			id, e = bots_media_send_text(a, binding.external_chat_id, bodies[i], left)
		}
		defer delete(id)
		if e.kind == .None {
			if se := iface.message_set_send_result(s.repo, ids[i], .Sent, id, ""); se.code != .None do return ids, false, "", 0, se
			delivered += 1
			continue
		}
		if e.kind == .Window_Closed {
			for row_id in ids[i:] {
				if se := iface.message_set_send_result(s.repo, row_id, .Held, "", ""); se.code != .None do return ids, false, "", 0, se
			}
			log.info(fmt.tprintf("bots: reply held binding=%s chunks=%d", binding.binding_id, len(ids)-i))
			bots_reengage(s, binding.binding_id)
			held = true
			break
		}
		_ = iface.message_set_send_result(s.repo, ids[i], .Failed, "", fmt.tprintf("%v", e.kind))
		for row_id in ids[i+1:] do _ = iface.message_set_send_result(s.repo, row_id, .Failed, "", "not_sent")
		unsent = len(ids)-i
		first_error = bots_send_error(e.kind)
		break
	}
	if delivered == 0 && !held do return ids, false, "", unsent, first_error
	sent_as = "native" if native else "link"
	if !native do log.info(fmt.tprintf("bots: media sent as link binding=%s kind=%s reason=%s", binding.binding_id, domain.channel_media_kind_text(domain.Channel_Media_Kind(kind)), plan.reason))
	return ids, held, sent_as, unsent, {}
}
