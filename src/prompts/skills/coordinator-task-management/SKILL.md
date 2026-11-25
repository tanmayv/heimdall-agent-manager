---
name: coordinator-task-management
description: How a task-chain COORDINATOR (or soloist) runs a chain with ham-ctl — choose tickets or workflow runs, propose and publish tasks with complete briefs, set the fleet and review roles, curate the chain summary, react to `[taskv2]` notices, record user verdicts (`review post --on-behalf-of user`), amend or replace tasks, and close the chain. Load whenever you coordinate a chain.
---

# Coordinator task management (Tickets)

You plan, triage, publish and steer. Leased **workers** and **reviewers** do the work, unless the chain runs in **Solo mode** (§8), where you are also the worker and the user reviews.

The Hub owns task state: active work claims make tasks `in_progress`, submits `in_review`, passing reviews `done`. There is no status verb for tasks. Commands use `./bin/ham-ctl`; exact flags are in `ham-ctl-reference` or `ham-ctl <group> --help`.

Any authenticated agent instance of the same owner may do these coordinator operations without chain membership or coordinator status: publication/completion, graph and scope, workflow run controls/reads, fleet configuration/deletion/pause/resume, ordinary task publication, and chain title/description/summary/directories. Target chains and referenced resources remain owner-isolated. This does not confer coordinator identity or widen proposal, named claim/transfer, assignee, lease-bound submission or review authority. Preserve required reviewer and explicit user approval gates.

## 1. Choose the next work item, not a chain type
Every task chain is `mixed_work`; you stay coordinator of the same chain, team and directories throughout. Add ordinary tickets when their briefs are known; add workflow runs for recurring recipes or discovery followed by fan-out. Reassess as work evolves; neither choice creates a second chain.

Ordinary tickets remain editable. Workflow-generated stage tasks are engine-managed: inspect their run and use whole-run retry/cancel rather than editing stage identities. Configure shared fleet roles before starting a recipe; runs never widen the fleet.

```bash
./bin/ham-ctl workflow templates
./bin/ham-ctl workflow run fix_flaky_tests --chain <chain-id> --request-id <stable-key> \
  --input suite=src/auth --input test_command="make test-auth" \
  --after task:<investigation-id>
./bin/ham-ctl workflow list --chain <chain-id>
./bin/ham-ctl workflow status <run-id>
./bin/ham-ctl workflow output <run-id> <stage-key> [--execution <n>]
./bin/ham-ctl workflow history <run-id>
./bin/ham-ctl workflow retry <run-id> --expected-revision <revision> --reason "<why>"
./bin/ham-ctl workflow cancel <run-id> --execution <number> --reason "<why>"
./bin/ham-ctl task-chain depend --chain <chain-id> --item task:<validation-id> --on workflow_run:<run-id>
```

To fan out over a list you already know, define a stage with `"for_each": "inputs.<array-input>"` and pass the list with `--inputs-file`; no echo stage is needed. An empty list completes that stage with zero tasks. See ham-ctl-reference "Authoring workflow definitions" for item placeholders.

Creation request keys are caller-selected and reused on network retries; a key with different inputs fails. Retry creates a new execution with fresh tasks and preserves all old attempts. Stage/cascade retry is unsupported. If outputs have already been consumed, retry/reopen is refused with consumer references; create replacement work and explicitly change the future dependency graph instead.

Use `task-chain graph [<chain-id>]` to inspect dependencies, scope history, and `work_revision`. Dependencies can join any ticket or whole run in this chain. For a ticket waiting on a run, `task depend <task-id> --on workflow_run:<run-id>` is the same graph edge; `--depends-on` on `task create`/`update` takes ticket ids only. Cancelled, failed, or excluded items do not satisfy prerequisites. Remove an edge with `task-chain remove-dependency --dependency <id> --reason "<why>"`. Graph verbs default to your chain; any authenticated agent of the owner may read/change it. Mutations still require an active chain, same-chain endpoints and an acyclic graph; started-input and consumption guards remain.

A new proposal can add work to an active chain mid-work. Its `kind` is `task` or `workflow_run`, describing the proposed item, never changing the chain type. Decide a pending proposal before proposing another.

