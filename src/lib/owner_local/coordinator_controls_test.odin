#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

// P-CS CC-A: the verified chain coordinator drives tasks without a lease.

cc_reason :: proc(f:^Fixture,reason:string) -> string {
    return encode(doc(map[string]string{"body_cipher"=cipher(f,reason)}))
}
cc_call :: proc(f:^Fixture,agent:Child,method,op,payload:string,task:="task") -> Result {
    return agent_run(f,agent,method,op,task,payload,agent_task_revision(f,task))
}
cc_revoke :: proc(f:^Fixture,reason,mode,disable:string) -> string {
    return encode(doc(map[string]string{"body_cipher"=cipher(f,reason),"mode"=mode,"disable_fleet"=disable}))
}
cc_cancel :: proc(f:^Fixture,reason,dependents:string) -> string {
    return encode(doc(map[string]string{"body_cipher"=cipher(f,reason),"dependents"=dependents}))
}
cc_heartbeat :: proc(f:^Fixture,op,cap:string) -> string {
    r:=lease_invoke(f,lease_request(f,lease_child(),"lease.heartbeat",op,"lease",cap,agent_task_revision(f,"task")),cap,lease_child())
    return r.code
}
cc_scalar :: proc(f:^Fixture,sql:string,args:..string) -> string {
    rows,ok:=query(f.store.db,sql,..args)
    if !ok || len(rows)!=1 do return "<none>"
    return rows[0][0]
}
cc_result :: proc(r:Result) -> json.Object {
    v,_:=json.parse_string(r.body,.JSON,true,context.temp_allocator)
    o,_:=v.(json.Object)
    return o
}

@(test)
cc_controls_open_only_to_the_verified_chain_coordinator :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    worker,reviewer,stranger:=lease_child(),lifecycle_reviewer(),agent_stranger()
    _=lifecycle_ready(t,f) // the worker holds a live lease: still no control authority
    verbs:=[14]string{"task.hold","task.release","task.cancel","task.reopen","task.resolve","merge.retry","task.delete","review.roles",
        "chain.complete","workflow.retry","workflow.cancel","lease.revoke","task.recheck","task.escalate"}
    for verb in verbs {
        testing.expectf(t,agent_command_method(verb),"%s is an agent command",verb)
        testing.expectf(t,agent_role(f,"task",coord,verb)==.Coordinator,"coordinator may %s",verb)
        testing.expectf(t,agent_role(f,"task",worker,verb)==.None,"worker refused %s",verb)
        testing.expectf(t,agent_role(f,"task",reviewer,verb)==.None,"reviewer refused %s",verb)
        testing.expectf(t,agent_role(f,"task",stranger,verb)==.None,"stranger refused %s",verb)
        restarted:=coord;restarted.epoch="new_epoch";restarted.run_count=2
        testing.expectf(t,agent_role(f,"task",restarted,verb)==.Coordinator,"a restarted coordinator keeps %s",verb)
        impostor:=coord;impostor.agent_id="other_agent"
        testing.expectf(t,agent_role(f,"task",impostor,verb)==.None,"another agent on the instance id is refused %s",verb)
    }
    // Still user-only: workflow gates, remote reservations, grants.
    for verb in ([6]string{"workflow.gate","fleet.reserve","grant.set","grant.recover","grant.revoke","workflow.define"}) {
        testing.expectf(t,!agent_command_method(verb),"%s stays off the agent allowlist",verb)
        testing.expectf(t,agent_role(f,"task",coord,verb)==.None,"%s stays human-only",verb)
    }
    // Fleet management is the bound coordinator's, never a worker's or reviewer's.
    for verb in ([3]string{"chain.member.set","fleet.policy.set","fleet.policy.read"}) {
        testing.expectf(t,agent_command_method(verb),"%s is an agent command",verb)
        testing.expectf(t,agent_role(f,"",coord,verb)==.Coordinator,"coordinator may %s",verb)
        for who in ([3]Child{worker,reviewer,stranger}) do testing.expectf(t,agent_role(f,"",who,verb)==.None,"%s refused %s",who.instance,verb)
    }
    // Admission: every new method refuses worker/reviewer/stranger tokens.
    reason:=cc_reason(f,"why")
    for verb in ([5]string{"task.hold","task.cancel","task.escalate","task.recheck","task.resolve"}) {
        for who in ([3]Child{worker,reviewer,stranger}) {
            testing.expectf(t,cc_call(f,who,verb,fmt.tprintf("%s_%s",who.instance,verb),reason).code=="invalid_scope","%s by %s refused",verb,who.instance)
        }
    }
    testing.expect_value(t,cc_call(f,worker,"lease.revoke","w_revoke",cc_revoke(f,"x","checkpoint","0")).code,"invalid_scope")
    testing.expect_value(t,agent_run(f,worker,"chain.complete","w_complete","",cc_reason(f,`{"expected_work_revision":"0","summary":"s"}`),agent_chain_rev(f)).code,"invalid_scope")
    testing.expect_value(t,agent_run(f,worker,"workflow.retry","w_retry","",cc_reason(f,`{"run_id":"run","execution":"1"}`),agent_chain_rev(f)).code,"invalid_scope")
    testing.expect_value(t,agent_run(f,worker,"workflow.cancel","w_wcancel","",cc_reason(f,`{"run_id":"run","execution":"1","reason":"r"}`),agent_chain_rev(f)).code,"invalid_scope")
    testing.expect_value(t,agent_run(f,coord,"workflow.gate","c_gate","",cc_reason(f,`{}`),agent_chain_rev(f)).code,"invalid_scope")
    rows,_:=query(f.store.db,"SELECT count(*) FROM local_handoffs WHERE kind!='lease.claim'")
    testing.expect_value(t,rows[0][0],"0")
    // A coordinator of another chain (lifetime binding) is foreign here.
    testing.expect(t,exec(f.store.db,"INSERT INTO task_chains VALUES('elsewhere','device','device','t','d',1); DROP TRIGGER local_member_chains_no_update; UPDATE local_member_chains SET chain_id='elsewhere' WHERE instance_id='coord_instance';"))
    testing.expect_value(t,cc_call(f,coord,"task.hold","foreign_hold",reason).code,"invalid_scope")
}

