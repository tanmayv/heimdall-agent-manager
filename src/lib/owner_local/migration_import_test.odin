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
        `{"dependency_id":"dep_run","chain_id":"legacy_chain","owner_user_id":"account","dependent_kind":"task","dependent_id":"t_ready","prerequisite_kind":"workflow_run","prerequisite_id":"run_1","created_by_kind":"user","created_by_id":"account","created_at":"x","removed_at":"","removed_by_kind":"","removed_by_id":"","removal_reason":""}`,
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
    receipt,code:=migration_import_lookup(&f.store,"mig_once","legacy_chain",m.digest)
    testing.expect(t,code=="ok" && receipt==first.body,"lookup replays before any document is fetched")
    replay:=migration_test_import(f,m,5000)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==first.body)
    // Same migration, different manifest digest: conflict.
    changed:=migration_test_rows(f)
    changed["comment"]=nil
    other:=migration_test_build(f,"mig_once",changed)
    _,code=migration_import_lookup(&f.store,"mig_once","legacy_chain",other.digest)
    testing.expect_value(t,code,"operation_conflict")
    testing.expect_value(t,migration_test_import(f,other).code,"operation_conflict")
    // A different migration for the already imported chain also conflicts.
    testing.expect_value(t,migration_test_import(f,migration_test_build(f,"mig_twice",rows)).code,"operation_conflict")
    rows_after,_:=query(f.store.db,"SELECT count(*) FROM migration_imports")
    testing.expect_value(t,rows_after[0][0],"1")
}
