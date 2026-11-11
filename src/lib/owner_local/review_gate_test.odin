#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

// A task's review gate is brief.reviewers (agent ids) plus the configured
// independent reviewer, and requires_user_approval.
gate_auditor :: proc()->Child {return {"audit_instance","audit_epoch",strings.repeat("c",64,context.temp_allocator),1,"auditor"}}
gate_second :: proc()->Child {return {"second_instance","second_epoch",strings.repeat("d",64,context.temp_allocator),1,"second"}}
gate_stranger :: proc()->Child {return {"stranger_instance","stranger_epoch",strings.repeat("e",64,context.temp_allocator),1,"stranger"}}

// lifecycle_seed with a brief naming reviewers (and optionally the user gate):
// the task is at revision 4 with requirements revision 1.
gate_seed :: proc(t:^testing.T,f:^Fixture,reviewers:string,user:=false) {
    child:=lease_child();fleet_seed(t,f,child)
    raw:=encode(doc(map[string]string{"configuration_revision"="1","author_agent_id"="author","reviewer_agent_id"="reviewer","reviewer_instance_id"="review_instance","directory_id"="directory","merge_policy"="none","repository"="","worktree"="","source_branch"="","target_branch"="","base_head"=""}))
    testing.expect_value(t,execute(&f.store,command(f,"lifecycle.configure","config","task",raw,"2"),raw,"",f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},{},Lifecycle_Proof{child,lifecycle_reviewer(),true}).code,"ok")
    brief:=strings.concatenate({`{"goal":"Complete scoped work","acceptance":["Tests pass"],"reviewers":`,reviewers,`,"requires_user_approval":true` if user else "","}"},context.temp_allocator)
    p:=encode(doc(map[string]string{"requirements_revision"="1","body_cipher"=cipher(f,brief)}))
    testing.expect_value(t,invoke(f,command(f,"requirements.edit","req1","task",p,"3"),p).code,"ok")
}
// Claim, acknowledge and submit attempt 1 (task revision 5 afterwards).
gate_submit :: proc(t:^testing.T,f:^Fixture)->bool {
    r:=lease_invoke(f,lease_request(f,lease_child(),"lease.claim","claim","lease","","4"),"",lease_child())
    if !testing.expect_value(t,r.code,"ok") do return false
    cap:=result_cap(r)
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.present","present",`{"requirements_revision":"1"}`,cap,"4").code,"ok")
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.ack","ack",`{"requirements_revision":"1"}`,cap,"4").code,"ok")
    return testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","submit",`{"requirements_revision":"1","head":"","summary":"gate work"}`,cap,"4").code,"ok")
}
gate_state :: proc(f:^Fixture)->string {
    rows,_:=query(f.store.db,"SELECT state FROM lifecycle_state")
    return rows[0][0] if len(rows)==1 else ""
}
gate_task_revision :: proc(f:^Fixture)->string {
    rows,_:=query(f.store.db,"SELECT revision FROM tasks WHERE chain_id='chain' AND task_id='task'")
    return rows[0][0] if len(rows)==1 else ""
}
// review.open then review.post for one reviewer child.
gate_review :: proc(t:^testing.T,f:^Fixture,child:Child,op,verdict:string)->string {
    p,_:=json.parse_string(lifecycle_verdict(),.JSON,true,context.temp_allocator)
    o:=p.(json.Object);o["verdict"]=json.String(verdict)
    payload:=encode(o)
    opened:=lifecycle_call(f,child,"review.open",fmt.tprintf("%s_open",op),payload,"",gate_task_revision(f))
    if opened.code!="ok" do return opened.code
    return lifecycle_call(f,child,"review.post",op,payload,result_cap(opened),gate_task_revision(f)).code
}

