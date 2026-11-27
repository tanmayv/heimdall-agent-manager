package agent

import "core:fmt"
import jsonx "odin_test:lib/jsonx"
import "core:mem"
import "base:runtime"
import virtual "core:mem/virtual"
import "core:strings"
import "core:testing"
import "core:sync"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import project_service "odin_test:hub/service/project"

Start_Test :: struct {
	db: sqlite.Conn,
	ti: sqlite.Taskchain_Repo_SQLite, tr: iface.Taskchain_Repository,
	ai: sqlite.Agent_Repo_SQLite, bi: sqlite.Bridge_Repo_SQLite,
	pi: sqlite.Provider_Repo_SQLite, ci: sqlite.Content_Repo_SQLite,
	ar: iface.Agent_Repository, br: iface.Bridge_Repository,
	pr: iface.Provider_Repository, cr: iface.Content_Repository,
	registry: project_service.Bridge_Runtime_Registry,
	clock: platform.Clock, ids: platform.ID_Generator,
	service: Agent_Service,
	commands: [dynamic]string,
	fail_send: bool,
	fail_confirmed_stop: bool,
	allocator:mem.Allocator,
}
START_TEST_NOW :: "2026-11-22T12:00:00Z"
start_test_clock :: proc(_: rawptr) -> string { return START_TEST_NOW }
start_test_id :: proc(_: rawptr, prefix: string) -> string { return fmt.tprintf("%sfixed", prefix) }
start_test_send :: proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	h := (^Start_Test)(ctx)
	context.allocator=h.allocator
	append(&h.commands, strings.clone(cmd.body_json))
	if h.fail_send do return false, domain.domain_error(.Bridge_Offline, "send failed")
	return true, {}
}
start_test_open :: proc(t: ^testing.T, h: ^Start_Test) -> bool {
	h.allocator=context.allocator
	db, ok, err := sqlite.open(":memory:")
	if !testing.expect(t, ok, err.message) do return false
	h.db = db
	migrated, merr := sqlite.run_migrations(&h.db)
	if !testing.expect(t, migrated, merr.message) do return false
	h.ar = sqlite.new_agent_repository(&h.ai, &h.db)
	h.br = sqlite.new_bridge_repository(&h.bi, &h.db)
	h.pr = sqlite.new_provider_repository(&h.pi, &h.db)
	h.cr = sqlite.new_content_repository(&h.ci, &h.db)
	h.clock = {now=start_test_clock}
	h.ids = {generate=start_test_id}
	h.service = new_agent_service_with_runtime(&h.ar, &h.br, nil, &h.cr, nil, {ctx=h, send_runtime_command=start_test_send}, &h.registry, &h.clock, &h.ids)
	h.service.fixture_start_fact = proc(inst: domain.Agent_Instance) -> Agent_Liveness {
		if runtime_expected_active(inst.runtime_status) do return {state = .Alive, reason = .pty_child_alive, pid = 42}
		return {state = .Exited, reason = .stop_confirmed}
	}
	h.tr = sqlite.new_taskchain_repository(&h.ti, &h.db)
	h.service.taskchains = &h.tr
	h.service.providers = &h.pr
	_, ok, err = iface.bridge_save_bridge(&h.br, {bridge_id="brg",owner_user_id="owner", status=.Online,created_at=START_TEST_NOW,updated_at=START_TEST_NOW})
	if !testing.expect(t, ok, err.message) do return false
	_, _, live := project_service.bridge_runtime_registry_accept_live(&h.registry,"brg",false,"","owner")
	if !testing.expect(t, live) do return false
	_, ok, err = iface.agent_save(&h.ar, {agent_id="agt",owner_user_id="owner",name="Worker",slug="worker",template_id=domain.TEMPLATE_EMPTY_ID,state=.Active,created_at=START_TEST_NOW,updated_at=START_TEST_NOW})
	if !testing.expect(t, ok, err.message) do return false
	_, perr := iface.bridge_provider_status_upsert(&h.pr,{bridge_id="brg",provider="codex",binary_path="/usr/bin/codex",state="present",checked_at=START_TEST_NOW})
	if !testing.expect_value(t, perr.code, domain.Error_Code.None) do return false
	_, perr = iface.bridge_provider_setting_upsert(&h.pr,{bridge_id="brg",provider="codex",enabled=true,updated_at=START_TEST_NOW})
	if !testing.expect_value(t, perr.code, domain.Error_Code.None) do return false
	_, ok, err = iface.agent_save_instance(&h.ar, {agent_instance_id="inst",owner_user_id="owner",agent_id="agt",bridge_id="brg",provider="codex",provider_profile="codex",model="gpt-6.1-sol",conversation_id="chat",runtime_status="stopped",startup_status="stopped",activity_status="unknown",runtime_transport="pty",run_count=3,created_at=START_TEST_NOW,updated_at=START_TEST_NOW})
	return testing.expect(t, ok, err.message)
}
start_test_close :: proc(h: ^Start_Test) {
	for s in h.commands do delete(s)
	delete(h.commands)
	project_service.bridge_runtime_registry_destroy(&h.registry)
	sqlite.close(&h.db)
}
start_test_auth :: proc() -> contracts.Auth_Context { return {kind=.Session,user_id="owner"} }

START_ORIGIN_CATALOG_ETAG :: "sha256:7b106ddce0851ff5c63fcd79fc2399fc50c6451f92bf06d6cb903429b1945ace"
// The golden bytes embed the catalog etag of the release they were captured on; every release
// migration changes it, so compare against the etag of the migrated test database instead.
start_test_expected :: proc(t: ^testing.T, h: ^Start_Test, i: int) -> string {
	etag, err := iface.provider_catalog_etag(&h.pr)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	out, _ := strings.replace_all(START_ORIGIN_COMMANDS[i], START_ORIGIN_CATALOG_ETAG, etag, context.temp_allocator)
	return out
}

// Captured by running origin/main 99879b7b, before production edits.
START_ORIGIN_COMMANDS := [3]string {
	`{"type":"launch_agent","protocol_version":1,"message_id":"msg_cmd_launch_fixed_inst","command_id":"cmd_launch_fixed_inst","payload":{"agent_instance_id":"inst","agent_id":"agt","agent_name":"Worker","display_name":"","role":"worker","coordinator_agent_instance_id":"","chain_title":"","project_id":"","project_path":"","chain_id":"","conversation_id":"chat","provider":"codex","provider_profile":"codex","effective_transport":"pty","catalog_etag":"sha256:7b106ddce0851ff5c63fcd79fc2399fc50c6451f92bf06d6cb903429b1945ace","model":"gpt-6.1-sol","launch_epoch":"","run_count":4,"permission_mode":"yolo","instance_token":"hit_inst","bootstrap_url":"/api/v1/bridge/agent-instances/inst/bootstrap"}}`,
	`{"type":"launch_agent","protocol_version":1,"message_id":"msg_cmd_launch_fixed_inst","command_id":"cmd_launch_fixed_inst","payload":{"agent_instance_id":"inst","agent_id":"agt","agent_name":"Worker","display_name":"","role":"worker","coordinator_agent_instance_id":"","chain_title":"","project_id":"","project_path":"","chain_id":"","conversation_id":"chat","provider":"codex","provider_profile":"codex","effective_transport":"pty","catalog_etag":"sha256:7b106ddce0851ff5c63fcd79fc2399fc50c6451f92bf06d6cb903429b1945ace","model":"gpt-6.1-sol","launch_epoch":"","run_count":4,"permission_mode":"yolo","instance_token":"hit_inst","bootstrap_url":"/api/v1/bridge/agent-instances/inst/bootstrap"}}`,
	`{"type":"launch_agent","protocol_version":1,"message_id":"msg_cmd_launch_fixed_inst_fixed","command_id":"cmd_launch_fixed_inst_fixed","payload":{"agent_instance_id":"inst_fixed","agent_id":"agt","agent_name":"Worker","display_name":"Worker #1","role":"coordinator","coordinator_agent_instance_id":"inst_fixed","chain_title":"Worker #1","project_id":"","project_path":"","chain_id":"chain_fixed","conversation_id":"chat_fixed","provider":"codex","provider_profile":"codex","effective_transport":"pty","catalog_etag":"sha256:7b106ddce0851ff5c63fcd79fc2399fc50c6451f92bf06d6cb903429b1945ace","model":"gpt-6.1-sol","launch_epoch":"","run_count":1,"permission_mode":"yolo","instance_token":"hit_inst_fixed","bootstrap_url":"/api/v1/bridge/agent-instances/inst_fixed/bootstrap"}}`,
}

