package http

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import content "odin_test:hub/service/content"
import events "odin_test:hub/service/events"
import auth_service "odin_test:hub/service/auth"

// `acp_delivery` on a user_to_agent message of an ACP instance. Omitted for
// PTY/non-ACP rows, which keep today's read_at semantics. For ACP rows the
// legacy read_at is bridge admission only; `status` is the authoritative path
// sent -> queued -> delivered -> read.
write_acp_delivery_json :: proc(b: ^strings.Builder, m: domain.Chat_Message, svc: ^content.Content_Service) {
    if svc == nil || svc.content == nil || svc.content.get_input_delivery == nil || m.direction != "user_to_agent" do return
    row, found, _ := iface.content_get_input_delivery(svc.content, m.message_id)
    if !found do return
    strings.write_string(b, `,"acp_delivery":{"status":"`); write_handler_json_string(b, content.acp_delivery_status(row))
    strings.write_string(b, `","state":"`); write_handler_json_string(b, row.state)
    strings.write_string(b, `","hold_reason":"`); write_handler_json_string(b, row.hold_reason)
    strings.write_string(b, `","tray_eligible":`); strings.write_string(b, "true" if content.acp_delivery_turn_held(row) else "false")
    strings.write_string(b, `,"mode":"`); write_handler_json_string(b, row.mode)
    strings.write_string(b, `","launch_epoch":"`); write_handler_json_string(b, row.launch_epoch)
    strings.write_string(b, `","turn_id":"`); write_handler_json_string(b, row.turn_id)
    strings.write_string(b, `","batch_id":"`); write_handler_json_string(b, row.batch_id)
    strings.write_string(b, `","error":"`); write_handler_json_string(b, row.error)
    strings.write_string(b, `","delivered_at":"`); write_handler_json_string(b, row.delivered_at)
    strings.write_string(b, `","agent_read_at":"`); write_handler_json_string(b, row.agent_read_at)
    strings.write_string(b, `","updated_at":"`); write_handler_json_string(b, row.updated_at)
    strings.write_string(b, `"}`)
}

write_send_now_batch_json :: proc(b: ^strings.Builder, batch: domain.ACP_Send_Now_Batch) {
    if batch.batch_id == "" { strings.write_string(b, "null"); return }
    members := batch.member_ids_json if batch.member_ids_json != "" else "[]"
    excluded := batch.excluded_json if batch.excluded_json != "" else "[]"
    fmt.sbprintf(b, `{{"batch_id":"%s","request_id":"`, batch.batch_id); write_handler_json_string(b, batch.request_id)
    strings.write_string(b, `","launch_epoch":"`); write_handler_json_string(b, batch.launch_epoch)
    fmt.sbprintf(b, `","attempt":%d,"state":"`, batch.attempt); write_handler_json_string(b, batch.state)
    strings.write_string(b, `","error":"`); write_handler_json_string(b, batch.error)
    strings.write_string(b, `","message_ids":`); strings.write_string(b, members)
    strings.write_string(b, `,"excluded":`); strings.write_string(b, excluded)
    strings.write_string(b, `,"created_at":"`); write_handler_json_string(b, batch.created_at)
    strings.write_string(b, `","updated_at":"`); write_handler_json_string(b, batch.updated_at)
    strings.write_string(b, `"}`)
}

messages_delivery_event_json :: proc(c: domain.Chat_Conversation, message_ids: []string, batch_id: string) -> string {
    raw, _ := json.marshal(struct {
        type, event, conversation_id, agent_instance_id: string,
        message_ids: []string,
        batch_id: string,
        fetch_required: bool,
    }{"chat_event", "messages_delivery", c.conversation_id, c.agent_instance_id, message_ids, batch_id, true}, allocator = context.temp_allocator)
    return string(raw)
}

publish_messages_delivery :: proc(bus: ^events.User_Event_Bus, c: domain.Chat_Conversation, message_ids: []string, batch_id: string) {
    if bus == nil || c.owner_user_id == "" || (len(message_ids) == 0 && batch_id == "") do return
    events.publish_owned(bus, string(c.owner_user_id), messages_delivery_event_json(c, message_ids, batch_id))
}

