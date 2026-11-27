package main

import "base:runtime"
import "core:encoding/json"
import vm "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"

acp_chat_recovery_busy:bool
acp_chat_recovery_last_ms:i64
acp_chat_recovery_cursor:int
ACP_Chat_Recovery_Job :: struct { root:string }

// The WS writer schedules work only. Filesystem/HTTP work is off that thread,
// bounded, and retried on later ticks (including after reconnect or restart).
acp_chat_recovery_tick :: proc(now:i64) {
    when ODIN_TEST do return // tests call the scanner with an isolated root
    if now-acp_chat_recovery_last_ms<10000 || sync.atomic_load(&acp_chat_recovery_busy) do return
    acp_chat_recovery_last_ms=now
    sync.atomic_store(&acp_chat_recovery_busy,true)
    context.allocator=runtime.heap_allocator()
    job:=new(ACP_Chat_Recovery_Job);job.root=bridge_shell_data_dir()
    thread.run_with_data(job,acp_chat_recovery_worker)
}

acp_chat_recovery_worker :: proc(data:rawptr) {
    context.allocator=runtime.heap_allocator()
    job:=cast(^ACP_Chat_Recovery_Job)data
    defer {delete(job.root);free(job);sync.atomic_store(&acp_chat_recovery_busy,false)}
    arena:vm.Arena;_=vm.arena_init_growing(&arena);defer vm.arena_destroy(&arena)
    context.temp_allocator=vm.arena_allocator(&arena)
    acp_chat_recovery_scan(job.root)
}

acp_chat_recovery_scan :: proc(data_dir:string) {
    if !acp_chat_vault_ready() do return
    root:=strings.concatenate({data_dir,"/bridge/acp"},context.temp_allocator)
    instances,err:=os.read_directory_by_path(root,256,context.temp_allocator)
    if err!=nil do return
    attempts,visited:=0,0
    for instance in instances {
        if instance.type!=.Directory || !acp_state_component_ok(instance.name) do continue
        dir:=strings.concatenate({root,"/",instance.name},context.temp_allocator)
        epochs,eerr:=os.read_directory_by_path(dir,256,context.temp_allocator)
        if eerr!=nil do continue
        for epoch in epochs {
            if epoch.type!=.Directory || !acp_state_component_ok(epoch.name) do continue
            if visited<acp_chat_recovery_cursor { visited+=1;continue }
            if attempts>=32 { acp_chat_recovery_cursor=visited;return }
            if !acp_chat_vault_ready() do return
            path:=strings.concatenate({dir,"/",epoch.name,"/state.json"},context.temp_allocator)
            acp_chat_recover_journal(path)
            attempts+=1;visited+=1
        }
    }
    // Rotate bounded batches so a permanently forbidden old turn cannot starve
    // newer detached journals, and live journals count against the I/O budget.
    acp_chat_recovery_cursor=0
}

// The lifecycle gate fences launch/recovery while an ownerless journal changes.
// No runtime/global mutex is held during HTTP. A same-epoch live owner alone
// writes its journal; this worker never races its dispatcher checkpoints.
acp_chat_recover_journal :: proc(path:string) -> bool {
    context.allocator=runtime.heap_allocator()
    saved,valid:=acp_state_read(path);if !valid do return false
    defer acp_state_delete(&saved)
    if !saved.seal_journal || saved.chat_outbox_json=="" do return false
    lifecycle:=bridge_agent_lifecycle_enter(saved.instance);defer acp_runtime_leave_lifecycle(lifecycle)
    // Stop/replacement may have checkpointed while we waited for the gate.
    fresh,readable:=acp_state_read(path)
    if !readable do return false
    acp_state_delete(&saved);saved=fresh
    sync.mutex_lock(&acp_runtime_mu)
    owner:=acp_runtimes[saved.instance]
    active:=owner!=nil && owner.epoch==saved.launch_epoch
    sync.mutex_unlock(&acp_runtime_mu)
    if active do return false
    epoch:=bridge_agent_instance_launch_epoch(saved.instance);defer delete(epoch)
    // Stop invalidates local CLI credentials. The existing public instance
    // assertion remains available as a generation fence; the Hub authenticates
    // the bridge bearer and current bridge ownership separately on this route.
    if epoch=="" do return false
    rec:=Bridge_Local_Agent_Token_Record{agent_instance_id=saved.instance}
    stale:=epoch!="" && epoch!=saved.launch_epoch
    durable:ACP_Runtime_Durable
    if json.unmarshal_string(saved.runtime_json,&durable,allocator=context.temp_allocator)!=nil do return false
    snap,present:=bridge_runtime_instance_snapshot(saved.instance)
    proof:=bridge_instance_probe(saved.instance)
    terminal:=present && (snap.stopped_intent_unix_ms!=0 ||
        proof.state=="exited" && proof.pid==snap.startup.pty_pid)
    // No local owner yet during initial cold reconcile does not prove interruption.
    if !stale && !durable.stopped && durable.error=="" && !terminal do return false
    r:=ACP_Runtime{instance=saved.instance,epoch=saved.launch_epoch,saved_outbox=strings.clone(saved.chat_outbox_json)}
    defer {acp_chat_destroy(&r);delete(r.saved_outbox)}
    if !acp_chat_prepare(&r) do return false
    if r.chat.d.publication_failed do return false
    if !acp_chat_resume_deferred(&r) do return false
    if r.chat.d.status=="pending" {
        acp_runtime_replace(&r.chat.d.status,"failed")
        acp_runtime_replace(&r.chat.d.stop_reason,"acp_turn_interrupted")
        if !acp_chat_flush(&r,true) do return false
    }
    if stale {
        for &entry in r.chat.d.outbox {
            if entry.kind!="" || entry.message_status=="failed" do continue
            entry.revision+=1
            acp_runtime_replace(&entry.message_status,"failed")
            acp_runtime_replace(&entry.stop_reason,"acp_turn_interrupted")
        }
    }
    if len(r.chat.d.outbox)==0 do return false
    acp_runtime_replace(&saved.chat_outbox_json,acp_event_json(r.chat.d))
    if !acp_state_write(path,&saved) do return false
    // The Hub's route-specific stale-epoch gate permits only already-bound failed
    // turns. Local agent credentials are never forwarded to the Hub.
    rec.instance_token=strings.concatenate({"hit_",saved.instance,"~",saved.launch_epoch})
    defer delete(rec.instance_token)
    for len(r.chat.d.outbox)>0 {
        entry:=r.chat.d.outbox[0]
        outcome:=acp_chat_publish_entry(acp_event_json(entry),rec)
        success:=outcome==.Saved
        // A terminal row from an uncertain earlier completion already satisfies
        // finalization. It must never be changed back to failed/pending.
        terminal_conflict:=outcome==.Terminal
        if !success && !terminal_conflict {
            if outcome==.Rejected {
                r.chat.d.publication_failed=true
                acp_runtime_replace(&saved.chat_outbox_json,acp_event_json(r.chat.d))
                acp_state_write(path,&saved)
            }
            return true
        }
        acp_chat_entry_delete(entry);ordered_remove(&r.chat.d.outbox,0)
        acp_runtime_replace(&saved.chat_outbox_json,acp_event_json(r.chat.d))
        if !acp_state_write(path,&saved) do return true
    }
    return true
}
