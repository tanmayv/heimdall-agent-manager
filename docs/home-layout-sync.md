# Account-owned Home layout API

The backend stores one layout per authenticated user in `user_home_layouts`.
Migration `257_user_home_layouts.sql` is additive. Reads never create rows.
The existing browser layout contract remains `{version, widgets}`; `version` is
the server revision, with zero meaning no stored layout. Home uses the account
API by default; browser storage is retained only as a first-use import backup.

Both `GET` and `PUT /api/v1/me/home-layout` require human user authentication and
exactly one `X-Heimdall-Expected-User` header containing the account ID captured
by the client layout session. Normal session/OIDC authentication and device-proof
rules apply. Agent and bridge credentials cannot access these preferences. The
header asserts identity; only the authenticated context selects the owner.
Missing/empty/duplicate headers return `400 validation_failed`; an account mismatch
returns `409 account_mismatch`. A queued A request carrying the newly active B
cookie therefore cannot read or modify B's layout.

## Read

```http
GET /api/v1/me/home-layout
X-Heimdall-Expected-User: usr_example
```

A fresh account returns HTTP 200 and `ETag: "0"` without writing:

```json
{
  "data": {
    "version": 0,
    "widgets": [
      {"id": "activity", "width": 2, "hidden": false},
      {"id": "chains", "width": 1, "hidden": false},
      {"id": "uptime", "width": 1, "hidden": false},
      {"id": "fleet", "width": 2, "hidden": false}
    ]
  },
  "meta": {"request_id": "req_example", "server_time": "2026-11-25T15:00:00Z"}
}
```

All layout responses carry `Cache-Control: no-store`. Successful GET and PUT
responses include a strong quoted decimal `ETag` matching `data.version`.
Canonical reads retain known widgets in their saved desktop order, including
hidden positions, drop retired IDs and duplicates, and append missing widgets
with the defaults above. Legacy invalid widths/visibility/options use the browser
normalization defaults. Invalid persisted records produce an error rather than
being overwritten with defaults. The database revision is authoritative.

## Conditional write

```http
PUT /api/v1/me/home-layout
Content-Type: application/json
X-Heimdall-Expected-User: usr_example
If-Match: "0"

{"version":0,"widgets":[{"id":"fleet","width":1,"hidden":true,"options":{"mobile_order":2,"custom":{"theme":"dark"}}},{"id":"uptime","width":2,"hidden":false,"options":{"mobile_order":0}}]}
```

This creates revision 1 and returns HTTP 200 with `ETag: "1"` and the canonical
layout in the same success envelope. Fleet and Uptime remain in that desktop
order with their saved widths, visibility and options; Activity and Chains are
appended with defaults. Mobile ranks remain independent inside `options`.

The precondition must be exactly one strong quoted nonnegative decimal integer
without leading zeroes (except `"0"`). Weak tags, wildcard, lists, missing or
duplicate preconditions, and unquoted integers return `400 validation_failed`.
`body.version` must equal the precondition. Versions are JavaScript-safe integers
from 0 to 9007199254740991; a PUT precondition must be below the maximum so that
incrementing it remains safe. The client cannot supply owner fields.

Writes validate known unique IDs, width 1 or 2, a required boolean `hidden`, and
optional object-shaped `options`. Unknown top-level/widget fields are rejected;
bounded arbitrary JSON inside options is retained for compatibility. The body
is limited to 32768 bytes, each encoded options object to 8192 bytes, and options
nesting to depth 16. Optional `mobile_order` must be a nonnegative JavaScript-safe
integer. Missing known widgets are appended as on reads.

First creation uses `INSERT ... ON CONFLICT DO NOTHING`; updates use
`UPDATE ... WHERE owner_user_id=? AND revision=?`. Each is one atomic SQLite
statement. Concurrent first creates and stale updates produce HTTP 409:

```json
{
  "error": {
    "code": "conflict",
    "message": "The Home layout changed elsewhere.",
    "details": {"reason": "home_layout_version_conflict"},
    "class": "recoverable"
  },
  "meta": {"request_id": "req_example"}
}
```

The shared error envelope may include additional standard fields. Refused writes
leave the stored revision and payload unchanged. Clients should explicitly reload
after a conflict; a retry must never blindly overwrite the winner.

