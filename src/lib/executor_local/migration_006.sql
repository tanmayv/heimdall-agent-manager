DROP TRIGGER readiness_scope;
DROP TRIGGER runtime_immutable;
DROP TRIGGER runtime_no_delete;
ALTER TABLE executor_runtime RENAME TO executor_runtime_v5;

CREATE TABLE executor_runtime (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), schema_version INTEGER NOT NULL CHECK(schema_version=6),
 account_id TEXT NOT NULL, executor_bridge_id TEXT NOT NULL, operator_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL CHECK(incarnation>0), clock_high_ms INTEGER NOT NULL CHECK(clock_high_ms>=0),
 recovery_state TEXT NOT NULL CHECK(recovery_state IN ('ready','reconciling','clock_uncertain')),
 policy_revision INTEGER NOT NULL DEFAULT 0 CHECK(policy_revision>=0), device_capacity INTEGER NOT NULL DEFAULT 0 CHECK(device_capacity BETWEEN 0 AND 128)
);
CREATE TRIGGER runtime_immutable BEFORE UPDATE ON executor_runtime
WHEN NEW.singleton IS NOT OLD.singleton OR NEW.account_id IS NOT OLD.account_id OR NEW.executor_bridge_id IS NOT OLD.executor_bridge_id
 OR NEW.operator_key_id IS NOT OLD.operator_key_id OR NEW.schema_version IS NOT OLD.schema_version
 OR NEW.incarnation<OLD.incarnation OR NEW.clock_high_ms<OLD.clock_high_ms OR NEW.policy_revision<OLD.policy_revision
BEGIN SELECT RAISE(ABORT,'immutable executor identity or version'); END;
CREATE TRIGGER runtime_no_delete BEFORE DELETE ON executor_runtime BEGIN SELECT RAISE(ABORT,'immutable executor identity'); END;

INSERT INTO executor_runtime SELECT singleton,6,account_id,executor_bridge_id,operator_key_id,incarnation,clock_high_ms,recovery_state,policy_revision,device_capacity FROM executor_runtime_v5;
DROP TABLE executor_runtime_v5;

-- Control credentials are Bridge-only and never part of child material.
CREATE TABLE executor_controls (
 reservation_id TEXT PRIMARY KEY REFERENCES executor_reservations(reservation_id),
 renewal_secret TEXT NOT NULL CHECK(length(renewal_secret)=64)
);
CREATE TRIGGER control_no_update BEFORE UPDATE ON executor_controls BEGIN SELECT RAISE(ABORT,'immutable control credential'); END;
CREATE TRIGGER control_no_delete BEFORE DELETE ON executor_controls BEGIN SELECT RAISE(ABORT,'retained control credential'); END;
-- Accepted signed deadlines do not authenticate a child until daemon delivery
-- has been confirmed. Lost replies retry the exact same version and expiry.
CREATE TABLE executor_renewals (
 reservation_id TEXT NOT NULL REFERENCES executor_reservations(reservation_id),
 deadline_version INTEGER NOT NULL CHECK(deadline_version>1),
 action_digest TEXT NOT NULL, document TEXT NOT NULL CHECK(json_valid(document)),
 state TEXT NOT NULL CHECK(state IN ('pending','confirmed')),
 PRIMARY KEY(reservation_id,deadline_version)
);
CREATE TRIGGER renewal_immutable BEFORE UPDATE ON executor_renewals
WHEN NEW.reservation_id IS NOT OLD.reservation_id OR NEW.deadline_version IS NOT OLD.deadline_version
 OR NEW.action_digest IS NOT OLD.action_digest OR NEW.document IS NOT OLD.document
 OR (OLD.state='confirmed' AND NEW.state!='confirmed')
BEGIN SELECT RAISE(ABORT,'immutable signed renewal'); END;
CREATE TRIGGER renewal_no_delete BEFORE DELETE ON executor_renewals BEGIN SELECT RAISE(ABORT,'retained renewal'); END;

CREATE TRIGGER readiness_scope BEFORE INSERT ON executor_readiness
WHEN NOT EXISTS(SELECT 1 FROM executor_reservations r JOIN executor_bootstraps b USING(reservation_id)
 WHERE r.reservation_id=NEW.reservation_id AND r.instance_id=NEW.instance_id AND r.launch_key=NEW.launch_key
 AND json_extract(b.document,'$.token_generation')=NEW.token_generation
 AND r.state='active' AND r.launch_state='confirmed'
 AND r.executor_incarnation=NEW.executor_incarnation AND r.observed_incarnation=NEW.executor_incarnation
 AND NEW.executor_incarnation=(SELECT incarnation FROM executor_runtime)
 AND NEW.ready_ms<r.expires_ms AND NEW.ready_ms<r.hard_ms)
BEGIN SELECT RAISE(ABORT,'readiness requires current exact child'); END;
