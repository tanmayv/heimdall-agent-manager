# Heimdall Tooling
- Use `{{ctl_bin}} ...` (`./bin/ham-ctl`) for Heimdall task, lease, review, chat, project, and memory workflows.
- Track all work as Heimdall tickets (the `ham-ctl task` and `lease` commands); read `TASK.md` in your run directory on every wake, choose and run checks appropriate to the change, and submit with `ham-ctl lease submit`, reporting the commands and their outcomes in the summary.

# Agent Operating Rules (Tickets)
These rules govern how you work with Heimdall tickets. Follow them every session.

## 1. Always track work in Heimdall tasks and read `TASK.md`
Every non-trivial unit of work is tracked in a Heimdall task and dispatched via a lease from the chain's owner Bridge (every chain is Bridge-owned):
- On wake, the owner Bridge materializes `<run_dir>/TASK.md`: the lease header with your **Workdir** (a per-task git checkout; do all work and commits there) and the requirements revision, the complete current requirements (goal, acceptance, inputs, reviewers), the bounded chain summary (done and open tasks, decisions, dead ends, coordinator notes), and its context provenance. After reading it, acknowledge the revision with `{{ctl_bin}} lease heartbeat --lease <lease-id> --acknowledge-requirements-revision <n>`. `ham-ctl task show <id>` has the full brief, reviews and attempts.
- Read `TASK.md` first on every wake, or inspect/claim your lease with `{{ctl_bin}} lease next`.
- Check the inbox using `{{ctl_bin}} chat read` for pending messages before starting anything new.
- If any command returns `409 lease_lost`, **stop immediately** without touching the working tree or committing further changes — another attempt now owns the task.

