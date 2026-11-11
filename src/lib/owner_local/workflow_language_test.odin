#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

language_test_define :: proc(f:^Fixture,id,spec:string)->Result {
    return advanced_call(f,"workflow.define",fmt.tprintf("define_%s",id),encode(doc(map[string]string{"workflow_id"=id,"version"="1","title"=id,"spec"=spec})))
}
language_test_run :: proc(f:^Fixture,id,run,inputs:string)->Result {
    return advanced_call(f,"workflow.run",fmt.tprintf("run_%s",run),encode(doc(map[string]string{"workflow_id"=id,"version"="1","run_id"=run,"inputs"=inputs})))
}
language_child_raw :: proc(f:^Fixture,task,lease:string,child:Child,method,op,payload,cap:string)->string {
    rows,ok:=query(f.store.db,"SELECT revision FROM tasks WHERE chain_id='chain' AND task_id=?",task)
    if !ok || len(rows)!=1 do return ""
    raw:=lifecycle_raw(f,child,method,op,payload,cap,rows[0][0])
    c,_:=contracts.owner_parse(raw,"lifecycle_command")
    c["task_id"]=json.String(task);c["lease_id"]=json.String(lease)
    sig,_:=test_sign(&f.owner_priv,"lifecycle_command",c);c["signature"]=json.String(sig)
    return encode(c)
}
language_child_call :: proc(f:^Fixture,task,lease:string,child:Child,method,op,payload,cap:string)->Result {
    raw:=language_child_raw(f,task,lease,child,method,op,payload,cap)
    return execute_lifecycle(&f.store,raw,payload,cap,child,f.owner,1000,Signer{&f.owner_priv,test_sign},Source_Proof{"",true})
}
language_finish :: proc(t:^testing.T,f:^Fixture,task,output:string) {
    workflow_bind(t,f,task)
    lease:=fmt.tprintf("lease_%s",task)
    claimed:=lease_invoke(f,workflow_lease_raw(f,task,lease,fmt.tprintf("claim_%s",task)),"",lease_child())
    if !testing.expect_value(t,claimed.code,"ok") do return
    cap:=result_cap(claimed)
    for method in ([2]string{"requirements.present","requirements.ack"}) {
        testing.expect_value(t,language_child_call(f,task,lease,lease_child(),method,fmt.tprintf("%s_%s",method,task),`{"requirements_revision":"1"}`,cap).code,"ok")
    }
    payload:=doc(map[string]string{"requirements_revision"="1","head"="","summary"="done"})
    if output!="" do payload["output"]=json.String(output)
    submitted:=language_child_call(f,task,lease,lease_child(),"lease.submit",fmt.tprintf("submit_%s",task),encode(payload),cap)
    if !testing.expect_value(t,submitted.code,"ok") do return
    verdict:=lifecycle_verdict()
    opened:=language_child_call(f,task,lease,lifecycle_reviewer(),"review.open",fmt.tprintf("open_%s",task),verdict,"")
    if !testing.expect_value(t,opened.code,"ok") do return
    testing.expect_value(t,language_child_call(f,task,lease,lifecycle_reviewer(),"review.post",fmt.tprintf("review_%s",task),verdict,result_cap(opened)).code,"ok")
}
language_tasks :: proc(f:^Fixture,run,execution,stage:string)->[][]string {
    rows,_:=query(f.store.db,"SELECT t.task_id,t.title,q.brief_json FROM local_workflow_tasks w JOIN local_workflow_language_items i USING(task_id) JOIN tasks t ON t.chain_id=w.chain_id AND t.task_id=w.task_id JOIN task_requirements q ON q.chain_id=t.chain_id AND q.task_id=t.task_id WHERE w.chain_id='chain' AND w.run_id=? AND w.execution=? AND i.stage_key=? ORDER BY i.stage_index",run,execution,stage)
    return rows[:]
}
LANGUAGE_DYNAMIC_SPEC :: `{"schema":"workflow.v1","name":"dynamic","stages":[
{"key":"source","brief":{"goal":"Produce","output":{"schema":"inline","required":["tasks","summary"]},"on_output":{"workflow":"follow","inputs":{"summary":"{{output.summary}}"}}}},
{"key":"approve","kind":"gate","depends_on":["source"],"approver":"user","prompt":"Approve {{stage.source.output.summary}}"},
{"key":"write","depends_on":["approve"],"for_each":"source.outputs[0].tasks","max_parallel":1,"title":"Write {{item.title}} {{stage.index}}/{{stage.count}}","brief":{"goal":"{{item.goal}}","acceptance":["done"]}},
{"key":"result","depends_on":["write"],"brief":{"goal":"Result {{stage.source.output.summary}}","acceptance":["done"]}}]}`

