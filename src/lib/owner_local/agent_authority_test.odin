#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

agent_coordinator_child :: proc() -> Child { return {"coord_instance","coord_epoch",strings.repeat("c",64,context.temp_allocator),1,"coordinator_agent"} }
agent_stranger :: proc() -> Child { return {"stranger","stranger_epoch",strings.repeat("d",64,context.temp_allocator),1,"stranger_agent"} }
agent_task_revision :: proc(f:^Fixture,task:string) -> string {
    rows,_:=query(f.store.db,"SELECT revision FROM tasks WHERE chain_id='chain' AND task_id=?",task)
    return rows[0][0] if len(rows)==1 else "0"
}
agent_chain_rev :: proc(f:^Fixture) -> string {
    rows,_:=query(f.store.db,"SELECT revision FROM task_chains WHERE chain_id='chain'")
    return rows[0][0]
}
// The device (UI) enrolls the coordinator member: the only way a child gains
// chain-management authority.
agent_seat_coordinator :: proc(t:^testing.T,f:^Fixture,child:Child) {
    p:=encode(doc(map[string]string{"instance_id"=child.instance,"agent_id"=child.agent_id,"role"="coordinator","enabled"="1"}))
    c:=command(f,"chain.member.set","seat_coordinator","",p,agent_chain_rev(f))
    testing.expect_value(t,execute(&f.store,c,p,f.genesis,f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},child).code,"ok")
}
agent_add_task :: proc(t:^testing.T,f:^Fixture,task:string) {
    p:=encode(doc(map[string]string{"title_cipher"=cipher(f,"second title"),"body_cipher"=cipher(f,"second body")}))
    testing.expect_value(t,invoke(f,command(f,"task.create",fmt.tprintf("create_%s",task),task,p,agent_chain_rev(f)),p).code,"ok")
}
agent_bind :: proc(t:^testing.T,f:^Fixture,task:string,child:Child) {
    p:=encode(doc(map[string]string{"instance_id"=child.instance,"configuration_revision"="1","enabled"="1"}))
    c:=command(f,"fleet.edit",fmt.tprintf("fleet_%s",task),task,p,agent_task_revision(f,task))
    testing.expect_value(t,execute(&f.store,c,p,f.genesis,f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},child).code,"ok")
}
// An owner-signed agent command, exactly as the owner Bridge builds it.
agent_command :: proc(f:^Fixture,agent:Child,method,op,task,payload,revision:string,signer:=0) -> string {
    c:=doc(map[string]string{"protocol_version"="1","account_id"="account","chain_id"="chain","immutable_owner_bridge"="bridge","principal_id"=agent.instance,"operation_id"=op,"method"=method,"task_id"=task,"expected_revision"=revision,"request_expires_ms"="2000","payload_digest"=contracts.owner_payload_digest(payload),"key_id"="bridge_key","signature"=strings.repeat("0",128,context.temp_allocator)})
    sig,_:=test_sign(&f.owner_priv if signer==0 else &f.creator_priv,"command",c);c["signature"]=json.String(sig)
    return encode(c)
}
agent_run :: proc(f:^Fixture,agent:Child,method,op,task,payload,revision:string,signer:=0) -> Result {
    return execute_agent(&f.store,agent_command(f,agent,method,op,task,payload,revision,signer),payload,agent,f.owner,1000,&f.kr,Signer{&f.owner_priv,test_sign})
}
agent_role :: proc(f:^Fixture,task:string,child:Child,verb:string) -> Agent_Role {
    role,_:=agent_authorize_locked(&f.store,"chain",task,child,verb)
    return role
}

