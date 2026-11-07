package sqlite

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// R3 one-shot import, Hub source side. Selection and freeze happen in ONE Hub
// transaction after the blocker check, so no lease, effect, workflow stage or
// merge can start between the check and the freeze. The Hub computes the
// quiescence digest over exactly the facts it checked.

SQLITE_INTEGER :: 1
SQLITE_NULL :: 5

legacy_count :: proc(conn:^Conn,sql:string,args:..string) -> (i64,bool) {
    rows,ok:=legacy_metadata(conn,sql,1,..args)
    if !ok || len(rows)!=1 do return 0,false
    n,parsed:=strconv.parse_i64(rows[0][0])
    return n,parsed
}

// Each code names a live execution the import would otherwise drop. A task
// awaiting review or merge has an unresolved execution and cannot import idle.
LEGACY_MIGRATION_BLOCKER_SQL := [?][2]string{
    {"live_leases","SELECT count(*) FROM task_leases WHERE chain_id=?1"},
    {"outstanding_effects","SELECT count(*) FROM owner_legacy_source_effects WHERE chain_id=?1 AND state='outstanding'"},
    {"running_workflows","SELECT count(*) FROM workflow_run_executions WHERE chain_id=?1 AND state IN ('pending','running')"},
    {"tasks_in_progress","SELECT count(*) FROM tasks WHERE chain_id=?1 AND state='in_progress'"},
    {"tasks_in_review","SELECT count(*) FROM tasks WHERE chain_id=?1 AND state='in_review'"},
    {"pending_merges",`SELECT count(*) FROM tasks t WHERE t.chain_id=?1 AND t.state='done'
      AND EXISTS(SELECT 1 FROM task_chain_directories d WHERE d.chain_id=?1 AND d.vcs_kind='git')
      AND (SELECT e.kind FROM task_events e WHERE e.task_id=t.task_id AND e.kind IN ('merged','merge_conflict','approved','submitted')
           ORDER BY e.event_id DESC LIMIT 1) IN ('approved','submitted')`},
    {"merge_conflicts",`SELECT count(*) FROM tasks t WHERE t.chain_id=?1
      AND (SELECT e.kind FROM task_events e WHERE e.task_id=t.task_id AND e.kind IN ('merged','merge_conflict','approved','submitted')
           ORDER BY e.event_id DESC LIMIT 1)='merge_conflict'`},
}

legacy_migration_blockers :: proc(ctx:rawptr,chain:string) -> ([]domain.Legacy_Migration_Blocker,domain.Domain_Error) {
    impl:=(^Taskchain_Repo_SQLite)(ctx)
    out:=make([dynamic]domain.Legacy_Migration_Blocker,context.temp_allocator)
    for b in LEGACY_MIGRATION_BLOCKER_SQL {
        n,ok:=legacy_count(impl.conn,b[1],chain)
        if !ok do return nil,legacy_storage_error()
        if n>0 do append(&out,domain.Legacy_Migration_Blocker{b[0],n})
    }
    return out[:],{}
}

legacy_quiescence_digest :: proc(s:domain.Legacy_Migration_Selection,generation,work_revision:i64) -> string {
    facts:=fmt.tprintf("heimdall-legacy-quiescence/v1\n%s\n%s\n%s\n%s\ngeneration=%d\nwork_revision=%d\n",s.account_id,s.chain_id,s.migration_id,s.selection_digest,generation,work_revision)
    for b in LEGACY_MIGRATION_BLOCKER_SQL do facts=fmt.tprintf("%s%s=0\n",facts,b[0])
    return contracts.owner_payload_digest(facts)
}

