# Durable task ownership cutover and verification

Task ownership persists through elapsed time, submission, review and external waits. Explicit release, cancellation and transfer control ownership; transfer fences the former writer and waits for an authenticated process-generation stop receipt before replacement execution.

## Storage and cutover

Migration 203 adds one active/waiting phase column to existing task_leases. No tables or generation-counter records are added. Current generation is the latest existing task event ID, read with an owner-scoped reverse indexed lookup returning one scalar. Errors fail closed.

Migration 203 clears legacy expiry/deadline values and snapshots legacy in-review tasks missing worker ownership into existing task_events. Boot restores an eligible, free previous holder as waiting, or records an ownership-repair diagnostic. It never steals another task's holder or restarts a deliberately stopped worker. Historical attempts, facets and reviews remain unchanged. Each conversion candidate gets a pending event and a checked event once; explicit release after conversion is not undone at later boot.

The SQL conversion is transactional. Retrying after the phase column exists but before the migration ledger is recorded reruns only the idempotent data conversion. Do not run old and new task schedulers concurrently.

## Operator cutover

1. Quiesce legacy dispatch and writers. Back up the database and record the deployed revision.
2. Install compatible Hub, Bridge, CLI and generated agent instructions together.
3. Run migration and boot reconciliation before enabling dispatch.
4. Inspect retained active/waiting owners and ownership_repair diagnostics. Resolve collisions explicitly; never choose a winner by timestamp.
5. Verify stop-pending cleanup through authenticated Bridge receipts. An offline Bridge remains pending.
6. After new-format writes, prefer forward repair. A downgrade is not validated: restoring an older snapshot would discard new work and is not an acceptable automatic rollback.

This change has not been deployed. No production database conversion or real multi-host cutover was performed.

## Acceptance evidence map

Paths below are relative to src/hub/service/taskv2 unless otherwise stated. Final commands and outcomes are recorded in the task submission and verification artifact.

| Check | Concrete coverage |
|---|---|
| CHECK-1 | durable_ownership_test.odin: elapsed-time/no-heartbeat ownership test |
| CHECK-2 | durable_ownership_test.odin: review/rework fencing and unrelated assignment exclusion |
| CHECK-3 | explicit_claims_test.odin; integrated_controls_test.odin: revoked worker/reviewer writes |
| CHECK-4 | durable_ownership_test.odin: boot, reconnect, exit and intentional stop; coordinator_controls_test.odin: inspection |
| CHECK-5 | coordinator_controls_test.odin, recheck_test.odin, m3b_test.odin; tests/task_controls_cli_smoke.py routes ten controls and claim/transfer/recover through the actual CLI to an isolated endpoint |
| CHECK-6 | integrated_controls_test.odin: stale competing transfer and retry without duplicate effects |
| CHECK-7 | coordinator_controls_test.odin: repairs do not approve; override preserves obligations and cannot synthesize success |
| CHECK-8 | requirements_runtime_test.odin and solo_test.odin: stale review invalidation and self-review refusal |
| CHECK-9 | legacy_claim_conversion_test.odin, durable_ownership_test.odin; src/hub/repository/sqlite/durable_claim_migration_test.odin |
| CHECK-10 | pack_dependencies_test.odin, src/bridge/taskv2_dependencies_render_test.odin; tests/ui_task_v2*_test.ts and tests/ui_ticket_board_test.ts; shipped prompt/source search |
| CHECK-11 | coordinator_controls_test.odin and integrated_controls_test.odin: cancellation state matrix, history, offline cleanup, late receipts, merge races; m3b_test.odin: workflow cancellation |
| CHECK-12 | explicit_claims_test.odin: status-derived identity/role and mismatch refusal |
| CHECK-13 | explicit_claims_test.odin: cross-Bridge identity, repeated claim and competing instance refusal |
| CHECK-14 | explicit_claims_test.odin; src/bridge/agent_api_taskchain_publish_test.odin: named target and context isolation |
| CHECK-15 | explicit_claims_test.odin and integrated_controls_test.odin: exact stop receipt, wrong Bridge/failed receipt refusal, offline stop and late callback fencing |

CLI smoke checks validate serialization/routing and refusal propagation against an isolated endpoint; service/Bridge tests validate transition behavior. They are not a production CLI-to-Hub deployment test. A stopped runtime projection alone is not trusted as proof of exit: one generation-specific receipt is required, and confirmed retries issue no redundant stop.

## Known unrelated failure

The HTTP suite has the previously reproduced test_extension_update_replays_discovery_but_not_duplicate_followups fixture failure (expected count 4, actual 5). Report this as a failed test, not as a fully green HTTP suite. Existing HTTP allocation warnings and UI server-rendering warnings remain outside this task's scope.
