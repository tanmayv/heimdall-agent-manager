-- Metadata-only events share the producer's transaction.
CREATE TABLE event_outbox (
 outbox_seq INTEGER PRIMARY KEY AUTOINCREMENT,
 event_id TEXT NOT NULL UNIQUE CHECK(event_id != ''),
 owner_user_id TEXT NOT NULL CHECK(owner_user_id != ''),
 subject TEXT NOT NULL CHECK(subject != ''),
 envelope_json TEXT NOT NULL CHECK(json_valid(envelope_json) AND json_type(envelope_json) = 'object'),
 headers_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(headers_json) AND json_type(headers_json) = 'object'),
 created_at TEXT NOT NULL,
 published_at TEXT
);
CREATE INDEX event_outbox_pending ON event_outbox(outbox_seq) WHERE published_at IS NULL;
CREATE INDEX event_outbox_published ON event_outbox(published_at) WHERE published_at IS NOT NULL;
