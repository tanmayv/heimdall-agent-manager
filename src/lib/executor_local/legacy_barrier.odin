package executor_local

import "core:fmt"
import "core:sync"
import contracts "odin_test:contracts"

// These are trusted storage inputs, not public migration commands. The caller
// must authenticate current selected-device consent and bind the source CAS
// generation before installing a barrier. Nothing here proves physical drain.
// All legacy dispatchers must admit BEFORE I/O, including jobs already queued.
// Do not use 'returned' as evidence that a PTY child or merge process is absent.
Legacy_Barrier :: struct {
    chain,migration,selection_digest:string,
    source_generation:i64,
}
// Resource identities must come from the consistent source inventory and be
// derived from the actual dispatch target, never just a claimed chain field.
// Shared resources may be retained by multiple source chains.
Legacy_Resource :: struct {kind,id:string}
legacy_resource_valid :: proc(r:Legacy_Resource)->bool {
    if r.kind=="workdir_hash" do return contracts.owner_hex(r.id,64)
    return (r.kind=="instance" || r.kind=="task") && contracts.owner_field_valid(r.id,"id")
}
legacy_resources_valid :: proc(resources:[]Legacy_Resource)->bool {
    if len(resources)>MAX_RECORDS do return false
    seen:=make(map[string]bool,context.temp_allocator)
    for r in resources {
        if !legacy_resource_valid(r) do return false
        key:=fmt.tprintf("%s:%s",r.kind,r.id)
        if seen[key] do return false
        seen[key]=true
    }
    return true
}
Legacy_Command :: struct {
    chain,id,input_digest:string,
    incarnation:i64,
}
Legacy_Barrier_Status :: struct {
    barrier:Legacy_Barrier,
    installed_incarnation,running,returned:i64,
}

// There is intentionally no remove/resume API. Source resume requires correlated
// destination retirement and a new authenticated generation, not row deletion.
legacy_barrier_install :: proc(s:^Store,b:Legacy_Barrier,resources:[]Legacy_Resource=nil)->Result {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if !contracts.owner_field_valid(b.chain,"id") || !contracts.owner_field_valid(b.migration,"id") || !contracts.owner_hex(b.selection_digest,64) || b.source_generation<=0 || !legacy_resources_valid(resources) do return fail("invalid_scope")
    if !begin(s) do return fail("storage_error")
    defer rollback(s)
    rows,read:=query(s.db,"SELECT migration_id,selection_digest,source_generation FROM executor_legacy_barriers WHERE chain_id=?",b.chain)
    if !read do return fail("storage_error")
    if len(rows)>0 {
        if rows[0][0]!=b.migration || rows[0][1]!=b.selection_digest || number(rows[0][2])!=b.source_generation do return fail("barrier_conflict")
        stored,read_resources:=query(s.db,"SELECT kind,resource_id FROM executor_legacy_resources WHERE chain_id=?",b.chain)
        if !read_resources do return fail("storage_error")
        if len(stored)!=len(resources) do return fail("barrier_conflict")
        wanted:=make(map[string]bool,context.temp_allocator)
        for r in resources do wanted[fmt.tprintf("%s:%s",r.kind,r.id)]=true
        for r in stored do if !wanted[fmt.tprintf("%s:%s",r[0],r[1])] do return fail("barrier_conflict")
        return Result{code="ok",replay=true}
    }
    count,counted:=query(s.db,"SELECT count(*) FROM executor_legacy_barriers")
    if !counted || len(count)!=1 do return fail("storage_error")
    if number(count[0][0])>=MAX_RECORDS do return fail("quota_exceeded")
    resource_count,resources_counted:=query(s.db,"SELECT count(*) FROM executor_legacy_resources")
    if !resources_counted || len(resource_count)!=1 do return fail("storage_error")
    if number(resource_count[0][0])+i64(len(resources))>MAX_RECORDS do return fail("quota_exceeded")
    _,written:=query(s.db,"INSERT INTO executor_legacy_barriers VALUES(?,?,?,?,?)",b.chain,b.migration,b.selection_digest,fmt.tprintf("%d",b.source_generation),fmt.tprintf("%d",s.incarnation))
    if !written do return fail("storage_error")
    for r in resources {
        if _,inserted:=query(s.db,"INSERT INTO executor_legacy_resources VALUES(?,?,?)",r.kind,r.id,b.chain);!inserted do return fail("storage_error")
    }
    if !commit(s) do return fail("storage_error")
    return Result{code="ok"}
}

