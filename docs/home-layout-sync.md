# Account-owned Home layout API

The backend stores one layout per authenticated user in `user_home_layouts`.
Migration `257_user_home_layouts.sql` is additive. Reads never create rows.
The existing browser layout contract remains `{version, widgets}`; `version` is
the server revision, with zero meaning no stored layout. UI synchronization and
browser import are implemented separately from this backend contract.

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

## Backend verification

Focused sibling tests cover defaults/canonical reads, schema and size bounds,
service guards before storage access, migration upgrade/idempotence/reopen,
owner isolation, concurrent first-create/update CAS across separate connections,
real HTTP persistence/conflicts/validation, agent denial, and switched-cookie
account fencing. Package-wide checks and independent review are required before
integration. UI import, cross-device refresh and browser interaction evidence
belong to the subsequent UI/integration tasks.
