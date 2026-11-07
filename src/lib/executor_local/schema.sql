
CREATE TABLE executor_runtime (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), schema_version INTEGER NOT NULL CHECK(schema_version=8),
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
CREATE TABLE executor_policies (revision INTEGER PRIMARY KEY, input_digest TEXT NOT NULL, document TEXT NOT NULL CHECK(json_valid(document)));
CREATE TRIGGER policy_no_update BEFORE UPDATE ON executor_policies BEGIN SELECT RAISE(ABORT,'immutable policy'); END;
CREATE TRIGGER policy_no_delete BEFORE DELETE ON executor_policies BEGIN SELECT RAISE(ABORT,'immutable policy'); END;
CREATE TABLE executor_slots (slot_id TEXT PRIMARY KEY, provider_profile TEXT NOT NULL, enabled INTEGER NOT NULL CHECK(enabled IN (0,1)));
CREATE TABLE executor_owner_watermarks (owner_bridge_id TEXT PRIMARY KEY, incarnation INTEGER NOT NULL CHECK(incarnation>0));
CREATE TRIGGER owner_watermark_monotonic BEFORE UPDATE ON executor_owner_watermarks
WHEN NEW.owner_bridge_id IS NOT OLD.owner_bridge_id OR NEW.incarnation<OLD.incarnation
BEGIN SELECT RAISE(ABORT,'owner incarnation cannot regress'); END;
CREATE TABLE executor_reservations (
 reservation_id TEXT PRIMARY KEY, owner_bridge_id TEXT NOT NULL, operation_id TEXT NOT NULL, chain_id TEXT NOT NULL,
 slot_id TEXT NOT NULL REFERENCES executor_slots(slot_id), instance_id TEXT NOT NULL, directory_key TEXT NOT NULL,
 prepare_digest TEXT NOT NULL, document TEXT NOT NULL CHECK(json_valid(document)),
 owner_incarnation INTEGER NOT NULL CHECK(owner_incarnation>0), executor_incarnation INTEGER NOT NULL CHECK(executor_incarnation>0),
 grant_generation INTEGER NOT NULL CHECK(grant_generation>0), deadline_version INTEGER NOT NULL CHECK(deadline_version>0),
 prepare_until_ms INTEGER NOT NULL CHECK(prepare_until_ms>0), expires_ms INTEGER NOT NULL CHECK(expires_ms>0),
 hard_ms INTEGER NOT NULL CHECK(hard_ms>=expires_ms AND hard_ms>=prepare_until_ms),
 state TEXT NOT NULL CHECK(state IN ('prepared','active','stopping','released')),
 launch_key TEXT NOT NULL, launch_state TEXT NOT NULL CHECK(launch_state IN ('none','queued','uncertain','confirmed','stopped')),
 observed_incarnation INTEGER NOT NULL DEFAULT 0 CHECK(observed_incarnation>=0),
 UNIQUE(owner_bridge_id,operation_id)
);
CREATE UNIQUE INDEX executor_slot_live ON executor_reservations(slot_id) WHERE state!='released';
CREATE UNIQUE INDEX executor_instance_live ON executor_reservations(instance_id) WHERE state!='released';
CREATE UNIQUE INDEX executor_directory_live ON executor_reservations(directory_key) WHERE state!='released' AND directory_key!='';
CREATE TRIGGER reservation_immutable BEFORE UPDATE ON executor_reservations
WHEN NEW.reservation_id IS NOT OLD.reservation_id OR NEW.owner_bridge_id IS NOT OLD.owner_bridge_id
 OR NEW.operation_id IS NOT OLD.operation_id OR NEW.chain_id IS NOT OLD.chain_id OR NEW.slot_id IS NOT OLD.slot_id
 OR NEW.instance_id IS NOT OLD.instance_id OR NEW.directory_key IS NOT OLD.directory_key
 OR NEW.prepare_digest IS NOT OLD.prepare_digest OR NEW.document IS NOT OLD.document
 OR NEW.owner_incarnation IS NOT OLD.owner_incarnation OR NEW.executor_incarnation IS NOT OLD.executor_incarnation
 OR NEW.grant_generation IS NOT OLD.grant_generation OR NEW.prepare_until_ms IS NOT OLD.prepare_until_ms
 OR NEW.hard_ms IS NOT OLD.hard_ms OR NEW.launch_key IS NOT OLD.launch_key
 OR NEW.deadline_version<OLD.deadline_version OR (OLD.state!='prepared' AND NEW.expires_ms<OLD.expires_ms)
 OR (OLD.state='released' AND NEW.state!='released') OR (OLD.state='stopping' AND NEW.state NOT IN ('stopping','released'))
 OR (OLD.state='active' AND NEW.state='prepared')
 OR (OLD.state!='prepared' AND NEW.state='released' AND NEW.launch_state!='stopped')
