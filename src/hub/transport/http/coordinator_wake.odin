package http

import "core:fmt"
import virtual "core:mem/virtual"
import "base:runtime"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import agent_service "odin_test:hub/service/agent"
import taskv2 "odin_test:hub/service/taskv2"
import content_service "odin_test:hub/service/content"

Coordinator_Wake_Outcome :: enum {
	Not_Needed, Started, Not_Coordinator, User_Stopped, Rate_Limited, Failed,
}

coordinator_wake_outcome_string :: proc(o: Coordinator_Wake_Outcome) -> string {
	switch o {
	case .Not_Needed: return "not_needed"
	case .Started: return "started"
	case .Not_Coordinator: return "not_coordinator"
	case .User_Stopped: return "user_stopped"
	case .Rate_Limited: return "rate_limited"
	case .Failed: return "failed"
	}
	unreachable()
}

COORDINATOR_WAKE_TARGET_MIN_INTERVAL_MS :: 120_000
COORDINATOR_WAKE_SENDER_MAX_PER_HOUR :: 20
COORDINATOR_WAKE_SENDER_WINDOW_MS :: 3_600_000

// Both maps have bounded storage even during an unbounded stream of new IDs.
COORDINATOR_WAKE_GUARD_SWEEP_INTERVAL_MS :: 60_000
COORDINATOR_WAKE_GUARD_MAX_ENTRIES :: 4096

Coordinator_Wake_Sender_Window :: struct { window_start_ms: i64, count: int }
Coordinator_Wake_Guard :: struct {
	mutex: sync.Mutex,
	last_target_ms: map[string]i64,
	sender_windows: map[string]Coordinator_Wake_Sender_Window,
	last_sweep_ms: i64,
}
coordinator_wake_guard: Coordinator_Wake_Guard

coordinator_wake_guard_try :: proc(sender_id, target_id: string, now_ms: i64) -> bool {
	sync.mutex_lock(&coordinator_wake_guard.mutex)
	defer sync.mutex_unlock(&coordinator_wake_guard.mutex)
	// Request arenas must never own global maps or their keys.
	context.allocator = runtime.heap_allocator()
	return coordinator_wake_guard_try_locked(&coordinator_wake_guard, sender_id, target_id, now_ms)
}

// The caller owns g exclusively (or holds its mutex) and supplies the allocator
// that owns its maps and keys. Tests use a local guard with a tracking allocator.
coordinator_wake_guard_try_locked :: proc(g: ^Coordinator_Wake_Guard, sender_id, target_id: string, now_ms: i64) -> bool {
	if now_ms - g.last_sweep_ms >= COORDINATOR_WAKE_GUARD_SWEEP_INTERVAL_MS ||
	   len(g.last_target_ms) >= COORDINATOR_WAKE_GUARD_MAX_ENTRIES ||
	   len(g.sender_windows) >= COORDINATOR_WAKE_GUARD_MAX_ENTRIES {
		coordinator_wake_guard_evict_expired(g, now_ms)
		g.last_sweep_ms = now_ms
	}
	last, target_exists := g.last_target_ms[target_id]
	if target_exists && now_ms - last < COORDINATOR_WAKE_TARGET_MIN_INTERVAL_MS do return false
	window, sender_exists := g.sender_windows[sender_id]
	if !sender_exists || now_ms - window.window_start_ms >= COORDINATOR_WAKE_SENDER_WINDOW_MS do window = {now_ms, 0}
	if window.count >= COORDINATOR_WAKE_SENDER_MAX_PER_HOUR do return false
	// Fail closed when every slot holds live rate-limit state. Never discard an
	// unexpired entry to admit a new ID, which would let callers bypass limits.
	if !target_exists && len(g.last_target_ms) >= COORDINATOR_WAKE_GUARD_MAX_ENTRIES do return false
	if !sender_exists && len(g.sender_windows) >= COORDINATOR_WAKE_GUARD_MAX_ENTRIES do return false
	if g.last_target_ms == nil do g.last_target_ms = make(map[string]i64)
	if g.sender_windows == nil do g.sender_windows = make(map[string]Coordinator_Wake_Sender_Window)
	target_key := target_id
	if !target_exists do target_key = strings.clone(target_id)
	sender_key := sender_id
	if !sender_exists do sender_key = strings.clone(sender_id)
	g.last_target_ms[target_key] = now_ms
	window.count += 1
	g.sender_windows[sender_key] = window
	return true
}

