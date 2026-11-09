#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

work_task_revision :: proc(f:^Fixture,id:string)->string {
    rows,_:=query(f.store.db,"SELECT revision FROM tasks WHERE chain_id='chain' AND task_id=?",id)
    return rows[0][0]
}
work_bind :: proc(t:^testing.T,f:^Fixture,id:string) {
    child:=lease_child()
    p:=encode(doc(map[string]string{"instance_id"=child.instance,"configuration_revision"="1","enabled"="1"}))
    c:=command(f,"fleet.edit",fmt.tprintf("fleet_%s",id),id,p,work_task_revision(f,id))
    testing.expect_value(t,execute(&f.store,c,p,"",f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},child).code,"ok")
    config:=encode(doc(map[string]string{"configuration_revision"="1","author_agent_id"="author","reviewer_agent_id"="reviewer","reviewer_instance_id"="review_instance","directory_id"="directory","merge_policy"="none","repository"="","worktree"="","source_branch"="","target_branch"="","base_head"=""}))
    c=command(f,"lifecycle.configure",fmt.tprintf("configure_%s",id),id,config,work_task_revision(f,id))
    testing.expect_value(t,execute(&f.store,c,config,"",f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},{},Lifecycle_Proof{child,lifecycle_reviewer(),true}).code,"ok")
}
work_finish :: proc(t:^testing.T,f:^Fixture,id:string,output:string="") {
    work_bind(t,f,id)
    lease:=fmt.tprintf("lease_%s",id)
    claimed:=dependency_claim(f,id,lease,fmt.tprintf("claim_%s",id),work_task_revision(f,id))
    if !testing.expect_value(t,claimed.code,"ok") do return
    cap:=result_cap(claimed);child:=lease_child();revision:=work_task_revision(f,id)
    req:=`{"requirements_revision":"1"}`
    for method in ([2]string{"requirements.present","requirements.ack"}) {
        testing.expect_value(t,dependency_lifecycle_call(f,id,lease,child,method,fmt.tprintf("%s_%s",method,id),req,cap,revision).code,"ok")
    }
    submit:=encode(doc(map[string]string{"requirements_revision"="1","head"="","summary"="Completed scope"}))
    if output!="" {
        value,_:=contracts.owner_content_document(submit);document,_:=value.(json.Object)
        document["output"]=json.String(output);submit=encode(document)
    }
    testing.expect_value(t,dependency_lifecycle_call(f,id,lease,child,"lease.submit",fmt.tprintf("submit_%s",id),submit,cap,revision).code,"ok")
    verdict:=`{"requirements_revision":"1","attempt":"1","head":"","verdict":"approve","summary":"Independent review"}`
    revision=work_task_revision(f,id)
    opened:=dependency_lifecycle_call(f,id,lease,lifecycle_reviewer(),"review.open",fmt.tprintf("open_%s",id),verdict,"",revision)
    if !testing.expect_value(t,opened.code,"ok") do return
    testing.expect_value(t,dependency_lifecycle_call(f,id,lease,lifecycle_reviewer(),"review.post",fmt.tprintf("review_%s",id),verdict,result_cap(opened),revision).code,"ok")
}
work_revision :: proc(f:^Fixture)->string {
    rows,_:=query(f.store.db,"SELECT work_revision FROM local_work_chains WHERE chain_id='chain'")
    return rows[0][0]
}
work_complete_call :: proc(f:^Fixture,op,revision:string)->Result {
    return work_call(f,"chain.complete",op,encode(doc(map[string]string{"expected_work_revision"=revision,"summary"="All included work succeeded"})))
}
@(test)
work_generation_receipts_strict_success_completion_restart_and_consumed_output_guard :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);work_seed(t,f)
    v,_:=contracts.owner_content_document(work_plan());plan,_:=v.(json.Object);plan["auto_approve"]=json.Boolean(true)
    testing.expect_value(t,work_call(f,"chain.propose","plan",encode(plan)).code,"ok")
    testing.expect(t,!work_inputs_ready(&f.store,"chain","task","second"))
    testing.expect_value(t,work_complete_call(f,"early_complete",work_revision(f)).code,"operation_conflict")
    stale:=work_revision(f)
    work_finish(t,f,"first")
    testing.expect(t,work_inputs_ready(&f.store,"chain","task","second"))
    work_finish(t,f,"second")
    rows,_:=query(f.store.db,"SELECT dependent_id,dependent_generation,prerequisite_id,prerequisite_generation,output_manifest_json FROM local_work_inputs")
    testing.expect(t,len(rows)==1 && rows[0][0]=="second" && rows[0][1]=="1" && rows[0][2]=="first" && rows[0][3]=="1")
    testing.expect_value(t,work_complete_call(f,"stale_complete",stale).code,"stale_revision")
    testing.expect_value(t,work_call(f,"work.dependency.add","started_contract",`{"dependency_id":"reverse","dependent":{"kind":"task","id":"first"},"prerequisite":{"kind":"task","id":"second"}}`).code,"operation_conflict")
    testing.expect_value(t,work_call(f,"task.reopen","consumed_reopen","Replace consumed output","first",work_task_revision(f,"first")).code,"operation_conflict")
    // T1: the refusal names its cause and the consuming dependent.
    cause:=reopen_refusal_cause(&f.store,"chain","first")
    testing.expectf(t,strings.contains(cause,"consumed by a started dependent") && strings.contains(cause,"task second"),"reopen cause: %q",cause)
    before:=encode(rows);revision:=work_revision(f)
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    rows,_=query(f.store.db,"SELECT dependent_id,dependent_generation,prerequisite_id,prerequisite_generation,output_manifest_json FROM local_work_inputs")
    testing.expect_value(t,encode(rows),before)
    testing.expect_value(t,work_complete_call(f,"complete",revision).code,"ok")
    testing.expect(t,metadata_replay(f,"complete").replay)
    testing.expect_value(t,work_call(f,"chain.propose","after_complete",work_plan()).code,"operation_conflict")
    rows,_=query(f.store.db,"SELECT summary,work_revision FROM local_work_completions")
    testing.expect(t,len(rows)==1 && rows[0][1]==revision)
}
@(test)
work_cancelled_or_excluded_prerequisites_never_succeed_and_scope_retains_history :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);work_seed(t,f)
    v,_:=contracts.owner_content_document(work_plan());plan,_:=v.(json.Object);plan["auto_approve"]=json.Boolean(true)
    testing.expect_value(t,work_call(f,"chain.propose","plan",encode(plan)).code,"ok")
    testing.expect_value(t,work_call(f,"work.scope","exclude_active",`{"item":{"kind":"task","id":"first"},"action":"exclude","reason":"No shortcut"}`).code,"operation_conflict")
    testing.expect_value(t,work_call(f,"task.cancel","cancel_first","Cancelled with reason","first",work_task_revision(f,"first")).code,"ok")
    testing.expect_value(t,work_call(f,"work.scope","exclude_terminal",`{"item":{"kind":"task","id":"first"},"action":"exclude","reason":"Out of scope"}`).code,"ok")
    testing.expect(t,!work_inputs_ready(&f.store,"chain","task","second"))
    testing.expect_value(t,work_complete_call(f,"cancelled_complete",work_revision(f)).code,"operation_conflict")
    rows,_:=query(f.store.db,"SELECT dependency_id FROM local_work_dependencies")
    p:=encode(doc(map[string]string{"dependency_id"=rows[0][0],"reason"="Explicitly replace the input contract"}))
    testing.expect_value(t,work_call(f,"work.dependency.remove","remove_edge",p).code,"ok")
    testing.expect(t,work_inputs_ready(&f.store,"chain","task","second"))
    work_finish(t,f,"second")
    testing.expect_value(t,work_complete_call(f,"complete_remaining",work_revision(f)).code,"ok")
    rows,_=query(f.store.db,"SELECT count(*),(SELECT count(*) FROM local_work_scope) FROM local_work_dependency_removals")
    testing.expect_value(t,encode(rows),encode([1][2]string{{"1","1"}}))
}
@(test)
work_draft_workflow_external_dependencies_activate_once_and_freeze_generation_receipts :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);work_seed(t,f)

    p:=`{"kind":"task","auto_approve":true,"tasks":[{"id":"first","title":"First","brief":{"goal":"Prerequisite","acceptance":["Done"]}}]}`
    testing.expect_value(t,work_call(f,"chain.propose","proposal",p).code,"ok")
    testing.expect_value(t,work_call(f,"chain.draft","draft","{}").code,"ok")
    testing.expect_value(t,advanced_call(f,"workflow.define","definition",workflow_test_definition()).code,"ok")
    testing.expect_value(t,advanced_call(f,"workflow.run","queue",`{"run_id":"run","workflow_id":"definition","version":"1"}`).code,"ok")
    testing.expect_value(t,work_call(f,"work.dependency.add","external_edge",`{"dependency_id":"external","dependent":{"kind":"workflow_run","id":"run"},"prerequisite":{"kind":"task","id":"first"}}`).code,"ok")
    testing.expect_value(t,work_call(f,"chain.publish","publish","{}").code,"ok")
    rows,_:=query(f.store.db,"SELECT count(*) FROM local_work_run_starts")
    testing.expect_value(t,rows[0][0],"0")
    work_finish(t,f,"first")
    rows,_=query(f.store.db,"SELECT count(*) FROM local_work_run_starts")
    testing.expect_value(t,rows[0][0],"1")
    rows,_=query(f.store.db,"SELECT dependent_kind,dependent_id,dependent_generation,prerequisite_id,prerequisite_generation FROM local_work_inputs")
    testing.expect_value(t,encode(rows),encode([1][5]string{{"workflow_run","run","1","first","1"}}))
    before:=encode(rows)
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect(t,metadata_replay(f,"publish").replay)
    rows,_=query(f.store.db,"SELECT dependent_kind,dependent_id,dependent_generation,prerequisite_id,prerequisite_generation FROM local_work_inputs")
    testing.expect_value(t,encode(rows),before)
    testing.expect_value(t,work_call(f,"task.reopen","consumed","Replace consumed output","first",work_task_revision(f,"first")).code,"operation_conflict")
    testing.expect_value(t,work_call(f,"work.dependency.add","late_edge",`{"dependency_id":"late","dependent":{"kind":"workflow_run","id":"run"},"prerequisite":{"kind":"task","id":"first"}}`).code,"ok")
    generated:=workflow_task_id("chain","run","1","first")
    edge:=doc(map[string]string{"dependency_id"="private"})
    edge["dependent"]=doc(map[string]string{"kind"="task","id"="first"})
    edge["prerequisite"]=doc(map[string]string{"kind"="task","id"=generated})
    p=encode(edge)
    testing.expect_value(t,work_call(f,"work.dependency.add","private_edge",p).code,"invalid_scope")

}
@(test)
work_never_started_cancelled_workflow_draft_requires_replacement_and_can_be_excluded :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);work_seed(t,f)
    testing.expect_value(t,work_call(f,"chain.draft","draft","{}").code,"ok")
    testing.expect_value(t,advanced_call(f,"workflow.define","definition",workflow_test_definition()).code,"ok")
    testing.expect_value(t,work_call(f,"workflow.draft","queue",`{"run_id":"run","workflow_id":"definition","version":"1"}`).code,"ok")
    testing.expect_value(t,advanced_call(f,"workflow.cancel","stale_cancel",`{"run_id":"run","execution":"2","reason":"stale"}`).code,"stale_revision")
    testing.expect_value(t,advanced_call(f,"workflow.cancel","cancel_draft",`{"run_id":"run","execution":"1","reason":"Cancelled before start"}`).code,"ok")
    sealed,valid:=work_snapshot(&f.store,"chain","workflow_run","run")
    testing.expect(t,valid && sealed.started && sealed.terminal && !sealed.succeeded)

    testing.expect_value(t,work_call(f,"work.scope","exclude_draft",`{"item":{"kind":"workflow_run","id":"run"},"action":"exclude","reason":"Replace draft"}`).code,"ok")
    testing.expect_value(t,advanced_call(f,"workflow.run","reuse_cancelled",`{"run_id":"run","workflow_id":"definition","version":"1"}`).code,"operation_conflict")
    testing.expect_value(t,work_call(f,"chain.publish","publish","{}").code,"ok")
    rows,_:=query(f.store.db,"SELECT count(*) FROM local_work_run_starts")
    testing.expect_value(t,rows[0][0],"0")
    testing.expect_value(t,work_complete_call(f,"empty_success",work_revision(f)).code,"operation_conflict")
}

