---
name: worker-task-management
description: How a WORKER or REVIEWER agent works a ticket lease with ham-ctl — read TASK.md, work in the per-task Workdir, heartbeat, choose and report your own checks, submit / hand off / block (`lease submit|handoff|block`) with decisions and dead ends, read more context (`task show|comments`, `task-chain summary get`), and post structured reviews (`review post`). Also how to share what you learned with the tasks that come after yours. Load whenever you are a worker or reviewer on a chain.
---

# Worker & reviewer task management (Tickets)

The chain's owner Bridge hands you work as a **lease** on one task (every chain is Bridge-owned; `ham-ctl` routes your lease, task and review verbs to that Bridge). You never set task status: holding a work lease *is* `in_progress`; `lease submit` moves the task to `in_review` (or `done` when nobody reviews it). Work only on the leased task; route scope questions to the coordinator (task comment, or `ham-ctl chat send --to <coordinator-instance-id>`).

All commands use `./bin/ham-ctl`. Exact flags: the `ham-ctl-reference` skill or `ham-ctl <group> --help`.

## Decision table: which command, when
| Situation | Command |
|---|---|
| Woken, or unsure what you hold | read `TASK.md`, then `lease next` |
| Idle and want work (solo mode, or after finishing) | `lease next` |
| Need context `TASK.md` omitted or points to | `task show <task-id>`, `task comments <task-id>`, `task-chain summary get` (see §6) |
| Long stretch without ham-ctl calls | `lease heartbeat --note "<progress>"` (at least every 15 min) |
| Made a choice others might re-open, or hit a dead end | note it now; pass it at submit/handoff as `--decision` / `--dead-end` |
| Work done | run the checks the change calls for (see §4), commit everything in the Workdir |
| Checks pass on a clean tree | `lease submit --summary "<what exists now; checks run; outcomes>" [--decision …] [--dead-end …]` |
| A check fails | fix, commit, re-run it; never submit a failure without saying so in the summary |
| Context or time running out, not finished | `lease handoff --summary … --next-steps … [--dead-end …]` |
| Need a user decision or an external system | `lease block --waiting-on user --reason "<question>"` (or `--waiting-on <system>`) |
| Brief is ambiguous or contradicts itself | `task comment <task-id> --body "<what is unclear>"`, then block if you cannot proceed |
| Asked to checkpoint (the task was put on hold or the lease revoked) | reach a safe point, commit, `lease handoff --summary … --next-steps …`; a reviewer hands off with its review progress instead of posting a verdict. The task stays parked until released |
| Woken with **Merge Conflict** | merge the directory's branch into yours in the Workdir, resolve, commit, re-run the affected checks, submit |
| Woken with `changes_requested` | address every Open Finding, re-check what changed, submit |
| Woken with **Your Block Was Answered** | continue with the answer; no need to ask again |
| Any command returns `409 lease_lost` | stop at once; touch nothing |
| Woken as a reviewer | read the brief and what the coordinator asked you to check, inspect the head and the worker's reported checks, run your own checks only where a concrete concern remains, then `review post` |
| Review: everything checks out | `review post --verdict approve` |
| Review: something is wrong | `review post --verdict request_changes --summary … [--findings-file …]` |
| Want to postpone this task or do something else first | `lease switch <task_id> --summary …` (solo) or `lease handoff --summary … --next-steps …`; never ask for a hold to postpone work (a hold is the coordinator's pause, and the user cannot answer a held task) |
| Solo: an urgent task arrives mid-task | `lease switch <task_id> --summary "<where you left off>"` |
| Found an unrelated bug | `issue list --query …`, then `issue vote <id>` or `issue create`; do not fix it in this task |

Never: set task status by hand, review your own work, or keep working after `lease_lost`.

## 1. On wake: read `TASK.md`
The owner Bridge writes `<run_dir>/TASK.md` before your turn. It is your authoritative context:

| Section | What it tells you |
|---|---|
| Header | task, chain, `lease_id`, instance, the requirements revision and whether you acknowledged it, and the **Workdir** + branch (or why the Workdir is unavailable: run `lease next` again before working) |
| Current requirements (complete) | the full brief as JSON: goal, acceptance, inputs, reviewers, approvals. It is never truncated |
| Chain summary | done tasks (+ commit), open tasks, coordinator notes and a bounded projection of recent lessons, decisions, dead ends and submissions |
| Context provenance | where the context came from (sources, cursors) |

Presenting requirements does not acknowledge them: after reading `TASK.md`, run `ham-ctl lease heartbeat --lease <lease-id> --acknowledge-requirements-revision <n>` (see §9). Notices such as a merge conflict to reconcile, an answered block, or review findings to address arrive with the lease and in `task show`; `ham-ctl task show <id>` always has the full brief.

`ham-ctl lease next` returns your lease (`status: current`), grants a ready task (`granted`, rewrites `TASK.md`) or `none`.

## 2. Work in the Workdir
In a git directory every task gets its own checkout: `<dir>/.heimdall/worktrees/<task_id>` on branch `heimdall/<task_id>`. **`cd` to the Workdir and do all edits and commits there.** `lease submit` runs there automatically. When the task is `done` the owner Bridge merges your branch into the directory's branch. Work from tasks you depend on is already merged into your starting point.

If you are woken with a merge conflict: in the Workdir, merge the directory's current branch into yours, resolve, commit, re-run the checks the merge affects, submit.

## 3. Heartbeat and `409 lease_lost`
Every `ham-ctl` call heartbeats implicitly. During long stretches without CLI calls, leave a note (it survives into the next attempt if this one dies):
```bash
./bin/ham-ctl lease heartbeat --note "fold transitions done; running unit tests"
```
**`409 lease_lost`: stop immediately.** Do not edit, commit or build further; the owner Bridge re-wakes you with a fresh `TASK.md` if needed.

## 4. Choose and report your checks
No task configures a verification command; you decide what proves the change. Choose and run checks appropriate to the change (a focused build, the tests that cover the code you touched, a reproduction of the bug, a grep for leftovers), and keep them proportionate: copy, docs and other low-risk changes may need none. Run long commands through `ham-ctl shell run`.

Report every check in `lease submit --summary`: the exact command, its outcome (pass/fail counts, exit code), and any check you deliberately skipped and why. A reviewer judges the work from your diff and this evidence; nothing is executed or gated on your behalf.

## 5. Submit, hand off, or block — and share what you learned
The tasks after yours see only their `TASK.md`. What you write here is what they learn:

| You write | Where it goes |
|---|---|
| `--summary` (line 1 = what exists now) | chain summary for **every** later task; full text to dependents and the next attempt |
| `--decision` (repeat per item) | dependents and the next attempt |
| `--dead-end` (repeat per item) | immutable handoff history; bounded summaries link to full evidence |
| `--next-steps` | dependents and the next attempt |
| `--output-file` | dependents (inline when small) |

**Record every decision others might re-open and every dead end in these flags, not only in the summary text** (protocol rule 11).

```bash
# Finished
./bin/ham-ctl lease submit \
  --summary "Added refresh_tokens table and rotation in auth/tokens.py; unittest green" \
  --decision "sha256 for token hashes (bcrypt too slow per request)" \
  --dead-end "SQLite partial index on revoked_at: our migrator rejects it" \
  [--output-file output.json] [--artifacts-file artifacts.json]

# Not finished (context or time running out): the next holder starts from this
./bin/ham-ctl lease handoff \
  --summary "Migration done; handler wiring remains" \
  --next-steps "add the route in wiring.odin; run the handler tests" \
  --dead-end "taking state_mutex before tx_mutex violates lockorder"

# Waiting on the user or something external
./bin/ham-ctl lease block --waiting-on user \
  --reason "Should the commit-diff limit default to 100 or 200?"
```
- Inline flags or `--handoff-file handoff.json` (`{"decisions":[…],"dead_ends":[…],"next_steps":"…"}`), not both.
- `artifacts.json`: `{"items":[{"kind":"file","path":"…","label":"…"},{"kind":"url","url":"…"},{"kind":"preview_port","port":5173}]}`.
- A block parks the task in `backlog`; the answer arrives with your next lease (`TASK.md`, `task show`). `--waiting-on` is free text: `user` for the user, `task` for another task, anything else for external systems.

## 6. Read more context
`TASK.md` keeps the complete requirements; only the derived chain summary is bounded. When you need more than it carries:
```bash
./bin/ham-ctl task show <task-id>                 # brief, requirements revision, blocked_on, reviews, attempts
./bin/ham-ctl task comments <task-id> --last 20   # comment bodies
./bin/ham-ctl task show <dependency-task-id>      # a prerequisite's handoff and output
./bin/ham-ctl task-chain summary get              # the curated chain summary (owner store; vault_locked if the Bridge cannot decrypt)
git -C <Workdir> log --oneline -20                # what earlier tasks merged into your starting point
```

## 7. Reviewing
When `TASK.md` says `reviewer` (a review lease):
1. Read the brief, the submitted attempt (summary with the checks the worker reported, handoff) and any review focus the coordinator gave in the brief or a comment: it says what *you* must check.
2. Inspect the change at the submitted head (`git show --stat <head>`, `git show <head>:<path>`).
3. Judge correctness yourself. Read the diff against the acceptance items and the worker's reported checks. Run your own checks (for example in a detached worktree at the submitted head) only where a concrete concern remains; say what you checked in `--summary` or findings. Your verdict needs no command evidence.
4. Post the verdict:
   ```bash
   ./bin/ham-ctl review post --verdict approve

   cat > findings.json <<'EOF'
   [{"path": "auth/tokens.py", "line": 142, "severity": "blocker",
     "text": "a revoked refresh token is still accepted"}]
   EOF
   ./bin/ham-ctl review post --verdict request_changes \
     --summary "revoked refresh tokens still rotate" --findings-file findings.json
   ```
   Findings use `path`, `line`, `severity`, `text`. `request_changes` needs `--summary` or findings. The response says `gate: waiting|approved|changes_requested`. When every required review passes, the task is `done`, its branch is merged and its dependents become ready.

## 8. Solo mode
When you are the chain's coordinator and also hold a worker fleet row (solo mode), you are the coordinator and the worker; the user reviews. Pull work with `lease next` (nothing is pushed to you), submit, and pull the next task right away. To take an urgent task mid-way: `ham-ctl lease switch <task_id> --summary "<where you left the current one>"` (the current task returns to `ready`; the attempt is not counted). You never review your own work; the owner Bridge refuses it.

### Unavailable fleet instances

A user-stopped, terminated, or failed fleet instance prevents an automatic replacement launch when no eligible free instance exists on that bridge. Use the task’s **Start agent** card to retry after repairing the cause. Retriable provider errors remain queued during backoff and retry automatically; bridge-offline blocks clear when that bridge reconnects.

## 9. Requirements changed while you work or review

On a requirement-change notice, refresh with `lease next` and read the latest `TASK.md`, including the changed goal, acceptance and revision. Reconcile your work and checks with the amendment, then acknowledge exactly the revision and lease you read:

```bash
./bin/ham-ctl lease heartbeat --lease <lease-id> --acknowledge-requirements-revision <n>
```

Only the holder may acknowledge its lease; an ordinary heartbeat or comment is not acknowledgement. If requirements change again, reread and acknowledge the newer revision. Submit binds the current lease/revision; a stale or unread revision must be reconciled before submission. Report scope decisions and any changed verification in task comments and the handoff.

For review, inspect the submitted requirements revision, attempt and commit. If a change requires a checkpoint, hand off the review rather than approving stale work. After worker rework, assess the new submission; do not reuse an obsolete verdict.

If the change substantially replaces the objective, deliverable or approach, ask the coordinator to record the decision on the original and create a linked replacement. Preserve completed work and checkpoint/handoff context; do not silently repurpose your task.
