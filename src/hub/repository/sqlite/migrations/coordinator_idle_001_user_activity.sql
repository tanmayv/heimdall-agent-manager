-- Coordinator idle-stop timers (REQ-CIS-1): the durable per-instance stamp of
-- the last USER event addressed to it (user chat, question answers, action
-- cards, user verdicts and requirement changes on its chain's tasks). Only
-- those events write it; heartbeats, agent output and notices never do. It is
-- deliberately outside the instance upsert so a stale save cannot roll it back.
ALTER TABLE agent_instances ADD COLUMN user_activity_at TEXT NOT NULL DEFAULT '';
