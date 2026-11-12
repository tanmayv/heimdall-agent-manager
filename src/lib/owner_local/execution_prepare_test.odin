#+feature dynamic-literals
package owner_local
import "core:encoding/json"
import "core:fmt"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"

@(test)
owner_preparation_initiation_lost_prepare_reply_query_and_exact_commit :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x:=execution_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
    sign:=Signer{&f.owner_priv,execution_test_sign}
    start:=execution_prepare_assignment(&f.store,"chain","task",f.owner,1000,sign)
    if !testing.expect_value(t,start.code,"ok") do return
    entries,ok:=execution_preparations(&f.store)
    if !testing.expect(t,ok && len(entries)==1) do return
    entry:=entries[0]
    testing.expect(t,execution_preparation_current(&f.store,entry.reservation,1000))
    replay:=execution_prepare_assignment(&f.store,"chain","task",f.owner,1001,sign)
    testing.expect(t,replay.code=="ok" && replay.replay)
    again,_:=execution_preparations(&f.store)
    testing.expect_value(t,again[0].prepare,entry.prepare)
    p,_:=contracts.executor_parse(entry.prepare,"prepare")
    resources:=executor.Resolved_Resources{field(p,"directory_key"),field(p,"provider_profile"),field(p,"instance_id"),field(p,"configuration_revision")}
    first:=executor.prepare(&x.host,entry.prepare,f.owner,1000,resources)
    testing.expect_value(t,first.code,"ok")
    // Lost reply: resend the original prepare, never create another identity.
    second:=executor.prepare(&x.host,entry.prepare,f.owner,1100,resources)
    testing.expect(t,second.code=="ok" && second.replay)
    receipt,signed:=executor.seal_receipt(&x.host,p,"prepare",second,{&f.creator_priv,execution_test_seal})
    testing.expect(t,signed)
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER query_write_fail BEFORE INSERT ON owner_execution_queries BEGIN SELECT RAISE(ABORT,'fault'); END"))
    testing.expect_value(t,execution_query_start(&f.store,entry.reservation,receipt,f.owner,x.host_key,1100,sign).code,"storage_error")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER query_write_fail"))
    query_result:=execution_query_start(&f.store,entry.reservation,receipt,f.owner,x.host_key,1100,sign)
    if !testing.expect_value(t,query_result.code,"ok") do return
    q,_:=contracts.executor_parse(query_result.body,"action")
    replay_query:=execution_query_start(&f.store,entry.reservation,receipt,f.owner,x.host_key,1101,sign)
    testing.expect(t,replay_query.replay && replay_query.body==query_result.body)
    host_query:=executor.action(&x.host,query_result.body,f.owner,1200)
    testing.expect_value(t,host_query.code,"ok")
    qr,q_ok:=executor.seal_receipt(&x.host,q,"action",host_query,{&f.creator_priv,execution_test_seal})
    testing.expect(t,q_ok)
    testing.expect_value(t,execution_prepare_commit(&f.store,entry.reservation,receipt,f.owner,x.host_key,1200,sign,query_result.body,receipt).code,"reservation_not_current")
    committed:=execution_prepare_commit(&f.store,entry.reservation,receipt,f.owner,x.host_key,1200,sign,query_result.body,qr)
    testing.expect_value(t,committed.code,"ok")
    rows,read:=query(f.store.db,"SELECT (SELECT count(*) FROM owner_execution_journal),(SELECT count(*) FROM local_leases),(SELECT count(*) FROM runtime_intents WHERE kind='executor.activate')")
    testing.expect(t,read);testing.expect_value(t,encode(rows),encode([1][3]string{{"1","1","1"}}))
    testing.expect(t,!execution_preparation_current(&f.store,entry.reservation,1200))
}

