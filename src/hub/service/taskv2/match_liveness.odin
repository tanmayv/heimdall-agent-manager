package taskv2

import "base:runtime"
import "core:fmt"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import agent "odin_test:hub/service/agent"

Match_Probe :: struct {
	chain_id: domain.Task_Chain_ID,
	for_launch: bool,
}

// Only a scheduler-stopped legacy generation may use the launch-only check.
// An elapsed timer, a stop intent in flight, or a projected status alone is
// not enough. The Bridge still has to verify absence for this generation.
match_can_probe_for_launch :: proc(inst: domain.Agent_Instance) -> bool {
	return lease_stop_reason(inst.stop_reason) && inst.stopped_at != "" &&
	       inst.stopped_by == "" && inst.last_error_json == ""
}

// Matching runs under the database UoW. It can consult observed facts, but a
// Bridge round trip must run off both that UoW and the websocket reader.
match_process_fact :: proc(svc: ^Service, u: ^Uow, inst: domain.Agent_Instance, chain_id: domain.Task_Chain_ID, for_launch := false) -> agent.Agent_Liveness {
	if svc == nil do return agent.agent_liveness(nil, inst, cache_only = true)
	when ODIN_TEST {
		if svc.fixture_process_fact != nil do return svc.fixture_process_fact(inst)
	}
	for_launch := for_launch && match_can_probe_for_launch(inst)
	fact := agent.agent_liveness(svc.agent_service, inst, cache_only = true, for_launch = for_launch)
	if fact.reason == .not_observed && u != nil && bridge_online(svc, inst.bridge_id) {
		queue_match_probe(svc, inst.agent_instance_id, chain_id, for_launch)
	}
	return fact
}

queue_match_probe :: proc(svc: ^Service, id: string, chain_id: domain.Task_Chain_ID, for_launch := false) {
	if svc == nil || svc.agent_service == nil || id == "" || chain_id == "" do return
	held := state_lock(svc)
	defer state_unlock(svc, held)
	heap := runtime.heap_allocator()
	if svc.pending_match_probes == nil do svc.pending_match_probes = make(map[string]Match_Probe, heap)
	if pending, exists := &svc.pending_match_probes[id]; exists {
		pending.for_launch = pending.for_launch || for_launch
	} else {
		svc.pending_match_probes[strings.clone(id, heap)] = {
			domain.Task_Chain_ID(strings.clone(string(chain_id), heap)), for_launch,
		}
	}
}

// Stop receipts are already authoritative. Queue the same scoped rematch to
// unlock a fresh generation, without a second round trip.
on_match_process_stopped :: proc(svc: ^Service, inst: domain.Agent_Instance) {
	queue_match_probe(svc, inst.agent_instance_id, domain.Task_Chain_ID(inst.chain_id))
}

// Drain one demanded observation per turn to bound delay to the other timers.
// An inconclusive response never retries itself. A later scheduling event can
// ask again after the cache expires.
drain_match_probe :: proc(svc: ^Service) {
	id: string
	job: Match_Probe
	held := state_lock(svc)
	for key, pending in svc.pending_match_probes {
		id, job = key, pending
		delete_key(&svc.pending_match_probes, key)
		break
	}
	state_unlock(svc, held)
	if id == "" do return
	chain_id := job.chain_id
	defer {
		delete(id, runtime.heap_allocator())
		delete(string(chain_id), runtime.heap_allocator())
	}
	inst, found, _ := iface.agent_get_instance(svc.agents, id)
	if !found do return
	defer domain.agent_instance_destroy(&inst)
	for_launch := job.for_launch && match_can_probe_for_launch(inst)
	fact := agent.agent_liveness(svc.agent_service, inst, cache_only = true, for_launch = for_launch)
	if fact.reason == .not_observed do fact = agent.agent_liveness(svc.agent_service, inst, for_launch = for_launch)
	if fact.state == .Unknown {
		fmt.eprintfln("task_dispatch_wait component=hub chain=%q agent=%q instance=%q bridge=%q reason=process_verification evidence=%v",
			chain_id, inst.agent_id, id, inst.bridge_id, fact.reason)
		return
	}
	u, opened, _ := begin_uow(svc)
	if !opened do return
	chain, present, _ := iface.taskchain_get_chain(svc.repo, chain_id)
	if !present || chain.owner_user_id != inst.owner_user_id {
		_, _ = end_uow(svc, &u, false)
		return
	}
	if agent.apply_observed_alive_projection(svc.agent_service, inst, fact) do effect_instance_changed(&u, id)
	match_scope_note_instance(chain_id, id)
	match_scope_note_agent(chain_id, inst.agent_id)
	ok, _ := match_chain_scoped_in_uow(svc, &u, chain, .Process_Verified)
	_, _ = end_uow(svc, &u, ok)
}
