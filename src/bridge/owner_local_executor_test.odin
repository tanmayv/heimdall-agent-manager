package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import owner "odin_test:lib/owner_local"

Owner_Executor_Probe :: struct {
    store:^owner.Store,
    mutex:^sync.Mutex,
    calls,accepts,read_failures:int,
    io_unlocked,io_outside_tx,exact:bool,
    block,entered,release,finished:bool,
    commit_failure,write_failure:bool,
    result,unknown_first:bool,
}
owner_executor_probe_snapshot :: proc(ctx:rawptr,s:^owner.Store,c:owner.Intent_Claim,now:i64)->(string,bool) {
    return strings.clone("pinned executor",context.temp_allocator),s.active==nil
}
owner_executor_probe_exchange :: proc(ctx:rawptr,c:owner.Intent_Claim,snapshot:string)->(string,i64) {
    p:=(^Owner_Executor_Probe)(ctx)
    p.calls+=1
    p.io_unlocked=sync.mutex_try_lock(p.mutex)
    if p.io_unlocked {
        p.io_outside_tx=p.store.active==nil
        sync.mutex_unlock(p.mutex)
    }
    if p.block {
        sync.atomic_store(&p.entered,true)
        started:=time.tick_now()
        for !sync.atomic_load(&p.release) && time.tick_since(started)<5*time.Second do time.sleep(time.Millisecond)
    }
    return strings.clone("authenticated receipt",context.temp_allocator),1000
}
owner_executor_probe_accept :: proc(ctx:rawptr,s:^owner.Store,c:owner.Intent_Claim,snapshot,response:string,now:i64)->(bool,bool,string) {
    p:=(^Owner_Executor_Probe)(ctx)
    p.accepts+=1
    p.exact=snapshot=="pinned executor" && response=="authenticated receipt" && c.payload=="original signed action" && c.destination=="executor"
    if p.read_failures>0 {p.read_failures-=1;return false,false,"storage_error"}
    if p.write_failure {
        p.write_failure=false
        if !owner.exec(s.db,"CREATE TRIGGER fail_executor_result BEFORE UPDATE OF state ON runtime_intents WHEN OLD.state='claimed' BEGIN SELECT RAISE(ABORT,'temporary storage error'); END") do panic("fault trigger")
    }
    if p.commit_failure {
        p.commit_failure=false
        if !owner.exec(s.db,"CREATE TABLE executor_parent(id INTEGER PRIMARY KEY); CREATE TABLE executor_child(id INTEGER REFERENCES executor_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER fail_executor_result AFTER UPDATE OF state ON runtime_intents WHEN OLD.state='claimed' BEGIN INSERT INTO executor_child VALUES(99); END") do panic("fault trigger")
    }
    if p.unknown_first && p.calls==1 do return true,false,"unknown_outcome"
    return true,true,"signed_receipt"
}
owner_executor_probe_batch :: proc(w:^Owner_Executor_Worker,p:^Owner_Executor_Probe,now:i64)->bool {
    return bridge_owner_executor_batch(w,p.store,p.mutex,now,p,owner_executor_probe_snapshot,owner_executor_probe_exchange,owner_executor_probe_accept)
}
owner_executor_probe_store :: proc(t:^testing.T,s:^owner.Store)->string {
    path:=fmt.tprintf("%s/.cache/heimdall-tests/executor-worker-%d.sqlite",bridge_env_get("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    if !testing.expect(t,owner.open(s,path,"account","bridge","bridge_key")) do return ""
    if !testing.expect(t,owner.exec(s.db,`INSERT INTO task_chains VALUES('chain','device','device','title','description',1);
      INSERT INTO command_receipts(principal_id,operation_id,chain_id,task_id,method,input_digest,digest_key_id,request_expires_ms,result_json,commit_seq)
      VALUES('device','create','chain','','chain.create','digest','device',2000,'result',1);`)) {return path}
    tx:owner.Transaction
    testing.expect(t,owner.transaction_begin(s,&tx))
    testing.expect(t,owner.intent_enqueue(&tx,{"chain","device","create",1,"executor.activate","executor","exact prepare","original signed action"}))
    testing.expect(t,owner.intent_enqueue(&tx,{"chain","device","create",1,"registry","","{}","signed registry"}))
    testing.expect(t,owner.transaction_commit(&tx))
    return path
}
owner_executor_probe_cleanup :: proc(s:^owner.Store,path:string) {
    owner.close(s)
    for suffix in ([4]string{"","-wal","-shm",".writer"}) do _=os.remove(fmt.tprintf("%s%s",path,suffix))
}

@(test)
test_owner_executor_worker_retains_response_and_completion_across_storage_failures :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    for commit_failure in ([2]bool{false,true}) {
        s:owner.Store
        path:=owner_executor_probe_store(t,&s)
        defer owner_executor_probe_cleanup(&s,path)
        mutex:sync.Mutex;w:Owner_Executor_Worker
        defer bridge_owner_executor_destroy(&w)
        p:=Owner_Executor_Probe{store=&s,mutex=&mutex,read_failures=1,write_failure=!commit_failure,commit_failure=commit_failure}
        original_temp:=context.temp_allocator
        arena:mem.Arena
        mem.arena_init(&arena,make([]byte,1024*1024,original_temp))
        scratch:=mem.arena_allocator(&arena)
        context.temp_allocator=scratch
        testing.expect(t,!owner_executor_probe_batch(&w,&p,1000))
        testing.expect(t,w.pending && w.received && w.completions.count==0 && p.calls==1)
        free_all(scratch)
        testing.expect(t,!owner_executor_probe_batch(&w,&p,1001))
        testing.expect(t,w.pending && w.completions.count==1 && p.calls==1 && p.accepts==2 && p.exact)
        free_all(scratch)
        testing.expect(t,!owner_executor_probe_batch(&w,&p,1002))
        testing.expect(t,p.calls==1 && p.accepts==2,"failed result persistence repeats neither I/O nor acceptance")
        testing.expect(t,owner.exec(s.db,"DROP TRIGGER fail_executor_result"))
        testing.expect(t,owner_executor_probe_batch(&w,&p,1003))
        testing.expect(t,w.completions.count==0 && p.calls==1 && p.io_unlocked && p.io_outside_tx)
        context.temp_allocator=original_temp
        rows,ok:=owner.query(s.db,"SELECT kind,state,attempts,result_json FROM runtime_intents ORDER BY kind")
        testing.expect(t,ok && len(rows)==2 && rows[0][0]=="executor.activate" && rows[0][1]=="settled" && rows[0][2]=="1" && rows[0][3]=="signed_receipt")
        testing.expect(t,rows[1][0]=="registry" && rows[1][1]=="pending" && rows[1][2]=="0","executor never steals registry work")
    }
}

Owner_Executor_Race :: struct {worker:^Owner_Executor_Worker,probe:^Owner_Executor_Probe}
@(test)
test_owner_executor_worker_allows_concurrent_owner_callback_and_fences_late_reply :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    for mode in 0..<3 {
        s:owner.Store
        path:=owner_executor_probe_store(t,&s)
        defer owner_executor_probe_cleanup(&s,path)
        mutex:sync.Mutex;w:Owner_Executor_Worker
        defer bridge_owner_executor_destroy(&w)
        p:=Owner_Executor_Probe{store=&s,mutex=&mutex,block=true}
        race:=Owner_Executor_Race{&w,&p}
        worker:=bridge_thread_start_with_data(&race,proc(data:rawptr) {
            context.allocator=context.temp_allocator
            r:=(^Owner_Executor_Race)(data)
            r.probe.result=owner_executor_probe_batch(r.worker,r.probe,1000)
            sync.atomic_store(&r.probe.finished,true)
            free_all(context.temp_allocator)
        })
        started:=time.tick_now()
        for !sync.atomic_load(&p.entered) && !sync.atomic_load(&p.finished) && time.tick_since(started)<5*time.Second do time.sleep(time.Millisecond)
        entered:=sync.atomic_load(&p.entered)
        testing.expect(t,entered,"I/O callback entered")
        available:=sync.mutex_try_lock(&mutex)
        testing.expect(t,available,"another owner handler acquires mutex during remote I/O")
        if available {
            rows,ok:=owner.query(s.db,"SELECT state,attempts FROM runtime_intents WHERE kind='executor.activate'")
            testing.expect(t,ok && len(rows)==1 && rows[0][0]=="claimed" && rows[0][1]=="1")
            // A callback can perform owner work while activation waits.
            if mode==1 {
                _,ok=owner.query(s.db,"INSERT INTO intent_invalidations SELECT intent_id,'device','cancel' FROM runtime_intents WHERE kind='executor.activate'")
                testing.expect(t,ok)
            }
            if mode==2 {
                owner.close(&s)
                testing.expect(t,owner.open(&s,path,"account","bridge","bridge_key"))
            }
            sync.mutex_unlock(&mutex)
        }
        if entered do testing.expect(t,!owner_executor_probe_batch(&w,&p,1001),"overlapping tick cannot claim or send")
        sync.atomic_store(&p.release,true)
        thread.join(worker);thread.destroy(worker)
        testing.expect(t,p.result && p.calls==1 && p.io_unlocked && p.io_outside_tx)
        testing.expect_value(t,p.accepts,1 if mode==0 else 0)
        rows,read:=owner.query(s.db,"SELECT state,result_json FROM runtime_intents WHERE kind='executor.activate'")
        testing.expect(t,read && len(rows)==1 && rows[0][0]==("settled" if mode==0 else "claimed" if mode==1 else "pending"))
        if mode!=0 do testing.expect_value(t,rows[0][1],"")
    }
}

