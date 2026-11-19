package contracts

// Agent events travel through the bridge envelope. Identity is derived from
// authentication; none of these requests accepts owner/subscriber ids.
Events_Next_Input :: struct {
	wait_ms, limit: int,
}
Events_Ack_Input :: struct {
	event_ids: []string,
}
Events_Watch_Input :: struct {
	chain_id: string,
}