start_test_row :: proc(t:^testing.T, h:^Start_Test) -> domain.Agent_Instance {
	inst, ok, err := iface.agent_get_instance(&h.ar,"inst")
	testing.expect(t,ok,err.message)
	return inst
}
start_test_sql :: proc(t:^testing.T, h:^Start_Test, sql:string) { testing.expect(t,sqlite.exec(&h.db,sql)) }
start_test_run :: proc(t:^testing.T, scenario:proc(t:^testing.T,h:^Start_Test)) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track,context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator=mem.tracking_allocator(&track)
	{
		arena: virtual.Arena
		assert(virtual.arena_init_growing(&arena)==nil)
		context.allocator=virtual.arena_allocator(&arena)
		h: Start_Test
		if start_test_open(t,&h) do scenario(t,&h)
		start_test_close(&h)
		virtual.arena_destroy(&arena)
	}
	testing.expect_value(t,len(track.allocation_map),0)
}

start_bytes_scenario :: proc(t:^testing.T,h:^Start_Test) {
	for mode in 0..<3 {
		start_test_sql(t,h,"UPDATE agent_instances SET runtime_status='stopped',run_count=3 WHERE agent_instance_id='inst';")
		inst:domain.Agent_Instance; ok:bool; err:domain.Domain_Error
		switch mode {
		case 0: inst,ok,err=start_instance(&h.service,start_test_auth(),"inst")
		case 1: inst,ok,err=restart_instance(&h.service,start_test_auth(),"inst")
		case 2: inst,ok,err=create_instance(&h.service,start_test_auth(),{agent_id="agt",bridge_id="brg",provider="codex",model="gpt-6.1-sol"})
		}
		testing.expect(t,ok,err.message)
		if testing.expect_value(t,len(h.commands),mode+1) do testing.expect_value(t,h.commands[mode],start_test_expected(t,h,mode))
		testing.expect_value(t,inst.runtime_status,"launching")
		testing.expect_value(t,inst.startup_status,"starting")
		testing.expect_value(t,inst.activity_status,"unknown")
		testing.expect_value(t,inst.run_count,1 if mode==2 else 4)
		testing.expect_value(t,inst.started_at,START_TEST_NOW)
		testing.expect_value(t,inst.last_seen_at,START_TEST_NOW)
		testing.expect_value(t,h.registry.active_instances,mode/2+1)
	}
}
start_live_scenario :: proc(t:^testing.T,h:^Start_Test) {
	start_test_sql(t,h,"UPDATE agent_instances SET runtime_status='running',stopped_by='user';")
	before:=start_test_row(t,h)
	ticket,err:=start_begin(&h.service,start_test_auth(),"inst",{if_live=.Refuse})
	testing.expect_value(t,err.code,domain.Error_Code.Conflict)
	testing.expect(t,strings.contains(err.details_json,"already_running"))
	start_ticket_destroy(&ticket)
	ticket,err=start_begin(&h.service,start_test_auth(),"inst",{if_live=.Keep})
	testing.expect_value(t,err.code,domain.Error_Code.None)
	testing.expect(t,ticket.kept_live && !ticket.reserved)
	testing.expect_value(t,start_send(&h.service,&ticket).code,domain.Error_Code.None)
	start_ticket_destroy(&ticket)
	testing.expect_value(t,fmt.tprintf("%#v",start_test_row(t,h)),fmt.tprintf("%#v",before))
	testing.expect_value(t,len(h.commands),0)
	inst,_,ok,start_err:=start(&h.service,start_test_auth(),"inst",{if_live=.Relaunch})
	testing.expect(t,ok,start_err.message)
	testing.expect_value(t,inst.run_count,4)
	testing.expect_value(t,len(h.commands),1)
}
start_refusals_scenario :: proc(t:^testing.T,h:^Start_Test) {
	for kind in 0..<11 {
		// Restore all launch gates before each independent refusal.
		h.registry.limits={}
		start_test_sql(t,h,"UPDATE agent_instances SET stopped_by='user',runtime_status='stopped'; UPDATE bridges SET status='online',plan_disabled_at=''; UPDATE bridge_provider_settings SET enabled=1;")
		req:=Start_Request{if_live=.Relaunch}
		auth:=start_test_auth()
		id:="inst"
		expected:=start_test_row(t,h)
		want:=domain.Error_Code.Conflict
		switch kind {
		case 0: id="missing"; want=.Not_Found
		case 1: auth.user_id="other";want=.Not_Found
		case 2: h.ar.reconfiguration_list=start_test_pending
		case 3: expected.configuration_revision+=1;req.expected=&expected
		case 4: req.provider="unknown";want=.Validation_Failed
		case 5: start_test_sql(t,h,"UPDATE bridges SET plan_disabled_at='2026-11-22';");want=.Plan_Limit_Reached
		case 6: start_test_sql(t,h,"UPDATE bridges SET status='offline';");want=.Bridge_Offline
		case 7:
			h.service.bridge_runtime_registry=nil
			want=.Bridge_Offline
		case 8:
			h.registry.limits.active_instances=1
			h.registry.active_instances=1
			want=.Bridge_Busy
		case 9:
			start_test_sql(t,h,"UPDATE bridge_provider_settings SET transport='acp';")
			want=.ACP_Unavailable
		case 10: req.guard=start_test_guard_refuse;want=.Forbidden
		}
		before:=start_test_row(t,h)
		ticket,err:=start_begin(&h.service,auth,id,req)
		testing.expectf(t,err.code!=.None,"refusal %d must fail",kind)
		// Unknown providers use the existing provider validation's exact error.
		if kind!=4 do testing.expectf(t,err.code==want,"refusal %d got %v want %v: %s",kind,err.code,want,err.message)
		start_ticket_destroy(&ticket)
		after:=start_test_row(t,h)
		testing.expect_value(t,fmt.tprintf("%#v",after),fmt.tprintf("%#v",before))
		if kind==8 do h.registry.active_instances=0
		testing.expect_value(t,h.registry.active_instances,0)
		h.service.bridge_runtime_registry=&h.registry
		h.ar=sqlite.new_agent_repository(&h.ai,&h.db)
		start_test_sql(t,h,"UPDATE bridge_provider_settings SET transport=NULL;")
	}
}
start_test_pending :: proc(_:rawptr,_,_:string,_:bool)->([]domain.Instance_Reconfiguration,domain.Domain_Error) {
	ops:=make([]domain.Instance_Reconfiguration,1)
	return ops,{}
}
start_test_guard_refuse :: proc(_:rawptr)->domain.Domain_Error {return domain.domain_error(.Forbidden,"guard refused")}
start_restart_refused_scenario :: proc(t:^testing.T,h:^Start_Test) {
	start_test_sql(t,h,"UPDATE bridges SET status='offline'; UPDATE agent_instances SET stopped_by='user';")
	_,ok,err:=restart_instance(&h.service,start_test_auth(),"inst")
	testing.expect(t,!ok)
	testing.expect_value(t,err.code,domain.Error_Code.Bridge_Offline)
	testing.expect_value(t,start_test_row(t,h).stopped_by,"user")
}
start_send_failure_scenario :: proc(t:^testing.T,h:^Start_Test) {
	h.fail_send=true
	_,ok,err:=start_instance(&h.service,start_test_auth(),"inst")
	testing.expect(t,!ok)
	testing.expect_value(t,err.code,domain.Error_Code.Bridge_Offline)
	inst:=start_test_row(t,h)
	testing.expect_value(t,inst.runtime_status,"launching")
	testing.expect_value(t,inst.stopped_at,"")
	testing.expect_value(t,inst.run_count,4)
	testing.expect_value(t,h.registry.active_instances,0)
}
start_uow_scenario :: proc(t:^testing.T,h:^Start_Test) {
	repos:=iface.Repositories{agents=h.ar}
	impl:sqlite.SQLite_Unit_Of_Work_Factory
	factory:=sqlite.new_unit_of_work_factory(&impl,&h.db,&repos)
	uow,begun,err:=iface.unit_of_work_begin(&factory)
	if !testing.expect(t,begun,err.message) do return
	defer if uow.ctx!=nil do iface.unit_of_work_rollback(&uow)
	ticket,begin_err:=start_begin(&h.service,start_test_auth(),"inst",{ref="transaction"})
	testing.expect_value(t,begin_err.code,domain.Error_Code.None)
	testing.expect_value(t,start_test_row(t,h).run_count,4)
	testing.expect_value(t,len(h.commands),0)
	iface.unit_of_work_rollback(&uow)
	testing.expect_value(t,start_test_row(t,h).run_count,3)
	start_cancel(&h.service,&ticket)
	start_ticket_destroy(&ticket)
	testing.expect_value(t,h.registry.active_instances,0)
}
start_bridge_scenario :: proc(t:^testing.T,h:^Start_Test) {
	launch,count,reused,ok,err:=start_begin_for_bridge(&h.service,"owner","brg","inst","dlv_test")
	testing.expect(t,ok,err.message)
	testing.expect(t,!reused)
	testing.expect_value(t,count,4)
	inst:=start_test_row(t,h)
	testing.expect_value(t,inst.start_ref,"dlv_test")
	testing.expect_value(t,inst.runtime_status,"launching")
	testing.expect_value(t,inst.startup_status,"starting")
	testing.expect_value(t,h.registry.active_instances,1)
	expected:=start_launch_json(&h.service,{instance=inst,command_id="sb_dlv_test"})
	testing.expect_value(t,launch,expected)
	again,count2,reused2,ok2,err2:=start_begin_for_bridge(&h.service,"owner","brg","inst","dlv_test")
	testing.expect(t,ok2,err2.message)
	testing.expect(t,reused2)
	testing.expect_value(t,count2,count)
	testing.expect_value(t,again,launch)
	start_test_sql(t,h,"UPDATE agent_instances SET runtime_status='stopped';")
	_,count3,_,ok3,err3:=start_begin_for_bridge(&h.service,"owner","brg","inst","dlv_next")
	testing.expect(t,ok3,err3.message)
	testing.expect_value(t,count3,5)
}
start_reused_live_scenario :: proc(t:^testing.T,h:^Start_Test) {
	ticket,err:=start_begin(&h.service,start_test_auth(),"inst",{ref="same"})
	testing.expect_value(t,err.code,domain.Error_Code.None)
	start_cancel(&h.service,&ticket)
	start_ticket_destroy(&ticket)
	for status in ([]string{"starting","running","idle","busy","failed","unreachable"}) {
		start_test_sql(t,h,fmt.tprintf("UPDATE agent_instances SET runtime_status='%s';",status))
		before:=start_test_row(t,h)
		ticket,err=start_begin(&h.service,start_test_auth(),"inst",{ref="same",if_live=.Relaunch})
		testing.expect_value(t,err.code,domain.Error_Code.None)
		if runtime_expected_active(status) {
			testing.expect(t,ticket.reused && !ticket.reserved)
			testing.expect_value(t,ticket.instance.run_count,before.run_count)
			testing.expect_value(t,ticket.instance.launch_epoch,before.launch_epoch)
		} else {
			testing.expect(t,!ticket.reused && ticket.reserved)
			testing.expect_value(t,ticket.instance.run_count,before.run_count+1)
		}
		start_cancel(&h.service,&ticket)
		start_ticket_destroy(&ticket)
	}
}
start_reuse_scenario :: proc(t:^testing.T,h:^Start_Test) {
	start_test_sql(t,h,"UPDATE agent_instances SET start_ref='same';")
	for status in ([]string{"running","failed","stopped","unreachable"}) {
		start_test_sql(t,h,fmt.tprintf("UPDATE agent_instances SET runtime_status='%s';",status))
		before:=start_test_row(t,h)
		ticket,ok,ended,err:=start_reuse(&h.service,"inst","same")
		testing.expect_value(t,err.code,domain.Error_Code.None)
		testing.expect_value(t,ok,status=="running")
		testing.expect_value(t,ended,status!="running")
		start_ticket_destroy(&ticket)
		testing.expect_value(t,fmt.tprintf("%#v",start_test_row(t,h)),fmt.tprintf("%#v",before))
		testing.expect_value(t,h.registry.active_instances,0)
	}
	start_test_sql(t,h,"UPDATE agent_instances SET runtime_status='running',start_ref='replacement';")
	before:=start_test_row(t,h)
	ticket,ok,ended,err:=start_reuse(&h.service,"inst","same")
	testing.expect(t,!ok && ended && err.code==.None)
	start_ticket_destroy(&ticket)
	testing.expect_value(t,fmt.tprintf("%#v",start_test_row(t,h)),fmt.tprintf("%#v",before))
}
start_clears_stop_scenario :: proc(t:^testing.T,h:^Start_Test) {
	start_test_sql(t,h,"UPDATE agent_instances SET stopped_by='user';")
	_,_,_,ok,err:=start_begin_for_bridge(&h.service,"owner","brg","inst","stop")
	testing.expect(t,ok,err.message)
	testing.expect_value(t,start_test_row(t,h).stopped_by,"")
}
start_refuse_bridge_live_scenario :: proc(t:^testing.T,h:^Start_Test) {
	for state in ([]string{"launching","running","idle"}) {
		for ref in ([]string{"","another"}) {
			start_test_sql(t,h,fmt.tprintf("UPDATE agent_instances SET runtime_status='%s',start_ref='%s',stopped_by='user';",state,ref))
			before:=start_test_row(t,h)
			_,_,_,ok,err:=start_begin_for_bridge(&h.service,"owner","brg","inst","request")
			testing.expect(t,!ok)
			testing.expect_value(t,err.code,domain.Error_Code.Conflict)
			testing.expect(t,strings.contains(err.details_json,"already_running"))
			testing.expect_value(t,fmt.tprintf("%#v",start_test_row(t,h)),fmt.tprintf("%#v",before))
			testing.expect_value(t,h.registry.active_instances,0)
		}
	}
}
start_reaper_scenario :: proc(t:^testing.T,h:^Start_Test) {
	start_test_sql(t,h,"UPDATE agent_instances SET runtime_status='running',last_seen_at='2026-11-22T11:58:29Z';")
	_,_,_,ok,err:=start_begin_for_bridge(&h.service,"owner","brg","inst","reap")
	testing.expect(t,!ok)
	testing.expect(t,strings.contains(err.details_json,"already_running"))
	reaped:=reap_stale_instances(&h.service,90_000)
	testing.expect_value(t,len(reaped),1)
	testing.expect_value(t,start_test_row(t,h).runtime_status,"unreachable")
	_,count,_,started,serr:=start_begin_for_bridge(&h.service,"owner","brg","inst","reap")
	testing.expect(t,started,serr.message)
	testing.expect_value(t,count,4)
}
start_create_scenario :: proc(t:^testing.T,h:^Start_Test) {
	// Creating a stopped row needs no launch capacity and mints no epoch.
	h.registry.limits.active_instances = 1
	h.registry.active_instances = 1
	inst,ok,err:=create_instance_stopped(&h.service,start_test_auth(),{agent_id="agt",bridge_id="brg",provider="codex",model="gpt-6.1-sol"})
	testing.expect(t,ok,err.message)
	testing.expect_value(t,inst.run_count,0)
	testing.expect_value(t,inst.runtime_status,"stopped")
	testing.expect_value(t,inst.startup_status,"stopped")
	testing.expect_value(t,inst.launch_epoch,"")
	testing.expect_value(t,h.registry.active_instances,1)
	h.registry.active_instances = 0
	_,found,cerr:=iface.content_get_conversation(&h.cr,inst.conversation_id)
	testing.expect(t,found,cerr.message)
	first,started,serr:=start_instance(&h.service,start_test_auth(),inst.agent_instance_id)
	testing.expect(t,started,serr.message)
	testing.expect_value(t,first.run_count,1)
}
start_guarded_save_scenario :: proc(t:^testing.T,h:^Start_Test) {
	inst:=start_test_row(t,h)
	next:=inst
	next.run_count+=1
	next.start_ref="winner"
	_,updated,err:=iface.agent_save_instance_guarded(&h.ar,next,inst.run_count,inst.launch_epoch,inst.configuration_revision)
	testing.expect(t,updated,err.message)
	next.start_ref="loser"
	_,updated,err=iface.agent_save_instance_guarded(&h.ar,next,inst.run_count,inst.launch_epoch,inst.configuration_revision)
	testing.expect(t,!updated)
	testing.expect_value(t,err.code,domain.Error_Code.None)
	testing.expect_value(t,start_test_row(t,h).start_ref,"winner")
	// Neither the old epoch nor the old config may win, and no deleted row is recreated.
	_,updated,_=iface.agent_save_instance_guarded(&h.ar,next,4,"wrong",0)
	testing.expect(t,!updated)
	_,updated,_=iface.agent_save_instance_guarded(&h.ar,next,4,"",1)
	testing.expect(t,!updated)
	next.agent_instance_id="missing"
	_,updated,_=iface.agent_save_instance_guarded(&h.ar,next,0,"",0)
	testing.expect(t,!updated)
}