@(test)
test_owner_executor_worker_unknown_outcome_retries_original_claim_after_floor :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    s:owner.Store
    path:=owner_executor_probe_store(t,&s)
    defer owner_executor_probe_cleanup(&s,path)
    mutex:sync.Mutex;w:Owner_Executor_Worker
    defer bridge_owner_executor_destroy(&w)
    p:=Owner_Executor_Probe{store=&s,mutex=&mutex,unknown_first=true}
    testing.expect(t,owner_executor_probe_batch(&w,&p,1000))
    before,read:=owner.query(s.db,"SELECT intent_id,payload_digest,payload_json,exact_fence_json,state,next_retry_ms,attempts FROM runtime_intents WHERE kind='executor.activate'")
    testing.expect(t,read && len(before)==1 && before[0][4]=="pending" && before[0][5]=="2000" && before[0][6]=="1")
    testing.expect(t,owner_executor_probe_batch(&w,&p,1999) && p.calls==1)
    testing.expect(t,owner_executor_probe_batch(&w,&p,2000) && p.calls==2 && p.exact)
    after,ok:=owner.query(s.db,"SELECT intent_id,payload_digest,payload_json,exact_fence_json,state,attempts FROM runtime_intents WHERE kind='executor.activate'")
    testing.expect(t,ok && len(after)==1 && after[0][4]=="settled" && after[0][5]=="2")
    for i in 0..<4 do testing.expect_value(t,after[0][i],before[0][i])
}

