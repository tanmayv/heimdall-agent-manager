package taskv2

import "core:fmt"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import agent "odin_test:hub/service/agent"

// ---- reuse and capacity (spec SCHED 7.4 and 9, REQ-SCHED-30..35) ---------------------
//
// Per agent (REQ-SCHED-33): an agent occupies at most `capacity` instances in
// the chain, counted over ALL bridges. Per chain (REQ-SCHED-34): at most
// max_parallel non-coordinator instances are occupied, and review_reserve of
// them are never taken by work. The coordinator is outside both counts.

// STOP_REASON_CAPACITY_YIELD: a lease-free grace instance stopped so a pending
// review of another agent can take its chain slot (REQ-SCHED-34).
STOP_REASON_CAPACITY_YIELD :: "capacity_yield"

// chain_cap_reserve_forced_zero: test hook. When set, the chain's
// review_reserve is treated as 0, so a test can show the cap deadlocks without
// the reserve (spec 14.4). Thread-local; never set outside tests.
@(thread_local)
chain_cap_reserve_forced_zero: bool

// chain_cap_limits: (M, r) for the chain; M == 0 means no chain cap. The
// stored reserve is validated on write (1 ≤ r ≤ M − 1); a row written before
// validation existed still gets the default reserve of 1.
chain_cap_limits :: proc(chain: domain.Task_Chain) -> (max_parallel: int, reserve: int) {
	if chain.max_parallel <= 0 do return 0, 0
	max_parallel = chain.max_parallel
	reserve = chain.review_reserve
	if reserve < 1 do reserve = 1
	if reserve > max_parallel - 1 do reserve = max(max_parallel - 1, 0)
	if chain_cap_reserve_forced_zero do reserve = 0
	return
}

@(private = "package")
ctx_is_coordinator :: proc(svc: ^Service, ctx: ^Match_Context, instance_id: string) -> bool {
	if ctx.has_coordinator do return ctx.coordinator.agent_instance_id == instance_id
	return is_coordinator(svc, ctx.chain, instance_id)
}

// instance_stopping: a live instance the lease system is stopping, in this
// unit of work or by a committed stop intent the bridge has not acted on yet.
@(private = "package")
instance_stopping :: proc(ctx: ^Match_Context, u: ^Uow, inst: domain.Agent_Instance) -> bool {
	if u != nil && effect_has_stop(u, inst.bridge_id, string(ctx.chain.chain_id), inst.agent_instance_id) do return true
	return lease_stop_reason(inst.stop_reason) && (instance_is_live(inst) || instance_is_pending(inst))
}

// instance_in_grace: a live or starting, lease-free, managed (fleet row) fleet
// instance that is not being stopped: the G of REQ-SCHED-34.
@(private = "package")
instance_in_grace :: proc(svc: ^Service, ctx: ^Match_Context, u: ^Uow, inst: domain.Agent_Instance) -> bool {
	if ctx.held[inst.agent_instance_id] do return false
	if !(instance_is_live(inst) || instance_is_pending(inst)) do return false
	if inst.stopped_by == agent.STOPPED_BY_USER do return false
	if _, managed := fleet_row_for_agent(ctx.fleets, inst.agent_id); !managed do return false
	if ctx_is_coordinator(svc, ctx, inst.agent_instance_id) do return false
	return !instance_stopping(ctx, u, inst)
}

Chain_Slots :: struct {
	work:   int, // W: work leases, active or waiting
	review: int, // R: active review leases
	grace:  int, // G: live lease-free fleet instances not being stopped
}

// chain_slots counts the occupied slots of the chain (REQ-SCHED-34). A review
// lease parked as waiting after a dispatch failure is not counted: its
// process never started.
chain_slots :: proc(svc: ^Service, ctx: ^Match_Context, u: ^Uow) -> Chain_Slots {
	s: Chain_Slots
	for l in ctx.leases {
		if ctx_is_coordinator(svc, ctx, l.holder_instance_id) do continue
		if l.kind == domain.LEASE_KIND_WORK do s.work += 1
		else if l.phase != domain.LEASE_PHASE_WAITING do s.review += 1
	}
	for inst in ctx.instances do if instance_in_grace(svc, ctx, u, inst) do s.grace += 1
	return s
}