// Select and freeze atomically. An exact replay of a frozen or imported
// selection returns its fence unchanged. Blockers refuse without writing.
legacy_migration_freeze_now :: proc(ctx:rawptr,s:domain.Legacy_Migration_Selection) -> (domain.Legacy_Source_Fence,[]domain.Legacy_Migration_Blocker,domain.Domain_Error) {
    impl:=(^Taskchain_Repo_SQLite)(ctx)
    factory:SQLite_Unit_Of_Work_Factory
    uf:=new_unit_of_work_factory(&factory,impl.conn,nil)
    tx,opened,err:=iface.unit_of_work_begin(&uf)
    if !opened do return {},nil,err
    committed:=false
    defer { if !committed do iface.unit_of_work_rollback(&tx) }
    f,found,ferr:=legacy_source_get(ctx,s.account_id,s.chain_id)
    if ferr.code!=.None do return {},nil,ferr
    if found {
        if f.selection.migration_id!=s.migration_id || f.selection.owner_bridge_id!=s.owner_bridge_id || f.selection.owner_key_id!=s.owner_key_id || f.selection.selection_digest!=s.selection_digest do return {},nil,legacy_conflict()
        if f.state!="draining" { committed,err=iface.unit_of_work_commit(&tx);return f,nil,err }
    }
    blockers,berr:=legacy_migration_blockers(ctx,s.chain_id)
    if berr.code!=.None do return {},nil,berr
    if len(blockers)>0 do return {},blockers,{}
    if !found {
        if serr:=legacy_migration_select(ctx,s);serr.code!=.None do return {},nil,serr
    }
    f,found,ferr=legacy_source_get(ctx,s.account_id,s.chain_id)
    if ferr.code!=.None || !found do return {},nil,legacy_storage_error()
    revision,ok:=legacy_count(impl.conn,"SELECT work_revision FROM task_chains WHERE chain_id=?1",s.chain_id)
    if !ok do return {},nil,legacy_storage_error()
    q:=legacy_quiescence_digest(s,f.generation,revision)
    if ferr=legacy_source_freeze(ctx,s.account_id,s.chain_id,s.migration_id,s.selection_digest,q,f.revision,f.generation);ferr.code!=.None do return {},nil,ferr
    f,_,ferr=legacy_source_get(ctx,s.account_id,s.chain_id)
    if ferr.code!=.None do return {},nil,ferr
    committed,err=iface.unit_of_work_commit(&tx)
    return f,nil,err
}

legacy_json_string :: proc(b:^strings.Builder,s:string) {
    raw,_:=json.marshal(s,allocator=context.temp_allocator)
    strings.write_string(b,string(raw))
}

// Every column of every row, in table column order, typed as stored.
legacy_export_rows :: proc(conn:^Conn,k:contracts.Owner_Export_Kind,chain:string) -> ([]string,domain.Domain_Error) {
    sql:=fmt.tprintf("SELECT * FROM %s WHERE %s ORDER BY %s",k.table,k.scope,k.order)
    stmt:sqlite3_stmt
    if sqlite3_prepare_v2(conn.db,strings.clone_to_cstring(sql,context.temp_allocator),-1,&stmt,nil)!=SQLITE_OK do return nil,legacy_storage_error()
    defer sqlite3_finalize(stmt)
    bind_text(stmt,1,chain)
    columns:=int(sqlite3_column_count(stmt))
    out:=make([dynamic]string,context.temp_allocator)
    for {
        rc:=sqlite3_step(stmt)
        if rc==SQLITE_DONE do return out[:],{}
        if rc!=SQLITE_ROW do return nil,legacy_storage_error()
        b:=strings.builder_make(context.temp_allocator)
        strings.write_byte(&b,'{')
        for i in 0..<columns {
            if i>0 do strings.write_byte(&b,',')
            legacy_json_string(&b,string(sqlite3_column_name(stmt,c.int(i))))
            strings.write_byte(&b,':')
            switch sqlite3_column_type(stmt,c.int(i)) {
            case SQLITE_INTEGER: strings.write_string(&b,fmt.tprintf("%d",sqlite3_column_int64(stmt,c.int(i))))
            case SQLITE_NULL: strings.write_string(&b,"null")
            case: legacy_json_string(&b,column_text_unowned(stmt,i))
            }
        }
        strings.write_byte(&b,'}')
        if strings.builder_len(b)>contracts.OWNER_MIGRATION_ROW_MAX do return nil,domain.domain_error(.Conflict,fmt.tprintf("legacy %s row exceeds the import row bound",k.kind),`{"code":"row_too_large"}`)
        append(&out,strings.to_string(b))
    }
}

