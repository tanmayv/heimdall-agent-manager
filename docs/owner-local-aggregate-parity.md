# Owner-local aggregate parity ledger

Task: task_18e569e48d6b5532, requirements revision 1. Baseline: 6b076ac70b439e0dc22d344fe344fbb7572e9d6e (W2/V12).

This is a field-by-field implementation ledger, **not a completion claim**. OPEN and PARTIAL rows are required work, not approved dispositions. C1 may not close, and M4 may not cut over an aggregate, while a required row is silently missing. Native values, authors, timestamps, facet versions and IDs must survive migration; do not reconstruct historical facts from current rows.

The audit at f3cc56d1 is historical. W2 already accepts the full top-level brief vocabulary and validates structured output: src/lib/workflow_v1/boundary.odin:52; src/lib/owner_local/lifecycle_agent.odin:123. Those implementations must be reused.

## Field inventory

Each durable field declared in the original aggregate domain structs is listed once below. Transport-only page items and derived comment previews/search-feed cursors are projections, not additional canonical bodies.

### Task_Chain

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `chain_id` | `src/hub/domain/taskchain.odin:123` | **LOCAL** `src/lib/owner_local/schema.sql:8`. task_chains.chain_id. |
| `owner_user_id` | `src/hub/domain/taskchain.odin:124` | **LOCAL** `src/lib/owner_local/schema.sql:1`. Account/owner is pinned by runtime_database. Native user IDs still need explicit preservation on legacy import; do not infer ID equivalence. |
| `title` | `src/hub/domain/taskchain.odin:125` | **LOCAL** `src/lib/owner_local/schema.sql:8`. task_chains title/description; protected registry publishes vault envelopes. V13 event evidence retains subsequent edits. |
| `description` | `src/hub/domain/taskchain.odin:126` | **LOCAL** `src/lib/owner_local/schema.sql:8`. task_chains title/description; protected registry publishes vault envelopes. V13 event evidence retains subsequent edits. |
| `publish_state` | `src/hub/domain/taskchain.odin:127` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `status` | `src/hub/domain/taskchain.odin:128` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `kind` | `src/hub/domain/taskchain.odin:130` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `coordinator_agent_instance_id` | `src/hub/domain/taskchain.odin:131` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `defaults_json` | `src/hub/domain/taskchain.odin:135` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `work_revision` | `src/hub/domain/taskchain.odin:136` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `completion_summary` | `src/hub/domain/taskchain.odin:137` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `last_activity_at` | `src/hub/domain/taskchain.odin:139` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `last_title_nudge_at` | `src/hub/domain/taskchain.odin:140` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `title_source` | `src/hub/domain/taskchain.odin:141` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `created_at` | `src/hub/domain/taskchain.odin:142` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `updated_at` | `src/hub/domain/taskchain.odin:143` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `published_at` | `src/hub/domain/taskchain.odin:144` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `completed_at` | `src/hub/domain/taskchain.odin:145` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `is_pinned` | `src/hub/domain/taskchain.odin:146` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `pinned_at` | `src/hub/domain/taskchain.odin:147` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |

### Task

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `task_id` | `src/hub/domain/taskchain.odin:165` | **LOCAL** `src/lib/owner_local/schema.sql:24`. tasks composite chain/task key; immutable global task ID uniqueness. |
| `chain_id` | `src/hub/domain/taskchain.odin:166` | **LOCAL** `src/lib/owner_local/schema.sql:24`. tasks composite chain/task key; immutable global task ID uniqueness. |
| `owner_user_id` | `src/hub/domain/taskchain.odin:167` | **LOCAL** `src/lib/owner_local/schema.sql:1`. Account/owner is pinned by runtime_database. Native user IDs still need explicit preservation on legacy import; do not infer ID equivalence. |
| `title` | `src/hub/domain/taskchain.odin:168` | **LOCAL** `src/lib/owner_local/schema.sql:24`. tasks title/body; protected registry contains task title only. V13 event evidence retains subsequent edits. |
| `description` | `src/hub/domain/taskchain.odin:169` | **LOCAL** `src/lib/owner_local/schema.sql:24`. tasks title/body; protected registry contains task title only. V13 event evidence retains subsequent edits. |
| `publish_state` | `src/hub/domain/taskchain.odin:170` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `state` | `src/hub/domain/taskchain.odin:172` | **PARTIAL** `src/lib/owner_local/migration_007.sql:53`. local_controls plus lifecycle_state fold cover hold/block/cancel/ready/review/done; native projection and vocabulary conversion need explicit ordinary adapters. |
| `kind` | `src/hub/domain/taskchain.odin:173` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `priority` | `src/hub/domain/taskchain.odin:174` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `attempt_no` | `src/hub/domain/taskchain.odin:176` | **PARTIAL** `src/lib/owner_local/migration_007.sql:101`. local_work_attempts records one row per lease; submission attempts are a separate counter. Original counts_toward_budget/outcome and structural-attempt semantics are not yet equivalent. |
| `brief_json` | `src/hub/domain/taskchain.odin:179` | **PARTIAL** `src/lib/owner_local/migration_004.sql:56`. Immutable revisioned brief_json+cipher, principal/operation. Full vocabulary and nested inputs/budget/gate shapes are validated. Native hard_deadline is applied to claim/switch and pinned across heartbeat. max_attempts accounting and input-reference resolution remain C1 work. |
| `blocked_on_json` | `src/hub/domain/taskchain.odin:183` | **PARTIAL** `src/lib/owner_local/migration_007.sql:53`. local_controls plus lifecycle_state fold cover hold/block/cancel/ready/review/done; native projection and vocabulary conversion need explicit ordinary adapters. |
| `requires_user_approval` | `src/hub/domain/taskchain.odin:184` | **PARTIAL** `src/lib/owner_local/migration_009.sql:103`. Local independent-agent/role/user review records and immutable V13 evidence. Native findings_json and complete reviewer/time fields are not yet accepted by ordinary adapters. |
| `ready_since` | `src/hub/domain/taskchain.odin:187` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `bridge_id` | `src/hub/domain/taskchain.odin:191` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `workflow_run_id` | `src/hub/domain/taskchain.odin:192` | **PARTIAL** `src/lib/owner_local/migration_011.sql:68`. Language-generated items retain run/execution/stage/index/effective priority. Ordinary generated_by_json and full native provenance import remain open. |
| `workflow_execution_no` | `src/hub/domain/taskchain.odin:193` | **PARTIAL** `src/lib/owner_local/migration_011.sql:68`. Language-generated items retain run/execution/stage/index/effective priority. Ordinary generated_by_json and full native provenance import remain open. |
| `stage_key` | `src/hub/domain/taskchain.odin:195` | **PARTIAL** `src/lib/owner_local/migration_011.sql:68`. Language-generated items retain run/execution/stage/index/effective priority. Ordinary generated_by_json and full native provenance import remain open. |
| `stage_index` | `src/hub/domain/taskchain.odin:196` | **PARTIAL** `src/lib/owner_local/migration_011.sql:68`. Language-generated items retain run/execution/stage/index/effective priority. Ordinary generated_by_json and full native provenance import remain open. |
| `generated_by_json` | `src/hub/domain/taskchain.odin:198` | **PARTIAL** `src/lib/owner_local/migration_011.sql:68`. Language-generated items retain run/execution/stage/index/effective priority. Ordinary generated_by_json and full native provenance import remain open. |
| `created_at` | `src/hub/domain/taskchain.odin:199` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `updated_at` | `src/hub/domain/taskchain.odin:200` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `published_at` | `src/hub/domain/taskchain.odin:201` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `started_at` | `src/hub/domain/taskchain.odin:202` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `completed_at` | `src/hub/domain/taskchain.odin:203` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |

### Task_Comment

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `delegated_client_id` | `src/hub/domain/taskchain.odin:207` | **PARTIAL** `src/lib/owner_local/schema.sql:29`. Local operation/principal/body/seq plus V13 command event actor/time. Native comment ID, delegated provenance and historical edits/timestamps need preservation. |
| `delegated_grant_id` | `src/hub/domain/taskchain.odin:207` | **PARTIAL** `src/lib/owner_local/schema.sql:29`. Local operation/principal/body/seq plus V13 command event actor/time. Native comment ID, delegated provenance and historical edits/timestamps need preservation. |
| `comment_id` | `src/hub/domain/taskchain.odin:208` | **PARTIAL** `src/lib/owner_local/schema.sql:29`. Local operation/principal/body/seq plus V13 command event actor/time. Native comment ID, delegated provenance and historical edits/timestamps need preservation. |
| `task_id` | `src/hub/domain/taskchain.odin:209` | **PARTIAL** `src/lib/owner_local/schema.sql:29`. Local operation/principal/body/seq plus V13 command event actor/time. Native comment ID, delegated provenance and historical edits/timestamps need preservation. |
| `chain_id` | `src/hub/domain/taskchain.odin:210` | **PARTIAL** `src/lib/owner_local/schema.sql:29`. Local operation/principal/body/seq plus V13 command event actor/time. Native comment ID, delegated provenance and historical edits/timestamps need preservation. |
| `owner_user_id` | `src/hub/domain/taskchain.odin:211` | **LOCAL** `src/lib/owner_local/schema.sql:1`. Account/owner is pinned by runtime_database. Native user IDs still need explicit preservation on legacy import; do not infer ID equivalence. |
| `author_agent_instance_id` | `src/hub/domain/taskchain.odin:212` | **PARTIAL** `src/lib/owner_local/schema.sql:29`. Local operation/principal/body/seq plus V13 command event actor/time. Native comment ID, delegated provenance and historical edits/timestamps need preservation. |
| `body` | `src/hub/domain/taskchain.odin:213` | **PARTIAL** `src/lib/owner_local/schema.sql:29`. Local operation/principal/body/seq plus V13 command event actor/time. Native comment ID, delegated provenance and historical edits/timestamps need preservation. |
| `created_at` | `src/hub/domain/taskchain.odin:214` | **PARTIAL** `src/lib/owner_local/schema.sql:29`. Local operation/principal/body/seq plus V13 command event actor/time. Native comment ID, delegated provenance and historical edits/timestamps need preservation. |
| `updated_at` | `src/hub/domain/taskchain.odin:215` | **PARTIAL** `src/lib/owner_local/schema.sql:29`. Local operation/principal/body/seq plus V13 command event actor/time. Native comment ID, delegated provenance and historical edits/timestamps need preservation. |

### Task_Chain_Member

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `chain_id` | `src/hub/domain/taskchain.odin:240` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `agent_instance_id` | `src/hub/domain/taskchain.odin:241` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `agent_id` | `src/hub/domain/taskchain.odin:242` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `owner_user_id` | `src/hub/domain/taskchain.odin:243` | **LOCAL** `src/lib/owner_local/schema.sql:1`. Account/owner is pinned by runtime_database. Native user IDs still need explicit preservation on legacy import; do not infer ID equivalence. |
| `role` | `src/hub/domain/taskchain.odin:244` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `created_at` | `src/hub/domain/taskchain.odin:245` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |

### Task_Dependency

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `task_id` | `src/hub/domain/taskchain.odin:249` | **PARTIAL** `src/lib/owner_local/migration_009.sql:77`. Same-chain local_dependencies cycle guards and immutable root command evidence. Original created_at and removed-edge history require native import. |
| `depends_on_task_id` | `src/hub/domain/taskchain.odin:250` | **PARTIAL** `src/lib/owner_local/migration_009.sql:77`. Same-chain local_dependencies cycle guards and immutable root command evidence. Original created_at and removed-edge history require native import. |
| `chain_id` | `src/hub/domain/taskchain.odin:251` | **PARTIAL** `src/lib/owner_local/migration_009.sql:77`. Same-chain local_dependencies cycle guards and immutable root command evidence. Original created_at and removed-edge history require native import. |
| `owner_user_id` | `src/hub/domain/taskchain.odin:252` | **LOCAL** `src/lib/owner_local/schema.sql:1`. Account/owner is pinned by runtime_database. Native user IDs still need explicit preservation on legacy import; do not infer ID equivalence. |
| `created_at` | `src/hub/domain/taskchain.odin:253` | **PARTIAL** `src/lib/owner_local/migration_009.sql:77`. Same-chain local_dependencies cycle guards and immutable root command evidence. Original created_at and removed-edge history require native import. |

### Task_Chain_Directory

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `directory_id` | `src/hub/domain/taskchain.odin:257` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `chain_id` | `src/hub/domain/taskchain.odin:258` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `owner_user_id` | `src/hub/domain/taskchain.odin:259` | **LOCAL** `src/lib/owner_local/schema.sql:1`. Account/owner is pinned by runtime_database. Native user IDs still need explicit preservation on legacy import; do not infer ID equivalence. |
| `path` | `src/hub/domain/taskchain.odin:260` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `bridge_id` | `src/hub/domain/taskchain.odin:261` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `vcs_kind` | `src/hub/domain/taskchain.odin:262` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `vcs_info_json` | `src/hub/domain/taskchain.odin:263` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `created_at` | `src/hub/domain/taskchain.odin:264` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |
| `updated_at` | `src/hub/domain/taskchain.odin:265` | **OPEN** Required native field has no complete canonical local equivalent yet. Preserve and implement before C1 closure; this is not an approved omission. |

