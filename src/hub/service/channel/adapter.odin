package channel

Channel_Error_Kind :: enum {
	None,
	Transient,
	Rate_Limited,
	Unauthorized,
	Chat_Unavailable,
	Invalid_Request,
	Aborted,
	Window_Closed,
	Template_Unavailable,
	Media_Too_Large,
	Media_Unavailable,
}

Channel_Error :: struct {
	kind:           Channel_Error_Kind,
	retry_after_ms: i64, // set for Rate_Limited
	provider_code:  int, // provider error code (Telegram error_code, Graph error.code); 0 if none
	message:        string, // safe to log; never contains a token, a phone number or message text
}

Inbound_Kind :: enum {
	Text,
	Start,
	Disconnect,
	Unsupported,
	Delivery_Failed,
	Media,
}

Inbound :: struct {
	update_key:          string, // globally unique per provider, used for dedupe
	external_chat_id:    string,
	external_message_id: string, // provider message id; Delivery_Failed: the id of OUR outbound message
	external_user_id:    string,
	chat_is_private:     bool,
	sender_display:      string,
	kind:                Inbound_Kind,
	text:                string, // Text: message text; Start: the pairing payload ("" when none)
	provider_time:       string, // RFC 3339 UTC of the provider event time; zero value when the provider gives none
	provider_code:       int, // Delivery_Failed: provider error code; 0 otherwise
	media:               Inbound_Media, // Media: text carries the caption.
}

Identity :: struct {
	bot_user_id:  string, // Telegram: bot id; WhatsApp: phone_number_id
	bot_username: string, // Telegram: username without "@"; WhatsApp: display number digits
}

Push_Verdict :: enum {
	Accepted,
	Bad_Signature,
	Bad_Payload,
	Foreign_Account,
}

Channel_Adapter :: struct {
	ctx:             rawptr,
	provider:        string, // "telegram" | "whatsapp" | "web"
	// Pull providers only (nil for push providers). Blocks up to the provider's long-poll window.
	poll:     proc(ctx: rawptr, cursor: string, cancel: ^bool, allocator := context.allocator) -> (batch: []Inbound, next_cursor: string, err: Channel_Error),
	send_text: proc(ctx: rawptr, external_chat_id: string, text: string) -> (external_message_id: string, err: Channel_Error),
	// Optional read reaction; nil means the provider does not support it.
	react: proc(ctx: rawptr, external_chat_id, external_message_id, emoji: string) -> Channel_Error,
	identity: proc(ctx: rawptr) -> (Identity, Channel_Error),
	pairing_url: proc(ctx: rawptr, identity: Identity, code: string, allocator := context.allocator) -> string,
	// Optional: the message text the user sends to pair (shown in the UI). nil means none (Telegram).
	pairing_text:    proc(ctx: rawptr, code: string, allocator := context.allocator) -> string,
	// Push providers only (nil for Telegram).
	// True when mode is "subscribe" and verify_token equals the configured token (constant time).
	push_challenge:  proc(ctx: rawptr, mode, verify_token: string) -> bool,
	// Verifies the signature over raw_body, then parses. Batch fields belong to allocator
	// (release with inbound_destroy_batch). Bad_Signature/Bad_Payload/Foreign_Account return an empty batch.
	// Foreign_Account: verified and well-formed, but every skipped entry/change was skipped for a
	// business account or phone number id mismatch and nothing else produced an event (8.4).
	push_parse:      proc(
		ctx: rawptr,
		signature_header, raw_body: string,
		allocator := context.allocator,
	) -> (
		batch: []Inbound,
		verdict: Push_Verdict,
	),
	// Optional read receipt; nil means unsupported.
	mark_read:       proc(ctx: rawptr, external_chat_id, external_message_id: string) -> Channel_Error,
	// Optional re-engagement message for a closed reply window; nil means unsupported.
	send_reengage:   proc(ctx: rawptr, external_chat_id: string) -> (external_message_id: string, err: Channel_Error),
	// Optional: the error kind for a provider code reported asynchronously (Delivery_Failed). nil = unsupported.
	failure_kind:    proc(provider_code: int) -> Channel_Error_Kind,
	// Free-form replies are accepted only this long after the user's last message; 0 = no window.
	reply_window_ms: i64,
	media:       Media_Capabilities,
	// Optional; nil = no inbound media. Reads at most max_bytes; a larger file is .Media_Too_Large.
	// Finishes within MEDIA_PROVIDER_BUDGET_MS. Never logs or returns the file reference or a URL.
	media_fetch: proc(ctx: rawptr, file_ref: string, max_bytes: i64, allocator := context.allocator) -> (Fetched_Media, Channel_Error),
	// Optional; nil = no native sends. One provider message (WhatsApp: upload, then message),
	// finished within min(timeout_ms, MEDIA_PROVIDER_BUDGET_MS) in total, no internal retry.
	send_media:  proc(ctx: rawptr, external_chat_id: string, media: Outbound_Media, timeout_ms: int) -> (external_message_id: string, err: Channel_Error),
	// Optional; send_text with a caller timeout (the request deadline, 11.8): one attempt,
	// finished within min(timeout_ms, the adapter's own send_text timeout). nil = use send_text.
	send_text_within: proc(ctx: rawptr, external_chat_id, text: string, timeout_ms: int) -> (external_message_id: string, err: Channel_Error),
}

MEDIA_PROVIDER_BUDGET_MS :: 15_000

// Same member order as domain.Channel_Media_Kind.
Media_Kind :: enum { None, Image, Document, Voice, Audio }

// What the provider declared for an inbound file. Strings belong to the batch allocator.
Inbound_Media :: struct {
	kind:     Media_Kind,
	file_ref: string, // Telegram file_id; WhatsApp media id
	name:     string, // provider file name; "" when none
	mime:     string, // base MIME type (lowercase, no parameters); "" when none
	size:     i64,    // bytes; 0 when the provider does not say
}

// One way the provider takes a file natively. Rules are tried in order.
Media_Send_Rule :: struct {
	kind:      Media_Kind,
	mimes:     []string, // exact base MIME types; nil = any type
	max_bytes: i64,
	caption:   bool, // the provider shows a caption with this kind
}

Media_Capabilities :: struct {
	fetch_max_bytes:   i64, // largest inbound file the provider lets us download; 0 = no inbound media
	caption_max_runes: int,
	send_rules:        []Media_Send_Rule, // empty = never native
}

Outbound_Media :: struct {
	kind:    Media_Kind,
	name:    string,
	mime:    string, // base MIME type
	bytes:   []byte,
	caption: string, // "" = none; non-empty only when the rule has caption = true
}

Fetched_Media :: struct {
	bytes: []byte, // belongs to the allocator passed to media_fetch
	mime:  string, // provider-reported base MIME type, same allocator; "" when none
}
