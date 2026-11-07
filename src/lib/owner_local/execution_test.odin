#+feature dynamic-literals
package owner_local

import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"
import vault "odin_test:lib/vault"

Execution_Test :: struct {owner:^Fixture,host:executor.Store,host_key:contracts.Owner_Verified_Key,path,prepare,lease,receipt:string}
execution_test_sign :: proc(ctx:rawptr,kind:string,o:json.Object)->(string,bool) {
    canonical,ok:=contracts.executor_canonical(strings.trim_prefix(kind,"executor."),o)
    if !ok do return test_sign(ctx,kind,o)
    signature,signed:=vault.sign_p256((^ecdsa.Private_Key)(ctx),transmute([]byte)canonical)
    return vault.hex_encode_lower(signature.sig[:],context.temp_allocator),signed
}
execution_test_seal :: proc(ctx:rawptr,kind:string,o:json.Object)->(string,bool) {return execution_test_sign(ctx,fmt.tprintf("executor.%s",kind),o)}
execution_test_signed :: proc(f:^Fixture,o:json.Object,kind:string,host:=false)->string {
    signature,ok:=execution_test_sign(&f.creator_priv if host else &f.owner_priv,fmt.tprintf("executor.%s",kind),o)
    if !ok do return ""
    m:=o;m["signature"]=json.String(signature)
    return encode(m)
}
execution_test_document :: proc(kind:string)->json.Object {
    value,_:=contracts.owner_content_document(#load("../../contracts/fixtures/executor-v1.json",string))
    root,_:=value.(json.Object);entries,_:=root["valid"].(json.Array)
    for item in entries {
        row,_:=item.(json.Object)
        if field(row,"kind")==kind {o,_:=contracts.executor_parse(field(row,"raw"),kind);return o}
    }
    return nil
}
execution_test_fixture :: proc(t:^testing.T)->^Execution_Test {
    x:=new(Execution_Test);x.owner=fixture(t);f:=x.owner
    x.path=fmt.aprintf("%s.executor",f.path)
    x.host_key=f.creator;x.host_key.kind="bridge";x.host_key.principal_id="executor";x.host_key.key_id="operator"
    remote_test_seed(t,f,x.host_key)
    if !testing.expect(t,executor.open(&x.host,x.path,"account","executor","operator")) do testing.fail_now(t,"executor open")
    policy:=execution_test_document("policy")
    testing.expect_value(t,executor.install_policy(&x.host,execution_test_signed(f,policy,"policy",true),x.host_key,1000).code,"ok")
    p:=execution_test_document("prepare")
    for pair in ([5][2]string{{"owner_bridge_id","bridge"},{"key_id","bridge_key"},{"launch_epoch","epoch"},{"lease_id","lease"},{"hard_ms","3601000"}}) do p[pair[0]]=json.String(pair[1])
    x.prepare=execution_test_signed(f,p,"prepare")
    x.lease=lease_request(f,lease_child(),"lease.claim","claim","lease","")
    return x
}
execution_test_destroy :: proc(x:^Execution_Test) {
    executor.close(&x.host)
    for ext in ([4]string{"","-wal","-shm",".writer"}) do _=os.remove(fmt.tprintf("%s%s",x.path,ext))
    delete(x.path);destroy(x.owner);free(x)
}
execution_test_prepare :: proc(t:^testing.T,x:^Execution_Test,now:i64=1000)->string {
    p,_:=contracts.executor_parse(x.prepare,"prepare")
    r:=executor.prepare(&x.host,x.prepare,x.owner.owner,now,{field(p,"directory_key"),field(p,"provider_profile"),field(p,"instance_id"),field(p,"configuration_revision")})
    if !testing.expect_value(t,r.code,"ok") do return ""
    raw,ok:=executor.seal_receipt(&x.host,p,"prepare",r,{&x.owner.creator_priv,execution_test_seal})
    testing.expect(t,ok)
    return raw
}
execution_test_commit :: proc(x:^Execution_Test,now:i64=1100,query_raw:string="",query_receipt:string="")->Result {
    return execution_prepare_commit(&x.owner.store,"reservation",x.receipt,x.owner.owner,x.host_key,now,{&x.owner.owner_priv,execution_test_sign},query_raw,query_receipt)
}
execution_test_query :: proc(t:^testing.T,x:^Execution_Test,now:i64=1200)->(string,string) {
    p,_:=contracts.executor_parse(x.prepare,"prepare");digest,_:=contracts.executor_digest("prepare",p)
    q:=execution_test_document("action")
    for pair in ([10][2]string{{"method","query"},{"operation_id",fmt.tprintf("query_%d",now)},{"owner_bridge_id","bridge"},{"key_id","bridge_key"},
        {"prepare_digest",digest},{"hard_ms","3601000"},{"expires_ms","3000"},{"request_expires_ms",fmt.tprintf("%d",now+1000)},
        {"owner_incarnation",fmt.tprintf("%d",x.owner.store.incarnation)},{"executor_incarnation",fmt.tprintf("%d",x.host.incarnation)}}) { q[pair[0]]=json.String(pair[1]) }
    raw:=execution_test_signed(x.owner,q,"action")
    r:=executor.action(&x.host,raw,x.owner.owner,now)
    if !testing.expect_value(t,r.code,"ok") do return "",""
    receipt,ok:=executor.seal_receipt(&x.host,q,"action",r,{&x.owner.creator_priv,execution_test_seal})
    testing.expect(t,ok)
    return raw,receipt
}

execution_test_claim :: proc(t:^testing.T,f:^Fixture)->Intent_Claim {
    claims,ok:=intent_claim_due(&f.store,1100)
    testing.expect(t,ok)
    for c in claims do if c.kind=="executor.activate" do return c
    testing.fail_now(t,"missing activation claim")
}
execution_test_challenge :: proc(t:^testing.T,x:^Execution_Test,claim:Intent_Claim)->executor.Fence_Challenge {
    pending,ok:=executor.fence_challenge(&x.host,claim.payload,claim.id,claim.attempt,x.owner.owner,x.host_key,1150,{&x.owner.creator_priv,execution_test_seal})
    testing.expect(t,ok)
    return pending
}
execution_test_fence_reply :: proc(x:^Execution_Test,request:string,now:i64=1200)->Result {
    return execution_fence_reply(&x.owner.store,request,x.host_key,x.owner.owner,1,"head",now,{&x.owner.owner_priv,execution_test_sign})
}

@(test)
owner_execution_signed_fence_exchange_is_exact_and_single_use :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x:=execution_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
    testing.expect_value(t,execution_prepare_start(&f.store,x.prepare,x.lease,f.owner,1000).code,"ok")
    x.receipt=execution_test_prepare(t,x)
    grant:=execution_test_commit(x)
    if !testing.expect_value(t,grant.code,"ok") do return
    claim:=execution_test_claim(t,f)
    pending:=execution_test_challenge(t,x,claim);defer executor.fence_challenge_destroy(&pending)
    other:=execution_test_challenge(t,x,claim);defer executor.fence_challenge_destroy(&other)
    testing.expect(t,pending.request!=other.request,"each exchange uses fresh OS entropy")
    before:=fleet_policy_test_state(f)
    reply:=execution_test_fence_reply(x,pending.request)
    if !testing.expect_value(t,reply.code,"ok") do return
    testing.expect_value(t,fleet_policy_test_state(f),before)
    mismatch:=executor.fence_accept(&x.host,&other,reply.body,f.owner,x.host_key,1200)
    testing.expect(t,!mismatch.current && !other.consumed)
    proof:=executor.fence_accept(&x.host,&pending,reply.body,f.owner,x.host_key,1200)
    testing.expect(t,proof.current && pending.consumed && proof.commit_seq==grant.seq)
    again:=executor.fence_accept(&x.host,&pending,reply.body,f.owner,x.host_key,1200)
    testing.expect(t,!again.current)
    testing.expect_value(t,executor.action(&x.host,grant.body,f.owner,1200,proof).code,"ok")
}

