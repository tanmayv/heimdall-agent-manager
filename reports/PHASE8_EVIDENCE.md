# Phase 8 — LIVE End-to-End Validation Report

**Feature under test:** last committed change `e9069bd` — *feat(taskchain): persisted current-task + priority/Queued + notification gating* (migration `019_current_task_and_priority.sql`).

**Isolation:** Built and run from a CLEAN git worktree pinned at `e9069bd` (`/tmp/hhr-clean`), so the other agent's UNCOMMITTED work (migration 020 title_tracking + repo edits) was excluded. Never touched `hub.mundus.in` or the mundus bridge. Local stack only: hub `127.0.0.1:8081`, dev-proxy `127.0.0.1:8080`, bridge `49323`.

## Stack
- Clean nix build (distinct store hashes vs the dirty tree, confirming WIP excluded).
- `scripts/dev-stack.sh start` → hub + dev-proxy + bridge RUNNING; bridge reported `bridge hub runtime ready`; `hub /api/v1/health` OK.
- DB `schema_migrations` max = **019** (no 020) — proves we ran only the committed feature.

## Step 2 — New hub exposes fields the remote lacks
- `GET /api/v1/agent-instances/<id>` → JSON includes `current_task_id` and `current_task_role`.
- Task JSON includes `priority` (PATCH echo; the list serializer omits it, but the column persists and is exposed on mutate).

## Setup
- Agents: Assignee `inst_18d191139d9e1250`, Reviewer `inst_18d19113a490a6b8`.
- Chain `chain_18d1911665436060`, both added as members (assignee=member, reviewer=reviewer).
- 3 tasks, all assigned→Assignee, reviewed→Reviewer:
  - Task-B-P0 `task_18d19126b08a0690` priority **p0**
  - Task-A-P1 `task_18d191267cdb8e90` priority **p1**
  - Task-C-P2 `task_18d19126eb6df410` priority **p2**

## (a) Auto-promotion ordering — PASS
On publish, the hub auto-promoted deterministically (review-over-work N/A; P0>P1>P2; one active work item):
```
Task-B-P0  in_progress   (assignee.current_task = task_18d19126b08a0690, role=work)
Task-A-P1  queued        (demoted)
Task-C-P2  queued        (demoted)
Reviewer.current_task = (none)
```
Verified via DB and API.

## (b) GOOD review path — PASS (real claude agents drove human-in-loop)
- Assignee submitted Task-B-P0: `in_progress → in_validation`.
- Auto-promotion: Reviewer.current_task = Task-B-P0 role=**REVIEW**; Assignee auto-advanced to next-priority Task-A-P1 role=**work** (`in_progress`).
- Live reviewer agent received a REVIEW nudge, self-identified as reviewer on the in_validation task, cast **LGTM** (`task_votes`: `inst_18d19113a490a6b lgtm`).
- Result: Task-B-P0 → **completed**; Reviewer advanced OFF it (current_task=none); Assignee remained on Task-A-P1(p1); Task-C-P2 still queued.

## (c) BAD review path — PASS
- First attempt raced the live reviewer (auto-LGTM at 17:33:43 completed the task 14s before my NGTM at 17:33:57 → later NGTM correctly a no-op via the `status != In_Validation` guard).
- Deterministic run: stopped both instances (current_task pointers auto-cleared on stop = CT-7). Re-submitted Task-C-P2 → `in_validation`; Reviewer.current_task = Task-C-P2 role=REVIEW.
- Reviewer cast **NGTM** → Task-C-P2 became Validated_Not_Good and auto-promotion (CT-10) immediately fed the rework back: **Assignee.current_task = Task-C-P2 role=work (`in_progress`)**; **Reviewer advanced OFF it (current_task=none)**.

## (d) Notification gating (work vs review, only current task) — PASS
- Gate: recipient woken only when persisted `current_task_id == task_id` (strict fail-closed for comments; fail-open when unset for status wakes); action label from persisted role.
- Proven live: in (b), when Task-B-P0 went to review, the Assignee had already advanced to Task-A-P1, so it was gated OUT of the Task-B-P0 review wake — only the Reviewer got the REVIEW nudge and acted on it.
- Message labels: `Review requested: <title>` / `Work ready: <title>` / `Rework requested (changes requested): <title>`.

## Deterministic CT test suites (clean worktree @ e9069bd, pinned odin)
```
PASS hub_ct_schema_foundation_test    (CT-1/CT-2/CT-3: migration 019 + current_task + priority + Queued round-trip)
PASS hub_ct_promotion_engine_test     (CT-4/CT-5/CT-7/CT-10 + manual set-current + priority patch)
PASS hub_ct_notification_gating_test  (CT-6/CT-8: gating + R8 work/review labels + dual-role)
PASS hub_ct_end_to_end_test           (review-over-work, priority, tiebreak, queued demotion, auto-advance, gated labeled notifications)
```

## Verdict
All CT REQ-ID groups (CT-1..CT-10, R6/R7/R8) validated both LIVE on an isolated local hub AND via deterministic test suites, built from the last committed change only. Feature is functioning as designed.
