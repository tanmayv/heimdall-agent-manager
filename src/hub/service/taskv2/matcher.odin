package taskv2

import "core:fmt"
import "core:slice"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import agent "odin_test:hub/service/agent"
import jsonx "odin_test:lib/jsonx"
import fleet_settings "odin_test:hub/service/fleet_settings"

// match_chain_in_uow is the matcher for one chain (plan §2.4/§2.5): a pure
// function of (tasks, leases, fleets, instances, bridges) that grants leases.
// It is invoked ONLY from the trigger table (after_chain_change, timers,
// on_instance_terminal, bridge hello, start-success, boot) and always inside
// the caller's unit of work. There is no manual run.
//
// Order: review pass first (an in_review task is closer to done than a ready
// one), then the work pass by priority P0 > P1 > P2, oldest ready_since first.
// Every grant check lives in grant_in_uow; a failed grant is a skip, never an
// error for the chain (the DB uniques are the backstop under any race).
match_chain_in_uow :: proc(svc: ^Service, u: ^Uow, chain: domain.Task_Chain, trigger: Trigger) -> (bool, domain.Domain_Error) {
	if chain.publish_state != .Published || chain.status != .Active do return reconcile_placement_in_uow(svc, u, chain)
	metric_matcher_run(trigger)
	ctx, ok, err := load_match_context(svc, chain)
	if !ok do return false, err
	defer destroy_match_context(&ctx)

	// Review pass.
	for task in ctx.sorted {
		if task.state != .In_Review || task.kind == .Gate do continue
		grant_reviews(svc, u, &ctx, task, trigger)
	}
	// Work passes: rework (a task worked before) ahead of new work
	// (REQ-SCHED-35), each by priority then age.
	stage_caps := make(map[string]map[string]int, context.temp_allocator)
	for rework in ([]bool{true, false}) {
		for task in ctx.sorted {
			if task.state != .Ready || task.kind == .Gate do continue
			if (task.attempt_no > 0) != rework do continue
			if task_has_live_lease(&ctx, task.task_id, domain.LEASE_KIND_WORK) do continue
			if task.stage_key != "" {
				if cap := workflow_task_max_parallel_cached(svc, &stage_caps, task); cap > 0 {
					if stage_live_work_lease_count(&ctx, task.workflow_run_id, task.workflow_execution_no, task.stage_key) >= cap do continue
				}
			}
			grant_work(svc, u, &ctx, task, trigger)
		}
	}
	return reconcile_placement_in_uow(svc, u, chain, ctx.grant_failures[:], true)
}

@(private = "package")
stage_live_work_lease_count :: proc(ctx: ^Match_Context, run_id: domain.Workflow_Run_ID, execution_no: int, stage_key: string) -> int {
	count := 0
	for l in ctx.leases {
		if l.phase == domain.LEASE_PHASE_WAITING || l.kind != domain.LEASE_KIND_WORK do continue
		if ctx.tasks_loaded {
			for t in ctx.tasks {
				if t.task_id == l.task_id && t.workflow_run_id == run_id && t.workflow_execution_no == execution_no && t.stage_key == stage_key {
					count += 1
					break
				}
			}
		} else if ctx.service != nil {
			// A context without tasks (inline grant) reads the leased task: bounded
			// by the chain's leases, not its tasks.
			if t, ok, _ := iface.taskchain_get_task(ctx.service.repo, l.task_id); ok && t.workflow_run_id == run_id && t.workflow_execution_no == execution_no && t.stage_key == stage_key do count += 1
		}
	}
	return count
}

// ---- context ------------------------------------------------------------------------

Grant_Placement_Failure :: struct {
 task_id: domain.Task_ID,
 failure: Placement_Failure,
}

Match_Context :: struct {
	service: ^Service,
 grant_failures: [dynamic]Grant_Placement_Failure,

	chain:     domain.Task_Chain,
	// tasks_loaded: false for a context built for one pulling instance or one
	// task (`lease next`, inline grants): tasks and sorted are then empty.
	tasks_loaded: bool,
	tasks:     []domain.Task,
	sorted:    []domain.Task,
	fleets:    []domain.Task_Chain_Fleet,
	dirs:      []domain.Task_Chain_Directory,
	leases:    [dynamic]domain.Task_Lease,
	instances: [dynamic]domain.Agent_Instance,
	// held: instance ids that hold a lease (existing or granted in this run).
	held:      map[string]bool,
	coordinator: domain.Agent_Instance,
	has_coordinator: bool,
	now_ms:    i64,
}

