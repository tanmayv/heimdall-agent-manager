package executor_local

import "core:testing"
import contracts "odin_test:contracts"

@(test)
executor_reconcile_never_observes_current_undispatched_claim_or_releases_without_absence :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    p:=document("prepare");testing.expect_value(t,reserve(f,p,&f.owner1).code,"ok")
    a:=activate_document(p);testing.expect_value(t,perform(f,a,&f.owner1).code,"ok")
    candidates,read:=reconcile_candidates(&f.store,"",1)
    testing.expect(t,read && len(candidates)==0,"queued launch is not restart recovery")
    intent,taken:=take_intent(&f.store,1200);testing.expect(t,taken)
    candidates,read=reconcile_candidates(&f.store,"",1)
    testing.expect(t,read && len(candidates)==0,"owner nonce callback may still be in flight before first dispatch")
    testing.expect(t,begin_dispatch(&f.store,intent,1200))
    candidates,read=reconcile_candidates(&f.store,"",1)
    if !testing.expect(t,read && len(candidates)==1) do return
    candidate:=candidates[0]
    stop,current:=reconcile_current(&f.store,candidate)
    testing.expect(t,current && !stop && candidate.launch_key==intent.launch_key)
    wrong:=candidate;wrong.launch_key="wrong"
    _,current=reconcile_current(&f.store,wrong);testing.expect(t,!current)
    _,current=reconcile_current(&f.store,intent);testing.expect(t,!current,"launch claim is not an observation candidate")
    candidates,read=reconcile_candidates(&f.store,candidate.reservation,1)
    testing.expect(t,read && len(candidates)==0,"cursor advances beyond an unknown child instead of starving later work")
    _,read=reconcile_candidates(&f.store,"",0);testing.expect(t,!read)
    _,read=reconcile_candidates(&f.store,"",RECONCILE_BATCH_MAX+1);testing.expect(t,!read)
    testing.expect(t,expire(&f.store,6000))
    stop,current=reconcile_current(&f.store,candidate)
    testing.expect(t,current && stop)
    rows,_:=query(f.store.db,"SELECT state FROM executor_reservations")
    testing.expect_value(t,rows[0][0],"stopping")
    testing.expect(t,observe_child(&f.store,candidate.reservation,observation(f,candidate.reservation,true)))
    rows,_=query(f.store.db,"SELECT state FROM executor_reservations")
    testing.expect(t,rows[0][0]=="stopping","a live exact child retains the charge after expiry")
    testing.expect(t,observe_child(&f.store,candidate.reservation,observation(f,candidate.reservation,false)))
    candidates,read=reconcile_candidates(&f.store,"",1)
    testing.expect(t,read && len(candidates)==0)
    _,current=reconcile_current(&f.store,candidate);testing.expect(t,!current)
}

@(test)
executor_reconcile_restart_can_observe_pending_original_without_launch_authority :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    p:=document("prepare");testing.expect_value(t,reserve(f,p,&f.owner1).code,"ok")
    a:=activate_document(p);testing.expect_value(t,perform(f,a,&f.owner1).code,"ok")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    candidates,read:=reconcile_candidates(&f.store,"",1)
    if !testing.expect(t,read && len(candidates)==1) do return
    candidate:=candidates[0]
    stop,current:=reconcile_current(&f.store,candidate)
    testing.expect(t,current && !stop && candidate.incarnation==f.store.incarnation)
    digest,_:=contracts.executor_digest("prepare",p)
    launch,query_only,found:=reservation_launch(&f.store,candidate.reservation,digest,1200)
    testing.expect(t,found && query_only && launch.launch_key==candidate.launch_key)
    testing.expect(t,!begin_dispatch(&f.store,launch,1200))
    testing.expect(t,!complete_recovery(&f.store,1200),"unknown original child blocks fresh admission")
    testing.expect(t,observe_child(&f.store,candidate.reservation,observation(f,candidate.reservation,false)))
    testing.expect(t,complete_recovery(&f.store,1200))
}
