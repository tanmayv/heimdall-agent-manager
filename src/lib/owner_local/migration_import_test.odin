#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

Migration_Fixture :: struct { selection,genesis,manifest,digest:string, documents:[]string }

migration_test_selection :: proc(f:^Fixture,migration:string,owner_bridge:="bridge",owner_key:="bridge_key")->(string,string) {
    sel:=doc(map[string]string{"protocol_version"="1","account_id"="account","chain_id"="legacy_chain","migration_id"=migration,"owner_bridge_id"=owner_bridge,"owner_key_id"=owner_key,
        "principal_id"="device","key_id"="device","expected_work_revision"="7","request_expires_ms"="301000","signature"=strings.repeat("0",128)})
    sig,_:=test_sign(&f.creator_priv,"migration_selection",sel);sel["signature"]=json.String(sig)
    g:=doc(map[string]string{"protocol_version"="1","account_id"="account","chain_id"="legacy_chain","creation_op"=migration,"owner_bridge_id"="bridge","owner_key_id"="bridge_key",
        "creator_id"="device","creator_key_id"="device","schema_version"="1","creator_signature"=strings.repeat("0",128),"owner_signature"=strings.repeat("0",128)})
    sig,_=test_sign(&f.creator_priv,"genesis",g);g["creator_signature"]=json.String(sig)
    sig,_=test_sign(&f.owner_priv,"genesis",g);g["owner_signature"]=json.String(sig)
    return encode(sel),encode(g)
}

// Mirrors the Hub exporter: verbatim rows grouped by kind, one document per
// kind here, and a manifest whose digest is the import identity.
migration_test_export :: proc(f:^Fixture,migration:string,rows:map[string][]string,selection:string)->(string,[]string) {
    sel,_:=contracts.owner_parse(selection,"migration_selection")
    selection_digest,_:=contracts.owner_digest("migration_selection",sel)
    kinds:=make([dynamic]contracts.Owner_Migration_Kind_Count)
    refs:=make([dynamic]contracts.Owner_Migration_Document_Ref)
    documents:=make([dynamic]string)
    for k in contracts.OWNER_MIGRATION_EXPORT_KINDS {
        list:=rows[k.kind]
        append(&kinds,contracts.Owner_Migration_Kind_Count{k.kind,k.table,i64(len(list))})
        if len(list)==0 do continue
        raw:=fmt.tprintf(`{{"format":"%s","kind":"%s","index":%d,"rows":[%s]}}`,contracts.OWNER_MIGRATION_EXPORT_FORMAT,k.kind,len(documents),strings.join(list,","))
        append(&refs,contracts.Owner_Migration_Document_Ref{i64(len(documents)),k.kind,i64(len(list)),i64(len(raw)),contracts.owner_payload_digest(raw)})
        append(&documents,raw)
    }
    m:=contracts.Owner_Migration_Manifest{contracts.OWNER_MIGRATION_EXPORT_FORMAT,"account","legacy_chain",migration,selection_digest,3,7,kinds[:],refs[:],contracts.OWNER_MIGRATION_ARCHIVAL_ONLY[:]}
    raw,_:=json.marshal(m,allocator=context.temp_allocator)
    return string(raw),documents[:]
}

