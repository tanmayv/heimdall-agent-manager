package executor_local

import "core:fmt"
import "core:sync"
import contracts "odin_test:contracts"

// Derive selected native identity from immutable retained draft data. Incoming
// transformed requests remain separate from the selected material, including
// retries of an existing draft. This association is not a launch receipt.
Legacy_Action_Draft :: struct {
    action:Legacy_Action,
    entry_index:i64,
    entry_digest,native_request_digest,draft_id:string,
}

legacy_action_observe_draft :: proc(s:^Store,o:Legacy_Action_Draft)->Result {
    if o.action.id<=0 || o.action.incarnation<=0 || o.entry_index< -1 ||
       !contracts.owner_hex(o.entry_digest,64) || !contracts.owner_hex(o.native_request_digest,64) ||
       !contracts.owner_hex(o.draft_id,64) {return fail("invalid_scope")}
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if !begin(s) do return fail("storage_error")
    defer rollback(s)
    if o.action.scope!=legacy_action_scope(s) do return fail("invalid_scope")
    id:=contracts.owner_payload_digest(encode(struct{action,index:i64,native,draft:string}{o.action.id,o.entry_index,o.native_request_digest,o.draft_id}))
    existing,read:=query(s.db,"SELECT entry_digest,observed_incarnation FROM executor_legacy_action_drafts WHERE association_id=?",id)
    if !read do return fail("storage_error")
    if len(existing)>0 {
        if existing[0][0]!=o.entry_digest || number(existing[0][1])!=o.action.incarnation do return fail("observation_conflict")
        return Result{code="ok",body=id,replay=true}
    }
    action,read_action:=query(s.db,"SELECT observed_incarnation,state,packet_digest FROM executor_legacy_actions WHERE action_id=?",fmt.tprintf("%d",o.action.id))
    if !read_action do return fail("storage_error")
    if len(action)!=1 || number(action[0][0])!=o.action.incarnation || o.action.incarnation!=s.incarnation ||
       action[0][1]!="running" || o.entry_index== -1 && action[0][2]!=o.entry_digest {return fail("invalid_scope")}
    draft,found:=local_draft_tx(s,o.draft_id)
    if !found do return fail("draft_not_found")
    config,valid:=contracts.executor_parse(draft.configuration,"local_configuration")
    if !valid do return fail("invalid_scope")
    rows,counted:=query(s.db,"SELECT count(*) FROM executor_legacy_action_drafts")
    if !counted || len(rows)!=1 do return fail("storage_error")
    if number(rows[0][0])>=MAX_RECORDS do return fail("retention_capacity")
    _,written:=query(s.db,"INSERT INTO executor_legacy_action_drafts VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
        id,fmt.tprintf("%d",o.action.id),fmt.tprintf("%d",o.entry_index),o.entry_digest,o.native_request_digest,o.draft_id,
        contracts.owner_payload_digest(draft.configuration),contracts.owner_payload_digest(draft.material),
        field(config,"instance_id"),field(config,"directory_id"),field(config,"directory_key"),fmt.tprintf("%d",s.incarnation))
    if !written || !commit(s) do return fail("storage_error")
    return Result{code="ok",body=id}
}
