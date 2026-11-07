#+build !windows
package main

import "core:os"
import "core:fmt"
import "core:strings"
import "core:testing"

// A legacy local token and unsigned wake are not physical launch authority.
// The signed native lifecycle/restart proof lives in executor_local_native_test.
@(test)
startup_wake_unsigned_legacy_token_cannot_confirm_or_replace_child :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    st:=p1c_test_setup(t);defer p1c_test_teardown(st)
    prior:=bridge_config.daemon_id
    bridge_config.daemon_id="unsigned_unpaired_native_wake"
    defer {bridge_config.daemon_id=prior}
    id:="unsigned_wake_instance"
    token:=bridge_agent_token_issue(id,"legacy-transport-only",.Agent,4)
    path:=fmt.tprintf("%s/previous-bootstrap",st.dir)
    testing.expect(t,os.write_entire_file(path,"keep")==nil)
    for count in ([3]int{4,3,5}) {
        command:=bridge_wake_launch_command_json("unsigned",id,"task","worker","claude","seed","agent","name","chain","title","coordinator","","",run_count=count)
        ok,_,_:=bridge_runtime_launch_agent("unsigned",command,purpose="warm")
        testing.expect(t,!ok,"an unsigned wake cannot claim readiness or launch")
        record,valid:=bridge_agent_token_verify(token.plaintext_token)
        testing.expect(t,valid && record.run_count==4,"pending/rejected wake preserves the current credential")
        testing.expect_value(t,bridge_agent_instance_run_count(id),4)
        data,err:=os.read_entire_file(path,context.temp_allocator)
        testing.expect(t,err==nil && string(data)=="keep")
    }
}

@(test)
startup_wake_forwards_exact_hub_credential_without_making_launch_authority :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    command:=bridge_wake_launch_command_json("wake","instance","task","worker","claude","seed","agent","name","chain","title","coordinator","","",
        run_count=5,instance_token="retained-transport-credential",launch_epoch="epoch")
    testing.expect_value(t,extract_json_string(command,"instance_token",""),"retained-transport-credential")
    testing.expect_value(t,extract_json_string(command,"launch_epoch",""),"epoch")
    run,_:=bridge_provider_json_extract_int(command,"run_count")
    testing.expect_value(t,run,5)
    testing.expect(t,!strings.contains(command,"signature"),"Hub routing never manufactures device consent")
}