## 2. Coordinator vs Worker vs Reviewer responsibilities
- **Coordinator** (`coordinator_agent_instance_id`):
  - The **only** free-form user channel for the chain (`chat send --to user`).
  - Triages incoming work and proposes tickets with `ham-ctl task-chain propose --file <proposal.json> [--require-decision]`, wiring order with `ham-ctl task depend <task-id> --on <task-id>`.
  - Maintains the chain summary (`<= 60` lines) via `ham-ctl task-chain summary set <text>` (or `--stdin`).
  - Reacts when work needs it (a task blocked on a human, parked on the coordinator, stuck, in merge conflict, or awaiting the user's review): inspects with `ham-ctl task show <id>` and corrects with the coordinator controls (`task hold|release|unblock|recheck|cancel|reopen|split`, `merge retry`, `lease revoke`).
  - Posts proxy user reviews when the user approves in chat: `ham-ctl review post --task <id> --verdict approve|request_changes --on-behalf-of user`.
- **Worker** (assignee):
  - Executes the leased task described in `TASK.md`.
  - Chooses and runs checks appropriate to the change (long commands via `ham-ctl shell run`); no task configures a verification command.
  - Submits completed work with `ham-ctl lease submit --summary "<summary>" [--decision "<text>"]... [--dead-end "<text>"]... [--output-file <json>] [--artifacts-file <json>]`, reporting each check's exact command and outcome in the summary.
  - Releases incomplete work with `ham-ctl lease handoff --summary "<summary>" --next-steps "<steps>" [--decision …] [--dead-end …]` or parks blockers with `ham-ctl lease block --waiting-on user|task|<system> --reason "<reason>"`.
  - Records every decision others might re-open and every dead end with `--decision` / `--dead-end`: the tasks that wait for this one, and later attempts, receive them.
- **Reviewer**:
  - Woken with a `review` lease when a task enters `in_review`.
  - Inspects the submitted head, handoff and artifacts (`TASK.md`, `ham-ctl task show <task_id>`, `git show <head>`), and the checks the worker reported.
  - Judges correctness independently; runs its own checks (for example in a detached worktree at `vcs.head`) only where a concrete concern remains. The verdict needs no command evidence.
  - Records the review verdict via `ham-ctl review post --task <id> --verdict approve|request_changes [--summary "<reason>"] [--findings-file <json>]` (findings: `[{"path","line","severity","text"}]`).

## 3. User-facing communication goes through the coordinator
The **only** free-form user channel is the task-chain coordinator.
- If you are **not** the coordinator, route every question, blocker, or scope change to the coordinator via `ham-ctl lease block --waiting-on user --reason "..."`, a task comment (`ham-ctl task comment <task_id> --body "..."`), or `ham-ctl chat send --to <coordinator_instance_id> --body "..."`.
- If you are the coordinator, acknowledge user messages promptly with `ham-ctl chat send --to user --body "..."`, use `--questions-file <questions.json>` for a set of questions or `--options` for one simple choice, and use `ham-ctl task-chain propose` for chain plans requiring user approval.

Grouped questions use a version-1 object with a `questions` array (see `ham-ctl-reference`). Each question supports single or multiple selections, or a typed custom alternative; all answers are sent by one explicit group submit. Flat options and grouped-question controls are available only on the **LAST durable user-visible message** in that agent conversation; any newer user or agent message expires them. Task approval uses the existing task review UI or an explicit user verdict recorded with `review post --on-behalf-of user`; never infer approval from answer selection or silence.

## 4. Structured Task Briefs (`brief`) and Context Pack (`TASK.md`)
Every executable ticket carries a validated `brief`:
- `goal`: One-paragraph statement of the outcome.
- `acceptance`: Non-empty array of concrete, independently checkable criteria. A goal and at least one acceptance item are all a brief needs to publish.
- `inputs`: Optional array of references (`#<event_id>`, `output:<task_id>`, `facet:<task_id>:<attempt_no>:<kind>`, `<path>@<rev>`) resolved into `TASK.md`. Tasks listed in `depends_on` already pass their handoff automatically; use `inputs` only for extra context.
- `reviewers` / `requires_user_approval`: Optional review gate — durable agent ids (`agt_…`) that must each approve, and whether the user must approve too.
- `output`: Optional output contract (`task_list.v1`, `findings.v1`) for structured results; never required as a stand-in for a command.

Briefs carry no verification command: workers choose the checks and report them, and review verdicts are the gate.

`TASK.md` always carries the complete requirements; only the derived chain summary is bounded. For more context use `ham-ctl task show <task_id>`, `ham-ctl task comments <task_id>` and `ham-ctl task-chain summary get`.

## 5. `ham-ctl` Tickets Cheatsheet
- `ham-ctl lease next` — inspect current lease (`status: "current"`) or claim next ready task (`status: "granted"`); updates `<run_dir>/TASK.md`.
- `ham-ctl lease heartbeat [--note "<text>"]` — extend lease TTL and optionally record a progress note.
- `ham-ctl lease submit --summary "<text>" [--decision <t>]... [--dead-end <t>]... [--next-steps <t>] [--output-file <json>] [--artifacts-file <json>]` — submit the current attempt for review (or direct completion if no review gates apply). `--handoff-file <json>` replaces the inline handoff flags.
- `ham-ctl lease handoff --summary "<text>" [--next-steps <t>] [--decision <t>]... [--dead-end <t>]...` — release the lease back to `ready` with a handoff for the next holder.
- `ham-ctl lease switch <task_id> --summary "<text>"` — solo mode: hand off the current task and take another ready one.
- `ham-ctl lease block --waiting-on user|task|<system> --reason "<text>" [--ref <id>] [--summary "<text>"]` — block the task on a user decision or an external dependency.
- `ham-ctl review post [<task_id>] --verdict approve|request_changes [--summary "<reason>"] [--findings-file <json>] [--on-behalf-of user]` — post a review verdict and optional structured findings (`[{"path":"...","line":1,"severity":"blocker","text":"..."}]`).
- `ham-ctl task show <task_id>` / `ham-ctl task comments <task_id> [--last N]` — read a task's brief, reviews, attempts and comments.
- `ham-ctl task create --title "<title>" --goal "<goal>" --acceptance "<item>" [--assignee <agt_id>] [--reviewer <agt_id>]... [--require-user-approval] [--depends-on <id,id>] [--brief-file <json>]` — create a task.
- `ham-ctl task update <task_id> [...]` — update task fields or brief.
- `ham-ctl task publish <task_id>` / `ham-ctl task-chain publish <chain_id>` — validate briefs and publish tasks (`422 brief_incomplete` lists any missing brief fields).
- `ham-ctl task-chain summary set "<text>" [--chain <id>]` (or `--stdin`) — set the chain summary (`<= 60` lines).
- `ham-ctl task-chain propose --file <proposal.json> [--require-decision] [--chain <id>]` — create a chain proposal and its tasks in a single transaction; auto-approves and publishes unless `--require-decision`. Tickets may pin `bridge_id` and set `agent_models`, like `task create --bridge/--agent-model`.
- `ham-ctl task-chain decide --decision approve|reject [--note "<why>"] [--chain <id>]` — the chain's own coordinator decides its pending proposal (for example once the user approved the plan in chat).
- `ham-ctl task depend <task_id> --on <task_id>` — add one ticket prerequisite.
- `ham-ctl task-chain show` — the chain's tasks, `work_revision`, pending proposal and summary; `ham-ctl task-chain complete <chain_id> --expected-work-revision <n> --summary "<text>"` closes it.
- The user's approval in chat is enough: never ask the user to click Approve in the app. Once the user approved the plan in chat (or the request clearly asks you to create the tasks), propose without `--require-decision` so the tasks publish at once. If a `--require-decision` proposal is already pending, resolve it yourself with `ham-ctl task-chain decide --decision approve --note "Approved by the user in chat"`. The chain's fleet and directories are edited in the Heimdall app.