@(test)
language_dynamic_output_gate_fanout_result_and_sibling_consumption :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,language_test_define(f,"follow",`{"schema":"workflow.v1","name":"follow","stages":[{"key":"follow","title":"Follow {{inputs.summary}}","brief":{"goal":"{{inputs.summary}}","acceptance":["done"]}}]}`).code,"ok")
    testing.expect_value(t,language_test_define(f,"dynamic",LANGUAGE_DYNAMIC_SPEC).code,"ok")
    testing.expect_value(t,language_test_run(f,"dynamic","dynamic",`{}`).code,"ok")
    source:=language_tasks(f,"dynamic","1","source")
    if !testing.expect_value(t,len(source),1) do return
    testing.expect_value(t,len(language_tasks(f,"dynamic","1","write")),0)
    language_finish(t,f,source[0][0],`{"summary":"planned","tasks":[{"key":"a","title":"Alpha","goal":"Build A"},{"key":"b","title":"Beta","goal":"Build B"}]}`)
    gate:=language_tasks(f,"dynamic","1","approve")
    if !testing.expect_value(t,len(gate),1) do return
    testing.expect(t,strings.contains(gate[0][2],"Approve planned"))
    testing.expect_value(t,len(language_tasks(f,"dynamic","1","write")),0)
    gate_payload:=`{"run_id":"dynamic","execution":"1","stage_key":"approve","verdict":"approve","summary":"Go"}`
    testing.expect_value(t,advanced_call(f,"workflow.gate","approve",gate_payload).code,"ok")
    writes:=language_tasks(f,"dynamic","1","write")
    if !testing.expect_value(t,len(writes),2) do return
    testing.expect_value(t,writes[0][1],"Write Alpha 0/2")
    testing.expect_value(t,writes[1][1],"Write Beta 1/2")
    for row in writes do language_finish(t,f,row[0],"")
    result:=language_tasks(f,"dynamic","1","result")
    if !testing.expect_value(t,len(result),1) do return
    testing.expect(t,strings.contains(result[0][2],"Result planned"))
    children,ok:=query(f.store.db,"SELECT target_run,consumed FROM local_workflow_output_triggers WHERE source_run='dynamic'")
    if !testing.expect(t,ok && len(children)==1) do return
    testing.expect_value(t,children[0][1],"0")
    testing.expect_value(t,len(language_tasks(f,children[0][0],"1","follow")),0)
    language_finish(t,f,result[0][0],"")
    follow:=language_tasks(f,children[0][0],"1","follow")
    if !testing.expect_value(t,len(follow),1) do return
    testing.expect_value(t,follow[0][1],"Follow planned")
    testing.expect_value(t,advanced_call(f,"workflow.retry","consumed_retry",`{"run_id":"dynamic","execution":"1"}`).code,"operation_conflict")
    for _ in 0..<3 {
        tx:Transaction
        testing.expect(t,transaction_begin(&f.store,&tx))
        testing.expect(t,workflow_refresh(&f.store))
        testing.expect(t,transaction_commit(&tx))
    }
    children,_=query(f.store.db,"SELECT target_run,consumed FROM local_workflow_output_triggers WHERE source_run='dynamic'")
    testing.expect_value(t,len(children),1)
    testing.expect_value(t,len(language_tasks(f,"dynamic","1","write")),2)
}

