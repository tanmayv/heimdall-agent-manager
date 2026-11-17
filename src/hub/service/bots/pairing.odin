package bots

import "core:crypto/sha2"
import "core:encoding/json"
import "core:strings"
import "core:sync"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import channel "odin_test:hub/service/channel"
import events "odin_test:hub/service/events"

bots_pairing_hash :: proc(code: string) -> string {
	hash: sha2.Context_256
	digest: [32]byte
	sha2.init_256(&hash)
	sha2.update(&hash, transmute([]byte)code)
	sha2.final(&hash, digest[:])
	return platform.hex_encode(digest[:], context.temp_allocator)
}

Bot_Pairing_Link :: struct {pairing_url, expires_at: string}
// Both returned strings are caller-owned.
bots_pairing_create :: proc(s: ^Bots_Service, owner: string) -> (Bot_Pairing_Link, domain.Domain_Error) {
	bot, err := bots_get(s, owner)
	if err.code != .None do return {}, err
	defer domain.bot_destroy(&bot)
	if s.adapter == nil do return {}, domain.domain_error(.Provider_Unavailable, "telegram is not configured on this hub", "{\"code\":\"channel_not_configured\"}")
	identity, channel_err := s.adapter.identity(s.adapter.ctx)
	if channel_err.kind != .None do return {}, domain.domain_error(.Provider_Unavailable, "channel identity unavailable")
	code, random_ok := platform.random_hex(16)
	if !random_ok do return {}, domain.domain_error(.Internal_Error, "pairing randomness unavailable")
	defer delete(code)
	now := platform.clock_now(s.clock)
	ms, valid := platform.rfc3339_to_unix_ms(now)
	if !valid do return {}, domain.domain_error(.Internal_Error, "pairing clock unavailable")
	expires := platform.format_rfc3339_utc(time.Time{_nsec = (ms + s.timers.bot_pairing_ttl_ms) * 1_000_000})
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	if e := iface.pairing_delete_for_owner(s.repo, owner, "telegram"); e.code != .None do return {}, e
	if e := iface.pairing_insert(s.repo, {code_hash = bots_pairing_hash(code), owner_user_id = owner, bot_id = bot.bot_id, provider = "telegram", created_at = now, expires_at = expires}); e.code != .None do return {}, e
	return {pairing_url = s.adapter.pairing_url(s.adapter.ctx, identity, code), expires_at = strings.clone(expires)}, {}
}

bots_publish_changed :: proc(s: ^Bots_Service, owner, bot_id: string) {
	if s.event_bus == nil do return
	data, _ := json.marshal(struct {type: string, payload: struct {bot_id: string}}{"bot_changed", {bot_id}}, allocator = context.allocator)
	events.publish_owned(s.event_bus, owner, string(data))
}

bots_notice :: proc(s: ^Bots_Service, chat_id, text: string) {
	ids, _ := channel_send(s, {external_chat_id = chat_id}, text, false)
	for id in ids do delete(id)
	delete(ids)
}

// Pairing state is serialized, but Telegram I/O happens after unlocking.
bots_pairing_start :: proc(s: ^Bots_Service, update: channel.Inbound, now: string) -> domain.Domain_Error {
	reply, previous_chat, owner, bot_id, err := bots_pairing_apply(s, update, now)
	defer {delete(previous_chat); delete(owner); delete(bot_id)}
	if err.code != .None do return err
	if reply != "" do bots_notice(s, update.external_chat_id, reply)
	if previous_chat != "" do bots_notice(s, previous_chat, COPY_REPLACED)
	if bot_id != "" do bots_publish_changed(s, owner, bot_id)
	return {}
}