// Only code=admitted grants one physical handler invocation. Every duplicate,
// including a lost reply or a command retained across restart, is query-only.
// The exact command ID is globally unique within this executor ledger.
legacy_command_admit :: proc(s:^Store,chain,id,input_digest:string,resources:[]Legacy_Resource=nil)->(Legacy_Command,Result) {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if !contracts.owner_field_valid(chain,"id") || !contracts.owner_field_valid(id,"id") || !contracts.owner_hex(input_digest,64) || !legacy_resources_valid(resources) do return {},fail("invalid_scope")
    if !begin(s) do return {},fail("storage_error")
    defer rollback(s)
    rows,read:=query(s.db,"SELECT chain_id,input_digest,admitted_incarnation,state FROM executor_legacy_commands WHERE command_id=?",id)
    if !read do return {},fail("storage_error")
    if len(rows)>0 {
        if rows[0][0]!=chain || rows[0][1]!=input_digest do return {},fail("command_conflict")
        return Legacy_Command{chain,id,input_digest,number(rows[0][2])},Result{code=rows[0][3],replay=true}
    }
    barriers,checked:=query(s.db,"SELECT 1 FROM executor_legacy_barriers WHERE chain_id=?",chain)
    if !checked do return {},fail("storage_error")
    if len(barriers)>0 do return {},fail("legacy_fenced")
    for r in resources {
        fenced,checked:=query(s.db,"SELECT 1 FROM executor_legacy_resources WHERE kind=? AND resource_id=? LIMIT 1",r.kind,r.id)
        if !checked do return {},fail("storage_error")
        if len(fenced)>0 do return {},fail("legacy_fenced")
    }
    count,counted:=query(s.db,"SELECT count(*) FROM executor_legacy_commands")
    if !counted || len(count)!=1 do return {},fail("storage_error")
    if number(count[0][0])>=MAX_RECORDS do return {},fail("quota_exceeded")
    _,written:=query(s.db,"INSERT INTO executor_legacy_commands VALUES(?,?,?,?,'running')",id,chain,input_digest,fmt.tprintf("%d",s.incarnation))
    if !written || !commit(s) do return {},fail("storage_error")
    return Legacy_Command{chain,id,input_digest,s.incarnation},Result{code="admitted"}
}

// This records only that the original synchronous invocation returned. A Bridge
// crash leaves 'running' permanently uncertain; reopening never clears it.
// Another invocation cannot finish it, even under the same command ID.
legacy_command_returned :: proc(s:^Store,c:Legacy_Command)->bool {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if c.incarnation!=s.incarnation || !begin(s) do return false
    defer rollback(s)
    rows,read:=query(s.db,"SELECT chain_id,input_digest,admitted_incarnation,state FROM executor_legacy_commands WHERE command_id=?",c.id)
    if !read || len(rows)!=1 || rows[0][0]!=c.chain || rows[0][1]!=c.input_digest || number(rows[0][2])!=c.incarnation do return false
    if rows[0][3]=="returned" do return true
    _,written:=query(s.db,"UPDATE executor_legacy_commands SET state='returned' WHERE command_id=?",c.id)
    return written && commit(s)
}

// A status read can report outstanding handler calls; it deliberately has no
// 'drained' boolean. Pre-upgrade work and actual daemon children still require
// a separate exhaustive, current physical observation under the barrier.
legacy_barrier_status :: proc(s:^Store,chain:string)->(Legacy_Barrier_Status,bool) {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if s.db==nil || s.unusable do return {},false
    rows,read:=query(s.db,`SELECT migration_id,selection_digest,source_generation,installed_incarnation,
      (SELECT count(*) FROM executor_legacy_commands WHERE chain_id=b.chain_id AND state='running'),
      (SELECT count(*) FROM executor_legacy_commands WHERE chain_id=b.chain_id AND state='returned')
      FROM executor_legacy_barriers b WHERE chain_id=?`,chain)
    if !read || len(rows)!=1 do return {},false
    r:=rows[0]
    return {Legacy_Barrier{chain,r[0],r[1],number(r[2])},number(r[3]),number(r[4]),number(r[5])},true
}
