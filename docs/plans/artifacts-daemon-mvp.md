# Plan: Artifacts Support in Daemon (MVP)

Status: Draft
Owner: TBD
Scope: MVP only. Attaching artifacts to task chains for review is explicitly out of scope (phase 2).

## 1. Goal

Add first-class **artifacts** to Heimdall: uploadable/fetchable files with a global
filesystem blob store and a metadata database, addressable by a stable
`artifact://<id>` link, creatable from coordinator chat and task comments, and
viewable inside the Electron app.

Supported types for MVP:

| Kind      | MIME                       | Extensions        | UI viewer          |
|-----------|----------------------------|-------------------|--------------------|
| markdown  | `text/markdown`            | `.md`             | rendered Markdown  |
| png       | `image/png`                | `.png`            | `<img>`            |
| jpeg      | `image/jpeg`               | `.jpg`, `.jpeg`   | `<img>`            |
| csv       | `text/csv`                 | `.csv`            | table preview      |
| html      | `text/html`                | `.html`, `.htm`   | sandboxed iframe   |

Non-goals for MVP:
- No version control / history (create, update, delete only — update overwrites).
- No task-chain attachment/review workflow (phase 2).
- No thumbnail generation, no transforms, no search/full-text index.
- No access-control beyond the existing daemon token auth.

## 2. Identity & Addressing

- `artifact_id`: daemon-generated, format `art_<random-hex>` (mirror existing
  `agt_`/`uct_` token style; reuse the random id generator used for tokens/ids).
- Public link: `artifact://<artifact_id>`.
  - This is an opaque logical reference. Resolution is always through the daemon,
    never a direct filesystem path (keeps the blob store relocatable and safe).
  - The Electron app and any renderer resolve `artifact://<id>` to
    `GET <daemonUrl>/artifacts/<id>/content` for bytes and
    `GET <daemonUrl>/artifacts/<id>` for metadata.
- Rationale for a custom scheme (not `http://`): links embedded in chat/comments
  must survive independent of daemon host/port and must be explicitly recognized
  by the UI so we can render an inline viewer instead of a raw hyperlink.

## 3. Storage Model

### 3.1 Blob store (global, filesystem)

- Root: `<server_data_dir>/artifacts/blobs/`.
  - `server_data_dir` is already resolved in `src/daemon/server.odin`
    (`server_data_dir`, tilde-expanded). Follow the same `os.make_directory_all`
    bootstrap used by every `*_db_init`.
- Layout: shard by id prefix to avoid huge flat dirs:
  `<root>/<first2>/<artifact_id>.<ext>`
  - Example: `.../artifacts/blobs/a3/art_a3f19c...e2.png`.
- Blobs are content bytes only. All descriptive data lives in the DB.
- Global by design: artifacts are **not** namespaced per project/chain in MVP.
  Metadata records optional `project_id` / origin references for later filtering,
  but the blob store itself is flat/global.

### 3.2 Metadata DB (`artifacts.db`)

New file `src/daemon/artifact_db_service.odin`, following the exact pattern of
`src/daemon/vcs_db_service.odin` (sqlite3 via `os.process_exec`, `sql_text`
escaping helper, `*_db_init(data_dir)` creating `<data_dir>/artifacts/`).

Table:

