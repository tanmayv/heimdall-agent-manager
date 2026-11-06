#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

history_call :: proc(f:^Fixture,method,payload:string) -> Result {
    return invoke(f,command(f,method,"history_read","",payload,"0"),payload)
}

@(test)
event_history_preserves_exact_bytes_auth_replay_and_restart :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    body:="original body\x00with controls"
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,body)}))
    c:=command(f,"task.comment","event_comment","task",p,"1")
    first:=invoke(f,c,p,1100)
    testing.expect_value(t,first.code,"ok")
    replay:=invoke(f,c,p,3000)
    testing.expect(t,replay.code=="ok" && replay.replay)
    row,ok:=query(f.store.db,"SELECT ts_ms,actor_kind,actor_id,kind,operation_id,evidence_json,completeness FROM local_events WHERE seq=3")
    if !testing.expect(t,ok && len(row)==1) do return
    testing.expect_value(t,row[0][0],"1100")
    testing.expect_value(t,row[0][1],"device")
    testing.expect_value(t,row[0][2],"device")
    testing.expect_value(t,row[0][3],"task.comment")
    testing.expect_value(t,row[0][4],"event_comment")
    testing.expect_value(t,row[0][6],"full")
    ev,parsed:=json.parse_string(row[0][5],.JSON,true,context.temp_allocator)
    o,obj:=ev.(json.Object)
    testing.expect(t,parsed==nil && obj)
    testing.expect_value(t,field(o,"command"),c)
    testing.expect_value(t,field(o,"payload"),p)
    testing.expect_value(t,field(o,"result"),first.body)
    content,_:=json.parse_string(field(o,"content"),.JSON,true,context.temp_allocator)
    opened,_:=content.(json.Object)
    testing.expect_value(t,field(opened,"body"),body)
    testing.expect(t,!exec(f.store.db,"UPDATE local_events SET actor_id='forged'"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM local_events"))
    close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    after,_:=query(f.store.db,"SELECT evidence_json FROM local_events WHERE seq=3")
    testing.expect_value(t,after[0][0],row[0][5])
    page:=history_call(f,"history.read",`{"cursor":"","limit":"100"}`)
    testing.expect_value(t,page.code,"ok")
    inventory,_:=json.parse_string(page.body,.JSON,true,context.temp_allocator)
    header,_:=inventory.(json.Object);items,_:=header["items"].(json.Array)
    testing.expect_value(t,len(items),3)
    // Read authorization precedes even historical evidence; read-only grants
    // still allow history, revocation denies inventory and exact fetch alike.
    _,_=query(f.store.db,"UPDATE local_grants SET can_mutate=0,revision=revision+1")
    testing.expect_value(t,history_call(f,"history.fetch",`{"seq":"3","offset":"0"}`).code,"ok")
    _,_=query(f.store.db,"UPDATE local_grants SET revoked=1,revision=revision+1")
    testing.expect_value(t,history_call(f,"history.read",`{"cursor":"","limit":"100"}`).code,"invalid_scope")
    testing.expect_value(t,history_call(f,"history.fetch",`{"seq":"3","offset":"0"}`).code,"invalid_scope")
}

@(test)
event_history_failure_is_atomic_and_does_not_capture_rejections :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER fail_event BEFORE INSERT ON local_events BEGIN SELECT RAISE(ABORT,'full disk'); END"))
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,"must roll back")}))
    c:=command(f,"task.comment","event_atomic","task",p,"1")
    testing.expect_value(t,invoke(f,c,p).code,"storage_error")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM local_events),(SELECT count(*) FROM command_receipts),(SELECT count(*) FROM local_changes),(SELECT count(*) FROM task_comments),(SELECT revision FROM tasks)")
    expected:=[5]string{"2","2","2","0","1"}
    for value,i in expected do testing.expect_value(t,rows[0][i],value)
    testing.expect(t,exec(f.store.db,"DROP TRIGGER fail_event"))
    testing.expect_value(t,invoke(f,c,p).code,"ok")
    testing.expect_value(t,invoke(f,command(f,"task.comment","wrong_revision","task",p,"1"),p).code,"stale_revision")
    rows,_=query(f.store.db,"SELECT count(*) FROM local_events")
    testing.expect_value(t,rows[0][0],"3")
}