// One read transaction over the frozen (or already imported) chain. Frozen
// rows cannot change, so repeated exports are byte-identical.
legacy_migration_export :: proc(ctx:rawptr,account,chain,migration:string) -> (domain.Legacy_Migration_Export,domain.Domain_Error) {
    impl:=(^Taskchain_Repo_SQLite)(ctx)
    factory:SQLite_Unit_Of_Work_Factory
    uf:=new_unit_of_work_factory(&factory,impl.conn,nil)
    tx,opened,err:=iface.unit_of_work_begin(&uf)
    if !opened do return {},err
    defer iface.unit_of_work_rollback(&tx)
    f,found,ferr:=legacy_source_get(ctx,account,chain)
    if ferr.code!=.None do return {},ferr
    if !found || f.selection.migration_id!=migration || (f.state!="frozen" && f.state!="imported") do return {},domain.domain_error(.Conflict,"legacy chain is not frozen for this migration",`{"code":"not_frozen"}`)
    revision,ok:=legacy_count(impl.conn,"SELECT work_revision FROM task_chains WHERE chain_id=?1 AND owner_user_id=?2",chain,account)
    if !ok do return {},legacy_storage_error()
    m:=contracts.Owner_Migration_Manifest{format=contracts.OWNER_MIGRATION_EXPORT_FORMAT,account_id=account,chain_id=chain,migration_id=migration,
        selection_digest=f.selection.selection_digest,source_generation=f.generation,work_revision=revision}
    kinds:=make([dynamic]contracts.Owner_Migration_Kind_Count,context.temp_allocator)
    refs:=make([dynamic]contracts.Owner_Migration_Document_Ref,context.temp_allocator)
    documents:=make([dynamic]string,context.temp_allocator)
    for k in contracts.OWNER_MIGRATION_EXPORT_KINDS {
        rows,rerr:=legacy_export_rows(impl.conn,k,chain)
        if rerr.code!=.None do return {},rerr
        append(&kinds,contracts.Owner_Migration_Kind_Count{k.kind,k.table,i64(len(rows))})
        for start:=0;start<len(rows); {
            size,end:=0,start
            for end<len(rows) && (end==start || size+len(rows[end])+1<=contracts.OWNER_MIGRATION_PART_TARGET) { size+=len(rows[end])+1;end+=1 }
            b:=strings.builder_make(context.temp_allocator)
            strings.write_string(&b,fmt.tprintf(`{{"format":"%s","kind":"%s","index":%d,"rows":[`,contracts.OWNER_MIGRATION_EXPORT_FORMAT,k.kind,len(documents)))
            for row,i in rows[start:end] { if i>0 do strings.write_byte(&b,',');strings.write_string(&b,row) }
            strings.write_string(&b,"]}")
            raw:=strings.to_string(b)
            append(&refs,contracts.Owner_Migration_Document_Ref{i64(len(documents)),k.kind,i64(end-start),i64(len(raw)),contracts.owner_payload_digest(raw)})
            append(&documents,raw)
            if len(documents)>contracts.OWNER_MIGRATION_MAX_DOCUMENTS do return {},domain.domain_error(.Conflict,"legacy chain exceeds the import document bound",`{"code":"export_too_large"}`)
            start=end
        }
    }
    m.kinds=kinds[:];m.documents=refs[:];m.archival_only=contracts.OWNER_MIGRATION_ARCHIVAL_ONLY[:]
    raw,merr:=json.marshal(m,allocator=context.temp_allocator)
    if merr!=nil || len(raw)>contracts.OWNER_MIGRATION_MANIFEST_MAX do return {},legacy_storage_error()
    return domain.Legacy_Migration_Export{string(raw),contracts.owner_payload_digest(string(raw)),documents[:]},{}
}

