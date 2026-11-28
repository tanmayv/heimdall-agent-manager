package bots

import "core:fmt"
import "core:os"
import "core:sync"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import channel "odin_test:hub/service/channel"

BOT_READ_REACTION :: "👀"
// Stop admitting calls after four seconds. Telegram bounds each admitted call
// to one second, keeping feedback below the bridge relay's 20-second stall.
BOT_READ_REACTION_BUDGET :: 4 * time.Second

// Exact provider reaction strings (Telegram rejects the WhatsApp hourglass).
BOT_QUEUED_REACTIONS := [?]struct {provider, emoji: string}{
	{"telegram", "✍"},
	{"whatsapp", "⏳"},
}

bots_queued_reaction :: proc(provider: string) -> string {
	for reaction in BOT_QUEUED_REACTIONS {
		if reaction.provider == provider do return reaction.emoji
	}
	return ""
}

// Channel_Error.message is adapter-sanitized; never include message/chat IDs,
// inbound text, credentials, or raw provider responses in feedback diagnostics.
bots_feedback_error :: proc(provider, operation: string, err: channel.Channel_Error, output: ^os.File = os.stderr) {
	fmt.fprintf(output, "bots: feedback failed provider=%s operation=%s kind=%v http_status=%d provider_code=%d description=%s\n",
		provider, operation, err.kind, err.http_status, err.provider_code, err.message)
}

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
		if fence := bots_legacy_guard(s, binding.owner_user_id); fence.code != .None do return nil, 0, fence
		messages, err := iface.messages_pending(s.repo, bot_id, -1)
		defer delete(messages)
		if err.code != .None {
			for &m in messages do domain.channel_message_destroy(&m)
			return nil, 0, err
		}
		ids := make([dynamic]string, context.temp_allocator)
		for m in messages {
			if !m.body_purged && m.direction == .Inbound do total += 1
			if m.body_purged || m.binding_id != binding.binding_id || m.direction != .Inbound {
				discard := m
				domain.channel_message_destroy(&discard)
				continue
			}
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
	if len(newly_read) > 0 do bots_publish_changed(s, binding.owner_user_id, bot_id)
	if len(newly_read) > 0 && bots_gate_on(s.experiments, binding.owner_user_id) {
		a := bots_adapter(s, binding.provider)
		started := time.tick_now()
		skip_reactions := false
		if a != nil && a.mark_read != nil && bots_legacy_provider_admit(s, binding.owner_user_id) {
			if err := a.mark_read(a.ctx, binding.external_chat_id, newly_read[len(newly_read)-1].external_message_id); err.kind != .None {
				bots_feedback_error(binding.provider, "mark_read", err)
				skip_reactions = err.kind == .Transient || err.kind == .Aborted || err.kind == .Rate_Limited
			}
		}
		if !skip_reactions && a != nil && a.react != nil {
			for m in newly_read {
				if time.tick_since(started) >= BOT_READ_REACTION_BUDGET do break
				if !bots_legacy_provider_admit(s, binding.owner_user_id) do break
				if err := a.react(a.ctx, binding.external_chat_id, m.external_message_id, BOT_READ_REACTION); err.kind != .None {
					bots_feedback_error(binding.provider, "read_reaction", err)
					// A provider outage must not multiply latency by the read limit.
					if err.kind == .Transient || err.kind == .Aborted || err.kind == .Rate_Limited do break
				}
			}
		}
	}
	keep = true
	return selected[:], total, {}
}

// Fresh rows are borrowed from the committed intake batch. No provider I/O runs
// under the service mutex or the delivery transaction, and retries are silent.
bots_queued_feedback :: proc(s: ^Bots_Service, fresh: []domain.Channel_Message, feedback_output: ^os.File = os.stderr) {
	started := time.tick_now()
	for m in fresh {
		if time.tick_since(started) >= BOT_READ_REACTION_BUDGET do break
		binding, found, err := iface.binding_get(s.repo, m.binding_id)
		defer domain.channel_binding_destroy(&binding)
		if err.code != .None || !found || binding.state != .Active || !bots_gate_on(s.experiments, binding.owner_user_id) do continue
		a := bots_adapter(s, binding.provider)
		emoji := bots_queued_reaction(binding.provider)
		if a == nil || a.react == nil || emoji == "" do continue
		if !bots_legacy_provider_admit(s, binding.owner_user_id) do continue
		if e := a.react(a.ctx, binding.external_chat_id, m.external_message_id, emoji); e.kind != .None {
			bots_feedback_error(binding.provider, "queued_reaction", e, feedback_output)
			if e.kind == .Transient || e.kind == .Aborted || e.kind == .Rate_Limited do break
		}
	}
}
