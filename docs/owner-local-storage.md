# Owner-local storage foundations

M1b extends the V1 device API without changing its signed wire format. One
`Store` serves one account, owner identity and database under a lifetime SQLite
writer lock. Schema upgrades and version markers commit together before serving.
Unknown future schema versions fail closed. Database identity, owner and account
cannot be changed; restart increments the incarnation. This does not authorize
restoring a stale backup or promoting a copy.

Transactions serialize on the store mutex. `begin`, `commit` and `rollback` form
the internal unit of work; nested candidates use savepoints. An unsuccessful
commit rolls back. SQL state, receipt, local change and outbox insertions belong
to the same transaction. The signer callback must be local pure cryptography;
network, process and filesystem side effects run only after commit.

The Bridge persists each verified paired directory with `observe_directory`
before executing a command. This security pin survives rejected commands, so a
later replay cannot roll back observed device revocation. `execute` requires the
same pinned version/hash under its transaction. Receipt replay itself does not
change any rows.

Command order remains current signed identity/read authorization, receipt/digest
lookup, retired-operation lookup, then live admission. Historical replay has no
mutation, clock or request-expiry requirement. Receipt bodies may be compacted
only after 30 days and after all intents attached to that receipt settle. The
retained tombstone rejects identical retries as `retired`, changed input as
`operation_conflict`. Receipts plus tombstones share the 100,000 operation quota;
compaction never frees deduplication capacity. At capacity new writes fail as
`retention_capacity`. Read requests do not allocate receipts.
Legacy V1 receipts conservatively start their retention age at request expiry,
because V1 did not record commit time; upgrade cannot prematurely retire them.

The outbox stores immutable intent identity, source principal/operation, kind,
destination, exact fence, payload and digest. Claiming commits an attempt counter
and the current writer incarnation before returning work. A result must match
that incarnation and attempt. Unknown outcomes stay retryable with the same
intent ID and payload; a consumer must deduplicate by those values. Claiming does
not guarantee exactly-once external I/O. On restart, abandoned claims return to
pending; an obsolete callback cannot settle a new claim. Registry publication
uses the existing signed revision-idempotent Hub receiver. Future launch/stop
consumers must additionally revalidate their exact execution fence.

Delivery owners must retain external outcomes until result persistence succeeds.
`Intent_Completions` holds at most one 20-item batch, cloning only claim IDs,
digests and bounded results into a process-lifetime allocator. Flush this queue
before claiming another batch. A temporary result write or commit failure keeps
the original fenced completion for a later request; it does not repeat network
I/O. A durable claim recheck discards obsolete completions without overwriting a
new attempt or settled result. Process death still uses the durable abandoned
claim recovery described above. The queue must be serialized with its store;
destroy it only after delivery workers drain or the process shuts down.

Backward clock observations block new mutations and claims; reads and receipt
replay remain available. Clock high watermarks never decrease. `reconcile_clock`
requires the current incarnation, expected clock generation, and a trusted time
at or beyond the durable watermark; it advances the generation atomically. It
cannot extend an execution deadline. Full agent capabilities, fleet/lease/review
folds and execution-fence admission are M1c; workflows and search are M2.

Integration entrypoints (all paths relative to the repository):

| API | Contract |
| --- | --- |
| `src/lib/owner_local/store.odin:41` `open` | Hold the profile writer lock, check identity before migration, create the flat schema on a new database (other versions refused), advance incarnation and recover abandoned claims. Caller provides a private directory and closes only after request/delivery workers drain. |
| `src/lib/owner_local/migrations.odin` `migrate` | Flat schema: a new database gets `schema.sql` at `SCHEMA_VERSION` in one transaction. A pre-release store at any other version rejects startup and must be recreated. Until a release users run owner chains on ships, change the schema in place and bump `SCHEMA_VERSION` with `runtime_database.schema_version`; after that, add numbered migration steps from this baseline. |
| `src/lib/owner_local/directory.odin:26` `verify_directory`, `:10` `observe_directory` | Verify paired root/enrollment/keyring and persist the monotonic security pin before execution. |
| `src/lib/owner_local/store.odin:100` `execute` | Current read authorization under the UoW, exact receipt/tombstone digest lookup, then live miss admission. Returns success only after commit. |
| `src/lib/owner_local/transaction.odin:14` `transaction_begin`, `:31` `transaction_savepoint`, `:41` `transaction_commit`, `:53` `transaction_rollback` | Thread-bound, explicit nested UoW. A same-thread nested begin fails; use a savepoint. SQL/cryptography only inside the transaction. Failed rollback quarantines uncertain connection state until reopen. |
| `src/lib/owner_local/outbox.odin:20` `intent_enqueue` | Enqueue under the current UoW after inserting its source receipt. One immutable effect per principal/operation/kind/destination. A repeated enqueue must match payload digest, fence and sequence. |
| `src/lib/owner_local/outbox.odin:36` `intent_claim_due`, `:64` `intent_result` | Claim at most 20 due effects, perform I/O outside the UoW, then settle or schedule retry with the exact claim. Claim failure returns no work. Unknown external outcomes must be queried/retried using the same ID. |
| `src/lib/owner_local/completions.odin:22` `intent_completion_keep`, `:58` `intent_completions_flush`, `:37` `intent_completions_destroy` | Retain and retry fenced result persistence across requests. Flush before claiming another batch; storage failure keeps ownership in memory, and restart recovers the persisted claim. |
| `src/lib/owner_local/retention.odin:18` `compact_receipts`, `:45` `reconcile_clock` | Bounded maintenance and trusted local clock-recovery APIs; neither is remotely exposed as a user command. |
| `src/bridge/owner_local.odin:35` `bridge_owner_publish`, `:41` `bridge_owner_publish_batch` | Request-driven registry publication retains completions and retries persistence before further delivery. The signer at `src/bridge/unseal_protocol.odin:848` uses only the already-loaded identity. |

M1c adds the minimal one-device fleet/configuration, exact-child lease capability,
claim/heartbeat and periodic expiry/outbox worker described in
[owner-local-leases.md](owner-local-leases.md). Current configuration receipts and
all active lease-related receipts are pinned before compaction. The broader
task/review/ACK/gate and workflow schema remains outside this lease slice.
Search and expanded deletion/retention policies follow separately. Remote
execution consumers must prove fence/deadline validity and exact effect
deduplication before acting; a replay result is never a launch authorization.

Focused evidence lives beside the implementation in `store_test.odin` and
`foundations_test.odin`. `tests/helpers/owner_local_storage_probe/main.odin` plus
`tests/test_owner_local_storage_recovery.py` provide real process-kill checks:
SIGKILL immediately before SQLite commit, immediately after commit before reply,
and after a durable outbox claim. The driver checks integrity, foreign keys,
exact row counts, replay and stable recovered effect identities.
`src/bridge/owner_local_delivery_test.odin:37` exercises the production delivery
batch with HTTP503/200 outcomes and both result-write and deferred-FK commit
failures, followed by storage recovery and eventual settlement without reopening
the store or repeating a successful POST.

V7 adds local control modes, immutable signed assignment and work-attempt
history, handoff/search producers, exact-child notices, one-shot held checkpoints
and merge-intent invalidation. V6 live leases/receipts and immutable submission
attempts are preserved; see [owner-local-controls.md](owner-local-controls.md).

V8 adds the bounded static workflow generation/dependency graph, immutable required
review pairs, exact source episodes/results and pending-card receipt pins in this
same Store. See [owner-local-workflows.md](owner-local-workflows.md) for the command
contract, cold recovery rules and remaining mandatory parity gates.
