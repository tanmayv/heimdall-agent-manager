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

// catalog_cursor is an opaque decimal HEIM_EVENTS sequence. It never replaces
// the per-connection UI stream_epoch/stream_seq transport watermark.
Catalog_Replay_Input :: struct {
    catalog_cursor: string,
    limit: int,
}
