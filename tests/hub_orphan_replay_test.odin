package hub_orphan_replay_test

import "core:fmt"
import "core:os"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import project "odin_test:hub/service/project"
import taskchain_service "odin_test:hub/service/taskchain"
import platform "odin_test:hub/platform"

// Verifies the orphan-recovery replay: when a bridge (re)connects, the Hub
// re-fires task_status_changed_notify for every deps-satisfied actionable task
// targeting one of that bridge's instances, and skips deps-unsatisfied tasks.

Fake :: struct {
	chains:      [4]domain.Task_Chain,
	chain_count: int,
	tasks:       [8]domain.Task,
	task_count:  int,
	deps:        [8]domain.Task_Dependency,
	dep_count:   int,
	instances:   [8]domain.Agent_Instance,
	inst_count:  int,
	sent_cmds:   int,
	seq:         int,
}

g: Fake

now_str :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-07-22T10:00:00Z" }
gen_id :: proc(ctx: rawptr, prefix: string) -> string { g.seq += 1; return strings.concatenate({prefix, fmt.tprintf("%d", g.seq)}) }

// --- taskchain repo ---
c_get :: proc(ctx: rawptr, id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	for i in 0..<g.chain_count { if g.chains[i].chain_id == id do return g.chains[i], true, {} }
	return {}, false, domain.domain_error(.Not_Found, "no chain")
}
c_list_owner :: proc(ctx: rawptr, owner: domain.User_ID) -> ([]domain.Task_Chain, domain.Domain_Error) {
	out := make([dynamic]domain.Task_Chain)
	for i in 0..<g.chain_count { if g.chains[i].owner_user_id == owner do append(&out, g.chains[i]) }
	return out[:], {}
}
t_get :: proc(ctx: rawptr, id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) {
	for i in 0..<g.task_count { if g.tasks[i].task_id == id do return g.tasks[i], true, {} }
	return {}, false, domain.domain_error(.Not_Found, "no task")
}
t_list_chain :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task, domain.Domain_Error) {
	out := make([dynamic]domain.Task)
	for i in 0..<g.task_count { if g.tasks[i].chain_id == chain_id do append(&out, g.tasks[i]) }
	return out[:], {}
}
d_list_chain :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Dependency, domain.Domain_Error) {
	out := make([dynamic]domain.Task_Dependency)
	for i in 0..<g.dep_count { if g.deps[i].chain_id == chain_id do append(&out, g.deps[i]) }
	return out[:], {}
}

// --- agent repo ---
a_get_instance :: proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	for i in 0..<g.inst_count { if g.instances[i].agent_instance_id == id do return g.instances[i], true, {} }
	return {}, false, domain.domain_error(.Not_Found, "no inst")
}
a_list_by_bridge :: proc(ctx: rawptr, bridge_id: string) -> ([]domain.Agent_Instance, domain.Domain_Error) {
	out := make([dynamic]domain.Agent_Instance)
	for i in 0..<g.inst_count { if g.instances[i].bridge_id == bridge_id do append(&out, g.instances[i]) }
	return out[:], {}
}

// --- counting bridge command sink ---
g_sent_bridge_b: int
g_sent_task_down: int

sink_send :: proc(ctx: rawptr, cmd: project.Runtime_Command) -> (bool, domain.Domain_Error) {
	if strings.contains(cmd.body_json, "task_status_changed_notify") {
		g.sent_cmds += 1
		if cmd.bridge_id == "bridge_B" do g_sent_bridge_b += 1
		if strings.contains(cmd.body_json, `"task_id":"down"`) do g_sent_task_down += 1
	}
	return true, {}
}

assignee_ref :: proc(id: string) -> string { return strings.concatenate({`{"type":"agent_instance","agent_instance_id":"`, id, `"}`}) }

