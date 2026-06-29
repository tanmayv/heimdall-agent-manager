# TASK PLANNING BUGS

Operational tracker for bugs discovered while coordinating Heimdall task chains.

This document is maintained by the planner during task-chain management. It captures issues found while creating, assigning, reviewing, and closing tasks so they can be audited and fixed later.

## Maintenance process

- Periodically check coder and reviewer task progress.
- Ensure implementation tasks remain auditable with project directory, source doc, changed files, decisions, commands, and validation notes in task comments.
- Ensure each implementation task has `reviewer-Heimdall-System@heimdall-system` as `lgtm_required` reviewer/participant.
- Do not create separate review-only tasks unless explicitly requested; implementation tasks are complete only after reviewer LGTM.
- Add any task-planning or task-management bugs here with recreation steps and current status.
- Capture agent task-chain mistakes and prompt improvements that would prevent them.

## Agent task-chain mistakes and prompt improvements

These are behavioral/process mistakes observed while managing chains. They should be fed back into agent prompts/bootstrap instructions.

### MISTAKE-001: Retrying task creation after an ambiguous failed response without first checking whether the task was created

**Observed behavior:** Planner retried task creation and created accidental duplicate/test tasks because `tasks create` returned failure while persisting tasks.

**Prompt improvement:**

> After any `ham-ctl tasks create` failure, do not retry immediately. First run `tasks list`, `tasks show`, or `task-chains show` to verify whether the task was actually persisted. If a task exists, continue from that task id. If accidental tasks were created and agent cannot cancel them, notify the operator and document cleanup needs.

**Status:** Added to tracker; partially mitigated by process. Keep as prompt guidance until all bootstrap/planner instructions explicitly mention checking task state after ambiguous create failures.

### MISTAKE-002: Creating separate review tasks instead of assigning reviewer approval to the implementation task

**Observed behavior:** Initial draft used separate review-only tasks. Operator clarified that the reviewer should be set on the implementation task and the task is complete only when reviewer approves it.

**Prompt improvement:**

> Do not create separate review-only tasks by default. Add the reviewer agent as `lgtm_required` on each implementation task. Treat implementation tasks as incomplete until reviewer LGTM is recorded on that same task.

**Status:** Fixed in prompts. Planner instructions and bootstrap guidance now require reviewers as `lgtm_required` on implementation tasks and discourage separate review-only tasks by default.

### MISTAKE-003: Not capturing project directory and source documents directly in task descriptions

**Observed behavior:** Operator reminded planner not to rely on agent context. Tasks must explicitly include project directory and implementation/process context for later audit.

**Prompt improvement:**

> Every implementation task description must include the absolute project directory, relevant source doc(s), expected audit notes, and validation requirements. Do not assume the assignee knows the repo path from conversation context.

**Status:** Fixed in planner prompt/process. Planner instructions now require task-chain drafts and task descriptions to include absolute project directory, source docs, validation requirements, and audit/logging requirements.

### MISTAKE-004: Planner created test tasks inside a real chain while debugging task creation behavior

**Observed behavior:** Planner used `test`/`test2` task creation attempts in the active production chain to diagnose task creation behavior.

**Prompt improvement:**

> Never create diagnostic/test tasks inside a real user-approved chain. If reproduction is needed, use a clearly named isolated repro chain or ask the operator first. Prefer read-only inspection before mutation.

**Status:** Added to tracker; accidental tasks need user-token cleanup because agent token cancellation is restricted.

### MISTAKE-005: Shell quoting caused Markdown backticks to execute as shell commands in chat body

**Observed behavior:** A `chat send-to-user --body` command used double quotes around Markdown containing backticks, causing shell command substitution attempts such as `docs/`.

**Prompt improvement:**

> When sending Markdown through shell, use a here-doc or single-quoted body. Avoid unescaped backticks inside double-quoted shell strings.

**Status:** Added to tracker; planner now uses here-docs for Markdown bodies.

### MISTAKE-006: Agents may say reviewer/user must transition because current installed CLI lacks `tasks done`

