#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"

// R3 `migration.import`: one-shot import of a frozen legacy Hub chain into this
// owner. One transaction verifies the signed selection and genesis and the
// exact manifest/document hashes, creates the chain and genesis
// (creation_op = migration_id), projects live tables with original IDs and
// authors, carries native done/cancelled/blocked state into lifecycle_state and
// local_controls, imports attempts/events/facets as native history, archives
// every document verbatim, rechecks counts and signs migration_import_receipt.
// The chain stays quarantined until migration_activate records the Hub cutover.
MIGRATION_SOURCE_REVISION :: "legacy_import"
MIGRATION_IMPORT_METHOD :: "migration.import"
MIGRATION_ACTIVATE_METHOD :: "migration.activate"

Migration_Import_Input :: struct {
    selection_raw, genesis_raw, manifest_raw: string, // genesis already carries owner_signature
    documents: []string,
}

migration_quarantined :: proc(s:^Store,chain:string) -> bool {
    rows,ok:=query(s.db,"SELECT 1 FROM migration_imports WHERE chain_id=? AND activated_seq IS NULL",chain)
    return !ok || len(rows)>0
}

// Before fetching any document: an exact earlier import replays its stored
// receipt, a different digest for the same migration or chain conflicts.
migration_import_lookup :: proc(s:^Store,migration,chain,manifest_digest:string) -> (receipt,code:string) {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    rows,ok:=query(s.db,"SELECT manifest_digest,receipt_json,migration_id FROM migration_imports WHERE migration_id=? OR chain_id=?",migration,chain)
    if !ok do return "","storage_error"
    if len(rows)==0 do return "","miss"
    if len(rows)!=1 || rows[0][0]!=manifest_digest || rows[0][2]!=migration do return "","operation_conflict"
    return rows[0][1],"ok"
}

// Imports whose Hub cutover has not yet been observed: (migration, chain, digest).
migration_pending :: proc(s:^Store) -> ([][3]string,bool) {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    rows,ok:=query(s.db,"SELECT migration_id,chain_id,manifest_digest FROM migration_imports WHERE activated_seq IS NULL ORDER BY migration_id LIMIT 20")
    if !ok do return nil,false
    out:=make([dynamic][3]string,context.temp_allocator)
    for r in rows do append(&out,[3]string{r[0],r[1],r[2]})
    return out[:],true
}

migration_plain :: proc(v:string,kr:^vault.Vault_Keyring) -> (string,bool) {
    if !vault.is_armored(v) do return v,true
    if kr==nil do return "",false
    plain,res:=vault.open(v,kr,context.temp_allocator)
    return plain,res==.Ok
}
migration_text :: proc(row:json.Object,name:string) -> string {
    #partial switch v in row[name] {
    case json.String: return string(v)
    case json.Integer: return fmt.tprintf("%d",i64(v))
    }
    return ""
}

Migration_Rows :: map[string][dynamic]json.Object

