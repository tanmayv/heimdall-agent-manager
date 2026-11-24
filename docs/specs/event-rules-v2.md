# Event rules v2: envelope, filter operators, new sources, per-target delivery

Status: **spec, for review** (chain `chain_18eae5babca58015`, task `task_18eafa2675276d31`).
No code in this task. Written against `a7d501da`; every `file:line` reference is to that tree.

**Summary.** Event rules v2 extends the existing actions system; it does not replace it. An
event stays `type + envelope`, but the envelope gets one universal shape (`entity`, not
`chain_id`/`task_id`). A rule is an existing action trigger whose filter grows from an
equals-only map to a boolean condition tree: nested `all`/`any`/`not` groups whose leaves
are checks with `eq`, `ne`, `in`, `not_in`, `exists` and `prefix`. The tree is evaluated
against one event, statelessly, and every run records which nodes were true. Targets are unchanged (agent, instance, bot). Two producers are added: memory
state changes and authenticated inbound webhooks. Because the expected profile is hundreds of
rules pointing at a handful of agents, matching moves to an in-memory compiled index and
delivery moves from one prompt per action to one prompt per target, gated by "the target has
read the previous one". Schema cost: two small new tables, one table rebuild, two indexes,
no new columns on existing tables.

Terms used here:

| Term | Meaning |
|---|---|
| Event rule (rule) | One row of `action_triggers` plus its action's target. Not to be confused with `Action_Target_Rule` (`src/hub/domain/action.odin:34`), which is a placement fallback and keeps its name. |
| Target | What an action delivers to: `agent`, `instance` or `bot` (`src/hub/domain/action.odin:3-5`). |
| Run | One row of `action_runs`: one matched occurrence of one rule (`src/hub/repository/sqlite/migrations/actions_001_reset.sql:65-87`). |
| Batch | New. All runs sent to one target in one prompt and one pipeline delivery. It has no table; it is the set of runs sharing a `delivery_id`. |

## 1. Requirements and positions

| ID | Requirement | Where |
|---|---|---|
| R1 | Event = type + envelope; rules filter envelope params with `eq`, `ne`, `in`, `not_in` (+ justified extras) | §2, §3.5 |
| R2 | A matching rule resolves to a target: new instance of `agt_`, existing `inst_`, or bot | §4 |
| R3 | Sources: chain/task catalog (exists), cron (exists), memory (new), inbound webhooks (new) | §5 |
| R4 | Many actions targeting few agents: cheap matcher, coalesced wakes, per-target backpressure | §3.7, §6, §7 |
| R5 | Matching is a boolean condition tree (nested AND/OR, NOT), leaves = R1 checks, evaluated per single event; UI tree editor and per-run matched-node display. One event = one fact: no event arrays, no `cause_id`/correlation | §3, §10 |

| ID | Coordinator input | Position |
|---|---|---|
| D1 | Envelope v2 with `entity:{kind,id}`; `chain_id`/`task_id` leave the top level | **Adopt**, with two clarifications: `topic_key`/`topic_generation` stay as optional top-level fields, and hub-internal timer events are out of scope (§2.2). |
| D2 | Generic "still the latest state event for its entity" validity for delayed runs | **Adopt.** One head row per (owner, entity, type); per-type callback only for occurrence events (§2.4). |
| D3 | Readers accept the new shape first, fall back to old for one release; template aliases kept | **Not adopted, by user decision U2:** no backward compatibility. Envelope v2 replaces the old shape in one step; no dual write, no reader fallback, no aliases (§8). |

User decisions applied in this revision:

| ID | Decision | Where |
|---|---|---|
| U1 | `ne`/`not_in` are true on a missing field; `exists` gives the strict form | §3.5 |
| U2 | No backward compatibility: the feature is not live | §8 |
| U3 | Webhook auth is a generated secret token, shown once, stored hashed; HMAC later. Per-webhook rate limit. Ingress only authenticates, size-checks, rate-limits and enqueues | §5.4 |
| U4 | Limits are configurable defaults | §9.1 |
| U5 | No per-run tree copy; older runs show seen values plus "rule edited since" | §3.6 |
| U6 | Two webhook URL forms sharing one hashed token: bearer header, and a secret URL for URL-only senders, with the token redacted from hub logs, traces and errors | §5.4 |

## 2. Envelope v2 (R1, D1, D2)

### 2.1 Today

`catalog_emit` builds the catalog envelope with top-level `chain_id` and `task_id`
(`src/hub/service/taskv2/catalog.odin:42-54`) and derives the entity only for versioning
(`catalog.odin:37-39`). Readers of the top-level ids:

| Reader | Reference |
|---|---|
| Matcher run snapshot | `src/hub/service/actions/matcher.odin:50-53` |
| Settle key and validity | `src/hub/service/actions/event_kind.odin:68-71`, `:87` |
| Prompt metadata and templates | `src/hub/service/actions/router.odin:202`, `src/hub/service/actions/template.odin:43-45` |
| Event inbox replay and notices | `src/hub/service/eventinbox/catalog.odin:90`, `src/hub/service/eventinbox/notifications.odin:169` |
| Web UI catalog replay | `src/ui/api/useUserWebSocket.ts:260-264` |
| Agents | `ham-ctl events next` hands the envelope to agents as-is |

### 2.2 Shape

```json
{
  "event_id": "evt_...",
  "type": "task.state",
  "class": "state",
  "owner_user_id": "tanmay",
  "entity": {"kind": "task", "id": "task_18ea..."},
  "entity_version": 12,
  "actor": "hub",
  "occurred_at": "2026-11-24T12:00:00Z",
  "data": {"state": "in_review", "chain_id": "chain_18ea..."}
}
```

Rules:

- **Universal fields only at the top level.** Parent links go into `data`: task events carry
  `data.chain_id`. Chain events carry nothing extra; the chain is the entity.
- **`entity` present means v2.** No version field is added; one discriminator is enough.
- **`class`** keeps its three values: `state`, `occurrence`, `resolvable`
  (`catalog.odin:65`, `:150-188`).
- **`topic_key` and `topic_generation` stay** as optional top-level fields on `resolvable`
  events. They are not universal, but the event inbox keys its stale/resolved logic on them
  (`src/hub/service/eventinbox/service.odin:531-548`, `notifications.odin:190-191`) and moving
  them buys nothing for rules.
- **NATS subjects do not change.** Chain and task tokens stay in the subject
  (`catalog.odin:56-59`), so existing consumer filters and stored `subject_filter` values keep
  working.
- **Out of scope:** hub-internal timer events built by `schedule_row`
  (`src/hub/service/actions/schedule_sync.odin:24-40`: `schedule.fired`, `action.resume`,
  `action.ready`, `delivery.unread`). They carry `action_id`/`trigger_id`, have no entity, and
  their definitions live in JetStream for as long as the trigger does. Rules treat a missing
  `entity` as kind `""` and id `""`. Rewriting stored schedule definitions is not worth it.

Entity kinds after v2: `chain`, `task`, `memory`, `webhook`.

| Type | Class | Entity | `data` | Subject |
|---|---|---|---|---|
| `chain.state` | state | chain | `state`, `completed_at`, `updated_at` | `ev.<owner>.chain.<chain>.state` |
| `chain.work_finished` | occurrence | chain | `outcome`, `work_revision` | `ev.<owner>.chain.<chain>.work_finished` |
| `task.*` (existing six) | as today | task | existing keys + `chain_id` | `ev.<owner>.chain.<chain>.task.<task>.<suffix>` |
| `memory.state` (new) | state | memory | §5.3 | `ev.<owner>.memory.<memory>.state` |
| `webhook.received` (new) | occurrence | webhook | the request body | `ev.<owner>.webhook.<webhook>.received` |

### 2.3 One producer helper

