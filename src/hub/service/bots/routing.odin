package bots

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Return an owned binding snapshot; release every unselected snapshot.
bots_reply_binding :: proc(s: ^Bots_Service, owner, bot_id: string) -> (domain.Channel_Binding, bool, domain.Domain_Error) {
	if fence := bots_legacy_guard(s, owner); fence.code != .None do return {}, false, fence
	active, err := iface.bindings_active_for_owner(s.repo, owner)
	defer {for &b in active do domain.channel_binding_destroy(&b); delete(active)}
	if err.code != .None || len(active) == 0 do return {}, false, err
	selected := 0
	matched := false
	pending, pending_err := iface.messages_pending(s.repo, bot_id, -1)
	defer {for &m in pending do domain.channel_message_destroy(&m); delete(pending)}
	if pending_err.code != .None do return {}, false, pending_err
	for m in pending {
		if m.direction != .Inbound || m.body_purged || m.read_at == "" do continue
		for b, i in active do if b.binding_id == m.binding_id {selected, matched = i, true; break}
		if matched do break
	}
	if !matched {
		history, history_err := iface.messages_history(s.repo, bot_id, -1)
		defer {for &m in history do domain.channel_message_destroy(&m); delete(history)}
		if history_err.code != .None do return {}, false, history_err
		for m in history {
			if m.direction != .Inbound || m.body_purged do continue
			for b, i in active do if b.binding_id == m.binding_id {selected, matched = i, true; break}
			if matched do break
		}
	}
	result := active[selected]
	active[selected] = {}
	return result, true, {}
}

bots_notice_binding :: proc(s: ^Bots_Service, owner, bot_id, through_message_id: string) -> (domain.Channel_Binding, bool, domain.Domain_Error) {
	if fence := bots_legacy_guard(s, owner); fence.code != .None do return {}, false, fence
	history, err := iface.messages_history(s.repo, bot_id, -1)
	defer {for &m in history do domain.channel_message_destroy(&m); delete(history)}
	if err.code != .None do return {}, false, err
	for m in history {
		if m.message_id != through_message_id || m.direction != .Inbound do continue
		binding, found, get_err := iface.binding_get(s.repo, m.binding_id)
		if get_err.code != .None do return binding, false, get_err
		if found && binding.state == .Active && binding.owner_user_id == owner && binding.bot_id == bot_id do return binding, true, {}
		domain.channel_binding_destroy(&binding)
		break
	}
	return bots_reply_binding(s, owner, bot_id)
}

// Return the oldest pending active channel, or the first active channel.
bots_read_binding :: proc(s: ^Bots_Service, owner, bot_id: string) -> (domain.Channel_Binding, bool, domain.Domain_Error) {
	if fence := bots_legacy_guard(s, owner); fence.code != .None do return {}, false, fence
	active, err := iface.bindings_active_for_owner(s.repo, owner)
	defer {for &b in active do domain.channel_binding_destroy(&b); delete(active)}
	if err.code != .None || len(active) == 0 do return {}, false, err
	pending, e := iface.messages_pending(s.repo, bot_id, -1)
	defer {for &m in pending do domain.channel_message_destroy(&m); delete(pending)}
	if e.code != .None do return {}, false, e
	selected := 0
	matched := false
	for m in pending {
		if m.direction != .Inbound || m.body_purged do continue
		for b, i in active do if b.binding_id == m.binding_id {selected, matched = i, true; break}
		if matched do break
	}
	result := active[selected]
	active[selected] = {}
	return result, true, {}
}
