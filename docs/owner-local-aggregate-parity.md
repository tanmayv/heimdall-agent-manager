# Owner-local aggregate parity ledger

Task: task_18e569e48d6b5532, requirements revision 2. Baseline: 6b076ac70b439e0dc22d344fe344fbb7572e9d6e (W2/V12).

C1a integration: task_18e57ad52bb4ea63, revision 1. The original broad C1 task is
held/superseded, not approved. The bounded foundation proposed for acceptance
and its successor API handoff are recorded at the end of this ledger.

Current C1f gate: all 240 native fields have canonical, tested source/storage/import/export mappings below. See [final reviewer matrix](owner-local-final-parity.md) and [machine evidence](owner-local-parity-evidence.json). Independent acceptance remains required. Historical checkpoint sections retain their original status and are superseded by this matrix. Only explicit C3/M3/M4 milestones remain, per coordinator `cmt_18e592e4d810d71a`; original authors, times, versions and IDs are preserved rather than reconstructed.

The audit at f3cc56d1 is historical. W2 already accepts the full top-level brief vocabulary and validates structured output: src/lib/workflow_v1/boundary.odin:52; src/lib/owner_local/lifecycle_agent.odin:123. Those implementations must be reused.

> **Owner-local attempt budget removed (2026-11-07).** By user decision on
> 2026-11-07 the Bridge-owned (owner-local) runtime no longer has an attempt
> budget: no `budget.activate` method, no budget admission/exhaustion,
> oscillation or native-blocked overlay, no `runtime.read.budget` and no
> counting attempts. Owner-local migration V29 drops the budget tables and
> releases any task the overlay had blocked
> (`src/lib/owner_local/migration_029_test.odin`). Attempt numbers remain as
> archival identity (`attempt.read`, `submission.read`, facets), and the
> archival `counts_toward_budget` value of imported native attempts is still
> preserved. The Hub's taskv2 budget is unchanged. Budget sections below are
> historical; the budget source and test files they cite were deleted.

## Field inventory

Each durable field declared in the original aggregate domain structs (including mixed-work graph records) is listed once below. Transport-only page items and derived comment previews/search-feed cursors are projections, not additional canonical bodies.

### Task_Chain

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `chain_id` | `src/hub/domain/taskchain.odin:123` | **CANONICAL** `native_fact_chain.chain_id`; signed `native.metadata.import` → `native.metadata.read` (chain). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `owner_user_id` | `src/hub/domain/taskchain.odin:124` | **CANONICAL** `native_fact_chain.owner_user_id`; signed `native.metadata.import` → `native.metadata.read` (chain). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `title` | `src/hub/domain/taskchain.odin:125` | **CANONICAL** `native_fact_chain.title`; signed `native.metadata.import` → `native.metadata.read` (chain). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `description` | `src/hub/domain/taskchain.odin:126` | **CANONICAL** `native_fact_chain.description`; signed `native.metadata.import` → `native.metadata.read` (chain). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `publish_state` | `src/hub/domain/taskchain.odin:127` | **CANONICAL** `native_fact_chain.publish_state`; signed `native.metadata.import` → `native.metadata.read` (chain). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `status` | `src/hub/domain/taskchain.odin:128` | **CANONICAL** `native_fact_chain.status`; signed `native.metadata.import` → `native.metadata.read` (chain). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `kind` | `src/hub/domain/taskchain.odin:130` | **CANONICAL** `native_fact_chain.kind`; signed `native.metadata.import` → `native.metadata.read` (chain). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `coordinator_agent_instance_id` | `src/hub/domain/taskchain.odin:131` | **CANONICAL** `native_fact_chain.coordinator_agent_instance_id`; signed `native.metadata.import` → `native.metadata.read` (chain). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `defaults_json` | `src/hub/domain/taskchain.odin:135` | **CANONICAL** `native_fact_chain.defaults_json`; signed `native.metadata.import` → `native.metadata.read` (chain). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `work_revision` | `src/hub/domain/taskchain.odin:136` | **CANONICAL** `native_fact_chain.work_revision`; signed `native.metadata.import` → `native.metadata.read` (chain). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `completion_summary` | `src/hub/domain/taskchain.odin:137` | **CANONICAL** `native_fact_chain.completion_summary`; signed `native.metadata.import` → `native.metadata.read` (chain). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `last_activity_at` | `src/hub/domain/taskchain.odin:139` | **CANONICAL** `native_fact_chain.last_activity_at`; signed `native.metadata.import` → `native.metadata.read` (chain). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `last_title_nudge_at` | `src/hub/domain/taskchain.odin:140` | **CANONICAL** `native_fact_chain.last_title_nudge_at`; signed `native.metadata.import` → `native.metadata.read` (chain). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `title_source` | `src/hub/domain/taskchain.odin:141` | **CANONICAL** `native_fact_chain.title_source`; signed `native.metadata.import` → `native.metadata.read` (chain). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `created_at` | `src/hub/domain/taskchain.odin:142` | **CANONICAL** `native_fact_chain.created_at`; signed `native.metadata.import` → `native.metadata.read` (chain). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `updated_at` | `src/hub/domain/taskchain.odin:143` | **CANONICAL** `native_fact_chain.updated_at`; signed `native.metadata.import` → `native.metadata.read` (chain). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `published_at` | `src/hub/domain/taskchain.odin:144` | **CANONICAL** `native_fact_chain.published_at`; signed `native.metadata.import` → `native.metadata.read` (chain). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `completed_at` | `src/hub/domain/taskchain.odin:145` | **CANONICAL** `native_fact_chain.completed_at`; signed `native.metadata.import` → `native.metadata.read` (chain). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `is_pinned` | `src/hub/domain/taskchain.odin:146` | **CANONICAL** `native_fact_chain.is_pinned`; signed `native.metadata.import` → `native.metadata.read` (chain). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `pinned_at` | `src/hub/domain/taskchain.odin:147` | **CANONICAL** `native_fact_chain.pinned_at`; signed `native.metadata.import` → `native.metadata.read` (chain). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |

### Task

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `task_id` | `src/hub/domain/taskchain.odin:165` | **CANONICAL** `native_fact_task.task_id`; signed `native.metadata.import` → `native.metadata.read` (task). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `chain_id` | `src/hub/domain/taskchain.odin:166` | **CANONICAL** `native_fact_task.chain_id`; signed `native.metadata.import` → `native.metadata.read` (task). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `owner_user_id` | `src/hub/domain/taskchain.odin:167` | **CANONICAL** `native_fact_task.owner_user_id`; signed `native.metadata.import` → `native.metadata.read` (task). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `title` | `src/hub/domain/taskchain.odin:168` | **CANONICAL** `native_fact_task.title`; signed `native.metadata.import` → `native.metadata.read` (task). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `description` | `src/hub/domain/taskchain.odin:169` | **CANONICAL** `native_fact_task.description`; signed `native.metadata.import` → `native.metadata.read` (task). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `publish_state` | `src/hub/domain/taskchain.odin:170` | **CANONICAL** `native_fact_task.publish_state`; signed `native.metadata.import` → `native.metadata.read` (task). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `state` | `src/hub/domain/taskchain.odin:172` | **CANONICAL** `native_fact_task.state`; signed `native.metadata.import` → `native.metadata.read` (task). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `kind` | `src/hub/domain/taskchain.odin:173` | **CANONICAL** `native_fact_task.kind`; signed `native.metadata.import` → `native.metadata.read` (task). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `priority` | `src/hub/domain/taskchain.odin:174` | **CANONICAL** `native_fact_task.priority`; signed `native.metadata.import` → `native.metadata.read` (task). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `attempt_no` | `src/hub/domain/taskchain.odin:176` | **CANONICAL** `native_fact_task.attempt_no`; signed `native.metadata.import` → `native.metadata.read` (task). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `brief_json` | `src/hub/domain/taskchain.odin:179` | **CANONICAL** `native_fact_task.brief_json`; signed `native.metadata.import` → `native.metadata.read` (task). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `blocked_on_json` | `src/hub/domain/taskchain.odin:183` | **CANONICAL** `native_fact_task.blocked_on_json`; signed `native.metadata.import` → `native.metadata.read` (task). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `requires_user_approval` | `src/hub/domain/taskchain.odin:184` | **CANONICAL** `native_fact_task.requires_user_approval`; signed `native.metadata.import` → `native.metadata.read` (task). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `ready_since` | `src/hub/domain/taskchain.odin:187` | **CANONICAL** `native_fact_task.ready_since`; signed `native.metadata.import` → `native.metadata.read` (task). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `bridge_id` | `src/hub/domain/taskchain.odin:191` | **CANONICAL** `native_fact_task.bridge_id`; signed `native.metadata.import` → `native.metadata.read` (task). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `workflow_run_id` | `src/hub/domain/taskchain.odin:192` | **CANONICAL** `native_fact_task.workflow_run_id`; signed `native.metadata.import` → `native.metadata.read` (task). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `workflow_execution_no` | `src/hub/domain/taskchain.odin:193` | **CANONICAL** `native_fact_task.workflow_execution_no`; signed `native.metadata.import` → `native.metadata.read` (task). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `stage_key` | `src/hub/domain/taskchain.odin:195` | **CANONICAL** `native_fact_task.stage_key`; signed `native.metadata.import` → `native.metadata.read` (task). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `stage_index` | `src/hub/domain/taskchain.odin:196` | **CANONICAL** `native_fact_task.stage_index`; signed `native.metadata.import` → `native.metadata.read` (task). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `generated_by_json` | `src/hub/domain/taskchain.odin:198` | **CANONICAL** `native_fact_task.generated_by_json`; signed `native.metadata.import` → `native.metadata.read` (task). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `created_at` | `src/hub/domain/taskchain.odin:199` | **CANONICAL** `native_fact_task.created_at`; signed `native.metadata.import` → `native.metadata.read` (task). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `updated_at` | `src/hub/domain/taskchain.odin:200` | **CANONICAL** `native_fact_task.updated_at`; signed `native.metadata.import` → `native.metadata.read` (task). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `published_at` | `src/hub/domain/taskchain.odin:201` | **CANONICAL** `native_fact_task.published_at`; signed `native.metadata.import` → `native.metadata.read` (task). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `started_at` | `src/hub/domain/taskchain.odin:202` | **CANONICAL** `native_fact_task.started_at`; signed `native.metadata.import` → `native.metadata.read` (task). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `completed_at` | `src/hub/domain/taskchain.odin:203` | **CANONICAL** `native_fact_task.completed_at`; signed `native.metadata.import` → `native.metadata.read` (task). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |

### Task_Comment

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `delegated_client_id` | `src/hub/domain/taskchain.odin:207` | **CANONICAL** `native_fact_comment.delegated_client_id`; signed `native.metadata.import` → `native.metadata.read` (comment). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `delegated_grant_id` | `src/hub/domain/taskchain.odin:207` | **CANONICAL** `native_fact_comment.delegated_grant_id`; signed `native.metadata.import` → `native.metadata.read` (comment). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `comment_id` | `src/hub/domain/taskchain.odin:208` | **CANONICAL** `native_fact_comment.comment_id`; signed `native.metadata.import` → `native.metadata.read` (comment). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `task_id` | `src/hub/domain/taskchain.odin:209` | **CANONICAL** `native_fact_comment.task_id`; signed `native.metadata.import` → `native.metadata.read` (comment). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `chain_id` | `src/hub/domain/taskchain.odin:210` | **CANONICAL** `native_fact_comment.chain_id`; signed `native.metadata.import` → `native.metadata.read` (comment). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `owner_user_id` | `src/hub/domain/taskchain.odin:211` | **CANONICAL** `native_fact_comment.owner_user_id`; signed `native.metadata.import` → `native.metadata.read` (comment). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `author_agent_instance_id` | `src/hub/domain/taskchain.odin:212` | **CANONICAL** `native_fact_comment.author_agent_instance_id`; signed `native.metadata.import` → `native.metadata.read` (comment). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `body` | `src/hub/domain/taskchain.odin:213` | **CANONICAL** `native_fact_comment.body`; signed `native.metadata.import` → `native.metadata.read` (comment). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `created_at` | `src/hub/domain/taskchain.odin:214` | **CANONICAL** `native_fact_comment.created_at`; signed `native.metadata.import` → `native.metadata.read` (comment). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `updated_at` | `src/hub/domain/taskchain.odin:215` | **CANONICAL** `native_fact_comment.updated_at`; signed `native.metadata.import` → `native.metadata.read` (comment). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |

### Task_Chain_Member

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `chain_id` | `src/hub/domain/taskchain.odin:240` | **CANONICAL** `native_metadata_members.chain_id`; signed `native.metadata.import` → `native.metadata.read` (member). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `agent_instance_id` | `src/hub/domain/taskchain.odin:241` | **CANONICAL** `native_metadata_members.agent_instance_id`; signed `native.metadata.import` → `native.metadata.read` (member). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `agent_id` | `src/hub/domain/taskchain.odin:242` | **CANONICAL** `native_metadata_members.agent_id`; signed `native.metadata.import` → `native.metadata.read` (member). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `owner_user_id` | `src/hub/domain/taskchain.odin:243` | **CANONICAL** `native_metadata_members.owner_user_id`; signed `native.metadata.import` → `native.metadata.read` (member). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `role` | `src/hub/domain/taskchain.odin:244` | **CANONICAL** `native_metadata_members.role`; signed `native.metadata.import` → `native.metadata.read` (member). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `created_at` | `src/hub/domain/taskchain.odin:245` | **CANONICAL** `native_metadata_members.created_at`; signed `native.metadata.import` → `native.metadata.read` (member). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |

### Task_Dependency

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `task_id` | `src/hub/domain/taskchain.odin:249` | **CANONICAL** `native_record_values.record_json.task_id`; signed `native.metadata.import` → `native.metadata.read` (dependency). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `depends_on_task_id` | `src/hub/domain/taskchain.odin:250` | **CANONICAL** `native_record_values.record_json.depends_on_task_id`; signed `native.metadata.import` → `native.metadata.read` (dependency). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `chain_id` | `src/hub/domain/taskchain.odin:251` | **CANONICAL** `native_record_values.record_json.chain_id`; signed `native.metadata.import` → `native.metadata.read` (dependency). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `owner_user_id` | `src/hub/domain/taskchain.odin:252` | **CANONICAL** `native_record_values.record_json.owner_user_id`; signed `native.metadata.import` → `native.metadata.read` (dependency). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `created_at` | `src/hub/domain/taskchain.odin:253` | **CANONICAL** `native_record_values.record_json.created_at`; signed `native.metadata.import` → `native.metadata.read` (dependency). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |

### Task_Chain_Directory

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `directory_id` | `src/hub/domain/taskchain.odin:257` | **CANONICAL** `native_metadata_directories.directory_id`; signed `native.metadata.import` → `native.metadata.read` (directory). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `chain_id` | `src/hub/domain/taskchain.odin:258` | **CANONICAL** `native_metadata_directories.chain_id`; signed `native.metadata.import` → `native.metadata.read` (directory). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `owner_user_id` | `src/hub/domain/taskchain.odin:259` | **CANONICAL** `native_metadata_directories.owner_user_id`; signed `native.metadata.import` → `native.metadata.read` (directory). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `path` | `src/hub/domain/taskchain.odin:260` | **CANONICAL** `native_metadata_directories.path`; signed `native.metadata.import` → `native.metadata.read` (directory). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `bridge_id` | `src/hub/domain/taskchain.odin:261` | **CANONICAL** `native_metadata_directories.bridge_id`; signed `native.metadata.import` → `native.metadata.read` (directory). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `vcs_kind` | `src/hub/domain/taskchain.odin:262` | **CANONICAL** `native_metadata_directories.vcs_kind`; signed `native.metadata.import` → `native.metadata.read` (directory). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `vcs_info_json` | `src/hub/domain/taskchain.odin:263` | **CANONICAL** `native_metadata_directories.vcs_info_json`; signed `native.metadata.import` → `native.metadata.read` (directory). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `created_at` | `src/hub/domain/taskchain.odin:264` | **CANONICAL** `native_metadata_directories.created_at`; signed `native.metadata.import` → `native.metadata.read` (directory). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `updated_at` | `src/hub/domain/taskchain.odin:265` | **CANONICAL** `native_metadata_directories.updated_at`; signed `native.metadata.import` → `native.metadata.read` (directory). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |

### Fleet_Bridge_Model

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `provider_profile` | `src/hub/domain/taskchain.odin:269` | **CANONICAL** `native_fleet_policies.bridge_models_json[bridge].provider_profile`; signed `native.metadata.import` → `native.metadata.read` (nested:fleet.bridge_models_json). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `provider` | `src/hub/domain/taskchain.odin:270` | **CANONICAL** `native_fleet_policies.bridge_models_json[bridge].provider`; signed `native.metadata.import` → `native.metadata.read` (nested:fleet.bridge_models_json). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `model` | `src/hub/domain/taskchain.odin:271` | **CANONICAL** `native_fleet_policies.bridge_models_json[bridge].model`; signed `native.metadata.import` → `native.metadata.read` (nested:fleet.bridge_models_json). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |

### Task_Chain_Fleet

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `provider_profile` | `src/hub/domain/taskchain.odin:300` | **CANONICAL** `native_fleet_policies.provider_profile`; signed `native.metadata.import` → `native.metadata.read` (fleet). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `task_chain_id` | `src/hub/domain/taskchain.odin:301` | **CANONICAL** `native_fleet_policies.chain_id`; signed `native.metadata.import` → `native.metadata.read` (fleet). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `agent_id` | `src/hub/domain/taskchain.odin:302` | **CANONICAL** `native_fleet_policies.agent_id`; signed `native.metadata.import` → `native.metadata.read` (fleet). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `capacity` | `src/hub/domain/taskchain.odin:303` | **CANONICAL** `native_fleet_policies.capacity`; signed `native.metadata.import` → `native.metadata.read` (fleet). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `min_warm` | `src/hub/domain/taskchain.odin:304` | **CANONICAL** `native_fleet_policies.min_warm`; signed `native.metadata.import` → `native.metadata.read` (fleet). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `idle_ttl_seconds` | `src/hub/domain/taskchain.odin:307` | **CANONICAL** `native_fleet_policies.idle_ttl_seconds`; signed `native.metadata.import` → `native.metadata.read` (fleet). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `bridge_models_json` | `src/hub/domain/taskchain.odin:308` | **CANONICAL** `native_fleet_policies.bridge_models_json`; signed `native.metadata.import` → `native.metadata.read` (fleet). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `provider` | `src/hub/domain/taskchain.odin:311` | **CANONICAL** `native_fleet_policies.provider`; signed `native.metadata.import` → `native.metadata.read` (fleet). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `model` | `src/hub/domain/taskchain.odin:312` | **CANONICAL** `native_fleet_policies.model`; signed `native.metadata.import` → `native.metadata.read` (fleet). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `roles_json` | `src/hub/domain/taskchain.odin:314` | **CANONICAL** `native_fleet_policies.roles_json`; signed `native.metadata.import` → `native.metadata.read` (fleet). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `bridge_id` | `src/hub/domain/taskchain.odin:317` | **CANONICAL** `native_fleet_policies.bridge_id`; signed `native.metadata.import` → `native.metadata.read` (fleet). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `paused_roles_json` | `src/hub/domain/taskchain.odin:321` | **CANONICAL** `native_fleet_policies.paused_roles_json`; signed `native.metadata.import` → `native.metadata.read` (fleet). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `created_at` | `src/hub/domain/taskchain.odin:322` | **CANONICAL** `native_fleet_policies.created_at`; signed `native.metadata.import` → `native.metadata.read` (fleet). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `updated_at` | `src/hub/domain/taskchain.odin:323` | **CANONICAL** `native_fleet_policies.updated_at`; signed `native.metadata.import` → `native.metadata.read` (fleet). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |

### Task_Event

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `event_id` | `src/hub/domain/taskv2.odin:10` | **CANONICAL** `native_history_records.record_json.event_id`; signed `native.history.import` → `native.history.read/fetch` (history:event). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `task_id` | `src/hub/domain/taskv2.odin:11` | **CANONICAL** `native_history_records.record_json.task_id`; signed `native.history.import` → `native.history.read/fetch` (history:event). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `chain_id` | `src/hub/domain/taskv2.odin:12` | **CANONICAL** `native_history_records.record_json.chain_id`; signed `native.history.import` → `native.history.read/fetch` (history:event). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `owner_user_id` | `src/hub/domain/taskv2.odin:13` | **CANONICAL** `native_history_records.record_json.owner_user_id`; signed `native.history.import` → `native.history.read/fetch` (history:event). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `ts_ms` | `src/hub/domain/taskv2.odin:14` | **CANONICAL** `native_history_records.record_json.ts_ms`; signed `native.history.import` → `native.history.read/fetch` (history:event). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `actor_kind` | `src/hub/domain/taskv2.odin:17` | **CANONICAL** `native_history_records.record_json.actor_kind`; signed `native.history.import` → `native.history.read/fetch` (history:event). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `actor_id` | `src/hub/domain/taskv2.odin:18` | **CANONICAL** `native_history_records.record_json.actor_id`; signed `native.history.import` → `native.history.read/fetch` (history:event). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `kind` | `src/hub/domain/taskv2.odin:19` | **CANONICAL** `native_history_records.record_json.kind`; signed `native.history.import` → `native.history.read/fetch` (history:event). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `payload_json` | `src/hub/domain/taskv2.odin:20` | **CANONICAL** `native_history_records.record_json.payload_json`; signed `native.history.import` → `native.history.read/fetch` (history:event). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |

### Task_Attempt

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `task_id` | `src/hub/domain/taskv2.odin:27` | **CANONICAL** `native_history_records.record_json.task_id`; signed `native.history.import` → `native.history.read/fetch` (history:attempt). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `attempt_no` | `src/hub/domain/taskv2.odin:28` | **CANONICAL** `native_history_records.record_json.attempt_no`; signed `native.history.import` → `native.history.read/fetch` (history:attempt). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `chain_id` | `src/hub/domain/taskv2.odin:29` | **CANONICAL** `native_history_records.record_json.chain_id`; signed `native.history.import` → `native.history.read/fetch` (history:attempt). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `owner_user_id` | `src/hub/domain/taskv2.odin:30` | **CANONICAL** `native_history_records.record_json.owner_user_id`; signed `native.history.import` → `native.history.read/fetch` (history:attempt). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `started_at` | `src/hub/domain/taskv2.odin:31` | **CANONICAL** `native_history_records.record_json.started_at`; signed `native.history.import` → `native.history.read/fetch` (history:attempt). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `ended_at` | `src/hub/domain/taskv2.odin:32` | **CANONICAL** `native_history_records.record_json.ended_at`; signed `native.history.import` → `native.history.read/fetch` (history:attempt). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `holder_instance_id` | `src/hub/domain/taskv2.odin:33` | **CANONICAL** `native_history_records.record_json.holder_instance_id`; signed `native.history.import` → `native.history.read/fetch` (history:attempt). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `outcome` | `src/hub/domain/taskv2.odin:36` | **CANONICAL** `native_history_records.record_json.outcome`; signed `native.history.import` → `native.history.read/fetch` (history:attempt). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `counts_toward_budget` | `src/hub/domain/taskv2.odin:37` | **CANONICAL** `native_history_records.record_json.counts_toward_budget`; signed `native.history.import` → `native.history.read/fetch` (history:attempt). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |

### Task_Attempt_Facet

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `task_id` | `src/hub/domain/taskv2.odin:43` | **CANONICAL** `native_history_records.record_json.task_id`; signed `native.history.import` → `native.history.read/fetch` (history:facet). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `attempt_no` | `src/hub/domain/taskv2.odin:44` | **CANONICAL** `native_history_records.record_json.attempt_no`; signed `native.history.import` → `native.history.read/fetch` (history:facet). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `chain_id` | `src/hub/domain/taskv2.odin:45` | **CANONICAL** `native_history_records.record_json.chain_id`; signed `native.history.import` → `native.history.read/fetch` (history:facet). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `owner_user_id` | `src/hub/domain/taskv2.odin:46` | **CANONICAL** `native_history_records.record_json.owner_user_id`; signed `native.history.import` → `native.history.read/fetch` (history:facet). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `kind` | `src/hub/domain/taskv2.odin:47` | **CANONICAL** `native_history_records.record_json.kind`; signed `native.history.import` → `native.history.read/fetch` (history:facet). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `v` | `src/hub/domain/taskv2.odin:48` | **CANONICAL** `native_history_records.record_json.v`; signed `native.history.import` → `native.history.read/fetch` (history:facet). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `body_json` | `src/hub/domain/taskv2.odin:49` | **CANONICAL** `native_history_records.record_json.body_json`; signed `native.history.import` → `native.history.read/fetch` (history:facet). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `writer` | `src/hub/domain/taskv2.odin:51` | **CANONICAL** `native_history_records.record_json.writer`; signed `native.history.import` → `native.history.read/fetch` (history:facet). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `written_at` | `src/hub/domain/taskv2.odin:52` | **CANONICAL** `native_history_records.record_json.written_at`; signed `native.history.import` → `native.history.read/fetch` (history:facet). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |

### Task_Lease

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `provider_profile` | `src/hub/domain/taskv2.odin:65` | **CANONICAL** `native_record_values.record_json.provider_profile`; signed `native.metadata.import` → `native.metadata.read` (lease). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `lease_id` | `src/hub/domain/taskv2.odin:66` | **CANONICAL** `native_record_values.record_json.lease_id`; signed `native.metadata.import` → `native.metadata.read` (lease). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `task_id` | `src/hub/domain/taskv2.odin:67` | **CANONICAL** `native_record_values.record_json.task_id`; signed `native.metadata.import` → `native.metadata.read` (lease). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `chain_id` | `src/hub/domain/taskv2.odin:68` | **CANONICAL** `native_record_values.record_json.chain_id`; signed `native.metadata.import` → `native.metadata.read` (lease). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `owner_user_id` | `src/hub/domain/taskv2.odin:69` | **CANONICAL** `native_record_values.record_json.owner_user_id`; signed `native.metadata.import` → `native.metadata.read` (lease). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `attempt_no` | `src/hub/domain/taskv2.odin:70` | **CANONICAL** `native_record_values.record_json.attempt_no`; signed `native.metadata.import` → `native.metadata.read` (lease). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `holder_instance_id` | `src/hub/domain/taskv2.odin:71` | **CANONICAL** `native_record_values.record_json.holder_instance_id`; signed `native.metadata.import` → `native.metadata.read` (lease). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `kind` | `src/hub/domain/taskv2.odin:72` | **CANONICAL** `native_record_values.record_json.kind`; signed `native.metadata.import` → `native.metadata.read` (lease). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `review_role` | `src/hub/domain/taskv2.odin:73` | **CANONICAL** `native_record_values.record_json.review_role`; signed `native.metadata.import` → `native.metadata.read` (lease). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `bridge_id` | `src/hub/domain/taskv2.odin:75` | **CANONICAL** `native_record_values.record_json.bridge_id`; signed `native.metadata.import` → `native.metadata.read` (lease). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `provider` | `src/hub/domain/taskv2.odin:76` | **CANONICAL** `native_record_values.record_json.provider`; signed `native.metadata.import` → `native.metadata.read` (lease). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `model` | `src/hub/domain/taskv2.odin:77` | **CANONICAL** `native_record_values.record_json.model`; signed `native.metadata.import` → `native.metadata.read` (lease). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `granted_at` | `src/hub/domain/taskv2.odin:78` | **CANONICAL** `native_record_values.record_json.granted_at`; signed `native.metadata.import` → `native.metadata.read` (lease). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `confirmed_at` | `src/hub/domain/taskv2.odin:81` | **CANONICAL** `native_record_values.record_json.confirmed_at`; signed `native.metadata.import` → `native.metadata.read` (lease). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `expires_at` | `src/hub/domain/taskv2.odin:83` | **CANONICAL** `native_record_values.record_json.expires_at`; signed `native.metadata.import` → `native.metadata.read` (lease). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `hard_deadline_at` | `src/hub/domain/taskv2.odin:84` | **CANONICAL** `native_record_values.record_json.hard_deadline_at`; signed `native.metadata.import` → `native.metadata.read` (lease). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `last_beat_at` | `src/hub/domain/taskv2.odin:85` | **CANONICAL** `native_record_values.record_json.last_beat_at`; signed `native.metadata.import` → `native.metadata.read` (lease). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `delivery` | `src/hub/domain/taskv2.odin:86` | **CANONICAL** `native_record_values.record_json.delivery`; signed `native.metadata.import` → `native.metadata.read` (lease). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `extended_at` | `src/hub/domain/taskv2.odin:89` | **CANONICAL** `native_record_values.record_json.extended_at`; signed `native.metadata.import` → `native.metadata.read` (lease). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |

### Task_Review

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `task_id` | `src/hub/domain/taskv2.odin:95` | **CANONICAL** `native_record_values.record_json.task_id`; signed `native.metadata.import` → `native.metadata.read` (review). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `chain_id` | `src/hub/domain/taskv2.odin:96` | **CANONICAL** `native_record_values.record_json.chain_id`; signed `native.metadata.import` → `native.metadata.read` (review). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `owner_user_id` | `src/hub/domain/taskv2.odin:97` | **CANONICAL** `native_record_values.record_json.owner_user_id`; signed `native.metadata.import` → `native.metadata.read` (review). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `attempt_no` | `src/hub/domain/taskv2.odin:98` | **CANONICAL** `native_record_values.record_json.attempt_no`; signed `native.metadata.import` → `native.metadata.read` (review). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `role` | `src/hub/domain/taskv2.odin:99` | **CANONICAL** `native_record_values.record_json.role`; signed `native.metadata.import` → `native.metadata.read` (review). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `reviewer_kind` | `src/hub/domain/taskv2.odin:101` | **CANONICAL** `native_record_values.record_json.reviewer_kind`; signed `native.metadata.import` → `native.metadata.read` (review). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `reviewer_agent_id` | `src/hub/domain/taskv2.odin:102` | **CANONICAL** `native_record_values.record_json.reviewer_agent_id`; signed `native.metadata.import` → `native.metadata.read` (review). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `reviewer_instance_id` | `src/hub/domain/taskv2.odin:103` | **CANONICAL** `native_record_values.record_json.reviewer_instance_id`; signed `native.metadata.import` → `native.metadata.read` (review). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `verdict` | `src/hub/domain/taskv2.odin:104` | **CANONICAL** `native_record_values.record_json.verdict`; signed `native.metadata.import` → `native.metadata.read` (review). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `findings_json` | `src/hub/domain/taskv2.odin:105` | **CANONICAL** `native_record_values.record_json.findings_json`; signed `native.metadata.import` → `native.metadata.read` (review). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `created_at` | `src/hub/domain/taskv2.odin:106` | **CANONICAL** `native_record_values.record_json.created_at`; signed `native.metadata.import` → `native.metadata.read` (review). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |

### Chain_Summary

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `curated_body` | `src/hub/domain/taskv2.odin:110` | **CANONICAL** `native_fact_summary.curated_body`; signed `native.metadata.import` → `native.metadata.read` (summary). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `curated_initialized` | `src/hub/domain/taskv2.odin:111` | **CANONICAL** `native_fact_summary.curated_initialized`; signed `native.metadata.import` → `native.metadata.read` (summary). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `failure_fingerprint` | `src/hub/domain/taskv2.odin:112` | **CANONICAL** `native_fact_summary.failure_fingerprint`; signed `native.metadata.import` → `native.metadata.read` (summary). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `chain_id` | `src/hub/domain/taskv2.odin:113` | **CANONICAL** `native_fact_summary.chain_id`; signed `native.metadata.import` → `native.metadata.read` (summary). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `owner_user_id` | `src/hub/domain/taskv2.odin:114` | **CANONICAL** `native_fact_summary.owner_user_id`; signed `native.metadata.import` → `native.metadata.read` (summary). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `body` | `src/hub/domain/taskv2.odin:115` | **CANONICAL** `native_fact_summary.body`; signed `native.metadata.import` → `native.metadata.read` (summary). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `line_count` | `src/hub/domain/taskv2.odin:116` | **CANONICAL** `native_fact_summary.line_count`; signed `native.metadata.import` → `native.metadata.read` (summary). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `version` | `src/hub/domain/taskv2.odin:117` | **CANONICAL** `native_fact_summary.version`; signed `native.metadata.import` → `native.metadata.read` (summary). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `updated_at` | `src/hub/domain/taskv2.odin:118` | **CANONICAL** `native_fact_summary.updated_at`; signed `native.metadata.import` → `native.metadata.read` (summary). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |

### Workflow_Definition

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `def_id` | `src/hub/domain/taskv2.odin:122` | **CANONICAL** `native_record_values.record_json.def_id`; signed `native.metadata.import` → `native.metadata.read` (definition). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `owner_user_id` | `src/hub/domain/taskv2.odin:123` | **CANONICAL** `native_record_values.record_json.owner_user_id`; signed `native.metadata.import` → `native.metadata.read` (definition). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `name` | `src/hub/domain/taskv2.odin:124` | **CANONICAL** `native_record_values.record_json.name`; signed `native.metadata.import` → `native.metadata.read` (definition). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `version` | `src/hub/domain/taskv2.odin:125` | **CANONICAL** `native_record_values.record_json.version`; signed `native.metadata.import` → `native.metadata.read` (definition). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `body_json` | `src/hub/domain/taskv2.odin:126` | **CANONICAL** `native_record_values.record_json.body_json`; signed `native.metadata.import` → `native.metadata.read` (definition). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `created_at` | `src/hub/domain/taskv2.odin:127` | **CANONICAL** `native_record_values.record_json.created_at`; signed `native.metadata.import` → `native.metadata.read` (definition). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |

### Workflow_Run

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `run_id` | `src/hub/domain/workflow_run.odin:9` | **CANONICAL** `native_work_records.record_json.run_id`; signed `native.metadata.import` → `native.metadata.read` (work_run). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `chain_id` | `src/hub/domain/workflow_run.odin:10` | **CANONICAL** `native_work_records.record_json.chain_id`; signed `native.metadata.import` → `native.metadata.read` (work_run). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `owner_user_id` | `src/hub/domain/workflow_run.odin:11` | **CANONICAL** `native_work_records.record_json.owner_user_id`; signed `native.metadata.import` → `native.metadata.read` (work_run). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `title` | `src/hub/domain/workflow_run.odin:12` | **CANONICAL** `native_work_records.record_json.title`; signed `native.metadata.import` → `native.metadata.read` (work_run). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `definition_ref` | `src/hub/domain/workflow_run.odin:13` | **CANONICAL** `native_work_records.record_json.definition_ref`; signed `native.metadata.import` → `native.metadata.read` (work_run). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `spec_json` | `src/hub/domain/workflow_run.odin:14` | **CANONICAL** `native_work_records.record_json.spec_json`; signed `native.metadata.import` → `native.metadata.read` (work_run). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `inputs_json` | `src/hub/domain/workflow_run.odin:15` | **CANONICAL** `native_work_records.record_json.inputs_json`; signed `native.metadata.import` → `native.metadata.read` (work_run). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `current_execution_no` | `src/hub/domain/workflow_run.odin:16` | **CANONICAL** `native_work_records.record_json.current_execution_no`; signed `native.metadata.import` → `native.metadata.read` (work_run). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `request_id` | `src/hub/domain/workflow_run.odin:17` | **CANONICAL** `native_work_records.record_json.request_id`; signed `native.metadata.import` → `native.metadata.read` (work_run). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `request_hash` | `src/hub/domain/workflow_run.odin:18` | **CANONICAL** `native_work_records.record_json.request_hash`; signed `native.metadata.import` → `native.metadata.read` (work_run). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `created_by_kind` | `src/hub/domain/workflow_run.odin:19` | **CANONICAL** `native_work_records.record_json.created_by_kind`; signed `native.metadata.import` → `native.metadata.read` (work_run). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `created_by_id` | `src/hub/domain/workflow_run.odin:20` | **CANONICAL** `native_work_records.record_json.created_by_id`; signed `native.metadata.import` → `native.metadata.read` (work_run). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `created_at` | `src/hub/domain/workflow_run.odin:21` | **CANONICAL** `native_work_records.record_json.created_at`; signed `native.metadata.import` → `native.metadata.read` (work_run). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `updated_at` | `src/hub/domain/workflow_run.odin:22` | **CANONICAL** `native_work_records.record_json.updated_at`; signed `native.metadata.import` → `native.metadata.read` (work_run). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `revision` | `src/hub/domain/workflow_run.odin:23` | **CANONICAL** `native_work_records.record_json.revision`; signed `native.metadata.import` → `native.metadata.read` (work_run). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |

### Workflow_Run_Execution

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `run_id` | `src/hub/domain/workflow_run.odin:35` | **CANONICAL** `native_work_records.record_json.run_id`; signed `native.metadata.import` → `native.metadata.read` (work_execution). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `execution_no` | `src/hub/domain/workflow_run.odin:36` | **CANONICAL** `native_work_records.record_json.execution_no`; signed `native.metadata.import` → `native.metadata.read` (work_execution). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `chain_id` | `src/hub/domain/workflow_run.odin:37` | **CANONICAL** `native_work_records.record_json.chain_id`; signed `native.metadata.import` → `native.metadata.read` (work_execution). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `owner_user_id` | `src/hub/domain/workflow_run.odin:38` | **CANONICAL** `native_work_records.record_json.owner_user_id`; signed `native.metadata.import` → `native.metadata.read` (work_execution). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `state` | `src/hub/domain/workflow_run.odin:39` | **CANONICAL** `native_work_records.record_json.state`; signed `native.metadata.import` → `native.metadata.read` (work_execution). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `resolved_inputs_json` | `src/hub/domain/workflow_run.odin:40` | **CANONICAL** `native_work_records.record_json.resolved_inputs_json`; signed `native.metadata.import` → `native.metadata.read` (work_execution). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `started_at` | `src/hub/domain/workflow_run.odin:41` | **CANONICAL** `native_work_records.record_json.started_at`; signed `native.metadata.import` → `native.metadata.read` (work_execution). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `ended_at` | `src/hub/domain/workflow_run.odin:42` | **CANONICAL** `native_work_records.record_json.ended_at`; signed `native.metadata.import` → `native.metadata.read` (work_execution). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `failure_code` | `src/hub/domain/workflow_run.odin:43` | **CANONICAL** `native_work_records.record_json.failure_code`; signed `native.metadata.import` → `native.metadata.read` (work_execution). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `failure_detail` | `src/hub/domain/workflow_run.odin:44` | **CANONICAL** `native_work_records.record_json.failure_detail`; signed `native.metadata.import` → `native.metadata.read` (work_execution). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `output_manifest_json` | `src/hub/domain/workflow_run.odin:45` | **CANONICAL** `native_work_records.record_json.output_manifest_json`; signed `native.metadata.import` → `native.metadata.read` (work_execution). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `revision` | `src/hub/domain/workflow_run.odin:46` | **CANONICAL** `native_work_records.record_json.revision`; signed `native.metadata.import` → `native.metadata.read` (work_execution). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |

### Workflow_Stage_Execution

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `run_id` | `src/hub/domain/workflow_run.odin:52` | **CANONICAL** `native_work_records.record_json.run_id`; signed `native.metadata.import` → `native.metadata.read` (work_stage). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `execution_no` | `src/hub/domain/workflow_run.odin:53` | **CANONICAL** `native_work_records.record_json.execution_no`; signed `native.metadata.import` → `native.metadata.read` (work_stage). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `stage_key` | `src/hub/domain/workflow_run.odin:54` | **CANONICAL** `native_work_records.record_json.stage_key`; signed `native.metadata.import` → `native.metadata.read` (work_stage). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `chain_id` | `src/hub/domain/workflow_run.odin:55` | **CANONICAL** `native_work_records.record_json.chain_id`; signed `native.metadata.import` → `native.metadata.read` (work_stage). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `owner_user_id` | `src/hub/domain/workflow_run.odin:56` | **CANONICAL** `native_work_records.record_json.owner_user_id`; signed `native.metadata.import` → `native.metadata.read` (work_stage). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `item_count` | `src/hub/domain/workflow_run.odin:57` | **CANONICAL** `native_work_records.record_json.item_count`; signed `native.metadata.import` → `native.metadata.read` (work_stage). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `expanded_at` | `src/hub/domain/workflow_run.odin:58` | **CANONICAL** `native_work_records.record_json.expanded_at`; signed `native.metadata.import` → `native.metadata.read` (work_stage). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |

### Workflow_Run_Event

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `event_id` | `src/hub/domain/workflow_run.odin:62` | **CANONICAL** `native_work_records.record_json.event_id`; signed `native.metadata.import` → `native.metadata.read` (work_event). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `run_id` | `src/hub/domain/workflow_run.odin:63` | **CANONICAL** `native_work_records.record_json.run_id`; signed `native.metadata.import` → `native.metadata.read` (work_event). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `execution_no` | `src/hub/domain/workflow_run.odin:64` | **CANONICAL** `native_work_records.record_json.execution_no`; signed `native.metadata.import` → `native.metadata.read` (work_event). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `chain_id` | `src/hub/domain/workflow_run.odin:65` | **CANONICAL** `native_work_records.record_json.chain_id`; signed `native.metadata.import` → `native.metadata.read` (work_event). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `owner_user_id` | `src/hub/domain/workflow_run.odin:66` | **CANONICAL** `native_work_records.record_json.owner_user_id`; signed `native.metadata.import` → `native.metadata.read` (work_event). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `ts_ms` | `src/hub/domain/workflow_run.odin:67` | **CANONICAL** `native_work_records.record_json.ts_ms`; signed `native.metadata.import` → `native.metadata.read` (work_event). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `actor_kind` | `src/hub/domain/workflow_run.odin:68` | **CANONICAL** `native_work_records.record_json.actor_kind`; signed `native.metadata.import` → `native.metadata.read` (work_event). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `actor_id` | `src/hub/domain/workflow_run.odin:69` | **CANONICAL** `native_work_records.record_json.actor_id`; signed `native.metadata.import` → `native.metadata.read` (work_event). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `kind` | `src/hub/domain/workflow_run.odin:70` | **CANONICAL** `native_work_records.record_json.kind`; signed `native.metadata.import` → `native.metadata.read` (work_event). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `payload_json` | `src/hub/domain/workflow_run.odin:71` | **CANONICAL** `native_work_records.record_json.payload_json`; signed `native.metadata.import` → `native.metadata.read` (work_event). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |

## Mixed-work canonical graph records

These are also part of the original full aggregate. Internal local task DAGs and output-trigger prerequisites do not establish external task/run dependency, scope-decision or consumption-receipt parity.

### Work_Item_Ref

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `kind` | `src/hub/domain/mixed_work.odin:9` | **CANONICAL** `native_work_records.record_json.dependent.kind`; signed `native.metadata.import` → `native.metadata.read` (nested:work_dependency.dependent). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `id` | `src/hub/domain/mixed_work.odin:10` | **CANONICAL** `native_work_records.record_json.dependent.id`; signed `native.metadata.import` → `native.metadata.read` (nested:work_dependency.dependent). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |

### Work_Dependency

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `dependency_id` | `src/hub/domain/mixed_work.odin:14` | **CANONICAL** `native_work_records.record_json.dependency_id`; signed `native.metadata.import` → `native.metadata.read` (work_dependency). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `chain_id` | `src/hub/domain/mixed_work.odin:15` | **CANONICAL** `native_work_records.record_json.chain_id`; signed `native.metadata.import` → `native.metadata.read` (work_dependency). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `owner_user_id` | `src/hub/domain/mixed_work.odin:16` | **CANONICAL** `native_work_records.record_json.owner_user_id`; signed `native.metadata.import` → `native.metadata.read` (work_dependency). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `dependent` | `src/hub/domain/mixed_work.odin:17` | **CANONICAL** `native_work_records.record_json.dependent`; signed `native.metadata.import` → `native.metadata.read` (work_dependency). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `prerequisite` | `src/hub/domain/mixed_work.odin:18` | **CANONICAL** `native_work_records.record_json.prerequisite`; signed `native.metadata.import` → `native.metadata.read` (work_dependency). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `created_by_kind` | `src/hub/domain/mixed_work.odin:19` | **CANONICAL** `native_work_records.record_json.created_by_kind`; signed `native.metadata.import` → `native.metadata.read` (work_dependency). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `created_by_id` | `src/hub/domain/mixed_work.odin:20` | **CANONICAL** `native_work_records.record_json.created_by_id`; signed `native.metadata.import` → `native.metadata.read` (work_dependency). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `created_at` | `src/hub/domain/mixed_work.odin:21` | **CANONICAL** `native_work_records.record_json.created_at`; signed `native.metadata.import` → `native.metadata.read` (work_dependency). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `removed_at` | `src/hub/domain/mixed_work.odin:24` | **CANONICAL** `native_work_records.record_json.removed_at`; signed `native.metadata.import` → `native.metadata.read` (work_dependency). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `removed_by_kind` | `src/hub/domain/mixed_work.odin:25` | **CANONICAL** `native_work_records.record_json.removed_by_kind`; signed `native.metadata.import` → `native.metadata.read` (work_dependency). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `removed_by_id` | `src/hub/domain/mixed_work.odin:26` | **CANONICAL** `native_work_records.record_json.removed_by_id`; signed `native.metadata.import` → `native.metadata.read` (work_dependency). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `removal_reason` | `src/hub/domain/mixed_work.odin:27` | **CANONICAL** `native_work_records.record_json.removal_reason`; signed `native.metadata.import` → `native.metadata.read` (work_dependency). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |

### Work_Input_Receipt

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `receipt_id` | `src/hub/domain/mixed_work.odin:34` | **CANONICAL** `native_work_records.record_json.receipt_id`; signed `native.metadata.import` → `native.metadata.read` (work_receipt). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `chain_id` | `src/hub/domain/mixed_work.odin:35` | **CANONICAL** `native_work_records.record_json.chain_id`; signed `native.metadata.import` → `native.metadata.read` (work_receipt). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `owner_user_id` | `src/hub/domain/mixed_work.odin:36` | **CANONICAL** `native_work_records.record_json.owner_user_id`; signed `native.metadata.import` → `native.metadata.read` (work_receipt). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `dependent` | `src/hub/domain/mixed_work.odin:37` | **CANONICAL** `native_work_records.record_json.dependent`; signed `native.metadata.import` → `native.metadata.read` (work_receipt). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `dependent_generation` | `src/hub/domain/mixed_work.odin:38` | **CANONICAL** `native_work_records.record_json.dependent_generation`; signed `native.metadata.import` → `native.metadata.read` (work_receipt). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `prerequisite` | `src/hub/domain/mixed_work.odin:39` | **CANONICAL** `native_work_records.record_json.prerequisite`; signed `native.metadata.import` → `native.metadata.read` (work_receipt). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `prerequisite_generation` | `src/hub/domain/mixed_work.odin:40` | **CANONICAL** `native_work_records.record_json.prerequisite_generation`; signed `native.metadata.import` → `native.metadata.read` (work_receipt). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `output_manifest_json` | `src/hub/domain/mixed_work.odin:41` | **CANONICAL** `native_work_records.record_json.output_manifest_json`; signed `native.metadata.import` → `native.metadata.read` (work_receipt). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `created_at` | `src/hub/domain/mixed_work.odin:42` | **CANONICAL** `native_work_records.record_json.created_at`; signed `native.metadata.import` → `native.metadata.read` (work_receipt). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |

### Work_Scope_Decision

| Native field | Original source | Local status and mapping |
| --- | --- | --- |
| `decision_id` | `src/hub/domain/mixed_work.odin:46` | **CANONICAL** `native_work_records.record_json.decision_id`; signed `native.metadata.import` → `native.metadata.read` (work_scope). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `chain_id` | `src/hub/domain/mixed_work.odin:47` | **CANONICAL** `native_work_records.record_json.chain_id`; signed `native.metadata.import` → `native.metadata.read` (work_scope). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `owner_user_id` | `src/hub/domain/mixed_work.odin:48` | **CANONICAL** `native_work_records.record_json.owner_user_id`; signed `native.metadata.import` → `native.metadata.read` (work_scope). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `item` | `src/hub/domain/mixed_work.odin:49` | **CANONICAL** `native_work_records.record_json.item`; signed `native.metadata.import` → `native.metadata.read` (work_scope). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `action` | `src/hub/domain/mixed_work.odin:50` | **CANONICAL** `native_work_records.record_json.action`; signed `native.metadata.import` → `native.metadata.read` (work_scope). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `reason` | `src/hub/domain/mixed_work.odin:51` | **CANONICAL** `native_work_records.record_json.reason`; signed `native.metadata.import` → `native.metadata.read` (work_scope). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `actor_kind` | `src/hub/domain/mixed_work.odin:52` | **CANONICAL** `native_work_records.record_json.actor_kind`; signed `native.metadata.import` → `native.metadata.read` (work_scope). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `actor_id` | `src/hub/domain/mixed_work.odin:53` | **CANONICAL** `native_work_records.record_json.actor_id`; signed `native.metadata.import` → `native.metadata.read` (work_scope). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |
| `created_at` | `src/hub/domain/mixed_work.odin:54` | **CANONICAL** `native_work_records.record_json.created_at`; signed `native.metadata.import` → `native.metadata.read` (work_scope). Every value/type compared by `src/lib/owner_local/aggregate_test.odin:37`; executed by `src/lib/owner_local/aggregate_test.odin:90`. |

## Current command parity gate

Accepted C1a-C1e signed families are canonical per `cmt_18e592e4d810d71a`. Every enabled signed-device method is assigned below, alongside the accepted exact-child lifecycle families. M4 owns legacy route-format convergence.

| Native command family / source | Signed equivalents | Executed proof |
| --- | --- | --- |
| Chain/task prose, draft, publication, priority / `src/hub/service/taskchain/taskchain_service.odin:450` | `chain.create`, `chain.edit`, `chain.draft`, `chain.publish`, `task.create`, `task.draft`, `task.edit`, `task.delete`, `task.publish`, `task.priority`, `task.comment` | `src/lib/owner_local/work_publication_test.odin:69` |
| Proposals and mixed scope/completion / `src/hub/service/taskv2/mixed_work.odin:92` | `chain.propose`, `chain.decide`, `work.dependency.add`, `work.dependency.remove`, `work.scope`, `chain.complete`, `work.read`, `dependency.edit` | `src/lib/owner_local/work_graph_test.odin:153` |
| Rich briefs and output / `src/hub/service/taskv2/brief_schema.odin:16` | `requirements.edit`, `requirements.present`, `requirements.ack`, `lease.submit`, `submission.read` | `src/lib/owner_local/aggregate_test.odin:106` |
| Claim, heartbeat, switch, handoff, block / `src/hub/service/taskv2/verbs_m2.odin:226` | `lease.claim`, `lease.heartbeat`, `lease.switch`, `lease.handoff`, `lease.block` | `src/lib/owner_local/work_admission_regression_test.odin:136` |
| Independent, role and human review / `src/hub/service/taskv2/verbs_m2.odin:328` | `review.open`, `review.post`, `review.role.open`, `review.role.post`, `review.roles`, `review.checkpoint` | `src/lib/owner_local/review_roles_test.odin:30` |
| Controls and merge recovery / `src/hub/service/taskv2/verbs_m2.odin:553` | `task.hold`, `task.release`, `task.cancel`, `task.reopen`, `task.resolve`, `merge.retry` | `src/lib/owner_local/controls_test.odin:72` |
| Metadata and fleet policy / `src/hub/domain/taskchain.odin:239` | `chain.member.set`, `chain.directory.set`, `chain.defaults.set`, `chain.summary.set`, `fleet.policy.set`, `fleet.policy.read`, `chain.metadata.read`, `fleet.edit`, `lifecycle.configure`, `runtime.read` | `src/lib/owner_local/operational_metadata_test.odin:39` |
| Workflow execution and output prerequisites / `src/hub/service/taskv2/workflow_execution.odin:481` | `workflow.define`, `workflow.run`, `workflow.draft`, `workflow.retry`, `workflow.cancel`, `workflow.read` | `src/lib/owner_local/work_graph_test.odin:208` |
| Source results and consumption / `src/hub/domain/taskv2.odin:9` | `source.observe`, `source.consume`, `source.ack`, `source.retire`, `source.resolve`, `source.escalate`, `source.read` | `src/lib/owner_local/sources_test.odin:55` |
| History and complete native export / `src/hub/service/taskv2/facets.odin:279` | `history.read`, `history.fetch`, `native.history.import`, `native.history.read`, `native.history.fetch`, `native.metadata.import`, `native.metadata.read` | `src/lib/owner_local/aggregate_test.odin:90` |
| Search, context and read authorization / `src/hub/service/taskv2/pack.odin:1` | `chain.search`, `chain.read`, `task.read`, `context.read`, `receipt.read` | `src/lib/owner_local/aggregate_test.odin:162` |
| Native attempt/expiry history (owner-local budget removed 2026-11-07) / `src/hub/service/taskv2/lease.odin:177` | `attempt.read` | `src/lib/owner_local/attempts_test.odin:27` |
| Grants and root recovery / `src/hub/domain/taskchain.odin:124` | `grant.set`, `grant.revoke`, `grant.read`, `grant.policy`, `grant.recover` | `src/lib/owner_local/grants_test.odin:47` |
| Workflow coordinator and explicit gates / `src/hub/service/taskv2/workflow_execution.odin:481` | `workflow.coordinator`, `workflow.gate`, `workflow.gate.post` | `src/lib/owner_local/workflow_language_test.odin:179` |

Only C3 bodies/envelopes/blob indexes, M3 dispatch/catalog/slot reservation, and M4 primary UI/CLI/live DB cutover remain. Exact source values are canonical, not waived by those milestones.

## C1/C3 shared reference contract

Coordinator message msg_18e5742cd8404560: retain native facet payload plus original typed artifact/message IDs and pinned revision/provenance. C3 owns plan local_objects canonical bodies/envelopes/blobs. C1 must not invent parallel IDs, paths or a second body table. Unknown references remain explicitly unresolved/import-pending; artifact text indexing stays deferred.

## Event transport and upgrade

Both history methods are chain-scoped signed device reads with current read authorization checked before any lookup. history.read takes the existing cursor/limit payload (limit 1..100). Keyset cursors bind account+chain and survive appends. history.fetch takes seq and byte offset as decimal strings; evidence is returned in UTF-8-safe chunks of at most 8192 raw bytes, with next_offset. Read-only grants work; revoked grants fail. No Hub content join or authority fallback is involved.

V13 is additive after V12. It copies existing local_changes only as legacy_tag with a null timestamp, unknown actor and empty evidence. It does not invent original payloads that prior slices never stored. Subsequent accepted device, lease, lifecycle, coordinator, expiry and source/merge completion mutations append evidence in their original UoW. Failed mutations/replays do not add events. Receipt compaction does not remove events.

## Historical completion gate (superseded by C1f current matrix)

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
src/lib/owner_local/controls.odin:162).
This does **not** claim max_attempts parity: original handoff continuations reuse
an attempt number, and replaced/dependency-added/reopened releases have
different counting semantics (src/hub/service/taskv2/fold.odin:138;
src/hub/service/taskv2/fold.odin:377). Counting local_work_attempts rows would be
incorrect. That native attempt model remains required work.

## Verified implementation checkpoint (requirements revision 1, attempt 2)

Commits: f2b0a40e (V13 events/initial ledger), d331951c (nested brief policy and
deadline handling), fae3a837 (mixed-work field coverage), followed by the
UTF-8/deletion regression and this verification record. Work is scoped to
`/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e569e48d6b5532`.
This is a checkpoint of unfinished C1 work, not a request to accept the full
aggregate. All OPEN/PARTIAL rows remain binding.

Exact successful commands, run in that Workdir through managed shell:

```bash
python3 scripts/generate-owner-local-contracts.py
python3 scripts/check-owner-aggregate-parity.py
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1-store-final99
nix develop --command odin test src/contracts -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1-events-contracts
nix develop --command odin test src/lib/workflow_v1 -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1-policy-language-final
nix develop --command npm ci --ignore-scripts --no-audit --no-fund
nix develop --command npm run typecheck
nix develop --command node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_controls_test.ts tests/ui_owner_grants_test.ts tests/ui_owner_registry_listing_test.ts tests/ui_owner_submission_history_test.ts tests/ui_owner_local_contract_test.ts
nix build .#ham-bridge .#ham-hub .#ham-ctl .#ham-pty-host -o $HOME/.cache/heimdall-tests/c1-policy-bins
nix develop --command odin build tools/owner_local_test_identity -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1-events-identity
nix develop --command env \
  HEIMDALL_E2E_HUB_BIN=$HOME/.cache/heimdall-tests/c1-policy-bins-1/bin/ham-hub \
  HEIMDALL_E2E_BRIDGE_BIN=$HOME/.cache/heimdall-tests/c1-policy-bins/bin/ham-bridge \
  HEIMDALL_E2E_CTL_BIN=$HOME/.cache/heimdall-tests/c1-policy-bins-2/bin/ham-ctl \
  HEIMDALL_E2E_PTY_BIN=$HOME/.cache/heimdall-tests/c1-policy-bins-3/bin/ham-pty-host \
  HEIMDALL_E2E_IDENTITY_BIN=$HOME/.cache/heimdall-tests/c1-events-identity \
  HEIMDALL_E2E_OWNER_LOCAL=1 HEIMDALL_E2E_OWNER_LEASE=1 \
  HEIMDALL_E2E_OWNER_LIFECYCLE=1 HEIMDALL_E2E_OWNER_CONTROLS=1 \
  HEIMDALL_E2E_OWNER_WORKFLOWS=1 HEIMDALL_E2E_OWNER_LANGUAGE=1 \
  HEIMDALL_E2E_OWNER_GRANTS=1 HEIMDALL_E2E_OWNER_REGISTRY=1 \
  node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/bridge_real_enroll_e2e.mjs
git diff --check
```

The matrix check accounts for 240 fields across 23 native structs. Contracts:
18/18; workflow language: 10/10; retained UI contracts: 15/15. Typecheck,
all four binary builds and the final real disposable demo pass.
The final demo is managed session `sh_b3ff73443bb29f7bcd8aca0b82949c47`,
exit 0, all steps passed; the event-checkpoint demo also passed as
`sh_2007a293a1458ffe8eb4d15b2fcb0b38`.
Final store suite count/result is recorded in the task handoff.

The real demo exercises production browser signing, actual CLI requests,
authenticated Hub relay, actual local owner restart, synthetic child PTYs,
Git merge paths, rendered controls, static/language workflows, search,
grants and registry pagination/revocation using disposable identities only.
It proves the new event transport through the real route and preserves
existing demos. It does not prove the missing native aggregate adapters or
a rich full-legacy import; those remain required. No production deployment,
live service restart, credential experiment or push was performed.
No unrelated boy-scout edits were made.

Corrected development dead ends: event INSERT initially had one extra
placeholder; an Odin test initially used unsupported multiline-do syntax;
typecheck initially lacked the already-pinned posthog-js dependency (npm ci
restored it without lock changes); the first broad demo omitted OWNER_LEASE
and therefore had no launchChild for controls (correct flags above pass).
The Unicode regression initially assumed the event encoder emitted literal
UTF-8; it actually escapes Unicode, so the final regression uses synthetic
verbatim native UTF-8 evidence to exercise continuation offsets and chunk
boundaries. These failures were corrected; do not infer remaining runtime
defects from their earlier logs.

Continue with the native attempt/outcome/counting model before max_attempts
enforcement; then integrate full metadata, publication/proposal decisions,
membership/directories/fleet policy, curated-summary metadata, all typed
facets/reference provenance, mixed-work records and strict ordinary adapters.
Use the OPEN/PARTIAL ledger rows as the acceptance checklist. Preserve V13
and its historical reconstruction helpers, shared W2 output validation,
current read authorization before replay, and the C1/C3 reference contract.
Full aggregate readiness is still below submission confidence. Independent
named code review remains required after completing C1.

## Native attempt projection checkpoint (attempt 3)

`runtime.read.attempts` is an additive observation, with the generated
`attempt_state` contract in `src/contracts/fixtures/owner-local-schema.json`.
It contains decimal-string `attempt_no` and `counting_attempts`, `last_release`,
the last granted `work_lease_id`, and `completeness` (`full` or `incomplete`).
`full` describes evidence for this projection, not completion of C1 or proof
that all native aggregate fields have been imported. Never enable migration
cutover or budget enforcement merely because that string is `full`.

The projection folds retained accepted events rather than counting leases or
submissions (`src/lib/owner_local/attempts.odin:86`). Handoff continues the same
attempt; a structural release affects whether the next grant spends budget
(`src/lib/owner_local/attempts.odin:18`). Both halves of an atomic switch are
read from its single retained event. Native grant counters are compared against
the original fold after every prefix of a synthetic event sequence
(`src/hub/service/taskv2/owner_attempt_projection_test.odin:13`). Existing V7
lease ordinals, V4 submission keys, their references, and V13 event/schema
history remain untouched. This checkpoint requires no database migration.

Required gaps remain explicit. V13 `legacy_tag` events lack native evidence;
the projection marks them incomplete instead of fabricating outcomes. A
workflow-wide retirement without a task-specific native event mapping also
marks the projection incomplete (`src/lib/owner_local/attempts.odin:122`).
Native per-attempt facets and submission-to-native-attempt mapping still need
implementation; `max_attempts` enforcement is not enabled by this checkpoint.

The controls question above was resolved by requirements revision 2 (REQ-P4):
C1 owns the correction. The new hold checkpoint below supersedes the old local
revocation behavior; old retained evidence is not rewritten.

## Native hold checkpoint (revision 2)

Native hold preserves live leases and asks for a checkpoint
(`src/hub/service/taskv2/verbs_m2.odin:622`). The owner now preserves live
work/review capabilities and deadlines while sending an exact-child notice
(`src/lib/owner_local/controls.odin:79`). New work/review admission remains
blocked; current holders may heartbeat, present/ACK requirements, submit, vote,
or checkpoint (`src/lib/owner_local/leases.odin:103`,
`src/lib/owner_local/lifecycle_agent.odin:66`). Work handoff continues its native
attempt; ordinary expiry still closes it. Hold alone spends nothing.

The hold is an overlay over the current lifecycle state. Release never restores
a stale pre-submit state, and a block saved while held remains blocked
(`src/lib/owner_local/controls.odin:85`). Verdicts are recorded while held;
the gate waits (`src/lib/owner_local/review_roles.odin:64`). Release evaluates
the retained gate and, if needed, creates a merge intent pinned to the original
submission (`src/lib/owner_local/store.odin:327`). Existing exact-child, current
read authorization, expiry, independent-review and replay boundaries remain.

New holds create no checkpoint-only capability. Old retired checkpoint bindings
remain narrowly usable for one unexpired checkpoint, never heartbeat/submit
(`src/lib/owner_local/controls.odin:212`). New immutable hold-event content
records `hold_semantics: live_lease_v1` (`src/contracts/owner_local.odin:15`,
`src/lib/owner_local/store.odin:317`); pre-fix held-work history stays explicitly
incomplete (`src/lib/owner_local/attempts.odin:66`). No migration or historical
rewrite is needed. V13 and every earlier migration remain unchanged.

The production Bridge notice consumer now permits a hold checkpoint directed
at its existing live holder/session, while skipping transferred/replaced children
and obsolete released holds (`src/bridge/owner_local_controls.odin:54`,
`src/bridge/owner_local_controls.odin:86`). The real synthetic provider records
incoming PTY notices so the disposable demo proves actual delivery as well as
a successful local storage command.

Signed regressions in `src/lib/owner_local/hold_test.odin` cover restart,
heartbeat renewal with pinned hard deadline, no new dispatch, one checkpoint,
native continuation, expiry, legacy compatibility, nested block preservation,
held submission, deferred approval/request-changes, exact merge binding and
release rollback/replay. Native-fold prefix comparison includes hold/checkpoint/
release (`src/hub/service/taskv2/owner_attempt_projection_test.odin:13`).
Full aggregate parity is still incomplete: native attempt records/facets/import,
budget enforcement, metadata/publication/config, strict ordinary adapters and
the rich full-legacy fixture remain required. This checkpoint does not authorize
migration cutover or C1 submission.

Checkpoint checks (all from the task Workdir):