@(private = "package")
// with_tasks=false skips the chain's tasks (the only part that grows with the
// chain): fleets, directories, leases and member instances are bounded by the
// fleet and the running instances (REQ-SCHED-38).
load_match_context :: proc(svc: ^Service, chain: domain.Task_Chain, with_tasks := true) -> (Match_Context, bool, domain.Domain_Error) {
	ctx := Match_Context{chain = chain, now_ms = now_ms(svc.clock), grant_failures=make([dynamic]Grant_Placement_Failure,context.temp_allocator)}
	ctx.service = svc
	if with_tasks {
		tasks, terr := iface.taskchain_list_tasks_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
		if terr.code != .None do return ctx, false, terr
		ctx.tasks_loaded = true
		ctx.tasks = tasks
		ctx.sorted = slice.clone(tasks)
		slice.sort_by(ctx.sorted, proc(a, b: domain.Task) -> bool {
			if a.priority != b.priority do return a.priority < b.priority
			ra, rb := a.ready_since, b.ready_since
			if ra != rb {
				if ra == "" do return false
				if rb == "" do return true
				return ra < rb
			}
			if a.created_at != b.created_at do return a.created_at < b.created_at
			return a.task_id < b.task_id
		})
	}
	fleets, ferr := iface.taskchain_list_fleets_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if ferr.code != .None do return ctx, false, ferr
	ctx.fleets = fleets
	dirs, derr := iface.taskchain_list_directories_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if derr.code == .None do ctx.dirs = dirs
	leases, lerr := iface.taskchain_list_leases_by_chain(svc.repo, chain.chain_id)
	if lerr.code != .None do return ctx, false, lerr
	ctx.leases = make([dynamic]domain.Task_Lease)
	append(&ctx.leases, ..leases)
	ctx.held = make(map[string]bool)
	for l in ctx.leases do ctx.held[l.holder_instance_id] = true
	// Chain instances: members ∪ owner instances bound to the chain ∪ coordinator.
	ctx.instances = make([dynamic]domain.Agent_Instance)
	seen := make(map[string]bool, context.temp_allocator)
	add := proc(ctx: ^Match_Context, seen: ^map[string]bool, inst: domain.Agent_Instance) {
		if inst.agent_instance_id == "" || seen[inst.agent_instance_id] do return
		seen[inst.agent_instance_id] = true
		append(&ctx.instances, inst)
	}
	if members, merr := iface.taskchain_list_members_by_chain(svc.repo, chain.chain_id, chain.owner_user_id); merr.code == .None {
		for m in members {
			if inst, iok, _ := iface.agent_get_instance(svc.agents, m.agent_instance_id); iok do add(&ctx, &seen, inst)
		}
	}
	if insts, ierr := iface.agent_list_instances_by_chain(svc.agents, chain.owner_user_id, string(chain.chain_id)); ierr.code == .None {
		for inst in insts do add(&ctx, &seen, inst)
	}
	if chain.coordinator_agent_instance_id != "" {
		if coord, cok, _ := iface.agent_get_instance(svc.agents, chain.coordinator_agent_instance_id); cok {
			add(&ctx, &seen, coord)
			ctx.coordinator = coord
			ctx.has_coordinator = true
		}
	}
	return ctx, true, domain.Domain_Error{}
}

@(private = "package")
destroy_match_context :: proc(ctx: ^Match_Context) {
	delete(ctx.grant_failures)
	delete(ctx.sorted)
	delete(ctx.leases)
	delete(ctx.instances)
	delete(ctx.held)
}

@(private = "package")
task_has_live_lease :: proc(ctx: ^Match_Context, task_id: domain.Task_ID, kind: string) -> bool {
	for l in ctx.leases {
		if l.phase == domain.LEASE_PHASE_WAITING || l.task_id != task_id || l.kind != kind do continue
		return true
	}
	return false
}

// ---- placement (plan §4a) -------------------------------------------------------------

// resolve_placement: task pin → fleet row bridge_id → chain directory bridge →
// coordinator bridge. directory_id is the chain directory on that bridge ("" if
// none) — the unit of the ≤ 1 live work lease rule.
resolve_placement :: proc(ctx: ^Match_Context, task: domain.Task, fleet: domain.Task_Chain_Fleet, honour_pin: bool) -> (Placement, bool) {
	bridge_id := ""
	if honour_pin do bridge_id = strings.trim_space(task.bridge_id)
	if bridge_id == "" do bridge_id = strings.trim_space(fleet.bridge_id)
	if bridge_id == "" && len(ctx.dirs) > 0 do bridge_id = ctx.dirs[0].bridge_id
	if bridge_id == "" && ctx.has_coordinator do bridge_id = ctx.coordinator.bridge_id
	if bridge_id == "" do return Placement{}, false
	return placement_on_bridge(ctx, fleet, bridge_id), true
}

// placement_on_bridge: the fleet row's runtime selection and the chain
// directory for one bridge. Reuse (REQ-SCHED-31) places a grant on the bridge
// of the instance it reuses.
placement_on_bridge :: proc(ctx: ^Match_Context, fleet: domain.Task_Chain_Fleet, bridge_id: string) -> Placement {
	provider, model := fleet_model_on_bridge(fleet, bridge_id)
	profile := fleet_profile_on_bridge(fleet, bridge_id)
	runtime_error: domain.Domain_Error
	if ctx.service != nil && ctx.service.agent_service != nil {
		s := agent.fleet_service(ctx.service.agent_service)
		r, err := fleet_settings.resolve(&s, ctx.chain.owner_user_id, bridge_id, fleet.agent_id, fleet_settings.legacy_runtime(fleet, bridge_id), catalog_fallback = false)
		runtime_error = err
		if err.code == .None do provider, profile, model = strings.clone(r.runtime.provider, context.temp_allocator), strings.clone(r.runtime.provider_profile, context.temp_allocator), strings.clone(r.runtime.model, context.temp_allocator)
		domain.fleet_runtime_destroy(r.runtime)
	}
	return Placement{
		runtime_error = runtime_error,
		bridge_id    = bridge_id,
		directory_id = resolve_directory_for_bridge(ctx.dirs, bridge_id),
		provider_profile=profile,
		provider     = provider,
		model        = model,
	}
}

// ---- work pass -----------------------------------------------------------------------

