package main

import "core:fmt"
import "core:testing"
import executor "odin_test:lib/executor_local"
import contracts "odin_test:contracts"

@(test)
bridge_legacy_dispatch_refuses_unscoped_resources_under_barrier :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    store,path:=bridge_legacy_test_store(t);defer bridge_legacy_test_close(store,path)
    barrier:=executor.Legacy_Barrier{"chain","migration",contracts.owner_payload_digest("selection"),0}
    testing.expect_value(t,bridge_legacy_install_barrier(store,barrier,[]executor.Legacy_Resource{{"instance","unrelated_claim"}}).code,"ok")
    for kind in ([4]string{"fs_write_file","vcs_commit","shell_pty_input","lsp_start"}) {
        packet:=executor.encode(struct{type,command_id:string}{kind,"original"})
        spec,known:=bridge_command_spec(kind)
        testing.expect(t,known)
        action,prepared:=bridge_legacy_dispatch_prepare(packet,kind,spec,store)
        testing.expect(t,prepared)
        job:=Bridge_Dispatch_Job{text=packet,command_type=kind,legacy_action=action}
        testing.expect(t,!bridge_legacy_dispatch_start(&job,store) && job.legacy_start_fenced,
            "caller claims cannot positively exclude shared filesystem/process resources")
        testing.expect(t,bridge_legacy_dispatch_end(action,false,store))
    }
    rows,read:=executor.query(store.db,"SELECT count(*),sum(state='discarded'),sum(state='running') FROM executor_legacy_actions")
    testing.expect(t,read && rows[0][0]=="4" && rows[0][1]=="4" && rows[0][2]=="0")
}

@(test)
bridge_legacy_dispatch_journals_original_occurrences_and_refuses_unrecorded_start :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    store,path:=bridge_legacy_test_store(t);defer bridge_legacy_test_close(store,path)
    packet:=`{"type":"wake_agent","payload":{"run":[]}}`
    spec,known:=bridge_command_spec("wake_agent");testing.expect(t,known)
    action,prepared:=bridge_legacy_dispatch_prepare(packet,"wake_agent",spec,store)
    testing.expect(t,prepared && action.id>0)
    rows,read:=executor.query(store.db,"SELECT command_id,chain_claim,state FROM executor_legacy_actions")
    testing.expect(t,read && rows[0][0]=="" && rows[0][1]=="" && rows[0][2]=="prepared")
    queue:=make([dynamic]Bridge_Dispatch_Job);defer delete(queue)
    append(&queue,Bridge_Dispatch_Job{legacy_action=action,text=packet,command_id="bridge_synthetic_id",command_type="wake_agent"})
    job,taken:=bridge_command_dispatch_take_queue_locked(&queue)
    testing.expect(t,taken && job.legacy_action==action,"taking a job preserves its exact native observation identity")
    job.text=`{"type":"wake_agent","payload":{"run":[],"stop":["retargeted"]}}`
    testing.expect(t,!bridge_legacy_dispatch_start(&job,store),"valid occurrence cannot be swapped onto different worker bytes")
    job.text=packet
    testing.expect(t,bridge_legacy_dispatch_start(&job,store))
    testing.expect(t,!bridge_legacy_dispatch_start(&job,store),"historical state replay cannot admit another invocation")
    testing.expect(t,bridge_legacy_dispatch_end(job.legacy_action,true,store))
    second,again:=bridge_legacy_dispatch_prepare(packet,"wake_agent",spec,store)
    testing.expect(t,again && second.id!=action.id)
    testing.expect(t,bridge_legacy_dispatch_end(second,false,store))
    testing.expect_value(t,executor.exec(store.db,"CREATE TRIGGER refuse_action BEFORE INSERT ON executor_legacy_actions BEGIN SELECT RAISE(ABORT,'test storage fault'); END;"),true)
    _,denied:=bridge_legacy_dispatch_prepare(packet,"wake_agent",spec,store)
    testing.expect(t,!denied,"a paired relevant action cannot enter the queue without durable evidence")
    testing.expect(t,executor.exec(store.db,"DROP TRIGGER refuse_action; CREATE TRIGGER refuse_start BEFORE UPDATE ON executor_legacy_actions WHEN NEW.state='running' BEGIN SELECT RAISE(ABORT,'test storage fault'); END;"))
    third,third_ok:=bridge_legacy_dispatch_prepare(packet,"wake_agent",spec,store);testing.expect(t,third_ok)
    job.legacy_action=third
    testing.expect(t,!bridge_legacy_dispatch_start(&job,store),"a failed running transition refuses the handler")
    testing.expect(t,bridge_legacy_dispatch_end(third,false,store))
    rows,read=executor.query(store.db,"SELECT state FROM executor_legacy_actions ORDER BY action_id")
    testing.expect(t,read && len(rows)==3 && rows[0][0]=="returned" && rows[1][0]=="discarded" && rows[2][0]=="discarded")
}

@(test)
bridge_legacy_dispatch_restart_refuses_stale_queue_and_observes_new_paired_work :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    store,path:=bridge_legacy_test_store(t);defer bridge_legacy_test_close(store,path)
    packet:=`{"type":"wake_agent","command_id":"original","chain_id":"claimed","payload":{"run":[]}}`
    spec,_:=bridge_command_spec("wake_agent")
    action,prepared:=bridge_legacy_dispatch_prepare(packet,"wake_agent",spec,store);testing.expect(t,prepared)
    executor.close(store);testing.expect(t,executor.open(store,path,"account","executor","operator"))
    job:=Bridge_Dispatch_Job{legacy_action=action,text=packet,command_id="original",command_type="wake_agent"}
    testing.expect(t,!bridge_legacy_dispatch_start(&job,store),"old incarnation cannot silently finish an unresolved queue occurrence")
    testing.expect(t,!bridge_legacy_dispatch_end(action,false,store))
    rows,read:=executor.query(store.db,"SELECT state FROM executor_legacy_actions WHERE action_id=?",fmt.tprintf("%d",action.id))
    testing.expect(t,read && rows[0][0]=="prepared")
    // A job retained from unpaired memory gets a fresh observation now; this
    // cannot fill the unknown interval before enrollment.
    job.legacy_action={}
    testing.expect(t,bridge_legacy_dispatch_start(&job,store))
    testing.expect(t,job.legacy_action.incarnation==store.incarnation && job.legacy_action.id!=action.id)
    testing.expect(t,bridge_legacy_dispatch_end(job.legacy_action,true,store))
    snapshot,ok:=executor.legacy_journal_snapshot(store)
    testing.expect(t,ok && snapshot.prior_coverage_unknown)
    discovery,_:=bridge_command_spec("provider_discover")
    testing.expect(t,!bridge_legacy_dispatch_requires_observation(discovery),"compatibility is not a coverage claim")
}

@(test)
bridge_legacy_dispatch_unconfigured_compatibility_preserves_paired_requirement :: proc(t:^testing.T) {
    saved:=bridge_cfg().daemon_id
    defer bridge_cfg().daemon_id=saved
    bridge_cfg().daemon_id=""
    job:=Bridge_Dispatch_Job{text=`{"type":"wake_agent","payload":{"run":[]}}`,command_type="wake_agent"}
    testing.expect(t,bridge_legacy_dispatch_start(&job),"unconfigured compatibility remains unknown, not verified coverage")
    job.paired_observation_required=true
    testing.expect(t,!bridge_legacy_dispatch_start(&job),"a paired queue admission cannot become unobserved after losing enrollment")
    closed:executor.Store
    testing.expect(t,!bridge_legacy_dispatch_start(&job,&closed),"unavailable paired journal refuses before handler effects")
}
