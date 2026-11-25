#+private file
package taskv2

import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"

// REQ-XCHAIN: an outsider assigned to a different chain can orchestrate its
// owner's work. Instance ownership, graph contracts and claim/review authority
// remain independent of that permission.
authz_fixture :: proc(t: ^testing.T) -> (^Fixture, bool) {
	fx := new(Fixture)
	conn, ok := fixture_clone_migrated(t)
	if !ok do return fx, false
	fx.conn = conn
	fixture_wire(fx)
	chain := seed_chain(t, fx, "authz_chain", true)
	seed_instance(fx, chain, "coord_instance", "agt_c", "", "idle", "coordinator")
	_, _, _ = iface.agent_save_instance(&fx.agents, domain.Agent_Instance{agent_instance_id="inst_outsider",owner_user_id="u1",agent_id="agt_w",chain_id="another_chain"})
	_, _, _ = iface.agent_save_instance(&fx.agents, domain.Agent_Instance{agent_instance_id="inst_foreign",owner_user_id="u2",agent_id="agt_foreign"})
	_ = seed_task(t, fx, chain, "authz_ticket")
	return fx, true
}

authz_run :: proc(t: ^testing.T, fx: ^Fixture, id: string) -> domain.Work_Item_Ref {
	u, ok, err := begin_uow(&fx.svc)
	if !testing.expect(t, ok, err.message) do return {}
	now := platform.clock_now(&fx.clock)
	_, rok, _ := iface.taskchain_insert_workflow_run(&fx.repo, domain.Workflow_Run{
		run_id=domain.Workflow_Run_ID(id),chain_id="authz_chain",owner_user_id="u1",
		title="Research",definition_ref="research@1",spec_json=`{"schema":"workflow.v1","name":"research","stages":[]}`,
		inputs_json="{}",current_execution_no=1,request_id=id,request_hash="hash",
		created_by_kind="user",created_by_id="u1",created_at=now,updated_at=now,revision=1,
	})
	_, eok, _ := iface.taskchain_insert_workflow_execution(&fx.repo, domain.Workflow_Run_Execution{
		run_id=domain.Workflow_Run_ID(id),execution_no=1,chain_id="authz_chain",owner_user_id="u1",
		state=domain.WORKFLOW_EXECUTION_PENDING,resolved_inputs_json="{}",output_manifest_json="{}",revision=1,
	})
	_, cerr := end_uow(&fx.svc, &u, rok && eok)
	testing.expect(t, rok && eok && cerr.code==.None, "seed workflow run")
	return domain.Work_Item_Ref{kind=domain.WORK_ITEM_WORKFLOW_RUN,id=id}
}

