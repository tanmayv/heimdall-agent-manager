package taskchain

import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"
import platform "odin_test:hub/platform"
import project "odin_test:hub/service/project"

// Auto-promotion ports the ham-daemon task_recompute_promotions behavior into the
// lean Hub/Bridge split. It runs entirely against durable Hub state on the
// mutation path (no scheduler thread here): when a task's dependencies clear and
// its assignee slot is free, the task advances into the instance's current task
// and the existing runtime-command fan-out wakes the assignee's bridge.
//
// Current-task model (Phase 2, CT-4/CT-5/CT-7):
//   * Every agent instance has AT MOST ONE current task across both roles
//     (R1, R6, R7). An instance can be an assignee (work) on some tasks and a
//     reviewer (review) on others; we pick a single focus.
//   * Selection order per instance: REVIEW wins over WORK (R7); within a pool,
//     priority P0 > P1 > P2 (CT-3); ties break oldest created_at, then task_id.
//   * The chosen WORK task advances Assigned/Queued -> In_Progress and becomes
//     the instance current_task (role = work).
//   * The chosen REVIEW task (a task the instance reviews, sitting In_Validation)
//     becomes the instance current_task (role = review); its status is untouched.
//   * The instance's OTHER unblocked work tasks (Assigned/In_Progress that are not
//     the chosen focus) are demoted to Queued (R2/CT-2) so exactly one work item is
//     active. Blocked, paused, terminal, and validation tasks are left as-is.
//   * When an instance has no eligible focus, its current_task pointer is cleared
//     (CT-5 auto-advance / CT-7 consistency).

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