@(test)
owner_preparation_restart_never_mints_replacement_or_admits_old_epoch :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x:=execution_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
    sign:=Signer{&f.owner_priv,execution_test_sign}
    testing.expect_value(t,execution_prepare_assignment(&f.store,"chain","task",f.owner,1000,sign).code,"ok")
    entries,_:=execution_preparations(&f.store);if len(entries)!=1 do return
    entry:=entries[0]
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    retry:=execution_prepare_assignment(&f.store,"chain","task",f.owner,1100,sign)
    testing.expect(t,retry.code=="ok" && retry.replay)
    testing.expect(t,!execution_preparation_current(&f.store,entry.reservation,1100))
    entries,_=execution_preparations(&f.store)
    testing.expect_value(t,len(entries),1)
    testing.expect_value(t,entries[0].prepare,entry.prepare)
    expiry:=i64(1000)+contracts.EXECUTOR_PREPARE_TTL_MS
    testing.expect(t,execution_expire_preparations(&f.store,expiry))
    // The never-launched reservation was released with its expiry (F1 d):
    // the old assignment is no longer current, so nothing is minted for it.
    retry=execution_prepare_assignment(&f.store,"chain","task",f.owner,expiry+1,sign)
    testing.expect_value(t,retry.code,"invalid_scope")
    rows,_:=query(f.store.db,"SELECT (SELECT count(*) FROM owner_execution_journal),(SELECT count(*) FROM local_leases)")
    testing.expect_value(t,encode(rows),fmt.tprintf("[[%q,%q]]","1","0"))
}

@(test)
owner_preparation_cancel_before_or_after_response_prevents_grant :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x:=execution_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
    sign:=Signer{&f.owner_priv,execution_test_sign}
    testing.expect_value(t,execution_prepare_assignment(&f.store,"chain","task",f.owner,1000,sign).code,"ok")
    entries,_:=execution_preparations(&f.store);if len(entries)!=1 do return
    entry:=entries[0]
    // Current admission changes while remote I/O is outside the owner mutex.
    revision,_:=query(f.store.db,"SELECT revision FROM tasks WHERE task_id=?", "task")
    testing.expect_value(t,control_call(f,"task.cancel","cancel_preparation",revision[0][0]).code,"ok")
    testing.expect(t,!execution_preparation_current(&f.store,entry.reservation,1100))
    testing.expect_value(t,execution_query_start(&f.store,entry.reservation,"{}",f.owner,x.host_key,1100,sign).code,"invalid_scope")
    rows,_:=query(f.store.db,"SELECT count(*) FROM local_leases")
    testing.expect_value(t,rows[0][0],"0")
}