### Fleet_Bridge_Model

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `provider_profile` | `src/hub/domain/taskchain.odin:269` | **PARTIAL** `src/lib/owner_local/migration_003.sql:49`. local_fleet is an exact launched-child assignment, not native fleet policy. local_assignment_history preserves changes. Native provider/model/budget/placement policy belongs in C1 metadata; automatic execution is M3. |
| `provider` | `src/hub/domain/taskchain.odin:270` | **PARTIAL** `src/lib/owner_local/migration_003.sql:49`. local_fleet is an exact launched-child assignment, not native fleet policy. local_assignment_history preserves changes. Native provider/model/budget/placement policy belongs in C1 metadata; automatic execution is M3. |
| `model` | `src/hub/domain/taskchain.odin:271` | **PARTIAL** `src/lib/owner_local/migration_003.sql:49`. local_fleet is an exact launched-child assignment, not native fleet policy. local_assignment_history preserves changes. Native provider/model/budget/placement policy belongs in C1 metadata; automatic execution is M3. |

### Task_Chain_Fleet

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `provider_profile` | `src/hub/domain/taskchain.odin:300` | **PARTIAL** `src/lib/owner_local/migration_003.sql:49`. local_fleet is an exact launched-child assignment, not native fleet policy. local_assignment_history preserves changes. Native provider/model/budget/placement policy belongs in C1 metadata; automatic execution is M3. |
| `task_chain_id` | `src/hub/domain/taskchain.odin:301` | **PARTIAL** `src/lib/owner_local/migration_003.sql:49`. local_fleet is an exact launched-child assignment, not native fleet policy. local_assignment_history preserves changes. Native provider/model/budget/placement policy belongs in C1 metadata; automatic execution is M3. |
| `agent_id` | `src/hub/domain/taskchain.odin:302` | **PARTIAL** `src/lib/owner_local/migration_003.sql:49`. local_fleet is an exact launched-child assignment, not native fleet policy. local_assignment_history preserves changes. Native provider/model/budget/placement policy belongs in C1 metadata; automatic execution is M3. |
| `capacity` | `src/hub/domain/taskchain.odin:303` | **PARTIAL** `src/lib/owner_local/migration_003.sql:49`. local_fleet is an exact launched-child assignment, not native fleet policy. local_assignment_history preserves changes. Native provider/model/budget/placement policy belongs in C1 metadata; automatic execution is M3. |
| `min_warm` | `src/hub/domain/taskchain.odin:304` | **PARTIAL** `src/lib/owner_local/migration_003.sql:49`. local_fleet is an exact launched-child assignment, not native fleet policy. local_assignment_history preserves changes. Native provider/model/budget/placement policy belongs in C1 metadata; automatic execution is M3. |
| `idle_ttl_seconds` | `src/hub/domain/taskchain.odin:307` | **PARTIAL** `src/lib/owner_local/migration_003.sql:49`. local_fleet is an exact launched-child assignment, not native fleet policy. local_assignment_history preserves changes. Native provider/model/budget/placement policy belongs in C1 metadata; automatic execution is M3. |
| `bridge_models_json` | `src/hub/domain/taskchain.odin:308` | **PARTIAL** `src/lib/owner_local/migration_003.sql:49`. local_fleet is an exact launched-child assignment, not native fleet policy. local_assignment_history preserves changes. Native provider/model/budget/placement policy belongs in C1 metadata; automatic execution is M3. |
| `provider` | `src/hub/domain/taskchain.odin:311` | **PARTIAL** `src/lib/owner_local/migration_003.sql:49`. local_fleet is an exact launched-child assignment, not native fleet policy. local_assignment_history preserves changes. Native provider/model/budget/placement policy belongs in C1 metadata; automatic execution is M3. |
| `model` | `src/hub/domain/taskchain.odin:312` | **PARTIAL** `src/lib/owner_local/migration_003.sql:49`. local_fleet is an exact launched-child assignment, not native fleet policy. local_assignment_history preserves changes. Native provider/model/budget/placement policy belongs in C1 metadata; automatic execution is M3. |
| `roles_json` | `src/hub/domain/taskchain.odin:314` | **PARTIAL** `src/lib/owner_local/migration_003.sql:49`. local_fleet is an exact launched-child assignment, not native fleet policy. local_assignment_history preserves changes. Native provider/model/budget/placement policy belongs in C1 metadata; automatic execution is M3. |
| `bridge_id` | `src/hub/domain/taskchain.odin:317` | **PARTIAL** `src/lib/owner_local/migration_003.sql:49`. local_fleet is an exact launched-child assignment, not native fleet policy. local_assignment_history preserves changes. Native provider/model/budget/placement policy belongs in C1 metadata; automatic execution is M3. |
| `paused_roles_json` | `src/hub/domain/taskchain.odin:321` | **PARTIAL** `src/lib/owner_local/migration_003.sql:49`. local_fleet is an exact launched-child assignment, not native fleet policy. local_assignment_history preserves changes. Native provider/model/budget/placement policy belongs in C1 metadata; automatic execution is M3. |
| `created_at` | `src/hub/domain/taskchain.odin:322` | **PARTIAL** `src/lib/owner_local/migration_003.sql:49`. local_fleet is an exact launched-child assignment, not native fleet policy. local_assignment_history preserves changes. Native provider/model/budget/placement policy belongs in C1 metadata; automatic execution is M3. |
| `updated_at` | `src/hub/domain/taskchain.odin:323` | **PARTIAL** `src/lib/owner_local/migration_003.sql:49`. local_fleet is an exact launched-child assignment, not native fleet policy. local_assignment_history preserves changes. Native provider/model/budget/placement policy belongs in C1 metadata; automatic execution is M3. |