@(test)
language_empty_input_fanout_retry_and_exact_publication_recovery :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    spec:=`{"kind":"workflow","v":1,"name":"empty","inputs":{"items":{"type":"array","default":[]}},"stages":[{"key":"empty","for_each":"workflow.input.items","brief":{"goal":"{{item}}","acceptance":["done"]}},{"key":"result","needs":["empty"],"brief":{"goal":"Result","acceptance":["done"]}}]}`
    testing.expect_value(t,language_test_define(f,"empty",spec).code,"ok")
    testing.expect_value(t,language_test_run(f,"empty","empty",`{}`).code,"ok")
    testing.expect_value(t,len(language_tasks(f,"empty","1","empty")),0)
    testing.expect_value(t,len(language_tasks(f,"empty","1","result")),1)
    claims,ok:=intent_claim_due(&f.store,1000)
    if !testing.expect(t,ok) do return
    prepared:=0
    for claim in claims {
        if claim.kind!="registry.prepare" do continue
        a,one:=language_registry_prepare(&f.store,claim,&f.kr,Signer{&f.owner_priv,test_sign})
        b,two:=language_registry_prepare(&f.store,claim,&f.kr,Signer{&f.owner_priv,test_sign})
        testing.expect(t,one && two && a==b && a!="")
        testing.expect(t,intent_result(&f.store,claim,false,"network unknown",1000))
        prepared+=1
    }
    testing.expect_value(t,prepared,1)
    testing.expect_value(t,advanced_call(f,"workflow.retry","running_retry",`{"run_id":"empty","execution":"1"}`).code,"operation_conflict")
    testing.expect_value(t,advanced_call(f,"workflow.cancel","cancel_empty",`{"run_id":"empty","execution":"1","reason":"retry test"}`).code,"ok")
    testing.expect_value(t,advanced_call(f,"workflow.retry","retry_empty",`{"run_id":"empty","execution":"1"}`).code,"ok")
    testing.expect_value(t,len(language_tasks(f,"empty","2","empty")),0)
    testing.expect_value(t,len(language_tasks(f,"empty","2","result")),1)
    old:=language_tasks(f,"empty","1","result")
    testing.expect(t,!workflow_task_current(&f.store,"chain",old[0][0]))
}

@(test)
language_invalid_run_and_expansion_commit_failure_leave_nothing :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    spec:=`{"schema":"workflow.v1","name":"items","stages":[{"key":"write","for_each":"inputs.items","brief":{"goal":"{{item}}","acceptance":["done"]}}]}`
    testing.expect_value(t,language_test_define(f,"items",spec).code,"ok")
    testing.expect_value(t,language_test_run(f,"items","invalid",`{"items":"bad"}`).code,"invalid_content")
    rows,_:=query(f.store.db,"SELECT count(*) FROM local_workflow_runs")
    testing.expect_value(t,rows[0][0],"0")
    testing.expect(t,exec(f.store.db,`CREATE TABLE language_failure(id INTEGER PRIMARY KEY);CREATE TABLE language_failure_ref(id INTEGER REFERENCES language_failure(id) DEFERRABLE INITIALLY DEFERRED);CREATE TRIGGER language_commit_failure AFTER INSERT ON local_workflow_stage_expansions BEGIN INSERT INTO language_failure_ref VALUES(1); END;`))
    testing.expect_value(t,language_test_run(f,"items","atomic",`{"items":["one","two"]}`).code,"storage_error")
    rows,_=query(f.store.db,"SELECT (SELECT count(*) FROM local_workflow_runs),(SELECT count(*) FROM local_workflow_tasks),(SELECT count(*) FROM local_workflow_stage_expansions),(SELECT count(*) FROM runtime_intents WHERE kind='registry.prepare'),(SELECT count(*) FROM command_receipts WHERE operation_id='run_atomic'),(SELECT count(*) FROM search_docs WHERE title='write')")
    for value in rows[0] do testing.expect_value(t,value,"0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER language_commit_failure"))
    testing.expect_value(t,language_test_run(f,"items","atomic",`{"items":["one","two"]}`).code,"ok")
    testing.expect_value(t,len(language_tasks(f,"atomic","1","write")),2)
}