@(test)
cc_hold_release_cancel_reopen_resolve_require_reasons_and_audit_the_agent :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    cap:=lifecycle_ready(t,f)
    for verb in ([5]string{"task.hold","task.release","task.cancel","task.reopen","task.resolve"}) {
        testing.expectf(t,cc_call(f,coord,verb,fmt.tprintf("blank_%s",verb),cc_reason(f,"   ")).code=="invalid_content","%s requires a reason on the agent path",verb)
    }
    testing.expect_value(t,cc_call(f,coord,"task.hold","hold",cc_reason(f,"coordhold pause for rebase")).code,"ok")
    testing.expect_value(t,cc_scalar(f,"SELECT mode FROM local_controls"),"held")
    testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM runtime_intents WHERE kind='checkpoint'"),"1")
    testing.expect_value(t,cc_call(f,coord,"task.release","release",cc_reason(f,"rebased")).code,"ok")
    testing.expect_value(t,cc_call(f,coord,"task.cancel","cancel",cc_reason(f,"superseded by other work")).code,"ok")
    // The stop notice reaches the live holder on the agent path too (R2-7).
    testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM runtime_intents WHERE kind='stop'"),"1")
    testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM local_leases WHERE retired_seq IS NULL"),"0")
    testing.expect_value(t,cc_heartbeat(f,"after_cancel",cap),"invalid_scope")
    testing.expect_value(t,cc_call(f,coord,"task.reopen","reopen",cc_reason(f,"needed after all")).code,"ok")
    testing.expect_value(t,cc_scalar(f,"SELECT mode FROM local_controls"),"ready")
    // T1: a second reopen is refused and the cause is named.
    testing.expect_value(t,cc_call(f,coord,"task.reopen","reopen_again",cc_reason(f,"again")).code,"operation_conflict")
    cause:=reopen_refusal_cause(&f.store,"chain","task")
    testing.expectf(t,strings.contains(cause,"not cancelled, done or merge-blocked"),"reopen cause: %q",cause)
    // Audit: each control is a handoff by the coordinator and an agent event
    // carrying the reason.
    rows,_:=query(f.store.db,"SELECT kind,principal_id,summary FROM local_handoffs WHERE kind LIKE 'task.%' ORDER BY seq")
    testing.expect_value(t,len(rows),4)
    for row in rows do testing.expectf(t,row[1]=="coord_instance" && row[2]!="","control %s attributed to the coordinator with its reason",row[0])
    events,_:=query(f.store.db,"SELECT actor_kind,actor_id FROM local_events WHERE kind IN('task.hold','task.release','task.cancel','task.reopen')")
    testing.expect_value(t,len(events),4)
    for e in events do testing.expect(t,e[0]=="agent" && e[1]=="coord_instance")
    testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM local_events WHERE kind='task.hold' AND evidence_json LIKE '%coordhold pause for rebase%'"),"1")

    // A worker's own block (waiting on a human, e.g. an unavailable worktree)
    // is cleared by the coordinator's unblock.
    g:=fixture(t);defer destroy(g);lifecycle_seed(t,g)
    agent_seat_coordinator(t,g,coord)
    gcap:=lifecycle_ready(t,g)
    block:=`{"requirements_revision":"1","summary":"Workdir unavailable","next_steps":"fix repo","waiting_on":"human"}`
    testing.expect_value(t,lifecycle_call(g,lease_child(),"lease.block","block",block,gcap).code,"ok")
    testing.expect_value(t,cc_call(g,coord,"task.resolve","unblock",cc_reason(g,"repo repaired")).code,"ok")
    testing.expect_value(t,cc_scalar(g,"SELECT mode FROM local_controls"),"ready")
}