**Observed behavior:** An agent reported it could not move a task to `review_ready` because `tasks status` is restricted to user tokens.

**Clarification:** This is true for the currently installed `/nix/store/.../ham-ctl` command: `tasks status` is restricted to user tokens, and that binary's task command list does not include `tasks done`. However, repository source contains a newer `tasks done`/`handle_task_done` path that would allow an agent to submit for review without using the restricted manual status endpoint once that version is built/deployed.

**Prompt improvement:**

> To submit work for review, first check whether the active `ham-ctl` supports `tasks done`. If available, use `tasks done --token <token> --task-id <id> --comment <summary/evidence>`. If unavailable, log completion/evidence in task comments and notify the planner/operator that the current CLI cannot move the task to `review_ready` with an agent token.

**Status:** Fixed/deployed. Home Manager config now points generated bootstraps at a `ham-ctl` that exposes `tasks done`; subsequent agent task submissions used `tasks done` successfully.

## Bugs

### BUG-001: `tasks create` can return failure while still creating the task

**Status:** Fixed / validate if it regresses

**Fixed by:** `ea44473` (Fix task create and done success responses), validated with `tests/test_task_create_done_response.sh` against a latest isolated daemon.

**Observed while:** Creating the chat window audit implementation chain.

**Impact:** High. A planner may retry after seeing failure, which can create duplicate or accidental tasks.

**Observed behavior:**

- `ham-ctl tasks create ... --chain-id chain-19f0f0e8c1c` returned:
  - `{"ok":false,"message":"append task create failed"}`
- Later `ham-ctl tasks list` showed that the supposedly failed tasks had actually been created, including:
  - `task-19f0f0e8c3f` — intended Phase 1 task
  - `task-19f0f0ea68b` — accidental `test` task
  - `task-19f0f0eb9fc` — accidental `test2` task

**How to recreate:**

1. Create a task chain:
   ```bash
   ham-ctl task-chains create --token <agent-token> --title "Repro chain" --project-id heimdall-system --coordinator planner-Heimdall-System@heimdall-system
   ```
2. Create a task in that chain:
   ```bash
   ham-ctl tasks create --token <agent-token> --title "Repro task" --description "Repro" --assignee coder-Heimdall-System@heimdall-system --coordinator planner-Heimdall-System@heimdall-system --status planning --chain-id <chain-id>
   ```
3. Observe CLI response.
4. Run:
   ```bash
   ham-ctl tasks list --token <agent-token>
   ```
5. Check whether the task exists despite a failed response.

**Expected behavior:**

- If task creation succeeds, CLI should return `ok: true` with the task id.
- If task creation fails, no task should be persisted.
- The operation should be atomic/idempotent or expose enough data to prevent duplicate retries.

**Current workaround:**

- After any `tasks create` failure, run `tasks list` or inspect the chain before retrying.

---

### BUG-002: Agent token cannot cancel accidental planner-created tasks

**Status:** Open / needs design clarification

**Observed while:** Attempting to clean up accidental test tasks created during BUG-001 investigation.

**Impact:** Medium. Planner can create accidental tasks due to misleading create failures but cannot clean them up with the same agent token.

**Observed behavior:**

- Attempted:
  ```bash
  ham-ctl tasks status --token <agent-token> --task-id <task-id> --status cancelled --body "Cleanup"
  ```
- CLI returned:
  - `{"ok":false,"message":"manual status changes restricted to user tokens"}`

**How to recreate:**

1. Create a task with an agent token.
2. Try to cancel it with the same agent token using `tasks status`.
3. Observe restricted manual status-change error.

**Expected behavior options:**

- Either allow the creating/coordinator agent to cancel tasks while the chain is still planning, or
- Provide a dedicated safe cleanup/void command for planner-created mistakes, or
- Make `tasks create` reliably atomic so cleanup is rarely needed.

**Current workaround:**

- Ask `operator@local` or a user-token holder to cancel accidental tasks.

---

### BUG-003: Task reviewer field defaults to `operator@local` even when workflow requires agent reviewer

**Status:** Open / verify behavior

