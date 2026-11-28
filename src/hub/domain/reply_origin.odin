package domain

// Reply origin (R7). An agent reply answers the user->agent inputs the agent
// consumed since its previous reply in the same conversation; the bot chain
// routes the reply to their origin channel. Data only: no channel egress here.

// Origin of a user message without a channel (web UI, ctl): chat_messages.origin NULL.
REPLY_ORIGIN_LOCAL :: "local"

// route_status values recorded on a reply (metadata_json.reply_origin).
REPLY_ROUTE_ROUTED    :: "routed"    // every answered input shares one origin
REPLY_ROUTE_AMBIGUOUS :: "ambiguous" // several origins, or none while the conversation has channels
REPLY_ROUTE_EXPLICIT  :: "explicit"  // chat send --reply-to named the input
REPLY_ROUTE_NONE      :: "none"      // nothing consumed and no channel to route to

// source values: how the answered set was obtained.
REPLY_SOURCE_CONSUMED  :: "consumed"  // inputs consumed after the watermark
REPLY_SOURCE_INHERITED :: "inherited" // nothing new: the previous reply's set
REPLY_SOURCE_REPLY_TO  :: "reply_to"
REPLY_SOURCE_NONE      :: "none"

// Consumption kinds: ACP inline delivery, or the agent's own marking chat read.
INPUT_CONSUMED_DELIVERED :: "delivered"
INPUT_CONSUMED_READ      :: "read"

// One user input's first consumption. seq is the durable consumption order.
Input_Consumption :: struct {
	seq: i64,
	message_id, owner_user_id, conversation_id, kind, consumed_at: string,
	origin: string, // the message's origin, REPLY_ORIGIN_LOCAL when NULL
}

// The last reply's consumption point in one conversation.
Reply_Watermark :: struct {
	conversation_id, owner_user_id: string,
	through_seq: i64,
	reply_message_id, updated_at: string,
}

// What a reply answers, as stored under metadata_json.reply_origin.
Reply_Origin :: struct {
	answered_message_ids: []string,
	origin: string, // the single origin, "" when ambiguous or none
	route_status: string,
	source: string,
}
