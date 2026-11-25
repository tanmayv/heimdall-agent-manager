package taskchain

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Only explicit task orchestration calls this. A generic conversation's chain
// binding or coordinator membership does not opt it into shared Fleet settings.
promote_task_instance :: proc(service: ^Taskchain_Service, owner: domain.User_ID, instance_id: string) -> domain.Domain_Error {
	if service.agent_service == nil do return {}
	inst, found, err := iface.agent_get_instance(service.agents, instance_id)
	if err.code != .None do return err
	if !found || inst.owner_user_id != owner do return domain.domain_error(.Not_Found, "instance not found")
	defer domain.agent_instance_destroy(&inst)
	scope, se := iface.fleet_scope_classify(service.agent_service.bridges, inst)
	if se.code != .None do return se
	if scope == .Excluded do return {}
	return iface.fleet_scope_set(service.agent_service.bridges, inst, "chain")
}
