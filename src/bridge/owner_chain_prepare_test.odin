package main

import "core:strings"
import "core:testing"

// A prepared chain boots its first launched instance as coordinator (no
// restart), starts exactly one post-live bind for it, keeps that role across
// a relaunch, and never hands it to another instance. A bound coordinator
// wins over the pending slot; clearing the slot restores the Hub role.
@(test)
test_owner_chain_prepare_pending_launch_role :: proc(t:^testing.T) {
    saved_effect,saved_sync:=bridge_owner_pending_bind_effect,bridge_owner_pending_sync_effects
    defer { bridge_owner_pending_bind_effect=saved_effect;bridge_owner_pending_sync_effects=saved_sync }
    @(static) binds:[dynamic]string
    clear(&binds)
    bridge_owner_pending_sync_effects=true
    bridge_owner_pending_bind_effect=proc(chain,instance,agent:string) { append(&binds,strings.concatenate({chain,"|",instance,"|",agent},context.temp_allocator)) }
    defer delete(binds)

    chain:="chain_prepare_role_test"
    bridge_owner_coordinator_cache_set(chain,"")
    defer bridge_owner_pending_clear(chain)
    role,coord:=bridge_owner_launch_role(chain,"inst_first","worker","")
    testing.expect_value(t,role,"worker")
    testing.expect_value(t,coord,"")
    testing.expect_value(t,len(binds),0)

    bridge_owner_pending_set(chain,"agt_coord")
    role,coord=bridge_owner_launch_role(chain,"inst_first","worker","")
    testing.expect_value(t,role,"coordinator")
    testing.expect_value(t,coord,"inst_first")
    testing.expect_value(t,len(binds),1)
    if len(binds)==1 do testing.expect_value(t,binds[0],"chain_prepare_role_test|inst_first|agt_coord")

    role,_=bridge_owner_launch_role(chain,"inst_first","worker","")
    testing.expect_value(t,role,"coordinator")
    testing.expect_value(t,len(binds),1)
    role,coord=bridge_owner_launch_role(chain,"inst_other","worker","")
    testing.expect_value(t,role,"worker")
    testing.expect_value(t,coord,"")

    // Once bound, the store's coordinator decides; the pending slot is ignored.
    bridge_owner_coordinator_cache_set(chain,"inst_first")
    role,coord=bridge_owner_launch_role(chain,"inst_other","worker","")
    testing.expect_value(t,role,"worker")
    testing.expect_value(t,coord,"inst_first")

    bridge_owner_coordinator_cache_set(chain,"")
    bridge_owner_pending_clear(chain)
    role,_=bridge_owner_launch_role(chain,"inst_first","worker","")
    testing.expect_value(t,role,"worker")
    testing.expect_value(t,len(binds),1)
}

@(test)
test_owner_chain_prepare_command_and_refusals :: proc(t:^testing.T) {
    spec,known:=bridge_command_spec("owner_chain_prepare")
    testing.expect(t,known && spec.queued && spec.requires_id && !spec.retry_safe,"queued, needs a command id, never retried blindly")
    _,code,_:=bridge_owner_chain_prepare("bad id/../","Title","")
    testing.expect_value(t,code,"bad_request")
    _,code,_=bridge_owner_chain_prepare("agt_coord","   ","")
    testing.expect_value(t,code,"bad_request")
}
