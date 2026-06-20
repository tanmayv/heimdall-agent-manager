package memory_provider

import contracts "odin_test:contracts"

Append_Event_Proc :: proc(state: rawptr, event: contracts.Memory_Event) -> contracts.Memory_Append_Response
Replay_Proc :: proc(state: rawptr) -> contracts.Memory_Replay_Response
List_Records_Proc :: proc(state: rawptr, request: contracts.Memory_List_Request) -> contracts.Memory_List_Response
History_Proc :: proc(state: rawptr, request: contracts.Memory_History_Request) -> contracts.Memory_History_Response

Memory_Provider :: struct {
	name: string,
	capabilities: []contracts.Memory_Provider_Capability,
	state: rawptr,
	append_event: Append_Event_Proc,
	replay: Replay_Proc,
	list_records: List_Records_Proc,
	history: History_Proc,
}

append_event :: proc(provider: ^Memory_Provider, event: contracts.Memory_Event) -> contracts.Memory_Append_Response {
	return provider.append_event(provider.state, event)
}

replay :: proc(provider: ^Memory_Provider) -> contracts.Memory_Replay_Response {
	return provider.replay(provider.state)
}

list_records :: proc(provider: ^Memory_Provider, request: contracts.Memory_List_Request) -> contracts.Memory_List_Response {
	return provider.list_records(provider.state, request)
}

history :: proc(provider: ^Memory_Provider, request: contracts.Memory_History_Request) -> contracts.Memory_History_Response {
	return provider.history(provider.state, request)
}