// G3: a committed row lives as long as its lease. While the lease is live a
// repeated prepare adopts the row (replay, never operation_conflict); once the
// lease expires the next maintenance pass retires the row with
// execution.lease_ended, and the next prepare is a new reservation and lease
// for the same assignment, itself adopted on repeat.
@(test)
owner_preparation_row_retires_with_its_lease_and_task_is_prepared_again :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x:=execution_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
    sign:=Signer{&f.owner_priv,execution_test_sign}
    if !testing.expect_value(t,execution_prepare_assignment(&f.store,"chain","task",f.owner,1000,sign).code,"ok") do return
    entries,_:=execution_preparations(&f.store);if !testing.expect_value(t,len(entries),1) do return
    entry:=entries[0]
    p,_:=contracts.executor_parse(entry.prepare,"prepare")
    resources:=executor.Resolved_Resources{field(p,"directory_key"),field(p,"provider_profile"),field(p,"instance_id"),field(p,"configuration_revision")}
    prepared:=executor.prepare(&x.host,entry.prepare,f.owner,1000,resources)
    receipt,_:=executor.seal_receipt(&x.host,p,"prepare",prepared,{&f.creator_priv,execution_test_seal})
    query_result:=execution_query_start(&f.store,entry.reservation,receipt,f.owner,x.host_key,1100,sign)
    q,_:=contracts.executor_parse(query_result.body,"action")
    qr,_:=executor.seal_receipt(&x.host,q,"action",executor.action(&x.host,query_result.body,f.owner,1200),{&f.creator_priv,execution_test_seal})
    if !testing.expect_value(t,execution_prepare_commit(&f.store,entry.reservation,receipt,f.owner,x.host_key,1200,sign,query_result.body,qr).code,"ok") do return

    // Live lease: a repeated prepare adopts the committed row.
    adopted:=execution_prepare_assignment(&f.store,"chain","task",f.owner,1300,sign)
    testing.expectf(t,adopted.code=="ok" && adopted.replay && adopted.body=="committed","live row adopted: %v",adopted)

    // The lease expires; the next maintenance pass retires the row.
    leases,_:=query(f.store.db,"SELECT expires_ms FROM local_leases")
    if !testing.expect_value(t,len(leases),1) do return
    ended:=number(leases[0][0])+1
    testing.expect(t,expire_leases(&f.store,ended))
    testing.expect(t,execution_expire_preparations(&f.store,ended))
    rows,_:=query(f.store.db,"SELECT state FROM owner_execution_journal WHERE reservation_id=?",entry.reservation)
    testing.expect_value(t,encode(rows),encode([1][1]string{{"retired"}}))
    events,_:=query(f.store.db,"SELECT count(*) FROM local_events WHERE kind='execution.lease_ended'")
    testing.expect_value(t,events[0][0],"1")

    // The task is prepared again: a new reservation and lease, not a conflict.
    again:=execution_prepare_assignment(&f.store,"chain","task",f.owner,ended+1,sign)
    testing.expectf(t,again.code=="ok" && !again.replay,"re-prepared after the lease ended: %v",again)
    fresh,_:=execution_preparations(&f.store)
    if testing.expect_value(t,len(fresh),1) {
        testing.expect(t,fresh[0].reservation!=entry.reservation,"a new reservation")
        fp,_:=contracts.executor_parse(fresh[0].prepare,"prepare")
        testing.expect(t,field(fp,"lease_id")!=field(p,"lease_id"),"a new lease")
    }
    repeat:=execution_prepare_assignment(&f.store,"chain","task",f.owner,ended+2,sign)
    testing.expectf(t,repeat.code=="ok" && repeat.replay,"the new row is adopted on repeat: %v",repeat)
    count,_:=query(f.store.db,"SELECT count(*) FROM owner_execution_journal")
    testing.expect_value(t,count[0][0],"2")
}

