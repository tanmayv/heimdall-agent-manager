CREATE TABLE event_state_heads (
 owner_user_id TEXT NOT NULL,
 entity_kind TEXT NOT NULL,
 entity_id TEXT NOT NULL,
 event_type TEXT NOT NULL,
 event_id TEXT NOT NULL,
 entity_version INTEGER NOT NULL,
 PRIMARY KEY(owner_user_id, entity_kind, entity_id, event_type)
);
