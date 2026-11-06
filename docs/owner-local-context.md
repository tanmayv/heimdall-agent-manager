# Bridge-owned chain context

Owner-local context is a derived Bridge projection, separate from canonical
requirements, submissions, handoffs, reviews, workflow evidence and source
episodes. Compaction never deletes these records. No decrypted projection or
historical body is published to the owner registry on the Hub.

`chain.read` returns `context`. `requirements.present` returns `chain_summary`
and `context_provenance`; the actual owner Bridge atomically writes the current
task, chain, lease, instance, complete requirements, ACK observation, summary and
provenance into the launched child's `TASK.md`. A historical receipt replay returns
its original response and does not overwrite a newer context file. After a failed
write, the CLI reports `context_delivery_failed`: present requirements with a new
operation ID to retry delivery. Presentation does not ACK requirements.

The projection is at most **60 lines and 16384 UTF-8 bytes**, with individual
preview lines at most 512 bytes. Embedded newlines are normalized before counting;
one giant line cannot evade the byte budget. Actual file delivery also enforces
its 32000-byte limit. If essential content cannot fit, delivery fails explicitly
and preserves the last complete file. Current requirements are never silently cut.

Unresolved source episodes take priority, followed by a bounded task preview,
recent distinct handoff lessons and recent submissions. This is deterministic
structural compaction. The chain description remains separate canonical
coordinator input. Full facet/event parity and common product-route convergence
remain C1/M4 work; this change does not migrate a Hub-authoritative chain.

## Snapshot provenance and retrieval

`local_chain_context`, added by migration **010** after grants **008** and
workflows **009**, stores the latest derived version, algorithm version, exact
source checkpoint, source count, digest and bounded body. Materialization and
source observation share the existing authorized Store transaction. SHA-256
streams ordered source records, framing each kind/ref/body field with its
eight-byte little-endian length after a domain/account/chain/checkpoint prefix.
It does not allocate a JSON copy of the complete archive.

`freshness: "snapshot"` describes the supplied `source_seq`, not a promise that
a saved response stays current. An authenticated read regenerates after a source
commit; unchanged reads and a process restart reuse the same version. Read or
projection-write failure returns an error. No client supplies the checkpoint.

Use signed, **chain-scoped** `context.read` with the existing `read_payload`
shape (`cursor`, `limit`; limit is validated, but this method emits one source chunk
per response). In the owner-local panel select **Read full context evidence**,
then **Next evidence page**. The ordinary signed CLI relay accepts the same method.
Response fields are `source_kind`, `source_ref`, `body`, `offset`, `source_seq`,
`revision` (chain revision), `source_count` and `next_cursor` (empty at end).

Composite source refs are opaque JSON tuples, so legal colons in IDs cannot alias\ndifferent records. Concatenate chunks for each `(source_kind, source_ref)` before parsing its original
JSON. Chunks contain at most 8192 source bytes and preserve UTF-8 boundaries; the
complete response fits the existing 65536-byte encoded page budget. Reads allocate
one source record rather than the full archive. Cursor scope binds account, chain,
source checkpoint and position/offset. Mutation yields `stale_cursor`: restart
enumeration. Every page requires current read authorization. Vault lock and owner
unavailability retain existing fail-closed relay behavior.

The stream covers chain/task prose, comments, immutable requirements/submissions,
handoffs, reviews, workflow definitions/events, source episodes and consumption
evidence. It excludes lease credentials. New C1 canonical event/facet types must
extend `context_sources` and keep their originals fetchable.

## Legacy overflow remediation

The old Hub mechanical summary collected every immutable dead end but emitted
`summary_overflow` on each rebuild after 60 lessons. The suggested `summary set`
only edited curated notes and could not resolve that condition.

Normal history growth now produces a bounded preview without an alert. Original
legacy facets remain authoritative and fetchable:

```bash
ham-ctl task-chain graph CHAIN_ID
ham-ctl task fetch TASK_ID facet:TASK_ID:ATTEMPT:handoff
ham-ctl task fetch TASK_ID chain-summary
```

The last command retrieves separate unabridged curated input. Authenticated
summary GET/set responses also include `curated_notes` and `projection_state`.
`summary set` accepts at most 60 lines and 16384 input bytes; it does not rewrite
mechanical history. The Bridge bounds decrypted previews again for `TASK.md`.
Oversized vault tokens are omitted with retrieval advice rather than cut into
invalid ciphertext; originals remain unchanged.

Hub migration **203** persists curated input separately from the source-failure
fingerprint. An actual source-read failure marks the projection stale and queues
one actionable coordinator notification. Unrelated rebuilds, note edits and
restarts retain the edge. Successful materialization clears it, so a later failure
rearms attention. Diagnose storage health and retry after recovery; editing notes
cannot repair storage. Failed summary saves publish no successful update.

## Verification and rollout boundary

Regressions in `src/lib/context_compaction/context_test.odin`,
`src/lib/owner_local/context_test.odin`,
`src/hub/service/taskv2/summary_compaction_test.odin` and
`src/bridge/owner_local_context_test.odin` cover 100 lessons, oversized Unicode
sources, exact retrieval, current read authorization, snapshot invalidation,
restart, failed writes, migration collision/COMMIT rollback, ACK preservation,
alert persistence/rearm and actual atomic file budgets.

The disposable enrollment demo in `tests/e2e/bridge_real_enroll_e2e.mjs` exercises
real Hub/Bridge/CLI/PTY routes and reads the launched child's actual `TASK.md`.
Use the build/demo recipe in [owner-local-lifecycle.md](owner-local-lifecycle.md)
with owner-local, lease, lifecycle and workflow options enabled.

These changes are tested in isolation, **not deployed**. No live Hub/Bridge
restart or rollout is authorized by this task. The running legacy notification
storm is not claimed fixed until the tested code is deployed separately.
