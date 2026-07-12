# Memory subject field removal design

## Scope
Design only for the broader removal of `subject_key` / `subject_agent` after Phase 1 (`48341d6`) stopped accepting them at CLI/RPC boundaries.

## RCA
`subject_agent` and `subject_key` currently still serve three different jobs:
1. legacy persistence compatibility in `memory.db`
2. public API/UI/notification targeting
3. expertise dedup/archive bucketing

That coupling is why the Phase 1 boundary deprecation did not finish the removal. Remaining daemon/UI/wrapper code still reads or emits the legacy fields, so they continue to leak into public behavior.

## Decision
Remove `subject_agent` and `subject_key` from active `Memory_Record` / `Memory_Event` contracts in one pass, but keep the physical DB columns temporarily as deprecated storage-only compatibility fields.

Reasoning:
- keeping the fields in the contracts would prolong public leakage and keep new code dependent on them
- the remaining references are broad but still tractable in one implementation phase
- DB column removal is the risky part, not contract removal

Implementation consequence:
- `src/contracts/memory_provider.odin` becomes canonical-target only
- DB read code may use an internal legacy row/normalizer helper, but public/service contracts do not
- physical column/index drop is deferred to a later cleanup after restart/migration compatibility is proven

## Canonical public response shape
Keep the existing flat JSON style and remove all public `subject_*` fields.

### Record JSON
```json
{
  "memory_id": "mem_...",
  "proposal_id": "proposal_...",
  "scope": "Project|Team_Project|Template|Personal",
  "team_id": "team-...",
  "template_key": "template-slug",
  "project_ids": ["project-a"],
  "role_keys": ["coder"],
  "task_chain_types": ["coding"],
  "type": "fact|habit|episode|expertise|skill|template",
  "title": "...",
  "body": "...",
  "status": "pending|active|archived|rejected",
  "reason": "...",
  "evidence": "...",
  "metadata_json": "...",
  "source_task_id": "task-...",
  "version": 2,
  "created_unix_ms": 0,
  "updated_unix_ms": 0
}
```

Rules:
- `team_id` only for `Team_Project`
- `template_key` only for `Template`
- `project_ids` / `role_keys` / `task_chain_types` are always arrays in JSON
- `Personal` remains internal-only to non-system callers, as today

### History / event JSON
History responses should use the same targeting fields and omit `subject_agent` / `subject_key` entirely.
At minimum each event includes:
- `event_id`, `memory_id`, `proposal_id`
- `scope`, `team_id?`, `template_key?`, `project_ids`, `role_keys`, `task_chain_types`
- `reason`, `evidence`, `author`, `source_task_id`, `created_unix_ms`

### Notification payloads
Replace `{subject_agent}` semantics with either:
- a new `target` string for human-readable notifications, or
- structured `team_id` / `template_key` / `project_ids` fields plus templates that do not require a legacy subject field

Preferred default text: target-aware if available, otherwise omit target.

## Read normalization and backfill
Normalize legacy rows at DB-read boundary before filtering, bootstrap selection, JSON serialization, or expertise dedup.

### Normalization rules
When canonical fields are missing, derive them from `scope + subject_key`:
- `Project` + `pr:<project>` -> `project_ids=[project]`
- `Team_Project` + `tp:<team>:<project>` -> `team_id=<team>`, `project_ids=[project]`
- `Template` + `tmpl:<template>` -> `template_key=<template>`
- `Personal` + `agent:<agent>` -> internal personal target only

### Source precedence
1. explicit canonical fields already stored on the row
2. derived values from legacy `subject_key`
3. legacy `subject_agent` only for internal personal fallback / migration diagnostics, not public serialization

### Backfill behavior
- No destructive rewrite in this phase
- If `project_ids` is empty and can be safely derived from `subject_key`, backfill it lazily (best-effort) or during startup migration
- `team_id` and `template_key` may be derived at read time in this phase if no dedicated DB columns are added yet
- Rows that cannot be parsed remain readable by `memory_id`, but they should be excluded from target-based matching unless canonical fields are otherwise valid; log them for follow-up

