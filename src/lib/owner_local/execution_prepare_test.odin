#+feature dynamic-literals
package owner_local
import "core:encoding/json"
import "core:fmt"
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
    testing.expect(t,execution_expire_preparations(&f.store,31000))
    retry=execution_prepare_assignment(&f.store,"chain","task",f.owner,31001,sign)
    testing.expect(t,retry.code=="ok" && retry.replay && retry.body=="retired")
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
