package main

import "base:runtime"
import "core:strings"
import "core:testing"
import owner "odin_test:lib/owner_local"

@(private = "file")
Notice_Delivery :: struct { instance, line: string }

@(private = "file", thread_local)
notice_deliveries: [dynamic]Notice_Delivery
@(private = "file", thread_local)
notice_live: bool

@(private = "file")
notice_capture :: proc(instance, line: string) -> bool {
    if !notice_live do return false
    append(&notice_deliveries,Notice_Delivery{strings.clone(instance,context.temp_allocator),strings.clone(line,context.temp_allocator)})
    return true
}

// One pass: decide, then deliver through the capture. Returns the lines delivered.
@(private = "file")
notice_pass :: proc(st:^Owner_Notice_State,candidates:[]owner.Coordinator_Notice_Candidate,now:i64) -> []Notice_Delivery {
    clear(&notice_deliveries)
    _=bridge_owner_notice_deliver_due(st,bridge_owner_notices_due(st,candidates,now),now)
    return notice_deliveries[:]
}

@(private = "file")
notice_state_destroy :: proc(st:^Owner_Notice_State) {
    for key in st.seen do delete(key,runtime.heap_allocator())
    delete(st.seen)
}

@(test)
test_owner_coordinator_notices_wake_the_coordinator_with_main_wording :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    saved:=bridge_owner_notice_deliver_effect
    defer bridge_owner_notice_deliver_effect=saved
    bridge_owner_notice_deliver_effect=notice_capture
    notice_live=true
    notice_deliveries=make([dynamic]Notice_Delivery,context.temp_allocator)
    st:Owner_Notice_State
    defer notice_state_destroy(&st)
    candidates:=[]owner.Coordinator_Notice_Candidate{
        {chain_id="chain_a",task_id="task_blocked",coordinator="inst_coord",trigger="blocked_on human",title="Pick a port",attempt="1"},
        {chain_id="chain_a",task_id="task_gone",coordinator="inst_coord",trigger="agent_not_running",title="Build",reason="Agent agt_x is not running",attempt="0"},
        {chain_id="chain_a",task_id="task_review",coordinator="inst_coord",trigger="review_requested_from_user",title="Ship it",attempt="2"},
        // No bound coordinator: nobody to tell.
        {chain_id="chain_b",task_id="task_orphan",coordinator="",trigger="blocked_on human",title="Orphan",attempt="1"},
    }
    got:=notice_pass(&st,candidates,1_000)
    if !testing.expect_value(t,len(got),3) do return
    for d in got do testing.expect_value(t,d.instance,"inst_coord")
    testing.expect_value(t,got[0].line,"[taskv2] blocked_on human: task task_blocked (Pick a port) is waiting on human input")
    testing.expect_value(t,got[1].line,"[taskv2] agent_not_running: task task_gone (Build): Agent agt_x is not running")
    testing.expect_value(t,got[2].line,"[taskv2] review_requested_from_user: task task_review (Ship it) is in_review and awaits user approval")
    // Deduplicated: the same conditions say nothing again.
    testing.expect_value(t,len(notice_pass(&st,candidates,2_000)),0)
    testing.expect_value(t,len(notice_pass(&st,candidates,1_000+BRIDGE_OWNER_NOTICE_BLOCKED_REALERT_MS-1)),0)
    // Blocked on human re-alerts once a day (main BLOCKED_REALERT_SECONDS); the others never.
    got=notice_pass(&st,candidates,1_000+BRIDGE_OWNER_NOTICE_BLOCKED_REALERT_MS)
    if testing.expect_value(t,len(got),1) do testing.expect_value(t,got[0].line,"[taskv2] blocked_on human: task task_blocked (Pick a port) still waiting on human input")
    // A new review attempt is a new request.
    next:=candidates[2];next.attempt="3"
    got=notice_pass(&st,[]owner.Coordinator_Notice_Candidate{candidates[0],candidates[1],next},1_000+BRIDGE_OWNER_NOTICE_BLOCKED_REALERT_MS+1)
    if testing.expect_value(t,len(got),1) do testing.expect_value(t,got[0].line,"[taskv2] review_requested_from_user: task task_review (Ship it) is in_review and awaits user approval")
    // A cleared condition is forgotten: blocking again notifies again.
    _=notice_pass(&st,nil,5_000_000_000)
    testing.expect_value(t,len(st.seen),0)
    got=notice_pass(&st,candidates[:1],5_000_000_001)
    if testing.expect_value(t,len(got),1) do testing.expect_value(t,got[0].line,"[taskv2] blocked_on human: task task_blocked (Pick a port) is waiting on human input")
    // A new coordinator is told about what is still outstanding.
    moved:=candidates[0];moved.coordinator="inst_coord_2"
    got=notice_pass(&st,[]owner.Coordinator_Notice_Candidate{moved},5_000_000_002)
    if testing.expect_value(t,len(got),1) do testing.expect_value(t,got[0].instance,"inst_coord_2")
}

