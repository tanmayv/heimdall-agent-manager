---
name: ham-ctl-reference
description: Authoritative reference for exact ham-ctl syntax, for every agent — flags, positional ids and valid values for bridge, agents, task-chain (create, propose, publish, directory, fleet, token-usage, graph/scope/complete), task (authoring and control), lease, review, workflow, issue, automations, webhooks, extension and context. Load when you need a flag or valid value you do not remember. Chat, shell, events, claims, memory, artifact and action-card detail is owned by other skills (pointer table inside).
---

# ham-ctl command reference

`ham-ctl` is the agent control CLI for Heimdall, called with your agent token (already configured) through the managed wrapper in your run directory:

```
./bin/ham-ctl <group> <verb> [<positional-id>] [--flags]
```

Conventions:
- `<id>` positional args come right after the verb; task and chain ids are globally unique, so `--chain` is usually optional.
- Each command prints a single JSON response line.
- `./bin/ham-ctl <group> --help` is the built-in reference of any group; `./bin/ham-ctl --help` lists all groups.

Groups: `bridge`, `agents`, `task-chain`, `task`, `workflow`, `lease`, `review`, `issue`, `chat`, `memory`, `artifact`, `shell`, `events`, `automations`, `extension`, `context`, `start-success`.

Groups documented elsewhere (the owner holds every verb, flag and valid value; do not look here):

| Group | Owning skill and heading |
| --- | --- |
| `chat read`/`send`, `set-title` | `heimdall-ctl-communication` "## 2. Read", "## 3. Send" |
| `chat send --questions-file`, delivered answers | `heimdall-ctl-communication` "## 4. Asking questions" |
| `start-success` | `heimdall-ctl-communication` "## 1. Startup" |
| `shell` run, serve, start, list, log, capture, signal, restart, set-port, kill | `shell-sessions` "## Commands", "## Other verbs" |
| `/proxy/<session_id>/` from this host | `shell-sessions` "## Calling a server session from this host" |
| preview, `preview_url`, tunnel behaviour | `heimdall-preview-setup` "## Start and share", "## Backend behavior through the tunnel" |
| `events next`, `ack`, `watch`, `unwatch`, `subscriptions`, `[events]` nudges | `chain-events-and-claims` "## Event inbox and migration notices", "## Subscriptions, watches and limits" |
| `lease <task-id>`, `lease transfer`, `task cancel` | `chain-events-and-claims` "## Durable claims, cancellation and transfer" |
| acknowledging a requirements revision | `chain-events-and-claims` "## Requirement revisions: acknowledging on your own claim" |
| amending requirements (`task update --expected-requirements-revision`), MCP `tasks.update` | `coordinator-task-management` "## 9. Live requirement amendments and significant changes" |
| `artifact` list, show, content, download, create, html-bundle | `artifact-authoring` "## 3. Upload"; flags: `ham-ctl artifact --help` |
| `memory` list, show, content, propose, scope flags | `memory-management-workflow` "## Scope", "## Commands" |
| `action create` and card payloads | `action-cards` "## From an agent: `ham-ctl action create`" |
| `search` | `search-command` "## Parameters (CLI flag / RPC field)" |
| lease and review procedure, `task fetch` | `worker-task-management` "## 5. Submit, hand off, or block — and share what you learned", "## 6. Fetch omitted or referenced context", "## 7. Reviewing" (signatures below) |

---

## bridge — discover bridges and their providers

Shared bridge runtime policy applies to task coordinators/workers/reviewers
across chains. It does not change staffing, placement or review gates.

- `bridge fleet show|defaults|overrides <bridge-id>` — complete revisioned settings.
- `bridge fleet apply <bridge-id> --draft-file <file>` — complete JSON object with
  `request_id`, `expected_revision`, `default_runtime` and full `overrides`.
  Saves atomically, then restarts changed running task agents, including claim
  holders. Reuse the identical ID/draft after an ambiguous response.
- `bridge fleet status <bridge-id> <application-id>` — durable per-target outcomes;
  saved settings and acknowledged runtime readiness are separate.
- `bridge fleet retry <bridge-id> <application-id>` — retry eligible failures with
  stable native keys; ready targets are skipped.

MCP parity: `fleet.read`/`fleet.status` require `mcp:instances:read`;
`fleet.apply`/`fleet.retry` require `mcp:instances:control`. Fleet Apply supports
active-task holders, preserving claims and review gates. Existing idle guards
for unrelated instance tools remain. Live grant/scope/cancellation checks apply
before new native work and recovery. See `docs/fleet-management.md`.
- `bridge list [--scope hub|configured|all]` — bridges you can target. Default `all` =
  Hub-registered + locally-configured peers + this host (self).
- `bridge providers --bridge <id>` — that bridge's providers and their models: `providers[].provider` (with `enabled`) and `providers[].models[].model_id`. These are the `--provider` / `--model` values a launch accepts. Without `--bridge` it returns the bridge list only (no providers or models); use `bridge list` to find bridge ids.
- `bridge provider-status <bridge-id>` — the same per-provider view of one bridge, documented for its `providers[].acp_availability`: whether that provider can run over ACP on that bridge and, if not, why (for example the bridge runs a version without ACP support). Check it before `agents instance reconfigure --transport acp`.