BEGIN SELECT RAISE(ABORT,'immutable reservation fence or invalid transition'); END;
CREATE TRIGGER reservation_no_delete BEFORE DELETE ON executor_reservations BEGIN SELECT RAISE(ABORT,'retained reservation'); END;
CREATE TABLE executor_receipts (
 owner_bridge_id TEXT NOT NULL, operation_id TEXT NOT NULL, kind TEXT NOT NULL, input_digest TEXT NOT NULL,
 reservation_id TEXT NOT NULL REFERENCES executor_reservations(reservation_id) DEFERRABLE INITIALLY DEFERRED,
 result_json TEXT NOT NULL CHECK(json_valid(result_json)), PRIMARY KEY(owner_bridge_id,operation_id)
);
CREATE TRIGGER receipt_no_update BEFORE UPDATE ON executor_receipts BEGIN SELECT RAISE(ABORT,'immutable executor receipt'); END;
CREATE TRIGGER receipt_no_delete BEFORE DELETE ON executor_receipts BEGIN SELECT RAISE(ABORT,'retained executor receipt'); END;
CREATE TABLE executor_intents (
 reservation_id TEXT NOT NULL REFERENCES executor_reservations(reservation_id), kind TEXT NOT NULL CHECK(kind IN ('launch','stop')),
 state TEXT NOT NULL CHECK(state IN ('pending','uncertain','settled')), claim_incarnation INTEGER NOT NULL DEFAULT 0 CHECK(claim_incarnation>=0),
 PRIMARY KEY(reservation_id,kind)
);

CREATE INDEX executor_deadlines ON executor_reservations(state,expires_ms);
CREATE INDEX executor_intents_due ON executor_intents(state,kind,reservation_id);
CREATE TABLE executor_issuances (
 principal_id TEXT NOT NULL, operation_id TEXT NOT NULL, owner_bridge_id TEXT NOT NULL,
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, input_digest TEXT NOT NULL,
 consent TEXT NOT NULL CHECK(json_valid(consent)), selection TEXT NOT NULL CHECK(json_valid(selection)),
 instance_id TEXT NOT NULL UNIQUE, token_secret TEXT NOT NULL UNIQUE,
 configuration TEXT NOT NULL CHECK(json_valid(configuration)), result_json TEXT NOT NULL CHECK(json_valid(result_json)),
 PRIMARY KEY(principal_id,operation_id)
);
CREATE TRIGGER issuance_no_update BEFORE UPDATE ON executor_issuances BEGIN SELECT RAISE(ABORT,'immutable issuance'); END;
CREATE TRIGGER issuance_no_delete BEFORE DELETE ON executor_issuances BEGIN SELECT RAISE(ABORT,'retained issuance'); END;
CREATE TABLE executor_directories (
 directory_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>0),
 directory_path TEXT NOT NULL, directory_key TEXT NOT NULL, enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),
 input_digest TEXT NOT NULL, document TEXT NOT NULL CHECK(json_valid(document)),
 PRIMARY KEY(directory_id,revision)
);
CREATE TRIGGER directory_no_update BEFORE UPDATE ON executor_directories BEGIN SELECT RAISE(ABORT,'immutable directory mapping'); END;
CREATE TRIGGER directory_no_delete BEFORE DELETE ON executor_directories BEGIN SELECT RAISE(ABORT,'retained directory mapping'); END;
CREATE TABLE executor_enrollment_pin (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), version INTEGER NOT NULL CHECK(version>=0), head_hash TEXT NOT NULL
);
INSERT INTO executor_enrollment_pin VALUES(1,0,'');
CREATE TRIGGER enrollment_pin_monotonic BEFORE UPDATE ON executor_enrollment_pin
WHEN NEW.singleton IS NOT OLD.singleton OR NEW.version<OLD.version OR (NEW.version=OLD.version AND NEW.head_hash IS NOT OLD.head_hash)
BEGIN SELECT RAISE(ABORT,'enrollment pin cannot regress'); END;
CREATE TRIGGER enrollment_pin_no_delete BEFORE DELETE ON executor_enrollment_pin BEGIN SELECT RAISE(ABORT,'retained enrollment pin'); END;
CREATE TABLE executor_chain_owners (
 chain_id TEXT PRIMARY KEY, owner_bridge_id TEXT NOT NULL, owner_key_id TEXT NOT NULL,
 genesis_digest TEXT NOT NULL, genesis_json TEXT NOT NULL CHECK(json_valid(genesis_json))
);
CREATE TRIGGER chain_owner_no_update BEFORE UPDATE ON executor_chain_owners BEGIN SELECT RAISE(ABORT,'immutable chain owner'); END;
CREATE TRIGGER chain_owner_no_delete BEFORE DELETE ON executor_chain_owners BEGIN SELECT RAISE(ABORT,'retained chain owner'); END;
CREATE TABLE executor_bootstraps (
 reservation_id TEXT PRIMARY KEY REFERENCES executor_reservations(reservation_id),
 input_digest TEXT NOT NULL, document TEXT NOT NULL CHECK(json_valid(document)),
 body TEXT NOT NULL, action_json TEXT NOT NULL CHECK(json_valid(action_json))
);
CREATE TRIGGER bootstrap_no_update BEFORE UPDATE ON executor_bootstraps BEGIN SELECT RAISE(ABORT,'immutable bootstrap'); END;
CREATE TRIGGER bootstrap_no_delete BEFORE DELETE ON executor_bootstraps BEGIN SELECT RAISE(ABORT,'retained bootstrap'); END;

