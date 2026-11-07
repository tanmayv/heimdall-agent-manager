DROP TRIGGER legacy_barrier_admission;
DROP TRIGGER legacy_command_admission;
DROP TRIGGER legacy_command_transition;
DROP TRIGGER reservation_shared_admission;
DROP TRIGGER local_shared_admission;
DROP TRIGGER readiness_scope;
DROP TRIGGER runtime_immutable;
DROP TRIGGER runtime_no_delete;
ALTER TABLE executor_runtime RENAME TO executor_runtime_v10;

CREATE TABLE executor_runtime (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), schema_version INTEGER NOT NULL CHECK(schema_version=11),
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
INSERT INTO executor_runtime SELECT singleton,11,account_id,executor_bridge_id,operator_key_id,incarnation,clock_high_ms,recovery_state,policy_revision,device_capacity FROM executor_runtime_v10;
DROP TABLE executor_runtime_v10;
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
CREATE TRIGGER reservation_shared_admission BEFORE INSERT ON executor_reservations
WHEN NEW.state!='released' AND (
 (SELECT count(*) FROM executor_live_resources)>=(SELECT device_capacity FROM executor_runtime)
 OR EXISTS(SELECT 1 FROM executor_live_resources WHERE slot_id=NEW.slot_id OR instance_id=NEW.instance_id
   OR (directory_key!='' AND directory_key=NEW.directory_key)))
BEGIN SELECT RAISE(ABORT,'shared executor resource conflict'); END;
CREATE TRIGGER local_shared_admission BEFORE INSERT ON executor_local_launches
WHEN NEW.state!='admitted' OR
 (SELECT count(*) FROM executor_live_resources)>=(SELECT device_capacity FROM executor_runtime)
 OR EXISTS(SELECT 1 FROM executor_live_resources WHERE slot_id=NEW.slot_id OR instance_id=NEW.instance_id
   OR (directory_key!='' AND directory_key=NEW.directory_key))
BEGIN SELECT RAISE(ABORT,'shared executor resource conflict'); END;
CREATE TRIGGER readiness_scope BEFORE INSERT ON executor_readiness
WHEN NOT EXISTS(SELECT 1 FROM executor_reservations r JOIN executor_bootstraps b USING(reservation_id)
 WHERE r.reservation_id=NEW.reservation_id AND r.instance_id=NEW.instance_id AND r.launch_key=NEW.launch_key
 AND json_extract(b.document,'$.token_generation')=NEW.token_generation
 AND r.state='active' AND r.launch_state='confirmed'
 AND r.executor_incarnation=NEW.executor_incarnation AND r.observed_incarnation=NEW.executor_incarnation
 AND NEW.executor_incarnation=(SELECT incarnation FROM executor_runtime)
 AND NEW.ready_ms<r.expires_ms AND NEW.ready_ms<r.hard_ms)
BEGIN SELECT RAISE(ABORT,'readiness requires current exact child'); END;
-- Native observation only. No row grants execution or proves historical origin.
-- Missing pre-upgrade history remains unknown.
CREATE TABLE executor_legacy_observations (
 observation_id TEXT PRIMARY KEY CHECK(length(observation_id)=64 AND observation_id NOT GLOB '*[^0-9a-f]*'),
 parent_command_id TEXT NOT NULL CHECK(length(parent_command_id)>0),
 parent_digest TEXT NOT NULL CHECK(length(parent_digest)=64 AND parent_digest NOT GLOB '*[^0-9a-f]*'),
 entry_index INTEGER NOT NULL CHECK(entry_index>=0),
 entry_digest TEXT NOT NULL CHECK(length(entry_digest)=64 AND entry_digest NOT GLOB '*[^0-9a-f]*'),
 chain_id TEXT NOT NULL CHECK(length(chain_id)>0),
 instance_id TEXT NOT NULL CHECK(length(instance_id)>0),
 task_id TEXT NOT NULL, lease_id TEXT NOT NULL,
 native_request_digest TEXT NOT NULL CHECK(length(native_request_digest)=64 AND native_request_digest NOT GLOB '*[^0-9a-f]*'),
 draft_id TEXT NOT NULL REFERENCES executor_local_drafts(draft_id),
 observed_incarnation INTEGER NOT NULL CHECK(observed_incarnation>0),
 UNIQUE(parent_command_id,entry_index,native_request_digest,draft_id)
);
CREATE TRIGGER legacy_observation_admission BEFORE INSERT ON executor_legacy_observations
WHEN NEW.observed_incarnation!=(SELECT incarnation FROM executor_runtime)
 OR EXISTS(SELECT 1 FROM executor_legacy_observations WHERE observation_id=NEW.observation_id)
BEGIN SELECT RAISE(ABORT,'observation requires current executor'); END;
CREATE TRIGGER legacy_observation_no_update BEFORE UPDATE ON executor_legacy_observations BEGIN SELECT RAISE(ABORT,'immutable native observation'); END;
CREATE TRIGGER legacy_observation_no_delete BEFORE DELETE ON executor_legacy_observations BEGIN SELECT RAISE(ABORT,'retained native observation'); END;

-- Database coverage only. Pre-upgrade physical/queued work remains unknown.
CREATE TABLE executor_native_journal (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1),
 sequence INTEGER NOT NULL CHECK(sequence>=0),
 coverage_version INTEGER NOT NULL CHECK(coverage_version=1),
 prior_coverage_unknown INTEGER NOT NULL CHECK(prior_coverage_unknown=1)
);
INSERT INTO executor_native_journal VALUES(1,0,1,1);
CREATE TRIGGER native_journal_no_replace BEFORE INSERT ON executor_native_journal WHEN EXISTS(SELECT 1 FROM executor_native_journal) BEGIN SELECT RAISE(ABORT,'retained native journal'); END;
CREATE TRIGGER native_journal_transition BEFORE UPDATE ON executor_native_journal
WHEN NEW.singleton IS NOT OLD.singleton OR NEW.coverage_version IS NOT OLD.coverage_version
 OR NEW.prior_coverage_unknown IS NOT OLD.prior_coverage_unknown
 OR OLD.sequence=9223372036854775807 OR NEW.sequence!=OLD.sequence+1