@(test)
language_gate_rejection_retry_discards_stale_generation_outputs :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,language_test_define(f,"gate",`{"schema":"workflow.v1","stages":[{"key":"gate","kind":"gate","approver":"user"},{"key":"after","depends_on":["gate"],"brief":{"goal":"After","acceptance":["done"]}}]}`).code,"ok")
    testing.expect_value(t,language_test_run(f,"gate","gate",`{}`).code,"ok")
    testing.expect_value(t,advanced_call(f,"workflow.gate","reject",`{"run_id":"gate","execution":"1","stage_key":"gate","verdict":"request_changes","summary":"Redo"}`).code,"ok")
    testing.expect_value(t,len(language_tasks(f,"gate","1","after")),0)
    testing.expect_value(t,advanced_call(f,"workflow.retry","retry_gate",`{"run_id":"gate","execution":"1"}`).code,"ok")
    testing.expect_value(t,advanced_call(f,"workflow.gate","old_approval",`{"run_id":"gate","execution":"1","stage_key":"gate","verdict":"approve","summary":"late"}`).code,"stale_revision")
    testing.expect_value(t,advanced_call(f,"workflow.gate","new_approval",`{"run_id":"gate","execution":"2","stage_key":"gate","verdict":"approve","summary":"Go"}`).code,"ok")
    testing.expect_value(t,len(language_tasks(f,"gate","2","after")),1)
}


coordinator_test_config :: proc(f:^Fixture,child:Child,revision,op:string)->Result {
    p:=encode(doc(map[string]string{"configuration_revision"=revision,"agent_id"=child.agent_id,"instance_id"=child.instance}))
    rows,_:=query(f.store.db,"SELECT revision FROM task_chains WHERE chain_id='chain'")
    raw:=command(f,"workflow.coordinator",op,"",p,rows[0][0])
    return execute(&f.store,raw,p,"",f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},child)
}
coordinator_test_raw :: proc(f:^Fixture,task,op,body,cap:string,child:Child,configuration:="1")->string {
    raw:=lifecycle_raw(f,child,"workflow.gate.post",op,body,cap,"1")
    c,_:=contracts.owner_parse(raw,"lifecycle_command")
    c["task_id"]=json.String(task);c["configuration_revision"]=json.String(configuration)
    sig,_:=test_sign(&f.owner_priv,"lifecycle_command",c);c["signature"]=json.String(sig)
    return encode(c)
}
@(test)
language_coordinator_gate_exact_binding_human_policy_and_replay :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    child:=lease_child()
    bound:=coordinator_test_config(f,child,"1","coordinator")
    if !testing.expect_value(t,bound.code,"ok") do return
    cap:=result_cap(bound)
    testing.expect(t,cap!="")
    testing.expect_value(t,language_test_define(f,"coord",`{"schema":"workflow.v1","stages":[{"key":"gate","kind":"gate","approver":"user_or_coordinator"},{"key":"human","kind":"gate","approver":"user"},{"key":"flagged","kind":"gate","requires_user_approval":true}]}`).code,"ok")
    testing.expect_value(t,language_test_run(f,"coord","coord",`{}`).code,"ok")
    gate:=language_tasks(f,"coord","1","gate")[0][0]
    payload:=`{"run_id":"coord","execution":"1","stage_key":"gate","verdict":"approve","summary":"Coordinator approval"}`
    raw:=coordinator_test_raw(f,gate,"coordinator_approve",payload,cap,child)
    other:=child;other.agent_id="another_agent"
    other_raw:=coordinator_test_raw(f,gate,"wrong_agent",payload,cap,other)
    testing.expect_value(t,execute_lifecycle(&f.store,other_raw,payload,cap,other,f.owner,1000,Signer{&f.owner_priv,test_sign}).code,"invalid_scope")
    testing.expect_value(t,execute_lifecycle(&f.store,raw,payload,cap,child,f.owner,1000+LEASE_TTL_MS,Signer{&f.owner_priv,test_sign}).code,"expired")
    approved:=execute_lifecycle(&f.store,raw,payload,cap,child,f.owner,1000,Signer{&f.owner_priv,test_sign})
    testing.expect_value(t,approved.code,"ok")
    replay:=execute_lifecycle(&f.store,raw,payload,cap,child,f.owner,1000+LEASE_TTL_MS,Signer{&f.owner_priv,test_sign})
    testing.expect(t,replay.code=="ok" && replay.replay)
    for key in ([2]string{"human","flagged"}) {
        task:=language_tasks(f,"coord","1",key)[0][0]
        body:=encode(doc(map[string]string{"run_id"="coord","execution"="1","stage_key"=key,"verdict"="approve","summary"="Not human"}))
        denied:=coordinator_test_raw(f,task,fmt.tprintf("deny_%s",key),body,cap,child)
        testing.expect_value(t,execute_lifecycle(&f.store,denied,body,cap,child,f.owner,1000,Signer{&f.owner_priv,test_sign}).code,"invalid_scope")
    }
    replacement:=child;replacement.epoch="replacement_epoch"
    new_binding:=coordinator_test_config(f,replacement,"2","replacement")
    testing.expect_value(t,new_binding.code,"ok")
    testing.expect_value(t,execute_lifecycle(&f.store,raw,payload,cap,child,f.owner,1000,Signer{&f.owner_priv,test_sign}).code,"invalid_scope")
}