`catalog_emit` lives in `taskv2` and takes a `Taskchain_Repository`
(`catalog.odin:13-25`). Memory and webhook producers must not import `taskv2`. Extract the
envelope building, version bump and outbox append into one producer-neutral proc (suggested
home: `src/hub/service/events`, input `{owner, type, class, entity_kind, entity_id, subject,
data, actor, topic_suffix, replace_open, event_id}`) working on the
`Event_Outbox_Repository` of the caller's unit of work. `catalog_emit` becomes a thin wrapper
that fills in the chain/task subject. The outbox already requires the caller's unit of work for
every statement (`src/hub/repository/sqlite/event_outbox_repo.odin:24-36`), so "event is
written in the producer's transaction" stays enforced by construction.

`event_entity_versions` restricts `entity_kind` to `task` and `chain` by CHECK
(`src/hub/repository/sqlite/migrations/events_002_topics.sql:2`). The migration in §9 rebuilds
it without that CHECK.

### 2.4 Generic validity for delayed runs (D2)

Today a delayed run is validated by a per-type callback that compares a payload snapshot with
the live chain row: state plus `completed_at`/`updated_at`
(`event_kind.odin:109-121`). That is the comparison that broke in `iss_18eaf94533c84f3e`; it
depends on every producer emitting exactly the persisted timestamps.

New rule, same for every type:

- A **state** event is valid iff it is still the newest event of its type for its entity.
- An **occurrence** event is always valid, unless its descriptor supplies `still_valid`.
  `chain.work_finished` keeps its `work_revision` check (`event_kind.odin:93-107`).
- A **resolvable** event is valid iff its topic generation is still open (the existing
  `event_topics` row; no new storage).

Storage: one row per (owner, entity, type), upserted by the producer helper in the same
transaction whenever `class == "state"`.

```sql
CREATE TABLE event_state_heads (
  owner_user_id TEXT NOT NULL, entity_kind TEXT NOT NULL, entity_id TEXT NOT NULL,
  event_type TEXT NOT NULL, event_id TEXT NOT NULL, entity_version INTEGER NOT NULL,
  PRIMARY KEY(owner_user_id, entity_kind, entity_id, event_type)
);
```

Validity is `head.event_id == run.event_id`: one primary-key read, only for runs with
`delay_s > 0`, at the same point as today (before planning, `router.odin:434-447`).

Why this is right for the cases that matter:

| Case | Result |
|---|---|
| Chain completed, then reopened inside the delay | Head moves to the `active` event; the delayed `completed` run is skipped as `superseded`. |
| Chain row touched without a state change | No event is emitted (`catalog.odin:100`), the head does not move, the run stays valid. This is the case the timestamp snapshot got wrong. |
| completed → active → completed inside the delay | The pending run was already replaced by the newest occurrence for the same settle key (`matcher.odin:184-193`); it matches the head. |

**Settle key** becomes generic too: `"<entity.kind>:<entity.id>"`, or `""` when there is no
entity. This equals today's behaviour for chain events (`event_kind.odin:68-71`) and gives
memory and webhook rules a per-entity debounce without a callback. The descriptor fields
`settle_key` and `still_valid` (`event_kind.odin:52-53`) remain only as optional overrides.
The chain-state snapshot check (`event_kind.odin:72-74`, `:108-122`) is deleted. A delayed
state run with no head row is skipped as `superseded`: the hub does not act on state it
cannot verify.

Rows are deleted with their entity where a delete path exists; otherwise they are bounded by
entities × state types (two state types today plus `memory.state`).

## 3. Condition tree (R1, R5)

### 3.1 Today

A trigger stores `event_type`, `subject_filter`, `match_key` and `data_filter`
(`action.odin:38-52`). `data_filter` is an object compared key by key for equality on
top-level `data` scalars (`matcher.odin:31-46`), and only string values on keys the
descriptor lists are accepted (`event_kind.odin:26-36`).

### 3.2 Model

A rule's condition is a boolean tree evaluated against **one event**. The evaluation is
stateless: it reads only that event's envelope, never other events, earlier results or the
database. When the root is true, the rule matches and the action triggers (subject to the
existing guards, delay and delivery rules). One event is one fact.

Four node types:

| Node | JSON | True when |
|---|---|---|
| All (AND) | `{"all": [node, …]}` | every child is true |
| Any (OR) | `{"any": [node, …]}` | at least one child is true |
| Not | `{"not": node}` | the child is false |
| Check (leaf) | `{"field": "…", "op": "…", "value": …}` | the R1 check holds (§3.5) |

`not` is included because it is free: one boolean flip, no new semantics. It also lets the
UI offer a "none of" group.

### 3.3 JSON shape

```json
{
  "kind": "event",
  "config": {
    "event_type": "webhook.received",
    "entity_id": "wh_18eb...",
    "filter": {
      "all": [
        {"field": "data.action", "op": "in", "value": ["opened", "reopened"]},
        {"any": [
          {"field": "data.repo.name", "op": "prefix", "value": "heimdall-"},
          {"field": "data.labels.urgent", "op": "exists", "value": true}
        ]},
        {"not": {"field": "data.draft", "op": "eq", "value": true}}
      ]
    }
  }
}
```

- `filter` is one node. Omitted or `{}` means "always true".
- `entity_id` (optional) pins the rule to one entity. It is compiled into the subject filter,
  so it costs nothing at match time. A check `entity.id eq X` that is a direct child of a
  root `all` is folded the same way. The old `chain_id` config key is removed
  (`event_kind.odin:16`, `:22-23`); `entity_id` replaces it.
- The old `"data": {"state": "completed"}` equals map is removed from the API. The tree is
  the only filter form.
- **Storage reuses the existing column.** `action_triggers.data_filter` is only constrained
  to valid JSON (`actions_001_reset.sql:56`), so it holds the tree without DDL. The stored
  root is always a group: a single check is wrapped in `all`. Existing rows are converted
  once by the migration in §9; the matcher has no reader for the old map.

### 3.4 Limits and validation

| Limit | Value |
|---|---|
| Depth (root = 1) | 4 |
| Checks (leaves) per tree | 16 |
| Nodes per tree | 24 |
| Children per group | 1 to 16 (an empty group is rejected) |
| Values per `in`/`not_in` list | 32 |
| Bytes per value / per field path | 256 / 128 |
| Stored tree, serialized | 4 KiB |

Depth 4 covers "A and (B or (C and D))" with room to spare and keeps the editor readable on
a phone. These are defaults; an operator can change them in hub config (§9.1). The
effective limits are returned by the trigger-types endpoint so UI and CLI do not hardcode
them.

Validation happens on save, in the trigger kind's `compile` step
(`triggers.odin:26-27`), and reports through the existing `detail_error` mechanism
(`triggers.odin:49-55`) with code `invalid_filter` plus two detail fields: `path`, a JSON
pointer to the offending node (for example `/all/1/any/0`), and `reason`:

| `reason` | Meaning |
|---|---|
| `unknown_node` | Object is not exactly one of the four node shapes (extra or missing keys). |
| `empty_group` | `all` or `any` with no children. |
| `too_deep` / `too_many_nodes` / `too_large` | A limit above was exceeded. |
| `unknown_field` | Path syntax invalid, or not a known field for this event type. |
| `unknown_op` | Operator not in §3.5. |
| `bad_value` | Wrong value type or size for the operator. |

The UI uses `path` to mark the node in the editor.

### 3.5 Checks: fields and operators

Fields:

| Path | Notes |
|---|---|
| `entity.id` | See folding in §3.3. |
| `entity.kind` | Allowed for completeness; constant per event type today. |
| `actor` | `user`, `hub`, `agt_…` (`catalog.odin:71-76`), `webhook:<id>`. |
| `data.<seg>[.<seg>…]` | Up to 4 segments after `data`, each `[A-Za-z0-9_-]{1,64}`. Object keys only; no array indexing. |

`type`, `owner_user_id`, `class` and `occurred_at` are not checkable: type and owner are the
index key, the other two have no use case yet.