@(test)
test_start_keeps_launch_bytes :: proc(t:^testing.T) { start_test_run(t,start_bytes_scenario) }

@(test)
test_start_if_live_table :: proc(t:^testing.T) { start_test_run(t,start_live_scenario) }

@(test)
test_start_refusals_write_nothing :: proc(t:^testing.T) { start_test_run(t,start_refusals_scenario) }

@(test)
test_start_restart_refused_keeps_user_stop :: proc(t:^testing.T) { start_test_run(t,start_restart_refused_scenario) }

@(test)
test_start_send_failure_preserves_unconfirmed_runtime :: proc(t:^testing.T) { start_test_run(t,start_send_failure_scenario) }

@(test)
test_start_begin_in_open_unit_of_work :: proc(t:^testing.T) { start_test_run(t,start_uow_scenario) }

@(test)
test_start_begin_opens_generation :: proc(t:^testing.T) { start_test_run(t,start_bridge_scenario) }

@(test)
test_start_begin_is_idempotent_per_ref :: proc(t:^testing.T) { start_test_run(t,start_bridge_scenario) }

@(test)
test_start_begin_reuses_ref_in_any_live_status :: proc(t:^testing.T) { start_test_run(t,start_reused_live_scenario) }

@(test)
test_start_reuse_never_writes :: proc(t:^testing.T) { start_test_run(t,start_reuse_scenario) }

