package delivery
import "core:testing"
import nats "odin_test:lib/nats"
@(test)
test_delivery_setup_failure_is_observable :: proc(t:^testing.T) {
 s:Service
 advisory:^nats.Pull
 for _ in 0..<10 {testing.expect(t,!supervisor_connect(&s,&advisory))}
 testing.expect_value(t,s.diagnostics.stages[.Connect].failures,u64(10))
 testing.expect_value(t,s.diagnostics.stages[.Connect].suppressed,u64(9))
 testing.expect(t,s.conn==nil && advisory==nil)
}
