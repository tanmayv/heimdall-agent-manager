package domain

ACP_Assistant_Turn :: struct {
    agent_instance_id, launch_epoch, turn_id, message_id: string,
    revision: i64,
    payload_hash: string,
}

// One ACP user input's delivery evidence. `state` is bridge-authored dispatch
// truth (sent -> queued -> dispatching -> delivered, or discarded); a Hub
// read of the row by the agent itself is separate evidence in agent_read_at.
// Bridge inbox admission (chat_messages.read_at for ACP) is neither.
ACP_Input_Delivery :: struct {
    message_id, owner_user_id, conversation_id, agent_instance_id, launch_epoch: string,
    state, hold_reason, mode, turn_id, batch_id, error: string,
    report_seq: i64,
    created_at, updated_at, delivered_at, agent_read_at: string,
}

// One conversation-level Send now request. Members are frozen at the first
// attempt (FIFO); retries re-validate them and never re-snapshot.
ACP_Send_Now_Batch :: struct {
    batch_id, owner_user_id, conversation_id, agent_instance_id, launch_epoch, request_id: string,
    attempt: i64,
    state, error, member_ids_json, excluded_json: string,
    created_at, updated_at: string,
}

// Latest bridge-reported runtime facts per instance launch epoch.
ACP_Input_Runtime :: struct {
    agent_instance_id, launch_epoch: string,
    steering_supported: bool,
    updated_at: string,
}
