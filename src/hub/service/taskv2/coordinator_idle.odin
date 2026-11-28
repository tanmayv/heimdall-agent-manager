package taskv2

import "core:fmt"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import agent "odin_test:hub/service/agent"

// Coordinator idle-stop timers (chain chain_18e9f7d582943fe0, REQ-CIS-1..5).
//
// Two hub-wide timers stop an idle chain coordinator:
//   * X (Coordinator_Idle_Completed, Service.coordinator_idle_completed_seconds):
//     X after the last user event, while every chain it coordinates is closed
//     and at least one is Completed;
//   * Y (Coordinator_Idle, Service.coordinator_idle_seconds): Y after the last
//     user event, whatever the chain status (Solo chains included).
// 0 disables a timer.
//
// Both measure from agent_instances.user_activity_at, a durable stamp that
// ONLY user events move (note_user_activity / note_chain_user_activity): user
// chat to the instance, answers to its questions and action cards, a user's
// verdict on a chain task (including review post --on-behalf-of user) and a
// user's requirement change on a chain task. Heartbeats, UI reads, agent
// output, [taskv2] notices, agent-to-agent messages and leases never touch it.
//
// Like every taskv2 timer the heap is a cache over columns: key = instance id,
// armed = the stamp the timer was armed from. At fire time the stamp, the
// instance and the chain status are re-read; a moved stamp, a stopped or
// user-stopped instance, or (X) an Active chain makes the fire a no-op. The
// guards (REQ-CIS-3: busy, a live lease, unread user input, the start grace)
// defer the stop and re-arm a retry. The stop itself is agent.stop_instance_confirmed,
// called after the unit of work commits, with a reason that does not start
// with "user" so stopped_by stays clear and the existing wakes still apply.

COORDINATOR_IDLE_REASON_COMPLETED :: agent.STOP_COORDINATOR_IDLE_DONE
COORDINATOR_IDLE_REASON           :: agent.STOP_COORDINATOR_IDLE
// A guarded fire retries after this delay.
COORDINATOR_IDLE_RETRY_SECONDS    :: 60
// A coordinator that (re)started this recently is never idle-stopped yet: a
// relaunch for a [taskv2] notice must get to read the notice first. This is a
// guard (it defers the stop), not a reset.
COORDINATOR_IDLE_START_GRACE_SECONDS :: 10 * 60

Coordinator_Idle_Stop :: struct {
	owner:       domain.User_ID,
	instance_id: string,
	reason:      agent.Stop_Reason,
	kind:        Timer_Kind,
	armed:       string,
}

// coordinator_idle_seconds_for: the configured duration of an idle timer kind.
coordinator_idle_seconds_for :: proc(svc: ^Service, kind: Timer_Kind) -> int {
	#partial switch kind {
	case .Coordinator_Idle_Completed: return svc.coordinator_idle_completed_seconds
	case .Coordinator_Idle:           return svc.coordinator_idle_seconds
	}
	return 0
}

coordinator_idle_enabled :: proc(svc: ^Service) -> bool {
	return svc != nil && (svc.coordinator_idle_completed_seconds > 0 || svc.coordinator_idle_seconds > 0)
}

// coordinated_chains: the chains whose coordinator member is this instance.
coordinated_chains :: proc(svc: ^Service, inst: domain.Agent_Instance) -> []domain.Task_Chain {
	chains, err := iface.taskchain_list_chains_by_coordinator(svc.repo, inst.agent_instance_id, inst.owner_user_id)
	if err.code != .None do return nil
	return chains
}

// chains_idle_completed: X applies only when nothing the instance coordinates
// is still Active and at least one chain is Completed.
chains_idle_completed :: proc(chains: []domain.Task_Chain) -> bool {
	completed := false
	for c in chains {
		if c.status == .Active do return false
		if c.status == .Completed do completed = true
	}
	return completed
}

// coordinator_activity_stamp returns the instance's user-activity stamp. A
// coordinator that never had a user event is seeded ONCE with now, so a hub
// upgrade gives every existing coordinator a full X/Y rather than stopping it
// at the first tick. The seed is durable, so a restart does not extend it.
coordinator_activity_stamp :: proc(svc: ^Service, instance_id: string) -> string {
	stamp, found, err := iface.agent_get_user_activity(svc.agents, instance_id)
	if !found || err.code != .None do return ""
	if stamp != "" do return stamp
	now := platform.clock_now(svc.clock)
	_, _ = iface.agent_touch_user_activity(svc.agents, instance_id, now)
	stamp, found, err = iface.agent_get_user_activity(svc.agents, instance_id)
	if !found || err.code != .None do return ""
	return stamp
}

// arm_coordinator_idle arms both idle timers for a coordinator from `stamp`.
// X is armed regardless of the current chain status: its fire re-checks the
// status, and completion re-arms it (arm_coordinator_idle_for_chain).
arm_coordinator_idle :: proc(svc: ^Service, instance_id, stamp: string) {
	if svc == nil || instance_id == "" || stamp == "" do return
	base := to_ms(stamp)
	if base == 0 do return
	if x := svc.coordinator_idle_completed_seconds; x > 0 {
		timers_arm(svc, .Coordinator_Idle_Completed, instance_id, base + i64(x) * 1000, stamp)
	}
	if y := svc.coordinator_idle_seconds; y > 0 {
		timers_arm(svc, .Coordinator_Idle, instance_id, base + i64(y) * 1000, stamp)
	}
}

