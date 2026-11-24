package actions

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import taskv2 "odin_test:hub/service/taskv2"
import jsonx "odin_test:lib/jsonx"

// Exercise the real completion producer and delayed matcher/router against the
// same SQLite store. Synthetic envelopes would hide missing completion stamps.
@(test)
test_settle_real_chain_completion :: proc(t: ^testing.T) {
 action_test_case(t, settle_real_completion_scenario)
}
settle_real_completion_scenario :: proc(t: ^testing.T, f: ^Action_Test) {
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
 _, saved, err = iface.taskchain_save_task(repo, {
  task_id="done", chain_id=chain.chain_id, owner_user_id="owner",
  title="Done", state=.Done, publish_state=.Published, brief_json="{}",
 })
 if !testing.expect(t, saved, err.message) do return
 chain, _, _ = iface.taskchain_get_chain(repo, chain.chain_id)
 trigger, _, _ := f.repos.actions.trigger_get(f.repos.actions.ctx, "trigger")
 trigger.delay_s = 10
 trigger.data_filter_json = `{"state":"completed"}`
 testing.expect_value(t, f.repos.actions.trigger_save(f.repos.actions.ctx, trigger).code, domain.Error_Code.None)
 svc := taskv2.Service{repo=repo, uow_factory=&f.factory, clock=&f.clock, ids=&f.ids}
 completed, ok, cerr := taskv2.work_chain_complete(&svc, "owner",
  {kind=taskv2.ACTOR_USER, id="owner"}, chain.chain_id, chain.work_revision, "All work passed")
 if !testing.expect(t, ok, cerr.message) do return
 stored, found, serr := iface.taskchain_get_chain(repo, chain.chain_id)
 testing.expect(t, found && serr.code==.None)
 testing.expect(t, stored.completed_at!="")
 testing.expect_value(t, completed.completed_at, stored.completed_at)
 uow, began, _ := iface.unit_of_work_begin(&f.factory)
 if !testing.expect(t, began) do return
 row, exists, rerr := uow.repos.event_outbox.next(uow.repos.event_outbox.ctx)
 _, _ = iface.unit_of_work_commit(&uow)
 if !testing.expect(t, exists && rerr.code==.None) do return
 testing.expect_value(t, jsonx.extract_string(row.envelope_json, "type", "", true, context.temp_allocator), "chain.state")
 data, _ := jsonx.extract_raw_object(row.envelope_json, "data", true, context.temp_allocator)
 testing.expect_value(t, jsonx.extract_string(data, "completed_at", "", true, context.temp_allocator), stored.completed_at)
 testing.expect_value(t, jsonx.extract_string(data, "updated_at", "", true, context.temp_allocator), stored.updated_at)
 testing.expect(t, handle_message(&f.runtime, {
  subject=row.subject, owner="owner", event_type="chain.state",
  event_id=jsonx.extract_string(row.envelope_json, "event_id", "", true, context.temp_allocator),
  stream_time_ms=f.now_ms, stream_sequence=1, envelope=test_config(row.envelope_json),
 }))
 pending, pending_found, _ := f.repos.actions.run_settle_pending(f.repos.actions.ctx, "trigger", "chain1")
 if !testing.expect(t, pending_found) do return
 drain_run(&f.runtime.router, pending.run_id, true)
 testing.expect_value(t, f.routes, 0)
 f.now_ms += 10_000
 drain_run(&f.runtime.router, pending.run_id, true)
 testing.expect_value(t, f.routes, 1)
 testing.expect_value(t, action_test_prompt_count(t, f), 1)
 action_test_expect(t, f, domain.ACTION_RUN_SKIPPED, 0)
}
