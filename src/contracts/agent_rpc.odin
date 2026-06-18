package contracts

Agent_RPC_Action :: enum {
	Health,
	List_Clients,
	Send_Stdin,
	Send_Message,
	Capture,
}

Agent_RPC_Request :: struct {
	agent_token: Agent_Token,
	action: Agent_RPC_Action,
	target_agent_instance_id: Agent_Instance_ID,
	payload: string,
}

Agent_RPC_Response :: struct {
	ok: bool,
	message: string,
	payload: string,
}