@(test)
test_start_begin_clears_user_stop :: proc(t:^testing.T) { start_test_run(t,start_clears_stop_scenario) }

@(test)
test_start_begin_refuses_live_row :: proc(t:^testing.T) { start_test_run(t,start_refuse_bridge_live_scenario) }

@(test)
test_reaped_row_accepts_start_begin :: proc(t:^testing.T) { start_test_run(t,start_reaper_scenario) }

@(test)
test_create_instance_stopped :: proc(t:^testing.T) { start_test_run(t,start_create_scenario) }

@(test)
test_create_instance_first_generation_is_one :: proc(t:^testing.T) { start_test_run(t,start_create_first_scenario) }

@(test)
test_start_repository_guarded_save :: proc(t:^testing.T) { start_test_run(t,start_guarded_save_scenario) }

start_test_racing_save :: proc(ctx:rawptr, next:domain.Agent_Instance, count:int, epoch:string, revision:int)->(domain.Agent_Instance,bool,domain.Domain_Error) {
	winner:=next
	winner.start_ref="lease_winner"
	_,won,err:=sqlite.agent_save_instance_guarded_sqlite(ctx,winner,count,epoch,revision)
	if !won do return {},false,err
	return sqlite.agent_save_instance_guarded_sqlite(ctx,next,count,epoch,revision)
}
start_race_scenario :: proc(t:^testing.T,h:^Start_Test) {
	h.ar.save_instance_guarded=start_test_racing_save
	ticket,err:=start_begin(&h.service,start_test_auth(),"inst",{ref="manual"})
	testing.expect_value(t,err.code,domain.Error_Code.Conflict)
	testing.expect(t,strings.contains(err.details_json,"start_raced"))
	start_ticket_destroy(&ticket)
	stored:=start_test_row(t,h)
	testing.expect_value(t,stored.run_count,4)
	testing.expect_value(t,stored.start_ref,"lease_winner")
	testing.expect_value(t,h.registry.active_instances,0)
	testing.expect_value(t,len(h.commands),0)
}
start_status_scenario :: proc(t:^testing.T,h:^Start_Test) {
	ticket,err:=start_begin(&h.service,start_test_auth(),"inst",{ref="status"})
	testing.expect_value(t,err.code,domain.Error_Code.None)
	testing.expect_value(t,h.registry.active_instances,1)
	proof := Process_Exit_Evidence{pid = 42, exit_code = 1, run_count = ticket.instance.run_count}
	_,ok,serr:=apply_bridge_status_report(&h.service,"brg","inst",1,"failed","unknown","owner",ticket.instance.launch_epoch, reason = "pty_child_exited", process_exit = &proof)
	testing.expect(t,ok,serr.message)
	// The HTTP status handler applies accepted rows to the runtime registry.
	generation:=project_service.bridge_runtime_registry_generation(&h.registry,"brg")
	_,_,tracking_err:=project_service.bridge_runtime_instance_apply(&h.registry,"brg",generation,"inst","owner","failed","unknown",1)
	testing.expect_value(t,tracking_err.code,domain.Error_Code.None)
	testing.expect_value(t,h.registry.active_instances,0)
	start_ticket_destroy(&ticket)
}
start_expiry_scenario :: proc(t:^testing.T,h:^Start_Test) {
	reserved_at:=time.now()._nsec
	ticket,err:=start_begin(&h.service,start_test_auth(),"inst",{ref="expiry"})
	testing.expect_value(t,err.code,domain.Error_Code.None)
	generation:=project_service.bridge_runtime_registry_generation(&h.registry,"brg")
	state,found:=project_service.bridge_runtime_instance_get(&h.registry,"brg",generation,"inst")
	testing.expect(t,found && state.reserved)
	testing.expect(t,state.expires_ns-reserved_at >= i64(time.Minute))
	testing.expect(t,state.expires_ns-reserved_at <= i64(61*time.Second))
	testing.expect_value(t,project_service.bridge_runtime_registry_sweep(&h.registry,reserved_at+i64(59*time.Second)),0)
	testing.expect_value(t,h.registry.active_instances,1)
	testing.expect_value(t,project_service.bridge_runtime_registry_sweep(&h.registry,reserved_at+i64(61*time.Second)),1)
	testing.expect_value(t,h.registry.active_instances,0)
	testing.expect_value(t,start_test_row(t,h).runtime_status,"launching")
	start_ticket_destroy(&ticket)
}
start_success_scenario :: proc(t:^testing.T,h:^Start_Test) {
	ticket,err:=start_begin(&h.service,start_test_auth(),"inst",{ref="success"})
	testing.expect_value(t,err.code,domain.Error_Code.None)
	auth:=contracts.Auth_Context{kind=.Instance_Token,user_id="owner",agent_instance_id="inst"}
	running,ok,serr:=mark_instance_start_success(&h.service,auth,ticket.instance.run_count)
	testing.expect(t,ok,serr.message)
	testing.expect_value(t,running.runtime_status,"running")
	testing.expect_value(t,running.run_count,4)
	testing.expect_value(t,start_send(&h.service,&ticket).code,domain.Error_Code.None)
	testing.expect_value(t,len(h.commands),1)
	testing.expect_value(t,h.registry.active_instances,1)
	testing.expect_value(t,start_test_row(t,h).run_count,4)
	start_settle(&h.service,&ticket,true)
	testing.expect_value(t,start_test_row(t,h).runtime_status,"running")
	start_ticket_destroy(&ticket)
}
start_acp_scenario :: proc(t:^testing.T,h:^Start_Test) {
	start_test_sql(t,h,`UPDATE bridges SET capabilities_json='{"features":["acp_runtime_v1"]}'; UPDATE bridge_provider_settings SET transport='acp';`)
	_,err:=iface.bridge_provider_status_upsert(&h.pr,{bridge_id="brg",provider="codex",binary_path="/bin/codex",state="present",checked_at=START_TEST_NOW,acp_adapter_json=`{"installed":true,"state":"ready","version":"0.162.0","runtime_kind":"system","checked_at":"now"}`})
	testing.expect_value(t,err.code,domain.Error_Code.None)
	start_test_sql(t,h,"UPDATE agent_instances SET launch_epoch='old_epoch';")
	ticket,berr:=start_begin(&h.service,start_test_auth(),"inst",{ref="acp"})
	testing.expect_value(t,berr.code,domain.Error_Code.None)
	testing.expect_value(t,ticket.instance.runtime_transport,"acp")
	testing.expect(t,strings.has_prefix(ticket.instance.launch_epoch,"launch_"))
	_,new_ok,new_err:=apply_bridge_status_report(&h.service,"brg","inst",1,"starting","unknown","owner",ticket.instance.launch_epoch)
	testing.expect(t,new_ok,new_err.message)
	_,old_ok,old_err:=apply_bridge_status_report(&h.service,"brg","inst",2,"failed","unknown","owner","old_epoch")
	testing.expect(t,!old_ok)
	testing.expect_value(t,old_err.code,domain.Error_Code.Conflict)
	launch:=start_launch_json(&h.service,ticket)
	testing.expect(t,strings.contains(launch,fmt.tprintf("\"launch_epoch\":\"%s\"",ticket.instance.launch_epoch)))
	auth,_,valid,verr:=verify_instance_token(&h.service,instance_assertion_token(ticket.instance))
	testing.expect(t,valid,verr.message)
	_,accepted,serr:=mark_instance_start_success(&h.service,auth,ticket.instance.run_count)
	testing.expect(t,accepted,serr.message)
	start_ticket_destroy(&ticket)
}
start_owned_scenario :: proc(t:^testing.T,h:^Start_Test) {
	track:mem.Tracking_Allocator
	mem.tracking_allocator_init(&track,runtime.heap_allocator());defer mem.tracking_allocator_destroy(&track)
	allocator:=mem.tracking_allocator(&track)
	{
		context.allocator=allocator
		ticket,err:=start_begin(&h.service,start_test_auth(),"inst",{ref="owned"},allocator)
		testing.expect_value(t,err.code,domain.Error_Code.None)
		launch:=start_launch_json(&h.service,ticket,allocator=allocator)
		delete(launch,allocator)
		start_cancel(&h.service,&ticket)
		start_ticket_destroy(&ticket)
	}
	testing.expect_value(t,len(track.allocation_map),0)

}

