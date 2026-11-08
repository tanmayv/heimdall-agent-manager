#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

// P-CS CC-B: lifecycle.force_submit, task.complete --force, task.split and the
// REQ-CC-13 self-approval guard on owner chains.

cw_run :: proc(f:^Fixture,agent:Child,method,op,payload:string,task:="task",source:=Source_Proof{"",true},children:[]Child=nil) -> Result {
    return execute_agent(&f.store,agent_command(f,agent,method,op,task,payload,agent_task_revision(f,task)),payload,agent,f.owner,1000,&f.kr,Signer{&f.owner_priv,test_sign},role_children=children,source=source)
}
cw_submit :: proc(f:^Fixture,reason:string,override:="0",head:="") -> string {
    return encode(doc(map[string]string{"requirements_revision"="1","head"=head,"summary"="coordinator submitted","override_ack"=override,"body_cipher"=cipher(f,reason)}))
}
cw_complete :: proc(f:^Fixture,reason,attempt:string,head:="",force:="1") -> string {
    return encode(doc(map[string]string{"attempt"=attempt,"head"=head,"force"=force,"body_cipher"=cipher(f,reason)}))
}
cw_split :: proc(f:^Fixture,body:string) -> string {
    return encode(doc(map[string]string{"body_cipher"=cipher(f,body)}))
}
cw_handoff :: proc(t:^testing.T,f:^Fixture,cap:string) {
    p:=`{"requirements_revision":"1","summary":"pausing","next_steps":"continue"}`
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.handoff","handoff",p,cap,agent_task_revision(f,"task")).code,"ok")
}
cw_worker_submit :: proc(t:^testing.T,f:^Fixture,cap:string,head:="") -> bool {
    p:=encode(doc(map[string]string{"requirements_revision"="1","head"=head,"summary"="Checks pass"}))
    return testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","submit",p,cap,agent_task_revision(f,"task"),Source_Proof{head,true}).code,"ok")
}
cw_review :: proc(t:^testing.T,f:^Fixture,verdict:string,head:="") -> bool {
    p:=lifecycle_verdict(head)
    if verdict!="approve" {
        o:=cc_result(Result{body=p});o["verdict"]=json.String(verdict);p=encode(o)
    }
    opened:=lifecycle_call(f,lifecycle_reviewer(),"review.open",fmt.tprintf("open_%s",verdict),p,"",agent_task_revision(f,"task"))
    if !testing.expect_value(t,opened.code,"ok") do return false
    return testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.post",fmt.tprintf("post_%s",verdict),p,result_cap(opened),agent_task_revision(f,"task")).code,"ok")
}
cw_edges :: proc(f:^Fixture) -> string {
    rows,_:=query(f.store.db,"SELECT task_id||'>'||prerequisite FROM local_dependencies ORDER BY task_id,prerequisite")
    out:=make([dynamic]string,context.temp_allocator)
    for r in rows do append(&out,r[0])
    return strings.join(out[:],",",context.temp_allocator)
}
cw_depend :: proc(t:^testing.T,f:^Fixture,task,prerequisite:string) {
    p:=fmt.tprintf(`{{"prerequisite":"%s","enabled":"1"}}`,prerequisite)
    testing.expect_value(t,invoke(f,command(f,"dependency.edit",fmt.tprintf("dep_%s_%s",task,prerequisite),task,p,agent_task_revision(f,task)),p).code,"ok")
}

// ---- lifecycle.force_submit -------------------------------------------------

@(test)
cw_force_submit_binds_the_last_retired_lease_and_feeds_the_review :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    cap:=lifecycle_ready(t,f);if cap=="" do return
    cw_handoff(t,f,cap)
    for who in ([3]Child{lease_child(),lifecycle_reviewer(),agent_stranger()}) {
        testing.expectf(t,cw_run(f,who,"lifecycle.force_submit",fmt.tprintf("w_%s",who.instance),cw_submit(f,"why")).code=="invalid_scope","%s refused",who.instance)
    }
    testing.expect_value(t,cw_run(f,coord,"lifecycle.force_submit","blank",cw_submit(f,"  ")).code,"invalid_content")
    // The head is the Bridge observation, never the caller's.
    testing.expect_value(t,cw_run(f,coord,"lifecycle.force_submit","unobserved",cw_submit(f,"why"),source=Source_Proof{}).code,"invalid_scope")
    head:=strings.repeat("e",40,context.temp_allocator)
    testing.expect_value(t,cw_run(f,coord,"lifecycle.force_submit","forged",cw_submit(f,"why",head=head),source=Source_Proof{head,true}).code,"invalid_scope") // merge_policy none has no head
    testing.expect_value(t,cc_scalar(f,"SELECT state FROM lifecycle_state"),"ready")
    r:=cw_run(f,coord,"lifecycle.force_submit","submit",cw_submit(f,"worker went quiet after committing"))
    if !testing.expect_value(t,r.code,"ok") do return
    out:=cc_result(r)
    testing.expect(t,field(out,"state")=="in_review" && field(out,"attempt")=="1" && field(out,"lease_id")=="lease" && field(out,"author_agent_id")=="author" &&
        field(out,"submitted_by")=="coord_instance" && field(out,"override_ack")=="0" && field(out,"live_lease_revoked")=="0",r.body)
    rows,_:=query(f.store.db,"SELECT lease_id,author_agent_id,principal_id,summary FROM local_submissions")
    testing.expect_value(t,encode(rows),encode([1][4]string{{"lease","author","coord_instance","coordinator submitted"}}))
    testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM local_handoffs WHERE kind='lifecycle.force_submit' AND principal_id='coord_instance' AND lease_id='lease' AND summary='worker went quiet after committing'"),"1")
    testing.expect_value(t,cc_scalar(f,"SELECT actor_kind||':'||actor_id FROM local_events WHERE kind='lifecycle.force_submit'"),"agent:coord_instance")
    view,viewed:=attempt_view(&f.store,"chain","task")
    testing.expect(t,viewed && !view.incomplete && view.in_review && view.last_release=="submitted","the attempt folds as submitted")
    testing.expect_value(t,cw_run(f,coord,"lifecycle.force_submit","again",cw_submit(f,"again")).code,"operation_conflict")
    // The independent reviewer reviews the coordinator-submitted attempt.
    if !cw_review(t,f,"approve") do return
    testing.expect_value(t,cc_scalar(f,"SELECT state FROM lifecycle_state"),"done")
}

