#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:testing"

// No reviewer is a valid state (origin/main parity: a task with no review
// roles is done on submit). lifecycle.configure accepts an empty reviewer;
// lease.submit then settles at once (done), or waits only for the user when
// the brief requires the user's approval. A reviewer, when named, is still
// never the author.

no_reviewer_seed :: proc(t:^testing.T,f:^Fixture,brief:string) {
    child:=lease_child();fleet_seed(t,f,child)
    raw:=encode(doc(map[string]string{"configuration_revision"="1","author_agent_id"="author","reviewer_agent_id"="","reviewer_instance_id"="","directory_id"="directory","merge_policy"="none","repository"="","worktree"="","source_branch"="","target_branch"="","base_head"=""}))
    c:=command(f,"lifecycle.configure","config","task",raw,"2")
    testing.expect_value(t,execute(&f.store,c,raw,"",f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},{},Lifecycle_Proof{child,{},true}).code,"ok")
    p:=encode(doc(map[string]string{"requirements_revision"="1","body_cipher"=cipher(f,brief)}))
    testing.expect_value(t,invoke(f,command(f,"requirements.edit","req1","task",p,"3"),p).code,"ok")
}
no_reviewer_submit :: proc(t:^testing.T,f:^Fixture) -> Result {
    cap:=lifecycle_ready(t,f)
    return lifecycle_call(f,lease_child(),"lease.submit","submit",`{"requirements_revision":"1","head":"","summary":"Checks pass"}`,cap)
}

@(test)
no_reviewer_task_is_done_on_submit :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    no_reviewer_seed(t,f,`{"goal":"Complete scoped work","acceptance":["Tests pass"]}`)
    r:=no_reviewer_submit(t,f)
    testing.expect_value(t,r.code,"ok")
    v,_:=json.parse_string(r.body,.JSON,true,context.temp_allocator)
    body,_:=v.(json.Object)
    testing.expect_value(t,field(body,"state"),"done")
    testing.expect_value(t,user_gate_state(f),"done")
    testing.expect_value(t,fleet_scalar(f,"SELECT count(*) FROM local_submissions WHERE chain_id='chain' AND task_id='task'"),"1")
}

@(test)
no_reviewer_with_user_approval_waits_for_the_user_only :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    no_reviewer_seed(t,f,USER_GATE_BRIEF)
    r:=no_reviewer_submit(t,f)
    testing.expect_value(t,r.code,"ok")
    testing.expect_value(t,user_gate_state(f),"in_review")
    // The user's device approval settles it; no agent review is owed.
    p:=lifecycle_verdict()
    testing.expect_value(t,invoke(f,command(f,"review.post","human","task",p,agent_task_revision(f,"task")),p).code,"ok")
    testing.expect_value(t,user_gate_state(f),"done")
}

@(test)
no_reviewer_configure_keeps_reviewer_rules_when_one_is_named :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    child:=lease_child();fleet_seed(t,f,child)
    configure :: proc(f:^Fixture,op,reviewer_agent,reviewer_instance:string,proof:Lifecycle_Proof) -> string {
        raw:=encode(doc(map[string]string{"configuration_revision"="1","author_agent_id"="author","reviewer_agent_id"=reviewer_agent,"reviewer_instance_id"=reviewer_instance,"directory_id"="directory","merge_policy"="none","repository"="","worktree"="","source_branch"="","target_branch"="","base_head"=""}))
        return execute(&f.store,command(f,"lifecycle.configure",op,"task",raw,"2"),raw,"",f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},{},proof).code
    }
    // The author never reviews its own task.
    testing.expect_value(t,configure(f,"self_review","author",child.instance,Lifecycle_Proof{child,child,true}),"invalid_scope")
    // An empty reviewer with a reviewer proof is inconsistent.
    testing.expect_value(t,configure(f,"phantom","","",Lifecycle_Proof{child,lifecycle_reviewer(),true}),"invalid_scope")
    // A half-named reviewer is refused.
    testing.expect_value(t,configure(f,"half","reviewer","",Lifecycle_Proof{child,{},true}),"invalid_scope")
    testing.expect_value(t,configure(f,"none","","",Lifecycle_Proof{child,{},true}),"ok")
}

// Solo (requirements rev 6, user 08:45Z): the coordinator works its own task
// under the same rule as any task. With no reviewer and no user gate it is
// done on submit; nothing forces an independent reviewer or a user review.
@(test)
no_reviewer_solo_coordinator_submits_to_done :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    no_reviewer_seed(t,f,`{"goal":"Complete scoped work","acceptance":["Tests pass"]}`)
    solo:=lease_child()
    agent_seat_coordinator(t,f,solo)
    coordinator,worker_row:=agent_solo_standing(&f.store,"chain",solo)
    testing.expect(t,coordinator && worker_row,"the coordinator holds the task's worker row (solo)")
    r:=no_reviewer_submit(t,f)
    testing.expect_value(t,r.code,"ok")
    testing.expect_value(t,user_gate_state(f),"done")
    testing.expect_value(t,fleet_scalar(f,"SELECT count(*) FROM local_reviews"),"0")
}
