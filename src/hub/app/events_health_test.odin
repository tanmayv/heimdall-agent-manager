package app

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import natstest "odin_test:lib/natstest"
import http "odin_test:hub/transport/http"

@(test)
test_events_config_and_boot_degraded_health :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	graph: App_Graph
	config := default_config()
	config.database_path = fmt.tprintf("/tmp/heimdall-e0b-health-%d-%d.db", os.get_pid(), time.tick_now()._nsec)
	defer _ = os.remove(config.database_path)
	defer _ = os.remove(fmt.tprintf("%s-wal", config.database_path))
	defer _ = os.remove(fmt.tprintf("%s-shm", config.database_path))
	missing, message := build_graph(&graph, config)
	testing.expect(t, !missing && strings.contains(message, "HEIMDALL_NATS_URL"), "missing URL fails before opening database")
	testing.expect(t, graph.db.db == nil)
	srv, started := natstest.start()
	defer natstest.destroy(&srv)
	if !testing.expect(t, started) do return
	natstest.stop(&srv)
	config.nats_url = srv.url
	built, reason := build_graph(&graph, config)
	if !testing.expect(t, built, reason) do return
	defer shutdown_graph(&graph)
	uow, began, _ := iface.unit_of_work_begin(&graph.uow_factory)
	if !testing.expect(t, began) do return
	err := uow.repos.event_outbox.append(uow.repos.event_outbox.ctx, {
	event_id = "evt_health", owner_user_id = "alice", subject = "ev.alice.task.one.occurrence",
	envelope_json = "{}", headers_json = "{}", created_at = "2026-11-19T00:00:00Z"})
	testing.expect_value(t, err.code, domain.Error_Code.None)
	committed, _ := iface.unit_of_work_commit(&uow)
	testing.expect(t, committed)
	expect_events_health(t, &graph, "degraded", 1)
	if !testing.expect(t, natstest.restart(&srv)) do return
	deadline := time.tick_now()
	for time.tick_since(deadline) < 10 * time.Second {
		health := decode_events_health(t, &graph)
		if health.data.events.status == "ok" && health.data.events.outbox_backlog == 0 do break
		time.sleep(20 * time.Millisecond)
	}
	expect_events_health(t, &graph, "ok", 0)
}
Events_Health_Response :: struct {
	data: struct {
		ok: bool,
		events: struct { status: string, outbox_backlog: i64 },
	},
}
decode_events_health :: proc(t: ^testing.T, graph: ^App_Graph) -> Events_Health_Response {
	response := health_handler(graph, http.Request{request_id = "health-test"})
	testing.expect_value(t, response.status, 200)
	result: Events_Health_Response
	err := json.unmarshal(transmute([]byte)response.body, &result, allocator = context.temp_allocator)
	testing.expect(t, err == nil, "health response is valid JSON")
	return result
}
expect_events_health :: proc(t: ^testing.T, graph: ^App_Graph, status: string, backlog: i64) {
	result := decode_events_health(t, graph)
	testing.expect(t, result.data.ok)
	testing.expect_value(t, result.data.events.status, status)
	testing.expect_value(t, result.data.events.outbox_backlog, backlog)
}
