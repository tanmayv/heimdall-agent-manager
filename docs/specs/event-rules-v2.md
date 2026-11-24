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
| D3 | Readers accept the new shape first, fall back to old for one release; template aliases kept | **Adopt, plus one addition:** producers also keep writing the old top-level `chain_id`/`task_id` for that release, because not every reader ships with the hub (§8). |

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
  so it costs nothing at match time. `chain_id` stays accepted as its alias for `chain.*`
  types (`event_kind.odin:16`, `:22-23`). A check `entity.id eq X` that is a direct child of
  a root `all` is folded the same way.
- The legacy `"data": {"state": "completed"}` map stays accepted as input and is compiled
  into `{"all": [eq checks on data.<key>]}`. Sending both `data` and `filter` is
  `invalid_filter`.
- **Storage reuses the existing column.** `action_triggers.data_filter` is only constrained
  to valid JSON (`actions_001_reset.sql:56`). New writes store the tree, and the stored root
  is always a group: a single check is wrapped in `all`. That makes the two stored forms
  unambiguous without a version field: a v1 equals map has only string values
  (`event_kind.odin:30-35`), while a stored tree is an object with exactly one key, `all`,
  `any` or `not`, whose value is an array or object. No DDL, no data migration; old rows keep
  matching.

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
a phone. The limits are returned by the trigger-types endpoint so UI and CLI do not hardcode
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
  they mean the same as wrapping the positive check in `not`. Put `exists: true` next to
  them when the field must be there. Two-valued logic throughout: every node is true or
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
- The tree itself is **not** copied into the run (up to 4 KiB × every run would defeat R4).
  The UI overlays the trace on the trigger's current tree when `_match.rev` equals the
  trigger's `rev`; otherwise it shows "the rule changed after this run" and only the
  recorded values. This is a deliberate trade-off (§14).
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
  auth_mode TEXT NOT NULL CHECK(auth_mode IN ('bearer','hmac')),
  secret TEXT NOT NULL,                                      -- see "Secret storage"
  enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL, last_received_at TEXT NOT NULL DEFAULT ''
);
CREATE INDEX event_webhooks_owner ON event_webhooks(owner_user_id);
```

Limit: 50 webhooks per owner.

**Endpoint.** `POST /api/v1/hooks/<webhook_id>`, registered outside session auth like the
existing provider webhooks (`src/hub/app/wiring.odin:802`, `:946-947`). The owner comes from
the webhook row, never from the request.

**Authentication** (two modes, one secret each):

| Mode | Request carries | Use |
|---|---|---|
| `bearer` (default) | `Authorization: Bearer <secret>` | Senders that can set a header: scripts, CI, Alertmanager, Grafana, n8n. |
| `hmac` | `X-Heimdall-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256(secret, t + "." + raw body)>` | Senders that can sign. Timestamp accepted from 300 s in the past to 30 s in the future. |

The HMAC check follows the hub's existing verifier (`src/hub/service/billing/webhook.odin:15-38`:
constant-time compare, five-minute bound, multiple `v1` values accepted so a sender can
rotate). Secrets are never accepted in the query string. Every failure (unknown id, disabled
webhook, wrong secret, bad signature, actions experiment off) returns the same `401` body so
the endpoint is not an oracle for webhook ids.

**Secret storage.** 32 random bytes, shown once on create and on rotate. `bearer` needs only
a SHA-256 of the secret. `hmac` needs the secret itself, so it must be stored with whatever
at-rest protection the hub uses for channel credentials. I did not verify that mechanism in
this task; W1 must cite it, and if none exists W1 ships `bearer` only and `hmac` waits.

**Size and shape limits.**

| Limit | Value | On violation |
|---|---|---|
| Body size | 64 KiB, checked before parsing | `413` |
| Content type | `application/json` | `415` |
| Body | a JSON object, nesting depth ≤ 16 | `400` |
| Rate, per webhook | 60 requests per minute | `429` with `Retry-After` |
| Rate, per owner | 300 requests per minute | `429` |
| Failed auth, per client IP | 20 per minute, then `429` before any lookup | `429` |

The limiter is the fixed-window, in-memory pattern the bot webhook already uses
(`src/hub/transport/http/bot_webhook_handlers.odin:25-76`), keyed by webhook id and owner
instead of globally. Client IP resolution reuses the trusted-CIDR logic at
`bot_webhook_handlers.odin:88`. Counters reset on hub restart; that is acceptable for a
protective limit.

**Replay and duplicate protection.**

- The event id is **deterministic**: `evt_wh_` + the first 32 hex digits of
  `SHA-256(webhook_id | key)`, where `key` is the `Idempotency-Key` header when present
  (≤ 128 bytes), else `t | SHA-256(body)` in `hmac` mode, else a fresh random id.
- `event_outbox.event_id` is UNIQUE (`migrations/events_001_outbox.sql:4`) and published
  rows are kept 24 hours (`src/hub/service/eventrelay/relay.odin:166-171`). A repeat inside
  24 hours hits that constraint and is answered `202` with the original event id and
  `"duplicate": true`. The outbox gets an "append if absent" operation for this; today a
  conflict is an internal error (`event_outbox_repo.odin:37-50`).
- The relay publishes with the event id as the JetStream message id (`relay.odin:216`), so
  the stream's two-minute duplicate window (`relay.odin:49-50`) is a second layer.
- Runs dedupe on `occurrence_key = <trigger_id>:<event_id>`, which is UNIQUE
  (`actions_001_reset.sql:71`), for as long as run history is kept.
- Honest scope: in `hmac` mode a captured request cannot be replayed (same id inside 24 h,
  stale timestamp after 5 minutes). In `bearer` mode the protection is against sender
  retries; whoever holds the bearer secret can post new events anyway.

**Response.** `202 {"event_id": "..."}` after the outbox row is committed. Nothing about
matched rules is returned.

**Envelope.** `type = webhook.received`, class `occurrence`, entity
`{kind: "webhook", id}`, `actor = "webhook:<id>"`, `data` = the request body object.
Request headers are not copied (see §12).

**Bounding the payload downstream.** A 64 KiB body copied into every matched run would be
megabytes per event at 300 rules. The run snapshot (`event_params`, `matcher.odin:47-65`) is
therefore a projection for every type:

- envelope header fields: `type`, `id`, `actor`, `occurred_at`, `fired_at`, `entity_kind`,
  `entity_id`, and the aliases `chain_id`/`task_id` (§8);
- `data`: every top-level scalar of at most 256 bytes (today the matcher copies every
  top-level scalar, `matcher.odin:57-61`), plus the nested paths the rule's own checks and
  the action's prompt template reference. That path list is computed when the rule is compiled;
- if the template uses the new variable `{{event.json}}`: the compact `data` JSON, cut at
  4 KiB;
- the match trace `_match` (§3.6);
- total cap 8 KiB per run.

Template additions (`template.odin:34-53`): nested `{{event.data.a.b}}`,
`{{event.entity.kind}}`, `{{event.entity.id}}`, `{{event.json}}`.

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

## 8. Compatibility and migration (D3)

**Release N (this work):**

| Party | Behaviour |
|---|---|
| Producers | Emit v2 fields **and** keep top-level `chain_id`/`task_id` on chain and task events. |
| Hub readers (matcher, inbox, validity) | Read `entity`/`data.chain_id` first; fall back to top-level ids. One shared accessor in `src/contracts/events.odin` with its TS mirror, used by every reader in §2.1. |
| Web UI | `useUserWebSocket.ts:260-264` uses the same accessor logic. |
| Templates | `{{event.chain_id}}` and `{{event.task_id}}` stay as aliases: the entity id when the entity is that kind, else `data.chain_id`. The matcher writes both aliases into every run snapshot, so stored old-shape and new-shape `action_runs.event_params` render identically and no stored row is rewritten. |
| Stored filters | v1 equals-map `data_filter` rows keep matching (§3.3). |
| Delayed runs created before the upgrade | Their events have no head row. A run whose entity has no head row falls back to the legacy per-type check (`event_kind.odin:72-124`). Delays are capped at 24 hours (`action.odin:6`), so this path is dead a day after the upgrade. |
| JetStream backlog | Old-shape messages (retained up to 14 days, `relay.odin:49`) are read through the fallback. |
| In-flight deliveries | One run per delivery; the "all runs with this `delivery_id`" update covers them as the one-member case. |

**Why the dual write (the addition to D3).** Reader fallback handles old events reaching new
code. It does not handle new events reaching old code, and two readers are not deployed with
the hub: an installed desktop UI, and agents that read raw envelopes through
`ham-ctl events next` under skill text that tells them where the ids are. Keeping the two
top-level fields for one release costs about sixty bytes per event and removes that ordering
problem.

**Release N+1 (one cleanup task):** stop writing top-level `chain_id`/`task_id`; remove the
reader fallback, the legacy validity callback for chain state, and the v1 equals-map filter
reader after a one-statement rewrite of remaining rows. The template aliases stay; they are
part of the user-facing prompt language.

**Rollback.** Every schema change is additive except the `event_entity_versions` rebuild,
which only drops a CHECK. An older hub ignores the new tables. It would not understand
tree-form filters, so rules saved with a condition tree must be disabled before a rollback; the
release notes must say so.

## 9. Data model changes

| Migration | Content |
|---|---|
| `events_007_entity_heads.sql` | Rebuild `event_entity_versions` without the `entity_kind` CHECK (copy, drop, rename; the table has no triggers or foreign keys in `events_002_topics.sql:1-5`). Create `event_state_heads` (§2.4). |
| `actions_006_target_batches.sql` | `CREATE INDEX action_runs_delivery ON action_runs(delivery_id) WHERE state = 'routed';` and `CREATE INDEX action_runs_parked ON action_runs(target_instance_id) WHERE state = 'deferred' AND target_instance_id <> '';` |
| `webhooks_001.sql` | `event_webhooks` (§5.4). |

No new columns. `action_triggers.data_filter` holds either a v1 equals map or a condition tree, told apart by shape (§3.3).
`action_runs.target_instance_id` gains a second use: set on parked runs (§6.2).
Each named migration must be added to the migration allowlist that the SQLite suite checks
(see the chain's dead-end notes for `actions_004`).

Domain and contract changes: condition-tree node types, the match trace, and the envelope accessor in
`src/contracts` with the TS mirror; `Event_Descriptor` gains `class`, entity kind, subject
template and field list (`event_kind.odin:47-54`); no change to `Action`, `Action_Trigger` or
`Action_Run` structs.

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
ham-ctl webhook create --name "CI" [--auth bearer|hmac]   # prints URL and secret once
ham-ctl webhook list | show <id> | enable <id> | disable <id> | delete <id>
ham-ctl webhook rotate <id>                                # prints the new secret once
ham-ctl webhook test <id> --data '{"hello":"world"}'       # signed POST from the CLI
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
- A trigger with no conditions shows "Always" and one "+ check" button. Existing v1 filters
  open as an "All of" group, which is what they mean.
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
  the view says so and lists only the recorded values (§3.6).
- Joined runs have their own trace, since each is its own event.

*Other UI.* A Webhooks section lists webhooks, creates one, copies the URL and rotates the
secret. `RunHistory.tsx` also shows "delivered with N other actions" and "waiting for the
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
- **Secrets.** Shown once, never logged, never in URLs; compared in constant time; rotation
  replaces the secret immediately.
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
| A copy of the tree in every run | The trace is tiny, the tree is not; an edited rule shows values only (§3.6). |
| `any`/`not` in the CLI shorthand | The shorthand stays a flat AND; trees go through `--trigger-json` (§10). |
| Per-trigger targets, new target kinds | R2 is met by existing kinds (§4). |
| Webhook request headers in `data` | Keeps the envelope to the body. Consequence: senders that put the event name in a header (GitHub) cannot be filtered on it. |
| Provider-specific signature formats (GitHub, Stripe) | Each is its own verifier. v2 webhooks are for senders you control or that can set a header. A natural follow-up: signature profiles plus a small header allowlist. |
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
| E1 | **Envelope v2 producer.** Extract the producer-neutral emit helper; `catalog_emit` wraps it; emit `entity` and `data.chain_id`, keep top-level ids (dual write). Migration `events_007` (versions rebuild only). | – | Golden test of the envelope for one chain and one task event shows both shapes; versions accept kind `memory`; `taskv2` suite passes; SQLite migration suite passes incl. upgrade from a populated `event_entity_versions`. |
| E2 | **Readers accept v2.** Envelope accessor in `src/contracts` + TS mirror; switch matcher snapshot, settle key, prompt metadata, templates, event inbox, UI replay. Run snapshot writes `entity_kind`, `entity_id` and both aliases. | E1 | Each reader has a test fed a v2-only envelope and an old-shape envelope with equal results; `{{event.chain_id}}` renders for a task event; actions, eventinbox and UI suites pass. |
| E3 | **Generic validity (D2).** `event_state_heads` in `events_007`; upsert in the emit helper for `state` class; generic check with legacy fallback when no head row; generic settle key. | E2 | Tests: reopened chain → `superseded`; chain row touched without state change → delivered; completed→active→completed → delivered once; pre-upgrade run without head row uses legacy check; `chain.work_finished` still uses `work_revision`. The four real-producer settle tests from `task_18eaf94a6a6d3b39` still pass. |
| F1 | **Condition tree.** Node parsing, validation with `path`/`reason`, compile to the flat form, short-circuit evaluation and full-trace evaluation as pure procs; legacy map compiled to an `all` group; tree stored in `data_filter`; trigger-types returns fields, operators, limits; `filter-test` endpoint. | E2 | Table test over every operator × {present string, number, bool, null, object, array, absent}; tests for `all`/`any`/`not` nesting incl. short-circuit result equal to full evaluation; every limit in §3.4 rejected with the right `reason` and `path`; v1 equals-map rows still match and are never misread as trees; `3` equals `"3"`; trace characters are in the author's node order. |
| F2 | **Compiled rule index.** Per-owner cache with epoch invalidation and minute refresh; single-statement join-or-queue insert; `_match` trace written to the run snapshot; pruning out of the hot path. | F1 | Test with 300 rules for one owner: second event runs zero trigger queries (query counter, like `src/hub/service/actions/performance_test.odin:23-25`); an edit, disable or delete is honoured on the next event; redelivery inserts nothing; schedule guard and retire still work. Records the measured per-event cost in the task comment. |
| B1 | **Per-target batch send.** Grouping, resolve once per group, backpressure park, digest render, one message/delivery, member update. Migration `actions_006`. | – | Tests: 10 actions → 1 instance, one event → 1 chat message, 1 delivery, 10 runs `routed` with one `delivery_id`; single run renders byte-identical to today; bot and instance groups resolve once each (call counter); `fresh_per_run` unchanged; 25 runs split 20 + 5. |
| B2 | **Batch lifecycle.** Final-state fan-out by `delivery_id`; parked release + single `action.ready`; lazy expiry at drain; replacement moves all members; schedules-unsupported sweep excludes parked runs; history exposes batch size. | B1 | Tests: read → all members `delivered`; `not_read` → all members failed with `not_read`, parked runs go out next as one digest; lost wake → released at expiry; bridge replacement keeps one delivery for all members; parked runs survive unsupported-schedule mode; in-flight single-run deliveries from before the change finalize. |
| M1 | **Memory producer.** `save_memory` in a unit of work; `memory.state` event on create and status change; descriptor + two presets. | E1, E3 | Tests: create pending, approve, reject, archive each emit one event with correct `status`/`previous_status`; edit without status change emits none; system memory emits none; rollback of the memory write leaves no outbox row; a rule with preset "Memory approved" produces a run. |
| W1 | **Webhook model and ingress.** `webhooks_001`; CRUD service + HTTP; ingress with auth modes, uniform 401, size/type/shape limits, rate limits, deterministic event id, outbox append-if-absent. Cites the secret-at-rest mechanism or ships `bearer` only. | E1 | Tests: valid bearer and valid hmac → 202 and one outbox row with owner from the row; wrong secret, unknown id and disabled webhook return identical 401; stale and future timestamps rejected; 64 KiB + 1 → 413; non-object → 400; 61st request in a minute → 429; same `Idempotency-Key` twice → one outbox row and `duplicate: true`; cross-owner CRUD → not found. |
| W2 | **Webhook rules.** `webhook.received` descriptor with free `data.` paths; run snapshot projection and 8 KiB cap; nested template variables and `{{event.json}}`; untrusted-data line; control-character stripping. | F1, W1 | Tests: 64 KiB body → run snapshot ≤ 8 KiB and contains the paths used by filter and template; nested variable renders; `{{` inside a webhook value is not expanded; prompt contains the untrusted-data line only for webhook-derived values. |
| C1 | **CLI.** Filter shorthand operators, match trace in `actions runs`, `ham-ctl webhook` group, `ham-ctl-reference` and Ninjy skill text. | F1, W1 | `src/ctl` tests for each shorthand form and each webhook verb, in the style of `src/ctl/actions_test.odin`; old shorthand `event:chain.state,state=completed` produces the same request as before. |
| U1a | **UI tree editor.** Nested group cards with All/Any/None modes, check rows, limits, plain-language sentence, error marking by node path, sample-event test. API types. | F1 | UI tests: build the §3.3 example and get exactly that JSON; open a v1 filter as an All-of group; depth and node limits disable the add buttons; a server `path` error marks the right node; usable at phone width. |
| U1b | **UI history and webhooks.** Read-only tree with per-node result and seen values in run history, edited-rule fallback; Webhooks section; batch and parked labels. | U1a, F2, W1, B2 | UI tests for a trace overlay with true and false nodes, the edited-rule fallback, creating a webhook with the secret shown once, and both history labels; existing actions UI tests pass. |
| X1 | **E2E on dev.** One webhook and one memory rule to a bot; 20 actions to one instance; a delayed chain rule across a reopen. | all above | Observed on dev: one digest prompt for the 20 actions, a second digest only after the read; webhook duplicate suppressed; reopened chain skipped as `superseded`. No rollout without the user's explicit OK. |
| N1 | **Next release cleanup.** Remove dual write, reader fallback, legacy chain-state validity and the object-form filter reader. | one release after X1 | Suites pass with v2-only envelopes; no `chain_id`/`task_id` at the envelope top level. |

Parallelism: E1 and B1 can start together. After E2, the tracks F (filters), M/W (producers)
and B (delivery) are independent until C1, U1b and X1.

## 14. Open points for the reviewer

1. **Missing-field rule for `ne`/`not_in`** (true on missing, §3.5). The alternative, "false
   unless present", is how some rule engines behave; I chose plain negation because it is one
   sentence and `exists` makes the strict form available.
2. **Dual write for one release** (§8) goes beyond D3 as given. It rests on the desktop UI and
   agent skill text being able to lag the hub; if both always ship with the hub, it can be
   dropped and E1 gets simpler.
3. **Webhook `hmac` mode** depends on a secret-at-rest mechanism I did not verify (§5.4).
4. **Batch limits** (20 runs, 24 KiB), webhook limits (64 KiB, 60/min) and tree limits
   (depth 4, 16 checks, 24 nodes) are starting values, not measured ones.
5. **Match trace without a tree copy** (§3.6): after a rule is edited, older runs show the
   values they saw but not the per-node view. Storing the tree per run would fix that at up
   to 4 KiB per run.
