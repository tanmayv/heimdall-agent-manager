package http

import "core:encoding/json"
import "core:mem"
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
  payload:=`{"event_id":"evt_missed","type":"task.state","owner_user_id":"alice","chain_id":"chain_1","task_id":"task_1"}`
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
 cursor,sent:=user_ws_catalog_page(&h,handle,"alice","0")
 defer delete(cursor)
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
 testing.expect_value(t,obj["stream_seq"].(json.Integer),json.Integer(1))
 testing.expect_value(t,obj["catalog_cursor"].(json.String),json.String("2"))
 // Legacy invalidation still uses the very next transport sequence.
 events.publish_raw_to_user(&bus,"alice",`{"type":"resource_changed","resource":"task","resource_id":"task_1","change":"updated"}`)
 _,live,read_live:=ws.read_frame(peer,&reader,time.Second)
 testing.expect(t,read_live && strings.contains(live,`"stream_seq":2`) && strings.contains(live,"resource_changed"))
 delete(live)
}