```bash
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1-r2-store-final
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_NAMES=owner_local.hold_requirements_rework_clears_deferred_rejection_without_counting_new_budget -out:$HOME/.cache/heimdall-tests/c1-r2-rework
nix develop --command odin test src/contracts -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1-r2-contracts
nix develop --command odin test src/hub/service/taskv2 -collection:odin_test=src -define:ODIN_TEST_NAMES=taskv2.test_owner_attempt_projection_matches_native_fold_prefixes -out:$HOME/.cache/heimdall-tests/c1-r2-native-hold
nix develop --command odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_NAMES=main.test_owner_local_control_notice_rejects_new_child_and_retries_unverified_child,main.test_owner_local_hold_notice_targets_current_live_holder_without_stopping_transferred_child -out:$HOME/.cache/heimdall-tests/c1-r2-bridge-hold2
nix develop --command npm run typecheck
nix develop --command node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_controls_test.ts tests/ui_owner_grants_test.ts tests/ui_owner_registry_listing_test.ts tests/ui_owner_submission_history_test.ts tests/ui_owner_local_contract_test.ts
nix build .#ham-bridge .#ham-hub .#ham-ctl .#ham-pty-host -o $HOME/.cache/heimdall-tests/c1-r2-bins
nix develop --command odin build tools/owner_local_test_identity -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1-r2-identity
nix develop --command env \
  HEIMDALL_E2E_HUB_BIN=$HOME/.cache/heimdall-tests/c1-r2-bins-1/bin/ham-hub \
  HEIMDALL_E2E_BRIDGE_BIN=$HOME/.cache/heimdall-tests/c1-r2-bins/bin/ham-bridge \
  HEIMDALL_E2E_CTL_BIN=$HOME/.cache/heimdall-tests/c1-r2-bins-2/bin/ham-ctl \
  HEIMDALL_E2E_PTY_BIN=$HOME/.cache/heimdall-tests/c1-r2-bins-3/bin/ham-pty-host \
  HEIMDALL_E2E_IDENTITY_BIN=$HOME/.cache/heimdall-tests/c1-r2-identity \
  HEIMDALL_E2E_OWNER_LOCAL=1 HEIMDALL_E2E_OWNER_LEASE=1 \
  HEIMDALL_E2E_OWNER_LIFECYCLE=1 HEIMDALL_E2E_OWNER_CONTROLS=1 \
  HEIMDALL_E2E_OWNER_WORKFLOWS=1 HEIMDALL_E2E_OWNER_LANGUAGE=1 \
  HEIMDALL_E2E_OWNER_GRANTS=1 HEIMDALL_E2E_OWNER_REGISTRY=1 \
  node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/bridge_real_enroll_e2e.mjs
python3 scripts/check-owner-aggregate-parity.py
git diff --check
```

Store: 112/112 plus the final added requirements-rework regression 1/1;
contracts: 18/18; native differential: 1/1; Bridge notice tests: 2/2;
retained UI tests: 16/16. No allocator warnings. Typecheck, identity build,
all four binary builds, matrix check (240 fields / 23 structs) and diff check
pass. The exact full-demo result is recorded in the task handoff.
No new full taskv2 suite is claimed: the focused native-fold test covers the
modified native comparison; unchanged native service code was not edited.

## Native attempt record checkpoint (revision 2, attempt 4)

The strict task-scoped device read `attempt.read` takes a positive decimal-string
`attempt` and returns one `native_attempt` record
(`src/contracts/fixtures/owner-local-schema.json:60`).
It shares current read authorization and task-revision fences with the other
owner reads; read-only grants work and revoked grants fail
(`src/lib/owner_local/store.odin:174`;
`src/contracts/owner_local.odin:290`).
The original `Task_Attempt` identity, times, holder, outcome and counting flag
remain the comparison source (`src/hub/domain/taskv2.odin:26`).

Records are projections of immutable V13 evidence, with bounded keyset scan
pages and one selected record retained in memory
(`src/lib/owner_local/attempts.odin:103`).
Handoff continuation clears end/outcome and updates holder/lease while retaining
the original start and counting flag; this follows native continuation
(`src/hub/service/taskv2/lease.odin:183`).
Local times are exposed as exact decimal milliseconds in `started_ms` and
`ended_ms`; import of original timestamp strings still needs its own
lossless adapter. Native expiry outcome prefixes are retained, separate from
the fold's release category (`src/lib/owner_local/attempts.odin:160`;
`src/hub/service/taskv2/lease.odin:407`).
New local expiry events retain `ttl` or `hard_cap` evidence
(`src/lib/owner_local/leases.odin:197`).
An older expiry without its reason yields an explicitly incomplete record;
the reason is not invented from later observations.

`submission.read` adds `native_attempt` and `attempt_completeness`
(`src/lib/owner_local/reads.odin:52`).
It maps the original submission's lease to its native grant; the V4 submission
key and V7 lease ordinal remain unchanged. Incomplete structural history returns
an empty native mapping and `incomplete`, not a guessed ordinal.
A record's `completeness` concerns its available projection evidence only:
it does not certify imported original history, facet parity, budget admission,
or migration readiness.

No database schema or historical event was rewritten. V13 and every earlier
migration remain unchanged. Still required before C1 closure:
original native history/attempt import, task-specific workflow-wide retirement
evidence, typed native facets and their linkage, budget admission/exhaustion,
metadata/publication/proposals/config, strict ordinary adapters, and the full
rich legacy fixture. C3 continues to own linked bodies/blobs; M4 owns actual
route cutover. No omitted field has been approved by this checkpoint.

Verification commands (from this task Workdir, via managed shell):

```bash
python3 scripts/generate-owner-local-contracts.py
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1-attempt4-records-final-store
nix develop --command odin test src/contracts -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1-attempt4-records-final-contracts
nix develop --command odin test src/hub/service/taskv2 -collection:odin_test=src -define:ODIN_TEST_NAMES=taskv2.test_owner_attempt_projection_matches_native_fold_prefixes -out:$HOME/.cache/heimdall-tests/c1-attempt4-records-final-native
nix develop --command npm run typecheck
nix develop --command node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_controls_test.ts tests/ui_owner_grants_test.ts tests/ui_owner_registry_listing_test.ts tests/ui_owner_submission_history_test.ts tests/ui_owner_local_contract_test.ts
nix build .#ham-bridge .#ham-hub .#ham-ctl .#ham-pty-host -o $HOME/.cache/heimdall-tests/c1-attempt4-records-final-bins
```

Store: 116/116; contracts: 19/19; native differential: 1/1.
Typecheck passes; retained UI tests: 17/17; all four binary builds pass.
The complete disposable demo passed (exit 0, all steps) in managed session
`sh_bb45fb95ba0e364ecd76f59d21aecfed`, including the new signed browser
and actual CLI native record reads. Its exact command is in the task handoff. Tests cover start/end/outcome preservation, continuation,
submission 1 mapping to native attempt 2, cancellation, non-counting reopen,
TTL/hard-cap expiry, incomplete old expiry evidence, atomic switch rollback,
restart and current read revocation
(`src/lib/owner_local/attempts_test.odin:8`).
The disposable demo also asserts signed browser and actual CLI relay reads of
native source/destination records and historical submission mapping
(`tests/e2e/owner_local_controls_flow.ts:37`;
`tests/e2e/owner_local_flow.ts:292`).
No full C1 submission or independent-review approval is claimed.

## Workflow retirement evidence checkpoint (revision 2, attempts 5/6)

The original workflow stop expires work leases with `chain_closed`, then
cancels each nonterminal task (`src/hub/service/taskv2/workflow_execution.odin:192`).
The native attempt outcome is `expired:chain_closed`, retaining its prefix
(`src/hub/service/taskv2/lease.odin:407`). V14 adds immutable
`local_task_retirements`, keyed by accepted event sequence and task, with the
workflow run/execution, exact work lease, reason and cause
(`src/lib/owner_local/migration_014.sql:55`). Its deferred parent-event foreign
key keeps task evidence and the accepted command in the same transaction.
V1–V13 migrations and all historical event bytes remain unchanged.

Static retry, language retry/cancel/gate rejection, and implicit expansion
failure record this evidence before revoking authority
(`src/lib/owner_local/workflow_retirements.odin:10`). Completed or already
cancelled tasks retain their existing history. The enclosing immutable event
retains the accepted time, actor and exact signed request, plus a serialized
`task_retirements` inventory (`src/lib/owner_local/events.odin:14`).
Automatic failure is marked `workflow.failed` independently of the enclosing
triggering command. Reconciliation binds evidence to the current transaction,
never retroactively to the original run command
(`src/lib/owner_local/workflow_language.odin:391`).

The existing bounded native-attempt projection consumes task-scoped evidence
after the enclosing command. It retains the original start/holder/counting
status and closes the exact live work lease at the accepted event time with
`expired:chain_closed` (`src/lib/owner_local/attempts.odin:178`). Cancellation
does not turn a submitted attempt into a second expiry. Native attempt numbers,
V7 work-lease ordinals and V4 submission keys remain distinct and unchanged.
Older unrepresented retirements remain incomplete; V14 does not invent history.

Four focused regressions cover static retry, language cancel/gate rejection,
implicit 257-item expansion failure, immutable evidence, exact replay,
event-write and deferred-COMMIT rollback, cold restart, and genuine V13
migration collision/rollback/recovery preserving exact events, receipts,
requirements and live capability (`src/lib/owner_local/workflow_retirements_test.odin:22`).
The retained disposable demo adds real signed browser and CLI native-record
reads around live sibling retirement and cold restart
(`tests/e2e/owner_local_language_flow.ts:145`).

This checkpoint does **not** close C1. Original native attempt/history import,
typed facets and linkage, budgets, metadata/publication/proposals/config,
strict ordinary adapters and the full rich legacy fixture remain required.
The existing language-stop exception for unsettled merge CAS remains unchanged
(`src/lib/owner_local/workflow_language.odin:373`); its eventual retirement
disposition still needs explicit reconciliation before claiming whole native
workflow parity. C3 owns linked bodies/blobs; M4 owns route cutover. No OPEN
or PARTIAL field row is approved for omission.

Verification from this task Workdir through managed shell:

```bash
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1-attempt6-retirement-store
nix develop --command odin test src/contracts -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1-attempt6-retirement-contracts
nix develop --command odin test src/hub/service/taskv2 -collection:odin_test=src -define:ODIN_TEST_NAMES=taskv2.test_owner_attempt_projection_matches_native_fold_prefixes -out:$HOME/.cache/heimdall-tests/c1-attempt6-retirement-native
nix develop --command npm run typecheck
nix develop --command node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_controls_test.ts tests/ui_owner_grants_test.ts tests/ui_owner_registry_listing_test.ts tests/ui_owner_submission_history_test.ts tests/ui_owner_local_contract_test.ts
nix build .#ham-bridge .#ham-hub .#ham-ctl .#ham-pty-host -o $HOME/.cache/heimdall-tests/c1-attempt6-retirement-bins
nix develop --command odin build tools/owner_local_test_identity -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1-attempt6-retirement-identity
nix develop --command env \
  HEIMDALL_E2E_HUB_BIN=$HOME/.cache/heimdall-tests/c1-attempt6-retirement-bins-1/bin/ham-hub \
  HEIMDALL_E2E_BRIDGE_BIN=$HOME/.cache/heimdall-tests/c1-attempt6-retirement-bins/bin/ham-bridge \
  HEIMDALL_E2E_CTL_BIN=$HOME/.cache/heimdall-tests/c1-attempt6-retirement-bins-2/bin/ham-ctl \
  HEIMDALL_E2E_PTY_BIN=$HOME/.cache/heimdall-tests/c1-attempt6-retirement-bins-3/bin/ham-pty-host \
  HEIMDALL_E2E_IDENTITY_BIN=$HOME/.cache/heimdall-tests/c1-attempt6-retirement-identity \
  HEIMDALL_E2E_OWNER_LOCAL=1 HEIMDALL_E2E_OWNER_LEASE=1 \
  HEIMDALL_E2E_OWNER_LIFECYCLE=1 HEIMDALL_E2E_OWNER_CONTROLS=1 \
  HEIMDALL_E2E_OWNER_WORKFLOWS=1 HEIMDALL_E2E_OWNER_LANGUAGE=1 \
  HEIMDALL_E2E_OWNER_GRANTS=1 HEIMDALL_E2E_OWNER_REGISTRY=1 \
  node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/bridge_real_enroll_e2e.mjs
python3 scripts/check-owner-aggregate-parity.py
git diff --check
```

Store: 120/120; contracts: 19/19; retained native differential: 1/1; UI: 17/17.
Typecheck and all four binary builds pass. No allocator warnings. The matrix
checker accounts for 240 fields in 23 structs; this is an inventory check,
not an implementation-completeness claim. The complete disposable demo passed
with exit 0 in managed session `sh_41d90a59840bde07efde87b5becce2a8`, including
the new native retirement CLI/browser reads and cold restart. Its exact command
appears above.

## C1a bounded foundation for independent acceptance

Task `task_18e57ad52bb4ea63` integrates only the nine C1 commits from
`6b076ac7..bfac0d0d`, in order, onto the same reviewed V12 base. The integrated
tree at `4867e4fa` is byte-identical to `bfac0d0d` (`git diff --exit-code
bfac0d0d HEAD`, exit 0). V1–V12 schema files remain byte-identical to the
base; V13/V14 remain byte-identical to the preserved checkpoint. Named
independent review is still required; this worker does not approve its work.

The subset submitted for acceptance is:

- Append-only accepted-command evidence with exact bytes, observed actor/time,
  explicit legacy incompleteness, authorized keyset/chunk reads and transactional
  rollback (`src/lib/owner_local/events.odin:12`; `migration_013.sql:55`).
- Strict nested brief shape validation and native seconds-based hard deadlines
  for claim/switch, pinned across heartbeat (`src/lib/workflow_v1/boundary.odin:52`;
  `src/lib/owner_local/leases.odin:15`; native `src/hub/service/taskv2/lease.odin:114`).
- Native live-hold/checkpoint behavior: retain current capability and TTL, prevent
  new dispatch, defer review gate settlement until release, and preserve blocked
  overlays (`src/lib/owner_local/controls.odin:67`; `review_roles.odin:64`;
  native `src/hub/service/taskv2/verbs_m2.odin:620`).
- Bounded retained-event native attempt observations, distinct from immutable
  lease ordinals/submission keys, with explicit incomplete history
  (`src/lib/owner_local/attempts.odin:103`; native
  `src/hub/service/taskv2/fold.odin:138`; `lease.odin:177`).
- Immutable task-scoped retirement evidence for nonmerging workflow tasks,
  preserving native `expired:chain_closed` outcomes and parent event provenance
  (`src/lib/owner_local/workflow_retirements.odin:10`; `migration_014.sql:55`;
  native `src/hub/service/taskv2/workflow_execution.odin:192`; `lease.odin:407`).

C1a found and fixed one concrete defect in that subset: the emitted native
retirement outcome `expired:chain_closed` was missing from both wire validators
(`src/contracts/owner_local.odin:59`; `src/ui/api/ownerLocal.ts:29`). The focused
contract regression failed before the fix in session
`sh_06e496f378a4b7525c891f2eeeea1777`. Both validators now accept it, and synthetic
retirement records must pass the public parser
(`src/lib/owner_local/workflow_retirements_test.odin:17`). No historical row,
event, ID, migration or capability is rewritten by this correction.

### Retained evidence verified without rerunning unchanged suites

The old attempt-6 handoff contains exact commands and output paths. C1a read
the retained session logs/status, rather than treating the handoff as new runs:

| Retained session | Verified result |
| --- | --- |
| `sh_1a14890c9c8566499ddcf63debf8c087` | Owner store 120/120, exit 0 |
| `sh_38163b05c4d915e78fd45724ac396a83` | Contracts 19/19; native fold differential 1/1, exit 0 |
| `sh_2dd8e244b2e1949891cdfc63e2350828` | Typecheck; retained UI 17/17, exit 0 |
| `sh_e8b61c912965d1cbc05182a4f565cbc5` | Four-binary build, exit 0; no build error diagnostic |
| `sh_41d90a59840bde07efde87b5becce2a8` | Complete disposable demo, all steps passed, exit 0; actual CLI/browser attempt and retirement reads, hold/heartbeat, cold restart |

New checks for the validator correction, from the C1a Workdir:

```bash
nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_NAMES=contracts.native_attempt_contract_is_task_scoped_read_only_and_validates_time_outcome -out:$HOME/.cache/heimdall-tests/c1a-outcome-contract-final
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_NAMES=owner_local.workflow_retirement_static_retry_is_atomic_replay_safe_and_restart_exact,owner_local.workflow_retirement_language_cancel_and_gate_rejection_preserve_native_outcome,owner_local.workflow_retirement_implicit_expansion_failure_uses_current_event,owner_local.workflow_retirement_v13_upgrade_collision_commit_rollback_and_exact_preservation -out:$HOME/.cache/heimdall-tests/c1a-retirement-four-final
nix develop --command node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_local_contract_test.ts
python3 scripts/check-owner-aggregate-parity.py
git diff --check
```

Results: contract 1/1, retirement 4/4, UI 8/8; inventory 240 fields/23 structs;
all exit 0. No allocator warnings. The inventory is not a parity proof. One
earlier focused storage invocation named three nonexistent tests and ran only
the static retry test; no coverage is claimed for those missing selections.
The corrected four-test command above selected and passed all four tests.
The unchanged full suites/builds/demo were not rerun for an outcome whitelist
addition; their retained results are separate from the new focused evidence.

### Required successor work and stable API boundaries

Every OPEN/PARTIAL row and the command-parity table above remains binding.
Foundation acceptance does not authorize migration or ordinary route cutover.

| Successor responsibility | Starting API and unresolved requirement |
| --- | --- |
| Native attempts/history and budgets | `attempt_scan` (`src/lib/owner_local/attempts.odin:103`) powers task-scoped `attempt.read`, `runtime.read.attempts` and submission-to-native mapping (`reads.odin:16`, `reads.odin:50`). It is an observation, not native import/export or budget admission. Preserve original IDs, timestamp strings, actors, exact payload/outcome/counting and typed facet linkage before max-attempt admission/exhaustion. Never count V7 lease rows as attempts or renumber V4 submissions. Preserve live-hold/checkpoint semantics. Reconcile deferred retirement after unsettled merge CAS (`workflow_language.odin:373`) before whole workflow parity. |
| Rich metadata/configuration | The 240-field inventory and command table require publication, priority, proposal/decision/publish, chain/task timestamps, membership/directories, provider/model/placement/fleet policy, curated summary, mixed-work graph/receipts/scope provenance and their strict ordinary adapters. Existing full brief validation is reusable; input-reference resolution remains required. |
| Facets and final parity proof | Retain original facet kinds, IDs, versions, writer/time/body and pinned typed artifact/message provenance. C3 owns linked canonical bodies/envelopes/blobs; unresolved references stay explicitly unresolved/import-pending. Add the full rich native fixture and adapter proof for validation, authorization, replay, search, history, restart and migration rollback. Named independent review must assess final parity. |
| Migration/cutover | Append V15+ for new schema; preserve V1–V14 and genuine historical reconstruction tests. `history.read`/`history.fetch` (`events.odin:26`, `events.odin:63`) expose current accepted evidence; legacy tags have no fabricated original provenance. M4 owns actual route cutover; no Hub writer fallback is introduced here. |

## C1b archival native history and typed facets (revision 1)

Task `task_18e57ad551f091b8` builds on accepted C1a `d78c6c54`.
Coordinator resolution `msg_18e57cee061a250b` explicitly places **exact archival
preservation/validation** in C1b, with **no automatic baseline activation**.
C1c REQ-Pc4 owns signed source-snapshot/cutoff selection and local-history
reconciliation, including fail-closed ambiguous overlap and no live boundary
effects. M4 owns actual route cutover. An archived native record is not a new
local work grant, a spent attempt, or permission to execute.

### Native source mapping

V15 `native_history_records` is an immutable archival store, keyed by current
chain/task scope, pinned source revision, record kind and the original native
key (`src/lib/owner_local/migration_015.sql:56`). The three native field families
in the inventory above now describe that archival mapping. The transport keeps
decimal identities/counting flags as strings; it preserves original timestamp
spellings and JSON payload/body strings without parsing and re-serializing those
stored values (`src/lib/owner_local/native_history.odin:110`).

| Source | Preserved identity and facts |
| --- | --- |
| `src/hub/domain/taskv2.odin:27` | Attempt: original task/attempt number, chain, original owner user ID, started/ended timestamp strings, holder, exact outcome and counting bit. Snapshot revisions retain changes to a native attempt without rewriting an earlier snapshot. |
| `src/hub/domain/taskv2.odin:9` | Event: original event ID, task/chain/owner, exact timestamp, actor kind/ID, kind and verbatim payload. Native event IDs remain distinct from owner accepted-command sequence numbers. The actual coordinator actor is retained (`src/hub/service/taskv2/events.odin:71`; `verbs_m2.odin:392`). |
| `src/hub/domain/taskv2.odin:43` | Facet: original task/attempt/kind/version, owner, writer, written-at string and verbatim body. All seven source kinds are retained: the six in `src/hub/service/taskv2/facets.odin:15`, including legacy read-only `verify`, plus `placement` (`src/hub/service/taskv2/placement_failures.odin:13`). |

Each record also retains caller-supplied pinned `provenance_json`; facet records
carry typed artifact/message IDs, pinned revision/provenance and explicit
`unresolved` or `import_pending` reference state. These are archival references,
not a second object/body resolver (`src/lib/owner_local/native_history.odin:94`).
C3 remains responsible for canonical linked bodies/envelopes/blobs. No path is
opened to discover a body, and no Hub body/authority join is introduced.

Positive facet-to-attempt linkage is checked before insertion and by a deferred
foreign key. Native pre-grant `placement` at attempt zero has no work-attempt
parent; other facet kinds cannot use zero. Original owner and
one-writer-per-attempt/kind invariants are checked;
conflicting reimports of the same source key fail, and known event/facet versions
cannot silently change across snapshots (`src/lib/owner_local/native_history.odin:110`;
`migration_015.sql:56`). `source_completeness` exposes the import declaration;
it does not assert selected current-baseline completeness or budget eligibility.
Missing history is not reconstructed from current runtime rows. Existing V13
legacy tags and V7/V4 lease/submission identifiers remain untouched.

### Authorized bounded API

All three methods are task-scoped signed-device commands. Existing current
read authorization precedes lookup or receipt replay; mutation is additionally
required for import (`src/contracts/owner_local.odin:114`;
`src/lib/owner_local/store.odin:127`).

| Method | Payload and result |
| --- | --- |
| `native.history.import` | Encrypted `body_cipher`; a strict bundle with source revision, original owner, declared completeness and arrays of exact typed record documents. At most 100 records per family and 64 KiB plaintext per command. Batches can append to the same source revision without rewriting keys. The import's own accepted event retains current importer/time/request provenance. |
| `native.history.read` | Source revision, `attempt`/`event`/`facet`, cursor and limit 1–100. Keyset inventory binds account/chain/task/source/kind; numeric native IDs and facet versions sort as SQLite i64, never JavaScript floats. Keys remain original native keys, not new IDs. |
| `native.history.fetch` | Source revision, kind, exact inventory key and decimal byte offset. Returns UTF-8-safe record chunks of at most 8192 raw bytes, next offset and source completeness. |

