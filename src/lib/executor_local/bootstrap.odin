#+feature dynamic-literals
package executor_local

import "core:sync"
import contracts "odin_test:contracts"

// Credential-bearing output stays inside the execution Bridge. Never serialize
// this object to the Hub, an owner, a receipt, or a task response.
Launch_Material :: struct {bootstrap,body,configuration,token_secret:string}

// Accept content only after activation committed, and a fresh bilateral owner
// check. A replay returns historical evidence; it cannot dispatch a launch.
// The caller resolves current enrolled keys and serializes invalidation/I/O.
accept_bootstrap :: proc(s:^Store,raw,body,action_raw:string,key:contracts.Owner_Verified_Key,
    now:i64,current:Current_Owner_Fence)->Result {
    context.allocator=context.temp_allocator
    b,valid:=contracts.executor_parse(raw,"bootstrap")
    a,activated:=contracts.executor_parse(action_raw,"action")
    if !valid || !activated do return fail("malformed")
    if !scope(s,b) || !contracts.executor_verify("bootstrap",b,key) ||
       !owner_bound(s,a,"action",key) {return fail("invalid_scope")}
    digest,_:=contracts.executor_digest("bootstrap",b)
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if !begin(s) do return fail("storage_error")
    defer rollback(s)
    old,read:=query(s.db,"SELECT input_digest,body FROM executor_bootstraps WHERE reservation_id=?",field(b,"reservation_id"))
    if !read do return fail("storage_error")
    if len(old)>0 {
        if old[0][0]!=digest || old[0][1]!=body do return fail("operation_conflict")
        return Result{"ok",digest,true}
    }
    rows,ok:=query(s.db,`SELECT r.document,r.launch_key,r.state,r.executor_incarnation,r.deadline_version,r.expires_ms,
       i.configuration,i.token_secret
       FROM executor_reservations r JOIN executor_issuances i ON i.instance_id=r.instance_id
       WHERE r.reservation_id=?`,field(b,"reservation_id"))
    if !ok do return fail("storage_error")
    if len(rows)!=1 do return fail("invalid_scope")
    row:=rows[0]
    p,prepared:=contracts.executor_parse(row[0],"prepare")
    if !prepared || !contracts.executor_bootstrap_matches(b,p,a,row[6],body,row[1],key,now) ||
       contracts.owner_payload_digest(row[7])!=field(p,"token_generation") {return fail("invalid_scope")}
    if row[2]!="active" || number(row[3])!=s.incarnation || row[4]!=field(b,"deadline_version") ||
       row[5]!=field(b,"expires_ms") {return fail("stale_intent")}
    if code:=clock(s,now);code!="" do return fail(code)
    if !current.current || current.prepare_digest!=field(b,"prepare_digest") ||
       current.owner_incarnation!=num(b,"owner_incarnation") || current.commit_seq!=num(a,"owner_commit_seq") {return fail("owner_fence_not_current")}
    ad,_:=contracts.executor_digest("action",a)
    receipt,recorded:=query(s.db,"SELECT 1 FROM executor_receipts WHERE owner_bridge_id=? AND operation_id=? AND kind='action' AND input_digest=? AND reservation_id=?",
        field(b,"owner_bridge_id"),field(a,"operation_id"),ad,field(b,"reservation_id"))
    if !recorded do return fail("storage_error")
    if len(receipt)!=1 do return fail("activation_not_committed")
    if _,written:=query(s.db,"INSERT INTO executor_bootstraps VALUES(?,?,?,?,?)",field(b,"reservation_id"),digest,raw,body,action_raw);!written do return fail("storage_error")
    if !commit(s) do return fail("storage_error")
    return Result{code="ok",body=digest}
}

// Content is retained across restarts, but credentials can only be obtained for
// the exact live launch claim of this serving incarnation. No new identity or
// deadline is inferred from retained content. Dispatch still needs a fresh fence.
launch_material :: proc(s:^Store,intent:Intent,now:i64)->(Launch_Material,bool) {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if intent.kind!="launch" do return {},false
    if _,current:=intent_current_locked(s,intent,now);!current do return {},false
    rows,ok:=query(s.db,`SELECT b.document,b.body,i.configuration,i.token_secret
      FROM executor_bootstraps b JOIN executor_reservations r USING(reservation_id)
      JOIN executor_issuances i ON i.instance_id=r.instance_id WHERE b.reservation_id=? AND EXISTS(SELECT 1 FROM executor_intents x
      WHERE x.reservation_id=b.reservation_id AND x.kind='launch' AND x.state='uncertain' AND x.claim_incarnation=0)`,intent.reservation)
    if !ok || len(rows)!=1 do return {},false
    row:=rows[0]
    return Launch_Material{row[0],row[1],row[2],row[3]},true
}