@(test)
test_mixed_work_agent_routing_authority :: proc(t: ^testing.T) {
	context.allocator=context.temp_allocator
	fx, ok := authz_fixture(t)
	defer sqlite.close(&fx.conn)
	if !ok do return
	ticket := domain.Work_Item_Ref{kind=domain.WORK_ITEM_TASK,id="authz_ticket"}
	run := authz_run(t,fx,"wrun_authz")
	outsider := Actor{kind=ACTOR_AGENT,id="inst_outsider"}
	chain,_,_ := iface.taskchain_get_chain(&fx.repo,"authz_chain")
	testing.expect(t,!is_coordinator(&fx.svc,chain,outsider.id),"outsider is not relabeled as coordinator")
	members,_ := iface.taskchain_list_members_by_chain(&fx.repo,chain.chain_id,"u1")
	testing.expect_value(t,len(members),1)

	forged_chain:=chain
	for id in ([]string{"missing","inst_foreign"}) {
		forged_chain.coordinator_agent_instance_id=id
		testing.expect(t,!task_write_actor_authorized(&fx.svc,forged_chain,Actor{kind=ACTOR_AGENT,id=id}),"stale coordinator metadata cannot bypass actual instance ownership")
	}
	// Foreign, unknown, malformed and misleading coordinator labels fail before
	// writing edges, scope, revisions or completion state.
	for actor in ([]Actor{
		{kind=ACTOR_AGENT,id="inst_foreign"},{kind=ACTOR_AGENT,id="missing"},
		{kind=ACTOR_AGENT},{kind="invalid",id="u1"},{kind=ACTOR_USER,id="u2"},
		{kind=ACTOR_COORDINATOR,id="inst_foreign"},
	}) {
		_,added,err := work_dependency_add(&fx.svc,"u1",actor,chain.chain_id,ticket,run,reconcile=false)
		testing.expect(t,!added && err.code==.Forbidden,"invalid actor cannot add dependency")
		_,scoped,serr := work_scope_decide(&fx.svc,"u1",actor,chain.chain_id,run,"include","audit")
		testing.expect(t,!scoped && serr.code==.Forbidden,"invalid actor cannot set scope")
		_,completed,cerr := work_chain_complete(&fx.svc,"u1",actor,chain.chain_id,chain.work_revision,"done")
		testing.expect(t,!completed && cerr.code==.Forbidden,"invalid actor cannot complete")
	}
	after,_,_ := iface.taskchain_get_chain(&fx.repo,chain.chain_id)
	edges,_ := iface.taskchain_list_work_dependencies(&fx.repo,chain.chain_id,"u1")
	scope,_ := iface.taskchain_list_work_scope_decisions(&fx.repo,chain.chain_id,"u1")
	testing.expect(t,after.work_revision==chain.work_revision && after.status==.Active && len(edges)==0 && len(scope)==0,"denials leave graph and chain unchanged")

	edge,added,aerr := work_dependency_add(&fx.svc,"u1",outsider,chain.chain_id,ticket,run,reconcile=false)
	if !testing.expect(t,added,aerr.message) do return
	testing.expect_value(t,edge.created_by_id,outsider.id)
	// Membership/coordinator agents retain the same owner permission.
	_,repeat,rerr := work_dependency_add(&fx.svc,"u1",Actor{kind=ACTOR_AGENT,id="coord_instance"},chain.chain_id,ticket,run,reconcile=false)
	testing.expect(t,repeat && rerr.code==.None,"coordinator retains idempotent add")
	_,cross,xerr := work_dependency_add(&fx.svc,"u2",outsider,chain.chain_id,ticket,run,reconcile=false)
	testing.expect(t,!cross && xerr.code==.Not_Found,"caller-supplied owner does not authorize")

	removed,why := work_dependency_remove(&fx.svc,"u1",outsider,chain.chain_id,edge.dependency_id,"",reconcile=false)
	testing.expect(t,!removed && why.code==.Validation_Failed,"removal still requires audit reason")
	removed,why=work_dependency_remove(&fx.svc,"u1",outsider,chain.chain_id,edge.dependency_id,"replan",reconcile=false)
	testing.expect(t,removed,why.message)
	_,excluded,serr := work_scope_decide(&fx.svc,"u1",outsider,chain.chain_id,run,"exclude","out of scope")
	testing.expect(t,!excluded && serr.code==.Conflict,"active work cannot be excluded")
	ex,_,_ := iface.taskchain_get_workflow_execution(&fx.repo,domain.Workflow_Run_ID(run.id),1,"u1")
	ex.state=domain.WORKFLOW_EXECUTION_CANCELLED
	ex.revision+=1
	_,updated,uerr:=iface.taskchain_update_workflow_execution(&fx.repo,ex)
	if !testing.expect(t,updated,uerr.message) do return
	for action in ([]string{"exclude","include","exclude"}) {
		decision,scoped,err := work_scope_decide(&fx.svc,"u1",outsider,chain.chain_id,run,action,"scope reviewed")
		testing.expect(t,scoped,err.message)
		testing.expect_value(t,decision.actor_id,outsider.id)
	}
	_,completed,cerr := work_chain_complete(&fx.svc,"u1",outsider,chain.chain_id,chain.work_revision,"done")
	testing.expect(t,!completed && cerr.code==.Conflict,"stale work revision still fails")
	current,_,_ := iface.taskchain_get_chain(&fx.repo,chain.chain_id)
	_,completed,cerr=work_chain_complete(&fx.svc,"u1",outsider,chain.chain_id,current.work_revision,"")
	testing.expect(t,!completed && cerr.code==.Validation_Failed,"summary remains mandatory")
	_,completed,cerr=work_chain_complete(&fx.svc,"u1",outsider,chain.chain_id,current.work_revision,"done")
	testing.expect(t,!completed && cerr.code==.Conflict,"included unfinished task prevents completion")
	task,_,_ := iface.taskchain_get_task(&fx.repo,"authz_ticket")
	task.state=.Done
	_,_,_=iface.taskchain_save_task(&fx.repo,task)
	current,_,_=iface.taskchain_get_chain(&fx.repo,chain.chain_id)
	done: domain.Task_Chain
	done,completed,cerr = work_chain_complete(&fx.svc,"u1",outsider,chain.chain_id,current.work_revision,"Accepted successful ticket; cancelled run excluded")
	testing.expect(t,completed,cerr.message)
	persisted,found,readerr:=iface.taskchain_get_chain(&fx.repo,"authz_chain")
	testing.expect(t,found && readerr.code==.None && done.status==.Completed && persisted.status==.Completed,"successful completion persists and returns completed chain")

}

