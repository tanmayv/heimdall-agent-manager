package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import owner "odin_test:lib/owner_local"

Owner_Delivery_Probe :: struct {
    calls:int,
    commit_failure,first_success,io_in_uow:bool,
    same_effect:bool,
    id,digest:string,
}
owner_delivery_probe_send :: proc(ctx:rawptr,s:^owner.Store,claim:owner.Intent_Claim) -> (bool,string,i64) {
    p:=(^Owner_Delivery_Probe)(ctx)
    p.io_in_uow=p.io_in_uow || s.active!=nil
    p.calls+=1
    if p.calls==1 {
        p.id=strings.clone(claim.id,context.temp_allocator);p.digest=strings.clone(claim.digest,context.temp_allocator)
        target:="pending"
        if p.first_success do target="settled"
        sql:=fmt.tprintf("CREATE TRIGGER fail_delivery_result BEFORE UPDATE OF state ON runtime_intents WHEN OLD.state='claimed' AND NEW.state='%s' BEGIN SELECT RAISE(ABORT,'temporary storage error'); END",target)
        if p.commit_failure {
            sql=fmt.tprintf("CREATE TRIGGER fail_delivery_result AFTER UPDATE OF state ON runtime_intents WHEN OLD.state='claimed' AND NEW.state='%s' BEGIN INSERT INTO result_child VALUES(99); END",target)
        }
        if !owner.exec(s.db,sql) do panic("fault trigger")
        if p.first_success do return true,"200",1000
        return false,"503",1000
    }
    p.same_effect=claim.id==p.id && claim.digest==p.digest && claim.attempt==2
    return true,"200",2000
}

@(test)
test_owner_local_publication_recovers_result_write_and_commit_failure_in_process :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    for commit_failure in ([2]bool{false,true}) {
        for first_success in ([2]bool{false,true}) {
            s:owner.Store
            path:=fmt.tprintf("%s/.cache/heimdall-tests/owner-delivery-%d-%v-%v.sqlite",bridge_env_get("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()),commit_failure,first_success)
            if !testing.expect(t,owner.open(&s,path,"account","bridge","bridge_key")) do continue
            q:owner.Intent_Completions
            defer {
                owner.intent_completions_destroy(&q);owner.close(&s)
                for suffix in ([4]string{"","-wal","-shm",".writer"}) do _=os.remove(fmt.tprintf("%s%s",path,suffix))
            }
            testing.expect(t,owner.exec(s.db,`INSERT INTO task_chains VALUES('chain','device','device','title','description',1);
              INSERT INTO command_receipts(principal_id,operation_id,chain_id,task_id,method,input_digest,digest_key_id,request_expires_ms,result_json,commit_seq)
              VALUES('device','create','chain','','chain.create','digest','device',2000,'result',1);
              CREATE TABLE result_parent(id INTEGER PRIMARY KEY);
              CREATE TABLE result_child(id INTEGER REFERENCES result_parent(id) DEFERRABLE INITIALLY DEFERRED);`))
            tx:owner.Transaction
            testing.expect(t,owner.transaction_begin(&s,&tx))
            testing.expect(t,owner.intent_enqueue(&tx,owner.Intent_Input{"chain","device","create",1,"registry","","{}","signed registry bytes"}))
            testing.expect(t,owner.transaction_commit(&tx))
            incarnation:=s.incarnation
            probe:=Owner_Delivery_Probe{commit_failure=commit_failure,first_success=first_success}
            testing.expect(t,!bridge_owner_publish_batch(&s,&q,1000,&probe,owner_delivery_probe_send))
            testing.expect(t,q.count==1 && probe.calls==1,"result survives failed persistence")
            testing.expect(t,!bridge_owner_publish_batch(&s,&q,1001,&probe,owner_delivery_probe_send))
            testing.expect_value(t,probe.calls,1)
            testing.expect(t,owner.exec(s.db,"DROP TRIGGER fail_delivery_result"))
            testing.expect(t,bridge_owner_publish_batch(&s,&q,1001,&probe,owner_delivery_probe_send))
            testing.expect(t,q.count==0 && probe.calls==1,"retry persistence before new network delivery")
            testing.expect(t,bridge_owner_publish_batch(&s,&q,2000,&probe,owner_delivery_probe_send))
            if first_success {
                testing.expect(t,probe.calls==1,"success acknowledgement never redelivers")
            } else {
                testing.expect(t,probe.calls==2 && probe.same_effect,"503 retries identical effect after retry floor")
            }
            rows,ok:=owner.query(s.db,"SELECT state,result_json FROM runtime_intents")
            testing.expect(t,ok && len(rows)==1 && rows[0][0]=="settled" && rows[0][1]=="200")
            testing.expect(t,s.incarnation==incarnation && !probe.io_in_uow,"no reopen or network inside UoW")
        }
    }
}
