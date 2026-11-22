package http

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import bots "odin_test:hub/service/bots"
import sqlite "odin_test:hub/repository/sqlite"
import agent_service "odin_test:hub/service/agent"
import project_service "odin_test:hub/service/project"
import ws "odin_test:lib/ws"

@(private = "file")
Tool_HTTP_Test :: struct { h: Agent_Handlers, sock: net.TCP_Socket, mu: sync.Mutex, cond: sync.Cond, attached, detached: int, token: string }
@(private = "file")
tool_http_test_run :: proc(raw: rawptr) {
    context=runtime.default_context()
    f:=(^Tool_HTTP_Test)(raw)
    // Model the router's socket ownership: handler joins writer before this close.
    defer net.close(f.sock)
    tool_stream_handler(&f.h,Request{query="ticket=tool_ticket",headers=[]contracts.HTTP_Header{{name="Sec-WebSocket-Key",value="dGhlIHNhbXBsZSBub25jZQ=="}}},f.sock)
}
@(private = "file")
tool_http_test_read :: proc(t: ^testing.T, socket: net.TCP_Socket, reader: ^ws.Frame_Reader) -> json.Object {
    _,body,got:=ws.read_frame(socket,reader,time.Second)
    testing.expect(t,got)
    if !got do return nil
    defer delete(body)
    value,_:=json.parse_string(body,.JSON,true,context.temp_allocator)
    obj,_:=value.(json.Object)
    return obj
}
@(test)
test_tool_stream_http_ticket_json_lifecycle_and_empty_baseline :: proc(t: ^testing.T) {
    pair,ok:=tool_http_pair(t)
    if !ok do return
    // The test owns the client; the handler thread owns and closes the Hub fd.
    defer net.close(pair.client)
    defer net.close(pair.listener)
    tickets:=new_user_ws_ticket_store();defer user_ws_ticket_store_free(&tickets)
    user_ws_ticket_store_put(&tickets,"tool_ticket",{kind=.Session,user_id="owner"},60)
    f: Tool_HTTP_Test
    repo:=iface.Agent_Repository{get_tool_instance=proc(ctx:rawptr,id:string)->(domain.Agent_Instance,bool,domain.Domain_Error){
        return domain.Agent_Instance{agent_instance_id=id,owner_user_id="owner" if id=="inst_a" else "foreign",bridge_id="brg_a",runtime_status="running"},true,{}
    }}
    content := iface.Content_Repository{get_conversation = proc(ctx: rawptr, id: string) -> (domain.Chat_Conversation, bool, domain.Domain_Error) {
        return domain.Chat_Conversation{conversation_id = id, owner_user_id = "owner", agent_instance_id = "inst_a"}, id == "chat_a", {}
    }}
    svc:=agent_service.Agent_Service{agents=&repo, content=&content}
    defer agent_service.tool_live_destroy(&svc.tool_live)
    svc.bridge_command_sink={ctx=&f,send_runtime_command=proc(raw:rawptr,c:project_service.Runtime_Command)->(bool,domain.Domain_Error){
        f:=(^Tool_HTTP_Test)(raw)
        value,_:=json.parse_string(c.body_json,.JSON,true,context.temp_allocator)
        root:=value.(json.Object)
        controls, _ := root["controls"].(json.Array)
        sync.mutex_lock(&f.mu);defer sync.mutex_unlock(&f.mu)
        for item in controls {
        obj := item.(json.Object)
        if agent_service.tool_live_text(obj,"type")=="tool_stream_attach" {
            f.attached+=1
            delete(f.token,runtime.heap_allocator())
            f.token=strings.clone(agent_service.tool_live_text(obj,"subscription_id"),runtime.heap_allocator())
        } else { f.detached+=1 }
        }
        sync.cond_signal(&f.cond)
        return true,{}
    }}
    f.h={agents=&svc,ws_tickets=&tickets};f.sock=pair.hub
    worker:=thread.create_and_start_with_data(&f,tool_http_test_run,self_cleanup=false)
    if worker==nil { net.close(pair.hub); return }
    defer {
        _=net.shutdown(pair.client,.Both)
        thread.join(worker);thread.destroy(worker)
        // Control worker can still use the fixture until service destruction.
    }
    response,got:=tool_http_response(pair.client,time.Second)
    testing.expect(t,got&&strings.contains(response,"101 Switching Protocols"));delete(response)
    conn:=ws.Connection{socket=pair.client,connected=true}
    reader:=ws.reader_make();defer ws.reader_destroy(&reader)
    testing.expect(t,ws.send_text(&conn,`{"type":"subscribe","instance_ids":["inst_a"]}`))
    legacy:=tool_http_test_read(t,pair.client,&reader)
    testing.expect_value(t,agent_service.tool_live_text(legacy,"code"),"upgrade_required")
    sync.mutex_lock(&f.mu)
    testing.expect_value(t,f.attached,0)
    sync.mutex_unlock(&f.mu)
    testing.expect(t,ws.send_text(&conn,`{"type":"subscribe","version":2,"views":[{"conversation_id":"chat_a","instance_ids":["inst_a"]}]}`))
    ack:=tool_http_test_read(t,pair.client,&reader)
    testing.expect_value(t,agent_service.tool_live_text(ack,"type"),"subscribed")
    sync.mutex_lock(&f.mu)
    for f.attached==0 { if !sync.cond_wait_with_timeout(&f.cond,&f.mu,time.Second) do break }
    token:=strings.clone(f.token);count:=f.attached
    sync.mutex_unlock(&f.mu)
    defer delete(token)
    testing.expect_value(t,count,1)
    frame:=fmt.tprintf(`{{"type":"tool_stream_state","epoch":"1000","subscription_id":"%s","run_count":0,"baseline":true,"snapshot":{{"instance_id":"inst_a","epoch":"1000","generation":1,"revision":0,"run_count":0,"active":[],"completed_since_last":[]}}}}`,token)
    testing.expect(t,agent_service.tool_live_apply_bridge(&svc,"brg_a",0,"1000",frame))
    baseline:=tool_http_test_read(t,pair.client,&reader)
    testing.expect_value(t,agent_service.tool_live_text(baseline,"type"),"state")
    snap:=baseline["snapshot"].(json.Object)
    testing.expect_value(t,len(snap["active"].(json.Array)),0)
    testing.expect_value(t,len(snap["completed_since_last"].(json.Array)),0)
    testing.expect(t,ws.send_text(&conn,`{"type":"subscribe","version":2,"views":[{"conversation_id":"chat_a","instance_ids":["inst_foreign"]}]}`))
    // A refused member degrades to a per-instance frame; the roster itself is accepted.
    replaced:=tool_http_test_read(t,pair.client,&reader)
    testing.expect_value(t,agent_service.tool_live_text(replaced,"type"),"subscribed")
    testing.expect_value(t,len(replaced["instance_ids"].(json.Array)),0)
    refused:=tool_http_test_read(t,pair.client,&reader)
    testing.expect_value(t,agent_service.tool_live_text(refused,"type"),"unavailable")
    testing.expect_value(t,agent_service.tool_live_text(refused,"instance_id"),"inst_foreign")
    testing.expect_value(t,agent_service.tool_live_text(refused,"reason"),"forbidden")
    // A conversation the viewer does not own still refuses the whole subscription.
    testing.expect(t,ws.send_text(&conn,`{"type":"subscribe","version":2,"views":[{"conversation_id":"chat_foreign","instance_ids":["inst_a"]}]}`))
    denied:=tool_http_test_read(t,pair.client,&reader)
    testing.expect_value(t,agent_service.tool_live_text(denied,"code"),"forbidden")
    testing.expect(t,ws.send_text(&conn,`{"type":"ping"}`))
    pong:=tool_http_test_read(t,pair.client,&reader)
    testing.expect_value(t,agent_service.tool_live_text(pong,"type"),"pong")
    testing.expect(t,ws.send_text(&conn,`{"type":"subscribe","version":2,"views":[]}`))
    ack=tool_http_test_read(t,pair.client,&reader)
    testing.expect_value(t,len(ack["instance_ids"].(json.Array)),0)
    sync.mutex_lock(&f.mu)
    for f.detached==0 { if !sync.cond_wait_with_timeout(&f.cond,&f.mu,time.Second) do break }
    count=f.detached
    sync.mutex_unlock(&f.mu)
    testing.expect_value(t,count,1)
    // Token is deliberately one-shot.
    _,reused:=user_ws_ticket_store_consume(&tickets,"tool_ticket")
    testing.expect(t,!reused)
    // Keep fixture-owned strings until the control worker has stopped.
    sync.mutex_lock(&svc.tool_live.mutex)
    svc.tool_live.stopped=true;sync.cond_signal(&svc.tool_live.control_cond)
    sync.mutex_unlock(&svc.tool_live.mutex)
    thread.join(svc.tool_live.control_worker)
    thread.destroy(svc.tool_live.control_worker);svc.tool_live.control_worker=nil
    delete(f.token,runtime.heap_allocator());f.token=""
}
@(test)
test_tool_stream_http_rejects_invalid_ticket_before_upgrade :: proc(t: ^testing.T) {
    pair,ok:=tool_http_pair(t);if !ok do return
    defer tool_http_pair_close(&pair)
    h:=Agent_Handlers{}
    tool_stream_handler(&h,Request{query="ticket=invalid"},pair.hub)
    response,got:=tool_http_response(pair.client,time.Second);defer delete(response)
    testing.expect(t,got&&strings.contains(response,"401 Unauthorized"))
}

