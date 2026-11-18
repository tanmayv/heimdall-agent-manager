package agent

import "core:encoding/json"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"

@(test)
test_runtime_transport_launch_and_wake_payloads_use_frozen_snapshot :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 defer free_all(context.temp_allocator)
 inst:=domain.Agent_Instance{agent_instance_id="inst_transport",provider="claude",provider_profile="work",model="opus",runtime_transport="acp",launch_epoch="epoch"}
 launch:=launch_command_json("cmd",inst)
 value,err:=json.parse(launch)
 testing.expect(t,err==nil,"launch JSON must remain valid after transport fields")
 if err==nil do json.destroy_value(value)
 testing.expect(t,strings.contains(launch,`"effective_transport":"acp"`))
 testing.expect(t,strings.contains(launch,`"provider_profile":"work"`))
 testing.expect(t,strings.contains(launch,`"launch_epoch":"epoch"`))
 testing.expect(t,strings.contains(launch,`"catalog_etag":""`))
 wake:=wake_agent_command_json("cmd","chain",[]Wake_Agent_Run_Entry{{agent_instance_id=inst.agent_instance_id,effective_transport=inst.runtime_transport,launch_epoch=inst.launch_epoch,catalog_etag="sha256:catalog"}},nil)
 value,err=json.parse(wake)
 testing.expect(t,err==nil)
 if err==nil do json.destroy_value(value)
 testing.expect(t,strings.contains(wake,`"effective_transport":"acp"`))
 testing.expect(t,strings.contains(wake,`"catalog_etag":"sha256:catalog"`))
 inst.runtime_transport=""
 launch=launch_command_json("cmd",inst)
 testing.expect(t,strings.contains(launch,`"effective_transport":"pty"`))
}

@(test)
test_runtime_transport_epochs_preserve_legacy_pty_behavior :: proc(t: ^testing.T) {
	testing.expect_value(t, runtime_launch_epoch(nil, "pty"), "")
	testing.expect_value(t, runtime_launch_epoch(nil, "pty", "reconfiguration_epoch"), "reconfiguration_epoch")
	ids := platform.real_id_generator()
	service := Agent_Service{ids=&ids}
	epoch := runtime_launch_epoch(&service, "acp", "old_epoch")
	testing.expect(t, strings.has_prefix(epoch, "launch_") && epoch != "old_epoch")
}
