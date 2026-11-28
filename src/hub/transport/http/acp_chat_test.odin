package http

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:net"
import "core:strings"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import events "odin_test:hub/service/events"
import vault "odin_test:lib/vault"

ACP_Chat_Fixture :: struct {
    delivery_sink: Ad_Sink,
    mq: MQ_HTTP_Fixture,
    repos: iface.Repositories,
    impl: sqlite.SQLite_Unit_Of_Work_Factory,
    factory: iface.Unit_Of_Work_Factory,
    vault_repo: iface.Vault_Directory_Repository,
}
acp_chat_root :: proc() -> string { return strings.concatenate({"04",strings.repeat("01",64,context.temp_allocator)},context.temp_allocator) }
acp_chat_directory :: proc(_:rawptr, owner:string) -> (domain.Vault_Directory,bool,domain.Domain_Error) { return {user_id=owner,current_epoch=1,root_device_id="root"},true,{} }
acp_chat_devices :: proc(_:rawptr,owner:string) -> ([]domain.Vault_Device,domain.Domain_Error) { rows:=make([]domain.Vault_Device,1,context.temp_allocator); rows[0]={user_id=owner,device_id="root",sign_public_key=acp_chat_root()}; return rows,{} }
acp_chat_directory_epoch2 :: proc(_:rawptr,owner:string) -> (domain.Vault_Directory,bool,domain.Domain_Error) { return {user_id=owner,current_epoch=2,root_device_id="root"},true,{} }
acp_chat_seal :: proc(text:string,epoch:u32=1) -> string {
    key:[32]byte
    id,_:=vault.vault_id_from_root_sign_pub(acp_chat_root())
    kr,_:=vault.keyring_from_single_key("tanmay",id,epoch,key[:]); defer vault.keyring_wipe(&kr)
    body,_:=vault.seal(transmute([]byte)text,&kr,context.temp_allocator)
    return body
}

@(test)
t5_assistant_ciphertext_retry_survives_vault_rotation :: proc(t:^testing.T) {
    arena:virtual.Arena;_=virtual.arena_init_growing(&arena);defer virtual.arena_destroy(&arena)
    context.allocator=virtual.arena_allocator(&arena);context.temp_allocator=context.allocator
    f:ACP_Chat_Fixture;acp_chat_open(t,&f);defer mq_http_base_close(f.mq.base)
    input:=contracts.ACP_Assistant_Message_Input{launch_epoch="epoch",turn_id="turn",message_id="msg_0123456789abcdef",revision=1,body=acp_chat_seal("partial"),message_status="pending"}
    r:=acp_chat_call(&f,input);testing.expect_value(t,r.status,200)
    f.vault_repo.get_directory=acp_chat_directory_epoch2
    r=acp_chat_call(&f,input);testing.expect_value(t,r.status,200)
    future:=input;future.revision=2;future.body=acp_chat_seal("future",3)
    r=acp_chat_call(&f,future);testing.expect_value(t,r.status,400)
    wrong:=future;wrong.body=mq_http_seal("wrong vault")
    r=acp_chat_call(&f,wrong);testing.expect_value(t,r.status,400)
    // A terminal outbox revision sealed before rotation remains valid, too.
    input.revision=2;input.message_status="failed";input.stop_reason="acp_turn_interrupted"
    r=acp_chat_call(&f,input);testing.expect(t,r.status==200 && strings.contains(r.body,`"relayed":true`),r.body)
    _,found,_:=iface.content_get_message(&f.mq.repo,input.message_id)
    testing.expect(t,!found,"G12: a relayed segment is never stored")
}
acp_chat_open :: proc(t:^testing.T,f:^ACP_Chat_Fixture) {
    mq_http_open(t,&f.mq,"acp")
    f.repos.content=f.mq.repo; f.repos.agents=f.mq.base.ag_repo
    f.factory=sqlite.new_unit_of_work_factory(&f.impl,&f.mq.base.conn,&f.repos)
    f.vault_repo={get_directory=acp_chat_directory,list_devices=acp_chat_devices}
    f.mq.svc.uow_factory=&f.factory; f.mq.svc.vault_directory=&f.vault_repo
    inst,_,_:=iface.agent_get_instance(&f.mq.base.ag_repo,"inst_mq")
    inst.launch_epoch="epoch"; inst.runtime_transport="acp"; inst.run_count+=1
    _,ok,e:=iface.agent_save_instance(&f.mq.base.ag_repo,inst); testing.expect(t,ok,e.message)
}
acp_chat_call :: proc(f:^ACP_Chat_Fixture,input:contracts.ACP_Assistant_Message_Input,token:="hit_inst_mq~epoch") -> Response {
    raw,_:=json.marshal(struct{agent_instance_id:string,params:contracts.ACP_Assistant_Message_Input}{"inst_mq",input},allocator=context.temp_allocator)
    req:=mq_http_req(f.mq.base,"/api/v1/agent-actions/chat/assistant-message",string(raw))
    req.headers={{name="Authorization",value=fmt.tprintf("Bearer %s",f.mq.base.bridge_token)},{name="X-Heimdall-Instance-Token",value=token}}
    return agent_action_chat_assistant_message_handler(&f.mq.agent_handlers,req)
}

