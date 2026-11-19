package contracts

BRIDGE_FEATURE_BOT_DELIVER_V1 :: "bot_deliver_v1"
BOT_DELIVER_FRAME :: "bot_deliver"
BOT_DELIVERY_REPORT_FRAME :: "bot_delivery_report"
BOT_DELIVERY_REPORT_ACK_FRAME :: "bot_delivery_report_ack"

Bot_Candidate_Wire :: struct {
	provider:         string `json:"provider"`,
	provider_profile: string `json:"provider_profile"`,
	model:            string `json:"model"`,
	tier:             string `json:"tier"`, // "preferred" | "allowed"
}

Bot_Timers_Wire :: struct {
	launch_ready_ms:      i64 `json:"launch_ready_ms"`,
	read_ms:              i64 `json:"read_ms"`,
	read_extend_ms:       i64 `json:"read_extend_ms"`,
	read_max_extends:     int `json:"read_max_extends"`,
	idle_no_reply_ms:     i64 `json:"idle_no_reply_ms"`,
	reply_cap_ms:         i64 `json:"reply_cap_ms"`,
	progress_interval_ms: i64 `json:"progress_interval_ms"`,
}

Bot_Skip_Wire :: struct {
	provider: string `json:"provider"`,
	model:    string `json:"model"`,
	reason:   string `json:"reason"`,
}

Bot_Deliver_Wire :: struct {
	type:               string `json:"type"`, // "bot_deliver"
	command_id:         string `json:"command_id"`,
	bridge_id:          string `json:"bridge_id"`,
	agent_instance_id:  string `json:"agent_instance_id"`,
	bot_id:             string `json:"bot_id"`,
	delivery_id:        string `json:"delivery_id"`,
	attempt_id:         string `json:"attempt_id"`,
	through_message_id: string `json:"through_message_id"`,
	pending_count:      int `json:"pending_count"`,
	current_provider:   string `json:"current_provider"`, // instance's provider in the hub record when the frame is built (11.4)
	current_model:      string `json:"current_model"`, // instance's model in the hub record when the frame is built (11.4)
	candidates:         []Bot_Candidate_Wire `json:"candidates"`,
	skip:               []Bot_Skip_Wire `json:"skip"`,
	timers:             Bot_Timers_Wire `json:"timers"`,
}

Bot_Candidate_Outcome_Wire :: struct {
	provider: string `json:"provider"`,
	model:    string `json:"model"`,
	outcome:  string `json:"outcome"`, // section 13.6
	detail:   string `json:"detail"`,
}

Bot_Delivery_Report_Wire :: struct {
	type:              string `json:"type"`, // "bot_delivery_report"
	protocol_version:  int `json:"protocol_version"`, // 1
	delivery_id:       string `json:"delivery_id"`,
	attempt_id:        string `json:"attempt_id"`,
	agent_instance_id: string `json:"agent_instance_id"`,
	seq:               int `json:"seq"`,
	state:             string `json:"state"`, // "working" | "acted" | "exhausted" | "busy"
	phase:             string `json:"phase"`, // section 13.5
	candidate_index:   int `json:"candidate_index"`,
	outcomes:          []Bot_Candidate_Outcome_Wire `json:"outcomes"`,
	reason:            string `json:"reason"`,
}

Bot_Delivery_Report_Ack_Wire :: struct {
	type:       string `json:"type"`, // "bot_delivery_report_ack"
	attempt_id: string `json:"attempt_id"`,
	seq:        int `json:"seq"`,
}
