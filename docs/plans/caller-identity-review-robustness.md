# Plan: Robust Caller Identity for Reviews (drop operator@local / user_proxy string coupling)

Status: Draft
Owner: TBD
Scope: Option A (targeted robustness fix) + two additions. Explicitly NOT the full
`user_proxy` concept removal (that role/seat stays as a team-member concept).

## 1. Problem

A user doing LGTM from the UI on a task whose reviewer is the user-proxy is sometimes
recorded as an **optional** participant vote (`lgtm_optional`) instead of the
**required** user review (`lgtm_required`). Because it lands optional,
`task_all_required_lgtms_approved` never counts it, auto-approve never fires, and the
task sits in `review_ready` even though the user approved.

Root cause (confirmed in code):
- `task_service_review_vote` only classifies a user's vote as required if it can
  **remap the caller to the `user_proxy` identity** via `task_user_proxy_reviewer_for`.
- That remap keys on **magic strings**: the literal `operator@local` and the
  user-proxy member's `route_to` (also hardcoded to `operator@local`).
- If the caller's user id is not exactly `operator@local` (e.g. operator changed
  their user id in Session Config, or the token resolves a different user id), the
  remap misses. `can_override` still lets the vote through, so it is silently
  downgraded to `lgtm_optional`.

## 2. Principles

1. **The middleware that resolves the token is the single source of truth for
   caller type.** The auth DB already stores `identity_type` (`agent` | `user`) and
   `auth_db_get_identity(token)` returns it. Business logic must branch on that fact,
   never on an id string.
2. **"A user approval is needed"** is a property of the task/review slot, and **"a
   user approval happened"** is a property of the caller having used a **user token** —
   independent of *which* user id it is.
3. **No business-logic branch may compare against `operator@local` or `user_proxy`
   strings.** A single internal recipient constant may remain for addressing the
   human inbox, but no code path may make decisions by string-matching it.
4. **No cheap-tier agents.** All agents in this chain run at `normal` or `smart`
   tier (reviewers/coordinator at `smart`). This is careful cross-cutting daemon work.

## 3. Design

### 3.1 Caller identity carried end-to-end
- Extend the review-vote command with the caller type resolved by the auth
  middleware, e.g. `Task_Review_Vote_Command.author_is_user: bool`.
- `task_author_and_type_from_body` already returns `is_user`; the HTTP and user-RPC
  vote handlers pass it through. The user-RPC path is always a user token
  (`author_is_user = true`).

### 3.2 "Needs user review" is an explicit signal, not a sentinel string
- Today `task_reviewer_agent_instance_id` returns the literal `"user_proxy"` when no
  concrete reviewer exists, and many callers detect "user review" by comparing to
  `"user_proxy"`/`"operator@local"`.
