package contracts

// Delivery result of a user message to an agent (R7, D5).
//
// POST /chats/{id}/messages answers the stored message with
// "delivery": Message_Delivery_Wire. MCP chains.message reports the same
// state as its "status" and the reason as "delivery_warning"; its stored
// replay receipt always says pending (persistence only).
//
// accepted: the running agent's bridge was sent the notice. pending: the
// message is stored and unread, but the agent is not running, still starting,
// or its bridge could not be reached; reason says which. A message to a
// stopped or dead agent is never accepted. Mirrored in
// src/ui/api/messageDelivery.ts.
MESSAGE_DELIVERY_ACCEPTED :: "accepted"
MESSAGE_DELIVERY_PENDING :: "pending"

MESSAGE_DELIVERY_REASON_AGENT_NOT_FOUND :: "agent_not_found"
MESSAGE_DELIVERY_REASON_AGENT_NOT_RUNNING :: "agent_not_running"
MESSAGE_DELIVERY_REASON_AGENT_STARTING :: "agent_starting"
MESSAGE_DELIVERY_REASON_AGENT_START_FAILED :: "agent_start_failed"
MESSAGE_DELIVERY_REASON_BRIDGE_OFFLINE :: "bridge_offline"
MESSAGE_DELIVERY_REASON_DELIVERY_UNAVAILABLE :: "delivery_unavailable"
MESSAGE_DELIVERY_REASON_CONVERSATION_UNAVAILABLE :: "conversation_unavailable"

Message_Delivery_Wire :: struct {
	state:  string `json:"state"`,  // MESSAGE_DELIVERY_ACCEPTED | MESSAGE_DELIVERY_PENDING
	reason: string `json:"reason"`, // MESSAGE_DELIVERY_REASON_*; "" when accepted
}