### Task_Event

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `event_id` | `src/hub/domain/taskv2.odin:10` | **LOCAL-NEW / IMPORT-OPEN** `src/lib/owner_local/migration_013.sql:55`. V13 local_events stores owner seq, actual actor/time and exact signed command/payload/content/result. Earlier local tags are explicitly legacy_tag with unknown actor/time; original Hub event IDs/payloads must be imported verbatim separately. |
| `task_id` | `src/hub/domain/taskv2.odin:11` | **LOCAL-NEW / IMPORT-OPEN** `src/lib/owner_local/migration_013.sql:55`. V13 local_events stores owner seq, actual actor/time and exact signed command/payload/content/result. Earlier local tags are explicitly legacy_tag with unknown actor/time; original Hub event IDs/payloads must be imported verbatim separately. |
| `chain_id` | `src/hub/domain/taskv2.odin:12` | **LOCAL-NEW / IMPORT-OPEN** `src/lib/owner_local/migration_013.sql:55`. V13 local_events stores owner seq, actual actor/time and exact signed command/payload/content/result. Earlier local tags are explicitly legacy_tag with unknown actor/time; original Hub event IDs/payloads must be imported verbatim separately. |
| `owner_user_id` | `src/hub/domain/taskv2.odin:13` | **LOCAL** `src/lib/owner_local/schema.sql:1`. Account/owner is pinned by runtime_database. Native user IDs still need explicit preservation on legacy import; do not infer ID equivalence. |
| `ts_ms` | `src/hub/domain/taskv2.odin:14` | **LOCAL-NEW / IMPORT-OPEN** `src/lib/owner_local/migration_013.sql:55`. V13 local_events stores owner seq, actual actor/time and exact signed command/payload/content/result. Earlier local tags are explicitly legacy_tag with unknown actor/time; original Hub event IDs/payloads must be imported verbatim separately. |
| `actor_kind` | `src/hub/domain/taskv2.odin:17` | **LOCAL-NEW / IMPORT-OPEN** `src/lib/owner_local/migration_013.sql:55`. V13 local_events stores owner seq, actual actor/time and exact signed command/payload/content/result. Earlier local tags are explicitly legacy_tag with unknown actor/time; original Hub event IDs/payloads must be imported verbatim separately. |
| `actor_id` | `src/hub/domain/taskv2.odin:18` | **LOCAL-NEW / IMPORT-OPEN** `src/lib/owner_local/migration_013.sql:55`. V13 local_events stores owner seq, actual actor/time and exact signed command/payload/content/result. Earlier local tags are explicitly legacy_tag with unknown actor/time; original Hub event IDs/payloads must be imported verbatim separately. |
| `kind` | `src/hub/domain/taskv2.odin:19` | **LOCAL-NEW / IMPORT-OPEN** `src/lib/owner_local/migration_013.sql:55`. V13 local_events stores owner seq, actual actor/time and exact signed command/payload/content/result. Earlier local tags are explicitly legacy_tag with unknown actor/time; original Hub event IDs/payloads must be imported verbatim separately. |
| `payload_json` | `src/hub/domain/taskv2.odin:20` | **LOCAL-NEW / IMPORT-OPEN** `src/lib/owner_local/migration_013.sql:55`. V13 local_events stores owner seq, actual actor/time and exact signed command/payload/content/result. Earlier local tags are explicitly legacy_tag with unknown actor/time; original Hub event IDs/payloads must be imported verbatim separately. |

### Task_Attempt

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `task_id` | `src/hub/domain/taskv2.odin:27` | **PARTIAL** `src/lib/owner_local/migration_007.sql:101`. local_work_attempts records one row per lease; submission attempts are a separate counter. Original counts_toward_budget/outcome and structural-attempt semantics are not yet equivalent. |
| `attempt_no` | `src/hub/domain/taskv2.odin:28` | **PARTIAL** `src/lib/owner_local/migration_007.sql:101`. local_work_attempts records one row per lease; submission attempts are a separate counter. Original counts_toward_budget/outcome and structural-attempt semantics are not yet equivalent. |
| `chain_id` | `src/hub/domain/taskv2.odin:29` | **PARTIAL** `src/lib/owner_local/migration_007.sql:101`. local_work_attempts records one row per lease; submission attempts are a separate counter. Original counts_toward_budget/outcome and structural-attempt semantics are not yet equivalent. |
| `owner_user_id` | `src/hub/domain/taskv2.odin:30` | **LOCAL** `src/lib/owner_local/schema.sql:1`. Account/owner is pinned by runtime_database. Native user IDs still need explicit preservation on legacy import; do not infer ID equivalence. |
| `started_at` | `src/hub/domain/taskv2.odin:31` | **PARTIAL** `src/lib/owner_local/migration_007.sql:101`. local_work_attempts records one row per lease; submission attempts are a separate counter. Original counts_toward_budget/outcome and structural-attempt semantics are not yet equivalent. |
| `ended_at` | `src/hub/domain/taskv2.odin:32` | **PARTIAL** `src/lib/owner_local/migration_007.sql:101`. local_work_attempts records one row per lease; submission attempts are a separate counter. Original counts_toward_budget/outcome and structural-attempt semantics are not yet equivalent. |
| `holder_instance_id` | `src/hub/domain/taskv2.odin:33` | **PARTIAL** `src/lib/owner_local/migration_007.sql:101`. local_work_attempts records one row per lease; submission attempts are a separate counter. Original counts_toward_budget/outcome and structural-attempt semantics are not yet equivalent. |
| `outcome` | `src/hub/domain/taskv2.odin:36` | **PARTIAL** `src/lib/owner_local/migration_007.sql:101`. local_work_attempts records one row per lease; submission attempts are a separate counter. Original counts_toward_budget/outcome and structural-attempt semantics are not yet equivalent. |
| `counts_toward_budget` | `src/hub/domain/taskv2.odin:37` | **PARTIAL** `src/lib/owner_local/migration_007.sql:101`. local_work_attempts records one row per lease; submission attempts are a separate counter. Original counts_toward_budget/outcome and structural-attempt semantics are not yet equivalent. |

### Task_Attempt_Facet

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `task_id` | `src/hub/domain/taskv2.odin:43` | **OPEN** `src/hub/service/taskv2/verbs_m2.odin:109`. Retain native kind/version/writer/written_at/body_json verbatim. Current output/handoff tables cover only a subset; C1 must add remaining typed facet commands/history. Original artifact/message IDs plus pinned revision/provenance stay native; C3 owns local_objects body/envelope/blob resolution. Unknown refs stay unresolved/import-pending. |
| `attempt_no` | `src/hub/domain/taskv2.odin:44` | **OPEN** `src/hub/service/taskv2/verbs_m2.odin:109`. Retain native kind/version/writer/written_at/body_json verbatim. Current output/handoff tables cover only a subset; C1 must add remaining typed facet commands/history. Original artifact/message IDs plus pinned revision/provenance stay native; C3 owns local_objects body/envelope/blob resolution. Unknown refs stay unresolved/import-pending. |
| `chain_id` | `src/hub/domain/taskv2.odin:45` | **OPEN** `src/hub/service/taskv2/verbs_m2.odin:109`. Retain native kind/version/writer/written_at/body_json verbatim. Current output/handoff tables cover only a subset; C1 must add remaining typed facet commands/history. Original artifact/message IDs plus pinned revision/provenance stay native; C3 owns local_objects body/envelope/blob resolution. Unknown refs stay unresolved/import-pending. |
| `owner_user_id` | `src/hub/domain/taskv2.odin:46` | **OPEN** `src/hub/service/taskv2/verbs_m2.odin:109`. Retain native kind/version/writer/written_at/body_json verbatim. Current output/handoff tables cover only a subset; C1 must add remaining typed facet commands/history. Original artifact/message IDs plus pinned revision/provenance stay native; C3 owns local_objects body/envelope/blob resolution. Unknown refs stay unresolved/import-pending. |
| `kind` | `src/hub/domain/taskv2.odin:47` | **OPEN** `src/hub/service/taskv2/verbs_m2.odin:109`. Retain native kind/version/writer/written_at/body_json verbatim. Current output/handoff tables cover only a subset; C1 must add remaining typed facet commands/history. Original artifact/message IDs plus pinned revision/provenance stay native; C3 owns local_objects body/envelope/blob resolution. Unknown refs stay unresolved/import-pending. |
| `v` | `src/hub/domain/taskv2.odin:48` | **OPEN** `src/hub/service/taskv2/verbs_m2.odin:109`. Retain native kind/version/writer/written_at/body_json verbatim. Current output/handoff tables cover only a subset; C1 must add remaining typed facet commands/history. Original artifact/message IDs plus pinned revision/provenance stay native; C3 owns local_objects body/envelope/blob resolution. Unknown refs stay unresolved/import-pending. |
| `body_json` | `src/hub/domain/taskv2.odin:49` | **OPEN** `src/hub/service/taskv2/verbs_m2.odin:109`. Retain native kind/version/writer/written_at/body_json verbatim. Current output/handoff tables cover only a subset; C1 must add remaining typed facet commands/history. Original artifact/message IDs plus pinned revision/provenance stay native; C3 owns local_objects body/envelope/blob resolution. Unknown refs stay unresolved/import-pending. |
| `writer` | `src/hub/domain/taskv2.odin:51` | **OPEN** `src/hub/service/taskv2/verbs_m2.odin:109`. Retain native kind/version/writer/written_at/body_json verbatim. Current output/handoff tables cover only a subset; C1 must add remaining typed facet commands/history. Original artifact/message IDs plus pinned revision/provenance stay native; C3 owns local_objects body/envelope/blob resolution. Unknown refs stay unresolved/import-pending. |
| `written_at` | `src/hub/domain/taskv2.odin:52` | **OPEN** `src/hub/service/taskv2/verbs_m2.odin:109`. Retain native kind/version/writer/written_at/body_json verbatim. Current output/handoff tables cover only a subset; C1 must add remaining typed facet commands/history. Original artifact/message IDs plus pinned revision/provenance stay native; C3 owns local_objects body/envelope/blob resolution. Unknown refs stay unresolved/import-pending. |