## Browser synchronization

Each Home mount captures the authenticated account and its lifecycle generation.
It first GETs the account layout. A nonzero server revision always wins over any
browser backup. Only a successful version-zero GET permits an import from
`heimdall:home-layout:<encoded-user-id>`. The backup must parse and normalize to
a bounded valid layout. Its old revision is discarded; import PUT uses version
zero. The conditional-create loser performs one GET of the winner, without
retrying its PUT. Missing/corrupt backups use defaults. Failed GETs never trigger
import. The backup key is neither deleted nor updated by server synchronization.

Edits remain optimistic and are debounced for 500ms, with one save in flight per
session. Newer edits survive an older successful reply and save against the new
confirmed revision. A typed `409 conflict` restores the last confirmed layout
and shows the changed-elsewhere message until **Reload saved layout** succeeds.
`409 account_mismatch` is an account error, not a layout conflict. Network,
server, authentication and initial-load failures show an error and disable
editing until a successful reload; they cannot silently save only to the browser.

Visible focus, online and visibility-change events coalesce a refresh. A refresh
waits for unsaved/in-flight edits to settle, and a response started before an edit
cannot replace that edit. There is no background polling or layout WebSocket.
Desktop order is the widget array; mobile order is the independent
`options.mobile_order`. Activity remains omitted on mobile. Width, visibility,
hidden positions, options, menus, mobile sheets and keyboard/touch ordering keep
their existing behavior.

Switching accounts invalidates the old session generation, aborts pending work,
and fences delayed replies (including A→B→A). The expected-user header also
protects against a queued request encountering a switched cookie at the server.
Navigation flushes a pending edit only while the same captured account and
generation remain valid. A switched-account request cannot write another user's
row, even if cancellation happens too late to stop transmission.

## Verification boundaries

Focused sibling tests cover defaults/canonical reads, schema and size bounds,
service guards before storage access, migration upgrade/idempotence/reopen,
owner isolation, concurrent first-create/update CAS across separate connections,
HTTP handler persistence/conflicts/validation, agent denial, and switched-cookie
account fencing. Controlled UI transport tests cover session generations,
in-flight replies, refresh coalescing, failure recovery and safe imports.

`tests/fixtures/home-layout-hub` is an isolated loopback test Hub composition:
the production TCP HTTP server, router, session authentication, Home handler,
service and real SQLite repositories. Its test-only login route mints a normal
SQLite-backed session in place of completing OIDC. It is not a production Hub
entrypoint or a test of the identity provider. Never point it at a live database.

`tests/fixtures/home-widgets/capture-sync.mjs` launches this composition and Vite
with fresh evidence/database/profile directories, and uses independent Chromium
browser contexts. Layout requests use the production browser adapter and real
HTTP/SQLite route. Other widget data remains a visual fixture and is not evidence
of Activity, Uptime, task-chain or Fleet persistence. The harness records actual
wire revisions/statuses, native desktop/mobile editing, a process restart and
DB reopen, offline recovery, conditional imports and switched-cookie refusal.
The sibling SQLite tests separately exercise upgrade from the pre-layout schema
and preserve the historical migration ledger. Screenshots cover 1440px desktop
and 390px mobile, including saved layout and recovery states.

Build the fixture with the repository's pinned toolchain, then run the harness
with an available Chromium binary and a new output directory:

```bash
nix develop --command bash scripts/dev-odin.sh build-debug tests/fixtures/home-layout-hub
HOME_HUB_BINARY=/path/printed/by/build \
HOME_CHROMIUM=/path/to/chromium \
HOME_CAPTURE_SHA="$(git rev-parse HEAD)" \
HOME_CAPTURE_TREE="$(git rev-parse HEAD^{tree})" \
node tests/fixtures/home-widgets/capture-sync.mjs /new/evidence/directory
```

Ports default to UI 5196, Hub 5197 and CDP 9346; override with `HOME_UI_PORT`,
`HOME_HUB_PORT`, and `HOME_CDP_PORT`. Existing suites/builds are delegated to the
designated Test Runner. Final commit/tree, commands, warning/skip counts, browser
reports and independent review are recorded in the integration task handoff;
source coverage descriptions here do not assert that every suite is leak-free.