@(test)
review_gate_requires_every_listed_reviewer :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    gate_seed(t,f,`["auditor","second"]`)
    if !gate_submit(t,f) do return
    // Each reviewer holds its own session; opening one never steals another.
    p:=lifecycle_verdict()
    testing.expect_value(t,lifecycle_call(f,gate_auditor(),"review.open","open_a",p,"","5").code,"ok")
    testing.expect_value(t,lifecycle_call(f,gate_second(),"review.open","open_b",p,"","5").code,"ok")
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.open","open_r",p,"","5").code,"ok")
    sessions,_:=query(f.store.db,"SELECT count(*) FROM local_review_sessions")
    testing.expect_value(t,sessions[0][0],"3")
    // Neither an unlisted agent nor the author reviews.
    testing.expect_value(t,lifecycle_call(f,gate_stranger(),"review.open","open_x",p,"","5").code,"invalid_scope")
    testing.expect_value(t,lifecycle_call(f,lease_child(),"review.open","open_self",p,"","5").code,"invalid_scope")
    testing.expect_value(t,gate_review(t,f,lifecycle_reviewer(),"vote_r","approve"),"ok")
    testing.expect_value(t,gate_state(f),"in_review")
    testing.expect_value(t,gate_review(t,f,gate_auditor(),"vote_a","approve"),"ok")
    testing.expect(t,gate_state(f)=="in_review","the second listed reviewer still owes a verdict")
    owed,_:=review_owed(&f.store,"chain","task","1",lifecycle_config_test(f))
    testing.expect_value(t,encode(owed),`["second"]`)
    testing.expect_value(t,gate_review(t,f,gate_second(),"vote_b","approve"),"ok")
    testing.expect_value(t,gate_state(f),"done")
    rows,_:=query(f.store.db,"SELECT group_concat(reviewer_agent_id,',') FROM (SELECT reviewer_agent_id FROM local_reviews ORDER BY reviewer_agent_id)")
    testing.expect_value(t,rows[0][0],"auditor,reviewer,second")
}

@(test)
review_gate_user_approval_after_every_reviewer :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    gate_seed(t,f,`["auditor"]`,user=true)
    if !gate_submit(t,f) do return
    testing.expect_value(t,gate_review(t,f,lifecycle_reviewer(),"vote_r","approve"),"ok")
    testing.expect_value(t,gate_review(t,f,gate_auditor(),"vote_a","approve"),"ok")
    testing.expect(t,gate_state(f)=="in_review","the user's approval is still owed")
    // The user's own device-signed review settles it.
    p:=lifecycle_verdict()
    testing.expect_value(t,invoke(f,command(f,"review.post","human","task",p,gate_task_revision(f)),p).code,"ok")
    testing.expect_value(t,gate_state(f),"done")
}

@(test)
review_gate_user_approval_alone_still_needs_reviewers :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    gate_seed(t,f,`["auditor"]`,user=true)
    if !gate_submit(t,f) do return
    p:=lifecycle_verdict()
    testing.expect_value(t,invoke(f,command(f,"review.post","human","task",p,"5"),p).code,"ok")
    testing.expect_value(t,gate_state(f),"in_review")
    testing.expect_value(t,gate_review(t,f,lifecycle_reviewer(),"vote_r","approve"),"ok")
    testing.expect_value(t,gate_state(f),"in_review")
    testing.expect_value(t,gate_review(t,f,gate_auditor(),"vote_a","approve"),"ok")
    testing.expect_value(t,gate_state(f),"done")
}

@(test)
review_gate_any_listed_reviewer_requests_changes :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    gate_seed(t,f,`["auditor","second"]`)
    if !gate_submit(t,f) do return
    testing.expect_value(t,gate_review(t,f,lifecycle_reviewer(),"vote_r","approve"),"ok")
    testing.expect_value(t,gate_review(t,f,gate_auditor(),"vote_a","request_changes"),"ok")
    testing.expect_value(t,gate_state(f),"ready")
    // The attempt is settled: a late reviewer is stale.
    testing.expect_value(t,lifecycle_call(f,gate_second(),"review.open","late",lifecycle_verdict(),"",gate_task_revision(f)).code,"stale_revision")
}