Implementation: `src/lib/owner_local/native_history.odin:182`; existing browser
signer/client adapters: `src/ui/api/ownerLocalClient.ts:63`. Native source facts
stay readable after task deletion and may be archived for retired workflow
executions without reactivating those tasks (`src/lib/owner_local/store.odin:174`,
`store.odin:231`; `native_history_test.odin`). Read revocation still denies them.

### Deferred workflow merge settlement

Native workflow stop skips terminal tasks
(`src/hub/service/taskv2/workflow_execution.odin:196`). Locally, approved submitted
work may still await a Git CAS. V15 records the workflow stop against the exact
extant intent/task/run/execution and original accepted event instead of discarding
the callback's identity (`src/lib/owner_local/workflow_retirements.odin:37`).
Prepared head/fence/digest and native submitted outcome remain intact.

Failed delivery keeps the same intent retryable. Obsolete incarnations, duplicate
callbacks and mutations that would invalidate an unresolved deferred merge are
rejected. After successful exact settlement, one immutable
`preserved_terminal` disposition is linked to the new bridge completion event;
it does not fabricate a second expiry for an already submitted attempt
(`src/lib/owner_local/workflow_retirements.odin:45`; `outbox.odin:116`;
`migration_015.sql:88`). Event-write failure rolls the disposition and settlement
back together. The workflow can retry only once its old merge is settled.

For pre-V15 failed/cancelled executions with a still-valid unsettled merge, the
migration retains the observable exact binding while marking original request
sequence **null**, cause **unknown**, and source completeness **incomplete**
(`src/lib/owner_local/migration_015.sql:88`). It neither backfills old events nor
invents their missing actor/time. Future settlement records its own accepted
event exactly once. Genuine V14 reconstruction verifies this path alongside
current-source deferral (`src/lib/owner_local/deferred_retirements_test.odin`).

### C1b proof and successor boundary

The shared synthetic source fixture
`src/contracts/fixtures/owner-native-history.json` contains three logical attempts,
eleven native events (including an ID above JavaScript's safe integer range and
a coordinator actor), and two versions of every native facet kind. Four work
leases include a handoff continuation and a structural replacement. The original
native fold proves **three attempts / two counted** from the same fixture used
by archival round-trip tests (`src/hub/service/taskv2/owner_native_history_test.odin`).
This verifies fidelity, not activation of an imported baseline.

Storage regressions cover exact records, provenance, writer/version/owner
conflicts, invalid references, orphan facets, accepted-event and deferred-COMMIT
rollback, paging/chunks/numeric ordering, partial snapshots, read revocation,
restart, deleted tasks, retired workflows and genuine V14 collision/rollback/
recovery (`src/lib/owner_local/native_history_test.odin`). Prepared-CAS regressions
cover current and historical missing-request evidence, failure/restart, stale
claim rejection, rollback and one final native terminal disposition
(`src/lib/owner_local/deferred_retirements_test.odin`).

The complete disposable demo adds actual CLI import/replay/fetch and signed
browser typed-facet inventory/read after owner cold restart, while retaining all
prior lifecycle, workflow, grant, controls, search and registry scenarios
(`tests/e2e/owner_local_flow.ts:77`). The first draft reused the ordinary lease
fixture's task and changed its expected revision; the final import scenario uses
its own disposable chain/task. No production deployment or live restart is used.

Successors must select/reconcile a signed snapshot and explicit cutoff before
using archived facts for admission (C1c REQ-Pc4), retain all other OPEN/PARTIAL
metadata/proposal/configuration/ordinary-adapter work, and complete the full rich
aggregate parity proof. M4 cutover and C3 linked-body resolution remain separate.
C1b does not waive any remaining field, activate a source snapshot, enforce a
budget, or claim whole-C1 completion. Named independent review remains required.

### Verification commands and outcomes

Commands ran through managed shell in
`/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad551f091b8`:

```bash
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1b-unicode-store-131
nix develop --command odin test src/contracts -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1b-archival-contracts-final
nix develop --command odin test src/hub/service/taskv2 -collection:odin_test=src -define:ODIN_TEST_NAMES=taskv2.test_owner_native_import_fixture_matches_original_attempt_accounting,taskv2.test_owner_attempt_projection_matches_native_fold_prefixes -out:$HOME/.cache/heimdall-tests/c1b-archival-native-final
nix develop --command npm run typecheck
nix develop --command node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_local_contract_test.ts tests/ui_owner_controls_test.ts tests/ui_owner_submission_history_test.ts tests/ui_owner_grants_test.ts tests/ui_owner_registry_listing_test.ts
nix build .#ham-bridge .#ham-hub .#ham-ctl .#ham-pty-host -o $HOME/.cache/heimdall-tests/c1b-unicode-bins
nix develop --command odin build tools/owner_local_test_identity -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1b-identity
nix develop --command env HEIMDALL_E2E_HUB_BIN=$HOME/.cache/heimdall-tests/c1b-unicode-bins-1/bin/ham-hub HEIMDALL_E2E_BRIDGE_BIN=$HOME/.cache/heimdall-tests/c1b-unicode-bins/bin/ham-bridge HEIMDALL_E2E_CTL_BIN=$HOME/.cache/heimdall-tests/c1b-unicode-bins-2/bin/ham-ctl HEIMDALL_E2E_PTY_BIN=$HOME/.cache/heimdall-tests/c1b-unicode-bins-3/bin/ham-pty-host HEIMDALL_E2E_IDENTITY_BIN=$HOME/.cache/heimdall-tests/c1b-identity HEIMDALL_E2E_OWNER_LOCAL=1 HEIMDALL_E2E_OWNER_LEASE=1 HEIMDALL_E2E_OWNER_LIFECYCLE=1 HEIMDALL_E2E_OWNER_CONTROLS=1 HEIMDALL_E2E_OWNER_WORKFLOWS=1 HEIMDALL_E2E_OWNER_LANGUAGE=1 HEIMDALL_E2E_OWNER_GRANTS=1 HEIMDALL_E2E_OWNER_REGISTRY=1 node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/bridge_real_enroll_e2e.mjs
python3 scripts/generate-owner-local-contracts.py
python3 scripts/check-owner-aggregate-parity.py
git diff --check
git diff --exit-code d78c6c54 -- src/lib/owner_local/schema.sql src/lib/owner_local/migration_{002..014}.sql
```

All exit 0: store **131/131**, contracts **20/20**, native differential **2/2**,
UI **18/18**, typecheck, four binary builds and the complete disposable demo.
No allocator warnings. Final store/build/demo session:
`sh_51924c5ee42e0973559459d147428f78` (all steps passed);
contracts/native: `sh_ba0593a18e148b4b7068b0f70a660470`;
typecheck/UI: `sh_a768d079995b1197d52db801b6a7dce6`.

The richer fixture exposed a real Unicode validation defect: the authority
ASCII parser was also being used for opaque archival JSON. Initial session
`sh_6d75cb75265d05f4a3e073eb6d08ab92` had six failing archival tests even though
its later two native checks passed and the shell's last exit was zero; that
session is **not passing evidence**. The worker corrected its earlier report.

The content-only flat decoder now retains strict field grammar, decoded-key
uniqueness, full-input checks, JSON escapes and surrogate pairing while allowing
Unicode inside opaque document values
(`src/lib/owner_local/native_history.odin:14`). Protected metadata still uses the
existing ASCII field validators; signed authority-envelope decoding is unchanged.
Opaque JSON bodies validate without rewriting original bytes. Raw UTF-8/emoji
round-trip and duplicate-key, isolated-surrogate and trailing-comma rejections
pass in `sh_8d5926b97115370854c9321a418faaa9`; the eight rich archival tests and
two native differential tests pass in `sh_3541b9fb2b92e48f07b33132972b7e32`.
Final Unicode-inclusive full store **131/131**, four binary builds and the complete
actual CLI/browser Unicode demo all passed with exit 0 in
`sh_51924c5ee42e0973559459d147428f78`. Its exact commands appear above.

Draft diagnostics were resolved: initial helper compile errors; rich bundles
exceeding the ordinary 8 KiB prose cap; an unknown limit field type/cursor shape;
one stale schema-version expectation; missing pinned `posthog-js` dependency
(restored with `nix develop --command npm ci --ignore-scripts --no-audit --no-fund`,
lockfile unchanged); a JSON envelope key-order assertion (corrected to compare
the exact archived record); and historical reconstruction retaining a V15
trigger (all V15 objects are now removed before reconstructing older schemas).
The first real demo's revision collision was corrected using a separate chain.

### Placement review correction (attempt 3)

Independent review correctly found an omitted seventh native facet kind.
`src/hub/service/taskv2/placement_failures.odin:10` explicitly permits placement
at attempt zero; its writer persists that facet without a work grant
(`placement_failures.odin:231`). The original regression demonstrates zero
`task_attempts` (`placement_failures_test.odin:35`). The earlier six-kind claim
above has been corrected. This finding was reproduced as `invalid_content` in
`sh_9f684f7aee8697bfa26bd5c398e0ca80` before the fix.

Odin/TS contracts now admit `placement`, with attempt zero permitted only for
that archival facet. Positive facets still require their exact snapshot attempt
parent. Zero placement stores NULL parent columns, never an invented attempt;
the unmerged V15 CHECK uses NULL-safe comparisons for the positive parent
backstop (`src/lib/owner_local/migration_015.sql:69`). Accepted V1–V14 bytes stay
unchanged. Runtime work-attempt contracts still require positive numbers.

The native matcher regression exports two synthetic source captures with stable
typed wrappers (`src/hub/service/taskv2/owner_native_placement_test.odin:67`).
They preserve pre-grant placement versions 1/2 and later attempt-one versions
1/2, exact HUB writer, native timestamps and body bytes. Its native fold counts
zero before grant and one after submission. Local replay/restart tests fetch
the original records exactly; statement and deferred-COMMIT failures roll back
archive rows, receipts and revisions (`src/lib/owner_local/native_placement_test.odin:34`).
Local work/submission rows and live counting remain zero after both archival
snapshots. No baseline activation, budget enforcement or C3 body resolution is
introduced.

New verification commands, run in this task's managed worktree:

```bash
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1b-placement-store-all
# 133/133 PASS, sh_986b7653da87835353d815ef43a54fbb
nix develop --command odin test src/hub/service/taskv2 -collection:odin_test=src -define:ODIN_TEST_NAMES=taskv2.test_owner_native_placement_archival_source_fixtures,taskv2.test_placement_worker_offline_is_durable_idempotent_and_recovers,taskv2.test_owner_native_import_fixture_matches_original_attempt_accounting,taskv2.test_owner_attempt_projection_matches_native_fold_prefixes -out:$HOME/.cache/heimdall-tests/c1b-placement-native-four
# 4/4 PASS, sh_3a9da0c75b9146faa0be60f3a0d86ae5
nix develop --command odin test src/contracts -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1b-placement-contracts-all
python3 scripts/check-owner-aggregate-parity.py
# 21/21 PASS; 240 fields/23 structs, sh_b5606b0e1ea198f3ea294cc466d87a22
nix build .#ham-bridge .#ham-hub .#ham-ctl .#ham-pty-host -o $HOME/.cache/heimdall-tests/c1b-placement-bins -L
# All four binaries PASS, sh_48258e4f21015db5566b6456b806cdc8
nix develop --command npm run typecheck
nix develop --command node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_local_contract_test.ts tests/ui_owner_controls_test.ts tests/ui_owner_grants_test.ts tests/ui_owner_registry_listing_test.ts tests/ui_owner_submission_history_test.ts
# Typecheck PASS, sh_bb048f54f8fb9f25e7c1c5fad2daaf00.
# UI 19/19 PASS and staged/unstaged diff checks PASS, sh_7eced5391bedd79c26d20ecad156bb70.
# Earlier UI invocation included a nonexistent flow-test filename; only its
# 10 actual contract tests were counted. The final command lists existing files.
```

The first new real demo (`sh_ec02b416f778abbc9654c7721b1e0775`) proved pre-grant
CLI import/replay, then exposed the browser helper's ordinary 8 KiB limit on a
larger native source bundle. The helper now uses the store's existing 64 KiB
plaintext/128 KiB JSON-expanded limit only for native import bodies; title,
description and ordinary bodies retain their original limits
(`src/ui/api/ownerLocalClient.ts:26`). The new real demo fetches all original
placement versions with the actual CLI after owner restart and verifies zero
runtime work/counting (`tests/e2e/owner_local_flow.ts:101`).
The complete rerun `sh_fd6ec788bccfb8c3375d73bc72873f09` exited 0 with
`all steps PASSED` (line 548), including all retained lease, lifecycle, controls,
workflow, language, grant and registry flows. No live services were restarted.

```bash
nix develop --command env \
  HEIMDALL_E2E_HUB_BIN=$HOME/.cache/heimdall-tests/c1b-placement-bins-1/bin/ham-hub \
  HEIMDALL_E2E_BRIDGE_BIN=$HOME/.cache/heimdall-tests/c1b-placement-bins/bin/ham-bridge \
  HEIMDALL_E2E_CTL_BIN=$HOME/.cache/heimdall-tests/c1b-placement-bins-2/bin/ham-ctl \
  HEIMDALL_E2E_PTY_BIN=$HOME/.cache/heimdall-tests/c1b-placement-bins-3/bin/ham-pty-host \
  HEIMDALL_E2E_IDENTITY_BIN=$HOME/.cache/heimdall-tests/c1b-identity \
  HEIMDALL_E2E_OWNER_LOCAL=1 HEIMDALL_E2E_OWNER_LEASE=1 \
  HEIMDALL_E2E_OWNER_LIFECYCLE=1 HEIMDALL_E2E_OWNER_CONTROLS=1 \
  HEIMDALL_E2E_OWNER_WORKFLOWS=1 HEIMDALL_E2E_OWNER_LANGUAGE=1 \
  HEIMDALL_E2E_OWNER_GRANTS=1 HEIMDALL_E2E_OWNER_REGISTRY=1 \
  node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/bridge_real_enroll_e2e.mjs
```

## C1c revision 2: native budget admission and explicit baseline activation

> Historical: the owner-local attempt budget described in this and the
> following budget sections was removed by user decision on 2026-11-07
> (owner-local migration V29). The cited budget files no longer exist.

This section supersedes earlier checkpoint statements that budget enforcement or
C1c activation is still unimplemented. It does not close unrelated aggregate
metadata/body/cutover rows or claim whole-C1 completion.

The budget fold follows the original native transitions and grant predicate
(`src/hub/service/taskv2/fold.odin:97`, `fold.odin:138`,
`fold.odin:362`, `fold.odin:377`). The source-backed implementation
(`src/lib/owner_local/budget.odin:10`) keeps logical attempt number,
counting attempts, current counting bit, review/infrastructure distinctions,
holds, reopen and terminal outcomes. Handoff continues the logical attempt.
Structural releases make the next attempt non-counting; they do not refund an
already spent attempt. The original default remains five attempts.
The shared migrated-seed fixture is checked against the original fold at every
prefix (`src/hub/service/taskv2/owner_budget_test.odin:81`); it declares seed4
and retains only the real post-seed attempt5 row, never invented rows1-4.

`lease.claim` and atomic switch admission consult the logical budget
(`src/lib/owner_local/leases.odin:103`, `controls.odin:187`).
Receipt replay remains ahead of mutation fences and creates no new authority.
Budget state/reason/configuration/requirements/execution and the current
owner-global checkpoint are visible through signed `runtime.read`
(`src/lib/owner_local/reads.odin:74`). Immutable budget evidence is appended
in the same transaction as its accepted cause event
(`src/lib/owner_local/events.odin:26`, `budget_runtime.odin:157`,
`migration_016.sql:72`). Failure rolls back the cause, lease retirement,
receipt and budget evidence together. Holds remain overlays, including an
expiry at the final attempt (`controls.odin:91`). Existing hard-deadline
clamping and heartbeat behavior are reused (`leases.odin:15`).

### Activation contract and boundaries

Archival import alone has no budget authority: a task with imported source
records reports `activation_required` and refuses another grant with
`recovery_required`. A new `budget.activate` is a normal task-scoped,
device-signed mutation requiring current mutation permission and task revision
(`src/contracts/owner_local.odin:42`, `owner_local.odin:116`,
`src/lib/owner_local/store.odin:236`). Its exact manifest binds:

- `source_revision`, `snapshot_digest`, counts of attempts/events/facets,
  and the final original `native_cutoff` event ID;
- the observed owner-global `local_cutoff` returned by
  `runtime.read.budget.local_cutoff`;
- current requirements/configuration revisions and exact workflow
  `run_id:execution` (or `standalone`);
- original source task gate/no-review facts used by the native fold.

The signer explicitly asserts a complete source prefix. The implementation
verifies all imported selected-snapshot records are full, counts/digest/cutoffs
match, the prefix starts at original `created` or valid `migrated`, and
post-seed attempt counting bits/outcomes match the native event fold.
Native event IDs need not be contiguous because IDs are shared across tasks.
Native dispatch failures retain the original `dispatch_failed` row outcome and refunded counting bit (native `src/hub/service/taskv2/dispatch.odin:77`). An imported native block still requires a signed answer before a future grant; source-blocked/oscillating state cannot disappear during activation.
Original `migrated` seeds are preserved even when no earlier attempt rows
exist; large valid seeds are not rejected by an invented cap. Counter overflow
fails closed (`src/lib/owner_local/budget_source.odin:35`).

The byte-preserving digest algorithm is defined in
`src/lib/owner_local/budget_source.odin:11`:

1. Start with SHA-256 of UTF-8 JSON
   `["native.budget.snapshot.v1",chain_id,task_id,source_revision]`.
2. Sort all exact archived records by binary `(record_kind,record_key)`.
3. For each record, replace the digest with SHA-256 of UTF-8 JSON
   `[previous_digest,record_kind,record_key,exact_record_json]`.
4. Sign the final digest and exact per-kind counts in the activation manifest.

Activation accepts empty local work history and uniquely proven contiguous
exact-ID overlap. Native and local lease-ID namespaces can overlap; the earlier
empty-only interpretation was an acceptance gap, not an authorized waiver
(coordinator `cmt_18e582d35466dd9b`). The implementation now compares the entire
local budget-transition prefix with a contiguous source suffix, validates
counter offsets and original attempt/lease/provenance facts, and records an
immutable identity mapping (`src/lib/owner_local/budget_overlap.odin:179`).
Disjoint, conflicting, incomplete or otherwise unprovable history remains
`recovery_required`; no independent histories are guessed together, no IDs are
renumbered, and no old native attempts are fabricated. Source live work/review/
hold and stale checkpoints remain rejected.

V16 keeps the activated baseline immutable and seals its selected source
snapshot against additions (`src/lib/owner_local/migration_016.sql:56`).
Later archival snapshots cannot replace that baseline or reset the count.
Requirements/configuration edits recompute against retained evidence; workflow
generation and exact-child fences remain authoritative. Operational source
freeze/export/cutover remains M4; this task performs no live cutover, deployment,
push or production restart.

### Verification

Final-source store suite:
`nix develop --command odin test src/lib/owner_local -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1c-budget-final142-store`
passed **142/142**, exit0, session
`sh_3e6407974468de330f05bd6738e335da`.
It covers manifest/fence rejection, statement and deferred-COMMIT activation
rollback, exhaustion retirement rollback, held expiry/release, incomplete
history, exact replay/restart, large migrated seeds, ambiguous preexisting local
work, atomic exhausted-destination switch rollback, dispatch refunds with original row bits/outcomes, signed answers to imported native blocks, and direct non-counting reopen of imported done/cancelled baselines. Genuine V15 upgrade
collision/COMMIT recovery preserves old authority and history; prior V1-V15 SQL
files are byte-identical to the reviewed C1b head.

Other checks (all exit0):

```bash
nix develop --command odin test src/contracts -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1c-budget-final-contracts
# 21/21; sh_b801a5b847e77b16c7148c17da2fb437

nix develop --command odin test src/hub/service/taskv2 -collection:odin_test=src -define:ODIN_TEST_NAMES=taskv2.test_owner_budget_native_fold_and_admission_prefixes,taskv2.test_owner_budget_shared_migrated_fixture_matches_native_admission,taskv2.test_owner_attempt_projection_matches_native_fold_prefixes -out:$HOME/.cache/heimdall-tests/c1c-budget-native-three
# 3/3; sh_c578b63132245e5c32a881ab2d9a381b

nix develop --command npm run typecheck
# PASS; sh_459f8cb4aa8d7e018c99be2ad5340248

nix develop --command node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_controls_test.ts tests/ui_owner_grants_test.ts tests/ui_owner_registry_listing_test.ts tests/ui_owner_submission_history_test.ts tests/ui_owner_local_contract_test.ts
# 20/20; sh_33d3632fdef11c6df66c64552b08d7d4

nix build .#ham-bridge .#ham-hub .#ham-ctl .#ham-pty-host -o $HOME/.cache/heimdall-tests/c1c-budget-final142-bins
# all four PASS; sh_52f56b1f738561d74417850ee8047c92

nix develop --command odin build tools/owner_local_test_identity -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1c-budget-identity
# PASS; sh_ea629aff541e0ea1210f21f39f89a03a
```

The unchanged full native-service suite was not repeated: the original fold is
unchanged, and the three source-backed differentials exercise its relevant
prefixes, including a shared fixture, migrated seed, work/review/handoff/hold,
structural dependency/replacement/reopen, expiry, infrastructure and dispatch
refund semantics. Store tests retain static/language workflow retry, retirement
and stale-execution coverage.

