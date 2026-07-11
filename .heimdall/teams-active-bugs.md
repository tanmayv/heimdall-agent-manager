# Teams Active Bugs / Product Gaps

Target project: `/Users/tanmayvijay/heimdall-agent-manager`

Last updated: 2026-07-11

## 1. Chain team placeholders block assignment to real swe-team agents

Status: fixed in working tree. RCA: chain teams were created with generated slot agents and task assignment correctly validated chain-team membership, but there was no supported mutation path to add/bind real runtime agents to the chain team. Fix: added authenticated `/teams/add-member` plus `ham-ctl teams add-member --token ... --team ... --role ... --agent-instance-id ...`; the member stores a stable slot and routes to the real agent, so assignment validation passes without direct SQL.

Relevant Teams v1 docs:

- `docs/teams-v1/02-team-kinds.md` — defines fixed role slots for each team kind, including coding roles.
- `docs/teams-v1/03-lifecycle.md` — `ensure_agent` must route by durable team-member row / scoped `(team_id, role_key, role_index)`, not by global role lookup.
- `docs/teams-v1/08-http-and-cli.md` — `ham-ctl teams show --team <id>` is expected as an observability command, and team/member routing uses `team_member_id` / `team_id`.

### Observed behavior

In chain `chain-19f500dc5ca` (`Fix coordinator chat visibility`), the chain team initially contained placeholder members rather than the actual swe-team role agents:

- `coder-1@team-chain-19f500dc5ca`
- `reviewer-1@team-chain-19f500dc5ca`
- `principal@swe-team` as coordinator

Attempts to assign or add real agents failed:

- `ham-ctl tasks create --assignee researcher@swe-team ...` failed with: `assignee is not a member of this chain team`
- `ham-ctl tasks assign ... --agent-instance-id researcher@swe-team` failed with: `agent is not a member of this chain team`
- `ham-ctl tasks participant ... researcher@swe-team ...` failed with: `agent is not a member of this chain team`

### Why this matters

The swe-team process requires role-specific delegation to actual agents, e.g. researcher, risk analyst, reviewer, planner, coder, tester. If a chain team is created with unresolved placeholders and there is no supported CLI/API path to bind or add the real agents, the coordinator cannot correctly assign or gate work.

### Workaround used

Because `ham-ctl` did not expose a usable team-membership command and assignment APIs rejected the agents, the coordinator directly patched the local teams DB:

- DB: `/Users/tanmayvijay/.local/share/heimdall/teams/teams.db`
- Table: `team_members`
- Added real agents to `team-chain-19f500dc5ca`:
  - `researcher@swe-team`
  - `risk-analyst@swe-team`
  - `planner@swe-team`
  - `reviewer@swe-team`
  - `coder@swe-team`
  - `tester@swe-team`

After that, normal `ham-ctl tasks assign` and `ham-ctl tasks participant` commands succeeded.

### Risk

Direct SQL against Heimdall state is unsafe as a routine workflow:

- Bypasses domain validation and event logging.
- May desynchronize in-memory daemon state from persisted DB state.
- May omit audit/task events that the UI or notification system expects.
- Can create inconsistent team membership if uniqueness/index assumptions change.

### Needed product/API fix

Add a supported way to manage chain team membership, such as:

- `ham-ctl teams show --team <team_id>` with real output.
- `ham-ctl teams add-member --team <team_id> --role <role> --agent-instance-id <agent>`.
- `ham-ctl teams bind-placeholder --team <team_id> --role <role> --placeholder <id> --agent-instance-id <agent>`.
- Or make task assignment able to add a valid project/team agent to the chain team with an explicit flag.

Also ensure these operations emit auditable events and update daemon in-memory state safely.

## 2. Planner task was started before required RCA/validation dependency completed

Status: fixed in working tree. RCA: dependency gating existed for task creation, promotion, and auto-claim paths, but manual status changes to `in_progress` did not re-check dependencies; ChainView used the user-RPC `task_status` path, so a coordinator/operator override could start a dependency-blocked task. Fix: `/tasks/status` / user-RPC status transitions to `in_progress` now enforce dependency, active-chain, assignee, and assignee-slot gating before persisting the status event; ChainView also displays `not_actionable_reason` and disables Start when dependencies are incomplete. Regression: `tests/test_task_status_dependency_gating.py` verifies a user-RPC manual start is rejected with `error=dependency` until the prerequisite is approved.

Relevant Teams v1 docs:

- `docs/teams-v1/07-ui.md` — `TaskDetail` should show dependencies and support permitted status/actions; local mutations must reconcile with task state.
- `docs/teams-v1/10-review-invariants.md` — review/lifecycle invariants should prevent bypassing required validation gates.

### Observed behavior

Task `task-19f5016c3fb` (`Plan coordinator chat visibility fix`) was started from ChainView even though it depended on the RCA task `task-19f50165f65`, which had not completed.

### Expected behavior

Planning should remain blocked until:

