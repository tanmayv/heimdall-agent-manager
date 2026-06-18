package contracts

Client_Info :: struct {
	agent_instance_id: Agent_Instance_ID,
	conversation_id: Conversation_ID,
	wrapper_instance_id: Wrapper_Instance_ID,
	agent_class: Agent_Class,
	display_name: string,
	kind: Client_Kind,
	access_mode: Client_Access_Mode,
	cwd: string,
	argv: []string,
	capabilities: []Client_Capability,
	has_agent_token: bool,
	connected: bool,
	last_seen_unix_ms: i64,
	metadata: map[string]string,
}

List_Clients_Response :: struct {
	clients: []Client_Info,
}