@(test)
test_cross_chain_workflow_summary_and_claim_boundaries :: proc(t: ^testing.T) {
	context.allocator=context.temp_allocator
	fx,ok:=authz_fixture(t)
	defer sqlite.close(&fx.conn)
	if !ok do return
	outsider:=Actor{kind=ACTOR_AGENT,id="inst_outsider"}
	auth:=contracts.Auth_Context{kind=.Instance_Token,user_id="u1",agent_instance_id=outsider.id}
	workflow_example_definition(t,fx,"cross_chain",`{"schema":"workflow.v1","name":"cross_chain","stages":[{"key":"approval","kind":"gate","approver":"user"}]}`)
	input:=Workflow_Run_Input{chain_id="authz_chain",ref="cross_chain",request_id="request"}
	for actor in ([]Actor{{kind=ACTOR_AGENT,id="inst_foreign"},{kind=ACTOR_AGENT,id="missing"},{kind="invalid"}}) {
		_,saved,err:=workflow_run(&fx.svc,"u1",actor,input)
		testing.expect(t,!saved && err.code==.Forbidden,"invalid actor cannot create run")
	}
	runs,_:=iface.taskchain_list_workflow_runs(&fx.repo,"authz_chain","u1")
	testing.expect_value(t,len(runs),0)
	run,saved,err:=workflow_run(&fx.svc,"u1",outsider,input)
	if !testing.expect(t,saved,err.message) do return
	duplicate,repeated,rerr:=workflow_run(&fx.svc,"u1",outsider,input)
	testing.expect(t,repeated && rerr.code==.None && duplicate.run_id==run.run_id,"request idempotency preserved")
	for actor in ([]Actor{{kind=ACTOR_AGENT,id="inst_foreign"},{kind=ACTOR_AGENT,id="missing"}}) {
		_,cancelled,cerr:=workflow_cancel(&fx.svc,run.run_id,"u1",actor,"stop",1)
		testing.expect(t,!cancelled && cerr.code==.Forbidden,"foreign/unknown cancel denied")
		_,retried,terr:=workflow_retry(&fx.svc,run.run_id,"u1",actor,"retry",run.revision)
		testing.expect(t,!retried && terr.code==.Forbidden,"foreign/unknown retry denied")
	}
	_,cancelled,cerr:=workflow_cancel(&fx.svc,run.run_id,"u1",outsider,"stop",0)
	testing.expect(t,!cancelled && cerr.code==.Validation_Failed,"execution target mandatory")
	_,cancelled,cerr=workflow_cancel(&fx.svc,run.run_id,"u1",outsider,"stop",1)
	if !testing.expect(t,cancelled,cerr.message) do return
	before,_,_:=workflow_context(&fx.svc,run.run_id,"u1")
	_,retried,terr:=workflow_retry(&fx.svc,run.run_id,"u1",outsider,"retry",before.run.revision+1)
	testing.expect(t,!retried && terr.code==.Conflict,"stale workflow revision fails")
	fresh: domain.Workflow_Run
	fresh,retried,terr=workflow_retry(&fx.svc,run.run_id,"u1",outsider,"retry",before.run.revision)
	testing.expect(t,retried,terr.message)
	testing.expect_value(t,fresh.current_execution_no,2)
	executions,_:=iface.taskchain_list_workflow_executions(&fx.repo,run.run_id,"u1")
	testing.expect_value(t,len(executions),2)

	_,summarized,serr:=chain_summary_set(&fx.svc,auth,"authz_chain","Cross-chain operator notes")
	testing.expect(t,summarized,serr.message)
	for id in ([]string{"missing","inst_foreign"}) {
		forged:=auth;forged.agent_instance_id=id
		_,changed,e:=chain_summary_set(&fx.svc,forged,"authz_chain","forged")
		testing.expect(t,!changed && e.code!=.None,"summary validates actual instance owner")
	}
	// Approved orchestration permission never authorizes named claims, transfer,
	// submission or review decisions.
	_,claimed,claimerr:=lease_claim(&fx.svc,auth,Lease_Claim_Input{task_id="authz_ticket",instance_id="coord_instance"})
	testing.expect(t,!claimed && claimerr.code==.Forbidden,"outsider cannot assign a named claim")
	_,transferred,transfererr:=lease_transfer(&fx.svc,auth,Lease_Claim_Input{task_id="authz_ticket",instance_id="coord_instance",reason="move"})
	testing.expect(t,!transferred && transfererr.code==.Forbidden,"outsider cannot transfer claims")
	_,submitted,suberr:=lease_submit(&fx.svc,auth,Submit_Input{summary="unleased"})
	testing.expect(t,!submitted && suberr.code!=.None,"submission still requires lease")
	_,reviewed,reverr:=review_post(&fx.svc,auth,Review_Input{task_id="authz_ticket",verdict="approve"})
	testing.expect(t,!reviewed && reverr.code!=.None,"outsider cannot supply a review verdict")
	chain,_,_:=iface.taskchain_get_chain(&fx.repo,"authz_chain")
	testing.expect(t,!is_coordinator(&fx.svc,chain,outsider.id),"orchestration never changes coordinator identity")
}