@(test)
owner_execution_signed_fence_rejects_substitution_revocation_and_expiry :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x:=execution_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
    testing.expect_value(t,execution_prepare_start(&f.store,x.prepare,x.lease,f.owner,1000).code,"ok")
    x.receipt=execution_test_prepare(t,x)
    if !testing.expect_value(t,execution_test_commit(x).code,"ok") do return
    claim:=execution_test_claim(t,f)
    pending:=execution_test_challenge(t,x,claim);defer executor.fence_challenge_destroy(&pending)
    reply:=execution_test_fence_reply(x,pending.request)
    if !testing.expect_value(t,reply.code,"ok") do return
    for pair in ([9][2]string{{"account_id","other"},{"executor_bridge_id","other"},{"owner_bridge_id","other"},
        {"chain_id","other"},{"reservation_id","other"},{"executor_incarnation","2"},{"owner_incarnation","2"},
        {"intent_id",strings.repeat("b",64,context.temp_allocator)},{"claim_attempt","2"}}) {
        request,_:=contracts.executor_parse(pending.request,"fence_request")
        request[pair[0]]=json.String(pair[1])
        raw:=execution_test_signed(f,request,"fence_request",true)
        testing.expect(t,execution_test_fence_reply(x,raw).code!="ok",pair[0])
    }
    request,_:=contracts.executor_parse(pending.request,"fence_request")
    request["action_digest"]=json.String(strings.repeat("b",64,context.temp_allocator))
    testing.expect_value(t,execution_test_fence_reply(x,execution_test_signed(f,request,"fence_request",true)).code,"invalid_scope")
    revoked:=x.host_key;revoked.revoked=true
    denied:=execution_fence_reply(&f.store,pending.request,revoked,f.owner,1,"head",1200,{&f.owner_priv,execution_test_sign})
    testing.expect_value(t,denied.code,"invalid_scope")
    denied=execution_fence_reply(&f.store,pending.request,x.host_key,f.owner,2,"head",1200,{&f.owner_priv,execution_test_sign})
    testing.expect_value(t,denied.code,"invalid_scope")
    denied=execution_fence_reply(&f.store,pending.request,x.host_key,f.owner,1,"other",1200,{&f.owner_priv,execution_test_sign})
    testing.expect_value(t,denied.code,"invalid_scope")
    revoked=f.owner;revoked.revoked=true
    denied_proof:=executor.fence_accept(&x.host,&pending,reply.body,revoked,x.host_key,1200)
    testing.expect(t,!denied_proof.current && !pending.consumed)
    for now in ([3]i64{1149,3000,10000}) {
        testing.expect(t,execution_test_fence_reply(x,pending.request,now).code!="ok")
        timed:=pending
        proof:=executor.fence_accept(&x.host,&timed,reply.body,f.owner,x.host_key,now)
        testing.expect(t,!proof.current)
        if now>=3000 {
            testing.expect(t,timed.consumed)
            proof=executor.fence_accept(&x.host,&timed,reply.body,f.owner,x.host_key,1200)
            testing.expect(t,!proof.current,"clock rollback cannot revive an expired exchange")
        }
    }
    response,_:=contracts.executor_parse(reply.body,"fence_reply")
    response["owner_commit_seq"]=json.String("999")
    forged:=execution_test_signed(f,response,"fence_reply")
    proof:=executor.fence_accept(&x.host,&pending,forged,f.owner,x.host_key,1200)
    testing.expect(t,!proof.current && !pending.consumed)
    // A validly signed response from the wrong domain cannot pass verification.
    testing.expect(t,!contracts.executor_verify("fence_reply",response,x.host_key))
}