@(test)
cw_force_submit_edge_cases :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    coord:=agent_coordinator_child()
    // Never leased: nothing to submit (R3-4).
    {
        f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);agent_seat_coordinator(t,f,coord)
        testing.expect_value(t,cw_run(f,coord,"lifecycle.force_submit","never",cw_submit(f,"x","1")).code,"operation_conflict")
    }
    // No acknowledgement on the last lease: refused unless overridden (audited).
    {
        f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);agent_seat_coordinator(t,f,coord)
        r:=lease_invoke(f,lease_request(f,lease_child(),"lease.claim","claim","lease","","4"),"",lease_child())
        if !testing.expect_value(t,r.code,"ok") do return
        cw_handoff(t,f,result_cap(r))
        testing.expect_value(t,cw_run(f,coord,"lifecycle.force_submit","unacked",cw_submit(f,"x")).code,"stale_revision")
        testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM local_submissions"),"0")
        ok:=cw_run(f,coord,"lifecycle.force_submit","override",cw_submit(f,"read the brief with the worker myself","1"))
        testing.expect_value(t,ok.code,"ok")
        testing.expect_value(t,field(cc_result(ok),"override_ack"),"1")
        testing.expect_value(t,cc_scalar(f,"SELECT next_steps FROM local_handoffs WHERE kind='lifecycle.force_submit'"),"requirements acknowledgement overridden")
    }
    // A live lease is revoked first (stop) and becomes the bound lease.
    {
        f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);agent_seat_coordinator(t,f,coord)
        cap:=lifecycle_ready(t,f)
        r:=cw_run(f,coord,"lifecycle.force_submit","live",cw_submit(f,"submit what is committed"))
        if !testing.expect_value(t,r.code,"ok") do return
        testing.expect_value(t,field(cc_result(r),"live_lease_revoked"),"1")
        testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM local_leases WHERE retired_seq IS NULL"),"0")
        testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM runtime_intents WHERE kind='stop'"),"1")
        testing.expect_value(t,cc_heartbeat(f,"after_force",cap),"invalid_scope")
        testing.expect_value(t,cc_scalar(f,"SELECT lease_id FROM local_submissions"),"lease")
    }
    // Held: not control_ready.
    {
        f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);agent_seat_coordinator(t,f,coord)
        cw_handoff(t,f,lifecycle_ready(t,f))
        testing.expect_value(t,cc_call(f,coord,"task.hold","hold",cc_reason(f,"pause")).code,"ok")
        testing.expect_value(t,cw_run(f,coord,"lifecycle.force_submit","held",cw_submit(f,"x")).code,"operation_conflict")
    }
    // The last lease already submitted (changes requested): nothing new to bind.
    {
        f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);agent_seat_coordinator(t,f,coord)
        cap:=lifecycle_ready(t,f)
        if !cw_worker_submit(t,f,cap) || !cw_review(t,f,"request_changes") do return
        testing.expect_value(t,cc_scalar(f,"SELECT state FROM lifecycle_state"),"ready")
        testing.expect_value(t,cw_run(f,coord,"lifecycle.force_submit","resubmit",cw_submit(f,"x","1")).code,"operation_conflict")
    }
}

// ---- task.complete --force ---------------------------------------------------

@(test)
cw_force_done_skips_only_the_independent_review :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    cap:=lifecycle_ready(t,f)
    if !cw_worker_submit(t,f,cap) do return
    for who in ([3]Child{lease_child(),lifecycle_reviewer(),agent_stranger()}) {
        testing.expectf(t,cw_run(f,who,"task.complete",fmt.tprintf("w_%s",who.instance),cw_complete(f,"why","1")).code=="invalid_scope","%s refused",who.instance)
    }
    testing.expect_value(t,cw_run(f,coord,"task.complete","no_force",cw_complete(f,"why","1",force="0")).code,"invalid_content")
    testing.expect_value(t,cw_run(f,coord,"task.complete","blank",cw_complete(f," ","1")).code,"invalid_content")
    testing.expect_value(t,cw_run(f,coord,"task.complete","stale",cw_complete(f,"why","2")).code,"stale_revision")
    r:=cw_run(f,coord,"task.complete","done",cw_complete(f,"reviewer agent is down; checks verified by hand","1"))
    if !testing.expect_value(t,r.code,"ok") do return
    out:=cc_result(r)
    testing.expect(t,field(out,"state")=="done" && field(out,"forced")=="1" && field(out,"skipped_gates")=="independent_review" && field(out,"notify")=="user",r.body)
    testing.expect_value(t,cc_scalar(f,"SELECT state FROM lifecycle_state"),"done")
    testing.expect_value(t,cc_scalar(f,"SELECT next_steps FROM local_handoffs WHERE kind='task.complete' AND principal_id='coord_instance'"),"forced by coordinator; skipped gates: independent_review")
    testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM local_events WHERE kind='task.complete' AND actor_kind='agent' AND evidence_json LIKE '%skipped_gates%'"),"1")
    view,viewed:=attempt_view(&f.store,"chain","task")
    testing.expect(t,viewed && !view.incomplete && !view.in_review,"the attempt is settled")
    testing.expect_value(t,cw_run(f,coord,"task.complete","again",cw_complete(f,"again","1")).code,"operation_conflict")
}

