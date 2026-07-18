# Plan: Artifact versioning + persisted annotations

## Goal

Make artifacts durable, editable, and reviewable:

1. **Editable artifacts** — update an existing artifact (bytes and/or metadata) after
   creation. (Update already exists but overwrites in place with no history.)
2. **Versioning** — keep the last **5** versions of each artifact's bytes+metadata in
   the DB so an artifact can be **rolled back** to a prior version.
3. **Persisted annotations** — move annotations from browser `localStorage` into the
   daemon DB, and record **which artifact version** each annotation was applied to.

## Current state (as-is)

- `src/contracts/artifacts.odin` — `Artifact_Metadata`, kinds/mime/ext allowlist,
  `artifact://` link helpers, routes (`/artifacts/create|update|delete`, `GET /artifacts`,
  `GET /artifacts/{id}`, `GET /artifacts/{id}/content`).
- `src/daemon/artifact_db_service.odin` — single `artifacts` table (one row per artifact,
  no history). `INSERT OR REPLACE`, `UPDATE`, `mark_deleted`, `get`, `list`, `find_origin`.
- `src/daemon/artifact_storage.odin` — sharded blob store keyed by artifact_id.
  **`artifact_write_blob` overwrites the same sharded path** (`aa/bb/art_...`), so the
  previous bytes are lost on update. `ARTIFACT_DEFAULT_MAX_BYTES = 10MB`.
- `src/daemon/artifact_http.odin` — `handle_post_artifact_update` overwrites blob + row
  in place (no version kept).
- `src/ctl/main.odin` — `artifacts create|get|fetch|list|update|delete`.
- `src/ui/utils/artifactAnnotations.ts` — annotations live **only in browser
  localStorage** (`heimdall.artifact.annotations.v1`); text + image contexts already
  modeled (`ArtifactAnnotationRecord`). No version linkage.
- `src/ui/components/ArtifactViewer.tsx` — annotation UI (create/edit/remove/copy),
  all backed by the localStorage util.
- `src/ui/api/endpoints/artifacts.ts` — RTKQ endpoints: `listArtifacts`,
  `fetchArtifactMeta`, content URL, create/update/delete.

### Key gaps to close

- Blob overwrite destroys old bytes → **must write version-addressed blobs**.
- No history table → **must add `artifact_versions`** and cap at 5.
- Annotations are ephemeral + client-only → **must add `artifact_annotations`** table
  with `version_no` linkage and REST/ctl/RTKQ wiring.

## Design

### Data model

New tables (in `artifacts.db`, created in `artifact_db_init`):

```sql
-- One row per stored version. Keep at most 5 per artifact (prune oldest).
CREATE TABLE IF NOT EXISTS artifact_versions (
  artifact_id      TEXT NOT NULL,
  version_no       INTEGER NOT NULL,      -- monotonic, starts at 1
  name             TEXT NOT NULL,
  kind             TEXT NOT NULL,
  mime             TEXT NOT NULL,
  ext              TEXT NOT NULL,
  size_bytes       INTEGER NOT NULL,
  sha256           TEXT NOT NULL,
  rel_path         TEXT NOT NULL,         -- version-addressed blob path
  description      TEXT NOT NULL,
  author_type      TEXT NOT NULL,
  author_id        TEXT NOT NULL,
  change_reason    TEXT NOT NULL DEFAULT '',
  created_unix_ms  INTEGER NOT NULL,
  PRIMARY KEY (artifact_id, version_no)
);
CREATE INDEX IF NOT EXISTS idx_artifact_versions_aid
  ON artifact_versions(artifact_id, version_no DESC);

-- Durable annotations, tied to the artifact version they were applied to.
CREATE TABLE IF NOT EXISTS artifact_annotations (
  annotation_id    TEXT PRIMARY KEY,
  artifact_id      TEXT NOT NULL,
  version_no       INTEGER NOT NULL,      -- artifact version the annotation targets
  author_type      TEXT NOT NULL,
  author_id        TEXT NOT NULL,
  context_type     TEXT NOT NULL,         -- 'text' | 'image'
  context_json     TEXT NOT NULL,         -- serialized TextAnnotationContext/ImageAnnotationContext
  comment          TEXT NOT NULL,
  created_unix_ms  INTEGER NOT NULL,
  updated_unix_ms  INTEGER NOT NULL,
  deleted          INTEGER NOT NULL DEFAULT 0,
  deleted_unix_ms  INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_artifact_annotations_aid
  ON artifact_annotations(artifact_id, deleted, created_unix_ms);
```