// instance_reviews_task reports whether instance_id is a designated reviewer of
// task (either via the task's own reviewer refs or the chain's default reviewer
// refs). An assignee of a task is never treated as its reviewer (an agent cannot
// review its own work), so an instance that is both assignee and reviewer is only
// eligible to WORK the task, not review it.
instance_reviews_task :: proc(task: domain.Task, chain: domain.Task_Chain, instance_id: string) -> bool {
	if instance_id == "" do return false
	if strings.contains(task.assignee_ref_json, instance_id) do return false
	if strings.contains(task.reviewer_refs_json, instance_id) do return true
	if strings.contains(chain.default_reviewer_refs_json, instance_id) do return true
	return false
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

// task_prefers is the deterministic ordering within a candidate pool: higher
// priority (lower ordinal) wins, then earliest created_at, then lexically
// smallest task_id. Priority is compared via explicit ordinals because the
// Task_Priority zero-value is P0 (most urgent); all real tasks carry an explicit
// priority (create_task defaults .P2, repo reads default p2).
task_prefers :: proc(a, b: domain.Task) -> bool {
	if a.priority != b.priority do return int(a.priority) < int(b.priority)
	if a.created_at != b.created_at do return a.created_at < b.created_at
	return string(a.task_id) < string(b.task_id)
}

// work_status_is_actionable reports whether a work (assignee) task status is one
// the assignee is expected to act on, making it a candidate for the instance's
// current work focus. Paused is deliberately held; validation/terminal statuses
// belong to the reviewer/coordinator, not the assignee's work queue.
work_status_is_actionable :: proc(status: domain.Task_Status) -> bool {
	return status == .Assigned || status == .Queued || status == .In_Progress || status == .Validated_Not_Good
}

// work_task_eligible reports whether task is a candidate for instance's current
// WORK focus: published, deps satisfied, and in an actionable work status.
work_task_eligible :: proc(tasks: []domain.Task, deps: []domain.Task_Dependency, task: domain.Task) -> bool {
	if task.publish_state != .Published do return false
	if !work_status_is_actionable(task.status) do return false
	if !deps_satisfied_for_task(tasks, deps, task.task_id) do return false
	return true
}

// promotion_eligible is retained for compatibility with callers/tests that ask
// whether a task can auto-claim into In_Progress right now (published, Assigned,
// deps satisfied). The richer selection lives in recompute_chain_promotions.
promotion_eligible :: proc(tasks: []domain.Task, deps: []domain.Task_Dependency, task: domain.Task) -> bool {
	if task.publish_state != .Published do return false
	if task.status != .Assigned do return false
	if !deps_satisfied_for_task(tasks, deps, task.task_id) do return false
	return true
}

// Instance_Focus is the resolved current-task decision for one instance.
Instance_Focus :: struct {
	task_id: domain.Task_ID,
	role:    domain.Current_Task_Role,
}

// recompute_chain_promotions scans one chain and reconciles every instance's
// single current task, promoting the chosen work task to In_Progress, demoting
// the instance's other unblocked work tasks to Queued, and persisting the
// current_task pointer (id + role) on each instance. It returns the number of
// tasks newly advanced into In_Progress. Callers must have already authorized the
// mutation that triggered the recompute; this operates with the chain's owner.
recompute_chain_promotions :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain) -> int {
	if service == nil || service.repo == nil do return 0
	if chain.status != .Active do return 0
	if chain.publish_state != .Published do return 0

	tasks, tasks_err := iface.taskchain_list_tasks_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if tasks_err.code != .None do return 0
	defer delete(tasks)
	deps, deps_err := iface.taskchain_list_dependencies_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if deps_err.code != .None do return 0
	defer delete(deps)

	// Collect the set of instances whose focus we must (re)compute: any assignee of
	// a task, plus any designated reviewer of a task (regardless of that task's
	// current status). Reviewers are collected even for tasks NOT in validation so
	// that a reviewer who just RESOLVED a task (moving it out of In_Validation)
	// gets re-evaluated and advances off it (CT-10 req 1); an instance with no
	// remaining eligible task simply has its pointer cleared.
	instance_ids := make([dynamic]string)
	defer { for id in instance_ids do delete(id); delete(instance_ids) }
	seen := make(map[string]bool)
	defer delete(seen)
	def_reviewers := extract_instances_from_ref_blob(chain.default_reviewer_refs_json)
	defer delete(def_reviewers)
	for t in tasks {
		a := primary_assignee_instance(t.assignee_ref_json)
		if a != "" && !seen[a] { seen[a] = true; append(&instance_ids, strings.clone(a)) }
		delete(a)
		reviewers := extract_instances_from_ref_blob(t.reviewer_refs_json)
		for id in reviewers do if instance_reviews_task(t, chain, id) && !seen[id] { seen[id] = true; append(&instance_ids, strings.clone(id)) }
		delete(reviewers)
		for id in def_reviewers do if instance_reviews_task(t, chain, id) && !seen[id] { seen[id] = true; append(&instance_ids, strings.clone(id)) }
	}

	// Resolve each instance's focus and collect the resulting task mutations. We
	// stage decisions first, then apply them so the tasks slice remains a stable
	// snapshot during selection.
	focus := make(map[string]Instance_Focus)
	defer delete(focus)
	// promote holds task_ids to advance into In_Progress; queue holds task_ids to
	// demote into Queued. A task_id never appears in both.
	promote := make(map[domain.Task_ID]bool)
	defer delete(promote)
	queue := make(map[domain.Task_ID]bool)
	defer delete(queue)

	for instance_id in instance_ids {
		// REVIEW pool: tasks in validation this instance reviews. Review wins over
		// work (R7), so if any review candidate exists it takes the focus.
		best_review: domain.Task
		have_review := false
		for t in tasks {
			if t.status != .In_Validation do continue
			if !instance_reviews_task(t, chain, instance_id) do continue
			if !have_review || task_prefers(t, best_review) { best_review = t; have_review = true }
		}

		// WORK pool: actionable, unblocked tasks assigned to this instance.
		best_work: domain.Task
		have_work := false
		for t in tasks {
			a := primary_assignee_instance(t.assignee_ref_json)
			is_mine := a == instance_id
			delete(a)
			if !is_mine do continue
			if !work_task_eligible(tasks[:], deps[:], t) do continue
			if !have_work || task_prefers(t, best_work) { best_work = t; have_work = true }
		}

		chosen_work_id := domain.Task_ID("")
		if have_review {
			focus[instance_id] = Instance_Focus{task_id = best_review.task_id, role = .Review}
		} else if have_work {
			focus[instance_id] = Instance_Focus{task_id = best_work.task_id, role = .Work}
			chosen_work_id = best_work.task_id
			// Advance the chosen work task into In_Progress when it is not already
			// there. Assigned/Queued are the normal not-started/held states; a
			// Validated_Not_Good task that the engine picks up is rework the agent
			// is now actively resuming, so it also advances to In_Progress (the
			// Validated_Not_Good -> In_Progress transition is legal). Only a task
			// already In_Progress needs no status change.
			if best_work.status == .Assigned || best_work.status == .Queued || best_work.status == .Validated_Not_Good {
				promote[best_work.task_id] = true
			}
		} else {
			focus[instance_id] = Instance_Focus{task_id = "", role = .None}
		}

		// Demote this instance's OTHER unblocked work tasks to Queued so exactly
		// one work item is active. When the focus is a review task, all of the
		// instance's actionable work tasks are demoted.
		for t in tasks {
			if t.task_id == chosen_work_id do continue
			a := primary_assignee_instance(t.assignee_ref_json)
			is_mine := a == instance_id
			delete(a)
			if !is_mine do continue
			if !work_task_eligible(tasks[:], deps[:], t) do continue
			// Leave Validated_Not_Good alone: it carries reviewer feedback the
			// assignee must act on; queuing it would erase that state.
			if t.status == .Assigned || t.status == .In_Progress { queue[t.task_id] = true }
		}
	}

	// Apply task status mutations first (promotions win over demotions for the same
	// id; they never collide, but be defensive). We stage promoted tasks and defer
	// their notifications until AFTER the instance current_task pointers are
	// persisted, because notification gating (CT-6) reads each recipient's
	// persisted current_task_id — the pointer must be up to date before we notify.
	promoted := 0
	now := platform.clock_now(service.clock)
	promoted_tasks := make([dynamic]domain.Task)
	defer delete(promoted_tasks)
	for t in tasks {
		if promote[t.task_id] {
			nt := t
			nt.status = .In_Progress
			if nt.started_at == "" do nt.started_at = now
			nt.updated_at = now
			saved, ok, _ := iface.taskchain_save_task(service.repo, nt)
			if ok {
				promoted += 1
				append(&promoted_tasks, saved)
			}
		} else if queue[t.task_id] {
			nt := t
			nt.status = .Queued
			nt.updated_at = now
			_, _, _ = iface.taskchain_save_task(service.repo, nt)
		}
	}

	// Persist each instance's current-task pointer BEFORE notifying, so the gate
	// sees the freshly-promoted focus. Skipped when no agent repo is configured
	// (some unit tests run the promotion engine repo-less).
	apply_instance_focus(service, focus)

	// Now fan out promotion notifications. System-initiated promotion: empty auth
	// actor so the runtime fan-out targets the assignee (no actor is excluded).
	for saved in promoted_tasks {
		notify_task_status_change(service, contracts.Auth_Context{}, saved, chain)
	}

	return promoted
}