For catalog and memory types the descriptor lists the known `data` keys and values, and
validation keeps rejecting unknown keys (as `event_kind.odin:30-35` does today). For
`webhook.received` any syntactically valid `data.` path is accepted, because the body is
user-defined.

Operators:

| Op | `value` | True when |
|---|---|---|
| `eq` | scalar | field is present and equal |
| `ne` | scalar | **not** `eq` |
| `in` | array of 1–32 scalars | field is present and equal to one of them |
| `not_in` | array of 1–32 scalars | **not** `in` |
| `exists` | `true` / `false` | field presence equals `value` |
| `prefix` | non-empty string | field is present, is a string, and starts with `value` |

Semantics, stated once:

- **Scalars compare as text**, exactly like the current matcher: strings by content, numbers
  and booleans by their JSON text (`matcher.odin:20-30`). So `3` equals `"3"`. Integers and
  booleans compare reliably; floats compare by serialized text and should not be used.
  Check values are normalized to text when the rule is compiled.
- **Present** means the path resolves to a string, number or boolean. `null`, objects, arrays
  and absent keys are **not present** for `eq`/`in`/`prefix`. For `exists`, objects and
  arrays count as present; `null` and absent do not.
- **Missing fields:** positive operators (`eq`, `in`, `prefix`) are false. `ne` and `not_in`
  are the exact negations of `eq` and `in`, so they are **true** on a missing field, and
  they mean the same as wrapping the positive check in `not` (user decision U1). Put
  `exists: true` next to them when the field must be there. Two-valued logic throughout: every node is true or
  false, never "unknown".
- **Comparison is byte-wise and case-sensitive.** No trimming, no Unicode folding.

Why the two extra operators, and why nothing else:

| Operator | Decision | Reason |
|---|---|---|
| `exists` | **In** | Without it the missing-field rule cannot be made strict, and webhook bodies are distinguished mostly by which keys they carry. One map lookup. |
| `prefix` | **In** | Covers refs, branch names, id families and path-like values, which `in` cannot enumerate. One bounded `has_prefix`. |
| `gt`/`lt`/`gte`/`lte` | Out | Needs typed numeric comparison, which contradicts "scalars compare as text". First candidate if a real case appears. |
| `suffix`, `contains` | Out | No current case; `contains` invites scanning large webhook strings. |
| regex / glob | Out | Unbounded cost and a ReDoS surface on an unauthenticated-input path. |
| Checks across events (sequences, counts, "A then B", correlation ids) | Out | R5 is explicit: one event, stateless. See §12. |

### 3.6 Match trace per run

Run history must show which nodes matched (R5). When a rule matches, the matcher evaluates
the tree a second time **without** short-circuiting and stores the outcome in the run
snapshot next to the existing `_trigger_rev` convention (`matcher.odin:166`):

```json
"_match": {"rev": 7, "nodes": "TTTFTTF"}
```

`nodes` has one character per node in pre-order (`T` or `F`), at most 24 characters. The
values each check saw are already in the snapshot, because the paths a rule's checks
reference are part of the run projection (§5.4).

- The trace is written only for matched rules, so its cost is bounded by matches, not by
  candidates.
- The tree itself is **not** copied into the run (user decision U5; up to 4 KiB × every run
  would defeat R4). The UI overlays the trace on the trigger's current tree when
  `_match.rev` equals the trigger's `rev`; otherwise it shows "rule edited since this run"
  and only the recorded values.
- Runs exist only for events that matched, so the root is always `T` in history. To answer
  "why did it not fire?", a stateless dry-run endpoint evaluates a tree against a pasted
  sample event and returns the same trace (§10).

### 3.7 Evaluation cost (R4)

Today each event costs one SQL query for candidate triggers (`matcher.odin:91`,
`ACTIONS_SQL_TRIGGERS_MATCH` at `src/hub/repository/sqlite/action_repo_sqlite.odin:316`), a
JSON parse of every candidate's filter (`matcher.odin:33-35`), and for every matched trigger
two open-run reads plus an insert (`matcher.odin:118-129`, `router.odin:100-107`).

v2 matcher:

1. **Compiled rule index, in memory, owned by the matcher thread.** The matcher is a single
   thread (`src/hub/service/actions/runtime.odin:68-151`), so reads need no lock.

   ```
   owner -> event_type -> { exact: subject -> [rule], wild: [rule] }
   ```

   `exact` holds rules whose subject filter has no `*` (this is today's `match_key`,
   `triggers.odin:70-73`); `wild` holds the rest with pre-split subject tokens. A rule is
   `{trigger_id, action_id, rev, updated_at_ms, kind, delay_s, tree, projection}`.
2. **Compile once.** The tree is parsed and validated when the rule is loaded into the
   index, never per event. The compiled form is a flat array of nodes in pre-order (kind,
   child range, and for checks: pre-split path, operator, normalized values). Within each
   group, checks are ordered before sub-groups and cheap operators first; the original
   position of each node is kept so the trace in §3.6 is reported in the author's order.
3. **Load:** one query per owner on first use (all effective triggers of that owner, the
   per-owner form of `ACTIONS_SQL_TRIGGERS_EFFECTIVE`, `action_repo_sqlite.odin:324`).
4. **Invalidate:** one atomic epoch counter on the actions service, bumped after commit by
   every action or trigger write (`service.odin:218-227`, `:360`) and by the matcher's own
   retire path (`matcher.odin:136-145`). The matcher compares the epoch once per fetched
   batch and drops the whole cache when it changed. Safety net: drop it once a minute in the
   existing sweep tick (`runtime.odin:84-87`). SQL stays the source of truth. A global epoch
   means one owner's edit makes every owner reload lazily (one query each on their next
   event); that is acceptable until edit rates say otherwise.
5. **Per event:** two hash lookups, then for each candidate: subject match (exact bucket:
   none), the existing `updated_at` guard (`matcher.odin:99-100`), then the tree with
   short-circuit: `all` stops at the first false child, `any` at the first true one. A check
   is at most five map lookups in the already-parsed envelope (`runtime.odin:158-177`) and one
   string comparison. Worst case per rule is 16 checks; no allocation, no recursion deeper
   than 4. The trigger-kind `guard` and `event_key` hooks (`triggers.odin:33-37`) run
   unchanged.
6. **Per matched rule:** the full-evaluation trace (§3.6), then one insert statement, no
   separate read. The join-or-queue decision that needs the action's open run today
   (`matcher.odin:119-122`) moves into that statement (insert `joined` when the action
   already has an open run, else `queued`; the unique index `action_runs_one_open`,
   `actions_005_settle.sql:7`, is the arbiter). History pruning leaves the hot path
   (`matcher.odin:132-134`) and stays in the minute sweep
   (`src/hub/service/actions/retention.odin:8-20`).
7. The lazy unread fallback (`expire_open_run` at match time, `matcher.odin:118`) moves to
   the per-target drain (§6).

Expected numbers for the profile "300 rules, 5 targets" (estimates, to be confirmed by the
test in F2): worst case 300 wildcard rules of one type × 16 checks is 4,800 short string
comparisons per event, still tens of microseconds, and short-circuiting makes the typical
case far smaller; the per-owner cache is on the order of a kilobyte per rule at the size
limit. Schedule rules always land in an exact bucket because their subject contains the
trigger id (`src/hub/service/actions/schedule_kind.odin:75`).

## 4. Targets (R2)

No new target kinds and no change to target storage. Each rule resolves through its action:

| Requirement | Existing mechanism |
|---|---|
| New instance of a durable agent (`agt_`) | `target_kind = agent` with `instance_strategy = fresh_per_run` (`action.odin:12-13`); placement rules pick the bridge (`router.odin:143-189`). |
| Existing instance (`inst_`) | `target_kind = instance` (`router.odin:130`, `:517-535`). |
| Bot | `target_kind = bot`, resolved to the bot's `agent_instance_id` and then the instance route (`router.odin:131-142`). |

