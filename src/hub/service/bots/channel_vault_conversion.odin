package bots

import "core:strings"
import "core:unicode/utf8"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import channel "odin_test:hub/service/channel"
import vault "odin_test:lib/vault"

Channel_Vault_Exchange :: struct {
	ctx: rawptr,
	run: proc(ctx: rawptr, generation: int, req: contracts.Bot_Channel_Vault_Request) -> (contracts.Bot_Channel_Vault_Result, bool),
}

// A provider adapter may use the borrowed UTF-8 text during the callback.
// The conversion does not perform a provider send or decide its disposition.
Bound_Reply_Consumer :: struct {
	ctx: rawptr,
	accept: proc(ctx: rawptr, provider, recipient, text: string),
}

// Called by verified channel intake before any message/spool write. The caller
// owns the returned ordinary vault envelope and its provider-event receipt.
seal_channel_input :: proc(s: ^Bots_Service, owner, binding_id, input_message_id, provider: string, event: channel.Inbound) -> (string, domain.Domain_Error) {
	if event.kind != .Text || event.external_chat_id == "" || event.external_user_id == "" ||
	   len(event.text) == 0 || len(event.text) > contracts.BOT_CHANNEL_VAULT_MAX_PLAINTEXT || !utf8.valid_string(event.text) {
		return "", bots_detail_error(.Validation_Failed, "channel_vault_invalid_input")
	}
	return convert_channel_text(s, {owner=owner, binding=binding_id, input=input_message_id, provider=provider, event=event}, {})
}

// The originating message and destination are resolved from durable records.
// No caller-selected ciphertext, recipient or proof enters the open path.
with_bound_channel_reply :: proc(s: ^Bots_Service, owner, reply_message_id: string, consumer: Bound_Reply_Consumer) -> domain.Domain_Error {
	if reply_message_id == "" || consumer.accept == nil do return bots_detail_error(.Validation_Failed, "channel_vault_invalid_reply")
	_, err := convert_channel_text(s, {owner=owner, reply=reply_message_id}, consumer)
	return err
}

@(private="file")
Conversion_Intent :: struct {
	owner, binding, input, provider, reply: string,
	event: channel.Inbound,
}

// Read both authorities in one transaction. Release the transaction before
// writing to a socket, waiting for the bridge, or invoking the recipient.
@(private="file")
channel_conversion_snapshot :: proc(s: ^Bots_Service, intent: Conversion_Intent) -> (Channel_Vault_Prepared, Channel_Vault_Authority, domain.Domain_Error) {
	context.allocator = context.temp_allocator
	uow, begun, begin_err := iface.unit_of_work_begin(s.uow_factory)
	if !begun do return {}, {}, begin_err
	defer if uow.ctx != nil do iface.unit_of_work_rollback(&uow)
	prepared, err := read_channel_conversion_source(s, uow.repos, intent.owner, intent.binding, intent.event.update_key, intent.input, intent.reply)
	if err.code != .None do return {}, {}, err
	if intent.reply == "" && (prepared.provider != intent.provider || prepared.recipient != intent.event.external_chat_id || prepared.external_user_id != intent.event.external_user_id) {
		return {}, {}, bots_detail_error(.Forbidden, "channel_vault_origin_mismatch")
	}
	authority, auth_err := channel_vault_authority(s, intent.owner, prepared.bridge_id)
	if auth_err.code != .None do return {}, {}, auth_err
	committed, commit_err := iface.unit_of_work_commit(&uow)
	uow.ctx = nil
	if !committed do return {}, {}, commit_err
	return prepared, authority, {}
}

@(private="file")
convert_channel_text :: proc(s: ^Bots_Service, intent: Conversion_Intent, consumer: Bound_Reply_Consumer) -> (string, domain.Domain_Error) {
	initial, authority, ref_err := channel_conversion_snapshot(s, intent)
	if ref_err.code != .None do return "", ref_err
	req := initial.request
	req.vault_id, req.vault_epoch = authority.vault_id, authority.vault_epoch
	if intent.reply == "" do req.body = intent.event.text
	if s.channel_vault_exchange.run == nil do return "", bots_detail_error(.Bridge_Offline, "channel_vault_bridge_unavailable")
	result, received := s.channel_vault_exchange.run(s.channel_vault_exchange.ctx, authority.connection_generation, req)
	defer contracts.bot_channel_vault_result_destroy(&result)
	if !received do return "", bots_detail_error(.Bridge_Timeout, "channel_vault_exchange_unavailable")
	// A bridge may have finished after pairing, placement or the vault changed.
	// Always resolve the original references again before releasing any bytes.
	current, now, current_err := channel_conversion_snapshot(s, intent)
	if current_err.code != .None do return "", current_err
	if current != initial do return "", bots_detail_error(.Conflict, "channel_vault_source_changed")
	if now != authority do return "", bots_detail_error(.Conflict, "channel_vault_authority_changed")
	if result.operation != req.operation do return "", bots_detail_error(.Conflict, "channel_vault_operation_mismatch")
	switch result.status {
	case "ok":
	case "vault_locked", "key_unavailable": return "", domain.vault_locked_error(initial.bridge_id)
	case "stale_placement": return "", bots_detail_error(.Conflict, "channel_vault_placement_changed")
	case "owner_mismatch", "invalid_scope": return "", bots_detail_error(.Forbidden, "channel_vault_scope_refused")
	case: return "", bots_detail_error(.Validation_Failed, "channel_vault_invalid_response")
	}
	if intent.reply != "" {
		if len(result.body) == 0 || len(result.body) > contracts.BOT_CHANNEL_VAULT_MAX_PLAINTEXT || !utf8.valid_string(result.body) do return "", bots_detail_error(.Validation_Failed, "channel_vault_invalid_response")
		consumer.accept(consumer.ctx, current.provider, current.recipient, result.body)
		return "", {}
	}
	if len(result.body) > contracts.BOT_CHANNEL_VAULT_MAX_TOKEN do return "", bots_detail_error(.Validation_Failed, "channel_vault_invalid_response")
	vid, epoch, cipher, parsed := vault.envelope_parse(result.body, context.temp_allocator)
	defer delete(cipher, context.temp_allocator)
	expected, valid_id := vault.vault_id_from_hex(authority.vault_id)
	if parsed != .Ok || !valid_id || vid != expected || epoch != authority.vault_epoch || len(cipher) != len(intent.event.text) + vault.HEADER_BYTES {
		return "", bots_detail_error(.Validation_Failed, "channel_vault_invalid_envelope")
	}
	return strings.clone(result.body), {}
}