The existing `artifacts` row stays as the **current/head** projection and gains a
`current_version_no INTEGER NOT NULL DEFAULT 1` column (migration: default existing rows
to 1 and backfill a version-1 row from the current blob on first touch).

### Version-addressed blobs (breaking the overwrite)

- `artifact_blob_rel_path` becomes version-aware:
  `aa/bb/art_.../v{version_no}` (keep the shard prefix; add a `v{n}` leaf).
- `artifact_write_blob(artifact_id, version_no, data)` writes to the versioned path and
  never overwrites a different version.
- Head content (`GET /artifacts/{id}/content`) resolves `current_version_no` → its
  `rel_path`. Add optional `?version=<n>` to fetch a specific version's bytes.
- Pruning: after inserting version N, delete versions `<= N-5` (row + blob).

### REST surface

- `POST /artifacts/update` (existing) — now **creates a new version** instead of
  overwriting: bump `version_no`, write versioned blob (or copy prior bytes if
  metadata-only change), insert `artifact_versions` row, update `artifacts` head +
  `current_version_no`, prune to 5. Accepts optional `change_reason`.
- `GET /artifacts/{id}/versions` — list up to 5 versions (metadata only).
- `GET /artifacts/{id}/content?version=<n>` — fetch a specific version's bytes.
- `POST /artifacts/rollback` — `{artifact_id, version_no, [change_reason]}`:
  materialize the target version as a **new head version** (roll-forward copy, so history
  stays append-only and itself capped at 5). Returns updated head.
- Annotations:
  - `POST /artifacts/annotations/create` — `{artifact_id, version_no?, context_type,
    context_json, comment}` (default `version_no` = current head).
  - `GET /artifacts/{id}/annotations[?version=<n>]` — list (non-deleted).
  - `POST /artifacts/annotations/update` — `{annotation_id, comment}`.
  - `POST /artifacts/annotations/delete` — `{annotation_id}` (soft delete).

All under the same `artifact_authorize_identity` auth used by existing handlers.
Author (`author_type`/`author_id`) captured from the authorized identity.

### Contracts

Add to `src/contracts/artifacts.odin`:
- `Artifact_Version` struct + route consts (`ROUTE_ARTIFACTS_VERSIONS_SUFFIX`,
  `ROUTE_ARTIFACTS_ROLLBACK`, `ROUTE_ARTIFACTS_ANNOTATIONS_*`).
- `Artifact_Annotation` struct (mirrors UI `ArtifactAnnotationRecord`: id, artifact_id,
  version_no, context_type, context_json, comment, author, timestamps).
- `ARTIFACT_MAX_VERSIONS :: 5`.

### CLI (`ham-ctl artifacts ...`)

- `artifacts update ... [--change-reason <text>]` (already replaces bytes/meta; now versioned).
- `artifacts versions --artifact-id <id>` — list versions.
- `artifacts rollback --artifact-id <id> --version <n> [--change-reason <text>]`.
- `artifacts fetch ... [--version <n>]`.
- `artifacts annotate --artifact-id <id> [--version <n>] --context-type text|image
  --context-json <json> --comment <text>`.
- `artifacts annotations --artifact-id <id> [--version <n>]`.
- `artifacts annotation-update --annotation-id <id> --comment <text>`.
- `artifacts annotation-delete --annotation-id <id>`.

### UI

- New RTKQ endpoints in `src/ui/api/endpoints/artifacts.ts`:
  `fetchArtifactVersions` (`ArtifactVersions:<id>`), `rollbackArtifact`,
  `fetchArtifactAnnotations` (`ArtifactAnnotations:<id>`),
  `createArtifactAnnotation`, `updateArtifactAnnotation`, `deleteArtifactAnnotation`.
  Mutations own precise invalidation (`Artifact:<id>`, `ArtifactVersions:<id>`,
  `ArtifactContent:<id>`, `ArtifactAnnotations:<id>`).
- Add `ArtifactVersions` and `ArtifactAnnotations` tag types to `heimdallApi.ts`.
- `src/ui/utils/artifactAnnotations.ts` — keep the record shape + markdown/summary
  helpers (still used for formatting/clipboard), but **replace the localStorage store**
  with the daemon-backed RTKQ endpoints. Provide a one-time best-effort migration that
  pushes any existing localStorage annotations to the daemon, then clears the key.
- `src/ui/components/ArtifactViewer.tsx` — read annotations from RTKQ; annotations show
  their `version_no`; add a version selector + "Roll back to this version" control.
  Annotations created while viewing version N record `version_no = N`.

