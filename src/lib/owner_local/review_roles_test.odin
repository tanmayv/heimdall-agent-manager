#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

role_auditor :: proc()->Child {return {"audit_instance","audit_epoch",strings.repeat("c",64,context.temp_allocator),1,"auditor"}}
role_test_config :: proc(user:string="0")->string {
    return encode(doc(map[string]string{"configuration_revision"="1","requires_user_approval"=user,"pairs"=`[{"role":"safety","agent_id":"auditor","instance_id":"audit_instance"},{"role":"correctness","agent_id":"auditor","instance_id":"audit_instance"}]`}))
}
role_test_ready :: proc(t:^testing.T,f:^Fixture)->string {
    children:=[1]Child{role_auditor()}
    testing.expect_value(t,advanced_call(f,"review.roles","roles",role_test_config("1"),"task",children[:]).code,"ok")
    r:=lease_invoke(f,lease_request(f,lease_child(),"lease.claim","claim","lease","","5"),"",lease_child())
    if !testing.expect_value(t,r.code,"ok") do return ""
    cap:=result_cap(r)
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.present","present",`{"requirements_revision":"1"}`,cap,"5").code,"ok")
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.ack","ack",`{"requirements_revision":"1"}`,cap,"5").code,"ok")
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","submit",`{"requirements_revision":"1","head":"","summary":"roleoutputneedle"}`,cap,"5").code,"ok")
    return cap
}
role_payload_test :: proc(role:string,verdict:string="approve")->string {
    p,_:=contracts.owner_parse(lifecycle_verdict(),"review_payload")
    p["role"]=json.String(role);p["verdict"]=json.String(verdict)
    return encode(p)
}
@(test)
review_roles_require_every_pair_and_configured_user_approval :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    if role_test_ready(t,f)=="" do return
    p:=lifecycle_verdict()
    primary:=lifecycle_call(f,lifecycle_reviewer(),"review.open","open_primary",p,"","6")
    safety:=role_payload_test("safety")
    audit:=lifecycle_call(f,role_auditor(),"review.role.open","open_audit",safety,"","6")
    if !testing.expect_value(t,primary.code,"ok") || !testing.expect_value(t,audit.code,"ok") do return
    // Opening a second child must not steal the first review session.
    sessions,_:=query(f.store.db,"SELECT count(*) FROM local_review_sessions")
    testing.expect_value(t,sessions[0][0],"2")
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.post","primary",p,result_cap(primary),"6").code,"ok")
    testing.expect_value(t,lifecycle_call(f,role_auditor(),"review.role.post","safety",safety,result_cap(audit),"7").code,"ok")
    state,_:=query(f.store.db,"SELECT state FROM lifecycle_state")
    testing.expect_value(t,state[0][0],"in_review")
    testing.expect_value(t,lifecycle_call(f,role_auditor(),"review.role.post","correctness",role_payload_test("correctness"),result_cap(audit),"8").code,"ok")
    state,_=query(f.store.db,"SELECT state FROM lifecycle_state")
    testing.expect(t,state[0][0]=="in_review","configured human gate still required")
    testing.expect_value(t,invoke(f,command(f,"review.post","human","task",p,"9"),p).code,"ok")
    state,_=query(f.store.db,"SELECT state,(SELECT count(*) FROM local_role_reviews),(SELECT count(*) FROM source_consumptions) FROM lifecycle_state")
    testing.expect(t,state[0][0]=="done" && state[0][1]=="2" && state[0][2]=="4","each exact result consumes separately in the commit")
}
@(test)
review_role_changes_win_author_exclusion_and_stale_attempt_rejection :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    bad:=encode(doc(map[string]string{"configuration_revision"="1","requires_user_approval"="0","pairs"=`[{"role":"safety","agent_id":"author","instance_id":"instance"}]`}))
    children:=[1]Child{lease_child()}
    testing.expect_value(t,advanced_call(f,"review.roles","self_roles",bad,"task",children[:]).code,"invalid_scope")
    rows,_:=query(f.store.db,"SELECT count(*) FROM local_role_configs")
    testing.expect(t,rows[0][0]=="0","invalid role candidate rolls back its header")
    if role_test_ready(t,f)=="" do return
    p:=role_payload_test("safety","request_changes")
    testing.expect_value(t,lifecycle_call(f,lease_child(),"review.role.open","self_open",p,"","6").code,"invalid_scope")
    opened:=lifecycle_call(f,role_auditor(),"review.role.open","audit_open",p,"","6")
    if !testing.expect_value(t,opened.code,"ok") do return
    testing.expect_value(t,lifecycle_call(f,role_auditor(),"review.role.post","changes",p,result_cap(opened),"6").code,"ok")
    state,_:=query(f.store.db,"SELECT state FROM lifecycle_state")
    testing.expect_value(t,state[0][0],"ready")
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.open","late_approve",lifecycle_verdict(),"","7").code,"stale_revision")
    replay:=lifecycle_call(f,role_auditor(),"review.role.post","changes",p,result_cap(opened),"6",{},4000000)
    testing.expect(t,replay.code=="ok" && replay.replay,"exact result replay after release remains historical")
}

@(test)
review_role_gate_storage_failure_never_waives_required_pairs :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    if role_test_ready(t,f)=="" do return
    p:=lifecycle_verdict()
    opened:=lifecycle_call(f,lifecycle_reviewer(),"review.open","open",p,"","6")
    if !testing.expect_value(t,opened.code,"ok") do return
    testing.expect(t,exec(f.store.db,"ALTER TABLE local_role_configs RENAME TO role_configs_unavailable"))
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.post","vote",p,result_cap(opened),"6").code,"storage_error")
    rows,_:=query(f.store.db,"SELECT state,(SELECT count(*) FROM local_reviews),(SELECT count(*) FROM command_receipts WHERE operation_id='vote') FROM lifecycle_state")
    testing.expect(t,rows[0][0]=="in_review" && rows[0][1]=="0" && rows[0][2]=="0")
    testing.expect(t,exec(f.store.db,"ALTER TABLE role_configs_unavailable RENAME TO local_role_configs"))
}

@(test)
review_role_reconfiguration_while_held_cannot_resume_stale_review :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    if role_test_ready(t,f)=="" do return
    testing.expect_value(t,control_call(f,"task.hold","hold","6").code,"ok")
    config,_:=contracts.owner_parse(role_test_config("1"),"review_roles")
    config["configuration_revision"]=json.String("2")
    children:=[1]Child{role_auditor()}
    testing.expect_value(t,advanced_call(f,"review.roles","new_roles",encode(config),"task",children[:]).code,"ok")
    testing.expect_value(t,control_call(f,"task.release","release","8").code,"ok")
    rows,_:=query(f.store.db,"SELECT state,(SELECT resume_state FROM local_controls) FROM lifecycle_state")
    testing.expect(t,rows[0][0]=="ready" && rows[0][1]=="ready")
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.open","stale_open",lifecycle_verdict(),"","9").code,"stale_revision")
}