@(test)
cw_force_done_policy_is_device_signed_and_default_on :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    if !cw_worker_submit(t,f,lifecycle_ready(t,f)) do return
    enabled,_:=force_done_enabled(&f.store,"chain")
    testing.expect(t,enabled,"default on")
    off:=`{"policy":"coordinator_force_done","value":"0"}`
    testing.expect_value(t,agent_run(f,coord,"chain.policy.set","agent_off","",off,agent_chain_rev(f)).code,"invalid_scope")
    testing.expect_value(t,agent_run(f,coord,"chain.policy.set","agent_bad","",`{"policy":"other","value":"0"}`,agent_chain_rev(f)).code,"invalid_scope")
    testing.expect_value(t,invoke(f,command(f,"chain.policy.set","device_off","",off,agent_chain_rev(f)),off).code,"ok")
    testing.expect_value(t,cw_run(f,coord,"task.complete","policy_off",cw_complete(f,"why","1")).code,"invalid_scope")
    code,why:=complete_refusal_locked(&f.store,"chain","task",coord)
    testing.expect(t,code=="invalid_scope" && strings.contains(why,"coordinator_force_done"),why)
    on:=`{"policy":"coordinator_force_done","value":"1"}`
    testing.expect_value(t,invoke(f,command(f,"chain.policy.set","device_on","",on,agent_chain_rev(f)),on).code,"ok")
    testing.expect_value(t,cw_run(f,coord,"task.complete","policy_on",cw_complete(f,"why","1")).code,"ok")
    testing.expect_value(t,cc_scalar(f,"SELECT group_concat(value) FROM (SELECT value FROM local_chain_policies ORDER BY accepted_seq)"),"0,1")
    testing.expect(t,!exec(f.store.db,"UPDATE local_chain_policies SET value='1'"),"policy history is immutable")
}

@(test)
cw_force_done_never_skips_a_user_approval_source :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    coord:=agent_coordinator_child()
    // Brief source: refused until the user's device approves; then only the
    // independent review is skipped.
    {
        f:=fixture(t);defer destroy(f);user_gate_seed(t,f);agent_seat_coordinator(t,f,coord)
        if !cw_worker_submit(t,f,lifecycle_ready(t,f)) do return
        testing.expect_value(t,cw_run(f,coord,"task.complete","brief_gate",cw_complete(f,"why","1")).code,"invalid_scope")
        // A coordinator relay is not the user.
        p:=lifecycle_verdict()
        testing.expect_value(t,agent_run(f,coord,"review.post","relay","task",p,agent_task_revision(f,"task")).code,"ok")
        testing.expect_value(t,cw_run(f,coord,"task.complete","after_relay",cw_complete(f,"why","1")).code,"invalid_scope")
        testing.expect_value(t,invoke(f,command(f,"review.post","human","task",p,agent_task_revision(f,"task")),p).code,"ok")
        testing.expect_value(t,user_gate_state(f),"in_review") // still owes the independent review
        r:=cw_run(f,coord,"task.complete","after_user",cw_complete(f,"reviewer unavailable","1"))
        testing.expect_value(t,r.code,"ok")
        testing.expect_value(t,field(cc_result(r),"skipped_gates"),"independent_review")
    }
    // Submission source: the submitted brief was gated even if the current
    // brief no longer is.
    {
        f:=fixture(t);defer destroy(f);user_gate_seed(t,f);agent_seat_coordinator(t,f,coord)
        if !cw_worker_submit(t,f,lifecycle_ready(t,f)) do return
        testing.expect(t,exec(f.store.db,`INSERT INTO task_requirements VALUES('chain','task',2,'{"goal":"Complete scoped work","acceptance":["Tests pass"]}','','device','req2')`))
        brief,_:=requirements_user_approval(&f.store,"chain","task")
        testing.expect(t,!brief,"the current brief is not gated")
        testing.expect_value(t,cw_run(f,coord,"task.complete","submission_gate",cw_complete(f,"why","1")).code,"invalid_scope")
    }
    // Role configuration source.
    {
        f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);agent_seat_coordinator(t,f,coord)
        if role_test_ready(t,f)=="" do return
        testing.expect_value(t,cw_run(f,coord,"task.complete","role_gate",cw_complete(f,"why","1")).code,"invalid_scope")
        code,why:=complete_refusal_locked(&f.store,"chain","task",coord)
        testing.expect(t,code=="invalid_scope" && strings.contains(why,"user's approval"),why)
    }
    // Workflow-language item source (and the task is workflow-generated).
    {
        f:=fixture(t);defer destroy(f);seed(t,f);agent_seat_coordinator(t,f,coord)
        spec:=`{"kind":"workflow","v":1,"name":"gated","stages":[{"key":"only","requires_user_approval":true,"brief":{"goal":"Only","acceptance":["done"]}}]}`
        testing.expect_value(t,language_test_define(f,"gated",spec).code,"ok")
        testing.expect_value(t,language_test_run(f,"gated","grun",`{}`).code,"ok")
        tasks:=language_tasks(f,"grun","1","only")
        if !testing.expect_value(t,len(tasks),1) do return
        required,_,ok:=complete_user_gate(&f.store,"chain",tasks[0][0],"0")
        testing.expect(t,ok && required,"a language item flag is a user-approval source")
        testing.expect_value(t,cw_run(f,coord,"task.complete","language",cw_complete(f,"why","0"),tasks[0][0]).code,"operation_conflict")
    }
}

@(test)
cw_force_done_git_requires_a_submitted_head_and_merges_through_the_intent :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f,true)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    cap:=lifecycle_ready(t,f)
    // Ready (no submission) with merge_policy git: refused.
    testing.expect_value(t,cw_run(f,coord,"task.complete","no_head",cw_complete(f,"why","0")).code,"operation_conflict")
    code,why:=complete_refusal_locked(&f.store,"chain","task",coord)
    testing.expect(t,code=="operation_conflict",why)
    head:=strings.repeat("a",40,context.temp_allocator)
    if !cw_worker_submit(t,f,cap,head) do return
    testing.expect_value(t,cw_run(f,coord,"task.complete","wrong_head",cw_complete(f,"why","1",strings.repeat("f",40,context.temp_allocator))).code,"stale_revision")
    r:=cw_run(f,coord,"task.complete","merge",cw_complete(f,"verified by hand","1",head))
    if !testing.expect_value(t,r.code,"ok") do return
    testing.expect_value(t,cc_scalar(f,"SELECT state FROM lifecycle_state"),"merge_pending")
    testing.expect_value(t,cc_scalar(f,"SELECT json_extract(exact_fence_json,'$.head')||':'||json_extract(exact_fence_json,'$.attempt') FROM runtime_intents WHERE kind='merge'"),fmt.tprintf("%s:1",head))
}