@(private = "file")
grant_work :: proc(svc: ^Service, u: ^Uow, ctx: ^Match_Context, task: domain.Task, trigger: Trigger) {
	assignee := brief_assignee(task.brief_json)
	// Existing canonical ownership wins over new placement selection until release.
	for claim in ctx.leases {
		if claim.task_id != task.task_id || claim.kind != domain.LEASE_KIND_WORK do continue
		if owner, found, _ := iface.agent_get_instance(svc.agents, claim.holder_instance_id); found { assignee = owner.agent_id }
	}
	// Work goes only to the assignee (REQ-SCHED-9); a task without one waits
	// (dispatch_blockers names it).
	if assignee == "" do return
	// A task for the coordinator's agent is served only by the coordinator,
	// which pulls it with `lease next` (REQ-SCHED-13). It is never woken; an
	// unavailable process gets the Start agent card.
	if ctx.has_coordinator && assignee == ctx.coordinator.agent_id {
		if reason := coordinator_unavailable_reason(svc, ctx); reason != "" {
			block_ready_agent_in_uow(svc, u, task, ctx.coordinator.agent_id, coordinator_placement(ctx), reason)
		}
		return
	}
	fleet, has_row := fleet_row_for_agent(ctx.fleets[:], assignee)
	if !has_row || fleet.paused do return
	evs, _ := task_fold_events(svc, task)
	view := fold_task(evs, fold_input_for_task(task, true))
	prefer := ""
	if view.last_release == .Changes_Requested || view.last_release == .Expired {
		prefer = last_attempt_holder(svc, task)
	}
	base, pok := resolve_placement(ctx, task, fleet, true)
	pick := pick_instance(svc, u, ctx, task, fleet, base, pok, placement_restriction(task, fleet, true), domain.LEASE_KIND_WORK, prefer)
	if !pick.found {
		if pick.why != "" do block_ready_agent_in_uow(svc, u, task, fleet.agent_id, pick.placement, pick.why)
		return
	}
	// The chain cap queues the grant silently; a slot frees by an event that
	// rematches (REQ-SCHED-34).
	if chain_cap_refusal(svc, ctx, u, pick.inst, pick.counted, domain.LEASE_KIND_WORK, task) != "" do return
	inst, placement, ready, why := pick_materialize(svc, u, ctx, fleet, pick, domain.LEASE_KIND_WORK)
	if !ready {
		if why != "" do block_ready_agent_in_uow(svc, u, task, fleet.agent_id, placement, why)
		return
	}
	lease, gok, gerr := grant_in_uow(svc, u, Grant_Request{
		chain = ctx.chain, task = task, instance = inst,
		kind = domain.LEASE_KIND_WORK, delivery = domain.LEASE_DELIVERY_WAKE,
		placement = placement, actor = hub_actor(), trigger = trigger, reuse_note = pick.reuse_note,
	})
	if !gok {
		record_grant_placement_failure(ctx, task, fleet, placement, "work", gerr)
		return
	}
	append(&ctx.leases, lease)
	ctx.held[inst.agent_instance_id] = true
}

// coordinator_unavailable_reason: why the coordinator cannot pull an item
// assigned to it ("" when it is running or starting, or its bridge is offline
// — the placement snapshot owns bridge absence; no business block).
@(private = "package")
coordinator_unavailable_reason :: proc(svc: ^Service, ctx: ^Match_Context) -> string {
	if !ctx.has_coordinator do return ""
	coord := ctx.coordinator
	if !bridge_online(svc, coord.bridge_id) do return ""
	if instance_is_live(coord) || instance_is_pending(coord) do return ""
	return instance_failure_reason(coord)
}

@(private = "package")
coordinator_placement :: proc(ctx: ^Match_Context) -> Placement {
	return Placement{bridge_id = ctx.coordinator.bridge_id, provider = ctx.coordinator.provider, model = ctx.coordinator.model}
}

// ---- review pass ---------------------------------------------------------------------

@(private = "file")
grant_reviews :: proc(svc: ^Service, u: ^Uow, ctx: ^Match_Context, task: domain.Task, trigger: Trigger) {
	if requirements_stale_review(svc, task) do return
	// A held task gets no new review lease (REQ-TV2-5).
	if task_is_held(task) do return
	reviewers := required_reviewers(task, task_author_agent(svc, task))
	if len(reviewers) == 0 do return
	reviews, _ := iface.taskchain_list_reviews_by_task(svc.repo, task.task_id, task.owner_user_id)
	failure, failed_agent := "", ""
	failed_placement: Placement
	// One review lease per (task, reviewer agent) (REQ-SCHED-6); the gate is a
	// strict AND over the same agents (gate.odin).
	for agent_id in reviewers {
		if !agent_review_owed(reviews, task, agent_id) do continue
		if review_lease_live_for(ctx, svc, task.task_id, agent_id) do continue
		// The coordinator pulls a review it owes (REQ-SCHED-13).
		if ctx.has_coordinator && agent_id == ctx.coordinator.agent_id {
			if reason := coordinator_unavailable_reason(svc, ctx); reason != "" {
				failure, failed_agent, failed_placement = reason, agent_id, coordinator_placement(ctx)
			}
			continue
		}
		fleet, has_row := fleet_row_for_agent(ctx.fleets[:], agent_id)
		if !has_row || fleet.paused do continue
		base, pok := resolve_placement(ctx, task, fleet, false)
		pick := pick_instance(svc, u, ctx, task, fleet, base, pok, placement_restriction(task, fleet, false), domain.LEASE_KIND_REVIEW, "")
		if !pick.found {
			// Capacity and retriable backoff report no reason and simply wait.
			if pick.why != "" do failure, failed_agent, failed_placement = pick.why, agent_id, pick.placement
			continue
		}
		// A review may take a grace instance's slot; otherwise it waits for a
		// running review to end (REQ-SCHED-34, spec 9.2).
		victim: domain.Agent_Instance
		if chain_cap_refusal(svc, ctx, u, pick.inst, pick.counted, domain.LEASE_KIND_REVIEW, task, &victim) != "" do continue
		inst, placement, ready, why := pick_materialize(svc, u, ctx, fleet, pick, domain.LEASE_KIND_REVIEW)
		if !ready {
			if why != "" do failure, failed_agent, failed_placement = why, agent_id, placement
			continue
		}
		lease, gok, gerr := grant_in_uow(svc, u, Grant_Request{
			chain = ctx.chain, task = task, instance = inst,
			kind = domain.LEASE_KIND_REVIEW, delivery = domain.LEASE_DELIVERY_WAKE,
			placement = placement, actor = hub_actor(), trigger = trigger, reuse_note = pick.reuse_note,
		})
		if !gok {
			record_grant_placement_failure(ctx, task, fleet, placement, "review", gerr)
			continue
		}
		// The review holds the slot now; only then does the grace instance yield.
		yield_grace_slot(svc, ctx, u, victim)
		append(&ctx.leases, lease)
		ctx.held[inst.agent_instance_id] = true
	}
	// An owed reviewer that cannot be placed would otherwise starve silently.
	// Surface it as the work path does (the same Start agent card); the block
	// takes the task out of the matcher's In_Review scan, so it is raised once.
	// While another review lease runs, its release rematches and decides then.
	if failure == "" do return
	for l in ctx.leases do if l.task_id == task.task_id && l.kind == domain.LEASE_KIND_REVIEW do return
	block_ready_agent_in_uow(svc, u, task, failed_agent, failed_placement, failure)
}

