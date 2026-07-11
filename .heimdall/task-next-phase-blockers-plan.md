# Task API Next-Phase Blockers Implementation Plan

Target project: `/Users/tanmayvijay/heimdall-agent-manager`
Chain: `chain-19f5046a70b`
Planner task: `task-19f50481d46`
Status: planning only. **No coding or task activation until reviewer/risk LGTM and explicit user/proxy approval.**

## Approved/current RCA summary

The current task read model exposes only `not_actionable_reason`, a single flat string generated mainly in `src/daemon/task_queries.odin`. Promotion/review/blocking logic exists, but is scattered across task query/service helpers and is not exposed as a structured API contract. UI consumers currently pass through and render the flat string.

Key implementation constraint: "next phase" is status-dependent:

- `planning` and system-promotable `blocked` tasks target `queued`.
- `queued` tasks target `in_progress`.
- `review_ready` tasks target `approved`.
- Manual `blocked` tasks may have no automatic target phase and should expose the manual block reason rather than pretending there is a universal transition.

Known risks validated by RCA:

- Dependency graphs may contain nonexistent IDs and cycles, so recursive blocker traversal needs a visited set, missing-task handling, max depth, and truncation markers.
- Recursive expansion on list endpoints can inflate payloads; use bounded/default depth and keep the object compact.
- Keep `not_actionable_reason` for backward compatibility.

## Proposed API contract

Add a structured `next_phase` object to task read responses while preserving `not_actionable_reason` unchanged.

Suggested shape:

```json
{
  "next_phase": {
    "current_status": "planning",
    "target_status": "queued",
    "actionable": false,
    "summary_code": "deps_unmet",
    "summary_text": "Waiting for 1 dependency task to be approved.",
    "depth": 0,
    "max_depth": 3,
    "truncated": false,
    "cycle_detected": false,
    "blockers": [
      {
        "kind": "dependency_unapproved",
        "task_id": "task-...",
        "status": "review_ready",
        "reason_code": "required_review_pending",
        "reason_text": "Waiting for required reviewer LGTM.",
        "depth": 1,
        "truncated": false,
        "cycle_detected": false,
        "dependency": { "...": "same compact next_phase summary" }
      }
    ]
  }
}
```

Initial blocker kinds:

- `chain_inactive`
- `dependency_unapproved`
- `dependency_missing`
- `dependency_cycle`
- `dependency_depth_truncated`
- `assignee_unassigned`
- `assignee_busy`
- `assignee_pending_review`
- `queued_behind`
- `required_review_pending`
- `reviewer_busy`
- `manual_block`
- `system_block`
- `unknown_not_actionable`

Depth policy:

- Default max dependency recursion depth: `3`.
- Hard cap: `5` if a future query parameter is added; for this implementation, prefer one daemon constant and no user-controlled unbounded recursion.
- On depth cap, emit `dependency_depth_truncated` and set `truncated: true` instead of continuing.
- On revisit of a task id in the current walk, emit `dependency_cycle` and set `cycle_detected: true`.

## Implementation tasks after approval

### Task A — Backend structured next-phase/read-model helpers

Assignee: `coder@swe-team`
Required reviewers: `reviewer@swe-team`, `risk-analyst@swe-team`

Scope:

- Implement structured blocker computation in `src/daemon/task_queries.odin` near existing task read-model helpers.
- Reuse existing gating helpers where safe: dependency blocking, active-slot blockers, reviewer active-slot blockers, required LGTM checks, chain status checks, and latest/manual blocked status body.
- Compute explicit `target_status` and `actionable` based on current status.
- Expand dependency blockers recursively with visited-set, missing-task, max-depth, truncation, and cycle markers.
- Compute pending required reviewers from task participants/votes rather than relying only on `reviewer_agent_instance_id`.
- Keep `not_actionable_reason` behavior unchanged.

Acceptance criteria:

- `task_write_state_json` emits `next_phase` for task reads without removing or renaming existing fields.
- Manual blocked tasks expose `manual_block` and do not claim a normal automatic target phase.
- Missing dependencies are distinct from unapproved existing dependencies.
- Multiple pending required reviewers can be represented.
- Recursive dependency summaries terminate for cycles and max-depth cases.

### Task B — REST/API plumbing and CLI observability

Assignee: `coder@swe-team`
Required reviewers: `reviewer@swe-team`, `risk-analyst@swe-team`

Scope:

- Ensure `GET /tasks`, `GET /tasks/{id}`, chain task list endpoints, and agent/user RPC task responses all include the new serialized field through the shared task JSON writer.
- Update `ham-ctl tasks show/list/next` output only if needed to preserve valid JSON/object output; no special CLI formatting is required for this phase.
- Document the field in the nearest API/help/docs location if one exists for task response schemas.

Acceptance criteria:

- Current clients that ignore unknown fields continue working.
- `ham-ctl tasks show --task-id <id>` includes `next_phase` in the JSON response.
- Existing `not_actionable_reason` string remains present and stable.

### Task C — Backend regression tests for blocker semantics

Assignee: `tester@swe-team` with `coder@swe-team` support
Required reviewers: `reviewer@swe-team`, `risk-analyst@swe-team`

Scope:

Add focused tests, likely `tests/test_task_next_phase_blockers.py` or equivalent project harness, covering:

1. Planning task blocked by unapproved dependency includes `dependency_unapproved` and nested dependency next-phase summary.
2. Missing dependency ID includes `dependency_missing`.
3. Recursive dependency chain is bounded and marks `truncated` at max depth.
4. Dependency cycle emits `dependency_cycle` and terminates quickly.
5. `review_ready` with multiple `lgtm_required` participants reports pending reviewers and clears blockers after LGTM votes.
6. Manual blocked task exposes `manual_block` and status body/reason.
7. Queued task blocked by assignee busy/queued-ahead work reports `assignee_busy` or `queued_behind` as appropriate.
8. Chain not active / planning chain reports `chain_inactive` for otherwise promotable tasks.
9. Backward compatibility: `not_actionable_reason` still exists in the response.

Acceptance criteria:

- New tests fail on current behavior and pass with implementation.
- Tests assert structured blocker kinds, relevant task/reviewer IDs, and cycle/truncation flags rather than only free-form text.
- Cycle/depth tests include a timeout or bounded assertion to catch nontermination regressions.

### Task D — UI consumption/rendering

Assignee: `coder@swe-team`
Required reviewers: `reviewer@swe-team`, `risk-analyst@swe-team`

Scope:

- Update `src/ui/store/taskSlice.ts` normalization to preserve `next_phase` / `nextPhase`.
- Update `src/ui/components/App.tsx` task detail/board blocker display to prefer structured `next_phase.summary_text` and top-level blocker details, with fallback to `notActionableReason` for old daemon responses.
- Keep recursive dependency rendering compact: show top-level blocker and one nested summary by default, with truncation/cycle labels when present.
- Avoid blocking existing task board rendering if the field is absent or malformed.

Acceptance criteria:

- Existing UI still renders against older API responses that only contain `not_actionable_reason`.
- New structured responses display clearer blocker text for dependency, review, manual block, and cycle/truncation cases.
- UI does not attempt to render unbounded recursive trees.

### Task E — UI/API integration tests

Assignee: `tester@swe-team`
Required reviewers: `reviewer@swe-team`, `risk-analyst@swe-team`

Scope:

- Add/update UI tests around task normalization and rendering, likely near `tests/test_ui_chain_task_surface.py` or a new focused test.
- Add API/e2e smoke to confirm task list/detail endpoints include `next_phase` and existing task screens tolerate the new field.

Acceptance criteria:

- UI test demonstrates fallback to `not_actionable_reason` when `next_phase` is missing.
- UI test demonstrates rendering a structured dependency/review blocker when `next_phase` is present.
- Existing task board tests continue to pass.

### Task F — Final validation and review package

Assignee: `tester@swe-team`
Required reviewers: `reviewer@swe-team`, `risk-analyst@swe-team`

Validation commands/evidence to collect:

- `python3 tests/test_task_next_phase_blockers.py` (new)
- `python3 tests/test_reviewer_gating.py`
- `python3 tests/test_task_reviewer_assignment.py`
- `python3 tests/test_task_vote_auto_approval.sh`
- `python3 tests/test_tasks.sh`
- `python3 tests/test_ui_chain_task_surface.py` or the new/updated UI blocker rendering test
- `npm run typecheck`
- `npm run build` if UI or API TypeScript changes are included and runtime permits
- Targeted manual smoke:
  - create a task blocked by an unapproved dependency;
  - inspect `ham-ctl tasks show` and verify `next_phase.blockers[0].kind=dependency_unapproved`;
  - create/inspect a missing dependency and verify `dependency_missing`;
  - create/inspect a review task with pending `lgtm_required` participant and verify `required_review_pending`;
  - verify the chain task UI displays a human-readable structured blocker summary.

Acceptance criteria:

- Backend, UI, and compatibility tests pass.
- Review package includes before/after JSON snippets for dependency, pending-review, manual-block, and cycle/depth cases.
- Reviewer and risk analyst LGTM are recorded before the chain is considered implementation-complete.

## Approval gate

Before any coding task starts:

1. This plan receives required LGTM from `reviewer@swe-team` and `risk-analyst@swe-team`.
2. Principal/coordinator obtains explicit user/proxy approval for the API contract and implementation plan.
3. Only then create/activate implementation tasks for coder/tester/reviewer, or explicitly move pre-created tasks from planning to ready.

Until then, this plan is documentation only and no source files should be changed.