@(private = "file")
Tool_HTTP_Pair :: struct {
	listener: net.TCP_Socket,
	client:   net.TCP_Socket,
	hub:      net.TCP_Socket,
}

@(private = "file")
tool_http_pair :: proc(t: ^testing.T) -> (Tool_HTTP_Pair, bool) {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil {
		testing.fail_now(t, "could not listen on loopback")
	}
	bound, bound_err := net.bound_endpoint(listener)
	if bound_err != nil {
		net.close(listener)
		testing.fail_now(t, "could not read bound endpoint")
	}
	client, dial_err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if dial_err != nil {
		net.close(listener)
		testing.fail_now(t, "could not dial loopback")
	}
	hub, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil {
		net.close(listener)
		net.close(client)
		testing.fail_now(t, "could not accept on loopback")
	}
	return Tool_HTTP_Pair{listener = listener, client = client, hub = hub}, true
}

@(private = "file")
tool_http_pair_close :: proc(p: ^Tool_HTTP_Pair) {
	if int(p.hub) > 0 { net.close(p.hub); p.hub = net.TCP_Socket(0) }
	if int(p.client) > 0 { net.close(p.client); p.client = net.TCP_Socket(0) }
	if int(p.listener) > 0 { net.close(p.listener); p.listener = net.TCP_Socket(0) }
}

