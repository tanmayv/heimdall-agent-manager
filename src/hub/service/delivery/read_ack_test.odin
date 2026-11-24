package delivery

import "core:fmt"
import "core:mem"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
test_awaiting_read_ignores_retry_offline_replace :: proc(t:^testing.T) {
 track:mem.Tracking_Allocator
 mem.tracking_allocator_init(&track,context.allocator)
 defer mem.tracking_allocator_destroy(&track)
 context.allocator=mem.tracking_allocator(&track)
 {
  f:=fixture_new(t,false);defer fixture_destroy(f)
  id:=fixture_route(t,f,ref="run:awaiting");defer delete(id)
  fixture_set(f,id,domain.DELIVERY_DELIVERED,1,"2000-01-01T00:00:00Z")
  f.replace_enabled=true
  on_bridge_offline(f.s,"brg_one");on_bridge_deleted(f.s,"brg_one");expire_due(f.s)
  on_command_result(f.s,"brg_one",fmt.tprintf("%s:1",id),`{"status":"failed","class":"fatal"}`)
  uow,ok,_:=iface.unit_of_work_begin(&f.factory);assert(ok)
  repo:=&uow.repos.pipeline_deliveries
  d,found,err:=repo.get(repo.ctx,id)
  testing.expect(t,found && err.code==.None)
  testing.expect_value(t,d.state,domain.DELIVERY_DELIVERED)
  testing.expect(t,!domain.pipeline_delivery_open(d.state))
  changed,e:=try_replace(f.s,&uow,d,.Bridge_Offline)
  testing.expect(t,!changed && e.code==.None)
  changed,e=close_delivery(f.s,&uow,d,domain.DELIVERY_FAILED,"no_answer","")
  testing.expect(t,!changed && e.code==.None)
  domain.pipeline_delivery_destroy(&d)
  rows,re:=repo.open_for_bridge(repo.ctx,"brg_one","",100)
  testing.expect(t,re.code==.None && len(rows)==0)
  domain.pipeline_deliveries_destroy(rows)
  _,exists,ref_err:=repo.open_by_ref(repo.ctx,"run:awaiting")
  testing.expect(t,!exists && ref_err.code==.None)
  iface.unit_of_work_rollback(&uow)
  testing.expect_value(t,f.replace_calls,i32(0))
  testing.expect_value(t,f.finals,i32(0))
 }
 testing.expect_value(t,len(track.allocation_map),0)
}

@(test)
test_nonprompt_and_unlinked_prompt_success_unchanged :: proc(t:^testing.T) {
 track:mem.Tracking_Allocator
 mem.tracking_allocator_init(&track,context.allocator)
 defer mem.tracking_allocator_destroy(&track)
 context.allocator=mem.tracking_allocator(&track)
 {
  f:=fixture_new(t,false);defer fixture_destroy(f)
  for kind in ([]string{"notice","lease","bot","prompt"}) {
   uow,ok,_:=iface.unit_of_work_begin(&f.factory);assert(ok)
   id,err:=route(f.s,&uow,{
    kind=kind,owner_user_id="alice",bridge_id="brg_one",agent_instance_id="inst_one",
    lifetime=LIFETIME_PROMPT,
   })
   testing.expect_value(t,err.code,domain.Error_Code.None)
   _,_=iface.unit_of_work_commit(&uow)
   fixture_set(f,id,domain.DELIVERY_FORWARDED)
   on_command_result(f.s,"brg_one",fmt.tprintf("%s:1",id),`{"status":"succeeded","outcome":"notified"}`)
   d:=fixture_get(f,id)
   testing.expect_value(t,d.state,domain.DELIVERY_DONE)
   testing.expect_value(t,d.outcome,"notified")
   domain.pipeline_delivery_destroy(&d)
  }
 }
 testing.expect_value(t,len(track.allocation_map),0)
}