@(test)
agent_policy_worker_own_task_coordinator_chain_verbs_and_foreign_refusal :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    agent_add_task(t,f,"other")
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    worker,reviewer,stranger:=lease_child(),lifecycle_reviewer(),agent_stranger()

    // Worker: only its own bound task, only worker verbs.
    for verb in ([5]string{"lease.next","lease.heartbeat","lease.submit","requirements.ack","lease.handoff"}) {
        testing.expect_value(t,agent_role(f,"task",worker,verb),Agent_Role.Worker)
        testing.expect_value(t,agent_role(f,"other",worker,verb),Agent_Role.None)
    }
    for verb in ([5]string{"chain.summary.set","task.create","chain.publish","review.human","task.edit"}) {
        testing.expect_value(t,agent_role(f,"task",worker,verb),Agent_Role.None)
    }
    testing.expect_value(t,agent_role(f,"task",worker,"task.comment"),Agent_Role.None)
    testing.expect_value(t,agent_role(f,"task",worker,"review.open"),Agent_Role.None)
    // A stale launch of the same instance is a different child.
    relaunched:=worker;relaunched.run_count=2
    testing.expect_value(t,agent_role(f,"task",relaunched,"lease.heartbeat"),Agent_Role.None)

    // Coordinator: chain-management verbs, never a worker lease.
    for verb in ([7]string{"chain.summary.set","task.create","task.comment","task.read","chain.read","task.edit","review.human"}) {
        testing.expect_value(t,agent_role(f,"task",coord,verb),Agent_Role.Coordinator)
    }
    testing.expect_value(t,agent_role(f,"task",coord,"lease.heartbeat"),Agent_Role.None)
    testing.expect_value(t,agent_role(f,"task",coord,"review.open"),Agent_Role.None)
    // The coordinator binding is by instance id: a restarted launch (new epoch)
    // keeps authority; the instance token already authenticates the live child.
    restarted:=coord;restarted.epoch="new_epoch";restarted.run_count=2
    testing.expect_value(t,agent_role(f,"task",restarted,"chain.summary.set"),Agent_Role.Coordinator)
    impostor:=coord;impostor.agent_id="other_agent"
    testing.expect_value(t,agent_role(f,"task",impostor,"chain.summary.set"),Agent_Role.None)

    // Reviewer: only the configured reviewer child.
    testing.expect_value(t,agent_role(f,"task",reviewer,"review.open"),Agent_Role.Reviewer)
    testing.expect_value(t,agent_role(f,"task",reviewer,"lease.heartbeat"),Agent_Role.None)
    testing.expect_value(t,agent_role(f,"task",reviewer,"chain.summary.set"),Agent_Role.None)

    // A foreign or unrelated agent is refused everything, including reads.
    for verb in ([6]string{"lease.next","task.read","chain.read","chain.summary.set","review.open","task.comment"}) {
        testing.expect_value(t,agent_role(f,"task",stranger,verb),Agent_Role.None)
    }
    // Unknown chain, unknown task and unknown verbs are refused.
    role,code:=agent_authorize_locked(&f.store,"no_chain","task",coord,"chain.read")
    testing.expect(t,role==.None && code=="invalid_scope")
    testing.expect_value(t,agent_role(f,"missing",coord,"task.read"),Agent_Role.None)
    testing.expect_value(t,agent_role(f,"task",coord,"grant.set"),Agent_Role.None)
    // Fleet management (membership, policy) is the coordinator's; remote
    // reservations and grants stay human-only; workers get none of it.
    testing.expect_value(t,agent_role(f,"",coord,"chain.member.set"),Agent_Role.Coordinator)
    testing.expect_value(t,agent_role(f,"",coord,"fleet.policy.set"),Agent_Role.Coordinator)
    testing.expect_value(t,agent_role(f,"task",coord,"fleet.reserve"),Agent_Role.None)
    testing.expect_value(t,agent_role(f,"",worker,"chain.member.set"),Agent_Role.None)
    testing.expect_value(t,agent_role(f,"",worker,"fleet.policy.set"),Agent_Role.None)
    testing.expect_value(t,agent_role(f,"task",worker,"fleet.edit"),Agent_Role.None)

    // Holding a live lease lets the worker read and comment on that task only.
    pick:=lifecycle_ready(t,f)
    if pick=="" do return
    testing.expect_value(t,agent_role(f,"task",worker,"task.comment"),Agent_Role.Worker)
    testing.expect_value(t,agent_role(f,"task",worker,"task.read"),Agent_Role.Worker)
    testing.expect_value(t,agent_role(f,"other",worker,"task.read"),Agent_Role.None)
}