@(test)
test_owner_executor_worker_rechecks_route_after_result_persistence_failure :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    for mode in 0..<3 {
        s:owner.Store
        path:=owner_executor_probe_store(t,&s)
        defer owner_executor_probe_cleanup(&s,path)
        mutex:sync.Mutex;w:Owner_Executor_Worker
        defer bridge_owner_executor_destroy(&w)
        p:=Owner_Executor_Probe{store=&s,mutex=&mutex,write_failure=true}
        testing.expect(t,!owner_executor_probe_batch(&w,&p,1000))
        testing.expect(t,w.pending && w.completions.count==1 && p.calls==1 && p.accepts==1)
        testing.expect(t,owner.exec(s.db,"DROP TRIGGER fail_executor_result"))
        // The full snapshot is rechecked again before retrying persistence.
        sql:="UPDATE runtime_intents SET destination_bridge='other' WHERE kind='executor.activate'"
        if mode==1 do sql="UPDATE runtime_intents SET exact_fence_json='changed fence' WHERE kind='executor.activate'"
        if mode==2 do sql="INSERT INTO intent_invalidations SELECT intent_id,'device','cancel' FROM runtime_intents WHERE kind='executor.activate'"
        changed:=owner.exec(s.db,sql)
        testing.expect(t,changed==(mode==2),"claimed-row transition guard rejects route/fence rewrites; invalidation remains append-only")
        testing.expect(t,owner_executor_probe_batch(&w,&p,1001))
        testing.expect(t,!w.pending && w.completions.count==0 && p.calls==1 && p.accepts==1)
        rows,ok:=owner.query(s.db,"SELECT state,result_json FROM runtime_intents WHERE kind='executor.activate'")
        testing.expect(t,ok && len(rows)==1 && rows[0][0]==("claimed" if mode==2 else "settled") && rows[0][1]==("" if mode==2 else "signed_receipt"))
    }
}