@(test)
owner_execution_signed_fence_rejects_retired_claim_and_both_runtime_restarts :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x:=execution_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
    testing.expect_value(t,execution_prepare_start(&f.store,x.prepare,x.lease,f.owner,1000).code,"ok")
    x.receipt=execution_test_prepare(t,x)
    if !testing.expect_value(t,execution_test_commit(x).code,"ok") do return
    claim:=execution_test_claim(t,f)
    pending:=execution_test_challenge(t,x,claim);defer executor.fence_challenge_destroy(&pending)
    reply:=execution_test_fence_reply(x,pending.request)
    if !testing.expect_value(t,reply.code,"ok") do return
    testing.expect(t,intent_result(&f.store,claim,false,"lost_reply",1200))
    testing.expect_value(t,execution_test_fence_reply(x,pending.request).code,"invalid_scope")
    retry_claims,retried:=intent_claim_due(&f.store,2200)
    testing.expect(t,retried && len(retry_claims)>0)
    testing.expect_value(t,execution_test_fence_reply(x,pending.request,2200).code,"invalid_scope")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,execution_test_fence_reply(x,pending.request).code,"invalid_scope")
    executor.close(&x.host);testing.expect(t,executor.open(&x.host,x.path,"account","executor","operator"))
    proof:=executor.fence_accept(&x.host,&pending,reply.body,f.owner,x.host_key,1200)
    testing.expect(t,!proof.current && !pending.consumed)
}