migration_import :: proc(s:^Store,input:Migration_Import_Input,device,owner_key:contracts.Owner_Verified_Key,
    directory_version:i64,directory_hash:string,now:i64,kr:^vault.Vault_Keyring,sign:Signer) -> Result {
    context.allocator=context.temp_allocator
    if s.db==nil || device.account_id!=s.account || owner_key.account_id!=s.account || owner_key.principal_id!=s.owner ||
       owner_key.key_id!=s.owner_key || owner_key.kind!="bridge" || !owner_key.enrolled || owner_key.revoked || sign.sign==nil { return fail("invalid_scope") }
    selection,sel_ok:=contracts.owner_parse(input.selection_raw,"migration_selection")
    genesis,gen_ok:=contracts.owner_parse(input.genesis_raw,"genesis")
    if !sel_ok || !gen_ok do return fail("malformed")
    chain,migration,principal:=field(selection,"chain_id"),field(selection,"migration_id"),field(selection,"principal_id")
    if e:=contracts.owner_verify_migration_selection(selection,s.account,chain,device,owner_key);e!=.None do return auth_fail(e)
    if e:=contracts.owner_verify_genesis(genesis,s.account,s.owner,device,owner_key);e!=.None do return auth_fail(e)
    if field(genesis,"chain_id")!=chain || field(genesis,"creation_op")!=migration do return fail("invalid_scope")
    selection_digest,_:=contracts.owner_digest("migration_selection",selection)
    genesis_digest,_:=contracts.owner_digest("genesis",genesis)
    manifest_digest:=contracts.owner_payload_digest(input.manifest_raw)
    manifest,manifest_ok:=contracts.owner_migration_manifest_parse(input.manifest_raw)
    if !manifest_ok do return fail("invalid_content")
    if manifest.account_id!=s.account || manifest.chain_id!=chain || manifest.migration_id!=migration || manifest.selection_digest!=selection_digest do return fail("digest_mismatch")

    tx:Transaction
    if !transaction_begin(s,&tx) do return fail("storage_error")
    defer transaction_rollback(&tx)
    state,ok:=query(s.db,"SELECT commit_seq,clock_high_ms,directory_version,directory_hash,recovery_state,database_id FROM runtime_database WHERE singleton=1")
    if !ok || len(state)!=1 do return fail("storage_error")
    if directory_version!=number(state[0][2]) || directory_hash!=state[0][3] do return fail("invalid_scope")
    existing,found:=query(s.db,"SELECT manifest_digest,receipt_json,migration_id,selection_digest FROM migration_imports WHERE migration_id=? OR chain_id=?",migration,chain)
    if !found do return fail("storage_error")
    if len(existing)>0 {
        if len(existing)!=1 || existing[0][0]!=manifest_digest || existing[0][2]!=migration || existing[0][3]!=selection_digest do return fail("operation_conflict")
        if !transaction_commit(&tx) do return fail("storage_error")
        return Result{code="ok",body=existing[0][1],replay=true}
    }
    if now<number(state[0][1]) {
        if !mark_clock_uncertain(&tx) do return fail("storage_error")
        return fail("clock_uncertain")
    }
    if state[0][4]!="ready" do return fail("clock_uncertain")
    clash,read:=query(s.db,"SELECT 1 FROM task_chains WHERE chain_id=? UNION ALL SELECT 1 FROM chain_genesis WHERE creation_op=? UNION ALL SELECT 1 FROM command_receipts WHERE principal_id=? AND operation_id=?",chain,migration,principal,migration)
    if !read do return fail("storage_error")
    if len(clash)>0 do return fail("operation_conflict")

    // Every document must hash to its manifest entry before anything is written.
    if len(input.documents)!=len(manifest.documents) do return fail("digest_mismatch")
    rows:=make(Migration_Rows)
    for ref,i in manifest.documents {
        items,valid:=contracts.owner_migration_document_parse(input.documents[i],ref)
        if !valid do return fail("digest_mismatch")
        list:=rows[ref.kind]
        for item in items {
            row:=item.(json.Object)
            // Every scoped row belongs to this chain and account.
            for name in ([2]string{"chain_id","task_chain_id"}) {
                if _,has:=row[name];has && migration_text(row,name)!=chain do return fail("invalid_scope")
            }
            if _,has:=row["owner_user_id"];has && migration_text(row,"owner_user_id")!=s.account do return fail("invalid_scope")
            append(&list,row)
        }
        rows[ref.kind]=list
    }
    if len(rows["chain"])!=1 do return fail("invalid_content")
    seq:=number(state[0][0])+1
    stamp:=fmt.tprintf("%d",seq)
    summary:=make(map[string]i64)
    if code:=migration_project(s,chain,principal,field(selection,"key_id"),migration,rows,seq,now,kr,&summary);code!="ok" do return fail(code)
    if _,ok=query(s.db,"INSERT INTO chain_genesis(chain_id,creation_op,genesis_digest,genesis_json,import_manifest_hash) VALUES(?,?,?,?,?)",chain,migration,genesis_digest,input.genesis_raw,manifest_digest);!ok do return fail("storage_error")
    if code:=migration_native_history(s,chain,rows,seq,&summary);code!="ok" do return fail(code)

    receipt:=doc(map[string]string{"protocol_version"="1","account_id"=s.account,"chain_id"=chain,"migration_id"=migration,"owner_bridge_id"=s.owner,"key_id"=s.owner_key,
        "selection_digest"=selection_digest,"manifest_digest"=manifest_digest,"genesis_digest"=genesis_digest,"database_id"=state[0][5],"import_seq"=stamp,
        "schema_version"=field(genesis,"schema_version"),"signature"=strings.repeat("0",128)})
    signature,signed:=sign.sign(sign.ctx,"migration_import_receipt",receipt)
    if !signed do return fail("storage_error")
    receipt["signature"]=json.String(signature)
    receipt_raw:=encode(receipt)
    if _,ok=query(s.db,"INSERT INTO migration_imports VALUES(?,?,?,?,?,?,?,?,?,?,NULL)",migration,manifest_digest,chain,selection_digest,principal,field(selection,"key_id"),stamp,input.manifest_raw,receipt_raw,encode(summary));!ok do return fail("storage_error")
    for ref,i in manifest.documents {
        if _,ok=query(s.db,"INSERT INTO migration_import_documents VALUES(?,?,?,?,?,?)",migration,fmt.tprintf("%d",ref.index),ref.kind,fmt.tprintf("%d",ref.rows),ref.sha256,input.documents[i]);!ok do return fail("storage_error")
    }
    // Count check: live projections and the archive hold exactly what the
    // manifest promised.
    checks,checked:=query(s.db,`SELECT (SELECT count(*) FROM tasks WHERE chain_id=?1),(SELECT count(*) FROM task_comments WHERE chain_id=?1),
      (SELECT count(*) FROM migration_import_documents WHERE migration_id=?2),(SELECT coalesce(sum(row_count),0) FROM migration_import_documents WHERE migration_id=?2)`,chain,migration)
    if !checked || len(checks)!=1 do return fail("storage_error")
    total:i64
    for k in manifest.kinds do total+=k.rows
    if number(checks[0][0])!=i64(len(rows["task"])) || number(checks[0][1])!=i64(len(rows["comment"])) || number(checks[0][2])!=i64(len(manifest.documents)) || number(checks[0][3])!=total do return fail("invalid_content")
    if _,ok=query(s.db,"INSERT INTO command_receipts(principal_id,operation_id,chain_id,task_id,method,input_digest,digest_key_id,request_expires_ms,result_json,commit_seq,created_ms) VALUES(?,?,?,'',?,?,?,?,?,?,?)",
        principal,migration,chain,MIGRATION_IMPORT_METHOD,manifest_digest,field(selection,"key_id"),field(selection,"request_expires_ms"),receipt_raw,stamp,fmt.tprintf("%d",now));!ok do return fail("storage_error")
    if _,ok=query(s.db,"INSERT INTO local_changes VALUES(?,?,?,'',1,?)",stamp,chain,MIGRATION_IMPORT_METHOD,migration);!ok do return fail("storage_error")
    if !event_record(&tx,seq,now,chain,"","device",principal,MIGRATION_IMPORT_METHOD,migration,input.selection_raw,manifest_digest,encode(summary),receipt_raw) do return fail("storage_error")
    if _,ok=query(s.db,"UPDATE runtime_database SET commit_seq=?,clock_high_ms=?,directory_version=?,directory_hash=? WHERE singleton=1",stamp,fmt.tprintf("%d",now),fmt.tprintf("%d",directory_version),directory_hash);!ok do return fail("storage_error")
    if !transaction_commit(&tx) do return fail("storage_error")
    return Result{code="ok",body=receipt_raw,seq=seq}
}

