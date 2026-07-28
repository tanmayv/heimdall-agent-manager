# Plan: Hub Artifacts Upload, Library, Chat Attachments, and Agent CLI Access

Status: Implemented (Phase 1 & 2)
Owner: Owl Team
Scope: Heimdall Hub rewrite (`src/hub`, `src/ui`, `src/ctl`, `src/bridge`)

## Goal

Make artifacts first-class in the Hub rewrite:

- Browser/UI uploads use **multipart/form-data**.
- Hub stores and serves artifacts in a binary-safe way.
- Library lists all user artifacts and opens a dedicated artifact viewer page.
- Conversation chat supports paste/upload attachments and renders attached artifacts.
- `ham-ctl hub artifacts ...` supports robust user artifact upload/fetch.
- `ham-ctl agent artifacts ...` lets agents upload, list, read, and fetch artifacts through the bridge without user tokens.

## Non-goals for first implementation pass

- Full artifact version history and rollback.
- Annotation workflows beyond preserving existing UI scaffolding where already present.
- Large streaming/chunked uploads beyond a configured max artifact size.
- Public unauthenticated artifact URLs.
- Cross-user artifact sharing.

## Current State Summary

There is partial support already:

- Hub routes exist for basic artifacts:
  - `GET /api/v1/artifacts`
  - `POST /api/v1/artifacts`
  - `GET /api/v1/artifacts/:id`
  - `GET /api/v1/artifacts/:id/content`
  - `PATCH /api/v1/artifacts/:id`
  - `DELETE /api/v1/artifacts/:id`
- UI has `ArtifactUpload.tsx`, `LibraryPage.tsx`, and `ArtifactViewer.tsx`.
- Chat messages already carry `artifact_ids_json` in Hub storage.
- Agent bridge local endpoint can relay `agent.artifacts.create` to Hub.

Important gaps:

- UI currently uses base64/legacy-ish upload helpers instead of multipart.
- Hub artifact create currently reads JSON fields like `content`, not multipart file parts.
- Content fetch returns JSON content rather than raw bytes with correct MIME.
- Active `AppShell` has `/library` nav but does not mount the full Library/viewer route.
- Current routed `ConversationThreadPage` does not upload/paste artifacts.
- `ham-ctl agent artifacts` only supports create, not list/show/fetch/read.

## Data Model

Artifact metadata should be owner-scoped and durable.

Required metadata fields:

```text
artifact_id        string  art_<random>
owner_user_id      string
kind               string  markdown|png|jpeg|csv|html|text|json|diff as supported
name               string
mime               string
ext                string
size_bytes         int
sha256             string
blob_ref           string  path/ref to stored bytes, or DB BLOB ref if chosen
agent_id           string
agent_instance_id  string
chain_id           string
task_id            string
project_id         string
origin_kind        string  library_upload|conversation_chat|clipboard_chat|task_comment|agent_upload|...
origin_ref         string  conversation_id|chain_id|task_id|agent_instance_id|...
created_at         timestamp
updated_at         timestamp
deleted_at         timestamp optional
```

Implementation can either:

1. extend current `artifacts` table, or
2. add a migration for missing columns such as `mime`, `ext`, `sha256`, `origin_kind`, `origin_ref`, and `deleted_at`.

Prefer filesystem/blob storage for bytes if artifacts can be several MiB. SQLite metadata remains the index/source of truth.

## Backend API

### 1. Create artifact: browser multipart path

Canonical UI endpoint:

```http
POST /api/v1/artifacts
Content-Type: multipart/form-data
Authorization/cookie auth as normal
```

Multipart fields:

```text
file                 required binary part
name                 optional, defaults to uploaded filename
kind                 optional, inferred from filename/MIME when missing
mime                 optional, inferred from file part Content-Type when missing
description          optional
project_id           optional
origin_kind          optional
origin_ref           optional
agent_id             optional
agent_instance_id    optional
chain_id             optional
task_id              optional
```

Response:

```json
{
  "artifact": {
    "artifact_id": "art_...",
    "name": "screenshot.png",
    "kind": "png",
    "mime": "image/png",
    "ext": ".png",
    "size_bytes": 12345,
    "sha256": "...",
    "project_id": "",
    "origin_kind": "conversation_chat",
    "origin_ref": "chat_...",
    "created_at": "...",
    "updated_at": "...",
    "link": "artifact://art_...",
    "renderer": "image"
  },
  "link": "artifact://art_..."
}
```

### 2. Create artifact: JSON/base64 fallback

Keep a binary-safe JSON fallback for CLI/bridge paths:

```http
POST /api/v1/artifacts
Content-Type: application/json
```

Body:

```json
{
  "name": "report.md",
  "kind": "markdown",
  "mime": "text/markdown",
  "content_base64": "...",
  "description": "",
  "project_id": "",
  "origin_kind": "agent_upload",
  "origin_ref": "inst_..."
}
```

This is not the primary browser path, but it is useful for:

- `ham-ctl hub artifacts upload` when multipart is not implemented in the low-level client yet.
- `ham-ctl agent artifacts upload` over bridge JSONL, because bridge-local JSONL should not carry raw binary.

### 3. List artifacts

```http
GET /api/v1/artifacts?limit=50&offset=0&project_id=&origin_kind=&origin_ref=&creator_id=&kind=&include_deleted=false
```

Response should include a list plus pagination metadata.

Required behavior:

- Only return artifacts owned by the authenticated user.
- Filter on `project_id`, `origin_kind`, `origin_ref`, `agent_instance_id`, `chain_id`, and `kind` where supported.
- Sort newest updated first.

### 4. Fetch metadata

```http
GET /api/v1/artifacts/:artifact_id
```

Returns metadata only, never bytes.

### 5. Fetch content

```http
GET /api/v1/artifacts/:artifact_id/content
```

Returns raw bytes:

```http
Content-Type: <artifact mime>
Content-Disposition: inline; filename="<safe-name>"
Cache-Control: private, max-age=60
```

No token-in-query for the UI path. Use existing cookie/bearer auth.

### 6. Update metadata

```http
PATCH /api/v1/artifacts/:artifact_id
Content-Type: application/json
```

Supported initially:

```json
{ "name": "new-name.md", "description": "..." }
```

Byte replacement can be a later explicit route unless trivial.

### 7. Delete

```http
DELETE /api/v1/artifacts/:artifact_id
```

Prefer soft-delete metadata plus blob deletion or tombstone behavior. Deleted artifact links should produce a clear `410 Gone` or `404` with JSON error.

## Backend Implementation Notes

### Multipart parsing

Add a small bounded multipart parser in Hub HTTP transport, or a transport helper:

```text
parse_multipart_form(req.body_bytes, content_type, max_bytes)
```

Requirements:

- Parse boundary from `Content-Type`.
- Support normal fields and one `file` part.
- Preserve raw file bytes.
- Reject missing boundary, malformed parts, multiple large file parts, and oversized body.
- Avoid treating arbitrary binary as UTF-8 text.

If current request storage is string-only, first add byte-preserving request-body plumbing or explicitly store body as bytes alongside string.

### Validation

- Enforce max upload size from config, default around 10 MiB.
- Infer kind from extension/MIME when possible.
- Validate supported combinations.
- Check image magic bytes for PNG/JPEG.
- Compute SHA-256 on bytes.
- Sanitize filenames for `Content-Disposition`.

### Content response

Add/verify raw binary response support in Hub HTTP transport. Do not JSON-wrap content responses.

## UI Implementation Plan

### 1. Artifact API client

Update `src/ui/api/endpoints/artifacts.ts` and `src/ui/api/daemonApi.ts`:

- `createArtifact` should accept a `File`/`Blob` path and send `FormData`.
- Do not set `Content-Type` manually for multipart.
- Fetch content with authenticated `fetch`, then:
  - `text()` for markdown/text/csv/html previews.
  - `blob()` + `URL.createObjectURL` for images.
- Remove token-in-query content URL usage for Hub rewrite routes.

### 2. Library route

Mount real routes in active `AppShell`:

```text
/library
/library/artifacts/:artifactId
```

Library requirements:

- List all artifacts for current user.
- Filter/search by name, kind, project, agent/instance, chain/origin.
- Upload button uses multipart.
- Click artifact opens `/library/artifacts/:artifactId`.
- Keep all interactive elements debug-ID compliant.

### 3. Artifact viewer page

Viewer page requirements:

- Dedicated route, not modal-only.
- Metadata header: name, kind, MIME, size, origin, created/updated.
- Markdown rendered via existing Markdown renderer.
- Image rendered via blob object URL.
- CSV/text shown in readable monospace/table fallback.
- HTML either unsupported initially or rendered in a sandboxed iframe if already safe.
- Download button fetches bytes and saves locally.

### 4. Chat composer attachments

In routed `ConversationThreadPage`:

- Add upload button using `ArtifactUploadButton` or a new multipart-aware equivalent.
- Add paste handling for images/files:
  - paste PNG screenshot -> upload immediately
  - paste supported file -> upload immediately where browser exposes file
- Maintain composer attachment state:

```ts
type ComposerAttachment = {
  artifactId: string;
  link: string;
  name: string;
  kind: string;
  mime: string;
  sizeBytes: number;
};
```

- Show attachment chips/cards above the textarea.
- Send body plus `artifact_ids`.
- Clear attachments after send.
- Optimistic message includes the attachment cards and `Sending` status.

### 5. Chat message rendering

- Extend normalized `ChatMessage` with `artifactIds` and optionally `artifacts` metadata.
- Render artifact chips/cards under the message body.
- Also detect `artifact://art_...` links in markdown and route them to `/library/artifacts/:id`.
- If metadata is not loaded yet, show a generic artifact chip by ID and fetch metadata lazily.

## ham-ctl User Mode

Add robust user-facing commands:

```bash
ham-ctl hub artifacts list [--kind <kind>] [--project-id <id>] [--origin-ref <id>]
ham-ctl hub artifacts upload --file <path> [--name <name>] [--kind <kind>] [--mime <mime>] [--project-id <id>] [--origin-kind <kind>] [--origin-ref <id>]
ham-ctl hub artifacts show --artifact-id <art_...|artifact://art_...>
ham-ctl hub artifacts fetch --artifact-id <art_...|artifact://art_...> --out <path>
ham-ctl hub artifacts cat --artifact-id <art_...|artifact://art_...>
ham-ctl hub artifacts delete --artifact-id <art_...|artifact://art_...>
```

Behavior:

- `upload --file` should prefer multipart if the HTTP client supports it.
- If multipart is too large a lift in the current Odin HTTP client, use JSON `content_base64` first, but keep the UI multipart requirement intact.
- `fetch --out` writes raw bytes exactly.
- `cat` refuses non-text artifacts unless `--force` is provided.
- Parse both `art_...` and `artifact://art_...`.
- Infer name/kind/mime from file path when omitted.

## ham-ctl Agent Mode

Agents use bridge-local auth and should not need user tokens.

Commands:

```bash
ham-ctl agent artifacts list [--kind <kind>] [--project-id <id>] [--origin-ref <id>]
ham-ctl agent artifacts upload --file <path> [--name <name>] [--kind <kind>] [--mime <mime>] [--description <text>]
ham-ctl agent artifacts show --artifact-id <art_...|artifact://art_...>
ham-ctl agent artifacts fetch --artifact-id <art_...|artifact://art_...> --out <path>
ham-ctl agent artifacts cat --artifact-id <art_...|artifact://art_...>
```

Bridge-local JSONL should use base64 envelopes for binary safety:

```json
{
  "name": "report.md",
  "kind": "markdown",
  "mime": "text/markdown",
  "content_base64": "..."
}
```

Add/extend agent action methods:

```text
agent.artifacts.create
agent.artifacts.list
agent.artifacts.show
agent.artifacts.content
```

Hub agent-action routes:

```http
POST /api/v1/agent-actions/artifacts/create
POST /api/v1/agent-actions/artifacts/list
POST /api/v1/agent-actions/artifacts/show
POST /api/v1/agent-actions/artifacts/content
```

For content fetch through bridge, return JSON with base64:

```json
{
  "artifact_id": "art_...",
  "name": "report.md",
  "kind": "markdown",
  "mime": "text/markdown",
  "content_base64": "..."
}
```

`ham-ctl agent artifacts fetch` decodes bytes to `--out`.

## Agent Chat Integration

When an agent uploads an artifact, the CLI should print both JSON and the stable link:

```json
{
  "artifact_id": "art_...",
  "link": "artifact://art_..."
}
```

Agents can then include the link in chat replies:

```bash
ham-ctl agent chat send --body "Uploaded test report: artifact://art_..."
```

Future convenience command:

```bash
ham-ctl agent chat send --body "See attached" --artifact-id art_...
```

This should populate `artifact_ids` instead of relying only on body links.

## Security and Auth

- UI artifact requests use current Hub auth cookies or bearer token injection from Electron auth gate.
- Do not put long-lived user tokens in artifact content URLs.
- Agent artifact access is mediated through bridge-local instance tokens and Hub `X-Heimdall-Instance-Token` validation.
- Artifact IDs are opaque but not authorization by themselves.
- Only artifact owner can fetch metadata/content.
- Validate all ownership for project/agent/chain/task context fields.

## Suggested Implementation Order

1. Backend raw content response support.
2. Backend artifact metadata normalization and binary-safe storage.
3. Backend multipart parser and `POST /api/v1/artifacts` multipart support.
4. JSON/base64 fallback on same create route.
5. Fix frontend artifact API to multipart and authenticated content fetch.
6. Mount `/library` and `/library/artifacts/:id` in `AppShell`.
7. Wire Library upload and viewer page.
8. Add chat composer upload/paste and attachment state.
9. Render message artifact cards/chips.
10. Add `ham-ctl hub artifacts upload/fetch/cat` robustness.
11. Add `ham-ctl agent artifacts list/show/content/fetch/cat` through bridge actions.
12. Add tests and deployment checks.

## Tests and Validation

Backend:

```bash
nix develop -c odin check src/hub -collection:odin_test=src
```

Frontend:

```bash
npm run typecheck -- --pretty false
npx vite build
```

Manual/API smoke tests:

```bash
# multipart upload
curl -i -X POST \
  -H "Authorization: Bearer <hut_token>" \
  -F "file=@README.md;type=text/markdown" \
  -F "name=README.md" \
  https://hub.mundus.in/api/v1/artifacts

# metadata
curl -i -H "Authorization: Bearer <hut_token>" \
  https://hub.mundus.in/api/v1/artifacts/<art_id>

# content
curl -i -H "Authorization: Bearer <hut_token>" \
  https://hub.mundus.in/api/v1/artifacts/<art_id>/content
```

CLI smoke tests:

```bash
ham-ctl hub artifacts upload --file README.md --name README.md
ham-ctl hub artifacts fetch --artifact-id art_... --out /tmp/README.md
cmp README.md /tmp/README.md

ham-ctl agent artifacts upload --file /tmp/test-log.md --name test-log.md
ham-ctl agent artifacts fetch --artifact-id art_... --out /tmp/test-log-copy.md
cmp /tmp/test-log.md /tmp/test-log-copy.md
```

UI smoke tests:

1. Upload Markdown in Library; it appears in list and opens rendered.
2. Upload PNG in Library; it appears in list and opens as image.
3. Paste screenshot into conversation composer; attachment chip appears.
4. Send message with attachment; optimistic message shows attachment and `Sending`.
5. Refresh conversation; attachment persists and opens viewer page.
6. Agent uploads artifact via `ham-ctl agent`; user can see it in Library.

## Acceptance Criteria

- UI uploads use multipart/form-data.
- Hub stores artifact bytes losslessly and serves raw bytes with correct MIME.
- Library lists all current user's artifacts.
- `/library/artifacts/:id` renders Markdown and images in a full page.
- Conversation composer supports paste/upload attachments.
- Sent chat messages persist `artifact_ids` and render attachments after reload.
- `ham-ctl hub artifacts upload/fetch` round-trips binary files.
- `ham-ctl agent artifacts upload/fetch` round-trips binary files through the bridge without user tokens.
- No artifact content URL requires token query parameters.
