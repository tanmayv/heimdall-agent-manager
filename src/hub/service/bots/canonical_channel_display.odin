package bots

import "core:encoding/json"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import content "odin_test:hub/service/content"
import events "odin_test:hub/service/events"

// This is a projection only. Never use metadata from a client to select a
// pairing, and never expose the provider address, receipt key or source proof.
channel_message_display :: proc(raw: rawptr, m: domain.Chat_Message) -> content.Channel_Display {
	s := (^Bots_Service)(raw)
	context.allocator=context.temp_allocator
	if s==nil || s.canonical_content==nil do return {}
	if m.direction=="user_to_agent" {
		if !strings.has_prefix(m.message_id,"msg_channel_") do return {}
		origin, err := iface.content_message_origin(s.canonical_content.content,m.message_id)
		if err.code!=.None do return {}
		provider := channel_display_provider(origin)
		return {provider,"received"} if provider!="" else {}
	}
	if m.direction!="agent_to_user" || m.message_type!="text" do return {}
	activation, active, err := iface.bot_web_activation_get(s.repo,string(m.owner_user_id))
	if err.code!=.None || !active || activation.conversation_id!=m.conversation_id || activation.agent_instance_id!=m.sender_agent_instance_id do return {}
	metadata: struct {reply_origin: domain.Reply_Origin}
	if json.unmarshal_string(m.metadata_json,&metadata,allocator=context.temp_allocator)!=nil do return {}
	origin := metadata.reply_origin
	provider := channel_display_provider(origin.origin)
	if s.repo.channel_reply_state!=nil {
		status, read_err := s.repo.channel_reply_state(s.repo.ctx,m.message_id,string(m.owner_user_id))
		if read_err.code==.None && status!="" do return {provider,status}
	}
	if origin.route_status==domain.REPLY_ROUTE_AMBIGUOUS && len(origin.answered_message_ids)>0 do return {"web","ambiguous"}
	if provider!="" {
		inst := domain.Agent_Instance{owner_user_id=m.owner_user_id,agent_instance_id=m.sender_agent_instance_id,conversation_id=m.conversation_id}
		repos := iface.Repositories{bots=s.repo^,content=s.canonical_content.content^}
		scope, _ := canonical_reply_target(s,&repos,inst,origin,m.message_id)
		if scope.binding_id=="" do return {provider,"stale"}
		return {"web","no_proof"}
	}
	return {"web","web_only"}
}

channel_display_provider :: proc(origin: string) -> string {
	if strings.has_prefix(origin,"telegram/") do return "telegram"
	if strings.has_prefix(origin,"whatsapp/") do return "whatsapp"
	return ""
}

// Targeted invalidation of the shared pane. The WS notification never embeds
// the vault envelope, source proof, address or caption.
publish_canonical_channel_change :: proc(s: ^Bots_Service,m: domain.Chat_Message,event: string) {
	if s.event_bus==nil do return
	raw, err := json.marshal(struct {
		type,event,direction,conversation_id,agent_instance_id,message_id: string,
		fetch_required: bool,
		fetch_kind,fetch_id: string,
	}{"chat_event",event,m.direction if event!="messages_delivery" else "",m.conversation_id,m.sender_agent_instance_id,m.message_id,true,
		"chat_message",m.message_id},allocator=context.temp_allocator)
	if err==nil do events.publish_owned(s.event_bus,string(m.owner_user_id),string(raw))
}
