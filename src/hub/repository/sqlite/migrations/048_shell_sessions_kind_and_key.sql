-- REQ-SHELL-1: collapse shell_sessions.kind to the three kinds the feature now
-- supports, and make the primary key bridge-qualified.
--
-- KIND. 'command' -> 'run', 'interactive' -> 'shell', and 'agent' is DROPPED.
-- The agent kind only ever meant "key the pty-host daemon by agent_instance_id
-- instead of session_id" (the removed branch in bridge_hub_handle_shell_start);
-- agent terminal panes are served by capture_agent_pane / get_agent_pane and
-- never had a shell_sessions row, so there is no live consumer and the rows are
-- deleted rather than remapped onto a kind that would misdescribe them.
--
-- KEY. session_id was a bare PRIMARY KEY, but ids are minted per-bridge and are
-- neither owner- nor bridge-qualified, so one bridge's INSERT could overwrite
-- another's row -- a CROSS-TENANT clobber, not merely a confusing one. The key
-- becomes (bridge_id, session_id). SQLite cannot ALTER a primary key, so this is
-- the standard table rebuild: new table, copy, drop, rename, recreate indexes.
-- INSERT OR IGNORE on the copy is belt-and-braces only: session_id was UNIQUE
-- before, so no pair can collide on the way in.
--
-- TWO constraints, because they stop two DIFFERENT failures and neither implies
-- the other: the composite PRIMARY KEY (bridge_id, session_id) stops one bridge
-- clobbering another bridge's row on insert, while the UNIQUE index on
-- (owner_user_id, session_id) keeps the owner-scoped read single-row -- that read
-- is `WHERE owner_user_id = ? AND session_id = ? LIMIT 1` and backs kill, attach,
-- signal, restart, set_port and log, so two same-owner rows across two bridges
-- would make it an arbitrary pick that silently acts on the WRONG session.
UPDATE shell_sessions SET kind = 'run'   WHERE kind = 'command';
UPDATE shell_sessions SET kind = 'shell' WHERE kind = 'interactive';
DELETE FROM shell_sessions WHERE kind = 'agent';

CREATE TABLE IF NOT EXISTS shell_sessions_rekeyed (
  session_id        TEXT NOT NULL,
  owner_user_id     TEXT NOT NULL,
  bridge_id         TEXT NOT NULL,
  project_id        TEXT NOT NULL DEFAULT '',
  chain_id          TEXT NOT NULL DEFAULT '',
  agent_instance_id TEXT NOT NULL DEFAULT '',
  kind              TEXT NOT NULL DEFAULT 'run',
  label             TEXT NOT NULL DEFAULT '',
  cmd               TEXT NOT NULL,
  cwd               TEXT NOT NULL DEFAULT '',
  status            TEXT NOT NULL DEFAULT 'starting',
  exit_code         INTEGER,
  pid               INTEGER NOT NULL DEFAULT 0,
  server_port       INTEGER NOT NULL DEFAULT 0,
  started_at        TEXT NOT NULL,
  finished_at       TEXT,
  created_at        TEXT NOT NULL,
  last_activity_at  TEXT,
  PRIMARY KEY (bridge_id, session_id)
);

INSERT OR IGNORE INTO shell_sessions_rekeyed (
  session_id, owner_user_id, bridge_id, project_id, chain_id, agent_instance_id,
  kind, label, cmd, cwd, status, exit_code, pid, server_port,
  started_at, finished_at, created_at, last_activity_at
)
SELECT
  session_id, owner_user_id, bridge_id, project_id, chain_id, agent_instance_id,
  kind, label, cmd, cwd, status, exit_code, pid, server_port,
  started_at, finished_at, created_at, last_activity_at
FROM shell_sessions;

DROP TABLE shell_sessions;
ALTER TABLE shell_sessions_rekeyed RENAME TO shell_sessions;

CREATE INDEX IF NOT EXISTS shell_sessions_bridge  ON shell_sessions(owner_user_id, bridge_id);
CREATE INDEX IF NOT EXISTS shell_sessions_project ON shell_sessions(owner_user_id, project_id);
CREATE INDEX IF NOT EXISTS shell_sessions_chain   ON shell_sessions(owner_user_id, chain_id);
-- run is agent-scoped, so the agent column is a first-class lookup key now.
CREATE INDEX IF NOT EXISTS shell_sessions_agent   ON shell_sessions(owner_user_id, agent_instance_id);
-- Every by-session-id lookup still arrives without a bridge (the REST surface is
-- /api/v1/shells/{session_id}), so owner+session stays an indexed path even though
-- it is no longer the primary key. UNIQUE, not merely indexed: it is the
-- constraint that makes that owner-scoped read single-row by construction rather
-- than by LIMIT 1 picking arbitrarily between two rows.
--
-- This cannot fail on EXISTING data. The pre-048 table had session_id as a bare
-- PRIMARY KEY, so no two rows could share a session_id at all -- let alone two
-- owned by the same user -- and the rebuild above copies that table verbatim. The
-- constraint therefore only ever bites on a FUTURE insert, which is the point: a
-- genuine id collision within one owner becomes a loud, recoverable insert failure
-- instead of a silent wrong-row mutation with no detector anywhere in the system.
CREATE UNIQUE INDEX IF NOT EXISTS shell_sessions_owner_session ON shell_sessions(owner_user_id, session_id);