The first focused real harness run omitted the existing initial transport-token
provisioning and returned `owner_unavailable`; the harness now calls its existing
isolated stop/restart setup before launching children. The corrected budget-only
real demo passed at `sh_0e372f6f9bb2557f2bfa86cac32dcdf4`. The subsequent complete
retained demo (including the budget flow) also passed at
`sh_2aedcf0dfa59c4600ac7b9b02ce2152b` before the final narrow dispatch/terminal
source-reconciliation additions.

Initial typecheck lacked the already pinned `posthog-js`; the ordinary
`nix develop --command npm ci --ignore-scripts --no-audit --no-fund`
restored dependencies (exit0, `sh_39c7aa99807e5bacc24a95f05d9d113a`), with no
lockfile changes. Draft migration fixtures retained additive V16 objects/seal
trigger while reconstructing old schemas; corrected reconstruction and final
142 tests pass. Draft compiler-only name/redeclaration and shell-quoting failures
were corrected before verification; none remain.

The final-source full retained demonstration is recorded below.


```bash
nix develop --command env \
  HEIMDALL_E2E_HUB_BIN=$HOME/.cache/heimdall-tests/c1c-budget-final142-bins-1/bin/ham-hub \
  HEIMDALL_E2E_BRIDGE_BIN=$HOME/.cache/heimdall-tests/c1c-budget-final142-bins/bin/ham-bridge \
  HEIMDALL_E2E_CTL_BIN=$HOME/.cache/heimdall-tests/c1c-budget-final142-bins-2/bin/ham-ctl \
  HEIMDALL_E2E_PTY_BIN=$HOME/.cache/heimdall-tests/c1c-budget-final142-bins-3/bin/ham-pty-host \
  HEIMDALL_E2E_IDENTITY_BIN=$HOME/.cache/heimdall-tests/c1c-budget-identity \
  HEIMDALL_E2E_OWNER_LOCAL=1 HEIMDALL_E2E_OWNER_LEASE=1 \
  HEIMDALL_E2E_OWNER_LIFECYCLE=1 HEIMDALL_E2E_OWNER_CONTROLS=1 \
  HEIMDALL_E2E_OWNER_WORKFLOWS=1 HEIMDALL_E2E_OWNER_LANGUAGE=1 \
  HEIMDALL_E2E_OWNER_BUDGET=1 HEIMDALL_E2E_OWNER_GRANTS=1 \
  HEIMDALL_E2E_OWNER_REGISTRY=1 \
  node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/bridge_real_enroll_e2e.mjs
```

Final-source result: **all steps PASSED**, exit0, session
`sh_10b1d57b2c0cba957b9c9d4033b3831d`. This includes every retained real lease,
lifecycle, controls, workflow, language, grants/recovery and registry flow plus
the new signed budget activation/exhaustion/restart/rendered-recovery flow
(`tests/e2e/owner_local_budget_flow.ts:7`). The budget-only shortcut remains
available with `HEIMDALL_E2E_OWNER_BUDGET_ONLY=1`.

Final parity/whitespace/immutable-migration checks:
`python3 scripts/check-owner-aggregate-parity.py` reports
**240 fields / 23 structs**, `git diff --check` and
`git diff --cached --check` pass, and
`git diff --exit-code c1016192 -- src/lib/owner_local/schema.sql src/lib/owner_local/migration_002.sql src/lib/owner_local/migration_003.sql src/lib/owner_local/migration_004.sql src/lib/owner_local/migration_005.sql src/lib/owner_local/migration_006.sql src/lib/owner_local/migration_007.sql src/lib/owner_local/migration_008.sql src/lib/owner_local/migration_009.sql src/lib/owner_local/migration_010.sql src/lib/owner_local/migration_011.sql src/lib/owner_local/migration_012.sql src/lib/owner_local/migration_013.sql src/lib/owner_local/migration_014.sql src/lib/owner_local/migration_015.sql`
passes. No unrelated changes, package-lock changes, deployment, production
restart or push. Independent named review is required; no self-review.

## C1c review rework (lease 3, requirements revision 2)

The independent review of `84576282` identified four real acceptance gaps.
Its earlier green tests remain historical evidence for their recorded coverage;
they did not establish these four paths. Coordinator
`cmt_18e582d35466dd9b` requires reachable exact overlap reconciliation, and
`cmt_18e582dc7cc651bf` keeps the real dependency route and oscillation in scope.

### Budget-owned overlay recovery and ordinary oscillation

> Historical: removed by user decision on 2026-11-07. V29 restores or clears
> every `budget_control_owners` overlay before dropping the table.

`budget_control_owners` preserves the independent control below a generated
budget/oscillation block. Current fold recovery restores that saved state,
including the underlying resume mode while held, rather than leaving a stale
budget block or erasing a separate human block
(`src/lib/owner_local/budget_runtime.odin:166`;
`migration_016.sql:83`). Explicit signed answer/cancel/reopen releases ownership
in the same transaction; holds themselves remain overlays
(`src/lib/owner_local/controls.odin:142`).

Ordinary local tasks now expose durable `oscillation` after the third effective
request-changes result, even without an imported baseline. Admission rejects
the fourth work grant until explicit native recovery
(`src/lib/owner_local/budget_runtime.odin:144`). A held verdict remains pending
until release. Regression tests exercise actual signed claim/present/ACK/submit/
independent-review cycles, restart, normal/held budget increases, preservation
of an independent human block, and signed recovery
(`src/lib/owner_local/budget_review_test.odin:8`).

### Exact contiguous overlap proof

The selected native snapshot must still pass complete-prefix/event-outcome
validation. For a nonempty local work prefix, activation additionally proves:

- Exact original lease identities, account/chain/task/Bridge, holder IDs,
  accepted event milliseconds and work-end actor IDs.
- A single contiguous source suffix covering all local budget-bearing
  transitions through the signed local cutoff. Source audit-only events may
  occur between those transitions.
- A consistent original logical-attempt/counting offset for every transition,
  plus matching original row outcomes, counting bits, start/end times, holder
  and requirements/configuration provenance. Workflow execution and any
  supplied head provenance must agree with retained local facts.
- Approval settlement from immutable accepted independent/pair/human review
  records at that event cutoff. Human or pair gates cannot be waived by
  presenting matching work lease IDs
  (`src/lib/owner_local/budget_overlap.odin:20`).

The immutable `native_budget_overlap` records link existing local event IDs
and logical attempts to original native event IDs and attempts. Baseline,
mapping, receipt and budget evidence commit or roll back together
(`src/lib/owner_local/migration_016.sql:96`;
`budget_overlap.odin:179`). IDs and archived bytes are untouched. Exact positive,
conflicting lease/time/actor/provenance, restart/replay, deferred-COMMIT rollback,
approved-terminal and direct-reopen cases are tested in
`src/lib/owner_local/budget_overlap_test.odin:1`.

Native whole-second timestamps retain their declared precision, with exact
native event milliseconds as anchors. The pinned Odin core parser accepts only
hundredths; proof comparison therefore parses its whole-second calendar/offset
form and validates the original fractional precision independently, retaining
the original timestamp bytes (`budget_overlap.odin:139`). Milliseconds and
timezone offsets are tested, and unprovable sub-millisecond/conflicting or
malformed forms reject. The first real rework demo caught this fractional-time
gap after its budget-recovery/oscillation/dependency cases passed; the corrected
real rework flow passes at `sh_d0497bf53c10425cfab6e67be984b765`.

### Real dependency mutation and non-counting recovery

Signed `dependency.edit` can add an ordinary dependency after work has begun.
It retires the exact current work lease and records a task-scoped
`dep_added` disposition plus exact-child checkpoint notice atomically with the
edge and accepted event (`src/lib/owner_local/workflows.odin:125`;
`migration_016.sql:88`). Native attempt observations and budget folding consume
this cause; old capabilities cannot renew, and the next grant is non-counting
after prerequisite completion
(`src/lib/owner_local/attempts.odin:170`;
`budget_runtime.odin:27`). Workflow-generated private graph edges retain their
existing plan ownership boundary; ordinary active and historical-work tasks
are no longer rejected merely for having lease/submission rows.

The signed route regression covers edge/event failure rollback, accepted replay,
restart, stale capability denial, signed prerequisite submission/independent
approval, then a non-counting source grant at max1
(`src/lib/owner_local/dependency_budget_test.odin:21`).
Native original-fold oracles independently confirm raised-budget readiness,
dependency structural release/admission and oscillation/answer behavior
(`src/hub/service/taskv2/owner_budget_test.odin:1`).

V16 is still unmerged and unapproved during this rework, so its additive
ownership/retirement/proof tables are added to that migration. V1-V15 remain
byte-identical. No live store/schema rollout, push, deployment or production
restart occurs. True historical-schema reconstruction drops all unapproved V16
objects before applying migration tests.

### Rework validation

Final store command:
`nix develop --command odin test src/lib/owner_local -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1c-rework-final-store151`
passes **151/151**, exit0, `sh_83fe801e2a02ad44458ae866df1b7bcd`.

Other checks (exit0):
```bash
nix develop --command odin test src/hub/service/taskv2 -collection:odin_test=src -define:ODIN_TEST_NAMES=taskv2.test_owner_review_recovery_dependency_and_oscillation_native_oracles,taskv2.test_owner_budget_native_fold_and_admission_prefixes,taskv2.test_owner_budget_shared_migrated_fixture_matches_native_admission,taskv2.test_owner_attempt_projection_matches_native_fold_prefixes -out:$HOME/.cache/heimdall-tests/c1c-rework-native-four
# 4/4; sh_a4d578c83edbaee4eab97bb257b45d56

nix develop --command odin test src/contracts -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1c-rework-contracts
# 21/21; sh_8d8a32d8acef38f0c2b4e214294977e2

nix develop --command npm run typecheck
# PASS; sh_5a6b856d86ef09bb0f7d491c3db6f00d

nix develop --command node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_controls_test.ts tests/ui_owner_grants_test.ts tests/ui_owner_registry_listing_test.ts tests/ui_owner_submission_history_test.ts tests/ui_owner_local_contract_test.ts
# 20/20; sh_b028f9937f058b75118743a3d8532bdb

nix build .#ham-bridge .#ham-hub .#ham-ctl .#ham-pty-host -o $HOME/.cache/heimdall-tests/c1c-rework-final-bins
# all4; sh_089d36f682f0a1d937b2e46e784772ce
```

The new focused real flow is runnable with
`HEIMDALL_E2E_OWNER_BUDGET_REWORK_ONLY=1`; the complete retained demonstration
adds `HEIMDALL_E2E_OWNER_BUDGET_REWORK=1`. It uses disposable Hub/Bridge processes,
actual CLI children, signed browser/CLI mutations and the production rendered
panel for oscillation visibility
(`tests/e2e/owner_local_budget_rework_flow.ts:6`).
Final combined real demonstration and repository-check results follow below.


The complete retained + rework real demonstration passed with exit0 and all
steps PASSED at `sh_c31366251d4bb47869b1af3b655d58f7` (664 log lines).
The final held recovery also restores prior `waiting_on`; its focused regression
passes at `sh_e743a99f0ef0d00a91553b959a9ac138`.

Final-source rebuild, **151/151** store tests, and the complete retained + rework
real demonstration pass with exit0 in `sh_e5ea77b16243c1028711dfb70c7c9a74`
(1262 lines, concluding `all steps PASSED`). The demonstration uses those exact
rebuilt binaries. Exact combined command:

```bash
nix build .#ham-bridge .#ham-hub .#ham-ctl .#ham-pty-host -o $HOME/.cache/heimdall-tests/c1c-rework-ready-bins && nix develop --command odin test src/lib/owner_local -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1c-rework-ready-store151 && nix develop --command env HEIMDALL_E2E_HUB_BIN=$HOME/.cache/heimdall-tests/c1c-rework-ready-bins-1/bin/ham-hub HEIMDALL_E2E_BRIDGE_BIN=$HOME/.cache/heimdall-tests/c1c-rework-ready-bins/bin/ham-bridge HEIMDALL_E2E_CTL_BIN=$HOME/.cache/heimdall-tests/c1c-rework-ready-bins-2/bin/ham-ctl HEIMDALL_E2E_PTY_BIN=$HOME/.cache/heimdall-tests/c1c-rework-ready-bins-3/bin/ham-pty-host HEIMDALL_E2E_IDENTITY_BIN=$HOME/.cache/heimdall-tests/c1c-budget-identity HEIMDALL_E2E_OWNER_LOCAL=1 HEIMDALL_E2E_OWNER_LEASE=1 HEIMDALL_E2E_OWNER_LIFECYCLE=1 HEIMDALL_E2E_OWNER_CONTROLS=1 HEIMDALL_E2E_OWNER_WORKFLOWS=1 HEIMDALL_E2E_OWNER_LANGUAGE=1 HEIMDALL_E2E_OWNER_BUDGET=1 HEIMDALL_E2E_OWNER_BUDGET_REWORK=1 HEIMDALL_E2E_OWNER_GRANTS=1 HEIMDALL_E2E_OWNER_REGISTRY=1 node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/bridge_real_enroll_e2e.mjs
```

The final repository check command (exit0,
`sh_635f5195eba21cf267113ac1ba6005a6`) was:

```bash
python3 scripts/check-owner-aggregate-parity.py
git diff --exit-code c1016192 -- src/lib/owner_local/schema.sql src/lib/owner_local/migration_002.sql src/lib/owner_local/migration_003.sql src/lib/owner_local/migration_004.sql src/lib/owner_local/migration_005.sql src/lib/owner_local/migration_006.sql src/lib/owner_local/migration_007.sql src/lib/owner_local/migration_008.sql src/lib/owner_local/migration_009.sql src/lib/owner_local/migration_010.sql src/lib/owner_local/migration_011.sql src/lib/owner_local/migration_012.sql src/lib/owner_local/migration_013.sql src/lib/owner_local/migration_014.sql src/lib/owner_local/migration_015.sql
git diff --check
git diff --cached --check
```

The inventory remains 240 fields/23 structs; it is an inventory check, not a
claim of completed aggregate parity. No broad unrelated suites were repeated;
unchanged identity code uses the prior tested disposable identity binary.

## C1c released-hold review follow-up (attempts 4–5, requirements revision 2)

> Historical: the budget overlay this section repairs was removed by user
> decision on 2026-11-07 (owner-local migration V29).

The prior rework still missed this ordering: hold before expiry → exhausted
while held → explicit release while still exhausted → authorized budget raise.
Its saved independent control state remained held, so restoring it resurrected
the released hold. This was a real review failure at `784e4bf3`, not an
accepted limitation. The independent signed regression is retained verbatim in
`src/lib/owner_local/budget_hold_recovery_test.odin:7`; its first run failed
with the reported resurrected hold and `invalid_scope`
(`sh_02c49d56ef2dbdc7eea05ad9010cf1fa`).

Accepted signed hold and release now advance the budget owner's saved
independent control state in the same transaction as visible controls,
checkpoints, lifecycle state, accepted event, revision, receipt and intents
(`src/lib/owner_local/controls.odin:70`). A release leaves budget exhaustion
in force while removing the saved hold. A later budget raise restores that
updated state. An unreleased hold, a new hold after release, original
independent block reason/waiting target, and cancellation remain intact.
There are no schema or contract changes in this follow-up.

The additional storage regression injects both statement and deferred-COMMIT
failures for the signed release and budget raise. It compares saved ownership,
visible controls, task revision, accepted events, receipts, checkpoints and
intents before/after rejection, restarts, retries the exact command and verifies
historical replay; only the accepted transitions can authorize the next grant.
Still-held-before-expiry, hold-after-expiry, release/rehold, independent-block
and cancellation paths also pass. The native original fold independently
confirms unheld/exhausted at max1 and unheld/Ready/admissible at max2
(`src/hub/service/taskv2/owner_budget_test.odin:12`).

Focused exact commands and outcomes:

```bash
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_NAMES=owner_local.independent_released_hold_does_not_return_after_budget_increase -out:$HOME/.cache/heimdall-tests/c1c-hold-released-red
# Reproduced review failure, exit1; sh_02c49d56ef2dbdc7eea05ad9010cf1fa

nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_NAMES=owner_local.independent_released_hold_does_not_return_after_budget_increase,owner_local.budget_increase_held_restart_preserves_hold_and_independent_block -out:$HOME/.cache/heimdall-tests/c1c-hold-released-green
# 2/2 PASS exit0; sh_1fb8997a91877373860c32ca5081a99a

nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_NAMES=owner_local.independent_released_hold_does_not_return_after_budget_increase,owner_local.budget_released_hold_restart_replay_and_transaction_rollback,owner_local.budget_hold_release_retains_independent_block_and_cancel,owner_local.budget_increase_held_restart_preserves_hold_and_independent_block -out:$HOME/.cache/heimdall-tests/c1c-hold-orderings
# 4/4 PASS exit0; sh_56d68c97b2d33c6e9d15fca619ca68a6

nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_NAMES=owner_local.budget_hold_before_expiry_and_rehold_remain_active_after_recovery -out:$HOME/.cache/heimdall-tests/c1c-hold-rehold
# 1/1 PASS exit0; sh_b15b1a575080be1ac68e112b6f76fba3

nix develop --command odin test src/hub/service/taskv2 -collection:odin_test=src -define:ODIN_TEST_NAMES=taskv2.test_owner_released_hold_after_budget_increase_native_ready -out:$HOME/.cache/heimdall-tests/c1c-hold-native
# 1/1 PASS exit0; sh_e4eb2307f1507a40b7f270cdf94a0b66
```

The real regression retains the earlier four cases and adds hold before actual
maintenance expiry, owner restart, explicit signed release under exhaustion,
budget increase, second owner restart, child rebinding and successful next
counting grant
(`tests/e2e/owner_local_budget_rework_flow.ts:54`).

The first full run (`sh_036360ee30bfbe6fe5c6925b0d3623d5`) built all four
binaries but failed one incidental test copied alongside the reviewer's hold
reproduction. That unrelated overlap test inserted an unsupported
`work_lease_id` field and incorrectly expected strict import to accept it;
the contract correctly returned `invalid_content`. Removed that unrelated
copied test and unused imports, retaining the exact hold reproduction and all
existing overlap conflict tests. The focused hold/rollback tests had passed;
the corrected full suite contains 155 tests. Typecheck was not reached in that
failed combined command and is explicitly rerun below.

Final validation results follow below. Earlier contract21/UI20/native4 evidence
remains applicable: this follow-up changes no contract or UI production code.


Final four-binary rebuild, **155/155** storage tests and typecheck pass with
exit0 (`sh_08ea52db116dfdd0e9695625da25e00d`):

```bash
git add src/lib/owner_local/budget_hold_recovery_test.odin && nix build .#ham-bridge .#ham-hub .#ham-ctl .#ham-pty-host -o $HOME/.cache/heimdall-tests/c1c-hold-release-final-bins && nix develop --command odin test src/lib/owner_local -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1c-hold-release-store155 && nix develop --command npm run typecheck
```

The complete retained demonstration with the additional exact hold ordering
passes with exit0, 687 log lines and `all steps PASSED`
(`sh_981a2525e9aaaaa795d27bc7cf37c387`). It runs against those same rebuilt
binaries with this exact command:

```bash
nix develop --command env HEIMDALL_E2E_HUB_BIN=$HOME/.cache/heimdall-tests/c1c-hold-release-final-bins-1/bin/ham-hub HEIMDALL_E2E_BRIDGE_BIN=$HOME/.cache/heimdall-tests/c1c-hold-release-final-bins/bin/ham-bridge HEIMDALL_E2E_CTL_BIN=$HOME/.cache/heimdall-tests/c1c-hold-release-final-bins-2/bin/ham-ctl HEIMDALL_E2E_PTY_BIN=$HOME/.cache/heimdall-tests/c1c-hold-release-final-bins-3/bin/ham-pty-host HEIMDALL_E2E_IDENTITY_BIN=$HOME/.cache/heimdall-tests/c1c-budget-identity HEIMDALL_E2E_OWNER_LOCAL=1 HEIMDALL_E2E_OWNER_LEASE=1 HEIMDALL_E2E_OWNER_LIFECYCLE=1 HEIMDALL_E2E_OWNER_CONTROLS=1 HEIMDALL_E2E_OWNER_WORKFLOWS=1 HEIMDALL_E2E_OWNER_LANGUAGE=1 HEIMDALL_E2E_OWNER_BUDGET=1 HEIMDALL_E2E_OWNER_BUDGET_REWORK=1 HEIMDALL_E2E_OWNER_GRANTS=1 HEIMDALL_E2E_OWNER_REGISTRY=1 node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/bridge_real_enroll_e2e.mjs
```


## C1d attempt 2 fleet-policy continuation checkpoint (requirements revision 1)

This is a **partial continuation checkpoint**, not a C1d submission or parity
closure. Every remaining OPEN/PARTIAL row is binding. The coordinator clarified
on 2026-11-06 that native lifecycle statuses must remain typed source snapshots
until coherent M4 activation, including unlaunched targets; generic metadata
edits may never rewrite leases, reviews, workflows or budget. C1e owns operational
publication. C1d still owes the rest of its operational metadata and import work.

The first implemented vertical is ordinary native fleet policy. The source
authority is `src/hub/domain/taskchain.odin:269` and
`src/hub/service/taskchain/taskchain_service.odin:1891`; editing a row preserves
live leases (`src/hub/service/taskchain/taskchain_service.odin:1975`).
`src/contracts/owner_fleet_policy.odin:8` preserves every field of the native
fleet and bridge-model shapes, including original timestamp strings and raw
nested JSON string values. Strict content parsing permits Unicode without
relaxing ASCII-only signed authority envelopes
(`src/contracts/owner_json.odin:31`). Duplicate decoded keys, unknown fields,
noncanonical integer slots, invalid roles and duplicate roles fail closed.
Integer policy values are exact i64 in the owner and raw signed/read documents;
browser callers must retain raw response bytes for values above JS safe integer.

