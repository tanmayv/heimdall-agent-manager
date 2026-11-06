package main

import "core:encoding/json"
import "core:sync"
import "core:testing"
import owner "odin_test:lib/owner_local"

@(test)
test_owner_local_control_notice_rejects_new_child_and_retries_unverified_child :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    sync.mutex_lock(&bridge_local_token_mutex)
    records:=bridge_local_token_records
    bridge_local_token_records=make([dynamic]Bridge_Local_Agent_Token_Record,context.temp_allocator)
    append(&bridge_local_token_records,Bridge_Local_Agent_Token_Record{agent_instance_id="notice_child",role=.Agent,token_hash="new_hash",instance_token="instance~new_epoch",run_count=2})
    sync.mutex_unlock(&bridge_local_token_mutex)
    sync.mutex_lock(&bridge_runtime_mutex)
    instances:=bridge_runtime_instances
    bridge_runtime_instances=make([dynamic]Bridge_Runtime_Instance,context.temp_allocator)
    inst:=Bridge_Runtime_Instance{agent_instance_id="notice_child"}
    inst.startup.launch_key="new_launch"
    append(&bridge_runtime_instances,inst)
    sync.mutex_unlock(&bridge_runtime_mutex)
    defer {
        sync.mutex_lock(&bridge_local_token_mutex);bridge_local_token_records=records;sync.mutex_unlock(&bridge_local_token_mutex)
        sync.mutex_lock(&bridge_runtime_mutex);bridge_runtime_instances=instances;sync.mutex_unlock(&bridge_runtime_mutex)
    }
    expected:=owner.Child{instance="notice_child",epoch="old_epoch",run_count=1,token_generation="old_generation"}
    bytes,_:=json.marshal(expected,allocator=context.temp_allocator)
    // nil Store proves the stale-child branch performs neither storage nor PTY
    // side effects and cannot invalidate the replacement's tokens.
    success,result,_:=bridge_owner_control_notice(nil,owner.Intent_Claim{kind="stop",fence=string(bytes)})
    testing.expect(t,success && result=="obsolete_child")
    testing.expect_value(t,bridge_local_token_records[0].invalidated_at_unix_ms,i64(0))
    sync.mutex_lock(&bridge_runtime_mutex);clear(&bridge_runtime_instances);sync.mutex_unlock(&bridge_runtime_mutex)
    success,result,_=bridge_owner_control_notice(nil,owner.Intent_Claim{kind="stop",fence=string(bytes)})
    testing.expect(t,!success && result=="child_unverified","missing runtime binding does not prove old child absent")
}