// POST /api/v1/agent-actions/chat/input-state: bridge-authored delivery
// reports, relayed from the ACP chat outbox in FIFO order with assistant rows.
agent_action_chat_input_state_handler :: proc(ctx: rawptr, req: Request) -> Response {
    h := cast(^Agent_Action_Handlers)ctx
    identity, authorized, denial := auth_service.authenticate_bridge_instance_for_turn_finalization(h.auth,{remote_addr=req.remote_addr,query=req.query,body=req.body,headers=req.headers})
    if !authorized do return respond_error(denial,req.request_id)
    inst := identity.instance
    raw := json_object_raw(req.body,"params")
    report: contracts.ACP_Input_State_Report
    if raw == "" || len(raw) > 256*1024 || json.unmarshal_string(raw,&report,allocator=context.temp_allocator) != nil do return respond_error(domain.domain_error(.Validation_Failed,"invalid input state report"),req.request_id)
    if report.launch_epoch != identity.asserted_epoch do return respond_error(domain.domain_error(.Forbidden,"bridge instance assertion token is invalid"),req.request_id)
    auth := contracts.Auth_Context{kind=.Instance_Token,user_id=string(inst.owner_user_id),bridge_id=inst.bridge_id,agent_instance_id=inst.agent_instance_id}
    result, ok, err := content.apply_input_state_report(h.content,auth,inst.agent_instance_id,report)
    if !ok do return respond_error(err,req.request_id)
    if len(result.changed_ids) > 0 || result.batch_changed do publish_messages_delivery(h.event_bus,result.conversation,result.changed_ids[:],report.batch_id)
    content.acp_delivery_notify_requeued(h.content,result.conversation,result.requeued_ids[:])
    body, _ := json.marshal(struct{applied:int,requeued:int,stale:bool}{len(result.changed_ids),len(result.requeued_ids),result.stale},allocator=context.temp_allocator)
    return respond_success(string(body),req.request_id,auth_ctx_server_time(req),200)
}

// POST /api/v1/chats/{cid}/send-now {request_id, launch_epoch, message_ids?}
send_now_handler :: proc(ctx: rawptr, req: Request) -> Response {
    h := (^Content_Handlers)(ctx)
    auth, ok, resp := require_auth(h.auth,req)
    if !ok do return resp
    input: struct { request_id, launch_epoch: string, message_ids: []string }
    if len(req.body) > 64*1024 || json.unmarshal_string(req.body,&input,allocator=context.temp_allocator) != nil do return respond_error(domain.domain_error(.Validation_Failed,"invalid send now request"),req.request_id)
    result, sent, err := content.send_now(h.content,auth,path_part(req.path,4),{request_id=input.request_id,launch_epoch=input.launch_epoch,message_ids=input.message_ids})
    if !sent do return respond_error(err,req.request_id)
    publish_messages_delivery(h.event_bus,result.conversation,result.changed_ids[:],result.batch.batch_id)
    b := strings.builder_make(allocator=context.temp_allocator)
    strings.write_string(&b,`{"outcome":"`); write_handler_json_string(&b,result.outcome); strings.write_string(&b,`","batch":`)
    write_send_now_batch_json(&b,result.batch); strings.write_byte(&b,'}')
    status := 200
    switch result.outcome {
    // queued: not delivered now, the bridge keeps the notice for the next idle.
    case "accepted", "duplicate", "queued": status = 202
    case "failed": status = 503
    }
    return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req),status)
}