migration_list :: proc(items:[]string)->[]string { return slice.clone(items,context.temp_allocator) }
migration_test_rows :: proc(f:^Fixture)->map[string][]string {
    j :: proc(s:string)->string { raw,_:=json.marshal(s,allocator=context.temp_allocator);return string(raw) }
    rows:=make(map[string][]string)
    rows["chain"]=migration_list([]string{fmt.tprintf(`{{"chain_id":"legacy_chain","owner_user_id":"account","title":%s,"description":%s,"publish_state":"published","status":"active","kind":"mixed_work","work_revision":7,"defaults_json":"{{}}","created_at":"2001-02-03T04:05:06Z","is_pinned":0,"pinned_at":null}}`,
        j(cipher(f,"Legacy ☃ chain")),j(cipher(f,"Legacy description")))})
    rows["task"]=migration_list([]string{
        fmt.tprintf(`{{"task_id":"t_done","chain_id":"legacy_chain","owner_user_id":"account","title":%s,"description":%s,"publish_state":"published","state":"done","priority":"p0","attempt_no":2,"brief_json":"{{\"goal\":\"Ship\",\"acceptance\":[\"Works\"]}}","blocked_on_json":"","created_at":"2001-01-01T00:00:00Z"}}`,j(cipher(f,"Done ☃ task")),j(cipher(f,"done body"))),
        fmt.tprintf(`{{"task_id":"t_cancel","chain_id":"legacy_chain","owner_user_id":"account","title":%s,"description":"","publish_state":"published","state":"cancelled","priority":"p2","attempt_no":0,"brief_json":"{{}}","blocked_on_json":""}}`,j(cipher(f,"Cancelled task"))),
        fmt.tprintf(`{{"task_id":"t_blocked","chain_id":"legacy_chain","owner_user_id":"account","title":"Plain blocked","description":"","publish_state":"published","state":"backlog","priority":"p1","attempt_no":1,"brief_json":"{{}}","blocked_on_json":"{{\"kind\":\"human\",\"reason\":\"needs keys\"}}"}}`),
        fmt.tprintf(`{{"task_id":"t_ready","chain_id":"legacy_chain","owner_user_id":"account","title":"Ready","description":"next","publish_state":"published","state":"ready","priority":"p1","attempt_no":0,"brief_json":"{{\"goal\":\"Next\",\"acceptance\":[\"Pass\"]}}","blocked_on_json":""}}`),
    })
    rows["dependency"]=migration_list([]string{`{"task_id":"t_ready","depends_on_task_id":"t_done","chain_id":"legacy_chain","owner_user_id":"account","created_at":"d1"}`})
    rows["work_dependency"]=migration_list([]string{
        `{"dependency_id":"dep_keep","chain_id":"legacy_chain","owner_user_id":"account","dependent_kind":"task","dependent_id":"t_blocked","prerequisite_kind":"task","prerequisite_id":"t_done","created_by_kind":"agent","created_by_id":"agt_orig","created_at":"2001-05-05T00:00:00Z","removed_at":"","removed_by_kind":"","removed_by_id":"","removal_reason":""}`,
        `{"dependency_id":"dep_run","chain_id":"legacy_chain","owner_user_id":"account","dependent_kind":"task","dependent_id":"t_ready","prerequisite_kind":"workflow_run","prerequisite_id":"run_1","created_by_kind":"user","created_by_id":"account","created_at":"x","removed_at":"y","removed_by_kind":"user","removed_by_id":"account","removal_reason":"run dropped"}`,
    })
    rows["comment"]=migration_list([]string{fmt.tprintf(`{{"comment_id":"cmt_1","task_id":"t_done","chain_id":"legacy_chain","owner_user_id":"account","author_agent_instance_id":"inst_author","body":%s,"created_at":"c1","updated_at":"c1","delegated_client_id":"","delegated_grant_id":""}}`,j(cipher(f,"migrated_comment_needle ☃")))})
    rows["summary"]=migration_list([]string{fmt.tprintf(`{{"chain_id":"legacy_chain","owner_user_id":"account","body":"raw","line_count":1,"version":3,"updated_at":"u","curated_body":%s,"failure_fingerprint":"","curated_initialized":1}}`,j(cipher(f,"Curated summary")))})
    rows["member"]=migration_list([]string{`{"chain_id":"legacy_chain","agent_instance_id":"inst_author","agent_id":"agt_orig","owner_user_id":"account","role":"worker","created_at":"m"}`})
    rows["fleet"]=migration_list([]string{`{"task_chain_id":"legacy_chain","agent_id":"agt_orig","capacity":2,"min_warm":0,"idle_ttl_seconds":600,"created_at":"f","updated_at":"f","bridge_models_json":"{}","roles_json":"[\"worker\"]","bridge_id":"","paused_roles_json":""}`})
    rows["attempt"]=migration_list([]string{`{"task_id":"t_done","attempt_no":1,"chain_id":"legacy_chain","owner_user_id":"account","started_at":"2025-04-03T12:00:00Z","ended_at":"2025-04-03T12:30:00Z","holder_instance_id":"inst_author","outcome":"submitted","counts_toward_budget":1}`})
    rows["event"]=migration_list([]string{
        `{"event_id":41,"task_id":"t_done","chain_id":"legacy_chain","owner_user_id":"account","ts_ms":1743681600000,"actor_kind":"user","actor_id":"account","kind":"created","payload_json":"{\"title\":\"x\"}"}`,
        `{"event_id":42,"task_id":"t_done","chain_id":"legacy_chain","owner_user_id":"account","ts_ms":1743681600001,"actor_kind":"agent","actor_id":"inst_author","kind":"submitted","payload_json":"not an object"}`,
    })
    rows["facet"]=migration_list([]string{`{"task_id":"t_done","attempt_no":1,"chain_id":"legacy_chain","owner_user_id":"account","kind":"handoff","v":1,"body_json":"{\"summary\":\"done ☃\"}","writer":"agent","written_at":"w"}`})
    rows["review"]=migration_list([]string{`{"task_id":"t_done","chain_id":"legacy_chain","owner_user_id":"account","attempt_no":1,"role":"","reviewer_kind":"user","reviewer_agent_id":"","reviewer_instance_id":"","verdict":"approve","findings_json":"[]","created_at":"r"}`})
    rows["artifact"]=migration_list([]string{`{"artifact_id":"art_1","owner_user_id":"account","kind":"file","name":"report.md","content":"inline","blob_ref":"blob://x","chain_id":"legacy_chain","task_id":"t_done","created_at":"a","updated_at":"a","deleted_at":null}`})
    return rows
}