// review_lease_live_for: an instance of `agent_id` already holds an active
// review lease on the task.
@(private = "package")
review_lease_live_for :: proc(ctx: ^Match_Context, svc: ^Service, task_id: domain.Task_ID, agent_id: string) -> bool {
	for l in ctx.leases {
		if l.phase == domain.LEASE_PHASE_WAITING || l.task_id != task_id || l.kind != domain.LEASE_KIND_REVIEW do continue
		for inst in ctx.instances do if inst.agent_instance_id == l.holder_instance_id && inst.agent_id == agent_id do return true
		if inst, ok, _ := iface.agent_get_instance(svc.agents, l.holder_instance_id); ok && inst.agent_id == agent_id do return true
	}
	return false
}

// Keep provider messages readable in both fleet and coordinator recovery cards.
instance_failure_reason :: proc(inst: domain.Agent_Instance) -> string {
	reason := fmt.tprintf("instance %s is %s", inst.agent_instance_id, inst.runtime_status)
	if message := jsonx.extract_string(inst.last_error_json, "message", "", true, context.temp_allocator); message != "" {
		return fmt.tprintf("%s: %s", reason, message)
	}
	return reason
}

// ---- instance selection --------------------------------------------------------------

// Pick: the instance chosen for a grant, before the chain cap is checked and
// before a new instance is created (pick_materialize).
Pick :: struct {
	inst:       domain.Agent_Instance,
	placement:  Placement,
	found:      bool,
	counted:    bool,   // inst already occupies a chain slot (REQ-SCHED-34)
	jit:        bool,   // no instance can be reused: create one on `placement`
	why:        string, // Start agent card reason when nothing may be picked
	reuse_note: string, // why an existing instance was not reused (jit only)
}

// pick_instance chooses WHO runs a grant for `fleet`, over all bridges unless
// `restrict` names one (task pin or fleet-row bridge; REQ-SCHED-30/31):
//   1. the holder of a waiting claim on the task (rework, a parked review);
//   2. `prefer` (the previous holder), then a live lease-free instance that
//      is not being stopped (a reviewer in its grace window keeps its process);
//   3. a stopped reusable instance on an online bridge that supports the
//      row's runtime (relaunched by the wake), below capacity;
//   4. an instance that is being stopped;
//   5. a new instance on `base`, below capacity, only when no existing
//      instance may be used and none must not be replaced (REQ-SCHED-32).
// Capacity is the agent's occupied instances over all bridges (REQ-SCHED-33).
// Among equal candidates the base placement's bridge wins. Coordinators are
// never candidates: an item for the coordinator's agent is pulled by the
// coordinator, never woken or JIT-copied (REQ-SCHED-13).
@(private = "file")
pick_instance :: proc(svc: ^Service, u: ^Uow, ctx: ^Match_Context, task: domain.Task, fleet: domain.Task_Chain_Fleet, base: Placement, base_ok: bool, restrict, kind, prefer: string) -> Pick {
	if ctx.has_coordinator && fleet.agent_id == ctx.coordinator.agent_id do return {placement = base}
	// A waiting claim is a reservation for this exact instance, including rework.
	for claim in ctx.leases {
		if claim.task_id != task.task_id || claim.phase != domain.LEASE_PHASE_WAITING || claim.kind != kind do continue
		for inst in ctx.instances {
			if inst.agent_instance_id != claim.holder_instance_id || inst.agent_id != fleet.agent_id do continue
			placement := placement_on_bridge(ctx, fleet, inst.bridge_id)
			if restrict != "" && inst.bridge_id != restrict do return {placement = placement, why = "assigned instance is on another bridge"}
			// Its bridge being away or ineligible is queueing reported by the
			// placement snapshot, checked before the instance (as before reuse).
			if reason, _ := placement_problem(svc, ctx, placement, true, fleet.agent_id); reason != "" do return {placement = placement}
			if disposition := agent.failed_instance_disposition(inst, ctx.now_ms); disposition == .Dead || disposition == .Hold do return {placement = placement, why = instance_failure_reason(inst)}
			if inst.stopped_by == agent.STOPPED_BY_USER do return {placement = placement, why = "assigned instance was stopped by the user"}
			if busy, err := iface.agent_runtime_busy(svc.agents, inst.agent_instance_id); busy || err.code != .None do return {placement = placement, why = "assigned instance has a pending runtime action"}
			if kind == domain.LEASE_KIND_WORK && placement.directory_id != "" && directory_has_work_lease_ctx(ctx, placement.directory_id) do return {placement = placement}
			return {inst = inst, placement = placement, found = true, counted = instance_slot_counted(svc, ctx, u, inst)}
		}
	}

	// Pause (REQ-SCHED-2) is decided by the callers before a pick.
	scan := reuse_scan(svc, u, ctx, task, fleet, restrict, base.bridge_id, kind, prefer)
	// Standard rematches end at ten minutes; provider backoff may be longer.
	// Recheck this task just after the earliest actual retry deadline.
	if scan.retry_due_ms > 0 do timers_arm(svc, .Rematch, string(task.task_id), scan.retry_due_ms + 1000, domain.task_state_string(task.state))
	choose :: proc(svc: ^Service, ctx: ^Match_Context, u: ^Uow, fleet: domain.Task_Chain_Fleet, inst: domain.Agent_Instance) -> Pick {
		return {inst = inst, placement = placement_on_bridge(ctx, fleet, inst.bridge_id), found = true, counted = instance_slot_counted(svc, ctx, u, inst)}
	}
	// Capacity bounds every pick that starts a process: a stopped previous
	// holder or warm instance is re-bootstrapped by the wake, so it may only be
	// chosen below capacity, exactly like a new instance (REQ-TV2-5).
	// A live or stopping instance is already counted, so its grant keeps the
	// occupied count; it still needs the agent's lease holders to stay within
	// capacity after the grant (a manual extra instance, or one on another
	// bridge, cannot bypass it).
	below_capacity := scan.occupied < scan.capacity
	within_capacity := scan.held < scan.capacity
	if scan.have_pref {
		if instance_is_live(scan.preferred) || instance_is_pending(scan.preferred) {
			if within_capacity do return choose(svc, ctx, u, fleet, scan.preferred)
		} else if below_capacity do return choose(svc, ctx, u, fleet, scan.preferred)
	}
	if scan.have_live && within_capacity do return choose(svc, ctx, u, fleet, scan.live)
	if scan.have_warm && below_capacity do return choose(svc, ctx, u, fleet, scan.warm)
	if scan.have_stopping && within_capacity do return choose(svc, ctx, u, fleet, scan.stopping)
	if !below_capacity do return {placement = base}
	// A new instance goes where the base placement says. Problems there are
	// queueing reported by the placement snapshot, never a card, and are
	// checked before an unusable instance's card (as before reuse).
	if !base_ok do return {placement = base}
	if reason, _ := placement_problem(svc, ctx, base, true, fleet.agent_id); reason != "" do return {placement = base}
	if scan.failure != "" do return {placement = base, why = scan.failure}
	if kind == domain.LEASE_KIND_WORK && base.directory_id != "" && directory_has_work_lease_ctx(ctx, base.directory_id) do return {placement = base}
	return {placement = base, found = true, jit = true, reuse_note = scan.unusable}
}