// GET /api/v1/chats/{cid}/send-now: the latest batch plus the runtime facts the
// UI needs after a reload (current epoch, steering capability if reported,
// send_now: what Send now takes for this runtime, "members" | "notice" | "",
// and agent_notified_at: when the agent was last pointed at its unread
// messages, "" when never).
get_send_now_handler :: proc(ctx: rawptr, req: Request) -> Response {
    h := (^Content_Handlers)(ctx)
    auth, ok, resp := require_auth(h.auth,req)
    if !ok do return resp
    c, found, err := content.get_conversation(h.content,auth,path_part(req.path,4))
    if !found do return respond_error(err,req.request_id)
    batch, _, _ := iface.content_latest_send_now_batch(h.content.content,c.conversation_id)
    epoch, transport := "", ""
    steering, known := false, false
    if h.content.agents != nil {
        if inst, have, _ := iface.agent_get_instance(h.content.agents,c.agent_instance_id); have { epoch = inst.launch_epoch; transport = inst.runtime_transport }
    }
    if rt, have, _ := iface.content_get_input_runtime(h.content.content,c.agent_instance_id); have && rt.launch_epoch == epoch { steering = rt.steering_supported; known = true }
    b := strings.builder_make(allocator=context.temp_allocator)
    strings.write_string(&b,`{"conversation_id":"`); write_handler_json_string(&b,c.conversation_id)
    strings.write_string(&b,`","runtime_transport":"`); write_handler_json_string(&b,transport)
    strings.write_string(&b,`","send_now":"`); strings.write_string(&b,contracts.RUNTIME_SEND_NOW_WIRE[contracts.runtime_transport_capabilities(transport).send_now])
    notified_at, _ := iface.content_agent_notified_at(h.content.content,c.owner_user_id,c.conversation_id)
    strings.write_string(&b,`","` + contracts.SEND_NOW_AGENT_NOTIFIED_AT_FIELD + `":"`); write_handler_json_string(&b,notified_at)
    strings.write_string(&b,`","launch_epoch":"`); write_handler_json_string(&b,epoch)
    strings.write_string(&b,`","steering_supported":`); strings.write_string(&b,"null" if !known else ("true" if steering else "false"))
    strings.write_string(&b,`,"batch":`); write_send_now_batch_json(&b,batch); strings.write_byte(&b,'}')
    return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req),200)
}

// Actual agent read evidence. Only the ACP instance's own read of its own
// conversation counts; the bridge input drain (input_source) never does.
// Returns the IDs that gained read evidence (temp allocator).
acp_note_agent_read_rows :: proc(h: ^Agent_Action_Handlers, auth: contracts.Auth_Context, inst: domain.Agent_Instance, rows: []domain.Chat_Message) -> []string {
    if inst.runtime_transport != "acp" || len(rows) == 0 do return nil
    ids := make([dynamic]string, context.temp_allocator)
    for row in rows do if row.direction == "user_to_agent" do append(&ids, row.message_id)
    changed, drop, c, err := content.note_agent_read(h.content,auth,inst.agent_instance_id,ids[:])
    if err.code != .None { fmt.println("ACP agent read evidence failed",inst.agent_instance_id,err.message); return nil }
    publish_messages_delivery(h.event_bus,c,changed[:],"")
    content.acp_send_inputs_read(h.content,c,drop[:])
    return changed[:]
}

// bridge_ws_agent_notice_typed applies a bridge's agent_notice_typed frame
// (contracts.Agent_Notice_Typed_Frame). bridge_id is the authenticated
// connection's; a frame for another bridge's instance is dropped. A moved
// timestamp refreshes the owner's Send now state (messages_delivery, no ids).
bridge_ws_agent_notice_typed :: proc(h: ^Bridge_Handlers, bridge_id, text: string) {
    if h == nil || h.content == nil do return
    frame: contracts.Agent_Notice_Typed_Frame
    if len(text) > 4096 || json.unmarshal_string(text, &frame, allocator = context.temp_allocator) != nil do return
    c, moved, err := content.note_agent_notice_typed(h.content, bridge_id, frame.agent_instance_id, frame.typed_at_ms)
    if err.code != .None || !moved || h.event_bus == nil do return
    events.publish_owned(h.event_bus, string(c.owner_user_id), messages_delivery_event_json(c, []string{}, ""))
}
