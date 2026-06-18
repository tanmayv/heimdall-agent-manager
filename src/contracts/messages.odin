package contracts

Command_Type :: enum {
	Stdin,
	Interrupt,
	Capture,
	Terminate,
	Ping,
	Messages_Available,
}

Command_Message :: struct {
	id: string,
	type: Command_Type,
	from_agent_instance_id: Agent_Instance_ID,
	from_agent_class: Agent_Class,
	conversation_id: string,
	pending_count: int,
	text: string, // Used by stdin-style commands only; Messages_Available must not carry message content.
}

Message_Event_Type :: enum {
	Messages_Available,
	Messages_Read,
	Message_Delivered,
}

Message_Event :: struct {
	event: Message_Event_Type,
	conversation_id: Conversation_ID,
	message_id: Message_ID,
	from_agent_instance_id: Agent_Instance_ID,
	target_agent_instance_id: Agent_Instance_ID,
	read_by_agent_instance_id: Agent_Instance_ID,
	pending_count: int,
	created_unix_ms: i64,
	read_unix_ms: i64,
}

Event_Type :: enum {
	Hello,
	Heartbeat,
	Ack,
	Output,
	Capture_Result,
	Exit,
	Error,
}

Event_Message :: struct {
	id: string,
	type: Event_Type,
	ok: bool,
	text: string,
	child_alive: bool,
	exit_code: int,
}
