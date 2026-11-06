# C1 final aggregate parity matrix

All 240 fields across 23 native aggregate structs have exact canonical storage, signed import/export and per-value comparison evidence. The frozen rich fixture covers complete brief policy, original author/time/ID/version data, placement and unresolved typed artifact/message references. Independent review is pending. Import never activates leases, membership, directories, dispatch or workflow execution.

## Native data matrix

Each row expands field by field in `docs/owner-local-aggregate-parity.md` and `docs/owner-local-parity-evidence.json`. The executable proof compares every key/value/type after bounded signed export and restart. Original history bytes, Unicode, integer precision and tuple identity remain exact.

| Original struct | Original fields | Canonical storage / export |
| --- | --- | --- |
| `Task_Chain` | `chain_id`, `owner_user_id`, `title`, `description`, `publish_state`, `status`, `kind`, `coordinator_agent_instance_id`, `defaults_json`, `work_revision`, `completion_summary`, `last_activity_at`, `last_title_nudge_at`, `title_source`, `created_at`, `updated_at`, `published_at`, `completed_at`, `is_pinned`, `pinned_at` | `native_fact_chain` / `native.metadata.read` |
| `Task` | `task_id`, `chain_id`, `owner_user_id`, `title`, `description`, `publish_state`, `state`, `kind`, `priority`, `attempt_no`, `brief_json`, `blocked_on_json`, `requires_user_approval`, `ready_since`, `bridge_id`, `workflow_run_id`, `workflow_execution_no`, `stage_key`, `stage_index`, `generated_by_json`, `created_at`, `updated_at`, `published_at`, `started_at`, `completed_at` | `native_fact_task` / `native.metadata.read` |
| `Task_Comment` | `delegated_client_id`, `delegated_grant_id`, `comment_id`, `task_id`, `chain_id`, `owner_user_id`, `author_agent_instance_id`, `body`, `created_at`, `updated_at` | `native_fact_comment` / `native.metadata.read` |
| `Task_Chain_Member` | `chain_id`, `agent_instance_id`, `agent_id`, `owner_user_id`, `role`, `created_at` | `native_metadata_members` / `native.metadata.read` |
| `Task_Dependency` | `task_id`, `depends_on_task_id`, `chain_id`, `owner_user_id`, `created_at` | `native_record_values` / `native.metadata.read` |
| `Task_Chain_Directory` | `directory_id`, `chain_id`, `owner_user_id`, `path`, `bridge_id`, `vcs_kind`, `vcs_info_json`, `created_at`, `updated_at` | `native_metadata_directories` / `native.metadata.read` |
| `Fleet_Bridge_Model` | `provider_profile`, `provider`, `model` | `native_fleet_policies` / `native.metadata.read` |
| `Task_Chain_Fleet` | `provider_profile`, `task_chain_id`, `agent_id`, `capacity`, `min_warm`, `idle_ttl_seconds`, `bridge_models_json`, `provider`, `model`, `roles_json`, `bridge_id`, `paused_roles_json`, `created_at`, `updated_at` | `native_fleet_policies` / `native.metadata.read` |
| `Task_Event` | `event_id`, `task_id`, `chain_id`, `owner_user_id`, `ts_ms`, `actor_kind`, `actor_id`, `kind`, `payload_json` | `native_history_records` / `native.history.read/fetch` |
| `Task_Attempt` | `task_id`, `attempt_no`, `chain_id`, `owner_user_id`, `started_at`, `ended_at`, `holder_instance_id`, `outcome`, `counts_toward_budget` | `native_history_records` / `native.history.read/fetch` |
| `Task_Attempt_Facet` | `task_id`, `attempt_no`, `chain_id`, `owner_user_id`, `kind`, `v`, `body_json`, `writer`, `written_at` | `native_history_records` / `native.history.read/fetch` |
| `Task_Lease` | `provider_profile`, `lease_id`, `task_id`, `chain_id`, `owner_user_id`, `attempt_no`, `holder_instance_id`, `kind`, `review_role`, `bridge_id`, `provider`, `model`, `granted_at`, `confirmed_at`, `expires_at`, `hard_deadline_at`, `last_beat_at`, `delivery`, `extended_at` | `native_record_values` / `native.metadata.read` |
| `Task_Review` | `task_id`, `chain_id`, `owner_user_id`, `attempt_no`, `role`, `reviewer_kind`, `reviewer_agent_id`, `reviewer_instance_id`, `verdict`, `findings_json`, `created_at` | `native_record_values` / `native.metadata.read` |
| `Chain_Summary` | `curated_body`, `curated_initialized`, `failure_fingerprint`, `chain_id`, `owner_user_id`, `body`, `line_count`, `version`, `updated_at` | `native_fact_summary` / `native.metadata.read` |
| `Workflow_Definition` | `def_id`, `owner_user_id`, `name`, `version`, `body_json`, `created_at` | `native_record_values` / `native.metadata.read` |
| `Workflow_Run` | `run_id`, `chain_id`, `owner_user_id`, `title`, `definition_ref`, `spec_json`, `inputs_json`, `current_execution_no`, `request_id`, `request_hash`, `created_by_kind`, `created_by_id`, `created_at`, `updated_at`, `revision` | `native_work_records` / `native.metadata.read` |
| `Workflow_Run_Execution` | `run_id`, `execution_no`, `chain_id`, `owner_user_id`, `state`, `resolved_inputs_json`, `started_at`, `ended_at`, `failure_code`, `failure_detail`, `output_manifest_json`, `revision` | `native_work_records` / `native.metadata.read` |
| `Workflow_Stage_Execution` | `run_id`, `execution_no`, `stage_key`, `chain_id`, `owner_user_id`, `item_count`, `expanded_at` | `native_work_records` / `native.metadata.read` |
| `Workflow_Run_Event` | `event_id`, `run_id`, `execution_no`, `chain_id`, `owner_user_id`, `ts_ms`, `actor_kind`, `actor_id`, `kind`, `payload_json` | `native_work_records` / `native.metadata.read` |
| `Work_Item_Ref` | `kind`, `id` | `native_work_records` / `native.metadata.read` |
| `Work_Dependency` | `dependency_id`, `chain_id`, `owner_user_id`, `dependent`, `prerequisite`, `created_by_kind`, `created_by_id`, `created_at`, `removed_at`, `removed_by_kind`, `removed_by_id`, `removal_reason` | `native_work_records` / `native.metadata.read` |
| `Work_Input_Receipt` | `receipt_id`, `chain_id`, `owner_user_id`, `dependent`, `dependent_generation`, `prerequisite`, `prerequisite_generation`, `output_manifest_json`, `created_at` | `native_work_records` / `native.metadata.read` |
| `Work_Scope_Decision` | `decision_id`, `chain_id`, `owner_user_id`, `item`, `action`, `reason`, `actor_kind`, `actor_id`, `created_at` | `native_work_records` / `native.metadata.read` |

