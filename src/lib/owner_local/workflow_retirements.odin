#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"

// Preserve task-scoped native expiry/cancellation evidence before revocation.
// The deferred parent FK requires the enclosing accepted event to commit too;
// no earlier event is backfilled by a later refresh (transaction.base_seq).
workflow_retire_task :: proc(s:^Store,c:json.Object,run,execution,task:string,seq:i64)->bool {
    if !transaction_current(s.active) || seq<=s.active.base_seq do return false
    chain:=field(c,"chain_id")
    rows,ok:=query(s.db,"SELECT COALESCE(l.state,'ready'),COALESCE(c.mode,'ready'),COALESCE(w.lease_id,'') FROM tasks t LEFT JOIN lifecycle_state l USING(chain_id,task_id) LEFT JOIN local_controls c USING(chain_id,task_id) LEFT JOIN local_leases w ON w.chain_id=t.chain_id AND w.task_id=t.task_id AND w.retired_seq IS NULL WHERE t.chain_id=? AND t.task_id=?",chain,task)
    if !ok || len(rows)!=1 do return false
    if rows[0][0]=="done" || rows[0][1]=="cancelled" do return true
    cause:=field(c,"method")
    _,ok=query(s.db,"INSERT INTO local_task_retirements VALUES(?,?,?,?,?,?,'chain_closed',?)",fmt.tprintf("%d",seq),chain,task,run,execution,rows[0][2],cause)
    if !ok do return false
    return control_mode(s,chain,task,"cancelled","ready","workflow execution stopped","")
}

// Included in the enclosing immutable event envelope. Actor, accepted time and
// exact signed input remain on that parent; these records retain native scope.
workflow_retirement_evidence :: proc(s:^Store,seq:i64)->(string,bool) {
    rows,ok:=query(s.db,"SELECT chain_id,task_id,run_id,execution,lease_id,reason,cause FROM local_task_retirements WHERE seq=? ORDER BY chain_id,task_id",fmt.tprintf("%d",seq))
    if !ok do return "",false
    items:=make([dynamic]json.Value,0,len(rows),context.temp_allocator)
    for row in rows {
        append(&items,doc(map[string]string{"chain_id"=row[0],"task_id"=row[1],"run_id"=row[2],"execution"=row[3],"lease_id"=row[4],"reason"=row[5],"cause"=row[6]}))
    }
    return encode(json.Array(items)),true
}

// Native workflow_stop_tasks preserves already terminal tasks. A merge intent
// has submitted work and may have performed its Git CAS; defer that decision
// without invalidating its exact fence/preparation. Failed deliveries retry.
workflow_defer_retirement :: proc(s:^Store,c:json.Object,run,execution,task,intent:string,seq:i64)->bool {
    if !transaction_current(s.active) || seq<=s.active.base_seq do return false
    prior,read:=query(s.db,"SELECT 1 FROM deferred_workflow_retirements WHERE intent_id=?",intent)
    if !read do return false
    if len(prior)>0 do return true
    _,ok:=query(s.db,"INSERT INTO deferred_workflow_retirements VALUES(?,?,?,?,?,?,?,'full')",intent,fmt.tprintf("%d",seq),field(c,"chain_id"),task,run,execution,field(c,"method"))
    return ok
}
workflow_settle_deferred :: proc(s:^Store,intent:string,seq:i64,head:string)->bool {
    rows,read:=query(s.db,"SELECT d.chain_id,d.task_id FROM deferred_workflow_retirements d WHERE intent_id=? AND NOT EXISTS(SELECT 1 FROM deferred_workflow_dispositions r WHERE r.intent_id=d.intent_id)",intent)
    if !read do return false
    if len(rows)==0 do return true
    states,ok:=query(s.db,"SELECT state FROM lifecycle_state WHERE chain_id=? AND task_id=?",rows[0][0],rows[0][1])
    if !ok || len(states)!=1 || states[0][0]!="done" do return false
    _,ok=query(s.db,"INSERT INTO deferred_workflow_dispositions VALUES(?,?,'preserved_terminal',?)",intent,fmt.tprintf("%d",seq),head)
    return ok
}
workflow_deferred_evidence :: proc(s:^Store,seq:i64)->(string,bool) {
    rows,ok:=query(s.db,`SELECT d.intent_id,COALESCE(d.requested_seq,''),d.chain_id,d.task_id,d.run_id,d.execution,d.cause,COALESCE(r.settled_seq,''),COALESCE(r.disposition,''),COALESCE(r.head,''),d.source_completeness
      FROM deferred_workflow_retirements d LEFT JOIN deferred_workflow_dispositions r USING(intent_id)
      WHERE d.requested_seq=? OR r.settled_seq=? ORDER BY d.intent_id`,fmt.tprintf("%d",seq),fmt.tprintf("%d",seq))
    if !ok do return "",false
    items:=make([dynamic]json.Value,context.temp_allocator)
    for row in rows {
        append(&items,doc(map[string]string{"intent_id"=row[0],"requested_seq"=row[1],"chain_id"=row[2],"task_id"=row[3],"run_id"=row[4],"execution"=row[5],"cause"=row[6],"settled_seq"=row[7],"disposition"=row[8],"head"=row[9],"source_completeness"=row[10]}))
    }
    return encode(json.Array(items)),true
}