This preserves restart compatibility for existing rows that only have legacy targeting.

## Expertise dedup / archive key
Replace `(scope, subject_key)` with a canonical expertise bucket key:

```text
scope
+ team_id              (Team_Project only)
+ template_key         (Template only)
+ normalized project_ids
+ normalized role_keys
+ normalized task_chain_types
+ normalized title slug
```

Archive rule on approval:
- archive other active `expertise` memories with the same bucket key and different `memory_id`

Why include title:
- using only scope/project/role/task-chain targeting is too broad and can archive unrelated expertise entries for the same target
- title-scoping preserves the current “one active version of the same expertise topic” intent without depending on `subject_key`

## Rollout order
1. **Backend contract + compatibility layer**
   - remove `subject_*` from contracts and public serializers
   - add legacy-row normalization
   - switch filters/bootstrap/applicability logic to canonical targets
   - switch notification payloads/templates off legacy subject fields
2. **UI / API wrapper cleanup**
   - stop sending/storing/displaying subject fields
   - consume `team_id`, `template_key`, `project_ids`, `role_keys`, `task_chain_types`
   - remove subject-based filters/forms/details/search terms
3. **Wrapper / prefs / prompts**
   - replace `{subject_agent}` message templates
   - update memory-event parsing in `src/wrapper/main.odin`
   - update `src/prompts/memory_audit_task_4.md`
4. **Docs + tests**
   - update active docs from subject-based targeting to canonical targeting
   - add regression coverage for normalization/backfill, restart, applicable-memory bootstrap, expertise dedup, and public JSON absence of subject fields
5. **Later cleanup**
   - drop legacy DB columns/indexes only after compatibility is stable

## Compatibility risks
- **UI breakage**: current UI/wrappers still expect legacy fields; backend serializer removal and UI/wrapper updates must land together or behind a tiny compatibility adapter.
- **Bootstrap regressions**: if normalization happens after filter/applicability checks, old rows with only `subject_key` will stop applying.
- **Notification regressions**: saved user-pref templates containing `{subject_agent}` will render poorly unless migrated or given fallback behavior.
- **Over-archiving expertise**: dedup must use the canonical bucket above, not only project/team scope.
- **Docs/test churn**: archived transcript fixtures contain many historical `subject_*` strings; update active tests/docs first and only regenerate fixtures if they are asserted in live tests.

## Required validation for implementation tasks
- daemon memory tests for list/show/history/applicable on legacy rows
- restart regression with pre-existing rows containing only `scope + subject_key`
- expertise archive regression proving unrelated titles are not archived
- wrapper/bootstrap regression proving project/team/template targeting still selects the right memories
- UI regression proving subject filters/fields are gone and canonical targets are shown

## Approval gate
Implementation should not start until the operator explicitly approves this design in chain chat.

### Approval request to route via coordinator
Proposed operator question:
- Approve one-pass contract removal of public `subject_agent` / `subject_key` while keeping DB columns temporarily as internal compatibility storage?
- Approve the canonical public response shape (`scope`, `team_id`, `template_key`, `project_ids`, `role_keys`, `task_chain_types`, no public `subject_*` fields)?
- Approve legacy-row normalization from `scope + subject_key` and the new expertise bucket key that includes normalized title?

### Approval evidence
- 2026-07-12: coordinator routed the approval request through chain chat `chain-19f5577322e` in message `chatmsg_1783851241192`.
- 2026-07-12: operator `operator@local` replied `"Approved"` in chain chat; approval message `chatmsg_1783851264721` (`created_unix_ms=1783851264721`).
- Coordinator recorded the durable approval evidence on task `task-19f55b38590` in comment `cmt_1783851283420`.
- Approved scope covered:
  1. one-pass removal of public `subject_agent` / `subject_key` from `Memory_Record` / `Memory_Event` while keeping DB columns temporarily for compatibility
  2. canonical public response shape without public `subject_*` fields
  3. legacy-row normalization from `scope + subject_key`
  4. expertise dedup/archive key based on canonical targets plus normalized title
  5. rollout order and compatibility risks documented for backend, UI, wrapper, docs, and tests
