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