## agents — durable identities, templates, and runtime instances
- `agents list` — your durable agent identities.
- `agents identity create --name <n> [--template <id>] [--provider <p>] [--slug <s>] [--instructions <t>]` — create a durable agent.
- `agents template list` — list agent templates (personas).
- `agents template create --name <n> [--description <d>] [--persona <t>] [--instructions <t>]` — create a template.
- `agents instance list [--agent <id>] [--live]` — list instances (durable, or only live with `--live`).
- `agents new-instance <agent-id> [--project <id>] [--bridge <id>] [--provider <p>] [--chain <id>]` — launch a NEW instance of a durable agent.
- `agents start <instance-id>` — start a STOPPED instance (errors if already running).
- `agents stop <instance-id> [--reason <t>] [--force]` — stop a running instance. `--force` also stops while a reconfiguration is in progress (recovery; it ends that operation).
- `agents instance reconfigure <instance-id> [--bridge <id>] [--provider <p>] [--profile <id>] [--model <m>] [--transport pty|acp] [--permission-mode yolo|ask] [--apply now|after_turn] [--expected-revision <n>] [--idempotency-key <k>]` — change where and how an instance runs; it restarts with a fresh session and the conversation stays. The CLI reads the instance first and fills every flag you leave out from its current configuration; the project is always kept. `--expected-revision` defaults to the instance's current `configuration_revision` (a concurrent change returns 409 `configuration changed; refresh before applying`). `--apply after_turn` on a busy instance queues the change until the current turn ends (operation phase `waiting_for_idle`); `now` (default) applies at once and supersedes a queued change. A changed `--provider` without `--profile` uses that provider's default profile. `--permission-mode` is user-only: the hub refuses it from an agent token. Returns the operation (202); follow it with `reconfigurations`.
- `agents instance reconfigurations <instance-id>` — list the instance's reconfiguration operations (`operations[]` with `phase`, `revision`, `idempotency_key`, `failure_code`). `phase` is the hub enum ordinal: 0 prepared, 1 stopping, 2 source_stopped, 3 launching, 4 ready, 5 failed, 6 recovery_required, 7 waiting_for_idle.
- `agents instance cancel-reconfiguration <instance-id>` — cancel the change queued after the current turn (the `waiting_for_idle` operation). Errors when nothing is queued.
- `agents restart <instance-id>` — restart (stop-then-start) an instance.


## task-chain — your task chains
Authenticated agent instances may perform the following operations on **any chain of their owner**;
caller chain membership and coordinator status are not required. The authenticated instance and
target resources must belong to the same owner; cross-owner access remains refused.

| Category | Supported surface | Guards that still apply |
| --- | --- | --- |
| Chain lifecycle | `publish`, `complete`, `set-status`, `archive`, `unarchive` | Draft/brief publication rules; completion revision, successes, merges, leases and pending proposals; status transition rules |
| Work graph and scope | `graph`, `depend`, `remove-dependency`, `scope`; ticket dependency edits | Active chain for mutations; endpoints in the same chain, DAG, started-input and consumption guards |
| Workflows | `run`, `retry`, `cancel`; `list`, `status`, `output`, `history` | Active chain for controls; request/revision/execution, terminal-state and consumed-output rules |
| Fleet | `list`, `set`, `pause`, `resume`; deletion through the fleet API | Referenced agents/bridges share the owner; capacity and placement rules |
| Ordinary task publication | `task publish` | Draft ordinary task in a published chain; complete brief with an assignee |
| Chain metadata | Title, description, curated summary and relevant directories | Field/summary limits and referenced bridge ownership |

This authorization does not make the caller the coordinator. Proposal controls, explicit named
claim assignment/transfer, assignee eligibility, lease-bound submissions and review eligibility
retain their separate policies. Keep required reviewer and explicit user approval gates; owner
access never substitutes for a verdict. Unpublish is unsupported.

- `task-chain list [--mine] [--project <id>]` — chains (`--mine` = ones you coordinate).
- `task-chain show [<chain-id>]` — show a chain (defaults to your current chain), including embedded `tasks` and `directories`.
- `task-chain create --title <title> [--description <desc>] [--coordinator <agt_id> --bridge <brg_id> --provider <p> --model <m> [--provider-profile <id>]] [--project <proj_id>]` — create a task chain (always `mixed_work`; `--kind` is optional and only `mixed_work` is accepted). With `--coordinator`, the Hub launches that durable agent as the chain's coordinator on `--bridge`, so `--provider` and `--model` are required and must be enabled and present on that bridge (e.g. `--provider claude --model opus`); list them with `bridge providers --bridge <brg_id>` (use a provider with `enabled: true` and one of its `models[].model_id`). `--project` needs `--coordinator`. A rejected create (missing or unknown provider/model, bad agent, bridge or project, offline bridge) returns the error and creates nothing: no chain and no instance.
  ```bash
  ./bin/ham-ctl task-chain create --title 'Fix flaky auth tests' \
    --coordinator agt_coord --bridge brg_main --provider claude --model opus [--project proj_x]
  ```
- `task-chain set-title <title> [--chain <id>]` — rename a chain of your owner.
- `task-chain set-description <text> [--chain <id>]` (or `--stdin`) — set the chain
  description (any authenticated agent of the owner; pass `""` to clear; `--chain` defaults to your chain).
- `task-chain summary get [<chain-id>]` (or `--chain <id>`) — read-only: the rendered chain summary
  as agents see it, with `line_count`, `max_lines`, `overflow_active`, `version`, `curated` (your full
  stored notes) and `curated_line_count` (defaults to your current chain; any chain of the same owner).
  Never writes, whatever else is passed.