V17 adds normalized immutable version/role/model rows and a current-version view;
prior V1–V16 SQL files remain unchanged. Each version links to its accepted
signed event, retaining actor/request/time/exact input in existing event history.
`fleet.policy.set` is a chain-scoped mutation with ordinary encrypted fleet
JSON; `fleet.policy.read` returns paged source-shaped current rows plus accepted
sequence. Chain CAS protects writes; chain revision binds cursors. Creation
timestamp changes for an existing agent conflict. Statement/COMMIT rejection
rolls back policy, normalized children, event, receipt and chain revision.
Both APIs retain the common current-read-scope-before-historical-replay rule.
No live assignment/capability is created or retired by policy updates
(`src/lib/owner_local/fleet_policy.odin:11`). Provider availability and
resource ownership at actual activation remain for coherent later integration;
this checkpoint proves structural policy validation, not dispatch readiness.

The owner-local panel can read/save policy and follow list pages
(`src/ui/components/taskchain/OwnerLocalPanel.tsx:107`). Its real rendered
test uses the existing browser signer and actual disposable relay; CLI observes
the UI's accepted update. No production deployment/restart/push was performed.

Checks from the assigned C1d Workdir:

```bash
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1d-policy-store-all
# 159/159 PASS (sh_b34780fa63936e3d68cb314e0c7336f9)
nix develop --command odin test src/contracts -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1d-policy-contracts-all
# 23/23 PASS (same session)
nix build .#ham-bridge .#ham-hub .#ham-ctl .#ham-pty-host -o $HOME/.cache/heimdall-tests/c1d-fleet-policy-bins
# All four PASS exit0 (sh_db93629275df855a44fa44ff79f72964)
nix develop --command npm ci --ignore-scripts --no-audit --no-fund
nix develop --command npm run typecheck
nix develop --command node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_local_contract_test.ts tests/ui_owner_controls_test.ts tests/ui_owner_grants_test.ts tests/ui_owner_registry_listing_test.ts tests/ui_owner_submission_history_test.ts
# Typecheck + 21/21 PASS exit0 (sh_608419267e595908f0a85b1f5efed814)
# Final panel typecheck PASS exit0 (sh_d437df6c3fb79292ece36cadca844ab7)
```

The new fourth policy storage regression reconstructs actual V16, tests schema
collision and deferred-COMMIT rollback without changing old evidence or live
capabilities, then migrates and proves a policy edit leaves the live child
capability usable. Historical migration fixtures drop V17 additions before
reconstruction and assert final schema17. Other retained packages were not
rerun; changed contracts/store and the retained real demo supply relevant checks.

Initial fixture generation overescaped JSON strings; corrected only the
fixtures. Initial typecheck found the known absent pinned posthog-js dependency;
npm ci restored it without a lockfile change. The first focused real demo
attempted CLI before the disposable token was provisioned; its fixture now
restarts the disposable owner first, following the existing budget-only harness.
The next comparison used property-order-sensitive JSON.stringify; replaced it
with exact key/value comparison. The final focused real CLI+rendered UI demo
passes all steps with exit0 (`sh_5c88b33d7a19516629437728ac796615`):

```bash
nix develop --command env HEIMDALL_E2E_HUB_BIN=$HOME/.cache/heimdall-tests/c1d-fleet-policy-bins-1/bin/ham-hub HEIMDALL_E2E_BRIDGE_BIN=$HOME/.cache/heimdall-tests/c1d-fleet-policy-bins/bin/ham-bridge HEIMDALL_E2E_CTL_BIN=$HOME/.cache/heimdall-tests/c1d-fleet-policy-bins-2/bin/ham-ctl HEIMDALL_E2E_PTY_BIN=$HOME/.cache/heimdall-tests/c1d-fleet-policy-bins-3/bin/ham-pty-host HEIMDALL_E2E_IDENTITY_BIN=$HOME/.cache/heimdall-tests/c1c-budget-identity HEIMDALL_E2E_OWNER_LOCAL=1 HEIMDALL_E2E_OWNER_FLEET_POLICY_ONLY=1 node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/bridge_real_enroll_e2e.mjs
```

The complete retained demo additionally uses this command (result recorded below):

```bash
nix develop --command env HEIMDALL_E2E_HUB_BIN=$HOME/.cache/heimdall-tests/c1d-fleet-policy-bins-1/bin/ham-hub HEIMDALL_E2E_BRIDGE_BIN=$HOME/.cache/heimdall-tests/c1d-fleet-policy-bins/bin/ham-bridge HEIMDALL_E2E_CTL_BIN=$HOME/.cache/heimdall-tests/c1d-fleet-policy-bins-2/bin/ham-ctl HEIMDALL_E2E_PTY_BIN=$HOME/.cache/heimdall-tests/c1d-fleet-policy-bins-3/bin/ham-pty-host HEIMDALL_E2E_IDENTITY_BIN=$HOME/.cache/heimdall-tests/c1c-budget-identity HEIMDALL_E2E_OWNER_LOCAL=1 HEIMDALL_E2E_OWNER_LEASE=1 HEIMDALL_E2E_OWNER_LIFECYCLE=1 HEIMDALL_E2E_OWNER_CONTROLS=1 HEIMDALL_E2E_OWNER_WORKFLOWS=1 HEIMDALL_E2E_OWNER_LANGUAGE=1 HEIMDALL_E2E_OWNER_BUDGET=1 HEIMDALL_E2E_OWNER_BUDGET_REWORK=1 HEIMDALL_E2E_OWNER_FLEET_POLICY=1 HEIMDALL_E2E_OWNER_GRANTS=1 HEIMDALL_E2E_OWNER_REGISTRY=1 node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/bridge_real_enroll_e2e.mjs
```

The additional content-parser regression rejects invalid UTF-8, overlong UTF-8 and malformed Unicode hex escapes with no production changes (1/1 PASS exit0, `sh_152b3b7b77c7647e81afcb7797b5a94a`):

```bash
nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_NAMES=contracts.owner_content_json_rejects_invalid_utf8_and_hex_escapes -out:$HOME/.cache/heimdall-tests/c1d-content-invalid-bytes-red2
```

Final contract package: **24/24 PASS**, exit0 (`sh_aa12368c07f27a2b8dd507d319f13c72`):

```bash
nix develop --command odin test src/contracts -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1d-policy-contracts-final24
```

The complete retained compatibility demo above passes all steps with **exit0**, 687 log lines (`sh_b8873369578548df11b58b8ef2286ba3`). Its `HEIMDALL_E2E_OWNER_FLEET_POLICY` flag is not a harness selector: the new fleet cases are proven separately by the explicit `HEIMDALL_E2E_OWNER_FLEET_POLICY_ONLY=1` focused CLI/rendered-UI demo. No new-case coverage is inferred from the retained run. Reuse these exact passing results; do not repeat unchanged suites.

Final inventory and whitespace checks pass (`sh_7624208bf3a4b867b22d4bc9a54f076e`): `python3 scripts/check-owner-aggregate-parity.py` reports240 fields/23 structs; `git diff --check` passes; explicit `git diff --exit-code HEAD --` over schema.sql and migrations002–016 confirms those files remain unchanged. No unrelated boy-scout edits were made.

## C1d attempt 3 native member/directory continuation checkpoint

This remains **partial C1d work**, not a submission or parity closure. Current
member/directory configuration, the other metadata kinds, defaults, curated
summary, brief references and aggregate activation remain required.

The native source shapes are `src/hub/domain/taskchain.odin:239` and
`src/hub/domain/taskchain.odin:256`. Native membership is keyed by
(chain_id, agent_instance_id), not by durable agent ID
(`src/hub/repository/sqlite/taskchain_repo_sqlite.odin:338`). The adapter retains
an empty historical instance identity without inventing a durable replacement.
Native directory bridge/VCS fields can be empty; all original timestamp
spellings and nested VCS JSON strings remain exact.

`src/contracts/owner_metadata.odin:7` and :15 define the ordinary source shapes;
:36 validates every field and nested JSON without unknown-key dropping.
`src/lib/owner_local/migration_018.sql:58` adds an explicit signed-import native
owner linkage, immutable source manifests, and normalized member/directory rows.
Its deferred event foreign keys bind source facts to accepted signed input.
V1–V17 migration SQL is unchanged.

`native.metadata.import` consumes an encrypted object with chain_id,
owner_user_id, source_revision, kind (member or directory), and a records array
of ordinary native objects. Current bounds are 49,152 plaintext bytes, 100
records per immutable kind/source snapshot and 4,096 bytes per string before
stricter ID/time checks (`src/contracts/owner_metadata.odin:36`, :66). Larger
aggregate import/chunk composition remains an explicit gap, not silent
truncation or an approved omission. A source revision/kind is pinned to exact
input bytes; changed content conflicts. A later revision preserves the earlier
snapshot. These imported facts do not enroll members, configure execution
directories, resolve filesystem paths, or mint/revoke child authority
(`src/lib/owner_local/native_metadata.odin:8`).

`native.metadata.read` returns paged ordinary source rows with original owner,
source revision, accepted sequence and record count. Its cursor binds account,
chain, source revision, kind and content digest (:50). Later local mutations do
not invalidate an immutable source page; changed source/kind cursors fail.
Current common grant checks still precede every read/replay. Mutation uses chain
CAS and commits rows, origin/manifest, event, receipt and revision atomically.
The browser signing adapter consumes these methods
(`src/ui/api/ownerLocalClient.ts:67`); the actual CLI relay consumes the signed
ordinary documents in `tests/e2e/owner_local_metadata_flow.ts:5`. No new rendered
metadata panel is claimed.

Verification from the assigned Workdir:

- `nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/c1d-metadata-full-a3f`
  — 163/163 PASS, session sh_a963dc1a3b976aa880f1f26b0baee83e. Covers source
  round-trip/history/replay/restart, scope/CAS, statement/deferred-COMMIT rollback,
  immutable guards, pagination/revoked grants, and genuine V17 migration
  collision/COMMIT rollback preserving live capabilities.
- `nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/c1d-metadata-contracts-a3i`
  — 25/25 PASS, sh_4f64de17ad4197ecb1f153f30ab869ec.
- `nix develop --command node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_local_contract_test.ts`
  — 12/12 PASS in sh_a963dc1a3b976aa880f1f26b0baee83e.
- `nix develop --command npm run typecheck` — PASS in
  sh_5311b13e49ceec913329666810b1b5d4 and sh_08e090bd142bcbb8415b35a45c200899.
  The latter combined shell's exit0 masked an earlier failed contract check;
  only the standalone a3i command above establishes final contract success.
- `nix build .#ham-bridge .#ham-hub .#ham-ctl .#ham-pty-host -o $HOME/.cache/heimdall-tests/c1d-metadata-a3-final-bins`
  — all four PASS in sh_c93ed5813395c23c63412cee5e6775eb, before that
  combined shell's subsequent test-only failure. Its binaries are the final
  production-source binaries exercised below.
- `nix develop --command env HEIMDALL_E2E_HUB_BIN=$HOME/.cache/heimdall-tests/c1d-metadata-a3-final-bins-1/bin/ham-hub HEIMDALL_E2E_BRIDGE_BIN=$HOME/.cache/heimdall-tests/c1d-metadata-a3-final-bins/bin/ham-bridge HEIMDALL_E2E_CTL_BIN=$HOME/.cache/heimdall-tests/c1d-metadata-a3-final-bins-2/bin/ham-ctl HEIMDALL_E2E_PTY_BIN=$HOME/.cache/heimdall-tests/c1d-metadata-a3-final-bins-3/bin/ham-pty-host HEIMDALL_E2E_IDENTITY_BIN=$HOME/.cache/heimdall-tests/c1c-budget-identity HEIMDALL_E2E_OWNER_LOCAL=1 HEIMDALL_E2E_OWNER_METADATA_ONLY=1 node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/bridge_real_enroll_e2e.mjs`
  — all steps PASS exit0, sh_378e329a4268e0a0703a0db71a0f0ad4. Actual enrollment,
  CLI relay, every native field, CAS/conflict denial, immutable paging, historical
  signed retry, exact event input and disposable owner restart were exercised.

Initial failed drafts included multiline-do syntax, a test map's stale outer
header after insertion, a malformed test edit, missing dynamic-literal feature,
and historical fixtures retaining new tables. Corrected tests now pass.
No production restart, deployment or push occurred. No unrelated code cleanup.


### V19 source-history continuation (C1d, incomplete)

The strict source contract preserves every ordinary field of native Task_Chain,
Task, Task_Comment and Chain_Summary: 20 + 25 + 10 + 9 fields
(`src/contracts/owner_metadata_facts.odin:1`). Normalized immutable tables preserve
original IDs, boolean/integer scalar types, exact timestamp strings, delegated
comment provenance and source revisions (`src/lib/owner_local/migration_019.sql:59`).
Signed imports and source-pinned ordinary paged reads use the existing
native.metadata API (`src/lib/owner_local/native_metadata.odin:9`).
Exact accepted document bytes remain in signed event evidence.

Coordinator decision: native comment/summary text is an immutable source fact;
it does not populate or replace C3 canonical linked bodies. Source lifecycle
statuses remain snapshots, separate from live local lifecycle authority.
Operational metadata updates, complete pinned input/output resolution,
fleet source linkage/activation validation and complete aggregate composition
remain required before C1d submission. Bounds remain explicit: 100 records,
49152 bundle bytes, and 4096 bytes per native string; no silent truncation.

Verified continuation, all exit 0:

- Contract 26 tests and storage 166 tests, including every new source kind,
  exact scalar round trips/history/restart, owner scope, signed replay,
  statement/deferred-COMMIT rollback, and genuine V18 migration collision/
  deferred-COMMIT rollback with a retained live child capability:
  `nix develop --command odin test src/contracts -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1d-v19-contract-final-a5`;
  `nix develop --command odin test src/lib/owner_local -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c1d-v19-storage-final-a5`
  (session `sh_10df2a829d2eca7292d84ef8cb66f177`).
- Four binaries:
  `nix build .#ham-bridge .#ham-hub .#ham-ctl .#ham-pty-host -o $HOME/.cache/heimdall-tests/c1d-v19-a5-bins`
  (session `sh_fd01917c0c6f481e02003e837b29999f`).
- TypeScript: `nix develop --command npm run typecheck`
  (session `sh_61cad592d9156e45a4016e6e3d40668c`);
  `nix develop --command node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_local_contract_test.ts`
  (12 tests, session `sh_7d837a24ac534acc676c29e47f462a44`).
- Actual signed UI modules -> CLI -> Hub relay -> disposable enrolled Bridge:
  extended `tests/e2e/owner_local_metadata_flow.ts:1` round-trips all six kinds,
  history/replay/CAS and restart. Session `sh_bbc69349c9cc5a04a00501c0fb8d4df4`
  passed every step using the four binaries above, retained
  `HEIMDALL_E2E_IDENTITY_BIN=$HOME/.cache/heimdall-tests/c1c-budget-identity`,
  `HEIMDALL_E2E_OWNER_LOCAL=1 HEIMDALL_E2E_OWNER_METADATA_ONLY=1`,
  and `node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/bridge_real_enroll_e2e.mjs`.
- `python3 scripts/check-owner-aggregate-parity.py`: 240 fields / 23 structs;
  `git diff --check`: clean.
## C1d-2 attempt 2 V20 continuation checkpoint

This checkpoint is partial: operational defaults, members, directories, curated
summary, typed authorized brief input/output resolution and the complete rich
aggregate composition remain required. Do not submit the whole task on this
checkpoint or interpret existing OPEN/PARTIAL rows as omissions.

`task.priority` accepts a strict native `p0`/`p1`/`p2` payload, writes immutable
normalized priority history and advances task/chain CAS
(`src/lib/owner_local/store.odin:236`). Task reads and chain listings consume the
current value. Existing live capabilities retain their exact binding and TTL;
listing cursors become stale. V20 preserves V1-V19 migrations and their retained
history (`src/lib/owner_local/migration_020.sql:1`).

One original chain owner now spans native history and metadata, including legacy
history imported before origins existed
(`src/lib/owner_local/native_metadata.odin:12`). V20 reconciles missing origins
and fails atomically on conflicting historical ownership. Imports preserve exact
native source documents and acceptance history.

Fleet source import uses `native.metadata.import` with `kind=fleet`: its records
are ordinary native fleet rows, while original owner and source revision live in
the signed import envelope. Import retains an immutable source snapshot without
installing operational policy (`src/lib/owner_local/native_fleet.odin:9`).
`fleet.policy.set` optionally binds a `source_revision` in its signed payload;
the decrypted ordinary policy must match that exact same-chain/agent snapshot
(`src/lib/owner_local/native_fleet.odin:22`). Accepted operational history and
ordinary policy reads retain the source link. Legacy unlinked sets remain
available. No capability enrollment or dispatch was added.

Coordinator decisions:

- `cmt_18e58b5c17004f02` / `msg_18e58b5d98757871`: source fleet import stays
  immutable; operational activation is separate. C1d-2 validates structural
  roles/capacity/bridge/provider/model contracts. Live catalog/slot activation
  remains M3.
- `msg_18e58bc86162ed29`: approved the next operational metadata command work,
  curated_summary in CONTEXT_SOURCE_SQL, curated notes in context_materialize,
  and priority in the task context row. These context changes are **not yet
  implemented** here. FTS and artifact indexing remain deferred.

Verification from the assigned Workdir:

```bash
nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/c1d2-fleet-contract-final-a2
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/c1d2-fleet-origin-store-final-a2
nix develop --command node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_local_contract_test.ts
nix develop --command npm run typecheck
nix build .#ham-bridge .#ham-hub .#ham-ctl .#ham-pty-host -o $HOME/.cache/heimdall-tests/c1d2-fleet-origin-a2-bins
```

Results: 27 contract tests, 176 storage tests, 14 UI contract tests, typecheck
and all four binary builds pass. Storage includes both import orders, legacy
origin reconciliation, V19 migration collision and deferred-COMMIT rollback,
statement/COMMIT failure for imports and activation, priority replay/restart,
live capability preservation and stale cursor rejection. Exact sessions:
`sh_716808d9a364123b45c6efe7339ce325`,
`sh_039b9b722bf0e71f865be7f9945f57f7`,
`sh_226d0216c77fd2bc285ad3a7f92c3d3f`,
`sh_6354a417ece75a272a35caf8ec3e3511`.

The initial typecheck lacked pinned posthog-js. The existing lockfile install
restored it without dependency-source edits:

```bash
nix develop --command npm ci --ignore-scripts --no-audit --no-fund
```

The real relay demo is extended in
`tests/e2e/owner_local_metadata_flow.ts:1`. Its first fleet drift assertion used
JavaScript Number arithmetic above 2^53, which did not change the payload.
The corrected fixture retains the original raw decimal bytes and changes them
explicitly. Production pinned-source mismatch tests already passed; no authority
validation was relaxed to accommodate the fixture.

Corrected real CLI/Hub/Bridge relay demo: PASS, exit 0
(`sh_f5972c4fe7d7cd7475997749c20a32fa`), preserving all six existing metadata
source kinds and proving operational priority and pinned fleet activation through
restart:

```bash
nix develop --command env HEIMDALL_E2E_HUB_BIN=$HOME/.cache/heimdall-tests/c1d2-fleet-origin-a2-bins-1/bin/ham-hub HEIMDALL_E2E_BRIDGE_BIN=$HOME/.cache/heimdall-tests/c1d2-fleet-origin-a2-bins/bin/ham-bridge HEIMDALL_E2E_CTL_BIN=$HOME/.cache/heimdall-tests/c1d2-fleet-origin-a2-bins-2/bin/ham-ctl HEIMDALL_E2E_PTY_BIN=$HOME/.cache/heimdall-tests/c1d2-fleet-origin-a2-bins-3/bin/ham-pty-host HEIMDALL_E2E_IDENTITY_BIN=$HOME/.cache/heimdall-tests/c1c-budget-identity HEIMDALL_E2E_OWNER_LOCAL=1 HEIMDALL_E2E_OWNER_METADATA_ONLY=1 node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/bridge_real_enroll_e2e.mjs
```

## C1d-2 attempt 3 V21 continuation checkpoint

This checkpoint remains partial. Operational members/directories, typed authorized
pinned brief input/output resolution and rich aggregate composition still require
implementation and independent review before submission.

Signed `chain.defaults.set` and `chain.summary.set` use strict encrypted prose
payloads, chain CAS and immutable normalized history
(`src/lib/owner_local/store.odin:236`). Defaults additionally require a strict
Unicode JSON object; exact original JSON text is retained. Native review-role
descriptions and pending proposals stay in defaults; installing active review
roles remains the separate `review.roles` operation, as approved in
`msg_18e58c9aa0808ab7`.

`chain.metadata.read` pages mixed operational defaults/summary history under
current chain read authorization with revision-bound cursors and a fixed byte
budget (`src/lib/owner_local/chain_metadata.odin:11`).
Ordinary chain reads consume current defaults
(`src/lib/owner_local/reads.odin:96`). Summary history and task priority enter the
context source inventory; materialization consumes current curated notes
(`src/lib/owner_local/context.odin:15`). Context algorithm/source-digest version 2
forces lazy rebuild of persisted V20 caches even when commit_seq is unchanged.

V21 appends immutable version tables and preserves V1-V20
(`src/lib/owner_local/migration_021.sql:1`). Regression coverage includes exact
replay, stale CAS and cursors, strict duplicate-key rejection, clearing current
notes/defaults without deleting history, statement/deferred-COMMIT rollback,
restart, live capability preservation, genuine V20 collision/COMMIT migration
rollback, and unchanged-checkpoint context cache upgrade
(`src/lib/owner_local/chain_metadata_test.odin:17`).
Historical reconstruction fixtures explicitly remove the additive V21 tables.

Final verification, all exit 0 from the assigned Workdir:

```bash
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/c1d2-v21-cache-final-a3
nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/c1d2-defaults-a3-contracts
nix develop --command node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_local_contract_test.ts
nix develop --command npm run typecheck
nix build .#ham-bridge .#ham-hub .#ham-ctl .#ham-pty-host -o $HOME/.cache/heimdall-tests/c1d2-v21-final-a3-bins
python3 scripts/check-owner-aggregate-parity.py
git diff --check
git diff --cached --check
```

