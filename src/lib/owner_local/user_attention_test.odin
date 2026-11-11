#+feature dynamic-literals
package owner_local

import "core:testing"

@(test)
user_attention_lists_blocked_tasks_until_resolved :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    items,ok:=user_attention_list(&f.store)
    testing.expect(t,ok && len(items)==0,"a ready task needs nobody")
    tasks,_:=query(f.store.db,"SELECT chain_id FROM tasks WHERE task_id='task'")
    chain:=tasks[0][0]
    blocked,stored:=block_agent_not_running(&f.store,chain,"task","agt_gone","Agent agt_gone is not running",1000)
    testing.expect(t,stored && blocked)
    items,ok=user_attention_list(&f.store)
    if !testing.expect(t,ok && len(items)==1) do return
    testing.expect_value(t,items[0],User_Attention{chain,"task","blocked","agent_not_running","ready","0"})
    // Blocked on the user (lease.block / task.escalate) reads as a question.
    _,_=query(f.store.db,"UPDATE local_controls SET waiting_on='human' WHERE chain_id=? AND task_id='task'",chain)
    items,_=user_attention_list(&f.store)
    testing.expect_value(t,items[0].badge,"question")
    // Blocked on another agent is not the user's.
    _,_=query(f.store.db,"UPDATE local_controls SET waiting_on='agent' WHERE chain_id=? AND task_id='task'",chain)
    items,_=user_attention_list(&f.store)
    testing.expect_value(t,len(items),0)
    _,_=query(f.store.db,"UPDATE local_controls SET waiting_on='user' WHERE chain_id=? AND task_id='task'",chain)
    rev,_:=query(f.store.db,"SELECT revision FROM tasks WHERE chain_id=? AND task_id='task'",chain)
    testing.expect_value(t,control_call(f,"task.resolve","resolve_user",rev[0][0]).code,"ok")
    items,_=user_attention_list(&f.store)
    testing.expect_value(t,len(items),0)
}

@(test)
user_attention_lists_a_review_awaiting_the_user_until_approved :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    no_reviewer_seed(t,f,USER_GATE_BRIEF)
    testing.expect_value(t,no_reviewer_submit(t,f).code,"ok")
    items,ok:=user_attention_list(&f.store)
    if !testing.expect(t,ok && len(items)==1) do return
    testing.expect_value(t,items[0].task_id,"task")
    testing.expect_value(t,items[0].attention,"review")
    testing.expect_value(t,items[0].state,"in_review")
    p:=lifecycle_verdict()
    testing.expect_value(t,invoke(f,command(f,"review.post","human","task",p,agent_task_revision(f,"task")),p).code,"ok")
    items,_=user_attention_list(&f.store)
    testing.expect_value(t,len(items),0)
}

@(test)
user_attention_lists_a_review_only_once_the_agent_reviewer_approved :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);user_gate_seed(t,f)
    cap:=lifecycle_ready(t,f)
    if cap=="" do return
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","submit",`{"requirements_revision":"1","head":"","summary":"Checks pass"}`,cap).code,"ok")
    testing.expect_value(t,user_gate_state(f),"in_review")
    // The agent reviewer is still owed: the user is not the gate yet.
    items,ok:=user_attention_list(&f.store)
    testing.expect(t,ok && len(items)==0,"no review item while an agent review is owed")
    p:=lifecycle_verdict()
    opened:=lifecycle_call(f,lifecycle_reviewer(),"review.open","open",p,"",agent_task_revision(f,"task"))
    if !testing.expect_value(t,opened.code,"ok") do return
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.post","post",p,result_cap(opened),agent_task_revision(f,"task")).code,"ok")
    items,ok=user_attention_list(&f.store)
    if !testing.expect(t,ok && len(items)==1) do return
    testing.expect_value(t,items[0].attention,"review")
    testing.expect_value(t,items[0].attempt,"1")
    testing.expect_value(t,invoke(f,command(f,"review.post","human","task",p,agent_task_revision(f,"task")),p).code,"ok")
    items,_=user_attention_list(&f.store)
    testing.expect_value(t,len(items),0)
}