// apply_instance_focus persists the resolved current_task pointer (id + role) on
// each instance, writing only when the value actually changes so we do not churn
// updated_at on every recompute. No-op when the agent repository is unavailable.
apply_instance_focus :: proc(service: ^Taskchain_Service, focus: map[string]Instance_Focus) {
	if service == nil || service.agents == nil do return
	for instance_id, f in focus {
		inst, ok, _ := iface.agent_get_instance(service.agents, instance_id)
		if !ok do continue
		if inst.current_task_id == string(f.task_id) && inst.current_task_role == f.role do continue
		inst.current_task_id = string(f.task_id)
		inst.current_task_role = f.role
		inst.updated_at = platform.clock_now(service.clock)
		_, _, _ = iface.agent_save_instance(service.agents, inst)
	}
}

// clear_instance_current_task clears the persisted current_task pointer for a
// single instance (CT-7 consistency): used when an instance stops/goes
// unreachable so a stale focus is not shown. No-op when already clear.
clear_instance_current_task :: proc(service: ^Taskchain_Service, instance_id: string) {
	if service == nil || service.agents == nil || instance_id == "" do return
	inst, ok, _ := iface.agent_get_instance(service.agents, instance_id)
	if !ok do return
	if inst.current_task_id == "" && inst.current_task_role == .None do return
	inst.current_task_id = ""
	inst.current_task_role = .None
	inst.updated_at = platform.clock_now(service.clock)
	_, _, _ = iface.agent_save_instance(service.agents, inst)
}