Acp_Chat_Bus :: struct {
    bus: events.User_Event_Bus,
    listener, peer, socket: net.TCP_Socket,
    slot: int,
}
// One owner UI socket on a real User_Event_Bus; frames are read from peer.
acp_chat_bus_open :: proc(t:^testing.T,f:^ACP_Chat_Fixture,b:^Acp_Chat_Bus) -> bool {
    lerr,derr,aerr:net.Network_Error
    b.listener,lerr=net.listen_tcp({address=net.IP4_Loopback,port=0});if !testing.expect(t,lerr==nil) do return false
    endpoint,_:=net.bound_endpoint(b.listener)
    b.peer,derr=net.dial_tcp(endpoint);if !testing.expect(t,derr==nil) do return false
    b.socket,_,aerr=net.accept_tcp(b.listener);if !testing.expect(t,aerr==nil) do return false
    _=net.set_option(b.peer,.Receive_Timeout,500*time.Millisecond)
    b.slot=events.user_ws_add(&b.bus,"tanmay",b.socket);if !testing.expect(t,b.slot>=0) do return false
    f.mq.agent_handlers.event_bus=&b.bus
    return true
}
acp_chat_bus_close :: proc(b:^Acp_Chat_Bus) {
    if b.slot>=0 do events.user_ws_remove(&b.bus,b.slot)
    net.close(b.socket);net.close(b.peer);net.close(b.listener)
}
// Reads one complete WS text frame payload (server frames are unmasked).
acp_chat_bus_frame :: proc(b:^Acp_Chat_Bus) -> string {
    buf:=make([dynamic]byte,context.temp_allocator)
    chunk:[65536]byte
    for {
        if len(buf)>=2 {
            n:=int(buf[1]&0x7f);head:=2
            if n==126 { if len(buf)<4 do n=-1; else { n=int(buf[2])<<8|int(buf[3]);head=4 } }
            else if n==127 { if len(buf)<10 do n=-1; else { m:=0;for i in 2..<10 do m=m<<8|int(buf[i]);n=m;head=10 } }
            if n>=0 && len(buf)>=head+n do return string(buf[head:head+n])
        }
        got,err:=net.recv_tcp(b.peer,chunk[:]);if err!=nil || got<=0 do return ""
        append(&buf,..chunk[:got])
    }
}