// instance_slot_counted: the instance already occupies a chain slot, so a grant
// to it is net zero for the total: it holds a work lease or an active review
// lease, or it is a grace instance (G).
@(private = "package")
instance_slot_counted :: proc(svc: ^Service, ctx: ^Match_Context, u: ^Uow, inst: domain.Agent_Instance) -> bool {
	for l in ctx.leases {
		if l.holder_instance_id != inst.agent_instance_id do continue
		if l.kind == domain.LEASE_KIND_WORK || l.phase != domain.LEASE_PHASE_WAITING do return true
	}
	return instance_in_grace(svc, ctx, u, inst)
}

// chain_cap_refusal checks one grant against the chain cap on the counts AFTER
// the grant (REQ-SCHED-34). `counted`: the target already occupies a slot.
// "" means the grant may proceed. A review that does not fit while a grace
// instance of another agent exists may take that instance's slot: when
// `yield_victim` is given, the instance to stop is written there and the
// caller stops it with yield_grace_slot only AFTER its grant succeeded, so a
// failed grant never stops a grace instance for nothing. Active and waiting
// work is never evicted. The coordinator is outside the cap.
chain_cap_refusal :: proc(svc: ^Service, ctx: ^Match_Context, u: ^Uow, inst: domain.Agent_Instance, counted: bool, kind: string, task: domain.Task, yield_victim: ^domain.Agent_Instance = nil) -> string {
	m, r := chain_cap_limits(ctx.chain)
	if m == 0 do return ""
	if inst.agent_instance_id != "" && ctx_is_coordinator(svc, ctx, inst.agent_instance_id) do return ""
	s := chain_slots(svc, ctx, u)
	if kind == domain.LEASE_KIND_WORK {
		// Re-activating the holder's own work claim leaves W unchanged.
		reactivation := false
		for l in ctx.leases do if l.task_id == task.task_id && l.kind == domain.LEASE_KIND_WORK && l.holder_instance_id == inst.agent_instance_id { reactivation = true; break }
		if !reactivation && s.work + 1 > m - r do return fmt.tprintf("chain work limit reached (%d work of max_parallel %d with review_reserve %d)", s.work, m, r)
	}
	if counted do return ""
	if s.work + s.review + s.grace + 1 <= m do return ""
	if kind == domain.LEASE_KIND_REVIEW && s.grace > 0 && yield_victim != nil {
		if victim, found := grace_victim(svc, ctx, u, inst.agent_id); found {
			yield_victim^ = victim
			return ""
		}
	}
	return fmt.tprintf("chain cap full (%d of max_parallel %d occupied)", s.work + s.review + s.grace, m)
}

// grace_victim: the grace instance of another agent that has been lease-free
// the longest, whose slot a pending review may take.
@(private = "file")
grace_victim :: proc(svc: ^Service, ctx: ^Match_Context, u: ^Uow, for_agent: string) -> (domain.Agent_Instance, bool) {
	best := -1
	for inst, i in ctx.instances {
		if inst.agent_id == for_agent || !instance_in_grace(svc, ctx, u, inst) do continue
		if best < 0 || grace_older(inst, ctx.instances[best]) do best = i
	}
	if best < 0 do return {}, false
	return ctx.instances[best], true
}

// yield_grace_slot stops the instance chain_cap_refusal chose, after the
// review that needed its slot was granted (stop intent first, REQ-SCHED-28).
yield_grace_slot :: proc(svc: ^Service, ctx: ^Match_Context, u: ^Uow, victim: domain.Agent_Instance) {
	if victim.agent_instance_id == "" do return
	if stopped, err := stop_instance_in_uow(svc, u, victim, string(ctx.chain.chain_id), STOP_REASON_CAPACITY_YIELD); !stopped {
		fmt.eprintfln("[taskv2] capacity yield: stopping %s failed: %s", victim.agent_instance_id, err.message)
	}
}

