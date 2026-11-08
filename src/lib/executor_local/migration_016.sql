-- Native local launches: the Bridge admits its own trusted launch command.
-- Device approval drafts, slot policy, capacity and signed directory mappings
-- no longer gate ordinary local launches. Retained rows are kept unchanged.
DROP TRIGGER runtime_immutable;
DROP TRIGGER runtime_no_delete;
DROP TRIGGER readiness_scope;
DROP TRIGGER reservation_shared_admission;
DROP TRIGGER legacy_barrier_admission;
DROP TRIGGER legacy_command_admission;
DROP TRIGGER legacy_command_transition;
DROP TRIGGER legacy_observation_admission;
DROP TRIGGER native_journal_executor_runtime_insert;
DROP TRIGGER native_journal_executor_runtime_update;
DROP TRIGGER native_journal_executor_runtime_delete;
DROP TRIGGER legacy_action_admission;
DROP TRIGGER legacy_action_transition;
DROP TRIGGER legacy_action_draft_admission;
DROP TRIGGER legacy_action_nudge_admission;
DROP TRIGGER legacy_action_effect_admission;
DROP TRIGGER local_shared_admission;
DROP VIEW executor_live_resources;
ALTER TABLE executor_runtime RENAME TO executor_runtime_v15;
CREATE TABLE executor_runtime (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), schema_version INTEGER NOT NULL CHECK(schema_version=16),
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
INSERT INTO executor_runtime SELECT singleton,16,account_id,executor_bridge_id,operator_key_id,incarnation,clock_high_ms,recovery_state,policy_revision,device_capacity FROM executor_runtime_v15;
DROP TABLE executor_runtime_v15;
INSERT INTO executor_slots VALUES('native_local','',0) ON CONFLICT(slot_id) DO UPDATE SET provider_profile='',enabled=0;
CREATE VIEW executor_live_resources AS
 SELECT slot_id,instance_id,directory_key FROM executor_reservations WHERE state!='released'
 UNION ALL SELECT slot_id,instance_id,directory_key FROM executor_local_launches WHERE state!='released' AND slot_id!='native_local';
CREATE TRIGGER readiness_scope BEFORE INSERT ON executor_readiness
WHEN NOT EXISTS(SELECT 1 FROM executor_reservations r JOIN executor_bootstraps b USING(reservation_id)
 WHERE r.reservation_id=NEW.reservation_id AND r.instance_id=NEW.instance_id AND r.launch_key=NEW.launch_key
 AND json_extract(b.document,'$.token_generation')=NEW.token_generation
 AND r.state='active' AND r.launch_state='confirmed'
 AND r.executor_incarnation=NEW.executor_incarnation AND r.observed_incarnation=NEW.executor_incarnation
 AND NEW.executor_incarnation=(SELECT incarnation FROM executor_runtime)
 AND NEW.ready_ms<r.expires_ms AND NEW.ready_ms<r.hard_ms)
BEGIN SELECT RAISE(ABORT,'readiness requires current exact child'); END;
CREATE TRIGGER reservation_shared_admission BEFORE INSERT ON executor_reservations
WHEN NEW.state!='released' AND (
 (SELECT count(*) FROM executor_live_resources)>=(SELECT device_capacity FROM executor_runtime)
 OR EXISTS(SELECT 1 FROM executor_live_resources WHERE slot_id=NEW.slot_id OR instance_id=NEW.instance_id
   OR (directory_key!='' AND directory_key=NEW.directory_key))
 OR EXISTS(SELECT 1 FROM executor_local_launches WHERE state!='released' AND instance_id=NEW.instance_id))
BEGIN SELECT RAISE(ABORT,'shared executor resource conflict'); END;
CREATE TRIGGER legacy_barrier_admission BEFORE INSERT ON executor_legacy_barriers
WHEN NEW.installed_incarnation!=(SELECT incarnation FROM executor_runtime)
BEGIN SELECT RAISE(ABORT,'legacy barrier requires current executor'); END;
CREATE TRIGGER legacy_command_admission BEFORE INSERT ON executor_legacy_commands
WHEN NEW.state!='running' OR NEW.admitted_incarnation!=(SELECT incarnation FROM executor_runtime)
 OR EXISTS(SELECT 1 FROM executor_legacy_barriers WHERE chain_id=NEW.chain_id)
BEGIN SELECT RAISE(ABORT,'legacy dispatch fenced'); END;
CREATE TRIGGER legacy_command_transition BEFORE UPDATE ON executor_legacy_commands
WHEN NEW.command_id IS NOT OLD.command_id OR NEW.chain_id IS NOT OLD.chain_id
 OR NEW.input_digest IS NOT OLD.input_digest OR NEW.admitted_incarnation IS NOT OLD.admitted_incarnation
 OR OLD.state!='running' OR NEW.state!='returned'
 OR NEW.admitted_incarnation!=(SELECT incarnation FROM executor_runtime)