// G12: ACP assistant output reaches the owner's UI stream and nothing else:
// no chat message, no unread bump, no preview, no stored revision index.
@(test)
g12_assistant_segment_streams_to_ui_without_storing :: proc(t:^testing.T) {
    arena:virtual.Arena; _=virtual.arena_init_growing(&arena); defer virtual.arena_destroy(&arena)
    context.allocator=virtual.arena_allocator(&arena); context.temp_allocator=context.allocator
    f:ACP_Chat_Fixture; acp_chat_open(t,&f); defer mq_http_base_close(f.mq.base)
    b:Acp_Chat_Bus;b.slot=-1;defer acp_chat_bus_close(&b)
    if !acp_chat_bus_open(t,&f,&b) do return
    before,_,_:=iface.content_get_conversation(&f.mq.repo,"chat_mq")
    input:=contracts.ACP_Assistant_Message_Input{launch_epoch="epoch",turn_id="turn",message_id="msg_0123456789abcdef",revision=1,body=acp_chat_seal("Hello"),message_status="pending",input_ids={"msg_input_a"}}
    r:=acp_chat_call(&f,input); testing.expect(t,r.status==200 && strings.contains(r.body,`"relayed":true`) && strings.contains(r.body,`"persisted":false`),r.body)
    frame:=acp_chat_bus_frame(&b)
    for want in ([]string{`"type":"agent_output"`,`"event":"assistant_segment"`,`"conversation_id":"chat_mq"`,`"agent_instance_id":"inst_mq"`,`"message_id":"msg_0123456789abcdef"`,`"revision":1`,`"message_status":"pending"`,`"input_ids":["msg_input_a"]`,input.body}) {
        testing.expectf(t,strings.contains(frame,want),"frame lacks %s: %s",want,frame)
    }
    input.revision=2; input.message_status="complete"; input.stop_reason="end_turn"; input.body=acp_chat_seal("Hello world")
    r=acp_chat_call(&f,input); testing.expect(t,r.status==200,r.body)
    frame=acp_chat_bus_frame(&b)
    testing.expect(t,strings.contains(frame,`"revision":2`) && strings.contains(frame,`"message_status":"complete"`) && strings.contains(frame,`"stop_reason":"end_turn"`) && strings.contains(frame,input.body),frame)
    testing.expect(t,strings.contains(frame,`"kind":"text"`),frame)
    // Thoughts and plans stream the same way, under their own kind.
    thought:=input; thought.kind="thought"; thought.message_id="msg_00000000000000aa"; thought.revision=1; thought.message_status="pending"; thought.stop_reason=""
    r=acp_chat_call(&f,thought); testing.expect(t,r.status==200,r.body)
    frame=acp_chat_bus_frame(&b)
    testing.expect(t,strings.contains(frame,`"kind":"thought"`) && strings.contains(frame,`"message_id":"msg_00000000000000aa"`),frame)
    bogus:=thought; bogus.kind="input_state"
    r=acp_chat_call(&f,bogus); testing.expect_value(t,r.status,400)
    testing.expect_value(t,b.bus.stream_seqs[b.slot],u64(3))
    // Fresh repository reads: the hub stored nothing about the stream.
    fresh_impl:sqlite.Content_Repo_SQLite; fresh:=sqlite.new_content_repository(&fresh_impl,&f.mq.base.conn)
    _,found,_:=iface.content_get_message(&fresh,input.message_id)
    testing.expect(t,!found,"assistant segment must not become a chat message")
    rows,_:=iface.content_list_messages(&fresh,"chat_mq","tanmay",100,"")
    testing.expect_value(t,len(rows),0)
    c,_,_:=iface.content_get_conversation(&fresh,"chat_mq")
    testing.expect_value(t,c.unread_count,before.unread_count)
    testing.expect_value(t,c.last_message_preview,before.last_message_preview)
    testing.expect_value(t,c.last_message_at,before.last_message_at)
}

// G12: the agent's reply is its explicit chat send, on ACP as on PTY.
@(test)
g12_acp_agent_chat_send_lands_as_message :: proc(t:^testing.T) {
    arena:virtual.Arena; _=virtual.arena_init_growing(&arena); defer virtual.arena_destroy(&arena)
    context.allocator=virtual.arena_allocator(&arena); context.temp_allocator=context.allocator
    f:ACP_Chat_Fixture; acp_chat_open(t,&f); defer mq_http_base_close(f.mq.base)
    body:=acp_chat_seal("The reply")
    raw,_:=json.marshal(struct{agent_instance_id:string,params:struct{body:string}}{"inst_mq",{body}},allocator=context.temp_allocator)
    req:=mq_http_req(f.mq.base,"/api/v1/agent-actions/chat/send-to-user",string(raw))
    req.headers={{name="Authorization",value=fmt.tprintf("Bearer %s",f.mq.base.bridge_token)},{name="X-Heimdall-Instance-Token",value="hit_inst_mq~epoch"}}
    r:=agent_action_chat_send_to_user_handler(&f.mq.agent_handlers,req)
    testing.expect(t,r.status==201,r.body)
    rows,_:=iface.content_list_messages(&f.mq.repo,"chat_mq","tanmay",100,"")
    testing.expect(t,len(rows)==1 && rows[0].direction=="agent_to_user" && rows[0].body==body,"explicit chat send is stored")
    c,_,_:=iface.content_get_conversation(&f.mq.repo,"chat_mq")
    testing.expect_value(t,c.unread_count,1)
    testing.expect_value(t,c.last_message_preview,body)
}