@(test)
test_start_begin_race_with_manual_start :: proc(t:^testing.T) {start_test_run(t,start_thread_race_scenario)}

@(test)
test_grant_race_with_manual_start :: proc(t:^testing.T) {start_test_run(t,start_race_scenario)}

@(test)
test_start_begin_failed_status_releases_reservation :: proc(t:^testing.T) {start_test_run(t,start_status_scenario)}

@(test)
test_start_begin_reservation_expires :: proc(t:^testing.T) {start_test_run(t,start_expiry_scenario)}

@(test)
test_start_success_before_command_result :: proc(t:^testing.T) {start_test_run(t,start_success_scenario)}

@(test)
test_start_success_when_command_result_is_lost :: proc(t:^testing.T) {start_test_run(t,start_success_scenario)}

@(test)
test_start_begin_acp_epoch :: proc(t:^testing.T) {start_test_run(t,start_acp_scenario)}

@(test)
test_start_ticket_ownership :: proc(t:^testing.T) {start_test_run(t,start_owned_scenario)}

Start_Race_Job :: struct { h:^Start_Test, bridge:bool, ref:string, opened, already:bool }
start_race_job :: proc(job:^Start_Race_Job) {
	arena:virtual.Arena
	assert(virtual.arena_init_growing(&arena)==nil)
	defer virtual.arena_destroy(&arena)
	context.allocator=virtual.arena_allocator(&arena)
	context.temp_allocator=context.allocator
	if job.bridge {
		_,_,_,ok,err:=start_begin_for_bridge(&job.h.service,"owner","brg","inst",job.ref)
		job.opened=ok
		job.already=err.code==.Conflict && strings.contains(err.details_json,"already_running")
	} else {
		_,ok,err:=start_instance(&job.h.service,start_test_auth(),"inst")
		job.opened=ok
		job.already=err.code==.Conflict && strings.contains(err.details_json,"already_running")
	}
}
start_thread_race_scenario :: proc(t:^testing.T,h:^Start_Test) {
	for round in 0..<100 {
		start_test_sql(t,h,"UPDATE agent_instances SET runtime_status='stopped';")
		ref:=fmt.tprintf("race_%d",round)
		jobs: [2]Start_Race_Job
		jobs[0]={h=h}
		jobs[1]={h=h,bridge=true,ref=ref}
		threads:[2]^thread.Thread
		previous_allocator:=context.allocator
		context.allocator=runtime.heap_allocator()
		for j in 0..<2 do threads[j]=thread.create_and_start_with_poly_data(&jobs[j],start_race_job)
		context.allocator=previous_allocator
		for th in threads {thread.join(th);thread.destroy(th)}
		testing.expectf(t,jobs[0].opened!=jobs[1].opened,"round %d: one winner",round)
		testing.expect(t,jobs[0].already!=jobs[1].already)
		testing.expect_value(t,start_test_row(t,h).run_count,4+round)
	}
}
start_wrong_target_scenario :: proc(t:^testing.T,h:^Start_Test) {
	before:=start_test_row(t,h)
	for owner in ([]domain.User_ID{"owner","other"}) {
		for bridge in ([]string{"brg","other"}) {
			if owner=="owner" && bridge=="brg" do continue
			_,_,_,ok,err:=start_begin_for_bridge(&h.service,owner,bridge,"inst","wrong")
			testing.expect(t,!ok)
			testing.expect_value(t,err.code,domain.Error_Code.Not_Found)
			testing.expect_value(t,fmt.tprintf("%#v",start_test_row(t,h)),fmt.tprintf("%#v",before))
			testing.expect_value(t,h.registry.active_instances,0)
		}
	}
}
start_create_first_scenario :: proc(t:^testing.T,h:^Start_Test) {
	inst,ok,err:=create_instance(&h.service,start_test_auth(),{agent_id="agt",bridge_id="brg",provider="codex",model="gpt-6.1-sol"})
	testing.expect(t,ok,err.message)
	testing.expect_value(t,inst.run_count,1)
	testing.expect_value(t,len(h.commands),1)
	if len(h.commands)==1 do testing.expect_value(t,h.commands[0],start_test_expected(t,h,2))
}

@(test)
test_start_begin_guarded_save :: proc(t:^testing.T) {start_test_run(t,start_race_scenario)}
@(test)
test_start_begin_wrong_bridge_or_owner :: proc(t:^testing.T) {start_test_run(t,start_wrong_target_scenario)}