// pick_materialize creates the new instance a pick asked for (after the chain
// cap admitted it, so a refused grant never leaves an unused instance behind).
@(private = "file")
pick_materialize :: proc(svc: ^Service, u: ^Uow, ctx: ^Match_Context, fleet: domain.Task_Chain_Fleet, pick: Pick, kind: string) -> (domain.Agent_Instance, Placement, bool, string) {
	if !pick.jit do return pick.inst, pick.placement, true, ""
	inst, ok, why := jit_prepare(svc, u, ctx, fleet, pick.placement, kind)
	return inst, pick.placement, ok, why
}

// jit_prepare creates a stopped instance. Only the subsequent grant opens
// its generation and reserves launch quota; dispatch follows commit.
@(private = "file")
jit_prepare :: proc(svc: ^Service, u: ^Uow, ctx: ^Match_Context, fleet: domain.Task_Chain_Fleet, placement: Placement, kind: string) -> (domain.Agent_Instance, bool, string) {
	if svc.agent_service == nil do return {}, false, "agent launch service is unavailable"
	provider, model := resolve_launch_model(svc.agent_service, placement.bridge_id, placement.provider, placement.model,placement.provider_profile)
	defer delete(provider)
	defer delete(model)
	project_id := domain.Project_ID("")
	if ctx.has_coordinator do project_id = ctx.coordinator.project_id
	auth := contracts.Auth_Context{user_id = string(ctx.chain.owner_user_id), kind = .Internal_User, bridge_id = placement.bridge_id}
	input := agent.Create_Instance_Input{
		fleet_scope = "chain",
		agent_id = fleet.agent_id, bridge_id = placement.bridge_id,
		provider = provider, model = model,provider_profile=placement.provider_profile,
		chain_id = string(ctx.chain.chain_id), project_id = project_id,
		member_role = "worker",
	}
	inst, ok, err := agent.create_instance_stopped(svc.agent_service, auth, input)
	if !ok {
		fmt.eprintfln("[taskv2] match: JIT %s instance for agent %s on bridge %s failed: %s", kind, fleet.agent_id, placement.bridge_id, err.message)
		return {}, false, err.message
	}
	effect_instance_changed(u, inst.agent_instance_id, "created")
	append(&ctx.instances, inst)
	return inst, true, ""
}

// ---- inline grant for a pulling instance (lease.next) ------------------------------

// Inline_Refusal: the first item for a pulling instance that could not be
// granted, and why (REQ-SCHED-41). Empty when nothing was available.
Inline_Refusal :: struct {
	task_id: domain.Task_ID,
	reason:  string,
}

// INLINE_CANDIDATE_LIMIT is k in spec SCHED 10.1: how many owed reviews and how
// many assigned ready tasks one `lease next` considers. A candidate refused by a
// grant check (held, stale requirements, directory rule) passes to the next.
INLINE_CANDIDATE_LIMIT :: 16

