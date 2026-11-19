package domain

// Event_Outbox_Row owns all string fields returned by a repository read.
// Envelope content is restricted to the metadata contract in events-jetstream-spec §3.1.
Event_Outbox_Row :: struct {
	outbox_seq: i64,
	event_id, owner_user_id, subject, envelope_json, headers_json, created_at, published_at: string,
}
event_outbox_row_destroy :: proc(row: ^Event_Outbox_Row) {
	delete(row.event_id); delete(row.owner_user_id); delete(row.subject)
	delete(row.envelope_json); delete(row.headers_json); delete(row.created_at); delete(row.published_at)
	row^ = {}
}
