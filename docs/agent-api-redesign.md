# Agent API redesign (bridge-local `agent.*` surface + `ham-ctl`)

Status: **PROPOSAL — design first, implement after review**

## Goal

Streamline the agent-facing API so it is intuitive, consistent, and complete.
Every capability is callable by any Bridge-launched agent using only its agent
token. All calls go through the local Bridge endpoint; the Bridge authenticates
the agent token, strips it, and forwards to the Hub with its own bridge token +
the instance token (`X-Heimdall-Instance-Token`) when a Hub round-trip is needed.

No backward compatibility is required. We redesign the wire methods first, then
reshape `ham-ctl` to match.

---

## 1. Current surface (the mess)

### Wire methods today (`bridge_local_method_allowed`, role `.Agent`)

```
agent.rest.request              agent.activity.report
agent.permission.request        agent.permission.reply
agent.chat.send_to_user         agent.chat.send_to_agent
agent.chat.fetch                agent.chat.read
agent.conversation.set_title    agent.chain.set_title
agent.agents.live               agent.context.get
agent.instances.launch          agent.instances.restart      agent.instances.stop
agent.tasks.create              agent.tasks.depend           agent.tasks.comment
agent.tasks.status              agent.tasks.set_current      agent.tasks.vote
agent.tasks.nudge
agent.artifacts.create          agent.artifacts.list         agent.artifacts.show
agent.artifacts.content
agent.memory.propose            agent.start_success
-- admin (bridge_local_is_admin_method) --
agent.agents.list               agent.agents.create
agent.templates.list            agent.templates.create
agent.bridges.list              agent.projects.list
agent.chains.coordinated
```

### Problems

1. **Inconsistent namespacing.** Durable-agent ops, template ops, and instance
   lifecycle are split across three noun spaces (`agents`, `templates`,
   `instances`) plus an "admin" bucket, even though they are all "agents" domain.
2. **Two dispatch buckets** (`agent-actions` envelope vs "admin" raw REST vs
   "instance lifecycle" raw REST) with three near-identical relay procs
   (`bridge_local_relay_agent_method`, `_relay_admin_method`,
   `_relay_instance_lifecycle`). Only routing differs.
3. **`launch` verb** for instance creation reads oddly; user asked for
   `new-instance`. There is no `start` for an existing stopped instance.
4. **`ham-ctl` verb sprawl / aliases.** `agents` (durable) vs `instances`
   (runtime) vs top-level `tasks`/`task-chains` vs `agent tasks` (deprecated);
   dozens of `--x` / `--x-id` alias pairs; `context` vs `tasks list` vs
   `chat read` overlap.
5. **Chat send is split** into `send_to_user` / `send_to_agent` — two methods for
   one concept ("send a message to a recipient").
6. **No first-class bridge/provider discovery.** `bridges.list` exists but
   provider capabilities per bridge are only reachable via `agent.rest.request`.

---

## 2. Proposed wire API (bridge-local `agent.*`)

Consistent `agent.<domain>.<verb>` naming, grouped by the five domains the user
named: **bridge, task-chain, task, agents, chat** — plus the small set of
instance-self / lifecycle calls that don't fit elsewhere (context, activity,
start-success, permission, memory, artifacts).

### 2.1 `bridge` — discovery (read-only)

There are TWO notions of "bridge" and agents should be able to print both:

1. **Hub-registered bridges** — every bridge enrolled to this owner
   (`GET /api/v1/bridges`), each with its provider capability matrix
   (`GET /api/v1/bridges/{id}/providers`). Cross-machine, durable, owner-scoped.
2. **Locally-configured peer bridges** — the peers *this* bridge is configured
   to dial (`[bridge].peers` in config, live status in `bridge_peer_states`:
   name, daemon_id, endpoint, reachability, active_sessions, last_seen,
   last_error). Local, runtime, no Hub round-trip.

