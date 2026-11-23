-- actions_001_reset.sql : no backfill; existing action rows are discarded (R1)
BEGIN;

DROP TRIGGER IF EXISTS action_revision_insert;
DROP TRIGGER IF EXISTS action_revision_update;
DROP TRIGGER IF EXISTS action_revision_delete;
DROP TRIGGER IF EXISTS action_revision_member_insert;
DROP TRIGGER IF EXISTS action_revision_member_delete;
DROP TRIGGER IF EXISTS action_revision_member_update;
DROP TABLE IF EXISTS action_schedule_revision;
DROP TABLE IF EXISTS scheduled_prompts;
DROP TABLE IF EXISTS actions;

CREATE TABLE actions (
  action_id TEXT PRIMARY KEY CHECK(action_id != ''),
  owner_user_id TEXT NOT NULL CHECK(owner_user_id != ''),
  name TEXT NOT NULL DEFAULT '',
  prompt_text TEXT NOT NULL,
  target_kind TEXT NOT NULL CHECK(target_kind IN ('agent','instance','bot')),
  target_agent_id TEXT NOT NULL DEFAULT '',
  target_project_id TEXT NOT NULL DEFAULT '',
  target_instance_id TEXT NOT NULL DEFAULT '',
  target_bot_id TEXT NOT NULL DEFAULT '',
  instance_strategy TEXT NOT NULL DEFAULT 'reuse' CHECK(instance_strategy IN ('reuse','fresh_per_run')),
  placement_selector TEXT NOT NULL DEFAULT 'first',
  last_spawned_instance_id TEXT NOT NULL DEFAULT '',
  enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
  min_interval_s INTEGER NOT NULL DEFAULT 30 CHECK(min_interval_s BETWEEN 5 AND 86400),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX actions_owner ON actions(owner_user_id);
CREATE TRIGGER actions_owner_immutable BEFORE UPDATE OF owner_user_id ON actions
  BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;

-- Ordered placement rules (target_kind 'agent'). Row shape = placement.Rule.
CREATE TABLE action_target_rules (
  action_id TEXT NOT NULL REFERENCES actions(action_id) ON DELETE CASCADE,
  position  INTEGER NOT NULL CHECK(position >= 0),
  bridge_id TEXT NOT NULL,   -- a bridge id or '*'
  provider  TEXT NOT NULL,   -- a catalog provider id or '*'
  model     TEXT NOT NULL,   -- a model id or '*'
  PRIMARY KEY(action_id, position),
  CHECK(NOT (provider = '*' AND model <> '*'))
);

CREATE TABLE action_triggers (
  trigger_id TEXT PRIMARY KEY CHECK(trigger_id != ''),
  action_id TEXT NOT NULL REFERENCES actions(action_id) ON DELETE CASCADE,
  owner_user_id TEXT NOT NULL,
  kind TEXT NOT NULL,                        -- registry key; no CHECK, so a new kind needs no DDL
  config TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(config)),
  event_type TEXT NOT NULL,                  -- derived by Trigger_Kind.compile
  subject_filter TEXT NOT NULL,              -- derived by Trigger_Kind.compile
  match_key TEXT NOT NULL DEFAULT '',        -- S2: subject_filter when it has no '*' token, else '' (6.6.1)
  data_filter TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(data_filter)),
  enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
  rev INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX action_triggers_match  ON action_triggers(owner_user_id, event_type, match_key) WHERE enabled = 1;
CREATE INDEX action_triggers_action ON action_triggers(action_id);

-- One row per matched occurrence.
CREATE TABLE action_runs (
  run_id TEXT PRIMARY KEY CHECK(run_id != ''),
  action_id TEXT NOT NULL REFERENCES actions(action_id) ON DELETE CASCADE,
  trigger_id TEXT NOT NULL,                  -- no foreign key: the trigger may be deleted later
  owner_user_id TEXT NOT NULL,
  occurrence_key TEXT NOT NULL UNIQUE,       -- '<trigger_id>:<event key>'
  event_type TEXT NOT NULL,
  event_id TEXT NOT NULL DEFAULT '',
  stream_sequence INTEGER NOT NULL DEFAULT 0,
  event_params TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(event_params)),
  state TEXT NOT NULL CHECK(state IN ('queued','deferred','routed','delivered','joined','skipped','failed')),
  not_before TEXT NOT NULL DEFAULT '',       -- state 'deferred': earliest delivery time
  joined_run_id TEXT NOT NULL DEFAULT '',    -- state 'joined': the run it merged into
  reason TEXT NOT NULL DEFAULT '',           -- 6.8.1
  rule_position INTEGER NOT NULL DEFAULT -1,
  target_instance_id TEXT NOT NULL DEFAULT '',
  message_id TEXT NOT NULL DEFAULT '',
  delivery_id TEXT NOT NULL DEFAULT '',      -- the current delivery of this run (6.11); '' before routing
  created_at TEXT NOT NULL,
  started_at TEXT NOT NULL DEFAULT '',       -- set when the run becomes 'routed'
  finished_at TEXT NOT NULL DEFAULT ''
);
CREATE UNIQUE INDEX action_runs_one_open ON action_runs(action_id) WHERE state IN ('queued','deferred','routed');
CREATE INDEX action_runs_action ON action_runs(action_id, created_at);
CREATE INDEX action_runs_joined ON action_runs(joined_run_id) WHERE state = 'joined';
CREATE INDEX action_runs_due    ON action_runs(state, not_before) WHERE state IN ('queued','deferred'); -- S2: runs_due, runs_deferred (6.16)

COMMIT;