// recompute_promotions_for_chain_id loads the chain by id then recomputes.
recompute_promotions_for_chain_id :: proc(service: ^Taskchain_Service, chain_id: domain.Task_Chain_ID) -> int {
	chain, ok, _ := iface.taskchain_get_chain(service.repo, chain_id)
	if !ok do return 0
	return recompute_chain_promotions(service, chain)
}

// resolve_current_task_role determines which role an instance would take on a
// task, validating that the pairing is legal and the task is actionable for that
// role. Returns ok=false with a descriptive error otherwise. Rules:
//   * WORK role: instance is the task's primary assignee and the task is in an
//     actionable work status (Assigned/Queued/In_Progress/Validated_Not_Good) with
//     satisfied dependencies.
//   * REVIEW role: instance is a designated reviewer (task or chain default, and
//     not the assignee) and the task is In_Validation.
// Work is preferred over review when an instance is both (it cannot review its own
// task anyway, so the two never collide on the same task).
resolve_current_task_role :: proc(tasks: []domain.Task, deps: []domain.Task_Dependency, chain: domain.Task_Chain, task: domain.Task, instance_id: string) -> (domain.Current_Task_Role, bool, domain.Domain_Error) {
	if task.publish_state != .Published do return .None, false, domain.domain_error(.Conflict, "cannot focus a draft task")
	assignee := primary_assignee_instance(task.assignee_ref_json)
	is_assignee := assignee == instance_id
	delete(assignee)
	if is_assignee {
		if !work_status_is_actionable(task.status) do return .None, false, domain.domain_error(.Conflict, "task is not in an actionable work status for its assignee")
		if !deps_satisfied_for_task(tasks, deps, task.task_id) do return .None, false, domain.domain_error(.Conflict, "task is blocked by unsatisfied dependencies")
		return .Work, true, domain.Domain_Error{}
	}
	if instance_reviews_task(task, chain, instance_id) {
		if task.status != .In_Validation do return .None, false, domain.domain_error(.Conflict, "review task is not awaiting validation")
		return .Review, true, domain.Domain_Error{}
	}
	return .None, false, domain.domain_error(.Forbidden, "instance is neither the assignee nor a reviewer of this task")
}