### Federation note

`GET /federation/artifacts/{id}` content stays head-only for v1 (versions/annotations are
local-daemon durable state; cross-daemon version sync is out of scope).

## Requirements (REQ-IDs)

- **ART-V1** — Updating an artifact MUST create a new version and MUST NOT destroy prior
  version bytes/metadata (up to the 5-version cap).
- **ART-V2** — At most **5** versions are retained per artifact; the oldest is pruned
  (row + blob) when a 6th is created.
- **ART-V3** — `GET /artifacts/{id}/versions` returns the retained versions; content is
  fetchable per version via `?version=<n>`.
- **ART-V4** — Rollback materializes a chosen prior version as the new head (append-only
  history), and head content/meta reflect it.
- **ART-A1** — Annotations are stored durably in the daemon DB (not localStorage) and
  survive restart.
- **ART-A2** — Each annotation records the `version_no` it was applied to.
- **ART-A3** — Annotation create/list/update(comment)/delete work via REST, ctl, and UI;
  list excludes soft-deleted.
- **ART-A4** — Existing localStorage annotations are migrated to the daemon once, then the
  local key is cleared (best-effort, non-blocking).
- **ART-C1** — Backward compatibility: existing artifacts (pre-migration) get a synthetic
  version 1 from their current blob on first read/update; `GET /content` with no version
  still returns head.

## Task plan (chain)

| # | Task | REQ-IDs | Depends on |
|---|------|---------|------------|
| 1 | Contracts: version/annotation structs, routes, `ARTIFACT_MAX_VERSIONS` | ART-V*, ART-A* | — |
| 2 | DB: `artifact_versions` + `artifact_annotations` tables, `current_version_no`, backfill/migration, prune-to-5 helper, CRUD | ART-V1..V4, ART-A1..A3, ART-C1 | 1 |
| 3 | Storage: version-addressed blob paths; write/read/delete by version; keep head resolution | ART-V1..V3, ART-C1 | 1 |
| 4 | HTTP: versioned update, `/versions`, `/content?version`, `/rollback`, annotations CRUD handlers + routes in `rest_router.odin` | ART-V*, ART-A1..A3 | 2, 3 |
| 5 | CLI: `versions`, `rollback`, `--version` fetch, annotate/annotations/annotation-update/annotation-delete, `--change-reason` | ART-V3,V4, ART-A3 | 4 |
| 6 | UI RTKQ endpoints + tags; ArtifactViewer version selector/rollback; annotations from daemon; localStorage migration | ART-V3,V4, ART-A1..A4 | 4 |
| 7 | Tests: daemon versioning/prune/rollback + annotations backend test; UI static boundary/tag test; migration test | all | 5, 6 |

## Validation strategy

- Backend test (Python, model on `tests/` artifact tests): create → update ×6 →
  assert exactly 5 versions retained, oldest pruned (row+blob gone), each version's bytes
  fetchable, rollback produces new head matching target bytes/sha, annotations persist
  with correct `version_no`, soft-delete hides from list, restart-durability.
- `ham-ctl artifacts versions|rollback|annotate|annotations` happy-path JSON asserts.
- UI: `tsc -b` + `vite build`; extend `test_ui_service_boundaries.py` for the new tags
  (no orphan invalidation); annotation migration unit check.

## Risks / open questions

- **Blob path change** — old artifacts use `aa/bb/art_...` (no `v{n}`). Migration must
  treat that as version 1 and either move it to `.../v1` or record its existing rel_path
  as version 1's `rel_path`. Prefer recording the existing path as v1 (no file moves).
- **Metadata-only update** — should it consume a version slot? Decision: **yes**, it
  creates a new version (copying prior bytes' rel_path/sha) so annotations' `version_no`
  linkage stays meaningful and rollback of metadata works. (Revisit if churn is a concern.)
- **Annotation validity across versions** — an annotation targets a specific `version_no`;
  the UI should visually flag annotations whose `version_no != current head` as "on older
  version" rather than silently repositioning them.
- Federation version sync intentionally deferred.

## Guardrails

- Reuse existing auth (`artifact_authorize_identity`), blob store, and sanitizers.
- Keep the `artifacts` head row as the single current projection; versions/annotations are
  additive tables.
- New RTKQ tags must have providers (no orphan invalidation) — enforced by the boundary test.
- Do not break existing create/get/list/delete/content behavior or the `artifact://` link.