```sql
CREATE TABLE IF NOT EXISTS artifacts (
  artifact_id      TEXT PRIMARY KEY,
  name             TEXT NOT NULL,          -- user-facing display name / filename
  kind             TEXT NOT NULL,          -- markdown|png|jpeg|csv|html
  mime             TEXT NOT NULL,
  ext              TEXT NOT NULL,
  size_bytes       INTEGER NOT NULL,
  sha256           TEXT NOT NULL DEFAULT '',
  rel_path         TEXT NOT NULL,          -- path under blobs root
  creator_type     TEXT NOT NULL,          -- user|agent
  creator_id       TEXT NOT NULL,          -- identity id from token
  project_id       TEXT NOT NULL DEFAULT '',
  origin_kind      TEXT NOT NULL DEFAULT '', -- chat|comment|direct
  origin_ref       TEXT NOT NULL DEFAULT '', -- chain_id/task_id/message_id if any
  description      TEXT NOT NULL DEFAULT '',
  created_unix_ms  INTEGER NOT NULL,
  updated_unix_ms  INTEGER NOT NULL,
  deleted          INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_artifacts_creator ON artifacts(creator_type, creator_id);
CREATE INDEX IF NOT EXISTS idx_artifacts_project ON artifacts(project_id);
CREATE INDEX IF NOT EXISTS idx_artifacts_origin  ON artifacts(origin_kind, origin_ref);
```

Delete is a soft-delete (`deleted=1`) in MVP; the blob is removed from disk on
delete, and the row is retained so dangling `artifact://` links resolve to a
clear "deleted" 410 response instead of a confusing 404.

Odin record + functions (mirroring `Vcs_Workspace_Record` helpers):
`Artifact_Record`, `artifact_db_init`, `artifact_db_insert`,
`artifact_db_get(id)`, `artifact_db_update_meta`, `artifact_db_mark_deleted`,
`artifact_db_list(filter)`, `artifact_write_json(builder, rec)`.

## 4. Daemon HTTP API

Register in `src/daemon/server.odin` alongside existing `POST /...` prefix routes
and/or in `src/daemon/rest_router.odin` for the path-segment style GETs. New file
`src/daemon/artifact_http.odin` (mirrors `vcs_http.odin`).

Auth: reuse `task_author_and_type_from_body` (returns identity id + is_user) for
the JSON POST routes so we capture `creator_type`/`creator_id` from the token.
For GET content/metadata, accept token via `?token=` query param (same approach
`vcs_http.odin` uses for `?file=`) or `Authorization` header.

### 4.1 Create

`POST /artifacts/create`
```jsonc
{
  "agent_token": "<token>",
  "name": "report.md",
  "kind": "markdown",          // optional; inferred from name/mime if omitted
  "mime": "text/markdown",     // optional; inferred from kind/ext
  "content_base64": "...",     // required: bytes, base64-encoded
  "project_id": "",            // optional
  "origin_kind": "direct",     // direct|chat|comment
  "origin_ref": "",            // chain/task/message id (optional)
  "description": ""            // optional
}
```
Response: `{ "ok": true, "artifact": { ...metadata... }, "link": "artifact://art_..." }`

Validation:
- Reject unsupported `kind`/`mime`/`ext` (allowlist in section 1).
- Enforce a max size (config: `daemon.artifact_max_bytes`, default e.g. 10 MiB).
- Decode base64 server-side; compute `size_bytes` + `sha256`; write blob; insert row.

> MVP transport note: the existing `write_response` hardcodes
> `Content-Type: application/json` and request bodies are handled as strings, so
> uploads use **base64-in-JSON**. This is simplest and reuses all current
> plumbing. A future phase can add true `multipart/form-data` + streaming.

### 4.2 Fetch metadata

`GET /artifacts/<artifact_id>` → `{ "ok": true, "artifact": {...} }`
`GET /artifacts?project_id=&creator_id=&origin_ref=&limit=` → `{ "ok": true, "artifacts": [...] }`

### 4.3 Fetch content (bytes)

`GET /artifacts/<artifact_id>/content`
- Streams raw bytes with the stored `mime` and
  `Content-Disposition: inline; filename="<name>"`.
- **Requires a new binary response helper** `write_binary_response(client, status,
  mime, bytes, extra_headers)` in `src/daemon/http.odin` because the current
  `write_response` is JSON-only. Keep CORS headers identical to `write_response`.
- Deleted artifact → `410 Gone` (JSON error body).

### 4.4 Update