| Method | Params | Source | Notes |
|---|---|---|---|
| `agent.bridge.list` | `{ scope?: "hub" \| "configured" \| "all" }` | Hub `GET /api/v1/bridges` and/or local `bridge_peer_states` | default `scope="all"`: merge Hub-registered + locally-configured, each tagged `origin: "hub" \| "configured"`; configured entries carry live reachability |
| `agent.bridge.providers` | `{ bridge_id? }` | Hub `GET /api/v1/bridges/{id}/providers` (or bridge caps) | providers (+ tiers) for one/all Hub bridges |

Replaces `agent.bridges.list`. Two changes:
- **Configured/peer bridges are now printable** via `scope="configured"` (served
  purely from the local bridge's `bridge_peer_states` — no Hub call), and folded
  into the default `scope="all"` output with an `origin` tag so an agent sees
  every bridge it could target, including the local host itself.
- Provider listing is promoted to a first-class verb (today it needs a raw
  `agent.rest.request`).

### 2.2 `agents` — durable identity, templates, and instances (one domain, three sub-nouns)

The user asked for `agents` with sub-commands `template`, `identity`, `instance`.
On the wire we keep them flat but consistently prefixed:

| Method | Params | Replaces |
|---|---|---|
| `agent.agents.list` | `{}` | `agent.agents.list` (durable identities) |
| `agent.agents.create` | `{ name, template_id?, provider?, tier?, slug?, instructions? }` | `agent.agents.create` |
| `agent.agents.template_list` | `{}` | `agent.templates.list` |
| `agent.agents.template_create` | `{ name, description?, persona?, instructions? }` | `agent.templates.create` |
| `agent.agents.instance_list` | `{ agent_id?, live? }` | `agent.agents.live` (+ durable list) |
| `agent.agents.new_instance` | `{ agent_id, bridge_id?, provider?, tier?, project_id?, chain_id?, display_name? }` | `agent.instances.launch` |
| `agent.agents.instance_start` | `{ instance_id }` | *(new)* re-spawn a stopped instance |
| `agent.agents.instance_stop` | `{ instance_id, reason? }` | `agent.instances.stop` |
| `agent.agents.instance_restart` | `{ instance_id }` | `agent.instances.restart` |

Key changes:
- **`launch` → `new_instance`** (creates + starts a fresh instance from an
  agent_id). Matches the user's `agents new-instance <agent-id>`.
- **`instance_start`** added, backed by a REAL new Hub route
  `POST /api/v1/agent-instances/{id}/start` (see §2.7). It starts an existing
  *stopped* instance and returns a clear error when the instance is already
  running rather than silently re-spawning.
- `instance_list` unifies "live instances" and "durable instance list" under one
  verb with a `live` filter, replacing the confusing `agents.live`.

#### `instance_start` behavior + error codes (DECIDED)

`agent.agents.instance_start { instance_id }` -> `POST /api/v1/agent-instances/{id}/start`:

| Situation | HTTP | Response |
|---|---|---|
| instance stopped/failed/unreachable | 200 | `{ ok:true, instance_id, runtime_status:"starting" }` |
| instance already running/starting | 409 | `{ ok:false, error:{ code:"already_running", message:"instance <id> is already running (runtime_status=<s>)" } }` |
| unknown / not same-owner | 404 | `{ ok:false, error:{ code:"not_found", message:"no such instance for this owner" } }` |

The Bridge surfaces the 409 to the agent as a terminal (non-retriable) error so
`ham-ctl agents start <id>` prints a clean "already running" instead of retrying.
`restart` keeps its existing absolute semantics (stop-if-running then start).

### 2.3 `task-chain` — chains

| Method | Params | Replaces |
|---|---|---|
| `agent.task_chain.list` | `{ coordinated_by_me?, project_id? }` | `agent.chains.coordinated` |
| `agent.task_chain.show` | `{ chain_id? }` | *(new; defaults to own chain)* |
| `agent.task_chain.set_title` | `{ title, chain_id? }` | `agent.chain.set_title` |

### 2.4 `task` — tasks (ONE way per action)

Renamed prefix `agent.task.*` (singular). The redesign's rule: **exactly one
method per action, and exactly one flag per concept.** It is fine if an agent
must call several commands (e.g. status then comment) — we do NOT provide sugar
verbs that duplicate another verb.

| Method | Params | Notes |
|---|---|---|
| `agent.task.list` | `{ chain_id? }` | list tasks (defaults to caller's chain) |
| `agent.task.show` | `{ task_id }` | one task incl. its comments + votes (replaces separate `comments`/`votes` reads) |
| `agent.task.create` | `{ title, description?, assignee_ref?, reviewer_refs?, chain_id? }` | |
| `agent.task.depend` | `{ task_id, depends_on_task_id }` | |
| `agent.task.comment` | `{ task_id, body, notify? }` | the ONLY way to comment |
| `agent.task.status` | `{ task_id, status }` | the ONLY way to change status |
| `agent.task.set_current` | `{ task_id }` | |
| `agent.task.vote` | `{ task_id, result, comment? }` | the ONLY way to vote |
| `agent.task.nudge` | `{ task_id, message? }` | |

Removed / collapsed redundancy (was multiple ways to do one thing):
- **`done` sugar dropped.** It was just `status --status in_validation`. Agents
  call `task status <id> --status in_validation` (the one status path). One less
  verb, no hidden status-string magic.
- **`comments add` / `votes add|vote` sub-verbs dropped.** Writing a comment is
  ONLY `task.comment`; casting a vote is ONLY `task.vote`. Reading them is folded
  into `task.show` (no separate `comments`/`votes` list verbs).
- **`update` merged into `status`/`comment`.** The old top-level `update` and
  `status` overlapped; there is now just `status` for status and `comment` for
  text.
- **`list`/`fetch`/`read`/`context` overlap removed.** Task listing is ONLY
  `task.list`; the instance snapshot stays under `agent.context.get` (§2.6) and
  no longer doubles as a task list.
- **`set-current`/`current` alias dropped** → only `set_current`.

Flag rule (one per concept): `--task` (not `--task-id`), `--chain`, `--body`
(comments), `--message` (nudge), `--result` (vote: `lgtm|ngtm`), `--status`,
`--on` (depend), `--assignee`, `--reviewer`, `--notify`. No `--x`/`--x-id` pairs,
no `--body`-as-`--message` cross-aliases.

### 2.5 `chat` — unified send + read (users AND agents)

Collapse `send_to_user` / `send_to_agent` into ONE `send` with a single REQUIRED
`to` field, and unify fetch/read under `read`:

| Method | Params | Replaces |
|---|---|---|
| `agent.chat.send` | `{ to (required), body }` | `chat.send_to_user` + `chat.send_to_agent` |
| `agent.chat.read` | `{ limit?, since?, include_read?, transcript?, mark_read? }` | `chat.fetch` + `chat.read` |

`to` (REQUIRED, DECIDED) is a single value that is EITHER:
- the literal string `"user"` → the bound user conversation (`send-to-user`), OR
- an actual **agent-instance-id** (e.g. `inst_18d2...`) → agent-to-agent
  (`send-to-agent`, `to_instance = to`).

So there is no separate `--to-instance`: `to` is the recipient, discriminated by
whether it equals `"user"` or looks like an instance id. The Bridge routes to
`chat/send-to-user` vs `chat/send-to-agent` accordingly. Missing/empty `to` is a
terminal `bad_request`. `read` always returns messages; `mark_read` defaults
true (today `read` marks, `fetch` doesn't — collapse into one flag).

### 2.6 Instance-self / misc (unchanged concept, kept)

| Method | Params | Notes |
|---|---|---|
| `agent.context.get` | `{}` | compact instance/chain/task/unread snapshot |
| `agent.start_success` | `{}` | mark ready (idempotent; already non-fatal) |
| `agent.activity.report` | `{ status, source? }` | |
| `agent.permission.request` / `.reply` | ... | |
| `agent.memory.propose` | `{ type, title, body?, evidence?, scope... }` | |
| `agent.artifact.list/create/show/content/download` | ... | RENAMED `artifacts`→`artifact` (DECIDED) for consistency with singular `task`/`task-chain` |
| `agent.rest.request` | escape hatch | keep, but discouraged |

### 2.7 New Hub route (DECIDED)

`instance_start` needs a distinct Hub endpoint so "start a stopped instance" is
not conflated with restart and can reject an already-running instance:

```
POST /api/v1/agent-instances/{id}/start
  200 -> { instance_id, runtime_status: "starting" }
  409 -> { error: { code: "already_running", message } }   # instance running/starting
  404 -> { error: { code: "not_found", message } }         # unknown / not same-owner
```

Wired next to the existing `/restart` and `/stop` routes in
`src/hub/app/wiring.odin`. `restart` is unchanged (absolute: stop-if-running,
then start).

---

## 3. Bridge dispatch simplification

Today three relay procs differ only by route resolution. Proposal:

- One `bridge_local_agent_route(method, params) -> (http_method, path, envelope)`
  pure function that returns whether the call uses the **agent-actions envelope**
  (`POST /api/v1/agent-actions/...` with `{method, agent_instance_id, params}`)
  or a **raw REST** route (`/api/v1/...` with the instance token header).
- One relay proc that consumes that, wrapped in `bridge_http_request_retry`
  (already applied). Removes `_relay_admin_method` / `_relay_instance_lifecycle`
  duplication.
- Method allowlist becomes a single sorted set (or prefix check
  `strings.has_prefix(method, "agent.")` + explicit deny-list), not a 400-char
  `||` chain.

Auth/forwarding invariant (unchanged, restated): agent token in → Bridge
authenticates it → strips it → forwards to Hub with `Authorization: Bearer
<bridge_token>` + `X-Heimdall-Instance-Token: <instance_token>`; Hub scopes every
op to the token owner (same-owner only). Agents never see a Hub URL or Hub token.

---

## 4. Proposed `ham-ctl` surface (matches §2)

Drop the `agent` namespace requirement entirely (the managed wrapper already
exports endpoint+token, so top-level works). Canonical verbs:

```
ham-ctl bridge list [--scope hub|configured|all]   # default all; prints Hub-registered + configured peers
ham-ctl bridge providers [--bridge <id>]

ham-ctl agents list
ham-ctl agents identity create --name <n> [--template <id>] [--provider <p>] [--tier <t>] [--instructions <t>]
ham-ctl agents template list
ham-ctl agents template create --name <n> [--persona <t>] [--instructions <t>]
ham-ctl agents instance list [--agent <id>] [--live]
ham-ctl agents new-instance <agent-id> [--project <id>] [--bridge <id>] [--provider <p>] [--tier <t>] [--chain <id>]
ham-ctl agents start   <agent-instance-id>
ham-ctl agents stop    <agent-instance-id> [--reason <t>]
ham-ctl agents restart <agent-instance-id>

ham-ctl task-chain list [--mine] [--project <id>]
ham-ctl task-chain show [<chain-id>]
ham-ctl task-chain set-title <title> [--chain <id>]

ham-ctl task list [--chain <id>]
ham-ctl task show    <task-id>            # task + its comments + votes
ham-ctl task create --title <t> [--description <d>] [--assignee <id>] [--reviewer <ref>] [--chain <id>]
ham-ctl task comment <task-id> --body <t> [--notify a,b]   # ONLY way to comment
ham-ctl task status  <task-id> --status <s>                # ONLY way to change status (incl. in_validation)
ham-ctl task vote    <task-id> --result <lgtm|ngtm> [--comment <t>]   # ONLY way to vote
ham-ctl task nudge   <task-id> [--message <t>]
ham-ctl task set-current <task-id>
ham-ctl task depend  <task-id> --on <task-id>
# removed: `done` (use status --status in_validation), `comments`/`votes`
# (use `show`), `update` (use `status`/`comment`)

ham-ctl chat read [--limit N] [--since T] [--include-read] [--transcript]
ham-ctl chat send --to user               --body <t>   # to the bound user
ham-ctl chat send --to <agent-instance-id> --body <t>   # to another agent

ham-ctl context
ham-ctl start-success
ham-ctl memory propose --type <t> --title <t> [...]
ham-ctl artifact <list|create|show|content|download> ...
```

Conventions:
- **Positional ids** for the object a verb acts on
  (`new-instance <agent-id>`, `start <instance-id>`, `task comment <task-id>`).
- One flag name per concept (no `--x` / `--x-id` alias pairs): `--project`,
  `--bridge`, `--provider`, `--tier`, `--chain`, `--task`.
- Sub-nouns under `agents`: `identity`, `template`, `instance`, plus the
  lifecycle verbs `new-instance` / `start` / `stop` / `restart` at the `agents`
  level (they act on instances but read naturally there).
- `chat send --to` is REQUIRED and is either `user` or an agent-instance-id;
  there is no `--to-instance`.

---

## 4.5 Help output (two levels, skill-style)

`ham-ctl` help is the primary way an agent discovers this API, so it must read
like a skill: purpose-first, example-driven, copy-pasteable.

### Level 1 — top-level `ham-ctl --help` / `ham-ctl help`

A single skill-style overview: one line of purpose, the command groups, and a
worked example per group. NOT an exhaustive flag dump. Format:

```
ham-ctl <version> — Heimdall agent CLI (talks to your local Bridge with your agent token)

USAGE
  ham-ctl <group> <verb> [<positional>] [--flags]
  Everything below is callable by any Bridge-launched agent. IDs are positional;
  each concept has exactly one flag. Run `ham-ctl <group> --help` for details.

GROUPS
  bridge      Discover bridges + their providers (Hub-registered and configured)
  agents      Durable identities, templates, and runtime instances
  task-chain  Your task chains
  task        Tasks within a chain (one command per action)
  chat        Read your inbox / send to the user or another agent
  memory      Propose a memory
  artifact    Create / read / download artifacts
  context     One-shot snapshot of this instance (chain, task, unread)
  start-success  Signal this instance is ready

EXAMPLES
  # See where you can run agents, and what providers each bridge offers
  ham-ctl bridge list
  ham-ctl bridge providers --bridge brg_abc

  # Launch a new instance of a durable agent, then start/stop/restart it
  ham-ctl agents new-instance agt_abc --project proj_x --bridge brg_abc --provider claude --tier smart
  ham-ctl agents start   inst_123
  ham-ctl agents stop    inst_123 --reason "done for now"
  ham-ctl agents restart inst_123

  # Work a task: read it, comment, change status (one way each)
  ham-ctl task show inst_task_1
  ham-ctl task comment inst_task_1 --body "pushed fix, tests green"
  ham-ctl task status  inst_task_1 --status in_validation

  # Talk to the user or another agent
  ham-ctl chat read
  ham-ctl chat send --to user --body "Done — ready for review."
  ham-ctl chat send --to inst_reviewer --body "Can you LGTM inst_task_1?"

  ham-ctl <group> --help    # detailed help for any group
```

Implementation: replace `print_usage` in `src/ctl/help.odin`. The overview text
lives in one place; `ham-ctl help` and bare `ham-ctl --help` both render it.

### Level 2 — per-group `ham-ctl <group> --help`

Each group prints a detailed, self-contained reference: purpose, every verb with
its positional + flags (required vs optional marked), and 1–2 examples per verb.
`--help` after any group/verb short-circuits to this before touching the network.

Example — `ham-ctl task --help`:

```
ham-ctl task — tasks within a task chain

Exactly one command per action; there is no `done`, `comments`, or `votes`.
Positional <task-id> identifies the task. --chain defaults to your current chain.

VERBS
  list                          List tasks in the chain.
      [--chain <id>]
  show <task-id>                Show a task with its comments and votes.
  create --title <t>            Create a task.
      [--description <d>] [--assignee <instance-id>] [--reviewer <instance-id>]
      [--depends-on <id,id>] [--chain <id>]
  comment <task-id> --body <t>  Add a comment (the only way to comment).
      [--notify <id,id>]
  status <task-id> --status <s> Change status; <s> ∈ planning|queued|in_progress|
      in_validation|validated_good|blocked|cancelled. Use in_validation to submit
      for review (there is no separate `done`).
  vote <task-id> --result <lgtm|ngtm>   Cast a review vote (the only way to vote).
      [--comment <t>]
  nudge <task-id> [--message <t>]       Nudge the task's owner.
  set-current <task-id>                 Mark this task as your current task.
  depend <task-id> --on <task-id>       Add a dependency.

EXAMPLES
  ham-ctl task show inst_task_1
  ham-ctl task comment inst_task_1 --body "pushed fix" --notify inst_rev
  ham-ctl task status inst_task_1 --status in_validation
  ham-ctl task vote inst_task_1 --result lgtm --comment "clean"
```

Every group (`bridge`, `agents`, `task-chain`, `task`, `chat`, `memory`,
`artifact`) ships an equivalent block. Sub-nouns get their own help too:
`ham-ctl agents template --help`, `ham-ctl agents instance --help`.

Rules for the help procs:
- Deterministic, no network, no token required (help must work anywhere).
- Same text drives usage-on-error: a missing required flag prints the group's
  `--help` body, not a one-line `usage:` string.
- Kept in per-group `print_<group>_help` procs so they stay next to the dispatch.

---

## 5. Decisions (RESOLVED)

1. **Real `/start` route (DECIDED).** Add a distinct Hub
   `POST /api/v1/agent-instances/{id}/start` that starts a stopped instance and
   returns `409 already_running` when it is already running/starting (§2.7).
   `restart` keeps absolute stop-then-start semantics.
2. **`agents` sub-nouns (DECIDED).** `agents template | identity | instance`.
3. **Artifacts (DECIDED).** Rename `artifacts` → `artifact` (singular),
   wire `agent.artifact.*`, ctl `ham-ctl artifact ...`.
4. **Chat `--to` (DECIDED).** REQUIRED; value is `user` OR an actual
   agent-instance-id. No default, no separate `--to-instance`.
5. **Wire names (DECIDED).** Flat with `_`, e.g. `agent.agents.new_instance`,
   `agent.agents.instance_start`.
6. **Local bridge identity in `configured` list (proposal, confirm during impl).**
   Synthesize an `origin: "self"` row for the running bridge (from
   `bridge_config`: daemon_id, local_endpoint_port) in `scope=configured|all` so
   an agent sees the machine it is on.

---

## 6. Rollout plan (after design sign-off)

1. Hub: add `POST /api/v1/agent-instances/{id}/start` (§2.7) with the 409
   already_running / 404 not_found semantics.
2. Bridge: land new flat `agent.*` wire methods + the unified
   `bridge_local_agent_route` router + single retry-wrapped relay; add
   `agent.bridge.list` scope handling (Hub + configured peers + self). Delete old
   method names (no external back-compat promised).
3. ctl: rewrite `src/ctl/agent_mode.odin` dispatch to the new
   verbs/positionals/single-flags (drop `done`/`comments`/`votes`/`update` and
   all `--x`/`--x-id` alias pairs).
4. ctl help (§4.5): replace `print_usage` with the skill-style Level-1 overview;
   add a `print_<group>_help` per group (bridge, agents[+template/instance],
   task-chain, task, chat, memory, artifact) for detailed Level-2 `--help`, and
   route missing-required-flag errors through those bodies.
5. Docs/skills: update `AGENTS.md` command families and the skills that
   reference `ham-ctl agent ...` to the new surface.
6. Tests: bridge method-routing table test (method → envelope/route); ctl
   arg→params builder tests (pure); help snapshot tests (Level-1 + each group's
   `--help` render deterministically with no network); and an e2e that drives
   new-instance / start / stop / restart and chat send-to-user/agent through a
   fake hub.
