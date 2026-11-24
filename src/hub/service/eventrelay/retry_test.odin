package eventrelay
import "core:testing"
import nats "odin_test:lib/nats"
@(test)
test_relay_failures_count_and_throttle :: proc(t:^testing.T) {
 s:Service // Empty URL is invalid before any network or SQL access.
 for _ in 0..<10 {ok,_:=step(&s);testing.expect(t,!ok)}
 testing.expect_value(t,s.diagnostics.stages[.Connect].failures,u64(10))
 testing.expect_value(t,s.diagnostics.stages[.Connect].suppressed,u64(9))
 testing.expect(t,s.connection==nil)
}
@(test)
test_idle_probe_is_slow_and_rechecks :: proc(t:^testing.T) {
 f:Relay_Fixture;defer relay_fixture_destroy(&f)
 if !relay_fixture_init(t,&f) do return
 observer,e:=nats.connect(f.svc.options)
 if !testing.expect(t,e.status==0) do return
 defer nats.destroy(observer)
 before,_,err:=nats.api_stats(observer)
 if !testing.expect(t,err.status==0) do return
 for _ in 0..<10 {ok,progress:=step(&f.svc);testing.expect(t,ok && !progress)}
 after,_,ae:=nats.api_stats(observer)
 testing.expect(t,ae.status==0)
 testing.expect(t,after-before<=2,"idle passes should not issue STREAM.INFO")
 f.svc.last_probe={}
 ok,_:=step(&f.svc)
 testing.expect(t,ok && f.svc.last_probe._nsec!=0,"periodic health probe must still run")
}
