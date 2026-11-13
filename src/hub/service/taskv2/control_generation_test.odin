package taskv2

import "core:testing"

@(test)
test_control_generation_uses_scalar_lookup_and_fails_closed :: proc(t:^testing.T) {
 fx,log,ok:=lease_fixture(t,"control_scalar_generation")
 defer lease_fixture_close(fx,log)
 if !ok do return
 chain:=seed_live_chain(t,fx,"chain_control_scalar_generation")
 task:=publish_task(t,fx,chain,"task_control_scalar_generation")
 expected:=task_control_generation(&fx.svc,task)
 if !testing.expect(t,expected>0,"existing task has generation") do return
 // Generation lookup must not materialize payload history or silently fall back.
 saved_history:=fx.repo.list_events_by_task
 fx.repo.list_events_by_task=nil
 testing.expect_value(t,task_control_generation(&fx.svc,task),expected)
 fx.repo.list_events_by_task=saved_history
 fx.repo.latest_event_id=nil
 testing.expect_value(t,task_control_generation(&fx.svc,task),i64(-1))
}