`POST /artifacts/update`
```jsonc
{ "agent_token": "...", "artifact_id": "art_...",
  "name": "...", "description": "...",
  "content_base64": "..." }   // optional: replaces bytes in place (no versioning)
```
- Metadata-only update if `content_base64` omitted.
- If content provided: overwrite blob at same `rel_path` (or new path if ext
  changed), recompute size/sha, bump `updated_unix_ms`.

### 4.5 Delete

`POST /artifacts/delete`
```jsonc
{ "agent_token": "...", "artifact_id": "art_..." }
```
- Removes blob file, sets `deleted=1`. Returns `{ "ok": true }`.

## 5. Chat & Comment Integration

Two ways to attach an artifact when talking to the coordinator or commenting:

### 5.1 Reference an already-created artifact (primary MVP path)

- Any message/comment body may contain an `artifact://art_...` token.
- The daemon does **not** need to parse it for storage; it's just text. The UI
  (and any agent renderer) recognizes the scheme and renders the inline viewer.
- CLI/agents create the artifact first (`/artifacts/create`), then paste the
  returned link into their chat/comment body.

### 5.2 Inline create-and-attach (convenience)

Extend the coordinator-send and task-comment endpoints with optional
`artifact` fields so a single call both stores the blob and posts the message:

- Coordinator send (`chainViewSlice.sendToCoordinator` → daemon chat send):
  accept optional `artifact_content_base64`, `artifact_name`, `artifact_kind`.
  Daemon creates the artifact (origin_kind=`chat`, origin_ref=`chain_id`), then
  appends `\n\nartifact://<id>` to the message body before persisting.
- Task comment (`handle_task_comment` in `src/daemon/task_http.odin`): same
  optional fields, origin_kind=`comment`, origin_ref=`task_id`.

This keeps the message store unchanged (link is just body text) while giving a
one-shot UX. Implement 5.1 first; 5.2 is a thin wrapper and can land second.

## 6. CLI (`ham-ctl`) Support

Add an `artifacts` command group in `src/ctl/main.odin` (mirror the `tasks`/`chat`
dispatch blocks):

```
ham-ctl artifacts create --token <t> --file <path> [--name <n>] [--kind <k>]
                         [--project <id>] [--description <text>]
ham-ctl artifacts get    --token <t> --id art_...            # prints metadata json
ham-ctl artifacts fetch  --token <t> --id art_... --out <path>   # writes bytes
ham-ctl artifacts list   --token <t> [--project <id>] [--json]
ham-ctl artifacts update --token <t> --id art_... [--file <path>] [--name <n>]
ham-ctl artifacts delete --token <t> --id art_...
```
`create`/`update` read the file, base64-encode, and POST. `fetch` GETs
`/content` and writes raw bytes. This is what agents use to produce artifacts.

## 7. Electron / UI Support

### 7.1 API layer (`src/ui/api/daemonApi.ts`)

- `createArtifact({ daemonUrl, token, name, kind, contentBase64, ... })`
- `fetchArtifactMeta({ daemonUrl, token, artifactId })`
- `artifactContentUrl({ daemonUrl, token, artifactId })` → returns the
  `/artifacts/<id>/content?token=...` URL for direct use in `<img src>` / iframe.
- `listArtifacts(...)`, `updateArtifact(...)`, `deleteArtifact(...)`.

### 7.2 Link resolution + viewer

- Extend `src/ui/components/Markdown.tsx` to recognize `artifact://art_...`
  tokens (currently only `http(s)` links are linkified). Render them as an
  **artifact chip** that opens an `ArtifactViewer`.
  - Keep the existing XSS discipline: never inject raw HTML from artifact bodies;
    for markdown artifacts, run their text back through the same Markdown renderer;
    for html artifacts use a sandboxed `<iframe sandbox>` pointed at the content
    URL (no `allow-same-origin` unless required, documented as a known tradeoff).