The target stays on the action, not on the trigger. "Many rules, few agents" is many actions
sharing a target. Giving each trigger its own target would duplicate the target, placement
and prompt model for no requirement.

## 5. Sources (R3)

### 5.1 Chain and task catalog (exists)

Only `chain.state` and `chain.work_finished` are offered as rule types today
(`event_kind.odin:56-62`), although the catalog also emits six task types
(`catalog.odin:142-216`, `:220-234`, `:285`). With the generic settle key and validity, a
type needs only a descriptor row. v2 adds descriptors for `task.state`,
`task.blocked_on_human` and `task.review_requested_from_user`. The other three task types
are left for when someone asks. `event_compile` hardcodes the chain subject
(`event_kind.odin:44`); it takes the subject template from the descriptor instead.

### 5.2 Cron (exists)

Unchanged: `schedule.fired` through NATS schedules (`schedule_kind.odin:13`, `:75-111`). It
benefits from the index (exact bucket) and from per-target delivery.

### 5.3 Memory (new producer)

Every memory write goes through `save_memory`
(`src/hub/service/content/attention_notify.odin:48-54`), called by create, update, approve,
reject and archive (`src/hub/service/content/content_service.odin:106-127`, `:196-222`).
That single path is where the event is produced.

- **One type: `memory.state`**, class `state`, entity `{kind: "memory", id: "mem_…"}`.
  "Created" and "approved" are states of one entity, which is exactly what D2 validity wants;
  two occurrence types would need their own validity story.
- **`data`:** `status` (`pending` | `active` | `rejected` | `archived`), `previous_status`
  (`""` on create), `memory_type`, `proposed_by_instance_id`, `proposed_in_chain_id`.
  Identifiers and enums only: no title, no body, no evidence. Scope id lists are arrays and
  therefore not filterable; they are left out.
- **Emit only when `status` changed** (or on create). Edits that keep the status emit nothing.
- **Presets** (like `event_kind.odin:59`): "Memory proposed" = `status eq pending`;
  "Memory approved" = `status eq active` and `previous_status eq pending`.
- **Actor:** `user`, or the proposing agent id when known, else `hub`.
- **System memories** (owner `system`, `content_service.odin:196`) emit nothing.
- **Transaction:** `save_memory` writes through the content repository without a unit of
  work today. The memory row and the outbox row must commit together, so the write moves
  into a unit of work (the service already has the factory, `content_service.odin:51`,
  used at `:262`). The attention notification stays after commit.

### 5.4 Inbound webhooks (new producer)

**Model.** A webhook is an owner-scoped endpoint that turns an authenticated JSON POST into
one `webhook.received` event.

```sql
CREATE TABLE event_webhooks (
  webhook_id TEXT PRIMARY KEY CHECK(webhook_id != ''),      -- wh_…
  owner_user_id TEXT NOT NULL CHECK(owner_user_id != ''),
  name TEXT NOT NULL DEFAULT '',
  token_hash TEXT NOT NULL CHECK(token_hash != ''),          -- hash of the secret token
  enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL, last_received_at TEXT NOT NULL DEFAULT ''
);
CREATE INDEX event_webhooks_owner ON event_webhooks(owner_user_id);
```

Limit: 50 webhooks per owner (default).

**Endpoints.** Two URL forms reach the same handler and the same webhook (user decision
U6). Both are registered outside session auth like the existing provider webhooks
(`src/hub/app/wiring.odin:802`, `:946-947`). The owner comes from the webhook row, never
from the request.

| Form | Request | For |
|---|---|---|
| A, bearer header | `POST /api/v1/hooks/<webhook_id>` with `Authorization: Bearer <token>` | Senders that can set a header: scripts, CI, Alertmanager, Grafana, n8n. Preferred. |
| B, secret URL | `POST /api/v1/hooks/<webhook_id>/<token>` | Senders that can only be given a URL (the Slack/Discord incoming-webhook style). |

**Authentication: one generated secret token** (user decisions U3, U6).

- The hub generates the token (32 random bytes, URL-safe, prefixed `whsec_`), shows it
  **once** on create and on rotate, and stores only its hash, the way bridge tokens are
  stored (`token_hash`, `src/hub/domain/bridge_token.odin:26-36`). The hub never holds the
  token in recoverable form, so this design depends on no secret-at-rest mechanism.
- **Both forms use the same token and the same check:** hash the presented token, compare
  with the stored hash in constant time. There is one `token_hash` per webhook, so
  **rotation invalidates both forms at once**.
- A request that carries a token in both places is rejected with the uniform `401`. Tokens
  are never accepted in the query string.
- Every failure (unknown id, disabled webhook, wrong or missing token, actions experiment
  off) returns the same `401` body in both forms, so neither is an oracle for webhook ids
  or tokens. Error bodies never echo the request path.

**Keeping the URL token out of the hub's records (form B).** A token in a path is a secret
in a place software likes to write down. Requirements:

- The handler takes the token segment out of the request before anything else sees it. From
  that point the path is `/api/v1/hooks/<webhook_id>/[redacted]` for every consumer: access
  and request logs, error logs, error responses, traces and spans, metrics labels, panic
  output and the rate limiter's keys.
- Redaction happens in the router or request wrapper, in one place, not at each log call.
  W1 must list every site in the hub that records a request path and show each receives the
  redacted form; I did not enumerate those sites in this task.
- The token is never stored, returned by any API after creation, or included in events,
  run snapshots or prompts.
- What the hub cannot control: a reverse proxy or load balancer in front of it, and the
  sender's own logs, see the full URL. `SELF_HOSTING.md` gets a note to exclude or mask
  `/api/v1/hooks/` paths in proxy access logs. This residual exposure is why form A stays
  the recommended one, and why the UI and CLI label form B as "anyone with this URL can
  post events".

HMAC request signing is not part of v1 (§12). It needs the hub to keep a recoverable secret,
and it can be added later as a second auth mode without changing the envelope or the rules.

**Ingress does four things and nothing else** (user decision U3):

1. redact the token segment (form B), then rate-limit and size-check, before parsing and
   before any SQL;
2. authenticate (one indexed read of the webhook row);
3. append one event to the outbox in one short transaction (version bump + outbox row, §2.3);
4. answer `202`.

No rule lookup, no matching, no target resolution and no delivery happens in the request.
The event reaches the matcher the same way every other event does: outbox, relay, JetStream,
matcher thread. A slow or blocked target cannot slow the endpoint, and a burst of webhooks
costs the request path only outbox inserts.

**Size and shape limits.**

| Limit | Value | On violation |
|---|---|---|
| Body size | 64 KiB, checked before parsing | `413` |
| Content type | `application/json` | `415` |
| Body | a JSON object, nesting depth ≤ 16 | `400` |
| Rate, per webhook | 60 requests per minute (required, U3) | `429` with `Retry-After` |
| Failed auth, per client IP | 20 per minute, then `429` before any lookup | `429` |

The limiter is the fixed-window, in-memory pattern the bot webhook already uses
(`src/hub/transport/http/bot_webhook_handlers.odin:25-76`), keyed by webhook id instead of
globally. All values in this table are configurable defaults (§9.1). Client IP resolution reuses the trusted-CIDR logic at
`bot_webhook_handlers.odin:88`. Counters reset on hub restart; that is acceptable for a
protective limit.

**Replay and duplicate protection.**

- A sender that may retry sends an `Idempotency-Key` header (≤ 128 bytes). The event id is
  then **deterministic**: `evt_wh_` + the first 32 hex digits of
  `SHA-256(webhook_id | key)`. Without the header the event id is random and every request
  is a new event.
- `event_outbox.event_id` is UNIQUE (`migrations/events_001_outbox.sql:4`) and published
  rows are kept 24 hours (`src/hub/service/eventrelay/relay.odin:166-171`). A repeat inside
  24 hours hits that constraint and is answered `202` with the original event id and
  `"duplicate": true`. The outbox gets an "append if absent" operation for this; today a
  conflict is an internal error (`event_outbox_repo.odin:37-50`).
