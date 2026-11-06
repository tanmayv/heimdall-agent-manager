#+feature dynamic-literals
package taskv2

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import local "odin_test:lib/owner_local"

owner_placement_bundle :: proc(fx:^Fixture,facets:[]domain.Task_Attempt_Facet,source:string)->string {
    attempts:=make([dynamic]string,context.temp_allocator)
    rows,_:=iface.taskchain_list_attempts_by_task(&fx.repo,"task","u1")
    for row in rows {
        append(&attempts,local.encode(contracts.Owner_Native_History_Attempt{task_id=string(row.task_id),chain_id=string(row.chain_id),owner_user_id=string(row.owner_user_id),attempt_no=fmt.tprintf("%d",row.attempt_no),started_at=row.started_at,ended_at=row.ended_at,holder_instance_id=row.holder_instance_id,outcome=row.outcome,counts_toward_budget=("1" if row.counts_toward_budget else "0"),provenance_json=`{"source":"native placement regression"}`}))
    }
    events:=make([dynamic]string,context.temp_allocator)
    source_events,_:=iface.taskchain_list_events_by_task(&fx.repo,"task","u1")
    for row in source_events {
        append(&events,local.encode(contracts.Owner_Native_History_Event{event_id=fmt.tprintf("%d",row.event_id),task_id=string(row.task_id),chain_id=string(row.chain_id),owner_user_id=string(row.owner_user_id),ts_ms=fmt.tprintf("%d",row.ts_ms),actor_kind=row.actor_kind,actor_id=row.actor_id,kind=row.kind,payload_json=row.payload_json,provenance_json=`{"source":"native placement regression"}`}))
    }
    documents:=make([dynamic]string,context.temp_allocator)
    for row in facets {
        append(&documents,local.encode(contracts.Owner_Native_History_Facet{task_id=string(row.task_id),chain_id=string(row.chain_id),owner_user_id=string(row.owner_user_id),attempt_no=fmt.tprintf("%d",row.attempt_no),kind=row.kind,v=fmt.tprintf("%d",row.v),body_json=row.body_json,writer=row.writer,written_at=row.written_at,references_json="[]",provenance_json=`{"source":"native placement regression"}`}))
    }
    return local.encode(map[string]string{"source_revision"=source,"owner_user_id"="u1","completeness"="full","attempts"=local.encode(attempts),"events"=local.encode(events),"facets"=local.encode(documents)})
}

owner_placement_compare :: proc(t:^testing.T,raw:string,facets:[]domain.Task_Attempt_Facet,expected_attempts:int) {
    bundle,valid:=contracts.owner_parse(raw,"native_history_bundle")
    if !testing.expect(t,valid) do return
    value,_:=contracts.owner_request_document(contracts.owner_string(bundle,"facets"));items,_:=value.(json.Array)
    if !testing.expect_value(t,len(items),len(facets)) do return
    for item,i in items {
        text,_:=item.(json.String);record,ok:=contracts.owner_parse(string(text),"native_history_facet")
        if !testing.expect(t,ok) do return
        original:=facets[i]
        testing.expect_value(t,contracts.owner_string(record,"attempt_no"),fmt.tprintf("%d",original.attempt_no))
        testing.expect_value(t,contracts.owner_string(record,"kind"),original.kind)
        testing.expect_value(t,contracts.owner_string(record,"v"),fmt.tprintf("%d",original.v))
        testing.expect_value(t,contracts.owner_string(record,"writer"),original.writer)
        testing.expect_value(t,contracts.owner_string(record,"written_at"),original.written_at)
        testing.expect_value(t,contracts.owner_string(record,"body_json"),original.body_json)
    }
    value,_=contracts.owner_request_document(contracts.owner_string(bundle,"attempts"));attempts,_:=value.(json.Array)
    testing.expect_value(t,len(attempts),expected_attempts)
    value,_=contracts.owner_request_document(contracts.owner_string(bundle,"events"));source,_:=value.(json.Array)
    events:=make([dynamic]domain.Task_Event,context.temp_allocator)
    for item in source {
        text,_:=item.(json.String);record,ok:=contracts.owner_parse(string(text),"native_history_event")
        if !testing.expect(t,ok) do return
        id,_:=strconv.parse_i64(contracts.owner_string(record,"event_id"));ts,_:=strconv.parse_i64(contracts.owner_string(record,"ts_ms"))
        append(&events,domain.Task_Event{event_id=id,ts_ms=ts,kind=contracts.owner_string(record,"kind"),payload_json=contracts.owner_string(record,"payload_json")})
    }
    native:=fold_task(events[:],Fold_Input{deps_done=true,kind=.Task,review_roles_count=1,max_attempts=100})
    testing.expect_value(t,native.attempt_no,expected_attempts)
    testing.expect_value(t,native.counting_attempts,expected_attempts)
}