// ---- workflow-generated refusals ----------------------------------------------

@(test)
cw_work_operations_refuse_workflow_generated_tasks :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    coord:=agent_coordinator_child()
    split:=`{"reason":"r","children":[{"task_id":"wf_child","title":"child"}]}`
    {
        f:=fixture(t);defer destroy(f);seed(t,f);agent_seat_coordinator(t,f,coord)
        spec:=`{"kind":"workflow","v":1,"name":"single","stages":[{"key":"only","brief":{"goal":"Only","acceptance":["done"]}}]}`
        testing.expect_value(t,language_test_define(f,"single",spec).code,"ok")
        testing.expect_value(t,language_test_run(f,"single","lrun",`{}`).code,"ok")
        tasks:=language_tasks(f,"lrun","1","only")
        if !testing.expect_value(t,len(tasks),1) do return
        stage:=tasks[0][0]
        testing.expect_value(t,cw_run(f,coord,"lifecycle.force_submit","fs",cw_submit(f,"x","1"),stage).code,"operation_conflict")
        testing.expect_value(t,cw_run(f,coord,"task.split","split",cw_split(f,split),stage).code,"operation_conflict")
        p:=cw_split(f,split)
        testing.expect_value(t,invoke(f,command(f,"task.split","device_split",stage,p,agent_task_revision(f,stage)),p).code,"operation_conflict")
    }
    {
        f:=fixture(t);defer destroy(f);seed(t,f);agent_seat_coordinator(t,f,coord)
        testing.expect_value(t,advanced_call(f,"workflow.define","define",workflow_test_definition()).code,"ok")
        testing.expect_value(t,advanced_call(f,"workflow.run","run",`{"run_id":"run","workflow_id":"definition","version":"1"}`).code,"ok")
        first:=workflow_task_id("chain","run","1","first")
        testing.expect_value(t,cw_run(f,coord,"task.split","legacy_split",cw_split(f,split),first).code,"operation_conflict")
        testing.expect_value(t,cw_run(f,coord,"task.complete","legacy_done",cw_complete(f,"x","0"),first).code,"operation_conflict")
        testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM tasks WHERE task_id='wf_child'"),"0")
    }
}

// ---- task.split ----------------------------------------------------------------

cw_split_setup :: proc(t:^testing.T,git:=false) -> ^Fixture {
    f:=fixture(t);lifecycle_seed(t,f,git)
    agent_seat_coordinator(t,f,agent_coordinator_child())
    for task in ([3]string{"dep1","dep2","pre"}) do agent_add_task(t,f,task)
    cw_depend(t,f,"dep1","task");cw_depend(t,f,"dep2","task")
    return f
}

@(test)
cw_split_creates_children_links_and_repoints_dependents_atomically :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=cw_split_setup(t,true);defer destroy(f)
    coord:=agent_coordinator_child()
    cw_depend(t,f,"task","pre")
    body:=`{"reason":"too big for one review","dependents":"all","children":[
      {"task_id":"c1","title":"First half"},
      {"task_id":"c2","title":"Second half","body":"the rest","brief":{"goal":"Second half","acceptance":["Second passes"]}}]}`
    for who in ([3]Child{lease_child(),lifecycle_reviewer(),agent_stranger()}) {
        testing.expectf(t,cw_run(f,who,"task.split",fmt.tprintf("w_%s",who.instance),cw_split(f,body)).code=="invalid_scope","%s refused",who.instance)
    }
    testing.expect_value(t,cw_run(f,coord,"task.split","no_reason",cw_split(f,`{"children":[{"task_id":"c1","title":"x"}]}`)).code,"invalid_content")
    r:=cw_run(f,coord,"task.split","split",cw_split(f,body))
    if !testing.expect_value(t,r.code,"ok") do return
    testing.expect_value(t,field(cc_result(r),"children"),"c1,c2")
    rows,_:=query(f.store.db,"SELECT task_id,title,body FROM tasks WHERE task_id IN('c1','c2') ORDER BY task_id")
    testing.expect_value(t,encode(rows),encode([2][3]string{{"c1","First half",""},{"c2","Second half","the rest"}}))
    // Briefs: copied from the original unless overridden.
    testing.expect_value(t,cc_scalar(f,"SELECT json_extract(brief_json,'$.goal') FROM task_requirements WHERE task_id='c1'"),"Complete scoped work")
    testing.expect_value(t,cc_scalar(f,"SELECT json_extract(brief_json,'$.goal') FROM task_requirements WHERE task_id='c2'"),"Second half")
    // Fleet and lifecycle copied, with the child's own worktree and branch.
    testing.expect_value(t,cc_scalar(f,"SELECT group_concat(instance_id||':'||enabled) FROM (SELECT * FROM local_fleet WHERE task_id IN('c1','c2') ORDER BY task_id)"),"instance:1,instance:1")
    testing.expect_value(t,cc_scalar(f,"SELECT json_extract(config_json,'$.worktree')||' '||json_extract(config_json,'$.source_branch')||' '||json_extract(config_json,'$.author_agent_id') FROM lifecycle_configs WHERE task_id='c1'"),"/repo/.heimdall/worktrees/c1 heimdall/c1 author")
    testing.expect_value(t,cc_scalar(f,"SELECT group_concat(state) FROM lifecycle_state WHERE task_id IN('c1','c2')"),"ready,ready")
    // Dependencies: children inherit prerequisites; dependents wait on all children.
    testing.expect_value(t,cw_edges(f),"c1>pre,c2>pre,dep1>c1,dep1>c2,dep2>c1,dep2>c2,task>pre")
    // Links both ways.
    testing.expect_value(t,cc_scalar(f,"SELECT group_concat(task_id||' '||relation||' '||other_task_id,';') FROM (SELECT * FROM local_task_links ORDER BY relation,ordinal,task_id)"),
        "c1 split_from task;c2 split_from task;task split_into c1;task split_into c2")
    // The original is cancelled with the reason.
    testing.expect_value(t,cc_scalar(f,"SELECT mode||'|'||reason FROM local_controls WHERE task_id='task'"),"cancelled|split into c1, c2: too big for one review")
    testing.expect_value(t,cc_scalar(f,"SELECT group_concat(destination_bridge) FROM (SELECT destination_bridge FROM runtime_intents WHERE kind='registry' AND operation_id='split' ORDER BY destination_bridge)"),"c1,c2")
    testing.expect_value(t,cc_scalar(f,"SELECT actor_kind||':'||actor_id FROM local_events WHERE kind='task.split'"),"agent:coord_instance")
    view,viewed:=attempt_view(&f.store,"chain","task")
    testing.expect(t,viewed && !view.incomplete && !view.live,"the original is closed")
    testing.expect_value(t,cw_run(f,coord,"task.split","again",cw_split(f,`{"reason":"r","children":[{"task_id":"c3","title":"x"}]}`)).code,"operation_conflict")
}

