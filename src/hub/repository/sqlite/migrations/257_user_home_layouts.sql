-- Durable, account-owned Home layout preferences. Version zero means no row.
CREATE TABLE IF NOT EXISTS user_home_layouts (
    owner_user_id TEXT PRIMARY KEY NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    revision INTEGER NOT NULL CHECK (revision >= 1 AND revision <= 9007199254740991),
    payload_json TEXT NOT NULL CHECK (length(CAST(payload_json AS BLOB)) <= 32768)
);