@(test)
agent_policy_member_of_another_chain_is_foreign :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    testing.expect_value(t,agent_role(f,"task",coord,"chain.read"),Agent_Role.Coordinator)
    // Lifetime binding to another chain makes the same child foreign here.
    testing.expect(t,exec(f.store.db,"INSERT INTO task_chains VALUES('elsewhere','device','device','t','d',1); DROP TRIGGER local_member_chains_no_update; UPDATE local_member_chains SET chain_id='elsewhere' WHERE instance_id='coord_instance';"))
    testing.expect_value(t,agent_role(f,"task",coord,"chain.read"),Agent_Role.None)
}

@(test)
agent_commands_execute_for_coordinator_and_refuse_everyone_else :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    summary:=encode(doc(map[string]string{"body_cipher"=cipher(f,"coordinator summary")}))
    r:=agent_run(f,coord,"chain.summary.set","summary","",summary,agent_chain_rev(f))
    testing.expect_value(t,r.code,"ok")
    replay:=agent_run(f,coord,"chain.summary.set","summary","",summary,"0")
    testing.expect_value(t,replay.code,"operation_conflict")
    comment:=encode(doc(map[string]string{"body_cipher"=cipher(f,"coordinator comment")}))
    testing.expect_value(t,agent_run(f,coord,"task.comment","comment","task",comment,agent_task_revision(f,"task")).code,"ok")
    events,_:=query(f.store.db,"SELECT actor_kind,actor_id FROM local_events WHERE kind='task.comment'")
    testing.expect(t,len(events)==1 && events[0][0]=="agent" && events[0][1]=="coord_instance","history attributes the agent, not a device")
    created:=encode(doc(map[string]string{"title_cipher"=cipher(f,"agent task"),"body_cipher"=cipher(f,"agent body")}))
    testing.expect_value(t,agent_run(f,coord,"task.create","create_agent","agent_task",created,agent_chain_rev(f)).code,"ok")
    read:=agent_run(f,coord,"task.read","read","task",`{"cursor":"","limit":"10"}`,"0")
    testing.expect(t,read.code=="ok" && strings.contains(read.body,"coordinator comment"))

    worker,stranger:=lease_child(),agent_stranger()
    // Worker without a lease, a stranger and a forged (device-key) signature.
    testing.expect_value(t,agent_run(f,worker,"task.comment","w_comment","task",comment,agent_task_revision(f,"task")).code,"invalid_scope")
    testing.expect_value(t,agent_run(f,worker,"chain.summary.set","w_summary","",summary,agent_chain_rev(f)).code,"invalid_scope")
    testing.expect_value(t,agent_run(f,stranger,"task.read","s_read","task",`{"cursor":"","limit":"10"}`,"0").code,"invalid_scope")
    testing.expect_value(t,agent_run(f,coord,"task.comment","forged","task",comment,agent_task_revision(f,"task"),1).code,"bad_signature")
    // Principal must be the proven child; methods outside the allowlist fail.
    other:=coord;other.instance="someone_else"
    raw:=agent_command(f,other,"task.comment","swap","task",comment,agent_task_revision(f,"task"))
    testing.expect_value(t,execute_agent(&f.store,raw,comment,coord,f.owner,1000,&f.kr,Signer{&f.owner_priv,test_sign}).code,"invalid_scope")
    fleet:=encode(doc(map[string]string{"instance_id"=coord.instance,"configuration_revision"="9","enabled"="1"}))
    testing.expect_value(t,agent_run(f,coord,"fleet.edit","fleet_self","task",fleet,agent_task_revision(f,"task")).code,"invalid_scope")
    // With a live lease the worker may comment on its own task.
    claimed,pick:=lease_next(&f.store,worker,f.owner,1000,Signer{&f.owner_priv,test_sign},"lease_w","op_w")
    if !testing.expect(t,claimed.code=="ok" && pick.status=="granted") do return
    testing.expect_value(t,agent_run(f,worker,"task.comment","w_comment2","task",comment,agent_task_revision(f,"task")).code,"ok")
}

