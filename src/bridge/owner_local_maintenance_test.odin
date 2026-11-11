package main

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import owner "odin_test:lib/owner_local"

Owner_Maintenance_Probe :: struct { calls:int, io_in_uow:bool }
owner_maintenance_test_send :: proc(ctx:rawptr,s:^owner.Store,claim:owner.Intent_Claim) -> (bool,string,i64) {
    p:=(^Owner_Maintenance_Probe)(ctx)
    p.calls+=1;p.io_in_uow=p.io_in_uow || s.active!=nil
    return true,"200",100
}

@(test)
test_owner_local_periodic_batch_expires_and_publishes_after_commit :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    s:owner.Store
    path:=fmt.tprintf("%s/.cache/heimdall-tests/owner-maintenance-%d.sqlite",bridge_env_get("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    if !testing.expect(t,owner.open(&s,path,"account","bridge","bridge_key")) do return
    q:owner.Intent_Completions
    defer {
        owner.intent_completions_destroy(&q);owner.close(&s)
        for suffix in ([4]string{"","-wal","-shm",".writer"}) do _=os.remove(fmt.tprintf("%s%s",path,suffix))
    }
    testing.expect(t,owner.exec(s.db,`INSERT INTO task_chains VALUES('chain','device','device','title','description',1);
      INSERT INTO tasks VALUES('chain','task','task title','task body',1);
      INSERT INTO command_receipts(principal_id,operation_id,chain_id,task_id,method,input_digest,digest_key_id,request_expires_ms,result_json,commit_seq)
       VALUES('device','create','chain','','chain.create','digest','device',2000,'result',1);
      INSERT INTO local_leases VALUES('lease','chain','task','instance','epoch',1,'generation',1,1,100,200,1,'{}',NULL);
      UPDATE runtime_database SET commit_seq=1;`))
    tx:owner.Transaction
    testing.expect(t,owner.transaction_begin(&s,&tx))
    testing.expect(t,owner.intent_enqueue(&tx,owner.Intent_Input{"chain","device","create",1,"registry","","{}","signed registry"}))
    testing.expect(t,owner.transaction_commit(&tx))
    probe:Owner_Maintenance_Probe
    testing.expect(t,bridge_owner_maintenance_batch(&s,&q,100,&probe,owner_maintenance_test_send))
    rows,ok:=owner.query(s.db,"SELECT retired_seq,(SELECT commit_seq FROM runtime_database),(SELECT count(*) FROM local_changes) FROM local_leases")
    testing.expect(t,ok && rows[0][0]=="2" && rows[0][1]=="2" && rows[0][2]=="1")
    testing.expect(t,probe.calls==1 && !probe.io_in_uow,"publication happens outside expiry and outbox UoW")
    testing.expect(t,bridge_owner_maintenance_batch(&s,&q,100,&probe,owner_maintenance_test_send))
    rows,ok=owner.query(s.db,"SELECT commit_seq FROM runtime_database")
    testing.expect(t,ok && rows[0][0]=="2" && probe.calls==1,"repeated tick creates no expiry or delivery duplicate")
    testing.expect(t,!bridge_owner_maintenance_batch(&s,&q,99,&probe,owner_maintenance_test_send))
}