// C1 (REQ-E2E-1 run5, user 10:10Z: monotonic clamp, never refuse): a
// background batch read its now before the owner mutex while a write
// committed (store clock ahead). The batch uses max(now, store clock) and the
// store stays healthy; a large backward jump is clamped (and logged) with no
// refusal; a store marked clock_uncertain by an older build opens healthy.
@(test)
test_owner_store_monotonic_clamp_never_refuses_and_heals_on_open :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    s:owner.Store
    path:=owner_executor_probe_store(t,&s)
    defer owner_executor_probe_cleanup(&s,path)
    state :: proc(s:^owner.Store) -> (string,i64) {
        rows,_:=owner.query(s.db,"SELECT recovery_state,clock_high_ms FROM runtime_database WHERE singleton=1")
        if len(rows)!=1 do return "",0
        return rows[0][0],owner.number(rows[0][1])
    }
    // A concurrent write committed at 5000 while the loop waited with now 4000.
    testing.expect(t,owner.exec(s.db,"UPDATE runtime_database SET clock_high_ms=5000 WHERE singleton=1"))
    mutex:sync.Mutex;w:Owner_Executor_Worker
    defer bridge_owner_executor_destroy(&w)
    p:=Owner_Executor_Probe{store=&s,mutex=&mutex}
    testing.expect(t,owner_executor_probe_batch(&w,&p,4000))
    recovery,high:=state(&s)
    testing.expect(t,recovery=="ready" && high>=5000,"the stale-now batch leaves the store healthy and its clock monotonic")
    testing.expect(t,p.calls==1,"the stale-now batch still claims and delivers its intent")

    // A genuine 15 s backward jump: clamped to the store clock, no refusal.
    testing.expect(t,owner.exec(s.db,"UPDATE runtime_database SET clock_high_ms=20000 WHERE singleton=1"))
    testing.expect_value(t,owner.effective_now(&s,5000),i64(20000))
    testing.expect_value(t,owner.effective_now(&s,25000),i64(25000))
    _,claimed:=owner.intent_claim_due(&s,5000)
    testing.expect(t,claimed,"a backward clock is clamped, never refused")
    recovery,high=state(&s)
    testing.expect(t,recovery=="ready" && high==20000,"the store never marks itself uncertain or moves its clock back")

    // A store marked clock_uncertain on disk (an older build) opens healthy.
    testing.expect(t,owner.exec(s.db,"UPDATE runtime_database SET recovery_state='clock_uncertain' WHERE singleton=1"))
    owner.close(&s)
    if !testing.expect(t,owner.open(&s,path,"account","bridge","bridge_key")) do return
    recovery,_=state(&s)
    testing.expect_value(t,recovery,"ready")
    _,claimed=owner.intent_claim_due(&s,20001)
    testing.expect(t,claimed,"writes work after the heal")
}
