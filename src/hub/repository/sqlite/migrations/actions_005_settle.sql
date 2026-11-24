BEGIN;
ALTER TABLE action_triggers ADD COLUMN delay_s INTEGER NOT NULL DEFAULT 0 CHECK(delay_s BETWEEN 0 AND 86400);
ALTER TABLE action_runs ADD COLUMN delay_s INTEGER NOT NULL DEFAULT 0 CHECK(delay_s BETWEEN 0 AND 86400);
ALTER TABLE action_runs ADD COLUMN settle_key TEXT NOT NULL DEFAULT '';
ALTER TABLE action_runs ADD COLUMN settle_pending INTEGER NOT NULL DEFAULT 0 CHECK(settle_pending IN (0,1));
DROP INDEX action_runs_one_open;
CREATE UNIQUE INDEX action_runs_one_open ON action_runs(action_id) WHERE state IN ('queued','deferred','routed') AND settle_pending=0;
CREATE UNIQUE INDEX action_runs_settle_pending ON action_runs(trigger_id,settle_key) WHERE state='deferred' AND settle_pending=1;
COMMIT;