// Set HEIMDALL_EXPORT_PLACEMENT_FIXTURES only to regenerate these synthetic
// captures. Normal runs compare exact original placement facts and accounting.
@(test)
test_owner_native_placement_archival_source_fixtures :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    fx,log,ok:=lease_fixture(t,"owner_placement_archive");defer lease_fixture_close(fx,log)
    if !ok do return
    chain:=seed_live_chain(t,fx,"chain")
    seed_fleet(fx,chain,"agt_w",bridge_id="br_1")
    seed_instance(fx,chain,"inst_w1","agt_w","br_1","idle")
    seed_bridge(fx,"br_review",false)
    seed_fleet(fx,chain,"agt_r",roles=`["reviewer"]`,bridge_id="br_review")
    seed_instance(fx,chain,"inst_r","agt_r","br_review","idle","reviewer")
    set_bridge_status(fx,"br_1",false)
    task:=publish_task(t,fx,chain,"task",brief=`{"goal":"g","review_roles":["reviewer"],"reviewers":["agt_r"]}`,bridge_pin="br_1")
    zero1,found:=get_facet(&fx.svc,task,0,FACET_PLACEMENT)
    if !testing.expect(t,found && zero1.writer==FACET_WRITER_HUB && zero1.v==1) do return
    fixture_advance(fx,17)
    fleets,_:=iface.taskchain_list_fleets_by_chain(&fx.repo,chain.chain_id,"u1")
    for fleet in fleets { if fleet.agent_id=="agt_w" { updated:=fleet;updated.capacity=2;updated.updated_at=platform.clock_now(&fx.clock);_,_=iface.taskchain_upsert_fleet(&fx.repo,updated) } }
    _,rechecked,_:=task_recheck(&fx.svc,task,actor_from_auth(user_auth()));testing.expect(t,rechecked)
    task=get_task(fx,"task")
    zero2:domain.Task_Attempt_Facet
    zero2,found=get_facet(&fx.svc,task,0,FACET_PLACEMENT)
    if !testing.expect(t,found && zero2.v==2 && zero2.body_json!=zero1.body_json) do return
    attempts,_:=iface.taskchain_list_attempts_by_task(&fx.repo,"task","u1")
    testing.expect(t,task.attempt_no==0 && len(attempts)==0)
    pre_facets:=[2]domain.Task_Attempt_Facet{zero1,zero2}
    before:=owner_placement_bundle(fx,pre_facets[:],"placement_pregrant")
    fixture_advance(fx,10);set_bridge_status(fx,"br_1",true);on_bridge_hello(&fx.svc,"br_1",nil)
    lease,held:=lease_of(fx,"inst_w1")
    if !testing.expect(t,held && lease.attempt_no==1) do return
    confirm_holder(fx,"inst_w1")
    _,submitted,_:=lease_submit(&fx.svc,inst_auth("inst_w1"),Submit_Input{summary="ready",vcs_json=`{"head":"h","dirty":false}`})
    if !testing.expect(t,submitted) do return
    task=get_task(fx,"task")
    one1:domain.Task_Attempt_Facet
    one1,found=get_facet(&fx.svc,task,1,FACET_PLACEMENT)
    if !testing.expect(t,found && one1.v==1) do return
    fixture_advance(fx,13)
    fleets,_=iface.taskchain_list_fleets_by_chain(&fx.repo,chain.chain_id,"u1")
    for fleet in fleets { if fleet.agent_id=="agt_r" { updated:=fleet;updated.capacity=2;updated.updated_at=platform.clock_now(&fx.clock);_,_=iface.taskchain_upsert_fleet(&fx.repo,updated) } }
    _,rechecked,_=task_recheck(&fx.svc,task,actor_from_auth(user_auth()));testing.expect(t,rechecked)
    task=get_task(fx,"task")
    one2:domain.Task_Attempt_Facet
    one2,found=get_facet(&fx.svc,task,1,FACET_PLACEMENT)
    if !testing.expect(t,found && one2.v==2 && one2.body_json!=one1.body_json) do return
    later_facets:=[4]domain.Task_Attempt_Facet{zero1,zero2,one1,one2}
    after:=owner_placement_bundle(fx,later_facets[:],"placement_later")
    export:=os.get_env("HEIMDALL_EXPORT_PLACEMENT_FIXTURES",context.temp_allocator)
    if export!="" {
        testing.expect(t,os.write_entire_file(fmt.tprintf("%s/owner-native-placement-pregrant.json",export),transmute([]u8)before)==nil)
        testing.expect(t,os.write_entire_file(fmt.tprintf("%s/owner-native-placement-later.json",export),transmute([]u8)after)==nil)
    } else {
        owner_placement_compare(t,string(#load("../../../contracts/fixtures/owner-native-placement-pregrant.json")),pre_facets[:],0)
        owner_placement_compare(t,string(#load("../../../contracts/fixtures/owner-native-placement-later.json")),later_facets[:],1)
    }
}
