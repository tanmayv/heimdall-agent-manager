package http

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import tv2 "odin_test:hub/service/taskv2"

Cross_Chain_HTTP_Fixture :: struct {
	wire: ^wire_fixture,
	repos: iface.Repositories,
	uow_impl: sqlite.SQLite_Unit_Of_Work_Factory,
	uow: iface.Unit_Of_Work_Factory,
	engine: tv2.Service,
}
xc_setup :: proc(t: ^testing.T) -> ^Cross_Chain_HTTP_Fixture {
	c:=new(Cross_Chain_HTTP_Fixture)
	c.wire=wire_setup(t,"cross_chain")
	f:=c.wire
	_,_=iface.taskchain_remove_member(&f.tc_repo,f.chain_id,f.instance_id,f.owner)
	inst,_,_:=iface.agent_get_instance(&f.ag_repo,f.instance_id)
	inst.chain_id="another_chain"
	_,_,_=iface.agent_save_instance(&f.ag_repo,inst)
	c.repos=iface.Repositories{taskchains=f.tc_repo,agents=f.ag_repo,bridges=f.br_repo}
	c.uow=sqlite.new_unit_of_work_factory(&c.uow_impl,&f.conn,&c.repos)
	c.engine=tv2.new_service(&f.tc_repo,&f.ag_repo,&f.br_repo,&f.clock,&f.ids)
	c.engine.uow_factory=&c.uow
	f.tc_svc.engine=&c.engine
	f.tc_svc.uow_factory=&c.uow
	f.th.task_engine=&c.engine
	f.ah.task_engine=&c.engine
	return c
}
xc_close :: proc(c: ^Cross_Chain_HTTP_Fixture) {wire_teardown(c.wire);free(c)}
xc_native :: proc(c: ^Cross_Chain_HTTP_Fixture, method,path,body: string) -> Request {
	req:=wire_cookie_request(c.wire,method,path,body)
	req.headers=c.wire.agent_headers[:]
	return req
}
xc_agent :: proc(c: ^Cross_Chain_HTTP_Fixture,path,params: string) -> Request {
	return xc_native(c,"POST",path,strings.concatenate({`{"params":`,params,`}`},context.temp_allocator))
}
xc_expect :: proc(t: ^testing.T,resp: Response,status: int) {
	testing.expectf(t,resp.status==status,"expected %d got %d: %s",status,resp.status,resp.body)
}
xc_task :: proc(t: ^testing.T,c: ^Cross_Chain_HTTP_Fixture,id: string,published:=true) -> domain.Task {
	task:=domain.Task{task_id=domain.Task_ID(id),chain_id=c.wire.chain_id,owner_user_id=c.wire.owner,
		title=id,kind=.Task,publish_state=.Published if published else .Draft,state=.Backlog,
		brief_json=`{"goal":"g","acceptance":["a"]}`}
	saved,ok,err:=iface.taskchain_save_task(&c.wire.tc_repo,task)
	testing.expect(t,ok,err.message)
	return saved
}