@(test)
cc_escalation_blocks_on_human_and_only_the_device_clears_it :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    cap:=lifecycle_ready(t,f)
    testing.expect_value(t,cc_call(f,coord,"task.escalate","blank",cc_reason(f," ")).code,"invalid_content")
    testing.expect_value(t,cc_call(f,lease_child(),"task.escalate","worker",cc_reason(f,"x")).code,"invalid_scope")
    testing.expect_value(t,cc_call(f,coord,"task.escalate","escalate",cc_reason(f,"needs a product decision")).code,"ok")
    rows,_:=query(f.store.db,"SELECT mode,waiting_on,reason FROM local_controls")
    testing.expect(t,len(rows)==1 && rows[0][0]=="blocked" && rows[0][1]=="human" && rows[0][2]=="needs a product decision")
    rows,_=query(f.store.db,"SELECT principal_id,waiting_on FROM local_handoffs WHERE kind='task.escalate'")
    testing.expect(t,len(rows)==1 && rows[0][0]=="coord_instance" && rows[0][1]=="human","the originator is recorded")
    // The holder is asked to checkpoint; its lease ends; dispatch stops.
    testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM local_leases WHERE retired_seq IS NULL"),"0")
    testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM runtime_intents WHERE kind='checkpoint'"),"1")
    testing.expect_value(t,cc_heartbeat(f,"after_escalate",cap),"invalid_scope")
    view,viewed:=attempt_view(&f.store,"chain","task")
    testing.expect(t,viewed && !view.incomplete && !view.live && view.last_release=="blocked","the escalation closes the attempt as blocked")
    // Agents cannot clear it by unblock, cancel or hold (R3-3).
    for verb in ([3]string{"task.resolve","task.cancel","task.hold"}) {
        testing.expectf(t,cc_call(f,coord,verb,fmt.tprintf("agent_%s",verb),cc_reason(f,"try to clear")).code=="invalid_scope","agent %s refused on a human escalation",verb)
    }
    testing.expect_value(t,cc_scalar(f,"SELECT mode FROM local_controls"),"blocked")
    // A device hold/release keeps it escalated; the device resolve clears it.
    testing.expect_value(t,control_call(f,"task.hold","device_hold",agent_task_revision(f,"task")).code,"ok")
    testing.expect_value(t,control_call(f,"task.release","device_release",agent_task_revision(f,"task")).code,"ok")
    rows,_=query(f.store.db,"SELECT mode,reason FROM local_controls")
    testing.expect(t,rows[0][0]=="blocked" && rows[0][1]=="needs a product decision")
    testing.expect_value(t,cc_call(f,coord,"task.resolve","agent_again",cc_reason(f,"still no")).code,"invalid_scope")
    testing.expect_value(t,control_call(f,"task.resolve","device_resolve",agent_task_revision(f,"task"),"decided: ship it").code,"ok")
    testing.expect_value(t,cc_scalar(f,"SELECT mode FROM local_controls"),"ready")
    // Not escalatable once in review/terminal or cancelled.
    testing.expect_value(t,cc_call(f,coord,"task.cancel","cancel",cc_reason(f,"drop")).code,"ok")
    testing.expect_value(t,cc_call(f,coord,"task.escalate","escalate_cancelled",cc_reason(f,"x")).code,"operation_conflict")
}