@(test)
t5_assistant_auth_epoch_vault_and_cap :: proc(t:^testing.T) {
    arena:virtual.Arena; _=virtual.arena_init_growing(&arena); defer virtual.arena_destroy(&arena)
    context.allocator=virtual.arena_allocator(&arena); context.temp_allocator=context.allocator
    f:ACP_Chat_Fixture; acp_chat_open(t,&f); defer mq_http_base_close(f.mq.base)
    input:=contracts.ACP_Assistant_Message_Input{launch_epoch="epoch",turn_id="turn",message_id="msg_0123456789abcdef",revision=1,body=acp_chat_seal("hello"),message_status="pending"}
    r:=acp_chat_call(&f,input,""); testing.expect_value(t,r.status,403)
    r=acp_chat_call(&f,input,"hit_other~epoch"); testing.expect(t,r.status>=400)
    input.launch_epoch="old"; r=acp_chat_call(&f,input); testing.expect_value(t,r.status,403)
    input.launch_epoch="epoch"; input.body="plaintext"; r=acp_chat_call(&f,input); testing.expect_value(t,r.status,400)
    input.body=mq_http_seal("another vault"); r=acp_chat_call(&f,input); testing.expect_value(t,r.status,400)
    input.body=strings.repeat("x",domain.vault_armored_max_bytes(contracts.ACP_ASSISTANT_MAX_BYTES)+1,context.temp_allocator)
    r=acp_chat_call(&f,input); testing.expect_value(t,r.status,400)
    input.body=acp_chat_seal(strings.repeat("x",contracts.ACP_ASSISTANT_MAX_BYTES,context.temp_allocator))
    r=acp_chat_call(&f,input); testing.expect(t,r.status==200,"stream bound must permit the full 1 MiB snapshot")
}

// A segment from a replaced launch is acknowledged (so the bridge drops it from
// its outbox) but not relayed; forged assertions are still refused.
@(test)
g12_assistant_stale_epoch_acknowledged_not_relayed :: proc(t:^testing.T) {
    arena:virtual.Arena; _=virtual.arena_init_growing(&arena); defer virtual.arena_destroy(&arena)
    context.allocator=virtual.arena_allocator(&arena); context.temp_allocator=context.allocator
    f:ACP_Chat_Fixture; acp_chat_open(t,&f); defer mq_http_base_close(f.mq.base)
    b:Acp_Chat_Bus;b.slot=-1;defer acp_chat_bus_close(&b)
    if !acp_chat_bus_open(t,&f,&b) do return
    inst,_,_:=iface.agent_get_instance(&f.mq.base.ag_repo,"inst_mq")
    inst.launch_epoch="replacement"; inst.run_count+=1
    _,saved,e:=iface.agent_save_instance(&f.mq.base.ag_repo,inst); testing.expect(t,saved,e.message)
    input:=contracts.ACP_Assistant_Message_Input{launch_epoch="epoch",turn_id="turn",message_id="msg_0123456789abcdef",revision=2,body=acp_chat_seal("partial"),message_status="failed",stop_reason="acp_turn_interrupted"}
    r:=acp_chat_call(&f,input); testing.expect(t,r.status==200 && strings.contains(r.body,`"relayed":false`),r.body)
    testing.expect_value(t,b.bus.stream_seqs[b.slot],u64(0))
    r=acp_chat_call(&f,input,"hit_inst_mq~forged"); testing.expect_value(t,r.status,403)
    original:=f.mq.base.bridge_token; f.mq.base.bridge_token="wrong"
    r=acp_chat_call(&f,input); testing.expect_value(t,r.status,403)
    f.mq.base.bridge_token=original
    // A PTY instance cannot publish ACP segments, even at its current epoch.
    inst,_,_=iface.agent_get_instance(&f.mq.base.ag_repo,"inst_mq")
    inst.runtime_transport="pty"; inst.run_count+=1
    _,saved,e=iface.agent_save_instance(&f.mq.base.ag_repo,inst); testing.expect(t,saved,e.message)
    current:=input; current.launch_epoch="replacement"
    r=acp_chat_call(&f,current,"hit_inst_mq~replacement"); testing.expect_value(t,r.status,409)
    _,found,_:=iface.content_get_message(&f.mq.repo,input.message_id); testing.expect(t,!found)
    testing.expect_value(t,b.bus.stream_seqs[b.slot],u64(0))
    // The generic read action still rejects an old-epoch assertion.
    req:=mq_http_req(f.mq.base,"/api/v1/agent-actions/chat/read",`{"agent_instance_id":"inst_mq","params":{}}`)
    req.headers={{name="Authorization",value=fmt.tprintf("Bearer %s",original)},{name="X-Heimdall-Instance-Token",value="hit_inst_mq~epoch"}}
    r=agent_action_chat_read_handler(&f.mq.agent_handlers,req); testing.expect_value(t,r.status,403)
}

