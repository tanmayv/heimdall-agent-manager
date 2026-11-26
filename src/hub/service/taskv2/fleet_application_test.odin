package taskv2

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import agent "odin_test:hub/service/agent"
import fleet "odin_test:hub/service/fleet_application"
import project "odin_test:hub/service/project"
import platform "odin_test:hub/platform"

// fail_marker: while set, sends whose body names it are refused (a stop the
// live source never confirmed). Preflight counters observe bridge round-trips
// that native starts may wait on, and how many overlap.
Fleet_Probe :: struct {commands:[dynamic]project.Runtime_Command,under_tx:bool,fx:^Fixture,mutex:sync.Mutex,fail_marker:string,preflights,preflight_in_flight,preflight_max:int,allocator:runtime.Allocator}
fleet_probe_send :: proc(ctx:rawptr,cmd:project.Runtime_Command)->(bool,domain.Domain_Error) {
	p:=(^Fleet_Probe)(ctx)
	u,ok,_:=iface.unit_of_work_begin(&p.fx.uow)
	if ok {p.under_tx=p.under_tx || u.nested;iface.unit_of_work_rollback(&u)}
	sync.mutex_guard(&p.mutex)
	if p.fail_marker!="" && strings.contains(cmd.body_json,p.fail_marker) do return false,domain.domain_error(.Bridge_Offline,"injected send failure")
	// Like a real sink, keep what outlives the call on an explicit allocator:
	// sends may run on a Fleet worker whose own arena is gone after the pass.
	a:=p.allocator if p.allocator.procedure!=nil else context.allocator
	append(&p.commands,project.Runtime_Command{bridge_id=strings.clone(cmd.bridge_id,a),command_id=strings.clone(cmd.command_id,a),body_json=strings.clone(cmd.body_json,a)})
	return true,{}
}
fleet_probe_validate :: proc(ctx:rawptr,cmd:project.Validate_Project_Path_Command)->(project.Project_Path_Validation_Result,bool,domain.Domain_Error) {
	p:=(^Fleet_Probe)(ctx)
	sync.atomic_add(&p.preflights,1)
	now:=sync.atomic_add(&p.preflight_in_flight,1)+1
	for {
		seen:=sync.atomic_load(&p.preflight_max)
		if now<=seen do break
		if _,swapped:=sync.atomic_compare_exchange_strong(&p.preflight_max,seen,now);swapped do break
	}
	time.sleep(2*time.Millisecond) // one bridge round-trip
	sync.atomic_sub(&p.preflight_in_flight,1)
	return {type="validate_project_path",command_id=cmd.command_id,project_id=cmd.project_id,path=cmd.path,ok=true},true,{}
}
fleet_probe_close :: proc(p:^Fleet_Probe) {
	a:=p.allocator if p.allocator.procedure!=nil else context.allocator
	for c in p.commands {delete(c.bridge_id,a);delete(c.command_id,a);delete(c.body_json,a)}
	delete(p.commands)
}
fleet_test_service :: proc(t:^testing.T,fx:^Fixture,log:^Wake_Log,p:^Fleet_Probe)->(fleet.Service,bool) {
	// Unlike legacy task fixture tables, application receipts reference users.
	// Use the real owner repository; never weaken the production foreign key.
	impl:sqlite.User_Repo_SQLite
	users:=sqlite.new_user_repository(&impl,&fx.conn)
	owner,found,oe:=iface.user_get_by_id(&users,"u1")
	if !found {
		if !testing.expectf(t,oe.code==.Not_Found,"Fleet fixture owner initial lookup: %v %s",oe.code,oe.message) do return {},false
		_,saved,se:=iface.user_save(&users,{user_id="u1",name="Fleet fixture owner",status=.Active})
		if !testing.expectf(t,saved && se.code==.None,"Fleet fixture user save: %v %s",se.code,se.message) do return {},false
		owner,found,oe=iface.user_get_by_id(&users,"u1")
	}
	if !testing.expectf(t,found && oe.code==.None && owner.user_id=="u1" && owner.status==.Active,"Fleet fixture owner verification: %v %s",oe.code,oe.message) do return {},false
	p.fx=fx
	if p.allocator.procedure==nil do p.allocator=context.allocator
	if p.commands==nil do p.commands=make([dynamic]project.Runtime_Command,p.allocator)
	log.service.bridge_command_sink={ctx=p,send_runtime_command=fleet_probe_send}
	log.service.hooks={ctx=&fx.svc,on_terminal=proc(ctx:rawptr,id:string){on_instance_terminal((^Service)(ctx),id)},launch_context=proc(ctx:rawptr,i:domain.Agent_Instance)->(agent.Start_Lease,bool,domain.Domain_Error){return reconfiguration_launch_context((^Service)(ctx),i)}}
	return {settings=agent.fleet_service(&log.service),agents=&log.service,factory=&fx.uow,clock=&fx.clock,ids=&fx.ids},true
}
fleet_feature_bridge :: proc(fx:^Fixture,id:string) {
	b,_,_:=iface.bridge_get_bridge(&fx.bridges,id)
	defer domain.bridge_destroy(&b)
	next:=b;next.capabilities_json=`{"features":["instance_reconfiguration_v1","start_agent_v1"]}`
	_,_,_=iface.bridge_save_bridge(&fx.bridges,next)
}
fleet_test_apply :: proc(s:^fleet.Service,key:string,revision:i64=0)->(domain.Fleet_Application_Record,bool,domain.Domain_Error) {
	return fleet.apply(s,{kind=.Internal_User,user_id="u1"},"br_1",{request_id=key,expected_revision=revision,default_runtime={"claude","claude","claude-sonnet-5-5"}})
}
fleet_test_ready :: proc(t:^testing.T,fx:^Fixture,log:^Wake_Log,target:domain.Fleet_Application_Target) {
	op,found,e:=iface.instance_reconfiguration_get(&fx.agents,"u1",target.agent_instance_id,target.operation_key)
	if !testing.expect(t,found && e.code==.None) do return
	defer domain.instance_reconfiguration_destroy(&op)
	agent.apply_reconfiguration_command_result(&log.service,"br_1",op.stop_command_id,`{"status":"succeeded"}`)
	i,_,_:=iface.agent_get_instance(&fx.agents,target.agent_instance_id)
	defer domain.agent_instance_destroy(&i)
	next:=i;next.runtime_status="running";next.startup_status="ready"
	_,_,_=iface.agent_save_instance(&fx.agents,next)
	agent.reconcile_active_reconfigurations(&log.service)
}

