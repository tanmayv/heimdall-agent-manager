package iface

import domain "odin_test:hub/domain"

// ACP input delivery evidence and Send now batches. Writers run inside the
// caller's unit of work; callers publish invalidations only after commit.
Content_Get_Input_Delivery_Proc :: proc(ctx: rawptr, message_id: string) -> (domain.ACP_Input_Delivery, bool, domain.Domain_Error)
Content_Save_Input_Delivery_Proc :: proc(ctx: rawptr, row: domain.ACP_Input_Delivery) -> domain.Domain_Error
// Undelivered rows (sent/queued/dispatching) in admission order. Filter by
// conversation_id when non-empty, otherwise by agent_instance_id.
Content_List_Open_Input_Deliveries_Proc :: proc(ctx: rawptr, conversation_id, agent_instance_id: string) -> ([]domain.ACP_Input_Delivery, domain.Domain_Error)
Content_Get_Send_Now_Batch_Proc :: proc(ctx: rawptr, batch_id: string) -> (domain.ACP_Send_Now_Batch, bool, domain.Domain_Error)
Content_Find_Send_Now_Batch_Proc :: proc(ctx: rawptr, conversation_id, request_id: string) -> (domain.ACP_Send_Now_Batch, bool, domain.Domain_Error)
Content_Save_Send_Now_Batch_Proc :: proc(ctx: rawptr, row: domain.ACP_Send_Now_Batch) -> domain.Domain_Error
Content_Get_Input_Runtime_Proc :: proc(ctx: rawptr, instance: string) -> (domain.ACP_Input_Runtime, bool, domain.Domain_Error)
Content_Save_Input_Runtime_Proc :: proc(ctx: rawptr, row: domain.ACP_Input_Runtime) -> domain.Domain_Error
// delivered_at != "" stamps chat_messages.delivered_at once; clear_read reopens
// a bridge-admitted (never dispatched) input for re-admission after relaunch.
Content_Set_Message_Delivery_Flags_Proc :: proc(ctx: rawptr, message_id, delivered_at: string, clear_read: bool) -> domain.Domain_Error

content_get_input_delivery :: proc(r: ^Content_Repository, message_id: string) -> (domain.ACP_Input_Delivery, bool, domain.Domain_Error) {
    if r == nil || r.get_input_delivery == nil do return {}, false, domain.domain_error(.Internal_Error, "input delivery repository is not configured")
    return r.get_input_delivery(r.ctx, message_id)
}
content_save_input_delivery :: proc(r: ^Content_Repository, row: domain.ACP_Input_Delivery) -> domain.Domain_Error {
    if r == nil || r.save_input_delivery == nil do return domain.domain_error(.Internal_Error, "input delivery repository is not configured")
    return r.save_input_delivery(r.ctx, row)
}
content_list_open_input_deliveries :: proc(r: ^Content_Repository, conversation_id, agent_instance_id: string) -> ([]domain.ACP_Input_Delivery, domain.Domain_Error) {
    if r == nil || r.list_open_input_deliveries == nil do return nil, domain.domain_error(.Internal_Error, "input delivery repository is not configured")
    return r.list_open_input_deliveries(r.ctx, conversation_id, agent_instance_id)
}
content_get_send_now_batch :: proc(r: ^Content_Repository, batch_id: string) -> (domain.ACP_Send_Now_Batch, bool, domain.Domain_Error) {
    if r == nil || r.get_send_now_batch == nil do return {}, false, domain.domain_error(.Internal_Error, "send now repository is not configured")
    return r.get_send_now_batch(r.ctx, batch_id)
}
content_find_send_now_batch :: proc(r: ^Content_Repository, conversation_id, request_id: string) -> (domain.ACP_Send_Now_Batch, bool, domain.Domain_Error) {
    if r == nil || r.find_send_now_batch == nil do return {}, false, domain.domain_error(.Internal_Error, "send now repository is not configured")
    return r.find_send_now_batch(r.ctx, conversation_id, request_id)
}
// request_id "" selects the conversation's most recent batch.
content_latest_send_now_batch :: proc(r: ^Content_Repository, conversation_id: string) -> (domain.ACP_Send_Now_Batch, bool, domain.Domain_Error) {
    return content_find_send_now_batch(r, conversation_id, "")
}
content_save_send_now_batch :: proc(r: ^Content_Repository, row: domain.ACP_Send_Now_Batch) -> domain.Domain_Error {
    if r == nil || r.save_send_now_batch == nil do return domain.domain_error(.Internal_Error, "send now repository is not configured")
    return r.save_send_now_batch(r.ctx, row)
}
content_get_input_runtime :: proc(r: ^Content_Repository, instance: string) -> (domain.ACP_Input_Runtime, bool, domain.Domain_Error) {
    if r == nil || r.get_input_runtime == nil do return {}, false, domain.domain_error(.Internal_Error, "input runtime repository is not configured")
    return r.get_input_runtime(r.ctx, instance)
}
content_save_input_runtime :: proc(r: ^Content_Repository, row: domain.ACP_Input_Runtime) -> domain.Domain_Error {
    if r == nil || r.save_input_runtime == nil do return domain.domain_error(.Internal_Error, "input runtime repository is not configured")
    return r.save_input_runtime(r.ctx, row)
}
content_set_message_delivery_flags :: proc(r: ^Content_Repository, message_id, delivered_at: string, clear_read: bool) -> domain.Domain_Error {
    if r == nil || r.set_message_delivery_flags == nil do return domain.domain_error(.Internal_Error, "message delivery repository is not configured")
    return r.set_message_delivery_flags(r.ctx, message_id, delivered_at, clear_read)
}
