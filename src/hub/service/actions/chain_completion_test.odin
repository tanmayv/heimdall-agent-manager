package actions

import "core:testing"
import "core:encoding/json"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import taskv2 "odin_test:hub/service/taskv2"
import jsonx "odin_test:lib/jsonx"

// Exercise the real completion producer and delayed matcher/router against the
// same SQLite store. State validity follows the producer head, not timestamps.
@(test)
test_settle_real_chain_completion :: proc(t: ^testing.T) {
 action_test_case(t, settle_real_completion_scenario)
}
settle_real_completion_scenario :: proc(t: ^testing.T, f: ^Action_Test) {
 settle_real_producer_scenario(t, f, false, false)
}
@(test)
test_settle_real_chain_completion_reopened :: proc(t: ^testing.T) {
 action_test_case(t, settle_real_completion_reopened_scenario)
}
settle_real_completion_reopened_scenario :: proc(t: ^testing.T, f: ^Action_Test) {
 settle_real_producer_scenario(t, f, false, true)
}
@(test)
test_settle_real_work_finished :: proc(t: ^testing.T) {
 action_test_case(t, settle_real_work_finished_scenario)
}
settle_real_work_finished_scenario :: proc(t: ^testing.T, f: ^Action_Test) {
 settle_real_producer_scenario(t, f, true, false)
}
@(test)
test_settle_real_work_finished_new_work :: proc(t: ^testing.T) {
 action_test_case(t, settle_real_work_finished_new_work_scenario)
}
settle_real_work_finished_new_work_scenario :: proc(t: ^testing.T, f: ^Action_Test) {
 settle_real_producer_scenario(t, f, true, true)
}
settle_real_producer_scenario :: proc(t: ^testing.T, f: ^Action_Test, work, superseded: bool, touch := false, cycle := false) {
 impl: sqlite.Taskchain_Repo_SQLite
 f.repos.taskchains = sqlite.new_taskchain_repository(&impl, &f.db)
 f.repos.taskchains.catalog = f.repos.event_outbox
 repo := &f.repos.taskchains
 chain, saved, err := iface.taskchain_save_chain(repo, {
  chain_id="chain1", owner_user_id="owner", title="Completion",
  status=.Active, publish_state=.Published, kind=domain.CHAIN_KIND_MIXED_WORK, defaults_json="{}",
  created_at="2026-01-01T00:00:00Z", updated_at="2026-01-01T00:00:00Z",
 })
 if !testing.expect(t, saved, err.message) do return
 task, saved_task, task_err := iface.taskchain_save_task(repo, {
  task_id="done", chain_id=chain.chain_id, owner_user_id="owner",
  title="Done", state=.Ready if work else .Done, publish_state=.Published, brief_json="{}",
 })
 if !testing.expect(t, saved_task, task_err.message) do return
 chain, _, _ = iface.taskchain_get_chain(repo, chain.chain_id)
 trigger, _, _ := f.repos.actions.trigger_get(f.repos.actions.ctx, "trigger")
 trigger.delay_s = 10
 typ := "chain.work_finished" if work else "chain.state"
 trigger.event_type = typ
 trigger.subject_filter = "ev.owner.chain.*.work_finished" if work else "ev.owner.chain.*.state"
 trigger.data_filter_json = `{"all":[{"field":"data.outcome","op":"eq","value":"work_batch_finished"}]}` if work else `{"all":[{"field":"data.state","op":"eq","value":"completed"}]}`
 testing.expect_value(t, f.repos.actions.trigger_save(f.repos.actions.ctx, trigger).code, domain.Error_Code.None)
 svc := taskv2.Service{repo=repo, uow_factory=&f.factory, clock=&f.clock, ids=&f.ids}
 if work {
  // record_event is the production terminal-transition path: it invokes
  // catalog_work_finished when the last task in the batch becomes terminal.
  u, began, berr := taskv2.begin_uow(&svc)
  if !testing.expect(t, began, berr.message) do return
  _, _, recorded, rerr := taskv2.record_event(&svc, &u, task,
   {kind=taskv2.ACTOR_USER, id="owner"}, taskv2.EV_CANCELLED, "{}")
  committed, cerr := taskv2.end_uow(&svc, &u, recorded)
  if !testing.expect(t, recorded, rerr.message) do return
  if !testing.expect(t, committed, cerr.message) do return
 } else {
  completed, ok, cerr := taskv2.work_chain_complete(&svc, "owner",
   {kind=taskv2.ACTOR_USER, id="owner"}, chain.chain_id, chain.work_revision, "All work passed")
  if !testing.expect(t, ok, cerr.message) do return
  testing.expect(t, completed.completed_at!="")
 }
 stored, found, serr := iface.taskchain_get_chain(repo, chain.chain_id)
 testing.expect(t, found && serr.code==.None)
 uow, began, _ := iface.unit_of_work_begin(&f.factory)
 if !testing.expect(t, began) do return
 // The terminal path also emits task.state; consume actual outbox rows until
 // the requested chain producer event, without synthesizing its data.
 row: domain.Event_Outbox_Row
 exists: bool
 for {
  var_err: domain.Domain_Error
  row, exists, var_err = uow.repos.event_outbox.next(uow.repos.event_outbox.ctx)
  if !exists || var_err.code!=.None { exists=false; break }
  if jsonx.extract_string(row.envelope_json, "type", "", true, context.temp_allocator)==typ do break
  testing.expect_value(t, uow.repos.event_outbox.mark_published(uow.repos.event_outbox.ctx, row.outbox_seq, "2026-11-23T00:00:00Z").code, domain.Error_Code.None)
 }
 _, _ = iface.unit_of_work_commit(&uow)
 if !testing.expect(t, exists, "real producer emitted expected chain event") do return
 data, _ := jsonx.extract_raw_object(row.envelope_json, "data", true, context.temp_allocator)
 if work {
  envelope := test_config(row.envelope_json)
  fields, _ := envelope["data"].(json.Object)
  revision, numeric := fields["work_revision"].(json.Integer)
  testing.expect(t, numeric, "producer revision remains a JSON integer")
  testing.expect_value(t, i64(revision), stored.work_revision)
  // The matcher stringifies scalar data in run snapshots. Exercise numeric
  // acceptance separately with the unchanged producer envelope as well.
  valid, reason := chain_work_finished_still_valid(&f.repos,
   {owner_user_id="owner", event_params_json=row.envelope_json})
  testing.expect(t, valid && reason=="", "real numeric producer revision is current")
 } else {
  testing.expect_value(t, jsonx.extract_string(data, "completed_at", "", true, context.temp_allocator), stored.completed_at)
  testing.expect_value(t, jsonx.extract_string(data, "updated_at", "", true, context.temp_allocator), stored.updated_at)
 }
 testing.expect(t, handle_message(&f.runtime, {
  subject=row.subject, owner="owner", event_type=typ,
  event_id=jsonx.extract_string(row.envelope_json, "event_id", "", true, context.temp_allocator),
  stream_time_ms=f.now_ms, stream_sequence=1, envelope=test_config(row.envelope_json),
 }))
 pending, pending_found, _ := f.repos.actions.run_settle_pending(f.repos.actions.ctx, "trigger", "chain:chain1")
 if !testing.expect(t, pending_found) do return
 drain_run(&f.runtime.router, pending.run_id, true)
 testing.expect_value(t, f.routes, 0)
 if touch {
  before := stored
  stored.updated_at="2026-11-24T12:00:00Z"
  _, saved, err := iface.taskchain_save_chain(repo,stored)
  testing.expect(t,saved,err.message)
  u, began, _ := iface.unit_of_work_begin(&f.factory)
  testing.expect(t,began)
  testing.expect_value(t,taskv2.catalog_chain_state(repo,&f.clock,before,stored).code,domain.Error_Code.None)
  _, _ = iface.unit_of_work_commit(&u)
 }
 if cycle {
  before := stored
  stored.status=.Active
  stored.completed_at=""
  _, saved, err := iface.taskchain_save_chain(repo,stored)
  testing.expect(t,saved,err.message)
  u, began, _ := iface.unit_of_work_begin(&f.factory)
  testing.expect(t,began)
  testing.expect_value(t,taskv2.catalog_chain_state(repo,&f.clock,before,stored).code,domain.Error_Code.None)
  _, _ = iface.unit_of_work_commit(&u)
  stored, _, _ = iface.taskchain_get_chain(repo,chain.chain_id)
  _, completed, cerr := taskv2.work_chain_complete(&svc,"owner",{kind=taskv2.ACTOR_USER,id="owner"},chain.chain_id,stored.work_revision,"Complete again")
  testing.expect(t,completed,cerr.message)
  u, began, _ = iface.unit_of_work_begin(&f.factory)
  testing.expect(t,began)
  latest: domain.Event_Outbox_Row
  for {
   next, exists, err := u.repos.event_outbox.next(u.repos.event_outbox.ctx)
   testing.expect_value(t,err.code,domain.Error_Code.None)
   if !exists do break
   if jsonx.extract_string(next.envelope_json,"type","",true,context.temp_allocator)=="chain.state" do latest=next
   testing.expect_value(t,u.repos.event_outbox.mark_published(u.repos.event_outbox.ctx,next.outbox_seq,"now").code,domain.Error_Code.None)
  }
  _, _ = iface.unit_of_work_commit(&u)
  testing.expect(t,latest.event_id!=row.event_id)
  testing.expect(t,handle_message(&f.runtime,{subject=latest.subject,owner="owner",event_type="chain.state",event_id=latest.event_id,stream_time_ms=f.now_ms,stream_sequence=2,envelope=test_config(latest.envelope_json)}))
  replaced,found,_ := f.repos.actions.run_settle_pending(f.repos.actions.ctx,"trigger","chain:chain1")
  testing.expect(t,found && replaced.run_id==pending.run_id && replaced.event_id==latest.event_id)
 }
 if superseded {
  if work {
   // Inserting new work advances the revision via the real SQLite trigger.
   _, inserted, ierr := iface.taskchain_save_task(repo, {
    task_id="new", chain_id=chain.chain_id, owner_user_id="owner",
    title="New work", state=.Ready, publish_state=.Published, brief_json="{}",
   })
   testing.expect(t, inserted, ierr.message)
   valid, reason := chain_work_finished_still_valid(&f.repos,
    {owner_user_id="owner", event_params_json=row.envelope_json})
   testing.expect(t, !valid && reason=="superseded", "new work supersedes numeric snapshot")
  } else {
   // Persist a reopened chain before the pending completion action fires.
   before := stored
   stored.status=.Active
   stored.completed_at=""
   _, reopened, rerr := iface.taskchain_save_chain(repo, stored)
   testing.expect(t, reopened, rerr.message)
   u, began, _ := iface.unit_of_work_begin(&f.factory)
   testing.expect(t,began)
   testing.expect_value(t,taskv2.catalog_chain_state(repo,&f.clock,before,stored).code,domain.Error_Code.None)
   _, _ = iface.unit_of_work_commit(&u)
  }
 }
 f.now_ms += 10_000
 drain_run(&f.runtime.router, pending.run_id, true)
 if superseded {
  testing.expect_value(t, f.routes, 0)
  testing.expect_value(t, action_test_prompt_count(t, f), 0)
  rows := action_test_rows(t, f)
  if testing.expect_value(t, len(rows), 1) {
   testing.expect_value(t, rows[0].state, domain.ACTION_RUN_SKIPPED)
   testing.expect_value(t, rows[0].reason, "superseded")
  }
 } else {
  testing.expect_value(t, f.routes, 1)
  testing.expect_value(t, action_test_prompt_count(t, f), 1)
  action_test_expect(t, f, domain.ACTION_RUN_SKIPPED, 0)
 }
}

@(test)
test_settle_real_chain_touch_keeps_head :: proc(t: ^testing.T) {
 action_test_case(t,settle_real_touch_scenario)
}
settle_real_touch_scenario :: proc(t: ^testing.T,f: ^Action_Test) {
 settle_real_producer_scenario(t,f,false,false,touch=true)
}
@(test)
test_settle_real_chain_recompletion_delivers_once :: proc(t: ^testing.T) {
 action_test_case(t,settle_real_cycle_scenario)
}
settle_real_cycle_scenario :: proc(t: ^testing.T,f: ^Action_Test) {
 settle_real_producer_scenario(t,f,false,false,cycle=true)
}
