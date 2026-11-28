package bots

import "core:crypto/sha2"
import "core:encoding/json"
import "core:fmt"
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

Bot_Pairing_Link :: struct {pairing_url, pairing_text, expires_at: string}
// All returned strings are caller-owned.
bots_pairing_create :: proc(s: ^Bots_Service, owner, provider: string) -> (Bot_Pairing_Link, domain.Domain_Error) {
	bot, err := bots_get(s, owner)
	if err.code != .None do return {}, err
	defer domain.bot_destroy(&bot)
	if _,err := pairing_activation_generation(s,owner,provider); err.code!=.None do return {},err
	entitled, entitlement_err := bots_channel_entitled(s, provider, owner)
	if entitlement_err.code != .None do return {}, entitlement_err
	if !entitled do return {}, bots_whatsapp_invite_only_error()
	a := bots_adapter(s, provider)
	if a == nil do return {}, domain.domain_error(.Provider_Unavailable, fmt.tprintf("%s is not configured on this hub", provider), "{\"code\":\"channel_not_configured\"}")
	identity, channel_err := a.identity(a.ctx)
	if channel_err.kind != .None do return {}, domain.domain_error(.Provider_Unavailable, "channel identity unavailable")
	code, random_ok := platform.random_hex(16)
	if !random_ok do return {}, domain.domain_error(.Internal_Error, "pairing randomness unavailable")
	defer delete(code)
	now := platform.clock_now(s.clock)
	ms, valid := platform.rfc3339_to_unix_ms(now)
	if !valid do return {}, domain.domain_error(.Internal_Error, "pairing clock unavailable")
	expires := platform.format_rfc3339_utc(time.Time{_nsec = (ms + s.timers.bot_pairing_ttl_ms) * 1_000_000})
	{
		sync.mutex_lock(&s.mutex)
		defer sync.mutex_unlock(&s.mutex)
		generation, mode_err := pairing_activation_generation(s,owner,provider)
		if mode_err.code!=.None do return {},mode_err
		if e := iface.pairing_delete_for_owner(s.repo, owner, provider); e.code != .None do return {}, e
		p := domain.Channel_Pairing{code_hash=bots_pairing_hash(code),owner_user_id=owner,bot_id=bot.bot_id,
			provider=provider,created_at=now,expires_at=expires}
		insert_err: domain.Domain_Error
		if generation>0 do insert_err=iface.bot_channel_conversion_pairing_insert_fresh(s.repo,p,generation)
		else do insert_err=iface.pairing_insert(s.repo,p)
		if insert_err.code!=.None do return {},insert_err
	}
	text := ""
	if a.pairing_text != nil do text = a.pairing_text(a.ctx, code)
	return {pairing_url = a.pairing_url(a.ctx, identity, code), pairing_text = text, expires_at = strings.clone(expires)}, {}
}

pairing_activation_generation :: proc(s: ^Bots_Service, owner, provider: string) -> (i64,domain.Domain_Error) {
	// Allow existing lightweight legacy adapters and fakes without cutover.
	if s.repo==nil || s.repo.web_activation_get==nil do return 0,{}
	state, found, err := iface.bot_web_activation_get(s.repo,owner)
	defer domain.bot_web_activation_destroy(&state)
	if err.code!=.None || !found do return 0,err
	if !state.enabled || !canonical_channel_enabled(s,provider,owner) do return 0,bots_legacy_guard(s,owner)
	return state.generation,{}
}

bots_publish_changed :: proc(s: ^Bots_Service, owner, bot_id: string) {
	if s.event_bus == nil do return
	data, _ := json.marshal(struct {type: string, payload: struct {bot_id: string}}{"bot_changed", {bot_id}}, allocator = context.allocator)
	events.publish_owned(s.event_bus, owner, string(data))
}