- The relay publishes with the event id as the JetStream message id (`relay.odin:216`), so
  the stream's two-minute duplicate window (`relay.odin:49-50`) is a second layer.
- Runs dedupe on `occurrence_key = <trigger_id>:<event_id>`, which is UNIQUE
  (`actions_001_reset.sql:71`), for as long as run history is kept.
- Honest scope: this protects against duplicates from sender retries and from a replayed
  request that carries an idempotency key. It does not stop someone who holds the token from
  posting new events; with a bearer token nothing can. TLS, token rotation and the rate
  limit are the controls for that. Signed timestamps would add replay protection for
  captured requests and come with the later HMAC mode.

**Response.** `202 {"event_id": "..."}` after the outbox row is committed. Nothing about
matched rules is returned.

**Envelope.** `type = webhook.received`, class `occurrence`, entity
`{kind: "webhook", id}`, `actor = "webhook:<id>"`, `data` = the request body object.
Request headers are not copied (see §12).

**Bounding the payload downstream.** A 64 KiB body copied into every matched run would be
megabytes per event at 300 rules. The run snapshot (`event_params`, `matcher.odin:47-65`) is
therefore a projection for every type:

- envelope header fields: `type`, `id`, `actor`, `occurred_at`, `fired_at`, `entity_kind`,
  `entity_id`;
- `data`: every top-level scalar of at most 256 bytes (today the matcher copies every
  top-level scalar, `matcher.odin:57-61`), plus the nested paths the rule's own checks and
  the action's prompt template reference. That path list is computed when the rule is compiled;
- if the template uses the new variable `{{event.json}}`: the compact `data` JSON, cut at
  4 KiB;
- the match trace `_match` (§3.6);
- total cap 8 KiB per run.

Template variables (`template.odin:34-53`): added are nested `{{event.data.a.b}}`,
`{{event.entity.kind}}`, `{{event.entity.id}}` and `{{event.json}}`; removed are
`{{event.chain_id}}` and `{{event.task_id}}` (§8).

## 6. Per-target delivery (R4)

### 6.1 Today

Coalescing is per action. An action has at most one open run
(`action_runs_one_open`, `actions_005_settle.sql:7`); later events for the same action join it
while it is open, including while its prompt awaits a read (`matcher.odin:119-122`,
`docs/prompt-delivery-ack.md`). Every open run is drained on its own (`router.odin:343-479`):
its own target resolution (`router.odin:126-190`), chat message, pipeline delivery, outbox
row (`src/hub/service/delivery/delivery.odin:161-235`) and 30-minute unread timer. One
hundred actions firing for one instance are one hundred prompts.

### 6.2 Design

Extend "join while unread" from the action to the target, using the columns that exist.

**Grouping.** The drain pass reads due runs together with their actions and groups them by
target spec:

| Target | Group key | Resolved |
|---|---|---|
| `instance` | instance id | once per group |
| `bot` | bot id | once per group (bot → `agent_instance_id`) |
| `agent`, `reuse` | agent id + project id + selector + placement rules | once per group (rules for all actions loaded in one query) |
| `agent`, `fresh_per_run` | the run itself | per run, as today: each run gets its own new instance |

Only runs with an identical key are merged. A bot action and an instance action that end up
at the same instance stay separate batches, serialized by the gate below. This keeps bridge
replacement (`router.odin:256-285`) well defined: every member of a batch has the same
placement rules.

**Per-run gates stay per run** and run first, unchanged: experiment and enabled checks
(`router.odin:355-363`), stale trigger revision (`router.odin:364-377`), the action slot and
settle logic (`router.odin:381-410`), the action's `min_interval_s` (`router.odin:411-433`),
and delayed-run validity (§2.4).

**Backpressure: one open delivery per target instance.** After resolving the group to an
instance, the drain checks whether that instance already has a routed action delivery
(existing index `action_runs_instance_routed`,
`migrations/actions_004_bot_activity.sql:2`).

- **No open delivery:** send a batch (below).
- **Open delivery:** park the group. Each run becomes `deferred` with
  `target_instance_id` set and `not_before` = the open delivery's expiry. No timer is
  scheduled for parked runs.

Parked runs are released two ways. When a delivery reaches a final state, the same
transaction sets `not_before = now` on the runs parked for that instance and, if any row
changed, appends one `action.ready` wake (the mechanism `finish_run` already uses for settle
waiters, `router.odin:87-97`). If that wake is lost, the runs become due at the delivery's
expiry and the drain expires the stale delivery lazily, which is today's fallback moved from
the action to the target (`router.odin:100-107`, `docs/prompt-delivery-ack.md`).

Parking instead of leaving runs `queued` matters: `runs_due` returns every queued run on
every pass, 32 at a time (`action_repo_sqlite.odin:332`, `router.odin:306-320`), so blocked
runs left `queued` would hide the runs behind them.

The queue per target is bounded without a new limit: an action has at most one open run, and
further events for it join that run. A target's backlog is at most its number of actions.

There is deliberately **no separate per-target rate setting**. Delivery to a target is
clocked by the target reading the previous prompt, and bounded below by the 30-minute unread
timer. The per-action `min_interval_s` stays as the per-action limit.

**Batch.** In one transaction:

1. Take up to 20 runs of the group, oldest first, stopping before the rendered body exceeds
   24 KiB. The rest stay parked for the next batch.
2. Render one chat message. **One run: exactly today's prompt and metadata**, so single-action
   behaviour does not change. Several runs: a digest.

   ```
   3 actions fired for you.

   ### 1. Nightly triage  (chain.state, 2026-11-24T12:00:05Z, 4 events)
   <rendered prompt of that action>

   ### 2. Release webhook  (webhook.received, 2026-11-24T12:00:07Z)
   <rendered prompt of that action>
   ...
   ```

   Metadata keeps today's top-level keys for the first run (`router.odin:193-217`), so current
   consumers of `message_type = action` keep working, and adds
   `runs: [{action_id, action_name, run_id, trigger_id, event_type, event_id, joined_count}]`.
3. One `persist_prompt`, one pipeline route with `ref = run:<first run id>` (format unchanged,
   `migrations/pipeline_001_deliveries.sql:9`) and `notice_count` = total events in the batch
   (`router.odin:248-253`).
4. One UPDATE moves every member to `routed` with the same `delivery_id`, `message_id` and
   `target_instance_id`.

**Final state.** `on_delivery_final` (`router.odin:109-125`) updates every run with that
`delivery_id` in one statement instead of one run. Each run keeps its own row, state and
reason, so history per action stays intact; the UI can show "delivered with 2 other actions"
from the shared `delivery_id`. Replacement (`router.odin:256-285`) re-plans once and moves all
members. The unread timer is per delivery already, so it becomes one per target delivery with
no change.

**One guard that must not be forgotten.** When NATS schedules are unsupported, the drain
skips deferred runs whose `not_before` is in the future as `rate_limited`
(`router.odin:321-341`). Parked runs need no timer and must be excluded from that sweep
(they are recognizable by a non-empty `target_instance_id`).

### 6.3 Why not a batch table

A batch has no state of its own: its lifecycle is the pipeline delivery's, and its members
are found by `delivery_id`. A table would add a second copy of delivery state, which is the
known deferred problem (delivery state in both SQL and JetStream) made worse. This design
adds no delivery state: it writes fewer `pipeline_deliveries` rows and fewer `dlv.*`
messages than today, and nothing new to JetStream.

## 7. Expected counts (R4)

One event that matches K rules whose actions point at T distinct idle targets, all immediate.
Example: K = 100, T = 3.