// Read raw response string until timeout
@(private = "file")
tool_http_response :: proc(sock: net.TCP_Socket, timeout: time.Duration) -> (string, bool) {
	_ = net.set_option(sock, .Receive_Timeout, timeout)
	buf: [4096]byte
	acc := make([dynamic]byte)
	defer delete(acc)
	for {
		n, err := net.recv_tcp(sock, buf[:])
		if err != nil || n <= 0 do break
		append(&acc, ..buf[:n])
		s := string(acc[:])
		if strings.contains(s, "\r\n\r\n") {
			return strings.clone(s), true
		}
	}
	if len(acc) > 0 {
		return strings.clone(string(acc[:])), true
	}
	return "", false
}


@(test)
test_tool_stream_http_failed_upstream_route_is_unavailable :: proc(t: ^testing.T) {
    pair,ok:=tool_http_pair(t); if !ok do return
    defer net.close(pair.client)
    defer net.close(pair.listener)
    tickets:=new_user_ws_ticket_store(); defer user_ws_ticket_store_free(&tickets)
    user_ws_ticket_store_put(&tickets,"tool_ticket",{kind=.Session,user_id="owner"},60)
    repo:=iface.Agent_Repository{get_tool_instance=proc(ctx:rawptr,id:string)->(domain.Agent_Instance,bool,domain.Domain_Error) {
        return domain.Agent_Instance{agent_instance_id=id,owner_user_id="owner",bridge_id="brg_offline",runtime_status="running"},true,{}
    }}
    content := iface.Content_Repository{get_conversation = proc(ctx: rawptr, id: string) -> (domain.Chat_Conversation, bool, domain.Domain_Error) {
        return domain.Chat_Conversation{conversation_id = id, owner_user_id = "owner", agent_instance_id = "inst_a"}, id == "chat_a", {}
    }}
    svc:=agent_service.Agent_Service{agents=&repo, content=&content}
    defer agent_service.tool_live_destroy(&svc.tool_live)
    svc.bridge_command_sink={send_runtime_command=proc(ctx:rawptr,c:project_service.Runtime_Command)->(bool,domain.Domain_Error) { return false,{} }}
    f:=Tool_HTTP_Test{h={agents=&svc,ws_tickets=&tickets},sock=pair.hub}
    worker:=thread.create_and_start_with_data(&f,tool_http_test_run,self_cleanup=false)
    testing.expect(t,worker!=nil)
    if worker==nil {net.close(pair.hub); return}
    defer {
        _=net.shutdown(pair.client,.Both)
        thread.join(worker); thread.destroy(worker)
    }
    response,got:=tool_http_response(pair.client,time.Second)
    testing.expect(t,got&&strings.contains(response,"101 Switching Protocols")); delete(response)
    conn:=ws.Connection{socket=pair.client,connected=true}
    reader:=ws.reader_make(); defer ws.reader_destroy(&reader)
    testing.expect(t,ws.send_text(&conn,`{"type":"subscribe","version":2,"views":[{"conversation_id":"chat_a","instance_ids":["inst_a"]}]}`))
    ack:=tool_http_test_read(t,pair.client,&reader)
    testing.expect_value(t,agent_service.tool_live_text(ack,"type"),"subscribed")
    unavailable:=tool_http_test_read(t,pair.client,&reader)
    testing.expect_value(t,agent_service.tool_live_text(unavailable,"type"),"unavailable")
    testing.expect_value(t,agent_service.tool_live_text(unavailable,"instance_id"),"inst_a")
    testing.expect_value(t,agent_service.tool_live_text(unavailable,"reason"),"bridge_offline")
    testing.expect(t,ws.send_text(&conn,`{"type":"ping"}`))
    pong:=tool_http_test_read(t,pair.client,&reader)
    testing.expect_value(t,agent_service.tool_live_text(pong,"type"),"pong")
}