@(test)
agent_lease_next_selects_priority_respects_holds_and_returns_current :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    child:=lease_child();fleet_seed(t,f,child)
    agent_add_task(t,f,"urgent");agent_bind(t,f,"urgent",child)
    agent_add_task(t,f,"unbound")
    p:=`{"priority":"p0"}`
    testing.expect_value(t,invoke(f,command(f,"task.priority","prio","urgent",p,agent_task_revision(f,"urgent")),p).code,"ok")
    hold:=encode(doc(map[string]string{"body_cipher"=cipher(f,"paused by user")}))
    testing.expect_value(t,invoke(f,command(f,"task.hold","hold","urgent",hold,agent_task_revision(f,"urgent")),hold).code,"ok")

    sign:=Signer{&f.owner_priv,test_sign}
    stranger:=agent_stranger()
    none,nobody:=lease_next(&f.store,stranger,f.owner,1000,sign,"lease_s","op_s")
    testing.expect(t,none.code=="ok" && nobody.status=="none","an unbound agent gets nothing")
    // The held p0 task is skipped; the ready p2 task is claimed atomically.
    r,pick:=lease_next(&f.store,child,f.owner,1000,sign,"lease_1","op_1")
    testing.expect_value(t,r.code,"ok")
    testing.expect(t,pick.status=="granted" && pick.task_id=="task" && pick.lease_id=="lease_1")
    testing.expect(t,strings.contains(r.body,"capability"))
    again,current:=lease_next(&f.store,child,f.owner,1000,sign,"lease_2","op_2")
    testing.expect(t,again.code=="ok" && current.status=="current" && current.lease_id=="lease_1","an existing lease is returned, not a second claim")
    rows,_:=query(f.store.db,"SELECT count(*) FROM local_leases WHERE retired_seq IS NULL")
    testing.expect_value(t,rows[0][0],"1")
    // Releasing the hold makes the p0 task first once the current lease ends.
    release:=encode(doc(map[string]string{"body_cipher"=cipher(f,"resume")}))
    testing.expect_value(t,invoke(f,command(f,"task.release","release","urgent",release,agent_task_revision(f,"urgent")),release).code,"ok")
    testing.expect(t,expire_leases(&f.store,901001))
    later,next:=lease_next(&f.store,child,f.owner,901002,sign,"lease_3","op_3")
    testing.expect(t,later.code=="ok" && next.status=="granted" && next.task_id=="urgent","p0 task is preferred")
}

@(test)
agent_lease_next_respects_dependencies_and_lifecycle_author_binding :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    child:=lease_child()
    agent_add_task(t,f,"after");agent_bind(t,f,"after",child)
    dep:=`{"prerequisite":"task","enabled":"1"}`
    testing.expect_value(t,invoke(f,command(f,"dependency.edit","dep","after",dep,agent_task_revision(f,"after")),dep).code,"ok")
    sign:=Signer{&f.owner_priv,test_sign}
    // A different agent identity on the same instance id is not the author.
    impostor:=child;impostor.agent_id="someone"
    _,refused:=lease_next(&f.store,impostor,f.owner,1000,sign,"lease_x","op_x")
    testing.expect_value(t,refused.status,"none")
    r,pick:=lease_next(&f.store,child,f.owner,1000,sign,"lease_1","op_1")
    testing.expect(t,r.code=="ok" && pick.status=="granted" && pick.task_id=="task","the unblocked lifecycle task is claimed; its dependent waits")
    st,found:=agent_lease_state(&f.store,child)
    testing.expect(t,found && st.lease_id=="lease_1" && st.configured && st.requirements_revision=="1" && st.capability!="")
}