// A brief naming the task's author or a chain coordinator as a reviewer can
// never settle, so every brief source refuses it (invalid_scope).
@(test)
review_gate_brief_never_names_author_or_coordinator :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=cw_split_setup(t);defer destroy(f)
    coord:=agent_coordinator_child()
    edit :: proc(f:^Fixture,op,brief:string) -> string {
        p:=encode(doc(map[string]string{"requirements_revision"="2","body_cipher"=cipher(f,brief)}))
        return invoke(f,command(f,"requirements.edit",op,"task",p,agent_task_revision(f,"task")),p).code
    }
    // requirements.edit: the configured author, a coordinator, the brief's own assignee.
    testing.expect_value(t,edit(f,"author",`{"goal":"g","acceptance":["a"],"reviewers":["auditor","author"]}`),"invalid_scope")
    testing.expect_value(t,edit(f,"coord",`{"goal":"g","acceptance":["a"],"reviewers":["coordinator_agent"]}`),"invalid_scope")
    testing.expect_value(t,edit(f,"assignee",`{"goal":"g","acceptance":["a"],"assignee":"auditor","reviewers":["auditor"]}`),"invalid_scope")
    testing.expect_value(t,cc_scalar(f,"SELECT max(revision) FROM task_requirements WHERE task_id='task'"),"1")
    // task.split: a child inherits the original's author.
    for reviewer,i in ([2]string{"author","coordinator_agent"}) {
        body:=fmt.tprintf(`{{"reason":"split","dependents":"all","children":[{{"task_id":"c%d","title":"Half","brief":{{"goal":"Half","acceptance":["a"],"reviewers":["%s"]}}}}]}}`,i,reviewer)
        testing.expectf(t,cw_run(f,coord,"task.split",fmt.tprintf("split_%d",i),cw_split(f,body)).code=="invalid_scope","split naming %s refused",reviewer)
    }
    // Proposals, publication and workflow runs share the same check.
    testing.expect_value(t,work_publish_brief(&f.store,"chain",`{"goal":"g","acceptance":["a"],"reviewers":["coordinator_agent"]}`),"invalid_scope")
    testing.expect_value(t,brief_reviewers_admissible(&f.store,"chain","",`{"goal":"g","acceptance":["a"],"reviewers":["coordinator_agent"]}`),"invalid_scope")
    testing.expect_value(t,brief_reviewers_admissible(&f.store,"chain","task",`{"goal":"g","acceptance":["a"],"reviewers":["author"]}`),"invalid_scope")
    testing.expect_value(t,brief_reviewers_admissible(&f.store,"chain","",`{"goal":"g","acceptance":["a"],"reviewers":["author"]}`),"ok")
    // Another agent is accepted.
    testing.expect_value(t,edit(f,"ok",`{"goal":"g","acceptance":["a"],"reviewers":["auditor"]}`),"ok")
}

// Dispatch: a submitted task owes every reviewer a review lease. review_targets
// names each owed agent with its member instances; review_pending is what that
// agent's `lease next` returns, until its verdict is posted.
@(test)
review_gate_dispatch_targets_every_owed_reviewer :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    gate_seed(t,f,`["auditor","second"]`)
    agent_seat(t,f,gate_auditor(),"worker");agent_seat(t,f,gate_second(),"worker")
    targets,ok:=review_targets(&f.store,"chain","task")
    testing.expect(t,ok && len(targets)==0,"nothing is owed before a submission")
    if !gate_submit(t,f) do return
    targets,ok=review_targets(&f.store,"chain","task")
    testing.expect_value(t,encode(targets),`[{"agent_id":"reviewer","instances":["review_instance"]},{"agent_id":"auditor","instances":["audit_instance"]},{"agent_id":"second","instances":["second_instance"]}]`)
    for child in ([2]Child{gate_auditor(),gate_second()}) {
        chain,task,found,read:=review_pending(&f.store,child)
        testing.expectf(t,read && found && chain=="chain" && task=="task","%s has a pending review",child.agent_id)
    }
    for child in ([2]Child{gate_stranger(),lease_child()}) {
        _,_,found,read:=review_pending(&f.store,child)
        testing.expectf(t,read && !found,"%s reviews nothing",child.agent_id)
    }
    testing.expect_value(t,gate_review(t,f,gate_auditor(),"vote_a","approve"),"ok")
    _,_,found,_:=review_pending(&f.store,gate_auditor())
    testing.expect(t,!found,"a posted verdict ends the review lease")
    targets,_=review_targets(&f.store,"chain","task")
    testing.expect_value(t,len(targets),2)
    // A held task dispatches nothing.
    testing.expect_value(t,control_call(f,"task.hold","hold",gate_task_revision(f)).code,"ok")
    targets,_=review_targets(&f.store,"chain","task")
    _,_,found,_=review_pending(&f.store,gate_second())
    testing.expect(t,len(targets)==0 && !found,"held")
}

