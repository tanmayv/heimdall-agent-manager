package app

import "core:encoding/json"
import domain "odin_test:hub/domain"
import events "odin_test:hub/service/events"
import agent "odin_test:hub/service/agent"
import taskv2 "odin_test:hub/service/taskv2"

task_engine_launch_context :: proc(ctx: rawptr, inst: domain.Agent_Instance) -> (agent.Start_Lease, bool, domain.Domain_Error) {
	return taskv2.reconfiguration_launch_context((^taskv2.Service)(ctx),inst)
}

fleet_on_changed :: proc(ctx: rawptr, owner: domain.User_ID, application: domain.Fleet_Application, settings_changed: bool) {
	g := (^App_Graph)(ctx)
	if settings_changed {
		data, _ := json.marshal(struct {bridge_id:string,revision:i64}{application.bridge_id,application.settings_revision},allocator=context.temp_allocator)
		events.publish_resource_changed(&g.event_bus,string(owner),"bridge_fleet_settings",application.bridge_id,"saved",string(data))
	}
	data, _ := json.marshal(application,allocator=context.temp_allocator)
	events.publish_resource_changed(&g.event_bus,string(owner),"bridge_fleet_application",application.application_id,application.state,string(data))
}
