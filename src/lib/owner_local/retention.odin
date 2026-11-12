package owner_local

import "core:fmt"

RECEIPT_RETENTION_MS :: i64(30*24*60*60*1000)

// Clock uncertainty is a durable safety observation, not a task mutation. No
// canonical change, receipt or intent is created; only reconciliation clears it.
// C1: the store is never marked clock_uncertain any more (effective_now
// clamps every decision instead). Kept so older call sites stay inert.
mark_clock_uncertain :: proc(tx:^Transaction) -> bool {
    return true
}

// Compaction retains deduplication identity permanently. Active or unknown
// outbox work pins its full receipt, regardless of age. Bounded batches avoid
// monopolizing the account writer. No automatic capacity reclamation exists.
compact_receipts :: proc(s:^Store,now:i64,limit:=100) -> (int,bool) {
    now:=effective_now(s,now) // C1: decide and stamp with max(caller clock, store clock)
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
    if _,ok=query(s.db,"UPDATE runtime_database SET clock_high_ms=max(clock_high_ms,CAST(? AS INTEGER)) WHERE singleton=1",fmt.tprintf("%d",now));!ok do return 0,false
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
    rows,ok:=query(s.db,`UPDATE runtime_database SET clock_generation=clock_generation+1,clock_high_ms=max(clock_high_ms,CAST(? AS INTEGER)),recovery_state='ready'
     WHERE singleton=1 AND incarnation=? AND clock_generation=? AND clock_high_ms<=? AND recovery_state!='recovery_required'
     RETURNING clock_generation`,fmt.tprintf("%d",trusted_now),fmt.tprintf("%d",incarnation),fmt.tprintf("%d",generation),fmt.tprintf("%d",trusted_now))
    if !ok || len(rows)!=1 do return false
    return transaction_commit(&tx)
}

// C1 (user 10:10Z): monotonic clamp, never refuse. Every owner-store decision
// uses effective now = max(the caller's clock, clock_high_ms), so time never
// runs backwards for a decision and the store never refuses a write because
// of the clock. A caller clock more than OWNER_CLOCK_ALERT_MS behind the
// store clock is a real backward jump: it is logged as an alert, and the
// decision still uses the high-water time.
OWNER_CLOCK_ALERT_MS :: i64(5000)
effective_now :: proc(s:^Store,now:i64) -> i64 {
    rows,ok:=query(s.db,"SELECT clock_high_ms FROM runtime_database WHERE singleton=1")
    if !ok || len(rows)!=1 do return now
    high:=number(rows[0][0])
    if now>=high do return now
    if high-now>OWNER_CLOCK_ALERT_MS do fmt.eprintfln("owner store clock alert: local clock is %d ms behind the store clock; using the store clock",high-now)
    return high
}
