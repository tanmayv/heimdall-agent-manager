package bots

import "core:sync"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import channel "odin_test:hub/service/channel"

// Row existence, not enabled, permanently fences this legacy deployment.
// Re-enabling canonical web reuses its conversation, not legacy work.
bots_legacy_guard :: proc(s: ^Bots_Service, owner: string) -> domain.Domain_Error {
	if owner == "" || s.repo == nil || s.repo.web_activation_get == nil do return {}
	row, activated, err := iface.bot_web_activation_get(s.repo, owner)
	defer domain.bot_web_activation_destroy(&row)
	if err.code != .None do return err
	if activated do return bots_detail_error(.Conflict, "bot_generation_inactive")
	return {}
}

// Serialize admission to a single external attempt against activation. An
// attempt admitted before activation can finish on the old side, but every
// subsequent chunk, retry or feedback call must obtain its own admission.
bots_legacy_provider_admit :: proc(s: ^Bots_Service, owner: string) -> bool {
	sync.mutex_lock(&s.legacy_fence_mutex)
	defer sync.mutex_unlock(&s.legacy_fence_mutex)
	return bots_legacy_guard(s, owner).code == .None
}

// Late callbacks can be safely acknowledged to retire the bridge's retry,
// but cannot change or restart work from a fenced delivery.
bots_legacy_attempt_guard :: proc(s: ^Bots_Service, attempt: domain.Bot_Delivery_Attempt) -> domain.Domain_Error {
	if s.repo == nil || s.repo.web_activation_get == nil do return {}
	d, found, err := iface.delivery_get(s.repo, attempt.delivery_id)
	defer domain.bot_delivery_destroy(&d)
	if err.code != .None do return err
	if !found do return bots_detail_error(.Not_Found, "bot_attempt_not_found")
	return bots_legacy_guard(s, d.owner_user_id)
}

// A retired owner's incoming mobile payload must not be newly staged as legacy
// plaintext. A provider status receipt contains no user payload and may still
// update the original outbound disposition (never release held sends).
bots_legacy_push_guard :: proc(s: ^Bots_Service, provider: string, update: channel.Inbound) -> domain.Domain_Error {
	if s.repo == nil || s.repo.web_activation_get == nil || update.kind == .Delivery_Failed do return {}
	binding, found, err := bots_find_binding(s, provider, update.external_chat_id, update.external_user_id)
	defer domain.channel_binding_destroy(&binding)
	if err.code != .None do return err
	if found {
		if e := bots_legacy_guard(s, binding.owner_user_id); e.code != .None do return e
	}
	if update.kind == .Start && update.text != "" {
		pairing, paired, pair_err := iface.pairing_get(s.repo, bots_pairing_hash(update.text))
		defer domain.channel_pairing_destroy(&pairing)
		if pair_err.code != .None do return pair_err
		if paired do return bots_legacy_guard(s, pairing.owner_user_id)
	}
	return {}
}
