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

## Narrowed acceptance scope\n\nThe later user instruction replaces the broad CHECK-1..15 coordinator-control matrix with non-expiring ownership, cancel, claim and transfer. Administrative override, generic inspection/control and re-review additions are removed. Retained coverage verifies elapsed-time persistence; review/rework and blocked ownership; legacy conversion/history/idempotency; identity and cross-Bridge claims; cancellation across states and late callbacks; exact stop receipts and competing transfers; simplified CLI routing; and waiting-owner UI.\n\nTests use service/Bridge fixtures and an isolated CLI endpoint. No production multi-host cutover was performed. Final commands, counts and baseline failures are recorded in the replacement task submission.\n\n## Known unrelated failure

The HTTP suite has the previously reproduced test_extension_update_replays_discovery_but_not_duplicate_followups fixture failure (expected count 4, actual 5). Report this as a failed test, not as a fully green HTTP suite. Existing HTTP allocation warnings and UI server-rendering warnings remain outside this task's scope.
