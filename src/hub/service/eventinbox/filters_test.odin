package eventinbox

import "core:testing"

@(test)
test_subscription_default_filters :: proc(t: ^testing.T) {
 coordinator, ok := filters("alice", "chain_1", "", "coordinator")
 testing.expect(t, ok)
 defer filters_destroy(coordinator)
 testing.expect_value(t, len(coordinator), 7)
 testing.expect_value(t, coordinator[0], "ev.alice.chain.chain_1.state")
 testing.expect_value(t, coordinator[1], "ev.alice.chain.chain_1.task.*.state")
 worker, wok := filters("alice", "chain_1", "task_1", "worker")
 testing.expect(t, wok)
 defer filters_destroy(worker)
 testing.expect_value(t, len(worker), 1)
 testing.expect_value(t, worker[0], "ev.alice.chain.chain_1.task.task_1.requirements_changed")
 bot, bok := filters("alice", "chain_1", "", "explicit")
 testing.expect(t, bok)
 defer filters_destroy(bot)
 testing.expect_value(t, len(bot), 4)
 for role in ([]string{"coordinator", "explicit", "worker"}) {
  bad, valid := filters("alice.*", "chain_1", "task_1", role)
  testing.expect(t, !valid && bad == nil, "subject wildcard injection rejected")
 }
 bad, valid := filters("alice", "chain_1", "", "worker")
 testing.expect(t, !valid && bad == nil, "worker needs a task")
 bad, valid = filters("alice", "chain_1", "task_1", "coordinator")
 testing.expect(t, !valid && bad == nil, "coordinator is chain scoped")
 bad, valid = filters("alice", "chain_1", "", "unknown")
 testing.expect(t, !valid && bad == nil, "unknown roles rejected")
}

@(test)
test_topic_generation_freshness :: proc(t: ^testing.T) {
 testing.expect(t, !topic_stale(1, 1, 0), "current open")
 testing.expect(t, topic_stale(1, 1, 1), "resolved")
 testing.expect(t, topic_stale(1, 2, 0), "superseded before resolution")
 testing.expect(t, topic_stale(1, 2, 1), "resolved before reopening")
 testing.expect(t, !topic_stale(2, 2, 1), "reopened request survives old resolution")
 testing.expect(t, topic_stale(2, 2, 2), "reopened request resolved")
}