## Operational and security proof

Accepted signed operations cover publication/proposals, mixed and ordinary dependencies, generation receipts, claims/switches, all 12 brief keys, typed pinned input context, structured output, named/role/human review, controls/merge recovery, metadata/fleet policy, workflows/output prerequisites, scoped search/context and exact historical replay. Authorization remains ahead of history lookup.

The new rich proof submits validated output, triggers a follow-up workflow, and proves independent approval cannot bypass the submitted human gate. Canonical live prose/output stays searchable. Exact source exports and materialized context are preserved after live mutations and restart.

V24 supplies the four remaining strict native source adapters: `Task_Lease`, `Task_Review` with verbatim findings, `Workflow_Definition`, and `Task_Dependency`. Typed JSON tuples distinguish composite IDs that collide under colon concatenation. Bounded snapshot cursors support long review identities. Statement/COMMIT rollback, read revocation, account/chain/cursor isolation and genuine V23 migration rollback retain live capabilities.

## Approved external milestones

Coordinator decision `cmt_18e592e4d810d71a` confirms accepted C1a-C1e operational families and only these remaining milestones. They are not preservation waivers.

| Milestone | Remaining work |
| --- | --- |
| `C3` | Artifact/message bodies, envelopes/blobs and their body indexes. Typed IDs, pinned versions, provenance and explicit unresolved/import_pending references are canonical and tested. |
| `M3` | Automatic dispatch, provider catalog launchability and slot reservation. Fleet policy, exact-child admission and original placement records are canonical and tested. |
| `M4` | Primary UI/CLI legacy route convergence and live database cutover. Accepted C1a-C1e signed operational families stay canonical; historical pin/status/title-nudge labels are preserved exactly by source import/export, not fabricated from new state. |

## Review files

- `src/contracts/fixtures/owner-native-aggregate.json`: frozen original documents, exact tuple bindings and complete brief.
- `src/lib/owner_local/aggregate_test.odin`: all-value export/restart, live policy, rollback/isolation and migration proofs.
- `tests/e2e/owner_local_aggregate_flow.ts`: enrolled disposable Hub/Bridge/CLI/PTY proof using exact large-integer tokens.
- `scripts/check-owner-aggregate-parity.py`: fail-closed field, fixture, route/storage and evidence gate.

## Reproduce the chosen checks

Run these commands in the assigned worktree:

```bash
cd /var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad5a65c6c86
python3 scripts/check-owner-aggregate-parity.py
python3 tests/test_owner_aggregate_parity_gate.py
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/c1f-v24-full218
nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/c1f-final-contracts31
nix develop --command npm run typecheck
nix develop --command node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_local_contract_test.ts
nix build .#ham-bridge .#ham-hub .#ham-ctl .#ham-pty-host -o $HOME/.cache/heimdall-tests/c1f-v24-bins
nix develop --command env HEIMDALL_E2E_HUB_BIN=$HOME/.cache/heimdall-tests/c1f-v24-bins-1/bin/ham-hub HEIMDALL_E2E_BRIDGE_BIN=$HOME/.cache/heimdall-tests/c1f-v24-bins/bin/ham-bridge HEIMDALL_E2E_CTL_BIN=$HOME/.cache/heimdall-tests/c1f-v24-bins-2/bin/ham-ctl HEIMDALL_E2E_PTY_BIN=$HOME/.cache/heimdall-tests/c1f-v24-bins-3/bin/ham-pty-host HEIMDALL_E2E_IDENTITY_BIN=$HOME/.cache/heimdall-tests/c1c-budget-identity HEIMDALL_E2E_OWNER_LOCAL=1 HEIMDALL_E2E_OWNER_LEASE=1 HEIMDALL_E2E_OWNER_AGGREGATE_ONLY=1 node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/bridge_real_enroll_e2e.mjs
git diff --check
```