@(test)
cc_lease_revoke_ends_the_lease_without_cancelling_and_disables_the_fleet :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    sign:=Signer{&f.owner_priv,test_sign}
    testing.expect_value(t,cc_call(f,coord,"lease.revoke","nothing_live",cc_revoke(f,"x","checkpoint","0")).code,"operation_conflict")
    cap:=lifecycle_ready(t,f)
    testing.expect_value(t,cc_call(f,coord,"lease.revoke","bad_mode",cc_revoke(f,"x","kill","0")).code,"malformed")
    testing.expect_value(t,cc_call(f,coord,"lease.revoke","blank",cc_revoke(f," ","checkpoint","0")).code,"invalid_content")
    r:=cc_call(f,coord,"lease.revoke","revoke",cc_revoke(f,"worker stalled","checkpoint","0"))
    testing.expect_value(t,r.code,"ok")
    testing.expect_value(t,field(cc_result(r),"mode"),"checkpoint")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM local_leases WHERE retired_seq IS NULL),(SELECT state FROM lifecycle_state),(SELECT count(*) FROM local_controls),(SELECT count(*) FROM local_work_attempts),(SELECT count(*) FROM control_notices WHERE kind='checkpoint'),(SELECT enabled FROM local_fleet)")
    testing.expect(t,rows[0][0]=="0" && rows[0][1]=="ready" && rows[0][2]=="0" && rows[0][3]=="1" && rows[0][4]=="1" && rows[0][5]=="1","lease ended, task ready, attempts kept, holder notified")
    testing.expect_value(t,cc_heartbeat(f,"after_revoke",cap),"invalid_scope")
    testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM local_handoffs WHERE kind='lease.revoke' AND principal_id='coord_instance' AND summary='worker stalled'"),"1")
    // The same child may claim again (fleet still enabled).
    again,pick:=lease_next(&f.store,lease_child(),f.owner,1000,sign,"lease_again","op_again")
    testing.expectf(t,again.code=="ok" && pick.status=="granted","reclaim: %s %v",again.code,pick)
    view,viewed:=attempt_view(&f.store,"chain","task")
    testing.expect(t,viewed && !view.incomplete && view.attempt_no==2 && view.live,"the revoked attempt closed; the reclaim is a new attempt")
    // Reassign (R3-2): revoke with stop + disable_fleet; the child cannot reclaim.
    r=cc_call(f,coord,"lease.revoke","revoke_stop",cc_revoke(f,"reassigning","stop","1"))
    testing.expect_value(t,r.code,"ok")
    rows,_=query(f.store.db,"SELECT (SELECT enabled FROM local_fleet),(SELECT count(*) FROM runtime_intents WHERE kind='stop'),(SELECT count(*) FROM local_work_attempts)")
    testing.expect(t,rows[0][0]=="0" && rows[0][1]=="1" && rows[0][2]=="2")
    none,nothing:=lease_next(&f.store,lease_child(),f.owner,1000,sign,"lease_3","op_3")
    testing.expect(t,none.code=="ok" && nothing.status=="none","a disabled fleet row is not reclaimed")
    testing.expect_value(t,agent_role(f,"task",lease_child(),"lease.heartbeat"),Agent_Role.None)
}

@(test)
cc_lease_revoke_races_an_in_flight_submit_by_revision :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    submit:=`{"requirements_revision":"1","head":"","summary":"Checks pass"}`
    // Revoke wins: the submit signed against the same revision is refused.
    {
        f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
        coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
        cap:=lifecycle_ready(t,f)
        rev:=agent_task_revision(f,"task")
        testing.expect_value(t,agent_run(f,coord,"lease.revoke","revoke","task",cc_revoke(f,"stalled","checkpoint","0"),rev).code,"ok")
        late:=lifecycle_call(f,lease_child(),"lease.submit","late_submit",submit,cap,rev)
        testing.expect(t,late.code=="stale_revision" || late.code=="invalid_scope","a submit racing a committed revoke is refused")
        testing.expect_value(t,cc_scalar(f,"SELECT state FROM lifecycle_state"),"ready")
        testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM local_submissions"),"0")
    }
    // Submit wins: the revoke signed against the pre-submit revision is stale,
    // and a fresh revoke finds no live lease to end.
    {
        f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
        coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
        cap:=lifecycle_ready(t,f)
        rev:=agent_task_revision(f,"task")
        testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","submit",submit,cap,rev).code,"ok")
        testing.expect_value(t,agent_run(f,coord,"lease.revoke","late_revoke","task",cc_revoke(f,"stalled","checkpoint","0"),rev).code,"stale_revision")
        testing.expect_value(t,cc_call(f,coord,"lease.revoke","fresh_revoke",cc_revoke(f,"stalled","checkpoint","0")).code,"operation_conflict")
        testing.expect_value(t,cc_scalar(f,"SELECT state FROM lifecycle_state"),"in_review")
    }
}

@(test)
cc_cancel_invalidates_a_claimed_merge_intent :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f,true)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    cap:=lifecycle_ready(t,f)
    head:=strings.repeat("a",40,context.temp_allocator)
    p:=encode(doc(map[string]string{"requirements_revision"="1","head"=head,"summary"="Submitted"}))
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","submit",p,cap,"4",Source_Proof{head,true}).code,"ok")
    verdict:=lifecycle_verdict(head)
    opened:=lifecycle_call(f,lifecycle_reviewer(),"review.open","open",verdict,"","5")
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.post","review",verdict,result_cap(opened),"5").code,"ok")
    testing.expect_value(t,cc_scalar(f,"SELECT state FROM lifecycle_state"),"merge_pending")
    claims,ok:=intent_claim_due(&f.store,1000);testing.expect(t,ok)
    merge:Intent_Claim
    for claim in claims do if claim.kind=="merge" do merge=claim
    if !testing.expect(t,merge.id!="","the merge intent is claimed") do return
    testing.expect_value(t,cc_call(f,coord,"task.cancel","cancel",cc_reason(f,"wrong target branch")).code,"ok")
    testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM intent_invalidations WHERE intent_id=? AND principal_id='coord_instance'",merge.id),"1")
    testing.expect(t,!merge_claim_current(&f.store,merge),"the claimed merge is no longer current")
    testing.expect(t,!merge_prepare(&f.store,merge,head),"a cancelled task's claimed merge cannot prepare")
}

