#+feature dynamic-literals
package owner_local

import "core:fmt"
import "core:testing"

// Owner-chain set-title nudge (title_nudge.odin): the same gate as the Hub's
// evaluate_title_nudge on origin/main, Bridge-held title state, and
// task-chain set-title (coordinator chain.edit) ending the nudges.

@(test)
title_nudge_gate_matches_origin_main :: proc(t:^testing.T) {
    hour:=i64(3600*1000)
    cases:=[?]struct{source:string,activity:bool,last_activity,last_nudge,now:i64,want:bool,reason:string}{
        {"agent",true,10,0,20,false,"non_default_title"},
        {"user",true,10,0,20,false,"non_default_title"},
        {"default",false,0,0,20,false,"no_activity"},
        {"default",true,10,0,20,true,""},
        {"default",true,10,10,10+hour+1,false,"no_new_activity"},
        {"default",true,20,10,10+hour-1,false,"cooldown"},
        {"default",true,20,10,10+hour,true,""},
    }
    for c in cases {
        d:=title_nudge_evaluate(c.source,c.activity,c.last_activity,c.last_nudge,c.now,TITLE_NUDGE_COOLDOWN_SECONDS)
        testing.expectf(t,d.should_nudge==c.want && d.reason==c.reason,"%v -> %v",c,d)
    }
    // A zero cooldown falls back to the 1 h default.
    testing.expect_value(t,title_nudge_evaluate("default",true,20,10,10+hour-1,0).reason,"cooldown")
}

@(test)
title_nudge_default_chain_nudges_its_coordinator_once_per_cooldown :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    hour:=i64(3600*1000)

    // An explicitly titled chain (no title state) is never nudged.
    _,_,d:=chain_title_activity(&f.store,coord.instance,1000)
    testing.expect_value(t,d.reason,"non_default_title")

    testing.expect(t,chain_title_source_set(&f.store,"chain","default"))
    // An agent of no chain of this owner is not activity here.
    _,_,d=chain_title_activity(&f.store,agent_stranger().instance,1000)
    testing.expect_value(t,d.reason,"no_chain")

    // First activity: nudge the coordinator.
    chain,target,first:=chain_title_activity(&f.store,coord.instance,1000)
    testing.expect(t,first.should_nudge && chain=="chain" && target==coord.instance)
    // Not delivered (coordinator still launching): nothing is stamped, so
    // the next activity retries at once.
    _,_,d=chain_title_activity(&f.store,coord.instance,2000)
    testing.expect(t,d.should_nudge,"an undelivered nudge is retried")
    // Delivered: stamped; more activity inside the hour is held back.
    testing.expect(t,chain_title_nudge_stamp(&f.store,"chain",2000))
    _,_,d=chain_title_activity(&f.store,coord.instance,3000)
    testing.expect_value(t,d.reason,"cooldown")
    // After the cooldown with new activity since the nudge: nudge again.
    _,_,d=chain_title_activity(&f.store,coord.instance,2000+hour)
    testing.expect(t,d.should_nudge,"re-nudge after the cooldown")
    testing.expect(t,chain_title_nudge_stamp(&f.store,"chain",2000+hour))
    // The cooldown elapsed but no activity since the last nudge: no nudge.
    source,activity,nudged,found,ok:=chain_title_state(&f.store,"chain")
    testing.expect(t,ok && found && source=="default" && activity==2000+hour && nudged==2000+hour)
    testing.expect_value(t,title_nudge_evaluate(source,true,activity,nudged,nudged+2*hour,TITLE_NUDGE_COOLDOWN_SECONDS).reason,"no_new_activity")
}

@(test)
title_nudge_set_title_by_coordinator_stops_nudges :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    testing.expect(t,chain_title_source_set(&f.store,"chain","default"))
    edit:=encode(doc(map[string]string{"title_cipher"=cipher(f,"Ship the importer"),"description_cipher"=cipher(f,"kept")}))

    // Only the chain's coordinator names it: workers and strangers are refused.
    for who in ([2]Child{lease_child(),agent_stranger()}) {
        testing.expectf(t,agent_run(f,who,"chain.edit",fmt.tprintf("rename_%s",who.instance),"",edit,agent_chain_rev(f)).code=="invalid_scope","%s cannot set the title",who.instance)
    }
    source,_,_,_,_:=chain_title_state(&f.store,"chain")
    testing.expect_value(t,source,"default")

    intents:=fleet_scalar(f,"SELECT count(*) FROM runtime_intents WHERE kind LIKE 'registry%'")
    testing.expect_value(t,agent_run(f,coord,"chain.edit","coord_rename","",edit,agent_chain_rev(f)).code,"ok")
    testing.expect_value(t,fleet_scalar(f,"SELECT title||'|'||description FROM task_chains WHERE chain_id='chain'"),"Ship the importer|kept")
    testing.expect(t,fleet_scalar(f,"SELECT count(*) FROM runtime_intents WHERE kind LIKE 'registry%'")!=intents,"the new title is republished")
    source,_,_,_,_=chain_title_state(&f.store,"chain")
    testing.expect_value(t,source,"agent")
    _,_,d:=chain_title_activity(&f.store,coord.instance,5000)
    testing.expect_value(t,d.reason,"non_default_title")
}

@(test)
title_nudge_device_rename_is_user_and_description_edit_keeps_default :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect(t,chain_title_source_set(&f.store,"chain","default"))
    current:=fleet_scalar(f,"SELECT title FROM task_chains WHERE chain_id='chain'")
    // Same title, new description: still the default title.
    same:=encode(doc(map[string]string{"title_cipher"=cipher(f,current),"description_cipher"=cipher(f,"new description")}))
    testing.expect_value(t,invoke(f,command(f,"chain.edit","describe","",same,summary_revision(f)),same).code,"ok")
    source,_,_,_,_:=chain_title_state(&f.store,"chain")
    testing.expect_value(t,source,"default")
    renamed:=encode(doc(map[string]string{"title_cipher"=cipher(f,"User title"),"description_cipher"=cipher(f,"new description")}))
    testing.expect_value(t,invoke(f,command(f,"chain.edit","rename","",renamed,summary_revision(f)),renamed).code,"ok")
    source,_,_,_,_=chain_title_state(&f.store,"chain")
    testing.expect_value(t,source,"user")
}
