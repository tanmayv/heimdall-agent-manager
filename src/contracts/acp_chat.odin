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

// A revision always replaces the entire sealed body. Retries must reuse the
// original ciphertext, since sealing the same text again changes its nonce.
ACP_Assistant_Message_Input :: struct {
    launch_epoch, turn_id, message_id: string,
    revision: i64,
    body, message_status: string,
    stop_reason: string,
}
