package bots

import "core:strings"
import "core:sync"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import channel "odin_test:hub/service/channel"

// Rows use the caller's scratch arena, because binding snapshots are released
// before the whole batch is committed. The update text itself stays borrowed.
bots_inbound_rows :: proc(s: ^Bots_Service, a: ^channel.Channel_Adapter, batch: []channel.Inbound, now: string) -> ([]domain.Channel_Message, domain.Domain_Error) {
	rows := make([dynamic]domain.Channel_Message, context.temp_allocator)
	for update in batch {
		if !update.chat_is_private || (update.kind != .Text && update.kind != .Media) do continue
		binding, found, err := bots_find_binding(s, a.provider, update.external_chat_id, update.external_user_id)
		defer domain.channel_binding_destroy(&binding)
		if err.code != .None do return nil, err
		if !found || !bots_gate_on(s.experiments, binding.owner_user_id) || update.external_user_id != binding.external_user_id do continue
		// Invite-only WhatsApp: a disabled owner's messages are never routed.
		entitled, entitlement_err := bots_channel_entitled(s, a.provider, binding.owner_user_id)
		if entitlement_err.code != .None do return nil, entitlement_err
		if !entitled do continue
		if fence := bots_legacy_guard(s, binding.owner_user_id); fence.code != .None {
			if fence.code == .Conflict do continue
			return nil, fence
		}
		limit := bots_media_limit(a)
		if update.kind == .Media && (limit == 0 || update.media.size > limit && update.text == "") do continue
		attachment: domain.Channel_Attachment
		if update.kind == .Media {
			mime := bots_media_mime(update.media.kind, update.media.mime)
			attachment = {
				attachment_id = strings.clone(platform.generate_id(s.ids, "cha_"), context.temp_allocator),
				kind = domain.Channel_Media_Kind(update.media.kind), file_ref = update.media.file_ref,
				mime = mime, name = bots_media_name(update.media.kind, update.media.name, mime),
				size_bytes = update.media.size, state = .Too_Large if update.media.size > limit else .Pending,
			}
		}
		body := update.text
		if len(body) > 16384 {
			cut := 16384
			for cut > 0 && (body[cut] & 0xc0) == 0x80 do cut -= 1
			body = strings.concatenate({body[:cut], "\n[truncated]"}, context.temp_allocator)
		}
		append(&rows, domain.Channel_Message{
			message_id = strings.clone(platform.generate_id(s.ids, "chm_"), context.temp_allocator),
			binding_id = strings.clone(binding.binding_id, context.temp_allocator),
			owner_user_id = strings.clone(binding.owner_user_id, context.temp_allocator),
			bot_id = strings.clone(binding.bot_id, context.temp_allocator),
			direction = .Inbound, body = body, attachment = attachment, provider_update_key = update.update_key,
			external_message_id = update.external_message_id, created_at = now,
		})
	}
	return rows[:], {}
}

// invite_only_chats (optional, batch scratch) records chats unbound for
// invite-only access, so later updates in the same batch stay silent instead of
// answering with the not-connected copy.
bots_inbound_side_effect :: proc(s: ^Bots_Service, a: ^channel.Channel_Adapter, update: channel.Inbound, now: string, invite_only_chats: ^map[string]bool = nil) -> domain.Domain_Error {
	if !update.chat_is_private {bots_notice(s, a.provider, update.external_chat_id, COPY_PRIVATE_ONLY); return {}}
	if update.kind == .Start do return bots_pairing_start(s, a, update, now)
	binding, found, err := bots_find_binding(s, a.provider, update.external_chat_id, update.external_user_id)
	defer domain.channel_binding_destroy(&binding)
	if err.code != .None do return err
	if !found {
		if invite_only_chats != nil && invite_only_chats[update.external_chat_id] do return {}
		bots_notice(s, a.provider, update.external_chat_id, bots_channel_copy(a.provider).not_connected)
		return {}
	}
	if !bots_gate_on(s.experiments, binding.owner_user_id) || bots_legacy_guard(s, binding.owner_user_id).code != .None do return {}
	entitled, entitlement_err := bots_channel_entitled(s, a.provider, binding.owner_user_id)
	if entitlement_err.code != .None do return entitlement_err
	if !entitled {
		revoked, e := bots_whatsapp_invite_only_unbind(s, binding.owner_user_id, true)
		if revoked && invite_only_chats != nil do invite_only_chats[update.external_chat_id] = true
		return e
	}
	if update.kind == .Disconnect do return bots_disconnect(s, binding.owner_user_id, a.provider, true)
	if update.kind == .Unsupported do bots_notice(s, a.provider, update.external_chat_id, COPY_UNSUPPORTED, binding.owner_user_id)
	if update.kind == .Media && update.external_user_id == binding.external_user_id {
		limit := bots_media_limit(a)
		if limit == 0 {bots_notice(s, a.provider, update.external_chat_id, COPY_UNSUPPORTED, binding.owner_user_id)} else if update.media.size > limit {
			bots_notice(s, a.provider, update.external_chat_id, COPY_MEDIA_TOO_LARGE, binding.owner_user_id)
		}
	}
	return {}
}