@(test)
language_retry_never_reads_previous_execution_output :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    spec:=`{"schema":"workflow.v1","stages":[{"key":"source","brief":{"goal":"Source","output":"task_list.v1"}},{"key":"gate","kind":"gate","depends_on":["source"],"approver":"user"},{"key":"write","depends_on":["gate"],"for_each":"source.outputs[0].tasks","title":"{{item.goal}}","brief":{"goal":"{{item.goal}}","acceptance":["done"]}}]}`
    testing.expect_value(t,language_test_define(f,"stale",spec).code,"ok")
    testing.expect_value(t,language_test_run(f,"stale","stale",`{}`).code,"ok")
    language_finish(t,f,language_tasks(f,"stale","1","source")[0][0],`{"tasks":[{"goal":"old_output"}]}`)
    testing.expect_value(t,advanced_call(f,"workflow.gate","stale_reject",`{"run_id":"stale","execution":"1","stage_key":"gate","verdict":"request_changes","summary":"Redo"}`).code,"ok")
    testing.expect_value(t,advanced_call(f,"workflow.retry","stale_retry",`{"run_id":"stale","execution":"1"}`).code,"ok")
    history,_:=query(f.store.db,"SELECT state FROM local_workflow_language_executions WHERE run_id='stale' AND execution=1")
    testing.expect_value(t,history[0][0],"failed")
    testing.expect_value(t,len(language_tasks(f,"stale","2","write")),0)
    testing.expect_value(t,len(language_tasks(f,"stale","2","gate")),0)
    language_finish(t,f,language_tasks(f,"stale","2","source")[0][0],`{"tasks":[{"goal":"new_output"}]}`)
    testing.expect_value(t,advanced_call(f,"workflow.gate","fresh_gate",`{"run_id":"stale","execution":"2","stage_key":"gate","verdict":"approve","summary":"Go"}`).code,"ok")
    current:=language_tasks(f,"stale","2","write")
    if testing.expect_value(t,len(current),1) do testing.expect_value(t,current[0][1],"new_output")
}


@(test)
language_reference_resolution_preserves_builtin_aliases_and_exact_identity :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,language_test_define(f,"imported",string(#load("../../prompts/workflows/fix_flaky_tests.json"))).code,"ok")
    for ref in ([3]string{"fix_flaky_tests","tpl_fix_flaky_tests","builtin:fix_flaky_tests"}) {
        id,version,found:=language_resolve_ref(&f.store,"chain",ref)
        testing.expect(t,found && id=="imported" && version=="1",ref)
    }
    simple:=`{"schema":"workflow.v1","name":"exact","stages":[{"key":"a","brief":{"goal":"g","acceptance":["done"]}}]}`
    testing.expect_value(t,language_test_define(f,"exact",simple).code,"ok")
    alias:=encode(doc(map[string]string{"workflow_id"="alias","version"="2","title"="Alias","spec"=simple}))
    testing.expect_value(t,advanced_call(f,"workflow.define","alias",alias).code,"ok")
    id,version,found:=language_resolve_ref(&f.store,"chain","exact")
    testing.expect(t,found && id=="exact" && version=="1")
}

@(test)
language_on_output_without_output_contract_uses_empty_output_and_raw_bindings :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,language_test_define(f,"follow",`{"schema":"workflow.v1","stages":[{"key":"follow","brief":{"goal":"Follow","acceptance":["done"]}}]}`).code,"ok")
    testing.expect_value(t,language_test_define(f,"source",`{"schema":"workflow.v1","stages":[{"key":"source","brief":{"goal":"Source","acceptance":["done"],"on_output":{"workflow":"follow","inputs":{"rate":1.5,"items":[{"value":2.5}],"summary":"{{output}}"}}}}]}`).code,"ok")
    testing.expect_value(t,language_test_run(f,"source","source",`{}`).code,"ok")
    language_finish(t,f,language_tasks(f,"source","1","source")[0][0],"")
    rows,ok:=query(f.store.db,"SELECT json_extract(l.inputs_json,'$.rate'),json_extract(l.inputs_json,'$.items[0].value'),json_extract(l.inputs_json,'$.summary'),g.consumed FROM local_workflow_output_triggers g JOIN local_workflow_language_runs l ON l.chain_id=g.chain_id AND l.run_id=g.target_run WHERE g.source_run='source'")
    if testing.expect(t,ok && len(rows)==1) {
        testing.expect_value(t,rows[0][0],"1.5")
        testing.expect_value(t,rows[0][1],"2.5")
        testing.expect_value(t,rows[0][2],"{}")
        testing.expect_value(t,rows[0][3],"1")
    }
}

