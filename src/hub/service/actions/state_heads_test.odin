package actions

import "core:testing"
import domain "odin_test:hub/domain"
import sqlite "odin_test:hub/repository/sqlite"
import iface "odin_test:hub/repository/iface"

@(test)
test_delayed_state_without_head_is_superseded :: proc(t: ^testing.T) {
	action_test_case(t, state_head_missing_scenario)
}
state_head_missing_scenario :: proc(t: ^testing.T, f: ^Action_Test) {
	settle_test_setup(t, f, 5)
	settle_test_event(t, f, "chain1", "missing", 1)
	pending, found, _ := f.repos.actions.run_settle_pending(f.repos.actions.ctx, "trigger", "chain:chain1")
	if !testing.expect(t, found) do return
	uow, began, _ := iface.unit_of_work_begin(&f.factory)
	testing.expect(t, began)
	testing.expect(t, sqlite.exec(&f.db, "DELETE FROM event_state_heads;"))
	_, _ = iface.unit_of_work_commit(&uow)
	f.now_ms+=5000
	drain_run(&f.runtime.router, pending.run_id, false)
	row, _, _ := f.repos.actions.run_get(f.repos.actions.ctx, pending.run_id)
	testing.expect(t, row.state==domain.ACTION_RUN_SKIPPED && row.reason=="superseded")
	testing.expect_value(t, f.routes, 0)
	testing.expect_value(t, f.settle_plans, 0)
}

// A pre-v2 pending run must be rejected, rather than interpreted as an occurrence.
@(test)
test_delayed_pre_v2_state_is_superseded_before_planning :: proc(t: ^testing.T) {
	action_test_case(t, state_head_pre_v2_scenario)
}
state_head_pre_v2_scenario :: proc(t: ^testing.T, f: ^Action_Test) {
	settle_test_setup(t, f, 5)
	settle_test_event(t, f, "chain1", "old", 1)
	pending, found, _ := f.repos.actions.run_settle_pending(f.repos.actions.ctx, "trigger", "chain:chain1")
	if !testing.expect(t, found) do return
	uow, began, _ := iface.unit_of_work_begin(&f.factory)
	if !testing.expect(t, began) do return
	// Keep the real trigger revision while restoring the old stored shape/key.
	testing.expect(t, sqlite.exec(&f.db, `UPDATE action_runs SET event_params=json_set(json_remove(event_params,'$.entity','$.class'),'$.chain_id','chain1'),settle_key='chain1' WHERE event_id='old';`))
	old, exists, _ := f.repos.actions.run_get(f.repos.actions.ctx, pending.run_id)
	testing.expect(t, exists)
	testing.expect_value(t, old.settle_key, "chain1")
	params := test_config(old.event_params_json)
	_, has_class := params["class"]
	_, has_entity := params["entity"]
	testing.expect(t, !has_class && !has_entity)
	testing.expect(t, sqlite.exec(&f.db, "DELETE FROM event_state_heads;"))
	_, _ = iface.unit_of_work_commit(&uow)
	f.now_ms += 5000
	drain_run(&f.runtime.router, pending.run_id, false)
	row, _, _ := f.repos.actions.run_get(f.repos.actions.ctx, pending.run_id)
	testing.expect_value(t, row.state, domain.ACTION_RUN_SKIPPED)
	testing.expect_value(t, row.reason, "superseded")
	testing.expect_value(t, f.routes, 0)
	testing.expect_value(t, f.settle_plans, 0)
}