main :: proc() {
	clock := platform.Clock{ctx = nil, now = now_str}
	ids := platform.ID_Generator{ctx = nil, generate = gen_id}
	repo := iface.Taskchain_Repository{
		ctx = nil, get_chain = c_get, list_chains_by_owner = c_list_owner,
		get_task = t_get, list_tasks_by_chain = t_list_chain, list_dependencies_by_chain = d_list_chain,
	}
	agents := iface.Agent_Repository{ ctx = nil, get_instance = a_get_instance, list_instances_by_bridge = a_list_by_bridge }
	sink := project.Bridge_Command_Sink{ ctx = nil, send_runtime_command = sink_send }
	service := taskchain_service.new_taskchain_service_with_runtime(&repo, &agents, sink, &clock, &ids)

	// Chain with two members on bridge B: upstream (inst_a on bridge A, elsewhere)
	// and downstream (inst_b on bridge B) that depends on upstream.
	g.chains[0] = domain.Task_Chain{chain_id = "chain_1", owner_user_id = "alice", publish_state = .Published, status = .Active, coordinator_agent_instance_id = "inst_a"}
	g.chain_count = 1
	// upstream completed; downstream deps now satisfied and ready.
	g.tasks[0] = domain.Task{task_id = "up", chain_id = "chain_1", owner_user_id = "alice", publish_state = .Published, status = .Completed, assignee_ref_json = assignee_ref("inst_a"), updated_at = "t1"}
	g.tasks[1] = domain.Task{task_id = "down", chain_id = "chain_1", owner_user_id = "alice", publish_state = .Published, status = .In_Progress, assignee_ref_json = assignee_ref("inst_b"), updated_at = "t2"}
	// a second task on bridge B that is still blocked (deps unsatisfied) -> must NOT replay.
	g.tasks[2] = domain.Task{task_id = "blocked", chain_id = "chain_1", owner_user_id = "alice", publish_state = .Published, status = .Assigned, assignee_ref_json = assignee_ref("inst_b2"), updated_at = "t3"}
	g.task_count = 3
	g.deps[0] = domain.Task_Dependency{task_id = "down", depends_on_task_id = "up", chain_id = "chain_1", owner_user_id = "alice"}
	g.deps[1] = domain.Task_Dependency{task_id = "blocked", depends_on_task_id = "down", chain_id = "chain_1", owner_user_id = "alice"}
	g.dep_count = 2
	// instances: inst_a on bridge A; inst_b + inst_b2 on bridge B.
	g.instances[0] = domain.Agent_Instance{agent_instance_id = "inst_a", owner_user_id = "alice", bridge_id = "bridge_A"}
	g.instances[1] = domain.Agent_Instance{agent_instance_id = "inst_b", owner_user_id = "alice", bridge_id = "bridge_B"}
	g.instances[2] = domain.Agent_Instance{agent_instance_id = "inst_b2", owner_user_id = "alice", bridge_id = "bridge_B"}
	g.inst_count = 3

	// Replay for bridge B: only "down" is deps-satisfied + targets a B instance.
	// "blocked" depends on "down" (in_progress, not terminal) -> deps unsatisfied -> skipped.
	// Note: notify_task_status_change is task-scoped, so replaying "down" fans out to
	// every bridge hosting one of its actors (coordinator inst_a on A + assignee
	// inst_b on B) -> 2 raw commands for 1 replayed task. That cross-bridge fan-out
	// is intended and idempotent; we assert on tasks replayed and that B was targeted.
	g.sent_cmds = 0; g_sent_bridge_b = 0; g_sent_task_down = 0
	t0: i64 = 1_000_000
	n := taskchain_service.replay_bridge_actionable_notifications_at(&service, "alice", "bridge_B", t0)
	check(n == 1, fmt.tprintf("expected 1 replay for bridge B, got %d", n))
	check(g_sent_task_down >= 1, "replay must notify for the actionable 'down' task")
	check(g_sent_bridge_b == 1, fmt.tprintf("expected 1 notify targeting bridge B, got %d", g_sent_bridge_b))

	// Throttle: an immediate re-replay for the same bridge (flapping) is suppressed.
	g.sent_cmds = 0; g_sent_bridge_b = 0
	n2 := taskchain_service.replay_bridge_actionable_notifications_at(&service, "alice", "bridge_B", t0 + 1_000)
	check(n2 == 0, fmt.tprintf("expected throttled (0) replay within window, got %d", n2))
	check(g.sent_cmds == 0, "throttled replay must send nothing")

	// After the throttle window elapses, replay runs again.
	g.sent_cmds = 0; g_sent_bridge_b = 0
	n3 := taskchain_service.replay_bridge_actionable_notifications_at(&service, "alice", "bridge_B", t0 + 20_000)
	check(n3 == 1, fmt.tprintf("expected replay after window, got %d", n3))
	check(g_sent_bridge_b == 1, "post-window replay must target bridge B again")

	// Replay for bridge A: "up" is Completed (terminal) -> not actionable -> nothing.
	// (Different bridge -> not throttled by bridge_B's timestamp.)
	g.sent_cmds = 0
	nA := taskchain_service.replay_bridge_actionable_notifications_at(&service, "alice", "bridge_A", t0 + 20_000)
	check(nA == 0, fmt.tprintf("expected 0 replay for bridge A, got %d", nA))
	check(g.sent_cmds == 0, "no notify expected for bridge A")

	fmt.println("PASS: hub orphan replay")
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln("FAIL:", message); os.exit(1) }
