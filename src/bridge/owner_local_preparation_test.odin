package main
import "core:mem"
import "core:sync"
import "core:testing"
import owner "odin_test:lib/owner_local"

owner_prepare_probe_current :: proc(s:^owner.Store,id:string,now:i64)->bool {
    rows,ok:=owner.query(s.db,"SELECT 1 FROM task_chains WHERE chain_id=?",id)
    return ok && len(rows)==1
}
owner_prepare_probe_snapshot :: proc(_:rawptr,s:^owner.Store,now:i64)->(owner.Intent_Claim,string,bool) {
    return owner.Intent_Claim{id="chain",kind="executor.prepare",destination="executor",payload="original signed action"},"pinned executor",true
}

owner_prepare_probe_denied :: proc(s:^owner.Store,id:string,now:i64)->bool {return false}

@(test)
test_owner_preparation_worker_retains_response_across_temp_reset_and_storage_retry :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    s:owner.Store;path:=owner_executor_probe_store(t,&s);defer owner_executor_probe_cleanup(&s,path)
    mutex:sync.Mutex;w:Owner_Executor_Worker
    defer bridge_owner_executor_destroy(&w)
    p:=Owner_Executor_Probe{store=&s,mutex=&mutex,read_failures=1}
    original:=context.temp_allocator
    arena:mem.Arena
    mem.arena_init(&arena,make([]byte,1024*1024,original))
    scratch:=mem.arena_allocator(&arena);context.temp_allocator=scratch
    testing.expect(t,!bridge_owner_preparation_batch(&w,&s,&mutex,1000,{},&p,owner_prepare_probe_snapshot,
        owner_executor_probe_exchange,owner_executor_probe_accept,owner_prepare_probe_current))
    testing.expect(t,w.pending && w.received && p.calls==1 && p.accepts==1)
    free_all(scratch)
    testing.expect(t,!bridge_owner_preparation_batch(&w,&s,&mutex,1001,{},&p,owner_prepare_probe_snapshot,
        owner_executor_probe_exchange,owner_executor_probe_accept,owner_prepare_probe_denied))
    testing.expect(t,w.pending && w.received && p.calls==1 && p.accepts==1)
    testing.expect(t,bridge_owner_preparation_batch(&w,&s,&mutex,1001,{},&p,owner_prepare_probe_snapshot,
        owner_executor_probe_exchange,owner_executor_probe_accept,owner_prepare_probe_current))
    testing.expect(t,!w.pending && p.calls==1 && p.accepts==2 && p.exact && p.io_unlocked && p.io_outside_tx)
    context.temp_allocator=original
}