**Observed while:** Creating the chat window audit implementation task.

**Impact:** Medium. The UI/API may show `operator@local` as `reviewer_agent_instance_id` even after adding `reviewer-Heimdall-System@heimdall-system` as `lgtm_required`, which can confuse audit and completion semantics.

**Observed behavior:**

- Created task with assignee/coordinator but no explicit reviewer flag exists in `tasks create` help.
- `tasks list` showed `reviewer_agent_instance_id: operator@local`.
- Added reviewer with:
  ```bash
  ham-ctl tasks participant --token <agent-token> --task-id <task-id> --agent-instance-id reviewer-Heimdall-System@heimdall-system --role lgtm_required
  ```
- Participant was added successfully, but the top-level reviewer field may still indicate `operator@local`.

**How to recreate:**

1. Create a task as a planner agent.
2. Add `reviewer-Heimdall-System@heimdall-system` as `lgtm_required`.
3. Run `tasks list` or `tasks show`.
4. Compare top-level `reviewer_agent_instance_id` with participants/votes.

**Expected behavior:**

- If reviewer is represented by `lgtm_required` participants, UI/API should make that the authoritative completion gate.
- Top-level `reviewer_agent_instance_id` should not imply the operator must review if an agent reviewer is required.

**Current workaround:**

- Put explicit review requirements in task descriptions.
- Add the reviewer agent as `lgtm_required` participant.
- Treat the task as complete only after reviewer LGTM vote.

---

### BUG-004: `tasks done` can return failure while still moving task to `review_ready`

**Status:** Fixed / validate if it regresses

**Fixed by:** `ea44473` (Fix task create and done success responses), validated with `tests/test_task_create_done_response.sh` against a latest isolated daemon and later live `tasks done` submissions returning `ok:true/status=review_ready`.

**Observed while:** Coder submitted Phase 1 of the chat window audit implementation for review.

**Impact:** High. An agent may believe review submission failed and retry or ask for manual intervention, while the task has already moved to `review_ready`. This can cause duplicate comments, confusion, or incorrect coordination state.

**Observed behavior:**

- Command:
  ```bash
  /nix/store/2jz1a08g2788jryxk7l8q3ql16yix5i9-ham-ctl-0.1.0/bin/ham-ctl \
    --daemon-url http://127.0.0.1:49322 \
    tasks done \
    --token <coder-agent-token> \
    --task-id task-19f0f0e8c3f \
    --comment "Implementation complete. Changed src/ui/store/chatSlice.ts and src/ui/components/MessageBubble.tsx. Validation: npm run typecheck passed. Note unrelated pre-existing worktree changes in src/lib/config/config.odin, src/lib/tmux/tmux.odin, and src/wrapper/main.odin were not touched."
  ```
- CLI returned:
  ```json
  {"ok":false,"message":"append task status failed"}
  ```
- But `tasks show` later showed `task-19f0f0e8c3f` had successfully moved to `review_ready`.

**How to recreate:**

1. Use a task currently assigned to an agent and in `in_progress`.
2. Run:
   ```bash
   ham-ctl --daemon-url http://127.0.0.1:49322 tasks done --token <assignee-agent-token> --task-id <task-id> --comment "done"
   ```
3. If the command returns `{"ok":false,"message":"append task status failed"}`, immediately run:
   ```bash
   ham-ctl tasks show --token <token> --task-id <task-id>
   ```
4. Check whether task status is nevertheless `review_ready`.

**Expected behavior:**

- If status transition is persisted, the CLI/API should return `ok: true`.
- If status transition fails, the task should remain unchanged.
- The operation should be atomic/idempotent or return the resulting task status so agents can safely continue.

**Current workaround:**

- After any `tasks done` failure, do not retry immediately.
- Run `tasks show` to verify the actual task status.
- If status is already `review_ready`, proceed with reviewer notification/coordination instead of retrying.


---

### BUG-005: Task does not auto-approve after all required reviewers vote LGTM

**Status:** Fixed / validate if it regresses