agent_seat :: proc(t:^testing.T,f:^Fixture,child:Child,role:string) {
    p:=encode(doc(map[string]string{"instance_id"=child.instance,"agent_id"=child.agent_id,"role"=role,"enabled"="1"}))
    c:=command(f,"chain.member.set",fmt.tprintf("seat_%s",child.instance),"",p,agent_chain_rev(f))
    testing.expect_value(t,execute(&f.store,c,p,f.genesis,f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},child).code,"ok")
}
// Lifecycle command of an arbitrary task/lease, signed by the owner key as the
// Bridge does for a proven child.
agent_lifecycle :: proc(f:^Fixture,child:Child,task,lease,method,op,payload,cap,configuration:string) -> Result {
    c:=doc(map[string]string{
        "protocol_version"="1","account_id"="account","owner_bridge_id"="bridge","chain_id"="chain","task_id"=task,
        "lease_id"=lease,"instance_id"=child.instance,"launch_epoch"=child.epoch,"run_count"=fmt.tprintf("%d",child.run_count),
        "token_generation"=child.token_generation,"configuration_revision"=configuration,"expected_revision"=agent_task_revision(f,task),
        "operation_id"=op,"method"=method,"request_expires_ms"="2000","capability_digest"=contracts.owner_payload_digest(cap),
        "key_id"="bridge_key","signature"=strings.repeat("0",128,context.temp_allocator),"payload_digest"=contracts.owner_payload_digest(payload)})
    sig,_:=test_sign(&f.owner_priv,"lifecycle_command",c);c["signature"]=json.String(sig)
    return execute_lifecycle(&f.store,encode(c),payload,cap,child,f.owner,1000,Signer{&f.owner_priv,test_sign},Source_Proof{"",true})
}
agent_assign_run :: proc(f:^Fixture,coord,worker,reviewer:Child,task:string) -> (string,string) {
    fleet:=encode(doc(map[string]string{"instance_id"=worker.instance,"configuration_revision"="1","enabled"="1"}))
    raw:=agent_command(f,coord,"fleet.edit",fmt.tprintf("fleet_%s",task),task,fleet,agent_task_revision(f,task))
    r:=execute_agent(&f.store,raw,fleet,coord,f.owner,1000,&f.kr,Signer{&f.owner_priv,test_sign},worker)
    if r.code!="ok" do return "fleet",r.code
    config:=encode(doc(map[string]string{"configuration_revision"="1","author_agent_id"=worker.agent_id,"reviewer_agent_id"=reviewer.agent_id,"reviewer_instance_id"=reviewer.instance,"directory_id"="owner_none","merge_policy"="none","repository"="","worktree"="","source_branch"="","target_branch"="","base_head"=""}))
    raw=agent_command(f,coord,"lifecycle.configure",fmt.tprintf("config_%s",task),task,config,agent_task_revision(f,task))
    r=execute_agent(&f.store,raw,config,coord,f.owner,1000,&f.kr,Signer{&f.owner_priv,test_sign},{},Lifecycle_Proof{worker,reviewer,true})
    if r.code!="ok" do return "configure",r.code
    return "","ok"
}