// R1 FIX B: after the work lease retires, a task that is not claimable
// (submitted for review, held, done) gets no new work generation; once it is
// ready again (rework) the next generation is prepared.
@(test)
owner_preparation_skips_non_claimable_task_after_retire :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x:=execution_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
    sign:=Signer{&f.owner_priv,execution_test_sign}
    reservation,_,committed:=execution_prepare_test_commit(t,x,sign)
    if !committed do return
    leases,_:=query(f.store.db,"SELECT expires_ms FROM local_leases")
    if !testing.expect_value(t,len(leases),1) do return
    ended:=number(leases[0][0])+1
    testing.expect(t,expire_leases(&f.store,ended))
    testing.expect(t,execution_expire_preparations(&f.store,ended))
    rows,_:=query(f.store.db,"SELECT state FROM owner_execution_journal WHERE reservation_id=?",reservation)
    testing.expect_value(t,encode(rows),encode([1][1]string{{"retired"}}))
    set_state:=proc(t:^testing.T,f:^Fixture,state:string) {
        _,ok:=query(f.store.db,"INSERT INTO lifecycle_state(chain_id,task_id,state) VALUES('chain','task',?) ON CONFLICT(chain_id,task_id) DO UPDATE SET state=excluded.state",state)
        testing.expect(t,ok)
    }
    for state,i in ([2]string{"in_review","done"}) {
        set_state(t,f,state)
        refused:=execution_prepare_assignment(&f.store,"chain","task",f.owner,ended+1+i64(i),sign)
        testing.expectf(t,refused.code=="invalid_scope","no work prepare for a %s task: %v",state,refused)
        testing.expectf(t,execution_prepare_skipped(&f.store,"chain","task",refused.code),"a %s task is skipped, not reported as refused",state)
    }
    set_state(t,f,"ready")
    _,held:=query(f.store.db,"INSERT INTO local_controls(chain_id,task_id,mode,resume_state,reason,waiting_on) VALUES('chain','task','held','ready','test hold','') ON CONFLICT(chain_id,task_id) DO UPDATE SET mode='held'")
    if testing.expect(t,held) {
        refused:=execution_prepare_assignment(&f.store,"chain","task",f.owner,ended+3,sign)
        testing.expectf(t,refused.code=="invalid_scope","no work prepare for a held task: %v",refused)
        _,_=query(f.store.db,"UPDATE local_controls SET mode='ready' WHERE chain_id='chain' AND task_id='task'")
    }
    testing.expect(t,!execution_prepare_skipped(&f.store,"chain","task","invalid_scope"),"a refusal of a claimable task is still reported")
    count,_:=query(f.store.db,"SELECT count(*) FROM owner_execution_journal")
    testing.expect_value(t,count[0][0],"1")
    again:=execution_prepare_assignment(&f.store,"chain","task",f.owner,ended+4,sign)
    testing.expectf(t,again.code=="ok" && !again.replay,"rework: the ready task is prepared again: %v",again)
}

// Commits the fixture's first remote preparation and returns its reservation
// and prepare document.
execution_prepare_test_commit :: proc(t:^testing.T,x:^Execution_Test,sign:Signer) -> (string,json.Object,bool) {
    f:=x.owner
    if !testing.expect_value(t,execution_prepare_assignment(&f.store,"chain","task",f.owner,1000,sign).code,"ok") do return "",nil,false
    entries,_:=execution_preparations(&f.store);if !testing.expect_value(t,len(entries),1) do return "",nil,false
    entry:=entries[0]
    p,_:=contracts.executor_parse(entry.prepare,"prepare")
    resources:=executor.Resolved_Resources{field(p,"directory_key"),field(p,"provider_profile"),field(p,"instance_id"),field(p,"configuration_revision")}
    prepared:=executor.prepare(&x.host,entry.prepare,f.owner,1000,resources)
    receipt,_:=executor.seal_receipt(&x.host,p,"prepare",prepared,{&f.creator_priv,execution_test_seal})
    query_result:=execution_query_start(&f.store,entry.reservation,receipt,f.owner,x.host_key,1100,sign)
    q,_:=contracts.executor_parse(query_result.body,"action")
    qr,_:=executor.seal_receipt(&x.host,q,"action",executor.action(&x.host,query_result.body,f.owner,1200),{&f.creator_priv,execution_test_seal})
    if !testing.expect_value(t,execution_prepare_commit(&f.store,entry.reservation,receipt,f.owner,x.host_key,1200,sign,query_result.body,qr).code,"ok") do return "",nil,false
    return entry.reservation,p,true
}

