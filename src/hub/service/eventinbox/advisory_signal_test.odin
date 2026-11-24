package eventinbox

import "core:fmt"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import eventrelay "odin_test:hub/service/eventrelay"
import nats "odin_test:lib/nats"
import natstest "odin_test:lib/natstest"

@(test)
test_advisory_arrival_wakes_idle_runtime_and_drains_backlog :: proc(t:^testing.T) {
 advisory_arrival_scenario(t)
 testing.expect_value(t,nats.shutdown(5000).status,i32(0))
}

@(test)
test_advisory_existing_backlog_continues_without_new_hints :: proc(t:^testing.T) {
 advisory_arrival_scenario(t,true)
 testing.expect_value(t,nats.shutdown(5000).status,i32(0))
}
advisory_arrival_scenario :: proc(t:^testing.T,queued:bool=false) {
 server,started:=natstest.start()
 if !testing.expect(t,started) do return
 defer natstest.destroy(&server)
 conn,ne:=nats.connect({url=server.url,timeout_ms=1000})
 if !testing.expect_value(t,ne.status,i32(0)) do return
 defer nats.destroy(conn)
 _,ne=nats.stream_add(conn,eventrelay.stream_config())
 if !testing.expect_value(t,ne.status,i32(0)) do return
 db,opened,_:=sqlite.open(":memory:")
 if !testing.expect(t,opened) do return
 defer sqlite.close(&db)
 migrated,_:=sqlite.run_migrations(&db)
 if !testing.expect(t,migrated) do return
 impl:sqlite.Event_Subscription_Repo_SQLite
 repo:=sqlite.new_event_subscription_repository(&impl,&db)
 repos:=iface.Repositories{event_subscriptions=repo}
 fi:sqlite.SQLite_Unit_Of_Work_Factory
 factory:=sqlite.new_unit_of_work_factory(&fi,&db,&repos)
 service:=Service{factory=&factory,options={url=server.url,timeout_ms=1000},
  ack_wait=50*time.Millisecond,max_deliver=1,reconcile_interval=10*time.Minute,
  notice=notification_record_dispatch}
 defer clear_notice_dirty(&service)
 defer counters_destroy(&service)
 defer provisioned_destroy(&service)
 testing.expect(t,sqlite.exec(&db,"INSERT INTO agent_instances(agent_instance_id,owner_user_id,agent_id,bridge_id,runtime_status,activity_status,created_at,updated_at) VALUES('busy','alice','agent','bridge','running','busy','now','now');"))
 uow,began,_:=iface.unit_of_work_begin(&factory)
 if !testing.expect(t,began) do return
 testing.expect_value(t,repo.put(repo.ctx,{subscription_id="advisory_sub",owner_user_id="alice",subscriber_instance_id="busy",
 chain_id="advisory",source="explicit",filter_subjects=`["ev.alice.chain.advisory.task.item.state"]`,consumer_name="advisory_sub",created_at="now"}).code,domain.Error_Code.None)
 iface.unit_of_work_commit(&uow)
 r:Runtime
 if queued {
  testing.expect(t,prepare_advisories(conn))
  testing.expect(t,ensure_consumer(&service,conn,{consumer_name="advisory_sub",filter_subjects=`["ev.alice.chain.advisory.task.item.state"]`,created_at="now"}))
 } else {start(&r,&service)}
 defer stop(&r)
 // Wait for the real consumer, keeping the busy target ineligible for notices.
 for _ in 0..<100 {
  _,ne=nats.consumer_state(conn,"HEIM_EVENTS","advisory_sub")
  if ne.status==0 do break
  time.sleep(10*time.Millisecond)
 }
 if !testing.expect_value(t,ne.status,i32(0)) do return
 time.sleep(100*time.Millisecond)
 pull,pe:=nats.pull_bind(conn,"HEIM_EVENTS","advisory_sub")
 if !testing.expect_value(t,pe.status,i32(0)) do return
 defer nats.pull_destroy(pull)
 for i in 0..<45 {
  _,ne=nats.publish(conn,"ev.alice.chain.advisory.task.item.state",
   transmute([]byte)fmt.tprintf("{\"event_id\":\"event_%d\"}",i),fmt.tprintf("event_%d",i),nil)
  testing.expect_value(t,ne.status,i32(0))
 }
 batch,be:=nats.fetch(pull,45,500)
 if !testing.expect_value(t,be.status,i32(0)) do return
 testing.expect_value(t,nats.batch_count(batch),45)
 nats.batch_destroy(batch) // Deliberately leave all 45 deliveries unacknowledged.
 time.sleep(75*time.Millisecond)
 began_at:=time.tick_now()
 batch,be=nats.fetch(pull,45,50) // Force the server's max-delivery check.
 nats.batch_destroy(batch)
 testing.expect(t,be.status==0 || be.status==NATS_TIMEOUT)
 if queued {
  // All hints predate the runtime subscription: only the initial wake and
  // full-batch continuation can drain these 45 durable advisories.
  time.sleep(100*time.Millisecond)
  start(&r,&service)
 }
 count:u64
 for _ in 0..<100 {
  count,ne=nats.subject_count(conn,"HEIM_EVENTS","ev.dlq.alice.chain.advisory.task.item.state")
  if count==45 do break
  time.sleep(10*time.Millisecond)
 }
 testing.expect_value(t,ne.status,i32(0))
 testing.expect_value(t,count,u64(45))
 testing.expect(t,time.tick_since(began_at)<2*time.Second,"advisory arrival and >20 backlog drain promptly without a safety reconcile")
 stop_at:=time.tick_now()
 stop(&r)
 testing.expect(t,time.tick_since(stop_at)<time.Second,"unsubscribe interrupts the advisory waiter before destruction")
}
