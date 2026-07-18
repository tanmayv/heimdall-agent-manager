# Mockup proposal: Artifact viewer versions + persisted annotations

## Scope
Proposal for the UI changes in `ArtifactViewer` to satisfy:
- ART-V3 / ART-V4: browse retained versions and roll back
- ART-A1..A4: daemon-backed annotations with visible version linkage and one-time localStorage migration

## Mockup

```text
┌ Artifact Viewer ─────────────────────────────────────────────────────────────┐
│ project/spec.md                                      [Download] [Close]     │
│ markdown • 14 KB • updated 2m ago • Head v6                               │
│                                                                            │
│ Description text…                                                          │
│                                                                            │
│ Versions: [ Head v6 ▾ ]  [View history]  [Rollback…]                       │
│                                                                            │
│ Annotation mode [on/off]                     [Copy all annotations]         │
│                                                                            │
│ Preview area                                                               │
│ ──────────────────────────────────────────────────────────────────────────  │
│ Markdown / PNG preview for selected version                                │
│                                                                            │
│ Right panel: Annotations                                                   │
│  • Showing annotations for v6                                              │
│  • If viewing older version: “Viewing retained version v4” badge           │
│                                                                            │
│  [v6 • head] Text annotation summary                                       │
│  [v4 • older version] Region x=… y=…                                       │
│                                                                            │
│  Empty state: “No annotations for this version yet.”                       │
└────────────────────────────────────────────────────────────────────────────┘
```

## Proposal details

### 1) Version selector placement
- Put the version selector in the viewer meta strip, directly under the artifact description and above annotation controls.
- Default label: `Head vN`.
- Dropdown options ordered newest-first: `Head vN`, `vN-1`, `vN-2`, …
- Selecting a retained version updates both preview content and annotation query scope to that `version_no`.

### 2) Rollback affordance + confirmation
- Place `Rollback…` beside the version selector.
- Enabled only when viewing a non-head retained version.
- Confirmation dialog copy:
  - Title: `Roll back artifact to v4?`
  - Body: `This creates a new head version using the content and metadata from v4. History is preserved.`
  - Optional text input: `Reason (optional)`
  - Actions: `Cancel` / `Create rollback version`
- On success:
  - viewer switches to new head version
  - toast: `Rollback created head v7 from v4`

### 3) Annotation version visibility
- Every annotation row gets a compact badge:
  - `v6 • head` for current head annotations
  - `v4 • older version` when `annotation.version_no !== current head`
- Panel header reflects the current query scope:
  - `Showing annotations for v6`
  - `Showing annotations for retained version v4`
- If the user opens head while older-version annotations are visible via selection change, keep them in their own version scope rather than silently reattaching them.

### 4) Migration timing + failure messaging
- Migration runs once, non-blocking, after viewer metadata + head version load succeeds.
- Source: existing localStorage key `heimdall.artifact.annotations.v1`.
- Behavior:
  - migrate only annotations for the current artifact
  - default migrated annotations to current head version when no historic version info exists
  - clear the local key only after all uploads for that artifact succeed
- UI messaging:
  - no blocking spinner for migration
  - optional subtle toast on success: `Imported local annotations to daemon`
  - non-blocking warning toast on failure: `Some local annotations could not be imported yet; retrying later`

## Open UX choices / default recommendation
1. **Show rollback button always vs only for older versions**
   - Recommend: show only when selected version is not current head.
2. **Annotation panel scoped to selected version vs all versions**
   - Recommend: scope to selected version by default; this matches version-specific annotation semantics and avoids misleading overlays.
3. **Migration success UI**
   - Recommend: lightweight toast only; avoid permanent banner noise.

## Implementation notes (for after approval)
- Add RTKQ tags: `ArtifactVersions`, `ArtifactAnnotations`
- Keep formatting helpers in `artifactAnnotations.ts`, but remove localStorage as source of truth
- Add one-time migration helper used by `ArtifactViewer`
- Add explicit invalidation for rollback + annotation mutations