// Cutover in one transaction: register the owner-local route, then mark the
// migration imported. The legacy guards already reject every canonical write;
// 'imported' is terminal, so the old writer can never be re-enabled.
legacy_migration_cutover :: proc(ctx:rawptr,account,chain,migration,manifest_digest,receipt_digest:string,route:domain.Owner_Registry_Record) -> (replayed:bool,err:domain.Domain_Error) {
    if !contracts.owner_hex(manifest_digest,64) || !contracts.owner_hex(receipt_digest,64) do return false,domain.domain_error(.Validation_Failed,"invalid import evidence")
    impl:=(^Taskchain_Repo_SQLite)(ctx)
    factory:SQLite_Unit_Of_Work_Factory
    uf:=new_unit_of_work_factory(&factory,impl.conn,nil)
    tx,opened,berr:=iface.unit_of_work_begin(&uf)
    if !opened do return false,berr
    committed:=false
    defer { if !committed do iface.unit_of_work_rollback(&tx) }
    f,found,ferr:=legacy_source_get(ctx,account,chain)
    if ferr.code!=.None do return false,ferr
    if !found || f.selection.migration_id!=migration do return false,legacy_conflict()
    if f.state=="imported" {
        if f.manifest_digest!=manifest_digest || f.receipt_digest!=receipt_digest do return false,legacy_conflict()
        committed,err=iface.unit_of_work_commit(&tx)
        return true,err
    }
    if f.state!="frozen" || route.account_id!=account || route.chain_id!=chain || route.owner_bridge_id!=f.selection.owner_bridge_id || route.owner_key_id!=f.selection.owner_key_id do return false,legacy_conflict()
    _,ok:=legacy_metadata(impl.conn,"INSERT OR IGNORE INTO owner_local_chains VALUES(?,?,?,?,?,?,?)",0,route.chain_id,route.account_id,route.owner_bridge_id,route.owner_key_id,route.creator_id,route.genesis_digest,route.genesis_json)
    if !ok do return false,legacy_storage_error()
    rows,read:=legacy_metadata(impl.conn,"SELECT account_id,owner_bridge_id,owner_key_id,creator_id,genesis_digest,genesis_json FROM owner_local_chains WHERE chain_id=?",6,chain)
    if !read do return false,legacy_storage_error()
    if len(rows)!=1 || rows[0][0]!=account || rows[0][1]!=route.owner_bridge_id || rows[0][2]!=route.owner_key_id || rows[0][3]!=route.creator_id || rows[0][4]!=route.genesis_digest || rows[0][5]!=route.genesis_json do return false,legacy_conflict()
    rows,ok=legacy_metadata(impl.conn,`UPDATE owner_legacy_migrations SET state='imported',revision=revision+1,manifest_digest=?,receipt_digest=?
      WHERE migration_id=? AND chain_id=? AND account_id=? AND state='frozen' AND revision=? RETURNING migration_id`,1,manifest_digest,receipt_digest,migration,chain,account,fmt.tprintf("%d",f.revision))
    if !ok || len(rows)!=1 do return false,legacy_conflict()
    committed,err=iface.unit_of_work_commit(&tx)
    return false,err
}

// Bridge-side activation re-derives its state from this lookup by migration.
legacy_migration_get :: proc(ctx:rawptr,account,migration:string) -> (domain.Legacy_Source_Fence,bool,domain.Domain_Error) {
    impl:=(^Taskchain_Repo_SQLite)(ctx)
    rows,ok:=legacy_metadata(impl.conn,"SELECT chain_id FROM owner_legacy_migrations WHERE account_id=? AND migration_id=?",1,account,migration)
    if !ok do return {},false,legacy_storage_error()
    if len(rows)!=1 do return {},false,{}
    return legacy_source_get(ctx,account,rows[0][0])
}
