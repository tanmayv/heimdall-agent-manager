package bots

import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import content "odin_test:hub/service/content"
import vault "odin_test:lib/vault"
import channelvault "odin_test:lib/channelvault"

// R7 supplies the actual answered set. Reduction to one live pairing does
// not guess at origin, switch to a newly paired chat, or pick a provider from
// untrusted metadata.
canonical_reply_target :: proc(s: ^Bots_Service, repos: ^iface.Repositories, inst: domain.Agent_Instance, origin: domain.Reply_Origin, reply_id: string) -> (channelvault.Reply_Scope, domain.Domain_Error) {
	if origin.route_status != domain.REPLY_ROUTE_EXPLICIT && origin.route_status != domain.REPLY_ROUTE_ROUTED do return {},{}
	if origin.origin == "" || origin.origin == domain.REPLY_ORIGIN_LOCAL || len(origin.answered_message_ids) == 0 do return {},{}
	owner := string(inst.owner_user_id)
	state, found, err := iface.bot_web_activation_get(&repos.bots,owner)
	if err.code != .None do return {},err
	if !found || !state.enabled || state.agent_instance_id!=inst.agent_instance_id || state.conversation_id!=inst.conversation_id do return {},channel_conversion_denied()
	if gate := bots_gate_error(s.experiments,owner); gate.code != .None do return {},gate
	binding_id: string
	selected: string
	for input_id in origin.answered_message_ids {
		receipt, have, read_err := iface.bot_channel_conversion_input_source(&repos.bots,input_id)
		if read_err.code != .None do return {},read_err
		if !have || receipt.inbound_message_id != input_id do return {},channel_conversion_denied()
		if binding_id!="" && binding_id!=receipt.binding_id do return {},channel_conversion_denied()
		binding_id=receipt.binding_id
		_, present, input_err := read_canonical_conversion_message(&repos.content,inst,input_id,"user_to_agent")
		if input_err.code != .None do return {},input_err
		if !present do return {},channel_conversion_denied()
		selected=input_id
	}
	binding, have_binding, binding_err := iface.binding_get(&repos.bots,binding_id)
	if binding_err.code != .None do return {},binding_err
	if !have_binding || binding.state!=.Active || binding.owner_user_id!=owner || binding.bot_id!=state.bot_id ||
	   origin.origin!=strings.concatenate({binding.provider,"/",binding.binding_id},context.temp_allocator) {
		return {},channel_conversion_denied()
	}
	if !canonical_channel_enabled(s,binding.provider) do return {},channel_conversion_denied()
	grant, have_grant, grant_err := iface.bot_channel_conversion_binding_get(&repos.bots,binding_id)
	if grant_err.code != .None do return {},grant_err
	if !have_grant || grant.activation_generation!=state.generation || grant.binding_generation<1 do return {},channel_conversion_denied()
	if entitled, entitlement_err := bots_channel_entitled(s,binding.provider,owner); entitlement_err.code!=.None {
		return {},entitlement_err
	} else if !entitled do return {},channel_conversion_denied()
	return {owner,inst.agent_instance_id,inst.conversation_id,binding.provider,binding_id,grant.binding_generation,selected,reply_id},{}
}

// Compute the scope before the local author seals its own plaintext. This
// preview does not commit a reply, route, or watermark.
prepare_canonical_reply :: proc(s: ^Bots_Service, snapshot: domain.Agent_Instance, reply_to: string) -> (channelvault.Reply_Scope, domain.Reply_Origin, domain.Domain_Error) {
	if s==nil || s.uow_factory==nil || !s.canonical_telegram do return {},{},{}
	context.allocator=context.temp_allocator
	uow, begun, begin_err := iface.unit_of_work_begin(s.uow_factory)
	if !begun do return {},{},begin_err
	defer if uow.ctx!=nil do iface.unit_of_work_rollback(&uow)
	inst, found, err := iface.agent_get_instance(&uow.repos.agents,snapshot.agent_instance_id)
	if err.code != .None do return {},{},err
	if !found || !content.message_delivery_assignment_matches(inst,snapshot) do return {},{},channel_conversion_denied()
	state, enabled, err_state := iface.bot_web_activation_get(&uow.repos.bots,string(inst.owner_user_id))
	if err_state.code!=.None do return {},{},err_state
	if !enabled || !state.enabled || state.agent_instance_id!=inst.agent_instance_id || state.conversation_id!=inst.conversation_id do return {},{},{}
	c, have, chat_err := iface.content_get_conversation(&uow.repos.content,inst.conversation_id)
	if chat_err.code != .None do return {},{},chat_err
	if !have || c.owner_user_id!=inst.owner_user_id || c.agent_instance_id!=inst.agent_instance_id do return {},{},channel_conversion_denied()
	origin, _, _, route_err := content.reply_origin_preview(&uow.repos.content,c,reply_to)
	if route_err.code != .None do return {},{},route_err
	reply_id := platform.generate_id(s.ids,"msg_chreply_")
	scope, scope_err := canonical_reply_target(s,uow.repos,inst,origin,reply_id)
	if scope_err.code == .Forbidden do return {},origin,{}
	return scope,origin,scope_err
}

record_canonical_reply_proof :: proc(raw: rawptr, repos: ^iface.Repositories, m: domain.Chat_Message, origin: domain.Reply_Origin, proof: content.Reply_Source_Proof) -> domain.Domain_Error {
	s := (^Bots_Service)(raw)
	if m.message_type!="text" || proof.input_message_id=="" || len(proof.proof)!=64 || !vault.is_lower_hex(proof.proof) ||
	   !strings.has_prefix(m.message_id,"msg_chreply_") || !channelvault.valid_id(m.message_id) {
		return channel_conversion_denied()
	}
	if _,_,_, parsed := vault.envelope_header(m.body); parsed!=.Ok do return channel_conversion_denied()
	inst, found, err := iface.agent_get_instance(&repos.agents,m.sender_agent_instance_id)
	if err.code!=.None do return err
	if !found || inst.owner_user_id!=m.owner_user_id || inst.conversation_id!=m.conversation_id do return channel_conversion_denied()
	scope, scope_err := canonical_reply_target(s,repos,inst,origin,m.message_id)
	if scope_err.code!=.None do return scope_err
	if scope.input_message_id=="" || scope.input_message_id!=proof.input_message_id do return bots_detail_error(.Conflict,"channel_reply_origin_changed")
	if err := iface.bot_channel_conversion_reply_insert(&repos.bots,m.message_id,scope.input_message_id,proof.proof); err.code!=.None do return err
	if repos.bots.channel_reply_enqueue==nil do return domain.domain_error(.Internal_Error,"channel reply outbox is not configured")
	return repos.bots.channel_reply_enqueue(repos.bots.ctx,m.message_id,scope.owner_user_id,scope.provider)
}