@(test)
review_gate_reviewer_edit_while_held_cannot_resume_stale_review :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f)
    gate_seed(t,f,`["auditor"]`)
    if !gate_submit(t,f) do return
    testing.expect_value(t,control_call(f,"task.hold","hold","5").code,"ok")
    brief:=`{"goal":"Complete scoped work","acceptance":["Tests pass"],"reviewers":["second"]}`
    p:=encode(doc(map[string]string{"requirements_revision"="2","body_cipher"=cipher(f,brief)}))
    testing.expect_value(t,invoke(f,command(f,"requirements.edit","req2","task",p,gate_task_revision(f)),p).code,"ok")
    testing.expect_value(t,control_call(f,"task.release","release",gate_task_revision(f)).code,"ok")
    rows,_:=query(f.store.db,"SELECT state,(SELECT resume_state FROM local_controls) FROM lifecycle_state")
    testing.expect(t,rows[0][0]=="ready" && rows[0][1]=="ready")
    testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.open","stale_open",lifecycle_verdict(),"",gate_task_revision(f)).code,"stale_revision")
}

lifecycle_config_test :: proc(f:^Fixture)->json.Object {
    config,_,_:=lifecycle_config(&f.store,"chain","task")
    return config
}

// V37 maps review roles to the agents that held them at migration time and
// records each decision; re-running it changes nothing.
@(test)
migration_037_maps_review_roles_to_reviewer_agents :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    // Attempt 1 is submitted: the role verdicts V37 carries bind a submission.
    if !gate_submit(t,f) do return
    close(&f.store)
    db:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    // V36 evidence: a brief naming roles, a review.roles configuration with a
    // user gate, a fleet row serving "perf" (and the author serving "safety",
    // never a reviewer of its own task), a workflow stage naming "perf".
    testing.expectf(t,exec(db,`INSERT INTO task_requirements VALUES('chain','task',2,'{"goal":"Complete scoped work","acceptance":["Tests pass"],"review_roles":["safety","perf","ghost"],"reviewers":["reviewer"]}','','device','req2')`),"setup 0")
    testing.expectf(t,exec(db,`INSERT INTO local_role_configs VALUES('chain','task',1,1,'[]')`),"setup 1")
    testing.expectf(t,exec(db,`INSERT INTO local_role_pairs VALUES('chain','task',1,'safety','auditor','{}')`),"setup 2")
    testing.expectf(t,exec(db,`INSERT INTO local_role_pairs VALUES('chain','task',1,'safety','author','{}')`),"setup 3")
    testing.expectf(t,exec(db,`INSERT INTO local_fleet_policy_versions SELECT 'chain','perf_agent',seq,'',1,0,0,'','','','["perf"]','','','t','t' FROM local_events ORDER BY seq DESC LIMIT 1`),"setup 4")
    testing.expectf(t,exec(db,`INSERT INTO local_fleet_policy_roles SELECT 'chain','perf_agent',seq,'perf',0 FROM local_events ORDER BY seq DESC LIMIT 1`),"setup 5")
    testing.expectf(t,exec(db,`INSERT INTO local_workflow_definitions VALUES('chain','wf',1,'{"schema":"workflow.v1","title":"WF","stages":[{"key":"a","brief":{"goal":"A","acceptance":["a"]}},{"key":"b","brief":{"goal":"B","acceptance":["b"],"review_roles":["perf"]}}]}')`),"setup 6")
    // Posted role verdicts on attempt 1: auditor approved as "safety" and
    // requested changes as "perf"; perf_agent approved as "perf".
    testing.expectf(t,exec(db,`INSERT INTO local_role_reviews VALUES('chain','task',1,1,'safety','auditor','audit_instance','rv1','approve','fine');
      INSERT INTO local_role_reviews VALUES('chain','task',1,1,'perf','auditor','audit_instance','rv2','request_changes','slow');
      INSERT INTO local_role_reviews VALUES('chain','task',1,1,'perf','perf_agent','perf_instance','rv3','approve','fast')`),"setup 7")
    testing.expectf(t,exec(db,`UPDATE schema_migrations SET version=36`),"setup 8")
    testing.expect_value(t,sqlite3_close(db),0)
    if !testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key")) do return
    check :: proc(t:^testing.T,f:^Fixture) {
        rows,_:=query(f.store.db,"SELECT schema_version,(SELECT version FROM schema_migrations) FROM runtime_database")
        testing.expect_value(t,encode(rows),encode([1][2]string{{"38","38"}}))
        brief,_:=query(f.store.db,"SELECT json_type(brief_json,'$.review_roles'),json_extract(brief_json,'$.reviewers'),json_extract(brief_json,'$.requires_user_approval') FROM task_requirements WHERE task_id='task' AND revision=2")
        testing.expect_value(t,encode(brief),encode([1][3]string{{"",`["reviewer","auditor","perf_agent"]`,"1"}}))
        untouched,_:=query(f.store.db,"SELECT brief_json FROM task_requirements WHERE task_id='task' AND revision=1")
        testing.expect_value(t,untouched[0][0],`{"goal":"Complete scoped work","acceptance":["Tests pass"]}`)
        mapped,_:=query(f.store.db,"SELECT subject,subject_id,revision,role,agent_id,source FROM local_review_role_migrations ORDER BY subject,role,agent_id")
        testing.expect_value(t,encode(mapped),encode([5][6]string{
            {"requirements","task","2","","","role_config_user_approval"},
            {"requirements","task","2","ghost","","user_approval"},
            {"requirements","task","2","perf","perf_agent","fleet_role"},
            {"requirements","task","2","safety","auditor","task_role_pairs"},
            {"workflow_definition","wf","1","perf","perf_agent","fleet_role"}}))
        // One review per agent; any request_changes among its roles wins.
        reviews,_:=query(f.store.db,"SELECT reviewer_agent_id,verdict,principal_kind,attempt FROM local_reviews ORDER BY reviewer_agent_id")
        testing.expect_value(t,encode(reviews),encode([2][4]string{{"auditor","request_changes","agent","1"},{"perf_agent","approve","agent","1"}}))
        stage,_:=query(f.store.db,"SELECT json_type(definition_json,'$.stages[1].brief.review_roles'),json_extract(definition_json,'$.stages[1].brief.reviewers') FROM local_workflow_definitions WHERE workflow_id='wf'")
        testing.expect_value(t,encode(stage),encode([1][2]string{{"",`["perf_agent"]`}}))
        // The rewritten evidence stays immutable.
        testing.expect(t,!exec(f.store.db,"UPDATE task_requirements SET brief_json='{}' WHERE task_id='task'"))
        testing.expect(t,!exec(f.store.db,"UPDATE local_workflow_definitions SET definition_json='{}'"))
    }
    check(t,f)
    // Idempotent: a re-run after a version downgrade changes nothing.
    testing.expect(t,exec(f.store.db,"UPDATE schema_migrations SET version=36"))
    close(&f.store)
    if !testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key")) do return
    check(t,f)
}

// A Hub-imported brief naming a role nobody holds requires the user instead.
@(test)
migration_037_import_brief_without_holders_requires_the_user :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    plain:=`{"goal":"g","acceptance":["a"]}`
    same,ok:=migration_037_import_brief(f.store.db,"chain","task",plain)
    testing.expect(t,ok && same==plain,"a brief without roles is untouched")
    next,mapped:=migration_037_import_brief(f.store.db,"chain","task",`{"goal":"g","acceptance":["a"],"review_roles":["security"]}`)
    testing.expect(t,mapped && brief_valid(next) && brief_user_approval(&f.store,next) && !strings.contains(next,"review_roles"),next)
    rows,_:=query(f.store.db,"SELECT role,agent_id,source FROM local_review_role_migrations")
    testing.expect_value(t,encode(rows),encode([1][3]string{{"security","","user_approval"}}))
}
