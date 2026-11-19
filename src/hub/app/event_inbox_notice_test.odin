
package app

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import project "odin_test:hub/service/project"

Event_Notice_Wire :: struct {
	t:                             ^testing.T,
	runtime, activity, stopped_by: string,
	sent:                          int,
}
event_notice_wire_get :: proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	f := (^Event_Notice_Wire)(ctx)
	return {
		agent_instance_id = strings.clone(id),
		owner_user_id = domain.User_ID(strings.clone("alice")),
		agent_id = strings.clone("agt_coord"),
		bridge_id = strings.clone("bridge"),
		runtime_status = strings.clone(f.runtime),
		activity_status = strings.clone(f.activity),
		stopped_by = strings.clone(f.stopped_by),
	}, true, {}
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
	testing.expect(t, event_inbox_notice(&graph, "alice", "agt_coord", target, 20, false))
	testing.expect_value(t, f.sent, 1)
	f.activity = "busy"
	testing.expect(t, !event_inbox_notice(&graph, "alice", "agt_coord", target, 20, false))
	f.activity = "idle"
	f.stopped_by = "user"
	testing.expect(t, !event_inbox_notice(&graph, "alice", "agt_coord", target, 20, false))
	f.stopped_by = ""
	testing.expect(t, !event_inbox_notice(&graph, "bob", "agt_coord", target, 20, false))
	testing.expect(t, !event_inbox_notice(&graph, "alice", "agt_other", target, 20, false))
	testing.expect(
		t,
		!event_inbox_notice(&graph, "alice", "agt_coord", target, 20, true),
		"never restart a live instance",
	)
	testing.expect_value(t, f.sent, 1)
	testing.expect_value(t, len(track.allocation_map), 0)
}
