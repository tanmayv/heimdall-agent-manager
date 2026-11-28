package contracts

// How far the agent was pointed at its unread user messages (PTY unread tray),
// as a message high-water mark: the newest user->agent message a typed
// unread-messages notice covered. Clocks are never compared.
//
// Bridge -> Hub (hub-runtime WebSocket): Agent_Notice_Typed_Frame. A runtime
// whose Send now is a notice (RUNTIME_SEND_NOW_WIRE "notice") reports it after
// the bridge committed a typed batch that carried the unread-messages notice;
// last_message_id is the hub message id that notice entry stands for (the
// coalesced entry carries the newest one). A failed typing is never reported.
// Reports wait in bridge memory while the hub socket is down; a bridge restart
// loses a pending report, and the tray stays "waiting" until the next notice.
//
// The Hub accepts a report only from the bridge that owns the instance, for a
// user->agent message of that instance's conversation, and stores it per
// conversation only when it is later in transcript order (created_at, then
// message_id). A delivered notice Send now stamps the conversation's latest
// user->agent message the same way.
//
// Hub -> UI: GET /api/v1/chats/{cid}/send-now carries the mark as
// SEND_NOW_NOTIFIED_THROUGH_MESSAGE_ID_FIELD and
// SEND_NOW_NOTIFIED_THROUGH_CREATED_AT_FIELD (the message's created_at,
// canonical RFC 3339 UTC), both "" when never notified. An older hub omits
// them. Mirrored in src/ui/api/agentNotified.ts.
AGENT_NOTICE_TYPED_FRAME :: "agent_notice_typed"

Agent_Notice_Typed_Frame :: struct {
	type:              string `json:"type"`, // AGENT_NOTICE_TYPED_FRAME
	agent_instance_id: string `json:"agent_instance_id"`,
	last_message_id:   string `json:"last_message_id"`,
}

SEND_NOW_NOTIFIED_THROUGH_MESSAGE_ID_FIELD :: "agent_notified_through_message_id"
SEND_NOW_NOTIFIED_THROUGH_CREATED_AT_FIELD :: "agent_notified_through_created_at"