@(test)
cw_split_dependents_last_and_map_and_children_are_claimable :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    coord:=agent_coordinator_child()
    {
        f:=cw_split_setup(t);defer destroy(f)
        cap:=lifecycle_ready(t,f)
        r:=cw_run(f,coord,"task.split","last",cw_split(f,`{"reason":"sequence","dependents":"last","children":[{"task_id":"c1","title":"a"},{"task_id":"c2","title":"b"}]}`))
        testing.expect_value(t,r.code,"ok")
        testing.expect_value(t,cw_edges(f),"dep1>c2,dep2>c2")
        // The original's live holder was asked to checkpoint; its lease ended.
        testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM local_leases WHERE retired_seq IS NULL"),"0")
        testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM runtime_intents WHERE kind='checkpoint'"),"1")
        testing.expect_value(t,cc_heartbeat(f,"after_split",cap),"invalid_scope")
        view,viewed:=attempt_view(&f.store,"chain","task")
        testing.expect(t,viewed && !view.incomplete && !view.live,"the original's attempt is closed")
        // The original's worker may claim a child (fleet copied).
        pick_r,pick:=lease_next(&f.store,lease_child(),f.owner,1000,Signer{&f.owner_priv,test_sign},"lease_child","op_child")
        testing.expectf(t,pick_r.code=="ok" && pick.status=="granted" && (pick.task_id=="c1" || pick.task_id=="c2"),"child claim: %s %v",pick_r.code,pick)
    }
    {
        f:=cw_split_setup(t);defer destroy(f)
        children:=`"children":[{"task_id":"c1","title":"a"},{"task_id":"c2","title":"b"}]`
        // The map must name every dependent with known child ids.
        for bad in ([3]string{`{"dep1":["c1"]}`,`{"dep1":["c1"],"dep2":["nope"]}`,`{"dep1":["c1"],"dep2":["c2"],"pre":["c1"]}`}) {
            testing.expect_value(t,cw_run(f,coord,"task.split",fmt.tprintf("bad_%d",len(bad)),cw_split(f,fmt.tprintf(`{{"reason":"r","dependents":"map","map":%s,%s}}`,bad,children))).code,"invalid_content")
        }
        testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM tasks WHERE task_id IN('c1','c2')"),"0")
        r:=cw_run(f,coord,"task.split","map",cw_split(f,fmt.tprintf(`{{"reason":"r","dependents":"map","map":{{"dep1":["c1"],"dep2":["c1","c2"]}},%s}}`,children)))
        testing.expect_value(t,r.code,"ok")
        testing.expect_value(t,cw_edges(f),"dep1>c1,dep2>c1,dep2>c2")
    }
}

@(test)
cw_split_refused_states_and_rollback_on_mid_way_failure :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    coord:=agent_coordinator_child()
    one:=`{"reason":"r","children":[{"task_id":"c1","title":"a"}]}`
    // Rollback: the second child collides with an existing task after the
    // first child, its links and fleet rows were written.
    {
        f:=cw_split_setup(t);defer destroy(f)
        before_edges:=cw_edges(f)
        before_seq:=cc_scalar(f,"SELECT commit_seq FROM runtime_database")
        r:=cw_run(f,coord,"task.split","collide",cw_split(f,`{"reason":"r","children":[{"task_id":"c1","title":"a"},{"task_id":"dep1","title":"b"}]}`))
        testing.expect_value(t,r.code,"operation_conflict")
        testing.expect_value(t,cc_scalar(f,"SELECT (SELECT count(*) FROM tasks WHERE task_id='c1')+(SELECT count(*) FROM local_task_links)+(SELECT count(*) FROM local_fleet WHERE task_id='c1')+(SELECT count(*) FROM lifecycle_configs WHERE task_id='c1')+(SELECT count(*) FROM task_requirements WHERE task_id='c1')+(SELECT count(*) FROM local_controls)+(SELECT count(*) FROM command_receipts WHERE operation_id='collide')+(SELECT count(*) FROM local_events WHERE kind='task.split')"),"0")
        testing.expect_value(t,cw_edges(f),before_edges)
        testing.expect_value(t,cc_scalar(f,"SELECT commit_seq FROM runtime_database"),before_seq)
        // An invalid dependents map is found after the children, links and
        // fleet rows were written: also rolled back.
        bad:=`{"reason":"r","dependents":"map","map":{"dep1":["c1"]},"children":[{"task_id":"c1","title":"a"}]}`
        testing.expect_value(t,cw_run(f,coord,"task.split","bad_map",cw_split(f,bad)).code,"invalid_content")
        testing.expect_value(t,cc_scalar(f,"SELECT (SELECT count(*) FROM tasks WHERE task_id='c1')+(SELECT count(*) FROM local_task_links)+(SELECT count(*) FROM local_controls)"),"0")
        testing.expect_value(t,cw_edges(f),before_edges)
    }
    // Refused while in review, merging, done or cancelled.
    {
        f:=cw_split_setup(t);defer destroy(f)
        cap:=lifecycle_ready(t,f)
        if !cw_worker_submit(t,f,cap) do return
        testing.expect_value(t,cw_run(f,coord,"task.split","in_review",cw_split(f,one)).code,"operation_conflict")
        if !cw_review(t,f,"approve") do return
        testing.expect_value(t,cw_run(f,coord,"task.split","done",cw_split(f,one)).code,"operation_conflict")
    }
    {
        f:=cw_split_setup(t,true);defer destroy(f)
        head:=strings.repeat("a",40,context.temp_allocator)
        if !cw_worker_submit(t,f,lifecycle_ready(t,f),head) || !cw_review(t,f,"approve",head) do return
        testing.expect_value(t,cc_scalar(f,"SELECT state FROM lifecycle_state WHERE task_id='task'"),"merge_pending")
        testing.expect_value(t,cw_run(f,coord,"task.split","merging",cw_split(f,one)).code,"operation_conflict")
    }
    {
        f:=cw_split_setup(t);defer destroy(f)
        testing.expect_value(t,cc_call(f,coord,"task.cancel","cancel",cc_reason(f,"gone")).code,"ok")
        testing.expect_value(t,cw_run(f,coord,"task.split","cancelled",cw_split(f,one)).code,"operation_conflict")
        testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM tasks WHERE task_id='c1'"),"0")
    }
}

