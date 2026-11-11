#+feature dynamic-literals
package executor_local
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"

notification_fixture :: proc(t:^testing.T,f:^Fixture)->(json.Object,string,string) {
    x:=bootstrap_fixture(t,f)
    testing.expect_value(t,accept_bootstrap(&f.store,x.raw,x.body,x.action,f.owner1.public,1300,proof(x.a)).code,"ok")
    intent,_:=take_intent(&f.store,1300)
    testing.expect(t,begin_dispatch(&f.store,intent,1300))
    testing.expect(t,observe_child(&f.store,intent.reservation,{intent.instance,intent.launch_key,f.store.incarnation,true}))
    n:=make(json.Object,context.temp_allocator)
    for entry in contracts.executor_schema("notification") do n[entry.name]=x.b[entry.name]
    message:="checkpoint € 日本語 😀\n"
    set(n,"intent_id",strings.repeat("a",64,context.temp_allocator));set(n,"owner_commit_seq","17")
    set(n,"message_digest",contracts.owner_payload_digest(message));set(n,"issued_ms","1400");set(n,"request_expires_ms","1900")
    raw:=signed(n,"notification",&f.owner1)
    n,_=contracts.executor_parse(raw,"notification")
    return n,raw,message
}
@(test)
executor_notification_ticket_journal_never_relabels_unknown_effect :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    n,raw,message:=notification_fixture(t,f)
    key:=f.owner1.public
    testing.expect(t,notification_current(&f.store,n,message,key,1400))
    testing.expect_value(t,notification_stage(&f.store,n,message,key,"ticket",1400).code,"not_found")
    testing.expect_value(t,notification_record(&f.store,n,message,key,"dispatch","{}",1400).code,"ticket_required")
    ticket:=encode(Notification_Ticket{"42","opaque-ticket","validated-profile",raw,message})
    testing.expect(t,exec(f.store.db,"CREATE TABLE notice_parent(id INTEGER PRIMARY KEY); CREATE TABLE notice_probe(id INTEGER REFERENCES notice_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER notice_failure AFTER INSERT ON executor_receipts WHEN NEW.kind='notification.ticket' BEGIN INSERT INTO notice_probe VALUES(1); END;"))
    testing.expect_value(t,notification_record(&f.store,n,message,key,"ticket",ticket,1400).code,"storage_error")
    testing.expect_value(t,notification_stage(&f.store,n,message,key,"ticket",1400).code,"not_found")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER notice_failure"))
    testing.expect_value(t,notification_record(&f.store,n,message,key,"ticket",ticket,1400).code,"ok")
    another:=encode(Notification_Ticket{"43","replacement-ticket","validated-profile",raw,message})
    replay:=notification_record(&f.store,n,message,key,"ticket",another,1400)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==ticket,"first exact PID/ticket is immutable")
    testing.expect_value(t,notification_record(&f.store,n,message,key,"dispatch","{}",1400).code,"ok")
    testing.expect(t,notification_record(&f.store,n,message,key,"dispatch","{}",1400).replay)
    set(n,"issued_ms","1450")
    renewed_raw:=signed(n,"notification",&f.owner1);renewed,_:=contracts.executor_parse(renewed_raw,"notification")
    testing.expect_value(t,notification_stage(&f.store,renewed,message,key,"ticket",1450).body,ticket)
    changed_message:="replacement"
    set(renewed,"message_digest",contracts.owner_payload_digest(changed_message))
    changed_raw:=signed(renewed,"notification",&f.owner1);changed,_:=contracts.executor_parse(changed_raw,"notification")
    testing.expect_value(t,notification_stage(&f.store,changed,changed_message,key,"ticket",1450).code,"operation_conflict")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    testing.expect_value(t,notification_stage(&f.store,n,message,key,"ticket",1450).code,"invalid_scope")
    records,ok:=query(f.store.db,"SELECT result_json FROM executor_receipts WHERE kind='notification.ticket'")
    testing.expect(t,ok && len(records)==1 && records[0][0]==ticket,"restart retains original evidence without preparing another effect")
}
@(test)
executor_notification_fence_consumes_one_action_scoped_nonce :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    n,raw,message:=notification_fixture(t,f)
    pending,ready:=notification_challenge(&f.store,raw,message,1,f.owner1.public,f.operator.public,1400,{&f.operator,sign_receipt})
    if !testing.expect(t,ready) do return
    defer fence_challenge_destroy(&pending)
    q,_:=contracts.executor_parse(pending.request,"notification_fence_request")
    r:=make(json.Object,context.temp_allocator)
    for entry in contracts.executor_schema("notification_fence_reply") do r[entry.name]=q[entry.name]
    digest,_:=contracts.executor_digest("notification_fence_request",q)
    set(r,"request_digest",digest);set(r,"prepare_digest",field(n,"prepare_digest"));set(r,"owner_commit_seq",field(n,"owner_commit_seq"))
    set(r,"checked_ms","1450");set(r,"key_id",f.owner1.public.key_id)
    reply:=signed(r,"notification_fence_reply",&f.owner1)
    pending.started=time.tick_now() // a loaded run must not hit the monotonic expiry
    proof:=notification_fence_accept(&f.store,&pending,reply,message,f.owner1.public,f.operator.public,1450)
    testing.expect(t,proof.current && pending.consumed)
    testing.expect(t,!notification_fence_accept(&f.store,&pending,reply,message,f.owner1.public,f.operator.public,1450).current)
    testing.expect(t,!contracts.executor_verify("fence_request",q,f.operator.public))
}

