#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:testing"
import contracts "odin_test:contracts"

work_seed :: proc(t:^testing.T,f:^Fixture) {
    g,_:=contracts.owner_parse(f.genesis,"genesis");digest,_:=contracts.owner_digest("genesis",g)
    p:=encode(doc(map[string]string{"genesis_digest"=digest,"title_cipher"=cipher(f,"chain"),"description_cipher"=cipher(f,"scope")}))
    testing.expect_value(t,invoke(f,command(f,"chain.create","create","",p,"0"),p).code,"ok")
}
work_call :: proc(f:^Fixture,method,op,body:string,task:string="",revision:string="")->Result {
    rev:=revision
    if rev=="" {
        rev=summary_revision(f)
        if method=="task.publish" {
            rows,_:=query(f.store.db,"SELECT revision FROM tasks WHERE chain_id='chain' AND task_id=?",task)
            if len(rows)==1 do rev=rows[0][0]
        }
    }
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,body)}))
    return invoke(f,command(f,method,op,task,p,rev),p)
}
work_draft_task :: proc(f:^Fixture,id,op:string)->Result {
    p:=encode(doc(map[string]string{"title_cipher"=cipher(f,id),"body_cipher"=cipher(f,"draft body")}))
    return invoke(f,command(f,"task.draft",op,id,p,summary_revision(f)),p)
}
work_state :: proc(f:^Fixture)->string {
    rows,_:=query(f.store.db,"SELECT name FROM sqlite_master WHERE type='table' AND name!='sqlite_sequence' ORDER BY name")
    values:=make([dynamic]string,context.temp_allocator)
    for row in rows {
        if row[0]=="runtime_database" do continue
        records,ok:=query(f.store.db,fmt.tprintf("SELECT * FROM %s ORDER BY rowid",row[0]))
        if ok do append(&values,encode(records))
    }
    return encode(values)
}
work_plan :: proc()->string {return `{"kind":"task","tasks":[{"id":"first","title":"First","brief":{"goal":"First goal","acceptance":["Verified"]}},{"id":"second","title":"Second","priority":"p1","brief":{"goal":"Second goal","acceptance":["Verified"]},"depends_on":["first"]}],"rationale":"Native ordering","alternative":"No parallel shortcut"}`}
@(test)
work_proposal_decision_publishes_atomically_and_retains_exact_replay_history :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);work_seed(t,f)
    testing.expect_value(t,work_call(f,"chain.draft","draft_chain","{}").code,"ok")
    testing.expect_value(t,work_call(f,"chain.propose","proposal",work_plan()).code,"ok")
    rows,_:=query(f.store.db,"SELECT count(*) FROM tasks")
    testing.expect_value(t,rows[0][0],"0")
    pending,id,ok:=work_pending(&f.store,"chain");testing.expect(t,ok && pending!=nil && id=="proposal")
    testing.expect_value(t,work_call(f,"chain.publish","bypass_decision","{}").code,"operation_conflict")
    testing.expect_value(t,work_call(f,"chain.propose","duplicate_proposal",work_plan()).code,"operation_conflict")
    testing.expect_value(t,work_call(f,"chain.decide","wrong_id",`{"proposal_id":"other","decision":"approve","note":""}`).code,"stale_revision")
    before:=summary_revision(f)
    testing.expect_value(t,work_call(f,"chain.decide","approve",`{"proposal_id":"proposal","decision":"approve","note":"Approved plan"}`).code,"ok")
    testing.expect_value(t,metadata_replay(f,"approve").code,"ok")
    testing.expect(t,metadata_replay(f,"approve").replay)
    testing.expect_value(t,work_call(f,"chain.decide","stale",`{"proposal_id":"proposal","decision":"approve","note":""}`,"",before).code,"stale_revision")
    rows,_=query(f.store.db,"SELECT count(*),(SELECT count(*) FROM local_work_active_dependencies),(SELECT count(*) FROM local_work_decisions),(SELECT publish_state FROM local_work_chains) FROM tasks")
    testing.expect_value(t,encode(rows),encode([1][4]string{{"2","1","1","published"}}))
    testing.expect(t,work_task_published(&f.store,"chain","first") && work_inputs_ready(&f.store,"chain","task","first") && !work_inputs_ready(&f.store,"chain","task","second"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM local_work_proposals"))
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect(t,metadata_replay(f,"approve").replay)
    p:=encode(doc(map[string]string{"cursor"="","limit"="3"}))
    read:=invoke(f,command(f,"work.read","work_read","",p,"0"),p)
    testing.expect_value(t,read.code,"ok")
}
@(test)
work_auto_approve_and_explicit_drafts_preserve_publication_ordering :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);work_seed(t,f)
    testing.expect_value(t,work_draft_task(f,"task","draft_task").code,"ok")
    testing.expect(t,!work_task_published(&f.store,"chain","task"))
    testing.expect_value(t,work_call(f,"task.publish","incomplete","{}","task").code,"invalid_content")
    brief:=`{"goal":"Ready","acceptance":["Publish is explicit"]}`
    p:=encode(doc(map[string]string{"requirements_revision"="1","body_cipher"=cipher(f,brief)}))
    testing.expect_value(t,invoke(f,command(f,"requirements.edit","draft_brief","task",p,"1"),p).code,"ok")
    testing.expect_value(t,work_call(f,"task.publish","publish_draft","{}","task").code,"ok")
    testing.expect(t,work_task_published(&f.store,"chain","task"))
    testing.expect_value(t,work_call(f,"task.publish","published_again","{}","task").code,"operation_conflict")
    v,_:=contracts.owner_content_document(work_plan());plan,_:=v.(json.Object)
    plan["auto_approve"]=json.Boolean(true)
    testing.expect_value(t,work_call(f,"chain.propose","auto_proposal",encode(plan)).code,"ok")
    pending,_,ok:=work_pending(&f.store,"chain");testing.expect(t,ok && pending==nil)
    rows,_:=query(f.store.db,"SELECT decision FROM local_work_decisions WHERE proposal_id='auto_proposal'")
    testing.expect_value(t,rows[0][0],"approve")
}
@(test)
work_publication_cycle_and_failed_event_or_commit_leave_no_partial_materialization :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);work_seed(t,f)
    plan:=`{"kind":"task","tasks":[{"id":"a","title":"A","brief":{"goal":"A","acceptance":["done"]},"depends_on":["b"]},{"id":"b","title":"B","brief":{"goal":"B","acceptance":["done"]},"depends_on":["a"]}]}`
    testing.expect_value(t,work_call(f,"chain.propose","cyclic",plan).code,"ok")
    before:=work_state(f)
    testing.expect_value(t,work_call(f,"chain.decide","cycle_approve",`{"proposal_id":"cyclic","decision":"approve","note":""}`).code,"operation_conflict")
    testing.expect_value(t,work_state(f),before)
    testing.expect_value(t,work_call(f,"chain.decide","reject_cycle",`{"proposal_id":"cyclic","decision":"reject","note":"Replace cycle"}`).code,"ok")
    testing.expect_value(t,work_call(f,"chain.propose","valid_plan",work_plan()).code,"ok")
    before=work_state(f)
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER work_fail BEFORE INSERT ON local_events WHEN NEW.kind='chain.decide' BEGIN SELECT RAISE(ABORT,'fixture'); END"))
    testing.expect_value(t,work_call(f,"chain.decide","event_fail",`{"proposal_id":"valid_plan","decision":"approve","note":""}`).code,"storage_error")
    testing.expect_value(t,work_state(f),before)
    testing.expect(t,exec(f.store.db,"DROP TRIGGER work_fail; CREATE TABLE work_parent(id INTEGER PRIMARY KEY); CREATE TABLE work_ref(id INTEGER REFERENCES work_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER work_fail AFTER INSERT ON local_work_decisions BEGIN INSERT INTO work_ref VALUES(1); END"))
    // Ignore the two empty fault-injection tables in the comparison snapshot.
    before=work_state(f)
    testing.expect_value(t,work_call(f,"chain.decide","commit_fail",`{"proposal_id":"valid_plan","decision":"approve","note":""}`).code,"storage_error")
    testing.expect_value(t,work_state(f),before)
}

