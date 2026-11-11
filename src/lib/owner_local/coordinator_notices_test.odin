#+feature dynamic-literals
package owner_local

import "core:testing"

@(test)
coordinator_notice_candidates_follow_blocks_and_holds :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    coord:=agent_coordinator_child()
    agent_seat_coordinator(t,f,coord)
    items,ok:=coordinator_notice_candidates(&f.store)
    testing.expect(t,ok && len(items)==0,"a ready task tells the coordinator nothing")
    blocked,stored:=block_agent_not_running(&f.store,"chain","task","agt_gone","Agent agt_gone is not running",1000)
    testing.expect(t,stored && blocked)
    items,ok=coordinator_notice_candidates(&f.store)
    if !testing.expect(t,ok && len(items)==1) do return
    testing.expect_value(t,items[0].trigger,"agent_not_running")
    testing.expect_value(t,items[0].coordinator,coord.instance)
    testing.expect_value(t,items[0].task_id,"task")
    testing.expect_value(t,items[0].reason,"Agent agt_gone is not running")
    testing.expect(t,items[0].title!="","the stored title travels with the candidate")
    // lease.block --waiting-on user and the older human both read as blocked_on human.
    for waiting in ([2]string{"user","human"}) {
        _,_=query(f.store.db,"UPDATE local_controls SET waiting_on=? WHERE chain_id='chain' AND task_id='task'",waiting)
        items,_=coordinator_notice_candidates(&f.store)
        testing.expect_value(t,items[0].trigger,"blocked_on human")
    }
    // Blocked on another agent is not the coordinator's to relay.
    _,_=query(f.store.db,"UPDATE local_controls SET waiting_on='agent' WHERE chain_id='chain' AND task_id='task'")
    items,_=coordinator_notice_candidates(&f.store)
    testing.expect_value(t,len(items),0)
    // A hold is a hold_stale candidate (the Bridge applies the age).
    _,_=query(f.store.db,"UPDATE local_controls SET mode='held',waiting_on='',reason='waiting for release' WHERE chain_id='chain' AND task_id='task'")
    items,_=coordinator_notice_candidates(&f.store)
    if !testing.expect_value(t,len(items),1) do return
    testing.expect_value(t,items[0].trigger,"hold_stale")
    testing.expect_value(t,items[0].reason,"waiting for release")
    _,_=query(f.store.db,"UPDATE local_controls SET mode='ready',reason='' WHERE chain_id='chain' AND task_id='task'")
    items,_=coordinator_notice_candidates(&f.store)
    testing.expect_value(t,len(items),0)
}

@(test)
coordinator_notice_candidates_list_a_review_awaiting_the_user_until_approved :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    no_reviewer_seed(t,f,USER_GATE_BRIEF)
    coord:=agent_coordinator_child()
    agent_seat_coordinator(t,f,coord)
    testing.expect_value(t,no_reviewer_submit(t,f).code,"ok")
    items,ok:=coordinator_notice_candidates(&f.store)
    if !testing.expect(t,ok && len(items)==1) do return
    testing.expect_value(t,items[0].trigger,"review_requested_from_user")
    testing.expect_value(t,items[0].coordinator,coord.instance)
    testing.expect_value(t,items[0].attempt,"1")
    p:=lifecycle_verdict()
    testing.expect_value(t,invoke(f,command(f,"review.post","human","task",p,agent_task_revision(f,"task")),p).code,"ok")
    items,_=coordinator_notice_candidates(&f.store)
    testing.expect_value(t,len(items),0)
}

@(test)
coordinator_notice_review_waits_for_the_agent_reviewer_before_asking_the_user :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);user_gate_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    cap:=lifecycle_ready(t,f)
    if cap=="" do return
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","submit",`{"requirements_revision":"1","head":"","summary":"Checks pass"}`,cap).code,"ok")
    testing.expect_value(t,user_gate_state(f),"in_review")
    // The agent reviewer is still owed: the user is not the gate yet.
    items,ok:=coordinator_notice_candidates(&f.store)
    testing.expect(t,ok && len(items)==0,"no review_requested_from_user while an agent review is owed")
    p:=lifecycle_verdict()
    opened:=lifecycle_call(f,lifecycle_reviewer(),"review.open","open",p,"",agent_task_revision(f,"task"))
    if !testing.expect_value(t,opened.code,"ok") do return
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.post","post",p,result_cap(opened),agent_task_revision(f,"task")).code,"ok")
    items,ok=coordinator_notice_candidates(&f.store)
    if !testing.expect(t,ok && len(items)==1) do return
    testing.expect_value(t,items[0].trigger,"review_requested_from_user")
    testing.expect_value(t,items[0].coordinator,coord.instance)
    testing.expect_value(t,invoke(f,command(f,"review.post","human","task",p,agent_task_revision(f,"task")),p).code,"ok")
    items,_=coordinator_notice_candidates(&f.store)
    testing.expect_value(t,len(items),0)
}

@(test)
coordinator_notice_hold_waits_for_the_checkpointing_holder_and_carries_its_hold_time :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    _=lifecycle_ready(t,f)
    payload:=encode(doc(map[string]string{"body_cipher"=cipher(f,"hold reason")}))
    testing.expect_value(t,invoke(f,command(f,"task.hold","hold","task",payload,agent_task_revision(f,"task")),payload).code,"ok")
    // The live holder was asked to checkpoint: not stale while it does.
    items,ok:=coordinator_notice_candidates(&f.store)
    testing.expect(t,ok && len(items)==0,"no hold_stale while a live holder checkpoints")
    // Its handoff or expiry retires the lease; the hold then counts from its receipt.
    _,retired:=query(f.store.db,"UPDATE local_leases SET retired_seq=(SELECT max(commit_seq)+1 FROM command_receipts) WHERE chain_id='chain' AND task_id='task' AND retired_seq IS NULL")
    testing.expect(t,retired)
    receipt,_:=query(f.store.db,"SELECT created_ms FROM command_receipts WHERE chain_id='chain' AND task_id='task' AND method='task.hold'")
    items,ok=coordinator_notice_candidates(&f.store)
    if !testing.expect(t,ok && len(items)==1 && len(receipt)==1) do return
    testing.expect_value(t,items[0].trigger,"hold_stale")
    testing.expect_value(t,items[0].since_ms,number(receipt[0][0]))
}