@(test)
work_mixed_run_to_run_and_run_to_task_receipts_pin_current_execution_and_prevent_retry :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);work_seed(t,f)
    v,_:=contracts.owner_content_document(work_plan());plan,_:=v.(json.Object);plan["auto_approve"]=json.Boolean(true)
    tasks,_:=plan["tasks"].(json.Array);second,_:=tasks[1].(json.Object);delete_key(&second,"depends_on")
    testing.expect_value(t,work_call(f,"chain.propose","plan",encode(plan)).code,"ok")
    testing.expect_value(t,work_call(f,"chain.draft","draft","{}").code,"ok")
    testing.expect_value(t,advanced_call(f,"workflow.define","definition",workflow_test_definition()).code,"ok")
    for run in ([2]string{"run","next_run"}) {
        testing.expect_value(t,work_call(f,"workflow.draft",fmt.tprintf("queue_%s",run),encode(doc(map[string]string{"run_id"=run,"workflow_id"="definition","version"="1"}))).code,"ok")
    }
    for pair,i in ([3][4]string{{"workflow_run","run","task","first"},{"workflow_run","next_run","workflow_run","run"},{"task","second","workflow_run","next_run"}}) {
        edge:=doc(map[string]string{"dependency_id"=fmt.tprintf("edge_%d",i)})
        edge["dependent"]=doc(map[string]string{"kind"=pair[0],"id"=pair[1]})
        edge["prerequisite"]=doc(map[string]string{"kind"=pair[2],"id"=pair[3]})
        testing.expect_value(t,work_call(f,"work.dependency.add",fmt.tprintf("add_%d",i),encode(edge)).code,"ok")
    }
    testing.expect_value(t,work_call(f,"chain.publish","publish","{}").code,"ok")
    work_finish(t,f,"first")
    for run in ([2]string{"run","next_run"}) {
        snap,ok:=work_snapshot(&f.store,"chain","workflow_run",run)
        testing.expect(t,ok && snap.started && !snap.succeeded && snap.generation==1)
        for key in ([2]string{"first","second"}) {
            output:=""
            if key=="first" do output=`{"value":7}`
            work_finish(t,f,workflow_task_id("chain",run,"1",key),output)
        }
        snap,ok=work_snapshot(&f.store,"chain","workflow_run",run)
        testing.expect(t,ok && snap.succeeded)
    }
    work_finish(t,f,"second")
    rows,_:=query(f.store.db,"SELECT dependent_kind,dependent_id,dependent_generation,prerequisite_kind,prerequisite_id,prerequisite_generation FROM local_work_inputs ORDER BY dependent_kind,dependent_id")
    testing.expect_value(t,encode(rows),encode([3][6]string{{"task","second","1","workflow_run","next_run","1"},{"workflow_run","next_run","1","workflow_run","run","1"},{"workflow_run","run","1","task","first","1"}}))
    manifests,_:=query(f.store.db,"SELECT output_manifest_json FROM local_work_inputs WHERE prerequisite_kind='workflow_run'")
    for row in manifests do testing.expect_value(t,row[0],`{"first":[{"value":7}],"second":[{}]}`)
    testing.expect_value(t,advanced_call(f,"workflow.retry","consumed_run_retry",`{"run_id":"run","execution":"1"}`).code,"operation_conflict")
    testing.expect_value(t,work_complete_call(f,"complete_graph",work_revision(f)).code,"ok")
}
@(test)
work_proposed_human_gate_remains_required_after_independent_approval :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);work_seed(t,f)
    v,_:=contracts.owner_content_document(work_plan());plan,_:=v.(json.Object);plan["auto_approve"]=json.Boolean(true)
    tasks,_:=plan["tasks"].(json.Array);first,_:=tasks[0].(json.Object);brief,_:=first["brief"].(json.Object)
    brief["requires_user_approval"]=json.Boolean(true)
    testing.expect_value(t,work_call(f,"chain.propose","plan",encode(plan)).code,"ok")
    work_finish(t,f,"first")
    testing.expect(t,!work_inputs_ready(&f.store,"chain","task","second"))
    testing.expect_value(t,work_complete_call(f,"gate_incomplete",work_revision(f)).code,"operation_conflict")
    p:=encode(doc(map[string]string{"requirements_revision"="1","attempt"="1","head"="","verdict"="approve","summary"="Explicit submitted human gate"}))
    testing.expect_value(t,invoke(f,command(f,"review.post","human_approval","first",p,work_task_revision(f,"first")),p).code,"ok")
    testing.expect(t,work_inputs_ready(&f.store,"chain","task","second"))
}

