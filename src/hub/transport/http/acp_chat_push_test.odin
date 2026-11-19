package http

import "core:fmt"
import "core:mem/virtual"
import "core:net"
import "core:strings"
import "core:testing"
import "core:time"
import iface "odin_test:hub/repository/iface"
import events "odin_test:hub/service/events"

@(test)
t13_chat_input_source_auth_and_activity_bubbles :: proc(t:^testing.T) {
    arena:virtual.Arena;_=virtual.arena_init_growing(&arena);defer virtual.arena_destroy(&arena)
    context.allocator=virtual.arena_allocator(&arena);context.temp_allocator=context.allocator
    f:ACP_Chat_Fixture;acp_chat_open(t,&f);defer mq_http_base_close(f.mq.base)
    listener,lerr:=net.listen_tcp({address=net.IP4_Loopback,port=0});testing.expect(t,lerr==nil);if lerr!=nil do return
    defer net.close(listener)
    endpoint,_:=net.bound_endpoint(listener)
    peer,derr:=net.dial_tcp(endpoint);testing.expect(t,derr==nil);if derr!=nil do return
    defer net.close(peer)
    socket,_,aerr:=net.accept_tcp(listener);testing.expect(t,aerr==nil);if aerr!=nil do return
    defer net.close(socket)
    _=net.set_option(peer,.Receive_Timeout,100*time.Millisecond)
    bus:events.User_Event_Bus
    slot:=events.user_ws_add(&bus,"tanmay",socket);testing.expect(t,slot>=0);if slot<0 do return
    defer events.user_ws_remove(&bus,slot)
    f.mq.agent_handlers.event_bus=&bus
    req:=mq_http_req(f.mq.base,"/api/v1/agent-actions/chat/read",`{"agent_instance_id":"inst_mq","params":{}}`)
    req.headers={{name="Authorization",value=fmt.tprintf("Bearer %s",f.mq.base.bridge_token)},{name="X-Heimdall-Instance-Token",value="hit_inst_mq~epoch"}}
    // Both empty CLI reads and fetches are silent.
    r:=agent_action_chat_read_handler(&f.mq.agent_handlers,req);testing.expect_value(t,r.status,200)
    r=agent_action_chat_fetch_handler(&f.mq.agent_handlers,req);testing.expect_value(t,r.status,200)
    testing.expect_value(t,bus.stream_seqs[slot],u64(0))
    _,saved,e:=iface.content_save_message(&f.mq.repo,{message_id="msg_input",conversation_id="chat_mq",owner_user_id="tanmay",direction="user_to_agent",body=acp_chat_seal("hello"),created_at="now"})
    testing.expect(t,saved,e.message)
    req.body=`{"agent_instance_id":"inst_mq","params":{"input_source":"bridge_acp","mark_read":false}}`
    r=agent_action_chat_read_handler(&f.mq.agent_handlers,req)
    testing.expect(t,r.status==200 && strings.contains(r.body,"msg_input"),r.body)
    testing.expect_value(t,bus.stream_seqs[slot],u64(0))
    // The source does not bypass Bridge/instance auth, transport or target checks.
    original:=req.headers
    req.headers=nil;r=agent_action_chat_read_handler(&f.mq.agent_handlers,req);testing.expect_value(t,r.status,401)
    req.headers=original
    req.headers={{name="Authorization",value=fmt.tprintf("Bearer %s",f.mq.base.bridge_token)},{name="X-Heimdall-Instance-Token",value="hit_inst_mq~wrong_epoch"}}
    r=agent_action_chat_read_handler(&f.mq.agent_handlers,req);testing.expect_value(t,r.status,403)
    req.headers=original
    req.body=`{"agent_instance_id":"inst_mq","params":{"input_source":"bridge_acp","target_instance_id":"inst_other"}}`
    r=agent_action_chat_read_handler(&f.mq.agent_handlers,req);testing.expect_value(t,r.status,403)
    req.body=`{"agent_instance_id":"inst_mq","params":{"input_source":"unknown"}}`
    r=agent_action_chat_read_handler(&f.mq.agent_handlers,req);testing.expect_value(t,r.status,400)
    inst,_,_:=iface.agent_get_instance(&f.mq.base.ag_repo,"inst_mq")
    inst.agent_instance_id="inst_pty";inst.runtime_transport="pty";inst.launch_epoch=""
    _,saved,e=iface.agent_save_instance(&f.mq.base.ag_repo,inst);testing.expect(t,saved,e.message)
    req.headers={{name="Authorization",value=fmt.tprintf("Bearer %s",f.mq.base.bridge_token)},{name="X-Heimdall-Instance-Token",value="hit_inst_pty"}}
    req.body=`{"agent_instance_id":"inst_pty","params":{"input_source":"bridge_acp"}}`
    r=agent_action_chat_read_handler(&f.mq.agent_handlers,req);testing.expect_value(t,r.status,403)
    req.headers=original
    testing.expect_value(t,bus.stream_seqs[slot],u64(0))
    // Normal agent CLI reads retain the bubble even on an ACP instance.
    req.body=`{"agent_instance_id":"inst_mq","params":{"mark_read":false}}`
    r=agent_action_chat_read_handler(&f.mq.agent_handlers,req);testing.expect_value(t,r.status,200)
    testing.expect_value(t,bus.stream_seqs[slot],u64(1))
    buf:[4096]byte
    n,err:=net.recv_tcp(peer,buf[:]);testing.expect(t,err==nil && strings.contains(string(buf[:n]),`"action":"chat_read"`))
    r=agent_action_chat_fetch_handler(&f.mq.agent_handlers,req);testing.expect_value(t,r.status,200)
    testing.expect_value(t,bus.stream_seqs[slot],u64(2))
    n,err=net.recv_tcp(peer,buf[:]);testing.expect(t,err==nil && strings.contains(string(buf[:n]),`"action":"chat_fetch"`))
    // A bridge ack still sends the read receipt, with no activity bubble.
    req.body=`{"agent_instance_id":"inst_mq","params":{"ack_message_ids":["msg_input"]}}`
    r=agent_action_chat_read_handler(&f.mq.agent_handlers,req);testing.expect_value(t,r.status,200)
    testing.expect_value(t,bus.stream_seqs[slot],u64(3))
    n,err=net.recv_tcp(peer,buf[:]);testing.expect(t,err==nil && strings.contains(string(buf[:n]),"messages_read") && !strings.contains(string(buf[:n]),"agent_action"))
    req.body=`{"agent_instance_id":"inst_mq","params":{}}`
    r=agent_action_chat_read_handler(&f.mq.agent_handlers,req);testing.expect_value(t,r.status,200)
    testing.expect_value(t,bus.stream_seqs[slot],u64(3))
}