@(test)
event_history_pages_and_chunked_evidence_are_lossless :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    for i in 0..<3 {
        p:=encode(doc(map[string]string{"body_cipher"=cipher(f,fmt.tprintf("%s%s",strings.repeat("x",4000,context.temp_allocator),strings.repeat("世",1333,context.temp_allocator)))}))
        testing.expect_value(t,invoke(f,command(f,"task.comment",fmt.tprintf("long_%d",i),"task",p,fmt.tprintf("%d",i+1)),p).code,"ok")
    }
    page:=history_call(f,"history.read",`{"cursor":"","limit":"2"}`)
    v,_:=json.parse_string(page.body,.JSON,true,context.temp_allocator);o,_:=v.(json.Object)
    cursor:=field(o,"next_cursor")
    testing.expect(t,cursor!="")
    // Appending does not invalidate a keyset cursor.
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,"later")}))
    testing.expect_value(t,invoke(f,command(f,"task.comment","later","task",p,"4"),p).code,"ok")
    page=history_call(f,"history.read",encode(doc(map[string]string{"cursor"=cursor,"limit"="100"})))
    v,_=json.parse_string(page.body,.JSON,true,context.temp_allocator);o,_=v.(json.Object);items,_:=o["items"].(json.Array)
    testing.expect_value(t,len(items),4)
    all:=strings.builder_make(context.temp_allocator)
    offset:="0";chunks:=0
    for i in 0..<20 {
        got:=history_call(f,"history.fetch",encode(doc(map[string]string{"seq"="3","offset"=offset})))
        if !testing.expect_value(t,got.code,"ok") do break
        testing.expect(t,len(got.body)<=MAX_PAGE)
        val,_:=json.parse_string(got.body,.JSON,true,context.temp_allocator);part,_:=val.(json.Object)
        strings.write_string(&all,field(part,"evidence"))
        next:=field(part,"next_offset")
        chunks+=1
        if next=="" do break
        testing.expect(t,number(next)>number(offset))
        offset=next
    }
    rows,_:=query(f.store.db,"SELECT evidence_json FROM local_events WHERE seq=3")
    testing.expect(t,chunks>1)
    testing.expect_value(t,strings.to_string(all),rows[0][0])
    // Odin's event encoder escapes Unicode. A native import may instead retain
    // verbatim UTF-8 JSON; exercise that boundary with synthetic historical bytes.
    native:=strings.concatenate({`{"payload":"`,strings.repeat("x",8001,context.temp_allocator),strings.repeat("世",1000,context.temp_allocator),`"}`},context.temp_allocator)
    _,inserted:=query(f.store.db,"INSERT INTO local_events VALUES(70,'chain','task',1000,'device','device','fixture','utf8_import',?,'full')",native)
    testing.expect(t,inserted)
    native_all:=strings.builder_make(context.temp_allocator)
    offset="0"
    for i in 0..<5 {
        fetched:=history_call(f,"history.fetch",encode(doc(map[string]string{"seq"="70","offset"=offset})))
        if !testing.expect_value(t,fetched.code,"ok") do break
        v,_:=json.parse_string(fetched.body,.JSON,true,context.temp_allocator);part,_:=v.(json.Object)
        strings.write_string(&native_all,field(part,"evidence"))
        offset=field(part,"next_offset")
        if offset=="" do break
    }
    testing.expect_value(t,strings.to_string(native_all),native)
    checked_utf8:=false
    for byte,i in transmute([]u8)native {
        if byte&0xc0==0x80 {
            bad:=encode(doc(map[string]string{"seq"="70","offset"=fmt.tprintf("%d",i)}))
            testing.expect_value(t,history_call(f,"history.fetch",bad).code,"malformed")
            checked_utf8=true;break
        }
    }
    testing.expect(t,checked_utf8,"fixture exercises a UTF-8 continuation offset")
    testing.expect_value(t,history_call(f,"history.fetch",`{"seq":"999","offset":"0"}`).code,"invalid_scope")
    testing.expect_value(t,history_call(f,"history.fetch",`{"seq":"3","offset":"9999999"}`).code,"malformed")
}

@(test)
event_history_tracks_child_and_expiry_with_observed_identity :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    cap:=lifecycle_ready(t,f)
    testing.expect(t,cap!="")
    result:=lifecycle_call(f,lease_child(),"requirements.present","event_present",`{"requirements_revision":"1"}`,cap)
    testing.expect_value(t,result.code,"ok")
    rows,ok:=query(f.store.db,"SELECT actor_kind,actor_id,evidence_json FROM local_events WHERE operation_id='event_present'")
    if !testing.expect(t,ok && len(rows)==1) do return
    testing.expect_value(t,rows[0][0],"agent")
    testing.expect_value(t,rows[0][1],lease_child().instance)
    testing.expect(t,strings.contains(rows[0][2],"requirements.present"))
    testing.expect(t,expire_leases(&f.store,1000+LEASE_TTL_MS))
    rows,ok=query(f.store.db,"SELECT actor_kind,actor_id,ts_ms,evidence_json FROM local_events WHERE kind='lease.expired'")
    if !testing.expect(t,ok && len(rows)==1) do return
    testing.expect_value(t,rows[0][0],"bridge")
    testing.expect_value(t,rows[0][1],"bridge")
    testing.expect_value(t,number(rows[0][2]),1000+LEASE_TTL_MS)
    testing.expect(t,strings.contains(rows[0][3],"lease_id"))
}

