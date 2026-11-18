package bots

import "core:encoding/json"
import "core:fmt"
import "core:strings"
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
channel_send :: proc(s: ^Bots_Service, binding: domain.Channel_Binding, text: string, record: bool) -> (message_ids: []string, err: domain.Domain_Error) {
	a := bots_adapter(s, binding.provider)
	if a == nil do return nil, domain.domain_error(.Provider_Unavailable, fmt.tprintf("%s is not configured on this hub", binding.provider), `{"code":"channel_not_configured"}`)
	if !utf8.valid_string(text) do return nil, domain.domain_error(.Validation_Failed, "text is invalid", `{"code":"text_invalid"}`)
	chunks := channel_text_chunks(text)
	defer delete(chunks)
	if len(chunks) == 0 do return nil, {}
	ids := make([dynamic]string)
	if record {
		for chunk in chunks {
			id := strings.clone(platform.generate_id(s.ids, "chm_"))
			insert_err := iface.message_insert_outbound(s.repo, {
				message_id = id, binding_id = binding.binding_id,
				owner_user_id = binding.owner_user_id, bot_id = binding.bot_id,
				direction = .Outbound, body = chunk, send_state = .Pending,
				created_at = platform.clock_now(s.clock),
			})
			if insert_err.code != .None {
				delete(id)
				for previous in ids {
					_ = iface.message_set_send_result(s.repo, previous, .Failed, "", "not_sent")
				}
				shrink(&ids)
				return ids[:], insert_err
			}
			append(&ids, id)
		}
	}
	for chunk, index in chunks {
		result: channel.Channel_Error
		external_id := ""
		rate_wait: i64
		for attempt in 0..<3 {
			external_id, result = a.send_text(a.ctx, binding.external_chat_id, chunk)
			if result.kind == .None do break
			delete(external_id)
			external_id = ""
			if attempt == 2 do break
			retry := true
			#partial switch result.kind {
			case .Transient:
				time.sleep(time.Duration(attempt + 1) * time.Second)
			case .Rate_Limited:
				wait := max(result.retry_after_ms, 0)
				if wait > 20_000 - rate_wait {
					retry = false
				} else {
					rate_wait += wait
					time.sleep(time.Duration(wait) * time.Millisecond)
				}
			case: retry = false
			}
			if !retry do break
		}
		if result.kind == .None {
			if record {
				err = iface.message_set_send_result(s.repo, ids[index], .Sent, external_id, "")
			}
			delete(external_id)
			if err.code == .None do continue
		} else {
			delete(external_id)
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
		return ids[:], err
	}
	shrink(&ids)
	return ids[:], {}
}
