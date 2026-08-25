package taskchain

import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// Auto-promotion ports the ham-daemon task_recompute_promotions behavior into the
// lean Hub/Bridge split. It runs entirely against durable Hub state on the
// mutation path (no scheduler thread here): when a task's dependencies clear and
// its assignee slot is free, the task advances Assigned -> In_Progress and the
// existing runtime-command fan-out wakes the assignee's bridge.
//
// Serialization rule (mirrors task_best_ready_task_for_assignee): at most one
// In_Progress task per assignee instance. Among eligible Assigned tasks for the
// same assignee we promote a single deterministic pick (created_at, then
// task_id).

// task_is_terminal reports whether a task status is a chain-dependency-clearing
// terminal state.
task_is_terminal :: proc(status: domain.Task_Status) -> bool {
	return status == .Completed || status == .Cancelled
}

// primary_assignee_instance returns the first agent_instance_id in a task's
// assignee ref blob, or "" if the assignee is a user / unresolved.
primary_assignee_instance :: proc(assignee_ref_json: string) -> string {
	instances := extract_instances_from_ref_blob(assignee_ref_json)
	defer delete(instances)
	if len(instances) == 0 do return ""
	return strings.clone(instances[0])
}

// deps_satisfied_for_task reports whether every dependency parent of task_id has
// reached a terminal (dependent-unblocking) status. Missing parents are treated
// as satisfied (they cannot block), matching the daemon's permissive behavior.
deps_satisfied_for_task :: proc(tasks: []domain.Task, deps: []domain.Task_Dependency, task_id: domain.Task_ID) -> bool {
	for dep in deps {
		if dep.task_id != task_id do continue
		found := false
		for parent in tasks {
			if parent.task_id != dep.depends_on_task_id do continue
			found = true
			if !domain.task_status_unblocks_dependents(parent.status) do return false
			break
		}
		_ = found
	}
	return true
}

// task_orders_before is the deterministic tie-break for assignee-slot selection:
// earliest created_at wins, then lexically smallest task_id.
task_orders_before :: proc(a, b: domain.Task) -> bool {
	if a.created_at != b.created_at do return a.created_at < b.created_at
	return string(a.task_id) < string(b.task_id)
}

// promotion_eligible reports whether a task is a candidate to auto-claim into
// In_Progress: published, currently Assigned, deps satisfied.
promotion_eligible :: proc(tasks: []domain.Task, deps: []domain.Task_Dependency, task: domain.Task) -> bool {
	if task.publish_state != .Published do return false
	if task.status != .Assigned do return false
	if !deps_satisfied_for_task(tasks, deps, task.task_id) do return false
	return true
}

// recompute_chain_promotions scans one chain and auto-claims eligible tasks to
// In_Progress, enforcing one active task per assignee instance. It returns the
// number of tasks promoted. Callers must have already authorized the mutation
// that triggered the recompute; this operates with the chain's owner directly.
recompute_chain_promotions :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain) -> int {
	if service == nil || service.repo == nil do return 0
	if chain.status != .Active do return 0
	if chain.publish_state != .Published do return 0

	tasks, tasks_err := iface.taskchain_list_tasks_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if tasks_err.code != .None do return 0
	deps, deps_err := iface.taskchain_list_dependencies_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if deps_err.code != .None do return 0

	// Assignee instances that already hold an In_Progress task are busy.
	busy := make(map[string]bool)
	defer delete(busy)
	for t in tasks {
		if t.status != .In_Progress do continue
		a := primary_assignee_instance(t.assignee_ref_json)
		if a == "" { continue }
		busy[a] = true
		delete(a)
	}

	promoted := 0
	// For each free assignee, pick the single best eligible task and promote it.
	// We iterate assignees deterministically by resolving best-per-assignee.
	handled := make(map[string]bool)
	defer delete(handled)
	for anchor in tasks {
		if !promotion_eligible(tasks[:], deps[:], anchor) do continue
		assignee := primary_assignee_instance(anchor.assignee_ref_json)
		if assignee == "" do continue
		defer delete(assignee)
		if handled[assignee] do continue
		if busy[assignee] { handled[assignee] = true; continue }

		// Find the deterministic best eligible task for this assignee.
		best: domain.Task
		found := false
		for cand in tasks {
			if !promotion_eligible(tasks[:], deps[:], cand) do continue
			ca := primary_assignee_instance(cand.assignee_ref_json)
			if ca != assignee { delete(ca); continue }
			delete(ca)
			if !found || task_orders_before(cand, best) {
				best = cand
				found = true
			}
		}
		handled[assignee] = true
		if !found do continue

		now := platform.clock_now(service.clock)
		best.status = .In_Progress
		if best.started_at == "" do best.started_at = now
		best.updated_at = now
		saved, ok, _ := iface.taskchain_save_task(service.repo, best)
		if ok {
			promoted += 1
			busy[assignee] = true
			// System-initiated promotion: empty auth actor so the runtime
			// fan-out targets the assignee (no actor is excluded).
			notify_task_status_change(service, contracts.Auth_Context{}, saved, chain)
		}
	}
	return promoted
}

// recompute_promotions_for_chain_id loads the chain by id then recomputes.
recompute_promotions_for_chain_id :: proc(service: ^Taskchain_Service, chain_id: domain.Task_Chain_ID) -> int {
	chain, ok, _ := iface.taskchain_get_chain(service.repo, chain_id)
	if !ok do return 0
	return recompute_chain_promotions(service, chain)
}
