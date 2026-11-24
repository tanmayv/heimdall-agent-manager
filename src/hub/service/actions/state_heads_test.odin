package actions

import "core:testing"
import domain "odin_test:hub/domain"
import sqlite "odin_test:hub/repository/sqlite"
import iface "odin_test:hub/repository/iface"

@(test)
test_delayed_state_without_head_is_superseded :: proc(t: ^testing.T) {
 action_test_case(t,state_head_missing_scenario)
}
state_head_missing_scenario :: proc(t: ^testing.T,f: ^Action_Test) {
 settle_test_setup(t,f,5)
 settle_test_event(t,f,"chain1","missing",1)
 pending,found,_ := f.repos.actions.run_settle_pending(f.repos.actions.ctx,"trigger","chain:chain1")
 if !testing.expect(t,found) do return
 uow,began,_ := iface.unit_of_work_begin(&f.factory)
 testing.expect(t,began)
 testing.expect(t,sqlite.exec(&f.db,"DELETE FROM event_state_heads;"))
 _,_ = iface.unit_of_work_commit(&uow)
 f.now_ms+=5000
 drain_run(&f.runtime.router,pending.run_id,false)
 row,_,_ := f.repos.actions.run_get(f.repos.actions.ctx,pending.run_id)
 testing.expect(t,row.state==domain.ACTION_RUN_SKIPPED && row.reason=="superseded")
 testing.expect_value(t,f.routes,0)
 testing.expect_value(t,f.settle_plans,0)
}
