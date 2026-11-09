#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import compact "odin_test:lib/context_compaction"

context_call :: proc(f:^Fixture,method,op,cursor:string) -> Result {
    p:=encode(doc(map[string]string{"cursor"=cursor,"limit"="20"}))
    return invoke(f,command(f,method,op,"",p,"0"),p)
}

context_seed_history :: proc(t:^testing.T,f:^Fixture) {
    for i in 0..<100 {
        summary:=fmt.tprintf("lesson %d %s",i,strings.repeat("long lesson ",200,context.temp_allocator))
        _,ok:=query(f.store.db,"INSERT INTO local_handoffs VALUES('chain','task','author',?,'handoff','lease',?,'keep original evidence','','',?)",fmt.tprintf("handoff%d",i),summary,fmt.tprintf("%d",i+100))
        testing.expect(t,ok)
    }
    // Colons are legal in IDs. Delimiter concatenation must not alias these
    // two distinct primary keys into one source_ref during reconstruction.
    for pair,i in ([2][2]string{{"a:b","c"},{"a","b:c"}}) {
        _,ok:=query(f.store.db,"INSERT INTO task_comments(chain_id,task_id,principal_id,operation_id,body,seq) VALUES('chain','task',?,?,'distinct composite identity',?)",pair[0],pair[1],fmt.tprintf("%d",2000+i))
        testing.expect(t,ok)
    }
    // One huge Unicode line, with significant evidence beyond the preview.
    _,ok:=query(f.store.db,"INSERT INTO task_comments(chain_id,task_id,operation_id,principal_id,body,seq) VALUES('chain','task','huge','author',?,1000)",strings.concatenate({strings.repeat("界",10000,context.temp_allocator),"TAIL_EVIDENCE"},context.temp_allocator))
    testing.expect(t,ok)
}

@(test)
context_bounded_projection_full_retrieval_restart_and_auth :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);context_seed_history(t,f)
    r:=context_call(f,"chain.read","context1","")
    if !testing.expect_value(t,r.code,"ok") do return
    parsed,_:=json.parse_string(r.body,.JSON,true,context.temp_allocator);o,_:=parsed.(json.Object)
    projection,_:=o["context"].(json.Object)
    body:=field(projection,"body")
    testing.expect(t,len(body)<=compact.MAX_BYTES && len(strings.split_lines(body,context.temp_allocator))<=compact.MAX_LINES)
    testing.expect(t,strings.contains(body,"lesson 99") && !strings.contains(body,"lesson 0 "),"recent distinct lessons take priority")
    testing.expect_value(t,field(projection,"freshness"),"snapshot")
    first,_:=query(f.store.db,"SELECT version,source_seq,source_digest FROM local_chain_context")
    testing.expect_value(t,context_call(f,"chain.read","context2","").code,"ok")
    close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,context_call(f,"chain.read","after_restart","").code,"ok")
    after,_:=query(f.store.db,"SELECT version,source_seq,source_digest FROM local_chain_context")
    testing.expect(t,first[0][0]==after[0][0] && first[0][1]==after[0][1] && first[0][2]==after[0][2],"restart does not invent new source content")
    // Traverse real signed read calls and reconstruct every exact source chunk.
    expected,ok:=context_sources(&f.store,"chain");testing.expect(t,ok)
    bodies:=make(map[string]string,context.temp_allocator)
    cursor:=""
    first_cursor:=""
    pages:=0
    for {
        page:=context_call(f,"context.read",fmt.tprintf("page%d",pages),cursor)
        if !testing.expect_value(t,page.code,"ok") do return
        testing.expect(t,len(page.body)<=MAX_PAGE)
        v,_:=json.parse_string(page.body,.JSON,true,context.temp_allocator);item,_:=v.(json.Object)
        key:=fmt.tprintf("%s:%s",field(item,"source_kind"),field(item,"source_ref"))
        bodies[key]=strings.concatenate({bodies[key],field(item,"body")},context.temp_allocator)
        next:=field(item,"next_cursor")
        if pages==0 do first_cursor=next
        pages+=1
        if next=="" do break
        if !testing.expect(t,next!=cursor && pages<1000,"cursor progresses") do return
        cursor=next
    }
    testing.expect_value(t,len(bodies),len(expected))
    for row in expected do testing.expect(t,bodies[fmt.tprintf("%s:%s",row[0],row[1])]==row[2],fmt.tprintf("exact original %s:%s",row[0],row[1]))
    found_tail:=false
    for key,value in bodies do if strings.has_prefix(key,"comment:") && strings.contains(value,"TAIL_EVIDENCE") do found_tail=true
    testing.expect(t,found_tail)
    // A signed source mutation invalidates old cursors and updates provenance.
    p:=encode(doc(map[string]string{"title_cipher"=cipher(f,"edited"),"description_cipher"=cipher(f,"curated separate input")}))
    revisions,_:=query(f.store.db,"SELECT revision FROM task_chains WHERE chain_id='chain'")
    testing.expect_value(t,invoke(f,command(f,"chain.edit","edit_context","",p,revisions[0][0]),p).code,"ok")
    testing.expect_value(t,context_call(f,"context.read","stale_page",first_cursor).code,"stale_cursor")
    testing.expect_value(t,context_call(f,"chain.read","updated","").code,"ok")
    updated,_:=query(f.store.db,"SELECT version,source_seq,source_digest FROM local_chain_context")
    testing.expect(t,number(updated[0][0])>number(first[0][0]) && updated[0][2]!=first[0][2])
    revoked:=f.creator;revoked.revoked=true
    read_payload:=encode(doc(map[string]string{"cursor"="","limit"="20"}))
    raw:=command(f,"context.read","revoked","",read_payload,"0")
    testing.expect(t,execute(&f.store,raw,read_payload,"",revoked,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign}).code!="ok")
    wrong:=f.creator;wrong.account_id="another_account"
    testing.expect(t,execute(&f.store,raw,read_payload,"",wrong,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign}).code!="ok")
    _,_=query(f.store.db,"INSERT INTO task_chains VALUES('other','other','other','private','private',1)")
    c,_:=contracts.owner_parse(command(f,"context.read","other_scope","",read_payload,"0"),"command")
    c["chain_id"]=json.String("other");sig,_:=test_sign(&f.creator_priv,"command",c);c["signature"]=json.String(sig)
    testing.expect(t,invoke(f,encode(c),read_payload).code!="ok","chain authorization precedes source enumeration")
}

