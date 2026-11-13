package taskv2

import "core:testing"
import "core:fmt"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"

@(test)
test_legacy_claim_conversion_restores_free_owner_and_preserves_history :: proc(t:^testing.T) {
 for mode in ([]string{"free","conflict","stopped","held","unassigned","removed","reviewer_only","paused","named_no_fleet"}) {
  fx,log,ok:=lease_fixture(t,fmt.tprintf("legacy_conversion_%s",mode))
  if !ok {lease_fixture_close(fx,log);continue}
  chain:=seed_live_chain(t,fx,fmt.tprintf("chain_conversion_%s",mode))
  seed_fleet(fx,chain,"agt_w")
  seed_instance(fx,chain,"inst_w1","agt_w","br_1","idle")
  brief:=`{"goal":"g","acceptance":["a"],"assignee":"agt_w"}`
  if mode=="unassigned" || mode=="removed" || mode=="reviewer_only" || mode=="paused" do brief=`{"goal":"g","acceptance":["a"]}`
  restored:=mode=="free" || mode=="held" || mode=="unassigned" || mode=="paused" || mode=="named_no_fleet"
  task:=publish_task(t,fx,chain,"task_conversion",brief=brief)
  task.requires_user_approval=true
  _,_,_=iface.taskchain_save_task(&fx.repo,task)
  confirm_holder(fx,"inst_w1")
  _,submitted,serr:=lease_submit(&fx.svc,inst_auth("inst_w1"),Submit_Input{summary="legacy submitted output"})
  if !testing.expect(t,submitted,serr.message) {lease_fixture_close(fx,log);continue}
  task=get_task(fx,"task_conversion")
  old,held:=lease_of(fx,"inst_w1")
  if !testing.expect(t,held,"submitted fixture owns waiting claim") {lease_fixture_close(fx,log);continue}
  _,_=iface.taskchain_delete_lease(&fx.repo,old.lease_id)
  inst,_,_:=iface.agent_get_instance(&fx.agents,"inst_w1")
  inst.current_task_id="";inst.current_task_role=.None
  if mode=="stopped" {inst.stopped_by="user";inst.runtime_status="stopped"}
  _,_,_=iface.agent_save_instance(&fx.agents,inst)
  if mode=="removed" || mode=="named_no_fleet" {
   deleted,derr:=iface.taskchain_delete_fleet(&fx.repo,chain.chain_id,"agt_w","u1")
   testing.expect(t,deleted,derr.message)
  }
  if mode=="reviewer_only" || mode=="paused" {
   fleets,_:=iface.taskchain_list_fleets_by_chain(&fx.repo,chain.chain_id,"u1")
   for fleet in fleets {
    if fleet.agent_id!="agt_w" do continue
    changed:=fleet
    if mode=="reviewer_only" do changed.roles_json=`["reviewer"]`
    if mode=="paused" do changed.paused_roles_json=`["worker"]`
    _,ferr:=iface.taskchain_upsert_fleet(&fx.repo,changed)
    testing.expect_value(t,ferr.code,domain.Error_Code.None)
   }
  }
  if mode=="conflict" {
   other:=old;other.lease_id="claim_other";other.task_id="other_task";other.phase=domain.LEASE_PHASE_ACTIVE
   _,saved,_:=iface.taskchain_save_lease(&fx.repo,other)
   testing.expect(t,saved,"preexisting assignment")
   inst.current_task_id="other_task";inst.current_task_role=.Work
   _,_,_=iface.agent_save_instance(&fx.agents,inst)
  }
  if mode=="held" {
   _,held_ok,herr:=task_hold(&fx.svc,task,actor_from_auth(user_auth()),"intentional pre-cutover hold")
   testing.expect(t,held_ok,herr.message)
  }
  testing.expect(t,sqlite.exec(&fx.conn,fmt.tprintf(`INSERT INTO task_reviews(task_id,chain_id,owner_user_id,attempt_no,role,reviewer_kind,verdict,created_at) VALUES ('task_conversion','chain_conversion_%s','u1',0,'security','agent','request_changes','2026-01-01T00:00:00Z');`,mode)),"seed historical verdict")
  reviews_before:=scalar_text(fx,"SELECT json_group_array(json_object('attempt',attempt_no,'role',role,'verdict',verdict,'created',created_at)) FROM task_reviews WHERE task_id='task_conversion';")
  history_before:=scalar_text(fx,"SELECT json_group_array(json_object('attempt',attempt_no,'holder',holder_instance_id,'outcome',outcome,'ended',ended_at)) FROM task_attempts WHERE task_id='task_conversion';")
  facets_before:=scalar_text(fx,"SELECT json_group_array(json_object('kind',kind,'body',body_json,'writer',writer,'written',written_at)) FROM task_attempt_facets WHERE task_id='task_conversion';")
  // Exercise the real idempotent 203 replay branch, as if its schema committed
  // before its migration ledger insertion. History predates the cutover marker.
  testing.expect(t,sqlite.exec(&fx.conn,"DELETE FROM schema_migrations WHERE version='203_durable_task_claims.sql';"),"clear cutover ledger")
  migrated,merr:=sqlite.run_migrations(&fx.conn)
  if !testing.expect(t,migrated,merr.message) {lease_fixture_close(fx,log);continue}
  events_before:=count_events(fx,"task_conversion",EV_SUBMITTED)
  attempts_before:=scalar_int(fx,"SELECT count(*) FROM task_attempts WHERE task_id='task_conversion';")
  wake_log_reset(log)
  boot(&fx.svc)
  claim,owns:=lease_of(fx,"inst_w1")
  if restored {
   testing.expect(t,owns && claim.task_id==task.task_id && claim.phase==domain.LEASE_PHASE_WAITING,"free legacy worker restored only as waiting owner")
  } else if mode=="conflict" {
   testing.expect(t,owns && claim.task_id=="other_task" && claim.lease_id=="claim_other","existing responsibility never stolen")
  } else if mode=="stopped" {
   testing.expect(t,!owns,"deliberate user stop never reconstructed")
   stopped,_,_:=iface.agent_get_instance(&fx.agents,"inst_w1")
   testing.expect_value(t,stopped.stopped_by,"user")
  }
  if mode=="removed" || mode=="reviewer_only" do testing.expect(t,!owns,"ineligible fleet member is not restored")
  if mode=="held" do testing.expect(t,task_is_held(get_task(fx,"task_conversion")),"deliberate hold retained")
  testing.expect(t,!wake_log_has_run(log,"inst_w1"),"conversion never launches worker")
  testing.expect_value(t,get_task(fx,"task_conversion").state,domain.Task_State.In_Review)
  testing.expect_value(t,count_events(fx,"task_conversion",EV_SUBMITTED),events_before)
  testing.expect_value(t,scalar_int(fx,"SELECT count(*) FROM task_attempts WHERE task_id='task_conversion';"),attempts_before)
  testing.expect_value(t,count_events(fx,"task_conversion",EV_CLAIM_CONVERSION_CHECKED),1)
  testing.expect_value(t,scalar_text(fx,"SELECT json_extract(payload_json,'$.repair_required') FROM task_events WHERE task_id='task_conversion' AND kind='durable_claim_conversion_checked';"),"0" if restored else "1")
  testing.expect_value(t,scalar_text(fx,"SELECT json_group_array(json_object('attempt',attempt_no,'holder',holder_instance_id,'outcome',outcome,'ended',ended_at)) FROM task_attempts WHERE task_id='task_conversion';"),history_before)
  testing.expect_value(t,scalar_text(fx,"SELECT json_group_array(json_object('kind',kind,'body',body_json,'writer',writer,'written',written_at)) FROM task_attempt_facets WHERE task_id='task_conversion';"),facets_before)
  testing.expect_value(t,scalar_text(fx,"SELECT json_group_array(json_object('attempt',attempt_no,'role',role,'verdict',verdict,'created',created_at)) FROM task_reviews WHERE task_id='task_conversion';"),reviews_before)
  if !restored {
   testing.expect(t,strings.contains(scalar_text(fx,"SELECT payload_json FROM task_events WHERE task_id='task_conversion' AND kind='durable_claim_conversion_checked';"),"repair_required"),"conversion diagnostic retained in task events")
  }
  if mode=="free" {
   // An explicit release after conversion must survive every later boot.
   _,_=iface.taskchain_delete_lease(&fx.repo,claim.lease_id)
  }
  boot(&fx.svc)
  testing.expect_value(t,count_events(fx,"task_conversion",EV_CLAIM_CONVERSION_CHECKED),1)
  if mode=="free" {_,again:=lease_of(fx,"inst_w1");testing.expect(t,!again,"later release is not undone")}
  lease_fixture_close(fx,log)
 }
}
