package eventinbox

import "core:fmt"
import "core:sync"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import eventrelay "odin_test:hub/service/eventrelay"
import nats "odin_test:lib/nats"
import natstest "odin_test:lib/natstest"

@(test)
test_incremental_subscription_cache_queries_and_deadlines :: proc(t: ^testing.T) {
 db, opened, _ := sqlite.open(":memory:")
 if !testing.expect(t,opened) do return
 defer sqlite.close(&db)
 migrated,_ := sqlite.run_migrations(&db)
 if !testing.expect(t,migrated) do return
 impl: sqlite.Event_Subscription_Repo_SQLite
 repo:=sqlite.new_event_subscription_repository(&impl,&db)
 repos:=iface.Repositories{event_subscriptions=repo}
 fi: sqlite.SQLite_Unit_Of_Work_Factory
 factory:=sqlite.new_unit_of_work_factory(&fi,&db,&repos)
 service:=Service{factory=&factory}
 r:=Runtime{service=&service,cache_allocator=context.allocator}
 defer clear_subscription_cache(&r)
 defer clear_notifications(&r)
 defer clear_notice_dirty(&service)
 uow,began,_:=iface.unit_of_work_begin(&factory)
 if !testing.expect(t,began) do return
 defer iface.unit_of_work_rollback(&uow)
 for i in 0..<512 {
  id:=fmt.tprintf("sub_%d",i)
  chain:=fmt.tprintf("chain_%d",i)
  testing.expect_value(t,repo.put(repo.ctx,{subscription_id=id,owner_user_id="alice",
   subscriber_instance_id="inst",chain_id=chain,source="explicit",
   filter_subjects="[]",consumer_name=id,created_at="now"}).code,domain.Error_Code.None)
 }
 now:=time.tick_now()
 before:=impl.queries
 testing.expect(t,refresh_subscription_cache(&r,repo,now))
 testing.expect_value(t,impl.queries-before,u64(3))
 testing.expect_value(t,len(r.subscription_cache),512)
 before=impl.queries
 for _ in 0..<20 do testing.expect(t,refresh_subscription_cache(&r,repo,now))
 testing.expect_value(t,impl.queries-before,u64(20))
 testing.expect_value(t,repo.remove(repo.ctx,"alice","inst","sub_1").code,domain.Error_Code.None)
 before=impl.queries
 testing.expect(t,refresh_subscription_cache(&r,repo,now))
 testing.expect_value(t,impl.queries-before,u64(3))
 testing.expect_value(t,len(r.subscription_cache),511)
 // Slow safety reconciliation discovers a deliberately lost invalidation.
 testing.expect(t,sqlite.exec(&db,"DELETE FROM event_inbox_changes;"))
 testing.expect_value(t,repo.remove(repo.ctx,"alice","inst","sub_2").code,domain.Error_Code.None)
 testing.expect(t,sqlite.exec(&db,"DELETE FROM event_inbox_changes;"))
 now._nsec+=i64(5*time.Minute)
 testing.expect(t,refresh_subscription_cache(&r,repo,now))
 testing.expect_value(t,len(r.subscription_cache),510)
 // Real target snapshots and delivery clocks are scoped to the changed chain.
 testing.expect(t,sqlite.exec(&db,"INSERT INTO agent_instances(agent_instance_id,owner_user_id,agent_id,bridge_id,runtime_status,activity_status,created_at,updated_at) VALUES('inst','alice','agent','bridge','running','idle','now','now');"))
 testing.expect(t,sqlite.exec(&db,"UPDATE agent_instances SET activity_status='busy' WHERE agent_instance_id='inst';"))
 testing.expect(t,refresh_subscription_cache(&r,repo,now))
 snapshot:=r.subscription_cache["alice/chain_3"].snapshots[0]
 testing.expect_value(t,snapshot.target.activity_status,"busy")
 // Make one target eligible and ensure cooldown and ack deadlines are honored.
 testing.expect(t,sqlite.exec(&db,"UPDATE agent_instances SET activity_status='idle' WHERE agent_instance_id='inst';"))
 testing.expect(t,refresh_subscription_cache(&r,repo,now))
 save_notification_state(&r,"schedule:sub_3",{dirty=true})
 save_notification_state(&r,"instance:alice/inst",{last_sent=now})
 testing.expect_value(t,runtime_wait_delay(&r,now),30*time.Second)
 save_notification_state(&r,"instance:alice/inst",{})
 due:=now; due._nsec+=i64(2*time.Second)
 save_notification_state(&r,"schedule:sub_3",{next_check=due})
 testing.expect_value(t,runtime_wait_delay(&r,now),2*time.Second)
}

