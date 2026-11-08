#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

// R2-1/R3-1: only a device-signed review is the user; an agent principal may
// add requires_user_approval but never remove it.

USER_GATE_BRIEF :: `{"goal":"Complete scoped work","acceptance":["Tests pass"],"requires_user_approval":true}`

// lifecycle_seed with a brief that requires the user's approval.
user_gate_seed :: proc(t:^testing.T,f:^Fixture,brief:=USER_GATE_BRIEF) {
    child:=lease_child();fleet_seed(t,f,child)
    raw:=encode(doc(map[string]string{"configuration_revision"="1","author_agent_id"="author","reviewer_agent_id"="reviewer","reviewer_instance_id"="review_instance","directory_id"="directory","merge_policy"="none","repository"="","worktree"="","source_branch"="","target_branch"="","base_head"=""}))
    c:=command(f,"lifecycle.configure","config","task",raw,"2")
    testing.expect_value(t,execute(&f.store,c,raw,"",f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},{},Lifecycle_Proof{child,lifecycle_reviewer(),true}).code,"ok")
    p:=encode(doc(map[string]string{"requirements_revision"="1","body_cipher"=cipher(f,brief)}))
    testing.expect_value(t,invoke(f,command(f,"requirements.edit","req1","task",p,"3"),p).code,"ok")
}
user_gate_state :: proc(f:^Fixture) -> string {
    rows,_:=query(f.store.db,"SELECT state FROM lifecycle_state WHERE chain_id='chain' AND task_id='task'")
    return rows[0][0] if len(rows)==1 else ""
}
// Submit attempt 1 and record the independent reviewer's approval.
user_gate_reviewed :: proc(t:^testing.T,f:^Fixture) -> bool {
    cap:=lifecycle_ready(t,f)
    if cap=="" do return false
    if !testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","submit",`{"requirements_revision":"1","head":"","summary":"Checks pass"}`,cap).code,"ok") do return false
    p:=lifecycle_verdict()
    opened:=lifecycle_call(f,lifecycle_reviewer(),"review.open","open",p,"",agent_task_revision(f,"task"))
    if !testing.expect_value(t,opened.code,"ok") do return false
    return testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.post","post",p,result_cap(opened),agent_task_revision(f,"task")).code,"ok")
}
user_gate_requirements :: proc(f:^Fixture,agent:Child,op,revision,brief:string) -> Result {
    p:=encode(doc(map[string]string{"requirements_revision"=revision,"body_cipher"=cipher(f,brief)}))
    if agent.instance=="" do return invoke(f,command(f,"requirements.edit",op,"task",p,agent_task_revision(f,"task")),p)
    return agent_run(f,agent,"requirements.edit",op,"task",p,agent_task_revision(f,"task"))
}

@(test)
user_gate_coordinator_relay_never_counts_as_user :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);user_gate_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    if !user_gate_reviewed(t,f) do return
    testing.expect_value(t,user_gate_state(f),"in_review")
    // The coordinator's review post --on-behalf-of user (review.human) is
    // recorded, as an agent row, and the gate keeps waiting for the user.
    p:=lifecycle_verdict()
    testing.expect_value(t,agent_run(f,coord,"review.post","relay","task",p,agent_task_revision(f,"task")).code,"ok")
    testing.expect_value(t,user_gate_state(f),"in_review")
    rows,_:=query(f.store.db,"SELECT principal_id,principal_kind FROM local_reviews WHERE principal_id='coord_instance'")
    testing.expect_value(t,encode(rows),encode([1][2]string{{"coord_instance","agent"}}))
    // The user's own device-signed review satisfies the gate.
    testing.expect_value(t,invoke(f,command(f,"review.post","human","task",p,agent_task_revision(f,"task")),p).code,"ok")
    testing.expect_value(t,user_gate_state(f),"done")
    rows,_=query(f.store.db,"SELECT principal_kind FROM local_reviews WHERE principal_id='device'")
    testing.expect_value(t,encode(rows),encode([1][1]string{{"device"}}))
}

