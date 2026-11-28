package contracts

ACP_ASSISTANT_MAX_BYTES :: 1024 * 1024
ACP_CHAT_ACK_MAX_IDS :: 100

// Only the Bridge ACP inbox drain sets this source. Ordinary agent chat reads
// omit it. The Hub validates instance authority and ACP transport before use.
ACP_CHAT_INPUT_SOURCE :: "bridge_acp"
ACP_Chat_Input_Fetch :: struct {
    input_source: string,
    mark_read, unread_only, receiver_only, oldest_first: bool,
    limit: int,
}

// One live ACP assistant segment (G12: streamed, not stored). The Hub relays it
// to the owner's UI as an `agent_output` event and never persists it. A
// revision always replaces the entire sealed body. Retries must reuse the
// original ciphertext, since sealing the same text again changes its nonce.
ACP_Assistant_Message_Input :: struct {
    launch_epoch, turn_id, message_id: string,
    revision: i64,
    body, message_status: string,
    stop_reason: string,
    // User message IDs this segment answers (one prompt or one steered batch).
    input_ids: []string,
    // Bridge outbox discriminator. "" is an assistant revision; ACP_OUTBOX_INPUT_STATE
    // carries an ACP_Input_State_Report JSON in body (plain, never sealed).
    kind: string,
}

ACP_OUTBOX_INPUT_STATE :: "input_state"
ACP_INPUT_REPORT_MAX_ENTRIES :: 128
ACP_SEND_NOW_MAX_MEMBERS :: 100

// Bridge-authored delivery evidence. report_seq is strictly increasing per
// launch epoch; the Hub applies an entry only when it is newer than the row.
// state: queued | dispatching | delivered. hold_reason (queued/dispatching):
// turn_active (held because a turn is running) | dispatch_pending (idle, next
// drain). mode (delivered): prompt | steer.
ACP_Input_State_Entry :: struct {
    message_id, state, hold_reason, mode, turn_id, batch_id, error: string,
}
// batch_state: dispatching | delivered | empty | failed. batch_error names the
// failure (cancel_timeout, runtime_failed, stale_epoch, ...).
ACP_Input_State_Report :: struct {
    launch_epoch: string,
    report_seq: i64,
    steering_supported: bool,
    batch_id: string,
    batch_attempt: i64,
    batch_state, batch_error: string,
    inputs: []ACP_Input_State_Entry,
}

// Hub -> bridge runtime commands. command_id for a batch is attempt-specific
// (cmd_sn_<batch>_a<n>) so a cached failure never blocks an explicit retry.
ACP_SEND_NOW_BATCH_COMMAND :: "acp_send_now_batch"
ACP_INPUTS_READ_COMMAND :: "acp_inputs_read"
ACP_Send_Now_Batch_Command :: struct {
    type, command_id, bridge_id, agent_instance_id, launch_epoch, batch_id: string,
    attempt: i64,
    message_ids: []string,
}
ACP_Inputs_Read_Command :: struct {
    type, command_id, bridge_id, agent_instance_id: string,
    message_ids: []string,
}
