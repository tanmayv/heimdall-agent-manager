package main

import "core:strings"
import "core:testing"

// `ham-ctl task-chain set-title` is served by the owner Bridge for owner
// chains (owner chain.edit; the gate and title state are tested in
// lib/owner_local title_nudge_test.odin), and activity on a Bridge with no
// owner store never delivers or creates anything.
@(test)
test_owner_title_set_title_route_and_activity_without_store :: proc(t:^testing.T) {
    testing.expect(t,bridge_owner_routable("agent.task_chain.set_title"),"set-title on an owner chain is served by the owner Bridge")
    testing.expect(t,bridge_agent_method_allowed("agent.task_chain.set_title"))
    testing.expect(t,strings.has_prefix(bridge_owner_title_nudge_notice(),"Nudge: Please set a short, human-meaningful title for this task chain: ham-ctl task-chain set-title"))

    saved_effect,saved_sync:=bridge_owner_title_nudge_deliver_effect,bridge_owner_title_nudge_sync
    defer { bridge_owner_title_nudge_deliver_effect=saved_effect;bridge_owner_title_nudge_sync=saved_sync }
    @(static) deliveries:int
    deliveries=0
    bridge_owner_title_nudge_sync=true
    bridge_owner_title_nudge_deliver_effect=proc(instance,notice:string) -> bool { deliveries+=1;return true }
    testing.expect(t,!bridge_owner_title_activity_run("inst_no_owner_store"),"no owner chain, no nudge")
    bridge_owner_title_activity("")
    bridge_owner_title_activity("inst_no_owner_store")
    testing.expect_value(t,deliveries,0)
}
