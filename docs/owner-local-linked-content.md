# Owner-local canonical linked content (C3)

C3 adds schema V25 to the existing account/immutable-owner runtime. It uses the
existing lifetime writer lock, signed device command admission, current grants,
directory pin, CAS, transaction, events, receipts and encrypted relay. The Hub
receives routing and the existing protected titles; linked bodies, references,
backup pages and search prose stay at the owner.

## Canonical records and producer contract

The generated Odin/TypeScript contract is
`src/contracts/fixtures/owner-local-schema.json`. All new commands are
**chain scoped** (`command.task_id=""`). A record's optional task is independently
checked against that same chain; an object cannot supply authority by naming an
account, owner, original author or provenance.

| Signed method | Payload / result |
| --- | --- |
| `linked.put` | `body_cipher` opens to one strict `linked_object`. Current mutation grant and chain CAS required. |
| `linked.delete` | `kind,object_id,revision`; permanently tombstones that version, removes its live body/search projection and outgoing references, collects unreferenced child blob chunks. |
| `linked.fetch` | `kind,object_id,revision,offset`; returns exact record bytes in bounded UTF-8 chunks and `next_offset`. Deleted identity returns `retired`. |
| `linked.read`, `linked.backup` | `cursor,limit`; encrypted manifest pages, next cursor, digest, required vault/epoch metadata and chain revision. |
| `linked.restore` | `body_cipher` opens to a bounded `linked_restore` bundle. Applies supplied and existing destination tombstones before inserting records, atomically. |
| `linked.facet.read` | `task_id,source_revision,key`; resolves references of an existing canonical imported facet to `resolved`, `unresolved` or `deleted`, without changing its original bytes. |
| `envelope.read` | `cursor,limit`; canonical event/field locations, envelope format, vault ID, epoch and ciphertext digest. Pair with `history.fetch` for exact signed bytes. |

A `linked_object` has `account_id,owner_bridge_id,chain_id,task_id,kind,object_id,
revision,author_id,created_ms,media_type,body_cipher,references,provenance`.
All fields are strings. Kinds are `message`, `artifact` and `blob`; revision
and original creation time use exact decimal strings. Imported source author,
time and provenance remain unchanged, while the importing signer/time and exact
input are independently recorded in the local event. Imported source claims do
not enroll a principal, create a grant or establish original-author authenticity.

`references` is a strict JSON array of `{kind,object_id,revision}` objects in
producer order. These ordered bytes remain in the canonical record; the SQL
reference set supplies transactional reachability. Every target must already
exist in the same chain. New records cannot reference themselves or future
records, producing a dependency DAG. Restore admits an already-tombstoned target
identity so historical references remain explicit rather than being silently
redirected to another version. Reusing a version with changed bytes conflicts.

Bodies are authenticated vault-v2 envelopes. The owner validates decryption,
retains the original token, and persists its vault ID/epoch. Blob bodies contain
producer-supplied UTF-8 encodings of binary chunks (for example base64); ordered
artifact/blob references form larger manifests. No path is opened, no directory
is crawled and no URL is fetched. Producers must upload chunks before their
referencing manifests. There is no cross-chain copy shortcut: export needs
current source read authority; import binds the exact destination scope and
needs its current write authority. Possession of an epoch key does not grant an
API read or write. A person who already decrypted content can manually author
new content; revocation cannot retract such copies.

Limits are explicit: at most 8,192 decrypted bytes / 16,384 JSON-encoded bytes per
body, 20,000 JSON-encoded bytes per complete record, 100 references, 256 bytes of
media type, 4,096 bytes of provenance; import bundles are bounded to 65,536
decrypted bytes and 100 objects/100 tombstones. The ordinary command frame limits
also apply. Use more chunks/pages rather than an oversized object. Identities
and tombstones have a bounded account capacity; they are not automatically
reclaimed to permit ID resurrection.

The production browser signing adapter prepares these requests;
the ordinary CLI signed-file relay transports them unchanged. The synthetic
enrollment proof uses those actual paths. Automatic legacy chat/artifact
producer-route cutover belongs to M4; C3 provides the authenticated destination
API it consumes. Existing ordinary workflow output and handoff writers continue
to produce canonical searchable prose through their existing transactions.

## Storage, references and deletion

`linked_identities` retains scoped version identity and original optional task.
`linked_bodies.record_json` is the authoritative exact body-bearing record.
Its message plaintext column and FTS rows are derived projections; artifacts
and blobs have no plaintext/index projection. `linked_references` has same-chain
foreign keys to the source body and target identity. `linked_tombstones` is
permanent. Immutable identity/body/reference/tombstone triggers prevent accidental
rewrites; deletion requires a tombstone before either body or reference GC.