@(test)
test_event_driven_inbox_idle_has_zero_queries_or_nats_calls :: proc(t: ^testing.T) {
 event_driven_inbox_idle_scenario(t)
 testing.expect_value(t,nats.shutdown(5000).status,i32(0))
}
event_driven_inbox_idle_scenario :: proc(t:^testing.T) {
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
 impl: sqlite.Event_Subscription_Repo_SQLite
 repo:=sqlite.new_event_subscription_repository(&impl,&db)
 repos:=iface.Repositories{event_subscriptions=repo}
 fi: sqlite.SQLite_Unit_Of_Work_Factory
 factory:=sqlite.new_unit_of_work_factory(&fi,&db,&repos)
 service:=Service{factory=&factory,options={url=server.url,timeout_ms=1000},reconcile_interval=10*time.Second}
 defer clear_notice_dirty(&service)
 defer provisioned_destroy(&service)
 sqlite.install_inbox_notifications(&db,&service,proc(ctx:rawptr){wake((^Service)(ctx))})
 r:Runtime
 start(&r,&service)
 defer stop(&r)
 // Wait for initial reconciliation through the synchronized query counter.
 for _ in 0..<100 {
  if sync.atomic_load(&impl.queries)>=4 do break
  time.sleep(20*time.Millisecond)
 }
 time.sleep(100*time.Millisecond)
 before:=sync.atomic_load(&impl.queries)
 api_before,_,_:=nats.api_stats(conn)
 testing.expect(t,before>=4)
 time.sleep(1200*time.Millisecond) // Longer than the removed one-second tick.
 testing.expect_value(t,sync.atomic_load(&impl.queries),before)
 api_after,_,_:=nats.api_stats(conn)
 // The second stats request itself increments the JetStream API counter once.
 testing.expect_value(t,api_after,api_before+1)
 // Unsubscribed catalog traffic does not wake an idle runtime.
 published(&service,"ev.alice.chain.unwatched.state")
 time.sleep(100*time.Millisecond)
 testing.expect_value(t,sync.atomic_load(&impl.queries),before)
 // A committed watch wakes promptly, without waiting for the safety interval.
 uow,began,_:=iface.unit_of_work_begin(&factory)
 if !testing.expect(t,began) do return
 testing.expect(t,sqlite.exec(&db,"INSERT INTO task_chains(chain_id,owner_user_id,title,status,kind,created_at,updated_at) VALUES('chain','alice','test','active','mixed_work','now','now');"))
 testing.expect_value(t,repo.put(repo.ctx,{subscription_id="new_sub",owner_user_id="alice",subscriber_instance_id="inst",
  chain_id="chain",source="explicit",filter_subjects=`["ev.alice.chain.chain.state"]`,consumer_name="new_sub",created_at="now"}).code,domain.Error_Code.None)
 iface.unit_of_work_commit(&uow)
 // put itself is one query; the runtime must do further work after it.
 baseline:=before+1
 for _ in 0..<100 {
  if sync.atomic_load(&impl.queries)>baseline do break
  time.sleep(20*time.Millisecond)
 }
 testing.expect(t,sync.atomic_load(&impl.queries)>baseline,"commit signals runtime")
 time.sleep(100*time.Millisecond)
 baseline=sync.atomic_load(&impl.queries)
 published(&service,"ev.alice.chain.chain.state")
 for _ in 0..<100 {
  if sync.atomic_load(&impl.queries)>baseline do break
  time.sleep(20*time.Millisecond)
 }
 testing.expect(t,sync.atomic_load(&impl.queries)>baseline,"subscribed catalog publication wakes runtime")
 time.sleep(100*time.Millisecond)
 baseline=sync.atomic_load(&impl.queries)
 testing.expect(t,sqlite.exec(&db,"INSERT INTO agent_instances(agent_instance_id,owner_user_id,agent_id,bridge_id,runtime_status,activity_status,created_at,updated_at) VALUES('inst','alice','agent','bridge','running','busy','now','now');"))
 testing.expect(t,sqlite.exec(&db,"UPDATE agent_instances SET activity_status='idle' WHERE agent_instance_id='inst';"))
 for _ in 0..<100 {
  if sync.atomic_load(&impl.queries)>baseline do break
  time.sleep(20*time.Millisecond)
 }
 testing.expect(t,sync.atomic_load(&impl.queries)>baseline,"activity change wakes runtime")
 time.sleep(100*time.Millisecond)
 _,state_err:=nats.consumer_state(conn,"HEIM_EVENTS","new_sub")
 testing.expect_value(t,state_err.status,i32(0))
 testing.expect(t,sqlite.exec(&db,"UPDATE task_chains SET status='archived' WHERE chain_id='chain';"))
 for _ in 0..<100 {
  _,state_err=nats.consumer_state(conn,"HEIM_EVENTS","new_sub")
  if state_err.jetstream==JS_CONSUMER_NOT_FOUND do break
  time.sleep(20*time.Millisecond)
 }
 testing.expect_value(t,state_err.jetstream,JS_CONSUMER_NOT_FOUND)

}

@(test)
test_event_driven_inbox_wait_keeps_signals_and_deadlines :: proc(t:^testing.T) {
 service:Service
 r:=Runtime{service=&service}
 wake(&service)
 started:=time.tick_now()
 wait_for_wake(&r,10*time.Second)
 testing.expect(t,time.tick_since(started)<100*time.Millisecond,"a signal before waiting is retained")
 consume_wake(&service)
 started=time.tick_now()
 wait_for_wake(&r,20*time.Millisecond)
 testing.expect(t,time.tick_since(started)>=20*time.Millisecond,"timer deadline wakes without a signal")
}
