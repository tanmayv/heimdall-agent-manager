package channel

Channel_Error_Kind :: enum { None, Transient, Rate_Limited, Unauthorized, Chat_Unavailable, Invalid_Request, Aborted }

Channel_Error :: struct {
	kind:            Channel_Error_Kind,
	retry_after_ms:  i64,     // set for Rate_Limited
	provider_code:   int,     // Telegram error_code for the Telegram adapter; 0 if none
	message:         string,  // safe to log; never contains the token
}

Inbound_Kind :: enum { Text, Start, Disconnect, Unsupported }

Inbound :: struct {
	update_key:        string,  // globally unique per provider, used for dedupe
	external_chat_id:  string,
	external_message_id: string, // provider message id for read reactions
	external_user_id:  string,
	chat_is_private:   bool,
	sender_display:    string,
	kind:              Inbound_Kind,
	text:              string,  // Text: message text; Start: the start payload ("" when none)
}

Identity :: struct {
	bot_user_id:  string,
	bot_username: string,  // without "@"
}

Channel_Adapter :: struct {
	ctx:      rawptr,
	provider: string, // "telegram"
	// Blocks up to the provider's long-poll window. `cursor` is opaque; "" means start.
	poll:     proc(ctx: rawptr, cursor: string, cancel: ^bool, allocator := context.allocator) -> (batch: []Inbound, next_cursor: string, err: Channel_Error),
	send_text: proc(ctx: rawptr, external_chat_id: string, text: string) -> (external_message_id: string, err: Channel_Error),
	// Optional read reaction; nil means the provider does not support it.
	react: proc(ctx: rawptr, external_chat_id, external_message_id, emoji: string) -> Channel_Error,
	identity: proc(ctx: rawptr) -> (Identity, Channel_Error),
	pairing_url: proc(ctx: rawptr, identity: Identity, code: string, allocator := context.allocator) -> string,
}
