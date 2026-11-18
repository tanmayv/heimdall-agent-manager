package bots

import "core:fmt"
import "core:log"
import "core:sync"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

BOT_READ_REACTION :: "👀"
// Stop admitting calls after four seconds. Telegram bounds each admitted call
// to one second, keeping feedback below the bridge relay's 20-second stall.
BOT_READ_REACTION_BUDGET :: 4 * time.Second

// Serializing selection and mark_read makes the unread snapshot authoritative
// across concurrent agent reads. The repository commits before feedback begins.
// Returned messages belong to the caller, including their strings.
bots_channel_read :: proc(s: ^Bots_Service, bot_id: string, binding: domain.Channel_Binding, limit: int) -> ([]domain.Channel_Message, int, domain.Domain_Error) {
	selected := make([dynamic]domain.Channel_Message)
	keep := false
	defer if !keep {
		for &m in selected do domain.channel_message_destroy(&m)
		delete(selected)
	}
	newly_read := make([dynamic]domain.Channel_Message, context.temp_allocator)
	total := 0
	{
		sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
		messages, err := iface.messages_pending(s.repo, bot_id, -1)
		defer delete(messages)
		if err.code != .None {
			for &m in messages do domain.channel_message_destroy(&m)
			return nil, 0, err
		}
		ids := make([dynamic]string, context.temp_allocator)
		for m in messages {
			if m.body_purged || m.binding_id != binding.binding_id || m.direction != .Inbound {
				discard := m
				domain.channel_message_destroy(&discard)
				continue
			}
			total += 1
			if len(selected) >= limit {
				discard := m
				domain.channel_message_destroy(&discard)
				continue
			}
			append(&selected, m)
			append(&ids, m.message_id)
			if m.read_at == "" do append(&newly_read, m)
		}
		if e := iface.messages_mark_read(s.repo, bot_id, ids[:], platform.clock_now(s.clock)); e.code != .None do return nil, 0, e
	}
	if len(newly_read) > 0 && bots_gate_on(s.experiments, binding.owner_user_id) {
		if s.adapter != nil && s.adapter.react != nil {
			started := time.tick_now()
			for m in newly_read {
				if time.tick_since(started) >= BOT_READ_REACTION_BUDGET do break
				if err := s.adapter.react(s.adapter.ctx, binding.external_chat_id, m.external_message_id, BOT_READ_REACTION); err.kind != .None {
					log.warn(fmt.tprintf("bots: react failed kind=%v", err.kind))
					// A provider outage must not multiply latency by the read limit.
					if err.kind == .Transient || err.kind == .Aborted || err.kind == .Rate_Limited do break
				}
			}
		}
	}
	keep = true
	return selected[:], total, {}
}