@(test)
test_fleet_apply_atomic_rollback_validation_and_idempotency :: proc(t:^testing.T) {
	fx,log,ok:=lease_fixture(t,"fleet_atomic");defer lease_fixture_close(fx,log);if !ok do return
	chain:=seed_live_chain(t,fx,"fleet_atomic");seed_fleet(fx,chain,"agt_w")
	p:Fleet_Probe;defer fleet_probe_close(&p);s,sok:=fleet_test_service(t,fx,log,&p);if !sok do return
	outer,begun,_:=iface.unit_of_work_begin(&fx.uow);if !testing.expect(t,begun) do return
	r,accepted,e:=fleet_test_apply(&s,"rolled_back")
	if !testing.expectf(t,accepted && e.code==.None,"nested Fleet Apply acceptance: %v %s",e.code,e.message) {iface.unit_of_work_rollback(&outer);return}
	testing.expect(t,len(p.commands)==0,"nested acceptance cannot send effects before outer COMMIT")
	domain.fleet_application_record_destroy(&r)
	iface.unit_of_work_rollback(&outer)
	snapshot,se:=iface.fleet_settings_get(&fx.bridges,"u1","br_1")
	testing.expect(t,se.code==.None && snapshot.revision==0 && len(p.commands)==0)
	domain.fleet_settings_destroy(snapshot)
	_,exists,_:=iface.fleet_application_get(&fx.bridges,"u1","br_1","rolled_back",true)
	testing.expect(t,!exists,"rollback removes snapshot and application/targets together")
	_,accepted,e=fleet.apply(&s,{user_id="foreign"},"br_1",{request_id="foreign",default_runtime={"claude","claude","claude-sonnet-5-5"}})
	testing.expect(t,!accepted && e.code==.Not_Found)
	_,accepted,e=fleet.apply(&s,{user_id="u1"},"br_1",{request_id="invalid",default_runtime={"claude","missing","bad"}})
	testing.expect(t,!accepted && e.code==.Unprocessable_Entity && len(p.commands)==0)
	r,accepted,e=fleet_test_apply(&s,"once")
	if !testing.expectf(t,accepted && e.code==.None,"Fleet Apply acceptance: %v %s",e.code,e.message) do return
	defer domain.fleet_application_record_destroy(&r)
	// Capability failures are saved separately from successfully committed policy.
	testing.expect(t,r.application.settings_saved && r.application.state=="partial_failure" && len(p.commands)==0)
	dup,dok,de:=fleet_test_apply(&s,"once")
	testing.expect(t,dok && de.code==.None && dup.application.application_id==r.application.application_id && len(p.commands)==0)
	domain.fleet_application_record_destroy(&dup)
	_,accepted,e=fleet_test_apply(&s,"stale")
	testing.expect(t,!accepted && e.code==.Conflict)
	_,accepted,e=fleet_test_apply(&s,"once",1)
	testing.expect(t,!accepted && e.code==.Conflict,"same request id with different revision fails before effects")
	testing.expect(t,!p.under_tx)
}