BEGIN SELECT RAISE(ABORT,'invalid native journal sequence'); END;
CREATE TRIGGER native_journal_no_delete BEFORE DELETE ON executor_native_journal BEGIN SELECT RAISE(ABORT,'retained native journal'); END;
CREATE TRIGGER native_journal_executor_runtime_insert AFTER INSERT ON executor_runtime BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_runtime_update AFTER UPDATE ON executor_runtime BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_runtime_delete AFTER DELETE ON executor_runtime BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_policies_insert AFTER INSERT ON executor_policies BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_policies_update AFTER UPDATE ON executor_policies BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_policies_delete AFTER DELETE ON executor_policies BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_slots_insert AFTER INSERT ON executor_slots BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_slots_update AFTER UPDATE ON executor_slots BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_slots_delete AFTER DELETE ON executor_slots BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_owner_watermarks_insert AFTER INSERT ON executor_owner_watermarks BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_owner_watermarks_update AFTER UPDATE ON executor_owner_watermarks BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_owner_watermarks_delete AFTER DELETE ON executor_owner_watermarks BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_reservations_insert AFTER INSERT ON executor_reservations BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_reservations_update AFTER UPDATE ON executor_reservations BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_reservations_delete AFTER DELETE ON executor_reservations BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_receipts_insert AFTER INSERT ON executor_receipts BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_receipts_update AFTER UPDATE ON executor_receipts BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_receipts_delete AFTER DELETE ON executor_receipts BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_intents_insert AFTER INSERT ON executor_intents BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_intents_update AFTER UPDATE ON executor_intents BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_intents_delete AFTER DELETE ON executor_intents BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_issuances_insert AFTER INSERT ON executor_issuances BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_issuances_update AFTER UPDATE ON executor_issuances BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_issuances_delete AFTER DELETE ON executor_issuances BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_directories_insert AFTER INSERT ON executor_directories BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_directories_update AFTER UPDATE ON executor_directories BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_directories_delete AFTER DELETE ON executor_directories BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_enrollment_pin_insert AFTER INSERT ON executor_enrollment_pin BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_enrollment_pin_update AFTER UPDATE ON executor_enrollment_pin BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_enrollment_pin_delete AFTER DELETE ON executor_enrollment_pin BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_chain_owners_insert AFTER INSERT ON executor_chain_owners BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_chain_owners_update AFTER UPDATE ON executor_chain_owners BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_chain_owners_delete AFTER DELETE ON executor_chain_owners BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_bootstraps_insert AFTER INSERT ON executor_bootstraps BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_bootstraps_update AFTER UPDATE ON executor_bootstraps BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_bootstraps_delete AFTER DELETE ON executor_bootstraps BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_readiness_insert AFTER INSERT ON executor_readiness BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_readiness_update AFTER UPDATE ON executor_readiness BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_readiness_delete AFTER DELETE ON executor_readiness BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_controls_insert AFTER INSERT ON executor_controls BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_controls_update AFTER UPDATE ON executor_controls BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_controls_delete AFTER DELETE ON executor_controls BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_renewals_insert AFTER INSERT ON executor_renewals BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_renewals_update AFTER UPDATE ON executor_renewals BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_renewals_delete AFTER DELETE ON executor_renewals BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_local_launches_insert AFTER INSERT ON executor_local_launches BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_local_launches_update AFTER UPDATE ON executor_local_launches BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_local_launches_delete AFTER DELETE ON executor_local_launches BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_local_observations_insert AFTER INSERT ON executor_local_observations BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_local_observations_update AFTER UPDATE ON executor_local_observations BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_local_observations_delete AFTER DELETE ON executor_local_observations BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_local_drafts_insert AFTER INSERT ON executor_local_drafts BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_local_drafts_update AFTER UPDATE ON executor_local_drafts BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_local_drafts_delete AFTER DELETE ON executor_local_drafts BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_local_draft_receipts_insert AFTER INSERT ON executor_local_draft_receipts BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_local_draft_receipts_update AFTER UPDATE ON executor_local_draft_receipts BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_local_draft_receipts_delete AFTER DELETE ON executor_local_draft_receipts BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_legacy_barriers_insert AFTER INSERT ON executor_legacy_barriers BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_legacy_barriers_update AFTER UPDATE ON executor_legacy_barriers BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_legacy_barriers_delete AFTER DELETE ON executor_legacy_barriers BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_legacy_resources_insert AFTER INSERT ON executor_legacy_resources BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_legacy_resources_update AFTER UPDATE ON executor_legacy_resources BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_legacy_resources_delete AFTER DELETE ON executor_legacy_resources BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_legacy_commands_insert AFTER INSERT ON executor_legacy_commands BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_legacy_commands_update AFTER UPDATE ON executor_legacy_commands BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_legacy_commands_delete AFTER DELETE ON executor_legacy_commands BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_legacy_observations_insert AFTER INSERT ON executor_legacy_observations BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_legacy_observations_update AFTER UPDATE ON executor_legacy_observations BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
CREATE TRIGGER native_journal_executor_legacy_observations_delete AFTER DELETE ON executor_legacy_observations BEGIN UPDATE executor_native_journal SET sequence=sequence+1 WHERE singleton=1; END;
