#+feature dynamic-literals
package owner_local
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"

execution_stop_test_fixture :: proc(t:^testing.T)->^Execution_Test {
    x:=execution_test_fixture(t);f:=x.owner
    config:=encode(doc(map[string]string{"configuration_revision"="1","author_agent_id"="author","reviewer_agent_id"="reviewer",
        "reviewer_instance_id"="review_instance","directory_id"="directory","merge_policy"="none","repository"="",
        "worktree"="","source_branch"="","target_branch"="","base_head"=""}))
    configured:=execute(&f.store,command(f,"lifecycle.configure","config","task",config,"2"),config,"",
        f.creator,f.owner,1,"head",1000,&f.kr,{&f.owner_priv,test_sign},{},Lifecycle_Proof{lease_child(),lifecycle_reviewer(),true})
    testing.expect_value(t,configured.code,"ok")
    lifecycle_edit(t,f,"1","3")
    x.lease=lease_request(f,lease_child(),"lease.claim","claim","lease","","4")
    testing.expect_value(t,execution_prepare_start(&f.store,x.prepare,x.lease,f.owner,1000).code,"ok")
    x.receipt=execution_test_prepare(t,x)
    testing.expect_value(t,execution_test_commit(x).code,"ok")
    _=execution_test_claim(t,f)
    return x
}

@(test)
owner_remote_stop_is_executor_routed_and_durable_across_query_stop_restarts :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    for handoff in ([2]bool{false,true}) {
        x:=execution_stop_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
        sign:=Signer{&f.owner_priv,execution_test_sign}
        if handoff {
            caps,_:=query(f.store.db,"SELECT capability_json FROM local_leases WHERE lease_id='lease'")
            payload:=encode(doc(map[string]string{"requirements_revision"="1","summary"="Remote handoff","next_steps"="Continue later"}))
            raw:=lifecycle_raw(f,lease_child(),"lease.handoff","stop_handoff",payload,caps[0][0])
            testing.expect_value(t,execute_lifecycle(&f.store,raw,payload,caps[0][0],lease_child(),f.owner,1300,sign).code,"ok")
        } else {
            revisions,_:=query(f.store.db,"SELECT revision FROM tasks WHERE task_id='task'")
            payload:=encode(doc(map[string]string{"body_cipher"=cipher(f,"Cancel exact remote lease")}))
            raw:=command(f,"task.cancel","stop_cancel","task",payload,revisions[0][0])
            testing.expect_value(t,invoke(f,raw,payload,1300).code,"ok")
        }
        claims,ok:=intent_claim_due(&f.store,1300,20,.Executor)
        if !testing.expect(t,ok && len(claims)==1 && execution_stop_kind(claims[0].kind)) do return
        c:=claims[0]
        testing.expect_value(t,c.destination,"executor")
        local,read:=intent_claim_due(&f.store,1300,20,.Owner);testing.expect(t,read)
        for claim in local do testing.expect(t,claim.kind!="stop","remote stop has no local consumer")
        query_request:=execution_stop_request(&f.store,c,f.owner,1400,sign)
        if !testing.expect_value(t,query_request.code,"ok") do return
        same:=execution_stop_request(&f.store,c,f.owner,1450,sign)
        testing.expect(t,same.code=="ok" && same.body==query_request.body,"lost query reply reuses immutable bytes")
        q,_:=contracts.executor_parse(query_request.body,"action")
        qr:=executor.action(&x.host,query_request.body,f.owner,1450)
        testing.expect_value(t,qr.code,"ok")
        receipt,signed:=executor.seal_receipt(&x.host,q,"action",qr,{&f.creator_priv,execution_test_seal})
        testing.expect(t,signed)
        testing.expect_value(t,execution_stop_accept(&f.store,c,query_request.body,receipt,x.host_key,1450).code,"accepted")
        stopped:=execution_stop_request(&f.store,c,f.owner,1500,sign)
        testing.expect_value(t,stopped.code,"ok")
        stop,_:=contracts.executor_parse(stopped.body,"action")
        testing.expect_value(t,field(stop,"method"),"stop")
        wrong:=x.host_key;wrong.principal_id="wrong_executor"
        testing.expect_value(t,execution_stop_accept(&f.store,c,stopped.body,receipt,wrong,1500).code,"invalid_scope")
        accepted:=executor.action(&x.host,stopped.body,f.owner,1500)
        testing.expect_value(t,accepted.code,"ok")
        stop_receipt,sealed:=executor.seal_receipt(&x.host,stop,"action",accepted,{&f.creator_priv,execution_test_seal})
        testing.expect(t,sealed)
        final:=execution_stop_accept(&f.store,c,stopped.body,stop_receipt,x.host_key,1500)
        testing.expect_value(t,final.code,"released") // prepared reservation: no child ever existed
        testing.expect(t,intent_result(&f.store,c,true,stop_receipt,1500))
        rows,_:=executor.query(x.host.db,"SELECT count(*) FROM executor_live_resources")
        testing.expect_value(t,rows[0][0],"0")
        close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
        retained,retained_ok:=query(f.store.db,"SELECT count(*) FROM owner_execution_stop_steps WHERE intent_id=?",c.id)
        testing.expect(t,retained_ok && retained[0][0]=="2")
        testing.expect(t,!exec(f.store.db,"UPDATE owner_execution_stop_steps SET request='{}'"),"request bytes are immutable")
    }
}

