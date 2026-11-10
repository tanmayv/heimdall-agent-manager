#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

advanced_call :: proc(f:^Fixture,method,op,body:string,task:string="",children:[]Child=nil,now:i64=1000)->Result {
    rows,ok:=query(f.store.db,"SELECT revision FROM task_chains WHERE chain_id='chain'")
    if task!="" do rows,ok=query(f.store.db,"SELECT revision FROM tasks WHERE chain_id='chain' AND task_id=?",task)
    if !ok || len(rows)!=1 do return fail("storage_error")
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,body)}))
    if method=="dependency.edit" do p=body
    raw:=command(f,method,op,task,p,rows[0][0],now+1000)
    if !observe_directory(&f.store,1,"head") do return fail("invalid_scope")
    return execute(&f.store,raw,p,f.genesis,f.creator,f.owner,1,"head",now,&f.kr,Signer{&f.owner_priv,test_sign},{},{},children)
}
workflow_test_definition :: proc()->string {
    stages:=[2]json.Object{
        doc(map[string]string{"key"="first","title"="First stage","body"="workflowsearchneedle","brief"=`{"goal":"First","acceptance":["Pass"]}`,"depends_on"="[]"}),
        doc(map[string]string{"key"="second","title"="Second stage","body"="Second output","brief"=`{"goal":"Second","acceptance":["Pass"]}`,"depends_on"=`["first"]`}),
    }
    return encode(doc(map[string]string{"workflow_id"="definition","version"="1","title"="workflowsearchneedle","stages"=encode(stages)}))
}
workflow_bind :: proc(t:^testing.T,f:^Fixture,task:string) {
    child:=lease_child()
    p:=`{"instance_id":"instance","configuration_revision":"1","enabled":"1"}`
    child.instance="instance"
    // Use actual test child's identity rather than a caller assertion.
    p=encode(doc(map[string]string{"instance_id"=child.instance,"configuration_revision"="1","enabled"="1"}))
    r:=execute(&f.store,command(f,"fleet.edit",fmt.tprintf("fleet_%s",task),task,p,"1"),p,"",f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},child)
    testing.expect_value(t,r.code,"ok")
    p=encode(doc(map[string]string{"configuration_revision"="1","author_agent_id"="author","reviewer_agent_id"="reviewer","reviewer_instance_id"="review_instance","directory_id"="directory","merge_policy"="none","repository"="","worktree"="","source_branch"="","target_branch"="","base_head"=""}))
    r=execute(&f.store,command(f,"lifecycle.configure",fmt.tprintf("config_%s",task),task,p,"2"),p,"",f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},{},Lifecycle_Proof{child,lifecycle_reviewer(),true})
    testing.expect_value(t,r.code,"ok")
}
workflow_lease_raw :: proc(f:^Fixture,task,lease,op:string)->string {
    raw:=lease_request(f,lease_child(),"lease.claim",op,lease,"","3")
    c,_:=contracts.owner_parse(raw,"lease_command")
    c["task_id"]=json.String(task)
    sig,_:=test_sign(&f.owner_priv,"lease_command",c);c["signature"]=json.String(sig)
    return encode(c)
}
@(test)
workflow_expansion_retry_replay_and_dependency_guards :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,advanced_call(f,"workflow.define","define",workflow_test_definition()).code,"ok")
    testing.expect_value(t,advanced_call(f,"workflow.run","run",`{"run_id":"run","workflow_id":"definition","version":"1"}`).code,"ok")
    first:=workflow_task_id("chain","run","1","first");second:=workflow_task_id("chain","run","1","second")
    testing.expect(t,dependency_ready(&f.store,"chain",first) && !dependency_ready(&f.store,"chain",second))
    workflow_bind(t,f,first);workflow_bind(t,f,second)
    blocked:=lease_invoke(f,workflow_lease_raw(f,second,"blocked_lease","blocked"),"",lease_child())
    testing.expect_value(t,blocked.code,"operation_conflict")
    claim:=workflow_lease_raw(f,first,"workflow_lease","claim_workflow")
    claimed:=lease_invoke(f,claim,"",lease_child())
    if !testing.expect_value(t,claimed.code,"ok") do return
    testing.expect_value(t,advanced_call(f,"workflow.retry","retry",`{"run_id":"run","execution":"1"}`).code,"ok")
    replay:=lease_invoke(f,claim,"",lease_child())
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==claimed.body,"historical grant replay remains read-only")
    testing.expect_value(t,lease_invoke(f,workflow_lease_raw(f,first,"old_new_lease","old_new_op"),"",lease_child()).code,"stale_revision")
    testing.expect_value(t,advanced_call(f,"workflow.retry","stale_retry",`{"run_id":"run","execution":"1"}`).code,"stale_revision")
    rows,ok:=query(f.store.db,"SELECT (SELECT count(*) FROM local_workflow_tasks),(SELECT count(*) FROM local_workflow_events),(SELECT state FROM local_workflow_executions WHERE execution=1),(SELECT count(*) FROM local_leases WHERE retired_seq IS NULL),(SELECT count(*) FROM runtime_intents WHERE kind='registry' AND destination_bridge!='')")
    testing.expect(t,ok && rows[0][0]=="4" && rows[0][1]=="2" && rows[0][2]=="superseded" && rows[0][3]=="0" && rows[0][4]=="4")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect(t,dependency_ready(&f.store,"chain",workflow_task_id("chain","run","2","first")))
    testing.expect(t,strings.contains(search_for(f,"workflowsearchneedle").body,"workflow"))
}
@(test)
workflow_commit_failure_rolls_back_expansion_receipt_fts_sources_and_publication :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,advanced_call(f,"workflow.define","define",workflow_test_definition()).code,"ok")
    testing.expect(t,exec(f.store.db,`CREATE TABLE workflow_failure(id INTEGER PRIMARY KEY);
      CREATE TABLE workflow_failure_ref(id INTEGER REFERENCES workflow_failure(id) DEFERRABLE INITIALLY DEFERRED);
      CREATE TRIGGER workflow_commit_failure AFTER INSERT ON local_workflow_tasks BEGIN INSERT INTO workflow_failure_ref VALUES(1); END;`))
    testing.expect_value(t,advanced_call(f,"workflow.run","run",`{"run_id":"run","workflow_id":"definition","version":"1"}`).code,"storage_error")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM local_workflow_runs),(SELECT count(*) FROM local_workflow_tasks),(SELECT count(*) FROM source_episodes),(SELECT count(*) FROM command_receipts WHERE operation_id='run'),(SELECT count(*) FROM tasks),(SELECT count(*) FROM runtime_intents WHERE operation_id='run')")
    testing.expect(t,rows[0][0]=="0" && rows[0][1]=="0" && rows[0][2]=="0" && rows[0][3]=="0" && rows[0][4]=="1" && rows[0][5]=="0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER workflow_commit_failure"))
    testing.expect_value(t,advanced_call(f,"workflow.run","run",`{"run_id":"run","workflow_id":"definition","version":"1"}`).code,"ok")
}
@(test)
workflow_definition_and_same_chain_dependency_cycles_reject :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    def,_:=contracts.owner_parse(workflow_test_definition(),"workflow_definition")
    v,_:=contracts.owner_request_document(field(def,"stages"));stages,_:=v.(json.Array)
    stage,_:=stages[0].(json.Object);stage["depends_on"]=json.String(`["second"]`)
    def["stages"]=json.String(encode(stages))
    testing.expect_value(t,advanced_call(f,"workflow.define","bad_define",encode(def)).code,"invalid_content")
    testing.expect(t,exec(f.store.db,"INSERT INTO tasks VALUES('chain','other','other','other',1); INSERT INTO task_chains VALUES('alien','device','device','alien','alien',1); INSERT INTO tasks VALUES('alien','alien_task','alien','alien',1);"))
    testing.expect_value(t,advanced_call(f,"dependency.edit","dep",`{"prerequisite":"other","enabled":"1"}`,"task").code,"ok")
    testing.expect_value(t,advanced_call(f,"dependency.edit","cycle",`{"prerequisite":"task","enabled":"1"}`,"other").code,"operation_conflict")
    testing.expect_value(t,advanced_call(f,"dependency.edit","cross",`{"prerequisite":"alien_task","enabled":"1"}`,"other").code,"operation_conflict")
    testing.expect(t,!dependency_ready(&f.store,"chain","task"))
    testing.expect_value(t,advanced_call(f,"workflow.define","static_define",workflow_test_definition()).code,"ok")
    testing.expect_value(t,advanced_call(f,"workflow.run","static_run",`{"run_id":"run","workflow_id":"definition","version":"1"}`).code,"ok")
    edge:=encode(doc(map[string]string{"prerequisite"=workflow_task_id("chain","run","1","first"),"enabled"="1"}))
    testing.expect_value(t,advanced_call(f,"dependency.edit","private_stage",edge,"other").code,"operation_conflict")
}