@(test)
test_fleet_preview_validation_runtime_and_override_removal :: proc(t:^testing.T) {
	fx,log,ok:=lease_fixture(t,"fleet_preview");defer lease_fixture_close(fx,log);if !ok do return
	chain:=seed_live_chain(t,fx,"fleet_preview")
	coord,_,_:=iface.agent_get_instance(&fx.agents,"inst_coord")
	_=iface.fleet_scope_set(&fx.bridges,coord,"manual");domain.agent_instance_destroy(&coord)
	i:=seed_instance(fx,chain,"preview_worker","agt_w","br_1","running")
	_=iface.fleet_scope_set(&fx.bridges,i,"chain")
	p:Fleet_Probe;defer fleet_probe_close(&p);s,sok:=fleet_test_service(t,fx,log,&p);if !sok do return
	draft:=domain.Fleet_Settings_Draft{default_runtime={"claude","","claude-opus-5-5"}}
	a,e:=fleet.preview(&s,{user_id="u1"},"br_1",draft)
	testing.expect(t,e.code==.None && a.affected_instances==0,"default-profile normalization compares actual runtime")
	draft.default_runtime.model="claude-sonnet-5-5"
	a,e=fleet.preview(&s,{user_id="u1"},"br_1",draft)
	testing.expect(t,e.code==.None && a.affected_instances==1)
	draft.overrides={{agent_id="agt_w",runtime={"claude","claude","claude-opus-5-5"}}}
	a,e=fleet.preview(&s,{user_id="u1"},"br_1",draft)
	testing.expect(t,e.code==.None && a.affected_instances==0,"override preserves matching process")
	draft.overrides=nil
	a,e=fleet.preview(&s,{user_id="u1"},"br_1",draft)
	testing.expect(t,e.code==.None && a.affected_instances==1,"removing override restores inherited default")
	_,e=fleet.preview(&s,{user_id="foreign"},"br_1",draft)
	testing.expect_value(t,e.code,domain.Error_Code.Not_Found)
	draft.expected_revision=1
	_,e=fleet.preview(&s,{user_id="u1"},"br_1",draft)
	testing.expect_value(t,e.code,domain.Error_Code.Conflict)
	draft.expected_revision=0;draft.default_runtime.provider_profile="missing"
	_,e=fleet.preview(&s,{user_id="u1"},"br_1",draft)
	testing.expect_value(t,e.code,domain.Error_Code.Unprocessable_Entity)
	draft.default_runtime.provider_profile="claude"
	draft.overrides={{agent_id="agt_w",runtime=draft.default_runtime},{agent_id="agt_w",runtime=draft.default_runtime}}
	_,e=fleet.preview(&s,{user_id="u1"},"br_1",draft)
	testing.expect_value(t,e.code,domain.Error_Code.Unprocessable_Entity)
	snapshot,_:=iface.fleet_settings_get(&fx.bridges,"u1","br_1")
	testing.expect(t,snapshot.revision==0 && len(p.commands)==0)
	domain.fleet_settings_destroy(snapshot)
}

