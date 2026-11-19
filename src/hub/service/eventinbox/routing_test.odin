package eventinbox

import "core:mem"
import "core:testing"
import "core:time"
import eventrelay "odin_test:hub/service/eventrelay"
import nats "odin_test:lib/nats"
import natstest "odin_test:lib/natstest"

@(test)
test_real_subscription_subject_routing :: proc(t: ^testing.T) {
 track: mem.Tracking_Allocator
 mem.tracking_allocator_init(&track, context.allocator)
 defer mem.tracking_allocator_destroy(&track)
 context.allocator = mem.tracking_allocator(&track)
 subscription_routing_scenario(t)
 testing.expect_value(t, nats.shutdown(5000).status, i32(0))
 testing.expect_value(t, len(track.allocation_map), 0)
}

subscription_routing_scenario :: proc(t: ^testing.T) {
 server, started := natstest.start()
 defer natstest.destroy(&server)
 if !testing.expect(t, started) do return
 conn, err := nats.connect({url = server.url, timeout_ms = 1000})
 if !testing.expect_value(t, err.status, i32(0)) do return
 defer nats.destroy(conn)
 _, err = nats.stream_add(conn, eventrelay.stream_config())
 if !testing.expect_value(t, err.status, i32(0)) do return
 coord, _ := filters("alice", "chain_1", "", "coordinator")
 defer filters_destroy(coord)
 worker, _ := filters("alice", "chain_1", "task_future", "worker")
 defer filters_destroy(worker)
 for cfg in ([]nats.Consumer_Config{
  {stream = "HEIM_EVENTS", durable = "coord", filter_subjects = coord, ack_wait_ns = i64(time.Minute), max_deliver = 10},
  {stream = "HEIM_EVENTS", durable = "worker", filter_subjects = worker, ack_wait_ns = i64(time.Minute), max_deliver = 10},
 }) {
  testing.expect_value(t, nats.consumer_add(conn, cfg).status, i32(0))
 }
 // Consumers exist before future tasks publish. No task enumeration or
 // consumer updates are needed, and other tenants/chains stay outside them.
 for subject in ([]string{
  "ev.bob.chain.chain_1.task.task_future.state",
  "ev.alice.chain.chain_other.task.task_future.state",
  "ev.alice.chain.chain_1.task.task_future.state",
  "ev.alice.chain.chain_1.task.task_future.requirements_changed",
  "ev.alice.chain.chain_1.task.task_other.requirements_changed",
 }) {
  _, err = nats.publish(conn, subject, transmute([]byte)subject)
  testing.expect_value(t, err.status, i32(0))
 }
 for durable in ([]string{"coord", "worker"}) {
  pull, perr := nats.pull_bind(conn, "HEIM_EVENTS", durable)
  if !testing.expect_value(t, perr.status, i32(0)) do return
  batch, berr := nats.fetch(pull, 10, 100)
  if testing.expect_value(t, berr.status, i32(0)) {
   testing.expect_value(t, nats.batch_count(batch), 1)
   msg := nats.batch_message(batch, 0)
   expected := "ev.alice.chain.chain_1.task.task_future.state" if durable == "coord" else "ev.alice.chain.chain_1.task.task_future.requirements_changed"
   testing.expect_value(t, nats.message_subject(msg), expected)
   testing.expect_value(t, nats.ack(msg).status, i32(0))
   nats.batch_destroy(batch)
  }
  nats.pull_destroy(pull)
 }
}