- Replace the string sentinel with an explicit predicate, e.g.
  `task_requires_user_review(state) -> bool`, derived from:
  - an `lgtm_required` participant that is the user-proxy seat, OR
  - a chain default reviewer that designates the user-proxy seat, OR
  - **(addition #1)** the *absence* of any concrete reviewer — a task with no
    reviewer set now means "needs user review" instead of defaulting to the
    `user_proxy` string sentinel.
- Keep a distinct accessor for the concrete agent reviewer (returns empty string
  when the reviewer is the user, rather than a magic value).

### 3.3 Vote classification
- In `task_service_review_vote`: a vote is `lgtm_required` when EITHER
  - the (possibly remapped) author holds the `lgtm_required` role for a concrete
    agent reviewer, OR
  - `author_is_user` is true AND `task_requires_user_review(state)` is true.
- Remove the `operator@local` literal branch from `task_user_proxy_reviewer_for`;
  attribute the user vote to the user-review slot based on token type, not id
  string. (The user-proxy *seat identity* used for the recorded vote author can
  remain the existing seat marker; what changes is that we no longer gate on the
  caller's id string.)

### 3.4 Human recipient addressing (addition #2)
- Introduce one internal constant for the durable human inbox recipient (single-user
  assumption, matching today's behavior) — but **only for addressing**, e.g.
  notification-outbox target, scheduled-prompt sender, merge-decision recipient.
- Every *decision* ("is this a user review?", "should this be routed to the human?",
  "skip this nudge target?") must use the token identity / `task_requires_user_review`,
  not a comparison to that constant.

### 3.5 Team-member user-proxy seat: unchanged
- `is_user_proxy` / `route_to` columns and the user-proxy team-member seat concept
  remain. This plan does not migrate or redesign the seat; it only removes the
  string-based *decision coupling* around it.

## 4. Out of Scope
- Removing `user_proxy` as a team-member role/seat (that is the larger Option B).
- Multi-user routing (we keep the single internal human-recipient constant).
- Any schema redesign of `team_members`.

## 5. Database Note (no migration)
Per direction: **do not write migration code.** If the persisted DB schema version is
older than the new version, the affected DB may be **dropped and reinitialised**. This
is handled as a **separate, isolated task** (see Phase 5) so the logic change and the
destructive DB reset are reviewed independently. Bump the relevant schema version so
older DBs are detected and reset on init.

## 6. Phased Delivery

Each phase is an independent task with its own reviewer gate. Phases are ordered so
the tree keeps building/passing between phases.

### Phase 1 — Introduce caller-identity plumbing (no behavior change)
- Add `author_is_user` to `Task_Review_Vote_Command`.
- Thread `is_user` from `task_author_and_type_from_body` through the HTTP and
  user-RPC vote handlers; user-RPC path sets it true.
- No classification logic changes yet; existing tests must stay green.
- Exit: builds, all existing tests pass, new field is populated but unused.

### Phase 2 — Explicit "needs user review" predicate
- Add `task_requires_user_review(state)` and a concrete-agent-reviewer accessor
  that returns empty (not `"user_proxy"`) when the reviewer is the user.
- Migrate `task_reviewer_agent_instance_id` sentinel consumers
  (`task_queries.odin`, `task_notifications.odin`, `task_nudge_scheduler.odin`) to
  the new predicate. Behavior preserved (still routes to the human), but no code
  branches on `"user_proxy"`/`"operator@local"` for the *decision*.
- **Addition #1**: no-reviewer task now maps to `task_requires_user_review = true`
  instead of the `user_proxy` string default.
- Exit: builds, tests pass, no business-logic string comparisons to the sentinels
  remain in the migrated files.

### Phase 3 — Fix vote classification on token identity
- In `task_service_review_vote`, classify a user vote as `lgtm_required` when
  `author_is_user && task_requires_user_review(state)`, independent of the caller's
  user id string.
- Remove the `operator@local` literal branch in `task_user_proxy_reviewer_for`.
- Ensure auto-approve fires when the required user review is satisfied.
- Exit: the reported bug is fixed; add a regression test proving a user LGTM (with a
  non-`operator@local` user id) is recorded as required and auto-approves.

### Phase 4 — Decouple human-recipient addressing from string decisions
- Introduce the single internal human-recipient constant for addressing only.
- Replace remaining decision-time comparisons to `operator@local`/`user_proxy` in
  `chat_http.odin`, `scheduled_prompt_service.odin`, `merge_lifecycle.odin`,
  `task_nudge_scheduler.odin`, `task_notifications.odin` fallback, `team_service.odin`
  default `route_to`, with token-identity / predicate checks.
- Exit: no business-logic branch compares against the human-recipient string; grep
  guard test added asserting the sentinels appear only in addressing/const contexts.

### Phase 5 — DB reset-on-old-version (separate, isolated task)
- Bump the schema version for the affected DB(s).
- On init, if the persisted version is older than the new version, **drop and
  reinitialise** that DB (no data migration). Log the reset clearly.
- Kept separate from Phases 1–4 so the destructive reset is reviewed on its own.
- Exit: starting the daemon against an older DB version resets cleanly; starting
  against the current version is a no-op.

### Phase 6 — Test sweep + verification
- Update the ~7 behavioral tests that assert user_proxy/operator@local review flow
  (`test_task_reviewer_assignment.py`, `test_ui_reviewer_merge.py`,
  `test_team_scaffold_no_reviewer_task.py`, `test_task_notification_recipient_scope.py`,
  `test_chain_status_orchestration.py`, `test_task18_e2e_runner.py`,
  `test_ui_sidebar_badge.py`).
- Add the Phase 3 regression test as a permanent guard.
- Full daemon build (`nix build .#ham-daemon`) + `tsc` + affected python tests green.

## 7. Acceptance Criteria
- A user LGTM via the UI/user-RPC is recorded as `lgtm_required` and triggers
  auto-approve, regardless of the user's id string.
- No business-logic branch compares against `operator@local` or `user_proxy`; those
  strings survive only as a single internal addressing constant / team-seat marker.
- A task with no reviewer set is treated as "needs user review".
- Older-version DBs are dropped and reinitialised on init (separate task); no
  migration code is added.
- Daemon builds; existing + new tests pass; no cheap-tier agents used in the chain.

## 8. Touchpoint Index (reference)
- Vote path: `task_commands.odin`, `task_http.odin`, `user_rpc.odin`,
  `task_service.odin` (`task_service_review_vote`, `task_user_proxy_reviewer_for`).
- Sentinel consumers: `task_queries.odin` (`task_reviewer_agent_instance_id`,
  `task_nudge_target_for_status`, blocker reasons), `task_notifications.odin`,
  `task_nudge_scheduler.odin`.
- Recipient addressing: `chat_http.odin`, `scheduled_prompt_service.odin`,
  `merge_lifecycle.odin`, `team_service.odin`.
- DB reset: the affected `*_db_service.odin` version constant + init path.
- Team seat (unchanged): `team_db_service.odin`, `team_http.odin`, `team_kinds.odin`,
  UI `App.tsx`/`teamKinds.ts`.