- `task-chain summary set <text> [--chain <id>]` (or `--body <text>`, `--file <path>`, `--stdin`) — replace
  the stored curated notes (`<= 60` lines; any authenticated agent of the owner) and re-render the summary surfaced in every
  agent's `TASK.md`. The 60-line render shows the title, your first 20 non-blank note lines (always),
  then dead ends, further note lines when room is left, then tasks. Mechanical sections are rebuilt from
  task history, so set cannot remove dead ends; ones that do not fit stay in each task's handoff facet
  (`task fetch <task-id> facet:<task-id>:<attempt>:handoff`). Mechanical lines in the set text (title, section
  headers, task and dead-end bullets, the omission pointer) are dropped, so edit from `curated`.
- `task-chain propose --file <proposal.json> [--auto-approve] [--chain <id>]` — create a chain
  proposal (`kind: "task"|"workflow_run"`, `rationale`, `alternative`, `tasks` array or `workflow` + `inputs`) and its draft
  tasks in a single transaction (coordinator only). With `--auto-approve`, validates briefs and
  publishes (or runs the proposed workflow) immediately.
- `task-chain decide <chain-id> --decision approve|reject [--reason <text>]` — approve or reject
  a pending chain proposal (publishes all tasks or starts the proposed workflow atomically on `approve`).
- `task-chain publish <chain-id>` — any authenticated agent of the owner may validate all task briefs and publish the chain (`422 brief_incomplete` lists missing fields per task; a task without an assignee is reported as `assignee_required`). `decide` and `publish` need the chain id (positional or `--chain`).
- `task-chain set-status --status <active|cancelled|archived> [--chain <id>]` — change
  the chain status. Any agent instance of the chain's owner may do this; chain membership
  and the coordinator role are not required. Cancel with `task-chain set-status cancelled --chain <id>` (there is no standalone chain cancel verb). Completion uses `task-chain complete` with a work revision and final summary.
