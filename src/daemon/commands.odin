package main

import contracts "odin_test:contracts"

Command_Source :: enum {
	Local_Agent_RPC,
	Remote_Router_Envelope,
}

Command_Kind :: enum {
	Send_Message,
	Fetch_Messages,
	Mark_Read,
}

Send_Message_Command :: struct {
	from_agent_instance_id: contracts.Agent_Instance_ID,
	target_agent_instance_id: contracts.Agent_Instance_ID,
	payload: string,
}

Fetch_Messages_Command :: struct {
	agent_instance_id: contracts.Agent_Instance_ID,
	conversation_id: contracts.Conversation_ID,
	limit: int,
	include_read: bool,
}

Mark_Read_Command :: struct {
	agent_instance_id: contracts.Agent_Instance_ID,
	conversation_id: contracts.Conversation_ID,
	message_id: contracts.Message_ID,
	read_unix_ms: i64,
}

Command :: struct {
	source: Command_Source,
	kind: Command_Kind,
	send_message: Send_Message_Command,
	fetch_messages: Fetch_Messages_Command,
	mark_read: Mark_Read_Command,
}

Service_Result :: struct {
	ok: bool,
	message: string,
	status_code: int,
	status_text: string,
	send_response: contracts.Send_Message_Response,
	fetch_response: contracts.Fetch_Messages_Response,
	pending_count: int,
	notified: bool,
}
