package eventinbox
import "core:testing"
@(test)
test_inbox_setup_failure_is_observable :: proc(t:^testing.T) {
 s:Service
 r:=Runtime{service=&s}
 for _ in 0..<10 {testing.expect(t,!runtime_connect(&r))}
 testing.expect_value(t,r.diagnostics.stages[.Connect].failures,u64(10))
 testing.expect_value(t,r.diagnostics.stages[.Connect].suppressed,u64(9))
}