An ordinary signed deletion of an artifact drops its outgoing references. A shared child blob stays
live until its final live source reference disappears. GC then tombstones and
removes that blob's live body, continuing through its child chunks iteratively.
A signed direct deletion may explicitly tombstone a referenced target; incoming
references keep their exact deleted identity. Uploaded chunks without a parent
are not silently swept while a producer is still building a manifest; explicit
signed deletion can remove them.

Task deletion includes its linked bodies in the same transaction as the task,
comments, search, task tombstone, event and receipt. Restoring an old object for
an already-deleted task creates/retains a linked tombstone instead of exposing
the old message, including objects previously unknown to the destination.
Statement failure or deferred-COMMIT failure rolls all participating rows back.

Imported native facets keep their original `references_json` and source
provenance byte-for-byte, including `unresolved/import_pending`. Resolution is a
current same-chain projection, never a rewrite of archival evidence. An imported
facet does not itself become a live blob pin; its artifact/message reference
continues to resolve to the retained version identity or deletion.

## Envelopes, backup and M4 integration

Current immutable `local_events.evidence_json` already retains the exact signed
command and payload independently of receipt compaction. C3's envelope inventory
makes that carrier explicit: `event seq + payload field` identifies the original
ciphertext, and version/vault/epoch/digest metadata identifies its key dependency.
Linked records retain their own original body envelope in their canonical row.
Requirements already retain their ciphertext. Output/handoff native signed
payloads are preserved in the same event history; portable export must wrap that
history as encrypted content, not dump plaintext SQLite.

Some pre-event V1 writes discarded original ciphertext. An additive migration
cannot recreate the original nonce/token or claim absent historical evidence.
The existing migration's incomplete event markers remain incomplete. The current
canonical plaintext can be preserved by M4's encrypted aggregate export, with
that provenance limit; C3 does not invent historical signatures or envelopes.
Coordinator acknowledged this boundary and the M4 staging contract in
`msg_18e5959901db5d4b`; independent named review remains required.

Backup pages contain `manifest_cipher`, `manifest_digest`, `required_keys`,
`chain_revision` and `next_cursor`. After decrypting, a page is a
`linked_restore` document containing format 1, exact account/owner/chain,
original body-record strings and tombstone identities, including each deleted
version's original optional task association. Restore rejects conflicting task
associations. Restore aggregate tasks and task tombstones before linked pages. Records are emitted in
durable insertion/dependency order. Tombstones are emitted first, even when the
first phase is empty. Pagination counts examined records, respects the complete
encoded/encrypted 64-KiB page budget and never silently truncates a large record.
Cursors bind account, immutable owner, chain, reader signing identity and chain
revision. A concurrent mutation makes continuation stale; discard that partial
inventory and restart. Every admitted record fits a manifest page.

M4 must:

1. Freeze/drain the chosen aggregate and retain all pages through terminal cursor.
2. Retain `envelope.read` metadata, exact encrypted history/source exports, grant
   policy and the established protected vault key wraps needed for every epoch.
   Vault IDs/epochs are metadata, not substitute key material.
3. Verify the complete scope, page digests, closure and key availability in a
   private **staging** store, before making the restored runtime visible.
4. Apply the complete latest available tombstone journal first, then restore
   body pages in their original dependency order, under the existing single
   writer. Local destination tombstones always dominate older body pages.
5. Rebuild derived search and only then perform the separately authorized M4
   activation/cutover.

`linked.restore` is the bounded authenticated import primitive, not a complete
whole-database backup-session or cutover controller. Within each call, tombstones
and body/reference/search writes commit together. A missing dependency fails
closed and rolls back that call. Imported tombstones apply **only their explicit
identity deletions**: they never cascade inferred blob GC from a partial restore
graph. A blob whose final live pin arrives on a later page must remain available.
Genuine existing destination blob tombstones still dominate imports. Any
unreferenced restore candidates remain retained until complete-inventory staging
can establish their disposition; there is no eager post-page sweep. M4 owns completeness across all pages and
offline staging before exposure. An old backup cannot contain deletions that
happened after it was taken: preserve the newest journal/destination tombstones;
if both are lost, no implementation can infer those unseen deletions.

No plaintext portable backup is produced by the linked backup API. Private
account DB and WAL files still contain local plaintext search/materializations
and must remain under the existing private-directory/0600-file policy; this
change adds no external blob directories or new filesystem permissions.
SQLite free pages, WAL, immutable events, prior backups, exported ciphertext,
held epoch keys and already-decrypted copies preclude a forensic-erasure claim.
Live API deletion/GC is not a promise to destroy every historical byte.

## Search and verification evidence

