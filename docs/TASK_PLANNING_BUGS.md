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

**Status:** Added to this tracker; should be added to planner bootstrap/prompt.

### MISTAKE-002: Creating separate review tasks instead of assigning reviewer approval to the implementation task

**Observed behavior:** Initial draft used separate review-only tasks. Operator clarified that the reviewer should be set on the implementation task and the task is complete only when reviewer approves it.

**Prompt improvement:**

> Do not create separate review-only tasks by default. Add the reviewer agent as `lgtm_required` on each implementation task. Treat implementation tasks as incomplete until reviewer LGTM is recorded on that same task.

**Status:** Applied to current planning process; should be added to planner/coder/reviewer prompts.

### MISTAKE-003: Not capturing project directory and source documents directly in task descriptions

**Observed behavior:** Operator reminded planner not to rely on agent context. Tasks must explicitly include project directory and implementation/process context for later audit.

**Prompt improvement:**

> Every implementation task description must include the absolute project directory, relevant source doc(s), expected audit notes, and validation requirements. Do not assume the assignee knows the repo path from conversation context.

**Status:** Applied to current Phase 1 task and future task drafts.

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

**Status:** Mitigated locally on 2026-06-28. Built a fresh repo `ham-ctl` at `/nix/store/2jz1a08g2788jryxk7l8q3ql16yix5i9-ham-ctl-0.1.0/bin/ham-ctl` and updated `~/.config/heimdall/config.toml` `ham_ctl_bin` to that binary. New agent bootstraps should now expose `tasks done`. Consider making this durable through Home Manager/release packaging so future generations do not regress.

## Bugs

### BUG-001: `tasks create` can return failure while still creating the task

**Status:** Open

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

**Status:** Open

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

**Status:** Open

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