migration_test_build :: proc(f:^Fixture,migration:string,rows:map[string][]string)->Migration_Fixture {
    sel,g:=migration_test_selection(f,migration)
    manifest,documents:=migration_test_export(f,migration,rows,sel)
    return {sel,g,manifest,contracts.owner_payload_digest(manifest),documents}
}
migration_test_import :: proc(f:^Fixture,m:Migration_Fixture,now:i64=1000)->Result {
    if !observe_directory(&f.store,1,"head") do return fail("invalid_scope")
    return migration_import(&f.store,Migration_Import_Input{m.selection,m.genesis,m.manifest,m.documents},f.creator,f.owner,1,"head",now,&f.kr,Signer{&f.owner_priv,test_sign})
}
migration_test_counts :: proc(f:^Fixture)->string {
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM task_chains),(SELECT count(*) FROM tasks),(SELECT count(*) FROM task_comments),(SELECT count(*) FROM migration_imports),(SELECT count(*) FROM migration_import_documents),(SELECT count(*) FROM native_history_records),(SELECT commit_seq FROM runtime_database)")
    return encode(rows)
}

@(test)
migration_import_rich_fixture_fidelity_quarantine_and_activation :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    m:=migration_test_build(f,"mig_rich",migration_test_rows(f))
    got:=migration_test_import(f,m)
    if !testing.expect_value(t,got.code,"ok") do return
    testing.expect(t,!got.replay)
    // The Hub-side verifier accepts the owner-signed receipt for this manifest.
    receipt,_:=contracts.owner_parse(got.body,"migration_import_receipt")
    sel,_:=contracts.owner_parse(m.selection,"migration_selection")
    g,_:=contracts.owner_parse(m.genesis,"genesis")
    testing.expect_value(t,contracts.owner_verify_migration_import(receipt,sel,g,m.digest,f.owner),contracts.Owner_Auth_Error.None)
    testing.expect_value(t,contracts.owner_verify_migration_import(receipt,sel,g,strings.repeat("e",64),f.owner),contracts.Owner_Auth_Error.Digest_Mismatch)
    // Field fidelity of the live projection.
    rows,_:=query(f.store.db,"SELECT title,description,creator FROM task_chains WHERE chain_id='legacy_chain'")
    testing.expect_value(t,encode(rows),encode([1][3]string{{"Legacy ☃ chain","Legacy description","device"}}))
    rows,_=query(f.store.db,"SELECT publish_state,status,work_revision>=7 FROM local_work_chains WHERE chain_id='legacy_chain'")
    testing.expect_value(t,encode(rows),encode([1][3]string{{"published","active","1"}}))
    rows,_=query(f.store.db,"SELECT creation_op,import_manifest_hash FROM chain_genesis WHERE chain_id='legacy_chain'")
    testing.expect_value(t,encode(rows),encode([1][2]string{{"mig_rich",m.digest}}))
    rows,_=query(f.store.db,"SELECT task_id,title,body FROM tasks WHERE chain_id='legacy_chain' ORDER BY task_id")
    testing.expect_value(t,encode(rows),encode([4][3]string{{"t_blocked","Plain blocked",""},{"t_cancel","Cancelled task",""},{"t_done","Done ☃ task","done body"},{"t_ready","Ready","next"}}))
    rows,_=query(f.store.db,"SELECT task_id,state,attempt FROM lifecycle_state WHERE chain_id='legacy_chain'")
    testing.expect_value(t,encode(rows),encode([1][3]string{{"t_done","done","2"}}))
    rows,_=query(f.store.db,"SELECT task_id,mode,resume_state,reason,waiting_on FROM local_controls WHERE chain_id='legacy_chain' ORDER BY task_id")
    testing.expect_value(t,encode(rows),encode([2][5]string{{"t_blocked","blocked","ready","needs keys","human"},{"t_cancel","cancelled","ready","imported: cancelled in legacy chain",""}}))
    rows,_=query(f.store.db,"SELECT task_id,operation_id,principal_id,body FROM task_comments")
    testing.expect_value(t,encode(rows),encode([1][4]string{{"t_done","cmt_1","inst_author","migrated_comment_needle ☃"}}))
    rows,_=query(f.store.db,"SELECT task_id,brief_json FROM task_requirements ORDER BY task_id")
    testing.expect_value(t,len(rows),2)
    rows,_=query(f.store.db,"SELECT dependency_id,dependent_id,prerequisite_id,created_at,created_by_kind,created_by_id FROM local_work_dependencies")
    testing.expect_value(t,encode(rows),encode([1][6]string{{"dep_keep","t_blocked","t_done","2001-05-05T00:00:00Z","agent","agt_orig"}}))
    rows,_=query(f.store.db,"SELECT task_id,prerequisite FROM local_dependencies")
    testing.expect_value(t,encode(rows),encode([1][2]string{{"t_ready","t_done"}}))
    rows,_=query(f.store.db,"SELECT curated_body FROM local_chain_summary_versions")
    testing.expect_value(t,encode(rows),encode([1][1]string{{"Curated summary"}}))
    rows,_=query(f.store.db,"SELECT record_kind,count(*) FROM native_history_records WHERE chain_id='legacy_chain' GROUP BY record_kind ORDER BY record_kind")
    testing.expect_value(t,encode(rows),encode([3][2]string{{"attempt","1"},{"event","1"},{"facet","1"}}))
    rows,_=query(f.store.db,"SELECT summary_json FROM migration_imports")
    testing.expect(t,strings.contains(rows[0][0],`"event_archival_only":1`),"an event the native vocabulary cannot hold is counted, not invented")
    // Every exported document is archived verbatim.
    archived,_:=query(f.store.db,"SELECT body FROM migration_import_documents ORDER BY doc_index")
    testing.expect_value(t,len(archived),len(m.documents))
    for row,i in archived do testing.expect_value(t,row[0],m.documents[i])
    indexed,_:=query(f.store.db,"SELECT count(*) FROM search_docs WHERE chain_id='legacy_chain' AND kind='comment' AND body LIKE '%migrated_comment_needle%'")
    testing.expect_value(t,indexed[0][0],"1")
    // Quarantined until the Hub cutover is observed.
    testing.expect(t,!control_ready(&f.store,"legacy_chain","t_ready") && !work_chain_active(&f.store,"legacy_chain"))
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,"too early")}))
    c,_:=contracts.owner_parse(command(f,"task.comment","early","t_ready",p,"1"),"command")
    c["chain_id"]=json.String("legacy_chain");sig,_:=test_sign(&f.creator_priv,"command",c);c["signature"]=json.String(sig)
    testing.expect_value(t,invoke(f,encode(c),p).code,"operation_conflict")
    pending,_:=migration_pending(&f.store)
    testing.expect(t,len(pending)==1 && pending[0][0]=="mig_rich" && pending[0][2]==m.digest)
    testing.expect_value(t,migration_activate(&f.store,"mig_rich",strings.repeat("e",64),2000,&f.kr,Signer{&f.owner_priv,test_sign}).code,"operation_conflict")
    activated:=migration_activate(&f.store,"mig_rich",m.digest,2000,&f.kr,Signer{&f.owner_priv,test_sign})
    testing.expect(t,activated.code=="ok" && !activated.replay)
    again:=migration_activate(&f.store,"mig_rich",m.digest,2000,&f.kr,Signer{&f.owner_priv,test_sign})
    testing.expect(t,again.code=="ok" && again.replay && again.seq==activated.seq,"activation is idempotent")
    testing.expect(t,control_ready(&f.store,"legacy_chain","t_ready") && work_chain_active(&f.store,"legacy_chain"))
    testing.expect(t,!control_ready(&f.store,"legacy_chain","t_blocked"),"native blocks survive activation")
    rows,_=query(f.store.db,"SELECT destination_bridge,payload_json FROM runtime_intents WHERE chain_id='legacy_chain' AND kind='registry' ORDER BY destination_bridge")
    testing.expect_value(t,len(rows),5)
    genesis_digest,_:=contracts.owner_digest("genesis",g)
    for row in rows {
        registry,valid:=contracts.owner_parse(row[1],"registry")
        testing.expect(t,valid && contracts.owner_verify_registry(registry,"account","bridge",genesis_digest,f.owner)==.None,"owner-signed registry for the chain and each task")
    }
    pending,_=migration_pending(&f.store)
    testing.expect_value(t,len(pending),0)
    // Restart keeps import, activation and archive.
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect(t,control_ready(&f.store,"legacy_chain","t_ready"))
    replay:=migration_test_import(f,m,3000)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==got.body)
}

