package message_provider

import contracts "odin_test:contracts"

Send_Message_Proc :: proc(state: rawptr, request: contracts.Send_Message_Request) -> contracts.Send_Message_Response
Fetch_Messages_Proc :: proc(state: rawptr, request: contracts.Fetch_Messages_Request) -> contracts.Fetch_Messages_Response
Unread_Count_Proc :: proc(state: rawptr, request: contracts.Unread_Count_Request) -> contracts.Unread_Count_Response
Mark_Read_Proc :: proc(state: rawptr, request: contracts.Mark_Read_Request) -> contracts.Mark_Read_Response

Message_Provider :: struct {
	name: string,
	capabilities: []contracts.Message_Provider_Capability,
	state: rawptr,
	send_message: Send_Message_Proc,
	fetch_messages: Fetch_Messages_Proc,
	unread_count: Unread_Count_Proc,
	mark_read: Mark_Read_Proc,
}

send_message :: proc(provider: ^Message_Provider, request: contracts.Send_Message_Request) -> contracts.Send_Message_Response {
	return provider.send_message(provider.state, request)
}

fetch_messages :: proc(provider: ^Message_Provider, request: contracts.Fetch_Messages_Request) -> contracts.Fetch_Messages_Response {
	return provider.fetch_messages(provider.state, request)
}

unread_count :: proc(provider: ^Message_Provider, request: contracts.Unread_Count_Request) -> contracts.Unread_Count_Response {
	return provider.unread_count(provider.state, request)
}

mark_read :: proc(provider: ^Message_Provider, request: contracts.Mark_Read_Request) -> contracts.Mark_Read_Response {
	return provider.mark_read(provider.state, request)
}