@(test)
test_cross_chain_http_graph_dependency_scope_and_completion :: proc(t: ^testing.T) {
	context.allocator=context.temp_allocator
	c:=xc_setup(t);defer xc_close(c)
	f:=c.wire
	base:=fmt.tprintf("/api/v1/task-chains/%s",f.chain_id)
	// Native endpoints receive the same authenticated outsider instance.
	xc_expect(t,publish_task_chain_handler(&f.th,xc_native(c,"POST",strings.concatenate({base,"/publish"},context.temp_allocator),"{}")),200)
	a:=xc_task(t,c,"xc_a");b:=xc_task(t,c,"xc_b")
	_=a;_=b
	xc_expect(t,mixed_work_handler(&f.th,xc_native(c,"GET",strings.concatenate({base,"/work/graph"},context.temp_allocator),"")),200)
	edge_body:=`{"dependent":{"kind":"task","id":"xc_a"},"prerequisite":{"kind":"task","id":"xc_b"}}`
	added:=mixed_work_handler(&f.th,xc_native(c,"POST",strings.concatenate({base,"/work/depend"},context.temp_allocator),edge_body))
	xc_expect(t,added,200)
	edges,_:=iface.taskchain_list_work_dependencies(&f.tc_repo,f.chain_id,f.owner)
	if !testing.expect(t,len(edges)==1,"one native dependency") do return
	remove:=fmt.tprintf(`{{"chain_id":"%s","dependency_id":"%s","reason":"replan"}}`,f.chain_id,edges[0].dependency_id)
	xc_expect(t,agent_action_work_handler(&f.ah,xc_agent(c,"/api/v1/agent-actions/work/remove-dependency",remove)),200)
	dep:=agent_action_task_depend_handler(&f.ah,xc_agent(c,"/api/v1/agent-actions/tasks/depend",`{"task_id":"xc_a","on":"xc_b"}`))
	xc_expect(t,dep,201)
	// Dependency replacement through update must use the same owner policy.
	xc_expect(t,patch_task_handler(&f.th,xc_native(c,"PATCH",strings.concatenate({base,"/tasks/xc_a"},context.temp_allocator),`{"depends_on":[]}`)),200)
	graph_params:=fmt.tprintf(`{{"chain_id":"%s"}}`,f.chain_id)
	xc_expect(t,agent_action_work_handler(&f.ah,xc_agent(c,"/api/v1/agent-actions/work/graph",graph_params)),200)
	include:=fmt.tprintf(`{{"chain_id":"%s","item":{{"kind":"task","id":"xc_b"}},"action":"include","reason":"accepted scope"}}`,f.chain_id)
	xc_expect(t,agent_action_work_handler(&f.ah,xc_agent(c,"/api/v1/agent-actions/work/scope",include)),200)
	// Completion requires an explicit id and rejects unfinished included work.
	xc_expect(t,agent_action_work_handler(&f.ah,xc_agent(c,"/api/v1/agent-actions/work/complete",`{"summary":"done"}`)),400)
	chain,_,_:=iface.taskchain_get_chain(&f.tc_repo,f.chain_id)
	incomplete:=fmt.tprintf(`{{"expected_work_revision":%d,"summary":"done"}}`,chain.work_revision)
	xc_expect(t,mixed_work_handler(&f.th,xc_native(c,"POST",strings.concatenate({base,"/work/complete"},context.temp_allocator),incomplete)),409)
	for id in ([]string{"xc_a","xc_b"}) {
		task,_,_:=iface.taskchain_get_task(&f.tc_repo,domain.Task_ID(id))
		task.state=.Done
		_,ok,err:=iface.taskchain_save_task(&f.tc_repo,task)
		testing.expect(t,ok,err.message)
	}
	chain,_,_=iface.taskchain_get_chain(&f.tc_repo,f.chain_id)
	complete:=fmt.tprintf(`{{"chain_id":"%s","expected_work_revision":%d,"summary":"Both tickets accepted"}}`,f.chain_id,chain.work_revision)
	xc_expect(t,agent_action_work_handler(&f.ah,xc_agent(c,"/api/v1/agent-actions/work/complete",complete)),200)
	done,_,_:=iface.taskchain_get_chain(&f.tc_repo,f.chain_id)
	testing.expect_value(t,done.status,domain.Task_Chain_Status.Completed)
	xc_expect(t,patch_task_chain_handler(&f.th,xc_native(c,"PATCH",base,`{"status":"active"}`)),200)
	reopened,_,_:=iface.taskchain_get_chain(&f.tc_repo,f.chain_id)
	native_complete:=fmt.tprintf(`{{"expected_work_revision":%d,"summary":"Native acceptance after explicit reopen"}}`,reopened.work_revision)
	xc_expect(t,mixed_work_handler(&f.th,xc_native(c,"POST",strings.concatenate({base,"/work/complete"},context.temp_allocator),native_complete)),200)
	// Cross-owner targets fail on both independent transport gates without changes.
	foreign_chain:=done;foreign_chain.chain_id="xc_foreign";foreign_chain.owner_user_id="foreign_chain";foreign_chain.status=.Active
	_,_,_=iface.taskchain_save_chain(&f.tc_repo,foreign_chain)
	xc_expect(t,mixed_work_handler(&f.th,xc_native(c,"GET","/api/v1/task-chains/xc_foreign/work/graph","")),404)
	xc_expect(t,agent_action_work_handler(&f.ah,xc_agent(c,"/api/v1/agent-actions/work/scope",`{"chain_id":"xc_foreign","item":{"kind":"task","id":"xc_b"},"action":"include","reason":"forged"}`)),404)
	unchanged,_,_:=iface.taskchain_get_chain(&f.tc_repo,"xc_foreign")
	testing.expect_value(t,unchanged.status,domain.Task_Chain_Status.Active)
}