// grant_inline_for_instance is the matcher restricted to ONE candidate holder:
// the instance that just called `lease.next`. delivery=inline, so the caller
// is never woken. Order (REQ-SCHED-12, REQ-SCHED-35): a review its agent owes,
// then rework on a task assigned to its agent, then new ready work assigned to
// its agent. Every grant check lives in grant_in_uow. Returns the lease and its
// task when something was granted; otherwise the first refusal, if any.
//
// Cost (REQ-SCHED-38/40): the candidates come from two index lookups
// (task_reviewers and tasks.assignee_agent_id), at most INLINE_CANDIDATE_LIMIT
// each. When both are empty (the idle path) nothing else is read. Otherwise the
// context holds the chain's fleet, directories, leases and member instances,
// never its tasks.
grant_inline_for_instance :: proc(svc: ^Service, u: ^Uow, chain: domain.Task_Chain, inst: domain.Agent_Instance, trigger: Trigger) -> (domain.Task_Lease, domain.Task, bool, Inline_Refusal) {
	refusal := Inline_Refusal{}
	if chain.publish_state != .Published || chain.status != .Active do return {}, {}, false, refusal
	if inst.agent_id == "" do return {}, {}, false, refusal
	metric_matcher_run(trigger)
	owed, oerr := iface.taskchain_list_owed_reviews(svc.repo, chain.chain_id, chain.owner_user_id, inst.agent_id, INLINE_CANDIDATE_LIMIT)
	if oerr.code != .None do return {}, {}, false, refusal
	assigned, aerr := iface.taskchain_list_assigned_ready(svc.repo, chain.chain_id, chain.owner_user_id, inst.agent_id, INLINE_CANDIDATE_LIMIT)
	if aerr.code != .None do return {}, {}, false, refusal
	if len(owed) == 0 && len(assigned) == 0 do return {}, {}, false, refusal
	ctx, ok, _ := load_match_context(svc, chain, with_tasks = false)
	if !ok do return {}, {}, false, refusal
	defer destroy_match_context(&ctx)
	if ctx.held[inst.agent_instance_id] do return {}, {}, false, refusal
	fleet, has_fleet := puller_fleet_row(&ctx, inst, is_coordinator(svc, chain, inst.agent_instance_id))
	if !has_fleet do return {}, {}, false, refusal
	actor := Actor{kind = ACTOR_AGENT, id = inst.agent_instance_id}
	note_refusal :: proc(refusal: ^Inline_Refusal, task_id: domain.Task_ID, reason: string) {
		if refusal.task_id == "" do refusal^ = Inline_Refusal{task_id = task_id, reason = reason}
	}

	// Review pass: reviews this agent owes (the lookup applies the listing,
	// own-work and already-posted rules of required_reviewers/agent_review_owed).
	for task in owed {
		listed := false
		for id in brief_reviewer_agents(task.brief_json, context.temp_allocator) do if id == inst.agent_id { listed = true; break }
		if !listed do continue
		if review_lease_live_for(&ctx, svc, task.task_id, inst.agent_id) do continue
		if fleet.paused { note_refusal(&refusal, task.task_id, "this agent's fleet row is paused"); continue }
		if task_is_held(task) { note_refusal(&refusal, task.task_id, "task is held"); continue }
		if requirements_stale_review(svc, task) { note_refusal(&refusal, task.task_id, "task requirements changed; the review waits for the worker"); continue }
		if restrict := placement_restriction(task, fleet, false); restrict != "" && restrict != inst.bridge_id { note_refusal(&refusal, task.task_id, "this agent's fleet row is placed on another bridge"); continue }
		placement := inline_placement(&ctx, fleet, inst)
		if reason := chain_cap_refusal(svc, &ctx, u, inst, instance_slot_counted(svc, &ctx, u, inst), domain.LEASE_KIND_REVIEW, task); reason != "" { note_refusal(&refusal, task.task_id, reason); continue }
		lease, gok, gerr := grant_in_uow(svc, u, Grant_Request{
			chain = chain, task = task, instance = inst,
			kind = domain.LEASE_KIND_REVIEW, delivery = domain.LEASE_DELIVERY_INLINE,
			placement = placement, actor = actor, trigger = trigger,
		})
		if gok {
			fresh, _, _ := iface.taskchain_get_task(svc.repo, task.task_id)
			return lease, fresh, true, {}
		}
		note_refusal(&refusal, task.task_id, gerr.message)
	}
	// Work: rework first (the task was worked before), then new work — the
	// lookup's order (REQ-SCHED-35). Placement follows the caller unless a
	// task pin or the fleet row's bridge restricts it (REQ-SCHED-31); the
	// chain cap applies to inline grants too (REQ-SCHED-34).
	for task in assigned {
		if brief_assignee(task.brief_json) != inst.agent_id do continue
		if task_has_live_lease(&ctx, task.task_id, domain.LEASE_KIND_WORK) do continue
		if fleet.paused { note_refusal(&refusal, task.task_id, "this agent's fleet row is paused"); continue }
		if reason := inline_bridge_refusal(task, fleet, inst); reason != "" { note_refusal(&refusal, task.task_id, reason); continue }
		placement := inline_placement(&ctx, fleet, inst)
		if placement.directory_id != "" && directory_has_work_lease_ctx(&ctx, placement.directory_id) { note_refusal(&refusal, task.task_id, "another work lease is live on this chain directory"); continue }
		if reason := chain_cap_refusal(svc, &ctx, u, inst, instance_slot_counted(svc, &ctx, u, inst), domain.LEASE_KIND_WORK, task); reason != "" { note_refusal(&refusal, task.task_id, reason); continue }
		lease, gok, gerr := grant_in_uow(svc, u, Grant_Request{
			chain = chain, task = task, instance = inst,
			kind = domain.LEASE_KIND_WORK, delivery = domain.LEASE_DELIVERY_INLINE,
			placement = placement, actor = actor, trigger = trigger,
		})
		if gok {
			fresh, _, _ := iface.taskchain_get_task(svc.repo, task.task_id)
			return lease, fresh, true, {}
		}
		note_refusal(&refusal, task.task_id, gerr.message)
	}
	return {}, {}, false, refusal
}

// inline_placement: the caller is where it is — its bridge and that bridge's
// chain directory, with the fleet row's runtime selection for that bridge.
// Placement follows the reused instance (REQ-SCHED-31).
@(private = "file")
inline_placement :: proc(ctx: ^Match_Context, fleet: domain.Task_Chain_Fleet, inst: domain.Agent_Instance) -> Placement {
	return placement_on_bridge(ctx, fleet, inst.bridge_id)
}

// inline_bridge_refusal: a task pin or the fleet row's bridge restricts work
// to one bridge, and pins win over reuse (REQ-SCHED-31).
@(private = "file")
inline_bridge_refusal :: proc(task: domain.Task, fleet: domain.Task_Chain_Fleet, inst: domain.Agent_Instance) -> string {
	if pin := strings.trim_space(task.bridge_id); pin != "" && pin != inst.bridge_id do return "task is pinned to another bridge"
	if row := strings.trim_space(fleet.bridge_id); row != "" && row != inst.bridge_id do return "this agent's fleet row is placed on another bridge"
	return ""
}