1. RCA task is complete.
2. RCA validation task is complete.
3. User/proxy approval is captured if required by the process.

### Workaround used

The planner task was reset to planning and its dependency was corrected to depend on the RCA validation task:

- `task-19f50165f65` — Research/RCA, assignee `researcher@swe-team`.
- `task-19f5016c3e8` — RCA validation, assignee `risk-analyst@swe-team`, depends on research.
- `task-19f5016c3fb` — Planning, assignee `planner@swe-team`, depends on validation.

### Needed product/API fix

ChainView should not allow starting a task whose dependencies are incomplete, or it should require an explicit privileged override that is visibly audited.

## 3. Reviewer agent did not auto-start when review was needed

Status: fixed in working tree. RCA: the autoscaler could eventually poll `review_ready` tasks, but the immediate `review_ready` notification path only queued/sent task notifications to reviewers and did not request a high-priority boot/wake. If the reviewer was offline, review could wait until a later scheduler tick or manual `agents start`. Fix: `task_notify_all_lgtm_required` now calls `task_notify_review_ready_agent`, which invokes `task_autoscaler_ensure_agent(..., "high", ...)` for each concrete required reviewer and the default-reviewer fallback before notification delivery. Regression: targeted unit assertion `test_review_ready_notifications_wake_reviewers_immediately` verifies the review-ready notification path wakes reviewers immediately.

Relevant Teams v1 docs:

- `docs/teams-v1/03-lifecycle.md` — Boot trigger #3 says task `review_ready` should boot the assigned reviewer or role-mapped reviewer; nudge scheduler pseudocode gives `review_ready` reviewer boot priority as high.
- `docs/teams-v1/07-ui.md` — Chain roster should reflect states like `live · reviewing` or `will boot when <trigger>`.
- `docs/teams-v1/08-http-and-cli.md` — `ham-ctl agents start` is intended to be removed/hidden from the main path; team lifecycle should handle needed boots automatically.

### Observed behavior

During chain `chain-19f500dc5ca`, task `task-19f5016c3e8` became `review_ready` and required `reviewer@swe-team` LGTM. The reviewer agent needed to be available for the task, but it was explicitly started by the coordinator rather than clearly auto-started by the task system.

Coordinator command used:

- `ham-ctl agents start reviewer@swe-team --agent pi`

The same manual start batch also included `researcher@swe-team`, `risk-analyst@swe-team`, and `planner@swe-team`.

### Expected behavior

When a task enters a state that requires review by a specific reviewer agent, the task/agent system should automatically ensure that reviewer is started or woken, just as it should for assigned executable work.

Expected trigger examples:

- Task enters `review_ready` and has `lgtm_required` reviewer participants.
- Task is awaiting a specific `reviewer_agent_instance_id`.
- A reviewer receives a targeted nudge or review-needed notification for an actionable task.

### Why this matters

Review gates can stall indefinitely if reviewer agents are offline and the coordinator must manually notice and start them. This is especially risky for chains that rely on explicit validation/review before implementation.

### Needed product/API fix

Add or verify lazy agent boot/wake behavior for review-needed states:

- When task status becomes `review_ready`, start/wake all required reviewer agents.
- When a task has required LGTM participants, target those agents with durable review-needed notifications.
- Ensure this behavior is auditable in task events or agent logs.
- Avoid waking unrelated agents; only required/assigned reviewers should be started.

## 4. Approved task can regress to review_ready after informational comment

Status: fixed in working tree. RCA: `task_service_comment_command` treated every unresolved comment on an approved task as blocking and emitted `system-comment-revert`, moving the task to `queued` and then auto-claiming it back to `in_progress`. This conflated ordinary informational comments with explicit changes-requested review actions. Fix: ordinary comments no longer regress approved tasks; the explicit NGTM review-vote path remains the changes-requested mechanism and still moves `review_ready` work back to `in_progress`. Regression: `tests/test_approved_task_comment_no_revert.py` verifies an approved task remains approved and no `system-comment-revert` event is emitted after an informational comment; `tests/test_tasks.sh` T11 expectations were updated accordingly.

### Observed behavior

Reviewer reported that `task-19f5016c3fb` had both required LGTM votes and auto-transitioned to `approved` at event `taskevt_1783756245923`, then later regressed back through `queued` / `in_progress` / `review_ready` after a coordinator informational comment was added and resolved.

Evidence from task log:

- `reviewer@swe-team` voted LGTM.
- `risk-analyst@swe-team` voted LGTM.
- System emitted `Task_Status_Changed` to `approved` with body `system_auto:all_lgtm_required_approved`.
- Later `system-comment-revert` moved it back to `queued` because of an unresolved informational coordinator comment.
- Planner resolved the comment and moved it to `review_ready` again.
- Current task state shows only a reviewer vote in `tasks show`, while the log still contains the prior risk LGTM event.

### Expected behavior