@(test)
user_gate_agent_request_changes_still_returns_the_task :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);user_gate_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    if !user_gate_reviewed(t,f) do return
    p,_:=contracts.owner_parse(lifecycle_verdict(),"review_payload");p["verdict"]=json.String("request_changes")
    testing.expect_value(t,agent_run(f,coord,"review.post","relay_changes","task",encode(p),agent_task_revision(f,"task")).code,"ok")
    testing.expect_value(t,user_gate_state(f),"ready")
}

@(test)
user_gate_requirements_ratchet_agents_add_only :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);user_gate_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    // An agent cannot drop the flag, by omission or explicitly.
    testing.expect_value(t,user_gate_requirements(f,coord,"drop","2",`{"goal":"g","acceptance":["a"]}`).code,"invalid_scope")
    testing.expect_value(t,user_gate_requirements(f,coord,"unset","2",`{"goal":"g","acceptance":["a"],"requires_user_approval":false}`).code,"invalid_scope")
    required,ok:=task_user_approval_required(&f.store,"chain","task")
    testing.expect(t,ok && required,"a refused agent edit leaves the gate in place")
    // Keeping it is an ordinary edit.
    testing.expect_value(t,user_gate_requirements(f,coord,"keep","2",`{"goal":"g2","acceptance":["a"],"requires_user_approval":true}`).code,"ok")
    // The user's device may remove it.
    testing.expect_value(t,user_gate_requirements(f,{},"device_unset","3",`{"goal":"g3","acceptance":["a"]}`).code,"ok")
    required,ok=task_user_approval_required(&f.store,"chain","task")
    testing.expect(t,ok && !required,"a device edit removes the gate")
    // An agent may add it back.
    testing.expect_value(t,user_gate_requirements(f,coord,"add","4",USER_GATE_BRIEF).code,"ok")
    required,ok=task_user_approval_required(&f.store,"chain","task")
    testing.expect(t,ok && required,"an agent adds the gate")
}

@(test)
user_gate_review_roles_ratchet :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    children:=[1]Child{role_auditor()}
    testing.expect_value(t,advanced_call(f,"review.roles","roles",role_test_config("1"),"task",children[:]).code,"ok")
    // The coordinator may configure roles (P-CS CC-A) but the ratchet refuses
    // clearing the flag on the agent path.
    cleared,_:=contracts.owner_parse(role_test_config("0"),"review_roles");cleared["configuration_revision"]=json.String("2")
    testing.expect_value(t,agent_run(f,coord,"review.roles","agent_roles","task",encode(doc(map[string]string{"body_cipher"=cipher(f,encode(cleared))})),agent_task_revision(f,"task")).code,"invalid_scope")
    // The owner-side ratchet itself: a non-device principal cannot clear the
    // configured flag, but may keep it; the device may clear it.
    c:=doc(map[string]string{"chain_id"="chain","task_id"="task","principal_id"="coord_instance","operation_id"="ratchet"})
    testing.expect_value(t,role_configure(&f.store,c,encode(cleared),children[:],99,false),"invalid_scope")
    rows,_:=query(f.store.db,"SELECT count(*),max(requires_user_approval) FROM local_role_configs")
    testing.expect_value(t,encode(rows),encode([1][2]string{{"1","1"}}))
    testing.expect_value(t,advanced_call(f,"review.roles","device_clear",encode(cleared),"task",children[:]).code,"ok")
    required,ok:=task_user_approval_required(&f.store,"chain","task")
    testing.expect(t,ok && !required,"the device cleared the role gate")
    testing.expect(t,approval_ratchet_allows(false,true,false) && approval_ratchet_allows(true,true,false) && !approval_ratchet_allows(true,false,false) && approval_ratchet_allows(true,false,true))
}