// grant_inline_task_for_instance: the work pass of grant_inline_for_instance
// restricted to ONE named task (lease switch). Returns why it cannot be granted.
grant_inline_task_for_instance :: proc(svc: ^Service, u: ^Uow, chain: domain.Task_Chain, inst: domain.Agent_Instance, task_id: domain.Task_ID, trigger: Trigger) -> (domain.Task_Lease, domain.Task, bool, domain.Domain_Error) {
	if chain.publish_state != .Published || chain.status != .Active do return {}, {}, false, domain.domain_error(.Conflict, "chain is not active")
	ctx, ok, err := load_match_context(svc, chain, with_tasks = false)
	if !ok do return {}, {}, false, err
	defer destroy_match_context(&ctx)
	fleet, has_fleet := puller_fleet_row(&ctx, inst, is_coordinator(svc, chain, inst.agent_instance_id))
	if !has_fleet do return {}, {}, false, domain.domain_error(.Conflict, "this agent has no fleet row in the chain")
	if fleet.paused do return {}, {}, false, domain.domain_error(.Conflict, "this agent's fleet row is paused on the chain")
	// One point read of the named task, not the chain's tasks.
	if task, found, _ := iface.taskchain_get_task(svc.repo, task_id); found && task.chain_id == chain.chain_id && task.owner_user_id == chain.owner_user_id {
		if task.state != .Ready || task.kind == .Gate do return {}, {}, false, domain.domain_error(.Conflict, "task is not ready")
		if task_has_live_lease(&ctx, task.task_id, domain.LEASE_KIND_WORK) do return {}, {}, false, domain.domain_error(.Conflict, "task is already held")
		if brief_assignee(task.brief_json) != inst.agent_id do return {}, {}, false, domain.domain_error(.Conflict, "task is assigned to another agent")
		if reason := inline_bridge_refusal(task, fleet, inst); reason != "" do return {}, {}, false, domain.domain_error(.Conflict, reason)
		placement := inline_placement(&ctx, fleet, inst)
		if reason := chain_cap_refusal(svc, &ctx, u, inst, instance_slot_counted(svc, &ctx, u, inst), domain.LEASE_KIND_WORK, task); reason != "" do return {}, {}, false, domain.domain_error(.Conflict, reason, `{"code":"chain_cap"}`)
		lease, gok, gerr := grant_in_uow(svc, u, Grant_Request{
			chain = chain, task = task, instance = inst,
			kind = domain.LEASE_KIND_WORK, delivery = domain.LEASE_DELIVERY_INLINE,
			placement = placement, actor = Actor{kind = ACTOR_AGENT, id = inst.agent_instance_id}, trigger = trigger,
		})
		if !gok do return {}, {}, false, gerr
		fresh, _, _ := iface.taskchain_get_task(svc.repo, task.task_id)
		return lease, fresh, true, domain.Domain_Error{}
	}
	return {}, {}, false, domain.domain_error(.Not_Found, "task is not in this chain")
}

// puller_fleet_row: the fleet row an instance pulling work (`lease next`) works
// under. The coordinator needs no row (6.1): it is eligible by assignment and
// works under a row of its own agent on its own bridge, outside capacity.
@(private = "file")
puller_fleet_row :: proc(ctx: ^Match_Context, inst: domain.Agent_Instance, coordinator: bool) -> (domain.Task_Chain_Fleet, bool) {
	if coordinator do return domain.Task_Chain_Fleet{task_chain_id = ctx.chain.chain_id, agent_id = inst.agent_id, capacity = 1}, true
	for f in ctx.fleets do if f.agent_id == inst.agent_id do return f, true
	return {}, false
}

// ---- helpers -----------------------------------------------------------------------------

// last_attempt_holder: the holder of the highest-numbered attempt row.
last_attempt_holder :: proc(svc: ^Service, task: domain.Task) -> string {
	attempts, err := iface.taskchain_list_attempts_by_task(svc.repo, task.task_id, task.owner_user_id)
	if err.code != .None do return ""
	best := domain.Task_Attempt{attempt_no = -1}
	for a in attempts do if a.attempt_no > best.attempt_no do best = a
	return best.holder_instance_id if best.attempt_no >= 0 else ""
}

@(private = "package")
directory_has_work_lease_ctx :: proc(ctx: ^Match_Context, directory_id: string) -> bool {
	// One live work lease per chain directory. VCS directories are exempt only
	// for git when per-lease worktrees are on (PER_LEASE_WORKTREES_ENABLED);
	// otherwise two leases would share one checkout and wipe each other's work.
	if PER_LEASE_WORKTREES_ENABLED {
		for d in ctx.dirs {
			if d.directory_id == directory_id {
				if d.vcs_kind == "git" do return false
			}
		}
	}
	for l in ctx.leases {
		if l.phase == domain.LEASE_PHASE_WAITING || l.kind != domain.LEASE_KIND_WORK do continue
		if resolve_directory_for_bridge(ctx.dirs, l.bridge_id) == directory_id do return true
	}
	return false
}

_ :: platform

// A full row is queueing even when its bridge is offline. Capacity counts the
// agent's lease holders on every bridge (REQ-SCHED-33); `placement` is kept
// for callers and no longer narrows the count.
fleet_row_full :: proc(ctx: ^Match_Context, fleet: domain.Task_Chain_Fleet, placement: Placement) -> bool {
	count := 0
	for inst in ctx.instances {
		if inst.agent_id != fleet.agent_id do continue
		if ctx.held[inst.agent_instance_id] do count += 1
	}
	return count >= max(1, fleet.capacity)
}

// ---- dispatch diagnosis (task re-check) ------------------------------------------------

