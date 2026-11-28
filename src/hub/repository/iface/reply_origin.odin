package iface

import domain "odin_test:hub/domain"

// Reply origin storage (R7). Writers run inside the caller's unit of work.

// Records the first consumption of a user->agent message of this conversation;
// a later consumption of the same message, or any other row, is ignored.
Content_Record_Input_Consumption_Proc :: proc(ctx: rawptr, owner: domain.User_ID, conversation_id, message_id, kind, consumed_at: string) -> domain.Domain_Error
// Consumptions with seq > after_seq, in seq order, with each message's origin.
Content_List_Input_Consumptions_Proc :: proc(ctx: rawptr, owner: domain.User_ID, conversation_id: string, after_seq: i64) -> ([]domain.Input_Consumption, domain.Domain_Error)
Content_Get_Reply_Watermark_Proc :: proc(ctx: rawptr, owner: domain.User_ID, conversation_id: string) -> (domain.Reply_Watermark, bool, domain.Domain_Error)
// Compare-and-swap: writes next only while the stored through_seq still equals
// expected_seq (0 with no row); otherwise a Conflict.
Content_Advance_Reply_Watermark_Proc :: proc(ctx: rawptr, next: domain.Reply_Watermark, expected_seq: i64) -> domain.Domain_Error
// A message's origin (REPLY_ORIGIN_LOCAL when NULL), and whether any user
// message of the conversation arrived through a channel.
Content_Message_Origin_Proc :: proc(ctx: rawptr, message_id: string) -> (string, domain.Domain_Error)
Content_Conversation_Has_Channel_Proc :: proc(ctx: rawptr, owner: domain.User_ID, conversation_id: string) -> (bool, domain.Domain_Error)

content_reply_origin_supported :: proc(r: ^Content_Repository) -> bool {
	return r != nil && r.record_input_consumption != nil && r.list_input_consumptions != nil && r.get_reply_watermark != nil &&
		r.advance_reply_watermark != nil && r.message_origin != nil && r.conversation_has_channel != nil
}
content_record_input_consumption :: proc(r: ^Content_Repository, owner: domain.User_ID, conversation_id, message_id, kind, consumed_at: string) -> domain.Domain_Error {
	if r == nil || r.record_input_consumption == nil do return {} // repositories without reply origin record nothing
	return r.record_input_consumption(r.ctx, owner, conversation_id, message_id, kind, consumed_at)
}
content_list_input_consumptions :: proc(r: ^Content_Repository, owner: domain.User_ID, conversation_id: string, after_seq: i64) -> ([]domain.Input_Consumption, domain.Domain_Error) {
	if r == nil || r.list_input_consumptions == nil do return nil, domain.domain_error(.Internal_Error, "reply origin repository is not configured")
	return r.list_input_consumptions(r.ctx, owner, conversation_id, after_seq)
}
content_get_reply_watermark :: proc(r: ^Content_Repository, owner: domain.User_ID, conversation_id: string) -> (domain.Reply_Watermark, bool, domain.Domain_Error) {
	if r == nil || r.get_reply_watermark == nil do return {}, false, domain.domain_error(.Internal_Error, "reply origin repository is not configured")
	return r.get_reply_watermark(r.ctx, owner, conversation_id)
}
content_advance_reply_watermark :: proc(r: ^Content_Repository, next: domain.Reply_Watermark, expected_seq: i64) -> domain.Domain_Error {
	if r == nil || r.advance_reply_watermark == nil do return domain.domain_error(.Internal_Error, "reply origin repository is not configured")
	return r.advance_reply_watermark(r.ctx, next, expected_seq)
}
content_message_origin :: proc(r: ^Content_Repository, message_id: string) -> (string, domain.Domain_Error) {
	if r == nil || r.message_origin == nil do return "", domain.domain_error(.Internal_Error, "reply origin repository is not configured")
	return r.message_origin(r.ctx, message_id)
}
content_conversation_has_channel :: proc(r: ^Content_Repository, owner: domain.User_ID, conversation_id: string) -> (bool, domain.Domain_Error) {
	if r == nil || r.conversation_has_channel == nil do return false, domain.domain_error(.Internal_Error, "reply origin repository is not configured")
	return r.conversation_has_channel(r.ctx, owner, conversation_id)
}