### Task_Lease

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `provider_profile` | `src/hub/domain/taskv2.odin:65` | **PARTIAL** `src/lib/owner_local/migration_003.sql:58`. Exact-child local_leases and immutable signed lease commands/events preserve new deadlines/authority. Native provider/model/placement/delivery/confirmation/history fields still need a canonical mapping. |
| `lease_id` | `src/hub/domain/taskv2.odin:66` | **PARTIAL** `src/lib/owner_local/migration_003.sql:58`. Exact-child local_leases and immutable signed lease commands/events preserve new deadlines/authority. Native provider/model/placement/delivery/confirmation/history fields still need a canonical mapping. |
| `task_id` | `src/hub/domain/taskv2.odin:67` | **PARTIAL** `src/lib/owner_local/migration_003.sql:58`. Exact-child local_leases and immutable signed lease commands/events preserve new deadlines/authority. Native provider/model/placement/delivery/confirmation/history fields still need a canonical mapping. |
| `chain_id` | `src/hub/domain/taskv2.odin:68` | **PARTIAL** `src/lib/owner_local/migration_003.sql:58`. Exact-child local_leases and immutable signed lease commands/events preserve new deadlines/authority. Native provider/model/placement/delivery/confirmation/history fields still need a canonical mapping. |
| `owner_user_id` | `src/hub/domain/taskv2.odin:69` | **LOCAL** `src/lib/owner_local/schema.sql:1`. Account/owner is pinned by runtime_database. Native user IDs still need explicit preservation on legacy import; do not infer ID equivalence. |
| `attempt_no` | `src/hub/domain/taskv2.odin:70` | **PARTIAL** `src/lib/owner_local/migration_003.sql:58`. Exact-child local_leases and immutable signed lease commands/events preserve new deadlines/authority. Native provider/model/placement/delivery/confirmation/history fields still need a canonical mapping. |
| `holder_instance_id` | `src/hub/domain/taskv2.odin:71` | **PARTIAL** `src/lib/owner_local/migration_003.sql:58`. Exact-child local_leases and immutable signed lease commands/events preserve new deadlines/authority. Native provider/model/placement/delivery/confirmation/history fields still need a canonical mapping. |
| `kind` | `src/hub/domain/taskv2.odin:72` | **PARTIAL** `src/lib/owner_local/migration_003.sql:58`. Exact-child local_leases and immutable signed lease commands/events preserve new deadlines/authority. Native provider/model/placement/delivery/confirmation/history fields still need a canonical mapping. |
| `review_role` | `src/hub/domain/taskv2.odin:73` | **PARTIAL** `src/lib/owner_local/migration_003.sql:58`. Exact-child local_leases and immutable signed lease commands/events preserve new deadlines/authority. Native provider/model/placement/delivery/confirmation/history fields still need a canonical mapping. |
| `bridge_id` | `src/hub/domain/taskv2.odin:75` | **PARTIAL** `src/lib/owner_local/migration_003.sql:58`. Exact-child local_leases and immutable signed lease commands/events preserve new deadlines/authority. Native provider/model/placement/delivery/confirmation/history fields still need a canonical mapping. |
| `provider` | `src/hub/domain/taskv2.odin:76` | **PARTIAL** `src/lib/owner_local/migration_003.sql:58`. Exact-child local_leases and immutable signed lease commands/events preserve new deadlines/authority. Native provider/model/placement/delivery/confirmation/history fields still need a canonical mapping. |
| `model` | `src/hub/domain/taskv2.odin:77` | **PARTIAL** `src/lib/owner_local/migration_003.sql:58`. Exact-child local_leases and immutable signed lease commands/events preserve new deadlines/authority. Native provider/model/placement/delivery/confirmation/history fields still need a canonical mapping. |
| `granted_at` | `src/hub/domain/taskv2.odin:78` | **PARTIAL** `src/lib/owner_local/migration_003.sql:58`. Exact-child local_leases and immutable signed lease commands/events preserve new deadlines/authority. Native provider/model/placement/delivery/confirmation/history fields still need a canonical mapping. |
| `confirmed_at` | `src/hub/domain/taskv2.odin:81` | **PARTIAL** `src/lib/owner_local/migration_003.sql:58`. Exact-child local_leases and immutable signed lease commands/events preserve new deadlines/authority. Native provider/model/placement/delivery/confirmation/history fields still need a canonical mapping. |
| `expires_at` | `src/hub/domain/taskv2.odin:83` | **PARTIAL** `src/lib/owner_local/migration_003.sql:58`. Exact-child local_leases and immutable signed lease commands/events preserve new deadlines/authority. Native provider/model/placement/delivery/confirmation/history fields still need a canonical mapping. |
| `hard_deadline_at` | `src/hub/domain/taskv2.odin:84` | **PARTIAL** `src/lib/owner_local/migration_003.sql:58`. Exact-child local_leases and immutable signed lease commands/events preserve new deadlines/authority. Native provider/model/placement/delivery/confirmation/history fields still need a canonical mapping. |
| `last_beat_at` | `src/hub/domain/taskv2.odin:85` | **PARTIAL** `src/lib/owner_local/migration_003.sql:58`. Exact-child local_leases and immutable signed lease commands/events preserve new deadlines/authority. Native provider/model/placement/delivery/confirmation/history fields still need a canonical mapping. |
| `delivery` | `src/hub/domain/taskv2.odin:86` | **PARTIAL** `src/lib/owner_local/migration_003.sql:58`. Exact-child local_leases and immutable signed lease commands/events preserve new deadlines/authority. Native provider/model/placement/delivery/confirmation/history fields still need a canonical mapping. |
| `extended_at` | `src/hub/domain/taskv2.odin:89` | **PARTIAL** `src/lib/owner_local/migration_003.sql:58`. Exact-child local_leases and immutable signed lease commands/events preserve new deadlines/authority. Native provider/model/placement/delivery/confirmation/history fields still need a canonical mapping. |

