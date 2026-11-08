#+feature dynamic-literals
package owner_local
import "core:encoding/json"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"

// R5 re-verification fixtures for the owner side of the scoped Linux Codex
// notification guarantees on the integrated Bridge-owned branch. They use the
// existing fake executor harness; no provider or daemon is started.

r5_authority_counts :: proc(f:^Fixture)->string {
    rows,_:=query(f.store.db,`SELECT (SELECT count(*) FROM local_leases),(SELECT count(*) FROM local_work_attempts),
      (SELECT count(*) FROM command_receipts),(SELECT count(*) FROM local_events),(SELECT count(*) FROM control_notices),
      (SELECT count(*) FROM owner_execution_bootstraps),(SELECT count(*) FROM owner_execution_journal)`)
    return encode(rows)
}
r5_hold :: proc(f:^Fixture,op:string,now:i64)->Result {
    revisions,_:=query(f.store.db,"SELECT revision FROM tasks WHERE task_id='task'")
    payload:=encode(doc(map[string]string{"body_cipher"=cipher(f,"checkpoint € 日本語 😀")}))
    return invoke(f,command(f,"task.hold",op,"task",payload,revisions[0][0]),payload,now)
}
r5_notification_claims :: proc(t:^testing.T,f:^Fixture,now:i64)->[dynamic]Intent_Claim {
    claims,ok:=intent_claim_due(&f.store,now,20,.Executor)
    testing.expect(t,ok)
    out:=make([dynamic]Intent_Claim,context.temp_allocator)
    for c in claims do if c.kind=="executor.notification" do append(&out,c)
    return out
}
// Simulate an unactivated migration import over this chain. Production imports
// only create new chains, so this is a defense-in-depth probe of every gate.
r5_quarantine :: proc(t:^testing.T,f:^Fixture)->bool {
    _,ok:=query(f.store.db,"INSERT INTO migration_imports VALUES('r5_migration',?,'chain',?,'device','device',1,'{}','{}','{}',NULL)",
        strings.repeat("d",64,context.temp_allocator),strings.repeat("e",64,context.temp_allocator))
    return testing.expect(t,ok && migration_quarantined(&f.store,"chain"),"chain is quarantined")
}
r5_activate :: proc(t:^testing.T,f:^Fixture)->bool {
    ok:=exec(f.store.db,"UPDATE migration_imports SET activated_seq=2 WHERE migration_id='r5_migration'")
    return testing.expect(t,ok && !migration_quarantined(&f.store,"chain"),"quarantine lifted")
}

// (a) One task.hold notice settles exactly once after a lost executor result.
// The retried claim re-signs the same effect, so the executor journal returns
// its original receipt; the owner settles one intent and grants no authority.
@(test)
owner_hold_notification_settles_once_after_lost_result :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x,activation:=execution_bootstrap_fixture(t);defer execution_test_destroy(x);f:=x.owner
    sign:=Signer{&f.owner_priv,execution_test_sign}
    if !testing.expect_value(t,execution_bootstrap(&f.store,activation,"Worker","","[]",f.owner,1200,sign).code,"ok") do return
    if !testing.expect_value(t,r5_hold(f,"r5_hold",1300).code,"ok") do return
    held:=r5_authority_counts(f)
    first:=r5_notification_claims(t,f,1300)
    if !testing.expect_value(t,len(first),1) do return
    c1:=first[0]
    produced:=execution_notification(&f.store,c1,f.owner,1400,sign)
    if !testing.expect_value(t,produced.code,"ok") do return
    v1,_:=contracts.owner_content_document(produced.body);b1,_:=v1.(json.Object)
    n1,_:=contracts.executor_parse(field(b1,"notification"),"notification")
    // The executor result is lost in transport: the owner records failure and
    // retries the same intent after the bounded delay.
    testing.expect(t,intent_result(&f.store,c1,false,"",1400))
    testing.expect_value(t,len(r5_notification_claims(t,f,1401)),0)
    retry:=r5_notification_claims(t,f,2400)
    if !testing.expect_value(t,len(retry),1) do return
    c2:=retry[0]
    testing.expect(t,c2.id==c1.id && c2.attempt==2 && c2.payload==c1.payload && c2.fence==c1.fence)
    testing.expect_value(t,execution_notification(&f.store,c1,f.owner,2400,sign).code,"no_current_target")
    again:=execution_notification(&f.store,c2,f.owner,2400,sign)
    if !testing.expect_value(t,again.code,"ok") do return
    v2,_:=contracts.owner_content_document(again.body);b2,_:=v2.(json.Object)
    n2,_:=contracts.executor_parse(field(b2,"notification"),"notification")
    testing.expect(t,field(b1,"message")==field(b2,"message") && field(n1,"intent_id")==field(n2,"intent_id") &&
        executor.notification_effect(n1)==executor.notification_effect(n2),
        "retry addresses the same executor journal effect, never a new delivery")
    receipt:=`{"status":"delivered","ticket":"original"}`
    testing.expect(t,intent_result(&f.store,c2,true,receipt,2500),"one settlement")
    testing.expect(t,!intent_result(&f.store,c2,true,receipt,2500),"no duplicate settlement")
    testing.expect(t,!intent_result(&f.store,c1,true,receipt,2500),"stale claim cannot settle")
    testing.expect_value(t,len(r5_notification_claims(t,f,100000)),0)
    testing.expect_value(t,execution_notification(&f.store,c2,f.owner,2600,sign).code,"no_current_target")
    rows,_:=query(f.store.db,"SELECT state,attempts,result_json FROM runtime_intents WHERE kind='executor.notification'")
    testing.expect(t,len(rows)==1 && rows[0][0]=="settled" && rows[0][1]=="2" && rows[0][2]==receipt)
    testing.expect_value(t,r5_authority_counts(f),held)
}

