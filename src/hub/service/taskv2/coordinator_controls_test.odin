package taskv2

import "core:testing"
import "core:strings"
import project "odin_test:hub/service/project"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Ordinary administrative repair must preserve the genuine approval obligation.
@(test)
test_coordinator_repairs_never_fabricate_user_approval :: proc(t: ^testing.T) {
    fx, log, ok := lease_fixture(t, "controls_no_approval")
    defer lease_fixture_close(fx, log)
    if !ok do return
    chain := seed_live_chain(t, fx, "chain_controls")
    seed_fleet(fx, chain, "agt_w")
    seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
    _ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"review_roles":[]}`)
    row := get_task(fx, "task_1")
    row.requires_user_approval = true
    _, _, _ = iface.taskchain_save_task(&fx.repo, row)
    confirm_holder(fx, "inst_w1")
    _, submitted, err := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary="ready for user", vcs_json=`{"head":"h1","dirty":false}`})
    if !testing.expect(t, submitted, err.message) do return
    actor := actor_from_auth(inst_auth("inst_coord"))
    _, held, herr := task_hold(&fx.svc, get_task(fx,"task_1"), actor, "inspect")
    if !testing.expect(t, held, herr.message) do return
    _, released, rerr := task_release(&fx.svc, get_task(fx,"task_1"), actor)
    if !testing.expect(t, released, rerr.message) do return
    for _ in 0..<2 {
        _, checked, cerr := task_recheck(&fx.svc,get_task(fx,"task_1"),actor)
        testing.expect(t, checked,cerr.message)
    }
    testing.expect_value(t,get_task(fx,"task_1").state,domain.Task_State.In_Review)
    testing.expect_value(t,count_reviews(fx,"task_1"),0)
    testing.expect_value(t,count_events(fx,"task_1",EV_APPROVED),0)
    testing.expect_value(t,count_events(fx,"task_1",EV_SUBMITTED),1)
}

controls_input :: proc(t:^testing.T,fx:^Fixture,id,operation,request:string)->Task_Control_Input {
    state,ok,err:=task_control_inspect(&fx.svc,get_task(fx,id),actor_from_auth(user_auth()))
    testing.expect(t,ok,err.message)
    return {operation=operation,reason="regression exercise",request_id=request,expected_generation=state.generation}
}

@(test)
test_coordinator_override_policy_requires_literal_true :: proc(t:^testing.T) {
    fx,log,ok:=lease_fixture(t,"controls_literal_policy")
    defer lease_fixture_close(fx,log)
    if !ok do return
    chain:=seed_live_chain(t,fx,"chain_literal_policy")
    _=seed_task(t,fx,chain,"task_1",`{"goal":"g","acceptance":["a"],"review_roles":[]}`)
    actor:=actor_from_auth(inst_auth("inst_coord"))
    for defaults in ([]string{`{}`,`{"allow_coordinator_override":false}`,`{"allow_coordinator_override":"true"}`,`{"nested":{"allow_coordinator_override":true}}`}) {
        chain.defaults_json=defaults
        _,_,_=iface.taskchain_save_chain(&fx.repo,chain)
        input:=controls_input(t,fx,"task_1","force-complete","invalid-policy")
        input.obligations=[]string{"missing worker evidence"}
        before:=count_all_events(fx,"task_1")
        _,applied,err:=task_control(&fx.svc,get_task(fx,"task_1"),actor,input)
        testing.expect(t,!applied && err.code==.Forbidden,"only explicit top-level boolean true authorizes override")
        testing.expect_value(t,count_all_events(fx,"task_1"),before)
        inspected,iok,ierr:=task_control_inspect(&fx.svc,get_task(fx,"task_1"),actor)
        testing.expect(t,iok,ierr.message)
        testing.expect(t,strings.contains(inspected.actions_json,`"operation":"force-complete","allowed":false`),"inspection agrees with denied override")
    }
}

@(test)
test_coordinator_cancel_fences_worker_and_is_idempotent :: proc(t:^testing.T) {
    fx,log,ok:=lease_fixture(t,"controls_cancel")
    defer lease_fixture_close(fx,log)
    if !ok do return
    chain:=seed_live_chain(t,fx,"chain_cancel_control")
    seed_fleet(fx,chain,"agt_w")
    seed_instance(fx,chain,"inst_w1","agt_w","br_1","idle")
    _=publish_task(t,fx,chain,"task_1",brief=`{"goal":"g","acceptance":["a"],"review_roles":[]}`)
    confirm_holder(fx,"inst_w1")
    lease,held:=lease_of(fx,"inst_w1")
    if !testing.expect(t,held,"worker assigned") do return
    actor:=actor_from_auth(inst_auth("inst_coord"))
    input:=controls_input(t,fx,"task_1","cancel","cancel-once")
    result,cancelled,err:=task_control(&fx.svc,get_task(fx,"task_1"),actor,input)
    if !testing.expect(t,cancelled,err.message) do return
    testing.expect_value(t,result.task.state,domain.Task_State.Cancelled)
    _,still:=lease_of(fx,"inst_w1")
    testing.expect(t,!still,"cancellation revokes current assignment")
    events:=count_all_events(fx,"task_1")
    again,repeated,rerr:=task_control(&fx.svc,get_task(fx,"task_1"),actor,input)
    testing.expect(t,repeated,rerr.message)
    testing.expect_value(t,again.task.state,domain.Task_State.Cancelled)
    testing.expect_value(t,count_all_events(fx,"task_1"),events)
    input.reason="different mutation with reused request"
    _,accepted,cerr:=task_control(&fx.svc,get_task(fx,"task_1"),actor,input)
    testing.expect(t,!accepted && cerr.code==.Conflict,"request identity cannot be reused for different content")
    _,late,lerr:=lease_submit(&fx.svc,inst_auth("inst_w1"),Submit_Input{lease_id=lease.lease_id,summary="late",vcs_json=`{"head":"late","dirty":false}`})
    testing.expect(t,!late && lerr.code==.Conflict,"late worker cannot submit after cancellation")
    testing.expect_value(t,get_task(fx,"task_1").state,domain.Task_State.Cancelled)
    testing.expect_value(t,count_events(fx,"task_1",EV_SUBMITTED),0)
}

@(test)
test_coordinator_revision_conflict_and_completed_cancel_preserve_history :: proc(t:^testing.T) {
    fx,log,ok:=lease_fixture(t,"controls_revision")
    defer lease_fixture_close(fx,log)
    if !ok do return
    chain:=seed_live_chain(t,fx,"chain_revision_control")
    seed_fleet(fx,chain,"agt_w")
    seed_instance(fx,chain,"inst_w1","agt_w","br_1","idle")
    _=publish_task(t,fx,chain,"task_1",brief=`{"goal":"g","acceptance":["a"],"review_roles":[]}`)
    confirm_holder(fx,"inst_w1")
    stale:=controls_input(t,fx,"task_1","cancel","stale-cancel")
    _,submitted,serr:=lease_submit(&fx.svc,inst_auth("inst_w1"),Submit_Input{summary="completed",vcs_json=`{"head":"h1","dirty":false}`})
    if !testing.expect(t,submitted,serr.message) do return
    actor:=actor_from_auth(user_auth())
    _,accepted,err:=task_control(&fx.svc,get_task(fx,"task_1"),actor,stale)
    testing.expect(t,!accepted && err.code==.Conflict,"stale revision rejected inside transaction")
    fresh:=controls_input(t,fx,"task_1","cancel","completed-cancel")
    events:=count_all_events(fx,"task_1")
    _,_,_=task_control(&fx.svc,get_task(fx,"task_1"),actor,fresh)
    testing.expect_value(t,get_task(fx,"task_1").state,domain.Task_State.Done)
    testing.expect_value(t,count_all_events(fx,"task_1"),events)
    testing.expect_value(t,count_events(fx,"task_1",EV_SUBMITTED),1)
}

@(test)
test_coordinator_override_does_not_synthesize_verified_success :: proc(t:^testing.T) {
    fx,log,ok:=lease_fixture(t,"controls_override")
    defer lease_fixture_close(fx,log)
    if !ok do return
    chain:=seed_live_chain(t,fx,"chain_override_control")
    _=seed_task(t,fx,chain,"task_1",`{"goal":"g","acceptance":["a"],"review_roles":[],"on_output":{"start_workflow":"missing-followup"}}`)
    input:=controls_input(t,fx,"task_1","force-complete","force-once")
    input.obligations=[]string{"worker submission absent","user approval absent"}
    _,unauthorized,uerr:=task_control(&fx.svc,get_task(fx,"task_1"),actor_from_auth(inst_auth("inst_coord")),input)
    testing.expect(t,!unauthorized && uerr.code==.Forbidden,"coordinator override requires explicit chain policy")
    result,forced,err:=task_control(&fx.svc,get_task(fx,"task_1"),actor_from_auth(user_auth()),input)
    if !testing.expect(t,forced,err.message) do return
    testing.expect_value(t,result.task.state,domain.Task_State.Done)
    testing.expect_value(t,count_reviews(fx,"task_1"),0)
    testing.expect_value(t,count_events(fx,"task_1",EV_SUBMITTED),0)
    testing.expect_value(t,count_events(fx,"task_1",EV_APPROVED),0)
    testing.expect_value(t,count_events(fx,"task_1",EV_MERGED),0)
    testing.expect_value(t,count_events(fx,"task_1","workflow_trigger_failed"),0)
    runs,runs_err:=iface.taskchain_list_workflow_runs(&fx.repo,chain.chain_id,"u1")
    testing.expect(t,runs_err.code==.None && len(runs)==0,"administrative completion does not trigger follow-up workflow execution")
    snapshot,snapok,serr:=work_item_snapshot(&fx.svc,chain.chain_id,"u1",{kind=domain.WORK_ITEM_TASK,id="task_1"})
    testing.expect(t,snapok,serr.message)
    testing.expect(t,snapshot.terminal && !snapshot.succeeded,"administrative outcome cannot satisfy a prerequisite")
}

// A real bridge round trip returns after an explicit reopen. Its actual effect
// remains audit evidence while the new attempt keeps lifecycle authority.
Controls_Merge_Race :: struct { fx:^Fixture, t:^testing.T, operation:string }
controls_merge_reopen_reply :: proc(raw:rawptr,command:project.Runtime_Command,timeout_ms:int)->(string,bool,domain.Domain_Error) {
    race:=(^Controls_Merge_Race)(raw)
    operation:=race.operation if race.operation!="" else "reopen"
    input:=controls_input(race.t,race.fx,"task_1",operation,"control-during-merge")
    _,ok,err:=task_control(&race.fx.svc,get_task(race.fx,"task_1"),actor_from_auth(user_auth()),input)
    testing.expect(race.t,ok,err.message)
    return strings.clone(`{"ok":false,"conflict":true,"files":["a.odin"]}`),true,{}
}

@(test)
test_coordinator_reopen_fences_inflight_merge_callback :: proc(t:^testing.T) {
    fx,log,ok:=lease_fixture(t,"controls_merge_race")
    defer lease_fixture_close(fx,log)
    if !ok do return
    chain:=seed_live_chain(t,fx,"chain_merge_control")
    seed_fleet(fx,chain,"agt_w")
    seed_instance(fx,chain,"inst_w1","agt_w","br_1","idle")
    _=publish_task(t,fx,chain,"task_1",brief=`{"goal":"g","acceptance":["a"],"review_roles":[]}`)
    confirm_holder(fx,"inst_w1")
    _,submitted,err:=lease_submit(&fx.svc,inst_auth("inst_w1"),Submit_Input{summary="completed",vcs_json=`{"head":"h1","dirty":false}`})
    if !testing.expect(t,submitted,err.message) do return
    task:=get_task(fx,"task_1")
    events,_:=iface.taskchain_list_events_by_task(&fx.repo,task.task_id,task.owner_user_id)
    race:=Controls_Merge_Race{fx=fx,t=t}
    fx.svc.bridge_command_sink={ctx=&race,send_runtime_command_wait=controls_merge_reopen_reply}
    run_merge(&fx.svc,Merge_Effect{owner="u1",task_id="task_1",bridge_id="br_1",repo="/repo",branch="task/1",workdir="/work",attempt_no=task.attempt_no,completion_event_id=merge_completion_event_id(events)})
    row:=get_task(fx,"task_1")
    testing.expect(t,row.state!=.Done && row.state!=.Cancelled,"reopened attempt remains active")
    testing.expect(t,!strings.contains(row.blocked_on_json,"merge_conflict"),"old conflict cannot block reopened result")
    testing.expect_value(t,count_events(fx,"task_1",EV_MERGE_CONFLICT),0)
    testing.expect_value(t,count_events(fx,"task_1","late_merge_outcome"),1)
    assert_projection_matches_fold(t,fx,chain.chain_id,"u1","late merge after reopen")
}

@(test)
test_coordinator_cancel_review_revokes_all_participants_without_erasing_evidence :: proc(t:^testing.T) {
    fx,log,ok:=lease_fixture(t,"controls_cancel_review")
    defer lease_fixture_close(fx,log)
    if !ok do return
    chain:=seed_live_chain(t,fx,"chain_cancel_review_control")
    seed_fleet(fx,chain,"agt_w")
    seed_fleet(fx,chain,"agt_r",roles=`["reviewer"]`)
    seed_instance(fx,chain,"inst_w1","agt_w","br_1","idle")
    seed_instance(fx,chain,"inst_r1","agt_r","br_1","idle")
    _=publish_task(t,fx,chain,"task_1",brief=`{"goal":"g","acceptance":["a"],"review_roles":["reviewer"]}`)
    confirm_holder(fx,"inst_w1")
    _,submitted,err:=lease_submit(&fx.svc,inst_auth("inst_w1"),Submit_Input{summary="review this",vcs_json=`{"head":"h1","dirty":false}`})
    if !testing.expect(t,submitted,err.message) do return
    review,assigned:=lease_of(fx,"inst_r1")
    if !testing.expect(t,assigned,"reviewer assigned") do return
    input:=controls_input(t,fx,"task_1","cancel","cancel-review")
    _,cancelled,cerr:=task_control(&fx.svc,get_task(fx,"task_1"),actor_from_auth(inst_auth("inst_coord")),input)
    if !testing.expect(t,cancelled,cerr.message) do return
    for id in ([]string{"inst_w1","inst_r1"}) {
        _,bound:=lease_of(fx,id)
        testing.expect(t,!bound,"all participants lose current assignment")
    }
    _,late,lerr:=review_post(&fx.svc,inst_auth("inst_r1"),Review_Input{lease_id=review.lease_id,verdict="approve"})
    testing.expect(t,!late && lerr.code==.Conflict,"cancelled reviewer cannot approve")
    _,human,herr:=user_review(&fx.svc,user_auth(),"task_1",Review_Input{verdict="approve"})
    testing.expect(t,!human && herr.code==.Conflict,"late user review cannot revive task")
    testing.expect_value(t,count_events(fx,"task_1",EV_SUBMITTED),1)
    testing.expect_value(t,count_reviews(fx,"task_1"),0)
    testing.expect_value(t,get_task(fx,"task_1").state,domain.Task_State.Cancelled)
    snapshot,snapok,serr:=work_item_snapshot(&fx.svc,chain.chain_id,"u1",{kind=domain.WORK_ITEM_TASK,id="task_1"})
    testing.expect(t,snapok,serr.message)
    testing.expect(t,snapshot.terminal && !snapshot.succeeded,"cancelled prerequisite remains unsatisfied")
    assert_projection_matches_fold(t,fx,chain.chain_id,"u1","cancel review")
}


@(test)
test_coordinator_cancel_completing_task_wins_over_inflight_merge :: proc(t:^testing.T) {
    fx,log,ok:=lease_fixture(t,"controls_cancel_merge")
    defer lease_fixture_close(fx,log)
    if !ok do return
    chain:=seed_live_chain(t,fx,"chain_cancel_merge_control")
    seed_fleet(fx,chain,"agt_w")
    seed_instance(fx,chain,"inst_w1","agt_w","br_1","idle")
    _=publish_task(t,fx,chain,"task_1",brief=`{"goal":"g","acceptance":["a"],"review_roles":[]}`)
    confirm_holder(fx,"inst_w1")
    _,submitted,err:=lease_submit(&fx.svc,inst_auth("inst_w1"),Submit_Input{summary="completed work",vcs_json=`{"head":"h1","dirty":false}`})
    if !testing.expect(t,submitted,err.message) do return
    task:=get_task(fx,"task_1")
    u,uok,uerr:=begin_uow(&fx.svc)
    if !testing.expect(t,uok,uerr.message) do return
    _,_,recorded,rerr:=record_event(&fx.svc,&u,task,hub_actor(),EV_MERGE_SNAPSHOT,`{"applicable":true}`)
    _,cerr:=end_uow(&fx.svc,&u,recorded)
    if !testing.expect(t,recorded && cerr.code==.None,rerr.message) do return
    testing.expect_value(t,task_merge_status(&fx.svc,get_task(fx,"task_1")).state,"pending")
    events,_:=iface.taskchain_list_events_by_task(&fx.repo,task.task_id,task.owner_user_id)
    race:=Controls_Merge_Race{fx=fx,t=t,operation="cancel"}
    fx.svc.bridge_command_sink={ctx=&race,send_runtime_command_wait=controls_merge_reopen_reply}
    run_merge(&fx.svc,Merge_Effect{owner="u1",task_id="task_1",bridge_id="br_1",repo="/repo",branch="task/1",workdir="/work",attempt_no=task.attempt_no,completion_event_id=merge_completion_event_id(events)})
    testing.expect_value(t,get_task(fx,"task_1").state,domain.Task_State.Cancelled)
    testing.expect_value(t,count_events(fx,"task_1",EV_MERGE_CONFLICT),0)
    testing.expect_value(t,count_events(fx,"task_1","late_merge_outcome"),1)
    testing.expect_value(t,count_events(fx,"task_1",EV_SUBMITTED),1)
    _,_,_=task_recheck(&fx.svc,get_task(fx,"task_1"),actor_from_auth(user_auth()))
    testing.expect_value(t,get_task(fx,"task_1").state,domain.Task_State.Cancelled)
    assert_projection_matches_fold(t,fx,chain.chain_id,"u1","cancel completing task")
}

@(test)
test_coordinator_rereview_requires_new_submission_before_approval :: proc(t:^testing.T) {
    fx,log,ok:=lease_fixture(t,"controls_rereview")
    defer lease_fixture_close(fx,log)
    if !ok do return
    chain:=seed_live_chain(t,fx,"chain_rereview_control")
    seed_fleet(fx,chain,"agt_w")
    seed_instance(fx,chain,"inst_w1","agt_w","br_1","idle")
    _=publish_task(t,fx,chain,"task_1",brief=`{"goal":"g","acceptance":["a"],"review_roles":[]}`)
    row:=get_task(fx,"task_1"); row.requires_user_approval=true
    _,_,_=iface.taskchain_save_task(&fx.repo,row)
    confirm_holder(fx,"inst_w1")
    _,submitted,err:=lease_submit(&fx.svc,inst_auth("inst_w1"),Submit_Input{summary="first result",vcs_json=`{"head":"h1","dirty":false}`})
    if !testing.expect(t,submitted,err.message) do return
    input:=controls_input(t,fx,"task_1","rereview","rereview-once")
    _,changed,cerr:=task_control(&fx.svc,get_task(fx,"task_1"),actor_from_auth(inst_auth("inst_coord")),input)
    if !testing.expect(t,changed,cerr.message) do return
    testing.expect_value(t,get_task(fx,"task_1").attempt_no,2)
    _,old,old_err:=user_review(&fx.svc,user_auth(),"task_1",Review_Input{verdict="approve"})
    testing.expect(t,!old && old_err.code==.Conflict,"prior result cannot be approved during rework")
    testing.expect_value(t,count_reviews(fx,"task_1"),0)
    confirm_holder(fx,"inst_w1")
    _,resubmitted,rerr:=lease_submit(&fx.svc,inst_auth("inst_w1"),Submit_Input{summary="new result",vcs_json=`{"head":"h2","dirty":false}`})
    if !testing.expect(t,resubmitted,rerr.message) do return
    _,approved,aerr:=user_review(&fx.svc,user_auth(),"task_1",Review_Input{verdict="approve"})
    testing.expect(t,approved,aerr.message)
    testing.expect_value(t,get_task(fx,"task_1").state,domain.Task_State.Done)
}

@(test)
test_coordinator_policy_override_and_owner_inspection :: proc(t:^testing.T) {
    fx,log,ok:=lease_fixture(t,"controls_inspection")
    defer lease_fixture_close(fx,log)
    if !ok do return
    chain:=seed_live_chain(t,fx,"chain_inspect_control")
    chain.defaults_json=`{"allow_coordinator_override":true}`
    _,_,_=iface.taskchain_save_chain(&fx.repo,chain)
    seed_fleet(fx,chain,"agt_w")
    seed_instance(fx,chain,"inst_w1","agt_w","br_1","idle")
    _=publish_task(t,fx,chain,"task_1",brief=`{"goal":"g","acceptance":["a"],"review_roles":[]}`)
    confirm_holder(fx,"inst_w1")
    actor:=actor_from_auth(inst_auth("inst_coord"))
    inspected,iok,ierr:=task_control_inspect(&fx.svc,get_task(fx,"task_1"),actor)
    if !testing.expect(t,iok,ierr.message) do return
    testing.expect(t,strings.contains(inspected.owners_json,`"instance_id":"inst_w1"`),"owner instance visible")
    testing.expect(t,strings.contains(inspected.owners_json,`"agent_id":"agt_w"`) && strings.contains(inspected.owners_json,`"runtime_status"`),"durable identity and runtime visible")
    testing.expect(t,strings.contains(inspected.actions_json,"only a done or cancelled task can be reopened"),"refused reopen explains lifecycle prerequisite")
    input:=controls_input(t,fx,"task_1","force-complete","policy-override")
    input.obligations=[]string{"accept administrative outcome"}
    result,forced,ferr:=task_control(&fx.svc,get_task(fx,"task_1"),actor,input)
    if !testing.expect(t,forced,ferr.message) do return
    testing.expect_value(t,result.outcome,"overridden")
    testing.expect(t,len(result.obligations)>1,"actual unmet obligations supplement supplied reason")
    testing.expect_value(t,count_reviews(fx,"task_1"),0)
    events,_:=iface.taskchain_list_events_by_task(&fx.repo,"task_1","u1")
    attributed:=false
    for event in events do if event.kind==EV_ADMIN_COMPLETED {attributed=event.actor_id=="inst_coord" && event.actor_kind!=ACTOR_USER}
    testing.expect(t,attributed,"override remains coordinator evidence")
}
