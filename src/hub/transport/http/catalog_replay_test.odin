package http

import "core:encoding/json"
import "core:mem"
import "base:runtime"
import "core:mem/virtual"
import "core:net"
import "core:strings"
import "core:testing"
import "core:time"
import events "odin_test:hub/service/events"
import eventinbox "odin_test:hub/service/eventinbox"
import eventrelay "odin_test:hub/service/eventrelay"
import nats "odin_test:lib/nats"
import natstest "odin_test:lib/natstest"
import ws "odin_test:lib/ws"

@(test)
test_user_ws_catalog_replay_and_live_sequence :: proc(t: ^testing.T) {
	http_nats_test_lock(); defer http_nats_test_unlock()
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track,context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator=mem.tracking_allocator(&track)
	catalog_ws_scenario(t)
	testing.expect_value(t,nats.shutdown(5000).status,i32(0))
	testing.expect_value(t,len(track.allocation_map),0)
}
catalog_ws_scenario :: proc(t: ^testing.T) {
	server,started:=natstest.start();defer natstest.destroy(&server)
	if !testing.expect(t,started) do return
	conn,ne:=nats.connect({url=server.url,timeout_ms=1000})
	if !testing.expect_value(t,ne.status,i32(0)) do return
	defer nats.destroy(conn)
	_,ne=nats.stream_add(conn,eventrelay.stream_config())
	testing.expect_value(t,ne.status,i32(0))
	for subject in ([]string{"ev.bob.chain.chain_1.task.task_1.state","ev.alice.chain.chain_1.task.task_1.state"}) {
		payload:=`{"event_id":"evt_missed","type":"task.state","owner_user_id":"alice","entity":{"kind":"task","id":"task_1"},"data":{"chain_id":"chain_1"}}`
		// Subject scoping also prevents an inconsistent foreign-tenant envelope.
		_,ne=nats.publish(conn,subject,transmute([]byte)payload)
		testing.expect_value(t,ne.status,i32(0))
	}
	listener,le:=net.listen_tcp(net.Endpoint{address=net.IP4_Loopback,port=0})
	if !testing.expect(t,le==nil) do return
	defer net.close(listener)
	bound,be:=net.bound_endpoint(listener)
	if !testing.expect(t,be==nil) do return
	peer,de:=net.dial_tcp(net.Endpoint{address=net.IP4_Loopback,port=bound.port})
	if !testing.expect(t,de==nil) do return
	defer net.close(peer)
	hub,_,ae:=net.accept_tcp(listener)
	if !testing.expect(t,ae==nil) do return
	defer net.close(hub)
	bus:events.User_Event_Bus
	handle,attach:=events.user_ws_attach(&bus,"alice",hub)
	if !testing.expect(t,attach==.Attached) do return
	defer events.user_ws_detach(&bus,handle)
	reader:=ws.reader_make();defer ws.reader_destroy(&reader)
	_,ready,got:=ws.read_frame(peer,&reader,time.Second)
	testing.expect(t,got && strings.contains(ready,"user_ws_ready"))
	delete(ready)
	service:=eventinbox.Service{options={url=server.url,timeout_ms=1000}}
	h:=User_Handlers{event_bus=&bus,catalog=&service}
	temp:virtual.Arena
	if virtual.arena_init_growing(&temp)!=nil do return
	defer virtual.arena_destroy(&temp)
	context.temp_allocator=virtual.arena_allocator(&temp)
	state:=User_Catalog_State{cursor=strings.clone("0"),available=true}
	defer user_catalog_destroy(&state)
	sent:=user_ws_catalog_step(&h,handle,"alice",&state,.Attach)
	testing.expect(t,sent)
	_,page,read_page:=ws.read_frame(peer,&reader,time.Second)
	if !testing.expect(t,read_page) do return
	defer delete(page)
	value,je:=json.parse_string(page,parse_integers=true)
	if !testing.expect(t,je==nil) do return
	defer json.destroy_value(value)
	obj:=value.(json.Object)
	list:=obj["events"].(json.Array)
	testing.expect_value(t,len(list),1)
	if len(list)==1 {
		event:=list[0].(json.Object)
		entity:=event["entity"].(json.Object)
		data:=event["data"].(json.Object)
		testing.expect_value(t,entity["kind"].(json.String),json.String("task"))
		testing.expect_value(t,entity["id"].(json.String),json.String("task_1"))
		testing.expect_value(t,data["chain_id"].(json.String),json.String("chain_1"))
	}
	testing.expect_value(t,obj["stream_seq"].(json.Integer),json.Integer(1))
	testing.expect_value(t,obj["catalog_cursor"].(json.String),json.String("2"))
	// Legacy invalidation still uses the very next transport sequence.
	events.publish_raw_to_user(&bus,"alice",`{"type":"resource_changed","resource":"task","resource_id":"task_1","change":"updated"}`)
	_,live,read_live:=ws.read_frame(peer,&reader,time.Second)
	testing.expect(t,read_live && strings.contains(live,`"stream_seq":2`) && strings.contains(live,"resource_changed"))
	delete(live)
	// A new live invalidation is followed only by a watermark, never a replay.
	_,ne=nats.publish(conn,"ev.alice.chain.chain_1.task.task_1.state",transmute([]byte)string(`{"owner_user_id":"alice","entity":{"kind":"task","id":"task_1"},"data":{"chain_id":"chain_1"},"type":"task.state"}`))
	testing.expect_value(t,ne.status,i32(0))
	testing.expect(t,user_ws_catalog_receive(&h,handle,"alice",&state,`{"type":"client_heartbeat","at":1}`))
	_,mark,mark_ok:=ws.read_frame(peer,&reader,time.Second)
	testing.expect(t,mark_ok && strings.contains(mark,"catalog_watermark") && !strings.contains(mark,"task.state"))
	delete(mark)
	before,_,_:=nats.api_stats(conn)
	temp_before:=temp.total_used
	for _ in 0..<100 {
		testing.expect(t,user_ws_catalog_receive(&h,handle,"alice",&state,`{"type":"unknown"}`))
		testing.expect(t,user_ws_catalog_receive(&h,handle,"alice",&state,`{"type":"catalog_next"}`))
		testing.expect(t,user_ws_catalog_receive(&h,handle,"alice",&state,`{"type":"client_heartbeat","at":1}`))
	}
	after,_,_:=nats.api_stats(conn)
	testing.expect(t,after-before<=2,"unknown controls and repeated heartbeats do no queue work")
	testing.expect_value(t,temp.total_used,temp_before)
	testing.expect_value(t,bus.stream_seqs[handle.idx],u64(3))
	prior_conn:=state.connection
	for _ in 0..<201 {
		_,ne=nats.publish(conn,"ev.alice.chain.chain_1.task.task_1.state",transmute([]byte)string(`{"owner_user_id":"alice","entity":{"kind":"task","id":"task_1"},"data":{"chain_id":"chain_1"},"type":"task.state"}`))
		testing.expect_value(t,ne.status,i32(0))
	}
	testing.expect(t,user_ws_catalog_step(&h,handle,"alice",&state,.Attach))
	_,first_page,page_ok:=ws.read_frame(peer,&reader,time.Second)
	testing.expect(t,page_ok && state.has_more)
	delete(first_page)
	// An immediate continuation is rate-limited; a later parsed control drains it.
	seq_before:=bus.stream_seqs[handle.idx]
	testing.expect(t,user_ws_catalog_receive(&h,handle,"alice",&state,`{"type":"catalog_next"}`))
	testing.expect_value(t,bus.stream_seqs[handle.idx],seq_before)
	state.last_page={}
	testing.expect(t,user_ws_catalog_receive(&h,handle,"alice",&state,`{"type":"catalog_next"}`))
	_,last_page,last_ok:=ws.read_frame(peer,&reader,time.Second)
	testing.expect(t,last_ok && !state.has_more)
	delete(last_page)
	testing.expect(t,state.connection==prior_conn,"pages reuse one connection")
	testing.expect_value(t,temp.total_used,temp_before)
	natstest.stop(&server)
	state.last_heartbeat={}
	testing.expect(t,user_ws_catalog_receive(&h,handle,"alice",&state,`{"type":"client_heartbeat","at":2}`))
	_,outage,outage_ok:=ws.read_frame(peer,&reader,time.Second)
	testing.expect(t,outage_ok && strings.contains(outage,"catalog_unavailable"))
	delete(outage)
	outage_seq:=bus.stream_seqs[handle.idx]
	for _ in 0..<5 {
		state.last_heartbeat={}
		state.last_connect={}
		testing.expect(t,user_ws_catalog_receive(&h,handle,"alice",&state,`{"type":"client_heartbeat","at":3}`))
	}
	testing.expect_value(t,bus.stream_seqs[handle.idx],outage_seq)
	testing.expect_value(t,temp.total_used,temp_before)

}

// Handler responses use request-arena ownership in production. Track both arena
// backing allocations and teardown while keeping the shared fixture outside it.
// The replay/page helpers additionally run with a direct Tracking_Allocator.
tracked_catalog_handler_request :: proc(t:^testing.T, handler:proc(rawptr,Request)->Response, ctx:rawptr, req:Request) -> Response {
	parent:=context.temp_allocator
	parent_allocator:=context.allocator
	track:mem.Tracking_Allocator
	mem.tracking_allocator_init(&track,runtime.heap_allocator())
	defer mem.tracking_allocator_destroy(&track)
	arena:mem.Dynamic_Arena
	allocator:=mem.tracking_allocator(&track)
	mem.dynamic_arena_init(&arena,block_allocator=allocator,array_allocator=allocator)
	context.allocator=mem.dynamic_arena_allocator(&arena)
	context.temp_allocator=context.allocator
	request:=req
	request.body=strings.clone(req.body)
	response:=handler(ctx,request)
	result:=Response{status=response.status,body=strings.clone(response.body,parent)}
	context.allocator=parent_allocator
	context.temp_allocator=parent
	mem.dynamic_arena_destroy(&arena)
	testing.expect_value(t,len(track.allocation_map),0)
	return result
}