@(test)
agent_coordinator_creates_assigns_and_the_assigned_pair_runs_the_task :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    coord,worker,reviewer,stranger:=agent_coordinator_child(),lease_child(),lifecycle_reviewer(),agent_stranger()
    agent_seat_coordinator(t,f,coord);agent_seat(t,f,worker,"worker");agent_seat(t,f,reviewer,"reviewer")
    tmpl,code:=agent_assignment_template(&f.store,"chain")
    testing.expect(t,code=="ok" && tmpl.merge_policy=="none","no chain directory -> merge policy none")
    // The coordinator creates two tasks; the second depends on the first.
    for task in ([2]string{"first","second"}) {
        created:=encode(doc(map[string]string{"title_cipher"=cipher(f,task),"body_cipher"=cipher(f,"agent body")}))
        testing.expect_value(t,agent_run(f,coord,"task.create",fmt.tprintf("create_%s",task),task,created,agent_chain_rev(f)).code,"ok")
        brief:=encode(doc(map[string]string{"requirements_revision"="1","body_cipher"=cipher(f,`{"goal":"Ship it","acceptance":["Tests pass"]}`)}))
        testing.expect_value(t,agent_run(f,coord,"requirements.edit",fmt.tprintf("req_%s",task),task,brief,agent_task_revision(f,task)).code,"ok")
        testing.expect_value(t,agent_run(f,coord,"task.priority",fmt.tprintf("prio_%s",task),task,`{"priority":"p0"}`,agent_task_revision(f,task)).code,"ok")
        step,result:=agent_assign_run(f,coord,worker,reviewer,task)
        testing.expectf(t,result=="ok","%s assignment step %s: %s",task,step,result)
    }
    testing.expect_value(t,agent_run(f,coord,"dependency.edit","dep","second",`{"prerequisite":"first","enabled":"1"}`,agent_task_revision(f,"second")).code,"ok")
    // A non-member cannot be assigned, a git configuration outside the
    // chain's configured directory is refused, and a worker cannot assign.
    fleet:=encode(doc(map[string]string{"instance_id"=stranger.instance,"configuration_revision"="2","enabled"="1"}))
    raw:=agent_command(f,coord,"fleet.edit","fleet_stranger","second",fleet,agent_task_revision(f,"second"))
    testing.expect_value(t,execute_agent(&f.store,raw,fleet,coord,f.owner,1000,&f.kr,Signer{&f.owner_priv,test_sign},stranger).code,"invalid_scope")
    git:=encode(doc(map[string]string{"configuration_revision"="2","author_agent_id"=worker.agent_id,"reviewer_agent_id"=reviewer.agent_id,"reviewer_instance_id"=reviewer.instance,"directory_id"="elsewhere","merge_policy"="git","repository"="/repo","worktree"="/repo/.heimdall/worktrees/second","source_branch"="heimdall/second","target_branch"="main","base_head"=strings.repeat("b",40,context.temp_allocator)}))
    raw=agent_command(f,coord,"lifecycle.configure","config_git","second",git,agent_task_revision(f,"second"))
    testing.expect_value(t,execute_agent(&f.store,raw,git,coord,f.owner,1000,&f.kr,Signer{&f.owner_priv,test_sign},{},Lifecycle_Proof{worker,reviewer,true}).code,"invalid_scope")
    self_fleet:=encode(doc(map[string]string{"instance_id"=worker.instance,"configuration_revision"="2","enabled"="1"}))
    raw=agent_command(f,worker,"fleet.edit","worker_fleet","second",self_fleet,agent_task_revision(f,"second"))
    testing.expect_value(t,execute_agent(&f.store,raw,self_fleet,worker,f.owner,1000,&f.kr,Signer{&f.owner_priv,test_sign},worker).code,"invalid_scope")

    // The assigned worker leases the unblocked task, ACKs and submits.
    r,pick:=lease_next(&f.store,worker,f.owner,1000,Signer{&f.owner_priv,test_sign},"lease_first","op_first")
    if !testing.expect(t,r.code=="ok" && pick.status=="granted" && pick.task_id=="first","the dependent task waits; the first task is claimed") do return
    st,_:=agent_lease_state(&f.store,worker)
    req:=`{"requirements_revision":"1"}`
    testing.expect_value(t,agent_lifecycle(f,worker,"first","lease_first","requirements.present","present",req,st.capability,"1").code,"ok")
    testing.expect_value(t,agent_lifecycle(f,worker,"first","lease_first","requirements.ack","ack",req,st.capability,"1").code,"ok")
    testing.expect_value(t,agent_lifecycle(f,worker,"first","lease_first","lease.submit","submit",`{"requirements_revision":"1","head":"","summary":"done"}`,st.capability,"1").code,"ok")
    // Only the assigned reviewer reviews.
    verdict:=encode(doc(map[string]string{"requirements_revision"="1","attempt"="1","head"="","verdict"="approve","summary"="reviewed"}))
    testing.expect_value(t,agent_lifecycle(f,stranger,"first","lease_first","review.open","s_open",verdict,"","1").code,"invalid_scope")
    opened:=agent_lifecycle(f,reviewer,"first","lease_first","review.open","open",verdict,"","1")
    if !testing.expect_value(t,opened.code,"ok") do return
    testing.expect_value(t,agent_lifecycle(f,reviewer,"first","lease_first","review.post","post",verdict,result_cap(opened),"1").code,"ok")
    states,_:=query(f.store.db,"SELECT state FROM lifecycle_state WHERE chain_id='chain' AND task_id='first'")
    testing.expect_value(t,states[0][0],"done")
    // With its prerequisite done, the dependent task is claimable.
    next,second:=lease_next(&f.store,worker,f.owner,1000,Signer{&f.owner_priv,test_sign},"lease_second","op_second")
    testing.expect(t,next.code=="ok" && second.task_id=="second","the dependency is released by the approved prerequisite")
}

