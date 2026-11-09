---
name: coordinator-task-management
description: How a task-chain COORDINATOR runs a Bridge-owned chain of tickets with ham-ctl — propose and publish tasks with complete briefs (`task-chain propose|publish`, `task create|publish`), wire ticket dependencies (`task depend`), name each task's reviewers (`--reviewer`), curate the chain summary so learnings reach every agent, react when work needs you (blocked on a human, parked on the coordinator, stuck, merge conflicts, user reviews), correct tasks with coordinator controls (`task hold|release|unblock|recheck|cancel|reopen|split|done --force`, `lease revoke`, `merge retry`), record user verdicts (`review post --on-behalf-of user`), and close the chain (`task-chain complete`). Covers Solo mode, where the coordinator also does the work, and importing legacy Hub chains. Load whenever you coordinate a chain.
---

# Coordinator task management (Tickets)

You plan, triage, publish and steer. Leased **workers** and **reviewers** do the work, unless the chain runs in **Solo mode** (§8), where you are also the worker and the user reviews.

Every chain is **Bridge-owned**: its tasks, leases, reviews, fleet, workflow runs and summary live in the owner Bridge's local store, and `ham-ctl` routes your task, lease and review verbs to that owner. The Hub only knows which Bridge owns the chain (plus chat, agents, artifacts, memory and projects). Leases make tasks `in_progress`, submits make them `in_review`, passing reviews make them `done`. There is no status verb for tasks. Commands use `./bin/ham-ctl`; exact flags are in `ham-ctl-reference` or `ham-ctl <group> --help`.

Chains are renamed, archived and given their directories in the Heimdall app; `ham-ctl` has no verbs for that (`task-chain list|set-title|directory|graph|decide|scope …` answer `{"ok":false,"code":"hub_chains_removed"}`). To start a new chain yourself, `./bin/ham-ctl task-chain create --title <t> [--description <d>] [--coordinator-agent <agt_id>]`: your Bridge owns it and binds you (or the named agent, launched on your Bridge) as its only coordinator; the user then sees it in the app. You then manage its fleet (§3); grants stay with the user.

## 1. Inspect the chain
```bash
./bin/ham-ctl task-chain show            # your chain: tasks, work_revision, pending proposal, summary
./bin/ham-ctl task list                  # tasks with comment summaries
./bin/ham-ctl task show <task-id>        # one task: brief, requirements revision, blocked_on, reviews
./bin/ham-ctl task comments <task-id> --last 20
```
Dependencies are between tickets of the same chain: `task depend <task-id> --on <prerequisite-task-id>` adds one; `--depends-on <ids>` on `task create`/`task update` sets (and on update replaces) the whole list. Cancelled tasks do not satisfy prerequisites; repoint dependents when you cancel (§5 controls).

Workflow runs that already exist on a Bridge-owned chain (for example one carried over by an import) are steered as a whole: `workflow retry <run-id> --expected-revision <n> --reason "<why>"` or `workflow cancel <run-id> --execution <n> --reason "<why>"`. Their generated stage tasks are engine-managed; do not edit, reopen or cancel them individually.

## 2. Propose, approve, publish
```bash
cat > proposal.json <<'EOF'
{
  "kind": "task",
  "rationale": "Backend first so the UI verifies against a real endpoint.",
  "tasks": [
    {"id": "t_api", "title": "Commit-diff endpoint", "priority": "p1",
     "brief": {"goal": "Expose paginated commit-diff for chain directories.",
               "acceptance": ["GET …/vcs/commit-diff returns <= 200 hunks", "unit tests cover pagination and pass"],
               "assignee": "agt_worker_odin", "reviewers": ["agt_reviewer"]}},
    {"id": "t_ui", "title": "Diff viewer", "depends_on": ["t_api"],
     "brief": {"goal": "Render the commit diff in the task panel.", "acceptance": ["diff renders per file with hunk headers", "UI tests for the viewer pass"],
               "assignee": "agt_worker_ui", "requires_user_approval": true}}
  ]
}
EOF
./bin/ham-ctl task-chain propose --file proposal.json [--require-decision]
```
- Per-task fields: `id`, `title`, `description`, `priority`, `depends_on`, `brief`. **Put `assignee`, `reviewers` and `requires_user_approval` inside `brief`**; top-level copies are ignored.
- Proposals auto-approve by default: briefs are validated and tasks publish at once. Pass `--require-decision` when the user wants to see the plan first; the user then approves or rejects it in the Heimdall app (there is no agent `decide` verb). Existing work continues. Wait for a pending proposal to be decided before proposing another.
- Single tasks: `task create --title … --goal … --acceptance … (repeat) [--assignee agt_…] [--reviewer agt_…]… [--require-user-approval] [--input <ref>] [--depends-on <ids>]`, then `task publish <task-id>` or `task-chain publish <chain-id>`.
- Publish refuses incomplete briefs with `422 brief_incomplete` listing what is missing per task; a brief whose `reviewers` names an agent that is not an enabled member of the chain fleet is refused.

