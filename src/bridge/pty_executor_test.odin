package main
import "core:strings"
import "core:testing"
@(test)
pty_executor_exact_control_wire_shape_and_invalid_identity :: proc(t:^testing.T) {
    key:=strings.repeat("a",64);defer delete(key)
    for tag in ([2]u8{PTY_HOST_T_EXECUTOR_CLOSE,PTY_HOST_T_EXECUTOR_LAUNCH}) {
        frame:=pty_host_encode_executor_control(tag,"inst",key);defer delete(frame)
        payload:=pty_host_test_reframe(t,frame)
        testing.expect_value(t,payload[0],tag)
        offset:=1
        instance,ok:=pty_host_get_str(payload,&offset);defer delete(instance);testing.expect(t,ok && instance=="inst")
        got,read:=pty_host_get_str(payload,&offset);defer delete(got);testing.expect(t,read && got==key)
        testing.expect_value(t,offset,len(payload))
    }
    for invalid in ([3]string{"","path/inst"," bad"}) {
        frame:=pty_host_encode_executor_control(PTY_HOST_T_EXECUTOR_CLOSE,invalid,key)
        testing.expect_value(t,len(frame),0);delete(frame)
    }
    frame:=pty_host_encode_executor_control(PTY_HOST_T_EXECUTOR_CLOSE,"inst","not_a_key")
    testing.expect_value(t,len(frame),0);delete(frame)
}
