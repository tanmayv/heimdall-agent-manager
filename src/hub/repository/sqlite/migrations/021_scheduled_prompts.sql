CREATE TABLE IF NOT EXISTS scheduled_prompts (
  id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  target_instance_id TEXT NOT NULL,
  prompt_text TEXT NOT NULL,
  target_run_at TEXT NOT NULL,
  interval TEXT NOT NULL DEFAULT '',
  state TEXT NOT NULL DEFAULT 'active',
  in_flight INTEGER NOT NULL DEFAULT 0,
  leased_at TEXT NOT NULL DEFAULT '',
  deleted_at TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