**A good brief** is self-contained: a goal a newcomer can act on, checkable acceptance items (a ticket needs a non-empty goal and at least one acceptance item; nothing else is required). Do not prescribe a verification command: the worker chooses and reports checks appropriate to the change, and reviewers judge correctness from the diff and that evidence. Add `inputs` (`output:<task>`, `<path>@<rev>`) only for context beyond what dependencies already bring: a task automatically receives the handoff of every task it waits for.

## 3. Fleet and reviewers
Assign work to durable identities (`agt_…`), never `inst_…`. You manage the chain's fleet (the user can too, in the app):
- `task-chain fleet list` — rows (capacity, bridge, provider/model, pause) and members (`running`).
- `task-chain fleet set --agent agt_… [--capacity N] [--provider p --model m] [--project <repo project>]` — saves the row and, when the agent has no member yet, launches it on the owner Bridge and binds it, so `task create --assignee agt_… --reviewer agt_…` dispatches to it. Pass `--project` for the chain repository's project (git tasks need workers launched there); `--instance inst_…` binds a running instance instead. A row for your own agent is your solo row.
- `task-chain fleet pause|resume --agent agt_…` (the whole row), `task-chain fleet remove --agent agt_…` (disables its members); `agents start|stop|restart <inst>` for the chain's instances.
- Limits: you never add a coordinator, never remove, disable, demote or stop yourself; grants stay with the user.
- Review gate: a task's reviewers are the agents in `brief.reviewers` (`--reviewer agt_…`, repeatable) plus the `requires_user_approval` flag. Every listed reviewer must approve (one `request_changes` sends the task back); with `--require-user-approval` the user must also approve from the Heimdall app. On a Bridge-owned chain the first `--reviewer` is the independent reviewer configured with the `--assignee`; several reviewers need a brief.
- Every reviewer must be an enabled member of the chain fleet: add it with `task-chain fleet set --agent agt_…` first. Each reviewer opens its own review session on the submitted attempt when it runs `review post`. Re-target a task's reviewers with `task update <task-id> --reviewer agt_… [--reviewer agt_…] [--require-user-approval]`; tell the reviewers in the brief or a comment what to check.

## 4. Share learnings across the chain
Agents see only their `TASK.md`. Use the channels the owner Bridge carries forward:

| What | Where | Who sees it |
|---|---|---|
| Conventions every task must follow ("use `pytest -q`", "never touch `legacy/`") | `task-chain summary set` (≤ 60 lines) | every agent, every attempt |
| What a task produced, decided, ruled out | worker's `lease submit` `--summary`, `--decision`, `--dead-end`, `--output-file` | dependents (full), every task (summary line 1 + dead ends in the chain summary) |
| Extra context for one task | `brief.inputs` | that task |
| Lessons that outlive the chain (build quirks, project rules) | `ham-ctl memory propose` (project scope) | future chains |

Read the summary with `task-chain summary get` (or `show`); it never writes and reads only the owner store (`vault_locked` when the owner Bridge cannot decrypt it; it never prints ciphertext). Only `summary set <text>|--file <path>|--stdin` writes.

The owner Bridge projects a bounded chain summary from retained source history and separate curated notes. Keep notes short and current. `summary set` edits notes; it cannot remove immutable handoff history.
```bash
./bin/ham-ctl task-chain summary set --stdin <<'EOF'
Conventions: tests with `pytest -q`; never edit legacy/.
Decided: token hashes are sha256 (t_api).
EOF
```

## 5. When work needs you
Routine events stay quiet. The owner Bridge wakes you with a one-line `[owner-local] <method> on task <id>; …` message, or the task shows up in the user's attention deck, when something needs a decision. Inspect with `task show <id>` (its `blocked_on`, reviews and attempts) and `task comments <id>`, then:

| Situation | Do this |
|---|---|
| Blocked on a human (`lease block --waiting-on user`, or `task escalate`) | Read the question (`task show <id>`), ask the user with `chat send --questions-file <questions.json>` for a set of questions, or `--options` for one simple choice. Their answer (given in the task's UI) re-readies the task and appears in the worker's `TASK.md`. An escalation is cleared only by the user |
| Parked on you (`blocked_on.kind=coordinator`: attempt budget exhausted, or review rounds keep bouncing) | Read the attempts and open findings (`task show`, `task comments`), sharpen or split the brief (`task update`, `task split`), make `acceptance` unambiguous, then `task unblock <id> --reason "<what changed>"`; ask the user only if you cannot resolve it |
| A held task's reason is resolved | `task release <id> --reason "<why>"`; otherwise leave it held |
| Ready but unclaimed, or `blocked_on.kind=agent_not_running` | Check `task-chain fleet list` and `bridge list`; fix the fleet (`task-chain fleet set|resume`) or `agents start` the stopped member, or ask the user (the task's **Start agent** card). A user's deliberate stop is never cleared by you. Infrastructure failures spend no attempt budget |
| Stuck `ready` / `in_review` / merge | `task recheck <id>`: it re-runs the gate, readiness, dispatch and merge-back without approving or touching a live lease, and its `reasons` name what still holds (waiting reviewer, `fleet full n/m`, bridge offline, directory without git). Prefer it to `task hold` + `task release` |
| A task needs the user's review | Summarise the evidence and point the user to the existing task review UI; if they explicitly decide in chat, record their verdict (§6). No task approval action card is required |
| Merge conflict / failed merge-back | The first conflict returns the task to its worker with a Merge Conflict note; a repeat parks it on you: inspect, then `merge retry <id> --reason …` or `task unblock <id> --reason …`. For a merge that never ran (bridge offline) check the bridge |
| A batch of work finished | Assess the goal; add more work or explicitly complete the chain (§7) |

### Pausing vs deferring: when to `task hold`
`task hold` is a deliberate stop: nothing dispatches until someone runs `task release`. A hold never gives the user an Answer card, so the user cannot answer a held task. A Review card the user already owes, or a nested **Start agent** action, stays in their deck. Pick the command that matches what you want:

| Intent | Command |
|---|---|
| Work on something else first (solo) | `lease switch <other_task> --summary …`; the current task returns to `ready` |
| Stop now; someone continues later | `lease handoff --summary … --next-steps …` |
| This task must run after another | `task update <id> --depends-on <id>` (or `task depend`) |
| This task is less urgent | `task update <id> --priority p2` |
| You need the user's answer or decision | `lease block --waiting-on user --reason "<question>"`, which gives the user an answerable card |
| Pause dispatch deliberately (re-route to another identity or model, re-plan, wait on an external event) | `task hold <id> --reason "<why and what releases it>"`, then `task release <id> --reason …` |

Rules: never hold a task just to postpone it, and never hold when the user's input is needed (the user cannot answer a held task). Release every hold you set as soon as its reason is resolved.

### Coordinator controls
You can correct tasks directly. Every control takes `--reason` (recorded in the audit trail as "by coordinator"); only the chain coordinator may use them, and refusals are printed verbatim.

| Verb | Effect |
|---|---|
| `task hold|release|unblock|recheck <id>` | pause, resume, clear a block, re-evaluate (release and unblock also take `--reason` or `--note`) |
| `task cancel <id> --reason … [--dependents drop|keep|repoint --to <id>]` | cancel; decide what its dependents wait on |
| `task reopen <id> --reason …` | reopen a cancelled, done or merge-blocked task; a refusal names its cause (chain not active, consumed by a started dependent, generated workflow task, wrong state) |
| `task delete <id> --reason …` | delete an unstarted task |
| `task escalate <id> --reason …` | block on a human; only the user clears it |
| `task submit-for-review <id> --summary … --reason … [--override-ack]` | submit the last lease's committed work on the worker's behalf |
| `task done <id> --force --reason …` | complete skipping only the agent review, never a user approval |
| `task split <id> --child-file <json> --reason … [--dependents all|last|map --map …]` | replace a ready task by children |
| `lease revoke <id> --reason … [--disable-fleet] [--stop]` | end a live lease (default: ask the holder to checkpoint) |
| `merge retry <id> --reason …` | retry a failed merge-back |
| `task update <id> --reviewer agt_… [--reviewer …] [--require-user-approval]` | change who reviews a task |
| `task create|update … --assignee self` | only in solo mode (you hold a worker fleet row); otherwise refused: use solo mode or `task done --force` |

Submit kept work for review BEFORE `lease revoke --disable-fleet`: it bumps the fleet revision, after which the old lease can no longer be submitted.

## 6. Recording the user's verdict
- Tasks with `requires_user_approval` (and gates whose approver is `user`) need the user's OWN approval in Heimdall (attention deck / task review UI). A relayed approval is refused (`403 user_approval_required`). You, the chain coordinator, may add or remove the flag yourself (`task update <id> --no-require-user-approval --reason "<why>"`); the change is audited, and clearing it re-evaluates the review gate, so a task already holding every other approval completes. While the flag is on, only the user's own approval counts. When the user asks for changes in chat, you may still relay that:
  ```bash
  ./bin/ham-ctl review post <task-id> --verdict request_changes --on-behalf-of user \
    --summary "<the user's reason>"
  ```
- Unflagged tasks: when the user explicitly decides in chat you may record it with `review post <task-id> --verdict approve|request_changes --on-behalf-of user`.
  The user can also approve directly from their attention deck. Do not create or attach a `task.review` action card as a required step. Never infer task approval from a question-answer selection or silence; wait for an explicit review decision. Unrelated action-card operations, such as memory approval, remain available.

## 7. Closing and out-of-scope defects
- Completion is explicit. Read `work_revision` from `task-chain show`, then run
  `task-chain complete <chain-id> --expected-work-revision <n> --summary "<final acceptance>"`.
  Every ticket must be published and done (or cancelled), every carried-over workflow run settled, and no live leases or pending proposal may remain. A changed revision requires a fresh inspection, not a blind retry.
- Abandoned work: `task cancel <id> --reason … --dependents drop|keep|repoint --to <id>`, or `task delete` for an unstarted task.
- Unrelated bugs: search `issue list --query …`, vote `issue vote <id>`, or file `issue create --title … --description …`.

## 8. Solo mode
The chain is solo when you are the Soloist or hold a worker fleet row yourself (a task assigned to you, or `task-chain fleet set --agent <your agt_id>`). Then:
- You pull work with `lease next` (nothing is pushed), work it per `worker-task-management`, and `lease submit`. Lapsed leases are not counted as attempts.
- New tasks do NOT default to `requires_user_approval`; a task with no reviewers is done on submit. Add `--require-user-approval` when the user wants to review a task; they then review it from their attention deck. The coordinator may also remove it with `--no-require-user-approval --reason "<why>"` (workers and reviewers cannot).
- You may post `review post --on-behalf-of user` for a task that does not require user approval; for one that does, only the user's own verdict counts (`403 solo_self_review`).
- When woken with nothing in hand, run `lease next` to pull the next ready task.
- Urgent request mid-task: create the task, then `lease switch <task_id> --summary "<where you left off>"`.

## 9. Live requirement amendments and significant changes

Use a native requirement amendment when the user changes acceptance details or clarifies the goal while retaining the task's objective and deliverable. Read `task show` first, then supply its `requirements_revision`, the revised goal/acceptance, and a concrete reason:

```bash
./bin/ham-ctl task show <task-id>
./bin/ham-ctl task update <task-id> --goal "<revised goal>" \
  --acceptance "<current acceptance item>" \
  --expected-requirements-revision <n> --reason "<what changed and why>"
```

Repeated acceptance flags replace the list; include every item that should remain. A revision conflict requires a fresh read and deliberate reconciliation, not a blind retry. In the UI use **Change requirements**, provide goal, acceptance and reason, and inspect the task's revision, read status and **Requirement changes** history.

Native delivery prompts active workers to refresh `lease next`, read the new `TASK.md`, and acknowledge the exact revision on their own lease. Do not acknowledge for them. An edit after submission invalidates stale review evidence: reviewers checkpoint and worker rework must be submitted before current approval. Comments preserve discussion but do not wake agents or change their brief. Preserve existing review gates.

For a significant change to objective, deliverable or approach that invalidates the plan or review basis:

1. Record the decision on the original task: rationale, old/new scope, retained work and original task disposition.
2. Create a self-contained replacement task linked to the original, with current acceptance and required approvals; record the replacement ID on the original.
3. Checkpoint active work before redirecting it. In solo mode, `lease switch <replacement-id> --summary "..."` preserves progress. Explicitly rewire future dependencies and keep terminal/workflow lifecycle restrictions. A reference link preserves provenance; a dependency should exist only when the new task actually requires successful completion of the old one.

Do not overwrite the original into an unrelated assignment or treat the scope change as approval of unfinished work.

## 10. Legacy Hub chains
Chains created before Hub task chains were removed remain on the Hub as read-only records (no data is dropped) until they are imported to a Bridge. The user imports them from **Settings → Bridges → Import all legacy chains**: one click imports every not-yet-imported chain, and re-running skips those already imported. One chain can also be moved with `ham-ctl task-chain migrate --chain <id> --owner <bridge-id>`, which needs a request signed by an enrolled browser device (agents only relay it).

Busy chains are imported too. The import neutralizes live work in one transaction and records what it did: live leases end, in-progress tasks are force-held on the owner, in-review tasks carry over in review, running workflows are cancelled, workflow gates on never-succeeded runs are released (their tickets force-held), pending merges are closed (imported done; unmerged work stays on its branch), and outstanding effects are retired. After an import, review the force-held tasks and `task release` them as appropriate. An aborted, unfinished import leaves the chain a read-only legacy record that can be imported again.