@(test)
t5_chat_ack_validates_entire_batch_and_replays :: proc(t:^testing.T) {
    arena:virtual.Arena; _=virtual.arena_init_growing(&arena); defer virtual.arena_destroy(&arena)
    context.allocator=virtual.arena_allocator(&arena); context.temp_allocator=context.allocator
    f:ACP_Chat_Fixture; acp_chat_open(t,&f); defer mq_http_base_close(f.mq.base)
    for cid,i in ([]string{"chat_mq","chat_other"}) {
        _,ok,e:=iface.content_save_message(&f.mq.repo,{message_id="msg_in" if i==0 else "msg_other",conversation_id=cid,owner_user_id="tanmay",direction="user_to_agent",sender_agent_instance_id="inst_mq",message_type="previous_context",body=acp_chat_seal("input"),created_at="now"})
        testing.expect(t,ok,e.message)
    }
    req:=mq_http_req(f.mq.base,"/api/v1/agent-actions/chat/read",`{"agent_instance_id":"inst_mq","params":{"ack_message_ids":["msg_in","msg_other"]}}`)
    req.headers={{name="Authorization",value=fmt.tprintf("Bearer %s",f.mq.base.bridge_token)},{name="X-Heimdall-Instance-Token",value="hit_inst_mq~epoch"}}
    r:=agent_action_chat_read_handler(&f.mq.agent_handlers,req); testing.expect_value(t,r.status,400)
    row,_,_:=iface.content_get_message(&f.mq.repo,"msg_in"); testing.expect_value(t,row.read_at,"")
    req.body=`{"agent_instance_id":"inst_mq","params":{"ack_message_ids":["msg_in"],"target_instance_id":"inst_mq"}}`
    r=agent_action_chat_read_handler(&f.mq.agent_handlers,req); testing.expect_value(t,r.status,400)
    req.body=`{"agent_instance_id":"inst_mq","params":{"ack_message_ids":["msg_in","msg_in"]}}`
    r=agent_action_chat_read_handler(&f.mq.agent_handlers,req); testing.expect(t,r.status==200,r.body)
    testing.expect(t,strings.contains(r.body,`"marked_count":1`))
    r=agent_action_chat_read_handler(&f.mq.agent_handlers,req); testing.expect_value(t,r.status,200)
    testing.expect(t,strings.contains(r.body,`"marked_count":0`))
}

