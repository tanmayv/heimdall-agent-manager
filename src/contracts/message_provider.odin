package contracts

Message_ID :: distinct string

Message_Provider_Capability :: enum {
	Send_Message,
	Fetch_Messages,
	Unread_Count,
	Mark_Read,
	Delivery_Receipts,
}

Message_Provider_Info :: struct {
	name: string,
	version: string,
	capabilities: []Message_Provider_Capability,
}

Message_Direction :: enum {
	Inbound,
	Outbound,
}

Message_Status :: enum {
	Pending,
	Sent,
	Delivered,
	Read,
	Failed,
}

Message :: struct {
	id: Message_ID,
	conversation_id: Conversation_ID,
	from_agent_instance_id: Agent_Instance_ID,
	target_agent_instance_id: Agent_Instance_ID,
	direction: Message_Direction,
	status: Message_Status,
	body: string,
	created_unix_ms: i64,
	updated_unix_ms: i64,
	read_unix_ms: i64,
	metadata: map[string]string,
}

Send_Message_Request :: struct {
	from_agent_instance_id: Agent_Instance_ID,
	target_agent_instance_id: Agent_Instance_ID,
	conversation_id: Conversation_ID,
	body: string,
	metadata: map[string]string,
}

Send_Message_Response :: struct {
	ok: bool,
	message: string,
	message_id: Message_ID,
	conversation_id: Conversation_ID,
	created_unix_ms: i64,
}

Fetch_Messages_Request :: struct {
	agent_instance_id: Agent_Instance_ID,
	conversation_id: Conversation_ID,
	after_message_id: Message_ID,
	limit: int,
	include_read: bool,
}

Fetch_Messages_Response :: struct {
	ok: bool,
	message: string,
	messages: []Message,
	has_more: bool,
}

Unread_Count_Request :: struct {
	agent_instance_id: Agent_Instance_ID,
	conversation_id: Conversation_ID,
}

Unread_Count_Response :: struct {
	ok: bool,
	message: string,
	conversation_id: Conversation_ID,
	unread_count: int,
}

Mark_Read_Request :: struct {
	agent_instance_id: Agent_Instance_ID,
	conversation_id: Conversation_ID,
	through_message_id: Message_ID,
}

Mark_Read_Response :: struct {
	ok: bool,
	message: string,
	conversation_id: Conversation_ID,
	marked_count: int,
	read_unix_ms: i64,
}

Delivery_Receipt_Type :: enum {
	Accepted,
	Sent,
	Delivered,
	Read,
	Failed,
}

Delivery_Receipt :: struct {
	message_id: Message_ID,
	conversation_id: Conversation_ID,
	agent_instance_id: Agent_Instance_ID,
	type: Delivery_Receipt_Type,
	created_unix_ms: i64,
	message: string,
}

Delivery_Receipts_Request :: struct {
	agent_instance_id: Agent_Instance_ID,
	conversation_id: Conversation_ID,
	after_unix_ms: i64,
	limit: int,
}

Delivery_Receipts_Response :: struct {
	ok: bool,
	message: string,
	receipts: []Delivery_Receipt,
	has_more: bool,
}