BEGIN SELECT RAISE(ABORT,'immutable legacy command or stale completion'); END;
CREATE TRIGGER legacy_observation_admission BEFORE INSERT ON executor_legacy_observations
WHEN NEW.observed_incarnation!=(SELECT incarnation FROM executor_runtime)
 OR EXISTS(SELECT 1 FROM executor_legacy_observations WHERE observation_id=NEW.observation_id)
BEGIN SELECT RAISE(ABORT,'observation requires current executor'); END;
CREATE TRIGGER native_journal_executor_runtime_insert AFTER INSERT ON executor_runtime BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_runtime_update AFTER UPDATE ON executor_runtime BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_runtime_delete AFTER DELETE ON executor_runtime BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER legacy_action_admission BEFORE INSERT ON executor_legacy_actions
WHEN NEW.observed_incarnation!=(SELECT incarnation FROM executor_runtime) OR NEW.state!='received' OR NEW.previous_state!=''
 OR NEW.action_id!=(SELECT sequence+1 FROM executor_native_journal WHERE singleton=1)
BEGIN SELECT RAISE(ABORT,'action observation requires current journal'); END;
CREATE TRIGGER legacy_action_transition BEFORE UPDATE ON executor_legacy_actions
WHEN NEW.action_id IS NOT OLD.action_id OR NEW.observed_incarnation IS NOT OLD.observed_incarnation
 OR NEW.command_id IS NOT OLD.command_id OR NEW.command_kind IS NOT OLD.command_kind
 OR NEW.chain_claim IS NOT OLD.chain_claim OR NEW.packet_digest IS NOT OLD.packet_digest
 OR NEW.observed_incarnation!=(SELECT incarnation FROM executor_runtime)
 OR NEW.previous_state IS NOT OLD.state
 OR NOT ((OLD.state='received' AND NEW.state IN ('prepared','discarded'))
      OR (OLD.state='prepared' AND NEW.state IN ('running','discarded'))
      OR (OLD.state='running' AND NEW.state='returned'))
BEGIN SELECT RAISE(ABORT,'immutable action evidence or invalid transition'); END;
CREATE TRIGGER legacy_action_draft_admission BEFORE INSERT ON executor_legacy_action_drafts
WHEN NEW.observed_incarnation!=(SELECT incarnation FROM executor_runtime)
 OR NOT EXISTS(SELECT 1 FROM executor_legacy_actions WHERE action_id=NEW.action_id
  AND observed_incarnation=NEW.observed_incarnation AND state='running')
BEGIN SELECT RAISE(ABORT,'draft association requires current running occurrence'); END;
CREATE TRIGGER legacy_action_nudge_admission BEFORE INSERT ON executor_legacy_action_nudges
WHEN NEW.observed_incarnation!=(SELECT incarnation FROM executor_runtime)
 OR NOT EXISTS(SELECT 1 FROM executor_legacy_actions WHERE action_id=NEW.action_id AND observed_incarnation=NEW.observed_incarnation AND state='running')
 OR NOT EXISTS(SELECT 1 FROM executor_local_launches WHERE launch_id=NEW.launch_id AND launch_key=NEW.launch_key
  AND instance_id=NEW.instance_id AND state='active' AND observed_incarnation=NEW.observed_incarnation)
BEGIN SELECT RAISE(ABORT,'nudge requires current exact native child'); END;
CREATE TRIGGER legacy_action_effect_admission BEFORE INSERT ON executor_legacy_action_effects
WHEN NEW.observed_incarnation!=(SELECT incarnation FROM executor_runtime)
 OR NOT EXISTS(SELECT 1 FROM executor_legacy_actions WHERE action_id=NEW.action_id AND state='running' AND observed_incarnation=NEW.observed_incarnation)
BEGIN SELECT RAISE(ABORT,'effect observation requires current running occurrence'); END;
CREATE TRIGGER local_shared_admission BEFORE INSERT ON executor_local_launches
WHEN NEW.state!='admitted' OR NEW.slot_id!='native_local' OR NEW.directory_key!=''
 OR EXISTS(SELECT 1 FROM executor_local_launches WHERE state!='released' AND instance_id=NEW.instance_id)
 OR EXISTS(SELECT 1 FROM executor_reservations WHERE state!='released' AND instance_id=NEW.instance_id)
BEGIN SELECT RAISE(ABORT,'shared executor resource conflict'); END;
