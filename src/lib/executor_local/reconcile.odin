package executor_local

import "core:fmt"
import "core:sync"

// Observation work is bounded and ordered by retained reservation identity.
// It never acquires launch permission. Skip current undispatched claims: their
// owner nonce callback may be in flight with the application mutex released.
RECONCILE_BATCH_MAX :: 16
reconcile_candidates :: proc(s:^Store,after:string,limit:int)->([]Intent,bool) {
    context.allocator=context.temp_allocator
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if s.db==nil || s.unusable || limit<=0 || limit>RECONCILE_BATCH_MAX do return nil,false
    rows,ok:=query(s.db,`SELECT r.reservation_id,r.instance_id,r.launch_key,r.document
      FROM executor_reservations r
      WHERE r.reservation_id>? AND r.state IN ('active','stopping') AND
        (r.state='stopping' OR r.executor_incarnation!=CAST(? AS INTEGER) OR r.launch_state='confirmed' OR
          EXISTS(SELECT 1 FROM executor_intents i WHERE i.reservation_id=r.reservation_id
            AND i.kind='launch' AND i.claim_incarnation>0))
      ORDER BY r.reservation_id LIMIT CAST(? AS INTEGER)`,
      after,fmt.tprintf("%d",s.incarnation),fmt.tprintf("%d",limit))
    if !ok do return nil,false
    out:=make([]Intent,len(rows),context.temp_allocator)
    for row,i in rows do out[i]=Intent{row[0],"query",row[1],row[2],row[3],s.incarnation}
    return out,true
}

// Recheck immediately before local physical I/O. A candidate never grants
// launch, extends a deadline, or releases a charge without exact observation.
reconcile_current :: proc(s:^Store,intent:Intent)->(stop,current:bool) {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if s.db==nil || s.unusable || intent.incarnation!=s.incarnation || intent.kind!="query" do return false,false
    rows,ok:=query(s.db,`SELECT r.state FROM executor_reservations r
      WHERE r.reservation_id=? AND r.instance_id=? AND r.launch_key=? AND r.document=?
        AND r.state IN ('active','stopping') AND
        (r.state='stopping' OR r.executor_incarnation!=CAST(? AS INTEGER) OR r.launch_state='confirmed' OR
          EXISTS(SELECT 1 FROM executor_intents i WHERE i.reservation_id=r.reservation_id
            AND i.kind='launch' AND i.claim_incarnation>0))`,
      intent.reservation,intent.instance,intent.launch_key,intent.document,fmt.tprintf("%d",s.incarnation))
    if !ok || len(rows)!=1 do return false,false
    return rows[0][0]=="stopping",true
}