@(test)
migration_import_failure_rolls_back_completely :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    m:=migration_test_build(f,"mig_fail",migration_test_rows(f))
    before:=migration_test_counts(f)
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER migration_fail BEFORE INSERT ON migration_import_documents WHEN NEW.doc_index>3 BEGIN SELECT RAISE(ABORT,'disk failure'); END"))
    testing.expect_value(t,migration_test_import(f,m).code,"storage_error")
    testing.expect_value(t,migration_test_counts(f),before)
    rows,_:=query(f.store.db,"SELECT count(*) FROM local_grants WHERE chain_id='legacy_chain'")
    testing.expect_value(t,rows[0][0],"0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER migration_fail"))
    // A busy native state cannot import idle and leaves nothing behind.
    busy:=migration_test_rows(f)
    busy["task"]=migration_list([]string{`{"task_id":"t_review","chain_id":"legacy_chain","owner_user_id":"account","title":"r","description":"","publish_state":"published","state":"in_review","priority":"p1","attempt_no":1,"brief_json":"{}","blocked_on_json":""}`})
    busy["comment"]=nil;busy["dependency"]=nil;busy["work_dependency"]=nil;busy["attempt"]=nil;busy["event"]=nil;busy["facet"]=nil;busy["review"]=nil
    testing.expect_value(t,migration_test_import(f,migration_test_build(f,"mig_busy",busy)).code,"operation_conflict")
    testing.expect_value(t,migration_test_counts(f),before)
    testing.expect_value(t,migration_test_import(f,m).code,"ok")
}

