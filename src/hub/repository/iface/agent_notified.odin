package iface

import domain "odin_test:hub/domain"

// The PTY unread tray's message high-water mark (migration 272,
// contracts/agent_notified.odin): the newest user->agent message a typed
// unread notice covered, per conversation. Monotonic in transcript order
// (created_at, message_id).

Agent_Notified_Through :: struct {
	message_id: string, // "" when never notified
	created_at: string, // that message's created_at
}

// message_id must name a user->agent message of conversation_id (owner-scoped),
// else Not_Found; "" means the conversation's latest user->agent message (none:
// nothing moves). moved is false when the stored mark is at or after it.
Content_Note_Agent_Notified_Proc :: proc(ctx: rawptr, owner: domain.User_ID, conversation_id, message_id: string) -> (Agent_Notified_Through, bool, domain.Domain_Error)
Content_Agent_Notified_Through_Proc :: proc(ctx: rawptr, owner: domain.User_ID, conversation_id: string) -> (Agent_Notified_Through, domain.Domain_Error)

content_note_agent_notified :: proc(r: ^Content_Repository, owner: domain.User_ID, conversation_id, message_id: string) -> (Agent_Notified_Through, bool, domain.Domain_Error) {
	if r == nil || r.note_agent_notified == nil do return {}, false, domain.domain_error(.Internal_Error, "agent notified repository is not configured")
	return r.note_agent_notified(r.ctx, owner, conversation_id, message_id)
}

// Empty when never notified or the repository does not track it.
content_agent_notified_through :: proc(r: ^Content_Repository, owner: domain.User_ID, conversation_id: string) -> (Agent_Notified_Through, domain.Domain_Error) {
	if r == nil || r.agent_notified_through == nil do return {}, {}
	return r.agent_notified_through(r.ctx, owner, conversation_id)
}
