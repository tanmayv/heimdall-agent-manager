# Owner-local controls and assignment

This extends the running-local-child, named author/reviewer lifecycle.
Required additional role pairs and static workflow/source integration are now
covered by [owner-local-workflows.md](owner-local-workflows.md).
There is no scheduler for unlaunched agents and no remote owner transfer.
See [owner-local-lifecycle.md](owner-local-lifecycle.md) for setup and independent
review, and [owner-local-search.md](owner-local-search.md) for scoped search.

## Device controls

Use the owner panel's **Read runtime** to obtain the task revision and current
control mode. Every control signs that exact task revision; a stale request
fails without changing the task. **Retry same operation** replays the stored
historical result, after current read authorization, without reissuing effects.
The panel can export its sealed signed operation for the real CLI:

```bash
ham-ctl task-chain owner-local relay --request-file owner-local-request.json
```

The CLI transport token does not authorize a device control.

| Panel control / signed method | Behavior |
| --- | --- |
| Hold task / `task.hold` | Save the current review/ready state, revoke current lease/session authority, and enqueue exact-child checkpoint notices. |
| Release hold / `task.release` | Restore the saved state; old capabilities remain retired. A new claim/review session is required. |
| Cancel task / `task.cancel` | Revoke authority, invalidate unsettled merge intents, and enqueue exact-child stops. Preserve submissions, verdicts, handoffs and assignment history. |
| Reopen task / `task.reopen` | Reopen cancelled, completed or merge-blocked work for a new submission/review. Never reuse an earlier approval for the next submission. |
| Resolve human block / `task.resolve` | Require a nonempty device-signed answer. Release the human block without treating the answer as a review verdict. |
| Retry unchanged merge / `merge.retry` | Bind the current attempt, head, requirements and configuration; retain the original queued merge intent, prepared head and retry floor. |
| Assign local instance / `fleet.edit` | Require a real current local child when enabling/rebinding. Revoke old leases/review sessions, retain signed assignment history, and enqueue exact-child checkpoint notices. |
| Configure review and merge / `lifecycle.configure` | Bind the named independent pair to observed exact local children and validated paths; revoke old authority and require a fresh claim. |

The body field carries a reason or explicit answer. Hold, cancel, resolve and
merge retry require nonempty text. The enable-assignment checkbox can disable a
previously recorded assignment even after its child has exited; disabling cannot
mint a new capability. Re-enabling requires fresh observed-child validation.

Current control mode is separate from the submission/merge state in runtime
observations. A held, blocked or cancelled task cannot claim, heartbeat, submit
or post a new verdict. A hold retains one exact, unexpired checkpoint-only
binding: the old worker may save one handoff, or the old reviewer may save one
review checkpoint, with the new task revision. This does not revive its lease
or permit a verdict. Release, cancellation, rebinding or a requirements edit
clears unused checkpoint-only authority. Editing requirements or assignment while held changes
its saved resume state to ready, so release cannot revive a stale review.

Requirements edits retain the worker lease so the holder can present and ACK
the new exact revision. They invalidate review sessions and enqueue checkpoint
notices; no new ACK is inferred. Existing capabilities without the new handoff
methods can be renewed by heartbeat to receive the expanded method set.

## Exact-child handoff and block

Use the existing agent CLI with a strict lifecycle input file:

```bash
ham-ctl task-chain owner-local lease --request-file handoff.json
```

Outer input fields are the same as submit: `protocol_version`, `chain_id`,
`task_id`, `lease_id`, `configuration_revision`, `expected_revision`,
`operation_id`, `method`, `request_expires_ms`, `capability`, and `payload`.
The capability and payload are exact JSON strings. New operation IDs represent
new commands; retry the original complete input bytes after a lost reply.

For method `lease.handoff`, the decoded payload is:

```json
{"requirements_revision":"1","summary":"Completed parsing; checks pending","next_steps":"Run focused tests"}
```

