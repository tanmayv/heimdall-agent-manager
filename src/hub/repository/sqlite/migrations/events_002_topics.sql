CREATE TABLE event_entity_versions (
 owner_user_id TEXT NOT NULL, entity_kind TEXT NOT NULL CHECK(entity_kind IN ('task','chain')),
 entity_id TEXT NOT NULL, version INTEGER NOT NULL CHECK(version > 0),
 PRIMARY KEY(owner_user_id,entity_kind,entity_id)
);
CREATE TABLE event_topics (
 owner_user_id TEXT NOT NULL, topic_key TEXT NOT NULL,
 generation INTEGER NOT NULL CHECK(generation > 0), opened_event_id TEXT NOT NULL,
 resolved_generation INTEGER NOT NULL DEFAULT 0,
 resolved_at TEXT NOT NULL DEFAULT '', resolved_by_event_id TEXT NOT NULL DEFAULT '',
 PRIMARY KEY(owner_user_id,topic_key)
);