@(test)
test_fleet_apply_all_instances_scope_and_duplicate_recovery :: proc(t:^testing.T) {
	fx,log,ok:=lease_fixture(t,"fleet_pages");defer lease_fixture_close(fx,log);if !ok do return
	chain:=seed_live_chain(t,fx,"fleet_pages");fleet_feature_bridge(fx,"br_1")
	other:=seed_chain(t,fx,"fleet_other",true)
	for n in 0..<132 {
		i:=seed_instance(fx,chain if n%2==0 else other,fmt.tprintf("fleet_instance_%d",n),"agt_w","br_1","running")
		testing.expect_value(t,iface.fleet_scope_set(&fx.bridges,i,"chain").code,domain.Error_Code.None)
	}
	for scope in ([]string{"manual","excluded"}) {
		i:=seed_instance(fx,chain,scope,"agt_w","br_1","running");_=iface.fleet_scope_set(&fx.bridges,i,scope)
	}
	for state in ([]string{"stopped","failed","unreachable"}) {
		i:=seed_instance(fx,chain,state,"agt_w","br_1",state);_=iface.fleet_scope_set(&fx.bridges,i,"chain")
	}
	seed_bridge(fx,"br_2");_=seed_instance(fx,chain,"different_bridge","agt_w","br_2","running")
	p:Fleet_Probe;defer fleet_probe_close(&p);s,sok:=fleet_test_service(t,fx,log,&p);if !sok do return
	preview, pre := fleet.preview(&s,{user_id="u1"},"br_1",{default_runtime={"claude","claude","claude-sonnet-5-5"}})
	testing.expect(t,pre.code==.None && preview.affected_instances==132 && preview.expected_revision==0, "preview includes all pages and shares Apply scope exclusions")
	snapshot, se := iface.fleet_settings_get(&fx.bridges,"u1","br_1")
	testing.expect(t,se.code==.None && snapshot.revision==0 && len(p.commands)==0,"preview never saves settings or sends lifecycle commands")
	domain.fleet_settings_destroy(snapshot)
	operations, oe := iface.instance_reconfiguration_list(&fx.agents,"","",true)
	testing.expect(t,oe.code==.None && len(operations)==0,"preview allocates no native operation")
	for &op in operations do domain.instance_reconfiguration_destroy(&op)
	delete(operations)
	r,accepted,e:=fleet_test_apply(&s,"many")
	if !testing.expect(t,accepted && e.code==.None,e.message) do return
	defer domain.fleet_application_record_destroy(&r)
	testing.expect_value(t,len(r.application.targets),preview.affected_instances)
	testing.expect_value(t,len(p.commands),132)
	testing.expect(t,!p.under_tx && r.application.state=="restarting")
	for target in r.application.targets do testing.expect_value(t,target.state,"restarting")
	// Reconstructing the service (Hub recovery) observes existing native intents.
	recovered,rok:=fleet_test_service(t,fx,log,&p);if !rok do return
	fleet.reconcile(&recovered)
	testing.expect(t,len(p.commands)==132,"no duplicate stop dispatch on app recovery")
	active, ae := iface.instance_reconfiguration_list(&fx.agents,"","",true)
	testing.expect(t,ae.code==.None && len(active)==132,"native reconciliation includes targets beyond 128")
	for &op in active do domain.instance_reconfiguration_destroy(&op)
	delete(active)
	fleet_test_ready(t,fx,log,r.application.targets[0])
	fleet.reconcile(&recovered)
	status,found,_:=fleet.read_application(&recovered,{user_id="u1"},"br_1",r.application.application_id)
	if testing.expect(t,found) {
		testing.expect_value(t,status.application.targets[0].state,"ready")
		domain.fleet_application_record_destroy(&status)
	}
	retried,_,_:=fleet.retry_application(&recovered,{user_id="u1"},"br_1",r.application.application_id)
	domain.fleet_application_record_destroy(&retried)
	testing.expect(t,len(p.commands)==133,"successful target is never restarted again")
}

