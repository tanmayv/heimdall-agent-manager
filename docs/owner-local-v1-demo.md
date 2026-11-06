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
`stale_cursor`. Hub listing pages use `after_chain` and `after_task` from the
last returned entry, with at most 100 entries per request.

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
  --test tests/ui_owner_local_contract_test.ts
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