For `lease.block`, add a nonempty identifier `waiting_on`, such as `human`.
Both persist immutable prose, release the exact work lease, and enqueue an exact
stop intent in the same transaction as the operation receipt. Block additionally
requires explicit device resolution. Summary and next steps each have the
existing 8192 UTF-8 byte / 16384 JSON-encoded byte limit.

A reviewer uses `review.checkpoint` and its current review capability. The
decoded payload contains `requirements_revision`, `attempt`, `head`,
`summary`, and `next_steps`. This releases only that review session, preserves
`in_review`, and records no verdict. A later reviewer must open a fresh session.

## Atomic switch

Method `lease.switch` uses the source lease/capability and task revision.
Its decoded payload is:

```json
{
  "requirements_revision":"1",
  "summary":"Checkpoint source work",
  "next_steps":"Continue destination work",
  "destination_chain_id":"chain_destination",
  "destination_task_id":"task_destination",
  "destination_revision":"4",
  "destination_configuration_revision":"1",
  "destination_requirements_revision":"1",
  "destination_lease_id":"lease_new_unique_identity"
}
```

The destination must exist in this immutable owner's Store, be ready and
unblocked, and have a signed enabled assignment/lifecycle configuration for the
same exact child and durable author. Destination task, fleet configuration and
requirements revisions must match. Existing destination holders, reused lease
IDs, a different owner or child, and stale revisions fail closed.

Release, handoff evidence, a new durable work attempt, destination lease/capability, receipt pins and command
receipt commit together. Any failure, including SQLite COMMIT failure, leaves the
source lease intact. The result contains the destination capability and task
revision. The child must explicitly present and ACK destination requirements;
the source ACK does not transfer. No switch stop intent targets the transferred
child. A delayed stop from earlier work also skips a child holding a new lease.

## Merge repair and recovery

An unchanged retry keeps the original deterministic merge identity and prepared
head, including when Git CAS succeeded but its reply was lost. Retry never
silently changes the base, source, target, submission, or independent verdict.

For changed source/base/path input, reopen merge-blocked work, repair the worktree
and target externally, save a new validated lifecycle configuration, then claim,
present/ACK, submit and obtain a new independent review. Old merge intents are
durably invalidated; late old results cannot change the gate. No force update or
blind candidate merge is introduced. Cancellation/reopen preserves evidence;
it does not undo a Git effect that already completed.

V7 upgrades V6 transactionally and preserves identity, clocks, receipts,
capabilities, immutable submissions/reviews and search documents. It adds current
control modes, immutable signed assignment snapshots and work attempts, immutable handoff/control
prose, exact-child notices and merge-intent invalidations. Handoff summaries,
next steps, waiting reasons and control answers enter scoped search in the same
transaction and are rebuilt from canonical rows after restart. Existing output
documents retain every submission attempt.

Notice delivery runs after commit under the owner and local startup I/O locks.
It validates launch epoch, run count and token generation before PTY I/O.
A replaced child is obsolete; an unverified daemon response stays retryable.
A successful stop invalidates local tokens. Checkpoint notices convey no
capability or approval. Transient result-write failures use the existing retained
completion queue; process restart retries the original durable intent.

## Verification entrypoints

`src/lib/owner_local/controls_test.odin` covers control/replay/revision fences,
switch rejection and COMMIT rollback, actual new lease issuance, restart,
assignment revocation, review checkpoint, V6 upgrade collision/COMMIT recovery,
and merge retry identity/old-result invalidation.

The disposable real Hub/Bridge/CLI/PTY demo preserves prior lifecycle/search
cases and adds real switch, block/resolve, handoff/search and rendered panel
hold/release/cancel/reopen. Run its existing build instructions with
`HEIMDALL_E2E_OWNER_CONTROLS=1` in addition to the owner-local, lease and lifecycle
flags. It does not restart or deploy production services.