delivery_on_inbound :: proc(s: ^Bots_Service, bot_id: string, now_ms: i64, fresh: []domain.Channel_Message = nil) -> domain.Domain_Error {
	queued := false
	err: domain.Domain_Error
	{
		sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
		err = bots_delivery_on_inbound_locked(s, bot_id, now_ms, &queued)
	}
	if err.code == .None && queued do bots_queued_feedback(s, fresh)
	return err
}

// Caller holds the service lock. This proc only changes durable delivery rows;
// it never selects a bridge or sends a command.
bots_delivery_on_inbound_locked :: proc(s: ^Bots_Service, bot_id: string, now_ms: i64, queued: ^bool = nil) -> domain.Domain_Error {
	uow, ok, err := iface.unit_of_work_begin(s.uow_factory)
	if !ok do return err
	defer if uow.ctx != nil do iface.unit_of_work_rollback(&uow)
	messages, pending_err := iface.messages_pending(s.repo, bot_id, -1)
	defer {for &m in messages do domain.channel_message_destroy(&m); delete(messages)}
	if pending_err.code != .None do return pending_err
	last_index := -1
	for m, i in messages do if !m.body_purged do last_index = i
	if last_index < 0 {_, e := bots_uow_commit(&uow); return e}
	bot, bot_found, bot_err := iface.bot_get(s.repo, bot_id)
	defer domain.bot_destroy(&bot)
	if bot_err.code != .None do return bot_err
	if !bot_found || !bots_gate_on(s.experiments, bot.owner_user_id) || bots_legacy_guard(s, bot.owner_user_id).code != .None do return {}
	d, found, get_err := iface.delivery_get_open(s.repo, bot_id)
	defer domain.bot_delivery_destroy(&d)
	if get_err.code != .None do return get_err
	now := platform.format_rfc3339_utc(time.Time{_nsec = now_ms * 1_000_000})
	last := messages[last_index]
	if !found {
		if e := iface.delivery_insert(s.repo, {delivery_id = platform.generate_id(s.ids, "bdl_"), bot_id = bot_id,
			owner_user_id = last.owner_user_id, through_message_id = last.message_id, state = .Pending,
			round = 1, created_at = now, updated_at = now}); e.code != .None do return e
	} else if d.state == .Waiting {
		updated := d
		updated.through_message_id, updated.updated_at = last.message_id, now
		if _, e := iface.delivery_update(s.repo, updated, .Waiting); e.code != .None do return e
	}
	_, commit_err := bots_uow_commit(&uow)
	if queued != nil do queued^ = commit_err.code == .None && found && (d.state == .Dispatched || d.state == .Waiting)
	return commit_err
}

// R2 and R3 are committed together after all outbound chunks were sent.
bots_channel_replied :: proc(s: ^Bots_Service, bot_id, binding_id: string) -> domain.Domain_Error {
	sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
	uow, ok, err := iface.unit_of_work_begin(s.uow_factory)
	if !ok do return err
	defer if uow.ctx != nil do iface.unit_of_work_rollback(&uow)
	now := platform.clock_now(s.clock)
	if _, e := iface.messages_mark_replied_binding(s.repo, bot_id, binding_id, now); e.code != .None do return e
	d, found, get_err := iface.delivery_get_open(s.repo, bot_id)
	defer domain.bot_delivery_destroy(&d)
	if get_err.code != .None do return get_err
	if found {
		messages, list_err := iface.messages_history(s.repo, bot_id, -1)
		defer {for &m in messages do domain.channel_message_destroy(&m); delete(messages)}
		if list_err.code != .None do return list_err
		replied := false
		for m in messages do if m.message_id == d.through_message_id && m.replied_at != "" do replied = true
		if replied {
			attempts, attempt_err := iface.attempt_list_for_delivery(s.repo, d.delivery_id)
			defer {for &a in attempts do domain.bot_delivery_attempt_destroy(&a); delete(attempts)}
			if attempt_err.code != .None do return attempt_err
			for a in attempts {
				if !domain.bot_attempt_state_open(a.state) do continue
				updated := a
				updated.state, updated.finished_at = .Acted, now
				if _, e := iface.attempt_update(s.repo, updated, a.state); e.code != .None do return e
			}
			updated := d
			updated.state, updated.finish_reason, updated.finished_at, updated.updated_at = .Acted, "acted", now, now
			if _, e := iface.delivery_update(s.repo, updated, d.state); e.code != .None do return e
			ms, _ := platform.rfc3339_to_unix_ms(now)
			if e := bots_delivery_on_inbound_locked(s, bot_id, ms); e.code != .None do return e
		}
	}
	_, commit_err := bots_uow_commit(&uow)
	return commit_err
}

// SQLite closes and frees its transaction context on commit, including failures.
bots_uow_commit :: proc(uow: ^iface.Unit_Of_Work) -> (bool, domain.Domain_Error) {
	ok, err := iface.unit_of_work_commit(uow)
	uow.ctx = nil
	return ok, err
}
