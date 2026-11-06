# Owner-local requirements, submission and independent review

The owner-local panel and managed CLI now run a single-device task through
requirements presentation/ACK, submission, independent review and a durable
merge gate. V1 create/task/comment/read and the original claim/heartbeat path
remain usable. The Hub relays encrypted requests and retains protected listing
metadata; it does not decide local ACKs, verdicts or merges.

## Configure from the owner-local panel

Create the chain/task and assign its running worker as described in
[owner-local-leases.md](owner-local-leases.md). Start an independent local reviewer.
Both children must be currently running on the owner Bridge.

In **Lifecycle configuration JSON**, enter this minimal no-merge configuration.
Use the durable agent IDs and the reviewer's actual instance ID:

```json
{
  "configuration_revision": "1",
  "author_agent_id": "agt_worker",
  "reviewer_agent_id": "agt_reviewer",
  "reviewer_instance_id": "inst_reviewer",
  "directory_id": "dir_local",
  "merge_policy": "none",
  "repository": "",
  "worktree": "",
  "source_branch": "",
  "target_branch": "",
  "base_head": ""
}
```

Set the current task revision and choose **Configure review and merge**. The
device signs the complete configuration. The owner binds the durable IDs to
actual launch records, tokens, run counts and exact PTY children. A different
instance of the same author agent cannot self-review. Config revisions increase;
configuration changes on ready/in-review work retire old leases and review
sessions atomically. Completed or merge-blocked work must be reopened before
rebinding; unsettled old merge intents are invalidated. See
[owner-local-controls.md](owner-local-controls.md).

For Git, use `merge_policy: "git"` and supply a canonical local repository,
its task worktree at `<repository>/.heimdall/worktrees/<task_id>`, source branch
`heimdall/<task_id>`, an existing target branch and its exact current commit as
`base_head`. The worker's enrolled launch project must resolve to that repository
or worktree. Paths must be inside the Bridge filesystem root; symlink escapes,
different repositories, invalid refs and remote paths reject.

The target must be **un-checked-out in every Git worktree**. This slice updates it
with an atomic ref compare-and-swap, so it must not leave a checked-out working
tree inconsistent. The source must be clean at submit and share ancestry with
the pinned target. No auto-commit, forced reset, branch deletion or worktree
removal occurs.

In the body field enter a complete brief:

```json
{"goal":"Implement the assigned change","acceptance":["The focused checks pass"]}
```

Set **Requirements revision** to `1` and choose **Save requirements**.
Subsequent changes use exactly the next revision. Each revision is immutable;
saving one never ACKs it for a worker. An amendment during review invalidates
that submission for further verdicts and returns the task to ready for rework.

## Worker CLI

Claim and renew using the existing `lease_input` file documented in
[owner-local-leases.md](owner-local-leases.md). A configured task's capability
also permits presentation, ACK and submit.

The same CLI accepts a strict lifecycle file:

```json
{
  "protocol_version": "1",
  "chain_id": "chain_example",
  "task_id": "task_example",
  "lease_id": "lease_unique",
  "configuration_revision": "1",
  "expected_revision": "4",
  "operation_id": "op_present",
  "method": "requirements.present",
  "request_expires_ms": "REPLACE_WITH_CURRENT_UNIX_MS_PLUS_300000",
  "capability": "COPY_THE_LATEST_CAPABILITY_STRING",
  "payload": "{\"requirements_revision\":\"1\"}"
}
```

```bash
./bin/ham-ctl task-chain owner-local lease --request-file lifecycle.json
```

Read the returned brief. Then send a new operation ID with method
`requirements.ack` and the same exact requirements revision. ACK requires that
revision to have been presented to this live lease. Ordinary heartbeats do not ACK.

To submit, use method `lease.submit` and payload:

```json
{"requirements_revision":"1","head":"ACTUAL_CLEAN_GIT_COMMIT_OR_EMPTY_FOR_NO_MERGE","summary":"What changed; exact checks and results"}
```

Use a fresh operation ID/expiry and the current task revision. The owner verifies
the source commit itself. Release, immutable summary/head/brief provenance,
submitted attempt, review state, receipt and change sequence commit together.
An unacknowledged revision, old child, retired lease, expired capability or stale
task revision rejects.

Retain the **exact request file** to retry a lost response. A matching receipt
replays after lease release and request/lease expiry without any new effects.
Current authenticated child/read scope still applies; a stopped, rotated,
disabled or reassigned child cannot read old bodies. Changed signed input under
the same operation ID conflicts. Historical results never authorize new execution.

## Independent reviewer and human verdicts

Read runtime in the panel to obtain submitted attempt, head, requirements
revision and current task revision. From the configured reviewer's own managed
CLI use a lifecycle file with method `review.open`, empty capability, and payload:

```json
{"requirements_revision":"1","attempt":"1","head":"EXACT_SUBMITTED_HEAD_OR_EMPTY","verdict":"approve","summary":"Independent review findings"}
```

