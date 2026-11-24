CREATE TABLE event_entity_versions_v2 (
 owner_user_id TEXT NOT NULL, entity_kind TEXT NOT NULL,
 entity_id TEXT NOT NULL, version INTEGER NOT NULL CHECK(version > 0),
 PRIMARY KEY(owner_user_id,entity_kind,entity_id)
);
INSERT INTO event_entity_versions_v2 SELECT * FROM event_entity_versions;
DROP TABLE event_entity_versions;
ALTER TABLE event_entity_versions_v2 RENAME TO event_entity_versions;
