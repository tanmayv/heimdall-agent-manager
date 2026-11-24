package actions
import "core:fmt"
import "core:sync"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import eventrelay "odin_test:hub/service/eventrelay"
import nats "odin_test:lib/nats"
import natstest "odin_test:lib/natstest"

runtime_test_server :: proc(t:^testing.T)->(natstest.Server,^nats.Connection,bool) {
 server,ok:=natstest.start()
 if !testing.expect(t,ok) do return server,nil,false
 conn,err:=nats.connect({url=server.url,timeout_ms=1000})
 if !testing.expect_value(t,err.status,i32(0)) do return server,conn,false
 _,err=nats.stream_add(conn,eventrelay.stream_config())
 return server,conn,testing.expect_value(t,err.status,i32(0))
}
runtime_test_wait :: proc(f:^Action_Test,state:string,timeout:time.Duration=5*time.Second)->bool {
 start:=time.tick_now()
 for time.tick_since(start)<timeout {
  uow,ok,_:=iface.unit_of_work_begin(&f.factory)
  if !ok do return false
  run,found,err:=uow.repos.actions.run_open(uow.repos.actions.ctx,"action")
  iface.unit_of_work_rollback(&uow)
  if found && err.code==.None && run.state==state do return true
  time.sleep(10*time.Millisecond)
 }
 return false
}
runtime_start_scenario :: proc(t:^testing.T,f:^Action_Test) {
 server,conn,ok:=runtime_test_server(t)
 defer natstest.destroy(&server);defer nats.destroy(conn)
 if !ok do return
 testing.expect_value(t,nats.consumer_add(conn,matcher_consumer_config(8)).status,i32(0))
 testing.expect(t,start(&f.runtime,f.runtime.svc,f.runtime.router,{nats_url=server.url,max_deliver=8}))
 defer stop(&f.runtime)
 _,err:=nats.publish(conn,"ev.owner.chain.chain1.state",transmute([]u8)string(`{"event_id":"live","type":"chain.state","entity":{"kind":"chain","id":"chain1"},"owner_user_id":"owner","data":{"state":"completed"}}`))
 testing.expect_value(t,err.status,i32(0))
 testing.expect(t,runtime_test_wait(f,"routed"))
 stop(&f.runtime)
 testing.expect(t,f.runtime.thread==nil && f.runtime.options.nats_url=="")
 testing.expect_value(t,f.routes,1)
}

@(test)
test_matcher_consumer_default_options :: proc(t:^testing.T) {
 defer nats.shutdown(5000)
 server,conn,ok:=runtime_test_server(t)
 defer natstest.destroy(&server);defer nats.destroy(conn)
 if !ok do return
 err:=nats.consumer_add(conn,matcher_consumer_config(0))
 testing.expect_value(t,err.status,i32(0))
 testing.expect_value(t,matcher_consumer_config(0).max_deliver,i64(10))
 testing.expect_value(t,matcher_consumer_config(-1).max_deliver,i64(10))
 testing.expect_value(t,matcher_consumer_config(8).max_deliver,i64(8))
}

@(test)
test_matcher_setup_log_rate_limit :: proc(t:^testing.T) {
 gate:Setup_Log_Gate
 testing.expect(t,setup_log_due(&gate,0))
 testing.expect(t,!setup_log_due(&gate,i64(time.Second)))
 testing.expect(t,!setup_log_due(&gate,i64(30*time.Second)-1))
 testing.expect(t,setup_log_due(&gate,i64(30*time.Second)))
 testing.expect(t,!setup_log_due(&gate,i64(31*time.Second)))
 testing.expect(t,setup_log_due(&gate,i64(60*time.Second)))
}

