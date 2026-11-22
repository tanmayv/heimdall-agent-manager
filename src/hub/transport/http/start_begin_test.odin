package http

import "core:fmt"
import "core:mem"
import virtual "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import agent_service "odin_test:hub/service/agent"
import bridge_service "odin_test:hub/service/bridge"
import project_service "odin_test:hub/service/project"

start_http_run :: proc(t:^testing.T,scenario:proc(t:^testing.T,c:^Coordinator_Wake_Fixture)) {
	track:mem.Tracking_Allocator
	mem.tracking_allocator_init(&track,context.allocator);defer mem.tracking_allocator_destroy(&track)
	context.allocator=mem.tracking_allocator(&track)
	{
		arena:virtual.Arena
		assert(virtual.arena_init_growing(&arena)==nil)
		context.allocator=virtual.arena_allocator(&arena)
		c:=coordinator_wake_fixture(t)
		scenario(t,c)
		coordinator_wake_fixture_destroy(c)
		virtual.arena_destroy(&arena)
	}
	testing.expect_value(t,len(track.allocation_map),0)
}
start_route_scenario :: proc(t:^testing.T,c:^Coordinator_Wake_Fixture) {
	f:=c.f
	bs:=bridge_service.new_bridge_service(&f.br_repo,&f.clock,&f.ids)
	enrolled,ok,err:=bridge_service.enroll_bridge_from_device_grant(&bs,{owner_user_id=string(f.owner),bridge_public_key="test_start_key",bridge_key_fingerprint="start_fingerprint",machine_hostname="start_box"})
	if !testing.expect(t,ok,err.message) do return
	bid:=enrolled.bridge.bridge_id
	testing.expect(t,sqlite.exec(&f.conn,fmt.tprintf("UPDATE bridges SET status='online' WHERE bridge_id='%s'; UPDATE agent_instances SET bridge_id='%s' WHERE agent_instance_id='inst_wake';",bid,bid)))
	testing.expect(t,project_service.bridge_runtime_registry_mark_live(&c.registry,bid,false,""))
	_,pe:=iface.bridge_provider_status_upsert(&c.providers,{bridge_id=bid,provider="claude",state="present",binary_path="/bin/claude",checked_at="now"})
	testing.expect_value(t,pe.code,domain.Error_Code.None)
	h:=Bridge_Handlers{bridges=&bs,agents=&f.ag_svc}
	req:=Request{method="POST",path="/api/v1/bridge/agent-instances/inst_wake/start-begin",body=`{"ref":"route"}`}
	resp:=bridge_instance_start_begin_handler(&h,req)
	testing.expect_value(t,resp.status,401)
	req.headers={{name="Authorization",value=fmt.tprintf("Bearer %s",enrolled.bridge_token)}}
	req.query="token=not_allowed"
	testing.expect(t,bridge_instance_start_begin_handler(&h,req).status!=200)
	req.query=""

	req.body=`{}`
	resp=bridge_instance_start_begin_handler(&h,req)
	testing.expect_value(t,resp.status,400)
	req.body=`{"ref":"route"}`
	resp=bridge_instance_start_begin_handler(&h,req)
	testing.expectf(t,resp.status==200,"%d %s",resp.status,resp.body)
	testing.expect(t,strings.contains(resp.body,`"launch":{`))
	testing.expect(t,strings.contains(resp.body,`"command_id":"sb_route"`))
	testing.expect(t,strings.contains(resp.body,`"run_count":1`))
	req.body=`{"ref":"different"}`
	resp=bridge_instance_start_begin_handler(&h,req)
	testing.expect_value(t,resp.status,409)
	testing.expect(t,strings.contains(resp.body,`"code":"already_running"`))
	req.path="/api/v1/bridge/agent-instances/missing/start-begin"
	resp=bridge_instance_start_begin_handler(&h,req)
	testing.expect_value(t,resp.status,404)
	other,other_ok,other_err:=bridge_service.enroll_bridge_from_device_grant(&bs,{owner_user_id=string(f.owner),bridge_public_key="other_start_key",bridge_key_fingerprint="other_start_fingerprint",machine_hostname="other_start_box"})
	testing.expect(t,other_ok,other_err.message)
	req.path="/api/v1/bridge/agent-instances/inst_wake/start-begin"
	req.headers={{name="Authorization",value=fmt.tprintf("Bearer %s",other.bridge_token)}}
	testing.expect_value(t,bridge_instance_start_begin_handler(&h,req).status,404)
}
@(test)
test_start_begin_route :: proc(t:^testing.T) {start_http_run(t,start_route_scenario)}

