#+feature dynamic-literals
package executor_local

import "core:fmt"
import "core:sync"
import contracts "odin_test:contracts"

// Current_Owner_Fence is obtained from authoritative owner validation before
// activation. A receipt replay is historical evidence, never launch admission.
action :: proc(s:^Store,raw:string,key:contracts.Owner_Verified_Key,now:i64,current:Current_Owner_Fence={})->Result {
    context.allocator=context.temp_allocator
    o,valid:=contracts.executor_parse(raw,"action")
    if !valid do return fail("malformed")
    if !scope(s,o) || !contracts.executor_verify("action",o,key) do return fail("invalid_scope")
    digest,_:=contracts.executor_digest("action",o)
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if !begin(s) do return fail("storage_error")
    defer rollback(s)
    if prior,found:=receipt(s,field(o,"owner_bridge_id"),field(o,"operation_id"),"action",digest);found do return prior
    id,method:=field(o,"reservation_id"),field(o,"method")
    rows,read:=query(s.db,"SELECT owner_bridge_id,chain_id,prepare_digest,grant_generation,deadline_version,prepare_until_ms,expires_ms,hard_ms,state,executor_incarnation,owner_incarnation FROM executor_reservations WHERE reservation_id=?",id)
    if !read do return fail("storage_error")
    if len(rows)!=1 do return fail("invalid_scope")
    row:=rows[0]
    if row[0]!=field(o,"owner_bridge_id") || row[1]!=field(o,"chain_id") || row[2]!=field(o,"prepare_digest") ||
       row[3]!=field(o,"grant_generation") || row[7]!=field(o,"hard_ms") || num(o,"owner_incarnation")<number(row[10]) { return fail("invalid_scope") }
    if method=="query" {
        body,ok:=result_body(s,id)
        if !ok do return fail("storage_error")
        return Result{code="ok",body=body}
    }
    quota,q_ok:=query(s.db,"SELECT count(*) FROM executor_receipts")
    if !q_ok do return fail("storage_error")
    if number(quota[0][0])>=MAX_RECORDS do return fail("retention_capacity")
    if !request_live(o,now) do return fail("expired")
    if code:=clock(s,now,method!="stop");code!="" do return fail(code)
    if num(o,"executor_incarnation")!=s.incarnation do return fail("stale_incarnation")
    if !owner_watermark(s,field(o,"owner_bridge_id"),num(o,"owner_incarnation")) do return fail("stale_owner")
    switch method {
    case "activate":
        if row[8]!="prepared" do return fail("operation_conflict")
        if number(row[9])!=s.incarnation do return fail("stale_incarnation")
        if number(row[5])<=now || num(o,"expires_ms")<=now do return fail("expired")
        if field(o,"deadline_version")!=row[4] do return fail("stale_deadline")
        if !current.current || current.prepare_digest!=row[2] || current.owner_incarnation!=num(o,"owner_incarnation") ||
           current.commit_seq!=num(o,"owner_commit_seq") { return fail("owner_fence_not_current") }
        if _,ok:=query(s.db,"UPDATE executor_reservations SET state='active',launch_state='queued',expires_ms=? WHERE reservation_id=?",field(o,"expires_ms"),id);!ok do return fail("storage_error")
        if _,ok:=query(s.db,"INSERT INTO executor_intents VALUES(?,'launch','pending',0)",id);!ok do return fail("storage_error")
    case "heartbeat":
        if row[8]!="active" || number(row[6])<=now || num(o,"expires_ms")<=now do return fail("expired")
        if number(row[4])==0x7fffffffffffffff || num(o,"deadline_version")!=number(row[4])+1 || num(o,"expires_ms")<number(row[6]) do return fail("stale_deadline")
        if !current.current || current.prepare_digest!=row[2] || current.owner_incarnation!=num(o,"owner_incarnation") ||
           current.commit_seq!=num(o,"owner_commit_seq") { return fail("owner_fence_not_current") }
        if _,ok:=query(s.db,"UPDATE executor_reservations SET expires_ms=?,deadline_version=? WHERE reservation_id=?",field(o,"expires_ms"),field(o,"deadline_version"),id);!ok do return fail("storage_error")
    case "stop":
        if row[8]=="released" do return fail("retired")
        if field(o,"deadline_version")!=row[4] do return fail("stale_deadline")
        if row[8]=="prepared" {
            if _,ok:=query(s.db,"UPDATE executor_reservations SET state='released' WHERE reservation_id=?",id);!ok do return fail("storage_error")
        } else {
            if _,ok:=query(s.db,"UPDATE executor_reservations SET state='stopping' WHERE reservation_id=?",id);!ok do return fail("storage_error")
            if _,ok:=query(s.db,"INSERT OR IGNORE INTO executor_intents VALUES(?,'stop','pending',0)",id);!ok do return fail("storage_error")
        }
    }
    body,ok:=result_body(s,id)
    if !ok || !save_receipt(s,o,"action",digest,body) || !commit(s) do return fail("storage_error")
    return Result{code="ok",body=body}
}

