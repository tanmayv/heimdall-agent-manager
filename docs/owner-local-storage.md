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

Backward clock observations block new mutations and claims; reads and receipt
replay remain available. Clock high watermarks never decrease. `reconcile_clock`
requires the current incarnation, expected clock generation, and a trusted time
at or beyond the durable watermark; it advances the generation atomically. It
cannot extend an execution deadline. Full agent capabilities, fleet/lease/review
folds and execution-fence admission are M1c; workflows and search are M2.

Integration entrypoints (all paths relative to the repository):

| API | Contract |
| --- | --- |
| `src/lib/owner_local/store.odin:41` `open` | Hold the profile writer lock, check identity before migration, apply version 2 atomically, advance incarnation and recover abandoned claims. Caller provides a private directory and closes only after request/delivery workers drain. |
| `src/lib/owner_local/migrations.odin:10` `migrate` | Transactional V1 upgrade; existing canonical rows, receipt results and signed publication bytes survive. Unsupported future versions or orphaned intent provenance reject startup. |
| `src/lib/owner_local/directory.odin:26` `verify_directory`, `:10` `observe_directory` | Verify paired root/enrollment/keyring and persist the monotonic security pin before execution. |
| `src/lib/owner_local/store.odin:99` `execute` | Current read authorization under the UoW, exact receipt/tombstone digest lookup, then live miss admission. Returns success only after commit. |
| `src/lib/owner_local/transaction.odin:14` `transaction_begin`, `:31` `transaction_savepoint`, `:41` `transaction_commit`, `:53` `transaction_rollback` | Thread-bound, explicit nested UoW. A same-thread nested begin fails; use a savepoint. SQL/cryptography only inside the transaction. Failed rollback quarantines uncertain connection state until reopen. |
| `src/lib/owner_local/outbox.odin:20` `intent_enqueue` | Enqueue under the current UoW after inserting its source receipt. One immutable effect per principal/operation/kind/destination. A repeated enqueue must match payload digest, fence and sequence. |
| `src/lib/owner_local/outbox.odin:36` `intent_claim_due`, `:64` `intent_result` | Claim at most 20 due effects, perform I/O outside the UoW, then settle or schedule retry with the exact claim. Claim failure returns no work. Unknown external outcomes must be queried/retried using the same ID. |
| `src/lib/owner_local/retention.odin:18` `compact_receipts`, `:42` `reconcile_clock` | Bounded maintenance and trusted local clock-recovery APIs; neither is remotely exposed as a user command. |
| `src/bridge/owner_local.odin:33` `bridge_owner_publish` | Existing request-driven registry publication now uses durable claims and fenced results. The signer at `src/bridge/unseal_protocol.odin:848` uses only the already-loaded identity. |

M1c must add the actual agent capability/fence contracts, local pinned instance
and configuration inputs, lease/fleet/review schema and guards, matching/gates,
and periodic outbox startup/drain integration. Before using receipt compaction
with executions, extend its retention pin to every active execution related to
the operation; V1 has no executions. This foundation recovers pending work when
the store opens and retries registry publication on requests; it does not add a
background scheduler or change Hub authority routes. M2 supplies workflow schema,
search and deletion/retention policies for the expanded aggregate. Remote
execution consumers must prove fence/deadline validity and exact effect
deduplication before acting; a replay result is never a launch authorization.

Focused evidence lives beside the implementation in `store_test.odin` and
`foundations_test.odin`. `tests/helpers/owner_local_storage_probe/main.odin` plus
`tests/test_owner_local_storage_recovery.py` provide real process-kill checks:
SIGKILL immediately before SQLite commit, immediately after commit before reply,
and after a durable outbox claim. The driver checks integrity, foreign keys,
exact row counts, replay and stable recovered effect identities.