@(test)
cc_cancel_dependents_keep_drop_repoint_are_atomic :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    setup :: proc(t:^testing.T) -> ^Fixture {
        f:=fixture(t);lifecycle_seed(t,f)
        agent_seat_coordinator(t,f,agent_coordinator_child())
        for task in ([3]string{"dep1","dep2","alt"}) do agent_add_task(t,f,task)
        for task in ([2]string{"dep1","dep2"}) {
            p:=`{"prerequisite":"task","enabled":"1"}`
            testing.expect_value(t,invoke(f,command(f,"dependency.edit",fmt.tprintf("dep_%s",task),task,p,agent_task_revision(f,task)),p).code,"ok")
        }
        return f
    }
    edges :: proc(f:^Fixture) -> string {
        rows,_:=query(f.store.db,"SELECT task_id||'>'||prerequisite FROM local_dependencies ORDER BY task_id,prerequisite")
        out:=make([dynamic]string,context.temp_allocator)
        for r in rows do append(&out,r[0])
        return strings.join(out[:],",",context.temp_allocator)
    }
    coord:=agent_coordinator_child()
    {
        f:=setup(t);defer destroy(f)
        // Refusals leave everything as it was.
        testing.expect_value(t,cc_call(f,coord,"task.cancel","self",cc_cancel(f,"r","repoint:task")).code,"invalid_scope")
        testing.expect_value(t,cc_call(f,coord,"task.cancel","missing",cc_cancel(f,"r","repoint:nowhere")).code,"invalid_scope")
        testing.expect_value(t,cc_call(f,coord,"task.cancel","onto_dependent",cc_cancel(f,"r","repoint:dep1")).code,"operation_conflict")
        p:=`{"prerequisite":"dep1","enabled":"1"}`
        testing.expect_value(t,invoke(f,command(f,"dependency.edit","alt_dep","alt",p,agent_task_revision(f,"alt")),p).code,"ok")
        testing.expect_value(t,cc_call(f,coord,"task.cancel","cycle",cc_cancel(f,"r","repoint:alt")).code,"operation_conflict")
        testing.expect_value(t,edges(f),"alt>dep1,dep1>task,dep2>task")
        testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM local_controls"),"0")
        testing.expect_value(t,cc_call(f,coord,"task.cancel","bad_choice",cc_cancel(f,"r","move")).code,"malformed")
        // Repoint dep2 alone is fine once the cycle is gone.
        p=`{"prerequisite":"dep1","enabled":"0"}`
        testing.expect_value(t,invoke(f,command(f,"dependency.edit","alt_undep","alt",p,agent_task_revision(f,"alt")),p).code,"ok")
        before:=agent_task_revision(f,"dep1")
        r:=cc_call(f,coord,"task.cancel","repoint",cc_cancel(f,"replaced by alt","repoint:alt"))
        testing.expect_value(t,r.code,"ok")
        testing.expect_value(t,edges(f),"dep1>alt,dep2>alt")
        testing.expect_value(t,field(cc_result(r),"dependent_task_ids"),"dep1,dep2")
        testing.expect(t,agent_task_revision(f,"dep1")!=before,"dependents' revisions advance")
        testing.expect_value(t,cc_scalar(f,"SELECT mode FROM local_controls WHERE task_id='task'"),"cancelled")
    }
    {
        f:=setup(t);defer destroy(f)
        r:=cc_call(f,coord,"task.cancel","keep",cc_reason(f,"parked"))
        testing.expect_value(t,r.code,"ok")
        out:=cc_result(r)
        testing.expect(t,field(out,"dependents")=="keep" && field(out,"dependent_task_ids")=="dep1,dep2" && field(out,"warning")!="","keep warns that dependents stay blocked")
        testing.expect_value(t,edges(f),"dep1>task,dep2>task")
        testing.expect_value(t,cc_call(f,coord,"task.reopen","reopen",cc_reason(f,"back")).code,"ok")
        testing.expect_value(t,cc_call(f,coord,"task.cancel","drop",cc_cancel(f,"abandoned","drop")).code,"ok")
        testing.expect_value(t,edges(f),"")
        testing.expect(t,dependency_ready(&f.store,"chain","dep1"),"a dropped edge unblocks the dependent")
    }
}

