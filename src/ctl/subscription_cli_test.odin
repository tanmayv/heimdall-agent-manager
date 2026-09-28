package main

import "core:encoding/json"
import "core:strings"
import "core:testing"

@(test)
test_agentmode_chain_subscribe_params :: proc(t: ^testing.T) {
	p1 := ctl_agentmode_chain_subscribe_params("chain_abc", "all")
	testing.expect(t, strings.contains(p1, `"chain_id":"chain_abc"`), "chain_id should match")
	testing.expect(t, strings.contains(p1, `"events":"all"`), "events should match default 'all'")

	p2 := ctl_agentmode_chain_subscribe_params("chain_xyz", "chain_status")
	testing.expect(t, strings.contains(p2, `"chain_id":"chain_xyz"`), "chain_id should match")
	testing.expect(t, strings.contains(p2, `"events":"chain_status"`), "events should match specific event")
}

@(test)
test_agentmode_chain_unsubscribe_params :: proc(t: ^testing.T) {
	p1 := ctl_agentmode_chain_unsubscribe_params("chain_abc", "")
	testing.expect(t, strings.contains(p1, `"chain_id":"chain_abc"`), "chain_id should match")
	testing.expect(t, strings.contains(p1, `"events":""`), "events should be empty when not specified")

	p2 := ctl_agentmode_chain_unsubscribe_params("chain_xyz", "task_status")
	testing.expect(t, strings.contains(p2, `"chain_id":"chain_xyz"`), "chain_id should match")
	testing.expect(t, strings.contains(p2, `"events":"task_status"`), "events should match specific event")
}

@(test)
test_agentmode_task_subscribe_params :: proc(t: ^testing.T) {
	p1 := ctl_agentmode_task_subscribe_params("task_abc", "all")
	testing.expect(t, strings.contains(p1, `"task_id":"task_abc"`), "task_id should match")
	testing.expect(t, strings.contains(p1, `"events":"all"`), "events should match default 'all'")

	p2 := ctl_agentmode_task_subscribe_params("task_xyz", "task_status")
	testing.expect(t, strings.contains(p2, `"task_id":"task_xyz"`), "task_id should match")
	testing.expect(t, strings.contains(p2, `"events":"task_status"`), "events should match specific event")
}

@(test)
test_agentmode_task_unsubscribe_params :: proc(t: ^testing.T) {
	p1 := ctl_agentmode_task_unsubscribe_params("task_abc", "")
	testing.expect(t, strings.contains(p1, `"task_id":"task_abc"`), "task_id should match")
	testing.expect(t, strings.contains(p1, `"events":""`), "events should be empty when not specified")

	p2 := ctl_agentmode_task_unsubscribe_params("task_xyz", "task_status")
	testing.expect(t, strings.contains(p2, `"task_id":"task_xyz"`), "task_id should match")
	testing.expect(t, strings.contains(p2, `"events":"task_status"`), "events should match specific event")
}

@(test)
test_user_chain_subscribe_body :: proc(t: ^testing.T) {
	b1 := ctl_user_chain_subscribe_body("all", "inst_agent_1")
	defer delete(b1)
	testing.expect(t, strings.contains(b1, `"events":"all"`), "events should match 'all'")
	testing.expect(t, strings.contains(b1, `"agent_instance_id":"inst_agent_1"`), "agent_instance_id should match")

	b2 := ctl_user_chain_subscribe_body("chain_status", "")
	defer delete(b2)
	testing.expect(t, strings.contains(b2, `"events":"chain_status"`), "events should match 'chain_status'")
	testing.expect(t, !strings.contains(b2, "agent_instance_id"), "agent_instance_id should be omitted when empty")
}

@(test)
test_user_chain_unsubscribe_body :: proc(t: ^testing.T) {
	b1 := ctl_user_chain_unsubscribe_body("", "")
	defer delete(b1)
	testing.expect_value(t, b1, "{}")

	b2 := ctl_user_chain_unsubscribe_body("task_status", "inst_agent_2")
	defer delete(b2)
	testing.expect(t, strings.contains(b2, `"events":"task_status"`), "events should match")
	testing.expect(t, strings.contains(b2, `"agent_instance_id":"inst_agent_2"`), "agent_instance_id should match")
}

@(test)
test_command_tokens_skips_events_flags :: proc(t: ^testing.T) {
	args := []string{"ham-ctl", "task-chain", "subscribe", "chain_123", "--events", "all"}
	tokens := command_tokens(args)
	defer delete(tokens)

	testing.expect_value(t, len(tokens), 3)
	testing.expect_value(t, tokens[0], "task-chain")
	testing.expect_value(t, tokens[1], "subscribe")
	testing.expect_value(t, tokens[2], "chain_123")

	args2 := []string{"ham-ctl", "task", "unsubscribe", "task_456", "--event-type", "task_status"}
	tokens2 := command_tokens(args2)
	defer delete(tokens2)

	testing.expect_value(t, len(tokens2), 3)
	testing.expect_value(t, tokens2[0], "task")
	testing.expect_value(t, tokens2[1], "unsubscribe")
	testing.expect_value(t, tokens2[2], "task_456")
}