### Task_Review

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `task_id` | `src/hub/domain/taskv2.odin:95` | **PARTIAL** `src/lib/owner_local/migration_009.sql:103`. Local independent-agent/role/user review records and immutable V13 evidence. Native findings_json and complete reviewer/time fields are not yet accepted by ordinary adapters. |
| `chain_id` | `src/hub/domain/taskv2.odin:96` | **PARTIAL** `src/lib/owner_local/migration_009.sql:103`. Local independent-agent/role/user review records and immutable V13 evidence. Native findings_json and complete reviewer/time fields are not yet accepted by ordinary adapters. |
| `owner_user_id` | `src/hub/domain/taskv2.odin:97` | **LOCAL** `src/lib/owner_local/schema.sql:1`. Account/owner is pinned by runtime_database. Native user IDs still need explicit preservation on legacy import; do not infer ID equivalence. |
| `attempt_no` | `src/hub/domain/taskv2.odin:98` | **PARTIAL** `src/lib/owner_local/migration_009.sql:103`. Local independent-agent/role/user review records and immutable V13 evidence. Native findings_json and complete reviewer/time fields are not yet accepted by ordinary adapters. |
| `role` | `src/hub/domain/taskv2.odin:99` | **PARTIAL** `src/lib/owner_local/migration_009.sql:103`. Local independent-agent/role/user review records and immutable V13 evidence. Native findings_json and complete reviewer/time fields are not yet accepted by ordinary adapters. |
| `reviewer_kind` | `src/hub/domain/taskv2.odin:101` | **PARTIAL** `src/lib/owner_local/migration_009.sql:103`. Local independent-agent/role/user review records and immutable V13 evidence. Native findings_json and complete reviewer/time fields are not yet accepted by ordinary adapters. |
| `reviewer_agent_id` | `src/hub/domain/taskv2.odin:102` | **PARTIAL** `src/lib/owner_local/migration_009.sql:103`. Local independent-agent/role/user review records and immutable V13 evidence. Native findings_json and complete reviewer/time fields are not yet accepted by ordinary adapters. |
| `reviewer_instance_id` | `src/hub/domain/taskv2.odin:103` | **PARTIAL** `src/lib/owner_local/migration_009.sql:103`. Local independent-agent/role/user review records and immutable V13 evidence. Native findings_json and complete reviewer/time fields are not yet accepted by ordinary adapters. |
| `verdict` | `src/hub/domain/taskv2.odin:104` | **PARTIAL** `src/lib/owner_local/migration_009.sql:103`. Local independent-agent/role/user review records and immutable V13 evidence. Native findings_json and complete reviewer/time fields are not yet accepted by ordinary adapters. |
| `findings_json` | `src/hub/domain/taskv2.odin:105` | **PARTIAL** `src/lib/owner_local/migration_009.sql:103`. Local independent-agent/role/user review records and immutable V13 evidence. Native findings_json and complete reviewer/time fields are not yet accepted by ordinary adapters. |
| `created_at` | `src/hub/domain/taskv2.odin:106` | **PARTIAL** `src/lib/owner_local/migration_009.sql:103`. Local independent-agent/role/user review records and immutable V13 evidence. Native findings_json and complete reviewer/time fields are not yet accepted by ordinary adapters. |

### Chain_Summary

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `curated_body` | `src/hub/domain/taskv2.odin:110` | **PARTIAL** `src/lib/owner_local/migration_010.sql:52`. V10 deterministic context compaction is canonical local projection with digest/version. It is not a substitute for original curated body, initialization or failure metadata. |
| `curated_initialized` | `src/hub/domain/taskv2.odin:111` | **PARTIAL** `src/lib/owner_local/migration_010.sql:52`. V10 deterministic context compaction is canonical local projection with digest/version. It is not a substitute for original curated body, initialization or failure metadata. |
| `failure_fingerprint` | `src/hub/domain/taskv2.odin:112` | **PARTIAL** `src/lib/owner_local/migration_010.sql:52`. V10 deterministic context compaction is canonical local projection with digest/version. It is not a substitute for original curated body, initialization or failure metadata. |
| `chain_id` | `src/hub/domain/taskv2.odin:113` | **PARTIAL** `src/lib/owner_local/migration_010.sql:52`. V10 deterministic context compaction is canonical local projection with digest/version. It is not a substitute for original curated body, initialization or failure metadata. |
| `owner_user_id` | `src/hub/domain/taskv2.odin:114` | **LOCAL** `src/lib/owner_local/schema.sql:1`. Account/owner is pinned by runtime_database. Native user IDs still need explicit preservation on legacy import; do not infer ID equivalence. |
| `body` | `src/hub/domain/taskv2.odin:115` | **PARTIAL** `src/lib/owner_local/migration_010.sql:52`. V10 deterministic context compaction is canonical local projection with digest/version. It is not a substitute for original curated body, initialization or failure metadata. |
| `line_count` | `src/hub/domain/taskv2.odin:116` | **PARTIAL** `src/lib/owner_local/migration_010.sql:52`. V10 deterministic context compaction is canonical local projection with digest/version. It is not a substitute for original curated body, initialization or failure metadata. |
| `version` | `src/hub/domain/taskv2.odin:117` | **PARTIAL** `src/lib/owner_local/migration_010.sql:52`. V10 deterministic context compaction is canonical local projection with digest/version. It is not a substitute for original curated body, initialization or failure metadata. |
| `updated_at` | `src/hub/domain/taskv2.odin:118` | **PARTIAL** `src/lib/owner_local/migration_010.sql:52`. V10 deterministic context compaction is canonical local projection with digest/version. It is not a substitute for original curated body, initialization or failure metadata. |

### Workflow_Definition

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `def_id` | `src/hub/domain/taskv2.odin:122` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `owner_user_id` | `src/hub/domain/taskv2.odin:123` | **LOCAL** `src/lib/owner_local/schema.sql:1`. Account/owner is pinned by runtime_database. Native user IDs still need explicit preservation on legacy import; do not infer ID equivalence. |
| `name` | `src/hub/domain/taskv2.odin:124` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `version` | `src/hub/domain/taskv2.odin:125` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `body_json` | `src/hub/domain/taskv2.odin:126` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `created_at` | `src/hub/domain/taskv2.odin:127` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |

### Workflow_Run

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `run_id` | `src/hub/domain/workflow_run.odin:9` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `chain_id` | `src/hub/domain/workflow_run.odin:10` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `owner_user_id` | `src/hub/domain/workflow_run.odin:11` | **LOCAL** `src/lib/owner_local/schema.sql:1`. Account/owner is pinned by runtime_database. Native user IDs still need explicit preservation on legacy import; do not infer ID equivalence. |
| `title` | `src/hub/domain/workflow_run.odin:12` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `definition_ref` | `src/hub/domain/workflow_run.odin:13` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `spec_json` | `src/hub/domain/workflow_run.odin:14` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `inputs_json` | `src/hub/domain/workflow_run.odin:15` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `current_execution_no` | `src/hub/domain/workflow_run.odin:16` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `request_id` | `src/hub/domain/workflow_run.odin:17` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `request_hash` | `src/hub/domain/workflow_run.odin:18` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `created_by_kind` | `src/hub/domain/workflow_run.odin:19` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `created_by_id` | `src/hub/domain/workflow_run.odin:20` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `created_at` | `src/hub/domain/workflow_run.odin:21` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `updated_at` | `src/hub/domain/workflow_run.odin:22` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `revision` | `src/hub/domain/workflow_run.odin:23` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |

### Workflow_Run_Execution

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `run_id` | `src/hub/domain/workflow_run.odin:35` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `execution_no` | `src/hub/domain/workflow_run.odin:36` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `chain_id` | `src/hub/domain/workflow_run.odin:37` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `owner_user_id` | `src/hub/domain/workflow_run.odin:38` | **LOCAL** `src/lib/owner_local/schema.sql:1`. Account/owner is pinned by runtime_database. Native user IDs still need explicit preservation on legacy import; do not infer ID equivalence. |
| `state` | `src/hub/domain/workflow_run.odin:39` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `resolved_inputs_json` | `src/hub/domain/workflow_run.odin:40` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `started_at` | `src/hub/domain/workflow_run.odin:41` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `ended_at` | `src/hub/domain/workflow_run.odin:42` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `failure_code` | `src/hub/domain/workflow_run.odin:43` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `failure_detail` | `src/hub/domain/workflow_run.odin:44` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `output_manifest_json` | `src/hub/domain/workflow_run.odin:45` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `revision` | `src/hub/domain/workflow_run.odin:46` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |

### Workflow_Stage_Execution

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `run_id` | `src/hub/domain/workflow_run.odin:52` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `execution_no` | `src/hub/domain/workflow_run.odin:53` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `stage_key` | `src/hub/domain/workflow_run.odin:54` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `chain_id` | `src/hub/domain/workflow_run.odin:55` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `owner_user_id` | `src/hub/domain/workflow_run.odin:56` | **LOCAL** `src/lib/owner_local/schema.sql:1`. Account/owner is pinned by runtime_database. Native user IDs still need explicit preservation on legacy import; do not infer ID equivalence. |
| `item_count` | `src/hub/domain/workflow_run.odin:57` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |
| `expanded_at` | `src/hub/domain/workflow_run.odin:58` | **PARTIAL** `src/lib/owner_local/migration_009.sql:53`. W2 pins definition/version, runs/executions, task mappings, outputs and prerequisites locally. Preserve extra native labels/timestamps/manifests during aggregate import; no assertion that table names alone prove parity. |

### Workflow_Run_Event

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `event_id` | `src/hub/domain/workflow_run.odin:62` | **LOCAL-NEW / IMPORT-OPEN** `src/lib/owner_local/migration_013.sql:55`. V13 local_events stores owner seq, actual actor/time and exact signed command/payload/content/result. Earlier local tags are explicitly legacy_tag with unknown actor/time; original Hub event IDs/payloads must be imported verbatim separately. |
| `run_id` | `src/hub/domain/workflow_run.odin:63` | **LOCAL-NEW / IMPORT-OPEN** `src/lib/owner_local/migration_013.sql:55`. V13 local_events stores owner seq, actual actor/time and exact signed command/payload/content/result. Earlier local tags are explicitly legacy_tag with unknown actor/time; original Hub event IDs/payloads must be imported verbatim separately. |
| `execution_no` | `src/hub/domain/workflow_run.odin:64` | **LOCAL-NEW / IMPORT-OPEN** `src/lib/owner_local/migration_013.sql:55`. V13 local_events stores owner seq, actual actor/time and exact signed command/payload/content/result. Earlier local tags are explicitly legacy_tag with unknown actor/time; original Hub event IDs/payloads must be imported verbatim separately. |
| `chain_id` | `src/hub/domain/workflow_run.odin:65` | **LOCAL-NEW / IMPORT-OPEN** `src/lib/owner_local/migration_013.sql:55`. V13 local_events stores owner seq, actual actor/time and exact signed command/payload/content/result. Earlier local tags are explicitly legacy_tag with unknown actor/time; original Hub event IDs/payloads must be imported verbatim separately. |
| `owner_user_id` | `src/hub/domain/workflow_run.odin:66` | **LOCAL** `src/lib/owner_local/schema.sql:1`. Account/owner is pinned by runtime_database. Native user IDs still need explicit preservation on legacy import; do not infer ID equivalence. |
| `ts_ms` | `src/hub/domain/workflow_run.odin:67` | **LOCAL-NEW / IMPORT-OPEN** `src/lib/owner_local/migration_013.sql:55`. V13 local_events stores owner seq, actual actor/time and exact signed command/payload/content/result. Earlier local tags are explicitly legacy_tag with unknown actor/time; original Hub event IDs/payloads must be imported verbatim separately. |
| `actor_kind` | `src/hub/domain/workflow_run.odin:68` | **LOCAL-NEW / IMPORT-OPEN** `src/lib/owner_local/migration_013.sql:55`. V13 local_events stores owner seq, actual actor/time and exact signed command/payload/content/result. Earlier local tags are explicitly legacy_tag with unknown actor/time; original Hub event IDs/payloads must be imported verbatim separately. |
| `actor_id` | `src/hub/domain/workflow_run.odin:69` | **LOCAL-NEW / IMPORT-OPEN** `src/lib/owner_local/migration_013.sql:55`. V13 local_events stores owner seq, actual actor/time and exact signed command/payload/content/result. Earlier local tags are explicitly legacy_tag with unknown actor/time; original Hub event IDs/payloads must be imported verbatim separately. |
| `kind` | `src/hub/domain/workflow_run.odin:70` | **LOCAL-NEW / IMPORT-OPEN** `src/lib/owner_local/migration_013.sql:55`. V13 local_events stores owner seq, actual actor/time and exact signed command/payload/content/result. Earlier local tags are explicitly legacy_tag with unknown actor/time; original Hub event IDs/payloads must be imported verbatim separately. |
| `payload_json` | `src/hub/domain/workflow_run.odin:71` | **LOCAL-NEW / IMPORT-OPEN** `src/lib/owner_local/migration_013.sql:55`. V13 local_events stores owner seq, actual actor/time and exact signed command/payload/content/result. Earlier local tags are explicitly legacy_tag with unknown actor/time; original Hub event IDs/payloads must be imported verbatim separately. |

