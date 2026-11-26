package taskv2

import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import agent "odin_test:hub/service/agent"

// Only the matching durable Fleet operation retains a claim. Ordinary deaths,
// user stops and unrelated/stale operation generations keep their old cleanup.
fleet_runtime_operation :: proc(svc: ^Service, inst: domain.Agent_Instance) -> (blocking: bool, ready_ref: string) {
	if inst.stopped_by=="user" || svc.agents==nil || svc.agents.reconfiguration_list==nil do return
	rows, err:=iface.instance_reconfiguration_list(svc.agents,string(inst.owner_user_id),inst.agent_instance_id,false)
	if err.code!=.None do return
	defer {for &op in rows do domain.instance_reconfiguration_destroy(&op);delete(rows)}
	for op in rows {
		if !strings.has_prefix(op.idempotency_key,"fleet_target_") do continue
		record, owned, re := iface.fleet_application_by_operation(svc.bridges, inst.owner_user_id, inst.agent_instance_id, op.idempotency_key)
		if !owned || re.code != .None do continue
		claim_matches := false
		lease, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, inst.agent_instance_id)
		for target in record.application.targets do if target.operation_key == op.idempotency_key {
			claim_matches = (held && lease.lease_id == target.lease_id) || (!held && target.lease_id == "")
		}
		domain.fleet_application_record_destroy(&record)
		if !claim_matches do continue
		source:=!op.destination_committed && inst.configuration_revision==op.expected_revision && inst.launch_epoch==op.source_launch_epoch && inst.run_count==op.source_run_count && inst.bridge_id==op.source.bridge_id
		destination:=op.destination_committed && inst.configuration_revision==op.expected_revision+1 && inst.launch_epoch==op.launch_epoch && inst.bridge_id==op.destination.bridge_id
		if !source && !destination do continue
		if domain.instance_reconfiguration_blocks_input(op) do return true,""
		if op.phase==.Ready && destination do return false,strings.clone(op.operation_id,context.temp_allocator)
	}
	return
}

// Called through the existing native lifecycle hook after destination commit.
// It preserves claim identity and refreshes only the actual runtime projection.
reconfiguration_launch_context :: proc(svc: ^Service, inst: domain.Agent_Instance) -> (agent.Start_Lease, bool, domain.Domain_Error) {
	allocator:=context.allocator
	scratch: Scratch
	context.allocator=scratch_begin(&scratch)
	defer scratch_end(&scratch)
	u, begun, err:=begin_uow(svc)
	if !begun do return {},false,err
	l,held,le:=iface.taskchain_get_lease_by_holder(svc.repo,inst.agent_instance_id)
	if !held {_,_=end_uow(svc,&u,false);return {},false,le if le.code!=.Not_Found else domain.Domain_Error{}}
	task,found,te:=iface.taskchain_get_task(svc.repo,l.task_id)
	chain,cok,ce:=iface.taskchain_get_chain(svc.repo,l.chain_id)
	if !found || !cok || l.owner_user_id!=inst.owner_user_id {_,_=end_uow(svc,&u,false);return {},false,te if te.code!=.None else ce}
	l.provider=inst.provider;l.provider_profile=inst.provider_profile;l.model=inst.model;l.bridge_id=inst.bridge_id
	_,saved,se:=iface.taskchain_save_lease(svc.repo,l)
	if !saved {_,_=end_uow(svc,&u,false);return {},false,se}
	if l.phase==domain.LEASE_PHASE_ACTIVE do set_instance_pointer(svc,&u,inst.agent_instance_id,string(l.task_id),.Review if l.kind==domain.LEASE_KIND_REVIEW else .Work)
	pack:=build_pack_json(svc,chain,task,l,inst)
	_,cerr:=end_uow(svc,&u,true)
	if cerr.code!=.None do return {},false,cerr
	return {task_id=strings.clone(string(l.task_id),allocator),role=strings.clone("reviewer" if l.kind==domain.LEASE_KIND_REVIEW else "worker",allocator),lease_id=strings.clone(l.lease_id,allocator),pack_json=strings.clone(pack,allocator),permission_mode=strings.clone(domain.agent_instance_effective_permission_mode(inst),allocator)},true,{}
}