// arm_coordinator_idle_instance arms the idle timers for a live coordinator
// from its CURRENT stamp (no reset). Used at boot, on start-success and when a
// chain completes.
arm_coordinator_idle_instance :: proc(svc: ^Service, inst: domain.Agent_Instance) {
	if !coordinator_idle_enabled(svc) || inst.agent_instance_id == "" do return
	if len(coordinated_chains(svc, inst)) == 0 do return
	arm_coordinator_idle(svc, inst.agent_instance_id, coordinator_activity_stamp(svc, inst.agent_instance_id))
}

// arm_coordinator_idle_for_chain (re)arms the idle timers of every coordinator
// of a chain, e.g. after it completed (X re-arm on re-complete).
arm_coordinator_idle_for_chain :: proc(svc: ^Service, chain: domain.Task_Chain) {
	if !coordinator_idle_enabled(svc) do return
	for id in chain_coordinator_instance_ids(svc, chain) {
		if inst, ok, _ := iface.agent_get_instance(svc.agents, id); ok do arm_coordinator_idle_instance(svc, inst)
	}
}

chain_coordinator_instance_ids :: proc(svc: ^Service, chain: domain.Task_Chain) -> []string {
	ids := make([dynamic]string, context.temp_allocator)
	if chain.coordinator_agent_instance_id != "" do append(&ids, chain.coordinator_agent_instance_id)
	if members, err := iface.taskchain_list_members_by_chain(svc.repo, chain.chain_id, chain.owner_user_id); err.code == .None {
		for m in members {
			if m.role != "coordinator" || m.agent_instance_id == "" do continue
			seen := false
			for id in ids do if id == m.agent_instance_id { seen = true; break }
			if !seen do append(&ids, m.agent_instance_id)
		}
	}
	return ids[:]
}

// note_user_activity is THE reset: a user event addressed to `instance_id`
// moves its durable stamp to now and re-arms its idle timers. Call it only for
// user events (see the file comment), after the event committed; it never
// opens a unit of work.
note_user_activity :: proc(svc: ^Service, instance_id: string) {
	if svc == nil || svc.agents == nil || instance_id == "" do return
	now := platform.clock_now(svc.clock)
	if _, err := iface.agent_touch_user_activity(svc.agents, instance_id, now); err.code != .None {
		fmt.eprintfln("[taskv2] user activity stamp for %s failed: %s", instance_id, err.message)
		return
	}
	if !coordinator_idle_enabled(svc) do return
	inst, ok, _ := iface.agent_get_instance(svc.agents, instance_id)
	if !ok || len(coordinated_chains(svc, inst)) == 0 do return
	stamp, found, _ := iface.agent_get_user_activity(svc.agents, instance_id)
	if found do arm_coordinator_idle(svc, instance_id, stamp)
}

// note_chain_user_activity: a user event on a chain task (verdict,
// requirement change) resets the chain coordinator's stamp.
note_chain_user_activity :: proc(svc: ^Service, chain_id: domain.Task_Chain_ID) {
	if svc == nil || svc.repo == nil || chain_id == "" do return
	chain, ok, _ := iface.taskchain_get_chain(svc.repo, chain_id)
	if !ok do return
	for id in chain_coordinator_instance_ids(svc, chain) do note_user_activity(svc, id)
}

// rebuild_coordinator_idle_timers (boot, REQ-CIS-4): arm X and Y for every
// live coordinator from its stamp. A timer whose deadline passed while the hub
// was down is due at the first tick and fires then (guards permitting).
rebuild_coordinator_idle_timers :: proc(svc: ^Service) {
	if !coordinator_idle_enabled(svc) do return
	insts, err := iface.agent_list_active_runtime_instances(svc.agents)
	if err.code != .None do return
	for inst in insts {
		fact := match_process_fact(svc, nil, inst, domain.Task_Chain_ID(inst.chain_id))
		if fact.state == .Exited || fact.reason == .never_started do continue
		arm_coordinator_idle_instance(svc, inst)
	}
}

// coordinator_idle_guard reports why a due idle stop must wait (REQ-CIS-3),
// or "" when the coordinator may be stopped now.
coordinator_idle_guard :: proc(svc: ^Service, inst: domain.Agent_Instance, now_ms: i64) -> string {
	if inst.activity_status == "busy" do return "busy"
	// Only an ACTIVE claim is live work. A waiting claim (submitted for review,
	// blocked on the user) permits no work, and is exactly the idle-waiting
	// case Y must stop (a Solo coordinator waiting on the user's review).
	if lease, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, inst.agent_instance_id); held && lease.phase == domain.LEASE_PHASE_ACTIVE do return "lease"
	if inst.started_at != "" {
		if started := to_ms(inst.started_at); started > 0 && now_ms - started < COORDINATOR_IDLE_START_GRACE_SECONDS * 1000 do return "starting"
	}
	if coordinator_has_unread_user_input(svc, inst) do return "user_input"
	return ""
}