// Live projection. Titles, descriptions and bodies are decrypted from the
// legacy vault ciphertext; IDs and authors are the legacy ones.
migration_project :: proc(s:^Store,chain,principal,key_id,migration:string,rows:Migration_Rows,seq,now:i64,kr:^vault.Vault_Keyring,summary:^map[string]i64) -> string {
    stamp:=fmt.tprintf("%d",seq)
    c:=rows["chain"][0]
    title,t_ok:=migration_plain(migration_text(c,"title"),kr)
    description,d_ok:=migration_plain(migration_text(c,"description"),kr)
    if !t_ok || !d_ok do return "invalid_content"
    if _,ok:=query(s.db,"INSERT INTO task_chains VALUES(?,?,?,?,?,1)",chain,principal,key_id,title,description);!ok do return "storage_error"
    if _,ok:=query(s.db,"INSERT INTO local_grants VALUES(?,?,?,1,?,1,1,0)",chain,principal,key_id,fmt.tprintf("%d",now+GRANT_MAX_TTL_MS));!ok do return "storage_error"
    // Owner-local chains are active or completed; cancelled/archived chains
    // admit no further work, which is the completed behavior.
    status:="active" if migration_text(c,"status")=="active" else "completed"
    if status!="active" do summary^["chain_status_completed"]+=1
    publish:="draft" if migration_text(c,"publish_state")=="draft" else "published"
    // task_chains inserts the work row; publication/status are the legacy ones.
    if _,ok:=query(s.db,"UPDATE local_work_chains SET publish_state=?,status=? WHERE chain_id=?",publish,status,chain);!ok do return "storage_error"
    if defaults:=migration_text(c,"defaults_json");defaults!="" && defaults!="{}" {
        if _,ok:=query(s.db,"INSERT INTO local_chain_defaults_versions VALUES(?,?,?)",chain,stamp,defaults);!ok do return "invalid_content"
    }
    for t in rows["task"] {
        task:=migration_text(t,"task_id")
        if !contracts.owner_field_valid(task,"id") do return "invalid_content"
        task_title,a:=migration_plain(migration_text(t,"title"),kr)
        body,b:=migration_plain(migration_text(t,"description"),kr)
        if !a || !b do return "invalid_content"
        if _,ok:=query(s.db,"INSERT INTO tasks VALUES(?,?,?,?,1)",chain,task,task_title,body);!ok do return "operation_conflict"
        task_publish:="draft" if migration_text(t,"publish_state")=="draft" else "published"
        if _,ok:=query(s.db,"INSERT INTO local_task_publications VALUES(?,?,?,?)",chain,task,stamp,task_publish);!ok do return "storage_error"
        if p:=migration_text(t,"priority");p=="p0" || p=="p1" || p=="p2" {
            if _,ok:=query(s.db,"INSERT INTO local_task_priority_versions VALUES(?,?,?,?)",chain,task,stamp,p);!ok do return "storage_error"
        }
        brief,c_ok:=migration_plain(migration_text(t,"brief_json"),kr)
        if c_ok && brief_valid(brief) {
            if _,ok:=query(s.db,"INSERT INTO task_requirements VALUES(?,?,1,?,'',?,?)",chain,task,brief,principal,migration);!ok do return "storage_error"
        } else do summary^["brief_not_imported"]+=1
        // Carry the native terminal/blocked state into live lifecycle and
        // controls (R2 follow-up). Busy states were refused before freeze.
        native_state,blocked:=migration_text(t,"state"),migration_text(t,"blocked_on_json")
        switch {
        case native_state=="done":
            if _,ok:=query(s.db,"INSERT INTO lifecycle_state(chain_id,task_id,state,attempt) VALUES(?,?,'done',?)",chain,task,migration_text(t,"attempt_no"));!ok do return "storage_error"
        case native_state=="cancelled":
            if _,ok:=query(s.db,"INSERT INTO local_controls VALUES(?,?,'cancelled','ready','imported: cancelled in legacy chain','')",chain,task);!ok do return "storage_error"
        case native_state=="in_progress" || native_state=="in_review":
            return "operation_conflict"
        case blocked!="":
            reason,waiting:="imported: blocked in legacy chain","human"
            if v,valid:=contracts.owner_content_document(blocked);valid {
                if o,obj:=v.(json.Object);obj {
                    if r:=field(o,"reason");r!="" do reason=r
                    if k:=field(o,"kind");k!="" do waiting=k
                }
            }
            if _,ok:=query(s.db,"INSERT INTO local_controls VALUES(?,?,'blocked','ready',?,?)",chain,task,reason,waiting);!ok do return "storage_error"
        }
        summary^["task"]+=1
    }
    for d in rows["dependency"] {
        if _,ok:=query(s.db,"INSERT INTO local_dependencies VALUES(?,?,?)",chain,migration_text(d,"task_id"),migration_text(d,"depends_on_task_id"));!ok do return "invalid_content"
    }
    for d in rows["work_dependency"] {
        if migration_text(d,"removed_at")!="" || migration_text(d,"dependent_kind")!="task" || migration_text(d,"prerequisite_kind")!="task" { summary^["work_dependency_archival"]+=1;continue }
        if _,ok:=query(s.db,"INSERT INTO local_work_dependencies VALUES(?,?,'task',?,'task',?,?,?,?,?)",chain,migration_text(d,"dependency_id"),migration_text(d,"dependent_id"),migration_text(d,"prerequisite_id"),
            migration_text(d,"created_at"),migration_text(d,"created_by_kind"),migration_text(d,"created_by_id"),stamp);!ok do return "invalid_content"
    }
    for m in rows["comment"] {
        body,ok:=migration_plain(migration_text(m,"body"),kr)
        if !ok do return "invalid_content"
        author:=migration_text(m,"author_agent_instance_id")
        if author=="" do author=migration_text(m,"owner_user_id")
        if _,ok=query(s.db,"INSERT INTO task_comments VALUES(?,?,?,?,?,?)",chain,migration_text(m,"task_id"),migration_text(m,"comment_id"),author,body,stamp);!ok do return "invalid_content"
    }
    for m in rows["summary"] {
        curated,ok:=migration_plain(migration_text(m,"curated_body"),kr)
        if !ok do return "invalid_content"
        if curated=="" do continue
        if _,ok=query(s.db,"INSERT INTO local_chain_summary_versions VALUES(?,?,?)",chain,stamp,curated);!ok do return "storage_error"
    }
    // Imports bump the local work revision through triggers; never go below
    // the legacy revision clients last observed.
    if _,ok:=query(s.db,"UPDATE local_work_chains SET work_revision=max(work_revision,CAST(? AS INTEGER)) WHERE chain_id=?",migration_text(c,"work_revision"),chain);!ok do return "storage_error"
    if completions:=rows["work_completion"];len(completions)>0 {
        last:=completions[len(completions)-1]
        if _,ok:=query(s.db,"INSERT INTO local_work_completions VALUES(?,?,?,?,'user',?,?)",chain,migration_text(last,"work_revision"),migration_text(last,"summary"),migration_text(last,"completed_at"),s.account,stamp);!ok do return "storage_error"
    }
    return "ok"
}

