# Artifacts Daemon MVP — Reverse-Engineered Status & Completion Analysis

Status: Rescued WIP under review
Branch: `heimdall-team-team-chain-19f5ab6d938-artifacts-daemon-mvp-uploadfetchcrud-art`
Rescue commit: `698123d` (pushed to origin)
Original plan: `docs/plans/artifacts-daemon-mvp.md`
Agent validation report: `reports/artifacts-validation-report.md` (on the branch)

## Context

The artifacts MVP chain (`chain-19f5ab6d938`) was in progress when a daemon
restart triggered a `task.db` schema-version reset (bumped 6→7 by the
caller-identity chain's Phase 5, "drop old DB, no migration"). That deleted the
chain's tracking metadata, but **all implementation files survived** in the git
worktree as uncommitted changes and have now been committed (`698123d`).

This doc reconstructs the plan from the code + the agent's own validation report,
scores completion, and lists what remains to finish.

## What was built (by file)

| File | Lines | Purpose |
|---|---|---|
| `src/contracts/artifacts.odin` | 223 | Shared types, `art_`/`artifact://` constants, kind/mime/ext allowlist, magic-byte checks |
| `src/daemon/artifact_db_service.odin` | 243 | `artifacts.db` sqlite metadata store (create/get/list/update/soft-delete) |
| `src/daemon/artifact_storage.odin` | 135 | Global blob store: sharded paths, write/read/delete, payload validation, base64 |
| `src/daemon/artifact_http.odin` | 517 | HTTP handlers: create/get/list/content/update/delete + inline-attach helpers |
| `src/daemon/http.odin` (mod) | — | New `write_binary_response` (binary/mime + `Content-Disposition`) |
| `src/daemon/rest_router.odin` (mod) | — | Routes for all 6 artifact endpoints |
| `src/daemon/server.odin` (mod) | — | `artifact_storage_init` / `artifact_db_init` wired into startup |
| `src/daemon/task_http.odin`, `user_rpc.odin`, `agent_rpc.odin` (mod) | — | Inline create-and-attach on comments / send-to-user |
| `src/lib/config/config.odin` (mod) | — | `artifact_max_bytes`, `artifact_blob_dir` parsing |
| `src/ctl/main.odin` (mod) | — | `ham-ctl artifacts create|get|fetch|list|update|delete` |
| `src/ui/api/daemonApi.ts` (mod) | — | create/fetchMeta/contentUrl/list/update/delete helpers |
| `src/ui/components/ArtifactViewer.tsx` | 219 | Viewer: markdown/png/jpeg/csv/html (sandboxed iframe) + metadata + download |
| `src/ui/components/Markdown.tsx`, `MarkdownBody.tsx` (new/mod) | — | `artifact://` recognition → artifact chip |
| `src/ui/components/MessageBubble.tsx` (mod) | — | Renders artifact chips in chat/comments |
| `tests/test_artifacts_backend_cli.py` | — | Backend + CLI roundtrip, allowlist, oversize, magic-byte, inline attach |
| `tests/test_artifact_ui_static.py` | — | UI helper exports, chip recognition, viewer debug IDs, CSV/iframe |

## Reconstructed requirements → completion

Derived from `docs/plans/artifacts-daemon-mvp.md` §12 acceptance criteria and the
agent's ART-/UI- REQ-IDs.

| REQ | Requirement | Status | Notes |
|---|---|---|---|
| ART-1 | Create markdown/png/jpeg/csv/html via daemon HTTP | ✅ Done | static + manual verified |
| ART-2 | `art_<hex>` IDs and `artifact://art_...` links | ✅ Done | |
| ART-3 | Global sharded FS blob store under `<data_dir>/artifacts/blobs` | ✅ Done | `<aa>/<bb>/art_<id>` sharding |
| ART-4 | sqlite metadata (`artifacts.db`), soft-delete row | ✅ Done | |
| ART-5 | Full CRUD create/get/list/content/update/delete + auth | ⚠️ Partial | **update byte-replace broken (ART-8)** |
| ART-6 | Content served with correct MIME + inline disposition | ✅ Done | `write_binary_response` |
| ART-7 | Reject unsupported kind, oversize, image magic-byte mismatch | ✅ Done | covered by test |
| ART-8 | **Update overwrites bytes in place (no versioning)** | ❌ **BLOCKER** | `POST /artifacts/update` w/ `content_base64` → HTTP 500 `blob_write_failed` |
| ART-9 | `ham-ctl artifacts create` + `fetch` roundtrip | ✅ Done | |
| ART-10 | Inline create-and-attach on comment / send-to-user (plan §5.2) | ✅ Done | daemon side wired in task_http/user_rpc |
| ART-11 | Shared `contracts/artifacts.odin`, config, all binaries build | ✅ Done | daemon/ctl/ui builds pass |
| UI-1 | daemonApi artifact helpers | ✅ Done | |
| UI-2 | `artifact://` recognition → chip in shared markdown renderer | ✅ Done | |
| UI-3 | Viewer: markdown re-render, img, CSV table, sandboxed HTML iframe, download, debug IDs | ✅ Done | |
| TEST-1 | Automated suite (backend/CLI/UI) | ⚠️ Gap | passes, but **no automated test for byte-replacement update** |
| VAL-1 | Independent validation clean | ❌ Blocked | gated on ART-8 |

**Rough completion: ~90%.** All architecture, storage, routing, CLI, UI, inline
attach, validation, and safety (allowlist, magic bytes, sandboxed HTML, soft
delete + 410) are implemented and independently verified. One functional bug and
one test gap remain.

## The single blocker: ART-8 (byte-replacement update)

Symptom (from validation report): `POST /artifacts/update` with replacement
`content_base64` returns HTTP 500 `blob_write_failed`, old bytes left in place.
Daemon log:
`artifact_write_blob: make_directory_all failed for .../blobs/33/1f/art_331f...`

Diagnosis: `artifact_write_blob` (`src/daemon/artifact_storage.odin:96`) is reused
for both create and update, writing to the same sharded path
(`<aa>/<bb>/art_<id>`). On **update** the blob file already exists at that path;
the write/overwrite path fails on the second write (the create path succeeds
because the file does not yet exist). The error message logs `abs_path` (the file)
while the call actually passes `parent_dir(abs_path)`, obscuring the real failure.
Likely fixes to evaluate:
- overwrite in place safely (truncate/replace existing file) instead of a
  make-dir + write that assumes a fresh path, and/or
- delete the existing blob before re-writing, and/or
- correct the failure logging to show the real errno/path.

This is a small, localized fix in `artifact_storage.odin` (+ the update handler in
`artifact_http.odin:168`).

## What remains to finish the MVP

1. **Fix ART-8**: make `artifact_write_blob` correctly overwrite an existing blob
   on update (localized change in `src/daemon/artifact_storage.odin`).
2. **Close TEST-1 gap**: add an automated test asserting byte-replacement update
   succeeds (bytes + sha + size change, metadata-only update still works).
3. **Re-run VAL-1**: independent validation clean once ART-8 lands.
4. **Housekeeping before merge**:
   - decide whether `config.toml` / `config-test.toml` doc-comment additions stay
     (they are harmless artifact-option docs);
   - confirm the branch rebases cleanly onto current `develop` (it forked from an
     older tip; `develop` has since gained the diff + caller-identity merges);
   - run full `nix build .#ham-daemon .#ham-ctl .#ham-wrapper` + `tsc` + the two
     artifact tests on top of current `develop`.

## Merge readiness

Not yet mergeable: one functional blocker (ART-8) + its missing test. Everything
else is implemented and verified. Recommended path: land the ART-8 fix + test on
this branch, rebase onto current `develop`, re-validate, then merge like the other
two chains.

## Note on the destructive-reset lesson

The Phase 5 "drop DB on version bump, no migration" behavior deleted an in-flight
chain on restart. Suggest a follow-up hardening: back up (rename) the old DB
before dropping, and/or log a loud warning listing what is being discarded, so an
in-progress chain is recoverable. Tracked separately from the artifacts work.