// Mark uncertain BEFORE external I/O. Never claim it twice after an ambiguous
// result: query the same exact child. The daemon must deduplicate launch_key.
take_intent :: proc(s:^Store,now:i64)->(Intent,bool) {
    context.allocator=context.temp_allocator
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if !begin(s) do return {},false
    defer rollback(s)
    if code:=clock(s,now,false);code!="" do return {},false
    rows,ok:=query(s.db,`SELECT i.reservation_id,i.kind,r.instance_id,r.launch_key,r.document
      FROM executor_intents i JOIN executor_reservations r USING(reservation_id)
      WHERE i.state='pending' AND ((i.kind='stop' AND r.state='stopping') OR
        (i.kind='launch' AND r.state='active' AND r.expires_ms>CAST(? AS INTEGER) AND
         (SELECT recovery_state FROM executor_runtime WHERE singleton=1)='ready'))
      ORDER BY CASE i.kind WHEN 'stop' THEN 0 ELSE 1 END,i.reservation_id LIMIT 1`,fmt.tprintf("%d",now))
    if !ok || len(rows)==0 do return {},false
    row:=rows[0]
    if _,written:=query(s.db,"UPDATE executor_intents SET state='uncertain',claim_incarnation=? WHERE reservation_id=? AND kind=?",fmt.tprintf("%d",s.incarnation),row[0],row[1]);!written do return {},false
    if row[1]=="launch" {
        if _,written:=query(s.db,"UPDATE executor_reservations SET launch_state='uncertain' WHERE reservation_id=?",row[0]);!written do return {},false
    }
    if !commit(s) do return {},false
    return Intent{row[0],row[1],row[2],row[3],row[4],s.incarnation},true
}

// Expiry cannot free active/stopping resources. Queue exact safety stops and
// retain the charge until a trusted exact-child absence observation arrives.
expire :: proc(s:^Store,now:i64)->bool {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if !begin(s) do return false
    defer rollback(s)
    if code:=clock(s,now,false);code!="" do return false
    stamp:=fmt.tprintf("%d",now)
    if _,ok:=query(s.db,"UPDATE executor_reservations SET state='released' WHERE state='prepared' AND prepare_until_ms<=CAST(? AS INTEGER)",stamp);!ok do return false
    if _,ok:=query(s.db,"UPDATE executor_reservations SET state='stopping' WHERE state='active' AND expires_ms<=CAST(? AS INTEGER)",stamp);!ok do return false
    if !exec(s.db,"INSERT OR IGNORE INTO executor_intents SELECT reservation_id,'stop','pending',0 FROM executor_reservations WHERE state='stopping'") do return false
    return commit(s)
}
observe_child :: proc(s:^Store,id:string,observation:Child_Observation)->bool {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if observation.executor_incarnation!=s.incarnation || !begin(s) do return false
    defer rollback(s)
    rows,ok:=query(s.db,"SELECT instance_id,launch_key,state FROM executor_reservations WHERE reservation_id=?",id)
    if !ok || len(rows)!=1 || rows[0][0]!=observation.instance || rows[0][1]!=observation.launch_key || (rows[0][2]!="active" && rows[0][2]!="stopping") do return false
    if observation.present {
        if _,written:=query(s.db,"UPDATE executor_reservations SET launch_state='confirmed',observed_incarnation=? WHERE reservation_id=?",fmt.tprintf("%d",s.incarnation),id);!written do return false
        if _,written:=query(s.db,"UPDATE executor_intents SET state='settled' WHERE reservation_id=? AND kind='launch'",id);!written do return false
    } else {
        if _,written:=query(s.db,"UPDATE executor_reservations SET state='released',launch_state='stopped',observed_incarnation=? WHERE reservation_id=?",fmt.tprintf("%d",s.incarnation),id);!written do return false
        if _,written:=query(s.db,"UPDATE executor_intents SET state='settled' WHERE reservation_id=?",id);!written do return false
    }
    return commit(s)
}
complete_recovery :: proc(s:^Store,now:i64)->bool {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if !begin(s) do return false
    defer rollback(s)
    if code:=clock(s,now,false);code!="" do return false
    rows,ok:=query(s.db,"SELECT count(*) FROM executor_reservations WHERE state IN ('active','stopping') AND observed_incarnation!=?",fmt.tprintf("%d",s.incarnation))
    if !ok || len(rows)!=1 || rows[0][0]!="0" do return false
    if !exec(s.db,"UPDATE executor_runtime SET recovery_state='ready' WHERE singleton=1") do return false
    return commit(s)
}