// Attempts, events and facets become native history snapshots through the
// existing archival importer. A record the native vocabulary cannot hold
// stays only in the verbatim archive and is counted, never invented.
migration_native_history :: proc(s:^Store,chain:string,rows:Migration_Rows,seq:i64,summary:^map[string]i64) -> string {
    per_task:=make(map[string][3][dynamic]string)
    attempts:=make(map[string]bool)
    order:=make([dynamic]string)
    for t in rows["task"] { append(&order,migration_text(t,"task_id")) }
    add :: proc(per_task:^map[string][3][dynamic]string,task:string,slot:int,record:string) {
        lists:=per_task[task]
        append(&lists[slot],record)
        per_task[task]=lists
    }
    for a in rows["attempt"] {
        task,attempt:=migration_text(a,"task_id"),migration_text(a,"attempt_no")
        r:=encode(doc(map[string]string{"task_id"=task,"attempt_no"=attempt,"chain_id"=chain,"owner_user_id"=s.account,"started_at"=migration_text(a,"started_at"),"ended_at"=migration_text(a,"ended_at"),
            "holder_instance_id"=migration_text(a,"holder_instance_id"),"outcome"=migration_text(a,"outcome"),"counts_toward_budget"="0" if migration_text(a,"counts_toward_budget")=="0" else "1","provenance_json"="{}"}))
        if _,ok:=native_content_parse(r,"native_history_attempt");!ok { summary^["attempt_archival_only"]+=1;continue }
        attempts[fmt.tprintf("%s/%s",task,attempt)]=true
        add(&per_task,task,0,r)
    }
    for e in rows["event"] {
        task:=migration_text(e,"task_id")
        r:=encode(doc(map[string]string{"event_id"=migration_text(e,"event_id"),"task_id"=task,"chain_id"=chain,"owner_user_id"=s.account,"ts_ms"=migration_text(e,"ts_ms"),"actor_kind"=migration_text(e,"actor_kind"),
            "actor_id"=migration_text(e,"actor_id"),"kind"=migration_text(e,"kind"),"payload_json"=migration_text(e,"payload_json"),"provenance_json"="{}"}))
        parsed,ok:=native_content_parse(r,"native_history_event")
        if !ok || !native_json_object(field(parsed,"payload_json")) { summary^["event_archival_only"]+=1;continue }
        add(&per_task,task,1,r)
    }
    for f in rows["facet"] {
        task,attempt:=migration_text(f,"task_id"),migration_text(f,"attempt_no")
        r:=encode(doc(map[string]string{"task_id"=task,"attempt_no"=attempt,"chain_id"=chain,"owner_user_id"=s.account,"kind"=migration_text(f,"kind"),"v"=migration_text(f,"v"),"body_json"=migration_text(f,"body_json"),
            "writer"=migration_text(f,"writer"),"written_at"=migration_text(f,"written_at"),"references_json"="[]","provenance_json"="{}"}))
        parsed,ok:=native_content_parse(r,"native_history_facet")
        if !ok || !native_json_object(field(parsed,"body_json")) || (attempt!="0" && !attempts[fmt.tprintf("%s/%s",task,attempt)]) { summary^["facet_archival_only"]+=1;continue }
        add(&per_task,task,2,r)
    }
    names:=[3]string{"attempts","events","facets"}
    for task in order {
        lists,has:=per_task[task]
        if !has do continue
        c:=doc(map[string]string{"chain_id"=chain,"task_id"=task})
        for slot in 0..<3 {
            for start:=0;start<len(lists[slot]); {
                end,size:=start,0
                for end<len(lists[slot]) && end-start<100 && (end==start || size+len(lists[slot][end])+64<contracts.OWNER_DOCUMENT_MAX/2) { size+=len(lists[slot][end])+64;end+=1 }
                bundle:=doc(map[string]string{"source_revision"=MIGRATION_SOURCE_REVISION,"owner_user_id"=s.account,"completeness"="full","attempts"="[]","events"="[]","facets"="[]"})
                bundle[names[slot]]=json.String(encode(lists[slot][start:end]))
                if code:=native_history_import(s,c,encode(bundle),seq);code!="ok" do return code
                summary[names[slot]]+=i64(end-start)
                start=end
            }
        }
    }
    return "ok"
}