@(test)
cw_split_ratchet_keeps_the_user_gate_on_children :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    coord:=agent_coordinator_child()
    // Brief-gated original.
    {
        f:=fixture(t);defer destroy(f);user_gate_seed(t,f);agent_seat_coordinator(t,f,coord)
        drop:=`{"reason":"r","children":[{"task_id":"c1","title":"a","brief":{"goal":"A","acceptance":["ok"],"requires_user_approval":false}}]}`
        testing.expect_value(t,cw_run(f,coord,"task.split","drop",cw_split(f,drop)).code,"invalid_scope")
        testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM tasks WHERE task_id='c1'"),"0")
        keep:=`{"reason":"r","children":[{"task_id":"c1","title":"a","brief":{"goal":"A","acceptance":["ok"]}},{"task_id":"c2","title":"b"},{"task_id":"c3","title":"c","unassigned":true}]}`
        testing.expect_value(t,cw_run(f,coord,"task.split","keep",cw_split(f,keep)).code,"ok")
        for id in ([3]string{"c1","c2","c3"}) {
            gated,_:=task_user_approval_required(&f.store,"chain",id)
            testing.expectf(t,gated,"%s keeps the user gate",id)
        }
        testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM local_fleet WHERE task_id='c3'"),"0")
    }
    // The user's device may drop it.
    {
        f:=fixture(t);defer destroy(f);user_gate_seed(t,f)
        drop:=cw_split(f,`{"reason":"user split","children":[{"task_id":"c1","title":"a","brief":{"goal":"A","acceptance":["ok"],"requires_user_approval":false}}]}`)
        testing.expect_value(t,invoke(f,command(f,"task.split","device_split","task",drop,agent_task_revision(f,"task")),drop).code,"ok")
        gated,_:=task_user_approval_required(&f.store,"chain","c1")
        testing.expect(t,!gated,"a device split may drop the gate")
        testing.expect_value(t,cc_scalar(f,"SELECT actor_kind FROM local_events WHERE kind='task.split'"),"device")
    }
    // Role-configuration gate: copied with the lifecycle to assigned children.
    {
        f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);agent_seat_coordinator(t,f,coord)
        children:=[1]Child{role_auditor()}
        testing.expect_value(t,advanced_call(f,"review.roles","roles",role_test_config("1"),"task",children[:]).code,"ok")
        testing.expect_value(t,cw_run(f,coord,"task.split","roles",cw_split(f,`{"reason":"r","children":[{"task_id":"c1","title":"a"}]}`)).code,"ok")
        testing.expect_value(t,cc_scalar(f,"SELECT requires_user_approval||':'||(SELECT count(*) FROM local_role_pairs WHERE task_id='c1') FROM local_role_configs WHERE task_id='c1'"),"1:2")
    }
    // Assignee override: a participant of this chain (observed by the Bridge).
    {
        f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);agent_seat_coordinator(t,f,coord)
        body:=cw_split(f,`{"reason":"r","children":[{"task_id":"c1","title":"a","assignee_instance_id":"coord_instance"}]}`)
        testing.expect_value(t,cw_run(f,coord,"task.split","unobserved",body).code,"invalid_scope")
        observed:=[1]Child{coord}
        testing.expect_value(t,cw_run(f,coord,"task.split","assigned",body,children=observed[:]).code,"ok")
        testing.expect_value(t,cc_scalar(f,"SELECT f.instance_id||':'||json_extract(c.config_json,'$.author_agent_id') FROM local_fleet f JOIN lifecycle_configs c USING(chain_id,task_id) WHERE f.task_id='c1'"),"coord_instance:coordinator_agent")
    }
}

// ---- REQ-CC-13 self-approval guard ---------------------------------------------

@(test)
cw_coordinator_never_reviews_or_completes_its_own_work :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    // Solo: the coordinator is the task's configured author.
    solo:=agent_coordinator_child();solo.agent_id="author"
    {
        f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);agent_seat_coordinator(t,f,solo)
        if !cw_worker_submit(t,f,lifecycle_ready(t,f)) do return
        testing.expect_value(t,cw_run(f,solo,"task.complete","self_done",cw_complete(f,"mine","1")).code,"invalid_scope")
        code,why:=complete_refusal_locked(&f.store,"chain","task",solo)
        testing.expect(t,code=="invalid_scope" && strings.contains(why,"solo_self_review"),why)
        testing.expect_value(t,agent_run(f,solo,"review.post","self_relay","task",lifecycle_verdict(),agent_task_revision(f,"task")).code,"invalid_scope")
        testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM local_reviews"),"0")
    }
    coord:=agent_coordinator_child()
    // It never names itself a role reviewer or the lifecycle reviewer.
    {
        f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);agent_seat_coordinator(t,f,coord)
        roles:=encode(doc(map[string]string{"configuration_revision"="1","requires_user_approval"="0","pairs"=`[{"role":"safety","agent_id":"coordinator_agent","instance_id":"coord_instance"}]`}))
        p:=encode(doc(map[string]string{"body_cipher"=cipher(f,roles)}))
        observed:=[1]Child{coord}
        testing.expect_value(t,cw_run(f,coord,"review.roles","self_role",p,children=observed[:]).code,"invalid_scope")
        testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM local_role_configs"),"0")
        config:=encode(doc(map[string]string{"configuration_revision"="2","author_agent_id"="author","reviewer_agent_id"="coordinator_agent","reviewer_instance_id"="coord_instance","directory_id"="directory","merge_policy"="none","repository"="","worktree"="","source_branch"="","target_branch"="","base_head"=""}))
        testing.expect_value(t,cw_run(f,coord,"lifecycle.configure","self_reviewer",config).code,"invalid_scope")
        // A coordinator that did not work the task may relay and complete.
        if !cw_worker_submit(t,f,lifecycle_ready(t,f)) do return
        testing.expect_value(t,cw_run(f,coord,"task.complete","other_done",cw_complete(f,"verified","1")).code,"ok")
    }
}