@(test)
cc_cancel_refuses_language_workflow_tasks_but_not_legacy_stages :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    coord:=agent_coordinator_child()
    // Legacy-run stage tasks stay cancellable on both paths: nothing else can
    // stop them (workflow.cancel handles pending and language runs only).
    {
        f:=fixture(t);defer destroy(f);seed(t,f)
        agent_seat_coordinator(t,f,coord)
        testing.expect_value(t,advanced_call(f,"workflow.define","define",workflow_test_definition()).code,"ok")
        testing.expect_value(t,advanced_call(f,"workflow.run","run",`{"run_id":"run","workflow_id":"definition","version":"1"}`).code,"ok")
        first:=workflow_task_id("chain","run","1","first");second:=workflow_task_id("chain","run","1","second")
        testing.expect_value(t,cc_call(f,coord,"task.cancel","agent_cancel",cc_reason(f,"stop stage"),first).code,"ok")
        testing.expect_value(t,advanced_call(f,"task.cancel","device_cancel","stop stage",second).code,"ok")
        testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM local_controls WHERE mode='cancelled'"),"2")
    }
    // A coordinator retries a legacy run.
    {
        f:=fixture(t);defer destroy(f);seed(t,f)
        agent_seat_coordinator(t,f,coord)
        testing.expect_value(t,advanced_call(f,"workflow.define","define",workflow_test_definition()).code,"ok")
        testing.expect_value(t,advanced_call(f,"workflow.run","run",`{"run_id":"run","workflow_id":"definition","version":"1"}`).code,"ok")
        testing.expect_value(t,agent_run(f,coord,"workflow.retry","retry","",cc_reason(f,`{"run_id":"run","execution":"1"}`),agent_chain_rev(f)).code,"ok")
        testing.expect_value(t,cc_scalar(f,"SELECT current_execution FROM local_workflow_runs WHERE run_id='run'"),"2")
        testing.expect_value(t,cc_scalar(f,"SELECT actor_kind FROM local_events WHERE kind='workflow.retry'"),"agent")
    }
    // Language-run tasks are refused on both paths; workflow.cancel stops the run.
    {
        f:=fixture(t);defer destroy(f);seed(t,f)
        agent_seat_coordinator(t,f,coord)
        spec:=`{"kind":"workflow","v":1,"name":"single","stages":[{"key":"only","brief":{"goal":"Only","acceptance":["done"]}}]}`
        testing.expect_value(t,language_test_define(f,"single",spec).code,"ok")
        testing.expect_value(t,language_test_run(f,"single","lrun",`{}`).code,"ok")
        tasks:=language_tasks(f,"lrun","1","only")
        if !testing.expect_value(t,len(tasks),1) do return
        stage:=tasks[0][0]
        testing.expect_value(t,cc_call(f,coord,"task.cancel","agent_cancel",cc_reason(f,"stop stage"),stage).code,"operation_conflict")
        testing.expect_value(t,advanced_call(f,"task.cancel","device_cancel","stop stage",stage).code,"operation_conflict")
        testing.expect_value(t,agent_run(f,lease_child(),"workflow.cancel","w_cancel","",cc_reason(f,`{"run_id":"lrun","execution":"1","reason":"r"}`),agent_chain_rev(f)).code,"invalid_scope")
        testing.expect_value(t,agent_run(f,coord,"workflow.cancel","wcancel","",cc_reason(f,`{"run_id":"lrun","execution":"1","reason":"wrong inputs"}`),agent_chain_rev(f)).code,"ok")
        testing.expect_value(t,cc_scalar(f,"SELECT state FROM local_workflow_language_executions WHERE run_id='lrun'"),"cancelled")
    }
}

@(test)
cc_recheck_settles_a_missed_gate_and_records_nothing_when_unchanged :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    cap:=lifecycle_ready(t,f)
    events:=cc_scalar(f,"SELECT count(*) FROM local_events")
    r:=cc_call(f,coord,"task.recheck","ready_noop",cc_reason(f,"recheck"))
    testing.expect(t,r.code=="ok" && field(cc_result(r),"changed")=="0","a ready task: nothing to settle")
    testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM local_events"),events)
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","submit",`{"requirements_revision":"1","head":"","summary":"Done"}`,cap).code,"ok")
    r=cc_call(f,coord,"task.recheck","waiting",cc_reason(f,"recheck"))
    testing.expect(t,r.code=="ok" && field(cc_result(r),"changed")=="0" && field(cc_result(r),"state")=="in_review","it never approves")
    verdict:=lifecycle_verdict()
    opened:=lifecycle_call(f,lifecycle_reviewer(),"review.open","open",verdict,"","5")
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.post","review",verdict,result_cap(opened),"5").code,"ok")
    testing.expect_value(t,cc_scalar(f,"SELECT state FROM lifecycle_state"),"done")
    // Simulate a missed gate evaluation; recheck settles it.
    testing.expect(t,exec(f.store.db,"UPDATE lifecycle_state SET state='in_review'"))
    testing.expect_value(t,cc_call(f,lease_child(),"task.recheck","worker",cc_reason(f,"x")).code,"invalid_scope")
    r=cc_call(f,coord,"task.recheck","settle",cc_reason(f,"recheck"))
    testing.expect_value(t,r.code,"ok")
    out:=cc_result(r)
    testing.expect(t,field(out,"changed")=="1" && field(out,"state")=="done" && field(out,"previous_state")=="in_review")
    testing.expect_value(t,cc_scalar(f,"SELECT state FROM lifecycle_state"),"done")
    testing.expect_value(t,cc_scalar(f,"SELECT actor_kind FROM local_events WHERE kind='task.recheck'"),"agent")
}

