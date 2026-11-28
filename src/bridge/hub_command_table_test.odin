package main

import "core:testing"
import contracts "odin_test:contracts"

// The hub command dispatch table has one row per type and resolves the
// commands that used to be an if-chain in bridge_hub_handle_command.
@(test)
hub_command_table_routes_each_type_once :: proc(t: ^testing.T) {
	for a, i in bridge_hub_command_table {
		testing.expect(t, a.type != "" && a.handler != nil, a.type)
		for b in bridge_hub_command_table[i+1:] do testing.expect(t, a.type != b.type, a.type)
	}
	for type in ([]string{"stop_agent", "notify_agent_message", "notify_task_nudge", "wake_agent", "tool_stream_attach",
		contracts.ACP_SEND_NOW_BATCH_COMMAND, contracts.ACP_INPUTS_READ_COMMAND, contracts.START_AGENT_FRAME}) {
		testing.expect(t, bridge_hub_command_handler(type) != nil, type)
	}
	testing.expect(t, bridge_hub_command_handler("no_such_command") == nil)
	testing.expect(t, bridge_hub_command_handler(contracts.ACP_SEND_NOW_BATCH_COMMAND) != bridge_hub_command_handler(contracts.ACP_INPUTS_READ_COMMAND))
}