Once a task is approved by all required reviewers, adding an informational comment should not regress the task out of `approved` unless the comment is explicitly marked as changes-requested/blocking or a reviewer casts NGTM.

At minimum, any regression from `approved` should preserve/reflect prior LGTM vote state consistently and require a clear audit reason.

### Impact

- Creates phantom pending reviews.
- Makes reviewers appear busy on already-approved tasks.
- Can block downstream dependency promotion and chain progress.
- Confuses coordinator and reviewer agents because task log and current summary disagree.

### Needed product/API fix

- Do not auto-revert approved tasks for ordinary unresolved informational comments.
- Distinguish blocking review comments from informational comments.
- Preserve and display all historical/current LGTM votes consistently after status transitions.
- Add regression tests for approved-task comment behavior.

## 5. Task creation accepts invalid/nonexistent dependency IDs

Status: fixed in working tree. RCA: dependency handling only used `depends_on` for actionability/promotion checks, so planning tasks could be created with typo/nonexistent dependency IDs and then remain stuck forever. Fix: task creation now validates `depends_on` before persisting: a dependency requires a chain, every dependency ID must exist, dependencies must be in the same chain, and self-dependency is rejected. Regression: `tests/test_task_create_dependency_validation.py` verifies missing and cross-chain dependency IDs return structured 400 errors and valid same-chain dependencies still work.

### Observed behavior

While setting up chain `chain-19f5046a70b`, two tasks were accidentally created with typo dependency IDs:

- `task-19f5047fac6` was created depending on nonexistent/incorrect `task-19f5048b79e`.
- Earlier in chain `chain-19f5030c63d`, similar typo dependency tasks were created and then manually blocked as superseded.

The task creation command accepted the dependency value instead of rejecting it. The result was a task that could never promote naturally because its dependency did not refer to the intended existing task.

### Expected behavior

Task creation/update should validate every dependency ID before persisting the task:

- Dependency task must exist.
- Dependency task should normally be in the same chain unless an explicit cross-chain dependency feature exists and is intentionally used.
- A task should not depend on itself.
- Dependency graph should reject cycles or at least detect/report them clearly.
- CLI/API should return a clear error before task creation if validation fails.

### Impact

- Easy to create permanently stuck planning tasks.
- Planner/coordinator must manually notice and block superseded tasks.
- Downstream chain progress and UI blocker explanations become confusing.
- This increases the need for the requested next-phase blocker API, but that API should not be a substitute for validation at write time.

### Needed product/API fix

- Add dependency validation to `ham-ctl tasks create`, task creation HTTP/RPC handler, and any task update path that can alter dependencies.
- Add tests for nonexistent dependency, cross-chain dependency policy, self-dependency, and cycle handling.
- Return structured validation errors that the UI can display.

## 6. Coordinator chat visibility bug under investigation

Status: fixed in working tree. RCA: coordinator replies sent from agent context lacked durable chain scoping / UI refresh targeting, so a reply could persist as direct agent-to-user chat while the chain coordinator chat view did not know to refresh. Fix: `send_to_user` supports `chain_id`, validates that the sender is the chain coordinator, persists chain-scoped messages, includes compact `chain_id` metadata in chat websocket events, and the UI refreshes only the focused matching chain while preserving legacy direct-chat fallback. Regressions: `tests/test_send_to_user_chain_id.py`, `tests/test_chat_event_chain_id.py`, `tests/test_ui_chain_chat_event_targeting.py`, and `tests/test_ui_live_chat_ws_fallback.py` passed.

Relevant Teams v1 docs:

- `docs/teams-v1/README.md` locked decision #9 — user posts in chain chat are delivered only to the coordinator; coordinator decides what to forward.
- `docs/teams-v1/07-ui.md` — Chain view left panel is coordinator chat only, with every user message going only to the coordinator inbox.
- `docs/teams-v1/08-http-and-cli.md` — chain-scoped chat messages carry `chain_id`; `POST /chat send-to-coordinator` and `GET /chat inbox` filter by `chain_id` when provided.

### User report

The operator reported that a chat reply sent by `principal@swe-team` did not appear in the expected coordinator chat UI for chain `chain-19f500dc5ca`.

### Initial hypothesis / challenge

This may not be a simple UI rendering issue. Heimdall appears to have multiple related planes:

- Agent-to-user direct chat.
- Chain-scoped coordinator chat.
- Message delivery/read state.
- User-client websocket updates.
- Task/chain comments and Need Attention surfaces.

The bug should be investigated as a routing/state-sync/product-model issue before implementation.

### Current chain tasks

- `task-19f50165f65` — Research coordinator chat visibility bug.
- `task-19f5016c3e8` — Validate coordinator chat RCA.
- `task-19f5016c3fb` — Plan coordinator chat visibility fix.

### Desired fix direction

Do not duplicate messages blindly. Determine the intended source of truth for coordinator chat, then ensure messages sent by the coordinator in chain context are visible in the expected chain/coordinator UI and updated via the correct websocket/event path.