**Fixed by:** `2139bd1` (Fix task vote auto-approval response coverage), validated with `tests/test_task_vote_auto_approval.sh`; later live tasks auto-approved after reviewer LGTM.

**Observed while:** Reviewer approved Phase 1 of the chat window audit implementation.

**Impact:** High. Dependent tasks may remain blocked/planning because the completed task stays in `review_ready` even though all required reviews are satisfied. This breaks the documented auto-transition behavior and requires manual/user intervention or coordinator workaround.

**Observed behavior:**

- Task: `task-19f0f0e8c3f`
- Required reviewer participant:
  - `reviewer-Heimdall-System@heimdall-system` with role `lgtm_required`
- Recorded vote:
  ```json
  {
    "reviewer_agent_instance_id": "reviewer-Heimdall-System@heimdall-system",
    "approved": true,
    "comment": "LGTM confirmed. Typecheck and build passed."
  }
  ```
- `tasks show` still reports:
  - `status: review_ready`
  - `not_actionable_reason: awaiting_review:reviewer-Heimdall-System@heimdall-system`
- This contradicts the CLI help text stating:
  - `review_ready→approved (all lgtm_required voted)`

**How to recreate:**

1. Create or use a task with exactly one `lgtm_required` reviewer.
2. Move the task to `review_ready`.
3. Have that reviewer vote LGTM:
   ```bash
   ham-ctl tasks vote --token <reviewer-token> --task-id <task-id> --result lgtm --comment "LGTM"
   ```
4. Run:
   ```bash
   ham-ctl tasks show --token <token> --task-id <task-id>
   ```
5. Check whether the task moved to `approved` or incorrectly remains `review_ready` / `awaiting_review`.

**Expected behavior:**

- Once every `lgtm_required` participant has an LGTM vote, the task should automatically transition from `review_ready` to `approved`.
- `not_actionable_reason` should no longer say it is awaiting the reviewer who already voted.
- Dependent tasks should become eligible for promotion according to dependency rules.

**Current workaround:**

- Planner/operator must inspect votes manually.
- Treat a `review_ready` task with all required LGTM votes as logically approved for coordination, but note the daemon state mismatch.
- If manual status changes are required, ask a user-token holder/operator to move or repair the task state.

---

### BUG-006: Blocked chain still prevents creating a new project chain

**Status:** Open

**Observed while:** Pausing the chat window audit implementation chain to prioritize core task create/done/vote fixes.

**Impact:** Medium to high. A coordinator cannot create a replacement/urgent chain in the same project after pausing the current chain with `status: blocked`, because the daemon still treats the blocked chain as the project's active chain.

**Observed behavior:**

- Paused chain `chain-19f0f0e8c1c` using:
  ```bash
  ham-ctl task-chains status --token <planner-token> --chain-id chain-19f0f0e8c1c --status blocked --final-summary "Paused..."
  ```
- `task-chains show` confirmed:
  - `status: blocked`
- Attempted to create a new project chain:
  ```bash
  ham-ctl task-chains create --token <planner-token> --title "Unblock core task create done vote and description editing" --project-id heimdall-system --coordinator planner-Heimdall-System@heimdall-system
  ```
- Daemon returned:
  ```json
  {"ok":false,"message":"project already has an active chain","active_chain_id":"chain-19f0f0e8c1c"}
  ```

**How to recreate:**

1. Create/activate a chain for a project.
2. Move that chain to `blocked`.
3. Try to create another chain with the same `project-id`.
4. Observe that the blocked chain is still considered active.

**Expected behavior:**

- Either `blocked` should be a true paused/non-active state that allows a replacement active chain, or
- There should be a dedicated `paused`/`superseded` chain state, or
- The error message should clarify that blocked chains still occupy the project's active-chain slot and provide an intended workflow.

**Current workaround:**

- Create the urgent chain without a `project-id` and include the project directory/context explicitly in task descriptions.
- This preserves execution but weakens project-level grouping/auditability.

---

### PROCESS-001: Nudges intentionally do not run for planning/done task chains

**Status:** Intended behavior / prompt-process note