// Ordinary producers have task-attempt prerequisites, not invented workflow runs.
@(test)
language_ordinary_on_output_replay_restart_and_consumed_reopen :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,language_test_define(f,"follow",`{"schema":"workflow.v1","stages":[{"key":"follow","title":"Follow {{inputs.summary}}","brief":{"goal":"Follow","acceptance":["done"]}}]}`).code,"ok")
    brief:=`{"goal":"Ordinary producer","acceptance":["done"],"on_output":{"workflow":"follow","inputs":{"summary":"{{output.summary}}"}}}`
    req_payload:=encode(doc(map[string]string{"requirements_revision"="1","body_cipher"=cipher(f,brief)}))
    testing.expect_value(t,invoke(f,command(f,"requirements.edit","ordinary_brief","task",req_payload,"1"),req_payload).code,"ok")
    // Bind through current signed task revisions.
    child:=lease_child()
    payload:=encode(doc(map[string]string{"instance_id"=child.instance,"configuration_revision"="1","enabled"="1"}))
    rows,_:=query(f.store.db,"SELECT revision FROM tasks WHERE task_id='task'")
    testing.expect_value(t,execute(&f.store,command(f,"fleet.edit","ordinary_fleet","task",payload,rows[0][0]),payload,"",f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},child).code,"ok")
    payload=encode(doc(map[string]string{"configuration_revision"="1","author_agent_id"="author","reviewer_agent_id"="reviewer","reviewer_instance_id"="review_instance","directory_id"="directory","merge_policy"="none","repository"="","worktree"="","source_branch"="","target_branch"="","base_head"=""}))
    rows,_=query(f.store.db,"SELECT revision FROM tasks WHERE task_id='task'")
    testing.expect_value(t,execute(&f.store,command(f,"lifecycle.configure","ordinary_config","task",payload,rows[0][0]),payload,"",f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},{},Lifecycle_Proof{child,lifecycle_reviewer(),true}).code,"ok")
    rows,_=query(f.store.db,"SELECT revision FROM tasks WHERE task_id='task'")
    raw:=workflow_lease_raw(f,"task","ordinary_lease","ordinary_claim")
    c,_:=contracts.owner_parse(raw,"lease_command");c["expected_revision"]=json.String(rows[0][0])
    sig,_:=test_sign(&f.owner_priv,"lease_command",c);c["signature"]=json.String(sig)
    claimed:=lease_invoke(f,encode(c),"",child)
    if !testing.expect_value(t,claimed.code,"ok") do return
    cap:=result_cap(claimed)
    for method in ([2]string{"requirements.present","requirements.ack"}) {
        testing.expect_value(t,language_child_call(f,"task","ordinary_lease",child,method,method,`{"requirements_revision":"1"}`,cap).code,"ok")
    }
    testing.expect_value(t,language_child_call(f,"task","ordinary_lease",child,"lease.submit","ordinary_submit",`{"requirements_revision":"1","head":"","summary":"done","output":"{\"summary\":\"ordinary-bound\"}"}`,cap).code,"ok")
    verdict:=lifecycle_verdict()
    opened:=language_child_call(f,"task","ordinary_lease",lifecycle_reviewer(),"review.open","ordinary_open",verdict,"")
    if !testing.expect_value(t,opened.code,"ok") do return
    review_cap:=result_cap(opened)
    review_raw:=language_child_raw(f,"task","ordinary_lease",lifecycle_reviewer(),"review.post","ordinary_review",verdict,review_cap)
    testing.expect(t,exec(f.store.db,`CREATE TABLE ordinary_commit_fail(id INTEGER PRIMARY KEY);
      CREATE TABLE ordinary_commit_ref(id INTEGER REFERENCES ordinary_commit_fail(id) DEFERRABLE INITIALLY DEFERRED);
      CREATE TRIGGER ordinary_trigger_commit_failure AFTER INSERT ON local_workflow_output_triggers BEGIN INSERT INTO ordinary_commit_ref VALUES(1); END;`))
    failed:=execute_lifecycle(&f.store,review_raw,verdict,review_cap,lifecycle_reviewer(),f.owner,1000,Signer{&f.owner_priv,test_sign})
    testing.expect_value(t,failed.code,"storage_error")
    rolled_back,rollback_read:=query(f.store.db,"SELECT (SELECT count(*) FROM local_workflow_runs),(SELECT count(*) FROM local_workflow_output_triggers),(SELECT count(*) FROM command_receipts WHERE operation_id='ordinary_review'),(SELECT state FROM lifecycle_state WHERE task_id='task')")
    testing.expect(t,rollback_read && rolled_back[0][0]=="0" && rolled_back[0][1]=="0" && rolled_back[0][2]=="0" && rolled_back[0][3]=="in_review")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER ordinary_trigger_commit_failure"))
    approved:=execute_lifecycle(&f.store,review_raw,verdict,review_cap,lifecycle_reviewer(),f.owner,1000,Signer{&f.owner_priv,test_sign})
    testing.expect_value(t,approved.code,"ok")
    found,ok:=query(f.store.db,"SELECT source_run,source_execution,target_run,consumed FROM local_workflow_output_triggers WHERE source_task='task'")
    if !testing.expect(t,ok && len(found)==1) do return
    testing.expect_value(t,found[0][0],"")
    testing.expect_value(t,found[0][1],"")
    testing.expect_value(t,found[0][3],"1")
    follow:=language_tasks(f,found[0][2],"1","follow")
    if testing.expect_value(t,len(follow),1) do testing.expect_value(t,follow[0][1],"Follow ordinary-bound")
    replay:=execute_lifecycle(&f.store,review_raw,verdict,review_cap,lifecycle_reviewer(),f.owner,1000,Signer{&f.owner_priv,test_sign})
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==approved.body)
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    tx:Transaction
    testing.expect(t,transaction_begin(&f.store,&tx))
    testing.expect(t,workflow_refresh(&f.store))
    testing.expect(t,transaction_commit(&tx))
    found,ok=query(f.store.db,"SELECT target_run FROM local_workflow_output_triggers WHERE source_task='task'")
    testing.expect(t,ok && len(found)==1 && len(language_tasks(f,found[0][0],"1","follow"))==1)
    replay=execute_lifecycle(&f.store,review_raw,verdict,review_cap,lifecycle_reviewer(),f.owner,1000,Signer{&f.owner_priv,test_sign})
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==approved.body)
    testing.expect_value(t,advanced_call(f,"task.reopen","ordinary_reopen","retry","task").code,"operation_conflict")
}