## 2. Propose, approve, publish
To start a new chain with its own coordinator (usually only when the user asks), name the durable agent, its bridge, and a provider and model enabled on that bridge (`./bin/ham-ctl bridge providers --bridge <brg_id>` lists them: use a `providers[].provider` with `enabled: true` and one of its `models[].model_id`). `--kind` is optional; every chain is `mixed_work`.
```bash
./bin/ham-ctl task-chain create --title 'Fix flaky auth tests' \
  --coordinator agt_coord --bridge brg_main --provider claude --model opus [--project proj_x]
```
A rejected create (missing or unknown provider/model, bad agent, bridge or project) returns the error and creates nothing: fix the arguments and rerun; no orphan chain to clean up.

```bash
cat > proposal.json <<'EOF'
{
  "kind": "task",
  "rationale": "Backend first so the UI verifies against a real endpoint.",
  "tasks": [
    {"id": "t_api", "title": "Commit-diff endpoint", "priority": "p1",
     "brief": {"goal": "Expose paginated commit-diff for chain directories.",
               "acceptance": ["GET …/vcs/commit-diff returns <= 200 hunks", "taskchain unit tests cover pagination and pass"],
               "assignee": "agt_worker_odin", "review_roles": ["reviewer"]}},
    {"id": "t_ui", "title": "Diff viewer", "depends_on": ["t_api"],
     "brief": {"goal": "Render the commit diff in the task panel.", "acceptance": ["diff renders per file with hunk headers", "UI tests for the viewer pass"],
               "assignee": "agt_worker_ui", "requires_user_approval": true}}
  ]
}
EOF
./bin/ham-ctl task-chain propose --file proposal.json [--auto-approve]
./bin/ham-ctl task-chain decide <chain-id> --decision approve|reject [--reason <text>]
```
- Per-task fields: `id`, `title`, `description`, `priority`, `depends_on`, `brief`. **Put `assignee`, `reviewers` and `requires_user_approval` inside `brief`**; top-level copies are ignored.
- Without `--auto-approve` the proposal waits for an explicit decision. Existing work continues.
- Single tasks: `task create --title … --goal … --acceptance … (repeat) [--assignee agt_…] [--reviewer agt_…] [--review-role <role>] [--require-user-approval] [--input <ref>] [--depends-on <ids>]`, then `task publish <task-id>` or `task-chain publish <chain-id>`.
- Single-task publication requires an already published chain; unpublish is unsupported.
- Publish refuses incomplete briefs with `422 brief_incomplete` listing what is missing per task, including `review_role:<r>` when no fleet row holds a role the brief asks for.

**A good brief** is self-contained: a goal a newcomer can act on and checkable acceptance items (the hub requires only a non-empty goal and at least one acceptance item). Also state limits (scope, files not to touch), a stop condition and the approval scope: which external or destructive actions the user has approved, if any. Do not prescribe a verification command: the worker chooses and reports checks, and reviewers judge correctness from the diff and that evidence. Add `inputs` (`output:<task>`, `<path>@<rev>`) only for context beyond what dependencies already bring: a task automatically receives the handoff of every task it waits for.

## 3. Fleet and review roles
Assign work to durable identities (`agt_…`), never `inst_…`. Referenced durable agents and bridges must belong to the owner, and capacity, role and placement checks still apply. `fleet pause`/`resume` stop/start new leases while current work continues. Fleet deletion is `DELETE /api/v1/task-chains/{chain-id}/fleets/{agent-id}`; no fleet delete CLI verb exists.
```bash
./bin/ham-ctl task-chain fleet list [<chain-id>]
./bin/ham-ctl task-chain fleet set <chain-id> --agent agt_worker_odin \
  --capacity 2 --roles worker,reviewer [--min-warm 1] [--idle-ttl 300] \
  [--bridge brg_main]
```
- Runtime defaults and durable-agent overrides are shared across chains per bridge. Use Home Fleet or `bridge fleet show|apply|status|retry` (see `ham-ctl-reference`). Apply restarts changed running task agents, including active claim holders, while preserving claims/workdirs/review gates. Read status for acknowledged readiness; saved settings alone do not prove ready.
- On a bridge that has completed its first Apply, omit runtime fields from chain staffing writes; attempts to change/clear legacy provider/profile/model or `bridge_models` return `fleet_runtime_managed`. Staffing/placement-only updates preserve legacy audit fields. Legacy runtime flags remain usable only on unconfigured bridges. Future launches resolve shared policy locally in the Hub with no additional Fleet startup network read.
- Roles: `worker`, `reviewer`, or a custom review role (`security`, `perf`, …). A brief's `review_roles` asks every agent holding that role to review. Each role can carry a description that tells the reviewer what to check; the user edits roles and descriptions in the chain's **Review roles** dialog.
- Reviewers named on one task (`brief.reviewers` / `--reviewer`) review that task only.
- Each agent's bridge comes from: the task's bridge pin, then its fleet row's bridge, then the chain's first directory, then your own bridge.