start_projection_scenario :: proc(t:^testing.T,h:^Start_Test) {
	start_test_sql(t,h,"UPDATE agent_instances SET start_ref='projection',runtime_status='running',chain_id='projection_chain';")
	rows,e:=iface.agent_list_instances_by_owner(&h.ar,"owner")
	testing.expect_value(t,e.code,domain.Error_Code.None)
	testing.expect_value(t,len(rows),1)
	if len(rows)==1 do testing.expect_value(t,rows[0].start_ref,"projection")
	rows,e=iface.agent_list_instances_by_owner(&h.ar,"owner",50,"2026-11-23T00:00:00Z")
	testing.expect_value(t,e.code,domain.Error_Code.None)
	testing.expect_value(t,len(rows),1)
	if len(rows)==1 do testing.expect_value(t,rows[0].start_ref,"projection")
	rows,e=iface.agent_list_instances_by_bridge(&h.ar,"brg")
	testing.expect_value(t,e.code,domain.Error_Code.None)
	testing.expect_value(t,len(rows),1)
	if len(rows)==1 do testing.expect_value(t,rows[0].start_ref,"projection")
	rows,e=iface.agent_list_instances_by_chain(&h.ar,"owner","projection_chain")
	testing.expect_value(t,e.code,domain.Error_Code.None)
	testing.expect_value(t,len(rows),1)
	if len(rows)==1 do testing.expect_value(t,rows[0].start_ref,"projection")
	rows,e=iface.agent_list_active_runtime_instances(&h.ar)
	testing.expect_value(t,e.code,domain.Error_Code.None)
	testing.expect_value(t,len(rows),1)
	if len(rows)==1 do testing.expect_value(t,rows[0].start_ref,"projection")
}
@(test)
test_start_ref_survives_repository_projections :: proc(t:^testing.T) {start_test_run(t,start_projection_scenario)}

start_test_fail_display_save :: proc(ctx:rawptr, next:domain.Agent_Instance, count:int, epoch:string, revision:int)->(domain.Agent_Instance,bool,domain.Domain_Error) {
	if next.runtime_status=="launching" && next.run_count==count {
		if next.display_name=="fail_busy" do return {},false,domain.domain_error(.Bridge_Busy,"injected display save failure")
		if next.display_name=="fail_conflict" do return {},false,{}
	}
	return sqlite.agent_save_instance_guarded_sqlite(ctx,next,count,epoch,revision)
}
start_reconfigure_settle_scenario :: proc(t:^testing.T,h:^Start_Test) {
	h.ar.save_instance_guarded=start_test_fail_display_save
	for name in ([]string{"fail_busy","fail_conflict"}) {
		start_test_sql(t,h,"UPDATE agent_instances SET runtime_status='running';")
		before:=start_test_row(t,h)
		_,ok,err:=reconfigure_instance(&h.service,start_test_auth(),"inst",{has_display_name=true,display_name=name})
		testing.expect(t,!ok)
		testing.expect_value(t,err.code,domain.Error_Code.Bridge_Busy if name=="fail_busy" else domain.Error_Code.Conflict)
		after:=start_test_row(t,h)
		testing.expect_value(t,after.runtime_status,"launching")
		testing.expect_value(t,after.startup_status,"starting")
		testing.expect_value(t,after.run_count,before.run_count+1)
		testing.expect_value(t,h.registry.active_instances,0)
		testing.expect_value(t,len(h.commands),0)
	}
}
@(test)
test_reconfigure_display_save_failure_settles_committed_start :: proc(t:^testing.T) {start_test_run(t,start_reconfigure_settle_scenario)}

start_expected_generation_scenario :: proc(t:^testing.T,h:^Start_Test) {
 selected:=start_test_row(t,h)
 start_test_sql(t,h,"UPDATE agent_instances SET run_count=4,runtime_status='running';")
 for policy in ([]Start_If_Live{.Keep,.Relaunch,.Refuse}) {
  ticket,err:=start_begin(&h.service,start_test_auth(),"inst",{expected=&selected,if_live=policy})
  testing.expect_value(t,err.code,domain.Error_Code.Conflict)
  testing.expect(t,strings.contains(err.details_json,"start_raced"),"stale selection is rejected before live policy")
  start_ticket_destroy(&ticket)
 }
 testing.expect_value(t,start_test_row(t,h).run_count,4)
 testing.expect_value(t,h.registry.active_instances,0)
 // A caller with no snapshot keeps the established live policy.
 kept,kerr:=start_begin(&h.service,start_test_auth(),"inst",{if_live=.Keep})
 testing.expect_value(t,kerr.code,domain.Error_Code.None)
 testing.expect(t,kept.kept_live)
 start_settle(&h.service,&kept,true);start_ticket_destroy(&kept)
 relaunched,rerr:=start_begin(&h.service,start_test_auth(),"inst",{if_live=.Relaunch})
 testing.expect_value(t,rerr.code,domain.Error_Code.None)
 testing.expect_value(t,relaunched.instance.run_count,5)
 start_settle(&h.service,&relaunched,true);start_ticket_destroy(&relaunched)
}
@(test)
test_start_expected_generation_precedes_live_policy :: proc(t:^testing.T) {start_test_run(t,start_expected_generation_scenario)}

start_action_bot_scenario :: proc(t:^testing.T,h:^Start_Test) {
 start_test_sql(t,h,"UPDATE agent_instances SET kind='bot',stopped_by='user',runtime_status='stopped';")
 // This is the same bridge endpoint used by event-executor and bot-delivery starts.
 text,count,reused,ok,err:=start_begin_for_bridge(&h.service,"owner","brg","inst","event_action-delivery")
 defer delete(text)
 testing.expect(t,ok && err.code==.None,err.message)
 testing.expect_value(t,count,4)
 testing.expect(t,!reused && text!="")
 inst:=start_test_row(t,h)
 defer domain.agent_instance_destroy(&inst)
 testing.expect_value(t,inst.stopped_by,"")
 testing.expect_value(t,inst.runtime_status,"launching")
 testing.expect_value(t,inst.start_ref,"event_action-delivery")
}
@(test)
test_action_start_wakes_user_stopped_bot :: proc(t:^testing.T) {start_test_run(t,start_action_bot_scenario)}

start_rollover_after_user_stop_scenario :: proc(t:^testing.T,h:^Start_Test) {
	start_test_sql(t,h,"UPDATE agent_instances SET runtime_status='running';")
	selected := start_test_row(t,h)
	_, stopped, stop_err := stop_instance(&h.service,start_test_auth(),"inst",{reason="user_requested"})
	testing.expect(t,stopped,stop_err.message)
	before := start_test_row(t,h)
	auth := contracts.Auth_Context{kind=.Instance_Token,user_id="owner",agent_instance_id="inst"}
	_, restarted, err := restart_instance(&h.service,auth,"inst")
	testing.expect(t,!restarted,"delayed self restart cannot undo user stop")
	testing.expect_value(t,err.code,domain.Error_Code.Conflict)
	testing.expect_value(t,start_test_row(t,h).run_count,before.run_count)
	testing.expect_value(t,start_test_row(t,h).stopped_by,"user")
	testing.expect_value(t,h.registry.active_instances,0)
	testing.expect_value(t,len(h.commands),1) // Only the stop, no launch.
	// The same stop also invalidates an earlier fleet selection snapshot.
	_, _, stale, stale_err := start(&h.service,start_test_auth(),"inst",{if_live=.Relaunch,expected=&selected})
	testing.expect(t,!stale)
	testing.expect_value(t,stale_err.code,domain.Error_Code.Conflict)
	testing.expect_value(t,start_test_row(t,h).run_count,before.run_count)
	testing.expect_value(t,len(h.commands),1)
	// A new explicit user intent may still restart the stopped instance.
	manual, manual_ok, manual_err := restart_instance(&h.service,start_test_auth(),"inst")
	testing.expect(t,manual_ok,manual_err.message)
	testing.expect_value(t,manual.run_count,before.run_count+1)
	testing.expect_value(t,manual.stopped_by,"")
	testing.expect_value(t,start_test_row(t,h).stop_reason,"")
	testing.expect_value(t,len(h.commands),2)
}

@(test)
test_rollover_after_user_stop_is_refused :: proc(t:^testing.T) {start_test_run(t,start_rollover_after_user_stop_scenario)}