## Command parity and remaining implementation

| Original command family | Original source | Current owner equivalent / required work |
| --- | --- | --- |
| Chain/task create, edit, publish | `src/hub/service/taskchain/taskchain_service.odin:450`, `:973`, `:1222` | chain.create/edit and task.create/edit retain prose and publish title intents (`src/lib/owner_local/store.odin:236`). OPEN: draft/publication/priority/native metadata commands and publication claim fences. |
| Propose, decide, publish plan | `src/hub/service/taskv2/verbs_m2.odin:965`, `:1096`, `:841` | OPEN: native pending proposal, immutable decision history, validated task materialization and publication in one local UoW. Workflow expansion is not proposal parity. |
| Full brief + requirement revisions | `src/hub/service/taskv2/brief_schema.odin:16` | requirements.edit retains raw brief+cipher (`src/lib/owner_local/lifecycle.odin:49`); Nested inputs/budget/gate shape validation and native hard_deadline now apply locally. OPEN: input-reference resolution, native max_attempts accounting and ordinary matching policy consistency. |
| Claim, heartbeat, present, acknowledge | `src/hub/domain/taskv2.odin:64` | Exact-child signed lease commands (`src/lib/owner_local/leases.odin:45`), snapshot presentation/ACK (`src/lib/owner_local/lifecycle_agent.odin:94`). OPEN: native attempt budgets/structural outcomes, placement/provider/model evidence. Automatic matching stays M3. |
| Submit, handoff, block, switch | `src/hub/service/taskv2/verbs_m2.odin:63`, `:136`, `:269`, `:226` | local lifecycle commands and structured output validation retained. OPEN: full handoff/decisions/dead_ends/VCS/artifact/runtime facets and reference resolution through C3. |
| Review, checkpoint, hold, release, cancel, reopen, answer | `src/hub/service/taskv2/verbs_m2.odin:328`, `:625`, `:674`, `:553`, `:584` | Independent named review, role gates and local controls retained (`src/lib/owner_local/review_roles.odin:75`; `controls.odin:55`). OPEN: native findings payload/time and exact ordinary command adapters. No user gate is added to this ticket. |
| Members, directories, fleet policy | `src/hub/domain/taskchain.odin:239`, `:256`, `:299` | OPEN: full metadata records and commands. Existing exact-child fleet assignment/configure is not capacity/provider/model/membership policy parity. |
| Curated summary / fetch | `src/hub/domain/taskv2.odin:109`; `src/hub/service/taskv2/facets.odin:279` | V10 context.read/compaction retained. OPEN: curated-vs-projection metadata and native event/facet/directory references. |
| Task event history | `src/hub/domain/taskv2.odin:9` | V13 immutable local_events; history.read inventory and history.fetch byte chunks (`src/lib/owner_local/events.odin:13`). Exact raw command/payload plus decrypted device content and result; actual child/Bridge identity/time. Old tags explicitly incomplete. Native imported IDs/timestamps/payloads remain import work. |
| Workflow definitions/runs/retries/gates/output prerequisites | `src/hub/domain/workflow_run.odin:8` | Retain W2 language/static adapters, immutable definition/input/output snapshots and generated provenance. Detailed reviewed mapping: [workflow language](owner-local-workflow-language.md). Extra native metadata is listed in the field inventory above. |
| Ordinary CLI/UI/worker route convergence | `src/ctl/taskv2_cmds.odin:1351` | Existing owner-local relay accepts validated signed methods; final ordinary cutover is M4. C1 must supply strict metadata/brief/facet adapters and rich synthetic parity proof before that cutover. |

## C1/C3 shared reference contract

Coordinator message msg_18e5742cd8404560: retain native facet payload plus original typed artifact/message IDs and pinned revision/provenance. C3 owns plan local_objects canonical bodies/envelopes/blobs. C1 must not invent parallel IDs, paths or a second body table. Unknown references remain explicitly unresolved/import-pending; artifact text indexing stays deferred.

## Event transport and upgrade

Both history methods are chain-scoped signed device reads with current read authorization checked before any lookup. history.read takes the existing cursor/limit payload (limit 1..100). Keyset cursors bind account+chain and survive appends. history.fetch takes seq and byte offset as decimal strings; evidence is returned in UTF-8-safe chunks of at most 8192 raw bytes, with next_offset. Read-only grants work; revoked grants fail. No Hub content join or authority fallback is involved.

V13 is additive after V12. It copies existing local_changes only as legacy_tag with a null timestamp, unknown actor and empty evidence. It does not invent original payloads that prior slices never stored. Subsequent accepted device, lease, lifecycle, coordinator, expiry and source/merge completion mutations append evidence in their original UoW. Failed mutations/replays do not add events. Receipt compaction does not remove events.

## Completion gates still open

- Implement remaining metadata/publication/proposal/membership/directory/fleet/curated-summary rows and commands above, with validation and immutable history.
- Reconcile work-attempt vs submission-attempt identity, structural counting and budget enforcement before claiming parity.
- Preserve all native facet kinds/versions/writers/times and references under the shared C3 contract.
- Add a genuinely rich native synthetic fixture and ordinary command adapters; demonstrate restart, validation failures, migration rollback, exact history, auth/replay/search and retained demos.
- Have independent named code review judge any explicit disposition. This ledger alone does not approve omissions or complete REQ-P1/P2/P3.


## Nested brief policy and lease deadlines

The shared strict brief boundary now validates input-reference string arrays,
positive integer budget.max_attempts/budget.hard_deadline, and exact gate
approver/prompt shapes. Unsupported budget keys and invalid approvers are
rejected rather than silently ignored (src/lib/workflow_v1/boundary.odin:50).
This strengthens ordinary/static requirements and workflow definition
admission through the existing shared boundary.

The native deadline unit is seconds
(src/hub/service/taskv2/lease.odin:114).
Claim and atomic switch use the same owner helper and the destination's current
requirement snapshot; initial TTL clamps to the hard deadline and arithmetic
overflow rejects. Heartbeat retains the originally signed hard deadline
(src/lib/owner_local/leases.odin:15;
src/lib/owner_local/controls.odin:161).
This does **not** claim max_attempts parity: original handoff continuations reuse
an attempt number, and replaced/dependency-added/reopened releases have
different counting semantics (src/hub/service/taskv2/fold.odin:138;
src/hub/service/taskv2/fold.odin:377). Counting local_work_attempts rows would be
incorrect. That native attempt model remains required work.
