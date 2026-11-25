-- Immutable request and bounded target snapshot, with CAS progress updates.
-- Targets are versioned together so one status read never mixes revisions.
CREATE TABLE IF NOT EXISTS bridge_fleet_applications (
    application_id TEXT PRIMARY KEY,
    bridge_id TEXT NOT NULL REFERENCES bridges(bridge_id) ON DELETE CASCADE,
    owner_user_id TEXT NOT NULL REFERENCES users(user_id),
    request_id TEXT NOT NULL,
    request_json TEXT NOT NULL,
    authority_json TEXT NOT NULL DEFAULT '',
    revision INTEGER NOT NULL CHECK(revision > 0),
    state TEXT NOT NULL CHECK(state IN ('pending','restarting','ready','partial_failure')),
    application_json TEXT NOT NULL CHECK(json_valid(application_json)),
    UNIQUE(owner_user_id,bridge_id,request_id)
);
CREATE INDEX IF NOT EXISTS fleet_applications_active ON bridge_fleet_applications(state)
WHERE state IN ('pending','restarting','partial_failure');