start_rollover_duplicate_scenario :: proc(t:^testing.T,h:^Start_Test) {
	start_test_sql(t,h,"UPDATE agent_instances SET runtime_status='running';")
	auth := contracts.Auth_Context{kind=.Instance_Token,user_id="owner",agent_instance_id="inst"}
	inst, ok, err := restart_instance(&h.service,auth,"inst",{expected_run_count=3})
	testing.expect(t,ok,err.message)
	testing.expect_value(t,inst.run_count,4)
	testing.expect_value(t,len(h.commands),1)
	testing.expect_value(t,h.registry.active_instances,1)
	_, again, duplicate_err := restart_instance(&h.service,auth,"inst",{expected_run_count=3})
	testing.expect(t,!again)
	testing.expect_value(t,duplicate_err.code,domain.Error_Code.Conflict)
	testing.expect_value(t,start_test_row(t,h).run_count,4)
	testing.expect_value(t,len(h.commands),1)
	testing.expect_value(t,h.registry.active_instances,1)
}

start_rollover_failed_send_scenario :: proc(t:^testing.T,h:^Start_Test) {
	start_test_sql(t,h,"UPDATE agent_instances SET runtime_status='running';")
	h.fail_send=true
	auth := contracts.Auth_Context{kind=.Instance_Token,user_id="owner",agent_instance_id="inst"}
	_, ok, err := restart_instance(&h.service,auth,"inst",{expected_run_count=3})
	testing.expect(t,!ok)
	testing.expect_value(t,err.code,domain.Error_Code.Bridge_Offline)
	testing.expect_value(t,start_test_row(t,h).run_count,4)
	testing.expect_value(t,start_test_row(t,h).runtime_status,"launching")
	testing.expect_value(t,h.registry.active_instances,0)
	h.fail_send=false
	_, again, retry_err := restart_instance(&h.service,auth,"inst",{expected_run_count=3})
	testing.expect(t,!again,"ambiguous failed restart is never retried as a new generation")
	testing.expect_value(t,retry_err.code,domain.Error_Code.Conflict)
	testing.expect_value(t,len(h.commands),1)
	testing.expect_value(t,h.registry.active_instances,0)
}

start_rollover_reconfiguration_scenario :: proc(t:^testing.T,h:^Start_Test) {
	start_test_sql(t,h,`UPDATE bridges SET capabilities_json='{"features":["instance_reconfiguration_v1"]}'; UPDATE agent_instances SET runtime_status='running';`)
	// A real durable operation admitted first fences rollover without changing
	// its destination or opening another launch generation.
	op, accepted, err := begin_instance_reconfiguration(&h.service,start_test_auth(),"inst",{bridge_id="brg",provider="codex",provider_profile="codex",model="gpt-6.1-sol",permission_mode="ask",idempotency_key="configuration",expected_revision=0})
	testing.expect(t,accepted,err.message)
	testing.expect_value(t,op.destination.permission_mode,"ask")
	before := start_test_row(t,h)
	commands, reservations := len(h.commands), h.registry.active_instances
	auth := contracts.Auth_Context{kind=.Instance_Token,user_id="owner",agent_instance_id="inst"}
	_, restarted, restart_err := restart_instance(&h.service,auth,"inst",{expected_run_count=before.run_count})
	testing.expect(t,!restarted)
	testing.expect_value(t,restart_err.code,domain.Error_Code.Conflict)
	testing.expect_value(t,start_test_row(t,h).run_count,before.run_count)
	testing.expect_value(t,start_test_row(t,h).configuration_revision,before.configuration_revision)
	testing.expect_value(t,start_test_row(t,h).provider_profile,before.provider_profile)
	testing.expect_value(t,len(h.commands),commands)
	testing.expect_value(t,h.registry.active_instances,reservations)
	stored, found, read_err := iface.instance_reconfiguration_get(&h.ar,"owner","inst","configuration")
	testing.expect(t,found,read_err.message)
	testing.expect_value(t,stored.operation_id,op.operation_id)
	testing.expect_value(t,stored.destination.permission_mode,"ask")
}

start_rollover_before_reconfiguration_scenario :: proc(t:^testing.T,h:^Start_Test) {
	start_test_sql(t,h,`UPDATE bridges SET capabilities_json='{"features":["instance_reconfiguration_v1"]}'; UPDATE agent_instances SET runtime_status='running';`)
	auth := contracts.Auth_Context{kind=.Instance_Token,user_id="owner",agent_instance_id="inst"}
	inst, restarted, err := restart_instance(&h.service,auth,"inst",{expected_run_count=3})
	testing.expect(t,restarted,err.message)
	op, accepted, config_err := begin_instance_reconfiguration(&h.service,start_test_auth(),"inst",{bridge_id="brg",provider="codex",provider_profile="codex",model="gpt-6.1-sol",permission_mode="ask",idempotency_key="configuration",expected_revision=inst.configuration_revision})
	testing.expect(t,accepted,config_err.message)
	testing.expect_value(t,op.source.bridge_id,"brg")
	testing.expect_value(t,op.destination.permission_mode,"ask")
	testing.expect_value(t,start_test_row(t,h).run_count,4)
	commands := len(h.commands)
	_, duplicate, duplicate_err := restart_instance(&h.service,auth,"inst",{expected_run_count=3})
	testing.expect(t,!duplicate)
	testing.expect_value(t,duplicate_err.code,domain.Error_Code.Conflict)
	testing.expect_value(t,len(h.commands),commands)
	// Reconfiguration owns subsequent stop/commit/start; rollover never retries.
	testing.expect_value(t,start_test_row(t,h).configuration_revision,inst.configuration_revision)
	testing.expect_value(t,h.registry.active_instances,0)
}

@(test)
test_rollover_duplicate_restart_has_one_generation :: proc(t:^testing.T) {start_test_run(t,start_rollover_duplicate_scenario)}
@(test)
test_rollover_failed_restart_releases_reservation :: proc(t:^testing.T) {start_test_run(t,start_rollover_failed_send_scenario)}

start_ready_before_send_error_scenario :: proc(t: ^testing.T, h: ^Start_Test) {
	ticket, err := start_begin(&h.service, start_test_auth(), "inst", {})
	if !testing.expect_value(t, err.code, domain.Error_Code.None) do return
	defer start_ticket_destroy(&ticket)
	saved, applied, report_err := apply_bridge_status_report(&h.service, "brg", "inst", 1, "running", "idle", launch_epoch = ticket.instance.launch_epoch)
	if !testing.expect(t, applied, report_err.message) do return
	defer domain.agent_instance_destroy(&saved)

	start_settle(&h.service, &ticket, false)

	current := start_test_row(t, h)
	defer domain.agent_instance_destroy(&current)
	testing.expect_value(t, current.runtime_status, "running")
	testing.expect_value(t, current.startup_status, "ready")
	testing.expect_value(t, current.last_applied_seq, 1)
	testing.expect_value(t, current.stopped_at, "")
}

@(test)
test_start_send_error_cannot_overwrite_ready_report :: proc(t: ^testing.T) {
	start_test_run(t, start_ready_before_send_error_scenario)
}
@(test)
test_reconfiguration_before_rollover_preserves_destination :: proc(t:^testing.T) {start_test_run(t,start_rollover_reconfiguration_scenario)}
@(test)
test_rollover_before_reconfiguration_preserves_operation :: proc(t:^testing.T) {start_test_run(t,start_rollover_before_reconfiguration_scenario)}

