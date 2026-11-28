package content

import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import agent "odin_test:hub/service/agent"
import platform "odin_test:hub/platform"

// Persistence only: callers with a UOW commit the message, conversation preview
// and their receipt together before invoking deliver_user_message.
persist_user_message :: proc(s:^Content_Service,auth:contracts.Auth_Context,cid:string,input:Message_Input, request_message_id := "")->(domain.Chat_Message,bool,domain.Domain_Error) {
	c,ok,err:=get_conversation(s,auth,cid)
	if !ok do return {},false,err
	if s.agent_configuration_service!=nil {
		if valid,e:=agent.validate_instance_message_configuration(s.agent_configuration_service,c.owner_user_id,c.agent_instance_id);!valid do return {},false,e
	} else {
		if idle,e:=agent.reconfiguration_require_idle(&agent.Agent_Service{agents=s.agents},c.agent_instance_id);!idle do return {},false,e
	}
	if valid,e:=validate_initial_message_for_owner(s,c.owner_user_id,input);!valid do return {},false,e
	now:=platform.clock_now(s.clock)
	kind:=input.message_type;if kind=="" do kind="text"
	id := request_message_id
	if id == "" do id = platform.generate_id(s.ids, "msg_")
	m:=domain.Chat_Message{message_id=id,conversation_id=c.conversation_id,owner_user_id=c.owner_user_id,direction="user_to_agent",sender_agent_id=c.agent_id,sender_agent_instance_id=c.agent_instance_id,body=input.body,artifact_ids_json=artifact_json_or_empty(input.artifact_ids_json),message_type=kind,metadata_json=input.metadata_json,created_at=now}
	saved,written,werr:=iface.content_save_message(s.content,m)
	if !written do return {},false,werr
	c.last_message_preview=input.body;c.last_message_at=now;c.updated_at=now
	if _,updated,uerr:=iface.content_save_conversation(s.content,c);!updated do return {},false,uerr
	acp_delivery_record_sent(s,c,saved)
	return saved,true,{}
}

// Shared normal user-message effects, always invoked after durable persistence.
deliver_user_message :: proc(s:^Content_Service,auth:contracts.Auth_Context,cid:string,m:domain.Chat_Message)->(bool,domain.Domain_Error) {
	c,ok,err:=get_conversation(s,auth,cid)
	if !ok do return false,err
	notify_message_attention(s,m)
	notified,nerr:=notify_agent_message_checked(s,c,"user_to_agent","user",m.message_id,"User")
	record_activity_and_maybe_nudge(s,cid,m.created_at)
	note_user_activity(s,c.agent_instance_id)
	return notified,nerr
}

// User_Activity_Hook reports a USER event addressed to an agent instance
// (chat, action card, question answer) after it committed. Wiring points it at
// the task engine's coordinator idle-stop stamp (taskv2.note_user_activity).
// Agent-authored messages, notices and reads never call it.
User_Activity_Hook :: struct {
	ctx: rawptr,
	run: proc(ctx: rawptr, instance_id: string),
}

note_user_activity :: proc(s:^Content_Service, instance_id:string) {
	if s==nil || s.user_activity.run==nil || instance_id=="" do return
	s.user_activity.run(s.user_activity.ctx,instance_id)
}

// note_action_card_answered: the user accepting / rejecting / discarding an
// action card an agent sent them (chat send --actions) is a user event for
// that agent. Cards no message carried (curator cards) have no addressee.
note_action_card_answered :: proc(s:^Content_Service, owner:domain.User_ID, card_id:string) {
	if s==nil || s.user_activity.run==nil do return
	sender,found,_:=iface.content_action_card_sender(s.content,owner,card_id)
	if found do note_user_activity(s,sender)
}
