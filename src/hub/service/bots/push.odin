package bots

import "core:fmt"
import "core:mem/virtual"
import "core:sync"
import "core:strings"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import channel "odin_test:hub/service/channel"

Push_Receive_Result :: enum { Stored, Bad_Signature, Bad_Payload, Foreign_Account, Store_Failed, Not_Configured }
BOT_PUSH_INTAKE_BATCH :: 50
BOT_PUSH_INTAKE_IDLE :: 5 * time.Second
BOT_PUSH_INTAKE_RETRY :: 5 * time.Second

bots_push_enabled :: proc(s: ^Bots_Service, provider: string) -> bool {
	if s == nil do return false
	a := bots_adapter(s, provider)
	if a == nil || a.push_parse == nil do return false
	n, err := iface.experiment_count_enabled(s.experiments, "bots")
	return err.code == .None && n > 0
}

bots_push_challenge :: proc(s: ^Bots_Service, provider, mode, verify_token: string) -> bool {
	if s == nil do return false
	a := bots_adapter(s, provider)
	return a != nil && a.push_challenge != nil && a.push_challenge(a.ctx, mode, verify_token)
}

bots_push_receive :: proc(s: ^Bots_Service, provider, signature, body: string) -> (result: Push_Receive_Result, events, inserted: int) {
	if s == nil do return .Not_Configured, 0, 0
	a := bots_adapter(s, provider)
	if a == nil || a.push_parse == nil do return .Not_Configured, 0, 0
	batch, verdict := a.push_parse(a.ctx, signature, body, context.temp_allocator)
	// The adapter allocates this batch in the caller's scratch arena.
	switch verdict {
	case .Bad_Signature: return .Bad_Signature, 0, 0
	case .Bad_Payload: return .Bad_Payload, 0, 0
	case .Foreign_Account: return .Foreign_Account, 0, 0
	case .Accepted:
	}
	if len(batch) == 0 do return .Stored, 0, 0
	now := platform.clock_now(s.clock)
	rows := make([]domain.Channel_Push_Event, len(batch), context.temp_allocator)
	for b, i in batch {
		rows[i] = {provider = provider, event_key = b.update_key, kind = domain.Channel_Push_Kind(b.kind),
			external_chat_id = b.external_chat_id, external_user_id = b.external_user_id,
			external_message_id = b.external_message_id, sender_display = b.sender_display,
			media_kind = domain.Channel_Media_Kind(b.media.kind), media_ref = b.media.file_ref,
			media_name = b.media.name, media_mime = b.media.mime, media_size = b.media.size,
			body = b.text, provider_code = b.provider_code, provider_time = b.provider_time, received_at = now}
	}
	count, err := iface.push_events_insert(s.repo, rows)
	if err.code != .None do return .Store_Failed, len(batch), 0
	fmt.printf("bots: whatsapp webhook stored events=%d new=%d\n", len(batch), count)
	return .Stored, len(batch), count
}

bots_intake_entry :: proc(data: rawptr) {
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	bots_intake_thread((^Bots_Runtime)(data))
}

bots_intake_thread :: proc(rt: ^Bots_Runtime) {
	for !sync.atomic_load(&rt.intake_stop) {
		more, delay := bots_push_intake_iteration(rt)
		free_all(context.temp_allocator)
		if !more && bots_intake_wait(rt, delay) do return
	}
}

bots_push_intake_iteration :: proc(rt: ^Bots_Runtime) -> (more: bool, delay: time.Duration) {
	s := rt.service
	a := s.whatsapp
	events, err := iface.push_events_pending(s.repo, "whatsapp", BOT_PUSH_INTAKE_BATCH)
	defer {for &e in events do domain.channel_push_event_destroy(&e); delete(events)}
	if err.code != .None do return false, BOT_PUSH_INTAKE_RETRY
	if len(events) == 0 do return false, BOT_PUSH_INTAKE_IDLE
	if a == nil do return false, BOT_PUSH_INTAKE_RETRY
	now := platform.clock_now(s.clock)
	batch := make([]channel.Inbound, len(events), context.temp_allocator)
	ordinary := make([dynamic]channel.Inbound, context.temp_allocator)
	touches := make([dynamic]domain.Channel_Inbound_Touch, context.temp_allocator)
	release := make(map[string]bool, context.temp_allocator)
	seqs := make([]i64, len(events), context.temp_allocator)
	for e, i in events {
		batch[i] = {update_key = e.event_key, kind = channel.Inbound_Kind(e.kind), external_chat_id = e.external_chat_id,
			external_user_id = e.external_user_id, external_message_id = e.external_message_id,
			sender_display = e.sender_display, text = e.body, provider_code = e.provider_code,
			provider_time = e.provider_time, chat_is_private = true,
			media = {kind = channel.Media_Kind(e.media_kind), file_ref = e.media_ref, name = e.media_name, mime = e.media_mime, size = e.media_size}}
		seqs[i] = e.seq
		if e.kind == .Delivery_Failed do continue
		append(&ordinary, batch[i])
		binding, found, binding_err := bots_find_binding(s, "whatsapp", e.external_chat_id, e.external_user_id)
		if binding_err.code != .None {domain.channel_binding_destroy(&binding); return false, BOT_PUSH_INTAKE_RETRY}
		if found && bots_gate_on(s.experiments, binding.owner_user_id) {
			// Binding snapshots are freed below; retain only scratch-owned ids.
			id := strings.clone(binding.binding_id, context.temp_allocator)
			append(&touches, domain.Channel_Inbound_Touch{id, e.provider_time if e.provider_time != "" else now})
			if e.kind == .Text || e.kind == .Unsupported || e.kind == .Media do release[id] = true
		}
		domain.channel_binding_destroy(&binding)
	}
	rows, map_err := bots_inbound_rows(s, a, ordinary[:], now)
	if map_err.code != .None do return false, BOT_PUSH_INTAKE_RETRY
	inserted, commit_err := iface.push_batch_commit(s.repo, rows, touches[:], seqs, now)
	defer {for id in inserted do delete(id); delete(inserted)}
	if commit_err.code != .None {
		fmt.eprintln("bots: whatsapp intake commit failed")
		return false, BOT_PUSH_INTAKE_RETRY
	}
	for id in release do bots_release_held(s, id)
	for b in batch {
		if b.kind == .Delivery_Failed {bots_on_delivery_failed(s, a, b)} else {
			if e := bots_inbound_side_effect(s, a, b, now); e.code != .None do fmt.eprintf("bots: inbound side effect code=%v\n", e.code)
		}
	}
	seen := make(map[string]bool, context.temp_allocator)
	for row in rows {
		fresh := false
		for id in inserted do if id == row.message_id do fresh = true
		if !fresh || seen[row.bot_id] do continue
		seen[row.bot_id] = true
		ms, _ := platform.rfc3339_to_unix_ms(now)
		if e := delivery_on_inbound(s, row.bot_id, ms); e.code != .None do fmt.eprintf("bots: inbound delivery code=%v\n", e.code)
	}
	return len(events) == BOT_PUSH_INTAKE_BATCH, 0
}