start_test_confirmed_wait :: proc(ctx: rawptr, command: project_service.Runtime_Command, _: int) -> (string, bool, domain.Domain_Error) {
	h := (^Start_Test)(ctx)
	// The Bridge reader consumes accepted and terminal frames in order and
	// takes this lock while advancing reconfiguration. Do not wait while
	// holding it or the reader cannot reach the terminal reply.
	if !sync.mutex_try_lock(&h.service.reconfiguration_mutex) {
		return "", false, domain.domain_error(.Internal_Error, "runtime reply would deadlock on the Hub lifecycle lock")
	}
	sync.mutex_unlock(&h.service.reconfiguration_mutex)
	switch jsonx.extract_string(command.body_json, "type", "", true, context.temp_allocator) {
	case "instance.probe":
		return strings.concatenate({`{"ok":true,"command_id":"`, command.command_id, `","payload":{"result":{"agent_instance_id":"inst","state":"alive","pid":42,"run_count":3,"launch_epoch":""}}}`}), true, {}
	case "stop_agent":
		payload, ok := jsonx.extract_raw_object(command.body_json, "payload", true, context.temp_allocator)
		if !ok || jsonx.extract_int(payload, "expected_run_count", -1, true) != 3 || jsonx.extract_int(payload, "expected_process_pid", 0, true) != 42 {
			return "", false, domain.domain_error(.Validation_Failed, "unfenced stop")
		}
		if h.fail_confirmed_stop do return "", false, domain.domain_error(.Bridge_Timeout, "fixture stop did not acknowledge")
		return strings.concatenate({`{"ok":true,"command_id":"`, command.command_id, `","payload":{"status":"succeeded","result":{"agent_instance_id":"inst","expected_run_count":3,"expected_process_pid":42,"runtime_status":"stopped"}}}`}), true, {}
	case "launch_agent":
		if !jsonx.extract_bool(command.body_json, "confirm_start", false, true) do return "", false, domain.domain_error(.Validation_Failed, "missing confirmation")
		row, ready, err := mark_instance_start_success(&h.service, {kind = .Instance_Token, user_id = "owner", agent_instance_id = "inst"}, 4)
		defer domain.agent_instance_destroy(&row)
		if !ready do return "", false, err
		return strings.concatenate({`{"ok":true,"command_id":"`, command.command_id, `","payload":{"status":"succeeded","result":{"agent_instance_id":"inst","expected_run_count":4,"process_pid":43,"runtime_status":"running"}}}`}), true, {}
	}
	return "", false, domain.domain_error(.Validation_Failed, "unexpected fixture command")
}

confirmed_runtime_actions_scenario :: proc(t: ^testing.T, h: ^Start_Test) {
	start_test_sql(t, h, "UPDATE agent_instances SET runtime_status='running', startup_status='ready';")
	h.service.bridge_command_sink.send_runtime_command_wait = start_test_confirmed_wait
	h.fail_confirmed_stop = true
	_, stopped, stop_err := stop_instance_confirmed(&h.service, start_test_auth(), "inst", {})
	testing.expect(t, !stopped)
	testing.expect_value(t, stop_err.code, domain.Error_Code.Bridge_Timeout)
	before := start_test_row(t, h)
	testing.expect_value(t, before.runtime_status, "running")
	testing.expect_value(t, before.stopped_by, "")
	h.fail_confirmed_stop = false
	row, ok, err := stop_instance_confirmed(&h.service, start_test_auth(), "inst", {})
	testing.expect(t, ok, err.message)
	testing.expect_value(t, row.runtime_status, "stopped")
	testing.expect_value(t, row.stopped_by, "user")
	testing.expect_value(t, row.stop_reason, "user_requested")
}

confirmed_live_start_scenario :: proc(t: ^testing.T, h: ^Start_Test) {
	start_test_sql(t, h, "UPDATE agent_instances SET runtime_status='running', startup_status='ready';")
	h.service.bridge_command_sink.send_runtime_command_wait = start_test_confirmed_wait
	row, ok, err := start_instance_confirmed(&h.service, start_test_auth(), "inst")
	testing.expect(t, ok, err.message)
	testing.expect_value(t, row.runtime_status, "running")
	testing.expect_value(t, row.startup_status, "ready")
	testing.expect_value(t, row.run_count, 4)
}

@(test)
test_explicit_stop_requires_confirmed_exit :: proc(t: ^testing.T) { start_test_run(t, confirmed_runtime_actions_scenario) }
@(test)
test_explicit_start_replaces_live_generation_and_waits_for_ready :: proc(t: ^testing.T) { start_test_run(t, confirmed_live_start_scenario) }

task_stop_receipt_scenario :: proc(t: ^testing.T, h: ^Start_Test) {
	start_test_sql(t, h, "UPDATE agent_instances SET runtime_status='running', startup_status='ready', stop_reason='task_completed';")
	make_reply :: proc(op: string, run_count: int) -> string {
		return strings.concatenate({`{"ok":true,"command_id":"`, op, `","payload":{"status":"succeeded","result":{"agent_instance_id":"inst","expected_run_count":`, fmt.tprintf("%d", run_count), `,"runtime_status":"stopped"}}}`})
	}
	db_row := start_test_row(t, h)
	op := task_stop_command_id("inst", db_row.run_count)
	old_op := task_stop_command_id("inst", db_row.run_count - 1)
	_, stale := apply_task_stop_receipt(&h.service, db_row.bridge_id, old_op, make_reply(old_op, db_row.run_count - 1), db_row.owner_user_id)
	_, unrelated := apply_task_stop_receipt(&h.service, db_row.bridge_id, op, make_reply(old_op, db_row.run_count), db_row.owner_user_id)
	_, wrong_bridge := apply_task_stop_receipt(&h.service, "another_bridge", op, make_reply(op, db_row.run_count), db_row.owner_user_id)
	_, accepted := apply_task_stop_receipt(&h.service, db_row.bridge_id, op, fmt.tprintf("{\"ok\":true,\"command_id\":%q,\"payload\":{\"status\":\"accepted\"}}", op), db_row.owner_user_id)
	testing.expect(t, !stale && !unrelated && !wrong_bridge && !accepted)
	testing.expect_value(t, start_test_row(t, h).runtime_status, "running")

	start_test_sql(t, h, "UPDATE agent_instances SET current_task_id='new_task';")
	_, reassigned := apply_task_stop_receipt(&h.service, db_row.bridge_id, op, make_reply(op, db_row.run_count), db_row.owner_user_id)
	testing.expect(t, !reassigned, "a receipt cannot overwrite a new assignment")
	testing.expect_value(t, start_test_row(t, h).current_task_id, "new_task")
	start_test_sql(t, h, "UPDATE agent_instances SET current_task_id='';")
	stopped, applied := apply_task_stop_receipt(&h.service, db_row.bridge_id, op, make_reply(op, db_row.run_count), db_row.owner_user_id)
	testing.expect(t, applied)
	testing.expect_value(t, stopped.runtime_status, "stopped")
	testing.expect_value(t, stopped.status_message, "pty_stop_confirmed")
	testing.expect_value(t, stopped.stop_reason, "task_completed")
	_, duplicate := apply_task_stop_receipt(&h.service, db_row.bridge_id, op, make_reply(op, db_row.run_count), db_row.owner_user_id)
	testing.expect(t, !duplicate)
}

@(test)
test_scheduler_stop_receipt_cannot_stop_a_different_run_or_assignment :: proc(t: ^testing.T) {
	start_test_run(t, task_stop_receipt_scenario)
}

@(test)
test_start_keep_uses_process_fact_not_failed_projection :: proc(t: ^testing.T) {
	start_test_run(t, proc(t: ^testing.T, h: ^Start_Test) {
		h.service.fixture_start_fact = nil
		start_test_sql(t, h, "UPDATE agent_instances SET runtime_status='failed', startup_status='startup_failed';")
		ticket, waiting := start_begin(&h.service, start_test_auth(), "inst", {if_live = .Keep, ref = "lease"})
		defer start_ticket_destroy(&ticket)
		testing.expect_value(t, waiting.code, domain.Error_Code.Bridge_Busy)
		testing.expect_value(t, start_test_row(t, h).run_count, 3)

		// The verified live process wins even when the persisted UI cache is
		// wrong. No generation opens and no other launch is required.
		proof := Agent_Liveness{state = .Alive, reason = .pty_child_alive, pid = 42}
		kept, err := start_begin(&h.service, start_test_auth(), "inst", {if_live = .Keep, ref = "lease", process_fact = proof})
		defer start_ticket_destroy(&kept)
		testing.expect_value(t, err.code, domain.Error_Code.None)
		testing.expect(t, kept.kept_live && !kept.reserved)
		testing.expect_value(t, start_test_row(t, h).run_count, 3)
	})
}
