-- Shell command job tracking (REQ-15). The bridge runs shell commands LOCALLY and
-- reports STATUS ONLY to the hub (never output). The hub stores lightweight job
-- metadata so the UI can show a background-jobs list; command output lives only on
-- the bridge host and is never stored here. On completion the hub notifies the
-- agent via the transient nudge path (no chat message is stored).
CREATE TABLE IF NOT EXISTS shell_jobs (
  exec_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  agent_instance_id TEXT NOT NULL,
  cmd TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'running',
  exit_code INTEGER,
  started_at TEXT NOT NULL,
  finished_at TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS shell_jobs_instance ON shell_jobs(owner_user_id, agent_instance_id);
