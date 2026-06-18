package contracts

Agent_Class :: distinct string
Agent_Instance_ID :: distinct string
Conversation_ID :: distinct string
Wrapper_Instance_ID :: distinct string
Reconnect_Token :: distinct string
Ws_Token :: distinct string
Agent_Token :: distinct string

Client_Kind :: enum {
	Interactive,
}

Client_Access_Mode :: enum {
	Main,
	Copy,
	Read_Only,
}

Client_Capability :: enum {
	Stdin,
	Interrupt,
	Capture,
	Terminate,
}
