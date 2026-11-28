package bots

import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import vault "odin_test:lib/vault"

// Complete, replay-comparable authorization snapshot. Strings use request
// scratch. It is internal, never accepted as caller input or serialized as a
// public request. request.body is a raw, validated token, not a wire frame.
Channel_Vault_Prepared :: struct {
	request: contracts.Bot_Channel_Vault_Request,
	bridge_id, provider, recipient, external_user_id: string,
	input_token_digest, origin_event_id: string,
	instance_revision, instance_run_count, placement_revision: int,
}

channel_conversion_denied :: proc() -> domain.Domain_Error {
	return bots_detail_error(.Forbidden, "channel_conversion_source_inactive")
}

read_channel_conversion_source :: proc(s: ^Bots_Service, repos: ^iface.Repositories, owner, binding_id, event_id, input_id, reply_id: string) -> (Channel_Vault_Prepared, domain.Domain_Error) {
	if repos == nil do return {}, domain.domain_error(.Internal_Error,"channel conversion repositories are not configured")
	if owner == "" do return {}, channel_conversion_denied()
	if reply_id == "" {
		if binding_id == "" || event_id == "" || !strings.has_prefix(input_id,"msg_") do return {}, channel_conversion_denied()
	} else if !strings.has_prefix(reply_id,"msg_") do return {}, channel_conversion_denied()
	if gate := bots_gate_error(s.experiments,owner); gate.code != .None do return {}, gate
	activity, activated, err := iface.bot_web_activation_get(&repos.bots,owner)
	if err.code != .None do return {}, err
	if !activated || !activity.enabled || activity.owner_user_id != owner || activity.generation < 1 do return {}, channel_conversion_denied()
	bot, bot_found, bot_err := iface.bot_get(&repos.bots,activity.bot_id)
	if bot_err.code != .None do return {}, bot_err
	if !bot_found || bot.owner_user_id != owner do return {}, channel_conversion_denied()
	inst, inst_found, inst_err := iface.agent_get_instance(&repos.agents,activity.agent_instance_id)
	if inst_err.code != .None && inst_err.code != .Not_Found do return {}, inst_err
	if !inst_found || string(inst.owner_user_id) != owner || inst.conversation_id != activity.conversation_id ||
	   inst.agent_instance_id == bot.agent_instance_id || inst.bridge_id == "" {
		return {}, channel_conversion_denied()
	}
	if placement_err := check_web_runtime_policy(s,inst,inst.bridge_id,inst.provider,inst.model,inst.model); placement_err.code != .None do return {}, placement_err
	conv, conv_found, conv_err := iface.content_get_conversation(&repos.content,activity.conversation_id)
	if conv_err.code != .None && conv_err.code != .Not_Found do return {}, conv_err
	if !conv_found || string(conv.owner_user_id) != owner || conv.agent_instance_id != inst.agent_instance_id ||
	   conv.agent_id != inst.agent_id {
		return {}, channel_conversion_denied()
	}

	binding_id, event_id, input_id := binding_id,event_id,input_id
	source_proof, reply_token, input_digest: string
	op := "seal"
	if reply_id != "" {
		op = "open"
		decision, selected, decision_err := iface.bot_channel_conversion_reply_source(&repos.bots,reply_id)
		if decision_err.code != .None do return {}, decision_err
		if !selected || len(decision.source_proof) != 64 || !vault.is_lower_hex(decision.source_proof) do return {}, channel_conversion_denied()
		binding_id, event_id, input_id = decision.origin.binding_id,decision.origin.provider_update_key,decision.origin.inbound_message_id
		source_proof = decision.source_proof
		reply, found, read_err := read_canonical_conversion_message(&repos.content,inst,reply_id,"agent_to_user")
		if read_err.code != .None do return {}, read_err
		if !found do return {}, channel_conversion_denied()
		reply_token = reply.body
		origin, origin_found, origin_err := read_canonical_conversion_message(&repos.content,inst,input_id,"user_to_agent")
		if origin_err.code != .None do return {}, origin_err
		if !origin_found do return {}, channel_conversion_denied()
		input_digest = contracts.bot_channel_vault_sha256_hex(transmute([]byte)origin.body,context.temp_allocator)
	}

	grant, granted, grant_err := iface.bot_channel_conversion_binding_get(&repos.bots,binding_id)
	if grant_err.code != .None do return {}, grant_err
	if !granted || grant.activation_generation != activity.generation || grant.binding_generation < 1 do return {}, channel_conversion_denied()
	binding, bound, binding_err := iface.binding_get(&repos.bots,binding_id)
	if binding_err.code != .None && binding_err.code != .Not_Found do return {}, binding_err
	if !bound || binding.state != .Active || binding.owner_user_id != owner || binding.bot_id != bot.bot_id ||
	   binding.external_chat_id == "" ||
	   (binding.provider != domain.CHANNEL_PROVIDER_TELEGRAM && binding.provider != domain.CHANNEL_PROVIDER_WHATSAPP) {
		return {}, channel_conversion_denied()
	}
	entitled, entitlement_err := bots_channel_entitled(s,binding.provider,owner)
	if entitlement_err.code != .None do return {}, entitlement_err
	if !entitled do return {}, channel_conversion_denied()

	if op == "seal" {
		_, exists, message_err := iface.content_get_message(&repos.content,input_id)
		if message_err.code != .None && message_err.code != .Not_Found do return {}, message_err
		reused, origin_err := iface.bot_channel_conversion_origin_exists(&repos.bots,binding_id,event_id,input_id)
		if origin_err.code != .None do return {}, origin_err
		// Conversion is for fresh work only. A durable ingress caller must
		// replay an accepted receipt rather than re-seal a used ID/event.
		if exists || reused do return {}, bots_detail_error(.Conflict,"channel_conversion_source_in_use")
	}

	return {
		request={
			type=contracts.BOT_CHANNEL_VAULT_REQUEST_FRAME, operation=op,
			owner_user_id=owner, bridge_id=inst.bridge_id, agent_instance_id=inst.agent_instance_id,
			conversation_id=conv.conversation_id, activation_generation=activity.generation,
			provider=binding.provider, provider_event_id=event_id if op == "seal" else "", binding_id=binding_id,
			binding_generation=grant.binding_generation, input_message_id=input_id, reply_message_id=reply_id,
			source_proof=source_proof, body=reply_token,
		},
		bridge_id=inst.bridge_id, provider=binding.provider, recipient=binding.external_chat_id, external_user_id=binding.external_user_id,
		input_token_digest=input_digest, origin_event_id=event_id, instance_revision=inst.configuration_revision,
		instance_run_count=inst.run_count, placement_revision=bot.placement_revision,
	}, {}
}

read_canonical_conversion_message :: proc(repo: ^iface.Content_Repository, inst: domain.Agent_Instance, id, direction: string) -> (domain.Chat_Message,bool,domain.Domain_Error) {
	msg, found, err := iface.content_get_message(repo,id)
	if err.code != .None && err.code != .Not_Found do return {},false,err
	if !found || msg.owner_user_id != inst.owner_user_id || msg.conversation_id != inst.conversation_id ||
	   msg.direction != direction || msg.sender_agent_instance_id != inst.agent_instance_id ||
	   msg.message_type != "text" || msg.message_status != "complete" ||
	   len(msg.body) > contracts.BOT_CHANNEL_VAULT_MAX_TOKEN {
		return {},false,{}
	}
	_, _, _, parsed := vault.envelope_header(msg.body)
	if parsed != .Ok do return {},false,{}
	return msg,true,{}
}
