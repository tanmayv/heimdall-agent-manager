For signed device grants, expiry and paired-root recovery, see [owner-local-grants.md](owner-local-grants.md).

For the additive single-device fleet/lease/heartbeat flow, see [owner-local-leases.md](owner-local-leases.md).

# Owner-local V1 task demo

This opt-in slice supports chain creation, task creation, comment append and
bounded reads. Open **Task Chains → Owner-local** in the existing UI. Select an
enrolled online owner Bridge, enter a title/body, then choose **Create chain**,
**Create task**, **Add comment**, and **Read task**. The initial expected revision
is 0; successful writes return the next resource revision. A fresh read accepts
revision 0; use **Read chain** before creating additional tasks after other edits.
The owner is fixed at creation. Only the enrolled creating browser has the initial
local grant. This UI uses the account's existing passwordless device identity.

The panel lists protected titles even when the owner is offline. Detail reads
then return `owner_unavailable`; there is no alternate writer or detail cache.
Reads and comments are limited to 100 records per page and 64 KiB of JSON per
page, including its items/cursor JSON framing. Each prose field is limited to
8192 UTF-8 bytes and 16384 bytes as a JSON-encoded string (including quotes).
Oversized escaped content is rejected before commit with `invalid_content`.
These limits leave room for a complete header and at least one maximum-size
item on every nonterminal page. Incompatible oversized data from earlier draft
builds fails explicitly instead of returning a non-advancing cursor. Read results include
`next_cursor`; callers pass it in the next signed read and restart on
`stale_cursor`. Hub listing pagination is described below; its cursor advances over raw rows,
including hidden deletion tombstones.

## Protected registry listing and creator revocation

The panel consumes `GET /api/v1/owner-local/chains?page=1` until the response's
`terminal` is true. Each response contains `items`, `next_cursor` (an object with
`after_chain` and `after_task`), and `terminal`. Pass both cursor fields unchanged
on the next request, together with the same `chain_id` / `headers_only` filters.
A terminal response has empty cursor fields. Never infer completion from the
visible item count: an empty page can advance past 100 deletion tombstones.
Pages examine at most 100 raw rows (plus one unconsumed lookahead row) and the
encoded data object is at most 262144 bytes, including items and cursor framing.
A row that cannot fit alone fails explicitly, without returning a stuck cursor.

These are **live keyset cursors**, not snapshot cursors. Registry keys and deletion
tombstones are retained permanently: edits, deletion, and later publication do
not expire a position or produce `stale_cursor`. Concurrent insertion at or before
a consumed position requires a fresh listing from the beginning. An old or
cross-account position grants no access: each page applies current account
authentication and filtering. The panel discards in-flight pages when the vault
session changes and rejects non-advancing/malformed cursors. Owner-local signed
detail reads retain their separate snapshot/`stale_cursor` protocol.

The array response without `page=1` remains for existing callers, including the
separate header-only search discovery limit; it is not the complete panel listing.

First registry registration verifies both creator and owner signatures against
currently approved enrolled identities. If the creator is revoked before first
publication, registration fails closed; this patch adds no recovery or key
substitution path. Once registered, each publication verifies the current owner
and its exact enrolled Bridge signing identity, the new registry signature,
and the persisted account/chain/owner/key/creator/genesis digest and exact genesis
bytes. Creator revocation therefore cannot prevent an approved owner publishing
newer committed metadata or tombstones for that bound chain. It still denies the
creator's commands and receipt reads; revoking the owner still denies publication.
This addresses audit F1 and F2; it does not add general device grants.

## CLI and signing/export

The browser signs commands with its existing enrolled, non-extractable P-256
device key. **Export signed request for CLI** downloads the last operation's
encrypted signed request. **Retry same operation** keeps the operation ID and
exact signed command/payload, including after an unknown network outcome. An
export after a successful UI write exercises historical replay through the CLI.

From a running authorized instance on an account Bridge:

```bash
./bin/ham-ctl task-chain owner-local relay \
  --request-file /path/to/owner-local-request.json > owner-local-response.json
```

The CLI renews only the outer transport correlation/deadline. It cannot change
the human-signed command, sign commands, create grants, or authorize writes.
The owner authenticates the current enrolled human device and its local grant
again before receipt lookup. Matching historical receipts remain readable after
request expiry or removal of mutation permission, but revoked read access
denies replay. A changed input under an existing operation ID conflicts.

The CLI returns encrypted results. In the same unlocked browser panel, use
**Open CLI response** to decrypt and bind the result to the exported operation.
No content key or private signing key is exported. A running authorized instance
transport is required; this slice adds no native CLI login or agent signing.

## Isolated reproducible verification

Use the repository Nix toolchain. Rootless nix-portable hosts must also run the
demo inside `nix develop`, so the built `/nix/store` executables are visible.
These commands start disposable Hub/Bridge processes on ephemeral ports with a
mock OIDC provider and separate HOME, databases, identity stores and local socket.
They do not restart or deploy any existing service.

