CREATE TABLE IF NOT EXISTS experiments (
    owner_user_id TEXT NOT NULL,
    key           TEXT NOT NULL,
    enabled       INTEGER NOT NULL DEFAULT 0,
    updated_at    TEXT NOT NULL,
    PRIMARY KEY (owner_user_id, key)
);
CREATE INDEX IF NOT EXISTS experiments_owner ON experiments(owner_user_id);