All commands were executed through managed `ham-ctl shell run --cwd <worktree> --cmd ...`. Dependency restoration used `nix develop --command npm ci --ignore-scripts --no-audit --no-fund`, with no lockfile changes.

| Check | Recorded result |
| --- | --- |
| Parity gate | PASS: 240 original fields, 23 structs, exact fixture/storage/routes/proof anchors, 73 signed device methods and documented child methods. |
| Gate regression tests | 7 PASS, including missing source value, invented storage, partial row, uncovered method, missing brief key and unapproved milestone rejection. Session `sh_967909c74048c088da4db18cda2d25a5`. |
| Owner-local suite | 218 PASS, including all five new rich/security/migration/inventory tests. Session `sh_c9802e1ac253708a03c3584c08d44d89`. |
| Contracts | 31 PASS. Session `sh_e0a804e8fb9bf46fb50eb259fcbe5edd`. |
| TypeScript / UI contracts | Typecheck PASS; 20 tests PASS. Session `sh_ffeef6f813db6e673d17c395ab4b2a98`. |
| Production binaries | Bridge, Hub, CLI and PTY build PASS. Session `sh_bcafcff034da24c3fbd8a6c0e36624ea`. |
| Actual enrolled relay | Rich aggregate branch, account isolation, ordinary signed operations, replay and restart PASS; complete driver exits 0, all steps PASSED. Session `sh_e4d4cec7081c219232785d94e8e3baae`. |

The fixture uploads exact raw metadata documents. Its comparison reviver preserves unsafe integer tokens as `BigInt`; native history is reassembled across bounded UTF-8 chunk boundaries and compared byte-for-byte. Imported archival facts never create operational leases, runs, policy, members or assignments. Live command proof creates fresh authorized state separately.

## Review boundary and decisions

Independent review is required before C1 acceptance. This report does not claim review approval or live cutover. No push, production restart, deployment, live data migration or external body resolution was performed.

- Additive V24 leaves V1–V23 migrations unchanged. V23 test teardown is updated only to reconstruct genuine old schemas; current-version expectations become 24.
- Composite identities are typed JSON arrays. Existing persisted V23 record keys are not rewritten; reads use stored keys, preserving historical cursors and receipts. New four-kind immutable snapshots use bounded offset cursors bound to account, chain, source, kind and digest.
- Full original source ownership is retained independently of the current account that authorizes import. Historical pin/title/status metadata remains exact source evidence, without fabricating operational transitions.
- Archival facet text is preserved and fetchable; the search proof checks canonical live comment/output projections. C3 body indexes remain explicit.
- Nearby maintenance is limited to current-schema test expectations and removal of an unused import.

Initial draft failures were corrected before submission: Odin test syntax/map-header propagation, a duplicate operation ID, stale current-schema 23 expectations, an invalid test-only grant table name, and parity-script quoting. An initial archival-facet full-text expectation was replaced with the correct live-output projection check; no unsupported indexing claim remains.

## Exact modified paths

- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad5a65c6c86/docs/owner-local-aggregate-parity.md`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad5a65c6c86/docs/owner-local-final-parity.md`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad5a65c6c86/docs/owner-local-parity-evidence.json`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad5a65c6c86/scripts/check-owner-aggregate-parity.py`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad5a65c6c86/src/contracts/fixtures/owner-native-aggregate.json`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad5a65c6c86/src/contracts/owner_aggregate_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad5a65c6c86/src/contracts/owner_metadata.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad5a65c6c86/src/contracts/owner_metadata_facts.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad5a65c6c86/src/lib/owner_local/aggregate_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad5a65c6c86/src/lib/owner_local/context_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad5a65c6c86/src/lib/owner_local/controls_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad5a65c6c86/src/lib/owner_local/fleet_policy_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad5a65c6c86/src/lib/owner_local/foundations_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad5a65c6c86/src/lib/owner_local/grants_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad5a65c6c86/src/lib/owner_local/migration_023_test_drop.sql`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad5a65c6c86/src/lib/owner_local/migration_024.sql`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad5a65c6c86/src/lib/owner_local/migrations.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad5a65c6c86/src/lib/owner_local/native_metadata.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad5a65c6c86/src/lib/owner_local/search_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad5a65c6c86/src/lib/owner_local/work_native.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad5a65c6c86/src/ui/api/ownerLocal.ts`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad5a65c6c86/tests/e2e/owner_local_aggregate_flow.ts`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad5a65c6c86/tests/e2e/owner_local_flow.ts`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad5a65c6c86/tests/test_owner_aggregate_parity_gate.py`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e57ad5a65c6c86/tests/ui_owner_local_contract_test.ts`