Only linked message prose adds a new FTS producer. Inserts/deletes and search
postings share the canonical transaction; restart rebuild reads live canonical
message bodies. Current grant authorization precedes replay, reads, manifest
export, facet resolution and snippets. Artifact extraction/indexing and browser
cache remain deferred. Existing output/handoff producers and the real V1,
lifecycle, search and controls demonstrations are retained.

Storage regressions in `src/lib/owner_local/linked_test.odin` exercise signed
scope, exact source bytes and envelope epochs, replay/restart, artifact exclusion
from FTS, missing references, statement/deferred-COMMIT rollback, shared chunk GC,
old-backup tombstone dominance, deleted-task suppression, native facet resolution
and genuine V24 upgrade collision/COMMIT rollback with live capabilities retained.
Cross-language strict contracts are covered in the Odin contracts package and
`tests/ui_owner_local_contract_test.ts`.

The real enrolled proof is `tests/e2e/owner_local_linked_flow.ts`, enabled by
`HEIMDALL_E2E_OWNER_LINKED=1` alongside `HEIMDALL_E2E_OWNER_LOCAL=1` in the existing
disposable enrollment harness. It uploads synthetic message/artifact/chunk
records, imports original facets, exports encrypted manifests, restarts the
actual owner process, searches prose, rejects foreign scope, restores old pages
against a newer tombstone, and exercises blob GC through the real CLI/Hub relay.
No production service, live credential, deploy, push or revocation experiment is
part of these checks.

Exact commands, final outcomes and modified full paths are recorded in the task
submission and final progress comment.


## Attempt 1 verification (38c242ac)

Run from the assigned task worktree:

```bash
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/c3-linked-final228-$$
nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/c3-final-contracts-$$
nix develop --command odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_NAMES=test_owner_local_control_notice_rejects_new_child_and_retries_unverified_child,test_owner_local_publication_recovers_result_write_and_commit_failure_in_process,test_owner_local_lease_agent_route_and_wrapper_denial,test_owner_local_lifecycle_real_git_paths,test_owner_local_periodic_batch_expires_and_publishes_after_commit -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/c3-linked-bridge-$$
node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_local_contract_test.ts tests/ui_owner_submission_history_test.ts tests/ui_owner_controls_test.ts tests/ui_owner_grants_test.ts
nix develop --command npm run typecheck
python3 scripts/check-owner-aggregate-parity.py
python3 tests/test_owner_aggregate_parity_gate.py
nix build .#ham-hub .#ham-bridge .#ham-ctl .#ham-pty-host --out-link "$HOME/.cache/heimdall-tests/c3-linked-build" -L
nix develop --command odin build tools/owner_local_test_identity -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/c3-linked-identity
git diff --check
```

| Check | Outcome | Managed session |
| --- | --- | --- |
| Owner storage, including V24 collision/COMMIT rollback | 228/228 pass | `sh_73087164e779c02b1aa925d006101e7e` |
| Contracts | 32/32 pass | `sh_3d254f0c36c3faee65fa5ca39956cd39` |
| UI contracts, history, controls and grants | 29/29 pass | `sh_3d254f0c36c3faee65fa5ca39956cd39` |
| Typecheck | Pass | `sh_3d254f0c36c3faee65fa5ca39956cd39` |
| Native parity / negative gate cases | 240 fields / 23 structs / 81 methods; 7/7 pass | `sh_3d254f0c36c3faee65fa5ca39956cd39` |
| Bridge regressions | 5/5 pass | `sh_a9c25244493fb07485711d4624125aae` |
| Four binaries | Pass | `sh_589eb72839810973450e9d28b02b6355` |
| Isolated enrolled linked-content proof | All five harness steps pass | `sh_b419157e3b2e383ccbba8414da5ee95d` |
| Combined V1/lifecycle/controls/workflows/language/grants/linked proof | All five harness steps pass | `sh_9c4c2fbefe905466aa94ba5915314c56` |

The isolated linked proof uses the binaries above:

```bash
nix develop --command env \
  HEIMDALL_E2E_HUB_BIN="$HOME/.cache/heimdall-tests/c3-linked-build/bin/ham-hub" \
  HEIMDALL_E2E_BRIDGE_BIN="$HOME/.cache/heimdall-tests/c3-linked-build-1/bin/ham-bridge" \
  HEIMDALL_E2E_CTL_BIN="$HOME/.cache/heimdall-tests/c3-linked-build-2/bin/ham-ctl" \
  HEIMDALL_E2E_PTY_BIN="$HOME/.cache/heimdall-tests/c3-linked-build-3/bin/ham-pty-host" \
  HEIMDALL_E2E_IDENTITY_BIN="$HOME/.cache/heimdall-tests/c3-linked-identity" \
  HEIMDALL_E2E_OWNER_LOCAL=1 HEIMDALL_E2E_OWNER_LINKED_ONLY=1 \
  node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/bridge_real_enroll_e2e.mjs
```