@(test)
t5_conversation_message_read_is_owner_specific :: proc(t:^testing.T) {
    arena:virtual.Arena; _=virtual.arena_init_growing(&arena); defer virtual.arena_destroy(&arena)
    context.allocator=virtual.arena_allocator(&arena);context.temp_allocator=context.allocator
    f:ACP_Chat_Fixture;acp_chat_open(t,&f);defer mq_http_base_close(f.mq.base)
    body:=acp_chat_seal("private")
    _,ok,e:=iface.content_save_message(&f.mq.repo,{message_id="msg_0123456789abcdef",conversation_id="chat_mq",owner_user_id="tanmay",direction="agent_to_user",sender_agent_instance_id="inst_mq",body=body,artifact_ids_json="[]",message_type="text",created_at="now"})
    testing.expect(t,ok,e.message)
    req:=mq_http_req(f.mq.base,"/api/v1/chats/chat_mq/messages/msg_0123456789abcdef","");req.method="GET"
    r:=get_conversation_message_handler(&f.mq.handlers,req);testing.expect(t,r.status==200 && strings.contains(r.body,body))
    req.path="/api/v1/chats/chat_other/messages/msg_0123456789abcdef"
    r=get_conversation_message_handler(&f.mq.handlers,req);testing.expect_value(t,r.status,404)
    req=mq_http_req(f.mq.base,"/api/v1/chats/chat_mq/messages/msg_0123456789abcdef","", "other-user");req.method="GET"
    r=get_conversation_message_handler(&f.mq.handlers,req);testing.expect(t,r.status==403 || r.status==404,"a cookie session cannot read another owner's message")
}

@(test)
t5_chat_oldest_first_drains_tied_timestamps_before_newer_input :: proc(t:^testing.T) {
    arena:virtual.Arena;_=virtual.arena_init_growing(&arena);defer virtual.arena_destroy(&arena)
    context.allocator=virtual.arena_allocator(&arena);context.temp_allocator=context.allocator
    f:ACP_Chat_Fixture;acp_chat_open(t,&f);defer mq_http_base_close(f.mq.base)
    for i in 0..<103 {
        _,ok,e:=iface.content_save_message(&f.mq.repo,{message_id=fmt.tprintf("msg_%04d",i),conversation_id="chat_mq",owner_user_id="tanmay",direction="user_to_agent" if i<102 else "agent_to_agent",sender_agent_instance_id="inst_mq" if i<102 else "inst_origin",body=acp_chat_seal("input"),created_at="2026-11-18T00:00:00Z"})
        testing.expect(t,ok,e.message)
    }
    for batch in 0..<2 {
        req:=mq_http_req(f.mq.base,"/api/v1/agent-actions/chat/read",`{"agent_instance_id":"inst_mq","params":{"mark_read":false,"unread_only":true,"receiver_only":true,"oldest_first":true,"limit":100}}`)
        req.headers={{name="Authorization",value=fmt.tprintf("Bearer %s",f.mq.base.bridge_token)},{name="X-Heimdall-Instance-Token",value="hit_inst_mq~epoch"}}
        r:=agent_action_chat_read_handler(&f.mq.agent_handlers,req);testing.expect(t,r.status==200,r.body)
        parsed,_:=json.parse(r.body,allocator=context.temp_allocator);root,_:=parsed.(json.Object);data,_:=root["data"].(json.Object);rows,_:=data["messages"].(json.Array)
        testing.expect_value(t,len(rows),100 if batch==0 else 3)
        testing.expect(t,strings.contains(r.body,`"sender_agent_instance_id":"inst_origin"`) if batch==1 else strings.contains(r.body,`"sender_agent_instance_id":"inst_mq"`),"direct prompts require the durable sender identity")
        ids:=make([dynamic]string,allocator=context.temp_allocator)
        for row,i in rows { item,_:=row.(json.Object);id,_:=item["message_id"].(json.String);testing.expect_value(t,string(id),fmt.tprintf("msg_%04d",batch*100+i));append(&ids,string(id)) }
        raw,_:=json.marshal(struct{agent_instance_id:string,params:struct{ack_message_ids:[]string}}{"inst_mq",{ids[:]}},allocator=context.temp_allocator)
        req.body=string(raw);r=agent_action_chat_read_handler(&f.mq.agent_handlers,req);testing.expect(t,r.status==200,r.body)
    }
}