@(test)
owner_execution_signed_fence_monotonic_timeout_survives_frozen_wall_clock :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x:=execution_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
    testing.expect_value(t,execution_prepare_start(&f.store,x.prepare,x.lease,f.owner,1000).code,"ok")
    x.receipt=execution_test_prepare(t,x)
    if !testing.expect_value(t,execution_test_commit(x).code,"ok") do return
    claim:=execution_test_claim(t,f)
    pending:=execution_test_challenge(t,x,claim);defer executor.fence_challenge_destroy(&pending)
    request,_:=contracts.executor_parse(pending.request,"fence_request")
    request["request_expires_ms"]=json.String("1201")
    delete(pending.request)
    pending.request=strings.clone(execution_test_signed(f,request,"fence_request",true))
    reply:=execution_test_fence_reply(x,pending.request)
    if !testing.expect_value(t,reply.code,"ok") do return
    time.sleep(75*time.Millisecond)
    proof:=executor.fence_accept(&x.host,&pending,reply.body,f.owner,x.host_key,1200)
    testing.expect(t,!proof.current && pending.consumed)
}
@(test)
owner_execution_prepare_and_atomic_grant_activation_outbox :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x:=execution_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
    start:=execution_prepare_start(&f.store,x.prepare,x.lease,f.owner,1000)
    if !testing.expect_value(t,start.code,"ok") do return
    rows,ok:=query(f.store.db,"SELECT (SELECT count(*) FROM local_leases),(SELECT count(*) FROM runtime_intents WHERE kind='executor.activate')")
    testing.expect(t,ok);testing.expect_value(t,encode(rows),encode([1][2]string{{"0","0"}}))
    x.receipt=execution_test_prepare(t,x)
    grant:=execution_test_commit(x)
    if !testing.expect_value(t,grant.code,"ok") do return
    a,parsed:=contracts.executor_parse(grant.body,"action")
    testing.expect(t,parsed && contracts.executor_verify("action",a,f.owner))
    testing.expect_value(t,field(a,"owner_commit_seq"),fmt.tprintf("%d",grant.seq))
    testing.expect_value(t,field(a,"hard_ms"),"3601000")
    rows,ok=query(f.store.db,"SELECT expires_ms,hard_ms,(SELECT count(*) FROM runtime_intents WHERE kind='executor.activate') FROM local_leases")
    testing.expect(t,ok);testing.expect_value(t,encode(rows),encode([1][3]string{{"901100","3601000","1"}}))
    activated:=executor.action(&x.host,grant.body,f.owner,1100,{true,field(a,"prepare_digest"),1,grant.seq})
    testing.expect_value(t,activated.code,"ok")
    replay:=execution_test_commit(x,4000)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==grant.body)
    rows,ok=query(f.store.db,"SELECT (SELECT count(*) FROM local_leases),(SELECT count(*) FROM runtime_intents WHERE kind='executor.activate'),(SELECT count(*) FROM local_events WHERE kind='lease.claim')")
    testing.expect(t,ok);testing.expect_value(t,encode(rows),encode([1][3]string{{"1","1","1"}}))
}
@(test)
owner_execution_lost_prepare_reply_requires_fresh_exact_query :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x:=execution_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
    testing.expect_value(t,execution_prepare_start(&f.store,x.prepare,x.lease,f.owner,1000).code,"ok")
    _=execution_test_prepare(t,x)
    x.receipt=execution_test_prepare(t,x,1100)
    testing.expect_value(t,execution_test_commit(x,1200).code,"reservation_not_current")
    q,r:=execution_test_query(t,x,1200)
    changed,_:=contracts.executor_parse(q,"action");changed["reservation_id"]=json.String("other")
    wrong:=execution_test_signed(f,changed,"action")
    testing.expect_value(t,execution_test_commit(x,1200,wrong,r).code,"reservation_not_current")
    testing.expect_value(t,execution_test_commit(x,1200,q,r).code,"ok")
}
@(test)
owner_execution_commit_failure_rolls_back_grant_receipt_event_and_intent :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x:=execution_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
    testing.expect_value(t,execution_prepare_start(&f.store,x.prepare,x.lease,f.owner,1000).code,"ok")
    x.receipt=execution_test_prepare(t,x)
    testing.expect(t,exec(f.store.db,"CREATE TABLE fault_exec_parent(id INTEGER PRIMARY KEY); CREATE TABLE fault_exec_ref(id INTEGER REFERENCES fault_exec_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER fault_exec AFTER UPDATE ON owner_execution_journal BEGIN INSERT INTO fault_exec_ref VALUES(1); END"))
    testing.expect_value(t,execution_test_commit(x).code,"storage_error")
    rows,ok:=query(f.store.db,"SELECT state,(SELECT count(*) FROM local_leases),(SELECT count(*) FROM command_receipts WHERE operation_id='claim'),(SELECT count(*) FROM local_events WHERE kind='lease.claim'),(SELECT count(*) FROM runtime_intents WHERE kind='executor.activate') FROM owner_execution_journal")
    testing.expect(t,ok);testing.expect_value(t,encode(rows),encode([1][5]string{{"preparing","0","0","0","0"}}))
    testing.expect(t,exec(f.store.db,"DROP TRIGGER fault_exec"))
    testing.expect_value(t,execution_test_commit(x).code,"ok")
}
@(test)
owner_execution_prepare_replay_scope_and_stale_assignment_revalidation :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x:=execution_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
    first:=execution_prepare_start(&f.store,x.prepare,x.lease,f.owner,1000)
    testing.expect_value(t,first.code,"ok")
    replay:=execution_prepare_start(&f.store,x.prepare,x.lease,f.owner,4000)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.seq==first.seq)
    changed,_:=contracts.executor_parse(x.prepare,"prepare");changed["slot_id"]=json.String("slot2")
    testing.expect_value(t,execution_prepare_start(&f.store,execution_test_signed(f,changed,"prepare"),x.lease,f.owner,1000).code,"operation_conflict")
    x.receipt=execution_test_prepare(t,x)
    wrong:=x.host_key;wrong.revoked=true
    testing.expect_value(t,execution_prepare_commit(&f.store,"reservation",x.receipt,f.owner,wrong,1100,{&f.owner_priv,execution_test_sign}).code,"invalid_scope")
    testing.expect(t,exec(f.store.db,"UPDATE local_fleet SET enabled=0,configuration_revision=configuration_revision+1"))
    testing.expect_value(t,execution_test_commit(x).code,"invalid_scope")
}
@(test)
owner_execution_restart_recovers_saved_prepare_without_spending_new_grant :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x:=execution_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
    testing.expect_value(t,execution_prepare_start(&f.store,x.prepare,x.lease,f.owner,1000).code,"ok")
    _=execution_test_prepare(t,x)
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    x.receipt=execution_test_prepare(t,x,1100)
    q,r:=execution_test_query(t,x,1200)
    grant:=execution_test_commit(x,1200,q,r)
    testing.expect_value(t,grant.code,"ok")
    a,valid:=contracts.executor_parse(grant.body,"action")
    testing.expect(t,valid);testing.expect_value(t,field(a,"owner_incarnation"),"2")
    testing.expect_value(t,executor.action(&x.host,grant.body,f.owner,1200,{true,field(a,"prepare_digest"),2,grant.seq}).code,"ok")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    replay:=execution_test_commit(x,4000)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==grant.body)
    rows,ok:=query(f.store.db,"SELECT (SELECT count(*) FROM local_leases),(SELECT count(*) FROM runtime_intents WHERE kind='executor.activate')")
    testing.expect(t,ok);testing.expect_value(t,encode(rows),encode([1][2]string{{"1","1"}}))
}
@(test)
owner_execution_expired_prepare_never_grants_or_enqueues_activation :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x:=execution_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
    testing.expect_value(t,execution_prepare_start(&f.store,x.prepare,x.lease,f.owner,1000).code,"ok")
    x.receipt=execution_test_prepare(t,x)
    testing.expect_value(t,execution_test_commit(x,3000).code,"expired")
    rows,ok:=query(f.store.db,"SELECT (SELECT count(*) FROM local_leases),(SELECT count(*) FROM runtime_intents WHERE kind='executor.activate')")
    testing.expect(t,ok);testing.expect_value(t,encode(rows),encode([1][2]string{{"0","0"}}))
}