// set_instance_current_task manually pins an agent instance's current task to a
// specific task on behalf of a coordinator/user (CT-9 manual override). It
// validates ownership + chain scope, that the instance is the task's assignee or
// reviewer, and that the task is actionable for the resolved role; persists the
// pointer (id + role); and notifies the target agent that its current task
// changed with the correct work-vs-review action label (R8). Coordinator is NOT
// exempt from any rule (R5): the same validation applies regardless of caller.
set_instance_current_task :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, instance_id: string, task_id: domain.Task_ID) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	if service == nil || service.repo == nil do return domain.Agent_Instance{}, false, domain.domain_error(.Internal_Error, "taskchain service is not configured")
	if service.agents == nil do return domain.Agent_Instance{}, false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	if strings.trim_space(instance_id) == "" do return domain.Agent_Instance{}, false, domain.domain_error(.Validation_Failed, "instance id is required")

	task, task_ok, task_err := iface.taskchain_get_task(service.repo, task_id)
	if !task_ok do return domain.Agent_Instance{}, false, task_err
	// Ownership: the caller must own the task (mirrors get_task authorization).
	if owner_ok, owner_err := ownership.require_owner(auth, task.owner_user_id); !owner_ok do return domain.Agent_Instance{}, false, owner_err

	chain, chain_ok, chain_err := iface.taskchain_get_chain(service.repo, task.chain_id)
	if !chain_ok do return domain.Agent_Instance{}, false, chain_err
	// Instance-token callers may set their OWN current task (self-service focus
	// switch), but must be the chain coordinator to drive ANOTHER agent's focus.
	// (A user/proxy token is already owner-scoped above.)
	if auth.kind == .Instance_Token {
		is_self := auth.agent_instance_id == instance_id
		if !is_self && !is_chain_coordinator(service, chain, auth.agent_instance_id) {
			return domain.Agent_Instance{}, false, domain.domain_error(.Forbidden, "only the chain coordinator can set another agent's current task")
		}
	}

	inst, inst_ok, inst_err := iface.agent_get_instance(service.agents, instance_id)
	if !inst_ok do return domain.Agent_Instance{}, false, inst_err
	if inst.owner_user_id != task.owner_user_id do return domain.Agent_Instance{}, false, domain.domain_error(.Conflict, "instance and task belong to different owners")

	tasks, tasks_err := iface.taskchain_list_tasks_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if tasks_err.code != .None do return domain.Agent_Instance{}, false, tasks_err
	defer delete(tasks)
	deps, deps_err := iface.taskchain_list_dependencies_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if deps_err.code != .None do return domain.Agent_Instance{}, false, deps_err
	defer delete(deps)

	role, role_ok, role_err := resolve_current_task_role(tasks[:], deps[:], chain, task, instance_id)
	if !role_ok do return domain.Agent_Instance{}, false, role_err

	changed := inst.current_task_id != string(task.task_id) || inst.current_task_role != role
	inst.current_task_id = string(task.task_id)
	inst.current_task_role = role
	inst.updated_at = platform.clock_now(service.clock)
	saved, save_ok, save_err := iface.agent_save_instance(service.agents, inst)
	if !save_ok do return domain.Agent_Instance{}, false, save_err

	// Notify the target agent that its current task changed (R8: explicit
	// work-vs-review action label). Only fire on an actual change.
	if changed do notify_current_task_changed(service, saved, task, role)
	return saved, true, domain.Domain_Error{}
}

// notify_current_task_changed wakes the target instance's bridge to tell it its
// current task changed, stating whether the action is WORK (assignee) or REVIEW
// (reviewer) per R8. Fire-and-forget: a delivery failure does not fail the set.
notify_current_task_changed :: proc(service: ^Taskchain_Service, inst: domain.Agent_Instance, task: domain.Task, role: domain.Current_Task_Role) {
	if service.bridge_command_sink.send_runtime_command == nil do return
	if inst.bridge_id == "" do return
	if should_debounce_nudge_dispatch(service, inst.agent_instance_id, string(task.task_id)) do return
	action := "work"
	if role == .Review do action = "review"
	now := platform.clock_now(service.clock)
	cmd_id := platform.generate_id(service.ids, "cmd_")
	// R8: prefer the human-readable title (fall back to id) and state the action.
	name := task_display_name(task)
	verb := "WORK ON" if action == "work" else "REVIEW"
	message := strings.concatenate({"Your current task changed — ", verb, ": ", name})
	defer delete(message)
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `{"type":"notify_task_nudge","origin":"current_task_changed","command_id":"`)
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, `","agent_instance_id":"`)
	contracts.write_json_string(&b, inst.agent_instance_id)
	strings.write_string(&b, `","task_id":"`)
	contracts.write_json_string(&b, string(task.task_id))
	strings.write_string(&b, `","chain_id":"`)
	contracts.write_json_string(&b, string(task.chain_id))
	strings.write_string(&b, `","target_instance_id":"`)
	contracts.write_json_string(&b, inst.agent_instance_id)
	strings.write_string(&b, `","target_role":"`)
	contracts.write_json_string(&b, action)
	strings.write_string(&b, `","action":"`)
	contracts.write_json_string(&b, action)
	strings.write_string(&b, `","task_status":"`)
	contracts.write_json_string(&b, task_status_string(task.status))
	strings.write_string(&b, `","message":"`)
	contracts.write_json_string(&b, message)
	strings.write_string(&b, `","created_at":"`)
	contracts.write_json_string(&b, now)
	strings.write_string(&b, `"}`)
	_, _ = project.bridge_command_send_runtime(service.bridge_command_sink, project.Runtime_Command{bridge_id = inst.bridge_id, command_id = cmd_id, body_json = strings.to_string(b)})
}