- `task-chain archive [<chain-id>]` / `unarchive [<chain-id>]` — archive or restore a chain (any agent instance of the chain's owner).
- `task-chain pin <chain-id>` / `unpin <chain-id>` — pin a chain to the top of the sidebar.


### Relevant directories (`task-chain directory`)
Any authenticated agent of the owner may list/add/update/remove relevant directories; referenced bridges must belong to that owner.

Associate one or more working directories (local checkouts, CitC workspaces, repos) with a task chain so participating agents and the UI know which workspaces/directories are in scope. Directories are also embedded directly in `task-chain show [<chain-id>]` and `GET /api/v1/task-chains/:id` output under the `"directories"` array.

- `task-chain directory list [--chain <id>]` — list relevant directories for a task chain (`--chain` defaults to your current chain).
- `task-chain directory add --path <path> [--bridge <bridge_id>] [--vcs-kind <kind>] [--chain <id>]` — associate a directory with the chain.
- `task-chain directory update <directory-id> [--path <path>] [--bridge <bridge_id>] [--vcs-kind <kind>] [--chain <id>]` — update an existing directory entry.
- `task-chain directory remove <directory-id> [--chain <id>]` — disassociate a directory from the chain.

#### Directory JSON shape (lean payload)
Directory objects use a lean payload shape containing only operational fields. To keep coordination lightweight, metadata like timestamps (`created_at`, `updated_at`) and authorship/owner fields are intentionally omitted:

```json
{
  "directory_id": "dir_18d7a123bc45de67",
  "path": "/usr/local/google/home/tanmayvijay/heimdall-cloudtop",
  "bridge_id": "brg_18d03379a7d6d47b",
  "vcs_kind": "git",
  "vcs": {}
}
```

Fields:
- `directory_id`: Unique identifier for the directory record (`dir_...`).
- `path`: Target directory path on the bridge host.
- `bridge_id`: Identifier of the bridge where the directory resides.
- `vcs_kind`: Version control system kind (`git`, `citc`, `jj`, or empty).
- `vcs`: Object containing VCS-specific details (branch, commit, status, etc.).


### Token usage (`task-chain token-usage`)
- `task-chain token-usage [<chain-id>]` — per-agent (with its instances) and chain-total token usage, JSON (defaults to your chain). Each `lifetime` is `{total_tokens, context_tokens, est_tool_tokens, output_tokens, runs}`: counted runs (added at each hub stop/restart) plus the latest run when not counted yet; `total_tokens` = context (sum of runs) + output. An agent's `context` is the highest current % of window among its live instances. `has_data:false` when nothing was reported. A context figure is the provider's (`context_source` = its usage source) or, when the provider reports none, an estimate (`context_source:"estimate"`, `estimated_context_tokens` = tool-traffic tokens × 1.5; `context_tokens` stays provider-only). `usage_supported:false` means the provider cannot report context; absent means unknown. `warn_pct` / `rollover_pct` come from the bridge's shipped config, per row.


### Fleet management (`task-chain fleet`)
Any authenticated agent of the chain owner may configure, inspect, pause/resume or delete fleet rows without chain membership/coordinator status. Referenced durable agents and bridges must share that owner; capacity and placement validation still apply. Deletion uses `DELETE /api/v1/task-chains/{chain-id}/fleets/{agent-id}`; there is no dedicated `task-chain fleet delete` CLI verb.

Configure and inspect agent concurrency caps and placement (fleets) for a task chain. Fleets allow tasks to be assigned to durable agent types (`agt_...`) instead of individual instances (`inst_...`). Heimdall dynamically routes or provisions worker and reviewer instances to satisfy fleet capacity and placement rules.

Runtime selection belongs to shared bridge Fleet (`bridge fleet …`, above).
After a bridge's first Apply, omit `--provider`, `--model` and `--bridge-models`
from chain staffing updates. Legacy runtime changes/clears return
`fleet_runtime_managed`; capacity, pause and bridge placement still work
and preserve audit runtime fields. Legacy flags below remain compatibility
controls for unconfigured bridges. Listing legacy fields is not the effective
runtime policy on a configured bridge.

- `task-chain fleet list [<chain-id>]` — list fleet capacities, the pause switch (`paused`), placement (`bridge_id`, `provider`, `model`, `bridge_models`), and live active worker counts for a chain (defaults to current chain if omitted).
- `task-chain fleet set <chain-id> --agent <agent_id> --capacity <N> [--min-warm <M>] [--idle-ttl <seconds>] [--bridge <bridge_id>] [--provider <p>] [--model <m>] [--bridge-models <json>] [--bridge-models-file <path>]` — configure fleet capacity and placement for an agent on the chain. A row only bounds how many instances of that agent run; work goes to a task's assignee and reviews to its reviewers.

- `task-chain fleet pause [<chain-id>] --agent <agent_id>` — stop new work and review leases for the agent's row; current work continues.
- `task-chain fleet resume [<chain-id>] --agent <agent_id>` — allow new leases again.

#### Fleet JSON shape
`task-chain fleet list` returns a JSON array of fleet configurations:
```json
[
  {
    "chain_id": "chain_18d711c5384a0119",
    "agent_id": "agt_worker",
    "capacity": 3,
    "active_count": 1,
    "min_warm": 0,
    "idle_ttl_seconds": 300,
    "paused": false,
    "bridge_id": "brg_main",
    "provider": "claude",
    "model": "claude-opus-4-6",
    "bridge_models": {},
    "created_at": "2026-09-24T00:00:00Z",
    "updated_at": "2026-09-24T00:00:00Z"
  }
]
```

Fields:
- `chain_id`: Unique identifier of the task chain (`chain_...`).
- `agent_id`: Durable agent template identifier (`agt_...`).
- `capacity`: Maximum concurrent running worker instances allocated for this agent on the chain.
- `active_count`: Currently active (running or busy) worker instances assigned to tasks in this chain.
- `min_warm`: Minimum warm standby instances to maintain.
- `idle_ttl_seconds`: Time before idle instances are stopped or decommissioned.
- `paused`: `true` stops new work and review leases for this row; live leases continue.
- `bridge_id`: Optional chain staffing placement. `provider`, `model`, `bridge_models`: Legacy runtime audit/fallback values, authoritative only until that bridge's first shared Apply.

## task — ticket authoring and control
Tickets are the work items in a chain. The CLI, API and events keep the technical name `task`: `ham-ctl task …` verbs, `task_…` ids, `/tasks/` routes and `[taskv2]` notifications.
A positional `<task-id>` identifies the task and is enough on its own (task ids are globally unique; you rarely need `--chain`).

- `task list [--chain <id>]` — your chain's tasks. Each carries a `comment_summary`
  (count, last_comment_at, author, preview) — NOT full comment bodies.
- `task show <task-id> [--chain <id>]` — a task + its `brief` + `comment_summary` + facets.
- `task comments <task-id> [--last N]` — fetch comment BODIES; `--last N` = newest N (max 100).
- `task create --title <t> --assignee <agt_id> [--description <d>] [--priority p0|p1|p2] [--reviewer <agt_id|user,...>] [--review-focus <agt_id>=<text>]... [--depends-on <id,id>] [--bridge <bridge-id>] [--chain <id>] [--goal <g>] [--acceptance <a>]... [--input <ref>]... [--output-schema <task_list.v1|findings.v1>] [--on-output-workflow <name>] [--require-user-approval] [--brief-file <path.json>]` — create a task.
  `--assignee` is required (or `assignee` in `--brief-file`). `--assignee` and `--reviewer` take durable agent IDs (`agt_...`); `--reviewer` also takes `user` (the user's approval). The assignee cannot be a reviewer. `--review-focus <agt_id>=<text>` tells that reviewer what to check (`brief.review_focus`).
- `task update <task-id> [--title <t>] [--description <d>] [--priority p0|p1|p2] [--assignee <agt_id>] [--reviewer <agt_id|user,...>] [--review-focus <agt_id>=<text>]... [--depends-on <id,id>] [--bridge <bridge-id>] [--goal <g>] [--acceptance <a>]... [--input <ref>]... [--output-schema <task_list.v1|findings.v1>] [--on-output-workflow <name>] [--require-user-approval | --no-require-user-approval] [--brief-file <path.json>] [--expected-requirements-revision <n> --reason <text>]` — edit an existing task. `--goal` and `--acceptance` amend native requirements with optimistic concurrency: pass the revision just read from `task show` (`requirements_revision`) as `--expected-requirements-revision` with a `--reason`; acceptance flags replace the whole list; on conflict reread and reconcile. Existing ownership, terminal-task and workflow-stage restrictions still apply. Any agent instance of the task's owner may update it (chain membership is not required); dependency edits (`--depends-on`) use the same owner policy while preserving same-chain endpoints, DAG and started-input/consumption guards.
- `task publish <task-id>` — any authenticated agent of the owner may publish an ordinary draft task in a published chain after validating its brief. A brief needs a non-empty `goal`, at least one `acceptance` item and an `assignee` (`422 brief_incomplete` lists what is missing; a missing assignee is `assignee_required`).
- `task unblock <task-id> [--note <reason>]` — the owner or any of its agent instances clears a block and retries matching. Unavailable agents carry `blocked_on.kind=agent_not_running` (legacy `dispatch` is supported) and an agent/provider/model/bridge/error reason. Fix the cause first. The user can click **Start agent** (`agent.start {task_id}`) on the attention card or chat tray; failures keep the block, update its reason and show the error inline for retry. Updating the affected fleet row also clears its blocks. Infrastructure failures do not consume work attempt budget; a full fleet row is normal queueing. A task assigned to the coordinator's agent stays pull-only: an explicit user Start launches the coordinator before clearing the block, then it pulls the ready task.
- `task recheck <task-id>` — owner or any of its agent instances: recompute what the Hub would decide for the task now — the review gate against the CURRENT reviewers and user-approval flag; dependency readiness; a `bridge_offline` agent block whose bridge is back; dispatch against fleet capacity, pause and bridge state; and a done task's pending/failed merge-back (only when the task was already done and no merge job for it is still running; a task the re-check itself moves to done gets its one merge from that transition). Never approves (it only counts verdicts already posted), never touches a task with a live lease, never spends an attempt; a call that changes nothing records nothing. Prints `{task, changed, actions[], reasons[], message}`: `actions` say what changed (`state: in_review → done`, `dispatched: work lease …`, `merge-back re-queued …`), `reasons` say what still holds it (`waiting on review from agt_x`, `agt_w: fleet full 2/2 on bridge …`, `agt_w: bridge … is offline`, `chain directory … already has a live work lease (vcs_kind "")`, `merge pending: the merge-back is in flight on bridge …`, `merge none: chain directory … has vcs_kind ""`). Use it instead of `task hold` + `task release` to unstick a task. Also `POST /api/v1/tasks/{id}/recheck` and the **Re-check** item in the task card menu.
- `task hold <task-id> --reason <text>` — owner or any of its agent instances: stop dispatching the task until someone runs `task release`. No work or review lease is granted, the review gate freezes (verdicts are still recorded), and `task answer` is refused. A current lease is NOT revoked: its holder sees **Checkpoint Requested** in TASK.md and should `lease handoff`, after which the task parks in `backlog`. A hold never gives the user an Answer card: the user cannot answer a held task. A Review card the user already owes stays (their verdict is still recorded, and the gate resumes on release), and so does a nested agent-not-running **Start agent** action. Use it only to pause deliberately (re-routing to another identity or model, re-planning, waiting on an external event). Do NOT use it to postpone work (`lease switch`/`lease handoff`, `--depends-on`, `--priority`) or to ask the user (`lease block --waiting-on user`). Prints `{task, changed, checkpoint_requested, message}`; holding a held task is a no-op.
- `task release <task-id>` — owner or any of its agent instances: clear a hold. The task can be dispatched again, and an `in_review` task has its gate re-evaluated. Release itself never changes the attempt number. A task that was handed off at a checkpoint continues as the same attempt, and review leases keep the current attempt. A fresh work grant still counts as usual: the first lease of a task that was never leased, or a new claim after ownership was explicitly released, starts a new attempt. Releasing an unheld task is a no-op.
- `task comment <task-id> --body <t>` (or `--stdin`) `[--notify <id,id>]` — add a comment.
- `task depend <task-id> --on <task-id>|task:<task-id>|workflow_run:<run-id> [--chain <id>]` — add one prerequisite to a ticket. A `workflow_run:` prerequisite becomes a chain-level graph edge on the whole run (the ticket stays ineligible until that run succeeds). Other typed refs (stage keys, `workflow:` names, issues) are rejected with guidance; use `task-chain depend` for run-on-ticket or run-on-run edges. `--depends-on` on `task create`/`task update` takes ticket ids only (`task:<id>` accepted) and `update --depends-on` replaces the whole list.
- `task cancel <task-id>`: `chain-events-and-claims` "## Durable claims, cancellation and transfer".
- `task fetch <task-id> <ref>` — fetch one event (`#<event_id>`), `output:<task_id>`, `facet:<task_id>:<attempt_no>:<kind>`, or a file: `dir:<dir_id>:<rev>:<path>`, `<path>@<rev>`, or bare `<path>`; refs are referenced by `TASK.md`.

### lease and review: signatures only
Procedure, decisions and dead ends, checks and reviewing are owned by `worker-task-management`; claims and transfer by `chain-events-and-claims`. Exact signatures:
- `lease next` · `lease heartbeat [--note <text>] [--lease <id>] [--acknowledge-requirements-revision <n>]` (on `409 lease_lost` stop at once, touch nothing)
- `lease submit --summary <s> [handoff flags] [--output-file <json>] [--artifacts-file <json>] [--artifacts <json>] [--lease <id>]` — validates `output` against the brief's output contract (`task_list.v1`, `findings.v1`)
- `lease handoff --summary <s> [handoff flags] [--lease <id>]` — stop without finishing; the task returns to `ready` and the next holder gets your handoff · `lease switch <task_id> --summary <s> [handoff flags]` — hand off the current task (attempt not counted) and take `<task_id>` (must be `ready`) in one step
- Handoff flags: `--decision <text>` and `--dead-end <text>` (repeatable), `--next-steps <text>`, or `--handoff-file <json>` (`{"decisions":[…],"dead_ends":[…],"next_steps":"…"}`), not both.
- `lease block --waiting-on <kind> --reason <text> [--ref <id>] [--summary <s>]` — `<kind>` is free text: `user`, `task`, or an external system.
- `review post [<task-id>] --verdict approve|request_changes [--summary <reason>] [--findings-file <json>] [--task <id>] [--on-behalf-of user]` — findings `[{"path","line","severity","text"}]`; response `gate: waiting|approved|changes_requested`; coordinators pass `--on-behalf-of user` to record the user's verdict on tasks that require user approval (or gates whose approver is `user`); refused for an attempt your own agent authored (`author_self_review`; `coordinator-task-management` "## 6. Recording the user's verdict").

### Task states
A task carries a `state`: `backlog`, `ready`, `in_progress`, `in_review`, `done`, `cancelled`.
State is driven by the hub (leases, reviews, dependencies); agents do not set it directly.
The v1 verbs `task status`, `task vote`, `task nudge` and `task set-current` no longer exist.

### Mixed work
All chains have `kind: mixed_work`. Choose tickets or workflow runs per item while
keeping the same chain, coordinator, team, and directories. See coordinator-task-management.

## workflow — runs inside a mixed-work task chain
Any authenticated agent of the chain owner may start/retry/cancel runs and read their list, status, output and history without chain membership/coordinator status. Owner/reference isolation and active-chain, request/revision/execution, terminal-state and consumption rules still apply to controls. Workflow review gates retain their separate approver policy.

- `workflow templates` lists built-ins and owner definitions; `workflow define --file <definition.json>` saves a version.
- `workflow run <ref> --chain <id> --request-id <stable-key> [--title <text>] [--input k=v ...] [--inputs-file <json>] [--after task:<id>|workflow_run:<id> ...]` snapshots a recipe into that chain. Reuse the request key on network retries.
- `workflow list --chain <id>` lists runs and the chain work revision.
- `workflow status <run-id> [--execution <n>]` inspects a current or historical execution.
- `workflow output <run-id> <stage-key> [--execution <n>]` reads outputs.
- `workflow history <run-id>` reads executions and lifecycle events.
- `workflow retry <run-id> --expected-revision <n> --reason <text>` creates fresh execution/tasks for a terminal run. Consumed outputs block retry. Stage/cascade retry is unsupported.
- `workflow cancel <run-id> --execution <number> [--reason <text>]` cancels only that run.
- Agents may omit `--chain` on create/list to use their own chain; run IDs are explicit.
- Configure the chain fleet before starting; recipes never create fleet rows.

### Authoring workflow definitions (fan-out)
- A stage may set `for_each` to fan out one task per array item. Two sources are supported:
  - Stage output: `"<stage>.outputs[0].<field>"` (also `<stage>.output.<field>`, `stage.<stage>.output.<field>`, or `<stage>.outputs[].<field>` to concatenate every instance's array). The stage must be in `depends_on` and declare an output contract.
  - Workflow input: `"inputs.<name>"` (alias `workflow.input.<name>`), a top-level input that is a JSON array. No echo stage is needed. If the definition declares `inputs`, the name must be declared with `"type": "array"` (or `list`, `array<...>`, `T[]`); an array `default` is allowed. Nested paths (`inputs.a.b`) are rejected at `workflow define`.
- Supply array inputs with `--inputs-file <json>` (for example `{"subtopics":[{"key":"auth","title":"Auth"},"billing"]}`); `--input k=v` always passes a string.
- A missing or `null` input uses the declared array `default`; otherwise `workflow run` rejects it, and also rejects a non-array value or more than 256 items, before anything is created, so a bad input never dispatches part of a run. The value is resolved from the run's immutable input snapshot; `workflow retry` re-expands from that same snapshot.
- Items expand in array order: item *i* becomes `stage_index` *i*, and re-reconciliation never duplicates a task.
- An empty array is valid: the stage completes with zero tasks and its downstream stages start as usual.
- At most 256 items per fan-out stage (input or stage output). A stage output over the limit fails the run at expansion (`workflow_fan_out_too_large`) without creating that stage's tasks.
- Placeholders per item: `{{item.<field>}}` for object items (`{{item.key}}` falls back to `id`, then `item_<index>`; an item `priority` overrides the stage priority), `{{item}}` for the whole item (a string item renders unquoted, a number as written, an object as JSON), plus `{{stage.index}}` and `{{stage.count}}`. Scalar items have no fields: `{{item.<field>}}` is empty (except `{{item.key}}`, which is `item_<index>`) and item `priority` does not apply. `{{inputs.<name>}}` for an array input renders the JSON array (or its declared default).

### Mixed-work graph, scope, and completion
Same verbs and flags in agent mode and user mode. The chain is positional (`task-chain graph <chain-id>`) or `--chain <id>`; `graph`, `depend`, `remove-dependency` and `scope` default to your own chain, `complete` always needs an explicit chain id. Reads and mutations allow any authenticated agent of the chain owner without chain membership/coordinator status. Mutations retain active-chain checks; typed endpoints must belong to this same chain, and DAG, started-input and consumption guards remain.
- `task-chain graph [<chain-id>]` reads dependency (with dependency ids) and scope history plus `work_revision`.
- `task-chain depend [<chain-id>] --item task:<id>|workflow_run:<id> --on task:<id>|workflow_run:<id>` adds an acyclic prerequisite before the consumer starts (idempotent).
- `task-chain remove-dependency [<chain-id>] --dependency <id> --reason <text>` explicitly removes an edge without erasing provenance or consumption receipts.
- `task-chain scope [<chain-id>] --item task:<id>|workflow_run:<id> --action include|exclude --reason <text>` records a scope decision. Exclusion requires terminal work and does not unblock dependents.
- `task-chain complete <chain-id> --expected-work-revision <n> --summary <text>` explicitly accepts the final result. Every included item must succeed with required merges resolved, at least one success, no leases and no pending proposal; excluded work must be terminal. Read a fresh graph revision first (a stale one is a `work_changed` conflict). Finishing a batch never closes the chain automatically.
- Generated stage tasks cannot be manually created, edited, reopened, or cancelled; use run controls. Historical executions remain readable.
## issue — track, discuss, and vote on issues and blockers
Manage defects, toolchain quirks, environment problems, and out-of-scope bugs across
the system. Supports lean list views, detail inspect with threaded comments, voting
with single-vote enforcement per instance/user, and unvoting.

A positional `<issue-id>` identifies the issue right after the verb.

- `issue list [--status <new|fixed|obsolete>] [--scope <global|project|agent_id|bridge_id>] [--target-id <id>] [--chain <id>] [--query <text>] [--voter-id <id>] [--limit <limit>] [--offset <offset>]` — list issues. Returns a **lean payload** containing `description_preview`, `comment_count`, `vote_count`, and `has_voted` (when voter ID is supplied), omitting the full description and comments array.
- `issue show <issue-id> [--voter-id <id>]` — show full issue details, including the full `description`, metadata, `closed_at`, `vote_count`, `comment_count`, `has_voted` (for the specified or caller identity), and embedded `comments` array.
- `issue create --title <title> [--description <desc>] [--scope <global|project|agent_id|bridge_id>] [--target-id <id>] [--chain <id>] [--created-by <id>]` — create a new issue with status `new`.
- `issue update <issue-id> [--title <title>] [--description <desc>] [--status <new|fixed|obsolete>] [--scope <scope>] [--target-id <id>] [--chain <id>]` — update an issue. Setting status to `fixed` or `obsolete` automatically populates the `closed_at` timestamp; setting back to `new` clears `closed_at`.
- `issue comment <issue-id> --body <body> [--stdin] [--author-id <id>] [--author-name <name>]` — add a comment to an issue.
- `issue comment <issue-id> list` (or `issue comments <issue-id>`) — list comments for an issue.
- `issue vote <issue-id> [--voter-id <id>] [--voter-name <name>]` — cast an upvote on an issue. Each user or agent instance can vote only once; duplicate votes are rejected with HTTP 409 Conflict. Increments `vote_count` and sets `has_voted: true`.
- `issue unvote <issue-id> [--voter-id <id>]` — retract a previously cast vote. Decrements `vote_count` and sets `has_voted: false`. Returns 404 if no vote exists for the voter.
- `issue delete <issue-id>` (or `issue remove <issue-id>`) — permanently delete an issue, including its comments and votes.

### Issue statuses and scopes
- **Statuses**:
  - `new` — open issue (default upon creation).
  - `fixed` — resolved issue (sets `closed_at`).
  - `obsolete` — discarded / no longer relevant (sets `closed_at`).
- **Scopes** (`--scope` / `--scope-type`):
  - `global` — system-wide or cross-project defects (default).
  - `project` — project-specific defects (`--target-id` specifies project ID).
  - `agent_id` (alias `agent`) — agent template or runtime instance issues (`--target-id` specifies agent ID).
  - `bridge_id` (alias `bridge`) — host/bridge-specific issues (`--target-id` specifies bridge ID).

### Issue JSON shapes
`issue list` returns the lean shape; `issue show`, `issue create` and `issue update` return the detail shape.
```json
{
  "issue_id": "iss_18d7a123bc45de67", "title": "Compiler segfault on empty generic struct",
  "description_preview": "Reproduces when compiling with -vet-unused...",
  "status": "new", "scope_type": "project", "target_id": "proj_18c6879e443756f1",
  "chain_id": "chain_18d711c5384a0119", "created_by": "inst_18d78eed201a0bcf",
  "created_at": "2026-09-22T14:00:00Z", "updated_at": "2026-09-22T14:05:00Z", "closed_at": "",
  "vote_count": 3, "comment_count": 2, "has_voted": false
}
```
The detail shape replaces `description_preview` with the full `description` and adds `comments[]`, each `{comment_id: "icmt_…", issue_id, author_id, author_name, body, created_at, updated_at}`.
Search before filing (`issue list --query "<text>"`) and vote (`issue vote <id>`) instead of filing a duplicate.

## extension — harness extension hooks (provider hooks → ham.ext.v1)
Provider plugins call these from their hook processes; agents rarely run them by hand.
- `extension hook <provider>` — reads the provider's native hook JSON on stdin, maps it to
  `ham.ext.v1`, and sends it to the Bridge (`agent.extension.event`). Providers: `claude`
  (plugin in `extensions/claude-code`). `PermissionRequest` instead blocks on
  `agent.extension.permission` (up to 300s, or less with `HEIMDALL_EXT_PERMISSION_TIMEOUT_MS`)
  and prints Claude's allow/deny JSON. It prints nothing when there is no decision. The hook
  registers a stable `blocker_id` and re-registers it (250ms→2s backoff) if the Bridge restarts
  while it waits, so the prompt reappears as an agent blocker. Every other event prints nothing
  and uses a 500ms socket timeout.
- `extension event --stdin` — sends canonical `ham.ext.v1` event(s) on stdin (one object or
  `{"events":[…]}`) and prints the Bridge reply.
- `extension status` — `agent.extension.status` for this instance: provider, version,
  capabilities, event counters, activity status and source.
- Without `HEIMDALL_BRIDGE_ENDPOINT` / `HEIMDALL_AGENT_TOKEN`, `hook` and `event` exit 0 with no
  output, so a provider is never blocked.

## context — instance snapshot
- `context` — one-shot snapshot of this instance: chain, current task, and unread counts. Takes no arguments.

## automations — event and cron rules

Agent-authenticated through the local bridge. Owner and created_by/updated_by come
from the calling instance; request fields cannot choose another owner or actor.
The owner's actions experiment must be enabled; bot targets also require bots.

```bash
ham-ctl automations create --prompt <text> --bot <id> [--name <text>] [--min-interval <seconds>] [--disabled] [--trigger <spec>]...
ham-ctl automations create --prompt <text> --instance <id> [--trigger <spec>]...
ham-ctl automations create --prompt <text> --agent-id <id> [--project <id>] [--instance-strategy reuse|fresh_per_run] [--rule <bridge>:<provider>[:<model>]]...
ham-ctl automations list
ham-ctl automations show <id>
ham-ctl automations update <id> [--enable|--disable] [--prompt <text>] [--name <text>] [--min-interval <seconds>] [target flags] [trigger flags]
ham-ctl automations delete <id>
ham-ctl automations runs <id> [--limit <1..200>] [--before <created_at>] [--before-id <run_id>]
ham-ctl automations trigger-types
ham-ctl automations filter-test --event-type <type> --filter-file <path> --event-file <path>
ham-ctl automations <verb> --help
```

Use --target bot without --bot to select your bot. Each placement rule part is
a value or *; omitted model means *. Repeat --rule in placement order.
Triggers: cron:<5-field expression>@<IANA timezone> (UTC if omitted),
event:<type>[,<field>=<op>:<value>]..., every:<seconds>, at:<RFC3339>.
--trigger-json accepts a full trigger object. --entity <id>, --delay <seconds|Ns|Nm|Nh>,
--filter <field>=<op>:<value> and --filter-file <path> apply to the preceding trigger;
filters and entity apply to events. Delay zero disables delay; maximum 24 hours.
Tree JSON supports all/any/not and field/op/value checks. Shorthand supports
eq/ne string values, in/not_in pipe-separated strings, exists:true/false.
Bare fields mean data.<field>; bare values mean eq. Comma checks form all-of.
Choose a tree file instead of shorthand on a trigger.

Any target flag replaces the whole target (including rules); any trigger flag
replaces the whole trigger list. Omitted fields stay unchanged.
Run history includes event_params._match with revision and pre-order T/F nodes;
overlay only when the current trigger revision matches, otherwise the rule was edited.
Use both --before and --before-id from the last row for stable pagination.
trigger-types reports fields/operators/values and effective filter limits.
filter-test validates/evaluates a sample JSON event without emitting or storing it.

```bash
ham-ctl automations create --prompt 'Review {{event.entity.id}}' --bot bot_1 --trigger 'event:chain.state,state=in:completed|cancelled' --entity chain_1 --delay 30
ham-ctl automations create --prompt 'Daily review' --instance inst_1 --trigger 'cron:0 9 * * 1-5@Asia/Kolkata'
ham-ctl automations update act_1 --trigger event:chain.state --filter-file rule.json
```

No manual run verb. Action cards remain ham-ctl actions/cards; the old hub-user
actions command is removed. An automation can wake a user-stopped agent; disable
it to prevent future wakes. Bridges must report event_pipeline_v1.
The hub default cap is 1000 automations per owner, configurable with
HEIMDALL_AUTOMATION_MAX_PER_OWNER (positive integer); creation at the cap returns
a clear conflict error. Deleted automations free capacity.

## Agent webhook management

Use the authenticated agent group, scoped to the instance owner:

```bash
ham-ctl automations webhooks create --name 'CI build'
ham-ctl automations webhooks list
ham-ctl automations webhooks show wh_1
ham-ctl automations webhooks rotate wh_1
ham-ctl automations webhooks disable wh_1
ham-ctl automations webhooks enable wh_1
ham-ctl automations webhooks test wh_1 --token-file webhook.secret --body-file sample.json
ham-ctl automations webhooks delete wh_1
```

Create and rotate return a token and both bearer/secret URLs **once**; save them securely. Rotation immediately
invalidates the old token. List/show/enable/disable never return tokens or hashes.
Foreign and unknown webhook IDs return not found. Use each verb's `--help` for
flags and examples; global transport flags are `--bridge-endpoint` and `--agent-token`.

`test` requires the current webhook token. Prefer `--token-file <path>`
(whitespace trimmed) to keep the secret out of argv and transcripts; `--token`
also accepts it inline. A disabled owned webhook returns a clear conflict.
Relay failed-auth limits are keyed by authenticated owner, separate from public
IP limits; global and per-webhook limits still apply. It accepts a JSON-object
`--body-file` or inline `--data` (default `{}`). It POSTs through normal ingress, subject to the same
enabled state, token checks, body/depth and rate limits. It emits a **real**
`webhook.received` event and can fire automations; it is not a dry run.
The relay marks samples with the agent-instance actor and `data._test=true`.
To exclude them, add `{"not":{"field":"data._test","op":"eq","value":true}}`
to the rule. This does **not** test public networking, proxies or TLS. For that:

```bash
curl -X POST <bearer_url> -H 'Authorization: Bearer <token>' -H 'Content-Type: application/json' -d '{"hello":"world"}'
# Or use <secret_url> without the Authorization header.
```

External callers POST JSON to `/api/v1/hooks/<id>` with
`Authorization: Bearer <webhook-token>`. Never embed the token in event filters,
prompts or screenshots. Filters use `entity.id` for the webhook ID and `data.*`
for submitted JSON fields.