// coordinator_has_unread_user_input: a user message (or answer) the instance
// has not read yet. Errors count as pending: never stop on a failed read.
coordinator_has_unread_user_input :: proc(svc: ^Service, inst: domain.Agent_Instance) -> bool {
	if svc.content == nil || inst.conversation_id == "" do return false
	cursor := ""
	for _ in 0 ..< 20 {
		rows, err := iface.content_list_agent_inbox_messages(svc.content, inst.conversation_id, inst.owner_user_id, inst.agent_instance_id, true, true, false, false, 100, cursor, true)
		if err.code != .None do return true
		for m in rows do if m.direction == "user_to_agent" do return true
		if len(rows) < 100 do return false
		// The inbox cursor is the last row's created_at (oldest first).
		cursor = rows[len(rows) - 1].created_at
	}
	return true
}

// fire_coordinator_idle: the read-only half of an idle fire (inside the fire
// UoW). It returns the stop to perform after commit, or re-arms a retry when a
// guard holds.
fire_coordinator_idle :: proc(svc: ^Service, t: Timer, now_ms: i64) -> (stop: Coordinator_Idle_Stop, ok: bool) {
	secs := coordinator_idle_seconds_for(svc, t.kind)
	if secs <= 0 do return {}, false
	inst, found, _ := iface.agent_get_instance(svc.agents, t.key)
	if !found do return {}, false
	stamp, sfound, _ := iface.agent_get_user_activity(svc.agents, t.key)
	// A user event since arming moved the stamp: the newer timer owns it.
	if !sfound || stamp != t.armed do return {}, false
	if now_ms < to_ms(stamp) + i64(secs) * 1000 do return {}, false
	fact := match_process_fact(svc, nil, inst, domain.Task_Chain_ID(inst.chain_id))
	if inst.stopped_by == agent.STOPPED_BY_USER || fact.state == .Exited || fact.reason == .never_started do return {}, false
	chains := coordinated_chains(svc, inst)
	if len(chains) == 0 do return {}, false
	// X: reopened or new work cancels it; completion re-arms it.
	if t.kind == .Coordinator_Idle_Completed && !chains_idle_completed(chains) do return {}, false
	if why := coordinator_idle_guard(svc, inst, now_ms); why != "" {
		timers_arm(svc, t.kind, t.key, now_ms + COORDINATOR_IDLE_RETRY_SECONDS * 1000, t.armed)
		return {}, false
	}
	reason := COORDINATOR_IDLE_REASON_COMPLETED if t.kind == .Coordinator_Idle_Completed else COORDINATOR_IDLE_REASON
	return Coordinator_Idle_Stop{owner = inst.owner_user_id, instance_id = inst.agent_instance_id, reason = reason, kind = t.kind, armed = t.armed}, true
}

// coordinator_idle_stop_after_commit performs the stop outside any unit of
// work. Tests (and wiring that wants to observe) set Service.coordinator_stop;
// otherwise agent.stop_instance_confirmed is called as the owner's internal principal.
// A failed stop (bridge offline, reconfiguration in flight) retries later; the
// retry re-checks liveness, so a gone instance ends the loop.
coordinator_idle_stop_after_commit :: proc(svc: ^Service, stop: Coordinator_Idle_Stop, now_ms: i64) {
	// Close the window between the fire UoW's reads and the stop: a user event
	// that committed meanwhile moved the stamp (its newer timer owns the
	// decision) or left unread input the coordinator must see first.
	if current, found, _ := iface.agent_get_user_activity(svc.agents, stop.instance_id); !found || current != stop.armed do return
	if inst, found, _ := iface.agent_get_instance(svc.agents, stop.instance_id); found && coordinator_has_unread_user_input(svc, inst) {
		timers_arm(svc, stop.kind, stop.instance_id, now_ms + COORDINATOR_IDLE_RETRY_SECONDS * 1000, stop.armed)
		return
	}
	ok := false
	msg := ""
	if svc.coordinator_stop != nil {
		ok = svc.coordinator_stop(svc.coordinator_stop_ctx, stop.owner, stop.instance_id, string(stop.reason))
	} else if svc.agent_service != nil {
		row, stopped, err := agent.stop_instance_confirmed(svc.agent_service, contracts.Auth_Context{kind = .Internal_User, user_id = string(stop.owner)}, stop.instance_id, agent.Stop_Instance_Input{reason = stop.reason})
		defer domain.agent_instance_destroy(&row)
		ok = stopped
		msg = err.message
	}
	if ok {
		fmt.eprintfln("[taskv2] coordinator %s stopped: %s", stop.instance_id, stop.reason)
		return
	}
	fmt.eprintfln("[taskv2] coordinator idle stop of %s (%s) failed: %s; retrying", stop.instance_id, stop.reason, msg)
	timers_arm(svc, stop.kind, stop.instance_id, now_ms + COORDINATOR_IDLE_RETRY_SECONDS * 1000, stop.armed)
}