notification_journal_sequence :: proc(t:^testing.T,s:^Store)->i64 {
    rows,ok:=query(s.db,"SELECT sequence FROM executor_native_journal WHERE singleton=1")
    if !testing.expect(t,ok && len(rows)==1) do return -1
    return number(rows[0][0])
}

// R5: an owner task.hold notice settles each stage exactly once under the
// native-journal sequence triggers (migrations 011-015). A lost result write
// rolls back with the journal unchanged; the retry after loss records one
// result and every later exact or re-signed replay is read-only.
@(test)
executor_notification_hold_notice_settles_once_under_native_journal :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    n,raw,_:=notification_fixture(t,f)
    key:=f.owner1.public
    // The exact one-line notice the owner task.hold producer emits.
    message:=fmt.tprintf("[owner-local] task.hold on task %s; inspect owner-local runtime.",field(n,"task_id"))
    set(n,"message_digest",contracts.owner_payload_digest(message))
    raw=signed(n,"notification",&f.owner1);n,_=contracts.executor_parse(raw,"notification")
    triggers,listed:=query(f.store.db,"SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name GLOB 'native_journal_executor_receipts_*'")
    if !testing.expect(t,listed && triggers[0][0]=="3","receipt inserts/updates/deletes advance the native journal") do return
    s0:=notification_journal_sequence(t,&f.store)
    ticket:=encode(Notification_Ticket{"42","opaque-ticket","validated-profile",raw,message})
    testing.expect_value(t,notification_record(&f.store,n,message,key,"ticket",ticket,1400).code,"ok")
    s1:=notification_journal_sequence(t,&f.store)
    testing.expect_value(t,notification_record(&f.store,n,message,key,"dispatch",`{"esc_written":"1"}`,1400).code,"ok")
    s2:=notification_journal_sequence(t,&f.store)
    testing.expect(t,s1>s0 && s2>s1,"each committed stage advances the journal")
    // Lose only result persistence after the physical write.
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER r5_lost_result BEFORE INSERT ON executor_receipts WHEN NEW.kind='notification.result' BEGIN SELECT RAISE(ABORT,'lost result'); END"))
    testing.expect_value(t,notification_record(&f.store,n,message,key,"result",`{"status":"delivered"}`,1400).code,"storage_error")
    testing.expect_value(t,notification_journal_sequence(t,&f.store),s2)
    testing.expect_value(t,notification_stage(&f.store,n,message,key,"result",1400).code,"not_found")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER r5_lost_result"))
    result:=`{"status":"delivered","message_bytes_written":"66"}`
    settled:=notification_record(&f.store,n,message,key,"result",result,1450)
    testing.expect(t,settled.code=="ok" && !settled.replay && settled.body==result)
    s3:=notification_journal_sequence(t,&f.store)
    testing.expect(t,s3>s2,"the retry after loss commits one result")
    // Exact retry, a different claimed body and a re-signed transport copy are
    // all read-only replays of the first stored result.
    again:=notification_record(&f.store,n,message,key,"result",`{"status":"partial"}`,1450)
    testing.expect(t,again.code=="ok" && again.replay && again.body==result)
    set(n,"issued_ms","1460")
    resigned_raw:=signed(n,"notification",&f.owner1);resigned,_:=contracts.executor_parse(resigned_raw,"notification")
    replay:=notification_record(&f.store,resigned,message,key,"result",result,1460)
    testing.expect(t,replay.code=="ok" && replay.replay && replay.body==result)
    testing.expect_value(t,notification_stage(&f.store,resigned,message,key,"result",1460).body,result)
    testing.expect_value(t,notification_journal_sequence(t,&f.store),s3)
    rows,ok:=query(f.store.db,"SELECT kind,count(*) FROM executor_receipts WHERE kind LIKE 'notification.%' GROUP BY kind ORDER BY kind")
    testing.expect(t,ok && len(rows)==3,"one receipt per stage")
    for row in rows do testing.expect_value(t,row[1],"1")
}