@(test)
language_static_on_output_waits_for_run_and_fences_retry :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,language_test_define(f,"follow",`{"schema":"workflow.v1","stages":[{"key":"follow","brief":{"goal":"Follow","acceptance":["done"]}}]}`).code,"ok")
    def,_:=contracts.owner_parse(workflow_test_definition(),"workflow_definition")
    v,_:=contracts.owner_request_document(field(def,"stages"));stages,_:=v.(json.Array)
    first,_:=stages[0].(json.Object)
    first["brief"]=json.String(`{"goal":"Source","acceptance":["done"],"on_output":{"workflow":"follow"}}`)
    def["stages"]=json.String(encode(stages))
    testing.expect_value(t,advanced_call(f,"workflow.define","static_define",encode(def)).code,"ok")
    testing.expect_value(t,advanced_call(f,"workflow.run","static_run",`{"run_id":"static","workflow_id":"definition","version":"1"}`).code,"ok")
    language_finish(t,f,workflow_task_id("chain","static","1","first"),"")
    rows,ok:=query(f.store.db,"SELECT target_run,consumed FROM local_workflow_output_triggers WHERE source_run='static'")
    if !testing.expect(t,ok && len(rows)==1) do return
    testing.expect_value(t,rows[0][1],"0")
    testing.expect_value(t,len(language_tasks(f,rows[0][0],"1","follow")),0)
    language_finish(t,f,workflow_task_id("chain","static","1","second"),"")
    testing.expect_value(t,len(language_tasks(f,rows[0][0],"1","follow")),1)
    testing.expect_value(t,advanced_call(f,"workflow.retry","static_consumed_retry",`{"run_id":"static","execution":"1"}`).code,"operation_conflict")
    testing.expect_value(t,advanced_call(f,"workflow.run","static_unconsumed_run",`{"run_id":"stale_static","workflow_id":"definition","version":"1"}`).code,"ok")
    language_finish(t,f,workflow_task_id("chain","stale_static","1","first"),"")
    stale_rows,stale_read:=query(f.store.db,"SELECT target_run FROM local_workflow_output_triggers WHERE source_run='stale_static'")
    if !testing.expect(t,stale_read && len(stale_rows)==1) do return
    testing.expect_value(t,advanced_call(f,"workflow.retry","static_unconsumed_retry",`{"run_id":"stale_static","execution":"1"}`).code,"ok")
    states,read:=query(f.store.db,"SELECT state,failure FROM local_workflow_language_executions WHERE run_id=?",stale_rows[0][0])
    testing.expect(t,read && len(states)==1 && states[0][0]=="failed" && states[0][1]=="stale_source_execution")
    testing.expect_value(t,len(language_tasks(f,stale_rows[0][0],"1","follow")),0)

}