@(test)
cw_migration_v36_is_rerunnable :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    off:=`{"policy":"coordinator_force_done","value":"0"}`
    testing.expect_value(t,invoke(f,command(f,"chain.policy.set","off","",off,agent_chain_rev(f)),off).code,"ok")
    close(&f.store)
    db:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    testing.expect(t,exec(db,"UPDATE schema_migrations SET version=35"))
    testing.expect_value(t,sqlite3_close(db),0)
    if !testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key")) do return
    testing.expect_value(t,cc_scalar(f,"SELECT schema_version||':'||(SELECT version FROM schema_migrations) FROM runtime_database"),"36:36")
    enabled,_:=force_done_enabled(&f.store,"chain")
    testing.expect(t,!enabled,"the policy survives the re-run")
}

@(test)
cw_reads_expose_the_policy_and_split_links :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    testing.expect_value(t,cw_run(f,coord,"task.split","split",cw_split(f,`{"reason":"r","children":[{"task_id":"c1","title":"a"}]}`)).code,"ok")
    read:=agent_run(f,coord,"task.read","read_original","task",`{"cursor":"","limit":"10"}`,"0")
    testing.expect_value(t,read.code,"ok")
    links,_:=cc_result(read)["links"].(json.Array)
    testing.expect(t,len(links)==1 && field(links[0].(json.Object),"relation")=="split_into" && field(links[0].(json.Object),"task_id")=="c1",read.body)
    child:=agent_run(f,coord,"task.read","read_child","c1",`{"cursor":"","limit":"10"}`,"0")
    testing.expect(t,strings.contains(child.body,`"split_from"`),child.body)
    chain:=agent_run(f,coord,"chain.read","read_chain","",`{"cursor":"","limit":"10"}`,"0")
    testing.expect_value(t,field(cc_result(chain),"coordinator_force_done"),"1")
}

// Gaps found on audit: the device path never force-submits or force-completes
// (both are coordinator operations), a coordinator that only HELD a lease of
// the task is still its worker (REQ-CC-13), and an agent cannot split a task
// escalated to a human (the device can).
@(test)
cw_device_refusals_lease_holder_self_guard_and_escalated_split :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    coord:=agent_coordinator_child()
    {
        f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);agent_seat_coordinator(t,f,coord)
        cw_handoff(t,f,lifecycle_ready(t,f))
        p:=cw_submit(f,"device submit","1")
        testing.expect_value(t,invoke(f,command(f,"lifecycle.force_submit","device_fs","task",p,agent_task_revision(f,"task")),p).code,"invalid_scope")
        testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM local_submissions"),"0")
        // Once submitted by the coordinator, the device cannot force-done either.
        testing.expect_value(t,cw_run(f,coord,"lifecycle.force_submit","fs",cw_submit(f,"x","1")).code,"ok")
        d:=cw_complete(f,"device done","1")
        testing.expect_value(t,invoke(f,command(f,"task.complete","device_done","task",d,agent_task_revision(f,"task")),d).code,"invalid_scope")
        testing.expect_value(t,cc_scalar(f,"SELECT state FROM lifecycle_state"),"in_review")
    }
    // Lease holder: the coordinator's instance held the task's lease although
    // the configured author is another agent id.
    {
        holder:=lease_child();holder.agent_id="coordinator_agent"
        f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
        if !cw_worker_submit(t,f,lifecycle_ready(t,f)) do return
        // The worker's instance is then seated as the chain coordinator.
        agent_seat_coordinator(t,f,holder)
        worked,ok:=agent_self_worked(&f.store,"chain","task",holder)
        testing.expect(t,ok && worked,"a lease holder worked the task")
        testing.expect_value(t,cw_run(f,holder,"task.complete","holder_done",cw_complete(f,"mine","1")).code,"invalid_scope")
        testing.expect_value(t,agent_run(f,holder,"review.post","holder_relay","task",lifecycle_verdict(),agent_task_revision(f,"task")).code,"invalid_scope")
        testing.expect_value(t,cc_scalar(f,"SELECT state FROM lifecycle_state"),"in_review")
    }
    // Escalated to a human: the coordinator cannot split it away; the user can.
    {
        f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);agent_seat_coordinator(t,f,coord)
        testing.expect_value(t,cc_call(f,coord,"task.escalate","escalate",cc_reason(f,"needs a decision")).code,"ok")
        body:=`{"reason":"r","children":[{"task_id":"c1","title":"a"}]}`
        testing.expect_value(t,cw_run(f,coord,"task.split","agent_split",cw_split(f,body)).code,"invalid_scope")
        testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM tasks WHERE task_id='c1'"),"0")
        p:=cw_split(f,body)
        testing.expect_value(t,invoke(f,command(f,"task.split","device_split","task",p,agent_task_revision(f,"task")),p).code,"ok")
        testing.expect_value(t,cc_scalar(f,"SELECT mode FROM local_controls WHERE task_id='task'"),"cancelled")
    }
}