@(test)
test_fleet_apply_active_claim_pack_generation_and_ready :: proc(t:^testing.T) {
	fx,log,ok:=lease_fixture(t,"fleet_claim");defer lease_fixture_close(fx,log);if !ok do return
	chain:=seed_live_chain(t,fx,"fleet_claim");seed_fleet(fx,chain,"agt_w",bridge_id="br_1")
	seed_directory(fx,chain,"fleet_dir","br_1","git")
	i:=seed_instance(fx,chain,"fleet_holder","agt_w","br_1","running")
	_=iface.fleet_scope_set(&fx.bridges,i,"chain")
	_=iface.fleet_scope_set(&fx.bridges,seed_instance(fx,chain,"inst_coord","agt_c","br_1","running","coordinator"),"manual")
	task:=publish_task(t,fx,chain,"fleet_task",brief=`{"goal":"g","acceptance":["a"],"assignee":"agt_w"}`)
	task.requires_user_approval=true;_,_,_=iface.taskchain_save_task(&fx.repo,task)
	l,held:=lease_of(fx,"fleet_holder");if !testing.expect(t,held && l.task_id==task.task_id) do return
	before,_,_:=iface.agent_get_instance(&fx.agents,i.agent_instance_id)
	defer domain.agent_instance_destroy(&before)
	fleet_feature_bridge(fx,"br_1")
	p:Fleet_Probe;defer fleet_probe_close(&p);s,sok:=fleet_test_service(t,fx,log,&p);if !sok do return
	r,accepted,e:=fleet_test_apply(&s,"claim")
	if !testing.expect(t,accepted && e.code==.None && len(r.application.targets)==1,e.message) do return
	defer domain.fleet_application_record_destroy(&r)
	target:=r.application.targets[0]
	// A real terminal callback during the acknowledged stop retains this claim.
	on_instance_terminal(&fx.svc,i.agent_instance_id)
	current,stillheld:=lease_of(fx,i.agent_instance_id)
	testing.expect(t,stillheld && current.lease_id==l.lease_id && current.attempt_no==l.attempt_no)
	op,_,_:=iface.instance_reconfiguration_get(&fx.agents,"u1",i.agent_instance_id,target.operation_key)
	agent.apply_reconfiguration_command_result(&log.service,"br_1",op.stop_command_id,`{"status":"succeeded"}`)
	domain.instance_reconfiguration_destroy(&op)
	testing.expect(t,len(p.commands)==2,"one stop and one existing start command; no Fleet startup request")
	launch:=p.commands[1].body_json
	testing.expect(t,strings.contains(launch,l.lease_id) && strings.contains(launch,`"workdir":`) && strings.contains(launch,`"model":"claude-sonnet-5-5"`),"existing launch carries unchanged claim/worktree pack and committed runtime")
	after,_,_:=iface.agent_get_instance(&fx.agents,i.agent_instance_id)
	defer domain.agent_instance_destroy(&after)
	testing.expect(t,after.configuration_revision==before.configuration_revision+1 && after.run_count==before.run_count+1 && after.chain_id==before.chain_id && after.conversation_id==before.conversation_id && after.permission_mode==before.permission_mode && after.current_task_id==string(task.task_id))
	testing.expect(t,strings.contains(launch,fmt.tprintf(`"run_count":%d`,after.run_count)),"launch uses post-commit generation")
	agent.reconcile_instance_reconfigurations(&log.service,"br_1")
	testing.expect_value(t,len(p.commands),3)
	testing.expect(t,p.commands[2].body_json==launch,"redelivery is byte-frozen")
	status,_,_:=fleet.read_application(&s,{user_id="u1"},"br_1",r.application.application_id)
	testing.expect_value(t,status.application.state,"restarting");domain.fleet_application_record_destroy(&status)
	next:=after;next.runtime_status="running";next.startup_status="ready";_,_,_=iface.agent_save_instance(&fx.agents,next)
	agent.reconcile_active_reconfigurations(&log.service);fleet.reconcile(&s)
	status,_,_=fleet.read_application(&s,{user_id="u1"},"br_1",r.application.application_id)
	testing.expect_value(t,status.application.state,"ready");domain.fleet_application_record_destroy(&status)
	current,stillheld=lease_of(fx,i.agent_instance_id)
	testing.expect(t,stillheld && current.lease_id==l.lease_id && current.model=="claude-sonnet-5-5")
	task_after,_,_:=iface.taskchain_get_task(&fx.repo,task.task_id)
	testing.expect(t,task_after.requires_user_approval && task_after.brief_json==task.brief_json,"Fleet restart preserves required review gates and task requirements")
	// Same desired tuple after success is a no-op and creates no new commands.
	noop,nok,ne:=fleet_test_apply(&s,"no_op",1)
	testing.expect(t,nok && ne.code==.None && len(noop.application.targets)==0 && noop.application.settings_revision==1)
	domain.fleet_application_record_destroy(&noop)
}