@(test)
test_bridge_ready_carries_start_begin :: proc(t:^testing.T) {
	track:mem.Tracking_Allocator
	mem.tracking_allocator_init(&track,context.allocator);defer mem.tracking_allocator_destroy(&track)
	context.allocator=mem.tracking_allocator(&track)
	payload:=bridge_ready_payload("bridge",1,false)
	testing.expect(t,strings.contains(payload,`"start_begin":true`))
	delete(payload)
	testing.expect_value(t,len(track.allocation_map),0)
}

Start_Guard_Probe :: struct {guard:Coordinator_Start_Guard,saw_locked:bool}
start_guard_probe :: proc(ctx:rawptr)->domain.Domain_Error {
	p:=(^Start_Guard_Probe)(ctx)
	p.saw_locked=!sync.mutex_try_lock(&p.guard.agents.reconfiguration_mutex)
	if !p.saw_locked do sync.mutex_unlock(&p.guard.agents.reconfiguration_mutex)
	return coordinator_start_guard(&p.guard)
}
start_coordinator_guard_scenario :: proc(t:^testing.T,c:^Coordinator_Wake_Fixture) {
	f:=c.f
	auth:=contracts.Auth_Context{kind=.Session,user_id=string(f.owner)}
	first,found,_:=agent_service.get_instance(&f.ag_svc,auth,"inst_wake")
	testing.expect(t,found && first.stopped_by=="")
	// The stop lands after the wake's first policy check, before it acquires
	// reconfiguration_mutex. The guard must repeat the policy under that mutex.
	testing.expect(t,sqlite.exec(&f.conn,"UPDATE agent_instances SET stopped_by='user' WHERE agent_instance_id='inst_wake';"))
	probe:=Start_Guard_Probe{guard={agents=&f.ag_svc,auth=auth,instance_id="inst_wake"}}
	h:=Content_Handlers{agents=&f.ag_svc,content=&c.content}
	ok,err:=restart_stopped_conversation_instance(&h,auth,"chat_wake",&probe,start_guard_probe)
	testing.expect(t,!ok)
	testing.expect_value(t,err.code,domain.Error_Code.Conflict)
	testing.expect(t,probe.saw_locked && probe.guard.user_stopped)
	after,_,_:=agent_service.get_instance(&f.ag_svc,auth,"inst_wake")
	testing.expect_value(t,after.stopped_by,"user")
	testing.expect_value(t,after.run_count,first.run_count)
	testing.expect_value(t,len(c.commands),0)
}
@(test)
test_coordinator_wake_guard_under_mutex :: proc(t:^testing.T) {start_http_run(t,start_coordinator_guard_scenario)}

start_success_http_scenario :: proc(t:^testing.T,c:^Coordinator_Wake_Fixture) {
	f:=c.f
	launch,count,_,begun,err:=agent_service.start_begin_for_bridge(&f.ag_svc,f.owner,f.bridge_pin,"inst_wake","http_success")
	testing.expect(t,begun,err.message)
	testing.expect_value(t,count,1)
	testing.expect(t,strings.contains(launch,`"run_count":1`))
	// No bridge command result has been delivered. start-success authenticates
	// the generation already committed by the bridge-initiated opening.
	req:=Request{method="POST",path="/api/v1/agent-actions/start-success",body=`{"agent_instance_id":"inst_wake","params":{"run_count":1}}`,remote_addr="127.0.0.1:4444",headers={{name="Authorization",value=fmt.tprintf("Bearer %s",f.bridge_token)},{name="X-Heimdall-Instance-Token",value="hit_inst_wake"}}}
	resp:=agent_action_start_success_handler(&f.ah,req)
	testing.expectf(t,resp.status==200,"%d %s",resp.status,resp.body)
	row,ok,rerr:=iface.agent_get_instance(&f.ag_repo,"inst_wake")
	testing.expect(t,ok,rerr.message)
	testing.expect_value(t,row.runtime_status,"running")
	testing.expect_value(t,row.run_count,1)
}
@(test)
test_start_success_before_command_result :: proc(t:^testing.T) {start_http_run(t,start_success_http_scenario)}
@(test)
test_start_success_when_command_result_is_lost :: proc(t:^testing.T) {start_http_run(t,start_success_http_scenario)}
@(test)
test_start_begin_handler_auth :: proc(t:^testing.T) {start_http_run(t,start_route_scenario)}