| Per event | v1 today | v2 |
|---|---|---|
| Rule lookup | 1 SQL query + a JSON parse per candidate | 0 queries (warm cache) |
| Reads per matched rule | 2 (`matcher.odin:118-119`) | 0 |
| `action_runs` inserts | K (100) | K (100), one transaction |
| Target resolutions | K (100) | T (3) |
| Chat messages (prompts) | K (100) | T (3) |
| `pipeline_deliveries` rows | K (100) | T (3) |
| `dlv.*` outbox rows / JetStream messages | K (100) | T (3) |
| Unread timers (schedule definitions) | K (100) | T (3) |
| Wakes of an agent | K (100) | T (3) |
| Run state updates on routing | K statements | T statements covering K rows |
| Run state updates on final | K statements | T statements covering K rows |
| `event_state_heads` upserts | 0 | 1 if the event is `state` class, in the producer's transaction |

Per wake of a target in v2: one prompt, one delivery, one timer, one read receipt, and at most
one `action.ready` wake if runs were parked behind it. A second event arriving while the
target has not read the first costs K′ run inserts and zero deliveries; its runs go out as one
digest after the read.

Per webhook request: one indexed webhook read, one version upsert, one outbox insert, one
JetStream message.

## 8. Migration without a compatibility layer (U2)

The feature is not live, so v2 replaces v1 in one step. There is no dual write, no reader
fallback, no alias and no follow-up cleanup task.

**One switch, one release.** Producers emit only the v2 envelope, and every reader in §2.1
changes in the same task, because a producer-only or reader-only change would break the
other side:

| Party | Change |
|---|---|
| Producers | Top-level `chain_id`/`task_id` are gone; `entity` and `data.chain_id` replace them. |
| Matcher, settle key, prompt metadata | Read `entity`. Prompt metadata carries `entity_kind`/`entity_id` instead of `chain_id` (`router.odin:202`); the Ninjy skill that resolves chain titles from it is updated in the same task. |
| Event inbox | Replay and notices read the chain from `entity`/`data.chain_id` (`eventinbox/catalog.odin:90`, `notifications.odin:169`). |
| Web UI | Catalog replay reads `entity` (`useUserWebSocket.ts:260-264`). |
| Agents | `ham-ctl events next` returns v2 envelopes; skill text that names the id fields is updated. |
| Templates | `{{event.chain_id}}`/`{{event.task_id}}` are removed; `{{event.entity.id}}` and `{{event.data.chain_id}}` replace them. Unknown variables render literally (`template.odin:28`), so a missed prompt is visible, not silent. |
| Trigger config | `filter` tree only; the `data` map and `chain_id` key are rejected. CLI shorthand compiles to a tree on the client. |
| Validity | Head-row check only (§2.4). |

**What happens to data that exists at upgrade:**

| Data | Handling |
|---|---|
| Stored event triggers | Converted once in the migration: each equals map becomes an `all` group of `eq` checks on `data.<key>` (one `UPDATE` using SQLite JSON functions). `{}` already means "always". |
| Stored prompts | The same migration replaces `{{event.chain_id}}` with `{{event.entity.id}}` in `actions.prompt_text`. That is exact, because only `chain.*` event types exist today (`event_kind.odin:56-62`). `{{event.task_id}}` is always empty today and is replaced with nothing. Spellings with inner spaces are not caught and will render literally. |
| Old-shape events still in JetStream (retained up to 14 days, `relay.odin:49`) | Not interpreted. Catalog events without `entity` are acknowledged and skipped by the matcher and ignored by inbox replay. |
| Delayed runs pending at upgrade | No head row exists for their event, so they are skipped as `superseded` (§2.4). Delays are at most 24 hours (`action.odin:6`). |
| Runs already routed | Finish normally; the "all runs with this `delivery_id`" update covers them as the one-member case. |
| Run history | Old rows keep their old snapshot keys and show no entity or match trace. Nothing is rewritten. |

**Known consequences, stated so they are a choice and not a surprise:**

1. The envelope is not only read by actions. The event inbox and the UI catalog replay are
   live paths. With no fallback, an agent notice for an old-shape event that is still unread
   at the moment of upgrade is dropped. The legacy `[taskv2]` notice path is on by default
   (`--legacy-event-notices`, `src/hub/main.odin:547-551`), so those agents are still
   notified through it. See §14.
2. A desktop UI older than the hub does not understand v2 catalog replay and misses live
   refresh hints until it is updated. The UI and hub must ship together for this release.
3. Rollback to the previous hub is not supported once rules use the tree or webhooks exist;
   the previous hub cannot read tree filters. Schema changes themselves are additive except
   the `event_entity_versions` rebuild, which only drops a CHECK.

## 9. Data model changes

| Migration | Content |
|---|---|
| `events_007_entity_heads.sql` | Rebuild `event_entity_versions` without the `entity_kind` CHECK (copy, drop, rename; the table has no triggers or foreign keys in `events_002_topics.sql:1-5`). Create `event_state_heads` (§2.4). |
| `actions_006_rules_v2.sql` | Convert stored equals maps to trees and rewrite removed template variables (§8). `CREATE INDEX action_runs_delivery ON action_runs(delivery_id) WHERE state = 'routed';` and `CREATE INDEX action_runs_parked ON action_runs(target_instance_id) WHERE state = 'deferred' AND target_instance_id <> '';` |
| `webhooks_001.sql` | `event_webhooks` (§5.4). |