@(test)
test_fleet_apply_override_removal_and_capability_retry :: proc(t:^testing.T) {
	fx,log,ok:=lease_fixture(t,"fleet_override_retry");defer lease_fixture_close(fx,log);if !ok do return
	chain:=seed_live_chain(t,fx,"fleet_override_retry")
	coord,_,_:=iface.agent_get_instance(&fx.agents,"inst_coord");_=iface.fleet_scope_set(&fx.bridges,coord,"manual")
	i:=seed_instance(fx,chain,"fleet_override_holder","agt_w","br_1","running")
	_=iface.fleet_scope_set(&fx.bridges,i,"chain")
	p:Fleet_Probe;defer fleet_probe_close(&p);s,sok:=fleet_test_service(t,fx,log,&p);if !sok do return
	overrides:=[]domain.Fleet_Agent_Override{{agent_id="agt_w",runtime={"claude","claude","claude-opus-5-5"}}}
	r,accepted,e:=fleet.apply(&s,{user_id="u1"},"br_1",{request_id="override",default_runtime={"claude","claude","claude-sonnet-5-5"},overrides=overrides})
	if !testing.expect(t,accepted && e.code==.None,e.message) do return
	testing.expect(t,len(r.application.targets)==0 && len(p.commands)==0,"unchanged actual override needs no restart")
	domain.fleet_application_record_destroy(&r)
	r,accepted,e=fleet_test_apply(&s,"remove",1)
	if !testing.expect(t,accepted && e.code==.None && len(r.application.targets)==1,e.message) do return
	defer domain.fleet_application_record_destroy(&r)
	testing.expect(t,r.application.state=="partial_failure" && r.application.targets[0].retryable && len(p.commands)==0,"unsupported native capability is a saved retryable failure")
	fleet_feature_bridge(fx,"br_1")
	retry,rok,re:=fleet.retry_application(&s,{user_id="u1"},"br_1",r.application.application_id)
	testing.expect(t,rok && re.code==.None && retry.application.state=="restarting" && len(p.commands)==1)
	domain.fleet_application_record_destroy(&retry)
	fleet_test_ready(t,fx,log,r.application.targets[0]);fleet.reconcile(&s)
	status,found,_:=fleet.read_application(&s,{user_id="u1"},"br_1",r.application.application_id)
	testing.expect(t,found && status.application.state=="ready" && len(p.commands)==2)
	domain.fleet_application_record_destroy(&status)
	after,_,_:=iface.agent_get_instance(&fx.agents,i.agent_instance_id)
	testing.expect_value(t,after.model,"claude-sonnet-5-5")
	domain.agent_instance_destroy(&after)
}