-- Local readiness is an observation of an already confirmed exact child.
-- It cannot create an owner task, grant, lease, deadline, or launch identity.
CREATE TABLE executor_readiness (
 reservation_id TEXT PRIMARY KEY REFERENCES executor_reservations(reservation_id),
 instance_id TEXT NOT NULL, launch_key TEXT NOT NULL, token_generation TEXT NOT NULL,
 executor_incarnation INTEGER NOT NULL CHECK(executor_incarnation>0),
 ready_ms INTEGER NOT NULL CHECK(ready_ms>0)
);
CREATE TRIGGER readiness_scope BEFORE INSERT ON executor_readiness
WHEN NOT EXISTS(SELECT 1 FROM executor_reservations r JOIN executor_bootstraps b USING(reservation_id)
 WHERE r.reservation_id=NEW.reservation_id AND r.instance_id=NEW.instance_id AND r.launch_key=NEW.launch_key
 AND json_extract(b.document,'$.token_generation')=NEW.token_generation
 AND r.state='active' AND r.launch_state='confirmed'
 AND r.executor_incarnation=NEW.executor_incarnation AND r.observed_incarnation=NEW.executor_incarnation
 AND NEW.executor_incarnation=(SELECT incarnation FROM executor_runtime)
 AND NEW.ready_ms<r.expires_ms AND NEW.ready_ms<r.hard_ms)
BEGIN SELECT RAISE(ABORT,'readiness requires current exact child'); END;
CREATE TRIGGER readiness_no_update BEFORE UPDATE ON executor_readiness BEGIN SELECT RAISE(ABORT,'immutable readiness'); END;
CREATE TRIGGER readiness_no_delete BEFORE DELETE ON executor_readiness BEGIN SELECT RAISE(ABORT,'retained readiness'); END;

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

-- Local device consent never fabricates an owner, chain, task or lease.
CREATE TABLE executor_local_launches (
 launch_id TEXT PRIMARY KEY, principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 input_digest TEXT NOT NULL, consent TEXT NOT NULL CHECK(json_valid(consent)),
 configuration TEXT NOT NULL CHECK(json_valid(configuration)),
 slot_id TEXT NOT NULL REFERENCES executor_slots(slot_id),
 instance_id TEXT NOT NULL, directory_key TEXT NOT NULL,
 executor_incarnation INTEGER NOT NULL CHECK(executor_incarnation>0),
 launch_key TEXT NOT NULL UNIQUE, spawn_digest TEXT NOT NULL,
 admitted_ms INTEGER NOT NULL CHECK(admitted_ms>0), admitted_tick_ns INTEGER NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('admitted','dispatching','active','stopping','released')),
 observed_incarnation INTEGER NOT NULL DEFAULT 0 CHECK(observed_incarnation>=0),
 UNIQUE(principal_id,operation_id)
);
CREATE TRIGGER local_launch_immutable BEFORE UPDATE ON executor_local_launches
WHEN NEW.launch_id IS NOT OLD.launch_id OR NEW.principal_id IS NOT OLD.principal_id
 OR NEW.operation_id IS NOT OLD.operation_id OR NEW.input_digest IS NOT OLD.input_digest
 OR NEW.consent IS NOT OLD.consent OR NEW.configuration IS NOT OLD.configuration
 OR NEW.slot_id IS NOT OLD.slot_id OR NEW.instance_id IS NOT OLD.instance_id
 OR NEW.directory_key IS NOT OLD.directory_key OR NEW.executor_incarnation IS NOT OLD.executor_incarnation
 OR NEW.launch_key IS NOT OLD.launch_key OR NEW.spawn_digest IS NOT OLD.spawn_digest
 OR NEW.admitted_ms IS NOT OLD.admitted_ms OR NEW.admitted_tick_ns IS NOT OLD.admitted_tick_ns
 OR NEW.observed_incarnation<OLD.observed_incarnation
 OR (OLD.state='released' AND NEW.state!='released')
 OR (OLD.state='stopping' AND NEW.state NOT IN ('stopping','released'))
 OR (OLD.state!='admitted' AND NEW.state='admitted')
 OR (OLD.state IN ('active','stopping') AND NEW.state='dispatching')