The retained combined proof replaces `HEIMDALL_E2E_OWNER_LINKED_ONLY=1` with
`HEIMDALL_E2E_OWNER_LEASE=1 HEIMDALL_E2E_OWNER_LIFECYCLE=1
HEIMDALL_E2E_OWNER_CONTROLS=1 HEIMDALL_E2E_OWNER_WORKFLOWS=1
HEIMDALL_E2E_OWNER_LANGUAGE=1 HEIMDALL_E2E_OWNER_GRANTS=1
HEIMDALL_E2E_OWNER_LINKED=1`. The lease flag supplies the real child launcher;
isolated-only fixtures follow the existing cold-start setup. The linked case
refreshes its session after the synthetic grants test rotates the vault epoch.

The full lifecycle harness had one preexisting stale assertion: context already
returns algorithm 2, while the harness still required 1. That assertion now
matches the baseline source; the product projection was not altered. Pinned
`npm ci --ignore-scripts --no-audit --no-fund` restored the missing `posthog-js`
worktree dependency before the passing typecheck, without a lockfile change.
Early draft compiler/array-grammar/fixture failures and stale parity method-count
expectations were corrected; they are not relabeled as passing checks.


## REQ-B2 re-review: paginated restore GC

Independent reviewer #24 found a missing restore case in attempt 1: both source
and destination initially contain A -> B; the source adds C -> B and deletes A.
Its complete backup contains A's tombstone followed by live B and C. Applying
A's tombstone previously ran ordinary cascading GC against the destination's
partial graph, created a false permanent B tombstone, then silently skipped
B's later body. Earlier broad passing suites did not establish this property.

The reviewer regression is retained and extended in
`src/lib/owner_local/restore_gc_test.odin`. It first reproduced on 38c242ac
(1 selected test, failed: blob expected `ok`, got `retired`;
`sh_217c02faf8deb931e26cb7a52eb87f82`). The fix returns after the explicit
restore deletion and reference removal, before inferred GC. Ordinary
`linked.delete` and task deletion retain their existing cascading GC.

The regression restores actual limit=1 backup pages into an older destination,
checks exact B/C bytes and restart, verifies a genuine destination B tombstone
still wins against that same backup, and imports a later genuine source GC
journal to establish explicit blob deletion. The real enrolled linked-content
proof additionally sends the explicit old-artifact tombstone before a later
live artifact/blob page and checks the shared body through a real owner restart.

A staging store already damaged by the old implementation cannot distinguish
an inferred false tombstone from a genuine destination deletion. Do not remove
tombstones automatically: rebuild that private staging store from its verified
baseline and newest explicit journals. No production deployment occurred in
this task.

Attempt 2 validation:

| Check | Result | Managed session |
| --- | --- | --- |
| Reviewer reproduction on parent | 1 selected test fails as reported | `sh_217c02faf8deb931e26cb7a52eb87f82` |
| Extended restore/ordinary-GC boundary tests after fix | 4/4 pass | `sh_2386462beaeb54fc202f4217128dfed1` |
| Complete owner-local package | 229/229 pass | `sh_113969c041fd426f46efa436c191a9af` |
| Four binary builds | Pass | `sh_fc4f45b921906d82a924b3e485301597` |
| Parity / negative gate cases | 81 methods / 7 cases pass | `sh_f9722b949c694e98139edcf1d80df66c` |
| Combined actual enrolled proof, including new partial-page case | All five harness steps pass | `sh_92268dd51ef3b41ec2346736bb0c1b13` |

Exact new storage checks:

```bash
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_NAMES=review_restore_tombstone_must_preserve_blob_live_in_backup -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/c3-restore-reproduce-$$
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_NAMES=review_restore_tombstone_must_preserve_blob_live_in_backup,linked_encrypted_manifest_pages_restore_and_tombstone_dominance,linked_reference_delete_shared_blob_gc_tombstones_and_task_delete,linked_task_tombstone_suppresses_unknown_restored_message_and_delete_rolls_back -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/c3-restore-fixed-$$
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/c3-restore-final-$$
```

The first command intentionally ran before the fix. Builds, parity and the full
combined enrollment command use the exact commands and flags above from attempt
1, now against the corrected runtime and expanded fixture. Contracts, UI and
Bridge unit packages were not changed by this correction; their earlier passing
results are retained, while the final binaries and actual combined integration
path were rebuilt/re-executed. No production or cross-platform experiment was
run. Independent re-review remains required.