// coordinator_wake_guard_next_allowed: the earliest time at which
// coordinator_wake_guard_try(sender_id, target_id) can succeed, given the
// current state (now_ms when nothing blocks it). Does not record anything.
coordinator_wake_guard_next_allowed :: proc(sender_id, target_id: string, now_ms: i64) -> i64 {
	sync.mutex_lock(&coordinator_wake_guard.mutex)
	defer sync.mutex_unlock(&coordinator_wake_guard.mutex)
	return coordinator_wake_guard_next_allowed_locked(&coordinator_wake_guard, sender_id, target_id, now_ms)
}

coordinator_wake_guard_next_allowed_locked :: proc(g: ^Coordinator_Wake_Guard, sender_id, target_id: string, now_ms: i64) -> i64 {
	at := now_ms
	if last, ok := g.last_target_ms[target_id]; ok do at = max(at, last + COORDINATOR_WAKE_TARGET_MIN_INTERVAL_MS)
	if window, ok := g.sender_windows[sender_id]; ok && window.count >= COORDINATOR_WAKE_SENDER_MAX_PER_HOUR {
		at = max(at, window.window_start_ms + COORDINATOR_WAKE_SENDER_WINDOW_MS)
	}
	return at
}

// coordinator_wake_guard_release undoes the slot one attempt took at
// stamped_ms when the restart itself failed transiently, so the retry is not
// throttled by an attempt that started nothing. A newer stamp is left alone.
coordinator_wake_guard_release :: proc(sender_id, target_id: string, stamped_ms: i64) {
	sync.mutex_lock(&coordinator_wake_guard.mutex)
	defer sync.mutex_unlock(&coordinator_wake_guard.mutex)
	context.allocator = runtime.heap_allocator()
	coordinator_wake_guard_release_locked(&coordinator_wake_guard, sender_id, target_id, stamped_ms)
}

coordinator_wake_guard_release_locked :: proc(g: ^Coordinator_Wake_Guard, sender_id, target_id: string, stamped_ms: i64) {
	last, ok := g.last_target_ms[target_id]
	if !ok || last != stamped_ms do return
	key, _ := delete_key(&g.last_target_ms, target_id)
	delete(key)
	if window, wok := &g.sender_windows[sender_id]; wok && window.count > 0 do window.count -= 1
}

// Expired state is equivalent to an absent entry. Collect keys before removing
// them: map deletion can move entries and invalidate an ongoing iteration.
coordinator_wake_guard_evict_expired :: proc(g: ^Coordinator_Wake_Guard, now_ms: i64) {
	expired := make([dynamic]string)
	defer delete(expired)
	for key, last in g.last_target_ms {
		if now_ms - last >= COORDINATOR_WAKE_TARGET_MIN_INTERVAL_MS do append(&expired, key)
	}
	for key in expired {
		delete_key(&g.last_target_ms, key)
		delete(key)
	}
	clear(&expired)
	for key, window in g.sender_windows {
		if now_ms - window.window_start_ms >= COORDINATOR_WAKE_SENDER_WINDOW_MS do append(&expired, key)
	}
	for key in expired {
		delete_key(&g.sender_windows, key)
		delete(key)
	}
}

// Exclusive access and the owning allocator are required, as for eviction.
coordinator_wake_guard_destroy :: proc(g: ^Coordinator_Wake_Guard) {
	for key in g.last_target_ms do delete(key)
	for key in g.sender_windows do delete(key)
	delete(g.last_target_ms)
	delete(g.sender_windows)
	g.last_target_ms = nil
	g.sender_windows = nil
	g.last_sweep_ms = 0
}

// Tests only; keep the mutex itself intact.
coordinator_wake_guard_reset :: proc() {
	sync.mutex_lock(&coordinator_wake_guard.mutex)
	defer sync.mutex_unlock(&coordinator_wake_guard.mutex)
	context.allocator = runtime.heap_allocator()
	coordinator_wake_guard_destroy(&coordinator_wake_guard)
}

// Coordinator_Wake_Chains: which chain statuses make a stopped coordinator
// worth starting. Agent messages wake only Active chains; [taskv2] notices also
// reach Completed chains (a review or reopen notice after the chain finished).
Coordinator_Wake_Chains :: enum { Active_Only, Active_Or_Completed }

// Coordinator_Wake_Detail: what one attempt saw, for callers that retry.
Coordinator_Wake_Detail :: struct {
	live:         bool, // running/idle/busy/blocked: the notice can be delivered
	transitional: bool, // launching/starting/stopping: wait for it to settle
	guard_taken:  bool, // this attempt recorded a wake in the rate guard
	code:         domain.Error_Code,
}

