-- 034_cards.sql: Create cards table for Curator action cards feature (REQ-CARD-1)
CREATE TABLE IF NOT EXISTS cards (
  card_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  project_id TEXT NOT NULL,
  title TEXT NOT NULL,
  rationale TEXT NOT NULL DEFAULT '',
  scope TEXT NOT NULL DEFAULT 'project',
  provider TEXT NOT NULL DEFAULT '',
  confidence REAL NOT NULL DEFAULT 1.0,
  source_refs_json TEXT NOT NULL DEFAULT '[]',
  status TEXT NOT NULL DEFAULT 'pending',
  operations_json TEXT NOT NULL DEFAULT '[]',
  guard_json TEXT NOT NULL DEFAULT '{}',
  snooze_until TEXT NOT NULL DEFAULT '',
  ttl_at TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_cards_owner ON cards(owner_user_id);
CREATE INDEX IF NOT EXISTS idx_cards_project ON cards(project_id);
CREATE INDEX IF NOT EXISTS idx_cards_status ON cards(status);
CREATE INDEX IF NOT EXISTS idx_cards_owner_status ON cards(owner_user_id, status);
CREATE TRIGGER IF NOT EXISTS cards_owner_immutable BEFORE UPDATE OF owner_user_id ON cards BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;
