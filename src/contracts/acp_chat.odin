package contracts

ACP_ASSISTANT_MAX_BYTES :: 1024 * 1024
ACP_CHAT_ACK_MAX_IDS :: 100

// A revision always replaces the entire sealed body. Retries must reuse the
// original ciphertext, since sealing the same text again changes its nonce.
ACP_Assistant_Message_Input :: struct {
    launch_epoch, turn_id, message_id: string,
    revision: i64,
    body, message_status: string,
    stop_reason: string,
}