COORDINATOR_WAKE_TASK_NOTICE_SENDER :: "taskv2"
// A transient restart failure is retried after this delay.
COORDINATOR_WAKE_TRANSIENT_RETRY_MS :: i64(30_000)

coordinator_wake_after_agent_message :: proc(h: ^Agent_Action_Handlers, auth: contracts.Auth_Context, sender: domain.Agent_Instance, target_instance_id, conversation_id: string, now_ms: i64) -> Coordinator_Wake_Outcome {
	return coordinator_wake_stopped_instance(h, auth, target_instance_id, conversation_id, sender.agent_instance_id, sender.agent_instance_id, .Active_Only, now_ms)
}

// coordinator_wake_after_task_notice (REQ-CIS-2): a [taskv2] coordinator notice
// was sent to a coordinator that may be stopped. The bridge holds the notice
// until the PTY is alive, so starting the instance is all that delivery needs.
// Runs after the taskv2 commit, off every taskv2 lock (taskv2 drains these on
// its timer thread). The same rules as the agent-message wake apply: never a
// user-stopped instance, never a bot, and at most one start per target per
// COORDINATOR_WAKE_TARGET_MIN_INTERVAL_MS. The sender window is per target
// ("taskv2:<target>") so one busy chain cannot use up the wakes of another.
//
// The reply tells taskv2 whether to keep the wake: a rate-limited wake comes
// back when the guard allows it, a stopping/launching coordinator is checked
// again until it settles, and a transient restart failure releases its guard
// slot and is retried. Only a start or a permanent "no" settles the wake.
coordinator_wake_after_task_notice :: proc(h: ^Agent_Action_Handlers, owner, target_instance_id: string, now_ms: i64) -> (Coordinator_Wake_Outcome, taskv2.Coordinator_Wake_Reply) {
	auth := contracts.Auth_Context{kind = .Internal_User, user_id = owner}
	sender_key := strings.concatenate({COORDINATOR_WAKE_TASK_NOTICE_SENDER, ":", target_instance_id}, context.temp_allocator)
	detail: Coordinator_Wake_Detail
	outcome := coordinator_wake_stopped_instance(h, auth, target_instance_id, "", COORDINATOR_WAKE_TASK_NOTICE_SENDER, sender_key, .Active_Or_Completed, now_ms, &detail)
	reply := taskv2.Coordinator_Wake_Reply{}
	switch outcome {
	case .Started, .Not_Coordinator, .User_Stopped:
		reply.settled = true
	case .Not_Needed:
		// Live: the bridge delivers; taskv2 only watches for a stop that races
		// the delivery. Transitional: check again on the next tick.
		reply.live = detail.live
		reply.settled = !detail.live && !detail.transitional
	case .Rate_Limited:
		reply.retry_at_ms = coordinator_wake_guard_next_allowed(sender_key, target_instance_id, now_ms)
	case .Failed:
		if !coordinator_wake_transient_error(detail.code) {
			reply.settled = true
		} else {
			if detail.guard_taken do coordinator_wake_guard_release(sender_key, target_instance_id, now_ms)
			reply.retry_at_ms = now_ms + COORDINATOR_WAKE_TRANSIENT_RETRY_MS
		}
	}
	return outcome, reply
}

// coordinator_wake_transient_error: a restart failure worth retrying later.
coordinator_wake_transient_error :: proc(code: domain.Error_Code) -> bool {
	#partial switch code {
	case .Conflict, .Bridge_Offline, .Bridge_Busy, .Bridge_Timeout, .Rate_Limited,
	     .Provider_Unavailable, .Instance_Not_Running, .Internal_Error, .ACP_Installing, .Vault_Locked:
		return true
	}
	return false
}