@(test)
context_write_failure_is_explicit_and_requirements_remain_exact :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);context_seed_history(t,f)
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER context_fail BEFORE INSERT ON local_chain_context BEGIN SELECT RAISE(ABORT,'full'); END;"))
    testing.expect_value(t,context_call(f,"chain.read","failed","").code,"storage_error")
    rows,_:=query(f.store.db,"SELECT count(*) FROM local_chain_context")
    testing.expect_value(t,rows[0][0],"0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER context_fail"))
    cap:=lifecycle_ready(t,f)
    if cap=="" do return
    present:=lifecycle_call(f,lease_child(),"requirements.present","present_again","{\"requirements_revision\":\"1\"}",cap)
    if !testing.expect_value(t,present.code,"ok") do return
    v,_:=json.parse_string(present.body,.JSON,true,context.temp_allocator);o,_:=v.(json.Object)
    req,_:=lifecycle_requirements(&f.store,"chain","task")
    testing.expect_value(t,field(o,"brief"),req[1])
    testing.expect_value(t,field(o,"acknowledged"),"1")
    testing.expect(t,len(field(o,"chain_summary"))<=compact.MAX_BYTES && strings.contains(field(o,"context_provenance"),"source_digest"))
    count,_:=query(f.store.db,"SELECT (SELECT count(*) FROM local_handoffs),(SELECT count(*) FROM task_comments)")
    testing.expect(t,count[0][0]=="100" && count[0][1]=="3","projection never deletes originals")
}

@(test)
context_v9_upgrade_collision_commit_failure_preserves_combined_lineage :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    cap:=lifecycle_ready(t,f)
    if cap=="" do return
    original,_:=query(f.store.db,"SELECT (SELECT count(*) FROM local_grant_policy),(SELECT count(*) FROM local_leases),(SELECT count(*) FROM command_receipts),(SELECT count(*) FROM task_requirements)")
    close(&f.store)
    db:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    // Reconstruct genuine V9 while preserving grants8/workflows9 and live rows.
    prefix:=string(MIGRATION_009);prefix=prefix[:strings.index(prefix,"CREATE TABLE local_workflow_definitions")]
    testing.expect(t,exec(db,V10_TEST_DROP + "DROP TABLE local_chain_context;"))
    testing.expect(t,exec(db,prefix))
    testing.expect(t,exec(db,"DROP TABLE IF EXISTS owner_execution_stop_steps; UPDATE schema_migrations SET version=9; CREATE VIEW local_chain_context AS SELECT 1;"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"),"DDL collision rolls back header and marker")
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_:=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations),(SELECT count(*) FROM sqlite_master WHERE name='local_workflow_definitions') FROM runtime_database")
    testing.expect(t,rows[0][0]=="9" && rows[0][1]=="9" && rows[0][2]=="1")
    testing.expect(t,exec(db,`DROP VIEW local_chain_context;
      CREATE TABLE context_parent(id INTEGER PRIMARY KEY);
      CREATE TABLE context_ref(id INTEGER REFERENCES context_parent(id) DEFERRABLE INITIALLY DEFERRED);
      CREATE TRIGGER context_upgrade_failure AFTER UPDATE ON schema_migrations WHEN NEW.version=10 BEGIN INSERT INTO context_ref VALUES(1); END;`))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"),"COMMIT failure rolls back the entire migration")
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations),(SELECT count(*) FROM sqlite_master WHERE name='local_chain_context') FROM runtime_database")
    testing.expect(t,rows[0][0]=="9" && rows[0][1]=="9" && rows[0][2]=="0")
    testing.expect(t,exec(db,"DROP TRIGGER context_upgrade_failure"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    after,_:=query(f.store.db,"SELECT (SELECT count(*) FROM local_grant_policy),(SELECT count(*) FROM local_leases),(SELECT count(*) FROM command_receipts),(SELECT count(*) FROM task_requirements)")
    for value,i in original[0] do testing.expect_value(t,after[0][i],value)
    rows,_=query(f.store.db,"SELECT schema_version,(SELECT version FROM schema_migrations) FROM runtime_database")
    testing.expect(t,rows[0][0]=="37" && rows[0][1]=="37")
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.present","v10_present","{\"requirements_revision\":\"1\"}",cap).code,"ok")
    rows,_=query(f.store.db,"PRAGMA foreign_key_check")
    testing.expect_value(t,len(rows),0)
}