@(test)
user_gate_lifecycle_configure_cannot_remove_the_gate :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);user_gate_seed(t,f)
    coord,worker,reviewer:=agent_coordinator_child(),lease_child(),lifecycle_reviewer()
    agent_seat_coordinator(t,f,coord);agent_seat(t,f,reviewer,"reviewer")
    config:=doc(map[string]string{"configuration_revision"="2","author_agent_id"=worker.agent_id,"reviewer_agent_id"=reviewer.agent_id,"reviewer_instance_id"=reviewer.instance,"directory_id"="owner_none","merge_policy"="none","repository"="","worktree"="","source_branch"="","target_branch"="","base_head"=""})
    // The payload has no flag to clear: one carrying requires_user_approval is malformed.
    withflag:=doc(map[string]string{"requires_user_approval"="0"})
    for k,v in config do withflag[k]=v
    raw:=encode(withflag)
    testing.expect_value(t,execute_agent(&f.store,agent_command(f,coord,"lifecycle.configure","config_flag","task",raw,agent_task_revision(f,"task")),raw,coord,f.owner,1000,&f.kr,Signer{&f.owner_priv,test_sign},{},Lifecycle_Proof{worker,reviewer,true}).code,"malformed")
    raw=encode(config)
    testing.expect_value(t,execute_agent(&f.store,agent_command(f,coord,"lifecycle.configure","config2","task",raw,agent_task_revision(f,"task")),raw,coord,f.owner,1000,&f.kr,Signer{&f.owner_priv,test_sign},{},Lifecycle_Proof{worker,reviewer,true}).code,"ok")
    required,ok:=task_user_approval_required(&f.store,"chain","task")
    testing.expect(t,ok && required,"a coordinator reconfiguration keeps the user gate")
}

@(test)
user_gate_migration_backfills_principal_kind_without_regating :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);user_gate_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    if !user_gate_reviewed(t,f) do return
    p:=lifecycle_verdict()
    testing.expect_value(t,agent_run(f,coord,"review.post","relay","task",p,agent_task_revision(f,"task")).code,"ok")
    testing.expect_value(t,invoke(f,command(f,"review.post","human","task",p,agent_task_revision(f,"task")),p).code,"ok")
    testing.expect_value(t,user_gate_state(f),"done")
    // Simulate V34 rows: every review carries the column default ('agent').
    close(&f.store)
    db:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    testing.expect(t,exec(db,"DROP TRIGGER local_reviews_immutable; UPDATE local_reviews SET principal_kind='agent'; CREATE TRIGGER local_reviews_immutable BEFORE UPDATE ON local_reviews BEGIN SELECT RAISE(ABORT,'immutable lifecycle evidence'); END; UPDATE schema_migrations SET version=34"))
    testing.expect_value(t,sqlite3_close(db),0)
    if !testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key")) do return
    rows,_:=query(f.store.db,"SELECT reviewer_agent_id,principal_kind FROM local_reviews ORDER BY reviewer_agent_id")
    testing.expect_value(t,encode(rows),encode([3][2]string{{"coord_instance","agent"},{"device","device"},{"reviewer","agent"}}))
    version,_:=query(f.store.db,"SELECT schema_version,(SELECT version FROM schema_migrations) FROM runtime_database")
    testing.expect_value(t,encode(version),encode([1][2]string{{"35","35"}}))
    // An attempt already past the gate is not re-gated.
    testing.expect_value(t,user_gate_state(f),"done")
    // Review evidence stays immutable after the backfill.
    testing.expect(t,!exec(f.store.db,"UPDATE local_reviews SET principal_kind='device'"))
}

@(test)
user_gate_migration_keeps_waiting_attempts_on_the_device :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);user_gate_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    if !user_gate_reviewed(t,f) do return
    p:=lifecycle_verdict()
    testing.expect_value(t,agent_run(f,coord,"review.post","relay","task",p,agent_task_revision(f,"task")).code,"ok")
    testing.expect_value(t,user_gate_state(f),"in_review")
    close(&f.store)
    db:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    testing.expect(t,exec(db,"UPDATE schema_migrations SET version=34"))
    testing.expect_value(t,sqlite3_close(db),0)
    if !testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key")) do return
    testing.expect_value(t,user_gate_state(f),"in_review")
    rows,_:=query(f.store.db,"SELECT principal_kind FROM local_reviews WHERE principal_id='coord_instance'")
    testing.expect_value(t,encode(rows),encode([1][1]string{{"agent"}}))
    testing.expect_value(t,invoke(f,command(f,"review.post","human","task",p,agent_task_revision(f,"task")),p).code,"ok")
    testing.expect_value(t,user_gate_state(f),"done")
}