@(test)
owner_remote_stop_requeries_after_renewal_race_and_refuses_wrong_or_revoked_observer :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x:=execution_stop_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
    sign:=Signer{&f.owner_priv,execution_test_sign}
    activations,_:=query(f.store.db,"SELECT activation_json FROM owner_execution_journal")
    action,_:=contracts.executor_parse(activations[0][0],"action")
    proof:=executor.Current_Owner_Fence{true,field(action,"prepare_digest"),1,contracts.executor_number(action,"owner_commit_seq")}
    testing.expect_value(t,executor.action(&x.host,activations[0][0],f.owner,1200,proof).code,"ok")
    launch,taken:=executor.take_intent(&x.host,1200);testing.expect(t,taken)
    testing.expect(t,executor.observe_child(&x.host,launch.reservation,{launch.instance,launch.launch_key,x.host.incarnation,true}))
    revisions,_:=query(f.store.db,"SELECT revision FROM tasks WHERE task_id='task'")
    payload:=encode(doc(map[string]string{"body_cipher"=cipher(f,"Cancel remote")}))
    testing.expect_value(t,invoke(f,command(f,"task.cancel","stop_race","task",payload,revisions[0][0]),payload,1300).code,"ok")
    claims,ok:=intent_claim_due(&f.store,1300,20,.Executor)
    if !testing.expect(t,ok && len(claims)==1) do return
    c:=claims[0]
    first:=execution_stop_request(&f.store,c,f.owner,1400,sign)
    q,_:=contracts.executor_parse(first.body,"action")
    result:=executor.action(&x.host,first.body,f.owner,1400)
    receipt,signed:=executor.seal_receipt(&x.host,q,"action",result,{&f.creator_priv,execution_test_seal});testing.expect(t,signed)
    testing.expect_value(t,execution_stop_accept(&f.store,c,first.body,receipt,x.host_key,1400).code,"accepted")
    stale:=execution_stop_request(&f.store,c,f.owner,1450,sign)
    renew:=make(json.Object,context.temp_allocator)
    for k,v in action do renew[k]=v
    renew["method"]=json.String("heartbeat");renew["operation_id"]=json.String("pending_renew_race")
    renew["deadline_version"]=json.String("2")
    testing.expect_value(t,executor.action(&x.host,execution_test_signed(f,renew,"action"),f.owner,1450,proof).code,"ok")
    testing.expect_value(t,executor.action(&x.host,stale.body,f.owner,1500).code,"stale_deadline")
    // Signed bytes remain immutable until their transport window expires;
    // timeout/restart then creates a new query, never weakens ordinary stop.
    retry:=execution_stop_request(&f.store,c,f.owner,1500,sign)
    testing.expect_value(t,retry.body,stale.body)
    late:=i64(1451)+contracts.EXECUTOR_TRANSPORT_TTL_MS
    retry=execution_stop_request(&f.store,c,f.owner,late,sign)
    next,_:=contracts.executor_parse(retry.body,"action")
    testing.expect(t,field(next,"method")=="query" && field(next,"operation_id")!=field(q,"operation_id"))
    result=executor.action(&x.host,retry.body,f.owner,late)
    receipt,signed=executor.seal_receipt(&x.host,next,"action",result,{&f.creator_priv,execution_test_seal});testing.expect(t,signed)
    revoked:=x.host_key;revoked.revoked=true
    testing.expect_value(t,execution_stop_accept(&f.store,c,retry.body,receipt,revoked,late).code,"invalid_scope")
    testing.expect_value(t,execution_stop_accept(&f.store,c,retry.body,receipt,x.host_key,late).code,"accepted")
    next_stop:=execution_stop_request(&f.store,c,f.owner,late+1,sign)
    stop,_:=contracts.executor_parse(next_stop.body,"action")
    testing.expect_value(t,field(stop,"deadline_version"),"2")
    accepted:=executor.action(&x.host,next_stop.body,f.owner,late+1)
    testing.expect_value(t,accepted.code,"ok")
    receipt,signed=executor.seal_receipt(&x.host,stop,"action",accepted,{&f.creator_priv,execution_test_seal});testing.expect(t,signed)
    testing.expect_value(t,execution_stop_accept(&f.store,c,next_stop.body,receipt,x.host_key,late+1).code,"accepted")
    rows,_:=executor.query(x.host.db,"SELECT count(*) FROM executor_live_resources")
    testing.expect(t,rows[0][0]=="1","stopping does not prove absence")
}

