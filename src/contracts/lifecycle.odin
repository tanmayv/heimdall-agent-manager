package contracts

Health_Response :: struct {
	ok: bool,
	protocol_version: int,
}

Register_Request :: struct {
	protocol_version: int,
	wrapper_instance_id: Wrapper_Instance_ID,
	agent_class: Agent_Class,
	agent_instance_id: Agent_Instance_ID,
	display_name: string,
	kind: Client_Kind,
	requested_access_mode: Client_Access_Mode,
	cwd: string,
	argv: []string,
	capabilities: []Client_Capability,
	metadata: map[string]string,
}

Register_Response :: struct {
	agent_instance_id: Agent_Instance_ID,
	conversation_id: Conversation_ID,
	reconnect_token: Reconnect_Token,
	ws_url: string,
	ws_token: Ws_Token,
	agent_token: Agent_Token,
}

Reconnect_Request :: struct {
	protocol_version: int,
	agent_instance_id: Agent_Instance_ID,
	reconnect_token: Reconnect_Token,
	agent_class: Agent_Class,
	display_name: string,
	cwd: string,
	argv: []string,
	capabilities: []Client_Capability,
	metadata: map[string]string,
}

Reconnect_Response :: struct {
	agent_instance_id: Agent_Instance_ID,
	conversation_id: Conversation_ID,
	ws_url: string,
	ws_token: Ws_Token,
	agent_token: Agent_Token,
}