@(test)
owner_execution_fresh_fence_rejects_changed_claim_expiry_and_retired_grant :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x:=execution_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
    testing.expect_value(t,execution_prepare_start(&f.store,x.prepare,x.lease,f.owner,1000).code,"ok")
    pending,read:=execution_preparations(&f.store)
    testing.expect(t,read && len(pending)==1 && pending[0].prepare==x.prepare && pending[0].lease_command==x.lease)
    _,read=execution_preparations(&f.store,"",21);testing.expect(t,!read)
    x.receipt=execution_test_prepare(t,x)
    grant:=execution_test_commit(x);testing.expect_value(t,grant.code,"ok")
    pending,read=execution_preparations(&f.store);testing.expect(t,read && len(pending)==0)
    claims,ok:=intent_claim_due(&f.store,1200)
    if !testing.expect(t,ok) do return
    claim:Intent_Claim
    for item in claims do if item.kind=="executor.activate" do claim=item
    if !testing.expect(t,claim.id!="") do return
    current,digest,inc,seq:=execution_activation_fence(&f.store,claim,1200)
    testing.expect(t,current && inc==1 && seq==grant.seq)
    a,_:=contracts.executor_parse(grant.body,"action")
    testing.expect_value(t,digest,field(a,"prepare_digest"))
    changed:=claim;changed.destination="other_executor"
    current,_,_,_=execution_activation_fence(&f.store,changed,1200);testing.expect(t,!current)
    changed=claim;changed.fence="{}"
    current,_,_,_=execution_activation_fence(&f.store,changed,1200);testing.expect(t,!current)
    current,_,_,_=execution_activation_fence(&f.store,claim,999);testing.expect(t,!current)
    current,_,_,_=execution_activation_fence(&f.store,claim,3000);testing.expect(t,!current)
    testing.expect(t,expire_leases(&f.store,901101))
    current,_,_,_=execution_activation_fence(&f.store,claim,901101);testing.expect(t,!current)
}

