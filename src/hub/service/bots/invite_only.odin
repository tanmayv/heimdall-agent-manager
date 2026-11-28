package bots

import "core:sync"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

BOTS_WHATSAPP_INVITE_ONLY_REASON :: "whatsapp_invite_only"

// REQ-WAI-2c: when an account's effective `whatsapp_enabled` is off, its active
// WhatsApp binding is revoked exactly like a disconnect (pending messages purged,
// open delivery abandoned with reason whatsapp_invite_only) and the chat gets one
// invite-only notice. Two triggers call this: the next inbound message from that
// chat, and the periodic supervisor sweep. The revoke is the dedupe: once the
// binding is gone neither trigger finds it again, so the notice is sent once.
// `inbound` means the sender just wrote, so the reply window is open.
bots_whatsapp_invite_only_unbind :: proc(s: ^Bots_Service, owner_user_id: string, inbound: bool) -> (revoked: bool, err: domain.Domain_Error) {
	provider := domain.CHANNEL_PROVIDER_WHATSAPP
	sync.mutex_lock(&s.mutex)
	if bots_legacy_guard(s, owner_user_id).code != .None {
		sync.mutex_unlock(&s.mutex)
		return false, {}
	}
	binding, found, revoke_err := bots_disconnect_locked(s, owner_user_id, provider, BOTS_WHATSAPP_INVITE_ONLY_REASON)
	sync.mutex_unlock(&s.mutex)
	defer domain.channel_binding_destroy(&binding)
	if revoke_err.code != .None || !found do return false, revoke_err
	if inbound || !bots_window_closed(bots_adapter(s, provider), binding, bots_stamp_ms(platform.clock_now(s.clock))) {
		bots_notice(s, provider, binding.external_chat_id, COPY_WA_INVITE_ONLY, owner_user_id)
	}
	bots_publish_changed(s, owner_user_id, binding.bot_id)
	return true, {}
}

// Supervisor sweep (runs with the idle check, once a minute, without s.mutex):
// unbinds paired WhatsApp chats whose owner lost the entitlement even when they
// send nothing, so the bot stops replying there. Lookup failures skip the owner.
bots_whatsapp_entitlement_sweep :: proc(s: ^Bots_Service) {
	if s.whatsapp == nil do return
	// Snapshots are owned here and released explicitly; provider sends keep the
	// caller's allocator so adapter-owned strings are freed where allocated.
	bots, err := iface.bot_list(s.repo)
	defer {for &bot in bots do domain.bot_destroy(&bot); delete(bots)}
	if err.code != .None do return
	for bot in bots {
		entitled, lookup_err := bots_channel_entitled(s, domain.CHANNEL_PROVIDER_WHATSAPP, bot.owner_user_id)
		if entitled || lookup_err.code != .None do continue
		binding, bound, binding_err := iface.binding_get_active_by_owner(s.repo, bot.owner_user_id, domain.CHANNEL_PROVIDER_WHATSAPP)
		domain.channel_binding_destroy(&binding)
		if binding_err.code != .None || !bound do continue
		if canonical_channel_enabled(s,domain.CHANNEL_PROVIDER_WHATSAPP,bot.owner_user_id) && bots_legacy_guard(s,bot.owner_user_id).code==.Conflict {
			_ = bots_disconnect_canonical_owner(s,bot.owner_user_id,domain.CHANNEL_PROVIDER_WHATSAPP)
		} else {
			_, _ = bots_whatsapp_invite_only_unbind(s, bot.owner_user_id, false)
		}
	}
}
