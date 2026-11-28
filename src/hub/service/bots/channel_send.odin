package bots

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import channel "odin_test:hub/service/channel"

// Chunks borrow text; only the slice is owned. Include the delimiter so splitting
// preserves the exact plaintext, including whitespace.
channel_text_chunks :: proc(text: string, allocator := context.allocator) -> []string {
	remaining := text
	chunks := make([dynamic]string, allocator)
	for len(remaining) > 0 {
		cut := min(4000, len(remaining))
		if cut < len(remaining) {
			newline := strings.last_index_byte(remaining[:cut], '\n')
			space := strings.last_index_byte(remaining[:cut], ' ')
			if newline >= 0 { cut = newline + 1 } else if space >= 0 { cut = space + 1 } else {
				for cut > 0 && (remaining[cut] & 0xc0) == 0x80 do cut -= 1
			}
		}
		if cut > 0 do append(&chunks, remaining[:cut])
		remaining = remaining[cut:]
	}
	shrink(&chunks)
	return chunks[:]
}

// message_ids and each id belong to the caller, including on an error.
channel_send :: proc(s: ^Bots_Service, binding: domain.Channel_Binding, text: string, record: bool, action_ids_json := "") -> (message_ids: []string, held: bool, err: domain.Domain_Error) {
	if fence := bots_legacy_guard(s, binding.owner_user_id); fence.code != .None do return nil, false, fence
	a := bots_adapter(s, binding.provider)
	if a == nil do return nil, false, domain.domain_error(.Provider_Unavailable, fmt.tprintf("%s is not configured on this hub", binding.provider), `{"code":"channel_not_configured"}`)
	if !utf8.valid_string(text) do return nil, false, domain.domain_error(.Validation_Failed, "text is invalid", `{"code":"text_invalid"}`)
	chunks := channel_text_chunks(text)
	defer delete(chunks)
	if len(chunks) == 0 do return nil, false, {}
	closed := bots_window_closed(a, binding, bots_now_ms(s))
	if !record && closed do return nil, false, bots_send_error(.Window_Closed)
	ids := make([dynamic]string)
	state: domain.Channel_Send_State = .Pending
	if closed do state = .Held
	if record {
		// Publish after all send-state updates, including partial failures.
		defer bots_publish_changed(s, binding.owner_user_id, binding.bot_id)
		sync.mutex_lock(&s.mutex)
		defer sync.mutex_unlock(&s.mutex)
		if fence := bots_legacy_guard(s, binding.owner_user_id); fence.code != .None {delete(ids); return nil, false, fence}
		for chunk, i in chunks {
			id := strings.clone(platform.generate_id(s.ids, "chm_"))
			insert_err := iface.message_insert_outbound(s.repo, {
				message_id = id, binding_id = binding.binding_id,
				owner_user_id = binding.owner_user_id, bot_id = binding.bot_id,
				direction = .Outbound, body = chunk, send_state = state,
				created_at = platform.clock_now(s.clock),
				action_ids_json = action_ids_json if binding.provider == domain.CHANNEL_PROVIDER_WEB && i == len(chunks) - 1 else "",
			})
			if insert_err.code != .None {
				delete(id)
				for previous in ids {
					_ = iface.message_set_send_result(s.repo, previous, .Failed, "", "not_sent")
				}
				shrink(&ids)
				return ids[:], false, insert_err
			}
			append(&ids, id)
		}
	}
	if record && closed {
		log.info(fmt.tprintf("bots: reply held binding=%s chunks=%d", binding.binding_id, len(ids)))
		bots_reengage(s, binding.binding_id)
		shrink(&ids)
		return ids[:], true, {}
	}
	for chunk, index in chunks {
		external_id, result := bots_send_chunk(s, a, binding.external_chat_id, chunk, binding.owner_user_id)
		if result.kind == .None {
			if record {
				err = iface.message_set_send_result(s.repo, ids[index], .Sent, external_id, "")
			}
			delete(external_id)
			if err.code == .None do continue
		} else {
			delete(external_id)
			if record && result.kind == .Window_Closed {
				for id in ids[index:] {
					if e := iface.message_set_send_result(s.repo, id, .Held, "", ""); e.code != .None {shrink(&ids); return ids[:], false, e}
				}
				log.info(fmt.tprintf("bots: reply held binding=%s chunks=%d", binding.binding_id, len(ids)-index))
				bots_reengage(s, binding.binding_id)
				shrink(&ids)
				return ids[:], true, {}
			}
			if record {
				_ = iface.message_set_send_result(s.repo, ids[index], .Failed, "", fmt.tprintf("%v", result.kind))
			}
			details, _ := json.marshal(struct {code, kind: string}{"channel_send_failed", fmt.tprintf("%v", result.kind)}, allocator = context.temp_allocator)
			err = domain.domain_error(.Provider_Unavailable, "channel send failed", string(details))
		}
		if record {
			for id in ids[index+1:] {
				_ = iface.message_set_send_result(s.repo, id, .Failed, "", "not_sent")
			}
		}
		shrink(&ids)
		return ids[:], false, err
	}
	shrink(&ids)
	return ids[:], false, {}
}

// The caller owns external_message_id. Retry limits are shared by fresh and held sends.
bots_send_chunk :: proc(s: ^Bots_Service, a: ^channel.Channel_Adapter, chat_id, text: string, owner := "") -> (external_message_id: string, err: channel.Channel_Error) {
	result: channel.Channel_Error
	external_id := ""
	rate_wait: i64
	for attempt in 0..<3 {
		if !bots_legacy_provider_admit(s, owner) do return "", {kind = .Aborted}
		external_id, result = a.send_text(a.ctx, chat_id, text)
		if result.kind == .None do break
		delete(external_id)
		external_id = ""
		if attempt == 2 do break
		retry := true
		#partial switch result.kind {
		case .Transient: time.sleep(time.Duration(attempt + 1) * time.Second)
		case .Rate_Limited:
			wait := max(result.retry_after_ms, 0)
			if wait > 20_000 - rate_wait {retry = false} else {rate_wait += wait; time.sleep(time.Duration(wait) * time.Millisecond)}
		case: retry = false
		}
		if !retry do break
	}
	return external_id, result
}

bots_send_error :: proc(kind: channel.Channel_Error_Kind) -> domain.Domain_Error {
	details, _ := json.marshal(struct {code, kind: string}{"channel_send_failed", fmt.tprintf("%v", kind)}, allocator = context.temp_allocator)
	return domain.domain_error(.Provider_Unavailable, "channel send failed", string(details))
}