@(test)
test_cross_chain_http_workflow_reads_controls_and_metadata :: proc(t: ^testing.T) {
	context.allocator=context.temp_allocator
	c:=xc_setup(t);defer xc_close(c)
	f:=c.wire
	base:=fmt.tprintf("/api/v1/task-chains/%s",f.chain_id)
	xc_expect(t,publish_task_chain_handler(&f.th,xc_native(c,"POST",strings.concatenate({base,"/publish"},context.temp_allocator),"{}")),200)
	_,defined,deferr:=tv2.workflow_define(&c.engine,f.owner,`{"schema":"workflow.v1","name":"xc_gate","stages":[{"key":"approval","kind":"gate","approver":"user"}]}`)
	if !testing.expect(t,defined,deferr.message) do return
	for agent in ([]bool{false,true}) {
		input:=fmt.tprintf(`{{"chain_id":"%s","ref":"xc_gate","request_id":"native"}}`,f.chain_id)
		resp:Response
		if agent {
			input=fmt.tprintf(`{{"chain_id":"%s","ref":"xc_gate","request_id":"agent"}}`,f.chain_id)
			resp=agent_action_workflow_run_handler(&f.ah,xc_agent(c,"/api/v1/agent-actions/workflow/run",input))
		} else {resp=workflow_run_handler(&f.th,xc_native(c,"POST",strings.concatenate({base,"/workflow-runs"},context.temp_allocator),input))}
		xc_expect(t,resp,200 if agent else 201)
	}
	runs,_:=iface.taskchain_list_workflow_runs(&f.tc_repo,f.chain_id,f.owner)
	if !testing.expect(t,len(runs)==2,"native and agent runs created") do return
	xc_expect(t,workflow_runs_handler(&f.th,xc_native(c,"GET",strings.concatenate({base,"/workflow-runs"},context.temp_allocator),"")),200)
	xc_expect(t,agent_action_workflow_runs_handler(&f.ah,xc_agent(c,"/api/v1/agent-actions/workflow/runs",fmt.tprintf(`{{"chain_id":"%s"}}`,f.chain_id))),200)
	for run in runs {
		run_base:=fmt.tprintf("/api/v1/workflow-runs/%s",run.run_id)
		params:=fmt.tprintf(`{{"run_id":"%s","stage_key":"approval"}}`,run.run_id)
		xc_expect(t,workflow_status_handler(&f.th,xc_native(c,"GET",run_base,"")),200)
		xc_expect(t,workflow_history_handler(&f.th,xc_native(c,"GET",strings.concatenate({run_base,"/history"},context.temp_allocator),"")),200)
		outputreq:=xc_native(c,"GET",strings.concatenate({run_base,"/output"},context.temp_allocator),"");outputreq.query="stage_key=approval"
		xc_expect(t,workflow_output_handler(&f.th,outputreq),200)
		xc_expect(t,agent_action_workflow_status_handler(&f.ah,xc_agent(c,"/api/v1/agent-actions/workflow/status",params)),200)
		xc_expect(t,agent_action_workflow_output_handler(&f.ah,xc_agent(c,"/api/v1/agent-actions/workflow/output",params)),200)
		xc_expect(t,agent_action_workflow_history_handler(&f.ah,xc_agent(c,"/api/v1/agent-actions/workflow/history",params)),200)
		cancel:=fmt.tprintf(`{{"run_id":"%s","execution_no":1,"reason":"change approach"}}`,run.run_id)
		retry:=fmt.tprintf(`{{"run_id":"%s","expected_revision":%d,"reason":"retry"}}`,run.run_id,run.revision)
		if run.request_id=="agent" {
			xc_expect(t,agent_action_workflow_cancel_handler(&f.ah,xc_agent(c,"/api/v1/agent-actions/workflow/cancel",cancel)),200)
			xc_expect(t,agent_action_workflow_retry_handler(&f.ah,xc_agent(c,"/api/v1/agent-actions/workflow/retry",retry)),200)
		} else {
			xc_expect(t,workflow_cancel_handler(&f.th,xc_native(c,"POST",strings.concatenate({run_base,"/cancel"},context.temp_allocator),cancel)),200)
			xc_expect(t,workflow_retry_handler(&f.th,xc_native(c,"POST",strings.concatenate({run_base,"/retry"},context.temp_allocator),retry)),200)
		}
	}
	directories:=strings.concatenate({base,"/directories"},context.temp_allocator)
	foreign_dir:=fmt.tprintf(`{{"path":"/isolated/foreign","bridge_id":"%s"}}`,f.bridge_foreign)
	xc_expect(t,add_chain_directory_handler(&f.th,xc_native(c,"POST",directories,foreign_dir)),404)
	owned_dir:=fmt.tprintf(`{{"path":"/isolated/repo","bridge_id":"%s"}}`,f.bridge_pin)
	xc_expect(t,add_chain_directory_handler(&f.th,xc_native(c,"POST",directories,owned_dir)),201)
	dirs,_:=iface.taskchain_list_directories_by_chain(&f.tc_repo,f.chain_id,f.owner)
	if testing.expect(t,len(dirs)==1,"only owned directory persisted") {
		path:=fmt.tprintf("%s/%s",directories,dirs[0].directory_id)
		xc_expect(t,patch_chain_directory_handler(&f.th,xc_native(c,"PATCH",path,foreign_dir)),404)
		xc_expect(t,patch_chain_directory_handler(&f.th,xc_native(c,"PATCH",path,`{"path":"/isolated/moved"}`)),200)
		xc_expect(t,remove_chain_directory_handler(&f.th,xc_native(c,"DELETE",path,"")),200)
	}
	xc_expect(t,patch_task_chain_handler(&f.th,xc_native(c,"PATCH",base,`{"description":"Cross-chain description"}`)),200)
	title:=fmt.tprintf(`{{"chain_id":"%s","title":"Cross-chain title"}}`,f.chain_id)
	xc_expect(t,agent_action_chain_set_title_handler(&f.ah,xc_agent(c,"/api/v1/agent-actions/chain/set-title",title)),200)
	summary:=fmt.tprintf(`{{"chain_id":"%s","summary":"Operator notes"}}`,f.chain_id)
	xc_expect(t,agent_action_chain_summary_handler(&f.ah,xc_agent(c,"/api/v1/agent-actions/chain/summary",summary)),200)
	draft:=xc_task(t,c,"xc_draft",false)
	_=draft
	xc_expect(t,publish_task_handler(&f.th,xc_native(c,"POST",strings.concatenate({base,"/tasks/xc_draft/publish"},context.temp_allocator),"{}")),200)
	_,_,_=iface.agent_save(&f.ag_repo,domain.Agent{agent_id="xc_worker",owner_user_id=f.owner,name="Worker",slug="xc_worker"})
	fleet_base:=strings.concatenate({base,"/fleets/xc_worker"},context.temp_allocator)
	xc_expect(t,upsert_chain_fleet_handler(&f.th,xc_native(c,"PUT",fleet_base,`{"capacity":1}`)),200)
	xc_expect(t,list_chain_fleets_handler(&f.th,xc_native(c,"GET",strings.concatenate({base,"/fleets"},context.temp_allocator),"")),200)
	xc_expect(t,pause_chain_fleet_handler(&f.th,xc_native(c,"POST",strings.concatenate({fleet_base,"/pause"},context.temp_allocator),"{}")),200)
	xc_expect(t,pause_chain_fleet_handler(&f.th,xc_native(c,"POST",strings.concatenate({fleet_base,"/resume"},context.temp_allocator),"{}")),200)
	xc_expect(t,delete_chain_fleet_handler(&f.th,xc_native(c,"DELETE",fleet_base,"")),200)
}
