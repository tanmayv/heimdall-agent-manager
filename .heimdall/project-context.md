# Heimdall Agent Manager project context

Target project directory: `/Users/tanmayvijay/heimdall-agent-manager`.

## Current chain: coordinator chat visibility bug

User reported in chain `chain-19f500dc5ca` that a chat reply sent by `principal@swe-team` did not appear in the coordinator chat. Desired outcome is to investigate and fix coordinator/chain chat visibility so user-facing coordinator messages are visible in the expected coordinator chat surface.

Process constraints:
- Investigation/RCA before implementation.
- Principal creates only lightweight requirement/discovery framing and delegates detailed planning.
- Researcher should inspect current state and concrete code paths.
- Separate validator/risk reviewer should validate RCA before implementation planning.
- Planner owns detailed implementation task chain after RCA approval.
- No coding until user/proxy approval of plan.

## New chain: UI project creation bug

User reported that creating a project from the UI fails. Chain `chain-19f5030c63d` was created for investigation-first handling.

Initial lightweight brief:
- Target project: `/Users/tanmayvijay/heimdall-agent-manager`.
- Treat as a product/API/state bug, not a UI-only fix until RCA confirms.
- Investigate New Project modal/form, UI API client, daemon project create HTTP/service/store path, auth/validation, and UI refresh after creation.
- Need concrete reproduction evidence and logs/errors before implementation.
- Researcher should own RCA, another agent should validate, Planner should create detailed implementation tasks only after RCA/approval.
- Current blocker: assigning `researcher@swe-team` to the new chain failed with `assignee is not a member of this chain team`, matching the known team-membership product gap captured in `.heimdall/teams-active-bugs.md`.

## New chain: Task API next-phase blockers

User requested task API support to return blockers for a task's next phase. Chain `chain-19f5046a70b`, root task `task-19f5046a70b`.

Lightweight brief:
- Target project: `/Users/tanmayvijay/heimdall-agent-manager`.
- API should explain why a task is not advancing: dependency not complete, required reviewer/LGTM pending, manual blocked status/reason, assignee busy, chain not active, etc.
- If the blocker is another task, include that task's own next-phase completion/blocker conditions recursively.
- Must include cycle/loop protection and bounded depth so blocker calculation cannot hang on cyclic dependencies or malformed data.
- Current-state/RCA should inspect task API/read models, task promotion logic, review vote logic, and UI consumers before implementation.
