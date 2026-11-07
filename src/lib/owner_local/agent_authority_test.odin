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
    stale:=coord;stale.epoch="old_epoch"
    testing.expect_value(t,agent_role(f,"task",stale,"chain.summary.set"),Agent_Role.None)

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
    testing.expect_value(t,agent_role(f,"task",coord,"fleet.edit"),Agent_Role.None)

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