// Records the Hub cutover locally: lifts the quarantine and publishes the
// owner-signed registry (chain and task titles) through the normal outbox.
// Idempotent; an activated import replays.
migration_activate :: proc(s:^Store,migration,manifest_digest:string,now:i64,kr:^vault.Vault_Keyring,sign:Signer) -> Result {
    context.allocator=context.temp_allocator
    if s.db==nil || sign.sign==nil do return fail("invalid_scope")
    tx:Transaction
    if !transaction_begin(s,&tx) do return fail("storage_error")
    defer transaction_rollback(&tx)
    rows,ok:=query(s.db,"SELECT chain_id,manifest_digest,principal_id,key_id,activated_seq FROM migration_imports WHERE migration_id=?",migration)
    if !ok do return fail("storage_error")
    if len(rows)!=1 do return fail("invalid_scope")
    if rows[0][1]!=manifest_digest do return fail("operation_conflict")
    chain,principal,key_id:=rows[0][0],rows[0][2],rows[0][3]
    if rows[0][4]!="" {
        if !transaction_commit(&tx) do return fail("storage_error")
        return Result{code="ok",body=encode(map[string]string{"chain_id"=chain,"migration_id"=migration,"activated_seq"=rows[0][4]}),seq=number(rows[0][4]),replay=true}
    }
    state,read:=query(s.db,"SELECT commit_seq,clock_high_ms FROM runtime_database WHERE singleton=1")
    if !read || len(state)!=1 do return fail("storage_error")
    seq:=number(state[0][0])+1
    stamp:=fmt.tprintf("%d",seq)
    op:=fmt.tprintf("activate_%s",contracts.owner_payload_digest(migration)[:40])
    result:=encode(map[string]string{"chain_id"=chain,"migration_id"=migration,"activated_seq"=stamp})
    if _,ok=query(s.db,"UPDATE migration_imports SET activated_seq=? WHERE migration_id=?",stamp,migration);!ok do return fail("storage_error")
    if _,ok=query(s.db,"INSERT INTO command_receipts(principal_id,operation_id,chain_id,task_id,method,input_digest,digest_key_id,request_expires_ms,result_json,commit_seq,created_ms) VALUES(?,?,?,'',?,?,?,0,?,?,?)",
        principal,op,chain,MIGRATION_ACTIVATE_METHOD,manifest_digest,key_id,result,stamp,fmt.tprintf("%d",max(now,0)));!ok do return fail("storage_error")
    if _,ok=query(s.db,"INSERT INTO local_changes VALUES(?,?,?,'',1,?)",stamp,chain,MIGRATION_ACTIVATE_METHOD,op);!ok do return fail("storage_error")
    if !event_record(&tx,seq,max(now,number(state[0][1])),chain,"","bridge",s.owner,MIGRATION_ACTIVATE_METHOD,op,"",manifest_digest,"{}",result) do return fail("storage_error")
    genesis,found:=query(s.db,"SELECT genesis_digest FROM chain_genesis WHERE chain_id=?",chain)
    if !found || len(genesis)!=1 do return fail("storage_error")
    entries,listed:=query(s.db,"SELECT '',title,description FROM task_chains WHERE chain_id=?1 UNION ALL SELECT task_id,title,'' FROM tasks WHERE chain_id=?1",chain)
    if !listed do return fail("storage_error")
    for entry in entries {
        registry:=doc(map[string]string{"protocol_version"="1","account_id"=s.account,"chain_id"=chain,"owner_bridge_id"=s.owner,"key_id"=s.owner_key,"genesis_digest"=genesis[0][0],"metadata_revision"=stamp,"task_id"=entry[0],
          "chain_title_cipher"="","chain_description_cipher"="","task_title_cipher"="","deleted"="0","signature"=strings.repeat("0",128)})
        texts:=[2]string{entry[1],entry[2]}
        sealed:[2]string
        for text,j in texts {
            if entry[0]!="" && j>0 do continue
            out,sealed_ok:=vault.seal_string(text,kr,context.temp_allocator)
            if !sealed_ok do return fail("vault_locked")
            sealed[j]=out
        }
        if entry[0]=="" { registry["chain_title_cipher"]=json.String(sealed[0]);registry["chain_description_cipher"]=json.String(sealed[1]) } else { registry["task_title_cipher"]=json.String(sealed[0]) }
        signature,signed:=sign.sign(sign.ctx,"registry",registry)
        if !signed do return fail("storage_error")
        registry["signature"]=json.String(signature)
        if !intent_enqueue(&tx,Intent_Input{chain=chain,principal=principal,operation=op,seq=seq,kind="registry",destination=entry[0],fence="{}",payload=encode(registry)}) do return fail("storage_error")
    }
    if _,ok=query(s.db,"UPDATE runtime_database SET commit_seq=?,clock_high_ms=max(clock_high_ms,?) WHERE singleton=1",stamp,fmt.tprintf("%d",max(now,0)));!ok do return fail("storage_error")
    if !transaction_commit(&tx) do return fail("storage_error")
    return Result{code="ok",body=result,seq=seq}
}
