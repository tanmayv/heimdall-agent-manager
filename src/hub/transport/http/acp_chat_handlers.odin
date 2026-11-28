package http

import "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import content "odin_test:hub/service/content"
import events "odin_test:hub/service/events"
import auth_service "odin_test:hub/service/auth"

write_message_sender_json :: proc(b:^strings.Builder,msg:domain.Chat_Message) {
    strings.write_string(b,`,"sender_agent_id":"`);write_handler_json_string(b,msg.sender_agent_id)
    strings.write_string(b,`","sender_agent_instance_id":"`);write_handler_json_string(b,msg.sender_agent_instance_id)
    strings.write_byte(b,'"')
}

// Message-specific reads bypass list pagination and retain ordinary owner auth.
get_conversation_message_handler :: proc(ctx: rawptr, req: Request) -> Response {
    h := cast(^Content_Handlers)ctx
    auth, authorized, denial := require_auth(h.auth, req)
    if !authorized do return denial
    c, found, err := content.get_conversation(h.content, auth, path_part(req.path,4))
    if !found do return respond_error(err, req.request_id)
    msg, exists, merr := iface.content_get_message(h.content.content,path_part(req.path,6))
    if !exists do return respond_error(merr,req.request_id)
    if msg.conversation_id != c.conversation_id || msg.owner_user_id != c.owner_user_id do return respond_error(domain.domain_error(.Not_Found,"message not found"),req.request_id)
    b := strings.builder_make(allocator=context.temp_allocator)
    write_message_json(&b,msg,h.content)
    return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req),200)
}

agent_action_chat_assistant_message_handler :: proc(ctx: rawptr, req: Request) -> Response {
    h := cast(^Agent_Action_Handlers)ctx
    identity, authorized, denial := auth_service.authenticate_bridge_instance_for_turn_finalization(h.auth,{remote_addr=req.remote_addr,query=req.query,body=req.body,headers=req.headers})
    if !authorized do return respond_error(denial,req.request_id)
    inst := identity.instance
    raw := json_object_raw(req.body,"params")
    parsed, perr := json.parse(raw, allocator=context.temp_allocator, parse_integers=true)
    if perr != nil do return respond_error(domain.domain_error(.Validation_Failed,"invalid assistant message params"),req.request_id)
    obj, object := parsed.(json.Object)
    if !object do return respond_error(domain.domain_error(.Validation_Failed,"assistant message params must be an object"),req.request_id)
    for key in ([]string{"launch_epoch","turn_id","message_id","body","message_status"}) {
        if _, typed := obj[key].(json.String); !typed do return respond_error(domain.domain_error(.Validation_Failed,"assistant message string field missing"),req.request_id)
    }
    revision, integer := obj["revision"].(json.Integer)
    if !integer do return respond_error(domain.domain_error(.Validation_Failed,"assistant revision must be an integer"),req.request_id)
    if value, present := obj["stop_reason"]; present {
        if _, null := value.(json.Null); !null {
            if _, text := value.(json.String); !text do return respond_error(domain.domain_error(.Validation_Failed,"stop_reason must be a string or null"),req.request_id)
        }
    }
    input := contracts.ACP_Assistant_Message_Input{launch_epoch=json_string(raw,"launch_epoch"),turn_id=json_string(raw,"turn_id"),message_id=json_string(raw,"message_id"),revision=i64(revision),body=json_string(raw,"body"),message_status=json_string(raw,"message_status"),stop_reason=json_string(raw,"stop_reason")}
    if value, present := obj["input_ids"]; present {
        if _, null := value.(json.Null); !null {
            ids, array := value.(json.Array)
            if !array do return respond_error(domain.domain_error(.Validation_Failed,"input_ids must be an array"),req.request_id)
            list := make([dynamic]string, context.temp_allocator)
            for v in ids {
                id, text := v.(json.String)
                if !text do return respond_error(domain.domain_error(.Validation_Failed,"input_ids must be strings"),req.request_id)
                append(&list, string(id))
            }
            input.input_ids = list[:]
        }
    }
    if input.launch_epoch != identity.asserted_epoch do return respond_error(domain.domain_error(.Forbidden,"bridge instance assertion token is invalid"),req.request_id)
    auth := contracts.Auth_Context{kind=.Instance_Token,user_id=string(inst.owner_user_id),bridge_id=inst.bridge_id,agent_instance_id=inst.agent_instance_id}
    // G12: streamed, not stored. The segment goes to the owner's UI sockets
    // and nowhere else; a segment from a replaced launch is acknowledged so the
    // bridge drops it, but it is not relayed.
    relay, accepted, err := content.relay_assistant_segment(h.content,auth,inst.agent_instance_id,input)
    if !accepted do return respond_error(err,req.request_id)
    relayed := relay.event_json != ""
    if relayed && h.event_bus != nil do events.publish_raw_to_user(h.event_bus,relay.owner_user_id,relay.event_json)
    body, _ := json.marshal(struct{relayed:bool,persisted:bool}{relayed,false},allocator=context.temp_allocator)
    return respond_success(string(body),req.request_id,auth_ctx_server_time(req),200)
}

// Validate the entire batch before marking anything. No target/filter field is
// accepted, even when it happens to name the caller's own conversation.
agent_chat_ack_only :: proc(h: ^Agent_Action_Handlers,req: Request,auth: contracts.Auth_Context,inst: domain.Agent_Instance,params: string) -> (Response,bool) {
    parsed, err := json.parse(params,allocator=context.temp_allocator)
    if err != nil do return {},false
    obj, object := parsed.(json.Object)
    if !object do return {},false
    value, present := obj["ack_message_ids"]
    if !present do return {},false
    invalid := respond_error(domain.domain_error(.Validation_Failed,"ack-only requires 1 to 100 incoming message IDs and no other params"),req.request_id)
    ids, array := value.(json.Array)
    if len(obj) != 1 || !array || len(ids) < 1 || len(ids) > contracts.ACP_CHAT_ACK_MAX_IDS do return invalid,true
    conv, found, cerr := content.get_conversation_by_instance(h.content,auth,inst.agent_instance_id)
    if !found do return respond_error(cerr,req.request_id),true
    unread := make([dynamic]string,allocator=context.temp_allocator)
    for value in ids {
        id, text := value.(json.String)
        if !text || len(id) == 0 do return invalid,true
        msg, exists, merr := iface.content_get_message(h.content.content,string(id))
        if !exists || merr.code != .None || msg.owner_user_id != conv.owner_user_id || msg.conversation_id != conv.conversation_id || (msg.direction != "user_to_agent" && msg.direction != "agent_to_agent") || (msg.direction == "agent_to_agent" && msg.sender_agent_instance_id == inst.agent_instance_id) do return invalid,true
        duplicate := false
        for previous in unread do if previous == string(id) do duplicate = true
        if msg.read_at == "" && !duplicate do append(&unread,string(id))
    }
    count, read_at, mark_err := content.mark_messages_read_by_ids_at(h.content,auth,unread[:])
    if mark_err.code != .None do return respond_error(mark_err,req.request_id),true
    if count > 0 do publish_agent_messages_read(h,string(conv.owner_user_id),conv,unread[:],inst.agent_instance_id,read_at)
    body, _ := json.marshal(struct{marked_count:int,read_at:string}{count,read_at},allocator=context.temp_allocator)
    return respond_success(string(body),req.request_id,auth_ctx_server_time(req),200),true
}
