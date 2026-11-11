#+feature dynamic-literals
package owner_local
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

search_for :: proc(f:^Fixture,text:string,limit:string="50")->Result {
    p:=encode(doc(map[string]string{"query_cipher"=cipher(f,text),"limit"=limit}))
    return invoke(f,command(f,"chain.search","search","",p,"0"),p)
}
search_hits :: proc(result:Result)->json.Array {
    v,_:=json.parse_string(result.body,.JSON,true,context.temp_allocator)
    o,_:=v.(json.Object)
    a,_:=o["hits"].(json.Array)
    return a
}
@(test)
search_commits_updates_deletes_rebuilds_and_rejects_resurrection :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,search_for(f,"private").code,"ok")
    testing.expect_value(t,len(search_hits(search_for(f,"private"))),1)
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,"héllø 世界 needlecomment")}))
    c:=command(f,"task.comment","comment","task",p,"1")
    testing.expect_value(t,invoke(f,c,p).code,"ok")
    testing.expect_value(t,len(search_hits(search_for(f,"世界"))),1)
    testing.expect_value(t,len(search_hits(search_for(f,"needlecomment"))),1)
    p=encode(doc(map[string]string{"title_cipher"=cipher(f,"newtitle"),"body_cipher"=cipher(f,"newbody")}))
    c=command(f,"task.edit","edit","task",p,"2")
    testing.expect_value(t,invoke(f,c,p).code,"ok")
    testing.expect(t,invoke(f,c,p).replay)
    testing.expect_value(t,len(search_hits(search_for(f,"private"))),0)
    testing.expect_value(t,len(search_hits(search_for(f,"newbody"))),1)
    close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,len(search_hits(search_for(f,"newbody"))),1)
    testing.expect_value(t,len(search_hits(search_for(f,"needlecomment"))),1)
    p=encode(doc(map[string]string{"protocol_version"="1"}))
    c=command(f,"task.delete","delete","task",p,"3")
    testing.expect_value(t,invoke(f,c,p).code,"ok")
    testing.expect(t,invoke(f,c,p).replay,"delete historical replay survives removed row")
    testing.expect_value(t,len(search_hits(search_for(f,"newbody"))),0)
    testing.expect_value(t,len(search_hits(search_for(f,"needlecomment"))),0)
    testing.expect(t,search_rebuild(&f.store))
    testing.expect_value(t,len(search_hits(search_for(f,"needlecomment"))),0)
    p=encode(doc(map[string]string{"title_cipher"=cipher(f,"resurrect"),"body_cipher"=cipher(f,"resurrect")}))
    testing.expect_value(t,invoke(f,command(f,"task.create","recreate","task",p,"5"),p).code,"retired")
}
@(test)
search_scope_signature_read_right_and_revocation_precede_snippets :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect(t,exec(f.store.db,"INSERT INTO task_chains VALUES('hidden','other','other','private hidden','forbidden snippet',1)"))
    result:=search_for(f,"private")
    testing.expect_value(t,len(search_hits(result)),1)
    testing.expect(t,!strings.contains(result.body,"forbidden") && !strings.contains(result.body,"hidden"))
    _,_=query(f.store.db,"UPDATE local_grants SET can_mutate=0")
    testing.expect_value(t,search_for(f,"private").code,"ok")
    p:=encode(doc(map[string]string{"query_cipher"=cipher(f,"private"),"limit"="50"}))
    raw:=command(f,"chain.search","forged","",p,"0")
    c,_:=contracts.owner_parse(raw,"command")
    c["signature"]=json.String(strings.repeat("0",128,context.temp_allocator))
    testing.expect_value(t,invoke(f,encode(c),p).code,"bad_signature")
    f.creator.revoked=true // the device itself is revoked
    result=search_for(f,"private")
    testing.expect(t,result.code=="invalid_scope" && result.body=="")
}
@(test)
search_failed_commit_rolls_back_canonical_postings_receipts_and_tombstones :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER fail_search_receipt BEFORE INSERT ON command_receipts BEGIN SELECT RAISE(ABORT,'failure'); END"))
    p:=encode(doc(map[string]string{"title_cipher"=cipher(f,"failededit"),"body_cipher"=cipher(f,"failededit")}))
    testing.expect_value(t,invoke(f,command(f,"task.edit","failed","task",p,"1"),p).code,"storage_error")
    testing.expect_value(t,len(search_hits(search_for(f,"failededit"))),0)
    testing.expect_value(t,len(search_hits(search_for(f,"private"))),1)
    p=encode(doc(map[string]string{"protocol_version"="1"}))
    testing.expect_value(t,invoke(f,command(f,"task.delete","faileddelete","task",p,"1"),p).code,"storage_error")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM task_deletions),(SELECT count(*) FROM tasks)")
    testing.expect(t,rows[0][0]=="0" && rows[0][1]=="1")
    testing.expect_value(t,len(search_hits(search_for(f,"private"))),1)
}
@(test)
search_literal_bounds_key_unavailable_and_repair_failure_are_closed :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    for text in ([5]string{"\" OR secret","NEAR(private)","private*","世界","a-b"}) {
        testing.expect_value(t,search_for(f,text).code,"ok")
    }
    testing.expect_value(t,search_for(f,"private","51").code,"malformed")
    testing.expect_value(t,search_for(f,strings.repeat("q",257,context.temp_allocator)).code,"malformed")
    p:=encode(doc(map[string]string{"query_cipher"=cipher(f,"private"),"limit"="50"}))
    raw:=command(f,"chain.search","keymissing","",p,"0")
    testing.expect_value(t,execute(&f.store,raw,p,"",f.creator,f.owner,1,"head",1000,nil,{}).code,"invalid_content")
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER fail_rebuild BEFORE INSERT ON search_docs BEGIN SELECT RAISE(ABORT,'failure'); END"))
    testing.expect(t,!search_rebuild(&f.store))
    testing.expect_value(t,search_for(f,"private").code,"storage_error")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER fail_rebuild"))
    testing.expect(t,search_rebuild(&f.store))
    testing.expect_value(t,len(search_hits(search_for(f,"private"))),1)
}
@(test)
search_lifecycle_sources_are_current_and_protected_from_content_delete :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    lifecycle_seed(t,f)
    testing.expect_value(t,len(search_hits(search_for(f,"goal"))),1)
    cap:=lifecycle_ready(t,f)
    payload:="{\"requirements_revision\":\"1\",\"head\":\"\",\"summary\":\"searchoutputproof\"}"
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","submit_search",payload,cap).code,"ok")
    testing.expect_value(t,len(search_hits(search_for(f,"searchoutputproof"))),1)
    p:=encode(doc(map[string]string{"protocol_version"="1"}))
    testing.expect_value(t,invoke(f,command(f,"task.delete","protected","task",p,"5"),p).code,"operation_conflict")
}