BEGIN SELECT RAISE(ABORT,'immutable local launch or invalid transition'); END;
CREATE TRIGGER local_launch_no_delete BEFORE DELETE ON executor_local_launches BEGIN SELECT RAISE(ABORT,'retained local launch'); END;
CREATE TABLE executor_local_observations (
 launch_id TEXT NOT NULL REFERENCES executor_local_launches(launch_id),
 executor_incarnation INTEGER NOT NULL CHECK(executor_incarnation>0),
 present INTEGER NOT NULL CHECK(present IN (0,1)), PRIMARY KEY(launch_id,executor_incarnation,present)
);
CREATE TRIGGER local_observation_no_update BEFORE UPDATE ON executor_local_observations BEGIN SELECT RAISE(ABORT,'immutable local observation'); END;
CREATE TRIGGER local_observation_no_delete BEFORE DELETE ON executor_local_observations BEGIN SELECT RAISE(ABORT,'retained local observation'); END;
CREATE VIEW executor_live_resources AS
 SELECT slot_id,instance_id,directory_key FROM executor_reservations WHERE state!='released'
 UNION ALL SELECT slot_id,instance_id,directory_key FROM executor_local_launches WHERE state!='released';
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

CREATE TABLE executor_local_drafts (
 draft_id TEXT PRIMARY KEY, source_digest TEXT NOT NULL UNIQUE,
 revision INTEGER NOT NULL CHECK(revision>0),
 configuration TEXT NOT NULL CHECK(json_valid(configuration)),
 material TEXT NOT NULL CHECK(json_valid(material)),
 principal_id TEXT NOT NULL DEFAULT '', key_id TEXT NOT NULL DEFAULT '',
 state TEXT NOT NULL CHECK(state IN ('pending','prepared','authorized','cancelled')),
 launch_id TEXT REFERENCES executor_local_launches(launch_id),
 CHECK((state='pending' AND principal_id='' AND key_id='' AND launch_id IS NULL)
    OR (state!='pending' AND principal_id!='' AND key_id!='')),
 CHECK((state='authorized' AND launch_id IS NOT NULL) OR state!='authorized')
);
CREATE TRIGGER local_draft_immutable BEFORE UPDATE ON executor_local_drafts
WHEN NEW.draft_id IS NOT OLD.draft_id OR NEW.source_digest IS NOT OLD.source_digest
 OR NEW.revision IS NOT OLD.revision OR NEW.configuration IS NOT OLD.configuration
 OR NEW.material IS NOT OLD.material
 OR (OLD.principal_id!='' AND (NEW.principal_id IS NOT OLD.principal_id OR NEW.key_id IS NOT OLD.key_id))
 OR (OLD.launch_id IS NOT NULL AND NEW.launch_id IS NOT OLD.launch_id)
 OR (OLD.state='cancelled' AND NEW.state!='cancelled')
 OR (OLD.state='authorized' AND NEW.state NOT IN ('authorized','cancelled'))
 OR (OLD.state='prepared' AND NEW.state='pending')
BEGIN SELECT RAISE(ABORT,'immutable local draft or invalid transition'); END;
CREATE TRIGGER local_draft_no_delete BEFORE DELETE ON executor_local_drafts BEGIN SELECT RAISE(ABORT,'retained local draft'); END;
CREATE TABLE executor_local_draft_receipts (
 principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 input_digest TEXT NOT NULL, draft_id TEXT NOT NULL REFERENCES executor_local_drafts(draft_id),
 result_json TEXT NOT NULL CHECK(json_valid(result_json)), PRIMARY KEY(principal_id,operation_id)
);
CREATE TRIGGER local_draft_receipt_no_update BEFORE UPDATE ON executor_local_draft_receipts BEGIN SELECT RAISE(ABORT,'immutable draft receipt'); END;
CREATE TRIGGER local_draft_receipt_no_delete BEFORE DELETE ON executor_local_draft_receipts BEGIN SELECT RAISE(ABORT,'retained draft receipt'); END;