@(test)
migration_import_replay_conflict_owner_and_hash_refusals :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    rows:=migration_test_rows(f)
    m:=migration_test_build(f,"mig_once",rows)
    // A tampered document never matches its manifest hash.
    tampered:=m;tampered.documents=make([]string,len(m.documents))
    copy(tampered.documents,m.documents)
    tampered.documents[1]=strings.concatenate({tampered.documents[1][:len(tampered.documents[1])-2]," ]}"})
    testing.expect_value(t,migration_test_import(f,tampered).code,"digest_mismatch")
    // Wrong owner: the selection names another Bridge identity.
    sel,g:=migration_test_selection(f,"mig_other","other_bridge","other_key")
    manifest,documents:=migration_test_export(f,"mig_other",rows,sel)
    testing.expect_value(t,migration_test_import(f,{sel,g,manifest,contracts.owner_payload_digest(manifest),documents}).code,"owner_mismatch")
    // A genesis for a different creation operation cannot bind this migration.
    _,other_genesis:=migration_test_selection(f,"mig_elsewhere")
    wrong:=m;wrong.genesis=other_genesis
    testing.expect_value(t,migration_test_import(f,wrong).code,"invalid_scope")
    first:=migration_test_import(f,m)
    if !testing.expect_value(t,first.code,"ok") do return
    receipt,code,_:=migration_import_lookup(&f.store,"mig_once","legacy_chain",m.digest)
    testing.expect(t,code=="ok" && receipt==first.body,"lookup replays before any document is fetched")
    replay:=migration_test_import(f,m,5000)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==first.body)
    // Same migration, different manifest digest: conflict.
    changed:=migration_test_rows(f)
    changed["comment"]=nil
    other:=migration_test_build(f,"mig_once",changed)
    _,code,_=migration_import_lookup(&f.store,"mig_once","legacy_chain",other.digest)
    testing.expect_value(t,code,"operation_conflict")
    testing.expect_value(t,migration_test_import(f,other).code,"operation_conflict")
    // A different migration for the already imported chain also conflicts.
    testing.expect_value(t,migration_test_import(f,migration_test_build(f,"mig_twice",rows)).code,"operation_conflict")
    rows_after,_:=query(f.store.db,"SELECT count(*) FROM migration_imports")
    testing.expect_value(t,rows_after[0][0],"1")
}

// A real legacy chain usually lacks most kinds (no comments, history or
// dependencies); absent kinds import as empty.
@(test)
migration_import_minimal_chain_with_absent_kinds :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    full:=migration_test_rows(f)
    rows:=make(map[string][]string)
    rows["chain"]=full["chain"]
    rows["task"]=migration_list([]string{`{"task_id":"t_only","chain_id":"legacy_chain","owner_user_id":"account","title":"Only","description":"","publish_state":"draft","state":"backlog","priority":"p2","attempt_no":0,"brief_json":"{}","blocked_on_json":""}`})
    m:=migration_test_build(f,"mig_min",rows)
    got:=migration_test_import(f,m)
    if !testing.expect_value(t,got.code,"ok") do return
    counts,_:=query(f.store.db,"SELECT (SELECT count(*) FROM tasks WHERE chain_id='legacy_chain'),(SELECT count(*) FROM native_history_records),(SELECT count(*) FROM migration_import_documents)")
    testing.expect_value(t,encode(counts),encode([1][3]string{{"1","0","2"}}))
    rows2,_:=query(f.store.db,"SELECT publish_state FROM local_task_publications WHERE task_id='t_only'")
    testing.expect_value(t,encode(rows2),encode([1][1]string{{"draft"}}))
}

migration_test_op :: proc(cursor:string)->string { out,_:=strings.replace_all(cursor,":","_");return out }
migration_test_command :: proc(f:^Fixture,method,op,task,payload,revision:string)->string {
    c,_:=contracts.owner_parse(command(f,method,op,task,payload,revision),"command")
    c["chain_id"]=json.String("legacy_chain")
    sig,_:=test_sign(&f.creator_priv,"command",c);c["signature"]=json.String(sig)
    return encode(c)
}
migration_test_activate :: proc(t:^testing.T,f:^Fixture,m:Migration_Fixture,migration:string) {
    testing.expect_value(t,migration_activate(&f.store,migration,m.digest,1000,&f.kr,Signer{&f.owner_priv,test_sign}).code,"ok")
}

