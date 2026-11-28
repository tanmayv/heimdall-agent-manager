package iface

import domain "odin_test:hub/domain"

// agent_notified_at (migration 272): when the bridge last typed the notice that
// points the agent at its unread messages. Monotonic: an older time is ignored.
Content_Note_Agent_Notified_Proc :: proc(ctx: rawptr, owner: domain.User_ID, conversation_id, at: string) -> (bool, domain.Domain_Error)
Content_Agent_Notified_At_Proc :: proc(ctx: rawptr, owner: domain.User_ID, conversation_id: string) -> (string, domain.Domain_Error)

content_note_agent_notified :: proc(r: ^Content_Repository, owner: domain.User_ID, conversation_id, at: string) -> (bool, domain.Domain_Error) {
	if r == nil || r.note_agent_notified == nil do return false, domain.domain_error(.Internal_Error, "agent notified repository is not configured")
	return r.note_agent_notified(r.ctx, owner, conversation_id, at)
}
// "" when never notified or the repository does not track it.
content_agent_notified_at :: proc(r: ^Content_Repository, owner: domain.User_ID, conversation_id: string) -> (string, domain.Domain_Error) {
	if r == nil || r.agent_notified_at == nil do return "", {}
	return r.agent_notified_at(r.ctx, owner, conversation_id)
}