// Scale E: Apply cost must not be one serial bridge wait per target. Native
// starts overlap up to FLEET_RESTART_CONCURRENCY; the Fleet row is written once
// per pass whatever the size; per-target failure and retry accounting holds.
fleet_scale_run :: proc(t:^testing.T,n:int)->(writes:int,preflight_max:int,ok:bool) {
	tag:=fmt.tprintf("fleet_scale_%d",n)
	fx,log,fok:=lease_fixture(t,tag);defer lease_fixture_close(fx,log);if !fok do return
	chain:=seed_live_chain(t,fx,tag);fleet_feature_bridge(fx,"br_1")
	p:Fleet_Probe;defer fleet_probe_close(&p);s,sok:=fleet_test_service(t,fx,log,&p);if !sok do return
	log.service.bridge_command_sink.validate_project_path=fleet_probe_validate
	// An explicit per-bridge project path makes every native start wait on a
	// bridge preflight round-trip before reconfiguration_mutex.
	now:=platform.clock_now(&fx.clock)
	_,psaved,pe:=iface.project_save(&log.projects,{project_id="proj_fleet_scale",owner_user_id="u1",name="Fleet scale",slug="fleet-scale",state=.Active,created_at=now,updated_at=now})
	if !testing.expectf(t,psaved,"project save: %s",pe.message) do return
	_,bsaved,be:=iface.project_save_bridge_path(&log.projects,{project_id="proj_fleet_scale",bridge_id="br_1",owner_user_id="u1",path="/srv/fleet_scale"})
	if !testing.expectf(t,bsaved,"bridge path save: %s",be.message) do return
	failing:=0
	for k in 0..<n {
		// Every tenth stop is refused by the (live) source on first delivery.
		name:=fmt.tprintf("fleet_scale_fail_%d",k) if k%10==0 else fmt.tprintf("fleet_scale_ok_%d",k)
		if k%10==0 do failing+=1
		i:=seed_instance(fx,chain,name,"agt_w","br_1","running")
		i.project_id="proj_fleet_scale";_,_,_=iface.agent_save_instance(&fx.agents,i)
		testing.expect_value(t,iface.fleet_scope_set(&fx.bridges,i,"chain").code,domain.Error_Code.None)
	}
	p.fail_marker="fleet_scale_fail_"
	r,accepted,e:=fleet_test_apply(&s,tag)
	if !testing.expectf(t,accepted && e.code==.None,"apply %d: %s",n,e.message) do return
	defer domain.fleet_application_record_destroy(&r)
	if !testing.expect_value(t,len(r.application.targets),n) do return
	testing.expect_value(t,p.preflights,n)
	testing.expectf(t,p.preflight_max<=fleet.FLEET_RESTART_CONCURRENCY,"native starts in flight %d exceed limit",p.preflight_max)
	testing.expect_value(t,len(p.commands),n-failing)
	testing.expect_value(t,r.application.state,"restarting")
	// Per-target accounting is unchanged: refused stops are retryable failures.
	failed_targets:=0
	for target in r.application.targets {
		if strings.has_prefix(target.agent_instance_id,"fleet_scale_fail_") {
			failed_targets+=1
			testing.expect(t,target.state=="failed" && target.error_code=="stop_unconfirmed" && target.retryable,target.agent_instance_id)
		} else do testing.expect(t,target.state=="restarting" && target.error_code=="" && !target.retryable,target.agent_instance_id)
	}
	testing.expect_value(t,failed_targets,failing)
	writes=r.application.revision
	// Retry restarts exactly the failed targets, once each, in one more write.
	p.fail_marker=""
	retried,rok,re:=fleet.retry_application(&s,{user_id="u1"},"br_1",r.application.application_id)
	if !testing.expectf(t,rok && re.code==.None,"retry %d: %s",n,re.message) do return
	defer domain.fleet_application_record_destroy(&retried)
	testing.expect_value(t,len(p.commands),n)
	testing.expect_value(t,retried.application.revision,writes+1)
	testing.expect_value(t,retried.application.state,"restarting")
	for target in retried.application.targets do testing.expect(t,target.state=="restarting" && target.error_code=="",target.agent_instance_id)
	// A steady reconcile pass with nothing changed sends nothing and writes nothing.
	fleet.reconcile(&s)
	status,found,_:=fleet.read_application(&s,{user_id="u1"},"br_1",r.application.application_id)
	if testing.expect(t,found) {
		testing.expect_value(t,status.application.revision,writes+1)
		domain.fleet_application_record_destroy(&status)
	}
	testing.expect_value(t,len(p.commands),n)
	testing.expect_value(t,p.preflights,n) // native retry re-sends the stop without a new preflight
	return writes,p.preflight_max,true
}

@(test)
test_fleet_apply_scales_with_bounded_native_starts :: proc(t:^testing.T) {
	small_writes,small_max,sok:=fleet_scale_run(t,10)
	large_writes,large_max,lok:=fleet_scale_run(t,200)
	if !sok || !lok do return
	// Fleet row writes per Apply are constant (insert + one pass), not per target.
	testing.expect_value(t,small_writes,2)
	testing.expect_value(t,large_writes,small_writes)
	// Bridge waits overlap: 200 targets are not 200 serial preflights, and the
	// overlap never exceeds the documented bound.
	testing.expectf(t,large_max>1 && large_max<=fleet.FLEET_RESTART_CONCURRENCY,"200-target preflight overlap %d (10-target %d)",large_max,small_max)
}