// R3 review: imported comments keep legacy order (created_at, then id) and
// timestamps, each with its own sequence, so pages never repeat or skip.
@(test)
migration_import_comments_keep_order_timestamps_and_stable_pages :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    rows:=migration_test_rows(f)
    c :: proc(id,created,body:string)->string { return fmt.tprintf(`{{"comment_id":"%s","task_id":"t_done","chain_id":"legacy_chain","owner_user_id":"account","author_agent_instance_id":"","body":"%s","created_at":"%s","updated_at":"%s","delegated_client_id":"","delegated_grant_id":""}}`,id,body,created,created) }
    rows["comment"]=migration_list([]string{c("cmt_c","2001-03-01T00:00:00Z","third"),c("cmt_b","2001-01-01T00:00:00Z","second"),c("cmt_a","2001-01-01T00:00:00Z","first")})
    m:=migration_test_build(f,"mig_comments",rows)
    if !testing.expect_value(t,migration_test_import(f,m).code,"ok") do return
    migration_test_activate(t,f,m,"mig_comments")
    stored,_:=query(f.store.db,"SELECT operation_id,created_at,seq FROM task_comments ORDER BY seq")
    testing.expect(t,len(stored)==3 && stored[0][0]=="cmt_a" && stored[1][0]=="cmt_b" && stored[2][0]=="cmt_c")
    testing.expect(t,number(stored[0][2])<number(stored[1][2]) && number(stored[1][2])<number(stored[2][2]),"one sequence per comment")
    events,_:=query(f.store.db,"SELECT seq FROM local_events WHERE kind='migration.import'")
    testing.expect(t,number(events[0][0])>number(stored[2][2]),"the import commits after its comment sequences")
    seen:=make([dynamic]string)
    cursor:=""
    for _ in 0..<5 {
        p:=encode(doc(map[string]string{"cursor"=cursor,"limit"="1"}))
        got:=invoke(f,migration_test_command(f,"task.read",fmt.tprintf("read_comments_%s",migration_test_op(cursor)),"t_done",p,"0"),p)
        if !testing.expect_value(t,got.code,"ok") do return
        v,_:=contracts.owner_content_document(got.body);o,_:=v.(json.Object);items,_:=o["items"].(json.Array)
        for item in items { row,_:=item.(json.Object);append(&seen,fmt.tprintf("%s@%s",field(row,"operation_id"),field(row,"created_at"))) }
        cursor=field(o,"next_cursor")
        if cursor=="" do break
    }
    testing.expect_value(t,strings.join(seen[:],","),"cmt_a@2001-01-01T00:00:00Z,cmt_b@2001-01-01T00:00:00Z,cmt_c@2001-03-01T00:00:00Z")
    // A new local comment records its commit time and sorts after imports.
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,"local")}))
    testing.expect_value(t,invoke(f,migration_test_command(f,"task.comment","local_comment","t_done",p,"1"),p,1999).code,"ok")
    local,_:=query(f.store.db,"SELECT created_at,seq>(SELECT max(seq) FROM task_comments WHERE operation_id!='local_comment') FROM task_comments WHERE operation_id='local_comment'")
    testing.expect_value(t,encode(local),encode([1][2]string{{"1970-01-01T00:00:01.999Z","1"}}))
    testing.expect_value(t,comment_time(1700000000123),"2023-11-14T22:13:20.123Z")
}