@(test)
agent_bindings_for_lease_routing_ignore_disabled_rows_and_reviewers :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    bound,ok:=agent_lease_bound(&f.store,"instance")
    testing.expect(t,ok && bound,"an enabled fleet worker routes lease verbs to the owner")
    bound,ok=agent_lease_bound(&f.store,"review_instance")
    testing.expect(t,ok && !bound,"a reviewer-only binding does not")
    _,_=query(f.store.db,"UPDATE local_fleet SET enabled=0,configuration_revision=configuration_revision+1")
    bound,ok=agent_lease_bound(&f.store,"instance")
    testing.expect(t,ok && !bound,"a disabled fleet row does not")
    _,found,read:=agent_task_state(&f.store,"","missing")
    testing.expect(t,read && !found,"a task this store does not hold is not found, not an error")
}

// T1 `--assignee self`: the coordinator is solo only while it holds an
// enabled worker fleet row in the chain; workers and strangers are never
// the coordinator.
@(test)
agent_solo_standing_coordinator_and_worker_row :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    c,w:=agent_solo_standing(&f.store,"chain",coord)
    testing.expect(t,c && !w,"a coordinator without a fleet row is not solo")
    agent_add_task(t,f,"solo_task");agent_bind(t,f,"solo_task",coord)
    c,w=agent_solo_standing(&f.store,"chain",coord)
    testing.expect(t,c && w,"a coordinator holding a worker fleet row is solo")
    c,w=agent_solo_standing(&f.store,"chain",agent_stranger())
    testing.expect(t,!c && !w,"a stranger is neither")
    // A coordinator seated in another chain is foreign here.
    c,_=agent_solo_standing(&f.store,"elsewhere",coord)
    testing.expect(t,!c,"not the coordinator of another chain")
}

// T1 review: `task-chain summary get` on an owner chain reads the latest
// curated summary from the owner store.
@(test)
agent_chain_summary_current_reads_latest_curated_summary :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    body,version,ok:=chain_summary_current(&f.store,"chain")
    testing.expect(t,ok && body=="" && version=="0","no summary yet")
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    summary:=encode(doc(map[string]string{"body_cipher"=cipher(f,"coordinator summary")}))
    testing.expect_value(t,agent_run(f,coord,"chain.summary.set","summary","",summary,agent_chain_rev(f)).code,"ok")
    body,version,ok=chain_summary_current(&f.store,"chain")
    testing.expect(t,ok && body!="" && version!="0","summary stored")
    // The owner store keeps the opened text (the Bridge passes it through
    // bridge_owner_plain, which also tolerates an envelope).
    testing.expect_value(t,body,"coordinator summary")
}

// Replace: bind a new coordinator, then disable the previous one. Authority is
// per instance, so the old instance loses coordinator verbs only once disabled.
@(test)
agent_replaced_coordinator_loses_authority_after_disable :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    old:=agent_coordinator_child();agent_seat_coordinator(t,f,old)
    next:=Child{"next_coord","next_epoch",strings.repeat("f",64,context.temp_allocator),1,"next_agent"}
    p:=encode(doc(map[string]string{"instance_id"=next.instance,"agent_id"=next.agent_id,"role"="coordinator","enabled"="1"}))
    c:=command(f,"chain.member.set","seat_next","",p,agent_chain_rev(f))
    testing.expect_value(t,execute(&f.store,c,p,f.genesis,f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},next).code,"ok")
    testing.expect_value(t,agent_role(f,"task",old,"chain.summary.set"),Agent_Role.Coordinator)
    off:=encode(doc(map[string]string{"instance_id"=old.instance,"agent_id"=old.agent_id,"role"="coordinator","enabled"="0"}))
    c=command(f,"chain.member.set","demote_old","",off,agent_chain_rev(f))
    testing.expect_value(t,execute(&f.store,c,off,f.genesis,f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},Child{}).code,"ok")
    testing.expect_value(t,agent_role(f,"task",old,"chain.summary.set"),Agent_Role.None)
    testing.expect_value(t,agent_role(f,"task",next,"chain.summary.set"),Agent_Role.Coordinator)
    testing.expect_value(t,chain_coordinator_instance(&f.store,"chain"),next.instance)
}