- New component `src/ui/components/ArtifactViewer.tsx`:
  - markdown → fetch text, render via `Markdown`.
  - png/jpeg → `<img src={contentUrl}>`.
  - csv → fetch text, parse into a simple `<table>` (cap rows/cols for preview).
  - html → sandboxed iframe.
  - Shows metadata header (name, kind, size, creator, created time) and a
    "Download" action.
- Add `data-debug-id`s per AGENTS.md UI rules, e.g.
  `artifact-viewer`, `artifact-viewer-download-btn`, `artifact-chip-${artifactId}`.

### 7.3 Redux

- New `artifactsSlice.ts` (or fold into `chainViewSlice`) caching metadata by id
  and thunks `fetchArtifactMeta`, `createArtifact`, `deleteArtifact`.
- Chat/comment rendering paths already flow through `Markdown`, so once the
  renderer recognizes the scheme, existing coordinator chat and task comments get
  artifact chips automatically.

## 8. Contracts

Add `src/contracts/artifacts.odin` defining shared types/constants:
- `Artifact_ID`, route constants (`/artifacts/create`, `/artifacts/update`,
  `/artifacts/delete`, `/artifacts/{id}`, `/artifacts/{id}/content`), the
  `artifact://` scheme constant, allowed kind/mime tables.
- All three binaries import this so contract drift is caught at build time
  (per AGENTS.md contracts guidance).

## 9. Config

`config.toml` `[daemon]` additions (parsed in `src/lib/config/config.odin`):
- `artifact_max_bytes` (default 10485760).
- `artifact_blob_dir` (optional override; default `<data_dir>/artifacts/blobs`).

## 10. Security / Safety Notes

- Enforce the type allowlist on **both** create and serve; never trust
  client-provided mime alone — cross-check against `ext`/magic bytes for images.
- HTML artifacts are the main XSS risk → always render inside a sandboxed iframe
  served from the daemon content endpoint; never inline into the chat DOM.
- `artifact://` never exposes a filesystem path; resolution is daemon-mediated.
- Size cap + base64 decode guard against memory blowups in the string-based
  request pipeline.
- Keep the daemon's existing token auth on every route; record creator identity
  from the token, not from client-supplied fields.

## 11. Work Breakdown (suggested tasks)

1. Contracts: `src/contracts/artifacts.odin` (types, routes, allowlist).
2. DB service: `src/daemon/artifact_db_service.odin` + wire `artifact_db_init`
   into `server.odin` init sequence.
3. Blob store helpers + `write_binary_response` in `http.odin`.
4. HTTP handlers: `src/daemon/artifact_http.odin` (create/get/list/content/
   update/delete) + route registration.
5. Config plumbing (`artifact_max_bytes`, blob dir) in `src/lib/config`.
6. CLI: `artifacts` command group in `src/ctl/main.odin`.
7. Chat/comment inline create-and-attach (optional 5.2) in chat + task_http.
8. UI API layer in `daemonApi.ts`.
9. `ArtifactViewer.tsx` + `Markdown.tsx` `artifact://` recognition + chips.
10. Redux `artifactsSlice` + wiring into chain chat / comments.
11. Tests: daemon roundtrip (create→get→content→update→delete, type allowlist,
    size cap, deleted→410), CLI create/fetch, UI link-recognition + viewer
    gating (mirror existing `tests/` python static/e2e patterns).

## 12. Acceptance Criteria (MVP)

- Can create markdown/png/jpeg/csv/html artifacts via daemon HTTP and via
  `ham-ctl artifacts create`, receiving an `artifact://` link.
- Can fetch metadata and raw content by id; content served with correct mime.
- Can update (metadata and/or bytes, no versioning) and delete (soft, blob
  removed, link resolves to 410).
- Coordinator chat / task comment bodies containing `artifact://` render an
  inline viewer chip in the Electron UI for all five types.
- Unsupported types rejected; oversize rejected; deleted artifacts handled
  gracefully; existing token auth enforced on all routes.
- New logic covered by tests; existing tests pass.
```
