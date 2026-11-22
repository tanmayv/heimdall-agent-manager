package contracts

BRIDGE_FEATURE_EVENT_PIPELINE_V1 :: "event_pipeline_v1"
EVENT_DELIVER_FRAME :: "event_deliver"
DELIVERY_ID_PREFIX :: "dlv_"
DELIVERY_MAX_DELIVER :: 8
DELIVERY_ACK_WAIT_MS :: 60_000
DELIVERY_MAX_ACK_PENDING :: 256 // bounds open deliveries per bridge, waiting retries included (N10)
DELIVERY_MAX_IN_FLIGHT :: 16 // frames sent to one bridge and not yet answered; the hub enforces it (6.11.4)
DELIVERY_HANDLER_BUDGET_MS :: 30_000 // the bridge handler's deadline; MUST stay below DELIVERY_ACK_WAIT_MS
DELIVERY_RETRY_MIN_MS :: 10_000
DELIVERY_RETRY_MAX_MS :: 300_000
DELIVERY_OUTCOME_STARTED :: "started"
DELIVERY_OUTCOME_NOTIFIED :: "notified"
DELIVERY_OUTCOME_ACCEPTED :: "accepted" // kind bot: the bridge took over the attempt
DELIVERY_CLASS_RETRY :: "retry"
DELIVERY_CLASS_FATAL :: "fatal"
DELIVERY_NOTICE_MESSAGE :: "message" // type the chat-message notice
DELIVERY_NOTICE_EVENTS :: "events" // type the [events] line

// src/contracts/delivery_wire.odin — plain structs with json tags, in the style of bot_wire.odin
Delivery_Notice_Wire :: struct {
	line:  string `json:"line"`, // DELIVERY_NOTICE_MESSAGE | DELIVERY_NOTICE_EVENTS | ""
	count: int `json:"count"`,
}
Delivery_Wire :: struct {
	delivery_id:       string `json:"delivery_id"`,
	kind:              string `json:"kind"`,
	owner_user_id:     string `json:"owner_user_id"`,
	bridge_id:         string `json:"bridge_id"`,
	agent_instance_id: string `json:"agent_instance_id"`,
	cause:             string `json:"cause"`, // schedule | event | bot | lease
	ref:               string `json:"ref"`,
	conversation_id:   string `json:"conversation_id"`,
	message_id:        string `json:"message_id"`,
	notice:            Delivery_Notice_Wire `json:"notice"`,
	expires_at:        string `json:"expires_at"`, // RFC3339 UTC; the bridge keeps its ledger entry until this time plus a margin (6.11.6, S2)
	payload:           string `json:"payload,omitempty"`, // kinds bot and lease: the complete legacy frame text
}
Event_Deliver_Wire :: struct {
	type:              string `json:"type"`, // EVENT_DELIVER_FRAME
	command_id:        string `json:"command_id"`, // "<delivery_id>:<attempt>"
	agent_instance_id: string `json:"agent_instance_id"`, // repeated at the top level for the bridge's ordering key
	attempt:           int `json:"attempt"`, // JetStream num_delivered, 1..8
	final:             bool `json:"final"`, // attempt == DELIVERY_MAX_DELIVER
	delivery:          Delivery_Wire `json:"delivery"`,
}
