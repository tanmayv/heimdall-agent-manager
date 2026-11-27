
package app

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import project "odin_test:hub/service/project"
import agent "odin_test:hub/service/agent"

Event_Notice_Wire :: struct {
	graph:                                                  ^App_Graph,
	reads:                                                  int,
	stop_after_snapshot, fail_after_snapshot, guard_locked: bool,
	t:                                                      ^testing.T,
	runtime, activity, stopped_by:                          string,
	sent:                                                   int,
}
event_notice_wire_get :: proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	f := (^Event_Notice_Wire)(ctx)
	f.reads += 1
	if (f.stop_after_snapshot || f.fail_after_snapshot) && f.reads == 2 {
		acquired := sync.mutex_try_lock(&f.graph.agents.reconfiguration_mutex)
		f.guard_locked = !acquired
		if acquired do sync.mutex_unlock(&f.graph.agents.reconfiguration_mutex)
		if f.stop_after_snapshot do f.stopped_by = "user"
		if f.fail_after_snapshot do f.runtime = "superseded"
	}
	return {
		agent_instance_id = strings.clone(id),
		owner_user_id = domain.User_ID(strings.clone("alice")),
		agent_id = strings.clone("agt_coord"),
		bridge_id = strings.clone("bridge"),
		runtime_status = strings.clone(f.runtime),
		activity_status = strings.clone(f.activity),
		stopped_by = strings.clone(f.stopped_by),
		run_count = 2 if f.runtime == "superseded" else 1,
	}, true, {}
}
event_notice_fixture_process :: proc(inst: domain.Agent_Instance) -> agent.Agent_Liveness {
	switch inst.runtime_status {
	case "running": return {state = .Alive, reason = .pty_child_alive, pid = 42, ready = true}
	case "stopped": return {state = .Exited, reason = .missing_from_pty_roster}
	case: return {reason = .probe_timed_out}
	}
}
event_notice_wire_send :: proc(ctx: rawptr, command: project.Runtime_Command) -> (bool, domain.Domain_Error) {
	f := (^Event_Notice_Wire)(ctx)
	value, err := json.parse_string(command.body_json)
	if !testing.expect(f.t, err == nil) do return false, {}
	defer json.destroy_value(value)
	obj := value.(json.Object)
	testing.expect_value(f.t, string(obj["type"].(json.String)), "notify_task_nudge")
	testing.expect_value(f.t, string(obj["origin"].(json.String)), "events")
	testing.expect_value(f.t, string(obj["agent_instance_id"].(json.String)), "inst_coord")
	testing.expect_value(f.t, string(obj["task_id"].(json.String)), "")
	testing.expect_value(
		f.t,
		string(obj["message"].(json.String)),
		"[events] 20 new event(s) — run ham-ctl events next",
	)
	testing.expect_value(f.t, command.bridge_id, "bridge")
	f.sent += 1
	return true, {}
}
@(test)
test_event_inbox_notice_uses_existing_command_and_rechecks_idle :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	f := Event_Notice_Wire {
		t        = t,
		runtime  = "running",
		activity = "idle",
	}
	graph: App_Graph
	graph.ids = platform.real_id_generator()
	graph.agents.fixture_start_fact = event_notice_fixture_process
	graph.repos.agents = {
		ctx          = &f,
		get_instance = event_notice_wire_get,
	}
	graph.agents.bridge_command_sink = {
		ctx                  = &f,
		send_runtime_command = event_notice_wire_send,
	}
	target := domain.Event_Notice_Target {
		instance_id = "inst_coord",
	}
	testing.expect(t, event_inbox_notice(&graph, "alice", "inst_coord", target, 20, false))
	testing.expect_value(t, f.sent, 1)
	f.activity = "busy"
	testing.expect(t, !event_inbox_notice(&graph, "alice", "inst_coord", target, 20, false))
	f.activity = "idle"
	f.stopped_by = "user"
	testing.expect(t, !event_inbox_notice(&graph, "alice", "inst_coord", target, 20, false))
	f.stopped_by = ""
	testing.expect(t, !event_inbox_notice(&graph, "bob", "inst_coord", target, 20, false))
	// A target that is not the subscription's own instance is never notified (REQ-EVP-4a).
	testing.expect(t, !event_inbox_notice(&graph, "alice", "inst_sibling", target, 20, false))
	testing.expect(
		t,
		!event_inbox_notice(&graph, "alice", "inst_coord", target, 20, true),
		"never restart a live instance",
	)
	testing.expect_value(t, f.sent, 1)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_event_inbox_wake_guard_preserves_stop_after_snapshot :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	graph: App_Graph
	f := Event_Notice_Wire {
		t                   = t,
		graph               = &graph,
		runtime             = "stopped",
		stop_after_snapshot = true,
	}
	graph.repos.agents = {
		ctx          = &f,
		get_instance = event_notice_wire_get,
	}
	graph.agents.agents = &graph.repos.agents
	graph.agents.fixture_start_fact = event_notice_fixture_process
	target := domain.Event_Notice_Target {
		instance_id = "inst_coord",
	}
	testing.expect(t, !event_inbox_notice(&graph, "alice", "inst_coord", target, 20, true))
	testing.expect_value(t, f.reads, 2)
	testing.expect(t, f.guard_locked, "start guard executes under the same mutex as stop")
	testing.expect_value(t, f.stopped_by, "user")
	testing.expect_value(t, f.sent, 0)

	f.stopped_by = ""
	f.reads = 0
	f.guard_locked = false
	f.stop_after_snapshot = false
	f.fail_after_snapshot = true
	testing.expect(t, !event_inbox_notice(&graph, "alice", "inst_coord", target, 20, true))
	testing.expect_value(t, f.reads, 2)
	testing.expect(t, f.guard_locked)
	testing.expect_value(t, f.runtime, "superseded")

	// Inconclusive process observations are rejected before even entering start_instance.
	f.reads = 0
	testing.expect(t, !event_inbox_notice(&graph, "alice", "inst_coord", target, 20, true))
	testing.expect_value(t, f.reads, 1)
	testing.expect_value(t, len(track.allocation_map), 0)
}