@(test)
work_native_pending_metadata_preserves_original_actor_and_time_and_approves :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);work_seed(t,f)
    raw:=`{ "proposal":{"status":"pending","proposed_by_kind":"coordinator","proposed_by_id":"native_coordinator","proposed_by":"native_coordinator","proposed_at":"2025-01-02T03:04:05Z","created_at_ms":9007199254740993,"tasks":[{"id":"first","title":"Native","goal":"Native goal","acceptance":["Native accepted"]}]}, "other":17 }`
    testing.expect_value(t,defaults_call(f,raw,"legacy_pending",summary_revision(f)).code,"ok")
    testing.expect_value(t,work_call(f,"chain.decide","approve_legacy",`{"proposal_id":"legacy_pending","decision":"approve","note":"Preserve source"}`).code,"ok")
    rows,_:=query(f.store.db,"SELECT actor_kind,actor_id,created_at FROM local_work_proposals")
    testing.expect_value(t,encode(rows),encode([1][3]string{{"coordinator","native_coordinator","2025-01-02T03:04:05Z"}}))
    rows,_=query(f.store.db,"SELECT defaults_json FROM local_chain_defaults_versions ORDER BY accepted_seq LIMIT 1")
    testing.expect_value(t,rows[0][0],raw)
    pending,_,ok:=work_pending(&f.store,"chain")
    testing.expect(t,ok && pending==nil)
    testing.expect(t,metadata_replay(f,"approve_legacy").replay)
}
@(test)
work_mixed_and_legacy_edges_share_cycle_detection :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);work_seed(t,f)
    v,_:=contracts.owner_content_document(work_plan());plan,_:=v.(json.Object);plan["auto_approve"]=json.Boolean(true)
    testing.expect_value(t,work_call(f,"chain.propose","plan",encode(plan)).code,"ok")
    p:=`{"prerequisite":"second","enabled":"1"}`
    testing.expect_value(t,advanced_call(f,"dependency.edit","legacy_cross_cycle",p,"first").code,"operation_conflict")
    rows,_:=query(f.store.db,"SELECT count(*) FROM local_dependencies")
    testing.expect_value(t,rows[0][0],"0")
}

@(test)
work_revision_tracks_legacy_graph_and_control_changes_without_receipt_replay_mutation :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);work_seed(t,f)
    v,_:=contracts.owner_content_document(work_plan());plan,_:=v.(json.Object);plan["auto_approve"]=json.Boolean(true)
    tasks,_:=plan["tasks"].(json.Array);second,_:=tasks[1].(json.Object);delete_key(&second,"depends_on")
    testing.expect_value(t,work_call(f,"chain.propose","plan",encode(plan)).code,"ok")
    revision:=work_revision(f)
    testing.expect_value(t,advanced_call(f,"dependency.edit","legacy_edge",`{"prerequisite":"first","enabled":"1"}`,"second").code,"ok")
    testing.expect(t,number(work_revision(f))>number(revision))
    testing.expect(t,!work_inputs_ready(&f.store,"chain","task","second"))
    revision=work_revision(f)
    testing.expect(t,metadata_replay(f,"legacy_edge").replay)
    testing.expect_value(t,work_revision(f),revision)
    testing.expect_value(t,work_call(f,"task.cancel","cancel","Terminal cancellation","first",work_task_revision(f,"first")).code,"ok")
    testing.expect(t,number(work_revision(f))>number(revision))
}
