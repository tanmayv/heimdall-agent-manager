package main

import "core:sync"
import "core:encoding/json"
import contracts "odin_test:contracts"

// Private memory observation only. It excludes inline handlers, startup specs,
// daemon children and durable history. It cannot establish complete coverage,
// historical origin, a never-admitted disposition, or physical absence.
Bridge_Legacy_Dispatch_Snapshot :: struct {
    revision,generation:i64,
    queued,running:int,
    digest:string,
    valid:bool,
}
bridge_dispatch_observation_revision:i64
bridge_dispatch_observation_exhausted:bool

// Caller holds dispatch mutex. Saturate rather than allow an ABA at overflow.
bridge_dispatch_observation_changed_locked :: proc() {
    if bridge_dispatch_observation_revision==0x7fffffffffffffff {
        bridge_dispatch_observation_exhausted=true
        return
    }
    bridge_dispatch_observation_revision+=1
}

bridge_legacy_dispatch_snapshot_locked :: proc()->Bridge_Legacy_Dispatch_Snapshot {
    snapshot:=Bridge_Legacy_Dispatch_Snapshot{
        revision=bridge_dispatch_observation_revision,
        generation=bridge_dispatch_generation,
        valid=bridge_dispatch_initialized && !bridge_dispatch_observation_exhausted,
    }
    Entry :: struct {id,digest:string,state:Bridge_Dispatch_Claim_State}
    entries:=make([dynamic]Entry,context.temp_allocator)
    seen:=make(map[string]bool,context.temp_allocator)
    for claim in bridge_dispatch_claims {
        if seen[claim.command_id] do snapshot.valid=false
        seen[claim.command_id]=true
        if claim.state==.Completed do continue
        if !contracts.owner_hex(claim.input_digest,64) do snapshot.valid=false
        if claim.state==.Queued {snapshot.queued+=1} else {snapshot.running+=1}
        append(&entries,Entry{claim.command_id,claim.input_digest,claim.state})
    }
    // Include actual queue bytes, not only the in-memory claim projection.
    Job :: struct {id,digest:string,generation:i64}
    jobs:=make([dynamic]Job,context.temp_allocator)
    queues:=[]([]Bridge_Dispatch_Job){
        bridge_dispatch_lifecycle[:],bridge_dispatch_interactive[:],
        bridge_dispatch_background[:],bridge_dispatch_exclusive[:],
        bridge_dispatch_general_io[:],bridge_dispatch_shell[:],
        bridge_dispatch_model_discovery[:],
    }
    queued_seen:=make(map[string]bool,context.temp_allocator)
    for queue in queues do for job in queue {
        if queued_seen[job.command_id] do snapshot.valid=false
        queued_seen[job.command_id]=true
        digest:=contracts.owner_payload_digest(job.text)
        claim_index:=bridge_command_dispatch_claim_index_locked(job.command_id)
        if claim_index<0 {
            snapshot.valid=false
        } else {
            claim:=bridge_dispatch_claims[claim_index]
            if claim.state!=.Queued || claim.input_digest!=digest do snapshot.valid=false
        }
        append(&jobs,Job{job.command_id,digest,job.generation})
    }
    if snapshot.queued!=len(jobs) do snapshot.valid=false
    bytes,err:=json.marshal(struct{claims:[]Entry,jobs:[]Job}{entries[:],jobs[:]},allocator=context.temp_allocator)
    if err!=nil {snapshot.valid=false;return snapshot}
    snapshot.digest=contracts.owner_payload_digest(string(bytes))
    return snapshot
}

bridge_legacy_dispatch_snapshot :: proc()->Bridge_Legacy_Dispatch_Snapshot {
    sync.mutex_lock(&bridge_dispatch_mu);defer sync.mutex_unlock(&bridge_dispatch_mu)
    return bridge_legacy_dispatch_snapshot_locked()
}

// Caller must retain dispatch mutex through the operation whose memory CAS
// it is checking. A successful comparison alone does not fence later ingress.
bridge_legacy_dispatch_current_locked :: proc(old:Bridge_Legacy_Dispatch_Snapshot)->bool {
    current:=bridge_legacy_dispatch_snapshot_locked()
    return old.valid && current.valid && old.revision==current.revision &&
        old.generation==current.generation && old.queued==current.queued &&
        old.running==current.running && old.digest==current.digest
}