runtime_default_start_scenario :: proc(t:^testing.T,f:^Action_Test) {
 server,conn,ok:=runtime_test_server(t)
 defer natstest.destroy(&server);defer nats.destroy(conn)
 if !ok do return
 // Exercise production startup: no pre-created consumer and no explicit max_deliver.
 testing.expect(t,start(&f.runtime,f.runtime.svc,f.runtime.router,{nats_url=server.url}))
 defer stop(&f.runtime)
 ready:=false
 at:=time.tick_now()
 for time.tick_since(at)<5*time.Second {
  _,err:=nats.consumer_state(conn,"HEIM_EVENTS","hub_action_matcher")
  if err.status==0 {ready=true;break}
  time.sleep(10*time.Millisecond)
 }
 if !testing.expect(t,ready) do return
 _,err:=nats.publish(conn,"ev.owner.chain.chain1.state",transmute([]u8)string(`{"event_id":"default-start","type":"chain.state","entity":{"kind":"chain","id":"chain1"},"owner_user_id":"owner","data":{"state":"completed"}}`))
 testing.expect_value(t,err.status,i32(0))
 testing.expect(t,runtime_test_wait(f,"routed"))
 stop(&f.runtime)
 testing.expect_value(t,f.routes,1)
}
@(test)
test_runtime_default_options_create_matcher_and_consume :: proc(t:^testing.T) {
 action_test_case(t,runtime_default_start_scenario)
 testing.expect_value(t,nats.shutdown(5000).status,i32(0))
}
runtime_poison_scenario :: proc(t:^testing.T,f:^Action_Test) {
 server,conn,ok:=runtime_test_server(t)
 defer natstest.destroy(&server);defer nats.destroy(conn)
 if !ok do return
 testing.expect_value(t,nats.consumer_add(conn,matcher_consumer_config(8)).status,i32(0))
 testing.expect(t,start(&f.runtime,f.runtime.svc,f.runtime.router,{nats_url=server.url,max_deliver=8}))
 defer stop(&f.runtime)
 _,err:=nats.publish(conn,"ev.owner.chain.chain1.state",transmute([]u8)string("[]"))
 testing.expect_value(t,err.status,i32(0))
 at:=time.tick_now()
 for sync.atomic_load(&f.runtime.terminated)==0 && time.tick_since(at)<5*time.Second do time.sleep(10*time.Millisecond)
 stop(&f.runtime)
 testing.expect_value(t,sync.atomic_load(&f.runtime.terminated),i64(1))
 pull,e:=nats.pull_bind(conn,"HEIM_EVENTS","hub_action_matcher");testing.expect_value(t,e.status,i32(0))
 defer nats.pull_destroy(pull)
 batch,_:=nats.fetch(pull,1,100)
 testing.expect_value(t,nats.batch_count(batch),0);nats.batch_destroy(batch)
 testing.expect_value(t,len(action_test_rows(t,f)),0)
}
runtime_history_scenario :: proc(t:^testing.T,f:^Action_Test) {
 server,conn,ok:=runtime_test_server(t)
 defer natstest.destroy(&server);defer nats.destroy(conn)
 if !ok do return
 _,err:=nats.publish(conn,"ev.owner.chain.chain1.state",transmute([]u8)string(`{"event_id":"old","type":"chain.state","entity":{"kind":"chain","id":"chain1"},"data":{}}`))
 testing.expect_value(t,err.status,i32(0))
 testing.expect_value(t,nats.consumer_add(conn,matcher_consumer_config(8)).status,i32(0))
 pull,e:=nats.pull_bind(conn,"HEIM_EVENTS","hub_action_matcher");testing.expect_value(t,e.status,i32(0))
 defer nats.pull_destroy(pull)
 batch,_:=nats.fetch(pull,1,100)
 testing.expect_value(t,nats.batch_count(batch),0);nats.batch_destroy(batch)
 testing.expect_value(t,len(action_test_rows(t,f)),0)
 _,err=nats.publish(conn,"ev.owner.chain.chain1.state",transmute([]u8)string(`{"event_id":"new","type":"chain.state","entity":{"kind":"chain","id":"chain1"},"data":{}}`))
 testing.expect_value(t,err.status,i32(0))
 batch,e=nats.fetch(pull,1,1000)
 testing.expect_value(t,e.status,i32(0));defer nats.batch_destroy(batch)
 if !testing.expect_value(t,nats.batch_count(batch),1) do return
 view,valid,poison:=runtime_event_view(nats.batch_message(batch,0))
 testing.expect(t,valid && !poison && view.event_id=="new")
 testing.expect(t,handle_message(&f.runtime,view))
 testing.expect_value(t,nats.ack(nats.batch_message(batch,0)).status,i32(0))
 testing.expect_value(t,len(action_test_rows(t,f)),1)
}
runtime_real_matches :: proc(t:^testing.T,f:^Action_Test) {
 server,conn,ok:=runtime_test_server(t)
 defer natstest.destroy(&server);defer nats.destroy(conn)
 if !ok do return
 trigger,_,_:=f.repos.actions.trigger_get(f.repos.actions.ctx,"trigger");trigger.trigger_id="second"
 _=f.repos.actions.trigger_save(f.repos.actions.ctx,trigger)
 action_test_schedule(t,f,`{"mode":"cron","cron_expr":"0 * * * *","timezone":"UTC"}`)
 testing.expect_value(t,nats.consumer_add(conn,matcher_consumer_config(8)).status,i32(0))
 pull,err:=nats.pull_bind(conn,"HEIM_EVENTS","hub_action_matcher");testing.expect_value(t,err.status,i32(0))
 defer nats.pull_destroy(pull)
 _,err=nats.publish(conn,"ev.owner.chain.chain1.state",transmute([]u8)string(`{"event_id":"chain","type":"chain.state","entity":{"kind":"chain","id":"chain1"},"data":{}}`))
 testing.expect_value(t,err.status,i32(0))
 headers:=[1]nats.Header{{"Heim-Trigger-Rev","1"}}
 _,err=nats.publish(conn,"ev.owner.sched.schedule",transmute([]u8)string(`{"event_id":"fire","type":"schedule.fired","data":{}}`),headers=headers[:])
 testing.expect_value(t,err.status,i32(0))
 batch,be:=nats.fetch(pull,2,1000);testing.expect_value(t,be.status,i32(0))
 if !testing.expect_value(t,nats.batch_count(batch),2) {nats.batch_destroy(batch);return}
 for i in 0..<2 {
  message:=nats.batch_message(batch,i)
  view,valid,poison:=runtime_event_view(message);testing.expect(t,valid && !poison)
  testing.expect(t,handle_message(&f.runtime,view))
  // Commit succeeded, but pretend the process died before ack.
  testing.expect(t,handle_message(&f.runtime,view))
  testing.expect_value(t,nats.nak(message).status,i32(0))
 }
 nats.batch_destroy(batch)
 seen:=make(map[string]bool)
 deadline:=time.tick_now()
 for len(seen)<2 && time.tick_since(deadline)<5*time.Second {
  batch,_=nats.fetch(pull,2,500)
  for i in 0..<nats.batch_count(batch) {
   msg:=nats.batch_message(batch,i)
   view,_,_:=runtime_event_view(msg)
   testing.expect(t,handle_message(&f.runtime,view))
   seen[view.event_id]=true
   _=nats.ack(msg)
  }
  nats.batch_destroy(batch)
 }
 testing.expect_value(t,len(seen),2)
 drain_due(&f.runtime.router);action_test_done(t,f)
 action_test_expect(t,f,domain.ACTION_RUN_DELIVERED,1);action_test_expect(t,f,domain.ACTION_RUN_JOINED,2)
 testing.expect_value(t,f.routes,1);testing.expect_value(t,len(action_test_rows(t,f)),3)
}
runtime_reconcile_scenario :: proc(t:^testing.T,f:^Action_Test) {
 server,conn,ok:=runtime_test_server(t)
 defer natstest.destroy(&server);defer nats.destroy(conn)
 if !ok do return
 action_test_schedule(t,f,`{"mode":"interval","interval_s":600}`)
 // The trigger is durable with no definition or pending outbox row (NATS was down).
 relay:eventrelay.Service
 eventrelay.start(&relay,&f.factory,{url=server.url,timeout_ms=1000})
 defer eventrelay.stop(&relay)
 testing.expect(t,start(&f.runtime,f.runtime.svc,f.runtime.router,{nats_url=server.url,max_deliver=8}))
 defer stop(&f.runtime)
 at:=time.tick_now();found:=false
 for time.tick_since(at)<5*time.Second {
  msg,_,err:=nats.stream_next(conn,"HEIM_EVENTS","sched.def.schedule",1)
  if err.status==0 {nats.message_destroy(msg);found=true;break}
  time.sleep(10*time.Millisecond)
 }
 testing.expect(t,found)
}
runtime_deferral_scenario :: proc(t:^testing.T,f:^Action_Test) {
 server,conn,ok:=runtime_test_server(t)
 defer natstest.destroy(&server);defer nats.destroy(conn)
 if !ok do return
 f.now_ms=time.to_unix_nanoseconds(time.now())/1_000_000
 f.now_ms=(f.now_ms/1000)*1000
 action,_,_:=f.repos.actions.get(f.repos.actions.ctx,"action")
 action.min_interval_s=5;_=f.repos.actions.save(f.repos.actions.ctx,action)
 action_test_first(t,f)
 testing.expect(t,sqlite.exec(&f.db,"DELETE FROM event_outbox;"))
 f.now_ms+=1000
 action_test_match(t,f,"second");drain_due(&f.runtime.router)
 action_test_expect(t,f,domain.ACTION_RUN_DEFERRED,1)
 testing.expect_value(t,nats.consumer_add(conn,matcher_consumer_config(8)).status,i32(0))
 uow,began,_:=iface.unit_of_work_begin(&f.factory);assert(began)
 row,found,re:=uow.repos.event_outbox.next(uow.repos.event_outbox.ctx)
 iface.unit_of_work_rollback(&uow)
 testing.expect(t,found && re.code==.None)
 testing.expect(t,start(&f.runtime,f.runtime.svc,f.runtime.router,{nats_url=server.url,max_deliver=8}))
 defer stop(&f.runtime)
 _=publish_test_row(t,conn,row)
 testing.expect(t,runtime_test_wait(f,"routed",10*time.Second))
 stop(&f.runtime)
 testing.expect_value(t,f.routes,2)
}
@(test)
test_runtime_start_stop_clean :: proc(t:^testing.T) {action_test_case(t,runtime_start_scenario);testing.expect_value(t,nats.shutdown(5000).status,i32(0))}
@(test)
test_matcher_terminates_bad_body :: proc(t:^testing.T) {action_test_case(t,runtime_poison_scenario);testing.expect_value(t,nats.shutdown(5000).status,i32(0))}
@(test)
test_c13_first_start_ignores_history :: proc(t:^testing.T) {action_test_case(t,runtime_history_scenario);testing.expect_value(t,nats.shutdown(5000).status,i32(0))}
@(test)
test_matcher_real_server_overlap_and_redelivery :: proc(t:^testing.T) {action_test_case(t,runtime_real_matches);testing.expect_value(t,nats.shutdown(5000).status,i32(0))}
@(test)
test_runtime_reconciles_on_connect :: proc(t:^testing.T) {action_test_case(t,runtime_reconcile_scenario);testing.expect_value(t,nats.shutdown(5000).status,i32(0))}
@(test)
test_deferral_fire_real_server :: proc(t:^testing.T) {action_test_case(t,runtime_deferral_scenario);testing.expect_value(t,nats.shutdown(5000).status,i32(0))}