@(test)
cc_delete_requires_reason_and_an_unstarted_task :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    agent_add_task(t,f,"fresh")
    testing.expect_value(t,cc_call(f,coord,"task.delete","no_reason",`{"protocol_version":"1"}`,"fresh").code,"invalid_content")
    with_reason:=encode(doc(map[string]string{"protocol_version"="1","body_cipher"=cipher(f,"duplicate of task")}))
    testing.expect_value(t,cc_call(f,lease_child(),"task.delete","worker_delete",with_reason,"fresh").code,"invalid_scope")
    testing.expect_value(t,cc_call(f,coord,"task.delete","started",with_reason,"task").code,"operation_conflict")
    testing.expect_value(t,cc_call(f,coord,"task.delete","delete",with_reason,"fresh").code,"ok")
    testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM tasks WHERE task_id='fresh'"),"0")
    testing.expect_value(t,cc_scalar(f,"SELECT actor_kind||':'||actor_id FROM local_events WHERE kind='task.delete'"),"agent:coord_instance")
    testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM local_events WHERE kind='task.delete' AND evidence_json LIKE '%duplicate of task%'"),"1")
    // The device form without a reason is unchanged.
    agent_add_task(t,f,"fresh2")
    p:=`{"protocol_version":"1"}`
    testing.expect_value(t,invoke(f,command(f,"task.delete","device_delete","fresh2",p,agent_task_revision(f,"fresh2")),p).code,"ok")
}

@(test)
cc_review_roles_only_for_chain_participants_and_merge_retry :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    children:=[1]Child{role_auditor()}
    roles:=func_roles(f)
    raw:=agent_command(f,coord,"review.roles","roles_outsider","task",roles,agent_task_revision(f,"task"))
    testing.expect_value(t,execute_agent(&f.store,raw,roles,coord,f.owner,1000,&f.kr,Signer{&f.owner_priv,test_sign},role_children=children[:]).code,"invalid_scope")
    // Once the auditor is a fleet worker of this chain it is a participant.
    agent_add_task(t,f,"audit_home");agent_bind(t,f,"audit_home",role_auditor())
    raw=agent_command(f,coord,"review.roles","roles","task",roles,agent_task_revision(f,"task"))
    testing.expect_value(t,execute_agent(&f.store,raw,roles,coord,f.owner,1000,&f.kr,Signer{&f.owner_priv,test_sign},role_children=children[:]).code,"ok")
    testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM local_role_pairs"),"2")
    raw=agent_command(f,lease_child(),"review.roles","worker_roles","task",roles,agent_task_revision(f,"task"))
    testing.expect_value(t,execute_agent(&f.store,raw,roles,lease_child(),f.owner,1000,&f.kr,Signer{&f.owner_priv,test_sign},role_children=children[:]).code,"invalid_scope")

    // merge.retry on a merge_blocked task.
    g:=fixture(t);defer destroy(g);lifecycle_seed(t,g,true)
    agent_seat_coordinator(t,g,coord)
    cap:=lifecycle_ready(t,g)
    head:=strings.repeat("a",40,context.temp_allocator)
    p:=encode(doc(map[string]string{"requirements_revision"="1","head"=head,"summary"="Submitted"}))
    testing.expect_value(t,lifecycle_call(g,lease_child(),"lease.submit","submit",p,cap,"4",Source_Proof{head,true}).code,"ok")
    verdict:=lifecycle_verdict(head)
    opened:=lifecycle_call(g,lifecycle_reviewer(),"review.open","open",verdict,"","5")
    testing.expect_value(t,lifecycle_call(g,lifecycle_reviewer(),"review.post","review",verdict,result_cap(opened),"5").code,"ok")
    claims,ok:=intent_claim_due(&g.store,1000);testing.expect(t,ok)
    for claim in claims do if claim.kind=="merge" do testing.expect(t,intent_result(&g.store,claim,false,"merge_conflict",1000))
    testing.expect_value(t,cc_scalar(g,"SELECT state FROM lifecycle_state"),"merge_blocked")
    retry :: proc(f:^Fixture,reason:string) -> string {
        return encode(doc(map[string]string{"attempt"="1","requirements_revision"="1","head"=strings.repeat("a",40,context.temp_allocator),"configuration_revision"="1","body_cipher"=cipher(f,reason)}))
    }
    testing.expect_value(t,cc_call(g,lease_child(),"merge.retry","worker_retry",retry(g,"x")).code,"invalid_scope")
    testing.expect_value(t,cc_call(g,coord,"merge.retry","blank_retry",retry(g," ")).code,"invalid_content")
    testing.expect_value(t,cc_call(g,coord,"merge.retry","retry",retry(g,"target repaired")).code,"ok")
    testing.expect_value(t,cc_scalar(g,"SELECT state FROM lifecycle_state"),"merge_pending")
}