**Clarified by operator:** Nudges are intentionally limited to task chains that are not in `planning` or `done` state. We want nudges not to happen for task chains in planning mode.

**Rationale:** Planning chains are not yet approved/active work. Nudging agents from a planning chain can cause premature execution or coordination noise before the user-approved plan is activated. Done chains should also not generate new work nudges.

**Prompt improvement:**

> Before using `tasks nudge`, check the task chain status. Do not expect or attempt nudges for chains in `planning` or `done`. If a plan is approved and work should start, activate the chain first. If the chain should remain planning, use direct `ham-ctl send` messages only for meta-coordination, not execution nudges.

**Current workflow:**

- Keep planning chains quiet until approval/activation.
- Use direct messages for exceptional coordination while task-chain state bugs are being repaired.

---

### BUG-007: Agent inbox `--include-read` does not clear unread notifications and unread-count semantics need per-direction/per-channel clarity

**Status:** Prompt-level mitigation applied; model/design clarification still open

**Observed while:** Planner was reading direct agent-to-agent coordination messages from reviewer/coder.

**Impact:** Medium. Notification bubbles continued to report messages such as `8 Unread Messages from reviewer-Heimdall-System@heimdall-system` even after the planner fetched messages with `ham-ctl inbox --include-read --json`. This creates coordination noise and makes it look like the planner has not read messages.

**Observed behavior:**

- Running:
  ```bash
  ham-ctl inbox --token <planner-token> --include-read --limit 150 --json
  ```
  returned messages, many with `read:false`, but did not clear the unread count.
- Running inbox without `--include-read` later cleared them:
  ```bash
  ham-ctl inbox --token <planner-token> --limit 100 --json
  ```
- A second non-include-read fetch then returned no messages.

**Likely cause:**

- Agent inbox fetch maps to `fetch_messages` with `include_read=true`.
- `message_service_process_fetch` intentionally skips marking messages read when `include_read` is true:
  ```odin
  if request.include_read do continue // include_read may return old reads; avoid duplicate read receipts.
  ```
- This means `--include-read` is an inspection mode, not a read/ack mode, but the CLI/notification wording makes this easy to misunderstand.

**Required model clarification:**

Unread counts should be independently tracked for each communication direction/channel:

1. `user -> agent` unread count for agent user-chat notifications.
2. `agent -> user` unread count for user/client chat badges.
3. `agent -> agent` unread count for agent inbox/direct coordination messages.

These counts should not clobber or infer from one another. Fetch/read behavior should update only the appropriate direction/channel.

**How to recreate:**

1. Send agent-to-agent messages to an agent.
2. Observe wrapper notification with unread count.
3. Fetch with:
   ```bash
   ham-ctl inbox --token <agent-token> --include-read --json
   ```
4. Observe messages are returned but unread notification/count may remain.
5. Fetch with:
   ```bash
   ham-ctl inbox --token <agent-token> --json
   ```
6. Observe unread messages are marked read and subsequent unread fetch returns empty.

**Expected behavior options:**

- Option A: Document/rename `--include-read` as read-only history mode and make notifications tell agents to fetch without `--include-read` to acknowledge messages.
- Option B: Add an explicit `--mark-read` or `--ack` flag for inbox fetches, independent of include-read history mode.
- Option C: Make `--include-read` still mark currently unread messages as read while including historical read messages, if that is the desired UX.

**Prompt-level fix:**

> Agents should not use `--include-read` by default when responding to unread inbox notifications. For normal inbox handling and acknowledgement, run `ham-ctl inbox --token <agent-token> --json` without `--include-read`. Use `--include-read` only when explicitly inspecting history/debugging already-read messages.

**Current workaround:**

- To clear agent-to-agent unread notifications, run `ham-ctl inbox --token <agent-token> --json` without `--include-read`.
- Use `--include-read` only for history/debug inspection, not acknowledgement.
- Update bootstrap/prompt examples so unread notifications show the no-`--include-read` command.

---

### BUG-008: Task created in an already-active chain remains `planning/waiting_for_promotion`

**Status:** Open / likely code issue