history_submit :: proc(t:^testing.T,f:^Fixture,lease,revision,summary:string) {
    child:=lease_child()
    claimed:=lease_invoke(f,lease_request(f,child,"lease.claim",fmt.tprintf("claim_%s",lease),lease,"",revision),"",child)
    if !testing.expect_value(t,claimed.code,"ok") do testing.fail_now(t,"history claim")
    cap:=result_cap(claimed)
    for method in ([3]string{"requirements.present","requirements.ack","lease.submit"}) {
        p:=encode(doc(map[string]string{"requirements_revision"="1"}))
        if method=="lease.submit" do p=encode(doc(map[string]string{"requirements_revision"="1","head"="","summary"=summary}))
        raw:=lifecycle_raw(f,child,method,fmt.tprintf("%s_%s",method,lease),p,cap,revision)
        c,_:=contracts.owner_parse(raw,"lifecycle_command")
        c["lease_id"]=json.String(lease)
        signature,_:=test_sign(&f.owner_priv,"lifecycle_command",c);c["signature"]=json.String(signature)
        result:=execute_lifecycle(&f.store,encode(c),p,cap,child,f.owner,1000,Signer{&f.owner_priv,test_sign},Source_Proof{"",true})
        if !testing.expect_value(t,result.code,"ok") do testing.fail_now(t,"history submit")
    }
}
history_seed :: proc(t:^testing.T,f:^Fixture) {
    lifecycle_seed(t,f)
    history_submit(t,f,"first","4","historicalfirstneedle")
    verdict:=doc(map[string]string{"requirements_revision"="1","attempt"="1","head"="","verdict"="request_changes","summary"="Rework"})
    p:=encode(verdict)
    if !testing.expect_value(t,invoke(f,command(f,"review.post","rework","task",p,"5"),p).code,"ok") do testing.fail_now(t,"history rework")
    history_submit(t,f,"second","6","historicalsecondneedle")
}
history_read :: proc(f:^Fixture,attempt:string,offset:string="0")->Result {
    p:=encode(doc(map[string]string{"attempt"=attempt,"offset"=offset}))
    return invoke(f,command(f,"submission.read","read_history","task",p,"0"),p)
}
history_expect :: proc(t:^testing.T,f:^Fixture) {
    for term,i in ([2]string{"historicalfirstneedle","historicalsecondneedle"}) {
        result:=search_for(f,term)
        if !testing.expect_value(t,result.code,"ok") do return
        hits:=search_hits(result)
        if testing.expect_value(t,len(hits),1) {
            hit,_:=hits[0].(json.Object)
            attempt:=fmt.tprintf("%d",i+1)
            testing.expect_value(t,field(hit,"attempt"),attempt)
            testing.expect_value(t,field(hit,"object_id"),fmt.tprintf("task:%s",attempt))
            read:=history_read(f,attempt)
            if testing.expect_value(t,read.code,"ok") {
                v,_:=json.parse_string(read.body,.JSON,true,context.temp_allocator)
                o,_:=v.(json.Object)
                testing.expect_value(t,field(o,"kind"),"submission")
                testing.expect_value(t,field(o,"summary"),term)
                testing.expect_value(t,field(o,"attempt"),attempt)
                testing.expect_value(t,field(o,"requirements_revision"),"1")
            }
        }
    }
}
@(test)
search_all_retained_attempts_rebuild_restart_exact_read_and_denial :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);history_seed(t,f)
    history_expect(t,f)
    testing.expect(t,search_rebuild(&f.store))
    history_expect(t,f)
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    history_expect(t,f)
    testing.expect_value(t,history_read(f,"3").code,"invalid_scope")
    testing.expect_value(t,history_read(f,"1","9999").code,"malformed")
    testing.expect(t,exec(f.store.db,"INSERT INTO task_chains VALUES('other','device','device','other','other',1); INSERT INTO local_grants VALUES('other','device','device',1,9223372036854775807,1,0,0)"))
    p:=encode(doc(map[string]string{"attempt"="1","offset"="0"}))
    c,_:=contracts.owner_parse(command(f,"submission.read","cross_scope","task",p,"0"),"command")
    c["chain_id"]=json.String("other")
    signature,_:=test_sign(&f.creator_priv,"command",c);c["signature"]=json.String(signature)
    denied:=invoke(f,encode(c),p)
    testing.expect(t,denied.code=="invalid_scope" && denied.body=="")
    f.creator.revoked=true // the device itself is revoked
    denied=history_read(f,"1")
    testing.expect(t,denied.code=="invalid_scope" && denied.body=="")
    denied=search_for(f,"historicalfirstneedle")
    testing.expect(t,denied.code=="invalid_scope" && denied.body=="")
}
// R4b: an archived workflow stage task (migration_archived_tasks) is found by
// its run and stage identity and labelled archival. The import indexes it in
// its own transaction; the startup rebuild reproduces exactly the same rows.
@(test)
search_indexes_archived_stage_tasks_at_import_and_rebuild :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    rows:=migration_test_rows(f)
    rows["workflow_run"]=migration_list([]string{`{"run_id":"run_zeta","chain_id":"legacy_chain","owner_user_id":"account","current_execution_no":1}`})
    rows["workflow_execution"]=migration_list([]string{`{"run_id":"run_zeta","execution_no":1,"chain_id":"legacy_chain","owner_user_id":"account","state":"succeeded"}`})
    tasks:=make([dynamic]string)
    for task in rows["task"] do append(&tasks,task)
    append(&tasks,`{"task_id":"t_stage","chain_id":"legacy_chain","owner_user_id":"account","title":"Stage","description":"","publish_state":"published","state":"ready","kind":"task","priority":"p1","attempt_no":1,"brief_json":"{\"goal\":\"g\",\"acceptance\":[\"a\"]}","blocked_on_json":"","workflow_run_id":"run_zeta","workflow_execution_no":1,"stage_key":"deployprobe"}`)
    rows["task"]=tasks[:]
    m:=migration_test_build(f,"mig_search_stage",rows)
    if !testing.expect_value(t,migration_test_import(f,m).code,"ok") do return
    find :: proc(f:^Fixture,text,op:string)->(json.Array,string) {
        p:=encode(doc(map[string]string{"query_cipher"=cipher(f,text),"limit"="50"}))
        got:=invoke(f,migration_test_command(f,"chain.search",op,"",p,"0"),p)
        return search_hits(got),got.code
    }
    expect_archived :: proc(t:^testing.T,f:^Fixture,text,op:string) {
        hits,code:=find(f,text,op)
        if !testing.expect_value(t,code,"ok") do return
        if !testing.expect_value(t,len(hits),1) do return
        hit,_:=hits[0].(json.Object)
        testing.expect_value(t,field(hit,"kind"),"archived_task")
        testing.expect_value(t,field(hit,"task_id"),"t_stage")
        testing.expect_value(t,field(hit,"chain_id"),"legacy_chain")
        testing.expect_value(t,field(hit,"title"),"deployprobe")
    }
    // Indexed by the import itself: no restart or rebuild has happened yet.
    expect_archived(t,f,"deployprobe","archived_stage_key")
    expect_archived(t,f,"run_zeta","archived_run_id")
    migration_test_activate(t,f,m,"mig_search_stage")
    // Live tickets of the same import are not labelled archival, and the stage
    // task has no live 'task' document, even after its row is updated.
    docs :: proc(f:^Fixture)->string {
        count,_:=query(f.store.db,"SELECT (SELECT count(*) FROM search_docs WHERE kind='archived_task'),(SELECT count(*) FROM search_docs WHERE kind='task' AND chain_id='legacy_chain'),(SELECT count(*) FROM search_docs WHERE kind='task' AND task_id='t_stage')")
        return encode(count)
    }
    live_docs:=encode([1][3]string{{"1","4","0"}})
    testing.expect_value(t,docs(f),live_docs)
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,"cancel stage")}))
    testing.expect_value(t,invoke(f,migration_test_command(f,"task.cancel","cancel_archived_stage","t_stage",p,"1"),p).code,"ok")
    testing.expect_value(t,docs(f),live_docs)
    before,_:=query(f.store.db,"SELECT chain_id,task_id,object_id,revision,title,body FROM search_docs WHERE kind='archived_task'")
    testing.expect(t,search_rebuild(&f.store))
    after,_:=query(f.store.db,"SELECT chain_id,task_id,object_id,revision,title,body FROM search_docs WHERE kind='archived_task'")
    testing.expect_value(t,encode(after),encode(before))
    expect_archived(t,f,"deployprobe","archived_after_rebuild")
    testing.expect_value(t,docs(f),live_docs)
    close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    expect_archived(t,f,"deployprobe","archived_after_restart")
}