@(test)
test_owner_coordinator_notice_waits_for_a_live_coordinator_and_rate_limits_retries :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    saved:=bridge_owner_notice_deliver_effect
    defer bridge_owner_notice_deliver_effect=saved
    bridge_owner_notice_deliver_effect=notice_capture
    notice_deliveries=make([dynamic]Notice_Delivery,context.temp_allocator)
    st:Owner_Notice_State
    defer notice_state_destroy(&st)
    candidates:=[]owner.Coordinator_Notice_Candidate{{chain_id="chain",task_id="task",coordinator="inst_coord",trigger="review_requested_from_user",title="T",attempt="1"}}
    notice_live=false
    due:=bridge_owner_notices_due(&st,candidates,1_000)
    testing.expect_value(t,len(due),1)
    testing.expect_value(t,bridge_owner_notice_deliver_due(&st,due,1_000),0)
    // Not delivered: retried, but not before BRIDGE_OWNER_NOTICE_RETRY_MS.
    testing.expect_value(t,len(bridge_owner_notices_due(&st,candidates,1_000+BRIDGE_OWNER_NOTICE_RETRY_MS-1)),0)
    notice_live=true
    got:=notice_pass(&st,candidates,1_000+BRIDGE_OWNER_NOTICE_RETRY_MS)
    testing.expect_value(t,len(got),1)
    testing.expect_value(t,len(notice_pass(&st,candidates,1_000+10*BRIDGE_OWNER_NOTICE_RETRY_MS)),0)
}

@(test)
test_owner_coordinator_notice_hold_stale_after_the_interval_and_at_most_once_per_interval :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    saved:=bridge_owner_notice_deliver_effect
    defer bridge_owner_notice_deliver_effect=saved
    bridge_owner_notice_deliver_effect=notice_capture
    notice_live=true
    notice_deliveries=make([dynamic]Notice_Delivery,context.temp_allocator)
    st:Owner_Notice_State
    defer notice_state_destroy(&st)
    held:=[]owner.Coordinator_Notice_Candidate{{chain_id="chain",task_id="task_h",coordinator="inst_coord",trigger="hold_stale",title="Held one",reason="user hold",attempt="1"}}
    start:=i64(10_000)
    testing.expect_value(t,len(notice_pass(&st,held,start)),0)
    testing.expect_value(t,len(notice_pass(&st,held,start+BRIDGE_OWNER_NOTICE_HOLD_STALE_MS-1)),0)
    got:=notice_pass(&st,held,start+BRIDGE_OWNER_NOTICE_HOLD_STALE_MS)
    if testing.expect_value(t,len(got),1) do testing.expect_value(t,got[0].line,"[taskv2] hold_stale: task task_h (Held one) held for 30 min (reason: user hold); release it with `task release task_h` once the reason is resolved")
    // Many passes within the interval: one reminder only.
    for i in 1..=20 do testing.expect_value(t,len(notice_pass(&st,held,start+BRIDGE_OWNER_NOTICE_HOLD_STALE_MS+i64(i)*60_000)),0)
    got=notice_pass(&st,held,start+2*BRIDGE_OWNER_NOTICE_HOLD_STALE_MS)
    if testing.expect_value(t,len(got),1) do testing.expect(t,strings.contains(got[0].line,"held for 60 min"),got[0].line)
}

@(test)
test_owner_coordinator_notice_repeats_use_the_hold_time_and_throttle_failed_retries :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    saved:=bridge_owner_notice_deliver_effect
    defer bridge_owner_notice_deliver_effect=saved
    bridge_owner_notice_deliver_effect=notice_capture
    notice_live=true
    notice_deliveries=make([dynamic]Notice_Delivery,context.temp_allocator)
    st:Owner_Notice_State
    defer notice_state_destroy(&st)
    // A hold recorded 45 min before this Bridge first sees it is stale at once.
    now:=i64(100*60_000)
    held:=[]owner.Coordinator_Notice_Candidate{{chain_id="chain",task_id="task_h",coordinator="inst_coord",trigger="hold_stale",title="Held",reason="r",attempt="1",since_ms=now-45*60_000}}
    got:=notice_pass(&st,held,now)
    if testing.expect_value(t,len(got),1) do testing.expect(t,strings.contains(got[0].line,"held for 45 min"),got[0].line)
    // A blocked_on human re-alert that is not delivered is retried only after
    // BRIDGE_OWNER_NOTICE_RETRY_MS, not on every poll.
    blocked:=[]owner.Coordinator_Notice_Candidate{{chain_id="chain",task_id="task_b",coordinator="inst_coord",trigger="blocked_on human",title="B",attempt="1"}}
    testing.expect_value(t,len(notice_pass(&st,blocked,1_000)),1)
    realert:=1_000+BRIDGE_OWNER_NOTICE_BLOCKED_REALERT_MS
    notice_live=false
    testing.expect_value(t,len(notice_pass(&st,blocked,realert)),0)
    testing.expect_value(t,len(bridge_owner_notices_due(&st,blocked,realert+5_000)),0)
    notice_live=true
    got=notice_pass(&st,blocked,realert+BRIDGE_OWNER_NOTICE_RETRY_MS)
    if testing.expect_value(t,len(got),1) do testing.expect(t,strings.contains(got[0].line,"still waiting"),got[0].line)
}