@(test)
owner_remote_stop_recovers_legacy_wrong_device_settlement_idempotently :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x:=execution_stop_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
    revisions,_:=query(f.store.db,"SELECT revision FROM tasks WHERE task_id='task'")
    payload:=encode(doc(map[string]string{"body_cipher"=cipher(f,"Cancel remote")}))
    testing.expect_value(t,invoke(f,command(f,"task.cancel","legacy_stop","task",payload,revisions[0][0]),payload,1300).code,"ok")
    rows,read:=query(f.store.db,"SELECT i.chain_id,i.principal_id,i.operation_id,i.commit_seq,n.child_json FROM runtime_intents i JOIN control_notices n ON n.principal_id=i.principal_id AND n.operation_id=i.operation_id WHERE i.kind LIKE 'executor.stop:%'")
    if !testing.expect(t,read && len(rows)==1) do return
    row:=rows[0]
    // Reconstruct the old outbox representation from the actual signed
    // cancellation receipt, without manufacturing a grant or child record.
    tx:Transaction
    testing.expect(t,transaction_begin(&f.store,&tx))
    testing.expect(t,intent_enqueue(&tx,{row[0],row[1],row[2],number(row[3]),"stop",payload_hash(row[4]),row[4],
        encode(doc(map[string]string{"task_id"="task","method"="task.cancel"}))}))
    testing.expect(t,transaction_commit(&tx))
    claims,claimed:=intent_claim_due(&f.store,1400,20,.Owner);testing.expect(t,claimed)
    old_id:=""
    for claim in claims {
        if claim.kind=="stop" {
            old_id=claim.id
            testing.expect(t,intent_result(&f.store,claim,true,"child_absent",1400))
        }
    }
    testing.expect(t,old_id!="")
    testing.expect(t,execution_stop_recover(&f.store))
    testing.expect(t,execution_stop_recover(&f.store))
    checked,ok:=query(f.store.db,"SELECT (SELECT count(*) FROM runtime_intents WHERE kind LIKE 'executor.stop:%'),(SELECT count(*) FROM intent_invalidations WHERE intent_id=?),(SELECT result_json FROM runtime_intents WHERE intent_id=?)",old_id,old_id)
    testing.expect(t,ok && checked[0][0]=="1" && checked[0][1]=="1" && checked[0][2]=="child_absent","old evidence retained; exact executor stop remains pending")
}

@(test)
owner_remote_stop_v27_upgrade_collision_preserves_pending_intent :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x,_:=execution_bootstrap_fixture(t);defer execution_test_destroy(x);f:=x.owner
    before,_:=query(f.store.db,"SELECT database_id,commit_seq,(SELECT activation_json FROM owner_execution_journal) FROM runtime_database")
    close(&f.store)
    db:DB;testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    sql:=string(MIGRATION_027);prefix:=sql[:strings.index(sql,"CREATE TABLE owner_execution_bootstraps")]
    testing.expect(t,exec(db,strings.concatenate({"DROP TABLE owner_execution_stop_steps;",prefix,"UPDATE schema_migrations SET version=27; CREATE VIEW owner_execution_stop_steps AS SELECT 1;"},context.temp_allocator)))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_:=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations),database_id,commit_seq,(SELECT activation_json FROM owner_execution_journal) FROM runtime_database")
    testing.expect(t,rows[0][0]=="27" && rows[0][1]=="27" && rows[0][2]==before[0][0] && rows[0][3]==before[0][1] && rows[0][4]==before[0][2])
    testing.expect(t,exec(db,"DROP VIEW owner_execution_stop_steps"));testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    rows,_=query(f.store.db,"SELECT schema_version,(SELECT version FROM schema_migrations),database_id FROM runtime_database")
    testing.expect(t,rows[0][0]=="37" && rows[0][1]=="37" && rows[0][2]==before[0][0])
}