## 4. Share learnings across the chain
Agents see only their `TASK.md`. Use the channels the Hub carries forward:

| What | Where | Who sees it |
|---|---|---|
| Conventions every task must follow ("use `pytest -q`", "never touch `legacy/`") | `task-chain summary set` (≤ 60 lines) | every agent, every attempt |
| What a task produced, decided, ruled out | worker's `lease submit` `--summary`, `--decision`, `--dead-end`, `--output-file` | dependents (full), every task (summary line 1 + dead ends in the chain summary) |
| Extra context for one task | `brief.inputs` | that task |
| Lessons that outlive the chain (build quirks, project rules) | `ham-ctl memory propose` (project scope) | future chains |

The Hub renders the chain summary from your curated notes plus mechanical sections (done tasks with their commit, open tasks, every dead end). `summary set` replaces only your curated notes; they are stored separately and re-rendered at once and on every task event, so notes are never dropped and you cannot delete or compact dead ends. `task-chain summary get [<chain-id>]` is read-only: it shows what agents currently see and reports `curated` (your full stored notes), `curated_line_count`, `line_count`, `max_lines` and `overflow_active`. Edit from `curated`: if you paste the rendered `summary` instead, its mechanical lines (title, section headers, task and dead-end bullets, the omission pointer) are dropped on `set`.

The rendered summary is capped at 60 lines, filled in this order: 1. the title line; 2. up to the first 20 non-blank lines of your notes (always rendered); 3. dead ends; 4. further note lines, when room is left; 5. tasks.

When dead ends do not all fit, agents see the first ones plus a `- [+N more dead ends not shown …]` pointer, and the Hub sends `summary_overflow` once for that overflow episode. It does not repeat on later rebuilds or sets; it fires again only after the summary has fit and then overflows anew. Short notes leave room for more dead ends. Nothing is lost: every dead end stays in its task's handoff facet (`task fetch <task-id> facet:<task-id>:<attempt>:handoff`).
```bash
./bin/ham-ctl task-chain summary set --stdin <<'EOF'
Conventions: tests with `pytest -q`; never edit legacy/.
Decided: token hashes are sha256 (t_api).
EOF
```

## 5. React to `[taskv2]` notifications
Routine events stay quiet. You get one line, `[taskv2] <trigger>: …`, only when something needs you:

| Trigger | Do this |
|---|---|
| `proposal_decided` (approved / rejected) | approved: tasks are dispatching, keep the user posted. Rejected: read the reason, revise, propose again |
| `blocked_on human` | a worker ran `lease block --waiting-on user`. Read the question (`task show <id>`), ask the user with `chat send --questions-file <questions.json>` (a set) or `--options` (one simple choice). Their answer (given in the task's UI) re-readies the task and appears in the worker's `TASK.md` |
| `budget_exhausted` | read the attempts (`task fetch <id> facet:<id>:<n>:handoff`), then sharpen or split the brief (`task update`) or `workflow retry` |
| `oscillation` | review rounds keep bouncing: read the open findings (`task show`) and the handoff, make `acceptance` unambiguous |
| `hold_stale` | a task you (or the user) held has had no live lease for a while. If the hold's reason is resolved, `task release <id>`; otherwise leave it held. Repeats once per interval until released |
| `ready_unclaimed` | no eligible worker: check `task-chain fleet list` and `bridge list`, fix capacity, roles or bridge |
| `agent_not_running` | A ready task cannot obtain a running agent, or a claim holder exited or its runtime became unavailable. `task show <id>` shows `blocked_on.kind=agent_not_running` (legacy `dispatch` is equivalent), with agent/provider/model/bridge/error. The user can choose **Start agent** in the attention deck or chat tray; a failed start stays blocked and shows its error inline for retry. Fix the cause, then use the card or `task unblock <id> [--note <reason>]`; editing the affected fleet row also clears the block. No work attempt budget is spent. Full fleet rows remain queued without blocking |
| stuck `ready` / `in_review` / merge | A task looks stuck: `ready_unclaimed` with free fleet capacity, `in_review` although every owed review is in (e.g. after `--no-require-user-approval`), or a done task whose merge is `pending`/`failed`/`none`. Run `task recheck <id>`: it re-runs the gate, readiness, dispatch and merge-back without approving or touching a live lease, and its `reasons` name what still holds (waiting reviewer, `fleet full n/m`, bridge offline, directory without git). Prefer it to `task hold` + `task release`, which also asks a lease holder to checkpoint (see §5 "Pausing vs deferring") |
| `review_requested_from_user` | summarise the evidence and point the user to the existing task review UI; if they explicitly decide in chat, record their verdict (§6). No task approval action card is required |
| `merge_conflict` / `merge_failed` | a done task's branch did not merge; the task returns to its worker with a Merge Conflict section. For `merge_failed` (merge never ran, e.g. bridge offline) check the bridge |
| `gate_rejected` | a workflow gate was rejected: inspect the feedback, talk to the user, and retry the whole run if appropriate |
| `summary_overflow` | sent once per overflow episode: the chain has more dead ends than the 60-line summary can show. Nothing to compact. Your first 20 note lines stay visible. Check what agents see (`task-chain summary get`), trim notes you no longer need to free lines for dead ends, and if a task needs a dead end that is no longer shown, put it in that task's `brief.inputs` or point at `task fetch <task-id> facet:<task-id>:<attempt>:handoff` |
| `work_batch_finished` / `workflow_complete` | assess the goal; add more work or explicitly complete the chain |

### Pausing vs deferring: when to `task hold`
`task hold` is a deliberate stop: nothing dispatches until someone runs `task release`. A hold never gives the user an Answer card, so they cannot answer a held task; a Review card they already owe, or a nested **Start agent** action, stays in their deck. Pick the command that matches your intent:

| Intent | Command |
|---|---|
| Work on something else first (solo) | `lease switch <other_task> --summary …`; the current task returns to `ready` |
| Stop now; someone continues later | `lease handoff --summary … --next-steps …` |
| This task must run after another | `task update <id> --depends-on <id>` (or `task depend`) |
| This task is less urgent | `task update <id> --priority p2` |
| You need the user's answer or decision | `lease block --waiting-on user --reason "<question>"`, which gives the user an answerable card |
| Pause dispatch deliberately (re-route to another identity or model, re-plan, wait on an external event) | `task hold <id> --reason "<why and what releases it>"`, then `task release <id>` |

Rules: never hold a task just to postpone it, and never hold when the user's input is needed (the user cannot answer a held task). Release every hold you set as soon as its reason is resolved.

## 6. Recording the user's verdict
- Workflow gates with approver `user_or_coordinator`: your own `review post --verdict approve|request_changes` decides.
- Tasks with `requires_user_approval` and gates with approver `user`: retain the explicit review gate and use the existing task review UI. When the user explicitly decides in chat, record that verdict for them:
  ```bash
  ./bin/ham-ctl review post <task-id> --verdict approve --on-behalf-of user
  ./bin/ham-ctl review post <task-id> --verdict request_changes --on-behalf-of user \
    --summary "<the user's reason>"
  ```
  The user can also approve directly from their attention deck. Do not create or attach a `task.review` action card as a required step. Never infer task approval from a question-answer selection or silence; wait for an explicit review decision. Unrelated action-card operations, such as memory approval, remain available.

## 7. Closing and out-of-scope defects
- Completion is explicit. Read `task-chain graph --chain <id>`, then run `task-chain complete --chain <id> --expected-work-revision <n> --summary "<final acceptance>"`. Every included ticket must be published and done; every included run must have succeeded; required merges must be resolved, and no leases or pending proposal may remain. At least one success is required. A changed revision requires a fresh inspection, not a blind retry.
- Chain cancellation uses `task-chain set-status cancelled --chain <id>`; archive/restore uses `task-chain archive`/`unarchive`. These are same-owner operations; there is no standalone chain cancel verb or unpublish operation.
- Cancel terminally abandoned work, then exclude it with `task-chain scope --chain <id> --item task:<id>|workflow_run:<id> --action exclude --reason "<why>"`. Exclusion is auditable and never makes a failed prerequisite successful.
- Unrelated bugs: search `issue list --query …`, vote `issue vote <id>`, or file `issue create --title … --description …`.

## 8. Solo mode
The chain is solo when you are the Soloist or hold a worker fleet row yourself. Then:
- You pull work with `lease next` (nothing is pushed), work it per `worker-task-management`, and `lease submit`. Claims never lapse with time; runtime loss retains ownership while recovery is pending.
- New tasks default to `requires_user_approval`; the user reviews from their attention deck. To opt a task out: `task update <id> --no-require-user-approval`.
- You never review your own work (`403 solo_self_review`).
- `[taskv2] solo: task … is ready for you` means pull it with `lease next`.
- Urgent request mid-task: create the task, then `lease switch <task_id> --summary "<where you left off>"`.

## 9. Live requirement amendments and significant changes

Use a native requirement amendment when the user changes acceptance details or clarifies the goal while the task's objective and deliverable stay. Read `task show` first, then supply its `requirements_revision`, the revised goal/acceptance, and a concrete reason:

```bash
./bin/ham-ctl task show <task-id>
./bin/ham-ctl task update <task-id> --goal "<revised goal>" \
  --acceptance "<current acceptance item>" \
  --expected-requirements-revision <n> --reason "<what changed and why>"
```

Decide first whether the objective and deliverable are still the same; a comment alone does not update requirements or wake the worker, and the chain design and acceptance criteria must stay consistent with the amendment. Repeated acceptance flags replace the list; include every item that should remain. A revision conflict requires a fresh read and deliberate reconciliation, not a blind retry. In the UI use **Change requirements** (goal, acceptance, reason) and inspect the task's revision, read status and **Requirement changes** history. MCP clients use `tasks.get` then `tasks.update` with `expected_revision`, `reason` and an idempotent `request_id`; consult the CLI reference and MCP documentation for the distinct concurrency fields.

Native delivery prompts active workers to refresh `lease next`, read the new `TASK.md`, and acknowledge the exact revision on their own lease (`chain-events-and-claims` "Requirement revisions: acknowledging on your own claim"); do not acknowledge for them. An edit after submission invalidates stale review evidence: reviewers checkpoint and worker rework must be submitted before current approval. Comments preserve discussion but do not wake agents or change their brief. Preserve existing review gates.

For a significant change to objective, deliverable or approach that invalidates the plan or review basis:

1. Record the decision on the original task: rationale, old/new scope, retained work and original task disposition.
2. Create a self-contained replacement task linked to the original, with current acceptance and required approvals; record the replacement ID on the original.
3. Checkpoint active work before redirecting it. In solo mode, `lease switch <replacement-id> --summary "..."` preserves progress. Explicitly rewire future dependencies. Terminal tasks need an explicit reopen for further work, and workflow-managed stage identities stay under workflow lifecycle controls. A reference link preserves provenance; a dependency should exist only when the new task actually requires successful completion of the old one.

Do not overwrite the original into an unrelated assignment or treat the scope change as approval of unfinished work.

## Events, claims, transfer and cancel

Event inbox mechanics (`[events]` nudges, `events next` / `events ack`, deduplication, migration of `[taskv2]` notices) and durable claims, `lease transfer` and `task cancel` are in `chain-events-and-claims`: "Event inbox and migration notices" and "Durable claims, cancellation and transfer". Coordinators handle review requests, human blocks, merge conflicts and finished batches with the §5 controls and the required user gates (§6).
