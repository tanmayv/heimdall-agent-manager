# Bridge event-ledger operations

The bridge keeps `event-ledger-v1.json` beside its agent token store. The filename
is historical: a valid v1 snapshot is imported and atomically replaced with a v2
checkpoint at the first mutation. V2 has one compact JSON checkpoint line followed
by newline-terminated transition records. Begin is fsynced before an effect runs.
Pruned IDs are included in the next durable transition; checkpoints retain every
entry still inside its deduplication horizon.

## Health and delivery errors

The authenticated loopback `GET /bridge/health` response includes `event_ledger`:

| Status | Meaning | Recovery |
| --- | --- | --- |
| `ready` | Known state; writes are available. | None. |
| `full` | Admission has reached 4,096 entries. Existing entries remain usable. | Wait for expiry plus the safety margin; do not delete retained entries. |
| `checkpoint_pending` | A transient append/checkpoint failed; memory remains known. | Repair disk space, permissions or storage. The next mutation checkpoints automatically, without restarting. |
| `unavailable` | Startup could not read or validate durable state. | Preserve and repair the file, then restart the bridge to reload it. |

The top-level `ok` remains the loopback liveness indication. Health requires the
same Authorization credential as other loopback routes; do not publish it.
Delivery results distinguish `ledger_unavailable` (I/O/corrupt state) from
`ledger_full` (capacity), including retry/final failures.

## Repair

1. Inspect health and bridge logs. For `checkpoint_pending`, repair storage and
   allow the next delivery to retry; the bridge atomically replaces any ambiguous
   tail with its known memory state.
2. For `unavailable`, stop that profile's bridge service before editing anything.
   Make a byte-for-byte backup of the ledger and preserve its owner-only access.
   Fix access permissions or storage errors first, then restart and recheck health.
3. A final incomplete record after a valid checkpoint is recovered automatically.
   The next mutation replaces the incomplete tail with an atomic checkpoint.
   A malformed complete record or checkpoint is not automatically discarded.
   Inspect it against the backup; repair only damage whose correct contents are
   known. Truncate only an incomplete final append, never a complete committed
   record. Restart to reload after an operator repair.
4. If the correct retained history cannot be reconstructed, keep the bridge
   stopped and escalate. Discarding or restoring an older ledger can repeat
   already-performed effects. A deliberate reset requires an operator explicitly
   accepting that loss of the dedup horizon; it is not routine recovery.

The retention horizon is expiry plus ten minutes, or a 48-hour fallback without
expiry. A restored older journal and a backward wall-clock step can expose more
than 4,096 retained entries. Those entries remain readable and completable;
admission of new IDs stays closed until pruning lowers the count.

## Binary rollback

Do not start a v1-only bridge against a v2 ledger. Older readers quarantine the
file and start empty, which can duplicate effects. Roll back only to a binary
that supports the v2 reader (or backport that reader first). Keep the current
ledger through rollback; restoring a pre-upgrade backup omits newer effects and
also loses deduplication. The installer snapshots binaries, not a safe historical
replacement for live effect records.


## Inbox scheduling and subscription retirement

The inbox runtime waits for subscription changes, catalog publications for watched
scopes, agent activity changes, and the earliest cooldown or redelivery deadline.
It makes no subscription queries or JetStream API calls while idle between wakes.
A slow safety reconciliation recovers missed signals and external database edits;
its default is 300 seconds. Configure it with
`HEIMDALL_EVENT_INBOX_RECONCILE_SECONDS` or
`--event-inbox-reconcile-seconds` (1–86400 seconds).

Migration `events_009_incremental_inbox.sql` retires automatic subscriptions on
completed, cancelled, and archived chains, including existing rows. Explicit
watches survive completion and cancellation; archiving removes them. Every
retirement queues a durable JetStream consumer deletion, retried on reconnect.
Reopening a chain recreates current role defaults, starting from the reopen time;
it does not recreate explicit watches removed by archiving.

The durable max-delivery advisory stream also has a core subscription used only
as a wake hint. An Odin-owned waiter receives hints without polling the server;
the runtime reads and acknowledges durable advisories in bounded batches.
A full batch signals immediate continuation, including for advisories queued
before startup. Disconnect unsubscribes the hint and joins its waiter before
destroying any subscription or connection.