// R3 review blocker, owner side: a ticket gated on an unsucceeded workflow run
// or a live stage task is refused; finished stage tasks import as archive and
// can never be dispatched or reopened.
@(test)
migration_import_workflow_gates_and_stage_tasks :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    run :: proc(state:string)->(string,string) {
        return `{"run_id":"run_1","chain_id":"legacy_chain","owner_user_id":"account","current_execution_no":1}`,fmt.tprintf(`{{"run_id":"run_1","execution_no":1,"chain_id":"legacy_chain","owner_user_id":"account","state":"%s"}}`,state)
    }
    stage :: proc(state:string)->string { return fmt.tprintf(`{{"task_id":"t_stage","chain_id":"legacy_chain","owner_user_id":"account","title":"Stage","description":"","publish_state":"published","state":"%s","kind":"task","priority":"p1","attempt_no":1,"brief_json":"{{\"goal\":\"g\",\"acceptance\":[\"a\"]}}","blocked_on_json":"","workflow_run_id":"run_1","workflow_execution_no":1,"stage_key":"build"}}`,state) }
    gated:=migration_test_rows(f)
    r,e:=run("failed")
    gated["workflow_run"]=migration_list([]string{r});gated["workflow_execution"]=migration_list([]string{e})
    gated["work_dependency"]=migration_list([]string{`{"dependency_id":"dep_gate","chain_id":"legacy_chain","owner_user_id":"account","dependent_kind":"task","dependent_id":"t_ready","prerequisite_kind":"workflow_run","prerequisite_id":"run_1","created_by_kind":"user","created_by_id":"account","created_at":"x","removed_at":"","removed_by_kind":"","removed_by_id":"","removal_reason":""}`})
    testing.expect_value(t,migration_test_import(f,migration_test_build(f,"mig_gated",gated)).code,"operation_conflict")
    live:=migration_test_rows(f)
    r,e=run("running")
    live["workflow_run"]=migration_list([]string{r});live["workflow_execution"]=migration_list([]string{e})
    live["task"]=migration_list([]string{live["task"][0],stage("ready")})
    testing.expect_value(t,migration_test_import(f,migration_test_build(f,"mig_live_stage",live)).code,"operation_conflict")
    rows,_:=query(f.store.db,"SELECT count(*) FROM task_chains")
    testing.expect_value(t,rows[0][0],"0")
    // A finished run: its succeeded dependency is satisfied and its stage task
    // (still nominally ready in the Hub) is archival.
    done:=migration_test_rows(f)
    r,e=run("failed")
    done["workflow_run"]=migration_list([]string{r});done["workflow_execution"]=migration_list([]string{e})
    tasks:=make([dynamic]string)
    for task in done["task"] do append(&tasks,task)
    append(&tasks,stage("ready"))
    done["task"]=tasks[:]
    m:=migration_test_build(f,"mig_stage",done)
    if !testing.expect_value(t,migration_test_import(f,m).code,"ok") do return
    migration_test_activate(t,f,m,"mig_stage")
    testing.expect(t,migration_archived_task(&f.store,"legacy_chain","t_stage") && !work_task_published(&f.store,"legacy_chain","t_stage"),"a stage task is never dispatchable")
    testing.expect(t,work_task_published(&f.store,"legacy_chain","t_ready"))
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,"cancel stage")}))
    testing.expect_value(t,invoke(f,migration_test_command(f,"task.cancel","cancel_stage","t_stage",p,"1"),p).code,"ok")
    rev,_:=query(f.store.db,"SELECT revision FROM tasks WHERE task_id='t_stage'")
    p=encode(doc(map[string]string{"body_cipher"=cipher(f,"reopen stage")}))
    testing.expect_value(t,invoke(f,migration_test_command(f,"task.reopen","reopen_stage","t_stage",p,rev[0][0]),p).code,"operation_conflict")
}

// R3 review: the verbatim archive is readable, chain-scoped, paged and
// filterable by kind and task.
@(test)
migration_import_archive_read_pages_by_kind_and_task :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    rows:=migration_test_rows(f)
    rows["review"]=migration_list([]string{
        `{"task_id":"t_done","chain_id":"legacy_chain","owner_user_id":"account","attempt_no":1,"role":"","reviewer_kind":"user","reviewer_agent_id":"","reviewer_instance_id":"","verdict":"approve","findings_json":"[]","created_at":"r1"}`,
        `{"task_id":"t_ready","chain_id":"legacy_chain","owner_user_id":"account","attempt_no":1,"role":"security","reviewer_kind":"agent","reviewer_agent_id":"agt_r","reviewer_instance_id":"inst_r","verdict":"request_changes","findings_json":"[{\"note\":\"fix\"}]","created_at":"r2"}`,
        `{"task_id":"t_done","chain_id":"legacy_chain","owner_user_id":"account","attempt_no":2,"role":"security","reviewer_kind":"agent","reviewer_agent_id":"agt_r","reviewer_instance_id":"inst_r","verdict":"approve","findings_json":"[]","created_at":"r3"}`})
    m:=migration_test_build(f,"mig_archive",rows)
    if !testing.expect_value(t,migration_test_import(f,m).code,"ok") do return
    read :: proc(f:^Fixture,kind,task,cursor:string)->(json.Object,string) {
        p:=encode(doc(map[string]string{"kind"=kind,"task_id"=task,"cursor"=cursor,"limit"="1"}))
        got:=invoke(f,migration_test_command(f,"migration.archive.read",fmt.tprintf("archive_%s_%s_%s",kind,task,migration_test_op(cursor)),"",p,"0"),p)
        v,_:=contracts.owner_content_document(got.body);o,_:=v.(json.Object)
        return o,got.code
    }
    verdicts:=make([dynamic]string)
    cursor:=""
    for _ in 0..<5 {
        o,code:=read(f,"review","t_done",cursor)
        if !testing.expect_value(t,code,"ok") do return
        items,_:=o["items"].(json.Array)
        for item in items {
            row,_:=item.(json.Object)
            testing.expect_value(t,field(row,"kind"),"review")
            record,_:=contracts.owner_content_document(field(row,"record"));r,_:=record.(json.Object)
            attempt,_:=r["attempt_no"].(json.Integer)
            append(&verdicts,fmt.tprintf("%d:%s",i64(attempt),field(r,"verdict")))
        }
        cursor=field(o,"next_cursor")
        if cursor=="" do break
    }
    testing.expect_value(t,strings.join(verdicts[:],","),"1:approve,2:approve")
    o,code:=read(f,"comment","","")
    items,_:=o["items"].(json.Array)
    testing.expect(t,code=="ok" && len(items)==1)
    _,code=read(f,"review","","bad")
    testing.expect_value(t,code,"malformed")
    // Reads are allowed while quarantined; no mutation is.
    testing.expect(t,migration_quarantined(&f.store,"legacy_chain"))
}