@(test)
owner_execution_v24_upgrade_preserves_identity_and_rolls_back_collision :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    before,ok:=query(f.store.db,"SELECT database_id,commit_seq,incarnation FROM runtime_database")
    if !testing.expect(t,ok && len(before)==1) do return
    close(&f.store)
    db:DB;testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    // Reconstruct the exact historical runtime contract, retaining aggregate
    // tables and committed task/receipt rows. The new table must not survive.
    parts:=strings.split(string(MIGRATION_024),"CREATE TABLE native_record_snapshots",context.temp_allocator)
    testing.expect(t,exec(db,strings.concatenate({"PRAGMA foreign_keys=OFF; DROP TABLE owner_execution_journal;",parts[0],"UPDATE schema_migrations SET version=24; CREATE VIEW owner_execution_journal AS SELECT 1;"},context.temp_allocator)))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,read:=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations),database_id,commit_seq FROM runtime_database")
    testing.expect(t,read);testing.expect_value(t,encode(rows),encode([1][4]string{{"24","24",before[0][0],before[0][1]}}))
    testing.expect(t,exec(db,"DROP VIEW owner_execution_journal"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    rows,read=query(f.store.db,"SELECT schema_version,(SELECT version FROM schema_migrations),database_id,commit_seq FROM runtime_database")
    testing.expect(t,read);testing.expect_value(t,encode(rows),encode([1][4]string{{"25","25",before[0][0],before[0][1]}}))
}

@(test)
owner_execution_preparation_expiry_retires_without_lease_or_attempt :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x:=execution_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
    testing.expect_value(t,execution_prepare_start(&f.store,x.prepare,x.lease,f.owner,1000).code,"ok")
    x.receipt=execution_test_prepare(t,x)
    testing.expect(t,execution_expire_preparations(&f.store,2999))
    rows,ok:=query(f.store.db,"SELECT state FROM owner_execution_journal")
    testing.expect(t,ok);testing.expect_value(t,rows[0][0],"preparing")
    testing.expect(t,execution_expire_preparations(&f.store,3000))
    testing.expect_value(t,execution_test_commit(x,3000).code,"retired")
    rows,ok=query(f.store.db,"SELECT state,(SELECT count(*) FROM local_leases),(SELECT count(*) FROM local_work_attempts),(SELECT count(*) FROM runtime_intents WHERE kind='executor.activate') FROM owner_execution_journal")
    testing.expect(t,ok);testing.expect_value(t,encode(rows),encode([1][4]string{{"retired","0","0","0"}}))
    before,_:=query(f.store.db,"SELECT commit_seq FROM runtime_database")
    testing.expect(t,execution_expire_preparations(&f.store,3000))
    after,_:=query(f.store.db,"SELECT commit_seq FROM runtime_database")
    testing.expect_value(t,encode(after),encode(before))
    state,read:=executor.query(x.host.db,"SELECT state FROM executor_reservations")
    testing.expect(t,read);testing.expect(t,state[0][0]=="prepared","owner retirement cannot refund executor resources")
}