bots_notice :: proc(s: ^Bots_Service, provider, chat_id, text: string, owner := "") {
	a := bots_adapter(s, provider)
	binding := domain.Channel_Binding{owner_user_id = owner, provider = provider, external_chat_id = chat_id, last_inbound_at = platform.clock_now(s.clock)}
	if a != nil && s.repo != nil && s.repo.binding_get_active_by_chat != nil {
		active, found, err := iface.binding_get_active_by_chat(s.repo, provider, chat_id)
		defer domain.channel_binding_destroy(&active)
		if err.code != .None do return
		if found && bots_window_closed(a, active, bots_stamp_ms(platform.clock_now(s.clock))) do return
		if found {
			if owner != "" && owner != active.owner_user_id do return
			binding.last_inbound_at = strings.clone(active.last_inbound_at, context.temp_allocator)
			binding.owner_user_id = strings.clone(active.owner_user_id, context.temp_allocator)
		}
	}
	ids, _, _ := channel_send(s, binding, text, false)
	for id in ids do delete(id)
	delete(ids)
}

// Pairing state is serialized; provider I/O happens after unlocking.
bots_pairing_start :: proc(s: ^Bots_Service, a: ^channel.Channel_Adapter, update: channel.Inbound, now: string) -> domain.Domain_Error {
	reply, previous_chat, owner, bot_id, err := bots_pairing_apply(s, a, update, now)
	defer {delete(previous_chat); delete(owner); delete(bot_id)}
	if err.code != .None do return err
	if reply != "" {
		if generation, _ := pairing_activation_generation(s,owner,a.provider); owner!="" && generation>0 {
			bots_canonical_pairing_notice(s,a,update,owner,reply)
		} else {
			bots_notice(s,a.provider,update.external_chat_id,reply,owner)
		}
	}
	if previous_chat != "" do bots_notice(s, a.provider, previous_chat, bots_channel_copy(a.provider).replaced, owner)
	if bot_id != "" do bots_publish_changed(s, owner, bot_id)
	return {}
}