// Settled partial failures leave the reconcile listing; only retry moves them.
@(test)
test_fleet_reconcile_skips_settled_partial_failure :: proc(t:^testing.T) {
	fx,log,ok:=lease_fixture(t,"fleet_settled");defer lease_fixture_close(fx,log);if !ok do return
	chain:=seed_live_chain(t,fx,"fleet_settled")
	i:=seed_instance(fx,chain,"fleet_settled_holder","agt_w","br_1","running")
	_=iface.fleet_scope_set(&fx.bridges,i,"chain")
	p:Fleet_Probe;defer fleet_probe_close(&p);s,sok:=fleet_test_service(t,fx,log,&p);if !sok do return
	// Bridge lacks the native capability: a saved, retryable partial failure.
	r,accepted,e:=fleet_test_apply(&s,"settled")
	if !testing.expect(t,accepted && e.code==.None && r.application.state=="partial_failure",e.message) do return
	defer domain.fleet_application_record_destroy(&r)
	testing.expect(t,!fleet.application_in_flight(r.application))
	rows,le:=iface.fleet_application_list_active(&fx.bridges)
	testing.expect(t,le.code==.None && len(rows)==0,"partial_failure rows are not reloaded by every reconcile pass")
	for &row in rows do domain.fleet_application_record_destroy(&row)
	delete(rows)
	fleet_feature_bridge(fx,"br_1");fleet.reconcile(&s)
	status,_,_:=fleet.read_application(&s,{user_id="u1"},"br_1",r.application.application_id)
	testing.expect(t,status.application.state=="partial_failure" && status.application.revision==r.application.revision && len(p.commands)==0,"reconcile never retries on its own")
	domain.fleet_application_record_destroy(&status)
	retry,rok,_:=fleet.retry_application(&s,{user_id="u1"},"br_1",r.application.application_id)
	testing.expect(t,rok && retry.application.state=="restarting" && len(p.commands)==1)
	testing.expect(t,fleet.application_in_flight(retry.application))
	domain.fleet_application_record_destroy(&retry)
	rows,le=iface.fleet_application_list_active(&fx.bridges)
	testing.expect(t,le.code==.None && len(rows)==1,"a retried application is in flight again")
	for &row in rows do domain.fleet_application_record_destroy(&row)
	delete(rows)
}

// Hub callers (reaper passes, request threads) run Fleet on a per-pass arena
// that is not thread-safe. A parallel pass under such a caller must keep every
// worker allocation off that arena, and its outcome must survive the arena.
@(test)
test_fleet_parallel_pass_under_caller_arena :: proc(t:^testing.T) {
	fx,log,ok:=lease_fixture(t,"fleet_arena");defer lease_fixture_close(fx,log);if !ok do return
	chain:=seed_live_chain(t,fx,"fleet_arena");fleet_feature_bridge(fx,"br_1")
	p:Fleet_Probe;defer fleet_probe_close(&p);s,sok:=fleet_test_service(t,fx,log,&p);if !sok do return
	n:=3*fleet.FLEET_RESTART_CONCURRENCY
	for k in 0..<n {
		name:=fmt.tprintf("fleet_arena_fail_%d",k) if k%4==0 else fmt.tprintf("fleet_arena_ok_%d",k)
		_=iface.fleet_scope_set(&fx.bridges,seed_instance(fx,chain,name,"agt_w","br_1","running"),"chain")
	}
	p.fail_marker="fleet_arena_fail_"
	application_id:string
	{
		scratch:virtual.Arena
		if !testing.expect(t,virtual.arena_init_growing(&scratch)==nil) do return
		defer virtual.arena_destroy(&scratch)
		context.allocator=virtual.arena_allocator(&scratch)
		r,accepted,e:=fleet_test_apply(&s,"arena")
		if !testing.expectf(t,accepted && e.code==.None,"arena apply: %s",e.message) do return
		testing.expect_value(t,len(r.application.targets),n)
		application_id=strings.clone(r.application.application_id,context.temp_allocator)
		p.fail_marker=""
		retried,rok,re:=fleet.retry_application(&s,{user_id="u1"},"br_1",application_id)
		testing.expectf(t,rok && re.code==.None && retried.application.state=="restarting","arena retry: %s",re.message)
		fleet.reconcile(&s)
	}
	// Read back on the test's own allocator after the caller arena is gone.
	status,found,_:=fleet.read_application(&s,{user_id="u1"},"br_1",application_id)
	if !testing.expect(t,found) do return
	defer domain.fleet_application_record_destroy(&status)
	testing.expect_value(t,status.application.state,"restarting")
	testing.expect_value(t,status.application.revision,3)
	for target in status.application.targets do testing.expect(t,target.state=="restarting" && target.error_code=="" && target.error_message=="" && !target.retryable,target.agent_instance_id)
	testing.expect_value(t,len(p.commands),n)
}
