package main

import contracts "odin_test:contracts"

Daemon_Client :: struct {
	base_url: string,
	health: Daemon_Health_Proc,
	register: Daemon_Register_Proc,
	reconnect: Daemon_Reconnect_Proc,
	connect_websocket: Daemon_Connect_WebSocket_Proc,
}

Wrapper_Credentials :: struct {
	agent_instance_id: contracts.Agent_Instance_ID,
	conversation_id: contracts.Conversation_ID,
	reconnect_token: contracts.Reconnect_Token,
}

WebSocket_Session :: struct {
	agent_instance_id: contracts.Agent_Instance_ID,
	conversation_id: contracts.Conversation_ID,
	ws_url: string,
	ws_token: contracts.Ws_Token,
}

Daemon_Health_Proc :: proc(client: ^Daemon_Client) -> (contracts.Health_Response, bool)
Daemon_Register_Proc :: proc(client: ^Daemon_Client, request: contracts.Register_Request) -> (contracts.Register_Response, bool)
Daemon_Reconnect_Proc :: proc(client: ^Daemon_Client, request: contracts.Reconnect_Request) -> (contracts.Reconnect_Response, bool)
Daemon_Connect_WebSocket_Proc :: proc(client: ^Daemon_Client, session: WebSocket_Session) -> bool
