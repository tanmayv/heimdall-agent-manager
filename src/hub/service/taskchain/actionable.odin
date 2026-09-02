package taskchain

import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Minimum gap between orphan-recovery replays for the same bridge. A flapping
// bridge that reconnects rapidly will only trigger one full replay per window;
// the bridge-side nudge cooldown and wake coalescing absorb the rest.
REPLAY_MIN_INTERVAL_MS :: i64(10_000)

// Actionable-tasks read model. The Bridge scheduler polls this once per tick to
// learn which of *its* local instances have work to advance or nudge, without
// pulling the whole task graph. The Hub computes dependency-satisfaction here
// (it owns the global graph, so cross-bridge parents are handled transparently)
// and returns a compact projection.

Actionable_Task :: struct {
	task_id:             domain.Task_ID,
	chain_id:            domain.Task_Chain_ID,
	status:              domain.Task_Status,
	target_instance_id: string,
	target_role:        Nudge_Target,
	// action is the R8 work-vs-review label for the target ("work"|"review").
	action:             string,
	updated_at:         string,
	deps_satisfied:     bool,
}

// actionable_tasks_for_instances computes the actionable set for a specific set
// of agent instance ids (the instances a bridge hosts). It scans the owner's
// active chains once and emits one row per (task, local-target) pairing.
//
// A task is included when:
//   - its chain is Published + Active,
//   - the task is Published and non-terminal,
//   - the task's current nudge target resolves to one of `instance_ids`.
actionable_tasks_for_instances :: proc(service: ^Taskchain_Service, owner: domain.User_ID, instance_ids: []string) -> ([]Actionable_Task, domain.Domain_Error) {
	if service == nil || service.repo == nil do return nil, domain.domain_error(.Internal_Error, "taskchain repository is not configured")
	if len(instance_ids) == 0 do return nil, domain.Domain_Error{}

	local := make(map[string]bool)
	defer delete(local)
	for id in instance_ids {
		trimmed := strings.trim_space(id)
		if trimmed != "" do local[trimmed] = true
	}

	chains, chains_err := iface.taskchain_list_chains_by_owner(service.repo, owner)
	if chains_err.code != .None do return nil, chains_err

	out := make([dynamic]Actionable_Task)
	for chain in chains {
		if chain.publish_state != .Published do continue
		if chain.status != .Active do continue

		tasks, tasks_err := iface.taskchain_list_tasks_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
		if tasks_err.code != .None do continue
		deps, deps_err := iface.taskchain_list_dependencies_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
		if deps_err.code != .None do continue

		for task in tasks {
			if task.publish_state != .Published do continue
			if task_is_terminal(task.status) do continue

			role := nudge_target_for_status(task.status)
			if role == .None do continue
			target := resolve_target_instance(service, chain, task, role)
			if target == "" do continue
			if !local[target] do continue

			// CT-6/CT-8: gate the nudge on the target's PERSISTED current task. The
			// nudger only fires for the recipient's current task (fail-open when the
			// pointer is unset so we don't drop legitimate ready/stale nudges), and
			// the row carries the R8 work-vs-review action so the bridge nudge is
			// unambiguous.
			allowed, action := notification_allowed_for_recipient(service, target, task)
			if !allowed { delete(target); continue }

			append(&out, Actionable_Task{
				task_id            = task.task_id,
				chain_id           = task.chain_id,
				status             = task.status,
				target_instance_id = target,
				target_role        = role,
				action             = action,
				updated_at         = task.updated_at,
				deps_satisfied     = deps_satisfied_for_task(tasks, deps, task.task_id),
			})
		}
	}
	return out[:], domain.Domain_Error{}
}

// resolve_target_instance maps a nudge role to the concrete instance id that
// should act on the task: assignee ref, first reviewer ref (falling back to the
// chain default reviewer), or the chain coordinator.
resolve_target_instance :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, task: domain.Task, role: Nudge_Target) -> string {
	switch role {
	case .Assignee:
		return primary_assignee_instance(task.assignee_ref_json)
	case .Reviewer:
		reviewers := extract_instances_from_ref_blob(task.reviewer_refs_json)
		defer delete(reviewers)
		if len(reviewers) > 0 do return strings.clone(reviewers[0])
		def := extract_instances_from_ref_blob(chain.default_reviewer_refs_json)
		defer delete(def)
		if len(def) > 0 do return strings.clone(def[0])
		return ""
	case .Coordinator:
		return chain.coordinator_agent_instance_id
	case .None:
		return ""
	}
	return ""
}