No new columns. `action_triggers.data_filter` holds the condition tree (§3.3).
`action_runs.target_instance_id` gains a second use: set on parked runs (§6.2).
Each named migration must be added to the migration allowlist that the SQLite suite checks
(see the chain's dead-end notes for `actions_004`).

Domain and contract changes: condition-tree node types, the match trace, and the v2 envelope type in
`src/contracts` with the TS mirror; `Event_Descriptor` gains `class`, entity kind, subject
template and field list (`event_kind.odin:47-54`); no change to `Action`, `Action_Trigger` or
`Action_Run` structs.

### 9.1 Configurable limits (U4)

Every limit in this spec is a default compiled into the hub and overridable in hub config
(bound next to the existing settings in `src/hub/app/config_bind.odin`). Out-of-range
overrides are rejected at startup. The effective values are returned by
`GET /api/v1/actions/trigger-types`, so UI and CLI never hardcode them.

| Setting | Default |
|---|---|
| Tree depth / checks / nodes / stored bytes | 4 / 16 / 24 / 4 KiB |
| Values per `in` list, bytes per value | 32 / 256 |
| Webhook body size | 64 KiB |
| Webhook requests per minute, per webhook | 60 |
| Failed webhook auth per minute, per client IP | 20 |
| Webhooks per owner | 50 |
| Runs per batch / batch body size | 20 / 24 KiB |
| Run snapshot size | 8 KiB |

Limits are hub-wide. Per-owner or per-webhook overrides are not part of v2.

## 10. CLI and UI surface

**CLI (`ham-ctl actions`, parser at `src/ctl/hub_mode.odin:619`).** The trigger shorthand
`event:<type>,key=value` (tested at `src/ctl/actions_test.odin:51`) grows operators; a bare
key still means `data.<key>`:

| Shorthand | Check |
|---|---|
| `state=completed` | `eq` |
| `state!=archived` | `ne` |
| `state=completed\|archived` | `in` |
| `state!=completed\|archived` | `not_in` |
| `repo.name^=heimdall-` | `prefix` |
| `pull_request?` / `!pull_request?` | `exists` true / false |
| `@wh_18eb…` | `entity_id` |

Several shorthand checks on one trigger are combined with AND, as today. The shorthand does
not express `any`/`not` groups; trees are passed through `--trigger-json`, which keeps
accepting the full config. `ham-ctl actions runs` prints the match trace of each run as an
indented tree with a true/false mark per node. New group:

```bash
ham-ctl webhook create --name "CI"       # prints once: the token, the header URL, the secret URL
ham-ctl webhook list | show <id> | enable <id> | disable <id> | delete <id>
ham-ctl webhook rotate <id>              # new token + new secret URL, once; old ones stop working
ham-ctl webhook test <id> --token <token> --data '{"hello":"world"}'   # POST from the CLI
```

The `ham-ctl-reference` skill and the Ninjy bot skill are updated in the same task.

**HTTP.** `GET/POST /api/v1/webhooks`, `GET/PATCH/DELETE /api/v1/webhooks/<id>`,
`POST /api/v1/webhooks/<id>/rotate` (session auth, owner-scoped), plus the ingress in §5.4.
`GET /api/v1/actions/trigger-types` (`service.odin:404-435`) additionally returns, per event
type, its fields with allowed operators and known values, and the tree limits (§3.4).
`POST /api/v1/actions/filter-test` takes `{event_type, filter, event}` (a pasted sample
envelope or webhook body) and returns the validation result and the per-node trace of §3.6.
It is a pure function: no event is emitted and nothing is stored.

**UI** (`src/ui/components/actions/`).

*Tree editor* (in `TriggerListEditor.tsx`, per event trigger). One component renders the
tree as nested cards; each node is one row or card:

```
┌ Match [ All of ▾ ]                                   [+ check] [+ group]
│  data.action     [ is one of ▾ ]  opened, reopened                  ✕
│  ┌ [ Any of ▾ ]                                    [+ check] [+ group] ✕
│  │  data.repo.name    [ starts with ▾ ]  heimdall-                  ✕
│  │  data.labels.urgent [ exists ▾ ]                                 ✕
│  └
│  ┌ [ None of ▾ ]                                   [+ check] [+ group] ✕
│  │  data.draft        [ is ▾ ]  true                                ✕
│  └
└
In words: action is one of opened, reopened AND (repo.name starts with "heimdall-" OR
labels.urgent exists) AND NOT (draft is true)
```

- A group has a mode selector: **All of** (`all`), **Any of** (`any`), **None of**
  (`not` around `any`). A `not` around any other node, which only hand-written JSON
  produces, renders as a **Not** wrapper card.
- A check row is field, operator, value. Field and value are pickers when the event type's
  descriptor lists them (trigger-types response) and free text for webhook paths.
- "+ group" is disabled at depth 4 and both add buttons at the node limits; the limits come
  from the trigger-types response.
- A plain-language sentence under the tree restates it, so nesting mistakes are visible.
- Server validation errors carry the node `path` (§3.4); the editor marks that node.
- A trigger with no conditions shows "Always" and one "+ check" button.
- "Test with a sample event" opens a JSON box and calls `filter-test`, then shows the same
  read-only view as run history. This is how a user finds out why a rule did not fire.
- On narrow screens nested cards indent by a fixed small step and check rows stack field,
  operator and value vertically.

*Matched nodes in run history* (`RunHistory.tsx`). Expanding a run shows the same tree,
read-only, with the recorded trace overlaid:

```
✓ All of
   ✓ data.action is one of opened, reopened        saw: "opened"
   ✓ Any of
      ✗ data.repo.name starts with "heimdall-"     saw: "docs-site"
      ✓ data.labels.urgent exists
   ✓ None of
      ✗ data.draft is true                          saw: false
```

- Every node shows true or false with an icon and a text label, never colour alone.
- Checks show the value the event carried ("saw: …", or "missing").
- If the trigger was edited after the run (`_match.rev` differs from the trigger's `rev`),
  the view says "rule edited since this run" and lists only the recorded values (§3.6, U5).
- Joined runs have their own trace, since each is its own event.

*Other UI.* A Webhooks section lists webhooks, creates one (token, header URL and secret URL shown once, the secret URL with a warning that
anyone holding it can post events), and rotates the token. `RunHistory.tsx` also shows "delivered with N other actions" and "waiting for the
agent to read the previous prompt" for parked runs. API types in
`src/ui/api/endpoints/actions.ts`.

## 11. Security notes

- **Owner scoping.** The owner of a webhook event is the webhook row's owner. The matcher
  already drops events whose envelope owner differs from the subject owner
  (`matcher.odin:70-76`).
- **Webhook data is untrusted input that reaches an agent prompt.** Mitigations: values are
  inserted once and never re-interpreted as template text (`template.odin:9`); every
  inserted value is length-capped (§5.4) and stripped of control characters; a prompt that
  contains webhook-derived values gets one fixed line stating that the event data comes from
  an external webhook and is data, not instructions. This reduces, and does not remove,
  prompt-injection risk; the rule author decides which agent a webhook may wake.
- **No bodies in non-webhook envelopes.** Memory events carry ids and enums only (§5.3),
  matching the existing "metadata-only" outbox rule (`events_001_outbox.sql:1`).
- **Webhook tokens.** Generated by the hub, shown once, stored only as a hash, compared in
  constant time; rotation invalidates the old token for both URL forms immediately. Never in
  a query string. In the secret-URL form the token segment is redacted from hub logs,
  traces, metrics and errors before any other code sees the path (§5.4); proxies in front of
  the hub must be configured not to log it.
- **Abuse bounds.** Size, rate and failed-auth limits are checked before parsing and before
  any SQL (§5.4). A webhook wired to a `fresh_per_run` agent can spawn at most one instance
  per `min_interval_s` (default 30 s, `action.odin:9`) per action.
- **Filters cannot be made expensive:** no regex, bounded tree depth and size, bounded lists, bounded path depth (§3.4, §3.5).
- **Experiment gates** stay as they are: `actions` (and `bots` for bot targets) are checked at
  drain (`router.odin:356-358`); the webhook ingress also requires `actions`.

## 12. Deliberately left out

| Left out | Why |
|---|---|
| Regex, numeric comparisons, `contains`/`suffix` | §3.5. |
| Event arrays, conditions across several events, `cause_id`/correlation, counts or time windows | User decision: keep it simple. One event is one fact and the tree is evaluated statelessly against it (§3.2). |
| A copy of the tree in every run | User decision U5. The trace is tiny, the tree is not; an edited rule shows values only (§3.6). |
| `any`/`not` in the CLI shorthand | The shorthand stays a flat AND; trees go through `--trigger-json` (§10). |
| Per-trigger targets, new target kinds | R2 is met by existing kinds (§4). |
| Webhook request headers in `data` | Keeps the envelope to the body. Consequence: senders that put the event name in a header (GitHub) cannot be filtered on it. |
| HMAC request signing | User decision U3: token auth is the v1 baseline. HMAC needs a recoverable secret at rest and is a later, optional auth mode. |
| Provider-specific signature formats (GitHub, Stripe) | Each is its own verifier. v2 webhooks are for senders you control or that can set a header. A natural follow-up together with HMAC: signature profiles plus a small header allowlist. |
| Any backward compatibility (dual write, reader fallback, template aliases, old filter reader) | User decision U2 (§8). |
| Per-owner webhook rate limit, per-owner limit overrides | The per-webhook limit and the webhook count cap bound an owner already. |
| Outbound webhooks, non-JSON bodies, synchronous responses | Not required. |
| A per-target rate or concurrency setting | One open delivery per target is the backpressure (§6.2). |
| A batch table, any redesign of delivery state | §6.3; the SQL/JetStream duplication is not touched. |
| Rewriting stored schedule definitions and internal timer envelopes | §2.2. |
| Per-owner cache invalidation | A global epoch is enough to start (§3.7). |
| Descriptors for `task.requirements_changed`, `task.review_verdict`, `task.merge_conflict` | A table row each when needed (§5.1). |
| Memory events for edits that keep the status | No use case; avoids noise. |

## 13. Task breakdown

Sized for one worker each. Tests go beside the code and run as
`nix develop -c odin test <pkg> -collection:odin_test=src`; existing suites go through the
chain's Test Runner. "Deps" are hard ordering constraints.

| ID | Task | Deps | Acceptance |
|---|---|---|---|
| E1 | **Envelope v2 switch.** Extract the producer-neutral emit helper; `catalog_emit` wraps it and emits only the v2 shape. In the same task switch every reader: matcher snapshot, settle key, prompt metadata, templates, event inbox, UI replay, v2 envelope type in `src/contracts` + TS mirror, skill text. Migration `events_007` (versions rebuild). One task on purpose: there is no fallback, so producer and readers cannot merge separately. | – | Golden test: chain and task envelopes have `entity`, `data.chain_id` on task events, and no top-level `chain_id`/`task_id`; each reader has a test fed a v2 envelope; an old-shape catalog event is acked and skipped without error; `{{event.entity.id}}` renders and `{{event.chain_id}}` renders literally; versions accept kind `memory`; `taskv2`, actions, eventinbox, SQLite and UI suites pass. |
| E3 | **Generic validity (D2).** `event_state_heads` in `events_007`; upsert in the emit helper for `state` class; head-row check; generic settle key; delete the chain-state snapshot check. | E1 | Tests: reopened chain → `superseded`; chain row touched without state change → delivered; completed→active→completed → delivered once; delayed state run without a head row → `superseded`; `chain.work_finished` still uses `work_revision`. The real-producer settle tests from `task_18eaf94a6a6d3b39` are updated to the head-row rule and pass. |
| F1 | **Condition tree.** Node parsing, validation with `path`/`reason`, compile to the flat form, short-circuit evaluation and full-trace evaluation as pure procs; tree stored in `data_filter`; the `data` map and `chain_id` config key rejected; limits read from hub config (§9.1); trigger-types returns fields, operators, effective limits; `filter-test` endpoint; migration `actions_006` data conversion. | E1 | Table test over every operator × {present string, number, bool, null, object, array, absent}; tests for `all`/`any`/`not` nesting incl. short-circuit result equal to full evaluation; every limit in §3.4 rejected with the right `reason` and `path`; the migration converts a stored equals map and a stored `{{event.chain_id}}` prompt as §8 describes, and `{}` stays "always"; a limit overridden in config is enforced and reported; `3` equals `"3"`; trace characters are in the author's node order. |
| F2 | **Compiled rule index.** Per-owner cache with epoch invalidation and minute refresh; single-statement join-or-queue insert; `_match` trace written to the run snapshot; pruning out of the hot path. | F1 | Test with 300 rules for one owner: second event runs zero trigger queries (query counter, like `src/hub/service/actions/performance_test.odin:23-25`); an edit, disable or delete is honoured on the next event; redelivery inserts nothing; schedule guard and retire still work. Records the measured per-event cost in the task comment. |
| B1 | **Per-target batch send.** Grouping, resolve once per group, backpressure park, digest render, one message/delivery, member update. Migration `actions_006` (indexes). | – | Tests: 10 actions → 1 instance, one event → 1 chat message, 1 delivery, 10 runs `routed` with one `delivery_id`; single run renders byte-identical to today; bot and instance groups resolve once each (call counter); `fresh_per_run` unchanged; 25 runs split 20 + 5. |
| B2 | **Batch lifecycle.** Final-state fan-out by `delivery_id`; parked release + single `action.ready`; lazy expiry at drain; replacement moves all members; schedules-unsupported sweep excludes parked runs; history exposes batch size. | B1 | Tests: read → all members `delivered`; `not_read` → all members failed with `not_read`, parked runs go out next as one digest; lost wake → released at expiry; bridge replacement keeps one delivery for all members; parked runs survive unsupported-schedule mode; in-flight single-run deliveries from before the change finalize. |
| M1 | **Memory producer.** `save_memory` in a unit of work; `memory.state` event on create and status change; descriptor + two presets. | E1, E3 | Tests: create pending, approve, reject, archive each emit one event with correct `status`/`previous_status`; edit without status change emits none; system memory emits none; rollback of the memory write leaves no outbox row; a rule with preset "Memory approved" produces a run. |
| W1 | **Webhook model and ingress.** `webhooks_001`; CRUD service + HTTP; generated token shown once and stored hashed; ingress = rate limit, size check, token auth, outbox append-if-absent, `202`; uniform 401; deterministic event id from `Idempotency-Key`; limits from hub config. No HMAC. Both URL forms (bearer header, secret URL) on one handler; token segment redacted in the request wrapper; list of every hub site that records a request path; `SELF_HOSTING.md` proxy note. | E1 | Tests: valid token → 202 and exactly one outbox row with the owner from the row, through each URL form; a secret-URL request (accepted, rejected, oversized, rate-limited and one forced to error) leaves no token in captured logs, traces, metrics labels or response bodies; token in both header and path → 401; rotate invalidates both forms; the token is not retrievable after create and the table holds no plaintext; wrong token, missing token, unknown id and disabled webhook return identical 401; rotate invalidates the old token; default 64 KiB + 1 → 413; non-object → 400; 61st request in a minute to one webhook → 429 while another webhook is unaffected; same `Idempotency-Key` twice → one outbox row and `duplicate: true`; cross-owner CRUD → not found; the handler runs no trigger query and no delivery code (query counter). |
| W2 | **Webhook rules.** `webhook.received` descriptor with free `data.` paths; run snapshot projection and 8 KiB cap; nested template variables and `{{event.json}}`; untrusted-data line; control-character stripping. | F1, W1 | Tests: 64 KiB body → run snapshot ≤ 8 KiB and contains the paths used by filter and template; nested variable renders; `{{` inside a webhook value is not expanded; prompt contains the untrusted-data line only for webhook-derived values. |
| C1 | **CLI.** Filter shorthand operators, match trace in `actions runs`, `ham-ctl webhook` group, `ham-ctl-reference` and Ninjy skill text. | F1, W1 | `src/ctl` tests for each shorthand form and each webhook verb, in the style of `src/ctl/actions_test.odin`; shorthand `event:chain.state,state=completed` produces a `filter` tree with one `eq` check. |
| U1a | **UI tree editor.** Nested group cards with All/Any/None modes, check rows, limits, plain-language sentence, error marking by node path, sample-event test. API types. | F1 | UI tests: build the §3.3 example and get exactly that JSON; depth and node limits disable the add buttons; a server `path` error marks the right node; usable at phone width. |
| U1b | **UI history and webhooks.** Read-only tree with per-node result and seen values in run history, edited-rule fallback; Webhooks section; batch and parked labels. | U1a, F2, W1, B2 | UI tests for a trace overlay with true and false nodes, the edited-rule fallback, creating a webhook with the token shown once, and both history labels; existing actions UI tests pass. |
| X1 | **E2E on dev.** One webhook and one memory rule to a bot; 20 actions to one instance; a delayed chain rule across a reopen. | all above | Observed on dev: one digest prompt for the 20 actions, a second digest only after the read; webhook duplicate suppressed; reopened chain skipped as `superseded`. No rollout without the user's explicit OK. |

Parallelism: E1 and B1 can start together. After E1, the tracks F (filters), M/W (producers)
and B (delivery) are independent until C1, U1b and X1.

## 14. Decisions and the one open point

Settled by the user in requirements revision 3:

| Point | Decision |
|---|---|
| `ne`/`not_in` on a missing field | True; `exists` gives the strict form (U1). |
| Compatibility layer | None (U2). |
| Webhook auth | Generated token stored hashed; HMAC later (U3). |
| Limits | Configurable defaults (U4, §9.1). |
| Tree copy per run | No; "rule edited since" plus seen values (U5). |

Still open, for confirmation rather than design:

1. **"No compatibility" also covers the event inbox and UI catalog replay**, which are live
   paths that read the same envelope (§8, consequences 1 and 2). The spec applies U2 to them
   as written. The cost is bounded: unread old-shape inbox events at upgrade are covered only
   by the legacy notice path, and the UI must ship with the hub. If that is not acceptable
   for those two readers, the smallest exception is a fallback in the inbox and UI replay
   only, removed after the 14-day stream retention.