bots_pairing_apply :: proc(s: ^Bots_Service, a: ^channel.Channel_Adapter, update: channel.Inbound, now: string) -> (reply, previous_chat, owner, bot_id: string, err: domain.Domain_Error) {
	sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
	copy := bots_channel_copy(a.provider)
	binding, bound, binding_err := bots_find_binding(s, a.provider, update.external_chat_id, update.external_user_id)
	defer domain.channel_binding_destroy(&binding)
	if binding_err.code != .None do return "", "", "", "", binding_err

	if update.text == "" {
		return "" if bound else copy.not_connected, "", "", "", {}
	}
	hash := bots_pairing_hash(update.text)
	pairing, found, get_err := iface.pairing_get(s.repo, hash)
	defer domain.channel_pairing_destroy(&pairing)
	if get_err.code != .None do return "", "", "", "", get_err
	if !found || pairing.provider != a.provider || pairing.consumed_at != "" || pairing.expires_at <= now do return copy.pair_invalid, "", "", "", {}
	generation, mode_err := pairing_activation_generation(s,pairing.owner_user_id,a.provider)
	if mode_err.code==.Conflict do return "","","","",{}
	if mode_err.code!=.None do return "","","","",mode_err
	if !bots_gate_on(s.experiments, pairing.owner_user_id) do return COPY_PAIR_NOT_ENABLED, "", "", "", {}
	// A code issued before the account lost WhatsApp access must not pair.
	entitled, entitlement_err := bots_channel_entitled(s, a.provider, pairing.owner_user_id)
	if entitlement_err.code != .None do return "", "", "", "", entitlement_err
	if !entitled do return COPY_WA_INVITE_ONLY, "", "", "", {}
	bot, bot_found, bot_err := iface.bot_get_by_owner(s.repo, pairing.owner_user_id)
	defer domain.bot_destroy(&bot)
	if bot_err.code != .None do return "", "", "", "", bot_err
	if !bot_found do return COPY_PAIR_NO_BOT, "", "", "", {}
	if bound && binding.owner_user_id != pairing.owner_user_id do return copy.chat_taken, "", "", "", {}
	if bound && generation==0 {
		if bots_legacy_guard(s,binding.owner_user_id).code!=.None do return "","","","",{}
		consumed, consume_err := iface.pairing_consume(s.repo, hash, now)
		if consume_err.code != .None do return "", "", "", "", consume_err
		return copy.paired if consumed else copy.pair_invalid, "", "", "", {}
	}
	next := domain.Channel_Binding{
		binding_id = platform.generate_id(s.ids, "chb_"), owner_user_id = pairing.owner_user_id, bot_id = bot.bot_id,
		provider = a.provider, external_chat_id = update.external_chat_id, external_user_id = update.external_user_id,
		external_display = update.sender_display, state = .Active, created_at = now,
		last_inbound_at = update.provider_time if update.provider_time != "" else now,
	}
	previous: domain.Channel_Binding
	had_previous: bool
	activate_err: domain.Domain_Error
	if generation>0 {
		if !update.chat_is_private || update.external_chat_id=="" || update.external_user_id=="" ||
		   (bound && binding.external_user_id!=update.external_user_id) {
			return copy.pair_invalid,"","","",{}
		}
		// The fresh binding's unique ID distinguishes replacements in the same
		// activation. No old binding is promoted and no history is imported.
		previous,had_previous,activate_err=iface.bot_channel_conversion_binding_activate_fresh(s.repo,next,hash,now,generation,1,update.update_key)
	} else {
		previous,had_previous,activate_err=iface.binding_activate(s.repo,next,hash,now)
	}
	defer domain.channel_binding_destroy(&previous)
	if activate_err.code == .Conflict do return copy.pair_invalid, "", "", "", {}
	if activate_err.code != .None do return "", "", "", "", activate_err
	if generation>0 do return copy.paired,"",strings.clone(pairing.owner_user_id),strings.clone(bot.bot_id),{}
	if had_previous {
		if e := bots_revoke_contents(s, previous, now); e.code != .None do return "", "", "", "", e
	}
	return copy.paired, strings.clone(previous.external_chat_id) if had_previous && !bots_window_closed(a, previous, bots_stamp_ms(now)) else "", strings.clone(pairing.owner_user_id), strings.clone(bot.bot_id), {}
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

bots_disconnect :: proc(s: ^Bots_Service, owner_user_id, provider: string, notify: bool) -> domain.Domain_Error {
	return bots_disconnect_for_reason(s, owner_user_id, provider, notify, "binding_revoked")
}

// DELETE shares disconnect cleanup while preserving its bot_deleted terminal reason.
bots_disconnect_for_reason :: proc(s: ^Bots_Service, owner_user_id, provider: string, notify: bool, finish_reason: string) -> domain.Domain_Error {
	sync.mutex_lock(&s.mutex)
	if fence := bots_legacy_guard(s, owner_user_id); fence.code != .None {
		sync.mutex_unlock(&s.mutex)
		if fence.code==.Conflict && canonical_channel_enabled(s,provider,owner_user_id) {
			return bots_disconnect_canonical_owner(s,owner_user_id,provider)
		}
		return fence
	}
	binding, found, err := bots_disconnect_locked(s, owner_user_id, provider, finish_reason)
	sync.mutex_unlock(&s.mutex)
	defer domain.channel_binding_destroy(&binding)
	if err.code != .None do return err
	if !found do return bots_detail_error(.Not_Found, "binding_not_found")
	if notify && !bots_window_closed(bots_adapter(s, provider), binding, bots_stamp_ms(platform.clock_now(s.clock))) do bots_notice(s, provider, binding.external_chat_id, COPY_DISCONNECTED, owner_user_id)
	bots_publish_changed(s, owner_user_id, binding.bot_id)
	return {}
}

bots_disconnect_locked :: proc(s: ^Bots_Service, owner, provider, finish_reason: string) -> (domain.Channel_Binding, bool, domain.Domain_Error) {
	uow, ok, err := iface.unit_of_work_begin(s.uow_factory)
	if !ok do return {}, false, err
	defer if uow.ctx != nil do iface.unit_of_work_rollback(&uow)
	binding, found, get_err := iface.binding_get_active_by_owner(s.repo, owner, provider)
	if get_err.code != .None || !found do return binding, found, get_err
	now := platform.clock_now(s.clock)
	if e := iface.binding_revoke(s.repo, binding.binding_id, now); e.code != .None do return binding, found, e
	if e := bots_revoke_contents(s, binding, now, finish_reason); e.code != .None do return binding, found, e
	_, commit_err := bots_uow_commit(&uow)
	return binding, found, commit_err
}