// actionable_tasks_for_bridge resolves the bridge's hosted instances (via the
// agent repository) and returns their actionable set.
actionable_tasks_for_bridge :: proc(service: ^Taskchain_Service, owner: domain.User_ID, bridge_id: string) -> ([]Actionable_Task, domain.Domain_Error) {
	if service == nil || service.agents == nil do return nil, domain.domain_error(.Internal_Error, "agent repository is not configured")
	instances, err := iface.agent_list_instances_by_bridge(service.agents, bridge_id)
	if err.code != .None do return nil, err
	ids := make([dynamic]string)
	defer delete(ids)
	for inst in instances {
		if inst.owner_user_id != owner do continue
		append(&ids, inst.agent_instance_id)
	}
	return actionable_tasks_for_instances(service, owner, ids[:])
}

// replay_bridge_actionable_notifications re-fires task_status_changed_notify for
// every actionable task targeting an instance hosted on `bridge_id`. This is the
// orphan-recovery path: when a cross-bridge cascade (or any status change) fans
// out to a bridge that is offline at the time, the fire-and-forget notify is
// dropped. On the bridge's next reconnect the Hub replays the current actionable
// state so the (now-online) bridge wakes/nudges its agents. It is idempotent:
// re-sending a notify for an already-live agent is a harmless wrapper push.
//
// Returns the number of notifications sent. Iterates over ALL owners' bridges
// with this bridge_id is not needed — a bridge belongs to exactly one owner — so
// the caller supplies the owner resolved from the bridge's auth/record.
replay_bridge_actionable_notifications :: proc(service: ^Taskchain_Service, owner: domain.User_ID, bridge_id: string) -> int {
	return replay_bridge_actionable_notifications_at(service, owner, bridge_id, time.to_unix_nanoseconds(time.now()) / 1_000_000)
}

// replay_should_run applies the per-bridge throttle: returns true (and records
// now) when at least REPLAY_MIN_INTERVAL_MS has elapsed since the last replay for
// this bridge, false otherwise. now_ms is injected for testability.
replay_should_run :: proc(service: ^Taskchain_Service, bridge_id: string, now_ms: i64) -> bool {
	if service == nil do return false
	sync.mutex_lock(&service.replay_mutex)
	defer sync.mutex_unlock(&service.replay_mutex)
	if service.replay_last_unix_ms == nil do service.replay_last_unix_ms = make(map[string]i64)
	last, has := service.replay_last_unix_ms[bridge_id]
	if has && now_ms - last < REPLAY_MIN_INTERVAL_MS do return false
	service.replay_last_unix_ms[bridge_id] = now_ms
	return true
}

// replay_bridge_actionable_notifications_at is the now-injectable form used by
// tests; the public wrapper passes the real wall clock.
replay_bridge_actionable_notifications_at :: proc(service: ^Taskchain_Service, owner: domain.User_ID, bridge_id: string, now_ms: i64) -> int {
	if service == nil || service.repo == nil do return 0
	if service.bridge_command_sink.send_runtime_command == nil do return 0
	if !replay_should_run(service, bridge_id, now_ms) do return 0
	items, err := actionable_tasks_for_bridge(service, owner, bridge_id)
	if err.code != .None do return 0
	sent := 0
	for item in items {
		// Only replay tasks that are actually ready to act on. deps-unsatisfied
		// tasks will be re-notified when their parent completes (a fresh cascade).
		if !item.deps_satisfied do continue
		task, ok, _ := iface.taskchain_get_task(service.repo, item.task_id)
		if !ok do continue
		chain, chain_ok, _ := iface.taskchain_get_chain(service.repo, task.chain_id)
		if !chain_ok do continue
		// System-initiated replay: empty auth actor so the target isn't excluded.
		notify_task_status_change(service, contracts.Auth_Context{}, task, chain)
		sent += 1
	}
	return sent
}
