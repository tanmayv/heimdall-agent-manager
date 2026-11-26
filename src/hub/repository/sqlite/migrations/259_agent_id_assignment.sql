-- SCHED-0a (spec art_18eb828949cd9431, sections 6.4 and 11): agent-id assignment.
-- Additive only. The role columns (task_chain_fleets.roles_json,
-- paused_roles_json, task_leases.review_role) are dropped by SCHED-0b together
-- with the code that still reads them.

-- 1. Fleet row pause is one boolean. The repository keeps it derived from
--    paused_roles_json until SCHED-0b; a row paused for only some roles becomes
--    fully paused (fail closed) and is reported to the coordinator at boot.
ALTER TABLE task_chain_fleets ADD COLUMN paused INTEGER NOT NULL DEFAULT 0;
UPDATE task_chain_fleets SET paused = 1 WHERE trim(paused_roles_json) NOT IN ('', '[]');

-- 2. Chain cap (SCHED-1b). 0 = unlimited.
ALTER TABLE task_chains ADD COLUMN max_parallel INTEGER NOT NULL DEFAULT 0;
ALTER TABLE task_chains ADD COLUMN review_reserve INTEGER NOT NULL DEFAULT 0;

-- 3. Projections of brief_json for `lease next` (SCHED-1c). brief_json stays the
--    source of truth. The assignee is a virtual generated column, so it can never
--    drift from the brief; reviewers are kept in step by triggers on every task
--    write, whatever path wrote it. Only agent ids are projected: the literal
--    `user` reviewer is not an agent.
ALTER TABLE tasks ADD COLUMN assignee_agent_id TEXT GENERATED ALWAYS AS (
  CASE WHEN json_valid(brief_json) AND json_type(brief_json, '$.assignee') = 'text'
       THEN trim(json_extract(brief_json, '$.assignee')) ELSE '' END
) VIRTUAL;
CREATE INDEX IF NOT EXISTS idx_tasks_chain_assignee_state ON tasks(chain_id, assignee_agent_id, state);

CREATE TABLE IF NOT EXISTS task_reviewers (
  task_id       TEXT NOT NULL,
  agent_id      TEXT NOT NULL,
  chain_id      TEXT NOT NULL,
  owner_user_id TEXT NOT NULL,
  PRIMARY KEY (task_id, agent_id)
);
CREATE INDEX IF NOT EXISTS idx_task_reviewers_chain_agent ON task_reviewers(chain_id, agent_id);

CREATE TRIGGER IF NOT EXISTS task_reviewers_after_task_insert AFTER INSERT ON tasks BEGIN
  INSERT OR IGNORE INTO task_reviewers (task_id, agent_id, chain_id, owner_user_id)
  SELECT NEW.task_id, trim(r.value), NEW.chain_id, NEW.owner_user_id
  FROM json_each(CASE WHEN json_valid(NEW.brief_json) AND json_type(NEW.brief_json, '$.reviewers') = 'array'
                      THEN json_extract(NEW.brief_json, '$.reviewers') ELSE '[]' END) r
  WHERE r.type = 'text' AND trim(r.value) NOT IN ('', 'user');
END;

CREATE TRIGGER IF NOT EXISTS task_reviewers_after_brief_update AFTER UPDATE OF brief_json, chain_id ON tasks BEGIN
  DELETE FROM task_reviewers WHERE task_id = OLD.task_id;
  INSERT OR IGNORE INTO task_reviewers (task_id, agent_id, chain_id, owner_user_id)
  SELECT NEW.task_id, trim(r.value), NEW.chain_id, NEW.owner_user_id
  FROM json_each(CASE WHEN json_valid(NEW.brief_json) AND json_type(NEW.brief_json, '$.reviewers') = 'array'
                      THEN json_extract(NEW.brief_json, '$.reviewers') ELSE '[]' END) r
  WHERE r.type = 'text' AND trim(r.value) NOT IN ('', 'user');
END;

CREATE TRIGGER IF NOT EXISTS task_reviewers_after_task_delete AFTER DELETE ON tasks BEGIN
  DELETE FROM task_reviewers WHERE task_id = OLD.task_id;
END;

INSERT OR IGNORE INTO task_reviewers (task_id, agent_id, chain_id, owner_user_id)
SELECT t.task_id, trim(r.value), t.chain_id, t.owner_user_id
FROM tasks t, json_each(CASE WHEN json_valid(t.brief_json) AND json_type(t.brief_json, '$.reviewers') = 'array'
                             THEN json_extract(t.brief_json, '$.reviewers') ELSE '[]' END) r
WHERE r.type = 'text' AND trim(r.value) NOT IN ('', 'user');

-- 4. One-shot data mapping at the next boot (taskv2/sched0_migration.odin):
--    review roles folded into reviewers, assignees for true soloist chains,
--    holds and one alert per chain for what cannot be mapped. The role data it
--    needs is snapshotted here, so the SCHED-0b column drops cannot remove it
--    before the boot step has run. A database with no task-system data has
--    nothing to map and gets no marker.
CREATE TABLE IF NOT EXISTS sched0_fleet_roles (
  chain_id          TEXT NOT NULL,
  agent_id          TEXT NOT NULL,
  roles_json        TEXT NOT NULL DEFAULT '',
  paused_roles_json TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (chain_id, agent_id)
);
INSERT OR IGNORE INTO sched0_fleet_roles (chain_id, agent_id, roles_json, paused_roles_json)
SELECT task_chain_id, agent_id, roles_json, paused_roles_json FROM task_chain_fleets;

CREATE TABLE IF NOT EXISTS sched0_migration_pending (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1)
);
INSERT OR IGNORE INTO sched0_migration_pending (singleton)
SELECT 1 WHERE EXISTS (SELECT 1 FROM tasks) OR EXISTS (SELECT 1 FROM task_chain_fleets);
