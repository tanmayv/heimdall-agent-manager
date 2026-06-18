package main

import contracts "odin_test:contracts"

Send_Message_Context :: struct {
	from_agent_instance_id: contracts.Agent_Instance_ID,
	target_agent_instance_id: contracts.Agent_Instance_ID,
	conversation_id: contracts.Conversation_ID,
	body: string,
	rejected: bool,
	rejection_reason: string,
}

run_pre_send_hooks :: proc(ctx: ^Send_Message_Context) {
	// No-op for the POC. Future plugins may rewrite, reject, mirror, or route messages here.
}