// coordinator_wake_stopped_instance wakes a chain
// coordinator through restart_stopped_conversation_instance. An empty
// conversation_id resolves to the instance's own conversation.
coordinator_wake_stopped_instance :: proc(h: ^Agent_Action_Handlers, auth: contracts.Auth_Context, target_instance_id, conversation_id, sender_label, sender_key: string, chains_scope: Coordinator_Wake_Chains, now_ms: i64, detail: ^Coordinator_Wake_Detail = nil) -> Coordinator_Wake_Outcome {
	outcome := Coordinator_Wake_Outcome.Failed
	code := domain.Error_Code.Internal_Error
	scratch_detail: Coordinator_Wake_Detail
	d := detail if detail != nil else &scratch_detail
	d^ = {}
	defer {
		if outcome == .Failed do d.code = code
		switch outcome {
		case .Started: fmt.printf("coordinator_wake: started target=%s sender=%s\n", target_instance_id, sender_label)
		case .Not_Coordinator, .User_Stopped, .Rate_Limited:
			fmt.printf("coordinator_wake: skipped reason=%s target=%s sender=%s\n", coordinator_wake_outcome_string(outcome), target_instance_id, sender_label)
		case .Failed: fmt.printf("coordinator_wake: failed target=%s sender=%s code=%s\n", target_instance_id, sender_label, code)
		case .Not_Needed:
		}
	}
	// Repository records and the existing restart helper allocate nested records.
	// Give this synchronous operation its own arena, including all error paths.
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	if h.agents == nil do return outcome
	target, found, err := iface.agent_get_instance(h.agents.agents, target_instance_id)
	if !found { code = err.code; return outcome }
	defer domain.agent_instance_destroy(&target)
	if target.owner_user_id != domain.User_ID(auth.user_id) { code = .Not_Found; return outcome }
	outcome = .Not_Coordinator
	if target.kind != "agent" do return outcome
	// Spec assumption fallback: the repository proc is agent_get, not agent_get_agent.
	agent, agent_ok, agent_err := agent_service.get_agent(h.agents, auth, target.agent_id)
	if !agent_ok { outcome = .Failed; code = agent_err.code; return outcome }
	if agent.template_id == domain.TEMPLATE_BOT_ID do return outcome
	if h.taskchains == nil do return outcome
	chains, chains_err := iface.taskchain_list_chains_by_coordinator(h.taskchains.repo, target_instance_id, domain.User_ID(auth.user_id))
	if chains_err.code != .None { outcome = .Failed; code = chains_err.code; return outcome }
	eligible := false
	for chain in chains {
		if chain.status == .Active || (chains_scope == .Active_Or_Completed && chain.status == .Completed) { eligible = true; break }
	}
	if !eligible do return outcome
	outcome = .User_Stopped
	if target.stopped_by == agent_service.STOPPED_BY_USER do return outcome
	fact := agent_service.agent_liveness(h.agents, target)
	if fact.reason == .retired { outcome = .Not_Needed; return outcome }
	if fact.state == .Alive {
		d.live = fact.ready
		d.transitional = !fact.ready
		outcome = .Not_Needed; return outcome
	}
	if fact.state == .Unknown && fact.reason != .never_started {
		outcome = .Failed; code = .Bridge_Busy; return outcome
	}
	cid := conversation_id
	if cid == "" do cid = target.conversation_id
	if cid == "" && h.content != nil {
		if conv, conv_ok, _ := content_service.get_conversation_by_instance(h.content, auth, target_instance_id); conv_ok do cid = conv.conversation_id
	}
	if cid == "" { outcome = .Failed; code = .Not_Found; return outcome }
	outcome = .Rate_Limited
	if !coordinator_wake_guard_try(sender_key, target_instance_id, now_ms) do return outcome
	d.guard_taken = true
	ch := Content_Handlers{auth = h.auth, agents = h.agents, content = h.content, event_bus = h.event_bus}
	guard := Coordinator_Start_Guard{agents=h.agents, auth=auth, instance_id=target_instance_id}
	restarted, restart_err := restart_stopped_conversation_instance(&ch, auth, cid, &guard, coordinator_start_guard)
	if !restarted { if guard.user_stopped { outcome = .User_Stopped; return outcome }; outcome = .Failed; code = restart_err.code; return outcome }
	outcome = .Started
	return outcome
}


// Recheck the policy inside reconfiguration_mutex, after any concurrent stop.
Coordinator_Start_Guard :: struct { agents: ^agent_service.Agent_Service, auth: contracts.Auth_Context, instance_id: string, user_stopped: bool }
coordinator_start_guard :: proc(ctx: rawptr) -> domain.Domain_Error {
 g := (^Coordinator_Start_Guard)(ctx)
 inst, ok, err := agent_service.get_instance(g.agents, g.auth, g.instance_id)
 if !ok do return err
 defer domain.agent_instance_destroy(&inst)
 if inst.stopped_by == agent_service.STOPPED_BY_USER {
  g.user_stopped = true
  return domain.domain_error(.Conflict, "coordinator was stopped by user")
 }
 return {}
}