@(private = "file")
grace_older :: proc(a, b: domain.Agent_Instance) -> bool {
	if a.idle_since != b.idle_since {
		if a.idle_since == "" do return false
		if b.idle_since == "" do return true
		return a.idle_since < b.idle_since
	}
	return a.agent_instance_id < b.agent_instance_id
}

// ---- instance choice across bridges (REQ-SCHED-30..33) ---------------------------------

// placement_restriction: the only bridge a grant may use, or "" when any
// bridge may be used. A task pin (work only) or a fleet-row bridge_id wins
// over reuse (REQ-SCHED-31).
placement_restriction :: proc(task: domain.Task, fleet: domain.Task_Chain_Fleet, honour_pin: bool) -> string {
	if honour_pin {
		if pin := strings.trim_space(task.bridge_id); pin != "" do return pin
	}
	return strings.trim_space(fleet.bridge_id)
}

Reuse_Scan :: struct {
	occupied:      int, // REQ-SCHED-33: instances holding a lease or live/starting, all bridges
	held:          int, // instances holding a lease, all bridges
	capacity:      int,
	live:          domain.Agent_Instance, // rank 2: live lease-free, not stopping
	warm:          domain.Agent_Instance, // rank 3: stopped reusable
	stopping:      domain.Agent_Instance, // rank 4
	have_live, have_warm, have_stopping: bool,
	preferred:     domain.Agent_Instance,
	have_pref:     bool,
	// failure: a free instance that must not be replaced (user-stopped, Hold,
	// a pending runtime action). With no candidate it blocks a new instance
	// and names the Start agent card reason (REQ-SCHED-32). A Dead instance
	// (terminated, or failed without a typed error) does not: an agent with
	// only Dead instances gets a new one (REQ-SCHED-30 (5)).
	failure:       string,
	// unusable: a free instance that could not be reused because of its
	// bridge (offline, ineligible, provider, busy directory); recorded with
	// the grant (REQ-SCHED-31).
	unusable:      string,
	retry_due_ms:  i64,
}

// bridge_reuse_problem: why a free instance on `bridge_id` cannot take the
// grant ("" when it can). The same checks a new instance gets, on its bridge.
@(private = "package")
bridge_reuse_problem :: proc(svc: ^Service, ctx: ^Match_Context, fleet: domain.Task_Chain_Fleet, bridge_id: string, kind: string) -> string {
	p := placement_on_bridge(ctx, fleet, bridge_id)
	if reason, message := placement_problem(svc, ctx, p, true, fleet.agent_id); reason != "" do return message
	if kind == domain.LEASE_KIND_WORK && p.directory_id != "" && directory_has_work_lease_ctx(ctx, p.directory_id) do return "another work lease is live on its chain directory"
	return ""
}

