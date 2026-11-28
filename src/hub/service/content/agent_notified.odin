package content

import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// agent_notified_at: when the agent was last pointed at its unread messages
// (the bridge typed the unread notice, or a notice Send now was delivered).
// One timestamp per conversation, monotonic; the UI shows an unread message as
// notified when it was created at or before it.

// note_agent_notice_typed applies a bridge's agent_notice_typed report. Only
// the bridge that owns the instance may report it. The stored time never
// exceeds the Hub's own clock (a bridge clock ahead is clamped). Returns the
// conversation and whether the stored time moved.
note_agent_notice_typed :: proc(s: ^Content_Service, bridge_id, instance_id: string, typed_at_ms: i64) -> (domain.Chat_Conversation, bool, domain.Domain_Error) {
	if s.agents == nil do return {}, false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	if bridge_id == "" || instance_id == "" do return {}, false, domain.domain_error(.Validation_Failed, "agent notice report needs a bridge and an instance")
	inst, found, _ := iface.agent_get_instance(s.agents, instance_id)
	if !found || inst.bridge_id != bridge_id do return {}, false, domain.domain_error(.Not_Found, "agent instance not found")
	c, have, cerr := iface.content_conversation_by_instance(s.content, inst.owner_user_id, instance_id)
	if !have do return {}, false, cerr
	at := agent_notified_time(platform.clock_now(s.clock), typed_at_ms)
	moved, err := iface.content_note_agent_notified(s.content, c.owner_user_id, c.conversation_id, at)
	return c, moved, err
}

// agent_notified_time is min(typed_at, now) in the Hub's canonical format;
// typed_at_ms <= 0 means "now".
agent_notified_time :: proc(now: string, typed_at_ms: i64) -> string {
	if typed_at_ms <= 0 do return now
	typed := platform.format_rfc3339_utc(time.unix(0, typed_at_ms * 1_000_000))
	return typed if typed < now else now
}