@(test)
test_tool_stream_ticket_preserves_session_identity_and_refuses_other_kinds :: proc(t: ^testing.T) {
    store := new_user_ws_ticket_store()
    defer user_ws_ticket_store_free(&store)
    user_ws_ticket_store_put(&store, "session_ticket", {kind = .Session, user_id = "owner", session_id = "sess_hash", expires_ms = 42}, 60)
    auth, ok := user_ws_ticket_store_consume(&store, "session_ticket")
    testing.expect(t, ok)
    testing.expect_value(t, auth.kind, contracts.Auth_Kind.Session)
    testing.expect_value(t, auth.session_id, "sess_hash")
    testing.expect_value(t, auth.expires_ms, i64(42))
    // Only browser sessions hold tickets; anything else stored is never honoured.
    user_ws_ticket_store_put(&store, "bearer_ticket", {kind = .OIDC, user_id = "owner"}, 60)
    _, bearer_ok := user_ws_ticket_store_consume(&store, "bearer_ticket")
    testing.expect(t, !bearer_ok)
}

@(test)
test_bot_view_runtime_ids_drive_external_tool_stream :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    c := bot_channel_fixture(t)
    defer bot_channel_destroy(c)
    f := c.f
    bot, found, err := iface.bot_get_by_owner(&f.bot_repo, string(f.wire.owner))
    defer domain.bot_destroy(&bot)
    if !testing.expectf(t, found && err.code == .None, "%v", err) do return
    // Use the same authenticated bot instance for both channel reads.
    if !testing.expect(t, sqlite.exec(&f.wire.conn, fmt.tprintf(
        "UPDATE agent_instances SET agent_id = '%s', conversation_id = 'chat_bot_tool' WHERE agent_instance_id = '%s';",
        bot.agent_id, f.wire.instance_id))) { return }
    _, saved, save_err := iface.content_save_conversation(&f.content_repo, {
        conversation_id = "chat_bot_tool", owner_user_id = f.wire.owner,
        agent_id = bot.agent_id, agent_instance_id = f.wire.instance_id, created_at = "now", updated_at = "now",
    })
    if !testing.expectf(t, saved && save_err.code == .None, "%v", save_err) do return

    response := bot_me_handler(&f.handlers, bot_http_request(f, "GET", "/api/v1/bots/me", ""))
    view: struct {data: bots.Bot_View}
    testing.expect_value(t, response.status, 200)
    testing.expect_value(t, json.unmarshal(transmute([]u8)response.body, &view, allocator = context.temp_allocator), nil)
    id, conversation, bridge := view.data.advanced.agent_instance_id, view.data.advanced.conversation_id, view.data.advanced.bridge_id
    if !testing.expect(t, id == f.wire.instance_id && conversation == "chat_bot_tool" && bridge == f.wire.bridge_pin) do return
    subscribe := fmt.tprintf(`{{"type":"subscribe","version":2,"views":[{{"conversation_id":"%s","instance_ids":["%s"]}}]}}`, conversation, id)
    svc := agent_service.Agent_Service{agents = &f.wire.ag_repo, content = &f.content_repo}
    stream: Tool_HTTP_Test
    defer {
        agent_service.tool_live_destroy(&svc.tool_live)
        delete(stream.token, runtime.heap_allocator())
    }
    svc.bridge_command_sink = {ctx = &stream, send_runtime_command = proc(raw: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
        stream := (^Tool_HTTP_Test)(raw)
        value, parse_err := json.parse_string(cmd.body_json, .JSON, true, context.temp_allocator)
        if parse_err != .None do return false, {}
        controls, _ := value.(json.Object)["controls"].(json.Array)
        sync.mutex_lock(&stream.mu)
        defer sync.mutex_unlock(&stream.mu)
        for control in controls {
            obj := control.(json.Object)
            if agent_service.tool_live_text(obj, "type") != "tool_stream_attach" do continue
            delete(stream.token, runtime.heap_allocator())
            stream.token = strings.clone(agent_service.tool_live_text(obj, "subscription_id"), runtime.heap_allocator())
            stream.attached += 1
        }
        sync.cond_signal(&stream.cond)
        return true, {}
    }}
    for owner in ([]string{string(f.wire.owner), "wire_foreign_owner"}) {
        pair, ok := tool_http_pair(t)
        if !ok do return
        defer net.close(pair.client)
        defer net.close(pair.listener)
        tickets := new_user_ws_ticket_store()
        defer user_ws_ticket_store_free(&tickets)
        user_ws_ticket_store_put(&tickets, "tool_ticket", {kind = .Session, user_id = owner}, 60)
        viewer := Tool_HTTP_Test{h = {agents = &svc, ws_tickets = &tickets}, sock = pair.hub}
        worker := thread.create_and_start_with_data(&viewer, tool_http_test_run, self_cleanup = false)
        if !testing.expect(t, worker != nil) { net.close(pair.hub); return }
        defer {
            _ = net.shutdown(pair.client, .Both)
            thread.join(worker)
            thread.destroy(worker)
        }
        handshake, got := tool_http_response(pair.client, time.Second)
        testing.expect(t, got && strings.contains(handshake, "101 Switching Protocols"))
        delete(handshake)
        conn := ws.Connection{socket = pair.client, connected = true}
        reader := ws.reader_make()
        defer ws.reader_destroy(&reader)
        testing.expect(t, ws.send_text(&conn, subscribe))
        ack := tool_http_test_read(t, pair.client, &reader)
        if owner != string(f.wire.owner) {
            testing.expect_value(t, agent_service.tool_live_text(ack, "code"), "forbidden")
            continue
        }
        testing.expect_value(t, agent_service.tool_live_text(ack, "type"), "subscribed")
        sync.mutex_lock(&stream.mu)
        for stream.attached == 0 {
            if !sync.cond_wait_with_timeout(&stream.cond, &stream.mu, time.Second) do break
        }
        token := strings.clone(stream.token, context.temp_allocator)
        sync.mutex_unlock(&stream.mu)
        if !testing.expect(t, token != "") do return
        inbound, fresh, web_err := bots.bots_web_send(&f.service, owner, "web question", "bot-tool-web")
        defer domain.channel_message_destroy(&inbound)
        testing.expectf(t, fresh && web_err.code == .None, "%v", web_err)
        for provider, revision in ([]string{"web", "telegram"}) {
            if provider == "telegram" do bot_channel_inbound(t, c, "chm_bot_tool_telegram")
            read := bot_channel_read(c)
            testing.expect_value(t, read.status, 200)
            testing.expect(t, strings.contains(read.body, fmt.tprintf(`"channel":"%s"`, provider)))
            // Simulate an authenticated Bridge snapshot during each channel's reply.
            frame := fmt.tprintf(`{{"type":"tool_stream_state","epoch":"1000","subscription_id":"%s","run_count":0,"snapshot":{{"instance_id":"%s","epoch":"1000","generation":1,"revision":%d,"run_count":0,"active":[{{"call_id":"test_%s"}}],"completed_since_last":[]}}}}`, token, id, revision + 1, provider)
            testing.expect(t, agent_service.tool_live_apply_bridge(&svc, bridge, 0, "1000", frame))
            activity := tool_http_test_read(t, pair.client, &reader)
            testing.expect_value(t, agent_service.tool_live_text(activity, "type"), "state")
            testing.expect_value(t, agent_service.tool_live_text(activity, "instance_id"), id)
            snapshot, _ := activity["snapshot"].(json.Object)
            active, _ := snapshot["active"].(json.Array)
            if testing.expect_value(t, len(active), 1) {
                row, _ := active[0].(json.Object)
                testing.expect_value(t, agent_service.tool_live_text(row, "call_id"), fmt.tprintf("test_%s", provider))
            }
            reply := bot_channel_send(c)
            testing.expect_value(t, reply.status, 200)
            testing.expect(t, strings.contains(reply.body, fmt.tprintf(`"channel":"%s"`, provider)))
        }
    }
}