@(test)
workflow_v8_upgrade_collision_and_commit_failure_preserve_live_capability :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);cap:=lifecycle_ready(t,f)
    preserved_sql:=`SELECT (SELECT json_group_array(json_array(chain_id,principal_id,key_id,revision,expires_ms,can_read,can_mutate,revoked)) FROM local_grants),
      (SELECT json_group_array(json_array(chain_id,revision,recovery_enabled)) FROM local_grant_policy),
      (SELECT json_group_array(json_array(seq,command_json,payload_json)) FROM local_grant_audit),
      (SELECT json_group_array(json_array(principal_id,operation_id,input_digest,result_json)) FROM command_receipts)`
    before,checked:=query(f.store.db,preserved_sql)
    testing.expect(t,checked && len(before)==1)
    close(&f.store)
    db:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    testing.expect(t,exec(db,V9_TEST_DROP))
    prefix:=string(MIGRATION_008);prefix=prefix[:strings.index(prefix,"-- Existing profiles")]
    testing.expect(t,exec(db,prefix))
    testing.expect(t,exec(db,"DROP TABLE IF EXISTS owner_execution_stop_steps; UPDATE schema_migrations SET version=8; CREATE INDEX local_review_holder ON local_review_sessions(json_extract(child,'$.instance')); CREATE VIEW local_workflow_runs AS SELECT 1;"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_:=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations),(SELECT count(*) FROM local_leases WHERE retired_seq IS NULL),(SELECT count(*) FROM sqlite_master WHERE name='local_workflow_definitions') FROM runtime_database")
    testing.expect(t,rows[0][0]=="8" && rows[0][1]=="8" && rows[0][2]=="1" && rows[0][3]=="0")
    testing.expect(t,exec(db,`DROP VIEW local_workflow_runs;
      CREATE TABLE v9_failure(id INTEGER PRIMARY KEY);
      CREATE TABLE v9_failure_ref(id INTEGER REFERENCES v9_failure(id) DEFERRABLE INITIALLY DEFERRED);
      CREATE TRIGGER v9_commit_failure AFTER UPDATE ON schema_migrations WHEN NEW.version=9 BEGIN INSERT INTO v9_failure_ref VALUES(1); END;`))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations),(SELECT count(*) FROM sqlite_master WHERE name='source_episodes') FROM runtime_database")
    testing.expect(t,rows[0][0]=="8" && rows[0][1]=="8" && rows[0][2]=="0")
    testing.expect(t,exec(db,"DROP TRIGGER v9_commit_failure"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    after,preserved:=query(f.store.db,preserved_sql)
    if testing.expect(t,preserved && len(after)==1) {
        for value,i in before[0] do testing.expect_value(t,after[0][i],value)
    }
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.present","v9_present",`{"requirements_revision":"1"}`,cap).code,"ok")
    rows,_=query(f.store.db,"PRAGMA foreign_key_check")
    testing.expect_value(t,len(rows),0)
}

@(test)
workflow_inventory_pages_history_and_invalidates_stale_cursor :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,advanced_call(f,"workflow.define","definition",workflow_test_definition()).code,"ok")
    testing.expect_value(t,advanced_call(f,"workflow.run","run",`{"run_id":"run","workflow_id":"definition","version":"1"}`).code,"ok")
    testing.expect_value(t,advanced_call(f,"workflow.retry","retry",`{"run_id":"run","execution":"1"}`).code,"ok")
    cursor,old:="",""
    count:=0
    for i:=0;i<20;i+=1 {
        r:=workflow_inventory(&f.store,"chain",cursor,1,1)
        if !testing.expect_value(t,r.code,"ok") do return
        v,_:=contracts.owner_request_document(r.body);o,_:=v.(json.Object)
        for name in ([3]string{"runs","tasks","events"}) {a,_:=o[name].(json.Array);count+=len(a)}
        next:=field(o,"next_cursor")
        if old=="" do old=next
        if next=="" do break
        testing.expect(t,next!=cursor)
        cursor=next
    }
    testing.expect_value(t,count,7)
    testing.expect_value(t,advanced_call(f,"source.observe","fact",source_fact_test("page","1","0")).code,"ok")
    testing.expect_value(t,workflow_inventory(&f.store,"chain",old,1,1).code,"stale_cursor")
}