**Observed while:** Continuing the core task workflow chain after restarting onto Home Manager/latest daemon, ctl, and wrapper paths.

**Impact:** Medium. A coordinator may add a new task to an already-active chain and expect it to auto-promote/claim, but the task remains in `planning` with `not_actionable_reason: waiting_for_promotion`. Because nudges intentionally do not operate on planning tasks/chains, the coordinator must use direct messages to start work.

**Observed behavior:**

- Chain `chain-19f0f575d0e` was `in_progress`.
- Created task `task-19f110f5c62` in that chain with no dependencies and assignee `coder-Heimdall-System@heimdall-system`.
- `tasks create` returned `ok:true`.
- `tasks show` reported:
  - `status: planning`
  - `not_actionable_reason: waiting_for_promotion`
- Re-running `task-chains activate` failed with `only planning chains can be activated`, because the chain was already in progress.
- Waiting briefly did not promote the task.

**How to recreate:**

1. Use a chain already in `in_progress`.
2. Create a new no-dependency task in that chain:
   ```bash
   ham-ctl tasks create --token <token> --chain-id <active-chain-id> --title "new task" --assignee <agent>
   ```
3. Run:
   ```bash
   ham-ctl tasks show --token <token> --task-id <new-task-id>
   ```
4. Check whether status remains `planning/waiting_for_promotion` instead of promoting to queued/in_progress.

**Expected behavior:**

- A newly-created task in an already-active chain with satisfied dependencies should promote to `queued` or `in_progress` according to normal auto-claim rules, or
- The system should require an explicit supported command to promote newly appended tasks in active chains, and CLI/help should document that workflow.

**Current workaround:**

- Use direct `ham-ctl send` coordination to the assignee instead of `tasks nudge` while the task remains planning.
- Avoid relying on nudges for planning tasks, per intended nudge behavior.

---

### BUG-009: Auto-claim task event can be suppressed, leaving free agents unaware of newly assigned in-progress work

**Status:** Open

**Observed while:** Creating `task-19f13dfd271` for chat-window agent controls.

**Impact:** High. A task can be correctly promoted to `in_progress` for an idle assignee, but the assignee may not visibly react until a later manual/operator nudge. This makes it look like task assignment/nudge failed even though task state is correct.

**Observed behavior:**

- Task `task-19f13dfd271` was created, chain activated, and task auto-claimed:
  - `Task_Status_Changed` to `queued` with `system_auto:deps_cleared`
  - `Task_Status_Changed` to `in_progress` with `system_auto:auto_claimed`
- Planner nudge was also recorded as `Task_Nudged` and CLI returned sent=true.
- Coder did not start/acknowledge until a later operator nudge.

**Likely cause / contributing factor:**

- Wrapper task-event handling currently suppresses all events whose `changed_by` starts with `system-auto`:
  ```odin
  if strings.has_prefix(changed_by, "system-auto") {
      fmt.println("suppressed system-auto task event", task_id, status, changed_by)
      return
  }
  ```
- That suppresses the important `system-auto-claim` notification, even though it is exactly the event that tells an idle assignee “this is now your current active task.”
- If a subsequent manual nudge is missed, delayed, or not surfaced clearly, the agent may remain idle despite having an in-progress task.

**How to recreate:**

1. Ensure an assignee agent is idle and connected.
2. Create and activate a chain with a task assigned to that agent.
3. Observe task log showing `system_auto:auto_claimed`.
4. Check whether the agent receives a visible task-start notification without requiring an additional user/operator nudge.

**Expected behavior:**

- Auto-claim should reliably notify the assignee that the task is now their active work.
- Wrapper should not suppress `system-auto-claim` events targeted to the assignee.
- If task nudge delivery succeeds at daemon level but the agent does not visibly receive it, logs should expose where delivery failed.

**Potential fixes:**

- In wrapper, suppress only noisy system-auto events, not `system_auto:auto_claimed` for the target assignee.
- Add delivery/audit visibility for task notifications vs pane injection.
- Consider direct-message fallback for newly auto-claimed tasks if pane notification fails.
