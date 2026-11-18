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

Coordinator_Wake_Sender_Window :: struct { window_start_ms: i64, count: int }
Coordinator_Wake_Guard :: struct {
	mutex: sync.Mutex,
	last_target_ms: map[string]i64,
	sender_windows: map[string]Coordinator_Wake_Sender_Window,
}
coordinator_wake_guard: Coordinator_Wake_Guard

coordinator_wake_guard_try :: proc(sender_id, target_id: string, now_ms: i64) -> bool {
	sync.mutex_lock(&coordinator_wake_guard.mutex)
	defer sync.mutex_unlock(&coordinator_wake_guard.mutex)
	// Request arenas must never own global maps or their keys.
	context.allocator = runtime.heap_allocator()
	g := &coordinator_wake_guard
	if last, exists := g.last_target_ms[target_id]; exists && now_ms - last < COORDINATOR_WAKE_TARGET_MIN_INTERVAL_MS do return false
	window, exists := g.sender_windows[sender_id]
	if !exists || now_ms - window.window_start_ms >= COORDINATOR_WAKE_SENDER_WINDOW_MS do window = {now_ms, 0}
	if window.count >= COORDINATOR_WAKE_SENDER_MAX_PER_HOUR do return false
	if g.last_target_ms == nil do g.last_target_ms = make(map[string]i64)
	if g.sender_windows == nil do g.sender_windows = make(map[string]Coordinator_Wake_Sender_Window)
	target_key := target_id
	if _, found := g.last_target_ms[target_id]; !found do target_key = strings.clone(target_id)
	sender_key := sender_id
	if !exists do sender_key = strings.clone(sender_id)
	g.last_target_ms[target_key] = now_ms
	window.count += 1
	g.sender_windows[sender_key] = window
	return true
}

// Tests only; keep the mutex itself intact.
coordinator_wake_guard_reset :: proc() {
	sync.mutex_lock(&coordinator_wake_guard.mutex)
	defer sync.mutex_unlock(&coordinator_wake_guard.mutex)
	context.allocator = runtime.heap_allocator()
	g := &coordinator_wake_guard
	for key in g.last_target_ms do delete(key)
	for key in g.sender_windows do delete(key)
	delete(g.last_target_ms)
	delete(g.sender_windows)
	g.last_target_ms = nil
	g.sender_windows = nil
}

coordinator_wake_after_agent_message :: proc(h: ^Agent_Action_Handlers, auth: contracts.Auth_Context, sender: domain.Agent_Instance, target_instance_id, conversation_id: string, now_ms: i64) -> Coordinator_Wake_Outcome {
	outcome := Coordinator_Wake_Outcome.Failed
	code := domain.Error_Code.Internal_Error
	defer {
		switch outcome {
		case .Started: fmt.printf("coordinator_wake: started target=%s sender=%s\n", target_instance_id, sender.agent_instance_id)
		case .Not_Coordinator, .User_Stopped, .Rate_Limited:
			fmt.printf("coordinator_wake: skipped reason=%s target=%s sender=%s\n", coordinator_wake_outcome_string(outcome), target_instance_id, sender.agent_instance_id)
		case .Failed: fmt.printf("coordinator_wake: failed target=%s sender=%s code=%s\n", target_instance_id, sender.agent_instance_id, code)
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
	if target.runtime_status != "stopped" && target.runtime_status != "failed" && target.runtime_status != "unreachable" {
		outcome = .Not_Needed; return outcome
	}
	outcome = .Not_Coordinator
	if target.kind != "agent" do return outcome
	// Spec assumption fallback: the repository proc is agent_get, not agent_get_agent.
	agent, agent_ok, agent_err := agent_service.get_agent(h.agents, auth, target.agent_id)
	if !agent_ok { outcome = .Failed; code = agent_err.code; return outcome }
	if agent.template_id == domain.TEMPLATE_BOT_ID do return outcome
	if h.taskchains == nil do return outcome
	chains, chains_err := iface.taskchain_list_chains_by_coordinator(h.taskchains.repo, target_instance_id, domain.User_ID(auth.user_id))
	if chains_err.code != .None { outcome = .Failed; code = chains_err.code; return outcome }
	active := false
	for chain in chains do if chain.status == .Active { active = true; break }
	if !active do return outcome
	outcome = .User_Stopped
	if target.stopped_by == agent_service.STOPPED_BY_USER do return outcome
	outcome = .Rate_Limited
	if !coordinator_wake_guard_try(sender.agent_instance_id, target_instance_id, now_ms) do return outcome
	ch := Content_Handlers{auth = h.auth, agents = h.agents, content = h.content, event_bus = h.event_bus}
	restarted, restart_err := restart_stopped_conversation_instance(&ch, auth, conversation_id)
	if !restarted { outcome = .Failed; code = restart_err.code; return outcome }
	outcome = .Started
	return outcome
}