// R3 review: an import whose Hub migration was aborted is abandoned: never
// polled again and never activated.
@(test)
migration_import_abandoned_import_never_activates :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    m:=migration_test_build(f,"mig_aborted",migration_test_rows(f))
    if !testing.expect_value(t,migration_test_import(f,m).code,"ok") do return
    testing.expect(t,migration_abandon(&f.store,"mig_aborted"))
    pending,_:=migration_pending(&f.store)
    testing.expect_value(t,len(pending),0)
    testing.expect(t,migration_activate(&f.store,"mig_aborted",m.digest,2000,&f.kr,Signer{&f.owner_priv,test_sign}).code!="ok")
    testing.expect(t,migration_quarantined(&f.store,"legacy_chain") && !control_ready(&f.store,"legacy_chain","t_ready"))
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect(t,migration_quarantined(&f.store,"legacy_chain"))
}

// R3 re-review: an abandoned import never yields a receipt, and a new
// migration of the same chain to this owner replaces it (abort, then
// re-migrate to the same Bridge).
@(test)
migration_import_abandoned_import_is_replaced_by_a_new_migration :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    rows:=migration_test_rows(f)
    first:=migration_test_build(f,"mig_first",rows)
    if !testing.expect_value(t,migration_test_import(f,first).code,"ok") do return
    second:=migration_test_build(f,"mig_second",rows)
    _,code,other:=migration_import_lookup(&f.store,"mig_second","legacy_chain",second.digest)
    testing.expect(t,code=="pending_other" && other=="mig_first","a pending import of the chain is named, not replaced")
    testing.expect_value(t,migration_test_import(f,second).code,"operation_conflict")
    testing.expect(t,migration_abandon(&f.store,"mig_first"))
    // The abandoned migration is terminal: no receipt, no replay.
    receipt,aborted,_:=migration_import_lookup(&f.store,"mig_first","legacy_chain",first.digest)
    testing.expect(t,aborted=="migration_aborted" && receipt=="")
    testing.expect_value(t,migration_test_import(f,first).code,"migration_aborted")
    _,code,_=migration_import_lookup(&f.store,"mig_second","legacy_chain",second.digest)
    testing.expect_value(t,code,"miss")
    got:=migration_test_import(f,second)
    if !testing.expect_value(t,got.code,"ok") do return
    counts,_:=query(f.store.db,`SELECT (SELECT count(*) FROM tasks WHERE chain_id='legacy_chain'),(SELECT count(*) FROM task_comments WHERE chain_id='legacy_chain'),
      (SELECT group_concat(migration_id) FROM migration_imports),(SELECT count(*) FROM migration_import_documents WHERE migration_id='mig_first'),
      (SELECT creation_op FROM chain_genesis WHERE chain_id='legacy_chain'),(SELECT replaced_by FROM migration_discarded WHERE migration_id='mig_first'),
      (SELECT count(*) FROM native_history_records WHERE chain_id='legacy_chain')`)
    testing.expect_value(t,encode(counts),encode([1][7]string{{"4","1","mig_second","0","mig_second","mig_second","3"}}))
    fk,_:=query(f.store.db,"PRAGMA foreign_key_check");testing.expect_value(t,len(fk),0)
    guards,_:=query(f.store.db,"SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name IN('genesis_immutable_delete','migration_import_no_delete','migration_abandoned_no_delete')")
    testing.expect_value(t,guards[0][0],"3")
    testing.expect(t,!exec(f.store.db,"DELETE FROM chain_genesis"),"delete guards are restored")
    // The replacement activates normally; the discarded id stays terminal.
    migration_test_activate(t,f,second,"mig_second")
    testing.expect(t,control_ready(&f.store,"legacy_chain","t_ready"))
    _,code,_=migration_import_lookup(&f.store,"mig_first","legacy_chain",first.digest)
    testing.expect_value(t,code,"migration_aborted")
    // An activated import is never replaced.
    third:=migration_test_build(f,"mig_third",rows)
    _,code,_=migration_import_lookup(&f.store,"mig_third","legacy_chain",third.digest)
    testing.expect_value(t,code,"operation_conflict")
}