func_roles :: proc(f:^Fixture) -> string {
    return encode(doc(map[string]string{"body_cipher"=cipher(f,role_test_config("1"))}))
}

@(test)
cc_recheck_and_chain_complete_never_bypass_the_user_gate :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);user_gate_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    if !user_gate_reviewed(t,f) do return
    testing.expect_value(t,user_gate_state(f),"in_review")
    // Only the independent reviewer approved: recheck leaves it waiting.
    r:=cc_call(f,coord,"task.recheck","recheck",cc_reason(f,"recheck"))
    testing.expect(t,r.code=="ok" && field(cc_result(r),"changed")=="0" && field(cc_result(r),"state")=="in_review")
    testing.expect_value(t,user_gate_state(f),"in_review")
    complete :: proc(f:^Fixture,agent:Child,op:string) -> Result {
        body:=encode(doc(map[string]string{"expected_work_revision"=work_revision(f),"summary"="All work done"}))
        return agent_run(f,agent,"chain.complete",op,"",cc_reason(f,body),agent_chain_rev(f))
    }
    testing.expect_value(t,complete(f,coord,"complete_early").code,"operation_conflict")
    testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM local_work_completions"),"0")
    // The user's device approval settles it; the coordinator then closes the
    // chain and the completion names the agent principal.
    p:=lifecycle_verdict()
    testing.expect_value(t,invoke(f,command(f,"review.post","human","task",p,agent_task_revision(f,"task")),p).code,"ok")
    testing.expect_value(t,user_gate_state(f),"done")
    testing.expect_value(t,complete(f,lease_child(),"worker_complete").code,"invalid_scope")
    testing.expect_value(t,complete(f,coord,"complete").code,"ok")
    testing.expect_value(t,cc_scalar(f,"SELECT actor_kind||':'||actor_id FROM local_work_completions"),"agent:coord_instance")
}

@(test)
cc_reassign_revoke_disable_fleet_then_fleet_edit_then_lifecycle_configure :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    sign:=Signer{&f.owner_priv,test_sign}
    _=lifecycle_ready(t,f)
    replacement:=Child{"instance2","epoch2",strings.repeat("e",64,context.temp_allocator),1,"author2"}
    // Both the replacement and the reviewer are already participants of this chain.
    agent_add_task(t,f,"zz_home");agent_bind(t,f,"zz_home",replacement)
    agent_add_task(t,f,"zz_review_home");agent_bind(t,f,"zz_review_home",lifecycle_reviewer())
    testing.expect_value(t,cc_call(f,coord,"lease.revoke","revoke",cc_revoke(f,"reassigning to instance2","stop","1")).code,"ok")
    fleet_rev:=cc_scalar(f,"SELECT configuration_revision FROM local_fleet WHERE task_id='task'")
    testing.expect_value(t,fleet_rev,"2")
    // fleet.edit names the new instance (strictly newer configuration).
    p:=encode(doc(map[string]string{"instance_id"=replacement.instance,"configuration_revision"="3","enabled"="1"}))
    raw:=agent_command(f,coord,"fleet.edit","reassign_fleet","task",p,agent_task_revision(f,"task"))
    testing.expect_value(t,execute_agent(&f.store,raw,p,coord,f.owner,1000,&f.kr,sign,fleet_child=replacement).code,"ok")
    // lifecycle.configure makes it the author.
    config,_,_:=lifecycle_config(&f.store,"chain","task")
    config["configuration_revision"]=json.String("2");config["author_agent_id"]=json.String("author2")
    cp:=encode(config)
    raw=agent_command(f,coord,"lifecycle.configure","reassign_config","task",cp,agent_task_revision(f,"task"))
    testing.expect_value(t,execute_agent(&f.store,raw,cp,coord,f.owner,1000,&f.kr,sign,proof=Lifecycle_Proof{replacement,lifecycle_reviewer(),true}).code,"ok")
    // The old child gets nothing; the new one claims the task.
    old,none:=lease_next(&f.store,lease_child(),f.owner,1000,sign,"lease_old","op_old")
    testing.expect(t,old.code=="ok" && none.status=="none","the revoked child cannot reclaim")
    r,pick:=lease_next(&f.store,replacement,f.owner,1000,sign,"lease_new","op_new")
    testing.expectf(t,r.code=="ok" && pick.status=="granted" && pick.task_id=="task","replacement claims: %s %v",r.code,pick)
}