// (b) A quarantined chain refuses execution admission: preparation and the
// activation/bootstrap of an already committed reservation.
@(test)
owner_quarantined_chain_refuses_execution_admission :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    {
        x:=execution_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
        lifecycle_edit(t,f,"1","2")
        x.lease=lease_request(f,lease_child(),"lease.claim","claim","lease","","3")
        if !r5_quarantine(t,f) do return
        testing.expect(t,execution_prepare_start(&f.store,x.prepare,x.lease,f.owner,1000).code!="ok")
        rows,_:=query(f.store.db,"SELECT count(*) FROM owner_execution_journal")
        testing.expect_value(t,rows[0][0],"0")
        if !r5_activate(t,f) do return
        testing.expect_value(t,execution_prepare_start(&f.store,x.prepare,x.lease,f.owner,1000).code,"ok")
    }
    {
        x,activation:=execution_bootstrap_fixture(t);defer execution_test_destroy(x);f:=x.owner
        sign:=Signer{&f.owner_priv,execution_test_sign}
        if !r5_quarantine(t,f) do return
        current,_,_,_:=execution_activation_fence(&f.store,activation,1200)
        testing.expect(t,!current,"activation fence refuses a quarantined chain")
        testing.expect(t,execution_bootstrap(&f.store,activation,"Worker","","[]",f.owner,1200,sign).code!="ok")
        rows,_:=query(f.store.db,"SELECT count(*) FROM owner_execution_bootstraps")
        testing.expect_value(t,rows[0][0],"0")
        if !r5_activate(t,f) do return
        testing.expect_value(t,execution_bootstrap(&f.store,activation,"Worker","","[]",f.owner,1200,sign).code,"ok")
    }
}

// (b) A quarantined chain refuses notification admission: no task.hold notice
// is produced, and an already queued notice cannot be signed or fenced.
@(test)
owner_quarantined_chain_refuses_notification_admission :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    {
        x,activation:=execution_bootstrap_fixture(t);defer execution_test_destroy(x);f:=x.owner
        sign:=Signer{&f.owner_priv,execution_test_sign}
        if !testing.expect_value(t,execution_bootstrap(&f.store,activation,"Worker","","[]",f.owner,1200,sign).code,"ok") do return
        if !r5_quarantine(t,f) do return
        before:=r5_authority_counts(f)
        testing.expect_value(t,r5_hold(f,"r5_quarantined_hold",1300).code,"operation_conflict")
        testing.expect_value(t,len(r5_notification_claims(t,f,1300)),0)
        testing.expect_value(t,r5_authority_counts(f),before)
        if !r5_activate(t,f) do return
        testing.expect_value(t,r5_hold(f,"r5_activated_hold",1300).code,"ok")
        testing.expect_value(t,len(r5_notification_claims(t,f,1300)),1)
    }
    {
        x,activation:=execution_bootstrap_fixture(t);defer execution_test_destroy(x);f:=x.owner
        sign:=Signer{&f.owner_priv,execution_test_sign}
        if !testing.expect_value(t,execution_bootstrap(&f.store,activation,"Worker","","[]",f.owner,1200,sign).code,"ok") do return
        if !testing.expect_value(t,r5_hold(f,"r5_hold",1300).code,"ok") do return
        claims:=r5_notification_claims(t,f,1300)
        if !testing.expect_value(t,len(claims),1) do return
        if !r5_quarantine(t,f) do return
        testing.expect_value(t,execution_notification_current(&f.store,claims[0],1400),"no_current_target")
        testing.expect_value(t,execution_notification(&f.store,claims[0],f.owner,1400,sign).code,"no_current_target")
        if !r5_activate(t,f) do return
        testing.expect_value(t,execution_notification(&f.store,claims[0],f.owner,1400,sign).code,"ok")
    }
}