Use the submitted worker lease ID and the lifecycle configuration revision.
Opening review returns the immutable submission brief/summary and a short-lived
review capability. Send a new operation with method `review.post`, that exact
capability and the same binding. Verdict is `approve` or `request_changes`.
Stale attempts, heads, requirements, exact-child bindings and author identity
reject. Request changes returns the task to ready; the next submission advances
the attempt and cannot reuse old verdicts.

The panel's **Record human verdict** sends a separately device-signed verdict.
Human approval is recorded but does not replace required independent agent
approval. A human request for changes returns the task for rework. There is no
mandatory human approval gate in this slice.

No-merge approval finishes the task. Git approval commits a durable merge intent
with the exact attempt/head/requirements/configuration fence. Git runs after
the SQLite transaction. A prepared merge commit is persisted before target CAS.
A lost effect reply can therefore recover the same target/result after restart.
Settlement atomically records the exact merge receipt and gate/change sequence.
A changed target, conflict or failed effect remains `merge_blocked`; the durable
intent retries its original identity without silently rebasing or changing input.

## Runnable validation

Use freshly built binaries and a disposable identity probe. Rootless Nix
outputs must run inside `nix develop`:

```bash
nix build .#ham-hub .#ham-bridge .#ham-ctl .#ham-pty-host \
  -o "$HOME/.cache/heimdall-tests/owner-local-demo"
nix develop --command odin build tools/owner_local_test_identity \
  -collection:odin_test=src \
  -out:"$HOME/.cache/heimdall-tests/owner-local-identity"
nix develop --command env \
  HEIMDALL_E2E_HUB_BIN="$HOME/.cache/heimdall-tests/owner-local-demo/bin/ham-hub" \
  HEIMDALL_E2E_BRIDGE_BIN="$HOME/.cache/heimdall-tests/owner-local-demo-1/bin/ham-bridge" \
  HEIMDALL_E2E_CTL_BIN="$HOME/.cache/heimdall-tests/owner-local-demo-2/bin/ham-ctl" \
  HEIMDALL_E2E_PTY_BIN="$HOME/.cache/heimdall-tests/owner-local-demo-3/bin/ham-pty-host" \
  HEIMDALL_E2E_IDENTITY_BIN="$HOME/.cache/heimdall-tests/owner-local-identity" \
  HEIMDALL_E2E_OWNER_LOCAL=1 HEIMDALL_E2E_OWNER_LEASE=1 \
  HEIMDALL_E2E_OWNER_LIFECYCLE=1 \
  node --import ./tests/helpers/vaultEndpointHarness.ts \
    tests/e2e/bridge_real_enroll_e2e.mjs
```

The demo uses disposable enrolled accounts, real Hub/Bridge/CLI/PTY binaries,
the UI signing/relay client and actual synthetic provider children. It preserves
V1 pagination/offline/restart/privacy gates and claim/heartbeat. It adds real
requirements amendments, exact presentation/ACK, release replay, author/stale
review rejection, separate human verdicts, independent review, successful Git CAS
and a real content conflict that leaves its target unchanged and gate blocking.
The test uses client modules rather than browser automation.

```bash
nix develop --command odin build tests/helpers/owner_local_storage_probe \
  -collection:odin_test=src \
  -out:"$HOME/.cache/heimdall-tests/owner-local-storage-probe"
nix develop --command python3 tests/test_owner_local_storage_recovery.py \
  --probe "$HOME/.cache/heimdall-tests/owner-local-storage-probe"
```

The probe SIGKILLs actual processes before/after SQLite COMMIT and after outbox
claim. It verifies create/lease/submit rollback, complete post-commit recovery,
historical replay after release/expiry, and unchanged effect identities.
Unit tests additionally inject deferred-FK COMMIT failures, stale/revoked scope,
receipt retention, clock regressions and migration failures.

Durable scoped search and bounded unstarted-task content maintenance are now
implemented; see [owner-local-search.md](owner-local-search.md).

## Remaining M2 expansion

This is an explicit single-worker/single-reviewer, already-running-child slice.
General unlaunched dispatch/provider scheduling remains M3 work. Workflow
executions, dependencies and multiple review role folds remain M2c work. Local controls,
handoff/block/switch, assignment rebinding and merge repair are documented in
[owner-local-controls.md](owner-local-controls.md). Unsupported workflow
fields/methods reject at the strict contract boundary; no workflow authority is
inferred. Remote execution/reservations remain M3 and migration/recovery
integration remains M4. Checked-out-target merge orchestration and other platforms
need separate validation. No native provider interrupt behavior is established.

## Source entrypoints

| Boundary | Source |
| --- | --- |
| Strict mirrored inventory | `src/contracts/fixtures/owner-local-schema.json:18` |
| Exact local child and durable launch identity | `src/bridge/owner_local_leases.odin:16` |
| Device lifecycle edits/verdicts | `src/lib/owner_local/lifecycle.odin:31` |
| ACK/submit/reviewer capability and replay | `src/lib/owner_local/lifecycle_agent.odin:12` |
| Git path/ref/source validation and CAS | `src/bridge/owner_local_lifecycle.odin:19` |
| Durable effect settlement | `src/lib/owner_local/outbox.odin:65` |
| Immutable schema additions | `src/lib/owner_local/migration_004.sql:50` |
