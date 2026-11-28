package bots

import "core:encoding/json"
import "core:strings"
import "core:sync"
import "core:unicode/utf8"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// Returned message is caller-owned. Retry delivery even on replay: intake may
// have committed before a previous request failed to create its delivery.
bots_web_send :: proc(s: ^Bots_Service, owner, text, idempotency_key: string, attachments: []domain.Channel_Attachment = nil) -> (domain.Channel_Message, bool, domain.Domain_Error) {
	if len(text) > 16384 || (strings.trim_space(text) == "" && len(attachments) == 0) || !utf8.valid_string(text) do return {}, false, domain.domain_error(.Validation_Failed, "text must contain 1..16384 UTF-8 bytes")
	if len(idempotency_key) == 0 || len(idempotency_key) > 200 || strings.trim_space(idempotency_key) == "" || !utf8.valid_string(idempotency_key) do return {}, false, domain.domain_error(.Validation_Failed, "idempotency_key must contain 1..200 UTF-8 bytes")
	bot, err := bots_get(s, owner)
	defer domain.bot_destroy(&bot)
	if err.code != .None do return {}, false, err
	now := platform.clock_now(s.clock)
	// Preserve the legacy text-only hash; domain-separate attached payloads
	// so JSON-looking plain text cannot replay a different attachment payload.
	payload_hash := bots_pairing_hash(text)
	if len(attachments) > 0 {
		ids := make([dynamic]string, context.temp_allocator)
		append(&ids, text)
		for &a in attachments {
			a.attachment_id = strings.clone(platform.generate_id(s.ids, "cha_"), context.temp_allocator)
			append(&ids, a.artifact_id)
		}
		encoded, _ := json.marshal(ids[:], allocator = context.temp_allocator)
		payload_hash = strings.concatenate({"artifacts:", bots_pairing_hash(string(encoded))}, context.temp_allocator)
	}
	// Structured encoding prevents ambiguity between bot IDs and user keys.
	key, _ := json.marshal([]string{"web", bot.bot_id, idempotency_key}, allocator = context.temp_allocator)
	binding := domain.Channel_Binding{
		binding_id = platform.generate_id(s.ids, "chb_"), owner_user_id = owner,
		bot_id = bot.bot_id, provider = domain.CHANNEL_PROVIDER_WEB,
		external_chat_id = bot.bot_id, external_user_id = owner, state = .Active, created_at = now,
	}
	// generate_id may use scratch storage reused by its next call.
	binding.binding_id = strings.clone(binding.binding_id, context.temp_allocator)
	message := domain.Channel_Message{
		message_id = platform.generate_id(s.ids, "chm_"), owner_user_id = owner, bot_id = bot.bot_id,
		direction = .Inbound, provider_update_key = strings.concatenate({"web:", bots_pairing_hash(string(key))}, context.temp_allocator),
		external_message_id = payload_hash, body = text, created_at = now,
	}
	stored: domain.Channel_Message
	fresh: bool
	{
		sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
		if fence := bots_legacy_guard(s, owner); fence.code != .None do return {}, false, fence
		stored, fresh, err = iface.web_message_store(s.repo, binding, message, attachments)
	}
	if err.code != .None do return stored, fresh, err
	if fresh do bots_publish_changed(s, owner, bot.bot_id)
	ms, _ := platform.rfc3339_to_unix_ms(now)
	rows := []domain.Channel_Message{stored} if fresh else nil
	err = delivery_on_inbound(s, bot.bot_id, ms, rows)
	return stored, fresh, err
}
