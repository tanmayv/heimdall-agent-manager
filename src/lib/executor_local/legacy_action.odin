package executor_local

import "core:fmt"
import "core:sync"
import contracts "odin_test:contracts"

// An occurrence, not a command receipt. Repeated identical packets each receive
// an independent observation. Empty original IDs/chain claims stay empty.
// Neither receipt state nor handler return proves execution/physical absence.
Legacy_Action :: struct {id,incarnation:i64,scope:[64]u8}
legacy_action_scope :: proc(s:^Store)->[64]u8 {
    digest:=contracts.owner_payload_digest(encode(struct{account,executor,operator_key:string}{s.account,s.executor,s.operator_key}))
    result:[64]u8
    copy(result[:],transmute([]u8)digest)
    return result
}
Legacy_Action_Input :: struct {command_id,kind,chain_claim,packet_digest:string}

legacy_action_receive :: proc(s:^Store,input:Legacy_Action_Input)->(Legacy_Action,Result) {
    if !contracts.owner_field_valid(input.command_id,"optional") ||
       !contracts.owner_field_valid(input.kind,"id") ||
       !contracts.owner_field_valid(input.chain_claim,"optional") ||
       !contracts.owner_hex(input.packet_digest,64) {return {},fail("invalid_scope")}
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if !begin(s) do return {},fail("storage_error")
    defer rollback(s)
    rows,read:=query(s.db,"SELECT sequence,(SELECT count(*) FROM executor_legacy_actions) FROM executor_native_journal WHERE singleton=1")
    if !read || len(rows)!=1 || number(rows[0][0])==0x7fffffffffffffff do return {},fail("storage_error")
    if number(rows[0][1])>=MAX_RECORDS do return {},fail("retention_capacity")
    id:=number(rows[0][0])+1
    _,written:=query(s.db,"INSERT INTO executor_legacy_actions VALUES(?,?,?,?,?,?,'received','')",
        fmt.tprintf("%d",id),fmt.tprintf("%d",s.incarnation),input.command_id,input.kind,input.chain_claim,input.packet_digest)
    if !written || !commit(s) do return {},fail("storage_error")
    return Legacy_Action{id,s.incarnation,legacy_action_scope(s)},Result{code="ok"}
}

// Exact same-state replay is read-only, including after restart. A missing
// transition after crash stays unresolved; never relabel it returned/discarded
// from an old incarnation or infer that its daemon child disappeared.
legacy_action_transition :: proc(s:^Store,action:Legacy_Action,from,to:string,reject_barriers:bool=false)->Result {
    if action.id<=0 || action.incarnation<=0 ||
       reject_barriers && (from!="prepared" || to!="running") ||
       !(from=="received" && (to=="prepared" || to=="discarded") ||
         from=="prepared" && (to=="running" || to=="discarded") ||
         from=="running" && to=="returned") {return fail("invalid_scope")}
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if !begin(s) do return fail("storage_error")
    defer rollback(s)
    if action.scope!=legacy_action_scope(s) do return fail("invalid_scope")
    rows,read:=query(s.db,"SELECT observed_incarnation,state,previous_state FROM executor_legacy_actions WHERE action_id=?",fmt.tprintf("%d",action.id))
    if !read do return fail("storage_error")
    if len(rows)!=1 || number(rows[0][0])!=action.incarnation do return fail("action_not_found")
    if rows[0][1]==to {
        if rows[0][2]!=from do return fail("action_conflict")
        return Result{code="ok",replay=true}
    }
    if action.incarnation!=s.incarnation do return fail("stale_incarnation")
    if rows[0][1]!=from do return fail("action_conflict")
    // Trusted native dispatch uses this for resource users whose overlap with
    // a protected target has not been independently excluded. This is an
    // admission fence, not a claim that prior invocations/children drained.
    // Historical replay above cannot issue another handler invocation.
    if reject_barriers {
        barriers,read:=query(s.db,"SELECT 1 FROM executor_legacy_barriers LIMIT 1")
        if !read do return fail("storage_error")
        if len(barriers)>0 do return fail("legacy_fenced")
    }
    _,written:=query(s.db,"UPDATE executor_legacy_actions SET state=?,previous_state=? WHERE action_id=?",to,from,fmt.tprintf("%d",action.id))
    if !written || !commit(s) do return fail("storage_error")
    return Result{code="ok"}
}
