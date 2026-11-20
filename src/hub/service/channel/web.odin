package channel

// channel_send persists replies before completing this local delivery.
web_adapter :: proc() -> Channel_Adapter {
	return {provider = "web", send_text = web_send_text}
}
web_send_text :: proc(ctx: rawptr, external_chat_id, text: string) -> (string, Channel_Error) {
	return "", {}
}
