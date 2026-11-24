package contracts

import "core:encoding/json"

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

// Public catalog/producer envelope. Internal timer messages are a separate wire shape.
Event_Entity :: struct { kind, id: string }
Event_Envelope :: struct {
 event_id, type, class, owner_user_id: string,
 entity: Event_Entity,
 entity_version: i64,
 actor, occurred_at: string,
 data: json.Object,
 topic_key: string `json:"topic_key,omitempty"`,
 topic_generation: i64 `json:"topic_generation,omitempty"`,
}