bots_pairing_apply :: proc(s: ^Bots_Service, update: channel.Inbound, now: string) -> (reply, previous_chat, owner, bot_id: string, err: domain.Domain_Error) {
	sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
	binding, bound, binding_err := iface.binding_get_active_by_chat(s.repo, "telegram", update.external_chat_id)
	defer domain.channel_binding_destroy(&binding)
	if binding_err.code != .None do return "", "", "", "", binding_err
	if update.text == "" {
		return "" if bound else COPY_NOT_CONNECTED, "", "", "", {}
	}
	hash := bots_pairing_hash(update.text)
	pairing, found, get_err := iface.pairing_get(s.repo, hash)
	defer domain.channel_pairing_destroy(&pairing)
	if get_err.code != .None do return "", "", "", "", get_err
	if !found || pairing.consumed_at != "" || pairing.expires_at <= now do return COPY_PAIR_INVALID, "", "", "", {}
	if !bots_gate_on(s.experiments, pairing.owner_user_id) do return COPY_PAIR_NOT_ENABLED, "", "", "", {}
	bot, bot_found, bot_err := iface.bot_get_by_owner(s.repo, pairing.owner_user_id)
	defer domain.bot_destroy(&bot)
	if bot_err.code != .None do return "", "", "", "", bot_err
	if !bot_found do return COPY_PAIR_NO_BOT, "", "", "", {}
	if bound && binding.owner_user_id != pairing.owner_user_id do return COPY_PAIR_CHAT_TAKEN, "", "", "", {}
	if bound {
		consumed, consume_err := iface.pairing_consume(s.repo, hash, now)
		if consume_err.code != .None do return "", "", "", "", consume_err
		return COPY_PAIRED if consumed else COPY_PAIR_INVALID, "", "", "", {}
	}
	previous, had_previous, activate_err := iface.binding_activate(s.repo, {
		binding_id = platform.generate_id(s.ids, "chb_"), owner_user_id = pairing.owner_user_id, bot_id = bot.bot_id,
		provider = "telegram", external_chat_id = update.external_chat_id, external_user_id = update.external_user_id,
		external_display = update.sender_display, state = .Active, created_at = now,
	}, hash, now)
	defer domain.channel_binding_destroy(&previous)
	if activate_err.code == .Conflict do return COPY_PAIR_INVALID, "", "", "", {}
	if activate_err.code != .None do return "", "", "", "", activate_err
	if had_previous {
		if e := bots_revoke_contents(s, previous, now); e.code != .None do return "", "", "", "", e
	}
	return COPY_PAIRED, strings.clone(previous.external_chat_id) if had_previous else "", strings.clone(pairing.owner_user_id), strings.clone(bot.bot_id), {}
}

// Caller holds s.mutex. Disconnect supplies a transaction; binding_activate
// has already committed the replacement when pairing calls this cleanup.
bots_revoke_contents :: proc(s: ^Bots_Service, binding: domain.Channel_Binding, now: string, finish_reason := "binding_revoked") -> domain.Domain_Error {
	if e := iface.messages_purge_binding(s.repo, binding.binding_id); e.code != .None do return e
	d, found, err := iface.delivery_get_open(s.repo, binding.bot_id)
	defer domain.bot_delivery_destroy(&d)
	if err.code != .None || !found do return err
	attempts, list_err := iface.attempt_list_for_delivery(s.repo, d.delivery_id)
	defer {for &a in attempts do domain.bot_delivery_attempt_destroy(&a); delete(attempts)}
	if list_err.code != .None do return list_err
	for a in attempts {
		if !domain.bot_attempt_state_open(a.state) do continue
		updated := a
		updated.state, updated.finished_at = .Cancelled, now
		if _, e := iface.attempt_update(s.repo, updated, a.state); e.code != .None do return e
	}
	updated := d
	updated.state, updated.finish_reason, updated.finished_at, updated.updated_at = .Abandoned, finish_reason, now, now
	_, err = iface.delivery_update(s.repo, updated, d.state)
	return err
}

bots_disconnect :: proc(s: ^Bots_Service, owner_user_id: string, notify: bool) -> domain.Domain_Error {
	return bots_disconnect_for_reason(s, owner_user_id, notify, "binding_revoked")
}

// DELETE shares disconnect cleanup while preserving its bot_deleted terminal reason.
bots_disconnect_for_reason :: proc(s: ^Bots_Service, owner_user_id: string, notify: bool, finish_reason: string) -> domain.Domain_Error {
	sync.mutex_lock(&s.mutex)
	binding, found, err := bots_disconnect_locked(s, owner_user_id, finish_reason)
	sync.mutex_unlock(&s.mutex)
	defer domain.channel_binding_destroy(&binding)
	if err.code != .None do return err
	if !found do return bots_detail_error(.Not_Found, "binding_not_found")
	if notify do bots_notice(s, binding.external_chat_id, COPY_DISCONNECTED)
	bots_publish_changed(s, owner_user_id, binding.bot_id)
	return {}
}

bots_disconnect_locked :: proc(s: ^Bots_Service, owner, finish_reason: string) -> (domain.Channel_Binding, bool, domain.Domain_Error) {
	uow, ok, err := iface.unit_of_work_begin(s.uow_factory)
	if !ok do return {}, false, err
	defer if uow.ctx != nil do iface.unit_of_work_rollback(&uow)
	binding, found, get_err := iface.binding_get_active_by_owner(s.repo, owner, "telegram")
	if get_err.code != .None || !found do return binding, found, get_err
	now := platform.clock_now(s.clock)
	if e := iface.binding_revoke(s.repo, binding.binding_id, now); e.code != .None do return binding, found, e
	if e := bots_revoke_contents(s, binding, now, finish_reason); e.code != .None do return binding, found, e
	_, commit_err := bots_uow_commit(&uow)
	return binding, found, commit_err
}
