package owner_local

import "core:fmt"

RECEIPT_RETENTION_MS :: i64(30*24*60*60*1000)

// Clock uncertainty is a durable safety observation, not a task mutation. No
// canonical change, receipt or intent is created; only reconciliation clears it.
mark_clock_uncertain :: proc(tx:^Transaction) -> bool {
    if !transaction_current(tx) || tx.parent!=nil do return false
    if _,ok:=query(tx.store.db,"UPDATE runtime_database SET recovery_state='clock_uncertain' WHERE singleton=1 AND recovery_state='ready'");!ok do return false
    return transaction_commit(tx)
}

// Compaction retains deduplication identity permanently. Active or unknown
// outbox work pins its full receipt, regardless of age. Bounded batches avoid
// monopolizing the account writer. No automatic capacity reclamation exists.
compact_receipts :: proc(s:^Store,now:i64,limit:=100) -> (int,bool) {
    if now<RECEIPT_RETENTION_MS || limit<1 || limit>1000 do return 0,false
    tx:Transaction
    if !transaction_begin(s,&tx) do return 0,false
    defer transaction_rollback(&tx)
    state,read:=query(s.db,"SELECT clock_high_ms,recovery_state FROM runtime_database WHERE singleton=1")
    if !read || len(state)!=1 || now<number(state[0][0]) || state[0][1]!="ready" do return 0,false
    rows,ok:=query(s.db,`SELECT principal_id,operation_id FROM command_receipts r
      WHERE created_ms<=? AND request_expires_ms<? AND NOT EXISTS(SELECT 1 FROM runtime_intents i
       WHERE i.principal_id=r.principal_id AND i.operation_id=r.operation_id AND i.state!='settled')
      AND NOT EXISTS(SELECT 1 FROM lease_receipt_pins p JOIN local_leases l ON l.lease_id=p.lease_id WHERE p.principal_id=r.principal_id AND p.operation_id=r.operation_id AND l.retired_seq IS NULL)
      AND NOT EXISTS(SELECT 1 FROM local_fleet f WHERE f.principal_id=r.principal_id AND f.operation_id=r.operation_id)
      AND NOT EXISTS(SELECT 1 FROM local_workflow_coordinators c WHERE c.principal_id=r.principal_id AND c.operation_id=r.operation_id)
      AND NOT EXISTS(SELECT 1 FROM lifecycle_configs c WHERE c.principal_id=r.principal_id AND c.operation_id=r.operation_id)
      AND NOT EXISTS(SELECT 1 FROM source_receipt_pins p JOIN source_episodes e USING(chain_id,origin_kind,origin_id,episode_id) WHERE p.principal_id=r.principal_id AND p.operation_id=r.operation_id AND (e.resolved=0 OR (e.card_id!='' AND e.card_closed=0)))
      AND NOT EXISTS(SELECT 1 FROM local_workflow_language_executions x WHERE x.principal_id=r.principal_id AND x.operation_id=r.operation_id AND x.state='running')
      AND NOT EXISTS(SELECT 1 FROM local_workflow_events e JOIN local_workflow_executions x USING(chain_id,run_id,execution) WHERE e.principal_id=r.principal_id AND e.operation_id=r.operation_id AND x.state='running')
      AND NOT EXISTS(SELECT 1 FROM local_submissions a JOIN lifecycle_state t ON t.chain_id=a.chain_id AND t.task_id=a.task_id WHERE a.principal_id=r.principal_id AND a.operation_id=r.operation_id AND t.state!='done')
      ORDER BY commit_seq LIMIT ?`,fmt.tprintf("%d",now-RECEIPT_RETENTION_MS),fmt.tprintf("%d",now),fmt.tprintf("%d",limit))
    if !ok do return 0,false
    for row in rows {
        if _,ok=query(s.db,`INSERT INTO operation_tombstones SELECT principal_id,operation_id,chain_id,task_id,method,
          input_digest,digest_key_id,request_expires_ms,commit_seq FROM command_receipts WHERE principal_id=? AND operation_id=?`,row[0],row[1]);!ok do return 0,false
        if _,ok=query(s.db,"DELETE FROM lease_receipt_pins WHERE principal_id=? AND operation_id=?",row[0],row[1]);!ok do return 0,false
        if _,ok=query(s.db,"DELETE FROM command_receipts WHERE principal_id=? AND operation_id=?",row[0],row[1]);!ok do return 0,false
    }
    if _,ok=query(s.db,"UPDATE runtime_database SET clock_high_ms=? WHERE singleton=1",fmt.tprintf("%d",now));!ok do return 0,false
    if !transaction_commit(&tx) do return 0,false
    return len(rows),true
}

// Trusted local recovery API, not a command/capability. It can only advance a
// clock generation at/above the existing floor, never extend any deadline.
reconcile_clock :: proc(s:^Store,incarnation,generation,trusted_now:i64) -> bool {
    if trusted_now<0 || incarnation!=s.incarnation do return false
    tx:Transaction
    if !transaction_begin(s,&tx) do return false
    defer transaction_rollback(&tx)
    rows,ok:=query(s.db,`UPDATE runtime_database SET clock_generation=clock_generation+1,clock_high_ms=?,recovery_state='ready'
     WHERE singleton=1 AND incarnation=? AND clock_generation=? AND clock_high_ms<=? AND recovery_state!='recovery_required'
     RETURNING clock_generation`,fmt.tprintf("%d",trusted_now),fmt.tprintf("%d",incarnation),fmt.tprintf("%d",generation),fmt.tprintf("%d",trusted_now))
    if !ok || len(rows)!=1 do return false
    return transaction_commit(&tx)
}

// C1: a background caller's now can trail the store clock by however long it
// waited for the owner mutex while another write committed. A lag of at most
// OWNER_CLOCK_STALE_MS is that caller's own staleness, not a clock jump: it is
// raised to the store clock instead of marking the store clock_uncertain. A
// larger backward step is still a genuine jump and is refused as before.
OWNER_CLOCK_STALE_MS :: i64(5000)
clock_floor :: proc(s:^Store,now:i64) -> i64 {
    rows,ok:=query(s.db,"SELECT clock_high_ms FROM runtime_database WHERE singleton=1")
    if !ok || len(rows)!=1 do return now
    high:=number(rows[0][0])
    if now<high && high-now<=OWNER_CLOCK_STALE_MS do return high
    return now
}

// C1: a store marked clock_uncertain is not bricked. Once the trusted local
// clock is at or past clock_high_ms again, it advances the clock generation
// and returns to ready (reconcile_clock). A genuine backward jump keeps the
// store refusing writes until wall time catches up. recovered=true when this
// call cleared the mark.
clock_recover :: proc(s:^Store,now:i64) -> (recovered:bool,ok:bool) {
    rows,read:=query(s.db,"SELECT clock_generation,clock_high_ms,recovery_state FROM runtime_database WHERE singleton=1")
    if !read || len(rows)!=1 do return false,false
    if rows[0][2]!="clock_uncertain" || now<number(rows[0][1]) do return false,true
    return reconcile_clock(s,s.incarnation,number(rows[0][0]),now),true
}
