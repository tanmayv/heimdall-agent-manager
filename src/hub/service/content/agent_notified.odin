package content

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// The unread tray's message high-water mark (contracts/agent_notified.odin):
// the newest user->agent message a typed unread notice covered. Clocks are
// never compared; the mark moves only forward in transcript order.

// note_agent_notice_typed applies a bridge's agent_notice_typed report. Only
// the bridge that owns the instance may report it, and only for a user->agent
// message of that instance's conversation. Returns the conversation and
// whether the mark moved.
note_agent_notice_typed :: proc(s: ^Content_Service, bridge_id, instance_id, message_id: string) -> (domain.Chat_Conversation, bool, domain.Domain_Error) {
	if s.agents == nil do return {}, false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	if bridge_id == "" || instance_id == "" || message_id == "" do return {}, false, domain.domain_error(.Validation_Failed, "agent notice report needs a bridge, an instance and a message")
	inst, found, _ := iface.agent_get_instance(s.agents, instance_id)
	if !found || inst.bridge_id != bridge_id do return {}, false, domain.domain_error(.Not_Found, "agent instance not found")
	c, have, cerr := iface.content_conversation_by_instance(s.content, inst.owner_user_id, instance_id)
	if !have do return {}, false, cerr
	_, moved, err := iface.content_note_agent_notified(s.content, c.owner_user_id, c.conversation_id, message_id)
	return c, moved, err
}

// note_agent_notified_latest stamps the conversation's latest user->agent
// message: a delivered notice Send now pointed the agent at all of them.
note_agent_notified_latest :: proc(s: ^Content_Service, owner: domain.User_ID, conversation_id: string) -> bool {
	_, moved, _ := iface.content_note_agent_notified(s.content, owner, conversation_id, "")
	return moved
}