// A second worker lease ("lease2") through the requirements ack and submit.
cw_second_attempt :: proc(t:^testing.T,f:^Fixture) -> bool {
    child:=lease_child()
    r:=lease_invoke(f,lease_request(f,child,"lease.claim","claim2","lease2","",agent_task_revision(f,"task")),"",child)
    if !testing.expect_value(t,r.code,"ok") do return false
    cap:=result_cap(r)
    call :: proc(f:^Fixture,child:Child,method,op,payload,cap:string) -> Result {
        raw:=lease_request(f,child,"lease.heartbeat",op,"lease2",cap,agent_task_revision(f,"task"))
        c,_:=contracts.owner_parse(raw,"lease_command")
        c["method"]=json.String(method);c["payload_digest"]=json.String(contracts.owner_payload_digest(payload))
        signature,_:=test_sign(&f.owner_priv,"lifecycle_command",c);c["signature"]=json.String(signature)
        return execute_lifecycle(&f.store,encode(c),payload,cap,child,f.owner,1000,Signer{&f.owner_priv,test_sign},Source_Proof{"",true})
    }
    p:=`{"requirements_revision":"1"}`
    if !testing.expect_value(t,call(f,child,"requirements.present","present2",p,cap).code,"ok") do return false
    if !testing.expect_value(t,call(f,child,"requirements.ack","ack2",p,cap).code,"ok") do return false
    return testing.expect_value(t,call(f,child,"lease.submit","submit2",`{"requirements_revision":"1","head":"","summary":"Fixed"}`,cap).code,"ok")
}

// Review fix 1: force-done never overrides the user's device-signed
// request_changes on the latest attempt, even on an ungated non-git task
// that went back to ready. A new submission follows the normal rules.
@(test)
cw_force_done_never_overrides_a_device_request_changes :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    if !cw_worker_submit(t,f,lifecycle_ready(t,f)) do return
    gated,_:=task_user_approval_required(&f.store,"chain","task")
    testing.expect(t,!gated,"no user-approval source")
    o:=cc_result(Result{body=lifecycle_verdict()});o["verdict"]=json.String("request_changes");o["summary"]=json.String("not what I asked for")
    p:=encode(o)
    testing.expect_value(t,invoke(f,command(f,"review.post","user_rejects","task",p,agent_task_revision(f,"task")),p).code,"ok")
    testing.expect_value(t,cc_scalar(f,"SELECT state||':'||attempt FROM lifecycle_state"),"ready:1")
    testing.expect_value(t,cw_run(f,coord,"task.complete","override_user",cw_complete(f,"I disagree","1")).code,"invalid_scope")
    code,why:=complete_refusal_locked(&f.store,"chain","task",coord)
    testing.expect(t,code=="invalid_scope" && strings.contains(why,"requested changes"),why)
    testing.expect_value(t,cc_scalar(f,"SELECT state FROM lifecycle_state"),"ready")
    // A new attempt: the rejection was of attempt 1, so the normal rules apply.
    if !cw_second_attempt(t,f) do return
    testing.expect_value(t,cc_scalar(f,"SELECT state||':'||attempt FROM lifecycle_state"),"in_review:2")
    r:=cw_run(f,coord,"task.complete","after_fix",cw_complete(f,"reviewer unavailable","2"))
    testing.expect_value(t,r.code,"ok")
    testing.expect_value(t,field(cc_result(r),"skipped_gates"),"independent_review")
}

// Review fix 2: after a reassignment (A's lease retired, fleet -> B, author
// B, reviewer A) force_submit cannot bind A's lease under B's name.
@(test)
cw_force_submit_refuses_a_lease_from_a_previous_configuration :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    sign:=Signer{&f.owner_priv,test_sign}
    cw_handoff(t,f,lifecycle_ready(t,f))
    replacement:=Child{"instance2","epoch2",strings.repeat("e",64,context.temp_allocator),1,"author2"}
    p:=encode(doc(map[string]string{"instance_id"=replacement.instance,"configuration_revision"="2","enabled"="1"}))
    testing.expect_value(t,execute(&f.store,command(f,"fleet.edit","reassign_fleet","task",p,agent_task_revision(f,"task")),p,"",f.creator,f.owner,1,"head",1000,&f.kr,sign,replacement).code,"ok")
    config,_,_:=lifecycle_config(&f.store,"chain","task")
    config["configuration_revision"]=json.String("2");config["author_agent_id"]=json.String("author2")
    config["reviewer_agent_id"]=json.String("author");config["reviewer_instance_id"]=json.String("instance")
    cp:=encode(config)
    testing.expect_value(t,execute(&f.store,command(f,"lifecycle.configure","reassign_config","task",cp,agent_task_revision(f,"task")),cp,"",f.creator,f.owner,1,"head",1000,&f.kr,sign,{},Lifecycle_Proof{replacement,lease_child(),true}).code,"ok")
    testing.expect_value(t,cc_scalar(f,"SELECT instance_id||':'||configuration_revision FROM local_leases"),"instance:1")
    testing.expect_value(t,cw_run(f,coord,"lifecycle.force_submit","old_lease",cw_submit(f,"submit A's work","1")).code,"operation_conflict")
    testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM local_submissions"),"0")
    testing.expect_value(t,cc_scalar(f,"SELECT state FROM lifecycle_state"),"ready")
}

// Review nit (b): workflow runs waiting on the original are reported.
@(test)
cw_split_and_cancel_warn_about_workflow_run_dependents :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    coord:=agent_coordinator_child()
    for method in ([2]string{"task.split","task.cancel"}) {
        f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);agent_seat_coordinator(t,f,coord)
        testing.expect(t,exec(f.store.db,"INSERT INTO local_work_dependencies VALUES('chain','dep_run','workflow_run','run9','task','task','t','user','account',(SELECT max(seq) FROM local_events))"))
        r:Result
        if method=="task.split" {
            r=cw_run(f,coord,"task.split","split",cw_split(f,`{"reason":"r","children":[{"task_id":"c1","title":"a"}]}`))
        } else {
            r=cc_call(f,coord,"task.cancel","cancel",cc_reason(f,"gone"))
        }
        if !testing.expectf(t,r.code=="ok","%s: %s",method,r.code) do continue
        out:=cc_result(r)
        testing.expectf(t,field(out,"workflow_run_dependents")=="run9" && strings.contains(field(out,"warning"),"workflow runs"),"%s: %s",method,r.body)
    }
}
