package contracts

// When the agent was last pointed at its unread user messages (PTY unread tray).
//
// Bridge -> Hub (hub-runtime WebSocket): Agent_Notice_Typed_Frame. A runtime
// whose Send now is a notice (RUNTIME_SEND_NOW_WIRE "notice") reports it after
// the bridge committed a typed batch that carried the unread-messages notice;
// a failed typing is never reported. typed_at_ms is the bridge clock at that
// commit; the Hub never stores a time later than its own clock.
//
// Hub -> UI: GET /api/v1/chats/{cid}/send-now carries the conversation's one
// stored time as SEND_NOW_AGENT_NOTIFIED_AT_FIELD (canonical RFC 3339 UTC,
// "" when never). It only moves forward. A delivered notice Send now also
// stamps it. Mirrored in src/ui/api/agentNotified.ts.
AGENT_NOTICE_TYPED_FRAME :: "agent_notice_typed"

Agent_Notice_Typed_Frame :: struct {
	type:              string `json:"type"`, // AGENT_NOTICE_TYPED_FRAME
	agent_instance_id: string `json:"agent_instance_id"`,
	typed_at_ms:       i64 `json:"typed_at_ms"`, // bridge unix ms; <= 0 = the Hub's receipt
}

SEND_NOW_AGENT_NOTIFIED_AT_FIELD :: "agent_notified_at"
