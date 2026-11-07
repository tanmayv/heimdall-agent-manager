#+feature dynamic-literals
package owner_local
import "core:encoding/json"
import "core:testing"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"

@(test)
owner_hold_notification_keeps_original_child_and_grants_no_work :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x,activation:=execution_bootstrap_fixture(t);defer execution_test_destroy(x);f:=x.owner
    sign:=Signer{&f.owner_priv,execution_test_sign}
    testing.expect_value(t,execution_bootstrap(&f.store,activation,"Worker","","[]",f.owner,1200,sign).code,"ok")
    revisions,_:=query(f.store.db,"SELECT revision FROM tasks WHERE task_id='task'")
    payload:=encode(doc(map[string]string{"body_cipher"=cipher(f,"checkpoint")}))
    raw:=command(f,"task.hold","notification_hold","task",payload,revisions[0][0])
    before,_:=query(f.store.db,"SELECT (SELECT count(*) FROM local_leases),(SELECT count(*) FROM local_work_attempts)")
    testing.expect_value(t,invoke(f,raw,payload,1300).code,"ok")
    claims,ok:=intent_claim_due(&f.store,1300,20,.Executor)
    diagnostic,_:=query(f.store.db,"SELECT (SELECT group_concat(kind) FROM runtime_intents),(SELECT group_concat(child_json) FROM control_notices),(SELECT child_json FROM owner_execution_journal),(SELECT count(*) FROM local_leases WHERE retired_seq IS NULL)")
    if !testing.expectf(t,ok && len(claims)==1 && claims[0].kind=="executor.notification","claims %v; source %s",claims,encode(diagnostic)) do return
    notice:=claims[0]
    testing.expect_value(t,notice.fence,x.prepare)
    testing.expect_value(t,notice.destination,"executor")
    owner_claims,claimed:=intent_claim_due(&f.store,1300,20,.Owner)
    testing.expect(t,claimed)
    for claim in owner_claims do testing.expect(t,claim.kind!="checkpoint","remote checkpoint has only one consumer")
    result:=execution_notification(&f.store,notice,f.owner,1400,sign)
    if !testing.expect_value(t,result.code,"ok") do return
    value,_:=contracts.owner_content_document(result.body);bundle,_:=value.(json.Object)
    testing.expect_value(t,field(bundle,"message"),"[owner-local] task.hold on task task; inspect owner-local runtime.")
    n,parsed:=contracts.executor_parse(field(bundle,"notification"),"notification")
    testing.expect(t,parsed && contracts.executor_verify("notification",n,f.owner))
    b_rows,_:=query(f.store.db,"SELECT document FROM owner_execution_bootstraps")
    b,_:=contracts.executor_parse(b_rows[0][0],"bootstrap")
    testing.expect(t,contracts.executor_notification_matches(n,b,field(bundle,"message"),f.owner,1400))
    testing.expect_value(t,field(n,"intent_id"),notice.id)
    after,_:=query(f.store.db,"SELECT (SELECT count(*) FROM local_leases),(SELECT count(*) FROM local_work_attempts)")
    testing.expect_value(t,encode(before),encode(after))
    changed:=notice;changed.destination="replacement_executor"
    testing.expect_value(t,execution_notification(&f.store,changed,f.owner,1400,sign).code,"no_current_target")
    q:=make(json.Object,context.temp_allocator)
    for entry in contracts.executor_schema("notification_fence_request") do q[entry.name]=n[entry.name]
    digest,_:=contracts.executor_digest("notification",n)
    q["notification"]=json.String(field(bundle,"notification"));q["action_digest"]=json.String(digest)
    q["claim_attempt"]=json.String(fmt.tprintf("%d",notice.attempt));q["challenge"]=json.String(strings.repeat("b",64,context.temp_allocator))
    q["issued_ms"]=json.String("1400");q["request_expires_ms"]=json.String("1700")
    q["key_id"]=json.String(x.host_key.key_id);q["signature"]=json.String(strings.repeat("0",128,context.temp_allocator))
    challenge:=execution_test_signed(f,q,"notification_fence_request",true)
    directory,_:=query(f.store.db,"SELECT directory_version,directory_hash FROM runtime_database")
    fence:=execution_notification_fence_reply(&f.store,challenge,x.host_key,f.owner,number(directory[0][0]),directory[0][1],1450,sign)
    if !testing.expect_value(t,fence.code,"ok") do return
    request,_:=contracts.executor_parse(challenge,"notification_fence_request")
    reply,_:=contracts.executor_parse(fence.body,"notification_fence_reply")
    testing.expect(t,contracts.executor_notification_fence_matches(reply,request,n,f.owner,x.host_key,1450))
    revisions,_=query(f.store.db,"SELECT revision FROM tasks WHERE task_id='task'")
    release:=command(f,"task.release","notification_release","task",payload,revisions[0][0])
    testing.expect_value(t,invoke(f,release,payload,1500).code,"ok")
    testing.expect_value(t,execution_notification(&f.store,notice,f.owner,1500,sign).code,"no_current_target")
    testing.expect_value(t,execution_notification_fence_reply(&f.store,challenge,x.host_key,f.owner,number(directory[0][0]),directory[0][1],1500,sign).code,"no_current_target")
}
