package executor_local

import "core:fmt"
import "core:sync"
import contracts "odin_test:contracts"

// Private native evidence, never a grant, adopted mapping or completeness
// claim. The Bridge derives these fields from original packet spans and the
// actual transformed command. No raw command or token is exposed here.
Legacy_Draft_Observation :: struct {
    parent_command_id,parent_digest,entry_digest,chain,instance,task,lease,native_request_digest,draft_id:string,
    entry_index:i64,
}

// This clocks durable database changes only. It cannot cover dispatcher memory,
// a daemon child, filesystem mutation or missing pre-upgrade admissions. Those
// require separate physical observations under the Bridge's established gates.
Legacy_Journal_Snapshot :: struct {incarnation,sequence,coverage_version:i64,prior_coverage_unknown:bool}
legacy_journal_snapshot :: proc(s:^Store)->(Legacy_Journal_Snapshot,bool) {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if s.db==nil || s.unusable do return {},false
    rows,read:=query(s.db,`SELECT r.incarnation,j.sequence,j.coverage_version,j.prior_coverage_unknown
      FROM executor_runtime r CROSS JOIN executor_native_journal j WHERE r.singleton=1 AND j.singleton=1`)
    if !read || len(rows)!=1 || number(rows[0][0])!=s.incarnation do return {},false
    r:=rows[0]
    return {number(r[0]),number(r[1]),number(r[2]),r[3]=="1"},true
}

// A later packet may refer to an existing draft. Preserve that association
// independently of the immutable first draft material. Exact retries are
// read-only; reusing a packet/entry/native/draft identity with altered evidence
// conflicts, including after restart. This is not invocation deduplication.
legacy_observe_draft :: proc(s:^Store,o:Legacy_Draft_Observation)->Result {
    if !contracts.owner_field_valid(o.parent_command_id,"id") || !contracts.owner_hex(o.parent_digest,64) ||
       !contracts.owner_hex(o.entry_digest,64) || !contracts.owner_field_valid(o.chain,"id") ||
       !contracts.owner_field_valid(o.instance,"id") || !contracts.owner_field_valid(o.task,"optional") ||
       !contracts.owner_field_valid(o.lease,"optional") || !contracts.owner_hex(o.native_request_digest,64) ||
       !contracts.owner_hex(o.draft_id,64) || o.entry_index<0 {return fail("invalid_scope")}
    identity:=contracts.owner_payload_digest(encode(struct{parent:string,index:i64,native,draft:string}{o.parent_command_id,o.entry_index,o.native_request_digest,o.draft_id}))
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if !begin(s) do return fail("storage_error")
    defer rollback(s)
    rows,read:=query(s.db,`SELECT parent_command_id,parent_digest,entry_index,entry_digest,chain_id,instance_id,task_id,lease_id,native_request_digest,draft_id
      FROM executor_legacy_observations WHERE observation_id=?`,identity)
    if !read do return fail("storage_error")
    wanted:=[10]string{o.parent_command_id,o.parent_digest,fmt.tprintf("%d",o.entry_index),o.entry_digest,o.chain,o.instance,o.task,o.lease,o.native_request_digest,o.draft_id}
    if len(rows)>0 {
        for value,i in wanted do if rows[0][i]!=value do return fail("observation_conflict")
        return Result{code="ok",body=identity,replay=true}
    }
    draft,found:=local_draft_tx(s,o.draft_id)
    if !found do return fail("draft_not_found")
    config,valid:=contracts.executor_parse(draft.configuration,"local_configuration")
    if !valid || field(config,"instance_id")!=o.instance do return fail("invalid_scope")
    counts,counted:=query(s.db,"SELECT count(*) FROM executor_legacy_observations")
    if !counted || len(counts)!=1 do return fail("storage_error")
    if number(counts[0][0])>=MAX_RECORDS do return fail("retention_capacity")
    _,written:=query(s.db,"INSERT INTO executor_legacy_observations VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
        identity,wanted[0],wanted[1],wanted[2],wanted[3],wanted[4],wanted[5],wanted[6],wanted[7],wanted[8],wanted[9],fmt.tprintf("%d",s.incarnation))
    if !written || !commit(s) do return fail("storage_error")
    return Result{code="ok",body=identity}
}