@(test)
language_on_output_capacity_failure_is_durable_and_visible :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,language_test_define(f,"follow",`{"schema":"workflow.v1","stages":[{"key":"follow","brief":{"goal":"Follow","acceptance":["done"]}}]}`).code,"ok")
    testing.expect_value(t,language_test_define(f,"source",`{"schema":"workflow.v1","stages":[{"key":"source","brief":{"goal":"Source","acceptance":["done"],"on_output":{"workflow":"follow"}}}]}`).code,"ok")
    testing.expect_value(t,language_test_run(f,"source","source","{}").code,"ok")
    // Fill through the signed public path to exactly128 retained runs.
    for i in 0..<127 {
        id:=fmt.tprintf("budget_%d",i)
        if !testing.expect_value(t,language_test_run(f,"follow",id,"{}").code,"ok") do return
    }
    task:=language_tasks(f,"source","1","source")[0][0]
    language_finish(t,f,task,"")
    for i in 0..<2 {
        close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
        tx:Transaction
        testing.expect(t,transaction_begin(&f.store,&tx))
        testing.expect(t,workflow_refresh(&f.store))
        testing.expect(t,transaction_commit(&tx))
        rows,ok:=query(f.store.db,"SELECT (SELECT count(*) FROM local_workflow_runs),(SELECT count(*) FROM local_workflow_output_triggers),(SELECT count(*) FROM local_workflow_trigger_failures WHERE reason='workflow_budget')")
        testing.expect(t,ok && rows[0][0]=="128" && rows[0][1]=="0" && rows[0][2]=="1",fmt.tprintf("restart %d",i))
        cursor:=""
        visible:=false
        for page in 0..<10 {
            inventory:=workflow_inventory(&f.store,"chain",cursor,100,1)
            testing.expect_value(t,inventory.code,"ok")
            if strings.contains(inventory.body,"workflow_budget") do visible=true
            v,valid:=contracts.owner_request_document(inventory.body);o,obj:=v.(json.Object)
            if !valid || !obj { testing.expect(t,false);break }
            cursor=field(o,"next_cursor")
            if cursor=="" do break
        }
        testing.expect(t,visible)
    }
}
