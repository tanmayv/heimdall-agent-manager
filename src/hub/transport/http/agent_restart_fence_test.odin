package http

import "core:strings"
import "core:testing"
import virtual "core:mem/virtual"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import agent_service "odin_test:hub/service/agent"
import auth_service "odin_test:hub/service/auth"
import user_service "odin_test:hub/service/user"

@(test)
test_restart_handler_preserves_rollover_generation_fence :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t,virtual.arena_init_growing(&arena)==nil) do return
	defer virtual.arena_destroy(&arena)
	context.allocator=virtual.arena_allocator(&arena)
	users_repo := iface.User_Repository{get_by_id=proc(_: rawptr,id: domain.User_ID) -> (domain.User,bool,domain.Domain_Error) {
		return {user_id=id,name=string(id),status=.Active},true,{}
	}}
	clock := platform.real_clock()
	ids := http_test_id_generator()
	users := user_service.new_user_service_basic(&users_repo,&clock,&ids)
	auth := auth_service.new_auth_service({},&users)
	defer auth_service.oidc_free(&auth)
	headers := http_test_login(t,&auth,"owner")
	repo := iface.Agent_Repository{get_instance=proc(_: rawptr,id: string) -> (domain.Agent_Instance,bool,domain.Domain_Error) {
		return domain.agent_instance_clone({agent_instance_id=id,owner_user_id="owner",runtime_status="running",run_count=4}),true,{}
	}}
	agents := agent_service.new_agent_service(&repo,nil,nil,nil)
	h := Agent_Handlers{auth=&auth,agents=&agents}
	// Admission must reject the stale generation before any provider lookup,
	// persistence, capacity reservation or runtime command can happen.
	response := restart_agent_instance_handler(&h,{method="POST",path="/api/v1/agent-instances/inst/restart",headers=headers,body=`{"expected_run_count":3}`,request_id="life6_restart"})
	defer delete(response.body)
	testing.expect_value(t,response.status,409)
	testing.expect(t,strings.contains(response.body,`"code":"start_raced"`),response.body)
}
