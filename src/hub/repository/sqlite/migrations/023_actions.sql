CREATE TABLE IF NOT EXISTS actions (
  id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  target_instance_id TEXT NOT NULL,
  prompt_text TEXT NOT NULL,
  cron_expr TEXT NOT NULL DEFAULT '',
  timezone TEXT NOT NULL DEFAULT 'UTC',
  blackout_dates TEXT NOT NULL DEFAULT '[]',
  active_from TEXT NOT NULL DEFAULT '',
  active_until TEXT NOT NULL DEFAULT '',
  target_run_at TEXT NOT NULL DEFAULT '',
  interval TEXT NOT NULL DEFAULT '',
  state TEXT NOT NULL DEFAULT 'active',
  in_flight INTEGER NOT NULL DEFAULT 0,
  leased_at TEXT NOT NULL DEFAULT '',
  deleted_at TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_actions_target ON actions(target_instance_id);
CREATE INDEX IF NOT EXISTS idx_actions_owner_run ON actions(owner_user_id, target_run_at);
CREATE INDEX IF NOT EXISTS idx_actions_due ON actions(target_run_at) WHERE state = 'active' AND in_flight = 0 AND deleted_at = '';
CREATE TRIGGER IF NOT EXISTS actions_owner_immutable BEFORE UPDATE OF owner_user_id ON actions BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;

CREATE TABLE IF NOT EXISTS scheduled_prompts (
  id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL DEFAULT '',
  target_instance_id TEXT NOT NULL DEFAULT '',
  prompt_text TEXT NOT NULL DEFAULT '',
  target_run_at TEXT NOT NULL DEFAULT '',
  interval TEXT NOT NULL DEFAULT '',
  state TEXT NOT NULL DEFAULT 'active',
  in_flight INTEGER NOT NULL DEFAULT 0,
  leased_at TEXT NOT NULL DEFAULT '',
  deleted_at TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL DEFAULT ''
);

INSERT OR IGNORE INTO actions (
  id, owner_user_id, target_instance_id, prompt_text, target_run_at,
  interval, state, in_flight, leased_at, deleted_at, created_at, updated_at
)
SELECT
  id, owner_user_id, target_instance_id, prompt_text, target_run_at,
  interval, state, in_flight, leased_at, deleted_at, created_at, updated_at
FROM scheduled_prompts;