```bash
nix build .#ham-hub .#ham-bridge .#ham-ctl \
  --out-link "$HOME/.cache/heimdall-tests/owner-v1"

nix develop --command odin build tools/owner_local_test_identity \
  -collection:odin_test=src \
  -out:$HOME/.cache/heimdall-tests/owner-v1-identity

nix develop --command env \
  HEIMDALL_E2E_HUB_BIN="$HOME/.cache/heimdall-tests/owner-v1/bin/ham-hub" \
  HEIMDALL_E2E_BRIDGE_BIN="$HOME/.cache/heimdall-tests/owner-v1-1/bin/ham-bridge" \
  HEIMDALL_E2E_CTL_BIN="$HOME/.cache/heimdall-tests/owner-v1-2/bin/ham-ctl" \
  HEIMDALL_E2E_IDENTITY_BIN="$HOME/.cache/heimdall-tests/owner-v1-identity" \
  HEIMDALL_E2E_OWNER_LOCAL=1 \
  node --import ./tests/helpers/vaultEndpointHarness.ts \
    tests/e2e/bridge_real_enroll_e2e.mjs
```

The existing enrollment harness performs actual account/device approval and
vault delivery, then starts the real runtime. The owner-local case exercises
the same browser client functions as the UI, the actual HTTP relay and outbound
Bridge connection, SQLite commit, real process stop/restart, protected offline
listing, same-operation retries, forged signatures, and another-account
discovery/relay denial. It directly checks the disposable Hub database has no
legacy task/chain detail rows for the new local chain.

For the CLI leg only, the harness seeds a disposable authorized transport
instance and a private local-token record, using the production assertion encoder.
It bypasses provider launch, not token verification or routing. The real CLI,
local Bridge endpoint, Hub bridge/instance authentication and owner device/grant
checks all run. No scheduler or provider process is needed.

Focused storage tests additionally cover expired historical replay without
mutation permission, revoked read grants, operation conflicts, rollback on
receipt insertion failure, immutable genesis, account binding, and exclusive
writer locking:

```bash
nix develop --command odin test src/lib/owner_local \
  -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/owner-v1-storage
nix develop --command odin test src/hub/repository/sqlite \
  -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/owner-v1-registry
node --import ./tests/helpers/vaultEndpointHarness.ts \
  --test tests/ui_owner_local_contract_test.ts tests/ui_owner_registry_listing_test.ts
npm run typecheck
```

## Storage and boundaries

The owner stores `runtime.sqlite` in a private per-account directory below the
enrolled Bridge's existing vault state directory. SQLite uses WAL,
`synchronous=FULL`, foreign keys, and a separate lifetime SQLite OS lock for one
writer. Reopening verifies the same account/Bridge/key and advances incarnation.
The current signed directory is verified against the paired root, keyring and
persisted directory head. Local grants are read inside each transaction.
Bodies are decrypted only on the owner and persist locally for later expansion.

Mutations atomically write state, receipt, local change and signed publication
intent. A response requires commit success. Publication runs after commit;
failed publications remain pending and retry on subsequent owner requests.
Until publication succeeds, a locally created chain may be absent from Hub
listing. Receipts are retained; V1 rejects admission at 100,000 receipts or
1,000,000 local change entries rather than discarding replay evidence.
There is no compaction or tombstone reclamation API yet.

The Hub's new tables hold immutable signed genesis/account/owner/creator routing
and signed title/description listing envelopes only. Local chains have no row in
the legacy task engine, so its scheduler/reaper never acquires local authority.
Legacy chains continue using their existing routes. Registry publication is
account/owner authenticated, signature verified, monotonic and immutable across
retries. No migration of existing chains is performed.

Leases, fleet, scheduling, reviews, workflows, search/FTS, remote execution,
general grant management, backup/restore, key rotation and legacy migration
remain later expansion. This slice is not full M1 completion.

## Audit regression option

Add `HEIMDALL_E2E_OWNER_REGISTRY=1` to the disposable enrollment command above.
It creates 105 tasks through the real owner relay, renders the production panel,
deletes 104 tasks, and renders it again to verify the survivor behind tombstones.
It then enrolls synthetic creator/backup browsers, captures actual owner-signed
publications, rewinds only disposable Hub title metadata to simulate delayed
delivery, and revokes the creating browser through the signed directory API.
The real publication endpoint must accept the newer bound metadata and reject
a valid signed first publication whose creator was revoked. The actual owner
relay must reject a command signed by that revoked creator. No live database,
credentials, service, or deployment is used.

Focused HTTP regression command:

```bash
nix develop --command odin test src/hub/transport/http \
  -collection:odin_test=src \
  -define:ODIN_TEST_NAMES=owner_registry_bound_publication_survives_creator_revocation,owner_registry_http_pages_live_tombstones_bytes_and_accounts \
  -out:/tmp/owner-fixes-http-test
```