@(test)
work_language_run_on_draft_chain_does_not_expand_before_publication :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);work_seed(t,f)
    testing.expect_value(t,work_call(f,"chain.draft","draft","{}").code,"ok")
    spec:=`{"schema":"workflow.v1","stages":[{"key":"first","brief":{"goal":"First","acceptance":["Pass"]}}]}`
    testing.expect_value(t,language_test_define(f,"definition",spec).code,"ok")
    testing.expect_value(t,language_test_run(f,"definition","run","{}").code,"ok")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM local_work_pending_runs),(SELECT count(*) FROM local_workflow_runs),(SELECT count(*) FROM tasks)")
    testing.expect_value(t,encode(rows),encode([1][3]string{{"1","0","0"}}))
    testing.expect(t,metadata_replay(f,"run_run").replay)
    testing.expect_value(t,work_call(f,"chain.publish","publish","{}").code,"ok")
    rows,_=query(f.store.db,"SELECT (SELECT count(*) FROM local_work_run_starts),(SELECT count(*) FROM local_workflow_runs),(SELECT count(*) FROM tasks)")
    testing.expect_value(t,encode(rows),encode([1][3]string{{"1","1","1"}}))
    testing.expect(t,metadata_replay(f,"publish").replay)
    rows,_=query(f.store.db,"SELECT count(*) FROM local_workflow_tasks")
    testing.expect_value(t,rows[0][0],"1")
}