// dispatch_blockers explains why a ready task holds no work lease after a
// matcher pass: the same checks grant_work makes, in the same order, for the
// assignee's fleet row, but read-only (no JIT, no block event, no timer). Each
// entry is one human-readable reason; empty when nothing visible stops it.
dispatch_blockers :: proc(svc: ^Service, chain: domain.Task_Chain, task: domain.Task) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if chain.publish_state != .Published || chain.status != .Active {
		append(&out, "the chain is not active and published, so nothing is dispatched")
		return out[:]
	}
	if task.state != .Ready || task.kind == .Gate do return out[:]
	ctx, ok, _ := load_match_context(svc, chain)
	if !ok {
		append(&out, "the chain's fleet and leases could not be read")
		return out[:]
	}
	defer destroy_match_context(&ctx)
	if task_has_live_lease(&ctx, task.task_id, domain.LEASE_KIND_WORK) do return out[:]
	if task.stage_key != "" {
		stage_caps := make(map[string]map[string]int, context.temp_allocator)
		if cap := workflow_task_max_parallel_cached(svc, &stage_caps, task); cap > 0 {
			if n := stage_live_work_lease_count(&ctx, task.workflow_run_id, task.workflow_execution_no, task.stage_key); n >= cap {
				append(&out, fmt.tprintf("workflow stage %s is at max_parallel (%d/%d)", task.stage_key, n, cap))
				return out[:]
			}
		}
	}
	assignee := brief_assignee(task.brief_json)
	if assignee == "" {
		append(&out, "the task has no assignee; set one with `ham-ctl task update <id> --assignee <agt_…>`")
		return out[:]
	}
	if ctx.has_coordinator && assignee == ctx.coordinator.agent_id {
		coord := ctx.coordinator
		if !bridge_online(svc, coord.bridge_id) {
			append(&out, fmt.tprintf("coordinator %s: bridge %s is offline", coord.agent_instance_id, coord.bridge_id))
		} else if ctx.held[coord.agent_instance_id] {
			append(&out, fmt.tprintf("coordinator %s already holds a lease; it pulls this task after submitting", coord.agent_instance_id))
		} else if instance_is_live(coord) || instance_is_pending(coord) {
			append(&out, fmt.tprintf("assigned to the coordinator: waiting for %s to pull it with `ham-ctl lease next`", coord.agent_instance_id))
		} else {
			append(&out, fmt.tprintf("coordinator: %s", instance_failure_reason(coord)))
		}
		return out[:]
	}
	fleet, has_row := fleet_row_for_agent(ctx.fleets[:], assignee)
	if !has_row {
		append(&out, fmt.tprintf("assignee %s has no row in the chain fleet", assignee))
		return out[:]
	}
	if fleet.paused {
		append(&out, fmt.tprintf("%s: fleet row is paused", fleet.agent_id))
		return out[:]
	}
	placement, pok := resolve_placement(&ctx, task, fleet, true)
	if !pok {
		append(&out, fmt.tprintf("%s: no bridge placement can be resolved (no task pin, fleet bridge, chain directory or coordinator bridge)", fleet.agent_id))
		return out[:]
	}
	if placement.directory_id != "" && directory_has_work_lease_ctx(&ctx, placement.directory_id) {
		vcs := ""
		for d in ctx.dirs do if d.directory_id == placement.directory_id { vcs = d.vcs_kind; break }
		append(&out, fmt.tprintf("%s: chain directory %s already has a live work lease (vcs_kind %q; parallel work needs a git directory)", fleet.agent_id, placement.directory_id, vcs))
		return out[:]
	}
	held := 0
	for inst in ctx.instances {
		if inst.agent_id == fleet.agent_id && ctx.held[inst.agent_instance_id] do held += 1
	}
	if held >= max(1, fleet.capacity) && !fleet_owns_task(&ctx, task, fleet.agent_id) {
		append(&out, fmt.tprintf("%s: fleet full %d/%d over all bridges", fleet.agent_id, held, max(1, fleet.capacity)))
		return out[:]
	}
	if m, r := chain_cap_limits(ctx.chain); m > 0 {
		slots := chain_slots(svc, &ctx, nil)
		if !fleet_owns_task(&ctx, task, fleet.agent_id) && slots.work + 1 > m - r {
			append(&out, fmt.tprintf("chain work limit reached: %d work leases of max_parallel %d with review_reserve %d", slots.work, m, r))
			return out[:]
		}
	}
	if !bridge_online(svc, placement.bridge_id) {
		append(&out, fmt.tprintf("%s: bridge %s is offline", fleet.agent_id, placement.bridge_id))
		return out[:]
	}
	if svc.agent_service != nil && svc.agent_service.providers != nil {
		provider, model := resolve_launch_model(svc.agent_service, placement.bridge_id, placement.provider, placement.model,placement.provider_profile)
		_, valid, err := agent.validate_provider_model_intersection(svc.agent_service, placement.bridge_id, provider, model,placement.provider_profile)
		delete(provider)
		delete(model)
		if !valid {
			append(&out, fmt.tprintf("%s: %s", fleet.agent_id, err.message))
			return out[:]
		}
	}
	instance_reason := ""
	for inst in ctx.instances {
		if inst.agent_id != fleet.agent_id || ctx.held[inst.agent_instance_id] do continue
		if restrict := placement_restriction(task, fleet, true); restrict != "" && inst.bridge_id != restrict do continue
		if inst.stopped_by == agent.STOPPED_BY_USER {
			instance_reason = fmt.tprintf("instance %s was stopped by the user", inst.agent_instance_id)
			continue
		}
		disposition := agent.failed_instance_disposition(inst, ctx.now_ms)
		if disposition == .Dead || disposition == .Hold {
			instance_reason = instance_failure_reason(inst)
			continue
		}
		instance_reason = ""
		break
	}
	if instance_reason != "" {
		append(&out, fmt.tprintf("%s: %s", fleet.agent_id, instance_reason))
		return out[:]
	}
	append(&out, fmt.tprintf("%s: a slot is free (%d/%d over all bridges; placement bridge %s) but no lease was granted; see the hub log", fleet.agent_id, held, max(1, fleet.capacity), placement.bridge_id))
	return out[:]
}

fleet_owns_task :: proc(ctx: ^Match_Context, task: domain.Task, agent_id: string) -> bool {
	for claim in ctx.leases {
		if claim.task_id != task.task_id do continue
		for inst in ctx.instances do if inst.agent_instance_id == claim.holder_instance_id && inst.agent_id == agent_id do return true
	}
	return false
}


// A refused launch is a placement diagnostic, never an infrastructure block.
// Keep it in this matching pass and persist it with the existing snapshot.
record_grant_placement_failure :: proc(ctx: ^Match_Context, task: domain.Task, fleet: domain.Task_Chain_Fleet, placement: Placement, phase: string, err: domain.Domain_Error) {
	failures := make([dynamic]Placement_Failure, context.temp_allocator)
	reason := jsonx.extract_string(err.details_json, "code", "launch_refused", true, context.temp_allocator)
	append_placement_failure(&failures, ctx, task, fleet, placement, phase, reason, err.message, "grant")
	for failure in failures do append(&ctx.grant_failures, Grant_Placement_Failure{task.task_id, failure})
}