// G3 (decision a, failed launch): the executor proves the launched child gone
// (child_absent) while its lease is live. The owner ends the lease (reason
// child_absent) and retires the row at once; a repeat is a no-op; the old
// activation intent is no longer current, so it can neither block nor revive
// the ended lease; the task is prepared again as a new generation.
@(test)
owner_preparation_child_absent_ends_lease_and_task_is_replaced :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x:=execution_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
    sign:=Signer{&f.owner_priv,execution_test_sign}
    reservation,p,committed:=execution_prepare_test_commit(t,x,sign)
    if !committed do return
    claims,claimed:=intent_claim_due(&f.store,1300)
    activation:Intent_Claim
    for c in claims do if c.kind=="executor.activate" do activation=c
    if !testing.expect(t,claimed && activation.id!="","the activation intent exists") do return
    current,_,_,_:=execution_activation_fence(&f.store,activation,1300)
    testing.expect(t,current,"the activation is current while the lease is live")

    ended:=execution_child_absent(&f.store,activation,1300)
    testing.expectf(t,ended.code=="ok" && !ended.replay && ended.body=="child_absent","child_absent ends the lease: %v",ended)
    leases,_:=query(f.store.db,"SELECT retired_seq IS NOT NULL FROM local_leases WHERE lease_id=?",field(p,"lease_id"))
    testing.expect_value(t,encode(leases),encode([1][1]string{{"1"}}))
    rows,_:=query(f.store.db,"SELECT state FROM owner_execution_journal WHERE reservation_id=?",reservation)
    testing.expect_value(t,encode(rows),encode([1][1]string{{"retired"}}))
    events,_:=query(f.store.db,"SELECT count(*) FROM local_events WHERE kind='lease.expired' AND evidence_json LIKE '%child_absent%'")
    testing.expect_value(t,events[0][0],"1")
    again:=execution_child_absent(&f.store,activation,1301)
    testing.expect(t,again.code=="ok" && again.replay,"a repeated child_absent is a no-op")
    stale,_,_,_:=execution_activation_fence(&f.store,activation,1301)
    testing.expect(t,!stale,"the old activation intent cannot revive the ended lease")

    replaced:=execution_prepare_assignment(&f.store,"chain","task",f.owner,1302,sign)
    testing.expectf(t,replaced.code=="ok" && !replaced.replay,"the task is prepared again: %v",replaced)
    fresh,_:=execution_preparations(&f.store)
    if testing.expect_value(t,len(fresh),1) {
        fp,_:=contracts.executor_parse(fresh[0].prepare,"prepare")
        testing.expect(t,fresh[0].reservation!=reservation && field(fp,"lease_id")!=field(p,"lease_id"),"a new reservation and lease (new launch key and token on the executor)")
    }
}

// C3 (run7 regression): remote prepare_assignment -> prepare_start under a
// clock hook that runs ahead of the caller and advances on every read. The
// time derived at the operation's entry flows unchanged through the nested
// prepare_start, so the signed hard_ms matches its recomputation; a current
// hint never reads the hook, and a missing hint reads it exactly once.
prepare_ahead_reads: i64
prepare_ahead_clock :: proc() -> i64 {return 50_000+sync.atomic_add(&prepare_ahead_reads,1)}

@(test)
owner_preparation_operation_time_flows_through_nested_prepare_start :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    for missing_hint in ([2]bool{false,true}) {
        x:=execution_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
        f.store.clock=prepare_ahead_clock
        sign:=Signer{&f.owner_priv,execution_test_sign}
        before:=sync.atomic_load(&prepare_ahead_reads)
        hint:=i64(0) if missing_hint else 1000
        start:=execution_prepare_assignment(&f.store,"chain","task",f.owner,hint,sign)
        reads:=sync.atomic_load(&prepare_ahead_reads)-before
        if !testing.expectf(t,start.code=="ok" && !start.replay,"prepare under an advancing hook (missing hint %v): %s",missing_hint,start.code) do continue
        testing.expectf(t,reads==(1 if missing_hint else 0),"the hook is read once for a missing hint and never for a current one: %d reads",reads)
        entries,ok:=execution_preparations(&f.store)
        if !testing.expect(t,ok && len(entries)==1) do continue
        p,_:=contracts.executor_parse(entries[0].prepare,"prepare")
        derived:=50_000+before if missing_hint else 1000
        testing.expect_value(t,contracts.executor_number(p,"hard_ms"),derived+LEASE_HARD_MS)
        testing.expect_value(t,contracts.executor_number(p,"prepare_until_ms"),derived+contracts.EXECUTOR_PREPARE_TTL_MS)
    }
}