@(test)
event_v12_upgrade_collision_and_commit_rollback_preserve_live_runtime :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    cap:=lifecycle_ready(t,f)
    keep:="SELECT (SELECT json_group_array(json_array(principal_id,operation_id,input_digest,result_json)) FROM command_receipts),(SELECT json_group_array(json_array(chain_id,task_id,revision,brief_json,cipher)) FROM task_requirements),(SELECT capability_json FROM local_leases WHERE retired_seq IS NULL LIMIT 1)"
    before,_:=query(f.store.db,keep)
    close(&f.store)
    db:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    prefix:=string(MIGRATION_012);prefix=prefix[:strings.index(prefix,"CREATE TABLE local_workflow_output_triggers_v12")]
    testing.expect(t,exec(db,"DROP TABLE IF EXISTS local_budget_evidence; DROP TABLE IF EXISTS native_budget_baselines; DROP TRIGGER IF EXISTS deferred_prepared_merge_no_invalidation; DROP TABLE IF EXISTS deferred_workflow_dispositions; DROP TABLE IF EXISTS deferred_workflow_retirements; DROP TABLE IF EXISTS native_history_records; DROP TABLE IF EXISTS local_task_retirements; DROP TABLE local_events;"))
    testing.expect(t,exec(db,prefix))
    testing.expect(t,exec(db,"UPDATE schema_migrations SET version=12; CREATE VIEW local_events AS SELECT 1;"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_:=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations) FROM runtime_database")
    testing.expect(t,rows[0][0]=="12" && rows[0][1]=="12")
    testing.expect(t,exec(db,`DROP VIEW local_events; CREATE TABLE event_parent(id INTEGER PRIMARY KEY);
      CREATE TABLE event_ref(id INTEGER REFERENCES event_parent(id) DEFERRABLE INITIALLY DEFERRED);
      CREATE TRIGGER event_commit_fail AFTER UPDATE ON schema_migrations WHEN NEW.version=13 BEGIN INSERT INTO event_ref VALUES(1); END;`))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations),(SELECT count(*) FROM sqlite_master WHERE name='local_events') FROM runtime_database")
    testing.expect(t,rows[0][0]=="12" && rows[0][1]=="12" && rows[0][2]=="0")
    after,_:=query(db,keep)
    for value,i in before[0] do testing.expect_value(t,after[0][i],value)
    testing.expect(t,exec(db,"DROP TRIGGER event_commit_fail"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    after,_=query(f.store.db,keep)
    for value,i in before[0] do testing.expect_value(t,after[0][i],value)
    rows,_=query(f.store.db,"SELECT count(*) FROM local_events WHERE completeness='legacy_tag' AND ts_ms IS NULL AND actor_kind='unknown' AND evidence_json=''")
    changes,_:=query(f.store.db,"SELECT count(*) FROM local_changes")
    testing.expect_value(t,rows[0][0],changes[0][0])
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.present","event_after_upgrade",`{"requirements_revision":"1"}`,cap).code,"ok")
    rows,_=query(f.store.db,"PRAGMA foreign_key_check")
    testing.expect_value(t,len(rows),0)
}


@(test)
event_history_survives_canonical_task_deletion :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,"retained historical comment")}))
    testing.expect_value(t,invoke(f,command(f,"task.comment","retained_comment","task",p,"1"),p).code,"ok")
    p=`{"protocol_version":"1"}`
    testing.expect_value(t,invoke(f,command(f,"task.delete","history_delete","task",p,"2"),p).code,"ok")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM tasks),(SELECT count(*) FROM local_events),(SELECT count(*) FROM task_comments)")
    testing.expect(t,rows[0][0]=="0" && rows[0][1]=="4" && rows[0][2]=="0")
    fetched:=history_call(f,"history.fetch",`{"seq":"3","offset":"0"}`)
    testing.expect_value(t,fetched.code,"ok")
    testing.expect(t,strings.contains(fetched.body,"retained historical comment"))
    close(&f.store)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    rows,_=query(f.store.db,"PRAGMA foreign_key_check")
    testing.expect_value(t,len(rows),0)
    testing.expect_value(t,history_call(f,"history.fetch",`{"seq":"4","offset":"0"}`).code,"ok")
}