// reuse_scan is the read-only part of instance choice. `u` (may be nil) only
// informs which instances this unit of work is stopping. `arm_retry` arms the
// rematch for an instance in provider backoff (matcher only).
reuse_scan :: proc(svc: ^Service, u: ^Uow, ctx: ^Match_Context, task: domain.Task, fleet: domain.Task_Chain_Fleet, restrict, preferred_bridge, kind, prefer: string) -> Reuse_Scan {
	scan := Reuse_Scan{capacity = max(1, fleet.capacity)}
	better :: proc(cand, cur: domain.Agent_Instance, have: bool, preferred_bridge: string) -> bool {
		if !have do return true
		return cand.bridge_id == preferred_bridge && cur.bridge_id != preferred_bridge
	}
	for inst in ctx.instances {
		if inst.agent_id != fleet.agent_id do continue
		if ctx_is_coordinator(svc, ctx, inst.agent_instance_id) do continue
		in_scope := restrict == "" || inst.bridge_id == restrict
		// A lease holder always occupies its slot, whatever its runtime state
		// (a failed holder keeps its waiting claim).
		held := ctx.held[inst.agent_instance_id]
		if held { scan.held += 1; scan.occupied += 1 }
		if busy, err := iface.agent_runtime_busy(svc.agents, inst.agent_instance_id); busy || err.code != .None {
			if !held do scan.occupied += 1
			if in_scope && !held do scan.failure = "instance has a pending runtime action"
			continue
		}
		// A person stopped this instance: never re-woken, re-granted or
		// replaced, and not counted (REQ-SCHED-32, F4).
		if inst.stopped_by == agent.STOPPED_BY_USER {
			if in_scope && !held do scan.failure = fmt.tprintf("instance %s was stopped by the user", inst.agent_instance_id)
			continue
		}
		disposition := agent.failed_instance_disposition(inst, ctx.now_ms)
		if disposition == .Hold {
			if werr, typed := agent.instance_last_error(inst); typed && werr.class == .retriable {
				// Provider backoff: occupies its slot and is retried at its deadline.
				if !held do scan.occupied += 1
				if in_scope && !held {
					due := to_ms(inst.stopped_at) + agent.instance_retry_delay_ms(agent.instance_last_error_attempt(inst), werr.retry_after_ms)
					if scan.retry_due_ms == 0 || due < scan.retry_due_ms do scan.retry_due_ms = due
				}
				continue
			}
		}
		if disposition == .Dead do continue
		if disposition == .Hold {
			if in_scope && !held do scan.failure = instance_failure_reason(inst)
			continue
		}
		live := instance_is_live(inst) || instance_is_pending(inst)
		if !held && live do scan.occupied += 1
		if held || !in_scope do continue
		if why := bridge_reuse_problem(svc, ctx, fleet, inst.bridge_id, kind); why != "" {
			if scan.unusable == "" do scan.unusable = fmt.tprintf("instance %s on bridge %s: %s", inst.agent_instance_id, inst.bridge_id, why)
			continue
		}
		if prefer != "" && inst.agent_instance_id == prefer { scan.preferred = inst; scan.have_pref = true }
		if live {
			if instance_stopping(ctx, u, inst) {
				if better(inst, scan.stopping, scan.have_stopping, preferred_bridge) { scan.stopping = inst; scan.have_stopping = true }
			} else if better(inst, scan.live, scan.have_live, preferred_bridge) {
				scan.live = inst; scan.have_live = true
			}
		} else if better(inst, scan.warm, scan.have_warm, preferred_bridge) {
			scan.warm = inst; scan.have_warm = true
		}
	}
	return scan
}

// reuse_scan_has_candidate: an existing instance can take the grant now.
reuse_scan_has_candidate :: proc(scan: Reuse_Scan) -> bool {
	below := scan.occupied < scan.capacity
	within := scan.held < scan.capacity
	if scan.have_pref && (instance_is_live(scan.preferred) || instance_is_pending(scan.preferred)) && within do return true
	if scan.have_pref && below do return true
	return ((scan.have_live || scan.have_stopping) && within) || (scan.have_warm && below)
}

// agent_occupied_count: REQ-SCHED-33 for one agent, over all bridges: its
// chain instances that hold a lease, are live or starting, have a pending
// runtime action or are in provider backoff. User-stopped instances and the
// coordinator are not counted.
agent_occupied_count :: proc(svc: ^Service, ctx: ^Match_Context, agent_id: string) -> int {
	n := 0
	for inst in ctx.instances {
		if inst.agent_id != agent_id || ctx_is_coordinator(svc, ctx, inst.agent_instance_id) do continue
		if ctx.held[inst.agent_instance_id] { n += 1; continue }
		if busy, err := iface.agent_runtime_busy(svc.agents, inst.agent_instance_id); busy || err.code != .None { n += 1; continue }
		if inst.stopped_by == agent.STOPPED_BY_USER do continue
		disposition := agent.failed_instance_disposition(inst, ctx.now_ms)
		if disposition == .Hold {
			if werr, typed := agent.instance_last_error(inst); typed && werr.class == .retriable { n += 1; continue }
		}
		if disposition == .Dead || disposition == .Hold do continue
		if instance_is_live(inst) || instance_is_pending(inst) do n += 1
	}
	return n
}