Results: 181 storage tests, 27 contracts, 16 UI contract tests, typecheck,
four binary builds, and 240-field/23-struct inventory check pass.
Sessions: `sh_f811ab456b752d889cc218c0ed0f8f96` (storage),
`sh_221f4b94a78dec7badea4806e45d9037` (contracts/UI/typecheck),
`sh_32da9d31605337eeed70665129cdf29e` (builds).

Final real UI signatures -> CLI -> Hub -> disposable enrolled Bridge demo
passes exact notes/defaults, mixed-kind pagination, CAS/replay, context and
restart, retaining all prior metadata evidence
(`tests/e2e/owner_local_metadata_flow.ts:1`):

```bash
nix develop --command env HEIMDALL_E2E_HUB_BIN=$HOME/.cache/heimdall-tests/c1d2-v21-final-a3-bins-1/bin/ham-hub HEIMDALL_E2E_BRIDGE_BIN=$HOME/.cache/heimdall-tests/c1d2-v21-final-a3-bins/bin/ham-bridge HEIMDALL_E2E_CTL_BIN=$HOME/.cache/heimdall-tests/c1d2-v21-final-a3-bins-2/bin/ham-ctl HEIMDALL_E2E_PTY_BIN=$HOME/.cache/heimdall-tests/c1d2-v21-final-a3-bins-3/bin/ham-pty-host HEIMDALL_E2E_IDENTITY_BIN=$HOME/.cache/heimdall-tests/c1c-budget-identity HEIMDALL_E2E_OWNER_LOCAL=1 HEIMDALL_E2E_OWNER_METADATA_ONLY=1 node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/bridge_real_enroll_e2e.mjs
```

Session `sh_ca5688409f39f75b48a2f3ce8328781d`, exit 0, all steps PASSED.
Earlier draft failures were corrected: Odin test string escaping and dynamic
array slicing, stale final-schema expectations, and the native-origin V19
reconstruction retaining the additive V21 table. No failed check remains.

Coordinator decision `cmt_18e58cc6c33d5ca9` / `msg_18e58cc85d025237`
defines the next implementation:

- `chain.member.set` must keep workflow coordinator capability enrollment
  separate, while member removal revokes authority and expires leases.
- `chain.directory.set` manages CAS/history configuration separately from
  validated Git activation by `lifecycle.configure`. Directory modification
  or removal must invalidate cached directory resolution and active task path
  bindings.

These member/directory rules are approved but not yet implemented here.
FTS/artifact indexing remains deferred under the earlier coordinator decision.


## C1d-2 completion: operational members, directories, and immutable input pins (V22)

Coordinator decisions: `msg_18e58cc85d025237` separates operational membership
from coordinator capability enrollment; `cmt_18e58d747d1b50f1` keeps string
brief references with immutable pins; `cmt_18e58df40f408030` assigns provider
catalog launchability and placement validation to M3. C1d-2 preserves strict
policy shape, pinned source linkage, and exact-child lifecycle enrollment.

Implementation and evidence:

- Signed `chain.member.set` and `chain.directory.set` run under the existing
  chain CAS, receipt, accepted-event, and transaction boundary
  (`src/lib/owner_local/store.odin:236`). V22 adds immutable operational
  histories and revocation evidence without rewriting V1–V21
  (`src/lib/owner_local/migration_022.sql:1`,
  `src/lib/owner_local/migrations.odin:3`).
- Membership retains arbitrary native role identifiers. A role does not enroll
  a coordinator capability. Exact local child proof, lifetime single-chain
  binding, sole coordinator protection, and current launch authorization are
  enforced in `src/lib/owner_local/operational_metadata.odin:10` and
  `src/lib/owner_local/operational_metadata.odin:34`.
- Removal/rebinding retires affected leases, disables fleet assignments with
  an advanced configuration revision, revokes current lifecycle/coordinator
  authority, and preserves exact-child checkpoint notices and merge evidence
  (`src/lib/owner_local/operational_metadata.odin:20`). Rejoin alone cannot
  revive a prior capability. Explicit fresh fleet/lifecycle enrollment is
  required; revoked lifecycle bindings cannot fall back to generic claims
  (`src/lib/owner_local/lifecycle.odin:149`).
- Directory configuration preserves exact native-shaped JSON, including Unicode
  paths and VCS JSON. Updates/removal invalidate current bindings for that
  directory ID; unrelated active bindings survive. Current resolution reads
  the latest operational version, and a fresh Git lifecycle activation must
  match its enabled path (`src/lib/owner_local/operational_metadata.odin:67`,
  `src/lib/owner_local/operational_metadata.odin:90`).
- `chain.metadata.read` pages summary/defaults/member/directory history with
  revision-bound cursors and explicit `entity_id`, `enabled`, and `current`
  fields (`src/lib/owner_local/chain_metadata.odin:10`). Imported source
  snapshots remain provenance and never silently enroll operational authority.
- Brief input strings support `#<event_id>`, `output:<task>:<attempt>:<version>`,
  and `facet:<task>:<attempt>:<kind>[:<version>]`. Task IDs can contain colons;
  placement facets retain native attempt zero. A versionless facet spelling
  requires one immutable version at admission, then persists that exact pin.
  Mutable latest-output and unknown references fail closed
  (`src/contracts/owner_brief_refs.odin:9`).
- Immutable local rows are resolved only within the authorized Store account
  and chain. Accepted requirements persist bounded exact input bodies and
  digests; later source imports cannot change those pins. Both workflow
  expansion paths use the same pin boundary
  (`src/lib/owner_local/brief_refs.odin:9`,
  `src/lib/owner_local/brief_refs.odin:48`).
  `requirements.present` returns them as `resolved_inputs`
  (`src/lib/owner_local/lifecycle_agent.odin:103`). Old unpinned mutable
  requirements require an explicit edit; no mutable Hub lookup is used.
  Artifact/message references within source facets remain unresolved/import_pending
  provenance; C3 still owns their body import/indexing.

Metadata revocation also appends task/lease retirement evidence to the parent
accepted event (`src/lib/owner_local/events.odin:21`). Attempt and budget
scans consume that evidence as an explicit local replacement expiry, preserving
full history and native counting semantics
(`src/lib/owner_local/attempts.odin:184`,
`src/lib/owner_local/budget_runtime.odin:129`).

Final checks, all exit 0:

```bash
nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/c1d-v22-final-contracts
nix develop --command npm run typecheck
nix develop --command node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_local_contract_test.ts
```

Session `sh_01e547ab255dcacfcc05f7a0b831d41f`: 29 contracts, typecheck,
18 TypeScript contract tests pass, including colon-containing task IDs,
placement attempt zero, arbitrary native member roles, strict mutation scope,
and pinned reference grammar.

```bash
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/c1d-v22-history-final-store190
nix build .#ham-bridge .#ham-hub .#ham-ctl .#ham-pty-host -o $HOME/.cache/heimdall-tests/c1d-v22-history-final-bins
```

Full 190 storage tests pass (`sh_a983cf5411182f173475db4843ac71d0`).
Four binary builds pass (`sh_ec5ba88e4bc84bc593bab77119ac55b3`).
This includes signed CAS/replay/current authority, source-version pinning,
restart, statement and deferred-COMMIT rollback, genuine historical migrations,
coordinator revocation, unrelated-directory preservation, and complete
metadata-caused attempt/budget projections.

```bash
nix develop --command env HEIMDALL_E2E_HUB_BIN=$HOME/.cache/heimdall-tests/c1d-v22-history-final-bins-1/bin/ham-hub HEIMDALL_E2E_BRIDGE_BIN=$HOME/.cache/heimdall-tests/c1d-v22-history-final-bins/bin/ham-bridge HEIMDALL_E2E_CTL_BIN=$HOME/.cache/heimdall-tests/c1d-v22-history-final-bins-2/bin/ham-ctl HEIMDALL_E2E_PTY_BIN=$HOME/.cache/heimdall-tests/c1d-v22-history-final-bins-3/bin/ham-pty-host HEIMDALL_E2E_IDENTITY_BIN=$HOME/.cache/heimdall-tests/c1c-budget-identity HEIMDALL_E2E_OWNER_LOCAL=1 HEIMDALL_E2E_OWNER_LEASE=1 HEIMDALL_E2E_OWNER_METADATA_ONLY=1 node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/bridge_real_enroll_e2e.mjs
```

Session `sh_dae8cecc222ce025a1e76ceaa00e297a`: all steps PASSED.
Actual enrolled disposable Hub/Bridge/CLI and live PTY children demonstrate
strict member identity, sole coordinator protection, exact receipts, typed
source output pins, member removal/rejoin, explicit fresh enrollment, directory
path revocation, complete attempt expiry evidence, full retained V18–V21
composition, and owner restart. No live deployment/restart or push occurred.

Generated mirrors and whitespace pass
(`sh_210510f5f725ccf9a47ad3c6227f9ac2`):

```bash
python3 scripts/generate-owner-local-contracts.py
git diff --exit-code -- src/contracts/owner_schema.odin src/ui/api/ownerSchema.ts
git diff --check
git diff --cached --check
```

Earlier draft failures were corrected: Odin parameter/redeclaration/string
syntax; updating the schema JSON before regenerating mirrors; advancing the
fleet revision on disable; task-scoped rather than taskless control notices;
replaying original signed bytes; replacing fabricated unresolved fixture inputs
with immutable admitted facts; enabling the real-child harness; matching fresh
fleet/lifecycle configuration revisions; and extending exact retirement evidence
to attempt/budget scans. The last audit also restricted directory invalidation
to the current configuration rather than historical directory bindings.
Broader unrelated UI/Bridge suites were not repeated: focused contract tests,
typechecking, full owner-local storage, all builds, and actual enrolled relay
cover the changed boundaries. Named independent review remains required.

## C1e / V23 proposals, publication and mixed-work evidence

Task `task_18e57ad591fe06b0`, requirements revision1. This closes only the C1e slice. Unrelated OPEN/PARTIAL rows remain required for C1/M4; no aggregate-wide completion or final ordinary route cutover is claimed.

- Preserve V1 published-by-default create, as coordinator `cmt_18e58effbdc03d37` directs. Signed-device-only `chain.draft`, `task.draft`, `task.publish`, `chain.propose`, `chain.decide`, `chain.publish`, `workflow.draft`, `work.dependency.add/remove`, `work.scope`, `chain.complete` and bounded `work.read` extend the existing strict encrypted relay. Agent/coordinator capabilities are unchanged. Shared Odin/TS fixtures reject unknown fields, duplicate keys, invalid endpoint kinds and non-string/unsafe revision counters (`src/contracts/owner_work_test.odin:6`, `src/ui/api/ownerWork.ts:14`).
- The accepted operation ID is the stable local proposal ID. Raw proposal JSON, source actor/time metadata, raw task specs, immutable decisions/result and accepted event provenance remain retained. Native pending defaults without IDs derive identity from their accepted source event, preserving the original raw defaults; validating a projection never rewrites original metadata (`src/lib/owner_local/work_commands.odin:48`, `src/lib/owner_local/work_publication_test.odin:111`).
- Validate all draft/proposed briefs, immutable input references, named reviewers/declared review roles and both-pass dependencies before commit. Approval and auto-approval share one transaction for ordinary task creation, publication, priorities, typed edges, input pins, decision, defaults clear, history and discovery intents. Cycles, stale decisions/CAS, statement failure and deferred-COMMIT failure leave no partial materialization (`src/lib/owner_local/work_publication_test.odin:88`).
- Current task attempts and workflow executions remain the generation authorities. Every active typed prerequisite must succeed; cancellation and scope exclusion never turn it successful. A claim or queued-run activation freezes both generations and the exact output manifest. Consumed producer tasks cannot reopen; consumed runs cannot retry. Mixed and legacy ordinary edges share cycle detection/readiness; private workflow stage edges cannot become external endpoints (`src/lib/owner_local/work_graph.odin:11`, `:56`, `:134`). Existing V1 live-lease dependency retirement remains supported. Native stage-key output arrays are built from current executor output records, preserving structured output and `{}` fallback (`src/lib/owner_local/work_graph.odin:146`); run-to-run/run-to-task tests assert those exact manifests. Proposed human approval remains mandatory after independent review (`src/lib/owner_local/work_graph_test.odin:192`).
- Native `workflow.run` on an unpublished chain also stages without expansion (`src/hub/service/taskv2/workflow_execution.odin:163`, `:212`). Draft runs use the existing static/language validator in a savepoint and the existing executor at activation, after publication and prerequisite success. Record one immutable start and consumption receipts in the accepted transaction; never duplicate stage expansion on replay. A never-started cancelled draft must use a replacement run ID, per `cmt_18e5901dec9871e7`; activated retries retain existing exact execution fencing.
- Completion requires no pending proposal, exact current work revision, published successful included tasks with settled merges or successful current runs, satisfied prerequisites, terminal excluded items, at least one included success, and no live work/review leases. Store immutable summary/time/revision then make the chain terminal. Revision triggers include publication, task requirements/lifecycle/attempts, control overlays, language/static execution changes, legacy/mixed graph edits, scope and defaults. Receipt replay is read-only (`src/lib/owner_local/work_graph.odin:100`, `src/lib/owner_local/migration_023.sql:169`).
- Exact source imports add `work_dependency`, `work_receipt`, `work_scope`, `work_run`, `work_execution`, `work_stage` and `work_event`. All original fields, nested typed IDs, owner, exact generations, integer IDs/revisions above2^53, Unicode, raw JSON strings and timestamps round-trip against the fixture. Immutable source records retain source revision/digest/origin linkage and never configure or launch operational state (`src/contracts/owner_metadata_facts.odin:84`, `src/lib/owner_local/work_native_test.odin:10`). C3 retains linked body/index ownership.
- Append V23 after unchanged V1-V22. Genuine V22 collision and deferred-COMMIT upgrade failures preserve schema22, exact live capabilities/deadlines and prior rows; a clean retry upgrades and the old capability still presents requirements. Historical fixture reconstruction explicitly tears down every new table/trigger (`src/lib/owner_local/work_upgrade_test.odin:6`).

Reproduce the actual disposable signed relay (requires the standard identity helper):

```bash
nix build .#ham-bridge .#ham-hub .#ham-ctl .#ham-pty-host -o $HOME/.cache/heimdall-tests/c1e-v23-final-bins
nix develop --command env HEIMDALL_E2E_HUB_BIN=$HOME/.cache/heimdall-tests/c1e-v23-final-bins-1/bin/ham-hub HEIMDALL_E2E_BRIDGE_BIN=$HOME/.cache/heimdall-tests/c1e-v23-final-bins/bin/ham-bridge HEIMDALL_E2E_CTL_BIN=$HOME/.cache/heimdall-tests/c1e-v23-final-bins-2/bin/ham-ctl HEIMDALL_E2E_PTY_BIN=$HOME/.cache/heimdall-tests/c1e-v23-final-bins-3/bin/ham-pty-host HEIMDALL_E2E_IDENTITY_BIN=$HOME/.cache/heimdall-tests/c1c-budget-identity HEIMDALL_E2E_OWNER_LOCAL=1 HEIMDALL_E2E_OWNER_LEASE=1 HEIMDALL_E2E_OWNER_WORK_GRAPH_ONLY=1 node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/bridge_real_enroll_e2e.mjs
```

Real evidence: `tests/e2e/owner_local_work_graph_flow.ts:4` exercises draft proposal with no premature task rows, restart/exact replay, atomic decision/publication, blocked consumer claim, two real workers and independent reviewers, exact1→1 consumption receipt, stale completion rejection, exact work-revision completion, restart and stable decision/completion replay. Only throwaway services are restarted; no live deployment or push.

Final check commands and results are recorded in the task submission and completion note below.

### C1e final verification

All checks below passed, exit0. Final source branch retains no failing check or uncommitted implementation.

| Exact command | Result / evidence |
| --- | --- |
| `nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/c1e-v23-final207` |207 passed; `sh_4653a851a0b830eae333113205abccde`. Includes source-field/long-document, publication, cycles, statement/commit rollback, V22 migration, task/run mixed generations, structured manifests, consumed outputs, draft language/static expansion, submitted human gate, completion and restart. |
| `nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/c1e-v23-final30` |30 passed; same session. |
| `nix develop --command node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_local_contract_test.ts` |19 passed; `sh_2e2368111ae121849554935097452c6d`. |
| `nix develop --command npm run typecheck` |Pass; same session. Dependencies restored using `nix develop --command npm ci --ignore-scripts --no-audit --no-fund`, no lockfile changes. |
| `nix build .#ham-bridge .#ham-hub .#ham-ctl .#ham-pty-host -o $HOME/.cache/heimdall-tests/c1e-v23-final-bins` |All4 pass; `sh_23ef9be7541fa580ca66fe4dc3694e70`. |
| Exact final-bin relay command in the reproduction block above |All enrollment/isolation/owner scenario steps passed; `sh_d43d72352cb57c722fb9cba1c4c9335e`. |
| `python3 scripts/check-owner-aggregate-parity.py`, `git diff --check` |240 native fields /23 structs retain current original citations; whitespace clean. |

Checks deliberately not repeated: unrelated host/live deployment and broad external-service suites; all services in the actual proof are disposable. Final ordinary CLI/UI route convergence stays M4. Unrelated required OPEN/PARTIAL ledger items remain open.

Corrected dead ends: early fixtures used a different review lease ID, compared physical FTS rows across reopen, used the wrong metadata helper argument order and passed a string into Odin's source-location argument. A literal-brace `fmt.tprintf` expression produced invalid manifest formatting; the exact structured-output assertion caught it, and final207 verifies the corrected native manifest. Initial relay had no ready owner keyring; the standard isolated stop/restart initializes it. Initial typecheck lacked inherited pinned `posthog-js`; npm ci restored it without package changes. None of those initial failures are counted as final passing evidence.

## C1e independent-review corrections / attempt2

Independent review of `54de3e46` requested changes (`cmt_18e5921c618e87c8`). The earlier207-test evidence did not cover switch-to-draft admission or generation capture through the supported legacy dependency command. The findings were reproduced before implementation changes; this section supersedes the earlier readiness claim for those paths.

- `control_agent` applies `work_task_published` to the destination before recording a switch handoff or retiring the source (`src/lib/owner_local/controls.odin:203`). This requires both an active published chain and a published destination task, matching claim admission. Exact successful historical replay still follows existing read-authorization/receipt ordering.
- One ordered `UNION` enumerates active mixed edges and ordinary `local_dependencies` for both readiness and capture (`src/lib/owner_local/work_graph.odin:38`, `:44`, `:56`). Overlapping edge spellings produce one receipt; generated-stage private DAGs remain excluded. Existing generation/manifest checks and immutable source-sequence receipt identity remain authoritative.
- Ordinary claims and switch destinations capture that complete graph in the accepted transaction. Ordinary `lease.submit` also validates/captures effective inputs; existing receipt rows retain their original start sequence and manifest (`src/lib/owner_local/work_commands.odin:169`). No historical receipt is fabricated or overwritten.
- Six permanent signed regressions cover draft tasks, unpublished cross-chain destinations and later publication, legacy claim consumption, mixed/legacy overlap deduplication, statement/deferred-COMMIT rollback for claim and switch, unchanged source handoff/lease/attempt/event/outbox state on rejection, exact restart/replay, submit idempotence and producer reopen rejection. A dynamically added legacy edge retires the old consumer lease; the next attempt pins both prerequisite generations while the earlier receipt remains immutable (`src/lib/owner_local/work_admission_regression_test.odin:16`).
- The disposable actual relay removes the original active mixed edge, adds its legacy counterpart, and proves the legacy-only receipt and denied producer reopen. It also assigns/configures a draft switch target, rejects the real signed switch with `operation_conflict`, observes the unchanged source lease and zero destination attempts, then completes the original tasks across restart (`tests/e2e/owner_local_work_graph_flow.ts:39`).

Exact verification, all final checks exit0:

```bash
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/c1e-review-final213
nix develop --command npm run typecheck
nix build .#ham-bridge .#ham-hub .#ham-ctl .#ham-pty-host -o $HOME/.cache/heimdall-tests/c1e-review-final-bins
nix develop --command env HEIMDALL_E2E_HUB_BIN=$HOME/.cache/heimdall-tests/c1e-review-final-bins-1/bin/ham-hub HEIMDALL_E2E_BRIDGE_BIN=$HOME/.cache/heimdall-tests/c1e-review-final-bins/bin/ham-bridge HEIMDALL_E2E_CTL_BIN=$HOME/.cache/heimdall-tests/c1e-review-final-bins-2/bin/ham-ctl HEIMDALL_E2E_PTY_BIN=$HOME/.cache/heimdall-tests/c1e-review-final-bins-3/bin/ham-pty-host HEIMDALL_E2E_IDENTITY_BIN=$HOME/.cache/heimdall-tests/c1c-budget-identity HEIMDALL_E2E_OWNER_LOCAL=1 HEIMDALL_E2E_OWNER_LEASE=1 HEIMDALL_E2E_OWNER_WORK_GRAPH_ONLY=1 node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/bridge_real_enroll_e2e.mjs
python3 scripts/check-owner-aggregate-parity.py
git diff --check
```

Results:213 tests pass (`sh_cc7546684139850afbc2acdf73599162`); typecheck passes (`sh_82c178b34a8fefa06658819efe3f79b3`); all4 binaries build (`sh_e1c7f304c9c3d941785ad96d5ef0059f`); all actual relay/enrollment/isolation steps pass (`sh_449e1829ce8b1cbcbb33e5866d40af72`). Retain the previous30 Odin/19 TypeScript contract passes: this follow-up changes no wire schema or production TypeScript. The initial dynamic-edge regression expected an authorization error before prerequisite readiness; the existing readiness gate correctly returns `operation_conflict`, and its final expectation plus full213 pass records that ordering.

Only this review follow-up was changed; no migration rewrite, push, live restart or deployment. All unrelated required ledger OPEN/PARTIAL items remain open.
