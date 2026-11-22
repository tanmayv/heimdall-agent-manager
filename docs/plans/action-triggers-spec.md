# Action triggers: implementation spec (v7)

**Status:** spec for implementation, with amendment S2 (2026-11-22). Nothing in it is implemented yet.
**Base commit checked:** `origin/main` `f56f13e1`. Every `path:line` reference below was checked in that checkout. Paths are relative to the repository root. Section 14 lists each reference with the source text found at that line, so a reviewer can re-check it mechanically. `origin/main` moves fast: before you start a task, run `git fetch origin` and re-locate each symbol you touch by name. The symbol name is authoritative; the line number is a hint.
**Sources:** plan v7 rev 2 (`cmt_18ea482d685e121d`), the user decisions B1 to B5 and "no user-stop check" (2026-11-22), the earlier decisions R1 to R6, Q1 to Q7, A1, A2, A5, v5-Q1, v5-Q2, "prompt delivery only" and K12, the v6 spec (commit `81e1fd31`), and the scheduling spike (`art_18ea18d6373f5898`). **This document replaces all of them for implementers.** An implementer needs nothing else.
**Supersedes:** the v6 spec. Where this document and `81e1fd31` differ, this document is right.
**Amendment S2 (2026-11-22):** user decisions S-A to S-D (one start path for every agent start, one start command), a list of every case in which an agent cannot be launched (6.12.8), recommendations 1 to 5 of the scaling report (`art_18ea55db8c7ee510`), and a table of every lookup on the event paths (6.16). Section 12.1 lists what S2 changed in the text that was approved as S1. Every `path:line` that S2 added or touched was checked at `origin/main` `99879b7b`; section 14.1 lists them with their source text. Where a reference of section 14 and one of 14.1 name the same line, both hold: the files S2 cites did not move between the two commits, except where 14.1 says so.

## 0. How to read this spec

- **MUST**, **MUST NOT** and **SHOULD** are normative. Everything else is explanation.
- Each name in this document (table, column, route, subject, header, field, file, proc, constant) is fixed. Use it exactly as written.
- Section 6 defines the shared contracts once. Section 8 has one section per task. A task is implementable from its own section plus the contract sections it names.
- **Implementer choice** marks a detail the implementer decides, inside the stated constraints. Everything not marked that way is decided here.
- **Assumption** marks a statement that was read in the code but not proven by running it. The named task MUST verify it first. If it is false, the task MUST stop and report to the coordinator.
- **Settled** marks a former assumption with the evidence that closed it (section 10.2).
- A task MUST NOT build anything listed under its non-goals, even when it looks like a small step.
- The word **router** always means the hub code that turns a due run into a routed delivery (6.13). The word **executor** always means the bridge code that acts on a delivery (6.11.6). v6 used "executor" for the hub code; that name is gone.

## 1. Scope

### 1.1 What this chain delivers

An *action* is a stored prompt with a target and a list of triggers. When a trigger matches, the prompt reaches the target as a chat message, and the target's machine makes sure the agent sees it.

1. **Triggers.** An action has 0 to 16 triggers. A trigger is either a **schedule** (cron, interval or one-shot) or an **event** (a task chain changed state, or a chain's work finished). nats-server is the only scheduler: the hub publishes schedule definitions, and nats-server fires them as events.
2. **What, when, where: the hub.** Producers publish events through the existing outbox. One matcher turns an event into a run row. One router applies the overlap and rate rules, picks the machine and stores the prompt.
3. **One placement module.** Every decision about which machine, provider and model an agent runs on goes through `src/hub/service/placement`.
4. **One delivery pipeline.** The router publishes one small delivery message per run to a private JetStream stream. A per-bridge consumer on the hub forwards it over the existing hub → bridge WebSocket. Bridges get no NATS connection.
5. **The bridge acts.** The bridge looks at its own process table. It types the notice if the agent runs, or starts the agent if it does not, with no user-stop check. Before a start it asks the hub to open a new run generation (start-begin). It answers with the reply frame it already uses for every command.
6. **Four flows, one pipeline.** Action prompts (phase 1), `[events]` notices (phase 2), bot deliveries and task lease wakes (phase 3).
7. **Cleanup.** The bridge-side action scheduler, the hub routes that served it, and the run-now feature are deleted.
8. **One start path (amendment S2).** Every agent start, whoever asks for it, opens its run generation in one hub procedure (`start_begin`) and is launched by one bridge function from the launch command the hub wrote. The task engine's own start code and the bridge's launch from a manifest are deleted. One wire command, `start_agent`, replaces `launch_agent` and `wake_agent` (6.12).

### 1.2 Phases

| Phase | Tasks | Result |
|---|---|---|
| 1 | T1, T2, T3, T8, T9, T16, **T22**, T17, T10, T12, T13, then T14 | Actions with schedule and event triggers, targets `agent` and `instance`, on the placement module and the delivery pipeline. T22 is the one hub start procedure; the manual starts already run on it. T14 is the phase-1 integration and E2E. The actions feature ships (K12) |
| S | T23, T24, T25, then T26 | Start convergence (amendment S2): the one start command, the notice fallback and bots on start-begin, task lease dispatch on start-begin. It needs only T22 and T17, runs beside the rest of phase 1 and beside phase 2, and has its own integration and E2E (T26). It is released with phase 1 if it is ready then, otherwise next |
| 2 | T18 | `[events]` notices are chat messages (v5-Q1) on the pipeline. They reach stopped agents, user-stopped ones included, and wait for a busy agent |
| 3 | T4, T19, T20, then T21 | Placement adoption by task leases, taskchain, MCP and UI defaults (T4). Bot deliveries and the `bot` action target (T19). Task lease wakes (T20). T21 is the phase-3 integration and E2E |

No task of phases 1 to 3 depends on a later phase. Phase S sits between them: nothing in phases 1 and 2 depends on it; in phase 3, T19 depends on T24 and T20 depends on T23 and T25. The server reports the allowed target kinds in `GET /api/v1/actions/trigger-types` (`target_kinds`): phase 1 reports `["agent","instance"]` and rejects `bot`; T19 adds `"bot"`. The UI and CLI read the list, so they need no change in phase 3.

**Task numbers.** Numbers are those of plan v7. T5, T6, T7, T11 and T15 of v6 do not exist in v7; the numbers are not reused. T22 to T26 were added by amendment S2.

### 1.3 Non-goals (MUST NOT be built in this chain)

- Any action effect other than delivering a prompt: no shell command, no webhook, no task creation (user decision "prompt delivery only"). The router keeps one seam for a later kind (6.13) and nothing more.
- A run-now feature: no manual trigger kind, no `POST /actions/:id/run`, no `action.run_requested` event, no CLI `run` verb, no Run button (Q6, A3).
- A hub timer, tick or polling loop for schedules, deferred runs, delivery retries or delivery expiry (v5-Q2, REQ-PIPE-2).
- A data migration of existing actions. Existing rows are discarded (R1).
- Event types in the trigger picker other than `chain.state` and `chain.work_finished` (Q7).
- A NATS client on the bridge, or a new bridge → hub frame type (REQ-BRG-5). The only new bridge → hub request is start-begin (6.12); it replaces the manifest GET of every bridge-side start, one request for one request.
- A hub-side fallback that delivers an action to a bridge without the feature `event_pipeline_v1` (v7 question 1).
- Package `wake` and `content.send_to_instance` of the v6 spec. They are not built. (A hub start procedure **is** built: `start_begin`, 6.12, amendment S2.)
- Removing the old command names `launch_agent` and `wake_agent`, or their adapters on the bridge, while a bridge without `start_agent_v1` can still connect (6.12.6).
- Moving a user's own chat messages onto the pipeline (v7 question 5).
- Any change to which instance the task engine leases work to. Its user-stop avoidance (`src/hub/service/taskv2/matcher.odin:338`) stays (v7 question 4).
- Removing the old code path of notices, bots or leases for bridges without the feature (REQ-FLOW-4).
- The "start an agent, the hub chooses the machine" API. Section 6.10.8 sketches it so the module fits it. It is not built.
- Any selector other than `first` (6.10.6).
- Moving the state write of a move to another bridge (`reconfiguration_launch_destination`) or of a provider test onto `start_begin` (6.12.7).
- Any change to the event inbox's notification loop, to `events next` or to `events ack` (recommendations 6 to 14 of the scaling report). They are separate work.
- A byte limit on `HEIM_EVENTS` or `HEIM_DELIVER` (section 11).
- A waiting queue for runs that find no placement. Such a run fails and the next trigger tries again.

## 2. User decisions

Every decision the user made is listed here with the section that applies it. An implementer MUST NOT re-open them.

| ID | Decision | Applied in |
|---|---|---|
| R1 | No data migration. The old action tables are dropped and replaced | 6.4, T9 |
| R2 | Delete the bridge scheduler and the hub routes that served bridges. Fix `vault prune`, which probes one of those routes | T8, T9 |
| R3 | Actions stay behind the existing `actions` experiment flag | 6.15, T9, T10, T13 |
| R4 | The UI shows every action with its triggers | T13 |
| R5 | Triggers are a registry. A new trigger type is one registry entry plus a producer | 6.6, T9 |
| R6 | Producers, matcher and router are decoupled. Producers only publish | 5, 6.7, T9, T10 |
| Q1 | Schedules live on the existing stream `HEIM_EVENTS`. The release is forward-only | 6.3, T1, T14 |
| Q2 | An action can have several triggers, in the API and the UI | 6.4, 6.14, T9, T13 |
| Q3 | Daylight-saving behaviour is whatever nats-server does | 6.2.4, T2 |
| Q4 | "Chain completed" means `chain.state` with `data.state = "completed"` only | 6.6.3, T9 |
| Q5 | A bot receives the action prompt inside the `bot_deliver` payload | T19 |
| Q6 | Run-now is removed entirely | 1.3, T9, T12, T13 |
| Q7 | The event picker offers `chain.state` and `chain.work_finished` only | 6.6.3, T9, T13 |
| A1 | Overlap is handled per action: one open run per action; later matches join it; one per-action minimum interval. A `routed` run is open | 6.8 |
| A2 | An action target is an ordered list of placement rules; the first satisfiable rule wins | 6.10, 6.13, T9, T10 |
| A3 | Same as Q6 | 1.3 |
| A5 | One placement module for every consumer, with a pluggable selector. Dead and duplicate code is removed | 6.10, T3, T4 |
| v5-Q1 | The `[events]` notice is always a chat message, for idle and stopped agents alike | T18 |
| v5-Q2 | A match inside the minimum interval is deferred and delivered once when the interval ends. No hub tick | 6.8, T10 |
| Prompt only | Delivering a prompt is the only action effect | 1.3, 6.13 |
| K12 | Ship the actions feature first | 1.2, 7 |
| **B1** | The hub owns one JetStream consumer per bridge and forwards over the existing WebSocket. Bridges get no NATS connection | 6.11.1 to 6.11.4, T1, T16, T17 |
| **B2** | The hub picks the bridge when the run is routed | 6.13, 6.10, T3, T10 |
| **B3** | The bridge starts the agent. There is no user-stop check anywhere in the pipeline; a start clears the stop mark | 6.11.6, 6.12, T16, T17 |
| **B4** | The bridge answers with ack or nak on the existing `command_result` frame | 6.11.5, T16, T17 |
| **B5** | One pipeline for four flows: action prompts, `[events]` notices, bot deliveries, task lease wakes | 6.11, T10, T18, T19, T20 |
| **No stop check** | Actions and events wake a user-stopped agent. `stopped_by` is still written by a user stop and still shown | 6.12, T16, T18 |
| **S-A** | One start path for everything. The hub's start-begin (state write, plan check, quota, `run_count`, launch epoch) is used by every start; the bridge's `bridge_runtime_launch_agent` is the only launcher. The task engine's own state write (path B) is deleted and the F14 gaps close | 6.12, T22, T24, T25 |
| **S-B** | `launch_agent` and `wake_agent` merge into one start command. Old bridges keep the old names during rollout, gated by a feature flag | 6.12.6, T23 |
| **S-C** | The bridge fallback (lost shell, title or task-status notice) and bots replace their manifest GET with the same start-begin call: the same number of requests, no new kind of traffic. This supersedes K9 for these callers | 6.12.3, T24 |
| **S-D** | The convergence is done now, as amendment S2, before phase 1 is published | 1.2, 7 |
| **Scale 1 to 5** | Recommendations 1 to 5 of the scaling report are part of this chain: ledger entries live until the delivery expires plus a margin; the relay is woken on commit and publishes in batches; deliveries are pruned on a running hub; schedule fires get a short life; a schedule fire is looked up by its trigger | 6.11.6 (T17), 6.3.4 (T1), 6.11.10 (T16), 6.2.2 (T1, T9), 6.7 (T9, T10) |
| **Lookups** | Every lookup on the event paths is keyed and indexed; no step reads a whole table per event | 6.16, T3, T9, T10, T16 |

**The eight questions of plan v7.** Each default was accepted with the plan. They are decisions, not open questions.

| # | Question | Decided |
|---|---|---|
| v7-Q1 | Old bridges and actions | Actions require a bridge that reports `event_pipeline_v1`. No hub fallback. Such a bridge is not a placement candidate; a target pinned to it fails with `bridge_too_old` |
| v7-Q2 | Start-begin | `POST /api/v1/bridge/agent-instances/<id>/start-begin` replaces the descriptor GET for pipeline starts (6.12) |
| v7-Q3 | Busy agent | Retry with doubling delays for about 15 minutes (8 attempts), then deliver anyway, interrupting as a user message does (6.11.5) |
| v7-Q4 | Task leases and "no stop check" | No change: the task engine still avoids leasing to a user-stopped instance. Phase 3 only swaps the transport |
| v7-Q5 | The user's own chat messages | Stay off the pipeline in this chain. The `prompt` kind is shaped so they can move later |
| v7-Q6 | Bot prompt text and lease packs | They travel inside the delivery message (6.11.2, T19, T20) |
| v7-Q7 | A prompt pinned to an offline machine | Waits 1 hour, then the run is `failed`, `bridge_offline` |
| v7-Q8 | Explainer task `task_18ea45e40ce8fdcb` | Redone after this spec is approved. Not part of any task here |

### 2.1 Decisions that v7 supersedes

| Decision | In v6 | In v7 |
|---|---|---|
| **A4** one wake path | The user-message path on the hub for agents; `Bot_Delivery` for bots | The single wake path is the pipeline: hub route → `HEIM_DELIVER` → bridge executor. A user's own chat message keeps today's direct path |
| **v5-Q3** one hub start procedure | `agent.start_begin` / `start_send` for every start | **Restored by amendment S2 (S-A):** `start_begin` is the one place that opens a run generation, for hub-initiated and bridge-initiated starts alike (6.12). S1 had reduced it to one seam used by the pipeline only |
| **K9** no new bridge → hub messages | Left as it was | The bridge-side start is the normal path. The answer rides on `command_result` with added fields, and start-begin replaces the manifest GET. **Amendment S2 (S-C):** this now holds for every bridge-side start, the notice fallback and bots included; S1 had kept the manifest GET for those callers. No frame type and no other request is added |
| **User-stop gate** (`wake.allowed`) | Every non-manual start refused a user-stopped instance | Removed. Package `wake` is not created. Start-begin clears `stopped_by` |
| **A1** open runs | Open = `queued`, `deferred` | Open = `queued`, `deferred`, `routed` (6.8) |
| **U3** bot busy with a delivery | Prompt skipped | Phase 3: the prompt waits for the bot's open delivery; nothing is skipped (T19) |
| **U5** agent mid-turn | Prompt skipped (`target_busy`) | Delayed retry, then delivered anyway (v7-Q3) |

U1 (a disabled action's open run is skipped when due), U2 (`fresh_per_run` stops the previous instance) and U4 (history limits 200 runs, 30 days) are unchanged.

## 3. Requirements

Section 9 maps each one to tasks and named tests.

**Actions**

| ID | Requirement |
|---|---|
| REQ-ACT-1 | An action is a prompt, a target and 0 to 16 triggers. The schema is section 6.4. There is no data migration |
| REQ-ACT-2 | Trigger kinds are a registry. A test adds a fake kind and shows that the matcher and router sources are untouched |
| REQ-ACT-3 | Producers publish only through `event_outbox`. Package `actions` does not import `taskv2`, `taskchain`, `eventinbox`, `bots`, `agent` or `content`. No producer imports `actions`. An import check is part of the test suite |
| REQ-ACT-4 | The matcher is one durable consumer that starts at "new". Matching is generic. The owner is checked. A per-occurrence guard runs. The message is acknowledged after the commit |
| REQ-ACT-5 | Event triggers exist for `chain.state` and `chain.work_finished`, with a chain filter and a data filter. Prompts support template parameters |
| REQ-ACT-6 | **Changed in v7.** The router checks the action, applies the rate rule, calls `placement.select`, finds or creates the instance row, then runs one transaction that claims the run (`routed`), stores the prompt as a chat message and appends the delivery. The only effect is delivering a prompt |
| REQ-ACT-7 | Every run is recorded with a state and a reason. `GET /api/v1/actions/{id}/runs` returns them. Runs are pruned to 200 per action and 30 days |
| REQ-ACT-8 | One flag gates everything: every route requires the `actions` experiment, and the router re-checks it per run. A bot target also needs the `bots` experiment |
| REQ-ACT-9 | API v2: a nested `target` with `rules[]`, a `triggers[]` list, enable and disable, and `GET /api/v1/actions/trigger-types`. There is no run endpoint |
| REQ-ACT-10 | UI: every action with its triggers; several triggers per action; a placement rule list; the bot target when the server offers it; run history with the v7 states. There is no Run button |
| REQ-ACT-11 | CLI: `create`, `update`, `show`, `list`, `delete`, `runs`, `enable`, `disable`, with repeatable `--trigger` and `--rule`. There is no `run` |
| REQ-ACT-12 | Cleanup: the bridge scheduler and its tests; the hub bridge routes and aliases; snapshot, epoch and lease code; the heartbeat `schedules_*` fields; `run_action_handler`; `vault prune` moves to an ungated probe |
| REQ-ACT-13 | Overlap rules O1 to O4 with deferral; the open set is `queued`, `deferred`, `routed`; test cases C1 to C22 |
| REQ-ACT-14 | Placement rules for action targets as in 6.13 |

**Placement**

| ID | Requirement |
|---|---|
| REQ-PLACE-1 | `src/hub/service/placement` owns candidates, eligibility, rule matching, order and validation. It does not import `agent` |
| REQ-PLACE-2 | There is one eligibility predicate (`bridge_eligible`, `launchable`). A grep test shows that no other code reads bridge status, registry liveness, `plan_disabled_at` or provider/model state to decide a launch |
| REQ-PLACE-3 | Bots, action targets, task leases, instance create, move, relaunch, MCP and the UI defaults call the module. Every row of the inventory in 6.10.9 is carried out |
| REQ-PLACE-4 | Selection is a `Selector`. `first` is the only one built. A test registers a second selector and shows that no caller changed |
| REQ-PLACE-5 | There is one fixed order. Bots keep their results. Each changed behaviour listed in 6.10.4 has a test |
| REQ-PLACE-6 | `GET /api/v1/placement/candidates?agent_id=` returns the ordered candidates. The rule editor and the UI start flows use it and carry no default logic of their own |

**Scheduling**

| ID | Requirement |
|---|---|
| REQ-SCHED-0 | Done (the spike). Its conditions C1 to C6 are acceptance items of T1 and T9 (6.2.5) |
| REQ-SCHED-1 | One shared evaluator in `src/lib/schedule`, with parity tests (`*/1`, day-of-week 7, DST) |
| REQ-SCHED-2 | Schedule definitions are synced on write through the outbox, and reconciled at hub start and on reconnect. There is no periodic loop |
| REQ-SCHED-3 | A schedule fire is matched like any other event, with cause `schedule` |
| REQ-SCHED-4 | nats-server is the only scheduler. An old bridge does not crash and fires nothing |
| REQ-SCHED-5 | A stream guard and a fallback exist for nats-server older than 2.14 |

**Pipeline (hub)**

| ID | Requirement |
|---|---|
| REQ-PIPE-1 | Stream `HEIM_DELIVER`, subject `dlv.<owner>.<bridge_id>.<kind>`, published only through `event_outbox` |
| REQ-PIPE-2 | One durable consumer per capable bridge; one forwarder per such bridge; no timer or polling loop |
| REQ-PIPE-3 | Forward gate on the delivery row (state, expiry, flow validity) before every forward |
| REQ-PIPE-4 | `command_result` → ack, in-progress, delayed nak or term, as in 6.11.5. Result handling is idempotent |
| REQ-PIPE-5 | Start-begin (6.12): one procedure that clears `stopped_by`, sets `launching`, the epoch and `run_count + 1`, reserves quota and returns the launch command; idempotent per start reference; it is the procedure of REQ-ONE-1. No hub code in the pipeline reads `stopped_by`; a source scan test enforces it |
| REQ-PIPE-6 | Offline rules OFF-1 to OFF-5 and OFF-2b (6.11.7), each with a test |
| REQ-PIPE-7 | Exhausted deliveries are closed from the max-deliveries advisory |
| REQ-PIPE-8 | Feature `event_pipeline_v1`: a placement requirement for actions; a per-flow switch for notices, bots and leases |
| REQ-PIPE-9 | Package `delivery` imports no flow package (`actions`, `eventinbox`, `bots`, `taskv2`); flows register a `Sink` by `kind` |
| REQ-PIPE-10 | `forwarded` is committed before the frame is sent; only `routed` deliveries are ever placed again on a disconnect |

**Bridge**

| ID | Requirement |
|---|---|
| REQ-BRG-1 | `event_deliver` handler with the decision table of 6.11.6; no stop check |
| REQ-BRG-2 | Persistent dedupe ledger: an entry lives until its delivery's `expires_at` plus a margin of 10 minutes (REQ-SCALE-1), and survives a restart; `in_progress` before the effect, `done` before the reply; an `in_progress` entry without a live worker is decided again from the process table; a full ledger answers `retry` |
| REQ-BRG-3 | Starts go through the existing wake gate, the start-begin call and `bridge_runtime_launch_agent`; no second launch path; never generation 0. Amendment S2 extends this from pipeline starts to every bridge-side start (REQ-ONE-4) |
| REQ-BRG-4 | Answers use `command_result` with `outcome`, `class`, `retry_after_ms`; a `final` attempt always ends with a terminal answer, never with `retry` |
| REQ-BRG-5 | No NATS client and no new frame type on the bridge for the pipeline. The only new request is start-begin, in place of the manifest GET. (The start command of REQ-ONE-6 replaces two existing command types; it is not pipeline traffic) |

**Flows**

| ID | Requirement |
|---|---|
| REQ-FLOW-1 | (phase 2) `[events]` notices are `event_notice` chat messages routed as `kind = notice`; inbox timing unchanged (30 s cooldown, 5 s back-off); the five `stopped_by` reads are deleted |
| REQ-FLOW-2 | (phase 3) Bot deliveries and the `bot` action target use `kind = bot`; the bot supervisor still decides rounds and moves; the resend-on-reconnect code is skipped for capable bridges |
| REQ-FLOW-3 | (phase 3) Task lease wakes use `kind = lease`, appended in the grant transaction; redelivery on reconnect is skipped for capable bridges; nudge and confirmation behave as today; the generation is opened by `start_begin` in the grant (REQ-ONE-3) |
| REQ-FLOW-4 | Bridges without the feature keep today's path for each flow |

**One start path (amendment S2)**

| ID | Requirement |
|---|---|
| REQ-ONE-1 | One hub procedure, `start_begin`, opens every run generation: it alone writes `launching` for a start, bumps `run_count` and mints the launch epoch, after the plan, live-connection, provider and quota checks. A source scan test with a named allow-list enforces it (6.12.7) |
| REQ-ONE-2 | Every hub-initiated start outside the task engine (manual Start and Restart, new instance, chat message, coordinator wake, MCP, solo recovery, fleet change, reconfigure, the event inbox start) is a thin caller of it. Command bytes, error codes and HTTP statuses do not change |
| REQ-ONE-3 | Task lease dispatch calls `start_begin` inside the grant's unit of work; its own state write is deleted; a just-created instance starts with generation 1; the three gaps of finding F14 are closed, each with a test |
| REQ-ONE-4 | Every bridge-initiated start (pipeline delivery, notice fallback, bot delivery) calls start-begin before it launches. Against a hub that announces start-begin (`bridge_ready`), no launch from a manifest and no launch with generation 0 is left; against an older hub the bridge keeps today's manifest path, so no deploy order is required |
| REQ-ONE-5 | `bridge_runtime_launch_agent` is the only function that starts an agent process and has exactly two callers (6.12.3). It receives the launch command the hub wrote, unchanged |
| REQ-ONE-6 | One start command, `start_agent`, behind the feature `start_agent_v1`. A bridge without the feature receives `launch_agent` and `wake_agent` with unchanged bytes; a bridge with it still accepts both from an older hub |
| REQ-ONE-7 | Every case in which an agent cannot be launched (6.12.8, L1 to L23) has one defined result and a named test or E2E row |

**Scale and lookups (amendment S2)**

| ID | Requirement |
|---|---|
| REQ-SCALE-1 | A bridge ledger entry is kept until its delivery's `expires_at` plus `BRIDGE_LEDGER_MARGIN_MS` (10 minutes), not for a flat 48 hours. A redelivery inside that time has no second effect, also when the bridge's clock is ahead of the hub's by less than the margin |
| REQ-SCALE-2 | The relay is woken when a transaction that appended an outbox row commits, and publishes up to 64 rows per pass in `outbox_seq` order. The 1 s idle wait stays only as a fallback |
| REQ-SCALE-3 | `delivery.prune` also runs on a hub that stays up: when a delivery becomes final, at most once per hour. Its rule is unchanged (closed rows older than 30 days) and it reads an index |
| REQ-SCALE-4 | Schedule fires and deferral fires live at most 24 hours in `HEIM_EVENTS`, instead of 14 days |
| REQ-SCALE-5 | The matcher finds the trigger of a schedule fire through an index on the fire's subject; it does not load the user's other schedule triggers |
| REQ-LOOKUP-1 | Every lookup on the event paths is by primary key, by a named index or by a subject filter (6.16). A query-plan test enforces it |

**Rollout**

| ID | Requirement |
|---|---|
| REQ-DEPLOY-1 | Sync with `origin/main`. Hub first, then bridges. Mundus is deployed through a change request to `inst_18e8ba2e9e2c4e69`, stated as forward-only. E2E runs there. Brolabs is deployed only with the user's explicit OK |

**Removed from v6:** REQ-START-1 to 5 and REQ-WAKE-1 to 9. Do not implement them. REQ-ONE-1 to 7 take the place of REQ-START-1 to 5; the user-stop gate of REQ-WAKE stays removed.

## 4. What the code does today

These findings shape the design. F1 to F22 come from the v6 spec and were re-located at `f56f13e1`. V1 to V17 are the v7 findings; V12 to V17 were found while writing this spec.

| # | Finding | Consequence |
|---|---|---|
| F1 | "Chain completed" is already published. `catalog_chain_state` (`src/hub/service/taskv2/catalog.odin:95`) emits `chain.state` with `data.state` = `active`, `completed` or `archived`. `catalog_work_finished` (`src/hub/service/taskv2/catalog.odin:234`) emits `chain.work_finished` with `data.outcome` | No new producer is needed for the event triggers |
| F2 | `chain.state` carries the header `Nats-Rollup: sub` (`src/hub/service/taskv2/catalog.odin:65`), so the stream keeps only the newest state per chain | Accepted by the user (Q4). A hub that was down sees only the last state |
| F3 | The relay publishes `row.subject` with the headers of `row.headers_json` and passes `row.event_id` as the message id (`src/hub/service/eventrelay/relay.odin:131`) | A schedule definition and a delivery are ordinary outbox rows. `Nats-Msg-Id` is the row's `event_id` |
| F4 | Event envelopes hold ids and enums only (`docs/plans/events-jetstream-spec.md:26`). Action prompts are plain text in SQLite | The prompt never enters an event envelope or a `prompt` delivery. The router renders it from SQLite |
| F5 | The user-message path for an agent is: `send_chat_message_handler` (`src/hub/transport/http/content_handlers.odin:200`) → `restart_stopped_conversation_instance` (`src/hub/transport/http/content_handlers.odin:371`) → `send_message` (`src/hub/service/content/content_service.odin:245`), which is `persist_user_message` (`src/hub/service/content/user_message.odin:11`) plus `deliver_user_message` (`src/hub/service/content/user_message.odin:31`). An agent that was just started gets its first unread message again from `agent_action_start_success_handler` (`src/hub/transport/http/agent_action_handlers.odin:1326`) | The pipeline reuses `persist_user_message` and the start-success step. It does not use `deliver_user_message` |
| F6 | The user-message path for a bot is: `delivery_on_inbound` (`src/hub/service/bots/inbound.odin:88`) → `bots_delivery_on_inbound_locked` (`src/hub/service/bots/inbound.odin:101`) → `bots_dispatch_locked` (`src/hub/service/bots/supervisor.odin:78`) → frame `bot_deliver` → `bridge_bot_run` (`src/bridge/bot_delivery.odin:199`) | T19 moves the frame onto the pipeline; the supervisor stays |
| F7 | The event inbox uses neither path. `event_inbox_notice` (`src/hub/app/wiring.odin:1357`) calls `start_instance` with its own guard (`src/hub/app/wiring.odin:1406`) for a stopped target, or sends an `events` nudge command for an idle one | T18 |
| F8 | No bots code reads or clears `stopped_by`. A user message relaunches a user-stopped bot without clearing the stop | Closed by the general rule of 6.12 for pipeline starts |
| F9 | `ham-bridge vault prune --remove` probes `GET /api/v1/bridge/actions` (`src/bridge/vault_prune.odin:113`) and reads 401 or 403 as "token dead" (`src/bridge/vault_prune.odin:29`). That route answers 403 when the owner has Actions off. **Assumption** (code reading, not run): a live bridge is classified `Dead` | Fixed in T8 |
| F10 | The NATS wrapper hard-codes `js_DeliverAll` (`src/lib/nats/adapter.c:109`). `Consumer_Config` (`src/lib/nats/nats.odin:44`) has no deliver policy | The matcher's consumer must start at "new". T1 adds the option |
| F11 | Placement rules and wildcards exist only for bots (`src/hub/service/bots/placement.odin:18`). Every other caller is handed one fixed bridge, provider and model. The hub has two more choosers: the task bridge fallback (`resolve_placement`, `src/hub/service/taskv2/matcher.odin:160`) and the default provider and model (`resolve_launch_model`, `src/hub/service/taskv2/placement.odin:26`). The UI picks defaults by itself (`src/ui/components/chat/NewConversationPage.tsx:235`) | One module (6.10) |
| F12 | About six eligibility checks have drifted apart (table in 6.10.2). Examples: task leases do not check for a live connection (`bridge_online`, `src/hub/service/taskv2/lease.odin:1104`); bots do not check that the catalog provider is active; only bots accept a model alias. `validate_launchable` (`src/hub/service/provider/provider_service.odin:217`) duplicates `validate_provider_model_intersection` (`src/hub/service/agent/agent_service.odin:1635`). `select_bridge_for_agent` (`src/hub/service/agent/agent_service.odin:1658`) and `require_enabled_support` (`src/hub/service/agent/agent_service.odin:1529`) have no callers | One predicate (6.10.2) |
| F13 | The hub has several start implementations. `restart_instance` (`src/hub/service/agent/agent_service.odin:878`) and `start_instance` (`src/hub/service/agent/agent_service.odin:901`) share `relaunch_instance_locked` (`src/hub/service/agent/agent_service.odin:1126`). Task lease dispatch does not: `grant_attempt_in_uow` (`src/hub/service/taskv2/lease.odin:77`) sets `launching` and bumps `run_count` itself (`src/hub/service/taskv2/lease.odin:231`) and sends `wake_agent` after the commit (`flush_wakes`, `src/hub/service/taskv2/wake.odin:146`). Bots and bridge-local wakes launch on the bridge | **Converged by amendment S2** (6.12): `start_begin` is that database half, and every start uses it |
| F14 | Three gaps (**Assumption**: code readings, not reproduced). (a) An explicit lease claim can launch a user-stopped instance without clearing the stop: `lease_claim_in_uow` (`src/hub/service/taskv2/explicit_claims.odin:32`) and `lease_transfer_in_uow` (`src/hub/service/taskv2/explicit_claims.odin:120`) have no `stopped_by` check. (b) The coordinator wake checks `stopped_by` (`src/hub/transport/http/coordinator_wake.odin:288`) and then calls a restart that clears it (`src/hub/transport/http/coordinator_wake.odin:299`), with no guard in between. (c) An instance created for a task lease has `run_count` bumped twice | **Closed by amendment S2**: (a) and (c) by T25, (b) by T22 (6.12.7) |
| F15 | The NATS wrapper exposes no message timestamp. `Metadata` (`src/lib/nats/nats.odin:23`) has sequences only, and `ham_nats_metadata` (`src/lib/nats/adapter.c:173`) does not copy the time | The matcher needs the stream time (6.7 step 5, 6.6.2). T1 adds it |
| F16 | `upgrade_scheduled_prompts_schema` (`src/hub/repository/sqlite/migrations.odin:2010`) and `upgrade_actions_schema` (`src/hub/repository/sqlite/migrations.odin:2031`) run on every hub start (`src/hub/repository/sqlite/migrations.odin:1486`). They re-create `scheduled_prompts` and create indexes on old `actions` columns | They would break the new schema. T9 MUST delete both procedures and both calls |
| F17 | The bots order across bridges is: best rule rank first, and bridge age only as the tie-break (`bots_select_bridge`, `src/hub/service/bots/placement.odin:114`; `bots_rank_before`, `src/hub/service/bots/placement.odin:55`) | The spec uses the order the code has, so bot results do not change (6.10.3) |
| F18 | `restart_instance` clears the user stop and saves before it takes any lock (`clear_user_stop`, `src/hub/service/agent/agent_service.odin:888`). `start_instance` clears it under `reconfiguration_mutex` (`src/hub/service/agent/agent_service.odin:912`). `relaunch_instance_locked` sends the launch while holding that mutex, with no transaction open | Start-begin follows `start_instance`: clear under the mutex, then the database half (6.12) |
| F19 | The message type `action` already exists, with a UI card (`src/ui/components/workbench/AgentChatPane.tsx:2137`). It is sent today by `run_action_handler` (`src/hub/transport/http/action_handlers.odin:512`) and `bridge_execute_action_handler` (`src/hub/transport/http/action_handlers.odin:650`). `chat_messages.message_type` has no CHECK constraint | Action prompts keep `message_type = "action"`. The new type `event_notice` needs no schema change |
| F20 | `action_scheduler_format_rfc3339_utc` (`src/bridge/action_scheduler.odin:117`) is called from bridge files that have nothing to do with actions | T8 moves and renames it before deleting the scheduler |
| F21 | The relay never skips a row. If a publish fails, it retries the same row forever (`step_inner`, `src/hub/service/eventrelay/relay.odin:93`). The next row is always the oldest unpublished one (`src/hub/repository/sqlite/event_outbox_repo.odin:54`) | A rejected schedule definition, or a `dlv.` row with no stream behind it, would block every event. T1 adds poison handling for definition rows and creates `HEIM_DELIVER` in the same connect block as `HEIM_EVENTS` (6.3.6) |
| F22 | `SELF_HOSTING.md` names no minimum nats-server version, and its container example pins `nats:2.11` (`SELF_HOSTING.md:378`) | T14 updates it to 2.14 or newer |
| V1 | The hub → bridge link is one WebSocket per bridge. Commands are JSON frames with `type` and `command_id` (`src/hub/service/project/project_service.odin:32`). `bridge_command_send_runtime` (`src/hub/service/project/project_service.odin:82`) returns as soon as the socket write is done; it fails at once for an offline bridge (`src/hub/service/bridge_runtime/bridge_runtime.odin:66`). Nothing is queued | JetStream supplies the durability; the link is only the last hop |
| V2 | The bridge answers every command with `command_result` = `{command_id, ok, error, payload.status}`, status `accepted`, `succeeded` or `failed` (`src/bridge/hub_runtime_client.odin:4360`, `src/bridge/hub_runtime_client.odin:4380`). The hub fans the frame out with a hard-coded if-chain (`src/hub/transport/http/bridge_handlers.odin:2552`, `src/hub/transport/http/bridge_handlers.odin:2556`) | The answer of B4 rides on an existing frame. The delivery service adds one line to that chain |
| V3 | The bridge can already start an instance by itself: `bridge_task_wake_if_needed` (`src/bridge/agent_wake.odin:205`) checks its process table, applies coalescing, back-off and parking (`src/bridge/agent_wake.odin:111`), fetches the launch descriptor with `GET /api/v1/bridge/agent-instances/<id>/bootstrap` (`src/bridge/agent_wake.odin:299`; route at `src/hub/app/wiring.odin:1135`) and calls the one bridge launch function `bridge_runtime_launch_agent` (`src/bridge/hub_runtime_client.odin:2749`) | The bridge already has one start procedure. The executor reuses its gate and its launch |
| V4 | The bridge has no user-stop state: `stopped_by` appears nowhere in `src/bridge`. Only a 15 s stop-intent mark exists (`src/bridge/hub_runtime_client.odin:115`), and a launch clears it | "No stop check" is what the bridge does today |
| V5 | For a chat message the bridge never receives the text. `notify_agent_message` carries ids (`src/bridge/hub_runtime_client.odin:1210`); the bridge types `New message from <sender> — run 'ham-ctl chat read'` (`src/bridge/pty_host_runtime.odin:744`). After a start, the hub re-sends the notice for the first unread `user_to_agent` message (`src/hub/transport/http/agent_action_handlers.odin:1387`) | A `prompt` delivery needs ids only. A freshly started agent finds the prompt through the start-success step |
| V6 | Bots already split work the v7 way: the hub prepares the row, cancels the reservation because "bot_deliver performs launch locally" (`src/hub/service/bots/supervisor.odin:104`, `src/hub/service/bots/supervisor.odin:109`), and the bridge launches from the descriptor (`src/bridge/bot_delivery.odin:77`). The hub learns the state from `agent_instance_status` frames (`src/hub/transport/http/bridge_handlers.odin:2490`) | The hub/bridge split for starts has a working precedent |
| V7 | The NATS wrapper exposes `ack`, `nak`, `term`, `ack_reply` and `message_reply` (`src/lib/nats/nats.odin:324`, `src/lib/nats/nats.odin:330`). It hard-codes limits retention (`src/lib/nats/adapter.c:83`) and exposes no delayed nak, in-progress, `MaxAckPending` or message delete | T1 adds them (6.3.5). All of them were proven against the flake's nats-server (10.2) |
| V8 | Bridges report features in `bridge_hello.features` from one list (`src/bridge/hub_runtime_client.odin:4616`); the hub stores the hello in `bridges.capabilities_json` and checks it with `bridge_feature_supported` (`src/hub/service/agent/instance_reconfiguration.odin:56`). Bots gate on `bot_deliver_v1` the same way (`src/hub/service/bots/placement.odin:110`) | Version gating uses this mechanism |
| V9 | The hub consumes JetStream "max deliveries" advisories for `HEIM_EVENTS` with one stream and one consumer (`src/hub/service/eventinbox/runtime.odin:30`, `src/hub/service/eventinbox/runtime.odin:31`). Its drain drops every advisory of another stream | The delivery service gets its own advisory stream and consumer (6.11.8); the inbox code is not touched |
| V10 | The `[events]` inbox reads `stopped_by` in five places (`src/hub/service/eventinbox/notifications.odin:186`, `src/hub/service/eventinbox/notifications.odin:282`, `src/hub/app/wiring.odin:1367`, `src/hub/app/wiring.odin:1412`, `src/hub/repository/sqlite/event_subscription_repo.odin:362`) | Removed in T18 |
| V11 | The hub refuses an agent's `start-success` unless the generation is already committed: a missing or zero `run_count` is refused once the row's count is above 1 (`src/hub/transport/http/agent_action_handlers.odin:1338`), and a row whose status is `stopped`, `stopping` or `failed` is refused (`src/hub/service/agent/agent_service.odin:582`) | The hub must set `launching` and the new generation before the process starts. That is start-begin |
| V12 | A table `event_deliveries` already exists (`src/hub/repository/sqlite/migrations/events_004_delivery.sql:3`), with the domain type `Event_Delivery` (`src/hub/domain/event_subscription.odin:22`). It holds the inbox's ack receipts | The pipeline's table is named `pipeline_deliveries` (deviation D1) |
| V13 | The bridge dispatcher remembers each `command_id` and does not run a handler twice for the same id: it resends the cached terminal frame (`src/bridge/hub_command_dispatch.odin:584`). It also sends `accepted` by itself when it queues a command (`src/bridge/hub_command_dispatch.odin:634`) | The frame's `command_id` must differ per attempt: `<delivery_id>:<attempt>` (deviation D2). Every attempt is answered `accepted` first, by the dispatcher |
| V14 | `payload.result` of `command_result` is a typed struct with three fields (`src/bridge/hub_runtime_client.odin:4337`), not a free-form object, and its constructor is file-private (`src/bridge/hub_runtime_client.odin:4373`) | T17 adds three `omitempty` fields to that struct and a builder in the same file |
| V15 | `bridge_task_wake_if_needed` returns one bool. Already running, coalesced, backing off, parked and failed all return false | T17 splits out a variant that returns the decision and the error class |
| V16 | The bootstrap manifest carries no `run_count` (`src/hub/service/agent/agent_service.odin:2244`). Only the launch command does (`src/hub/service/agent/agent_service.odin:1822`). The wake path therefore launches with generation 0 (`src/bridge/hub_runtime_client.odin:2690`) | Start-begin returns the launch command of `launch_command_json_full` (`src/hub/service/agent/agent_service.odin:1781`), not the manifest |
| V17 | A launch reservation is an in-memory entry of the bridge's live connection. It expires after one minute (`src/hub/service/project/runtime_registry.odin:673`, `src/hub/service/project/runtime_registry.odin:622`), is dropped on disconnect, and is consumed or released by the first status frame that passes the epoch and sequence checks (`src/hub/service/agent/agent_service.odin:1190`, `src/hub/service/project/runtime_registry.odin:659`). No instance row can be created stopped: `prepare_instance` always writes `launching` (`src/hub/service/agent/agent_service.odin:386`) | A reservation taken at start-begin cannot leak (10.2). T16 adds `create_instance_stopped` (6.12.5) |
| S1 | (amendment S2, read at `99879b7b`) On the bridge, `bridge_runtime_launch_agent` already starts every agent process. It has five call sites: the `launch_agent` handler (`src/bridge/hub_runtime_client.odin:1145`), two in the `wake_agent` handler (`src/bridge/hub_runtime_client.odin:2576`, `src/bridge/hub_runtime_client.odin:2594`), the notice fallback (`src/bridge/agent_wake.odin:250`) and the bot launch (`src/bridge/bot_delivery.odin:87`). Three of them build the launch command on the bridge | "One launcher" needs no new launch code. What changes is where the launch command comes from (6.12.3) |
| S2 | `agent.stop_instance` holds `reconfiguration_mutex` while it calls into `taskv2` (`src/hub/service/taskv2/coordinator_wake.odin:15`). The grant runs inside the task engine's unit of work | The grant cannot take that mutex without inverting the lock order. `start_begin` takes no lock itself (6.12.2) |
| S3 | The task engine already calls into the agent service inside a grant, without the mutex: `jit_prepare` calls `prepare_instance` (`src/hub/service/taskv2/matcher.odin:449`) and keeps the reservation in its effects list for a rollback | The pattern T25 uses for `start_begin` exists and is in production |
| S4 | Path B checks neither the bridge's plan, nor its live connection (`bridge_online` reads the row's status only, `src/hub/service/taskv2/lease.odin:119`), nor the launch quota for an existing instance. Path C asks the hub nothing | Cases L6 to L8 of 6.12.8: a lease or a fallback can start an agent that a manual Start would refuse |
| S5 | The relay sleeps up to 1 s when its last pass published nothing, and publishes one row per pass (`src/hub/service/eventrelay/relay.odin:72`). An action passes the relay twice (the event, then the delivery) | Up to 2 s of added delay per action. REQ-SCALE-2 |
| S6 | `triggers_match(owner, "schedule.fired")` returns every enabled schedule trigger of the user; the subject filter is applied in memory (6.7 step 5) | A fire costs O(schedule triggers of the user). REQ-SCALE-5 |

## 5. Architecture

```
WHAT / WHEN  (hub + JetStream)
  producers ──outbox──► HEIM_EVENTS  ev.<owner>.…        (chain events, schedule fires, deferral fires)
                         │ durable consumer "hub_action_matcher", filter ev.>, starts at "new"
                         ▼
  MATCHER   event → triggers → guard → INSERT action_runs (queued | joined | skipped) → commit → ack

WHERE  (hub)
  ROUTER    action checks → rate rule (route or defer) → placement.select → find or create the instance row
            └─ ONE transaction: claim run (routed) + chat message (the prompt) + pipeline_deliveries row + outbox row
                         │ relay (existing)
                         ▼
            HEIM_DELIVER  dlv.<owner>.<bridge_id>.<kind>      kind = prompt | notice | bot | lease
                         │ one durable consumer per bridge: "brg_<bridge_id>", filter dlv.*.<bridge_id>.>
                         ▼
  FORWARDER (hub, one thread per capable bridge)  gate on the delivery row → commit "forwarded"
                         │ frame "event_deliver" over the WebSocket
                         ▼
ACT  (bridge; no NATS)
  EXECUTOR  ledger by delivery_id → look at the local process table
              running, idle  → type the notice                              → succeeded (notified)
              running, busy  → nothing                                      → failed, class retry
              not running    → start-begin on the hub, launch (no stop check) → succeeded (started)
                         │ command_result (existing frame)
                         ▼
RESULT (hub)  accepted  → JetStream in-progress
              succeeded → delivery done → Sink (run delivered) → JetStream ack
              retry     → JetStream nak with delay
              fatal     → place again or delivery failed → Sink (run failed) → JetStream term
```

### 5.1 Who owns what

| Concern | Hub + JetStream | Bridge |
|---|---|---|
| Triggers, schedules, timers, deferral | all of it | nothing (the bridge scheduler is deleted, R2) |
| Overlap and rate rules (A1, v5-Q2) | all of it | nothing |
| Which bridge, provider and model (A2, A5, B2) | `service/placement`, at route time | a local check that the provider binary really runs (`bridge_provider_runnable`, `src/bridge/agent_wake.odin:146`, kept) |
| Instance rows, conversations, the prompt as a chat message | all of it | nothing |
| Plan and quota checks | placement at route time; again in `start_begin`, for **every** start (S2) | nothing |
| Is the agent running, idle or busy right now | not consulted | decides from its process table |
| Run generation (`run_count`), launch epoch, `launching` status | allocated at start-begin, before the launch | uses what the hub returned |
| Starting the process | nothing | `bridge_runtime_launch_agent`, the single launch function, always from a launch command the hub wrote in `start_begin` (S2) |
| Typing the notice | nothing | as today |
| Retry timing | JetStream (AckWait, delayed nak, MaxDeliver) | may ask for a longer delay |

### 5.2 Packages

| Package | New? | Contents | Created or changed by |
|---|---|---|---|
| `src/lib/nats` | changed | stream flags, `deliver_new`, message time, subject purge, version check; retention, `max_ack_pending`, reply-subject acks, message delete | T1 |
| `src/lib/schedule` | new | pure cron, interval, blackout and window evaluator; `nats_cron` | T2 |
| `src/hub/service/placement` | new | rules, candidates, eligibility, order, validation, `Selector` | T3 |
| `src/hub/service/eventrelay` | changed | stream configs for both streams, purge rows, poison handling | T1 |
| `src/hub/service/delivery` | new | `route`, forwarders, result handling, offline rules, advisory handling, `Sink` registry | T16 |
| `src/contracts/delivery_wire.odin` | new | frame, delivery body, result fields, feature constant | T16 |
| `src/hub/service/agent` | changed | `start_begin.odin`: `start_begin`, `start`, `start_send`, `start_settle`, `start_cancel`, `start_begin_for_bridge`, `create_instance_stopped` (T22); `start_command.odin`: the one start command (T23) | T22, T23 |
| `src/contracts/start_wire.odin` | new | the `start_agent` frame name, the feature constant, the `deliver` values | T23 |
| `src/hub/service/actions` | new | `triggers.odin`, `schedule_sync.odin`, `template.odin` (T9); `matcher.odin`, `router.odin`, `runtime.odin` (T10) | T9, T10 |
| `src/bridge` | changed | `event_executor.odin`, `event_ledger.odin` (T17); `start_agent.odin` (T23); the manifest launch is deleted (T24); the scheduler is deleted (T8) | T8, T17, T23, T24 |
| `src/hub/service/eventinbox`, `bots`, `taskv2` | changed | each routes its flow through `delivery` for capable bridges; `taskv2` and `bots` start instances through `start_begin` (T25, T24) | T18, T19, T20, T24, T25 |

### 5.3 Import rules (MUST hold after every task)

| Package | MUST NOT import |
|---|---|
| `src/lib/schedule` | anything outside `core:` |
| `src/hub/service/placement` | `agent`, `bots`, `taskv2`, `taskchain`, `actions`, `content`, `delivery`. It imports `hub/domain`, `hub/repository/iface`, `hub/service/provider`, `hub/service/project`, `lib/jsonx`, `contracts` |
| `src/hub/service/delivery` | `actions`, `eventinbox`, `bots`, `taskv2`, `taskchain`, `agent`, `content`. It imports `hub/domain`, `hub/platform`, `hub/repository/iface`, `hub/service/project`, `lib/nats`, `lib/jsonx`, `contracts` |
| `src/hub/service/actions` | `taskv2`, `taskchain`, `eventinbox`, `bots`, `agent`, `content`. It imports `hub/domain`, `hub/platform`, `hub/repository/iface`, `hub/service/placement`, `hub/service/delivery`, `lib/nats`, `lib/schedule`, `lib/jsonx`, `contracts` |
| every producer (`taskv2`, `taskchain`) | `actions` |
| `src/hub/service/eventinbox` | `content`, `agent`, `delivery` (it reaches them through the callback filled at wiring, as today) |
| `src/bridge` | `lib/nats` |

Package `actions` reaches the agent service and the content service only through `Agent_Port` (6.13.2). It is filled in `src/hub/app/wiring.odin`.

The boundary tests that enforce these rules scan source files. Use `src/hub/app/thread_spawn_guard_test.odin:22` as the model for a test that walks the source tree.

## 6. Shared contracts

Each contract is defined once here. A task section names the contracts it implements. If a task needs to change a contract, it MUST stop and ask the coordinator, because other tasks build against the same text.

### 6.1 Odin rules for every task

**Tests**

- Run tests inside the flake shell, with the pinned Odin: `nix develop -c odin test <package-dir> -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/<unique-name>`. Never build test binaries under `/tmp`.
- To run one test, add `-define:ODIN_TEST_NAMES=<package>.<test_proc>` (comma-separated for several). Read the exact procedure name from the source first. Odin exits 0 with "No tests to run" when the name is wrong, so check that the reported test count is not zero, and report that count at hand-off.
- Every new test file wraps its scenarios in a tracking allocator and asserts that nothing is left allocated. Copy the pattern from `src/hub/service/eventinbox/service_test.odin` (`mem.tracking_allocator_init`, run the scenario, `testing.expect_value(t, len(track.allocation_map), 0)`).
- Tests that need NATS start a real server with `natstest.start` (`src/lib/natstest/server.odin:17`). `nats-server` is on `PATH` inside `nix develop`. A test that uses NATS ends with `nats.shutdown(5000)`.
- Tests that need SQLite open `:memory:`, call `sqlite.run_migrations`, and build an `iface.Repositories` value and a `sqlite.new_unit_of_work_factory` inline. There is no shared helper.
- The Nix checks `nats` and `events-relay` (`flake.nix:429`) run their packages under valgrind. A new package that links NATS gets the same treatment (T10).

**Transactions**

- A unit of work is `iface.unit_of_work_begin(factory)` (`src/hub/repository/iface/unit_of_work.odin:46`), then `iface.unit_of_work_commit(&uow)` or `iface.unit_of_work_rollback(&uow)`. There is no "run in transaction" helper. Use `defer if uow.ctx != nil do iface.unit_of_work_rollback(&uow)` right after a successful begin, as `src/hub/service/bots/supervisor.odin` does.
- Inside a unit of work, reach repositories through `uow.repos` (`src/hub/repository/iface/unit_of_work.odin:22`). All repositories share one SQLite connection (`src/hub/repository/sqlite/tx.odin:92`), so a service procedure that uses its own repository pointers also takes part in the transaction that is open on the calling thread.
- **No network I/O inside a unit of work.** That means no NATS call and no bridge command. Schedule sync and deferral only append `event_outbox` rows. `delivery.route` (6.11.3) only appends rows. Start-begin (6.12) writes rows and reserves quota in memory. A bridge command and a JetStream ack, nak or term are sent after the commit.

**Memory**

- A long-lived worker thread follows `eventrelay.entry` (`src/hub/service/eventrelay/relay.odin:55`): it creates a growing `virtual.Arena`, uses it as `context.allocator` and `context.temp_allocator`, and calls `free_all(context.allocator)` after every pass. Whatever must outlive a pass is written to SQLite before the pass ends.
- Before spawning a thread, set `context.allocator = runtime.heap_allocator()`, as `eventrelay.start` does (`src/hub/service/eventrelay/relay.odin:32`). The test in `src/hub/app/thread_spawn_guard_test.odin:22` fails the build otherwise.
- Long-lived state (service structs, cloned option strings) uses `runtime.heap_allocator()` and is freed in the service's `stop`.
- `platform.generate_id` (`src/hub/platform/ids.odin:13`) returns temporary-allocator storage. Clone the id if it must outlive the current temporary scope.
- Each interface below states who owns what it returns. Where nothing is stated, a returned string or slice is allocated in `context.allocator` and the caller frees it.
- Every fetched NATS batch is destroyed with `nats.batch_destroy` (`src/lib/nats/nats.odin:255`) on every path. Strings read from a message are views that die with the batch.

### 6.2 Subjects, headers and schedule definitions

#### 6.2.1 Subjects

All subjects live in the stream `HEIM_EVENTS`.

| Purpose | Subject | Published by |
|---|---|---|
| Existing chain events | `ev.<owner>.chain.<chain>.state`, `ev.<owner>.chain.<chain>.work_finished`, and the task subjects | `catalog_emit` (`src/hub/service/taskv2/catalog.odin:13`), unchanged |
| Schedule definition | `sched.def.<trigger_id>` | schedule sync (6.6.2), through the outbox |
| Schedule fire | `ev.<owner>.sched.<trigger_id>` | nats-server |
| Deferral definition (one-shot) | `sched.def.defer.<action_id>` | the router (6.8.3), through the outbox |
| Deferral fire | `ev.<owner>.action.<action_id>.resume` | nats-server |

`<owner>`, `<trigger_id>` and `<action_id>` MUST pass `nats.subject_token` (6.3.1) before they are put into a subject. Definitions sit outside `ev.>` so that no event consumer receives them. They sit in the same stream because nats-server requires the target of a schedule to be a subject of the same stream.

#### 6.2.2 Schedule definition row

A definition is one `event_outbox` row (`src/hub/domain/event_outbox.odin:5`), appended with `uow.repos.event_outbox.append` (`src/hub/repository/iface/event_outbox_repo.odin:22`) in the transaction that saves the trigger.

| Column | Value |
|---|---|
| `event_id` | `platform.generate_id(ids, "evt_")`. The relay sends it as `Nats-Msg-Id`, so it is unique per row |
| `owner_user_id` | the action's owner |
| `subject` | `sched.def.<trigger_id>` |
| `headers_json` | the object below |
| `envelope_json` | `{"event_id":"<event_id>","type":"schedule.fired","class":"occurrence","owner_user_id":"<owner>","action_id":"<action_id>","trigger_id":"<trigger_id>","data":{"rev":<rev>}}` |
| `created_at` | `platform.clock_now(clock)` |

Headers:

| Header | Value | When |
|---|---|---|
| `Nats-Schedule` | Mode `cron`: the output of `schedule.nats_cron` (6 fields, 6.2.4). Mode `interval`: `@every <n>s`. Mode `once`: `@at <RFC3339 UTC, suffix Z>` | always |
| `Nats-Schedule-Target` | `ev.<owner>.sched.<trigger_id>` | always |
| `Nats-Schedule-Time-Zone` | the IANA zone name | mode `cron` only, and only when the zone is not `UTC` and not empty. nats-server rejects this header with `@every` and `@at`, and rejects an empty value |
| `Nats-TTL` | `never` | always. Without it the definition ages out of the stream after 14 days and the schedule silently stops |
| `Nats-Schedule-TTL` | `24h` (`SCHEDULE_FIRE_TTL`) | always (amendment S2, REQ-SCALE-4). nats-server puts this value on each fire as its `Nats-TTL`, so a fire leaves the stream after 24 hours instead of 14 days. Only the matcher reads fires, once. A hub that is down for more than 24 hours does not see the fires of the time before that (risk S-K8). **Assumption:** nats-server 2.14.7 honours this header on scheduled messages. T1 verifies it first (`scenario_schedule_fire_ttl`); the fallback is in 6.3.4 |
| `Heim-Trigger-Rev` | the trigger's `rev` as a decimal string | always |

nats-server copies the body and every non-reserved header (here `Heim-Trigger-Rev`) onto each fire, and adds `Nats-Schedule-Next` (the next fire time, or the literal `purge` for a one-shot) and `Nats-Scheduler` (the definition subject). It strips `Nats-Msg-Id`, so a fire has no server-side dedup; the matcher's `occurrence_key` does that job (6.7).

Republishing a definition on the same subject replaces it. Republishing an **unchanged** `@every` definition restarts its interval from the publish time, so a definition is published only when it is new or changed.

#### 6.2.3 Purge row and deferral row

**Purge row** (stop a schedule): an outbox row with `subject = sched.def.<trigger_id>`, `headers_json = {"Heim-Op":"purge"}` and `envelope_json = {"event_id":"<event_id>","type":"schedule.purge","class":"occurrence","owner_user_id":"<owner>","trigger_id":"<trigger_id>","data":{}}`. The relay does not publish it. It purges the subject instead (6.3.4).

**Deferral row** (wake the hub once, 6.8.3): `subject = sched.def.defer.<action_id>`, headers `{"Nats-Schedule":"@at <not_before, RFC3339 UTC>","Nats-Schedule-Target":"ev.<owner>.action.<action_id>.resume","Nats-Schedule-TTL":"24h"}`, and `envelope_json = {"event_id":"<event_id>","type":"action.resume","class":"occurrence","owner_user_id":"<owner>","action_id":"<action_id>","data":{"run_id":"<run_id>"}}`. It has no `Nats-TTL` and no rev header; `Nats-Schedule-TTL` gives its fire the same 24-hour life as a schedule fire. nats-server removes a one-shot definition after it fires. A later deferral for the same action replaces an earlier one.

#### 6.2.4 Cron text and daylight saving

Users write 5-field cron (`minute hour day-of-month month day-of-week`). nats-server needs 6 fields with seconds first, and differs from our evaluator in three ways. `schedule.nats_cron` (T2) takes the 5-field text and returns the 6-field text. It removes the differences:

| Rule | Reason |
|---|---|
| Prefix the seconds field `0` | nats-server rejects 5 fields |
| For each of the five fields: emit `*` only when the user's text for that field is exactly `*`. Otherwise emit the values of our own parsed set as an ascending comma list, with no range and no step | nats-server treats `*/1` as a wildcard for the day-of-month / day-of-week rule and our evaluator does not. A plain list never counts as a wildcard, so both sides agree |
| In the day-of-week field, fold 7 into 0 before emitting | nats-server accepts 0 to 6 only. `5-7` becomes `0,5,6` |

Examples: `*/15 9 * * 1-5` → `0 0,15,30,45 9 * * 1,2,3,4,5`. `0 0 */1 * 7` → `0 0 0 1,2,…,31 * 0` (all 31 values written out).

**Daylight saving (Q3).** Fire times are whatever nats-server produces. In a zone with DST, a time that does not exist on the spring-forward day is skipped, and a time that occurs twice on the fall-back day fires twice. The hub adds no guard. The UI shows a note (T13).

#### 6.2.5 Conditions from the spike

Each condition is an acceptance item of the named task.

| # | Condition | Task |
|---|---|---|
| C1 | nats-server is 2.14.0 or newer where schedules are used. The hub checks this at run time (6.3.3) | T1 |
| C2 | `allow_msg_schedules` and `allow_msg_ttl` are added to the stream in the release that first publishes schedules, and never removed. This cannot be undone: an older hub binary can no longer bring its event relay up | T1, T14 |
| C3 | Definitions carry `Nats-TTL: never` | T9 |
| C4 | Definitions use subjects outside `ev.>` but inside the same stream | T1, T9 |
| C5 | The consumer is idempotent and checks the revision | T10 |
| C6 | A definition's `Nats-Msg-Id` is unique per outbox row and never derived from the revision | T9 (holds by construction: the relay uses `event_id`) |

#### 6.2.6 Reconcile

The set of definitions in the stream MUST equal the set of *effective* schedule triggers: triggers of kind `schedule` with `enabled = 1` whose action has `enabled = 1`.

Reconcile runs in the actions runtime thread (T10): once after every successful NATS connect, which covers hub start and reconnect. There is no periodic loop. Steps:

1. If `event_outbox.backlog` (`src/hub/repository/iface/event_outbox_repo.odin:25`) is not 0, do nothing now and try again on the next pass. A pending row may be the definition that looks missing.
2. Outside any unit of work, list the definitions: iterate `nats.stream_next(conn, "HEIM_EVENTS", "sched.def.*", start)` (`src/lib/nats/nats.odin:382`) until it reports not found. The filter has one wildcard token, so `sched.def.defer.<action_id>` is not listed. For each message keep the subject and, from the JSON body, `trigger_id` and `data.rev`.
3. In one unit of work, load the effective schedule triggers and compare:

| Case | Action |
|---|---|
| Trigger has no definition | append a definition row (6.2.2) |
| Definition's `data.rev` differs from the trigger's `rev` | append a definition row |
| Definition has no effective trigger | append a purge row (6.2.3) |
| Definition matches | nothing. Never republish an unchanged definition |

4. Commit. Reconcile is done for this connection.

#### 6.2.7 Delivery subjects (v7)

Deliveries do not live in `HEIM_EVENTS`. Their subject is `dlv.<owner>.<bridge_id>.<kind>` in the stream `HEIM_DELIVER` (6.3.6, 6.11.1). They are published through the same outbox and relay.

### 6.3 Stream and NATS wrapper (T1)

#### 6.3.1 Wrapper additions (`src/lib/nats`)

```odin
// nats.odin — additions. Existing fields and procedures stay as they are.
Stream_Config :: struct {
	// ... existing fields ...
	allow_msg_schedules: bool, // maps to jsStreamConfig.AllowMsgSchedules
	allow_msg_ttl:       bool, // maps to jsStreamConfig.AllowMsgTTL
}
Consumer_Config :: struct {
	// ... existing fields ...
	deliver_new: bool, // false = js_DeliverAll (today's behaviour), true = js_DeliverNew
}
Metadata :: struct {
	// ... existing fields ...
	timestamp_ns: i64, // stream timestamp of the message, Unix nanoseconds (jsMsgMetaData.Timestamp)
}

// Removes every message on exactly this subject. purged may be 0. No wildcard is accepted.
stream_purge_subject :: proc(conn: ^Connection, stream, subject: string) -> (purged: u64, err: Error)

// True when value is usable as one subject token: not empty, no character <= ' ', no '.', '*', '>', and no DEL.
// Same rule as eventinbox.subject_token, which becomes a call to this procedure.
subject_token :: proc(value: string) -> bool

// True when the connected server can run cron, @every and @at schedules: version >= 2.14.0.
// Fails closed: any error or unreadable version gives false.
server_supports_schedules :: proc(conn: ^Connection, stream: string) -> (supported: bool, err: Error)

// Pure. "2.14.7" >= (2,14,0) is true. An empty or malformed version is false. A suffix such as "-RC.1" is ignored.
version_at_least :: proc(version: string, major, minor, patch: int) -> bool
```

- The C struct behind `Metadata` and the FFI signatures in `src/lib/nats/ffi.odin:26` (`ham_nats_stream`) and `src/lib/nats/ffi.odin:27` (`ham_nats_consumer_add`) change together with `src/lib/nats/adapter.c:71` and `src/lib/nats/adapter.c:100`. Keep the Odin and C layouts identical.
- `stream_purge_subject` wraps `js_PurgeStream` with the purge subject option. `valid_string` rules of the existing procedures apply: an empty stream or subject returns `Error{status = INVALID}`.
- `server_supports_schedules`: **implementer choice** between two mechanisms. (a) Preferred: read the server version from the stream info that `js_GetStreamInfo` returns (the server puts it in the config metadata under the key `_nats.ver`) and pass it to `version_at_least(v, 2, 14, 0)`. (b) If nats.c 3.13 does not expose that metadata: publish a probe definition with `Nats-Schedule: 0 0 0 1 1 *` on `sched.def.probe` with target `ev.probe.sched`, treat JetStream error 10189 as "unsupported", and purge `sched.def.probe` afterwards. Either way the result MUST be false for nats-server 2.12 and 2.13, which accept only `@at`.
- Ownership: nothing new is allocated for the caller. `message_metadata` (`src/lib/nats/nats.odin:282`) still returns a value.

#### 6.3.2 Stream configuration

`eventrelay.stream_config` (`src/hub/service/eventrelay/relay.odin:26`) becomes:

| Field | Value |
|---|---|
| `name` | `HEIM_EVENTS` (unchanged) |
| `subjects` | `["ev.>", "sched.def.>"]` |
| `max_age_ns`, `duplicate_window_ns`, `replicas`, `allow_rollup`, `allow_direct` | unchanged |
| `allow_msg_schedules` | `true` |
| `allow_msg_ttl` | `true` |

The relay already calls `stream_add` and falls back to `stream_update`. The fallback upgrades an existing stream in place. The spike showed that the update keeps messages and consumers. It also showed that the flags cannot be turned off again. T1 MUST find every other place that builds a `HEIM_EVENTS` configuration (tests included) and make it use `eventrelay.stream_config`.

#### 6.3.3 Schedule support state

```odin
// src/hub/service/eventrelay/relay.odin
Schedule_Support :: enum i32 { Unknown, Supported, Unsupported }
schedule_support :: proc(s: ^Service) -> Schedule_Support // atomic read; safe from any thread
```

The relay sets the state after each successful stream setup, from `nats.server_supports_schedules`. It is `Unknown` until the first connect. This is the only place that decides it. Other code reads it through a port filled at wiring:

```odin
// defined in src/hub/service/actions (T9); wiring points it at eventrelay.schedule_support
Schedule_Support_Port :: struct { ctx: rawptr, get: proc(ctx: rawptr) -> int } // 0 Unknown, 1 Supported, 2 Unsupported
```

**Fallback on a server older than 2.14 (REQ-SCHED-5):**

| Where | Behaviour when the state is `Unsupported` |
|---|---|
| API (T9) | Creating or enabling a `schedule` trigger is refused with HTTP 409, error code `schedules_unsupported`, message `Scheduled triggers need nats-server 2.14 or newer.` Event triggers work |
| Relay (T1) | A row whose subject starts with `sched.def.` is marked published without being sent, and logged |
| Router (T10) | A run that would be deferred is recorded as `skipped` with reason `rate_limited` (6.8.3) |

When the state is `Unknown`, all three behave as for `Supported`.

#### 6.3.4 Relay row handling

`step_inner` (`src/hub/service/eventrelay/relay.odin:93`) gains three branches. Everything else is unchanged.

| Row | Relay action |
|---|---|
| `headers_json` has `Heim-Op` = `purge` | Call `nats.stream_purge_subject(conn, "HEIM_EVENTS", row.subject)`. On success (also when nothing was purged) mark the row published. On a connection error, retry as for a failed publish. `Heim-Op` is never sent as a header |
| Subject starts with `sched.def.` and the support state is `Unsupported` | Mark published, do not send, log once per process start |
| Subject starts with `sched.def.` and the publish fails with JetStream error 10189 (bad schedule pattern), 10190 (target not in stream) or 10223 (bad time zone) | Poison row: mark published, log the subject and the code, add 1 to `Service.schedule_rejects` (a new atomic `i64`). The relay continues with the next row |
| Any other row or error | As today |

Rows are still handled strictly in `outbox_seq` order. A purge followed by a new definition for the same subject therefore always ends with the definition in place.

**Wake on commit and batches (amendment S2, REQ-SCALE-2).** Today the relay publishes one row per pass and sleeps up to 1 s after a pass that published nothing (finding S5).

```odin
// src/hub/service/eventrelay/relay.odin
RELAY_BATCH :: 64
// Signals the relay's semaphore. Never blocks, never fails; safe from any thread and before start.
wake :: proc(s: ^Service)
```

- **Who calls `wake`.** Exactly one place: the commit of a SQLite transaction that appended at least one `event_outbox` row. The outbox repository's `append` marks the open transaction; the commit procedure, after a successful commit, calls the hook that wiring set to `eventrelay.wake`. No producer calls `wake` itself, and a rolled-back transaction does not signal. **Assumption:** every transaction of the hub commits through one procedure of `src/hub/repository/sqlite`. T1 locates it first; if there are several commit paths, each gets the hook, and the hand-off lists them.
- **The wait.** The idle wait of `entry` becomes `sync.sema_wait_with_timeout(&s.wake_sema, 1 s)` in place of the 50 ms sleep chunks. A signal ends it at once; the 1 s bound stays as a fallback for a lost signal and for rows written by another process. The back-off wait after a failed pass is unchanged.
- **Batches.** One pass publishes up to `RELAY_BATCH` rows, strictly in `outbox_seq` order, each marked published in its own statement after its publish succeeded, as today. The pass stops at the first row that fails, so order and the poison rules above are unchanged. `progress` is true when at least one row was handled.
- **Fire TTL fallback.** If `scenario_schedule_fire_ttl` shows that the server ignores `Nats-Schedule-TTL`, the header is still sent (it is harmless), and the matcher deletes each schedule fire and deferral fire after its commit with `nats.stream_delete_message` (6.3.5) by the message's stream sequence. T1 reports which of the two holds; T10 implements the delete only in that case.

#### 6.3.5 Wrapper additions for the delivery pipeline (`src/lib/nats`)

```odin
// nats.odin — additions for the pipeline. Existing fields and procedures stay as they are.
Retention :: enum i32 { Limits = 0, Work_Queue = 1 } // maps to js_LimitsPolicy / js_WorkQueuePolicy
Stream_Config :: struct {
	// ... existing fields and those of 6.3.1 ...
	retention: Retention, // zero value = Limits = today's behaviour
}
Consumer_Config :: struct {
	// ... existing fields and deliver_new ...
	max_ack_pending: i64, // 0 = server default (today's behaviour); maps to jsConsumerConfig.MaxAckPending
}

// The three calls below address a delivered message by its reply subject (nats.message_reply), like the
// existing ack_reply. The caller needs no message handle, so the reply subject can be stored in SQLite and
// used later from another thread. reply is borrowed. An empty reply returns Error{status = INVALID}.

// Negative ack with a redelivery delay. Publishes `-NAK {"delay": <delay_ns>}` to reply. delay_ms <= 0 means "now".
nak_reply_delay :: proc(conn: ^Connection, reply: string, delay_ms: i64) -> Error
// Work in progress: restarts the AckWait clock of this delivery. Publishes `+WPI` to reply.
in_progress_reply :: proc(conn: ^Connection, reply: string) -> Error
// Terminates the message: no redelivery; removed from a work-queue stream. Publishes `+TERM` to reply.
term_reply :: proc(conn: ^Connection, reply: string) -> Error

// Deletes one message by stream sequence (js_DeleteMsg). A sequence that no longer exists is not an error:
// deleted = false, err = {}.
stream_delete_message :: proc(conn: ^Connection, stream: string, sequence: u64) -> (deleted: bool, err: Error)
```

- `retention` and `max_ack_pending` change the FFI signatures of `ham_nats_stream` and `ham_nats_consumer_add` together with `src/lib/nats/adapter.c:83` (the hard-coded `js_LimitsPolicy`) and `src/lib/nats/adapter.c:100`. Existing callers pass nothing and keep today's values.
- `nak_reply_delay`, `in_progress_reply` and `term_reply` are plain publishes to the reply subject (`natsConnection_Publish`), followed by nothing: they do not wait for a server answer. `ack_reply` (`src/lib/nats/nats.odin:330`) is unchanged and keeps using a request. The delay in the `-NAK` body is in **nanoseconds**.
- The existing `nak` (`src/lib/nats/nats.odin:294`) and `term` (`src/lib/nats/nats.odin:299`) are unchanged.
- `stream_delete_message`: **Assumption** (not run in the capability check of 10.2): `js_DeleteMsg(js, stream, seq, NULL, &errCode)` exists in nats.c 3.13 and removes a message from a work-queue stream. T1 verifies it with `scenario_delete_message`. If it is false, T1 MUST stop and report; the fallback is to leave an exhausted message until `max_age` removes it (it is never redelivered, 10.2 item 7).
- Ownership: nothing is allocated for the caller.

**Facts proven against the flake's nats-server 2.14.7 with nats.c 3.13.0** (10.2). Build on them; do not re-derive them:

| # | Fact |
|---|---|
| N1 | A stream with `js_WorkQueuePolicy` accepts two consumers whose filters are disjoint (`dlv.*.b1.>` and `dlv.*.b2.>`). A consumer whose filter overlaps an existing one is refused with JetStream error 10100 |
| N2 | An acked message is removed from the stream. The other bridge's consumer never sees it |
| N3 | `-NAK {"delay": 3000000000}` published to the reply subject: no redelivery within 2 s, redelivery at 3 s with `num_delivered` 2 |
| N4 | `+WPI` published to the reply subject restarts AckWait |
| N5 | `+TERM` published to the reply subject: no redelivery, and the message is removed from the stream |
| N6 | With `MaxAckPending` 16, a fetch of 20 returns 16 |
| N7 | After `MaxDeliver` is exhausted the message is **not** redelivered, but it **stays** in the work-queue stream until `max_age` or until it is deleted. The max-deliveries advisory is emitted only while a pull request is waiting on that consumer. Its body is `{"type":"io.nats.jetstream.advisory.v1.max_deliver","stream":"HEIM_DELIVER","consumer":"brg_<bridge>","stream_seq":<n>,"deliveries":<n>}`; it has no message id |
| N8 | A repeated `Nats-Msg-Id` inside the duplicate window is reported as a duplicate and stored once |
| N9 | A consumer can be deleted, and a stream can be purged with a wildcard subject filter (`dlv.*.b2.>`) |
| N10 | **A message that was nak'd with a delay keeps counting against `MaxAckPending` until it is redelivered and acked.** With `MaxAckPending` 2 and two messages nak'd with an 8 s delay, the consumer reports `NumAckPending` 2 and a third message is held back for the whole delay. The pipeline therefore does not use `MaxAckPending` as its in-flight limit (6.11.4) |

#### 6.3.6 Stream `HEIM_DELIVER`

```odin
// src/hub/service/eventrelay/relay.odin
DELIVERY_STREAM :: "HEIM_DELIVER"
delivery_stream_config :: proc() -> nats.Stream_Config
```

| Field | Value |
|---|---|
| `name` | `HEIM_DELIVER` |
| `subjects` | `["dlv.>"]` |
| `retention` | `.Work_Queue` |
| `max_age_ns` | 24 hours |
| `duplicate_window_ns` | 2 minutes |
| `replicas` | 1 |
| `allow_direct` | `true` |
| `allow_rollup`, `allow_msg_schedules`, `allow_msg_ttl` | `false` |

The relay creates this stream in the same connect block as `HEIM_EVENTS` (`src/hub/service/eventrelay/relay.odin:101`), with the same add-then-update fallback. The relay's connect step succeeds only when **both** streams exist. Reason: the relay publishes strictly in `outbox_seq` order and never skips a row (F21), so a `dlv.` row published before its stream exists would block every event.

Why a second stream and not `HEIM_EVENTS`: the matcher and the event inbox read `ev.>` and must not see commands; `HEIM_EVENTS` keeps messages for 14 days and uses rollups, while a delivery must disappear when acked; a bridge's backlog can be purged when the bridge is deleted; and nothing irreversible is added to `HEIM_EVENTS` (risk K1 does not grow).

Per-bridge consumers on this stream are created by package `delivery` (6.11.3), not by the relay.

**`ack_reply_async`.** `ack_reply_async :: proc(conn: ^Connection, reply: string) -> Error` publishes `+ACK` to `reply` and returns. It does not wait for the server (the existing `ack_reply`, `src/lib/nats/nats.odin:330`, is a request with a timeout and blocks its caller). The pipeline uses only the async form (6.11.4).

### 6.4 Schema (T9)

"No migration" (R1) means no data migration. One forward-only schema file drops the old objects and creates the new ones.

- File: `src/hub/repository/sqlite/migrations/actions_001_reset.sql`. The feature-prefix name follows `events_001_outbox.sql` and `bots_web_001_channel.sql`.
- Registration takes three edits in `src/hub/repository/sqlite/migrations.odin`: a `#load` constant next to `MIGRATION_235_EXTENSION_VERSION_SYNC` (`src/hub/repository/sqlite/migrations.odin:726`); a new **last** entry in `migration_order` (`src/hub/repository/sqlite/migrations.odin:728`; the last entry at `origin/main` `99879b7b` is `235_extension_version_sync_0_5_72.sql` at `src/hub/repository/sqlite/migrations.odin:977`); and a branch in `migration_sql` (`src/hub/repository/sqlite/migrations.odin:1509`). If `origin/main` has added migrations since, yours still goes last.
- Delete `upgrade_scheduled_prompts_schema` and `upgrade_actions_schema` and their two calls (F16).

```sql
-- actions_001_reset.sql : no backfill; existing action rows are discarded (R1)
DROP TRIGGER IF EXISTS action_revision_insert;
DROP TRIGGER IF EXISTS action_revision_update;
DROP TRIGGER IF EXISTS action_revision_delete;
DROP TRIGGER IF EXISTS action_revision_member_insert;
DROP TRIGGER IF EXISTS action_revision_member_delete;
DROP TRIGGER IF EXISTS action_revision_member_update;
DROP TABLE IF EXISTS action_schedule_revision;
DROP TABLE IF EXISTS scheduled_prompts;
DROP TABLE IF EXISTS actions;

CREATE TABLE actions (
  action_id TEXT PRIMARY KEY CHECK(action_id != ''),
  owner_user_id TEXT NOT NULL CHECK(owner_user_id != ''),
  name TEXT NOT NULL DEFAULT '',
  prompt_text TEXT NOT NULL,
  target_kind TEXT NOT NULL CHECK(target_kind IN ('agent','instance','bot')),
  target_agent_id TEXT NOT NULL DEFAULT '',
  target_project_id TEXT NOT NULL DEFAULT '',
  target_instance_id TEXT NOT NULL DEFAULT '',
  target_bot_id TEXT NOT NULL DEFAULT '',
  instance_strategy TEXT NOT NULL DEFAULT 'reuse' CHECK(instance_strategy IN ('reuse','fresh_per_run')),
  placement_selector TEXT NOT NULL DEFAULT 'first',
  last_spawned_instance_id TEXT NOT NULL DEFAULT '',
  enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
  min_interval_s INTEGER NOT NULL DEFAULT 30 CHECK(min_interval_s BETWEEN 5 AND 86400),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX actions_owner ON actions(owner_user_id);
CREATE TRIGGER actions_owner_immutable BEFORE UPDATE OF owner_user_id ON actions
  BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;

-- Ordered placement rules (target_kind 'agent'). Row shape = placement.Rule.
CREATE TABLE action_target_rules (
  action_id TEXT NOT NULL REFERENCES actions(action_id) ON DELETE CASCADE,
  position  INTEGER NOT NULL CHECK(position >= 0),
  bridge_id TEXT NOT NULL,   -- a bridge id or '*'
  provider  TEXT NOT NULL,   -- a catalog provider id or '*'
  model     TEXT NOT NULL,   -- a model id or '*'
  PRIMARY KEY(action_id, position),
  CHECK(NOT (provider = '*' AND model <> '*'))
);

CREATE TABLE action_triggers (
  trigger_id TEXT PRIMARY KEY CHECK(trigger_id != ''),
  action_id TEXT NOT NULL REFERENCES actions(action_id) ON DELETE CASCADE,
  owner_user_id TEXT NOT NULL,
  kind TEXT NOT NULL,                        -- registry key; no CHECK, so a new kind needs no DDL
  config TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(config)),
  event_type TEXT NOT NULL,                  -- derived by Trigger_Kind.compile
  subject_filter TEXT NOT NULL,              -- derived by Trigger_Kind.compile
  match_key TEXT NOT NULL DEFAULT '',        -- S2: subject_filter when it has no '*' token, else '' (6.6.1)
  data_filter TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(data_filter)),
  enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
  rev INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX action_triggers_match  ON action_triggers(owner_user_id, event_type, match_key) WHERE enabled = 1;
CREATE INDEX action_triggers_action ON action_triggers(action_id);

-- One row per matched occurrence.
CREATE TABLE action_runs (
  run_id TEXT PRIMARY KEY CHECK(run_id != ''),
  action_id TEXT NOT NULL REFERENCES actions(action_id) ON DELETE CASCADE,
  trigger_id TEXT NOT NULL,                  -- no foreign key: the trigger may be deleted later
  owner_user_id TEXT NOT NULL,
  occurrence_key TEXT NOT NULL UNIQUE,       -- '<trigger_id>:<event key>'
  event_type TEXT NOT NULL,
  event_id TEXT NOT NULL DEFAULT '',
  stream_sequence INTEGER NOT NULL DEFAULT 0,
  event_params TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(event_params)),
  state TEXT NOT NULL CHECK(state IN ('queued','deferred','routed','delivered','joined','skipped','failed')),
  not_before TEXT NOT NULL DEFAULT '',       -- state 'deferred': earliest delivery time
  joined_run_id TEXT NOT NULL DEFAULT '',    -- state 'joined': the run it merged into
  reason TEXT NOT NULL DEFAULT '',           -- 6.8.1
  rule_position INTEGER NOT NULL DEFAULT -1,
  target_instance_id TEXT NOT NULL DEFAULT '',
  message_id TEXT NOT NULL DEFAULT '',
  delivery_id TEXT NOT NULL DEFAULT '',      -- the current delivery of this run (6.11); '' before routing
  created_at TEXT NOT NULL,
  started_at TEXT NOT NULL DEFAULT '',       -- set when the run becomes 'routed'
  finished_at TEXT NOT NULL DEFAULT ''
);
CREATE UNIQUE INDEX action_runs_one_open ON action_runs(action_id) WHERE state IN ('queued','deferred','routed');
CREATE INDEX action_runs_action ON action_runs(action_id, created_at);
CREATE INDEX action_runs_joined ON action_runs(joined_run_id) WHERE state = 'joined';
CREATE INDEX action_runs_due    ON action_runs(state, not_before) WHERE state IN ('queued','deferred'); -- S2: runs_due, runs_deferred (6.16)
```

Rules that the DDL does not express:

- All timestamps are RFC3339 UTC strings from `platform.clock_now` (`src/hub/platform/clock.odin:16`).
- Id prefixes: actions `act_` (as today), triggers `trg_`, runs `arun_`.
- An action has at most 16 triggers and at most 16 rules. Rules exist only for `target_kind = 'agent'`.
- `target_kind` decides which target column is set: `agent` → `target_agent_id` (and optionally `target_project_id`); `instance` → `target_instance_id`; `bot` → `target_bot_id`. The other target columns are empty.
- Deleting an action MUST delete its rules, triggers and runs explicitly in the same transaction. Do not rely on `ON DELETE CASCADE` being enabled.

#### 6.4.1 Pipeline schema (T16)

The pipeline owns one table. It is created by T16, not by T9, in their own file: `src/hub/repository/sqlite/migrations/pipeline_001_deliveries.sql`, registered **last** in `migration_order` the same way as `actions_001_reset.sql`. T9 and T16 run in the same wave; whichever merges second places its file after the other's. The two files do not depend on each other.

```sql
-- pipeline_001_deliveries.sql
-- One row per delivery, for all four kinds. NOT the existing event_deliveries table (inbox ack receipts, V12).
CREATE TABLE pipeline_deliveries (
  delivery_id TEXT PRIMARY KEY CHECK(delivery_id != ''),
  owner_user_id TEXT NOT NULL CHECK(owner_user_id != ''),
  kind TEXT NOT NULL CHECK(kind IN ('prompt','notice','bot','lease')),
  bridge_id TEXT NOT NULL CHECK(bridge_id != ''),
  agent_instance_id TEXT NOT NULL CHECK(agent_instance_id != ''),
  ref TEXT NOT NULL,                       -- run:<run_id> | sub:<agent_instance_id> | bot:<attempt_id> | lease:<lease_id>
  message_id TEXT NOT NULL DEFAULT '',     -- the chat message of a prompt or notice
  state TEXT NOT NULL CHECK(state IN ('routed','forwarded','done','failed','replaced')),
  outcome TEXT NOT NULL DEFAULT '',        -- state done: started | notified | accepted
  reason TEXT NOT NULL DEFAULT '',         -- state failed: 6.11.9
  round INTEGER NOT NULL DEFAULT 0,        -- placement round, 0..2 (6.11.7)
  excluded_bridges TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(excluded_bridges)),
  attempt INTEGER NOT NULL DEFAULT 0,      -- num_delivered of the newest forward
  ack_reply TEXT NOT NULL DEFAULT '',      -- JetStream reply subject of the newest forward
  stream_sequence INTEGER NOT NULL DEFAULT 0,
  retry_at TEXT NOT NULL DEFAULT '',       -- set by a retry answer: when JetStream redelivers; '' while a frame is in flight
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  forwarded_at TEXT NOT NULL DEFAULT '',   -- first forward
  updated_at TEXT NOT NULL
);
CREATE INDEX pipeline_deliveries_open ON pipeline_deliveries(bridge_id) WHERE state IN ('routed','forwarded');
CREATE INDEX pipeline_deliveries_ref  ON pipeline_deliveries(ref);
CREATE INDEX pipeline_deliveries_expiry ON pipeline_deliveries(expires_at) WHERE state IN ('routed','forwarded');       -- S2: expired (6.16)
CREATE INDEX pipeline_deliveries_closed ON pipeline_deliveries(updated_at) WHERE state IN ('done','failed','replaced'); -- S2: prune (6.11.10)
CREATE TRIGGER pipeline_deliveries_owner_immutable BEFORE UPDATE OF owner_user_id ON pipeline_deliveries
  BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;

-- S2: the column agent_instances.start_ref (start-begin idempotency, 6.12.2) is created by T22 in its own file,
-- agents_001_start_ref.sql, because T22 no longer waits for T16.
```

Rules that the DDL does not express:

- Id prefix: `dlv_`, from `platform.generate_id`.
- A row is never deleted by the pipeline while it is open. Closed rows (`done`, `failed`, `replaced`) older than 30 days are deleted by `delivery.prune` (6.11.10), which runs on events only.
- `ack_reply`, `attempt` and `stream_sequence` are written in the same statement that sets `forwarded` (REQ-PIPE-10).
- `domain.Agent_Instance` gains the field `start_ref: string`, and the agent repository reads and writes it. **Assumption:** `agent_instances` is read and written through one SELECT column list and one upsert in `src/hub/repository/sqlite`; T22 locates every statement that names the table's columns and adds the new one.

### 6.5 Domain types and repository (T9)

`src/hub/domain/action.odin` is rewritten. `Action_State`, `Action_Target_Mode` and the old fields are removed.

```odin
ACTION_TARGET_AGENT    :: "agent"
ACTION_TARGET_INSTANCE :: "instance"
ACTION_TARGET_BOT      :: "bot"
ACTION_MAX_TRIGGERS    :: 16
ACTION_MAX_RULES       :: 16
ACTION_MIN_INTERVAL_DEFAULT_S :: 30
ACTION_MIN_INTERVAL_MIN_S     :: 5
ACTION_MIN_INTERVAL_MAX_S     :: 86400
// ACTION_INSTANCE_STRATEGY_REUSE / _FRESH_PER_RUN and action_instance_strategy_valid stay.

Action :: struct {
	id:                       Action_ID,
	owner_user_id:            User_ID,
	name, prompt_text:        string,
	target_kind:              string,
	target_agent_id:          Agent_ID,
	target_project_id:        Project_ID,
	target_instance_id:       Agent_Instance_ID,
	target_bot_id:            string,
	instance_strategy:        string,
	placement_selector:       string,
	last_spawned_instance_id: Agent_Instance_ID,
	enabled:                  bool,
	min_interval_s:           int,
	created_at, updated_at:   string,
}
Action_Target_Rule :: struct { position: int, bridge_id, provider, model: string }
Action_Trigger :: struct {
	trigger_id:             string,
	action_id:              Action_ID,
	owner_user_id:          User_ID,
	kind:                   string,
	config_json:            string, // column config
	event_type:             string,
	subject_filter:         string,
	data_filter_json:       string, // column data_filter
	enabled:                bool,
	rev:                    int,
	created_at, updated_at: string,
}
Action_Run :: struct {
	run_id:                             string,
	action_id:                          Action_ID,
	trigger_id:                         string,
	owner_user_id:                      User_ID,
	occurrence_key:                     string,
	event_type, event_id:               string,
	stream_sequence:                    i64,
	event_params_json:                  string,
	state:                              string, // ACTION_RUN_* below
	not_before, joined_run_id, reason:  string,
	rule_position:                      int,
	target_instance_id, message_id:     string,
	delivery_id:                        string,
	created_at, started_at, finished_at: string,
}
ACTION_RUN_QUEUED :: "queued";     ACTION_RUN_DEFERRED :: "deferred"; ACTION_RUN_DELIVERED :: "delivered"
ACTION_RUN_ROUTED :: "routed"
// True for queued, deferred and routed.
action_run_open :: proc(state: string) -> bool
ACTION_RUN_JOINED :: "joined";     ACTION_RUN_SKIPPED  :: "skipped";  ACTION_RUN_FAILED    :: "failed"

action_destroy          :: proc(a: ^Action)
action_trigger_destroy  :: proc(t: ^Action_Trigger)
action_triggers_destroy :: proc(rows: []Action_Trigger)
action_rules_destroy    :: proc(rows: []Action_Target_Rule)
action_run_destroy      :: proc(r: ^Action_Run)
action_runs_destroy     :: proc(rows: []Action_Run)
```

`src/hub/repository/iface/action_repo.odin` is rewritten. `Scheduled_Prompt_Repository` and the field `scheduled_prompts` of `Repositories` (`src/hub/repository/iface/repos.odin:3`) are deleted. The old procedures `revision`, `snapshot`, `list_by_instance`, `list_by_bridge`, `cas_lease`, `max_updated_at_for_bridge` and `delete_prompt` are deleted.

```odin
Action_Repository :: struct {
	ctx: rawptr,
	// actions
	save:          proc(ctx: rawptr, a: domain.Action) -> domain.Domain_Error,                         // insert or update by id
	get:           proc(ctx: rawptr, id: domain.Action_ID) -> (domain.Action, bool, domain.Domain_Error),
	list:          proc(ctx: rawptr, owner: domain.User_ID) -> ([]domain.Action, domain.Domain_Error), // ordered by created_at, action_id
	delete_action: proc(ctx: rawptr, id: domain.Action_ID) -> domain.Domain_Error,                     // also rules, triggers, runs
	set_last_spawned: proc(ctx: rawptr, id: domain.Action_ID, instance_id, updated_at: string) -> domain.Domain_Error,
	// rules
	rules_list:    proc(ctx: rawptr, id: domain.Action_ID) -> ([]domain.Action_Target_Rule, domain.Domain_Error), // ordered by position
	rules_replace: proc(ctx: rawptr, id: domain.Action_ID, rows: []domain.Action_Target_Rule) -> domain.Domain_Error,
	// triggers
	trigger_save:   proc(ctx: rawptr, t: domain.Action_Trigger) -> domain.Domain_Error,
	trigger_get:    proc(ctx: rawptr, trigger_id: string) -> (domain.Action_Trigger, bool, domain.Domain_Error),
	trigger_delete: proc(ctx: rawptr, trigger_id: string) -> domain.Domain_Error,
	triggers_list:  proc(ctx: rawptr, id: domain.Action_ID) -> ([]domain.Action_Trigger, domain.Domain_Error), // ordered by created_at, trigger_id
	// Enabled triggers of enabled actions for one owner and event type whose match_key is `subject` or '',
	// ordered by created_at, trigger_id. Two index reads on action_triggers_match (6.16, Q3). S2.
	triggers_match: proc(ctx: rawptr, owner, event_type, subject: string) -> ([]domain.Action_Trigger, domain.Domain_Error),
	// Enabled triggers of one kind whose action is enabled, across all owners (reconcile).
	triggers_effective: proc(ctx: rawptr, kind: string) -> ([]domain.Action_Trigger, domain.Domain_Error),
	// runs
	run_insert: proc(ctx: rawptr, r: domain.Action_Run) -> (inserted: bool, err: domain.Domain_Error),  // INSERT OR IGNORE on occurrence_key
	run_get:    proc(ctx: rawptr, run_id: string) -> (domain.Action_Run, bool, domain.Domain_Error),
	run_open:   proc(ctx: rawptr, id: domain.Action_ID) -> (domain.Action_Run, bool, domain.Domain_Error), // the queued, deferred or routed run
	// Runs that are due for routing: state queued, or state deferred with not_before <= now. Never a routed run. Ordered by created_at, run_id.
	runs_due:   proc(ctx: rawptr, now: string, limit: int) -> ([]domain.Action_Run, domain.Domain_Error),
	// Runs in state deferred, whatever their not_before. Ordered by created_at, run_id.
	runs_deferred: proc(ctx: rawptr, limit: int) -> ([]domain.Action_Run, domain.Domain_Error),
	// Compare-and-set: writes next only if the stored state equals from_state. changed = false when it did not.
	run_transition: proc(ctx: rawptr, next: domain.Action_Run, from_state: string) -> (changed: bool, err: domain.Domain_Error),
	// started_at of the newest run whose started_at is set (routed, delivered, or failed after routing), or "".
	run_last_started_at: proc(ctx: rawptr, id: domain.Action_ID) -> (string, domain.Domain_Error),
	run_joined_count: proc(ctx: rawptr, run_id: string) -> (int, domain.Domain_Error),
	// Newest first. before_created_at = "" starts at the newest row.
	runs_list:  proc(ctx: rawptr, id: domain.Action_ID, limit: int, before_created_at: string) -> ([]domain.Action_Run, domain.Domain_Error),
	// Deletes rows of this action that are not open and are either older than cutoff or beyond the newest keep rows.
	runs_prune: proc(ctx: rawptr, id: domain.Action_ID, keep: int, cutoff: string) -> domain.Domain_Error,
}
```

Ownership: every returned struct and slice is allocated in `context.allocator`, and the caller frees it with the matching `domain.*_destroy` procedure. A struct passed in is borrowed for the call. The SQLite implementation stays in `src/hub/repository/sqlite/action_repo_sqlite.odin`; `open_action_snapshot_conn` and the snapshot connection are deleted.

#### 6.5.1 Pipeline domain type and repository (T16)

```odin
// src/hub/domain/pipeline_delivery.odin
DELIVERY_KIND_PROMPT :: "prompt"; DELIVERY_KIND_NOTICE :: "notice"
DELIVERY_KIND_BOT    :: "bot";    DELIVERY_KIND_LEASE  :: "lease"
DELIVERY_ROUTED :: "routed"; DELIVERY_FORWARDED :: "forwarded"; DELIVERY_DONE :: "done"
DELIVERY_FAILED :: "failed"; DELIVERY_REPLACED  :: "replaced"
DELIVERY_MAX_ROUNDS :: 3

Pipeline_Delivery :: struct {
	delivery_id, owner_user_id, kind, bridge_id, agent_instance_id, ref, message_id: string,
	state, outcome, reason: string,
	round:                 int,
	excluded_bridges_json: string, // column excluded_bridges
	attempt:               int,
	ack_reply:             string,
	stream_sequence:       i64,
	expires_at, created_at, forwarded_at, updated_at: string,
}
pipeline_delivery_destroy    :: proc(d: ^Pipeline_Delivery)
pipeline_deliveries_destroy  :: proc(rows: []Pipeline_Delivery)
pipeline_delivery_open       :: proc(state: string) -> bool // routed or forwarded
```

```odin
// src/hub/repository/iface/pipeline_delivery_repo.odin ; field `pipeline_deliveries` of iface.Repositories
Pipeline_Delivery_Repository :: struct {
	ctx: rawptr,
	insert: proc(ctx: rawptr, d: domain.Pipeline_Delivery) -> domain.Domain_Error,
	get:    proc(ctx: rawptr, delivery_id: string) -> (domain.Pipeline_Delivery, bool, domain.Domain_Error),
	// Compare-and-set on state: writes every mutable column of next only if the stored state equals from_state.
	// changed = false means another thread moved the row first. EVERY caller MUST branch on it (6.11.4, 6.11.5).
	transition: proc(ctx: rawptr, next: domain.Pipeline_Delivery, from_state: string) -> (changed: bool, err: domain.Domain_Error),
	// Open rows of one bridge, oldest first. state_filter "" = routed and forwarded.
	open_for_bridge: proc(ctx: rawptr, bridge_id, state_filter: string, limit: int) -> ([]domain.Pipeline_Delivery, domain.Domain_Error),
	// The open row with this ref, if any (at most one per ref by construction).
	open_by_ref: proc(ctx: rawptr, ref: string) -> (domain.Pipeline_Delivery, bool, domain.Domain_Error),
	// Frames in flight for one bridge: rows in state forwarded with retry_at = '' and updated_at > since.
	in_flight: proc(ctx: rawptr, bridge_id, since: string) -> (int, domain.Domain_Error),
	// Open rows with expires_at <= now, oldest first.
	expired: proc(ctx: rawptr, now: string, limit: int) -> ([]domain.Pipeline_Delivery, domain.Domain_Error),
	// Deletes closed rows with updated_at < cutoff.
	prune:   proc(ctx: rawptr, cutoff: string) -> domain.Domain_Error,
}
```

Ownership is that of 6.5: returned structs and slices are allocated in `context.allocator` and freed with the `domain.pipeline_*_destroy` procedures; a struct passed in is borrowed. The SQLite implementation is `src/hub/repository/sqlite/pipeline_delivery_repo_sqlite.odin`.

### 6.6 Trigger kinds (T9)

#### 6.6.1 The registry

A new trigger type is one entry in `TRIGGER_KINDS` plus a producer that publishes events. The matcher and the router are never edited for it (REQ-ACT-2).

```odin
// src/hub/service/actions/triggers.odin
Match_Spec :: struct { event_type, subject_filter, data_filter_json: string } // allocated in the allocator passed to compile

Event_View :: struct { // all strings borrowed from the fetched batch or the pass arena
	subject, owner, event_type, event_id: string,
	stream_sequence: u64,
	stream_time_ms:  i64,
	envelope:        json.Object,
	schedule_next:   string, // header Nats-Schedule-Next, "" when absent
	trigger_rev:     string, // header Heim-Trigger-Rev, "" when absent
}

Sync_Context :: struct { outbox: ^iface.Event_Outbox_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator }

Trigger_Kind :: struct {
	kind: string, // "schedule" | "event"
	// Validates config and derives the stored match columns. owner, action_id and trigger_id are final values.
	compile: proc(owner, action_id, trigger_id: string, config: json.Object, allocator: mem.Allocator) -> (Match_Spec, domain.Domain_Error),
	// Called inside the transaction that saves or deletes a trigger. Appends outbox rows only. nil = nothing to sync.
	// before == nil: the trigger is new. after == nil: it was deleted.
	// Both carry the EFFECTIVE enabled flag: trigger.enabled AND action.enabled.
	on_change: proc(sc: ^Sync_Context, before, after: ^domain.Action_Trigger) -> domain.Domain_Error,
	// The part of occurrence_key after '<trigger_id>:'. nil = the envelope's event_id.
	event_key: proc(msg: Event_View, allocator: mem.Allocator) -> string,
	// Per-occurrence check. run = false records the occurrence as skipped with this reason.
	// retire = true also disables the trigger for good (a one-shot that fired, or an ended window).
	// nil = always run.
	guard: proc(t: domain.Action_Trigger, msg: Event_View) -> (run: bool, reason: string, retire: bool),
}
TRIGGER_KINDS := [?]Trigger_Kind{schedule_kind, event_kind}
trigger_kind_find :: proc(kind: string) -> (^Trigger_Kind, bool)
```

Tests may append a kind to a package-level `extra_trigger_kinds: [dynamic]Trigger_Kind` that `trigger_kind_find` also searches. That is the seam the fake-kind test uses.

**The `match_key` rule (amendment S2).** When the service saves a trigger it sets the column `match_key` from the `subject_filter` that `compile` returned: the filter itself when none of its tokens is `*`, otherwise the empty string. No kind computes it and the matcher names no kind. A schedule trigger's filter is its own fire subject, so its `match_key` is that subject; an event trigger for one chain gets that chain's subject; an event trigger for any chain gets `''`. The matcher's token-by-token filter (6.7 step 5) still runs on every returned row, so `match_key` only narrows what is read.

**The `rev` rule.** A trigger's `rev` is 1 when it is created. It increases by 1 whenever its `config` or its `enabled` flag changes, and whenever its action's `enabled` flag changes. The service does this before it calls `on_change`. `rev` is only a filter for stale fires. It is never part of a publish id.

#### 6.6.2 Kind `schedule`

`config`:

| Key | Type | Rule |
|---|---|---|
| `mode` | string | `cron`, `interval` or `once`. Required |
| `cron_expr` | string | mode `cron`: required, 5 fields, MUST parse with `schedule.parse_cron` |
| `timezone` | string | optional IANA name, default `UTC`. MUST load with `schedule.timezone_valid`. Used for cron fires, blackout dates and nothing else |
| `interval_s` | integer | mode `interval`: required, 60 to 31536000 |
| `run_at` | string | mode `once`: required, RFC3339 with an offset or `Z`. A time in the past is accepted and fires at once |
| `blackout_dates` | array of `YYYY-MM-DD` | optional, at most 366 entries |
| `active_from`, `active_until` | string | optional RFC3339. If both are set, `active_from` < `active_until` |

Unknown keys are rejected with a validation error.

| Procedure | Behaviour |
|---|---|
| `compile` | Validates the table above. Returns `event_type = "schedule.fired"`, `subject_filter = "ev.<owner>.sched.<trigger_id>"`, `data_filter_json = "{}"` |
| `on_change` | `after == nil` or `after.enabled == false`: if `before != nil` and `before.enabled`, append a purge row. Otherwise, if `before == nil`, or `before.enabled == false`, or `before.rev != after.rev`: append a definition row built from `after` (6.2.2). Otherwise nothing. So one save appends at most one row per trigger |
| `event_key` | `"<trigger_rev>:<schedule_next>"`, or `"<trigger_rev>:once"` when `schedule_next` is `purge` or empty |
| `guard` | In this order. (1) `msg.trigger_rev` differs from `t.rev` → `(false, "stale_rev", false)`. (2) mode `once` → remember `retire = true` for the result. (3) `active_from` set and stream time before it → `(false, "outside_window", false)`. (4) `active_until` set and stream time after it → `(false, "outside_window", true)`. (5) the local date of the stream time in `timezone` is in `blackout_dates` → `(false, "blackout", retire)`. (6) otherwise `(true, "", retire)` |

When the matcher sees `retire = true` it sets the trigger's `enabled` to 0, adds 1 to `rev`, and calls `on_change` (which appends the purge row), in the same transaction as the run row. A one-shot is therefore never published again by reconcile.

#### 6.6.3 Kind `event`

`config`:

| Key | Type | Rule |
|---|---|---|
| `event_type` | string | Required. MUST be the `event_type` of an entry in `EVENT_DESCRIPTORS` |
| `chain_id` | string | Optional. When set it MUST pass `nats.subject_token`, and the chain MUST exist and belong to the owner (look it up through `uow.repos.taskchains`); otherwise error code `unknown_chain` |
| `data` | object of string values | Optional. Every key MUST be one of the descriptor's `data_keys` |

| Procedure | Behaviour |
|---|---|
| `compile` | `event_type` = the config's type. `subject_filter` = `ev.<owner>.chain.<chain_id or *>.<suffix>`, where `<suffix>` is the type without its `chain.` prefix (the same construction as `src/hub/service/eventinbox/filters.odin:9`). `data_filter_json` = the `data` object, or `{}` |
| `on_change` | `nil` |
| `event_key` | `nil` (the envelope's `event_id`) |
| `guard` | `nil` |

```odin
Data_Key :: struct { key: string, values: []string } // values empty = free text
Preset   :: struct { id, label: string, data_json: string }
Event_Descriptor :: struct { event_type, label, scope: string, data_keys: []Data_Key, presets: []Preset }

EVENT_DESCRIPTORS := [?]Event_Descriptor{
	{event_type = "chain.state", label = "Task chain state changed", scope = "chain",
	 data_keys = {{key = "state", values = {"active", "completed", "archived"}}},
	 presets   = {{id = "chain_completed", label = "Task chain completed", data_json = `{"state":"completed"}`}}},
	{event_type = "chain.work_finished", label = "Task chain work finished", scope = "chain",
	 data_keys = {{key = "outcome", values = {}}}, presets = {}},
}
```

These two entries are the whole picker (Q7). "Chain completed" is the preset `chain_completed` and nothing else (Q4).

### 6.7 Matcher (T10)

The matcher is one durable pull consumer on `HEIM_EVENTS`:

| Setting | Value |
|---|---|
| durable name | `hub_action_matcher` |
| `filter_subjects` | `["ev.>"]` |
| `deliver_new` | `true`. The first start sees no older message (case C13). After a restart the consumer continues where it stopped |
| `ack_wait_ns` | 60 s |
| `max_deliver` | the same value the event inbox passes for its consumer (`src/hub/service/eventinbox/service.odin:12`, field `max_deliver`), so both consumers treat poison messages alike |
| fetch | `nats.fetch(pull, 64, 1000)` |

For each message in a fetched batch, in order:

1. **Parse.** Build an `Event_View`. Split the subject: it must start with `ev.` and have an owner token. Ignore `ev.dlq.>` (ack, no rows). Parse the body as a JSON object; `event_type` is its `type`, `event_id` its `event_id`. A body that is not a JSON object is terminated with `nats.term` (`src/lib/nats/nats.odin:299`) and counted. Read `stream_sequence` and `timestamp_ns` from `nats.message_metadata`.
2. **Owner check.** If the envelope has `owner_user_id` and it differs from the subject's owner token, ack and count the message. No rows.
3. **Begin a unit of work.**
4. **Lookup.** `triggers_match(owner, event_type, subject)` with the event's full subject (S2, REQ-SCALE-5). A schedule fire returns its own trigger only.
5. **Filter.** Keep a trigger when all of these hold:
   - its `owner_user_id` equals the subject owner;
   - its `subject_filter` matches the subject token by token, where a filter token `*` matches any one token and the token counts are equal;
   - every key of its `data_filter` equals, as a string, the same key in the envelope's `data` object;
   - the event is not older than the trigger: `stream_time_ms >= rfc3339_to_unix_ms(trigger.updated_at)` (`src/hub/platform/clock.odin:122`). This drops events published before the trigger was created or last changed (case C10).
6. **Guard.** For each kept trigger, in the order returned, call the kind's `guard` (or assume `(true, "", false)`).
7. **Insert.** Compute `occurrence_key = "<trigger_id>:<event key>"`. Build the run with a new `run_id`, the event fields and `event_params` (6.9), then:

   | Guard result | Row |
   |---|---|
   | `run = false` | state `skipped`, the guard's reason, `finished_at = now` |
   | `run = true` and `run_open(action_id)` finds an open run | state `joined`, `joined_run_id` = that run, `finished_at = now` |
   | `run = true` and there is no open run | state `queued` |

   `run_insert` uses `INSERT OR IGNORE`, so a redelivered event adds nothing (O1). After inserting a row in state `skipped` or `joined`, call `runs_prune(action_id, 200, now - 30 days)` in the same unit of work. Every path that ends a run therefore prunes: the matcher here, and the router in its Decide and Record steps (6.13.1). A history that never delivers stays bounded too. If `retire` is true, retire the trigger (6.6.2).
8. **Commit, then ack** with `nats.ack` (`src/lib/nats/nats.odin:288`). If the commit fails, do not ack; the message is redelivered after `ack_wait`. A crash between commit and ack redelivers the message, and step 7 ignores it (case C12).

An event that matches no trigger (a deferral fire, for example) is simply acked.

**After the batch**, destroy it, then call the router's `drain_due` (6.13.1), with a resume hint for each deferral fire the batch contained (6.8.3). `drain_due` also runs once when the runtime starts. It does **not** run after an empty fetch. A drain on an idle timer would be the hub tick that the user ruled out.

### 6.8 Run states, overlap and deferral

#### 6.8.1 States and reasons

| State | Meaning | Open? |
|---|---|---|
| `queued` | Matched; waiting for the router | yes |
| `deferred` | Matched inside the minimum interval; routing is due at `not_before` | yes |
| `routed` | The router claimed the run: the prompt is stored as a chat message and a delivery is published. The run waits for the bridge's answer | **yes** |
| `delivered` | The bridge answered `succeeded` (outcome `started` or `notified`) | no |
| `joined` | Merged into the open run `joined_run_id`; it causes no prompt of its own | no |
| `skipped` | Deliberately not delivered; `reason` says why | no |
| `failed` | Delivery was planned or attempted and could not be done; `reason` says why | no |

| `reason` | State | Set by | When |
|---|---|---|---|
| `stale_rev` | skipped | matcher | a schedule fire carries an old revision |
| `outside_window` | skipped | matcher | the fire is before `active_from` or after `active_until` |
| `blackout` | skipped | matcher | the fire's local date is a blackout date |
| `experiment_off` | skipped | router | the owner's `actions` experiment is off (or `bots`, for a bot target) |
| `disabled` | skipped | router | the action was disabled after the match |
| `rate_limited` | skipped | router | inside the interval on a server without schedule support |
| `no_placement` | failed | router | no placement rule can be satisfied |
| `bridge_too_old` | failed | router, pipeline | the only machine the target allows does not report `event_pipeline_v1`; or the machine reconnected without it |
| `target_missing` | failed | router, pipeline | the target agent, instance or bot no longer exists; or start-begin answered "not found" |
| `delivery_failed` | failed | router | creating the instance, storing the prompt or appending the delivery failed |
| `bridge_offline` | failed | pipeline | the delivery expired before the bridge gave a final answer (6.11.7, OFF-3) |
| `start_failed` | failed | pipeline | the bridge answered `fatal` for a start: start-begin refused, or the provider cannot run there; no other machine could take it |
| `no_answer` | failed | pipeline | all 8 attempts were used and the bridge gave no final answer |

Removed from v6: `user_stopped`, `needs_recovery`, `target_busy`. No code may write them.

The reason of a failed delivery (6.11.9) is copied to the run unchanged, except that every bridge-side start reason maps to `start_failed`; the delivery row keeps the detailed reason.

#### 6.8.2 The four rules

| # | Rule | Enforced by |
|---|---|---|
| O1 | **One occurrence, one row.** A trigger records a given event at most once | `occurrence_key UNIQUE` and `INSERT OR IGNORE` |
| O2 | **One open run per action.** If the action has an open run (`queued`, `deferred` or `routed`), a new match is stored as `joined` to it. Otherwise it is stored as `queued` | the unique index `action_runs_one_open`; the lookup and the insert share one transaction |
| O3 | **One routed prompt per `min_interval_s`, and the later one is deferred, not dropped.** When the router takes a `queued` run and the action's last routed run started less than `min_interval_s` ago, the run becomes `deferred` with `not_before` = that start + `min_interval_s`. It is routed once, when `not_before` is reached. Default 30 s, range 5 s to 24 h | one comparison and one state change in the router |
| O4 | **Nothing is dropped silently.** Every match has a row with a state and, where it applies, a reason | the rows |

**A `routed` run is open (A1).** While its delivery waits for a busy agent or an offline machine, every later match is stored as `joined` to it and sends no prompt. The run closes when its delivery is final: `delivered` or `failed`. Only then can a new match open a new run.

The rate rule counts from the route time: `started_at` is written when the run becomes `routed`, and it is the value O3 compares. A run that later ends `failed` still counts, because its prompt was stored.

`{{run.joined_count}}` is fixed when the prompt is rendered at route time. Matches that join a `routed` run afterwards are counted in the run history only (`joined_count` of the runs route).

Matches that arrive while a run is deferred join it (O2). A run renders its prompt from its own event, not from the joined ones.

#### 6.8.3 Routing a deferred run without a hub tick

In the transaction that sets `deferred`, the router appends one deferral row (6.2.3). nats-server fires it at `not_before` and removes the definition. The fire reaches the runtime like any event and matches no trigger. The runtime reads `data.run_id` from it and hands it to the drain as a **resume hint** (6.13.1). The drain routes every open run whose `not_before` has passed, and also the hinted run, even when the hub's clock says it is not due yet. The fire is timed by the clock of nats-server, which may run ahead of the hub's clock. Without the hint, such a run would wait for an unrelated event (case C19).

A deferred run is therefore routed by the first of: its own fire, any event for any owner that arrives at or after `not_before`, or a hub start at or after `not_before`. If the fire is lost, one of the other two routes the run (case C14).

When the support state is `Unsupported` (6.3.3) nothing can wake the hub, so the run is not deferred. It is recorded as `skipped` with reason `rate_limited` (case C18).

A run can be deferred while the state is still `Unknown`. If the state then turns out to be `Unsupported`, the relay drops the deferral row (6.3.4) and no fire will come. So while the state is `Unsupported`, the drain also finishes every `deferred` run that is not yet due as `skipped`, `rate_limited`, and the runtime calls the drain once when it first reads that state (case C20).

#### 6.8.4 Closing a `routed` run

A `routed` run is closed by exactly one of:

| Closed by | New state |
|---|---|
| The pipeline reports its delivery `done` (`actions.on_delivery_final`, 6.13.4) | `delivered` |
| The pipeline reports its delivery `failed` | `failed` with the mapped reason |
| The pipeline placed the delivery again (6.11.7) | stays `routed`; `delivery_id`, `target_instance_id`, `message_id` and `rule_position` are rewritten |

Expiry needs no timer (OFF-5). `actions.expire_open_run(uow, action_id)` calls `delivery.expire` for the open run's delivery. It is called by the matcher before it looks up the open run of an action (so the next match of an action closes an expired run and opens a new one), and by the runs handler before it reads the history.

#### 6.8.5 Cases (acceptance of T10)

Each case is one named test in `src/hub/service/actions`. `min_interval_s` is 30 unless stated.

**How to read `delivered` in C1 to C20.** These tests use a fake route port that records the delivery, and a helper that reports it `done` to `on_delivery_final` at once. So `delivered` in the table means "routed, then closed by a `done` report". Where a case needs the run to stay `routed`, it says so.

| # | Test name | Situation | Expected rows |
|---|---|---|---|
| C1 | `test_c01_two_triggers_one_event` | One event matches two triggers of the same action | 1 `delivered`, 1 `joined`; one prompt |
| C2 | `test_c02_redelivery_adds_no_row` | The same event is delivered twice | no new row |
| C3 | `test_c03_cron_and_event_same_batch` | A schedule fire and a chain event arrive in one batch | 1 `delivered`, 1 `joined` |
| C4 | `test_c04_inside_interval_is_deferred` | A chain event arrives 5 s after a delivered schedule run | the row is `deferred` with `not_before` = that run's `started_at` + 30 s; it becomes `delivered` once, when a batch arrives at or after that time |
| C5 | `test_c05_after_interval_delivers` | The same, 31 s after | `delivered` at once |
| C6 | `test_c06_burst` | 50 matching events in 10 s | 1 `delivered` at once; 1 `deferred` with 48 `joined`; the deferred run is delivered 30 s after the first with `joined_count` 48. Two prompts in total |
| C7 | `test_c07_catch_up_after_downtime` | 3 schedule fires and 2 events are waiting when the runtime starts | at most 2 deliveries: one at once, and at most one deferred run that carries the rest |
| C8 | `test_c08_self_trigger_loop` | Delivering the action causes an event that matches it, repeatedly | one delivery per 30 s; no row is lost |
| C9 | `test_c09_two_actions_one_event` | One event matches triggers of two actions | each action has its own `delivered` run |
| C10 | `test_c10_trigger_newer_than_event` | The trigger was created after the event's stream time | no row |
| C11 | `test_c11_stale_rev` | A schedule fire carries an old `Heim-Trigger-Rev` | `skipped` with `stale_rev`; it neither opens nor joins a run |
| C12 | `test_c12_crash_between_commit_and_ack` | The message is redelivered after its row was committed | no new row; the open run is delivered once |
| C13 | `test_c13_first_start_ignores_history` | The consumer is created on a stream that already holds matching events | no rows |
| C14 | `test_c14_lost_deferral_fire` | The deferral fire never arrives | the deferred run is delivered by the next event, and by `drain_due` at start |
| C15 | `test_c15_disabled_while_deferred` | The action is disabled while a run is deferred | `skipped` with `disabled` when it comes due |
| C16 | `test_c16_double_resume` | The deferral fire is delivered twice, or two events arrive when the run is due | delivered once |
| C17 | `test_c17_match_after_deferred_delivery` | A new match arrives 1 s after a deferred run was delivered | a new `deferred` run with `not_before` = that delivery + 30 s |
| C18 | `test_c18_no_schedule_support` | Support state `Unsupported`; a second match arrives inside the interval | `skipped` with `rate_limited` |
| C19 | `test_c19_deferral_fire_early_clock_skew` | The deferral fire arrives 2 s before `not_before` by the hub's clock, and no other event follows | the deferred run is `delivered` by that fire |
| C20 | `test_c20_deferred_run_when_support_becomes_unsupported` | A run is deferred while the state is `Unknown`; the state then becomes `Unsupported` | the run is `skipped` with `rate_limited` on the next drain; without the state change it stays `deferred` |
| C21 | `test_c21_busy_target_joins_routed_run` | A cron every 2 minutes; the first run is routed and its delivery stays open for 10 minutes (the target is busy); then it is reported `done` | 1 run `routed` for the whole 10 minutes, then `delivered`; the 4 later fires are `joined` to it; one prompt message; `started_at` of the run is the route time |
| C22 | `test_c22_offline_pinned_machine_joins_routed_run` | The same, with a target pinned to one machine that is offline for 10 minutes and then answers | the same rows as C21; no second delivery row exists |

Tests drive time through an injected `platform.Clock` and call the matcher and router steps directly; they do not sleep for 30 s. C1 to C3, C12 and C13 also run against a real `nats-server` through `natstest`. C4 additionally has one real-server test in which nats-server delivers the `@at` fire (`test_deferral_fire_real_server`, with `min_interval_s` 5).

### 6.9 Prompt template (T9)

The matcher stores this JSON in `action_runs.event_params` when it inserts the run. All values are strings.

```json
{"type":"chain.state","id":"evt_…","chain_id":"…","task_id":"","actor":"hub","occurred_at":"…","fired_at":"…","data":{"state":"completed"}}
```

`fired_at` is the stream time of the message as RFC3339 UTC. The other keys come from the envelope; a missing key is stored as `""`. `data` holds the envelope's `data` values converted to strings (nested objects are dropped).

```odin
// src/hub/service/actions/template.odin. Pure. The result is allocated in allocator.
render :: proc(prompt: string, action: domain.Action, run: domain.Action_Run, joined_count: int, allocator: mem.Allocator) -> string
```

| Placeholder | Value |
|---|---|
| `{{event.type}}`, `{{event.id}}`, `{{event.chain_id}}`, `{{event.task_id}}`, `{{event.actor}}`, `{{event.occurred_at}}` | the keys of `event_params` |
| `{{event.data.<key>}}` | `event_params.data.<key>` |
| `{{schedule.fired_at}}` | `event_params.fired_at` |
| `{{action.id}}`, `{{action.name}}` | the action |
| `{{run.id}}` | the run |
| `{{run.joined_count}}` | the number of runs joined to this one at delivery time |

Substitution is literal and happens once: a value is never scanned for placeholders. A placeholder with optional spaces inside the braces (`{{ event.type }}`) is recognised. A known placeholder with no value becomes the empty string. An unknown placeholder is left exactly as written.

### 6.10 Placement (T3, T4)

#### 6.10.1 Types

```odin
// src/hub/service/placement/placement.odin
ANY :: "*"
Tier :: enum { Preferred, Allowed } // bots use both; every other caller leaves Preferred

// One placement rule. Each of bridge_id, provider, model is a value or ANY.
Rule :: struct { position: int, bridge_id, provider, model: string, tier: Tier }

Candidate :: struct {
	bridge_id, provider, provider_profile, model: string,
	resolved_model:    string, // the model's alias on this bridge, or ""
	bridge_created_at: string,
	provider_order:    int,    // index in the catalog order
	model_order:       int,    // index in the provider's effective model list on this bridge
	rule_position:     int,    // set by match
	tier:              Tier,   // set by match
}

Requirements :: struct {
	owner:         string,
	agent_id:      string,   // "" = do not check agent support
	features:      []string, // bridge capability flags the caller needs, e.g. "bot_deliver_v1"
	only_bridge:   string,   // "" = all of the owner's bridges
	exclude:       []string, // bridge ids to skip (bots: already tried in this round)
	prefer_bridge: string,   // "" or a bridge that wins whenever it has a matching candidate (bots: the current bridge)
}

Service :: struct { // long-lived, built at wiring; holds pointers only and caches nothing
	bridges:      ^iface.Bridge_Repository,
	agents:       ^iface.Agent_Repository,   // agent support rows
	providers:    ^provider.Provider_Service,
	registry:     ^project.Bridge_Runtime_Registry,
	entitlements: domain.Entitlement_Lookup,
	selectors:    [dynamic]Selector,         // heap; FIRST_SATISFIABLE is registered by new_service
}
new_service :: proc(bridges: ^iface.Bridge_Repository, agents: ^iface.Agent_Repository, providers: ^provider.Provider_Service,
	registry: ^project.Bridge_Runtime_Registry, entitlements: domain.Entitlement_Lookup) -> Service
service_destroy :: proc(s: ^Service)
```

#### 6.10.2 The one eligibility predicate

```odin
// Reasons, checked in this order. "" means eligible.
REASON_NOT_OWNER          :: "not_owner"
REASON_REVOKED            :: "revoked"
REASON_ENROLLMENT_PENDING :: "enrollment_pending"
REASON_PLAN_DISABLED      :: "plan_disabled"
REASON_OFFLINE            :: "offline"
REASON_NO_LIVE_CONNECTION :: "no_live_connection"
REASON_MISSING_FEATURE    :: "missing_feature"

// Can this machine take a launch for this owner now? Reads req.owner and req.features only.
bridge_eligible :: proc(s: ^Service, b: domain.Bridge, req: Requirements) -> (ok: bool, reason: string)

// The standard error for a reason: plan_disabled -> the entitlement limit error that
// require_launch_bridge_enabled builds today; offline and no_live_connection -> .Bridge_Offline;
// not_owner -> .Not_Found; the others -> .Conflict.
eligibility_error :: proc(s: ^Service, b: domain.Bridge, reason: string) -> domain.Domain_Error

// Can bridge B run provider P with model M (and profile) for agent A now?
// Does not check the bridge itself; pair it with bridge_eligible.
launchable :: proc(s: ^Service, agent_id, bridge_id, provider, model, profile: string) -> (domain.Resolved_Provider_Model, domain.Domain_Error)

// The bridge row says Online. Database status only: no live-connection, plan, revocation or feature check.
// This is NOT a launch decision. It is for code that describes or reacts to a bridge being away
// (diagnostics, redelivery, stop commands, merge re-queue). A launch decision uses bridge_eligible.
bridge_status_online :: proc(bridges: ^iface.Bridge_Repository, bridge_id: string) -> bool
```

| Reason | Condition (fields of `domain.Bridge`, `src/hub/domain/bridge.odin:10`) |
|---|---|
| `not_owner` | `b.owner_user_id != req.owner` |
| `revoked` | `b.revoked_at != ""` or `b.status == .Revoked` |
| `enrollment_pending` | `b.enrollment_pending_until != ""` |
| `plan_disabled` | the logic of `require_launch_bridge_enabled` (`src/hub/service/agent/agent_service.odin:2678`), moved here: re-read the bridge row when needed; disabled when `plan_disabled_at != ""` |
| `offline` | `b.status != .Online` |
| `no_live_connection` | `!project.bridge_runtime_registry_has_live(s.registry, b.bridge_id)` (`src/hub/service/project/runtime_registry.odin:419`), or the registry is nil |
| `missing_feature` | a name in `req.features` is not in the `features` array of `b.capabilities_json` (the parse of `bridge_feature_supported`, `src/hub/service/agent/instance_reconfiguration.odin:56`, moved here) |

`launchable` is `validate_provider_model_intersection` (`src/hub/service/agent/agent_service.odin:1635`) moved, with two additions. Steps, in order:

1. `provider` or `model` blank → `.Unprocessable_Entity`.
2. If `agent_id != ""`: read the support row with `iface.agent_get_support` (`src/hub/repository/iface/agent_repo.odin:105`). A row that exists and is not enabled → the error `resolve_provider_model` returns for that case today (`src/hub/service/agent/agent_service.odin:1608`). No row means enabled.
3. `provider.validate_profile`; the catalog provider must exist and have `state == "active"`.
4. `provider.apply_effective_models` (`src/hub/service/provider/provider_models.odin:41`); the model must equal the `model_id` of an active model, **or its `resolved_model` (the alias)**. The returned `Resolved_Provider_Model` carries the `model_id`.
5. A provider view of the bridge (`list_bridge_providers`, `src/hub/service/provider/provider_service.odin:366`) must match the provider and profile and be `enabled` with `detection_state == "present"`; otherwise `.Provider_Unavailable`.

Today's checks, and what the shared predicate requires:

| Check | Bots | Instance create | Move | Relaunch | Task lease | MCP | **Shared** |
|---|---|---|---|---|---|---|---|
| Bridge owned, `Online` | yes | yes | yes | yes | yes | yes | **yes** |
| Live connection in the registry | yes | yes | yes | yes | **no** | partly | **yes** |
| Plan allows launching | yes | yes | yes | yes | yes | yes | **yes** |
| Not revoked, not pending enrollment | no | no | no | no | yes | pending only | **yes** |
| Capability flags | bot flags | no | move flag | no | no | no | **from `Requirements.features`** |
| Agent enabled on the bridge | **no** | yes | yes | yes | if a row exists | yes | **yes** (no row = enabled) |
| Catalog provider active | **no** | yes | yes | yes | yes | yes | **yes** |
| Model active | yes | yes | yes | yes | yes | yes | **yes** |
| Model alias accepted | yes | no | no | no | no | no | **yes** |
| Provider enabled and detected on the bridge; profile valid | partly | yes | yes | yes | yes | yes | **yes** |

Quota reservation, transport readiness and the project path are not placement. They are checked at start-begin (6.12) and by the bridge.

#### 6.10.3 Candidates and the one order

```odin
// Every launchable (bridge, provider, model) of the owner. Caller-owned: the slice and its strings are
// allocated in allocator. Free by resetting that arena, or with candidates_destroy.
candidates :: proc(s: ^Service, req: Requirements, allocator: mem.Allocator) -> []Candidate
candidates_destroy :: proc(rows: []Candidate, allocator: mem.Allocator)

// Keeps the candidates some rule allows and orders them. Pure. Returns a new slice in allocator;
// its strings alias those of all.
match :: proc(rules: []Rule, all: []Candidate, allocator: mem.Allocator) -> []Candidate

// Shape and existence of a rule list. Pure checks first, then the owner's bridges and the provider catalog.
validate_rules :: proc(s: ^Service, owner: string, rules: []Rule, max: int) -> domain.Domain_Error
```

`candidates` walks the owner's bridges (`iface.bridge_list_by_owner`). It skips a bridge that fails `bridge_eligible`, is in `req.exclude`, or differs from a non-empty `req.only_bridge`. If `req.agent_id != ""` and the agent has a disabled support row for the bridge, it skips the bridge. For each remaining bridge it reads the provider views and keeps a view when it is `enabled`, has `detection_state == "present"` and `profile_state != "missing"`, and its catalog provider has `state == "active"`. For each kept view it emits one candidate per model with `state == "active"`.

`match`:

1. A rule matches a candidate when `rule.bridge_id` is `ANY` or equals the candidate's bridge; `rule.provider` is `ANY` or equals its provider; and `rule.model` is `ANY`, or equals its `model`, or equals its `resolved_model`.
2. For each candidate, the **first** rule in list order that matches decides `rule_position` and `tier`. A candidate that no rule matches is dropped.
3. When the deciding rule has `model == ANY`, only the provider's first active model on that bridge (lowest `model_order`) is kept.
4. An empty rule list keeps every candidate (all models), with `position` 0 and `tier = .Allowed`. Model collapse applies only to an explicit rule with `model == ANY`.
5. Sort, stable, by: `tier` (`Preferred` first), `rule_position`, `provider_order`, `model_order`, `bridge_created_at`, `bridge_id`. Then drop later duplicates of the same (bridge, provider, model).

This is the order bots use today (F17), so bot results do not change. Bridge age is the last tie-break. For a rule `(ANY, ANY, ANY)` the winner is the bridge that has the best-ranked provider, and the oldest such bridge when several have it.

`validate_rules` is `bots_validate_placement` (`src/hub/service/bots/placement.odin:18`) moved. It keeps the same detail codes in `details_json`: `too_many_candidates` (more than `max` rows), `unknown_bridge`, `unknown_provider`, `model_requires_provider` (provider `ANY` with a specific model), `duplicate_candidate`.

#### 6.10.4 Behaviour changes

The shared predicate changes who is eligible. Each change has one named test, in the task that causes it.

| Change | Task | Test |
|---|---|---|
| A model alias is accepted wherever a model is validated | T3 | `test_launchable_accepts_model_alias` |
| A bot is no longer placed on a provider whose catalog entry is inactive | T3 | `test_bot_skips_inactive_catalog_provider` |
| A bot is no longer placed on a bridge where its agent is disabled | T3 | `test_bot_skips_bridge_with_agent_disabled` |
| Instance create, move and relaunch refuse a revoked bridge and a bridge with pending enrollment | T3 | `test_prepare_instance_refuses_pending_bridge` |
| A task lease is not granted to a bridge whose row says `Online` but which has no live connection | T4 | `test_lease_requires_live_connection` |
| An MCP task target requires a live connection | T4 | `test_mcp_task_target_requires_live_connection` |

Every refusal carries the reason from 6.10.2. The task that causes a change lists it in its hand-off.

#### 6.10.5 Selection

```odin
Selector :: struct {
	name: string,
	ctx:  rawptr,
	// ordered is the output of match. Returns the index of the chosen candidate.
	pick: proc(ctx: rawptr, ordered: []Candidate, req: Requirements) -> (index: int, ok: bool),
}
FIRST_SATISFIABLE :: Selector{name = "first", pick = pick_first} // picks index 0

selector_register :: proc(s: ^Service, sel: Selector) // startup only; not thread-safe
selector_find     :: proc(s: ^Service, name: string) -> (Selector, bool)

// candidates -> match -> prefer_bridge -> Selector.pick.
// reason is "" on success, otherwise "no_candidate" or "unknown_selector".
// The returned Candidate's strings are allocated in allocator.
select :: proc(s: ^Service, req: Requirements, rules: []Rule, selector := "first",
	allocator := context.temp_allocator) -> (c: Candidate, ok: bool, reason: string)
```

If `req.prefer_bridge` is set and the matched list has a candidate on that bridge, `select` returns the first such candidate without calling the selector. This is the bots rule "the current bridge wins".

#### 6.10.6 The selector seam

`first` is the only selector built. A later strategy (for example one that balances by usage) is one more `Selector` registered at wiring. No caller changes, because callers pass a selector **name** and receive a `Candidate`. T3 proves this with a test that registers a second selector, `last`, and calls `select(..., selector = "last")` (`test_second_selector_needs_no_caller_change`).

#### 6.10.7 Candidates endpoint (T3)

`GET /api/v1/placement/candidates?agent_id=<id>` (user auth; `agent_id` optional). The handler is new: `src/hub/transport/http/placement_handlers.odin`, `placement_candidates_handler`. It is not behind an experiment.

```json
{"data":{
  "candidates":[{"bridge_id":"brg_…","provider":"claude","provider_profile":"","model":"opus","rank":0}],
  "bridges":[{"bridge_id":"brg_…","label":"laptop","eligible":true,"reason":""}],
  "providers":[{"provider":"claude","label":"Claude","models":["opus","sonnet"]}]
}}
```

- `candidates` is `match(nil, candidates(req))` for the caller: every launchable triple without model collapse, in the one order. `rank` is the index. The first entry is the default a UI preselects.
- `bridges` lists all of the owner's bridges, with `eligible` and `reason` from `bridge_eligible`. A rule may name a machine that is offline now.
- `providers` lists the active catalog providers with their active models, for the rule editor.

#### 6.10.8 Groundwork for "start an agent, the hub chooses" (sketch; NOT built)

```
POST /api/v1/agent-instances
{ "agent_id": "agt_…",
  "project_id": "…",                                               // optional
  "rules": [ {"bridge_id":"*","provider":"claude","model":"*"} ],  // optional; omitted = anywhere
  "selector": "first" }                                            // optional
→ 201 { "agent_instance_id": "…", "placement": {"bridge_id":"…","provider":"…","model":"…","rule_position":0,"selector":"first"} }
```

Today's request, with a required `bridge_id`, `provider` and `model`, is the special case of one fully specific rule, so it would keep working. A usage-based selector would read the per-instance token totals and the launch back-off state that already exist. Nothing in this chain builds this. The module is shaped so that building it later changes no caller.

#### 6.10.9 Inventory: what happens to each existing piece

**T3 requirements revision 4:** `validate_instance_message_configuration` retains its pre-T3 connectivity, ownership, idle-reconfiguration, project and provider/model checks. It does not apply launch bridge eligibility: plan-disabled, revoked and pending enrollment flags never refuse messages to an already-running agent. Its connectivity check is documented in the boundary-test allow-list.

| Existing code | What it is | Verdict | Task |
|---|---|---|---|
| `bots_validate_placement` (`src/hub/service/bots/placement.odin:18`) | rule list validation | **Moved** → `placement.validate_rules` | T3 |
| `bots_candidate_rank` (`src/hub/service/bots/placement.odin:42`), `Ranked_Bot_Candidate` (`src/hub/service/bots/placement.odin:50`), `bots_rank_before` (`src/hub/service/bots/placement.odin:55`) | rule matching and order | **Moved** → `placement.match` | T3 |
| `bots_expand_candidates` (`src/hub/service/bots/placement.odin:64`) | candidates of one bridge for the frame | **Redirected**: `placement.match(rules, placement.candidates(req with only_bridge))`, then converted to `contracts.Bot_Candidate_Wire`. The cap (`bot_max_local_candidates`, default 3) stays in bots | T3 |
| `bots_bridge_capable` (`src/hub/service/bots/placement.odin:110`) | capability flags | **Deleted** → `Requirements.features = {"bot_deliver_v1", "instance_reconfiguration_v1"}` | T3 |
| `bots_select_bridge` (`src/hub/service/bots/placement.odin:114`) | bridge choice; keeps the current bridge; skips tried ones | **Redirected** → `placement.select` with `prefer_bridge` and `exclude` | T3 |
| `bot_placement_options_handler` (`src/hub/transport/http/bot_handlers.odin:99`) | options list for the bots settings UI | **Kept** with its response shape; its `online` and `bot_capable` values come from `bridge_eligible` | T3 |
| `validate_provider_model_intersection` (`src/hub/service/agent/agent_service.odin:1635`) | the main "can B run P/M" check | **Moved** → `placement.launchable`. In T3 the old procedure stays as a one-line wrapper so that `taskv2` and `taskchain` compile. T4 redirects those callers and deletes the wrapper | T3, T4 |
| `validate_launchable` (`src/hub/service/provider/provider_service.odin:217`) | duplicate of the above | **Deleted**. Its HTTP caller (`src/hub/transport/http/provider_handlers.odin`) calls `placement.launchable` and maps `.Provider_Unavailable` to the `.Conflict` response it returns today. Its tests move to the placement package | T3 |
| `select_bridge_for_agent` (`src/hub/service/agent/agent_service.odin:1658`), `require_enabled_support` (`src/hub/service/agent/agent_service.odin:1529`) | no callers | **Deleted** | T3 |
| `require_launch_bridge_enabled` (`src/hub/service/agent/agent_service.odin:2678`), `bridge_feature_supported` (`src/hub/service/agent/instance_reconfiguration.odin:56`) | plan gate; capability parse | **Moved** into `placement.bridge_eligible`. Callers outside `agent` that need the capability parse call `placement.bridge_has_feature(b, name)` | T3 |
| `supported_bridge_count_for_agent` (`src/hub/service/agent/agent_service.odin:537`) | display count from a proxy | **Redirected** → the number of distinct bridges in `placement.candidates` for that agent | T3 |
| `prepare_instance` (`src/hub/service/agent/agent_service.odin:346`), `create_provider_test_instance` (`src/hub/service/agent/agent_service.odin:431`), `begin_instance_reconfiguration` (`src/hub/service/agent/instance_reconfiguration.odin:89`), `reconfiguration_validate_live_destination` (`src/hub/service/agent/instance_reconfiguration.odin:467`) | create, move | **Kept**. Their inline bridge checks become `bridge_eligible` + `launchable`. The move keeps its extra feature `instance_reconfiguration_v1` through `Requirements.features` | T3 |
| `resolve_launch_model` (`src/hub/service/taskv2/placement.odin:26`) | default provider and model picker | **Redirected** → `placement.select` with one rule `(bridge, provider or ANY, ANY)` | T4 |
| `placement_problem` (`src/hub/service/taskv2/placement_failures.odin:32`) | lease eligibility gate | **Kept** for the task-specific reasons (workspace, missing placement). Its bridge and model checks call the shared predicate and map the reasons to today's codes (`bridge_ineligible`, `bridge_offline`, `provider_ineligible`) | T4 |
| `bridge_online` (`src/hub/service/taskv2/lease.odin:1104`) | liveness from the database only; 11 callers | **Moved** → `placement.bridge_status_online` (same body, same meaning) for the ten callers that do not decide a launch. The one caller that decides a launch, the lease grant, uses `placement.bridge_eligible`. T4 lists every caller | T4 |
| `resolve_placement` (`src/hub/service/taskv2/matcher.odin:160`) | bridge fallback: task pin → fleet row → chain directory → coordinator | **Kept** as the task-specific source of rules. It builds an ordered `[]placement.Rule` (one specific-bridge rule per fallback step) and calls `placement.select` | T4 |
| `pick_instance` (`src/hub/service/taskv2/matcher.odin:328`) | which instance (waiting, live, warm, new) | **Kept**. It is instance choice, not placement | — |
| `fleet_model_on_bridge` (`src/hub/service/taskchain/taskchain_service.odin:2171`), `resolve_fleet_launch_model` (`src/hub/service/taskchain/taskchain_service.odin:2184`) | copies of the taskv2 procedures; callers in `taskchain_service.odin`, `src/hub/transport/http/taskchain_handlers.odin` and `src/hub/app/mcp_task_mutations.odin` | **Deleted** → the taskv2 original (`src/hub/service/taskv2/placement.odin:12`) and `placement.select` | T4 |
| `catalog_bridge_eligible` (`src/hub/service/mcp/catalog_read.odin:27`), `mcp_task_target` (`src/hub/app/mcp_task_mutations.odin:38`), the inline checks in `src/hub/app/mcp_runtime.odin` and `src/hub/app/mcp_chain_create.odin:15` | MCP eligibility flags | **Redirected** → `bridge_eligible` and `launchable` | T4 |
| `src/ui/components/chat/NewConversationPage.tsx:235`, `src/ui/components/tasks/fleetSelection.ts:26`, `src/ui/utils/bridgeLaunchOptions.ts:19` | client-side defaults | **Redirected** → the candidates endpoint; the UI preselects the first candidate and carries no default logic | T4 |
| The candidate loop in `bridge_bot_run` (`src/bridge/bot_delivery.odin:199`), `bridge_provider_runnable` (`src/bridge/agent_wake.odin:146`) | the bridge's own check that the binary really runs, plus back-off | **Kept**. It is a second, local step by design and uses facts only the bridge has | — |

#### 6.10.10 v7 additions to the placement contract

- **The pipeline feature.** The router passes `Requirements.features = {contracts.BRIDGE_FEATURE_EVENT_PIPELINE_V1}` (6.13.3). Nothing in the module changes for it: `missing_feature` already exists.
- **Candidates endpoint.** `GET /api/v1/placement/candidates` accepts a repeatable query parameter `feature=<name>`. Each value is added to `Requirements.features`. A bridge that lacks one is listed under `bridges` with `eligible = false` and `reason = "missing_feature"` and has no entry under `candidates`. Without the parameter the response is as in 6.10.7. T3 builds the parameter and the test `test_placement_candidates_feature_filter`; T13 uses it for the rule editor.
- Package `placement` does not import `delivery` and names no feature constant itself.

### 6.11 The delivery pipeline (T16, T17)

This section replaces section 6.11 of the v6 spec ("Wake and delivery"). Nothing of the v6 text applies.

#### 6.11.1 Subjects, stream and consumers

| Item | Value |
|---|---|
| Subject | `dlv.<owner_user_id>.<bridge_id>.<kind>`; `kind` is `prompt`, `notice`, `bot` or `lease`. Each token MUST pass `nats.subject_token` |
| Stream | `HEIM_DELIVER` (6.3.6) |
| Publish | Only through `event_outbox`, in the caller's transaction. Outbox `event_id` = `delivery_id`, so `Nats-Msg-Id` = `delivery_id` (F3). `headers_json` = `{}` |
| Consumer per bridge | Durable `brg_<bridge_id>`; `filter_subjects = ["dlv.*.<bridge_id>.>"]`; explicit ack; `ack_wait_ns` 60 s; `max_deliver` 8; `max_ack_pending` 256; `deliver_new = false` |
| Advisory stream | `HEIM_DELIVER_ADVISORIES`, subjects `["$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.HEIM_DELIVER.>"]`, limits retention, `max_age` 14 days, duplicate window 2 minutes; durable consumer `hub_delivery_dlq` (`ack_wait_ns` 1 s, unlimited `max_deliver`), modelled on `prepare_advisories` (`src/hub/service/eventinbox/runtime.odin:232`) |

Constants (package `contracts`, file `delivery_wire.odin`):

```odin
BRIDGE_FEATURE_EVENT_PIPELINE_V1 :: "event_pipeline_v1"
EVENT_DELIVER_FRAME        :: "event_deliver"
DELIVERY_ID_PREFIX         :: "dlv_"
DELIVERY_MAX_DELIVER       :: 8
DELIVERY_ACK_WAIT_MS       :: 60_000
DELIVERY_MAX_ACK_PENDING   :: 256      // bounds open deliveries per bridge, waiting retries included (N10)
DELIVERY_MAX_IN_FLIGHT     :: 16       // frames sent to one bridge and not yet answered; the hub enforces it (6.11.4)
DELIVERY_HANDLER_BUDGET_MS :: 30_000   // the bridge handler's deadline; MUST stay below DELIVERY_ACK_WAIT_MS
DELIVERY_RETRY_MIN_MS      :: 10_000
DELIVERY_RETRY_MAX_MS      :: 300_000
DELIVERY_OUTCOME_STARTED   :: "started"
DELIVERY_OUTCOME_NOTIFIED  :: "notified"
DELIVERY_OUTCOME_ACCEPTED  :: "accepted" // kind bot: the bridge took over the attempt
DELIVERY_CLASS_RETRY       :: "retry"
DELIVERY_CLASS_FATAL       :: "fatal"
DELIVERY_NOTICE_MESSAGE    :: "message" // type the chat-message notice
DELIVERY_NOTICE_EVENTS     :: "events"  // type the [events] line
```

#### 6.11.2 The delivery message and the frame

```odin
// src/contracts/delivery_wire.odin — plain structs with json tags, in the style of bot_wire.odin
Delivery_Notice_Wire :: struct {
	line:  string `json:"line"`,  // DELIVERY_NOTICE_MESSAGE | DELIVERY_NOTICE_EVENTS | ""
	count: int    `json:"count"`,
}
Delivery_Wire :: struct {
	delivery_id:       string `json:"delivery_id"`,
	kind:              string `json:"kind"`,
	owner_user_id:     string `json:"owner_user_id"`,
	bridge_id:         string `json:"bridge_id"`,
	agent_instance_id: string `json:"agent_instance_id"`,
	cause:             string `json:"cause"`,           // schedule | event | bot | lease
	ref:               string `json:"ref"`,
	conversation_id:   string `json:"conversation_id"`,
	message_id:        string `json:"message_id"`,
	notice:            Delivery_Notice_Wire `json:"notice"`,
	expires_at:        string `json:"expires_at"`,      // RFC3339 UTC; the bridge keeps its ledger entry until this time plus a margin (6.11.6, S2)
	payload:           string `json:"payload,omitempty"`, // kinds bot and lease: the complete legacy frame text
}
Event_Deliver_Wire :: struct {
	type:              string `json:"type"`,              // EVENT_DELIVER_FRAME
	command_id:        string `json:"command_id"`,        // "<delivery_id>:<attempt>"
	agent_instance_id: string `json:"agent_instance_id"`, // repeated at the top level for the bridge's ordering key
	attempt:           int    `json:"attempt"`,           // JetStream num_delivered, 1..8
	final:             bool   `json:"final"`,             // attempt == DELIVERY_MAX_DELIVER
	delivery:          Delivery_Wire `json:"delivery"`,
}
```

- The JetStream message body (the outbox `envelope_json`) is one `Delivery_Wire` object.
- `kind = prompt` and `kind = notice` carry ids and enums only. The prompt text never leaves SQLite.
- `kind = lease` carries in `payload` the exact text of a one-entry `start_agent` command (`start_command_json`, 6.12.6). `kind = bot` carries the exact text of a `Bot_Deliver_Wire` frame (`src/contracts/bot_wire.odin:31`). `payload` is a JSON string, so the bytes inside are kept as they were written. These are commands, not events: the "ids and enums only" rule of the event envelopes (`docs/plans/events-jetstream-spec.md:26`) does not bind them. They sit in a private stream and are removed when acked (v7-Q6).
- The message carries no run generation. The hub hands it out at start-begin (6.12).
- `command_id` differs per attempt (V13). The delivery id is the text before the last `:`.

**The answer.** The bridge answers with the existing `command_result` frame. Three fields are added under `payload.result`, all `omitempty`:

| Field | Values | Present when |
|---|---|---|
| `outcome` | `started`, `notified`, `accepted` | `payload.status = "succeeded"` |
| `class` | `retry`, `fatal` | `payload.status = "failed"` |
| `retry_after_ms` | integer ≥ 0; 0 or absent = "use the hub's schedule" | `class = "retry"` |

A failed answer also carries the existing typed `error` object. Its `cause` is the reason code of 6.11.9. The bridge builds it with `bridge_cause_wire_error` (`src/bridge/result_error.odin:56`). An old hub ignores the new fields.

#### 6.11.3 Package `delivery`: types and API

```odin
// src/hub/service/delivery/delivery.odin
Route_Input :: struct {
	kind, owner_user_id, bridge_id, agent_instance_id: string,
	cause, ref, conversation_id, message_id:           string,
	notice_line:      string,        // "" for kinds bot and lease
	notice_count:     int,
	payload:          string,        // kinds bot and lease
	lifetime:         time.Duration, // expires_at = now + lifetime
	round:            int,           // 0 for a first routing
	excluded_bridges: []string,      // bridges already tried for this ref
}
LIFETIME_PROMPT :: time.Hour        // v7-Q7
LIFETIME_NOTICE :: 5 * time.Minute  // the inbox sends a fresh notice anyway
LIFETIME_FLOW   :: 24 * time.Hour   // kinds bot and lease: the flow's still_valid decides earlier

Replace_Why :: enum { Bridge_Offline, Fatal_Answer, Downgrade }

// One per kind, registered at wiring before start. Every procedure runs on the calling thread, inside the
// unit of work that is passed in, and MUST do database work only (no NATS call, no bridge command).
Sink :: struct {
	ctx:  rawptr,
	kind: string,
	// The delivery is final: d.state is done or failed. Called exactly once per delivery.
	on_final:    proc(ctx: rawptr, uow: ^iface.Unit_Of_Work, d: domain.Pipeline_Delivery),
	// May d still be forwarded? nil = always. Example: the lease is still held and unconfirmed.
	still_valid: proc(ctx: rawptr, uow: ^iface.Unit_Of_Work, d: domain.Pipeline_Delivery) -> bool,
	// Try to place d on another machine. nil = this kind never moves. The flow calls delivery.route with
	// round = d.round + 1 and excluded_bridges = d's list plus d.bridge_id. True + no error means it routed a replacement.
	// False + no error means no placement. Any error (including delivery.route errors) aborts the whole UoW.
	replace:     proc(ctx: rawptr, uow: ^iface.Unit_Of_Work, d: domain.Pipeline_Delivery, why: Replace_Why) -> (bool, domain.Domain_Error),
}

Service :: struct { /* long-lived; heap; fields are an implementer choice */ }

new_service   :: proc(factory: ^iface.Unit_Of_Work_Factory, bridges: ^iface.Bridge_Repository,
	registry: ^project.Bridge_Runtime_Registry, commands: ^project.Bridge_Command_Sink,
	clock: ^platform.Clock, ids: ^platform.ID_Generator, options: nats.Connect_Options) -> ^Service
register_sink :: proc(s: ^Service, sink: Sink)   // before start; a second sink for one kind is a programming error (panic)
start         :: proc(s: ^Service) -> bool       // starts the supervisor thread
stop          :: proc(s: ^Service)               // stops and joins every thread; frees everything

// Pure. True when the bridge's stored hello lists event_pipeline_v1.
bridge_capable :: proc(b: domain.Bridge) -> bool

// Appends the pipeline_deliveries row (state routed) and the event_outbox row in the caller's unit of work.
// No network I/O. Errors: Validation_Failed (a subject token is invalid, unknown kind, lifetime <= 0, round >= DELIVERY_MAX_ROUNDS);
// Conflict with message "bridge_too_old" (the bridge row does not list the feature); Not_Found (no such bridge for this owner).
// delivery_id is allocated in context.temp_allocator.
route :: proc(s: ^Service, uow: ^iface.Unit_Of_Work, input: Route_Input) -> (delivery_id: string, err: domain.Domain_Error)

// Closes the delivery as failed/bridge_offline when it is open and expires_at <= now. closed = true when it did.
// Calls the kind's on_final inside uow.
expire :: proc(s: ^Service, uow: ^iface.Unit_Of_Work, delivery_id: string) -> (closed: bool)

// Hooks. Each opens its own unit of work(s). None waits for a bridge answer.
on_bridge_online  :: proc(s: ^Service, bridge_id: string)                          // after a successful hello
on_bridge_offline :: proc(s: ^Service, bridge_id: string)                          // the bridge has no live connection any more
on_bridge_deleted :: proc(s: ^Service, bridge_id: string)                          // the bridge was revoked
on_command_result :: proc(s: ^Service, bridge_id, command_id, result_json: string) // command_result whose id starts with "dlv_"
```

`route` is the only way a delivery is created. It does not check that the bridge is online; the caller's placement did (OFF-1).

**Wiring** (`src/hub/app/wiring.odin`, T16): build the service after the relay; register the sinks of the flows that exist; `delivery.start` directly after `eventrelay.start`; `delivery.stop` directly before the relay is stopped. Hooks:

| Hook | Where it is called |
|---|---|
| `on_bridge_online` | In the hello sequence, on the line after `bots.bots_on_bridge_hello` (`src/hub/transport/http/bridge_handlers.odin:1889`) |
| `on_bridge_offline` | In `bridge_ws_disconnect`, next to `taskv2.on_bridge_placement_changed` (`src/hub/transport/http/bridge_handlers.odin:1999`): only when the bridge is offline and was not replaced by a newer connection |
| `on_command_result` | In the `command_result` fan-out, next to the bots line (`src/hub/transport/http/bridge_handlers.odin:2556`): `if h.delivery != nil && type == "command_result" && strings.has_prefix(command_id, contracts.DELIVERY_ID_PREFIX) do delivery.on_command_result(h.delivery, bridge_id, command_id, text)` |
| `on_bridge_deleted` | After a successful `revoke_bridge` (`src/hub/service/bridge/bridge_service.odin:605`), in its HTTP handler |

`Bridge_Handlers` (`src/hub/transport/http/bridge_handlers.odin:41`) gains the field `delivery: ^delivery.Service`.

#### 6.11.4 Threads, forwarders and the forward gate

Package `delivery` owns one NATS connection and these threads. Each follows the memory rules of 6.1.

| Thread | Count | Blocks on | Does |
|---|---|---|---|
| Supervisor | 1 | `nats.fetch` on the advisory consumer (1 s server-side wait, like the matcher's fetch) | Connects; creates the advisory stream and consumer; at start and after every reconnect runs `expire_due` and wakes every forwarder; drains advisories (6.11.8) |
| Forwarder | 1 per bridge that ever connected with the feature since hub start | its semaphore while the bridge is not live, NATS is not connected, or the in-flight limit is reached; otherwise `nats.fetch(pull, n, 1000)` | Forwards deliveries of its bridge; sends the JetStream answers for its bridge (the answer queue below) |

There is no sleep and no timer in the package: a thread either waits on a semaphore that an event signals, or blocks in a JetStream fetch. `grep -n "time.sleep\|thread.sleep" src/hub/service/delivery/*.odin` MUST print nothing outside test files.

**Who may touch the NATS connection.** Only the supervisor and the forwarders call package `nats`. `on_command_result`, `route`, `expire` and the bridge hooks run on other threads (a WebSocket reader, a request handler) and MUST NOT make any NATS call: they write rows and, where an answer needs a JetStream call, put it on the bridge's answer queue.

```odin
// Guards Service.conn. Shared: held by a forwarder or the supervisor around every nats call, including the whole
// processing of a fetched batch (its messages belong to the connection). Exclusive: held by the supervisor only,
// to close and replace the connection. Service.connected is written under the exclusive lock.
Service.conn_lock: sync.RW_Mutex
// Per forwarder; guarded by Forwarder.mutex, which is a leaf lock: nothing else is taken while it is held.
Answer_Op :: enum { Ack, Nak_Delay, In_Progress, Term }
Answer    :: struct { op: Answer_Op, reply: string, delay_ms: i64 } // reply is cloned into the queue's own allocator
Forwarder.answers: [dynamic]Answer
```

Lock order: `conn_lock`, then a unit of work, then `Forwarder.mutex`. A thread never acquires `conn_lock` while it is inside a unit of work, and never begins waiting on a semaphore while it holds `conn_lock`. The supervisor releases every lock before it opens a unit of work for `expire_due`. Enqueueing an answer signals the forwarder's semaphore; it does not wait. An answer for a bridge that has no forwarder is dropped: the message is redelivered after AckWait and the gate handles it. Answers still queued when the connection is replaced are dropped for the same reason (their reply subjects stay valid on the server, but dropping is simpler and safe).

All four answer calls on the forwarder are plain publishes followed by nothing: the forwarder does not wait for the server's response to an ack. `nats.ack_reply` with its 2000 ms request (`src/lib/nats/nats.odin:330`) is **not** used by the pipeline; T1 adds `ack_reply_async` (6.3.5). A lost ack costs one redelivery, which the gate acks because the row is closed.

A forwarder is created by the first `on_bridge_online` of a capable bridge and lives until `stop` or `on_bridge_deleted`. `on_bridge_online` and the supervisor's reconnect step signal its semaphore. `on_bridge_offline` does not stop it: the forwarder sees that the bridge is not live (`project_service.bridge_runtime_registry_has_live`, `src/hub/service/project/runtime_registry.odin:419`) and waits. At most 256 forwarders exist; a capable bridge beyond that is logged once and counted in `Service.forwarders_refused`, and its deliveries wait in the stream (risk V-K3).

**One forwarder pass**

1. If NATS is not connected or the bridge has no live connection: wait on the semaphore; start again.
1a. Take `conn_lock` shared for the rest of the pass. Drain the answer queue: swap it out under `Forwarder.mutex`, then make each call.
1b. **In-flight limit.** In one read-only unit of work, `n = DELIVERY_MAX_IN_FLIGHT - in_flight(bridge_id, now - DELIVERY_ACK_WAIT_MS)`. If `n <= 0`: release `conn_lock`, wait on the semaphore for at most 1 s (`sync.sema_wait_with_timeout`), start again. Every answer signals the semaphore, so the wait normally ends at once when a slot frees; the 1 s bound only covers answers that never arrive, whose rows leave the count when they are older than AckWait.
2. If this forwarder has no pull binding for the current connection: `nats.consumer_add` with the settings of 6.11.1 (an existing durable is kept), then `nats.pull_bind(conn, "HEIM_DELIVER", "brg_<bridge_id>")`.
3. `nats.fetch(pull, n, 1000)`. For each message, run the gate below. Destroy the batch on every path.
4. Release `conn_lock`. `free_all(context.allocator)`.

The limit exists because the bridge's dispatcher queues at most 32 lifecycle commands (`src/bridge/hub_command_dispatch.odin:121`) and refuses the rest. It is counted in the database and not through `MaxAckPending`, because a delivery that waits for a delayed retry holds a `MaxAckPending` slot for the whole delay (N10): with a limit of 16 there, sixteen prompts for busy agents would hold back every other delivery of that bridge for up to 15 minutes. A waiting retry has `retry_at` set and is not in flight. `DELIVERY_MAX_ACK_PENDING` (256) only bounds how many open deliveries one bridge can have in total; reaching it needs 256 deliveries that are in flight or waiting for a retry at once (risk V-K18).

**The forward gate, for one message** (REQ-PIPE-3, REQ-PIPE-10)

1. Read `num_delivered` and `stream_sequence` from `nats.message_metadata`, and the reply subject from `nats.message_reply` (`src/lib/nats/nats.odin:324`). Parse the body into `Delivery_Wire`. A body that does not parse or has no `delivery_id` is terminated with `nats.term` and counted.
2. Begin a unit of work. Load the row.

| Row | Action |
|---|---|
| Not found | `nats.term`; count it |
| `done`, `failed` or `replaced` | `nats.ack`. Nothing is forwarded |
| Open and `expires_at <= now` | `expire`; commit; `nats.ack` |
| Open and the kind's `still_valid` returns false | write `failed`, reason `superseded`; `on_final`; commit; `nats.ack` |
| Open otherwise | step 3 |

3. In the **same** unit of work that loaded the row: `transition` to `forwarded` (from the state just read, `routed` or `forwarded`) with `attempt = num_delivered`, `ack_reply`, `stream_sequence`, `retry_at = ""`, `updated_at`, and `forwarded_at` if it is empty. **Commit.** If `changed` is false, another thread closed the row in between: treat it as the closed-row case (`nats.ack`, no frame).
4. Only after the commit: build `Event_Deliver_Wire` (`final = attempt >= DELIVERY_MAX_DELIVER`) and send it with `project_service.bridge_command_send_runtime` (`src/hub/service/project/project_service.odin:82`).
5. If the send reports failure: make **no** JetStream call. The message stays pending and is redelivered after AckWait (60 s). The row stays `forwarded`; it is never moved back to `routed`, because a failed socket write may have sent part of the frame. The forwarder ends this pass without handling the rest of the batch (those messages are redelivered too) and, before its next pass, waits on its semaphore for at most 5 s. A failed send therefore costs one of the 8 attempts per minute at most, not one every few seconds, so a connection that is reported live while its writes fail cannot use up a delivery before the disconnect is noticed (risk V-K19).

**Every transition acts on `changed`.** Load and `transition` always happen in one unit of work (units of work are serialised, so this costs nothing). `on_final`, `replace` and the JetStream answer run only when the transition changed the row. This is what makes "`on_final` is called exactly once per delivery" true. It applies to the gate, to `on_command_result`, to `expire`, to the offline rules and to the advisory handler.

**Repository failures (T16 review correction).** A repository or replacement callback error aborts the entire unit of work, including any replacement row and outbox writes. Do not fall through to finalization or queue a JetStream answer. Redelivery can retry the operation. If a replacement was written but the original row's compare-and-set changed nothing, abort that unit of work too. `Sink.replace` must propagate errors from `delivery.route`; it must not turn an error into `false` with no error. This bool/error contract correction was approved by the coordinator during T16 review.

The forwarder does not ack, nak or terminate a forwarded message by itself in any other case. The message stays pending until the answer arrives (6.11.5) or AckWait passes.

Because `forwarded` is committed before the frame is sent, **a delivery in state `routed` has certainly never reached a bridge.**

#### 6.11.5 What the hub does with the answer

`on_command_result` runs on the bridge's WebSocket reader thread. It does database work only and never calls NATS: the JetStream column of the table below is put on the bridge's answer queue after the commit, and that bridge's forwarder makes the call (6.11.4), normally within milliseconds and at worst after its current fetch returns (1 s). It parses the delivery id and the attempt from `command_id`, the status with `jsonx.extract_string(text, "status", top_level_only = false)` (as the bots line does, `src/hub/transport/http/bridge_handlers.odin:2557`), `outcome`, `class` and `retry_after_ms` the same way, and the reason from `contracts.wire_error_parse` (field `cause`).

It loads the row. It ignores the answer when the row is missing, belongs to another bridge, or is not `forwarded`. A closed row makes every later answer a no-op: result handling is idempotent (REQ-PIPE-4).

| Answer | Hub state (one unit of work; later columns apply only when `changed`) | JetStream (queued after the commit) |
|---|---|---|
| `accepted` | none | `In_Progress`, only when the answer's attempt equals `row.attempt` |
| `succeeded` (from any attempt) | row → `done` with `outcome` (`notified` when the field is missing); `on_final` | `Ack` |
| `failed`, class `retry`, answer's attempt = `row.attempt` < 8 | `reason` and `retry_at = now + delay` are stored on the row (a `transition` from `forwarded` to `forwarded`); the state stays `forwarded` | `Nak_Delay` with `retry_delay_ms(row.attempt, retry_after_ms)` |
| `failed`, class `retry`, on attempt 8 | as `fatal` with reason `no_answer` (a bridge MUST NOT send this, REQ-BRG-4) | `Term` |
| `failed`, class `fatal` or no class, answer's attempt = `row.attempt` | the kind's `replace(…, .Fatal_Answer)` when `row.round < DELIVERY_MAX_ROUNDS - 1`; true → row `replaced`; otherwise row → `failed` with the answer's reason (`start_failed` when it is empty) and `on_final` | `Term` |
| `failed` from an older attempt | none | none |
| no answer | none | redelivery after AckWait (60 s) |

```odin
// Pure. attempt is 1-based. 10 s, 20 s, 40 s, 80 s, 160 s, 300 s, 300 s for attempts 1 to 7: 910 s in total.
retry_delay_ms :: proc(attempt: int, asked_ms: i64) -> i64 // clamp(max(asked_ms, 10_000 << (attempt-1)), 10_000, 300_000)
```

If a queued JetStream call fails or is dropped, nothing is rolled back: the message is redelivered later and the forward gate acks it, because the row is closed.

A `fatal` answer is the bridge stating that it did not act. That is why such a delivery may be placed again (OFF-4).

The live status of the instance keeps coming from the bridge's `agent_instance_status` frames and heartbeat, as today.

#### 6.11.6 The bridge executor (T17)

The bridge handles the command type `event_deliver`. The handler runs on a dispatch worker (never on the WebSocket reader). The dispatcher sends `accepted` by itself when it queues the command (V13), serialises commands of one instance through the ordering key `agent:<agent_instance_id>`, and gives the handler a deadline of `DELIVERY_HANDLER_BUDGET_MS`.

**Ledger** (`src/bridge/event_ledger.odin`). Keyed by `delivery_id`.

```odin
Bridge_Ledger_State  :: enum { In_Progress = 1, Done = 2 }
Bridge_Ledger_Effect :: enum { Type = 1, Start = 2, Flow = 3 } // what the in-progress attempt set out to do
Bridge_Ledger_Entry  :: struct { id: string, state: Bridge_Ledger_State, effect: Bridge_Ledger_Effect, outcome: string, at_ms: i64, expires_ms: i64 }
BRIDGE_LEDGER_MAX_ENTRIES :: 4096
BRIDGE_LEDGER_MARGIN_MS   :: i64(10 * 60 * 1000)      // kept this long after the delivery's expires_at (S2, REQ-SCALE-1)
BRIDGE_LEDGER_FALLBACK_MS :: i64(48 * 60 * 60 * 1000) // life of an entry whose expires_at is missing or does not parse

bridge_event_ledger_load  :: proc()                                         // once, before bridge_hub_runtime_start
bridge_event_ledger_get   :: proc(id: string) -> (Bridge_Ledger_Entry, bool) // the returned strings are temp-allocated copies
// Writes In_Progress. ok = false when the ledger holds BRIDGE_LEDGER_MAX_ENTRIES live entries or the file cannot be written.
// expires_ms is the delivery's expires_at in Unix ms, or 0 when it is missing or does not parse.
bridge_event_ledger_begin :: proc(id: string, effect: Bridge_Ledger_Effect, now_ms, expires_ms: i64) -> (ok: bool)
bridge_event_ledger_done  :: proc(id, outcome: string, now_ms: i64) -> (ok: bool)
bridge_event_ledger_forget :: proc(id: string)                               // removes an In_Progress entry after a retry or fatal answer
```

- File: `event-ledger-v1.json` in the directory of `bridge_agent_token_store_path()` (`src/bridge/agent_token_store.odin:155`), beside `retry-journal-v1.json` (`src/bridge/retry_journal.odin:31`). Written with `bridge_retry_atomic_write` (`src/bridge/retry_journal.odin:114`).
- Disk shape: `{"version":1,"entries":[{"id":"dlv_…","state":2,"effect":1,"outcome":"notified","at_ms":1795000000000,"expires_ms":1795003600000}]}`. Enums are stored as integers, as the retry journal does.
- **Expiry is the only eviction rule (amendment S2, REQ-SCALE-1).** An entry is dropped when `now > expires_ms + BRIDGE_LEDGER_MARGIN_MS`, or, when `expires_ms` is 0, when `now - at_ms > BRIDGE_LEDGER_FALLBACK_MS`; at load and before every write. A full ledger never drops a live entry: `begin` returns false and the executor answers `retry`. Why this is safe: the hub never forwards a delivery after its `expires_at` (the forward gate closes it, 6.11.4), so the last frame of a delivery leaves the hub before `expires_at` by the hub's clock. The margin covers that frame's travel and handling (at most the handler budget, 30 s) and a bridge clock that runs ahead of the hub's by less than the rest of the margin. A bridge whose clock is wrong by more than about 9 minutes can act twice on a redelivery; that is risk S-K9. Why it matters: with a flat 48 hours the cap of 4096 entries allowed about 85 deliveries per bridge per hour; with this rule the ledger holds rate × (lifetime + margin), about 100 entries for 85 prompts per hour. Kinds `bot` and `lease` (lifetime 24 hours) gain a factor of two only.
- A missing file is an empty ledger. A file that does not parse, has another version or holds more than the cap is logged, renamed to `event-ledger-v1.json.corrupt` and replaced by an empty ledger. (This is the lenient rule of the task notice queue, not the fail-closed rule of the retry journal: a lost ledger costs at most one extra notice line.)
- One mutex guards the map and the file. Heap-allocated; the load runs next to `bridge_agent_wake_init` (`src/bridge/main.odin:265`), before `bridge_hub_runtime_start` (`src/bridge/main.odin:278`).
- **Write order.** `In_Progress` is written before any effect. `Done` with the outcome is written after the notice was typed or the launch call returned, and before the answer is sent. After an answer of `retry` or `fatal` the entry is forgotten, so the next attempt starts clean.

**Local state of the target instance.** From `bridge_runtime_instance_snapshot` (`src/bridge/hub_runtime_client.odin:3565`):

| Name | Condition |
|---|---|
| *absent* | no snapshot, or `!bridge_runtime_status_active(snap.runtime_status)` (`src/bridge/hub_runtime_client.odin:3978`) |
| *stopping* | `runtime_status == "stopping"` |
| *booting* | active, not stopping, and `!bridge_bot_ready(snap)` (`src/bridge/bot_delivery.odin:339`): the process exists but has not sent start-success |
| *idle* | ready and `snap.activity_status == "idle"` |
| *busy* | ready and any other activity (`active`, `unknown`) |

**Decision table for kinds `prompt` and `notice`** (REQ-BRG-1). Rows are checked in this order. "final" is the frame's `final` flag.

| # | Condition | Action | Answer |
|---|---|---|---|
| 0 | The frame does not parse, or `delivery.delivery_id`, `agent_instance_id` or `kind` is empty or unknown | none | `failed`, `fatal`, reason `invalid_frame` |
| 1 | Ledger: `Done` | none | `succeeded`, the stored outcome |
| 2 | Ledger: `In_Progress` and a worker for this delivery is alive | cannot be observed: the ordering key runs one command per instance at a time, so the later attempt waits in the dispatcher (which already answered `accepted`) and then finds row 1 or row 3 | — |
| 3 | Ledger: `In_Progress` (the bridge restarted mid-attempt), effect `Start`, and the instance is *booting*, *idle* or *busy* | write `Done`, outcome `started`. A running instance counts as the earlier attempt's success | `succeeded`, `started` |
| 3b | Ledger: `In_Progress`, any other case | continue with rows 4 to 9 as if there were no entry (effect `Type` types again: at worst one extra notice line) | as that row says |
| 4 | Bridge is draining or the vault is locked (`bridge_bot_busy_reason`, `src/bridge/bot_delivery.odin:95`) | none | not final: `failed`, `retry`. final: `failed`, `fatal`, reason `draining` or `vault_locked` |
| 5 | *stopping* | none | not final: `failed`, `retry`, `retry_after_ms` 5000. final: treat as *absent* |
| 6 | *booting* | none: the agent finds the stored message through the start-success step (V5) | `succeeded`, `started` |
| 7 | *idle* | ledger `begin(Type)`; type the notice (below); ledger `done` | `succeeded`, `notified`. If typing reports failure: not final `failed`, `retry`; final `failed`, `fatal`, reason `notice_failed` |
| 8 | *busy*, not final | none (the message notice presses ESC and would interrupt the turn, `src/bridge/pty_host_runtime.odin:794`) | `failed`, `retry`, `retry_after_ms` 0 |
| 8b | *busy*, final | as row 7: type anyway, as a user message does today (v7-Q3) | as row 7 |
| 9 | *absent* | ledger `begin(Start)`; start (below); ledger `done` on success | success: `succeeded`, `started`. Retriable failure: not final `failed`, `retry`, `retry_after_ms` = the bridge's own back-off; final `failed`, `fatal`. Fatal failure: `failed`, `fatal` |
| — | Ledger `begin` returned false in row 7, 8b or 9 | none | not final: `failed`, `retry`, `retry_after_ms` 60000. final: `failed`, `fatal`, reason `ledger_full` |

There is **no user-stop check** in this table (B3). The 15 s stop-intent mark is not consulted.

A `final` attempt always ends with `succeeded` or with `failed` and class `fatal` (REQ-BRG-4).

**Typing the notice**

| `notice.line` | Call |
|---|---|
| `message` | exactly what `notify_agent_message` does (`src/bridge/hub_runtime_client.odin:1225`): `bridge_rollover_queue_notice(instance_id, "user") \|\| bridge_pty_host_deliver_to_agent(instance_id, "message", "user", "", "")` |
| `events` | `bridge_pty_host_deliver_to_agent(instance_id, "task_nudge", "events", "", "", human_message = line)` (`src/bridge/pty_host_runtime.odin:850`) with `line = fmt.tprintf(contracts.EVENTS_NOTICE_FORMAT, notice.count)`. `EVENTS_NOTICE_FORMAT` is the text of `src/hub/app/wiring.odin:1389`, moved to `contracts` by T18 so the hub's old path and the bridge share it |

**Starting** (REQ-BRG-3). `bridge_event_start(instance_id, delivery_id, deadline_ns) -> Bridge_Wake_Result`, built on the wake machinery (T17 splits `bridge_task_wake_if_needed`, `src/bridge/agent_wake.odin:205`):

1. Under `bridge_wake_mutex`: if the instance became active meanwhile → result `Already_Active`. Evaluate `bridge_wake_gate` (`src/bridge/agent_wake.odin:111`) with the parked instance's unpark trigger, as today.
2. Gate `Coalesced` → retriable, `retry_after_ms` = the rest of the 30 s window. `Backing_Off` → retriable, `retry_after_ms` = `next_at_ms - now`. `Parked` → fatal, reason `start_parked`.
3. Gate `Wake`: record `last_wake_ms` and the generation, release the mutex, then call start-begin (6.12.3). Classify a failure by 6.12.4.
4. Launch: `bridge_runtime_launch_agent(command_id, launch_json, deadline_ns)` (`src/bridge/hub_runtime_client.odin:2749`) with the launch command and command id that start-begin returned. No other launch call may be added.
5. Record the result with `bridge_task_wake_record_result` (`src/bridge/agent_wake.odin:263`), as today, so back-off and parking stay shared with the other wake callers.
6. A launch failure is classified by `err.class`: `.retriable` → retriable with `err.retry_after_ms`; `.recoverable` and `.fatal` → fatal, reason `launch_failed`. After a failed launch the bridge reports the failed status as the wake path does (`bridge_wake_report_failed_status`, `src/bridge/hub_runtime_client.odin:2676`), which lets the hub release the reservation (10.2).

`Already_Active` is answered `succeeded`, `started`. A start-begin that the hub refuses with `already_running` is answered `started` **only** when the bridge's own snapshot shows a process for the instance; with no snapshot it is `failed` / `retry` after 30 s, and `failed` / `fatal` with reason `hub_row_live` on the final attempt (6.12.4, "A live row on the hub"). A delivery is therefore never closed as delivered when nothing on this bridge will act on it.

**Kinds `lease` and `bot`.** Row 0, row 1 and the ledger rules apply. The effect is `Flow`; the handlers are specified in T20 and T19. Before those tasks, the executor answers `failed`, `fatal`, reason `unknown_kind` for them.

#### 6.11.7 Offline rules

| # | Rule |
|---|---|
| OFF-1 | A delivery is routed only to a bridge that is eligible at that moment: live connection and feature included (the caller's `placement` call). **One exception:** a target that names exactly one machine (target kind `instance`, or rules that all name the same bridge) is routed to that machine even when it is offline, and waits there under OFF-3 (v7-Q7, 6.13.3, deviation D8) |
| OFF-2 | `on_bridge_offline(bridge)`: for every delivery of that bridge in state **`routed`**, call the kind's `replace(…, .Bridge_Offline)` when `round < DELIVERY_MAX_ROUNDS - 1`. True → the old row becomes `replaced`. False, or no `replace` → the row is left as it is and waits (OFF-3). Because the frame was never sent, the first machine cannot have acted. At most 3 rounds (rounds 0, 1, 2) |
| OFF-2b | A delivery in state **`forwarded`** is never placed again on a disconnect: the bridge may have started the agent or typed the notice and only the answer was lost. It waits. On reconnect the message is redelivered and the bridge ledger answers with the stored outcome. If the bridge does not return, OFF-3 expiry applies |
| OFF-3 | A delivery that cannot move waits in the bridge's consumer and is forwarded when the bridge reconnects, if it has not expired. Lifetimes: `LIFETIME_PROMPT` 1 h, `LIFETIME_NOTICE` 5 min, `LIFETIME_FLOW` 24 h with the flow's `still_valid`. An expired delivery is `failed`, `bridge_offline` |
| OFF-4 | A bridge that is online but keeps failing: delayed retries up to 8 attempts (about 15 minutes). The last attempt carries `final = true`, and the bridge must then answer for good. A `fatal` answer is placed again where the kind allows (6.11.5) |
| OFF-5 | Expiry needs no timer. It is applied: at the forward gate; in `on_bridge_online` for that bridge's open rows; at hub start and after a NATS reconnect (`expire_due`, all bridges); when the same action gets its next match and when its run history is read (6.8.4). A one-shot or disabled action has no next match: its expired run is closed by one of the others, and until then the history shows it as `routed` with an `expires_at` in the past. The message leaves the stream after 24 h |

**Replacing.** When `replace` returns true the pipeline writes the old row `replaced` in the same unit of work. The old JetStream message stays in the old bridge's consumer; the forward gate acks it when that bridge returns. The flow's `replace` is responsible for its own data (for a prompt: 6.13.5).

**Downgrade.** `on_bridge_online` of a bridge that does **not** report the feature: every open delivery of that bridge is handled in one unit of work — `routed` rows through `replace(…, .Downgrade)`, and every row that was not replaced becomes `failed`, `bridge_too_old`, with `on_final`. Then its forwarder is stopped and its consumer is deleted (`nats.consumer_delete`, `src/lib/nats/nats.odin:221`).

**Deleted bridge.** `on_bridge_deleted`: every open delivery of that bridge becomes `failed`, `target_missing`, with `on_final`; the forwarder is stopped; the consumer is deleted. Its messages leave the stream by `max_age`.

#### 6.11.8 Exhausted deliveries

The supervisor drains `hub_delivery_dlq` with `nats.fetch(advisory, 20, 1000)`. For each advisory it decodes `stream`, `consumer` and `stream_seq` (N7):

1. `stream != "HEIM_DELIVER"` or `stream_seq == 0` → ack the advisory, stop.
2. `nats.stream_get(conn, "HEIM_DELIVER", stream_seq)` (`src/lib/nats/nats.odin:336`). JetStream error 10037 (no such message) → ack the advisory, stop.
3. Parse the body's `delivery_id`. In one unit of work: if the row is open → `failed`, reason `no_answer`, `on_final`. It is **not** placed again: it was forwarded, so the bridge may have acted.
4. `nats.stream_delete_message(conn, "HEIM_DELIVER", stream_seq)`: an exhausted message is not removed from a work-queue stream by itself (N7).
5. Ack the advisory.

The advisory is emitted only while the forwarder has a pull waiting (N7). For a bridge that is away, the advisory comes when it returns; until then expiry (OFF-5) closes the delivery.

#### 6.11.9 Delivery reasons

| `reason` | Set by | Meaning |
|---|---|---|
| `bridge_offline` | hub | expired before a final answer |
| `no_answer` | hub | 8 attempts without a final answer |
| `bridge_too_old` | hub | the bridge reconnected without the feature |
| `target_missing` | hub, bridge | the bridge was deleted; or start-begin answered 404 |
| `superseded` | hub | the flow's `still_valid` returned false |
| `start_refused` | bridge | start-begin answered another 4xx (plan, quota, provider or model) |
| `hub_row_live` | bridge | start-begin answered `already_running` on the final attempt and this bridge has no process for the instance (6.12.4) |
| `start_parked` | bridge | the wake state is parked: the provider cannot run on this machine |
| `launch_failed` | bridge | `bridge_runtime_launch_agent` failed with a non-retriable error |
| `start_failed` | hub | a fatal answer without a reason |
| `draining`, `vault_locked`, `notice_failed`, `ledger_full` | bridge | the last attempt hit this condition |
| `invalid_frame`, `unknown_kind` | bridge | the frame cannot be handled by this bridge build |

#### 6.11.10 Housekeeping without a timer

`delivery.prune` deletes closed rows older than 30 days, through the index `pipeline_deliveries_closed` (6.4.1). It is called at the end of `expire_due` (hub start and NATS reconnect) and, since amendment S2 (REQ-SCALE-3), also when a delivery becomes final, at most once per hour: `Service.last_prune_ms` is an atomic `i64`; the code that just committed a `done` or `failed` transition compares it with the clock, and when an hour has passed it swaps the value (compare-and-swap, so one thread wins) and runs `prune` in a unit of work of its own, after its commit. A hub that stays up therefore prunes while deliveries flow, and a hub with no deliveries has nothing to prune. This is not a timer: nothing runs when nothing happens. Rows are **not** deleted when they become final: the run history and re-placement (`ref`, `excluded_bridges`) read them.

#### 6.11.11 Feature gating

| Case | Behaviour |
|---|---|
| New hub, bridge without `event_pipeline_v1`, **actions** | The feature is a placement requirement: the router passes `Requirements.features = {contracts.BRIDGE_FEATURE_EVENT_PIPELINE_V1}` (6.10.1). Such a bridge is not a candidate. When the only machines the rules allow lack the feature, the run is `failed`, `bridge_too_old` instead of `no_placement` (6.13.3) |
| New hub, old bridge, **notices, bots, task leases** | Each flow checks `delivery.bridge_capable` per bridge and uses today's code path when it is false. The old paths stay (REQ-FLOW-4) |
| A bridge reconnects without the feature | Downgrade rule of 6.11.7 |
| Old hub, new bridge | The bridge reports a feature the hub does not know; `event_deliver` is never sent |
| Bridge built before T8 with a new hub | Its own scheduler gets 404 from the removed routes and fires nothing (risk K15) |
| Rollout order | Hub first, then bridges (T14) |

### 6.12 One start path: start-begin on the hub, one launcher and one start command on the bridge (T22 to T25, T17)

**Rewritten by amendment S2** (user decisions S-A to S-D, section 2). This section replaces section 6.12 of the v6 spec and section 6.12 of this spec as approved in S1. It is the only definition of how an agent process is started. Every other section refers to it.

#### 6.12.1 Why, and the rule

Today the code starts an agent in three ways (F13, V3, V6):

| Path | Hub state before the launch | Launch |
|---|---|---|
| **A** `relaunch_instance_locked` (`src/hub/service/agent/agent_service.odin:1126`): manual Start and Restart, chat message, MCP, event inbox, solo recovery, fleet change | plan, live connection, provider and quota checked; `launching`; `run_count + 1`; one save | the hub sends `launch_agent` |
| **B** task lease dispatch: `grant_attempt_in_uow` (`src/hub/service/taskv2/lease.odin:77`) | its own write of `launching` and `run_count + 1` (`src/hub/service/taskv2/lease.odin:231`); **no** plan, quota or live-connection check | the hub sends `wake_agent` after the commit (`flush_wakes`, `src/hub/service/taskv2/wake.odin:146`) |
| **C** bridge-local: the notice fallback (`bridge_task_wake_if_needed`, `src/bridge/agent_wake.odin:205`) and bots (`bridge_bot_launch_via_descriptor`, `src/bridge/bot_delivery.odin:77`) | **none**: the bridge fetches a manifest with `GET …/bootstrap` (`src/bridge/agent_wake.odin:299`) | the bridge launches with generation 0 (V16); the hub then refuses the fresh agent's `start-success` once the row's count is above 1 (V11) |

**The rule (S-A).** After this chain there is one way:

1. **The hub opens every run generation in one procedure, `start_begin`** (6.12.2). It is the database half of path A. No other code writes `launching`, bumps `run_count` or mints a launch epoch for a start.
2. **The bridge starts every process in one function, `bridge_runtime_launch_agent`** (`src/bridge/hub_runtime_client.odin:2749`). It is already the only function that spawns an agent (V3); what changes is that it is always handed a launch command that the hub wrote in `start_begin`. The bridge no longer builds a launch command from a manifest or from a run entry.
3. **One wire command, `start_agent`**, carries hub-initiated starts (S-B, 6.12.6).

A start is **hub-initiated** (the hub decides to start: manual Start and Restart, chat message, MCP, solo recovery, fleet change, task lease) or **bridge-initiated** (the bridge finds that a process is missing: a pipeline delivery, the notice fallback, a bot delivery). Both use `start_begin`; they differ only in who carries the launch command to the launcher:

```
hub-initiated      caller ─► start_begin ─► start_agent command ───────────────► bridge_runtime_launch_agent
bridge-initiated   bridge ─► POST …/start-begin ─► start_begin ─► HTTP reply ──► bridge_runtime_launch_agent
```

#### 6.12.2 Hub side: `start_begin` and its three callers

```odin
// src/hub/service/agent/start_begin.odin  (new file, package agent; T22)

Start_If_Live :: enum {
	Refuse,   // a live row is an error: .Conflict with details code "already_running". Start button, every bridge-initiated start
	Relaunch, // open a new generation even when the row is live: Restart button, fleet model change, a lease that needs a new child
	Keep,     // leave a live row alone and report kept_live: chat message, coordinator wake, a lease for a live child (nudge)
}

Start_Request :: struct {
	if_live:   Start_If_Live,
	ref:       string,                                   // idempotency key, "" = none. See "Start references" below
	provider, model, profile: string,                    // optional override (fleet change, reconfigure); "" = the row's values
	expected:  ^domain.Agent_Instance,                   // optional: the row the caller decided on (step 5)
	guard:     proc(ctx: rawptr) -> domain.Domain_Error, // optional; runs first (step 1)
	guard_ctx: rawptr,
}

Start_Ticket :: struct {
	instance:    domain.Agent_Instance, // the saved row; owned by the ticket
	command_id:  string,                // owned by the ticket; "sb_<ref>" when ref != "", else "cmd_launch_<id>_<instance>"
	reservation: int,                   // generation of the in-memory launch reservation
	reserved:    bool,                  // false for kept_live and reused
	kept_live:   bool,                  // nothing was written; nothing must be launched
	reused:      bool,                  // the same ref already opened the current generation; nothing was written
}
start_ticket_destroy :: proc(t: ^Start_Ticket)

// The one place that opens a run generation. Reads and writes rows and reserves launch quota in the in-memory
// registry. No network I/O. Takes no lock itself. Joins the unit of work that is open on the calling thread, if any.
start_begin :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string, req: Start_Request,
	allocator := context.allocator) -> (t: Start_Ticket, err: domain.Domain_Error)

// The complete launch object for a ticket: launch_command_json_full for t.instance with t.command_id, plus the lease
// keys when lease != nil (6.12.6). Caller-owned. This text is what bridge_runtime_launch_agent receives, unchanged.
start_launch_json :: proc(service: ^Agent_Service, t: Start_Ticket, lease: ^Start_Lease = nil, allocator := context.allocator) -> string

// Hub-initiated, one instance: builds the start command from the ticket and sends it (6.12.6). On a send failure it
// marks the row failed, exactly as the send-failure branch of relaunch_instance_locked does today, and cancels the
// reservation. A kept_live or reused ticket sends nothing. Does network I/O.
start_send :: proc(service: ^Agent_Service, t: ^Start_Ticket) -> domain.Domain_Error

// Hub-initiated, for a caller that sent the command itself in a batch (task leases). sent = true: nothing more.
// sent = false: the row is marked failed and the reservation cancelled, as start_send does.
start_settle :: proc(service: ^Agent_Service, t: ^Start_Ticket, sent: bool)

// The caller's transaction rolled back. Cancels the reservation only; the row change was rolled back with it.
start_cancel :: proc(service: ^Agent_Service, t: ^Start_Ticket)

// Hub-initiated, outside a transaction: takes reconfiguration_mutex, runs start_begin and start_send, releases it.
// The send happens under the mutex, as it does today. MUST NOT be called inside a unit of work.
start :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string, req: Start_Request)
	-> (inst: domain.Agent_Instance, kept_live: bool, ok: bool, err: domain.Domain_Error)

// Bridge-initiated: takes reconfiguration_mutex, checks that the row belongs to owner and bridge_id (else Not_Found),
// runs start_begin with if_live = .Refuse and the given ref, and returns start_launch_json. ref MUST NOT be empty.
// The reservation is kept (see "Reservation" below). launch_json is allocated in context.allocator; the caller frees it.
start_begin_for_bridge :: proc(service: ^Agent_Service, owner: domain.User_ID, bridge_id, instance_id, ref: string)
	-> (launch_json: string, run_count: int, reused: bool, ok: bool, err: domain.Domain_Error)
```

Every ticket ends in exactly one of `start_send`, `start_settle`, `start_cancel` or (bridge-initiated) the HTTP reply, and then `start_ticket_destroy`.

**`start_begin`, in this order.** It is `relaunch_instance_locked` cut in front of its send (`src/hub/service/agent/agent_service.odin:1161`), plus the checks its callers make today. The statements are moved, not rewritten.

| # | Step | Today |
|---|---|---|
| 1 | Run `req.guard`, if set. An error is returned unchanged | `start_instance` (`src/hub/service/agent/agent_service.odin:901`) |
| 2 | Load the row with `get_instance` (owner check through `auth`). Not found → `Not_Found` | every caller |
| 3 | **Idempotency: a reference never opens a second generation.** If `req.ref != ""`, `inst.start_ref == req.ref` and the row is live (`runtime_expected_active(inst.runtime_status)`, `src/hub/service/agent/agent_service.odin:1758`): return a ticket with `reused = true` for the stored row, **whatever the live status** (`launching`, `starting`, `running`, `idle`, `busy`). Nothing is written and nothing is reserved. `start_ref` is overwritten by every later `start_begin`, so an equal `start_ref` on a live row means that the generation this reference opened is still the current one. `req.if_live` is not looked at in this case: a repeated request with `Relaunch` does **not** relaunch (review finding 3). A row that is no longer live (`stopped`, `failed`, `unreachable`) does not match, and the request continues with step 4 as a new start; callers that must never open a generation on a repeat use `start_reuse` instead (below) | new (S1; widened in S2 rework) |
| 4 | **Live-row rule.** If `runtime_expected_active(inst.runtime_status)` (`src/hub/service/agent/agent_service.odin:1758`): `Refuse` → `Conflict` with the message and details of `start_instance` today, `details_json = {"code":"already_running","runtime_status":"<status>"}`; `Keep` → a ticket with `kept_live = true`; `Relaunch` → continue. Nothing is written in the first two cases | `start_instance`; missing in path B |
| 5 | `reconfiguration_require_idle` (`src/hub/service/agent/instance_reconfiguration.odin:79`). If `req.expected` is set: a changed `configuration_revision`, `launch_epoch` or `bridge_id` → `Conflict` | `relaunch_instance_locked` |
| 6 | Apply the provider, model and profile override; `validate_pinned_provider_model` (`src/hub/service/agent/agent_service.odin:1620`) | `relaunch_instance_locked` |
| 7 | The bridge checks: the bridge row exists and has the same owner; the plan allows a launch (`require_launch_bridge_enabled`, `src/hub/service/agent/agent_service.odin:2678`); the bridge is `Online` and has a live connection. After T3 these are `placement.bridge_eligible`; T22 keeps whichever form is on its base | `relaunch_instance_locked`; **missing in path B and C** |
| 8 | On the in-memory row only: `stopped_by = ""`; `runtime_status = "launching"`, `startup_status = "starting"`, `activity_status = "unknown"`; `freeze_runtime_transport` (`src/hub/service/agent/agent_service.odin:2697`); `validate_frozen_runtime_transport` (`src/hub/service/agent/agent_service.odin:2722`) on that row; `runtime_launch_epoch` (`src/hub/service/agent/agent_service.odin:2706`); `run_count += 1`; the timestamps; `start_ref = req.ref` | `relaunch_instance_locked`; `clear_user_stop` (`src/hub/service/agent/agent_service.odin:888`), which today saves separately |
| 9 | `reserve_runtime_launch` (`src/hub/service/agent/agent_service.odin:324`): the launch quota. Not admitted → the quota error; nothing was written | `relaunch_instance_locked`; **missing in path B and C** |
| 10 | Save the row **once, conditionally** (`iface.agent_save_instance_guarded`, new): the UPDATE carries `WHERE agent_instance_id = ? AND run_count = ? AND launch_epoch = ? AND configuration_revision = ?` with the three values read in step 2. No row updated → another start or a reconfiguration changed the row since step 2: cancel the reservation and return `Conflict` with details code `start_raced`; nothing was written. Any other save error: cancel the reservation and return it. This, not a lock, is what makes "one bump per generation" hold between a caller that holds `reconfiguration_mutex` and the lease grant, which cannot (see "Locks" below) | `relaunch_instance_locked` (unconditional today) |
| 11 | Fill the ticket: a clone of the saved row and the command id, both in `allocator` | — |

Rules that follow from the order:

- **One bump.** `run_count` is bumped in step 8 and stored in the one save of step 10, once per start, for every caller.
- **A refused start writes nothing.** Steps 1 to 9 change no row. In particular the user's stop mark is cleared only in the save that opens the generation (S1 finding 2): `start_begin.odin` MUST NOT call `clear_user_stop` and MUST NOT contain a comparison on `stopped_by`. The assignment in step 8 is a write, not a read (B3).
- **Transport validation before the write.** S1 ran `validate_frozen_runtime_transport` after the save and marked the row `failed` on an error. S2 runs it in step 8 on the in-memory row, so an instance whose ACP support was withdrawn is refused with nothing written. **Assumption:** the procedure reads only the row it is given. T22 verifies this first; if it reads the stored row, T22 keeps S1's order (validate after the save; on an error mark the row `failed` and cancel the reservation) and reports it.

**Repeats that must not start anything: `start_reuse`.**

```odin
// Read-only. ok = true and a reused ticket when the row is live and inst.start_ref == ref (step 3). Otherwise ok = false,
// and `ended` says whether the generation that `ref` opened is over (the row is not live, or another start replaced it).
// Never writes, never reserves, never opens a generation.
start_reuse :: proc(service: ^Agent_Service, instance_id, ref: string, allocator := context.allocator)
	-> (t: Start_Ticket, ok: bool, ended: bool, err: domain.Domain_Error)
```

The redelivery of an unconfirmed lease wake uses it (T25 step 6). `start_begin_for_bridge` does not: a bridge that repeats a reference for a row that is no longer live is asking for a new start, and gets one.

**The guarded save and the race it closes.** `start` runs under `reconfiguration_mutex` but outside any unit of work; the lease grant runs inside a unit of work but cannot take the mutex. Without a guard, a `start` that read the row before the grant committed and saved after it would write the same `run_count` a second time (two launches of one generation, one without lease keys) and overwrite `start_ref`. With the guard exactly one of the two saves updates the row; the loser gets `start_raced`, cancels its reservation and reports it: `start` returns the `Conflict` to its caller (the Start button shows the instance as already starting on reload), a grant fails for that instance and the matcher's next run sees the live row. `iface.agent_save_instance_guarded(repo, inst, expect_run_count, expect_launch_epoch, expect_configuration_revision) -> (saved, updated: bool, err)` is added to the agent repository interface and its SQLite implementation by T22; inside an open unit of work it runs on that unit's connection like every other statement. Tests: `test_start_begin_guarded_save`, `test_grant_race_with_manual_start`.

**Start references** (`req.ref`, column `agent_instances.start_ref`, 6.4.1). A reference names the cause of one start, so a repeated request does not open a second generation.

| Caller | `ref` |
|---|---|
| Pipeline delivery (T17) | the delivery id, `dlv_…` |
| Notice fallback (T24) | `fb_<agent_instance_id>_<n>`, `n` = the bridge's wake-state generation of that instance (`Bridge_Wake_State.generation`, `src/bridge/agent_wake.odin:74`): it stays the same across the retries of one wake and changes after a successful launch |
| Bot delivery (T24) | `bot_<attempt_id>` |
| Task lease (T25) | the lease id, `lease_…` |
| Manual Start, Restart, chat message, MCP, solo recovery, fleet change | `""` (no idempotency, as today) |

The command id is `"sb_" + ref` in both the fresh and the reused case, so a repeated call returns identical bytes.

**Locks and transactions.**

| Caller | Lock | Transaction |
|---|---|---|
| `start` (hub-initiated, outside a transaction) | `reconfiguration_mutex` (`src/hub/service/agent/agent_service.odin:24`), held across `start_begin` and the send, as `start_instance` holds it today | none; each row write is its own statement, as today |
| `start_begin_for_bridge` (the route) | `reconfiguration_mutex`, held across `start_begin` only | none |
| Task lease grant (T25) | **none**: the grant already holds its unit of work, and `stop_instance` holds `reconfiguration_mutex` while it calls into `taskv2` (`src/hub/service/taskv2/coordinator_wake.odin:15`), so taking the mutex inside the grant would invert the lock order. This matches path B today, which writes the row inside the grant without the mutex and is guarded by `agent_runtime_busy` and the pending-stop check at the top of `grant_attempt_in_uow` | the grant's unit of work. The ticket rides in the effects list; a rollback calls `start_cancel`; after the commit the sender calls `start_settle` |

`start_begin` itself never sends anything, so it is safe inside a unit of work. That is the two-phase split that the earlier dead end asked for ("calling `start_instance` from task lease dispatch does network I/O under a mutex inside a SQLite transaction").

**Reservation.** For a hub-initiated start the reservation is consumed by the bridge's first status frame, or cancelled by `start_send` / `start_settle` when the command could not be sent. For a bridge-initiated start it is **kept** after the reply: it is consumed by the bridge's first status frame for the instance, released by a failed or stopped status frame, and otherwise expires after one minute (V17, 10.2). The row is not marked `failed` when the bridge never launches: the bridge's status frame, the reservation expiry and the stale-instance reaper (`src/hub/app/reaper.odin:108`) recover it, and the caller's retry sends the same `ref` and gets the same generation back (step 3).

The run generation does not depend on the order of later messages: `start-success` is accepted whether it arrives before or after the `command_result`, and also when the `command_result` is lost, because the generation was committed before the process existed.

**Route.** `POST /api/v1/bridge/agent-instances/*/start-begin`, registered next to the bootstrap route (`src/hub/app/wiring.odin:1135`). Handler `bridge_instance_start_begin_handler` in `src/hub/transport/http/bridge_handlers.odin`, placed after `bridge_instance_bootstrap_handler` (`src/hub/transport/http/bridge_handlers.odin:2878`) and authenticated exactly like it (bearer bridge access token; no token in query or body; instance id = `path_part(req.path, 5)`). It calls `start_begin_for_bridge`.

Request body: `{"ref":"dlv_…"}`. An empty or missing `ref` → `Validation_Failed`.

Response 200:

```json
{"data":{"launch":{ "…":"the object start_launch_json writes", "command_id":"sb_dlv_…" },
         "run_count":7,"reused":false}}
```

Errors use `respond_error` with the service's `Domain_Error`, so each code keeps the HTTP status it has everywhere else. The handler adds nothing to them.

#### 6.12.3 Bridge side: one launcher, and the start-begin call

`bridge_runtime_launch_agent(command_id, command_json, deadline_ns)` (`src/bridge/hub_runtime_client.odin:2749`) is the only function that starts an agent process. After this chain it has exactly two callers:

| Caller | Gets the launch command from |
|---|---|
| `bridge_start_agent_apply` (T23): the handler of `start_agent`, and of the old `launch_agent` and `wake_agent` names through their adapters (6.12.6) | the hub's command |
| `bridge_wake_attempt` (T17, T24): pipeline deliveries, the notice fallback, bot deliveries | `bridge_wake_start_begin` |

```odin
// src/bridge/agent_wake.odin  (T17)
// POSTs start-begin and returns the launch command (caller-owned) and its command id (cloned).
// Uses bridge_credential_snapshot, bridge_hub_url and the same transport choice as the manifest fetch it replaces:
// with a deadline, one attempt with timeout min(10_000, time left); without one, bridge_http_request_retry.
bridge_wake_start_begin :: proc(instance_id, ref: string, deadline_ns: i64 = 0)
	-> (launch_json, command_id: string, err: Bridge_Error, ok: bool)
```

The request is built like the existing bot switch call (`src/bridge/bot_delivery.odin:69`): method POST, path `{"api","v1","bridge","agent-instances",instance_id,"start-begin"}`, a JSON body, the bearer header. `launch_json` is the text of `data.launch`, passed to `bridge_runtime_launch_agent` **unchanged**. A bridge-initiated launch therefore uses the same launch command as a hub-initiated start of the same row.

**The fallback and bots (S-C).** `bridge_task_wake_if_needed` and its three notice callers (`src/bridge/hub_runtime_client.odin:1314`, `src/bridge/hub_runtime_client.odin:1351`, `src/bridge/hub_runtime_client.odin:1452`, through `bridge_task_status_notify_wake_local`, `src/bridge/agent_wake.odin:60`) and the bot launch (`src/bridge/bot_delivery.odin:84`) replace their manifest GET with this call (T24), **when the hub offers it** (below). It is one request in place of one request, to the same host with the same credential: no new kind of traffic. `bridge_wake_fetch_enriched_launch_json` (`src/bridge/agent_wake.odin:299`) keeps exactly one caller, the legacy branch below; it and `bridge_wake_launch_command_json` (`src/bridge/hub_runtime_client.odin:2690`) are deleted when the old command names are removed (6.12.6).

**The hub says that it has start-begin (review finding 5).** A bridge must not find out from a 404 that its hub is older: a 404 for a missing route looks like a 404 for a missing instance, and the second one parks the wake. The hub's `bridge_ready` frame already carries per-connection capability flags that the bridge honours only for the connection that carried them (`src/bridge/hub_runtime_client.odin:643`, written at `src/hub/transport/http/bridge_handlers.odin:3367`). T22 adds one:

```odin
// src/contracts/bridge.odin, next to BRIDGE_READY_FEATURES_UPDATE (src/contracts/bridge.odin:154)
BRIDGE_READY_START_BEGIN :: "start_begin" // true: this hub serves POST …/start-begin
```

The bridge keeps it in `bridge_hub_start_begin_supported` (an atomic bool, reset before every hello, as the other flags are at `src/bridge/hub_runtime_client.odin:671`).

| Hub flag | Notice fallback and bot launch (T24) | Pipeline start (T17) |
|---|---|---|
| true | start-begin | start-begin |
| absent or false (an older or rolled-back hub) | **the manifest GET, exactly as today** (generation 0, the legacy branch of `bridge_wake_attempt`) | cannot happen: only a hub with T22 sends `event_deliver` frames. If it does, the executor answers `failed`, `fatal`, reason `start_refused` |

So T24 needs no deploy order: a new bridge on an old hub behaves as an old bridge. As a second line of defence, a 404 **without** a JSON error body (a route the hub does not have) is classified retriable, not fatal (6.12.4).

#### 6.12.4 Failure classes on the bridge

| Start-begin result | Class | Reason |
|---|---|---|
| No URL or credential; transport error; HTTP status 0, 429 or 5xx | retriable | — |
| 409 whose error details carry `"code":"already_running"` (step 4 of 6.12.2) | **depends on the bridge's own snapshot**, see "A live row on the hub" below | — |
| any other 409, or 423 (the configuration changed or a reconfiguration is running) | retriable | — |
| 401 or 403 | retriable (the credential is being refreshed) | — |
| 404 | fatal | `target_missing` |
| 404 whose body is not the hub's JSON error object (the route does not exist: the capability flag was wrong or the hub was rolled back mid-connection) | retriable | `hub_unavailable`. The wake backs off; it is never parked for this |
| any other 4xx | fatal | `start_refused` |
| 200 without `data.launch` | fatal | `start_refused` |

The bridge finds the code by searching the response body for the string field `code` with `extract_json_string`-style parsing at any depth (the hub writes `details_json` into the error body as it does for `start_instance`; `ham-ctl` reads the same field). **Assumption:** `respond_error` includes `details_json` in the body of a 409. T22 verifies it in `test_start_begin_route` and, if it does not, adds the details to this one handler's response.

The same table serves all three bridge-initiated callers. What each does with a class is its own rule: the pipeline executor answers `retry` or `fatal` (6.11.6); the fallback records the result in the wake state, so a retriable class backs off and a fatal class parks (`bridge_task_wake_record_result`, `src/bridge/agent_wake.odin:263`); a bot worker reports the attempt as it reports a failed descriptor fetch today.

**A live row on the hub (`already_running`).** The hub refuses because its row is live. The bridge cannot tell from one answer which of two things is true: (a) a start from another cause is under way and its launch has not reached this bridge yet, or (b) the row is **stale**: the bridge restarted or the process died unseen, and nothing will ever run that generation's start-success step. In case (b) nothing the bridge can send corrects the row: `bridge_instance_status_json` returns `{}` for an instance without a snapshot (`src/bridge/hub_runtime_client.odin:3644`), and a non-active report whose sequence did not advance is dropped by the hub (`src/hub/service/agent/agent_service.odin:1219`). What corrects it is the hub's reaper: a live row that has not been heard from for `REAPER_STALE_MS` (`src/hub/app/reaper.odin:27`) on a sweep every 20 s (`src/hub/app/reaper.odin:30`) becomes `unreachable`, which is not a live status, so the next start-begin is accepted. That takes at most about 110 s.

The rule, for every bridge-initiated start:

| The bridge's own snapshot of the instance | Meaning | Pipeline delivery (T17) | Notice fallback, bot launch (T24) |
|---|---|---|---|
| a process exists (booting or running) | case (a), and the launch has arrived | `succeeded`, `started`: the start-success step of that generation finds the stored message (row 6 of 6.11.6) | nothing to do; the gate is released without a failure |
| none | (a) or (b), unknown | **not final:** `failed`, class `retry`, `retry_after_ms = BRIDGE_LIVE_ROW_RETRY_MS` (30 s), reason `hub_row_live`. The next attempt starts again at the decision table, so case (a) resolves as `Already_Active` or a typed prompt, and case (b) resolves when the reaper has run and start-begin is accepted. **Final:** `failed`, class `fatal`, reason `hub_row_live`; the run is `failed`, not `delivered` | a **stale-row retry**: the same wake, with the same reference, is tried again after `BRIDGE_LIVE_ROW_RETRY_MS`, up to `BRIDGE_LIVE_ROW_RETRIES` (5) times, 150 s in all, which outlasts the reaper. These retries are not failures: they do not count toward back-off or parking. After the fifth the wake records an ordinary retriable failure |

```odin
// src/bridge/agent_wake.odin
BRIDGE_LIVE_ROW_RETRY_MS :: i64(30_000)
BRIDGE_LIVE_ROW_RETRIES  :: 5 // 150 s, more than REAPER_STALE_MS (90 s) plus one sweep (20 s)
```

The pipeline needs no timer for this: the delivery's own delayed retries (8 attempts, about 15 minutes, 6.11.4) carry it. The fallback has no delivery behind it, so the bridge keeps one pending retry per instance in `Bridge_Wake_State` (`live_row_retry_at_ms`, `live_row_retries`) and runs it from the bridge's existing periodic loop (the loop that sends heartbeats); T24 names the call site. **Implementer choice** inside these constraints: at most one pending retry per instance; no thread per retry and no sleep; a retry that finds the instance active, a newer wake for it, or bridge shutdown drops the pending retry; the reference is unchanged across the retries.

Why not let the bridge's "I have no process" overrule the hub's row at once: that would change the live-row rule approved in S1 (D23) and would let a bridge kill a generation whose launch is still on its way to it.


#### 6.12.5 Creating an instance without starting it

Two callers need an instance row before anything starts it: the action router (6.13) and the task engine's just-in-time instance (`jit_prepare`, `src/hub/service/taskv2/matcher.odin:435`). Bots need the same (`src/hub/service/bots/supervisor.odin:104`). `prepare_instance` (`src/hub/service/agent/agent_service.odin:346`) always writes a `launching` row with `run_count` 1 and reserves quota (V17), which is a second place that opens a generation. T22 adds, in `start_begin.odin`:

```odin
// Creates an instance row and its conversation exactly as prepare_instance does, cancels the launch reservation
// (as bots do today, src/hub/service/bots/supervisor.odin:109), and saves the row with runtime_status = "stopped",
// startup_status = "stopped", activity_status = "unknown", stopped_by = "" and run_count = 0.
// It is started later through start_begin, which makes the first and only bump: the first generation is 1.
create_instance_stopped :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, input: Create_Instance_Input)
	-> (inst: domain.Agent_Instance, ok: bool, err: domain.Domain_Error)
```

`create_instance` (`src/hub/service/agent/agent_service.odin:330`) becomes `create_instance_stopped` followed by `start` with `if_live = .Refuse` (T22). The first launch of a new instance then carries `run_count` 1, as today.

**Assumption:** `prepare_instance` creates the instance's conversation, so `content.get_conversation_by_instance` (`src/hub/service/content/content_service.odin:237`) finds it right after. T22 verifies this in `test_create_instance_stopped`. If the conversation is created elsewhere (for example in `create_instance` after `prepare_instance`), `create_instance_stopped` MUST perform that step too.

#### 6.12.6 The one start command: `start_agent` (T23)

Today a plain start is `launch_agent` (one instance; the body is the launch object of `launch_command_json_full`, `src/hub/service/agent/agent_service.odin:1781`) and a task lease start is `wake_agent` (`wake_agent_command_json`, `src/hub/service/agent/agent_service.odin:1891`: a batch of run entries per bridge and chain, each either "launch" or "nudge the live child", plus a stop list). On the bridge the `wake_agent` handler rebuilds a launch command from each entry (`src/bridge/hub_runtime_client.odin:2576`, `src/bridge/hub_runtime_client.odin:2594`). S-B merges them.

```json
{"type":"start_agent","protocol_version":1,"command_id":"<id>","chain_id":"<chain id or empty>",
 "agent_instance_id":"<only when run has exactly one entry and stop is empty>",
 "payload":{
   "run":[ {"deliver":"launch","launch":{ …the object start_launch_json writes… }},
           {"deliver":"nudge", "launch":{ … }} ],
   "stop":["<agent_instance_id>", "…"]}}
```

```odin
// src/contracts/start_wire.odin  (new)
BRIDGE_FEATURE_START_AGENT_V1 :: "start_agent_v1"
START_AGENT_FRAME    :: "start_agent"
START_DELIVER_LAUNCH :: "launch" // start a new process from entry.launch
START_DELIVER_NUDGE  :: "nudge"  // the instance has a live child of this generation: keep it, refresh TASK.md, type the lease line

// src/hub/service/agent/start_command.odin  (new)
Start_Lease :: struct { task_id, role, lease_id, pack_json, permission_mode: string } // the lease keys of a launch object
Start_Run_Entry :: struct { bridge_id, deliver, launch_json: string, lease_id: string }
// The start_agent text. launch_json values are embedded as written. The top-level agent_instance_id is added by this
// procedure when len(run) == 1 and len(stop) == 0.
start_command_json :: proc(command_id, chain_id: string, run: []Start_Run_Entry, stop: []string) -> string
// The one sender of hub-initiated starts and stops. Picks the wire form by the bridge's features (below) and sends.
start_command_send :: proc(service: ^Agent_Service, bridge_id, command_id, chain_id: string,
	run: []Start_Run_Entry, stop: []string) -> (sent: bool, err: domain.Domain_Error)
```

- **`launch`** is the complete launch object: every key `launch_command_json_full` writes, with `run_count`, `launch_epoch` and the entry's own `command_id` from the ticket. For a task lease it also carries the lease keys that the bridge's `bridge_wake_launch_command_json` writes into its synthetic launch today (`task_id`, `role`, `lease_id`, `pack`, `permission_mode`; `src/bridge/hub_runtime_client.odin:2690`), in the same places. T23 reads that function for the exact key names and positions; they are fixed by it.
- The bridge passes `entry.launch` to `bridge_runtime_launch_agent` unchanged. It reads `agent_instance_id`, `task_id`, `role`, `lease_id`, `run_count` and `pack` from the same object for a nudge.
- `stop` is the stop list of `wake_agent`, unchanged in meaning: instances of that chain that should no longer run. An instance in `run` is never in `stop`. A command with an empty `run` is a pure stop.
- **A nudge is not a start**: its ticket is `kept_live`, the row is not changed, and the entry's `launch` is built from the stored row.

**Bridge handling.** One procedure applies the command; three thin handlers call it.

```odin
// src/bridge/start_agent.odin  (new)
// Applies every run entry and the stop list. For each run entry: deliver = nudge and a live child of that generation
// exists → nudge (bridge_wake_nudge_live_child, src/bridge/hub_runtime_client.odin:2632); otherwise
// bridge_runtime_launch_agent(entry command id, entry.launch, deadline). After a failed launch it sends the instance's
// status frame, as the wake_agent handler does today. ok = false when any launch failed; err is the first failure.
bridge_start_agent_apply :: proc(conn: ^ws.Connection, text: string, deadline_ns: i64) -> (ok: bool, err: Bridge_Error)
```

| Frame | Handler after T23 |
|---|---|
| `start_agent` | `bridge_start_agent_apply`; answers `succeeded` when `ok`, otherwise `failed` with the typed error of the first failed entry. Per-instance truth keeps coming from the `agent_instance_status` frames |
| `launch_agent` (from an older hub) | wraps the frame as one run entry with `deliver = launch` and `launch` = the frame itself, then `bridge_start_agent_apply`; answers as `launch_agent` answers today (`src/bridge/hub_runtime_client.odin:1136`) |
| `wake_agent` (from an older hub) | converts each run entry with `bridge_wake_launch_command_json` (kept for this adapter only), then `bridge_start_agent_apply`; answers `succeeded` always, as today (`src/bridge/hub_runtime_client.odin:2496`) |

Dispatcher registration: `start_agent` copies the `launch_agent` row of `bridge_command_spec` (`src/bridge/hub_command_dispatch.odin:270`). Its ordering key is `agent:<agent_instance_id>` when the top-level field is present (the `launch_agent` rule, `src/bridge/hub_command_dispatch.odin:408`) and the `wake_agent` rule otherwise (`src/bridge/hub_command_dispatch.odin:412`). A `start_agent` without `command_id` is rejected; the id synthesis for id-less `wake_agent` frames (`src/bridge/hub_command_dispatch.odin:519`) stays for the old name only.

**Rollout gating.** The bridge lists `start_agent_v1` in its hello features (`BRIDGE_RUNTIME_FEATURES`, `src/bridge/hub_runtime_client.odin:4616`); the hub reads it with `bridge_feature_supported` (`src/hub/service/agent/instance_reconfiguration.odin:56`). `start_command_send` is the only place that chooses:

| Hub | Bridge | Wire |
|---|---|---|
| new | reports `start_agent_v1` | `start_agent` |
| new | does not report it | the old names, built from the same tickets: one launch entry without lease keys and an empty stop list → `launch_agent` whose body is `entry.launch_json`; anything else → `wake_agent` from `wake_agent_command_json`. The bytes are those of `origin/main` for the same rows |
| old | new | the old names arrive; the adapters above handle them |
| old | old | unchanged |

Rollout order is free for this command: neither side needs the other to be updated first. The old names, the two adapters, `wake_agent_command_json` and `bridge_wake_launch_command_json` are removed by a later, separate change once no bridge without the feature is left (non-goal here, as for the other old paths).

`kind = lease` of the pipeline (6.11.2, T20) carries a one-entry `start_agent` text in `payload`. A lease therefore goes through the pipeline only to a bridge that reports **both** `event_pipeline_v1` and `start_agent_v1`; T20's capability check tests both.

#### 6.12.7 Every start path, today and after

| Start | Today | After | Task |
|---|---|---|---|
| Manual Start | `start_instance` (`src/hub/service/agent/agent_service.odin:901`) from `src/hub/transport/http/agent_handlers.odin:357` | thin caller: `start(…, {if_live = .Refuse, guard, guard_ctx})` | T22 |
| Manual Restart | `restart_instance` (`src/hub/service/agent/agent_service.odin:878`) from `src/hub/transport/http/agent_handlers.odin:344` | thin caller: `start(…, {if_live = .Relaunch})` | T22 |
| Fleet model change | `relaunch_instance` (`src/hub/service/agent/agent_service.odin:1118`) from `src/hub/transport/http/taskchain_handlers.odin:2347` | thin caller: `start(…, {if_live = .Relaunch, provider, model, profile, expected = &inst})` | T22 |
| Reconfigure (provider or model change of one instance) | `reconfigure_instance` (`src/hub/service/agent/agent_service.odin:1097`) | `start_begin` + `start_send` with the override, under the mutex it already holds | T22 |
| `relaunch_instance_locked` | `src/hub/service/agent/agent_service.odin:1126` | **deleted**; its body is `start_begin` + `start_send` | T22 |
| New instance | `create_instance` (`src/hub/service/agent/agent_service.odin:330`): `prepare_instance` + `send_instance_launch` | `create_instance_stopped` + `start` (6.12.5) | T22 |
| New instance through MCP (`instances.create`, chain create) | `prepare_instance` + `send_instance_launch` (`src/hub/app/mcp_runtime.odin:102`, `src/hub/app/mcp_chain_create.odin:45`) | `create_instance_stopped` + `start` | T22 |
| Chat message to a stopped agent, question answer | `restart_stopped_conversation_instance` (`src/hub/transport/http/content_handlers.odin:371`) | the same procedure calls `start(…, {if_live = .Keep})`; it gains an optional guard that it passes on | T22 |
| Coordinator wake | checks `stopped_by` (`src/hub/transport/http/coordinator_wake.odin:288`), then restarts through the line above (`src/hub/transport/http/coordinator_wake.odin:299`) | passes a guard that repeats its `stopped_by` check under the mutex; closes F14 (b). The coordinator wake is not part of the pipeline, so its rule "do not wake a user-stopped coordinator" stays | T22 |
| MCP `instances.start` | `src/hub/app/mcp_runtime.odin:128` | unchanged call to the thin `start_instance`, with its guard | T22 |
| Solo-agent recovery | `start_solo_task_agent` (`src/hub/service/taskv2/dispatch.odin:191`): `restart_instance` or `start_instance` | unchanged calls to the thin callers | T22 |
| Event inbox start (until T18) | `event_inbox_notice` (`src/hub/app/wiring.odin:1357`) with its guard (`src/hub/app/wiring.odin:1406`) | unchanged call to the thin `start_instance`; T18 moves capable bridges onto the pipeline | T22, T18 |
| **Task lease dispatch (path B)** | the state write in `grant_attempt_in_uow` (`src/hub/service/taskv2/lease.odin:231`); `effect_wake_lease` (`src/hub/service/taskv2/wake.odin:27`); `flush_wakes` (`src/hub/service/taskv2/wake.odin:146`) | `start_begin` inside the grant's unit of work with `ref = lease_id`; the ticket rides in the effects list; `flush_wakes` sends through `start_command_send` and settles; a rollback cancels. **The own state write is deleted** | T25 |
| New instance for a lease | `jit_prepare` (`src/hub/service/taskv2/matcher.odin:435`) writes `launching`, `run_count` 1; the grant bumps again (F14 c) | `create_instance_stopped`; `start_begin` makes the single bump | T25 |
| Explicit lease claim and transfer | `src/hub/service/taskv2/explicit_claims.odin:32`, `src/hub/service/taskv2/explicit_claims.odin:120` (F14 a) | go through the grant, so `start_begin` applies: the stop mark is cleared in the save that opens the generation | T25 |
| **Pipeline delivery** (action prompt, `[events]` notice) | does not exist | bridge-initiated: `bridge_wake_attempt` → `bridge_wake_start_begin` | T17 |
| **Notice fallback (path C)** | `bridge_task_wake_if_needed` (`src/bridge/agent_wake.odin:205`): manifest GET (`src/bridge/agent_wake.odin:246`), generation 0 | bridge-initiated: the same `bridge_wake_attempt`, always with a `ref`; the manifest branch is deleted | T24 |
| **Bot delivery (path C)** | the hub prepares the row and cancels the reservation (`src/hub/service/bots/supervisor.odin:104`); the bridge launches from the manifest (`src/bridge/bot_delivery.odin:84`), generation 0 | the hub creates the row with `create_instance_stopped`; the bridge calls start-begin with `ref = bot_<attempt_id>` | T24 |
| Old action scheduler (path C) | `src/bridge/action_scheduler.odin:952`, `src/bridge/action_scheduler.odin:1066` | deleted with the file | T8 |

**Not a start of an agent, and left as they are** (the allow-list of `test_start_has_one_implementation`, each with this reason):

| Code | Why it stays |
|---|---|
| `create_provider_test_instance` (`src/hub/service/agent/agent_service.odin:431`) | Launches a provider test (`launch_provider_test`), not an agent run. It has no conversation, no lease and no generation that an agent confirms |
| `reconfiguration_launch_destination` (`src/hub/service/agent/instance_reconfiguration.odin:241`) | The second half of a move to another bridge: a stop-then-launch state machine with its own recovery. It already reserves and sends through the shared helpers. After T23 its send goes through `start_command_send`, so it uses the one command; its state write is not moved in this chain. **Named in section 11 for the user** |
| the in-memory registry status in `reserve_runtime_launch` | Not a row |

**The scan test** `test_start_has_one_implementation` (created in T22, `src/hub/service/agent/boundary_test.odin`) scans the non-test files of `src/hub` for an assignment of `"launching"` to `runtime_status`, for `run_count += 1` and for `run_count = 1`. Its allow-list at T22 is: `src/hub/service/agent/start_begin.odin`; `prepare_instance` (still called by `jit_prepare` and bots); `src/hub/service/taskv2/lease.odin`; the two rows above. T25 removes `lease.odin`. T24 and T25 remove the last callers of `prepare_instance`'s `launching` write, and T26 deletes that write.

#### 6.12.8 Cases where an agent cannot be launched

Every case in which a start is refused or fails. "Today" is `origin/main`; path letters are those of 6.12.1. "After S2" applies to every start, because every start runs `start_begin` and `bridge_runtime_launch_agent`. The last column says who retries; it depends on the caller, not on the case, and the caller rules are listed after the table.

**Refused by the hub, before any process exists** (`start_begin`, 6.12.2; nothing is written)

| # | Cause | Today: where decided and what happens | After S2: result | Retried by |
|---|---|---|---|---|
| L1 | The instance does not exist, or belongs to another owner or bridge | A: `Not_Found`. B: the grant fails. C: the manifest GET answers 404 | `Not_Found` (step 2); 404 on the route | nobody: the cause is permanent. Pipeline: `target_missing` |
| L2 | The instance is already live and the caller did not ask for a restart | A: `Conflict` `already_running` (Start); Restart replaces it. B: keeps a live child and nudges it. C: the bridge's own process table decides; the hub is not asked | `Refuse` → 409 `already_running`; `Keep` → `kept_live`, nothing launched; `Relaunch` → a new generation (step 4) | not a failure for `Keep` and for bridge-initiated starts (6.12.4) |
| L3 | A reconfiguration, move or stop of that instance is running | A: `Conflict` from `reconfiguration_require_idle`. B: the grant is refused ("pending runtime action", "previous process stop is pending"). C: **not checked**; the bridge launches into the move | `Conflict` (step 5); 409 on the route | the caller's rule; the bridge treats this 409 as retriable |
| L4 | The row changed since the caller read it (`configuration_revision`, `launch_epoch`, bridge) | A: `Conflict`. B, C: not checked | `Conflict` when the caller passes `expected` (step 5) | the user repeats the action |
| L5 | The provider or model is not allowed for this owner, agent or bridge | A: the error of `validate_pinned_provider_model`. B: only the placement check at match time. C: **not checked** | the same error (step 6); 4xx on the route | nobody until the configuration changes. Pipeline: `start_refused`, then another machine if the rules allow |
| L6 | The bridge's plan does not allow launches (`plan_disabled`) | A: the plan error. B, C: **not checked: the agent starts** | the plan error (step 7) | nobody until the plan changes |
| L7 | The bridge is offline or has no live connection | A: `Bridge_Offline`. B: only the bridge row's status is read, not the connection (F12); a grant to a bridge that just dropped is written and its command fails to send. C: cannot occur (the bridge is the caller) | `Bridge_Offline` (step 7) | lease: the task waits with `bridge_offline` and is granted when the bridge returns. Pipeline: OFF-2, OFF-3 |
| L8 | The launch quota is used up (active instances: 2048 per owner, 16384 in total; `src/hub/service/project/runtime_registry.odin:26`) | A: the quota error. B: checked only for a just-created instance; an existing instance **starts over the limit**. C: **not checked** | the quota error (step 9) | lease: the task waits and is tried again on the next matcher run. Pipeline: `start_refused` |
| L9 | The instance uses ACP and the bridge no longer supports it | A: refused inside the send; the row is marked `failed`. B: checked after the commit; the dispatch fails | refused in step 8 with nothing written (see the Assumption there) | nobody until the bridge supports it again |
| L10 | The caller's own guard says no: the event inbox (the instance is no longer the subscriber's, or was stopped by the user), MCP, the coordinator wake (user-stopped coordinator, rate limit) | A: the guard's error, under the mutex; the coordinator wake checks outside the mutex (F14 b) | the guard's error (step 1), always under the mutex | per caller |
| L11 | The agent is archived, or not enabled on the bridge (a **new** instance only) | `prepare_instance` refuses | `create_instance_stopped` refuses the same way; no row is created | nobody |
| L12 | The task engine does not pick the instance: it was stopped by the user, the task is held, the attempt budget is used up, the directory already has a work lease | B: the matcher and the grant (v7-Q4) | unchanged; this is not a start decision, and `start_begin` is not reached | the task engine's own rules |

**Refused or failed on the way to the bridge**

| # | Cause | Today | After S2 | Retried by |
|---|---|---|---|---|
| L13 | The start command cannot be sent (the socket dropped after step 7) | A: the row is marked `failed`, the reservation is cancelled, the error is returned. B: `on_dispatch_failed` (`src/hub/service/taskv2/dispatch.odin:178`) parks the task; the row stays `launching` | one behaviour: `start_send` / `start_settle` marks the row `failed` and cancels the reservation; the lease additionally follows `on_dispatch_failed` | the user (manual); the task engine (lease) |
| L14 | The bridge is too old for the pipeline (`event_pipeline_v1` missing) | does not exist | actions: `bridge_too_old`, the run fails or goes to another machine. Notices, bots, leases: the old path (REQ-FLOW-4) | — |
| L15 | The bridge does not know `start_agent` | does not exist | **not a failure**: the hub sends the old names (6.12.6) | — |
| L16 | The bridge cannot reach start-begin: no URL or credential, transport error, 429, 5xx, 401, 403 | C: the manifest GET fails; the wake backs off | retriable (6.12.4) | pipeline: delayed retries, 8 attempts in about 15 minutes. Fallback: the wake back-off. Bot: the supervisor's next attempt |

**Refused or failed on the bridge** (`bridge_wake_attempt` and `bridge_runtime_launch_agent`; the hub row is already `launching`)

| # | Cause | Today | After S2 | Retried by |
|---|---|---|---|---|
| L17 | The bridge is draining, updating itself or its vault is locked | the launch returns a retriable error (`retry_after_ms` 30 s for an update, `src/bridge/hub_runtime_client.odin:2750`); bots answer busy | unchanged in the launcher. The pipeline checks before start-begin (row 4 of 6.11.6), so no generation is opened | every caller's retry; a final pipeline attempt ends `draining` or `vault_locked` |
| L18 | The bridge's wake gate says no: a start of this instance was tried less than 30 s ago (coalesced), is backing off after failures, or is parked because the provider binary or model is missing on this machine | C only: the fallback returns false | the same gate, now for every bridge-initiated start, **before** start-begin, so no generation is opened. Hub-initiated starts do not pass the gate, as today | coalesced and backing off: retry. Parked: `start_parked`, fatal, until the provider catalog changes or a launch by another path succeeds |
| L19 | The launch itself fails: provider binary missing, bootstrap cannot be materialised, the pty host is unreachable, the spawn fails | A: `command_result` `failed`; the row is set `failed` from the status frame. B: only a status frame; the task is parked by the grant-unconfirmed timer. C: the wake state records the class | one behaviour: the bridge sends the failed status frame, which sets the row `failed` and releases the reservation (10.2); the caller gets the typed error with its class (`retriable`, `recoverable`, `fatal`) | by class: retriable → retry; otherwise fatal for that caller |
| L20 | The hub's row is live but the bridge has no process (the bridge restarted, or the process died unseen) | A (Start): refused `already_running` until the reaper marks the row `unreachable` (`REAPER_STALE_MS` (`src/hub/app/reaper.odin:27`) on a sweep every 20 s (`src/hub/app/reaper.odin:30`); about 110 s at most). B: the nudge falls through to a launch. C: **launches anyway** with generation 0 | bridge-initiated: 409 `already_running`. No frame from the bridge corrects the row; the reaper does. The bridge retries past that window (6.12.4): the pipeline with `retry` every 30 s inside its attempt budget, the fallback and bots with up to 5 retries of 30 s. Hub-initiated starts are unchanged: Start is refused until the reaper ran, Restart and a lease (`Relaunch`) start at once | automatic, within about 150 s; a pipeline delivery that is still refused on its final attempt ends `failed`, `hub_row_live` |
| L21 | The launch command is older than the bridge's generation (a late duplicate) | the launcher refuses "superseded startup generation" | unchanged; cannot happen for a `reused` ticket, which carries the current generation | nobody: the newer generation wins |
| L22 | The bridge dies between start-begin and the launch | does not exist (C has no hub state) | the row stays `launching`; the reservation expires after one minute; the retry with the same `ref` gets the same generation back (step 3); without a retry the stale-instance reaper closes the row (V-K13) | the caller's retry |
| L23 | The process starts but never reports `start-success` | the row stays `launching` until the reaper; a lease is failed by the grant-unconfirmed timer | unchanged | the task engine (lease); the user otherwise |

**What each caller does with a refusal**

| Caller | A refusal or failure becomes |
|---|---|
| Manual Start, Restart, MCP, fleet change | the error and its HTTP status; no automatic retry |
| Chat message to a stopped agent | the message is stored; the start error is returned to the sender; the next message tries again |
| Task lease | refused in the grant → the grant fails with the existing placement failure for that instance, and the matcher tries again on its next run; failed after the commit → `on_dispatch_failed`, as today |
| Pipeline delivery | `retry` → delayed redelivery, 8 attempts; `fatal` → another machine where the kind allows, else the delivery and its run are `failed` with the reason of 6.11.9 |
| Notice fallback | the wake state: back-off for a retriable class, parked for the others; the next notice asks again |
| Bot delivery | the attempt is reported failed; the bot supervisor's rounds decide, as today |

**Behaviour that changes for task leases**, because path B skipped these checks: L6, L7 (live connection), L8 and L9 now refuse a grant that used to start an agent. Each has a test in T25, and the hand-off of T25 lists them (risk S-K2).

### 6.13 Router and target resolution (T10)

#### 6.13.1 `drain_due` and one run

```odin
// src/hub/service/actions/router.odin
// The only effect is "deliver a prompt". This table is the seam for another kind; none is planned.
Effect :: struct { kind: string, plan: proc(r: ^Router, action: domain.Action, run: domain.Action_Run, exclude: []string) -> Plan }
EFFECTS := [?]Effect{prompt_effect}

// What the router decided for one run, before the route transaction.
Plan :: struct {
	ok:               bool,   // false = the run fails with `reason`
	reason:           string,
	bridge_id, instance_id, conversation_id: string, // temp-allocated
	rule_position:    int,    // -1 for target kind instance
	stop_instance_id: string, // fresh_per_run: the previous instance to stop after the commit; "" otherwise
	spawned:          bool,   // a new instance was created for this run
}

// The pipeline, as package actions sees it. Filled at wiring with delivery.route / delivery.expire; faked in tests.
Route_Port :: struct {
	ctx:    rawptr,
	route:  proc(ctx: rawptr, uow: ^iface.Unit_Of_Work, input: delivery.Route_Input) -> (delivery_id: string, err: domain.Domain_Error),
	expire: proc(ctx: rawptr, uow: ^iface.Unit_Of_Work, delivery_id: string) -> (closed: bool),
}

Router :: struct {
	factory:     ^iface.Unit_Of_Work_Factory,
	experiments: ^iface.Experiment_Repository,
	placement:   ^placement.Service,
	agents:      Agent_Port,
	pipeline:    Route_Port,
	support:     Schedule_Support_Port,
	clock:       ^platform.Clock,
	ids:         ^platform.ID_Generator,
}

// A deferral fire that arrived in the batch: "this run may be routed now". Strings are borrowed.
Resume_Hint :: struct { owner, run_id: string }

// Routes every open run that is due, and every hinted run. Called after each non-empty batch, once at
// start, and once when the support state is first read as Unsupported.
drain_due :: proc(r: ^Router, hints: []Resume_Hint = nil)
```

`drain_due` handles, in this order:

1. Each hint: `run_get(hint.run_id)`. If the run is in state `deferred` and its `owner_user_id` equals `hint.owner`, handle it as due. Any other hint is ignored.
2. `runs_due(now, 32)`, each run; repeated until a load returns no run that this drain has not already handled. `runs_due` returns `queued` runs and due `deferred` runs only; a `routed` run is never returned.
3. Only when the support state is `Unsupported`: every run of `runs_deferred(32)` that is not yet due is finished as `skipped`, `rate_limited` (6.8.3).

For one run:

**Decide (unit of work A).** Re-read the run; if it is not `queued` or `deferred`, stop. Load the action. Then, in this order:

| # | Check | Result |
|---|---|---|
| 1 | The owner's `actions` experiment is off (6.15) | `skipped`, `experiment_off` |
| 2 | `action.enabled` is false | `skipped`, `disabled` |
| 3 | `target_kind` is `bot` and the owner's `bots` experiment is off | `skipped`, `experiment_off` |
| 4 | Rate rule, for a `queued` run only (a `deferred` run has already waited): `last = run_last_started_at(action)`. If `last != ""` and `now - last < min_interval_s`: when the support state is not `Unsupported`, set the run to `deferred` with `not_before = last + min_interval_s`, append the deferral row (6.2.3), commit, stop. When the support state is `Unsupported` | `skipped`, `rate_limited` |
| 5 | Otherwise | continue with Plan |

Commit A. A `skipped` result also sets `finished_at` and, in the same unit of work, calls `runs_prune(action, 200, now - 30 days)`. Unit of work A does **not** claim the run.

**Plan (no unit of work open).** Call the effect's `plan`. `prompt_effect` resolves the target (6.13.3): it calls `placement.select`, and finds or creates the instance row through `Agent_Port`. It writes nothing in package `actions`.

**Route (unit of work B).** One transaction (REQ-ACT-6):

1. Re-read the run. If it is not in the state unit of work A saw, roll back and stop (another drain took it).
2. `plan.ok == false` → `run_transition` to `failed` with `plan.reason`, `finished_at`; `runs_prune`; commit; stop.
3. Render the prompt (6.9) with `joined = run_joined_count(run)`.
4. Store the prompt: `Agent_Port.persist_prompt(uow, owner, plan.conversation_id, body, metadata_json)` → `message_id`. It is `content.persist_user_message` (`src/hub/service/content/user_message.odin:11`) with `message_type = "action"`; it only writes rows. An error → roll back; then, in a new unit of work, the run is `failed`, `delivery_failed`.
5. `pipeline.route(uow, {kind = "prompt", owner_user_id, bridge_id = plan.bridge_id, agent_instance_id = plan.instance_id, cause, ref = "run:<run_id>", conversation_id, message_id, notice_line = "message", notice_count = joined + 1, lifetime = delivery.LIFETIME_PROMPT, round = 0})` → `delivery_id`. An error whose message is `bridge_too_old` → roll back; run `failed`, `bridge_too_old`. Any other error → roll back; run `failed`, `delivery_failed`.
6. **Claim:** `run_transition` from the current state to `routed` with `started_at = now`, `delivery_id`, `target_instance_id`, `message_id`, `rule_position`.
7. When `plan.spawned`: `set_last_spawned(action, plan.instance_id, now)`.
8. Commit.

**After the commit.** When `plan.stop_instance_id != ""`: `Agent_Port.stop(owner, plan.stop_instance_id)` (`fresh_per_run`, U2).

The prompt, the claim and the delivery are in one transaction. So a crash before the commit routes the run again later, with no chat message left behind; and a crash after it delivers exactly once, because the outbox row is already stored. v6 risk K13 ("a crash between claim and delivery loses the prompt") no longer exists.

A crash between Plan and unit of work B can leave an instance row that Plan created. With strategy `reuse` the next attempt finds and uses it. With `fresh_per_run` it stays as an unused stopped instance (risk V-K12).

`cause` is `"schedule"` when `run.event_type == "schedule.fired"`, otherwise `"event"`. The chat message has this `metadata_json`:

```json
{"action_id":"act_…","action_name":"…","run_id":"arun_…","trigger_id":"trg_…","event_type":"schedule.fired",
 "joined_count":0,"triggered_at":"<event_params.fired_at>","cron_expr":"<schedule triggers in mode cron only>","timezone":"<same>"}
```

`triggered_at`, `cron_expr` and `timezone` are the keys the existing action card reads (`scheduleContextFromMetadata`, `src/ui/components/workbench/AgentChatPane.tsx:526`).

#### 6.13.2 `Agent_Port`

Package `actions` MUST NOT import `agent` or `content`. It reaches them through this port, implemented in `src/hub/app/wiring.odin` (T10).

```odin
Agent_Port :: struct {
	ctx: rawptr,
	// The instance of this agent that runs on this candidate, or found = false.
	// A match has the candidate's bridge_id, provider and model, and the given project_id, and is not deleted.
	// With several matches: prefer_instance if it is among them, else the newest by created_at.
	// The instance's run state and its user stop are NOT consulted. Strings are allocated in context.temp_allocator.
	find:   proc(ctx: rawptr, owner, agent_id, project_id, prefer_instance: string, c: placement.Candidate) -> (instance_id, conversation_id: string, found: bool),
	// Creates an instance on the candidate WITHOUT starting it (agent.create_instance_stopped, 6.12.5). Temp-allocated.
	create: proc(ctx: rawptr, owner, agent_id, project_id: string, c: placement.Candidate) -> (instance_id, conversation_id: string, err: domain.Domain_Error),
	// Stops an instance (agent.stop_instance with a reason that does not start with "user"). Errors are logged, not returned.
	stop:   proc(ctx: rawptr, owner, instance_id: string),
	// One instance for target_kind "instance": its agent id, bridge and conversation. found = false when it is gone.
	instance: proc(ctx: rawptr, owner, instance_id: string) -> (agent_id, bridge_id, conversation_id: string, found: bool),
	// Stores the prompt as a user_to_agent chat message with message_type "action", inside uow. Rows only.
	persist_prompt: proc(ctx: rawptr, uow: ^iface.Unit_Of_Work, owner, conversation_id, body, metadata_json: string) -> (message_id: string, err: domain.Domain_Error),
	// Marks one chat message read and records in its metadata that the prompt moved (6.13.5), inside uow. Rows only.
	retire_prompt:  proc(ctx: rawptr, uow: ^iface.Unit_Of_Work, owner, message_id, moved_to_instance_id: string),
}
```

`stop` uses a reason that does not start with `"user"`, so `stop_instance` does not set `stopped_by` (`src/hub/service/agent/agent_service.odin:856`).

No procedure of the port, and no code in package `actions`, reads `stopped_by` (REQ-PIPE-5).

#### 6.13.3 Target resolution

Every call passes `Requirements.features = {contracts.BRIDGE_FEATURE_EVENT_PIPELINE_V1}` and `Requirements.exclude` = the `exclude` list of the plan call (empty for a first routing).

| `target_kind` | Steps |
|---|---|
| `agent` | (1) `placement.select({owner, agent_id, features, exclude}, rules, action.placement_selector)`. No candidate → see "no candidate" below. (2) By `instance_strategy`, on the chosen candidate: see below |
| `instance` | (1) `Agent_Port.instance`. Not found → `failed`, `target_missing`. (2) Load its bridge; `placement.bridge_eligible` with the same `features` fails with reason `missing_feature` → `failed`, `bridge_too_old`. Any other failure → **not** a failure of the run: the delivery is routed to that bridge anyway and waits there (OFF-3, v7-Q7), unless the reason is `not_owner`, `revoked`, `enrollment_pending` or `plan_disabled`, which give `failed`, `no_placement`. An instance that belongs to a bot cannot be such a target: the API refuses it (6.14) |
| `bot` | Phase 1: cannot occur (the API refuses it). Phase 3: T19 |

**No candidate, for an `agent` target.** Call `placement.select` once more without `features`. If that finds a candidate, the only obstacle is the bridge version: `failed`, `bridge_too_old`. Otherwise `failed`, `no_placement`.

**A rule that names one machine that is offline.** When the action's rules name exactly one bridge (every rule has the same `bridge_id`, not `*`) and `select` finds no candidate only because that bridge is offline (its `bridge_eligible` reason is `offline`), the run is routed to that bridge and waits (OFF-3, v7-Q7): the router picks the instance on that bridge with `Agent_Port.find` by the agent's first rule; if none exists it cannot create one on an offline machine, and the run is `failed`, `no_placement`.

| Strategy | On the chosen candidate |
|---|---|
| `reuse` | `find(…, prefer_instance = action.last_spawned_instance_id, c)`. Found → use it, whatever its run state: the bridge starts it if it is not running, also when the user stopped it. Not found → `create`; `plan.spawned = true`. A `create` error → `failed`, `delivery_failed` |
| `fresh_per_run` | Always `create` a new instance on the candidate; `plan.spawned = true`; `plan.stop_instance_id = action.last_spawned_instance_id` |

- Priority is strict. Rule 1 is used whenever it can be satisfied, even if an instance already runs under rule 2.
- An agent target with an empty rule list is valid and means "anywhere" (6.10.3).
- A run with no satisfiable rule fails. There is no waiting queue; the next trigger tries again.

#### 6.13.4 The sink: closing a routed run

```odin
// src/hub/service/actions/router.odin — registered at wiring as the delivery.Sink of kind "prompt"
on_delivery_final :: proc(ctx: rawptr, uow: ^iface.Unit_Of_Work, d: domain.Pipeline_Delivery)
on_delivery_replace :: proc(ctx: rawptr, uow: ^iface.Unit_Of_Work, d: domain.Pipeline_Delivery, why: delivery.Replace_Why) -> (bool, domain.Domain_Error)
// Closes the action's open run if its delivery has expired (6.8.4). Rows only.
expire_open_run :: proc(r: ^Router, uow: ^iface.Unit_Of_Work, action_id: domain.Action_ID)
```

`on_delivery_final`: the run id is the text after `run:` in `d.ref`. Load the run. If it is not `routed`, or `run.delivery_id != d.delivery_id`, do nothing (the report is stale). Otherwise `run_transition` from `routed`:

| `d.state` | Run |
|---|---|
| `done` | `delivered`, `finished_at = now` |
| `failed` | `failed`, `finished_at = now`, reason by 6.8.1: `bridge_offline`, `no_answer`, `bridge_too_old` and `target_missing` are copied; every other delivery reason becomes `start_failed` |

Then `runs_prune(action, 200, now - 30 days)`. The sink does not call `drain_due`: joined matches never route by themselves, and the next match opens a new run.

The sink's `still_valid` is nil: a prompt delivery is valid until it expires.

#### 6.13.5 Placing a prompt again

`on_delivery_replace` (called by the pipeline for a `routed` delivery on a dropped or downgraded bridge, and for a `fatal` answer):

The declines below return `false, {}`. Any repository or routing error returns `false, err`, so the pipeline rolls back every write in this attempt (6.11.4); successful replacement returns `true, {}`.

1. Load the run and the action. Return false when the run is not `routed` with this delivery, when the action is gone, or when `target_kind != "agent"`.
2. Call the effect's `plan` with `exclude` = the bridges in `d.excluded_bridges_json` plus `d.bridge_id`. `plan.ok == false` → return false. (The "one named machine" rule of 6.13.3 does not apply here: the machine is in the exclude list.)
3. Render the prompt again and store it with `persist_prompt` in the new instance's conversation.
4. `retire_prompt(uow, owner, d.message_id, plan.instance_id)`: the first message is marked read (`content_mark_messages_read`, `src/hub/repository/iface/content_repo.odin:91`) and its metadata gains `"moved_to_instance_id"`.
5. `pipeline.route` with `round = d.round + 1` and `excluded_bridges` = that list.
6. `run_transition` from `routed` to `routed` with the new `delivery_id`, `target_instance_id`, `message_id`, `rule_position`. `started_at` is unchanged.
7. Return true. The pipeline then writes the old delivery `replaced`.

`plan` may create an instance row inside this unit of work. That is allowed: `create_instance_stopped` writes rows and touches the in-memory reservation only; it does no network I/O.

### 6.14 HTTP API v2 (T9; the runs route in T10)

All routes need user auth and the `actions` experiment (6.15). Responses use the existing envelope helpers. `src/hub/transport/http/action_handlers.odin` is rewritten; handlers are thin and call the service procedures of package `actions`.

| Method and path | Purpose | Response |
|---|---|---|
| `GET /api/v1/actions` | list the caller's actions | `{"data":[Action]}` |
| `POST /api/v1/actions` | create | 201 `{"data":Action}` |
| `GET /api/v1/actions/trigger-types` | what the server offers | below |
| `GET /api/v1/actions/{id}` | one action | `{"data":Action}`; 404 for another owner |
| `PATCH /api/v1/actions/{id}` | partial update | `{"data":Action}` |
| `DELETE /api/v1/actions/{id}` | delete the action, its rules, triggers and runs; appends purge rows for its schedule triggers | `{"deleted":true}` |
| `POST /api/v1/actions/{id}/enable`, `POST /api/v1/actions/{id}/disable` | set `enabled` | `{"data":Action}` |
| `GET /api/v1/actions/{id}/runs?limit=<1..200, default 50>&before=<created_at>` | run history, newest first (T10) | `{"data":[Run]}` |

The router returns the first registered route that matches (`route_matches`, `src/hub/transport/http/router.odin:75`). Register `GET /api/v1/actions/trigger-types` **before** `GET /api/v1/actions/*`. There is no `/run` route and no `/api/v1/scheduled-prompts*` or `/api/v1/bridge/actions*` route.

**Action**

```json
{"id":"act_…","owner_user_id":"…","name":"Nightly review","prompt_text":"…","enabled":true,"min_interval_s":30,
 "target":{"kind":"agent","agent_id":"agt_…","project_id":"","instance_strategy":"reuse","selector":"first",
           "rules":[{"bridge_id":"*","provider":"claude","model":"*"}],"last_spawned_instance_id":""},
 "triggers":[
   {"id":"trg_…","kind":"schedule","enabled":true,"rev":1,"next_fire_at":"2026-12-01T09:00:00Z",
    "config":{"mode":"cron","cron_expr":"0 9 * * 1-5","timezone":"America/New_York"},"created_at":"…","updated_at":"…"},
   {"id":"trg_…","kind":"event","enabled":true,"rev":1,"next_fire_at":"",
    "config":{"event_type":"chain.state","data":{"state":"completed"}},"created_at":"…","updated_at":"…"}],
 "created_at":"…","updated_at":"…"}
```

- Other targets: `{"kind":"instance","instance_id":"…"}` and `{"kind":"bot","bot_id":"…"}`.
- `next_fire_at` is for display only. For an effective schedule trigger it is: mode `cron` → `schedule.next_cron_slot` after now; mode `once` → `run_at` when it is in the future; mode `interval` → `""` (the phase is known only to nats-server). For every other trigger it is `""`.

**Create body**: `name` (optional), `prompt_text` (required, not blank), `enabled` (default true), `min_interval_s` (default 30), `target` (required), `triggers` (optional array; each item has `kind`, `config`, and optional `enabled`).

**Patch body**: any of `name`, `prompt_text`, `enabled`, `min_interval_s`, `target`, `triggers`. `target` replaces the whole target, rules included. `triggers` replaces the whole list: an item with an `id` updates that trigger, an item without an `id` creates one, and a trigger whose id is missing from the list is deleted.

**Validation** (HTTP 422 with a `details_json` code unless stated):

| Rule | Code |
|---|---|
| `prompt_text` blank | `prompt_required` |
| `min_interval_s` outside 5 to 86400 | `min_interval_out_of_range` |
| `target.kind` not in the server's `target_kinds` | `target_kind_unavailable` |
| target agent, instance or bot missing or not the caller's | 404 |
| `instance_strategy` not `reuse` or `fresh_per_run`; `selector` not registered | `invalid_strategy`, `unknown_selector` |
| `rules` on a target that is not `agent`; more than 16 rules; a bad rule | `rules_not_allowed`; otherwise the codes of `placement.validate_rules` |
| `target.kind = "instance"` and the instance belongs to a bot (a row of `bots` names it as its instance) | `target_is_bot_instance`. A bot is targeted with kind `bot` (T19), so that its delivery goes through the bot path and the `bots` experiment is checked. This rule stays after T19 |
| more than 16 triggers | `too_many_triggers` |
| unknown trigger `kind` | `unknown_trigger_kind` |
| a config that `Trigger_Kind.compile` rejects | the kind's code, for example `invalid_cron`, `invalid_timezone`, `unknown_event_type`, `unknown_chain` |
| a `schedule` trigger that would be effective while the support state is `Unsupported` | HTTP 409, `schedules_unsupported` |

**One transaction per write.** Create, patch, enable, disable and delete each run in one unit of work: save the action, replace the rules, save or delete triggers, apply the `rev` rule (6.6.1), and call each kind's `on_change` with the effective flags before and after. Nothing touches NATS.

**`GET /api/v1/actions/trigger-types`**

```json
{"data":{
  "target_kinds":["agent","instance"],
  "schedules_supported":true,
  "limits":{"max_triggers":16,"max_rules":16,"min_interval_s":{"min":5,"max":86400,"default":30}},
  "trigger_kinds":[
    {"kind":"schedule","label":"Schedule","modes":["cron","interval","once"]},
    {"kind":"event","label":"Event","events":[
      {"event_type":"chain.state","label":"Task chain state changed","scope":"chain",
       "data_keys":[{"key":"state","values":["active","completed","archived"]}],
       "presets":[{"id":"chain_completed","label":"Task chain completed","data":{"state":"completed"}}]},
      {"event_type":"chain.work_finished","label":"Task chain work finished","scope":"chain",
       "data_keys":[{"key":"outcome","values":[]}],"presets":[]}]}]
}}
```

`target_kinds` comes from one server value, `actions.Service.target_kinds`. Phase 1 sets `{"agent","instance"}`. T19 adds `"bot"`. `schedules_supported` is false only when the support state is `Unsupported`.

**Run**

```json
{"id":"arun_…","trigger_id":"trg_…","event_type":"chain.state","event_id":"evt_…","state":"deferred","reason":"",
 "not_before":"…","joined_run_id":"","joined_count":3,"rule_position":0,"target_instance_id":"","message_id":"",
 "delivery_id":"","delivery_expires_at":"","created_at":"…","started_at":"","finished_at":""}
```

`state` is one of `queued`, `deferred`, `routed`, `delivered`, `joined`, `skipped`, `failed` (6.8.1). `delivery_id` is set from `routed` on. `delivery_expires_at` is the `expires_at` of that delivery while the run is `routed`, and empty otherwise. Before it reads the rows, the handler calls `expire_open_run` (6.8.4), so an expired `routed` run is returned as `failed`, `bridge_offline`.

### 6.15 Experiment gating (R3)

- Every route of 6.14 calls `require_experiment_enabled(…, domain.ACTIONS_EXPERIMENT_KEY, …)` (`src/hub/transport/http/experiment_rest_handlers.odin:184`; the key is at `src/hub/domain/experiment.odin:12`) before any read or write, as the handlers do today.
- The router re-checks per run with a service-level helper modelled on `bots_gate_on` (`src/hub/service/bots/gate.odin:27`):

```odin
// src/hub/service/actions/gate.odin
actions_gate_on :: proc(repo: ^iface.Experiment_Repository, owner_user_id, key: string) -> bool
```

- With the flag off for an owner: every action route returns the existing "experimental feature disabled" error; triggers still match and rows are still written, but each run ends `skipped` with `experiment_off`; nothing is delivered. Turning the flag on again needs no repair step.
- A bot target also needs `domain.BOTS_EXPERIMENT_KEY` (`src/hub/domain/experiment.odin:13`), at create time and per run.
- The UI gate (`ActionsRouteGate`) is unchanged. `tests/ui_experimental_flags_test.ts` MUST keep passing.

### 6.16 Lookups on the event paths (amendment S2)

**The rule (REQ-LOOKUP-1).** No step that runs per event, per run, per delivery or per start may read a whole table or a whole user's rows. Every such lookup is by a primary key, by a named index, or by a JetStream subject filter. The table lists each one. A task that adds a lookup to one of these paths MUST add its row here and to the test.

`n` is the number of rows in the table. "Probe" means one B-tree descent, O(log n).

**One event: producer → matcher → router**

| # | Step | Lookup | Key | Index or subject | Cost |
|---|---|---|---|---|---|
| Q1 | Relay picks the next rows (6.3.4) | `event_outbox` rows not yet published, oldest first, up to 64 | `outbox_seq` | `event_outbox_pending(outbox_seq) WHERE published_at IS NULL` (`src/hub/repository/sqlite/migrations/events_001_outbox.sql:12`) | probe + rows read |
| Q2 | Matcher receives the event (6.7) | one durable consumer | subject | filter `ev.>` | one fetch per batch of up to 64 |
| Q3 | Matcher finds the triggers (6.7 step 4) | `triggers_match(owner, event_type, subject)` | `(owner_user_id, event_type, match_key)` | `action_triggers_match` (6.4), read twice: `match_key = <subject>` and `match_key = ''` | 2 probes + matching rows. **Changed by S2:** a schedule fire reads exactly its own trigger, not every schedule trigger of the user |
| Q4 | The action of a matching trigger | `action_get` | `action_id` | primary key | probe |
| Q5 | Open run of the action (6.7 step 7, 6.8.4) | `run_open(action_id)` | `action_id` | `action_runs_one_open(action_id) WHERE state IN (…)` | probe, at most one row |
| Q6 | Insert the run | `run_insert` | `occurrence_key` | the `UNIQUE` constraint on `occurrence_key` | probe |
| Q7 | Prune the action's history | `runs_prune(action_id, 200, cutoff)` | `action_id` | `action_runs_action(action_id, created_at)` | at most 200 rows of one action |
| Q8 | Runs due for routing (6.13.1), once per batch | `runs_due(now, limit)`, `runs_deferred(limit)` | `(state, not_before)` | `action_runs_due(state, not_before) WHERE state IN ('queued','deferred')` (**new in S2**, 6.4) | probe + due rows |
| Q9 | The rate rule | `run_last_started_at(action_id)` | `action_id` | `action_runs_action` | newest rows of one action, at most 200 |
| Q10 | Target rules | `rules_list(action_id)` | `action_id` | primary key `(action_id, position)` | at most 16 rows |
| Q11 | Placement (6.10) | the owner's bridges and their provider state | `owner_user_id` | the existing bridge and provider queries. T3 puts each statement it calls under the test below and adds an index where the plan shows a scan | rows of one owner |
| Q12 | Instance to reuse (6.13.3) | the instance of an agent on a bridge | ids | T10 puts its statement under the test below and adds an index where the plan shows a scan | rows of one agent |
| Q13 | Route transaction | insert chat message, insert `pipeline_deliveries`, append outbox | primary keys | — | 3 inserts |

**One delivery: forwarder → bridge → answer**

| # | Step | Lookup | Key | Index or subject | Cost |
|---|---|---|---|---|---|
| Q14 | Forwarder fetch (6.11.4) | one durable consumer per bridge | subject | filter `dlv.*.<bridge_id>.>` | one fetch |
| Q15 | In-flight count, once per pass | `in_flight(bridge_id, since)` | `bridge_id` | `pipeline_deliveries_open(bridge_id) WHERE state IN ('routed','forwarded')` | the open rows of one bridge, at most 256 |
| Q16 | Forward gate, answer, expiry of one delivery | `get`, `transition` | `delivery_id` | primary key | probe |
| Q17 | One open delivery per reference (notice, lease, bot; `replace`) | `open_by_ref(ref)` | `ref` | `pipeline_deliveries_ref(ref)` | probe |
| Q18 | Bridge online, offline, downgrade (6.11.7) | `open_for_bridge(bridge_id, …)` | `bridge_id` | `pipeline_deliveries_open` | the open rows of one bridge |
| Q19 | `expire_due` at hub start and reconnect | `expired(now, limit)` | `expires_at` | `pipeline_deliveries_expiry(expires_at) WHERE state IN ('routed','forwarded')` (**new in S2**, 6.4.1) | probe + expired rows |
| Q20 | Prune (6.11.10) | `prune(cutoff)` | `updated_at` | `pipeline_deliveries_closed(updated_at) WHERE state IN ('done','failed','replaced')` (**new in S2**) | probe + deleted rows |
| Q21 | Bridge ledger (6.11.6) | entry by delivery id | `delivery_id` | in-memory map | O(1); each write rewrites the file, whose size follows open lifetimes (S2: `expires_at` + margin), not 48 hours |
| Q22 | Bridge process table | snapshot by instance | `agent_instance_id` | in-memory map | O(1) |

**One start**

| # | Step | Lookup | Key | Index | Cost |
|---|---|---|---|---|---|
| Q23 | `start_begin` (6.12.2) | instance, bridge | ids | primary keys | 2 probes + 1 write |
| Q24 | Launch quota | the registry's counters | owner | in-memory | O(1) |
| Q25 | Lease grant (T25) | as today, plus Q23 | — | — | — |

**Not per event, and allowed to read more**

| Step | Reads | When |
|---|---|---|
| Schedule reconcile (6.2.6) | `triggers_effective("schedule")`, all owners | hub start and NATS reconnect |
| Runs history route | `runs_list(action_id, …)` on `action_runs_action` | a user request |
| Advisory drain (6.11.8) | one `stream_get` by sequence | per exhausted delivery |

**Outside this chain.** The event inbox's notification loop reads every subscription once per second (scaling report, recommendations 6, 8 and 9). It is not on the path of an action and is not changed here; T18 does not add a lookup to it.

**The test.** `test_event_path_queries_use_indexes` (`src/hub/repository/sqlite`, created by T9, extended by T3, T10 and T16 for their rows): for each statement behind Q1, Q3 to Q12 and Q15 to Q20 it runs `EXPLAIN QUERY PLAN` on a migrated database and fails when a plan line contains `SCAN` without `USING INDEX` or `USING COVERING INDEX` for the tables `action_triggers`, `action_runs`, `pipeline_deliveries` or `event_outbox`. The statements are exported from the repository files as constants so the test runs the text that production runs.

## 7. Dependency graph and waves

```
Phase 1
  T1 ─┬──────────► T9 ──┬─► T10 ─┬─► T12 (runs verb)
  T2 ─┤                 │        ├─► T13 (runs view)
  T3 ─┼─► T9            │        │
      ├─► T16 ──────────┤        │
      └─► T22 ──────────┘        │      T10 needs create_instance_stopped
  T1 ───► T16 ─► T17             │
  T8, T22 ─────► T17             │      T17 needs the start-begin route
  T9 ─► T12, T13                 │
  all of the above ──────────────┴─► T14

Phase S (start convergence, amendment S2; beside phases 1 and 2)
  T22, T17 ─► T23 ─► T25
  T22, T17 ─► T24
  T23, T24, T25 ─► T26

Phase 2
  T16, T17 ─► T18

Phase 3
  T3 ─► T4
  T10, T16, T17, T24 ─► T19
  T16, T17, T23, T25 ─► T20
  T4, T19, T20 ─► T21
```

**What amendment S2 does to phase 1.** Phase 1 gains one task, T22, and no other. It takes the start-begin work that S1 had inside T16 (the split of `relaunch_instance_locked`, the route, `create_instance_stopped`) and widens it to the one start procedure. T22 depends only on T3 and runs in wave 1b beside T9 and T16, so the number of waves does not grow. **Where phase 1 is not unblocked:** T17 and T10 now wait for T22 as well as for T16, and T22 changes every manual start, so its risk sits on phase 1's critical path (risk S-K1). T16 gets smaller in exchange. Everything else of the convergence (T23 to T26) is outside phase 1: no phase-1 task depends on it, and T14 does not wait for it.

| Task | Depends on | Wave |
|---|---|---|
| T1 NATS wrapper and stream configuration | — | 1a |
| T2 `src/lib/schedule` | — | 1a |
| T3 Placement module | — | 1a |
| T8 Delete the bridge scheduler | — | 1a |
| T9 Actions core | T1, T2, T3 | 1b |
| T16 Delivery pipeline, hub side | T1, T3 | 1b |
| T22 One hub start procedure (S2) | T3 | 1b |
| T10 Matcher, router, runtime, run history | T9, T16, T22 | 1c |
| T17 Bridge executor | T8, T16, T22 | 1c |
| T12 CLI v2 | T9 (the `runs` verb: T10) | 1c |
| T13 UI | T3, T9 (the runs view: T10) | 1c |
| T14 Phase-1 integration, docs, E2E | all of phase 1 | 1d |
| T23 One start command `start_agent` (S2) | T22, T17 | Sa |
| T24 Notice fallback and bots on start-begin (S2) | T22, T17 | Sa |
| T25 Task lease dispatch on start-begin (S2) | T22, T23 | Sb |
| T26 Phase-S integration and E2E (S2) | T23, T24, T25 | Sc |
| T18 `[events]` notices on the pipeline | T16, T17; the event-inbox fix (below) | 2 |
| T4 Placement adoption | T3 | 3a |
| T19 Bots and the `bot` action target | T10, T16, T17, T24 | 3a |
| T20 Task lease wakes | T16, T17, T23, T25 | 3a |
| T21 Phase-3 integration and E2E | T4, T19, T20 | 3b |

Tasks of one wave can run in parallel. Each works in its own task branch.

**Files touched by two tasks of one wave.** The second to merge rebases; neither may revert the other's lines.

| File | Tasks | Rule |
|---|---|---|
| `src/hub/repository/sqlite/migrations.odin` | T9, T16, T22 | each adds its file last (6.4.1) |
| `src/hub/app/wiring.odin` | T9, T16, then T10 | additive blocks |
| `src/hub/transport/http/bridge_handlers.odin` | T9 (removes scheduler handlers), T16 (adds hooks), T22 (adds the start-begin handler) | different procedures |
| `src/bridge/hub_runtime_client.odin` | T8, then T17, then T23 | each depends on the one before |
| `src/hub/service/agent/agent_service.odin` | T3, then T22, then T23 | each depends on the one before |
| `src/hub/service/taskv2/lease.odin` | T25 (phase S), T4 (phase 3) | different statements of `grant_attempt_in_uow`. The refusal of a wake grant to a bridge without a live connection arrives with whichever merges first: `test_grant_refused_no_live_connection` (T25) and `test_lease_requires_live_connection` (T4) both stay |
| `src/bridge/agent_wake.odin` | T8 keeps it unchanged; T17 changes it; T24 deletes the manifest branch | each depends on the one before |
| `src/hub/service/eventrelay/relay.odin` | T1 only (the wake on commit of S2 included) | — |

**Dependency on the event-inbox fix (`task_18ea483f167575d2`).** A separate change, outside this chain, is reworking event subscriptions (EV1: a quick fix; EV2: subscriptions owned by an instance, `subscriber_instance_id`, deleted with the instance, notice target = the owning instance only, counts and rate limits per instance). T18 MUST be started only after that work has merged to `origin/main`, and MUST be written against whatever subscription model is on `origin/main` then. Nothing in this spec assumes that a subscription belongs to a durable agent identity, nor that it belongs to an instance: T18 uses the instance id and bridge id that the inbox hands to its notice callback (`domain.Event_Notice_Target`) and changes nothing about how that target is chosen. No other task touches `src/hub/service/eventinbox`, except T1's one-line change in `filters.odin`.

## 8. Tasks

Each task section lists: goal, contracts, files, ordered steps, non-goals, acceptance, and named tests with their expected result. "Files" names what the task creates, changes or deletes. A task MUST NOT edit files outside its list, except for call sites the compiler forces it to touch; it reports those at hand-off.

### T1. NATS wrapper and stream configuration

**Goal.** Give the hub the NATS features that schedules and the matcher need, and switch the stream on for them.
**Requirements.** REQ-SCHED-0 (conditions C1, C2, C4), REQ-SCHED-5, REQ-PIPE-1 and the JetStream half of REQ-PIPE-4 and REQ-PIPE-7 (the additions below).
**Contracts.** 6.3 (all of it, including 6.3.5 and 6.3.6), 6.2.5.
**Depends on.** Nothing.

**Files**

| File | Change |
|---|---|
| `src/lib/nats/nats.odin` | Add the fields and procedures of 6.3.1 |
| `src/lib/nats/ffi.odin`, `src/lib/nats/adapter.c` | Pass the two stream flags, the deliver policy and the message timestamp; add the purge and version functions |
| `src/lib/nats/nats_test.odin` | New scenarios (below) |
| `src/lib/nats/README.md` | Document the additions and the nats-server 2.14 requirement for schedules |
| `src/hub/service/eventrelay/relay.odin` | `stream_config` (6.3.2); `Schedule_Support`, `schedule_support`, `schedule_rejects` (6.3.3); the three row branches (6.3.4) |
| `src/hub/service/eventrelay/relay_test.odin` | New tests (below) |
| `src/hub/service/eventinbox/filters.odin` | `subject_token` (`src/hub/service/eventinbox/filters.odin:43`) becomes a call to `nats.subject_token` |

**Steps**

1. Add `allow_msg_schedules` and `allow_msg_ttl` to `Stream_Config` (`src/lib/nats/nats.odin:35`), to the FFI call and to `ham_nats_stream`. Map them to `cfg.AllowMsgSchedules` and `cfg.AllowMsgTTL`.
2. Add `deliver_new` to `Consumer_Config` and to `ham_nats_consumer_add`. Replace the hard-coded policy at `src/lib/nats/adapter.c:109` with `deliver_new ? js_DeliverNew : js_DeliverAll`. Existing callers pass nothing and keep `js_DeliverAll`.
3. Add `timestamp_ns` to `Metadata` and copy `meta->Timestamp` in `ham_nats_metadata`. Add the field at the end of both the C and the Odin struct.
4. Add `stream_purge_subject`, `subject_token`, `version_at_least` and `server_supports_schedules`.
5. Change `eventrelay.stream_config`. Search the repository for other `Stream_Config` literals with the name `HEIM_EVENTS` and make them use `eventrelay.stream_config`.
6. After each successful stream setup in `step_inner`, call `nats.server_supports_schedules` and store the result atomically.
7. Add the row branches of 6.3.4 to `step_inner`.

**Non-goals.** No matcher or consumer for actions. No code that publishes schedule definitions. No change to how the event inbox consumes. No change to `max_age` or the duplicate window.

**Acceptance**

- All tests below pass against the flake's `nats-server`, and the existing tests of `src/lib/nats`, `src/hub/service/eventrelay` and `src/hub/service/eventinbox` still pass.
- The flake checks `nats` and `events-relay` (`flake.nix:429`) pass, which runs both packages under valgrind.
- `grep -n "js_DeliverAll" src/lib/nats/adapter.c` shows it only as the default branch.

**Tests** (`src/lib/nats/nats_test.odin`: new scenarios called from the existing root test `test_jetstream_real_server`, plus two pure tests)

| Name | Expected |
|---|---|
| `scenario_schedule_every` | A definition with `Nats-Schedule: @every 1s` and a target in the same stream produces at least 2 messages on the target within 4 s; each carries `Nats-Schedule-Next` and the definition's custom header |
| `scenario_schedule_cron_time_zone` | `Nats-Schedule: * * * * * *` with `Nats-Schedule-Time-Zone: Asia/Kolkata` fires; `Nats-Schedule-Next` ends in `+05:30` |
| `scenario_schedule_at_past` | `@at` with a time in the past fires once at once, with `Nats-Schedule-Next: purge`; afterwards `subject_count` of the definition subject is 0 |
| `scenario_ttl_never_outlives_max_age` | On a stream with `max_age` 2 s, a definition with `Nats-TTL: never` is still present after 4 s and a plain message is gone |
| `scenario_purge_subject` | After `stream_purge_subject` of an `@every 1s` definition, `purged` is 1 and no further fire arrives within 3 s. Purging an empty subject returns `purged` 0 and no error |
| `scenario_stream_update_keeps_data` | A stream created with the old configuration (no flags, subjects `ev.>`), holding 3 messages and 1 durable consumer, is updated to the new configuration: 3 messages remain and the consumer still answers `consumer_state` |
| `scenario_deliver_new` | With 2 messages stored, a consumer created with `deliver_new` returns nothing from `fetch_available`; after one more publish it returns exactly that message |
| `scenario_metadata_timestamp` | `timestamp_ns` of a fetched message is within 5 s of now |
| `scenario_supports_schedules` | `server_supports_schedules` is true on the flake server |
| `test_version_at_least` | `"2.14.0"`, `"2.14.7"`, `"3.0.0"`, `"2.14.0-RC.1"` → true; `"2.13.9"`, `"2.12.3"`, `""`, `"abc"` → false |
| `test_subject_token` | `"usr_1"` → true; `""`, `"a.b"`, `"a*"`, `"a>"`, `"a b"` → false |

Tests in `src/hub/service/eventrelay/relay_test.odin`:

| Name | Expected |
|---|---|
| `test_relay_stream_has_schedule_subjects` | After one `step`, a publish to `sched.def.x` is accepted by the stream |
| `test_relay_purge_row` | An outbox definition row followed by a purge row for the same subject: both end `published`, and `subject_count` of the subject is 0 |
| `test_relay_poison_schedule_row` | A definition row with `Nats-Schedule: 0 99 * * * *` is marked published, `schedule_rejects` is 1, and the next ordinary row is published |
| `test_relay_drops_definitions_when_unsupported` | With the support state forced to `Unsupported`, a `sched.def.` row is marked published and nothing is stored on its subject |
| `test_relay_reports_schedule_support` | After one `step` against the flake server, `schedule_support` is `Supported` |

**T1 additions in v7 (REQ-PIPE-1).** Contracts 6.3.5 and 6.3.6. They are part of this task, not a separate one.

Further files: none beyond the table above. Further steps, after step 7:

8. Add `Retention` and `Stream_Config.retention`; pass it through the FFI call; replace the hard-coded `cfg.Retention = js_LimitsPolicy` at `src/lib/nats/adapter.c:83` with a mapping from the new argument.
9. Add `Consumer_Config.max_ack_pending`; pass it through `ham_nats_consumer_add`; set `cfg.MaxAckPending` only when the value is greater than 0.
10. Add `nak_reply_delay`, `in_progress_reply`, `term_reply` (plain publishes, 6.3.5) and `stream_delete_message`.
11. Add `eventrelay.DELIVERY_STREAM` and `eventrelay.delivery_stream_config`. In the relay's connect block, create `HEIM_DELIVER` right after `HEIM_EVENTS`, with the same add-then-update fallback; the connection is kept only when both succeeded.

Further non-goals: no consumer on `HEIM_DELIVER`; no code that publishes to `dlv.>`; no change to the event inbox's advisory stream.

Further acceptance: `grep -n "js_LimitsPolicy" src/lib/nats/adapter.c` shows it only as the default branch; valgrind (the flake check `nats`) is clean with the new scenarios.

Further tests in `src/lib/nats/nats_test.odin` (scenarios called from `test_jetstream_real_server`):

| Name | Expected |
|---|---|
| `scenario_work_queue_ack_removes` | On a work-queue stream, an acked message is gone: `subject_count` of its subject is 0 |
| `scenario_work_queue_disjoint_consumers` | Two durable consumers with filters `dlv.*.b1.>` and `dlv.*.b2.>` are both created; a message on `dlv.u.b1.prompt` is fetched by the first and never by the second; a third consumer with filter `dlv.>` is refused (JetStream error 10100) |
| `scenario_max_ack_pending` | With `max_ack_pending` 16 and 20 messages stored, one fetch of 20 returns 16 |
| `scenario_nak_reply_delay` | After `nak_reply_delay(reply, 3000)`: `fetch_available` returns nothing for 2 s; the message is redelivered within 4 s with `num_delivered` 2 |
| `scenario_in_progress_reply` | With `ack_wait` 2 s: `in_progress_reply` at 1.5 s; no redelivery at 3 s; redelivery by 4.5 s |
| `scenario_term_reply` | After `term_reply`: no redelivery within `ack_wait` + 1 s, and `subject_count` of the subject is 0 |
| `scenario_ack_reply_work_queue` | `ack_reply` on a stored reply subject removes the message from the work-queue stream |
| `scenario_max_deliver_advisory` | With `max_deliver` 3 and `ack_wait` 1 s, on a stream that captures `$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.<stream>.>`: after the third delivery and one more waiting fetch, one advisory is stored whose body has the stream, the consumer and `stream_seq`; the message is not delivered a fourth time; `subject_count` of its subject is still 1 |
| `scenario_delayed_nak_counts_toward_max_ack_pending` | With `max_ack_pending` 2: fetch two messages and nak both with `nak_reply_delay` of 3 s; a third message is **not** delivered within 2 s; after the delay the two are redelivered. This pins fact N10. If the third message **is** delivered, stop and report: the in-flight design of 6.11.4 is then stricter than needed but still correct |
| `scenario_ack_reply_async` | `ack_reply_async(conn, reply)` returns without waiting; after `flush`, the message is gone from a work-queue stream |
| `scenario_delete_message` | After `stream_delete_message` of that sequence, `subject_count` is 0; deleting it again returns `deleted = false` and no error |

Further tests in `src/hub/service/eventrelay/relay_test.odin`:

| Name | Expected |
|---|---|
| `test_relay_creates_delivery_stream` | After one `step`, `nats.stream_info` finds `HEIM_DELIVER`, and a publish to `dlv.u.b.prompt` is accepted |
| `test_relay_publishes_delivery_row_once` | An outbox row with subject `dlv.u.b.prompt` and `event_id` `dlv_1` is published; `subject_count` is 1. A second row with the same `event_id` cannot be inserted (unique constraint of `event_outbox`) |
| `test_relay_delivery_row_does_not_block_events` | A `dlv.` row followed by an `ev.` row: both end published |

**Async ack (v7 rework).** T1 also adds `ack_reply_async :: proc(conn: ^Connection, reply: string) -> Error`: a plain publish of `+ACK` to the reply subject, with no request and no wait (the existing `ack_reply` stays for the event inbox). It is specified with the other reply calls in 6.3.5.

**Added by amendment S2 (REQ-SCALE-2, REQ-SCALE-4).**

| File | Change |
|---|---|
| `src/hub/service/eventrelay/relay.odin` | `wake`, `RELAY_BATCH`, the semaphore wait and the batch pass of 6.3.4 |
| `src/hub/repository/sqlite` (the commit procedure and `event_outbox_repo.odin`) | The "appended an outbox row" mark and the after-commit hook |
| `src/hub/app/wiring.odin` | Sets the hook to `eventrelay.wake` |
| `src/lib/nats/natstest` scenarios | `scenario_schedule_fire_ttl` |

Steps, after the task's own: (1) locate every commit path (the Assumption of 6.3.4) and report them; (2) the mark, the hook and `wake`; (3) the semaphore wait; (4) the batch pass; (5) `scenario_schedule_fire_ttl`, and report whether the server honours `Nats-Schedule-TTL`.

| Name | Expected |
|---|---|
| `test_relay_wakes_on_commit` (`eventrelay`) | the relay is idle; a transaction that appends one row commits: the row is published within 200 ms, measured against a relay whose idle wait is set to 10 s in the test |
| `test_relay_rollback_does_not_wake` (`eventrelay`) | a rolled-back transaction that appended a row signals nothing and publishes nothing |
| `test_relay_publishes_batch_in_order` (`eventrelay`) | 200 pending rows: published in `outbox_seq` order in at most 4 passes; with row 70 made to fail, rows 1 to 69 are published and row 70 is retried first |
| `test_relay_idle_fallback_wait` (`eventrelay`) | a row inserted without the hook (directly in the database) is still published after the fallback wait |
| `scenario_schedule_fire_ttl` (`natstest`) | a definition with `Nats-Schedule-TTL: 2s` on a stream with `max_age` 1 hour: its fire is in the stream after 1 s and gone after 4 s; the definition itself (`Nats-TTL: never`) is still there |

### T2. `src/lib/schedule`

**Goal.** One pure schedule evaluator that the hub uses for validation, for the guard, for the cron text sent to nats-server and for the "next fire" display.
**Requirements.** REQ-SCHED-1.
**Contracts.** 6.2.4.
**Depends on.** Nothing.

**Files**

| File | Change |
|---|---|
| `src/lib/schedule/schedule.odin` | New. The pure evaluator, copied from `src/bridge/action_scheduler.odin:87` to line 389, with the prefix `action_scheduler_` removed from every name |
| `src/lib/schedule/nats_cron.odin` | New. `nats_cron` |
| `src/lib/schedule/schedule_test.odin` | New |
| `src/lib/schedule/testdata/America_New_York.tzif` | Copied from `src/bridge/testdata/America_New_York.tzif` |

The bridge keeps its own copy until T8 deletes it. T2 does not edit `src/bridge`.

**Signatures**

```odin
package schedule // imports core: only

// Copied; behaviour unchanged.
Parsed_Cron :: struct { minutes: [60]bool, hours: [24]bool, dom: [32]bool, months: [13]bool, dow: [8]bool, dom_is_wildcard, dow_is_wildcard: bool }
parse_cron_field      :: proc(field: string, min_val, max_val: int, bits: ^[]bool) -> bool
parse_cron            :: proc(expr: string) -> (cron: Parsed_Cron, ok: bool)       // exactly 5 fields
format_rfc3339_utc    :: proc(ms: i64) -> string
parse_rfc3339_ms      :: proc(s: string) -> (i64, bool)
days_from_civil       :: proc(y_in, m, d: int) -> int
civil_from_days       :: proc(z: int) -> (year, month, day: int)
weekday_from_days     :: proc(days: int) -> int
next_cron_slot        :: proc(cron_expr, tz_name, blackout_json: string, active_from_ms, active_until_ms, after_ms: i64) -> (next_ms: i64, ok: bool)
next_cron_slot_region :: proc(cron_expr: string, reg: ^datetime.TZ_Region, blackout_json: string, active_from_ms, active_until_ms, after_ms: i64) -> (next_ms: i64, ok: bool)
advance_interval_ms   :: proc(target_run_at_ms: i64, interval_seconds: int, now_ms: i64) -> (next_run_ms: i64, completed: bool)
is_blackout_date      :: proc(blackout_json: string, year, month, day: int) -> bool

// New.
// 5-field user cron -> 6-field nats-server cron by the rules of 6.2.4. out is allocated in allocator.
nats_cron :: proc(expr: string, allocator := context.allocator) -> (out: string, ok: bool)
// True when the IANA zone can be loaded. "UTC" and "" are valid.
timezone_valid :: proc(name: string) -> bool
// The civil date of an instant in a zone. ok = false when the zone cannot be loaded.
local_date :: proc(ms: i64, tz_name: string) -> (year, month, day: int, ok: bool)
local_date_region :: proc(ms: i64, reg: ^datetime.TZ_Region) -> (year, month, day: int)
```

`nats_cron` needs the text of each field and its parsed set. Parse each of the five fields with `parse_cron_field` into its own bit set. Emit `*` when the field's text is exactly `*`; otherwise emit the set values in ascending order, comma-separated. For day-of-week, treat bit 7 as bit 0.

Ownership: `format_rfc3339_utc` and `nats_cron` return strings the caller frees. Everything else returns values. A region loaded inside `next_cron_slot`, `timezone_valid` or `local_date` is destroyed before the procedure returns.

**Steps**

1. Copy the evaluator region and rename. Do not change behaviour.
2. Port every test of `src/bridge/action_scheduler_test.odin` that exercises a copied procedure. Keep the expected values.
3. Add `nats_cron`, `timezone_valid`, `local_date`, `local_date_region` and their tests.

**Non-goals.** No timer, no queue, no claim or lease logic (lines after 389 of the bridge file are not copied). No NATS import. No change to the bridge.

**Acceptance**

- `nix develop -c odin test src/lib/schedule -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/schedule-$$` passes with a non-zero test count, with the tracking allocator clean.
- `grep -n "odin_test:" src/lib/schedule/*.odin` prints nothing.
- **Assumption to verify:** `timezone_valid("America/New_York")` is true on the hub host (the zone database is found at run time). If it is not, stop and report; schedule triggers with a time zone would be rejected there.

**Tests** (`src/lib/schedule/schedule_test.odin`)

| Name | Expected |
|---|---|
| the ported evaluator tests | the same results as in the bridge package |
| `test_nats_cron_steps_and_ranges` | `*/15 9 * * 1-5` → `0 0,15,30,45 9 * * 1,2,3,4,5` |
| `test_nats_cron_star_only_when_exact` | `0 0 */1 * *` → day-of-month is `1,2,…,31` written out, not `*`; `0 0 * * */1` → day-of-week is `0,1,2,3,4,5,6` |
| `test_nats_cron_dow_fold` | day-of-week `7` → `0`; `5-7` → `0,5,6`; `0-7` → `0,1,2,3,4,5,6`; `1,7` → `0,1` |
| `test_nats_cron_rejects_invalid` | 4 fields, 6 fields, `60 * * * *`, `? * * * *` → `ok = false` |
| `test_local_date_new_york` | with the test zone file, `2026-11-21T03:30:00Z` → 2026-11-20 |
| `test_cron_dst_gap`, `test_cron_dst_overlap` | Each asserts what `next_cron_slot_region` returns for `30 2 * * *` across 2027-03-14 and for `30 1 * * *` across 2027-11-07 in New York. The test comment states whether the result equals nats-server (which skips the gap and fires twice in the overlap). A difference is allowed, because the hub uses this result only for display; report it at hand-off |

### T3. Placement module; bots and the agent service on it; candidates endpoint

**Goal.** Create `src/hub/service/placement`, move the bots placement logic and the agent service's eligibility checks into it, delete the dead code, and expose the ordered candidates.
**Requirements.** REQ-PLACE-1, REQ-PLACE-2 (for `agent` and `bots`), REQ-PLACE-4, REQ-PLACE-5, REQ-PLACE-6 (server part).
**Contracts.** 6.10 (all of it). The rows of 6.10.9 marked T3.
**Depends on.** Nothing.

**Files**

| File | Change |
|---|---|
| `src/hub/service/placement/placement.odin`, `eligibility.odin`, `selector.odin` | New: the types and procedures of 6.10 |
| `src/hub/service/placement/placement_test.odin`, `boundary_test.odin` | New |
| `src/hub/service/bots/placement.odin` | Emptied into the module. What remains: conversion between `domain.Bot_Placement_Candidate` and `placement.Rule`, conversion of `placement.Candidate` to `contracts.Bot_Candidate_Wire`, and the cap |
| `src/hub/service/bots/supervisor.odin`, `src/hub/service/bots/service.odin`, `src/hub/service/bots/placement_test.odin` | Call the module |
| `src/hub/transport/http/bot_handlers.odin` | `bot_placement_options_handler` takes `online` and `bot_capable` from `bridge_eligible` |
| `src/hub/service/agent/agent_service.odin`, `src/hub/service/agent/instance_reconfiguration.odin`, `src/hub/service/agent/tool_stream.odin` | Inline checks → `bridge_eligible` + `launchable`; delete the dead procedures; `validate_provider_model_intersection` becomes a wrapper |
| `src/hub/service/provider/provider_service.odin` | Delete `validate_launchable` |
| `src/hub/transport/http/provider_handlers.odin`, `src/hub/transport/http/bridge_handlers.odin`, `src/hub/transport/http/agent_handlers.odin` | Redirect their callers |
| `src/hub/repository/sqlite/provider_profiles_test.odin`, `provider_models_test.odin` | The `validate_launchable` cases move to `src/hub/service/placement/placement_test.odin` |
| `src/hub/transport/http/placement_handlers.odin` | New: `placement_candidates_handler` (6.10.7) |
| `src/hub/app/wiring.odin` | Build one `placement.Service` in the app graph; give it to bots and to the new handler; register the route |

**Steps**

1. Create the package with the types of 6.10.1. `new_service` registers `FIRST_SATISFIABLE`. `selector_find("first")` MUST also succeed on a `Service` built as a plain struct literal with no registered selectors.
2. Move `require_launch_bridge_enabled` and the feature parse into `bridge_eligible`; add `bridge_has_feature(b: domain.Bridge, name: string) -> bool`. Move `validate_provider_model_intersection` into `launchable` and add the two additions of 6.10.2.
3. Implement `candidates`, `match`, `validate_rules`, `select` by moving the bots procedures (6.10.3, 6.10.5). Keep the bots tests' expected outcomes.
4. In package `agent`, add `agent_placement :: proc(service: ^Agent_Service) -> placement.Service`, which builds the struct from the service's own fields (`bridges`, `agents`, `providers`, `bridge_runtime_registry`, `entitlements`). Replace every inline check listed in 6.10.9 (rows `prepare_instance` to `reconfiguration_validate_live_destination`, and lines 1134 to 1138 of `relaunch_instance_locked`) with `bridge_eligible` + `eligibility_error` and `launchable`. Each caller keeps its own error message where it has one, but takes the decision from the predicate. Exception (requirements revision 4): `validate_instance_message_configuration` retains its existing non-launch connectivity check as described in 6.10.9.
5. Delete `select_bridge_for_agent`, `require_enabled_support`, `validate_launchable`, `bots_bridge_capable`, `require_launch_bridge_enabled`, `bridge_feature_supported`. Keep `validate_provider_model_intersection` as `return placement.launchable(…, agent_id = "", …)` with a comment that T4 deletes it.
6. Redirect bots: `bots_select_bridge` → `placement.select` with `features = {"bot_deliver_v1", "instance_reconfiguration_v1"}`, `exclude` = the bridges tried in this round, `prefer_bridge` = the bridge of the bot's instance, `agent_id` = the bot's agent. `bots_expand_candidates` → `match` over `candidates` with `only_bridge`, truncated to the cap.
7. Redirect `supported_bridge_count_for_agent`.
8. Add the candidates handler and route.

**Non-goals.** No change in `taskv2`, `taskchain`, `mcp` or the UI (T4). No selector other than `first` in production code. No "hub chooses" API (6.10.8). No change to the bridge-side candidate loop.

**Acceptance**

- The eight tests of `src/hub/service/bots/placement_test.odin` pass with unchanged expected outcomes: `test_placement_validation_errors`, `test_expand_candidates_empty_policy_allows_all`, `test_expand_candidates_ranks_preferred_first`, `test_expand_candidates_star_model_takes_first_active`, `test_expand_candidates_truncates_to_three`, `test_select_bridge_sticky_first`, `test_select_bridge_skips_tried_and_unsupported`, `test_placement_snapshot_alias_matches_resolved_model`. They may call the new procedures.
- The existing tests of `src/hub/service/agent`, `src/hub/service/bots`, `src/hub/service/provider`, `src/hub/transport/http`, `src/hub/app` and `src/hub/service/taskv2` pass.
- The deleted procedures are gone: `grep -rn "select_bridge_for_agent\|require_enabled_support\|validate_launchable\|bots_bridge_capable\|require_launch_bridge_enabled\|bridge_feature_supported" src/hub` prints nothing.
- The package builds with no import cycle and obeys 5.3.
- The hand-off lists the behaviour changes of 6.10.4 that T3 causes.

**Tests** (`src/hub/service/placement/placement_test.odin` unless stated)

| Name | Expected |
|---|---|
| `test_bridge_eligible_table` | One case per reason of 6.10.2, in order, plus the eligible case. A bridge with two problems reports the earlier reason |
| `test_launchable_table` | blank provider or model; disabled support row; no support row (allowed); inactive catalog provider; inactive model; unknown model; provider not enabled; provider not detected; bad profile; the valid case |
| `test_launchable_accepts_model_alias` | a model given by its alias is accepted and the result carries the `model_id` |
| `test_match_first_rule_decides` | a candidate that matches rules 0 and 2 gets `rule_position` 0 |
| `test_match_wildcard_model_keeps_first_active` | rule `(ANY, p, ANY)` keeps one model per (bridge, provider) |
| `test_match_empty_rules_allow_all` | no rules → every candidate, tier `Allowed`, position 0 |
| `test_match_order` | the order of 6.10.3: tier, rule position, provider order, model order, bridge age, bridge id |
| `test_match_drops_unmatched_and_duplicates` | — |
| `test_validate_rules_codes` | one case per detail code of 6.10.3 |
| `test_select_prefer_bridge_wins` | a matching candidate on `prefer_bridge` wins over a better-ranked one elsewhere |
| `test_select_exclude_and_only_bridge` | — |
| `test_select_no_candidate` | `ok = false`, reason `no_candidate` |
| `test_second_selector_needs_no_caller_change` | a selector `last` registered in the test is used by `select(…, "last")`; `select(…, "nope")` gives `unknown_selector` |
| `test_candidates_allocator_ownership` | with a tracking allocator: `candidates` then `candidates_destroy` leaves nothing allocated |
| `test_bot_skips_inactive_catalog_provider`, `test_bot_skips_bridge_with_agent_disabled` (`src/hub/service/bots/placement_test.odin`) | the changes of 6.10.4 |
| `test_prepare_instance_refuses_pending_bridge` (`src/hub/service/agent`) | a bridge with pending enrollment, and a revoked bridge, are refused |
| `test_placement_candidates_endpoint` (`src/hub/transport/http`) | the response shape of 6.10.7; candidates in order; an offline bridge appears in `bridges` with `eligible = false` and its reason; another owner's bridge never appears |
| `test_placement_imports` (`boundary_test.odin`) | no file of the package imports a package that 5.3 forbids |
| `test_agent_and_bots_use_the_predicate` (`boundary_test.odin`) | non-test files under `src/hub/service/agent` and `src/hub/service/bots` contain no `bridge_runtime_registry_has_live(`, no `.plan_disabled_at` and no `status != .Online` or `status == .Online`, except non-launch connectivity/stop/fencing checks on a documented allow-list (file, procedure and reason) in the boundary test |

**T3 addition in v7.** The `feature` query parameter of the candidates endpoint (6.10.10), with the test `test_placement_candidates_feature_filter` (`transport/http`): with `feature=x` a bridge whose hello lacks `x` is listed with `eligible = false`, `reason = "missing_feature"` and has no candidate; without the parameter it is eligible.

### T8. Delete the bridge scheduler

**Goal.** Remove the bridge-side action scheduler. nats-server is the only scheduler (REQ-SCHED-4).
**Requirements.** REQ-ACT-12 (bridge part), REQ-SCHED-4.
**Depends on.** Nothing. It can merge before or after the hub tasks; T14 integrates them into one release.

**Files**

| File | Change |
|---|---|
| `src/bridge/action_scheduler.odin`, `action_scheduler_test.odin`, `action_snapshot_test.odin`, `action_gate_test.odin` | **Delete** |
| `src/bridge/testdata/America_New_York.tzif` | Delete if no other bridge test loads it |
| `src/bridge/time_format.odin` | New: `bridge_format_rfc3339_utc_ms :: proc(ms: i64) -> string`, which is `action_scheduler_format_rfc3339_utc` (`src/bridge/action_scheduler.odin:117`) moved with the civil-date helpers it needs |
| `src/bridge/extension_blockers.odin`, `fs_management.odin`, `enroll_device_flow.odin`, `hub_runtime_client.odin`, `shell_run_wait_test.odin`, `tool_activity_live_test.odin` | Call `bridge_format_rfc3339_utc_ms` |
| `src/bridge/main.odin` | Remove `bridge_action_scheduler_start()` (`src/bridge/main.odin:280`) |
| `src/bridge/hub_runtime_client.odin` | Remove the two `bridge_action_scheduler_connection_changed()` calls (`src/bridge/hub_runtime_client.odin:501`) and the reading of `schedules_version`, `schedules_epoch` and `schedules_revision` from the heartbeat ack (`src/bridge/hub_runtime_client.odin:1033`) |
| `src/bridge/credential_state.odin` | `bridge_refresh_after_publish` (`src/bridge/credential_state.odin:821`) no longer repairs the scheduler's sync key |
| `src/bridge/recovery_command.odin`, `src/bridge/retry_journal.odin` | Remove the `sync:` and `slot:` operations (below) |
| `src/bridge/vault_prune.odin` | Probe an ungated route (below) |
| `docs/bounded-action-recovery.md` | Remove the parts that describe the action sync and slot recovery; add a first line saying that the bridge scheduler was removed by this chain |

**Steps**

1. Add `src/bridge/time_format.odin` and switch every call site of `action_scheduler_format_rfc3339_utc` outside the scheduler files.
2. Delete the four scheduler files.
3. Remove the references in `main.odin`, `hub_runtime_client.odin` and `credential_state.odin`. An old hub still sends `schedules_*` fields in the heartbeat ack; the bridge now ignores them.
4. Retry journal: nothing creates a record with a key prefix `sync:` or `slot:` any more. A journal file written by an older bridge may hold such records; drop them when the journal is loaded, so that an upgraded bridge does not stay in a repair state. `ham-bridge recovery resume-sync` prints `nothing to resume: the action scheduler was removed` and exits 0. `resume-refresh` is unchanged. **Assumption to verify first:** the `sync:` and `slot:` keys are used only by the action scheduler. If any other operation uses them, stop and report.
5. `vault prune`: change the probe at `src/bridge/vault_prune.odin:113` from `GET /api/v1/bridge/actions` to `GET /api/v1/bridge/update-catalog` (registered at `src/hub/app/wiring.odin:1152`; its handler `src/hub/transport/http/bridge_auto_update_handlers.odin:15` checks the bridge token and is behind no experiment). The verdict mapping at `src/bridge/vault_prune.odin:29` is unchanged.

**Non-goals.** No change to `bridge_task_wake_if_needed`, to its wrapper `bridge_task_status_notify_wake_local`, or to the wrapper's three callers (T17 changes `bridge_task_wake_if_needed` later; this task does not). No new request to the hub. No hub-side change (the hub routes and heartbeat fields are removed in T9).

**Acceptance**

- `nix develop -c odin build src/bridge -collection:odin_test=src` succeeds, and the bridge tests pass.
- `grep -rn "action_scheduler\|schedules_version\|schedules_epoch\|schedules_revision" src/bridge` prints nothing.
- The tests below pass.

**Tests**

| Name (package) | Expected |
|---|---|
| `test_bridge_format_rfc3339_utc_ms` (`bridge`) | the cases of the deleted scheduler test for this procedure, same results |
| `test_prune_probe_is_ungated` (`bridge`) | the probe request path is `api/v1/bridge/update-catalog` |
| `test_update_catalog_probe_status_codes` (`src/hub/transport/http`) | a live bridge token gets 2xx whether or not the owner has the `actions` experiment; a revoked token gets 401 or 403. If a revoked token gets any other status, stop and report: the probe would not detect dead tokens |
| `test_retry_journal_drops_scheduler_records` (`bridge`) | a journal holding `sync:` and `slot:` records loads with none of them and with no repair state |
| `test_heartbeat_ack_with_schedule_fields_is_ignored` (`bridge`) | an ack that carries `schedules_version` is processed without error |

**T8 note for v7.** `src/bridge/agent_wake.odin` is kept in full: the wake gate, back-off, parking and `bridge_provider_runnable` are what the bridge executor builds on (T17). Only the two calls from `action_scheduler.odin` disappear with that file.

### T9. Actions core: schema reset, registry, API v2, schedule sync, hub cleanup

**Goal.** Replace the old action model on the hub with actions, rules, triggers and runs; add the trigger registry, the write-time schedule sync, the reconcile procedure, the template renderer and API v2; delete the hub code that served the bridge scheduler.
**Requirements.** REQ-ACT-1, REQ-ACT-2, REQ-ACT-3 (the part for the files of this task), REQ-ACT-5, REQ-ACT-8 (routes), REQ-ACT-9, REQ-ACT-12 (hub part), REQ-SCHED-0 (conditions C3, C4, C6), REQ-SCHED-2, REQ-SCHED-5 (API part).
**Contracts.** 6.2, 6.3.3, 6.4, 6.5, 6.6, 6.9, 6.14, 6.15.
**Depends on.** T1, T2, T3.

**Files**

| File | Change |
|---|---|
| `src/hub/repository/sqlite/migrations/actions_001_reset.sql` | New (6.4) |
| `src/hub/repository/sqlite/migrations.odin` | Register the migration (three edits, 6.4); delete `upgrade_scheduled_prompts_schema`, `upgrade_actions_schema` and their calls |
| `src/hub/domain/action.odin` | Rewritten (6.5) |
| `src/hub/repository/iface/action_repo.odin`, `src/hub/repository/iface/repos.odin` | Rewritten interface; remove `scheduled_prompts` |
| `src/hub/repository/sqlite/action_repo_sqlite.odin` and its tests | Rewritten; remove the snapshot connection |
| `src/hub/service/actions/service.odin` | New: `Service`, inputs, `create`, `update`, `set_enabled`, `delete_action`, `get`, `list`, `trigger_types` |
| `src/hub/service/actions/triggers.odin`, `schedule_kind.odin`, `event_kind.odin` | New: the registry and both kinds (6.6) |
| `src/hub/service/actions/schedule_sync.odin` | New: the row builders of 6.2.2 and 6.2.3; `reconcile_plan` and `reconcile` (6.2.6) |
| `src/hub/service/actions/template.odin`, `gate.odin` | New (6.9, 6.15) |
| `src/hub/service/actions/*_test.odin`, `boundary_test.odin` | New |
| `src/hub/transport/http/action_handlers.odin` | Rewritten: thin handlers for 6.14, except the runs route (T10) |
| `src/hub/transport/http/bridge_handlers.odin` | Remove the `schedules_version`, `schedules_epoch` and `schedules_revision` fields from the heartbeat ack and the code that computes them |
| `src/hub/app/wiring.odin` | Build `actions.Service`; register the routes of 6.14; remove the routes and fields listed under "Deleted" |

**Service signatures** (`src/hub/service/actions/service.odin`)

```odin
Service :: struct {
	factory:      ^iface.Unit_Of_Work_Factory,
	repos:        ^iface.Repositories,
	placement:    ^placement.Service,
	experiments:  ^iface.Experiment_Repository,
	support:      Schedule_Support_Port,
	clock:        ^platform.Clock,
	ids:          ^platform.ID_Generator,
	target_kinds: []string, // phase 1: {"agent", "instance"}; heap-allocated at wiring
}

Rule_Input    :: struct { bridge_id, provider, model: string }
Target_Input  :: struct { kind, agent_id, project_id, instance_id, bot_id, instance_strategy, selector: string, rules: []Rule_Input }
Trigger_Input :: struct { id, kind: string, config: json.Object, enabled: Maybe(bool) }
Action_Input  :: struct { // a nil Maybe = the field was absent from the request
	name, prompt_text: Maybe(string),
	enabled:           Maybe(bool),
	min_interval_s:    Maybe(int),
	target:            Maybe(Target_Input),
	triggers:          Maybe([]Trigger_Input),
}
Action_View :: struct { action: domain.Action, rules: []domain.Action_Target_Rule, triggers: []domain.Action_Trigger }
action_view_destroy  :: proc(v: ^Action_View)
action_views_destroy :: proc(rows: []Action_View)

create        :: proc(s: ^Service, owner: string, in_: Action_Input) -> (Action_View, domain.Domain_Error)
update        :: proc(s: ^Service, owner, action_id: string, in_: Action_Input) -> (Action_View, domain.Domain_Error)
set_enabled   :: proc(s: ^Service, owner, action_id: string, enabled: bool) -> (Action_View, domain.Domain_Error)
delete_action :: proc(s: ^Service, owner, action_id: string) -> domain.Domain_Error
get           :: proc(s: ^Service, owner, action_id: string) -> (Action_View, domain.Domain_Error) // .Not_Found for another owner
list          :: proc(s: ^Service, owner: string) -> ([]Action_View, domain.Domain_Error)

// schedule_sync.odin
Stored_Definition :: struct { subject, trigger_id: string, rev: int }
Reconcile_Op      :: struct { publish: bool, trigger: ^domain.Action_Trigger, purge_subject: string } // publish = false means purge
// Pure. The result is allocated in allocator and points into triggers.
reconcile_plan :: proc(stored: []Stored_Definition, triggers: []domain.Action_Trigger, allocator: mem.Allocator) -> []Reconcile_Op
// One reconcile attempt (6.2.6). done = false when the outbox backlog was not 0.
reconcile :: proc(s: ^Service, conn: ^nats.Connection) -> (done: bool, err: domain.Domain_Error)
```

Ownership: an `Action_View` and everything in it is allocated in `context.allocator`; the caller frees it with `action_view_destroy`. Inputs are borrowed. `Service` holds pointers only, except `target_kinds`.

**Steps**

1. Write the migration and register it. Delete the two upgrade procedures.
2. Rewrite the domain types, the repository interface and the SQLite implementation.
3. Write the registry and both kinds. `schedule_kind.compile` validates with `schedule.parse_cron` and `schedule.timezone_valid`, and builds the header value with `schedule.nats_cron`.
4. Write the service. Each write runs in one unit of work and follows "One transaction per write" in 6.14. The target is validated through `uow.repos` (the agent, instance or chain must exist and belong to the owner). Rules are validated with `placement.validate_rules(…, domain.ACTION_MAX_RULES)`.
5. Apply the `rev` rule (6.6.1), then call `on_change` once per trigger with the effective flags before and after. For `set_enabled` and for a patch that changes `enabled`, this is called for every trigger of the action.
6. Refuse an effective `schedule` trigger while the support state is `Unsupported` (6.3.3).
7. Write `reconcile_plan` and `reconcile`. T9 does not call `reconcile` from production code; T10 does.
8. Write `render` (6.9) and `actions_gate_on` (6.15).
9. Rewrite the handlers and the routes. Register `trigger-types` before the wildcard route.
10. Delete the hub code listed below.

**Deleted on the hub**

| What | Where |
|---|---|
| `run_action_handler` and the route `POST /api/v1/actions/*/run` | `src/hub/transport/http/action_handlers.odin:512` |
| `bridge_list_actions_handler`, `bridge_execute_action_handler` and the routes under `/api/v1/bridge/actions` | `src/hub/transport/http/action_handlers.odin:596`, `src/hub/transport/http/action_handlers.odin:650` |
| The alias routes `/api/v1/scheduled-prompts*` | `src/hub/app/wiring.odin` (search for `scheduled-prompts`) |
| The duplicate cron validation `validate_cron_expression` | `src/hub/transport/http/action_handlers.odin:136` |
| The epoch, token, snapshot and lease code of the old handlers, and the `Action_Handlers` fields that only they use | `src/hub/transport/http/action_handlers.odin:19` and the rest of the file |
| The heartbeat `schedules_*` fields | `src/hub/transport/http/bridge_handlers.odin` (search for `schedules_`) |

After T9 and before T12 and T13 merge, the old CLI and UI call routes that no longer match. That is accepted inside phase 1: the feature is behind the `actions` experiment and T14 integrates all of it into one release.

**Non-goals.** No matcher, router, runtime thread or runs route (T10). No `bot` target (`target_kinds` has no `"bot"`). No call to NATS from any write path. No data migration. No change to the CLI or the UI.

**Acceptance**

- Every test below passes; the tracking allocator is clean in each.
- `grep -rn "scheduled_prompts\|scheduled-prompts\|action_schedule_revision\|schedules_version\|run_action_handler\|bridge_execute_action_handler" src/hub --include=*.odin` prints matches only in the migration `.sql` files and in the `DROP` statements.
- The existing test suites of `src/hub/repository/sqlite`, `src/hub/transport/http` and `src/hub/app` pass.

**Tests**

| Name (package) | Expected |
|---|---|
| `test_actions_reset_from_old_schema` (`repository/sqlite`) | A database built by every migration before `actions_001_reset.sql`, holding rows in `actions` and `scheduled_prompts`, migrates; the new tables exist and are empty; the old tables, the six triggers and `action_schedule_revision` are gone. Running the migrations a second time changes nothing |
| `test_action_repo_round_trip` (`repository/sqlite`) | save, get, list, rules replace, trigger save and delete, delete of an action removes rules, triggers and runs |
| `test_action_runs_one_open` (`repository/sqlite`) | a second `queued` row for the same action violates `action_runs_one_open`; `run_insert` with a duplicate `occurrence_key` returns `inserted = false` |
| `test_run_transition_cas` (`repository/sqlite`) | a transition from the wrong state returns `changed = false` and writes nothing |
| `test_runs_prune` (`repository/sqlite`) | keeps the newest 200 and nothing older than the cutoff; never deletes an open run |
| `test_schedule_compile_table` (`actions`) | one case per row of the config table in 6.6.2, valid and invalid; unknown key rejected |
| `test_event_compile_table` (`actions`) | subject filter with and without `chain_id`; unknown type; a data key outside the descriptor; a chain of another owner → `unknown_chain` |
| `test_schedule_definition_row` (`actions`) | the headers and body of 6.2.2 for cron with a zone, cron in UTC (no zone header), interval, once |
| `test_one_outbox_row_per_schedule_save` (`actions`) | create with one schedule trigger → 1 definition row; an update that changes only the name → 0 rows; a config change → 1 definition row with `rev` 2; disable → 1 purge row; enable → 1 definition row; delete → 1 purge row |
| `test_action_disable_purges_all_schedules` (`actions`) | an action with 2 schedule triggers and 1 event trigger: disable appends 2 purge rows and bumps 3 revs |
| `test_reconcile_plan_table` (`actions`) | the four cases of 6.2.6 |
| `test_reconcile_waits_for_backlog` (`actions`) | with a pending outbox row, `reconcile` returns `done = false` and appends nothing |
| `test_reconcile_real_server` (`actions`, natstest) | missing definition republished; stale `rev` republished; orphan purged; a matching one untouched (its stream sequence is unchanged) |
| `test_fake_trigger_kind` (`actions`) | a kind appended to `extra_trigger_kinds` in the test is accepted by `create`, and its `compile` and `on_change` are called. The test file is the only file that names it |
| `test_render_table` (`actions`) | every placeholder of 6.9; spaces inside braces; unknown placeholder left as written; a value that contains `{{…}}` is not expanded again |
| `test_actions_api_crud` (`transport/http`) | create with two triggers and two rules; get returns the shape of 6.14; patch replaces triggers by id; enable and disable; delete; another owner gets 404 |
| `test_actions_api_validation` (`transport/http`) | one case per row of the validation table in 6.14 |
| `test_actions_api_bot_target_refused_in_phase_1` (`transport/http`) | `target.kind = "bot"` → 422 `target_kind_unavailable` |
| `test_actions_api_instance_target_of_bot_refused` (`transport/http`) | `target.kind = "instance"` with a bot's instance → 422 `target_is_bot_instance`; nothing is saved |
| `test_actions_api_schedules_unsupported` (`transport/http`) | support `Unsupported`: a schedule trigger → 409 `schedules_unsupported`; an event trigger is accepted; `trigger-types` reports `schedules_supported: false` |
| `test_actions_api_flag_off` (`transport/http`) | with the experiment off every route of 6.14 returns the "experimental feature disabled" error |
| `test_actions_routes` (`app`) | `GET /api/v1/actions/trigger-types` reaches its handler, not the `{id}` handler; `POST /api/v1/actions/x/run`, `/api/v1/scheduled-prompts` and `/api/v1/bridge/actions` are not routed |
| `test_actions_imports` (`actions/boundary_test.odin`) | the package imports nothing that 5.3 forbids; no file under `src/hub/service/taskv2` or `src/hub/service/taskchain` imports `actions` |

**T9 changes in v7.** The schema, domain types and repository are those of 6.4 and 6.5 as written in this document:

- `action_runs.state` includes `routed`; the column `delivery_id` exists; the index `action_runs_one_open` covers `queued`, `deferred` and `routed`.
- `domain.ACTION_RUN_ROUTED`, `domain.action_run_open`, `Action_Run.delivery_id`.
- `run_open` returns the `queued`, `deferred` or `routed` run. `runs_due` never returns a `routed` run. `run_last_started_at` replaces `run_last_delivered_at`. `runs_prune` never deletes a `routed` run.
- T9 does **not** create `pipeline_deliveries` or `agent_instances.start_ref` (T16 and T22, 6.4.1).
- `test_action_repo_round_trip` and `test_runs_prune` cover the `routed` state: a `routed` run is returned by `run_open`, blocks a second open run through the index, is not returned by `runs_due`, and is not pruned.
- No code written by T9 names the reasons `user_stopped`, `needs_recovery` or `target_busy`.

**Added by amendment S2 (REQ-SCALE-4, REQ-SCALE-5, REQ-LOOKUP-1).** The schema of 6.4 has the column `action_triggers.match_key`, the three-column index `action_triggers_match` and the index `action_runs_due`. The service sets `match_key` on every trigger save (6.6.1). `triggers_match` takes the subject (6.5). Definition and deferral rows carry `Nats-Schedule-TTL` (6.2.2, 6.2.3). T9 creates `test_event_path_queries_use_indexes` with the statements it owns (Q3 to Q10 of 6.16) exported as constants.

| Name | Expected |
|---|---|
| `test_match_key_derivation` (`actions`) | a schedule trigger: `match_key` = `ev.<owner>.sched.<trigger_id>`; an event trigger with a chain: that chain's subject; an event trigger for any chain: `''`; changing the chain filter rewrites it |
| `test_triggers_match_reads_only_matching_keys` (`repository/sqlite`) | one owner with 1000 enabled schedule triggers and one wildcard event trigger of another type: `triggers_match(owner, "schedule.fired", <subject of trigger 500>)` returns exactly that trigger |
| `test_schedule_rows_carry_fire_ttl` (`actions`) | a definition row and a deferral row both have `Nats-Schedule-TTL` = `24h` |
| `test_event_path_queries_use_indexes` (`repository/sqlite`) | no table scan in the plans of Q3 to Q10 |

### T16. Delivery pipeline, hub side

**Goal.** A durable, at-least-once hop from "the hub decided to deliver something to an instance on bridge B" to "bridge B answered". (Amendment S2: the start-begin call moved to T22.)
**Requirements.** REQ-PIPE-1 to REQ-PIPE-4, REQ-PIPE-6 to REQ-PIPE-10, REQ-SCALE-3, REQ-LOOKUP-1 (rows Q15 to Q20).
**Contracts.** 6.11.1 to 6.11.5, 6.11.7 to 6.11.11, 6.4.1, 6.5.1, 6.16. The bridge side (6.11.6) is T17; start-begin (6.12) is T22.
**Depends on.** T1 (wrapper additions, `HEIM_DELIVER`), T3 (nothing is imported from `placement`, but `Requirements.features` is how callers apply the feature).

**Files**

| File | Change |
|---|---|
| `src/contracts/delivery_wire.odin` | New: the constants and structs of 6.11.1 and 6.11.2 |
| `src/hub/domain/pipeline_delivery.odin` | New (6.5.1) |
| `src/hub/repository/iface/pipeline_delivery_repo.odin`, `src/hub/repository/iface/repos.odin` | New repository interface; field `pipeline_deliveries` |
| `src/hub/repository/sqlite/pipeline_delivery_repo_sqlite.odin` | New |
| `src/hub/repository/sqlite/migrations/pipeline_001_deliveries.sql`, `src/hub/repository/sqlite/migrations.odin` | New migration, registered last (6.4.1) |
| `src/hub/service/delivery/delivery.odin` | New: types, `new_service`, `register_sink`, `start`, `stop`, `bridge_capable`, `route`, `expire`, `expire_due`, `prune`, `retry_delay_ms` |
| `src/hub/service/delivery/forwarder.odin` | New: the forwarder thread and the forward gate (6.11.4) |
| `src/hub/service/delivery/result.odin` | New: `on_command_result` (6.11.5) |
| `src/hub/service/delivery/offline.odin` | New: `on_bridge_online`, `on_bridge_offline`, `on_bridge_deleted` (6.11.7) |
| `src/hub/service/delivery/advisory.odin` | New: the supervisor thread and the advisory drain (6.11.8) |
| `src/hub/service/delivery/*_test.odin`, `boundary_test.odin` | New |
| `src/hub/transport/http/bridge_handlers.odin` | Field `delivery`; the three hooks of 6.11.3 |
| The HTTP handler that calls `revoke_bridge` | The `on_bridge_deleted` hook |
| `src/hub/app/wiring.odin` | Build, start and stop the service; the handler field |
| `flake.nix` | A check `delivery-pipeline` that runs `src/hub/service/delivery` under valgrind, modelled on `events-relay` (`flake.nix:429`) |

**Steps**

1. Contracts file, domain type, repository, migration. Run the repository round-trip test.
4. `route`, `bridge_capable`, `retry_delay_ms`, `expire`.
5. The forwarder and the gate.
6. `on_command_result`.
7. The offline hooks.
8. The supervisor: connect, advisory stream and consumer, `expire_due`, the advisory drain.
9. Wiring and the hooks in `bridge_handlers.odin`.
10. The boundary tests and the flake check.

**Reconnect handling** is an **implementer choice** inside these constraints: only the supervisor creates or closes the NATS connection, and only while it holds `conn_lock` exclusively (6.11.4); no thread other than the supervisor and the forwarders calls package `nats`; a forwarder that gets a connection error drops its pull binding, reports the error to the supervisor (an atomic flag plus the supervisor's wake-up) and waits on its semaphore; after a reconnect each forwarder creates a new pull binding (step 2 of the pass). Follow `eventrelay.step_inner` (`src/hub/service/eventrelay/relay.odin:93`) for the connect and back-off pattern; the supervisor's back-off wait is the advisory fetch timeout or, while not connected, a wait of at most 5 s between connect attempts, as the relay does.

**Test double.** The tests need a bridge. Build a fake in the test package: a `project.Bridge_Command_Sink` whose `send_runtime_command` records each frame and returns what the test set (sent or offline), and a registry stub that reports the bridge live or not. The test then calls `on_command_result` with the answer it wants. NATS is a real server through `natstest`.

**Non-goals.** No bridge code (T17). No sink of any flow (T10, T18, T19, T20 register theirs). No start-begin and no change to any start procedure (T22). No change to task lease dispatch or bots. No change to the event inbox's advisory handling. No timer, tick or sleep. No read of `stopped_by`.

**Acceptance**

- The tests below pass against the flake's `nats-server`; the tracking allocator is clean; the flake check passes.
- The existing tests of `src/hub/service/agent`, `src/hub/transport/http` and `src/hub/service/eventrelay` pass with unchanged counts, apart from the new tests.
- `grep -n "time.sleep\|thread.sleep" src/hub/service/delivery/*.odin` prints nothing outside `_test.odin` files.
- `grep -rn "stopped_by" src/hub/service/delivery` prints nothing.

**Tests** (package `delivery` unless stated; all NATS tests use `natstest`)

| Name | Expected |
|---|---|
| `test_pipeline_delivery_repo_round_trip` (`repository/sqlite`) | insert, get, `transition` compare-and-set (a wrong `from_state` changes nothing), `open_for_bridge`, `open_by_ref`, `expired`, `prune` |
| `test_migration_pipeline_001` (`repository/sqlite`) | the table and its four indexes exist after `run_migrations`; the existing `event_deliveries` table is untouched |
| `test_route_writes_row_and_outbox` | one `pipeline_deliveries` row in state `routed` and one `event_outbox` row with subject `dlv.<owner>.<bridge>.prompt`, `event_id` = the delivery id and a body that parses as `Delivery_Wire`; a rollback of the unit of work leaves neither |
| `test_route_refuses_incapable_bridge` | a bridge without the feature → `Conflict`, message `bridge_too_old`; no rows |
| `test_route_validation` | an owner or bridge id with a `.`; an unknown kind; `lifetime` 0; `round` 3 → `Validation_Failed` |
| `test_retry_delay_table` | attempts 1 to 7 with `asked` 0 → 10, 20, 40, 80, 160, 300, 300 s; `asked` 120 s on attempt 1 → 120 s; `asked` 1 h → 300 s |
| `test_forward_and_ack` | a routed delivery is forwarded as an `event_deliver` frame with `command_id` `<id>:1`, `attempt` 1, `final` false; the row is `forwarded` with `ack_reply` set **before** the fake sink is called; `succeeded` → row `done`, the sink's `on_final` called once, the stream holds no message on the subject |
| `test_accepted_keeps_message` | `accepted` only: with `ack_wait` shortened to 2 s in the test, no redelivery at 3 s (in-progress restarted the clock); the row stays `forwarded` |
| `test_retry_redelivers_after_delay` | `failed`/`retry` → no frame before the delay, a second frame with `command_id` `<id>:2` after it; the row stays `forwarded` |
| `test_fatal_terminates` | `failed`/`fatal` with a sink without `replace` → row `failed` with the answer's reason, `on_final` once, no redelivery, the message is gone |
| `test_fatal_is_replaced_when_sink_allows` | a sink whose `replace` routes a new delivery: the old row is `replaced`, the new one `routed` with `round` 1 and the old bridge in `excluded_bridges`; `on_final` is not called |
| `test_gate_drops_closed_rows` | a message whose row is `done`, `failed` or `replaced` is acked and no frame is sent |
| `test_gate_expires` | a message whose row has `expires_at` in the past: row `failed`, `bridge_offline`; `on_final`; acked; no frame |
| `test_gate_still_valid_false` | row `failed`, `superseded`; no frame |
| `test_gate_unknown_delivery_is_terminated` | a body with an unknown `delivery_id`, and a body that is not JSON: terminated, counted, no frame |
| `test_send_failure_keeps_forwarded` | the fake sink reports offline: the row stays `forwarded` (never back to `routed`); no nak is sent; the message is redelivered after AckWait (the test sets the service's AckWait to 1 s through a test-only field) with `attempt` 2; the rest of the fetched batch was not sent |
| `test_final_flag_on_last_attempt` | with `max_deliver` lowered to 3 in the test: the third frame has `final` true |
| `test_retry_on_final_attempt_is_fatal` | `failed`/`retry` answered on the last attempt → row `failed`, `no_answer` |
| `test_result_is_idempotent` | the same `succeeded` answer twice; a `failed` after `succeeded`; an answer for an unknown id; an answer from another bridge: one `on_final` in total, no error |
| `test_transition_lost_cas_is_a_no_op` | the row is closed by `expire` between the gate's load and a second forward of the same message (drive it with two sequential gate calls on a redelivered message); and two `succeeded` answers handled one after the other: `on_final` once, one `Ack` queued, no frame for the closed row |
| `test_answers_are_queued_not_sent_on_caller_thread` | `on_command_result` with the NATS server stopped returns at once and leaves one `Answer` in the queue; no `nats` call happened on the calling thread (the fake connection counts calls per thread id) |
| `test_reconnect_while_answers_arrive` | a thread feeds 200 answers through `on_command_result` while the test restarts the NATS server twice: no crash, no leak under the tracking allocator, every row ends `done`, and after the last reconnect the stream holds no message of those deliveries |
| `test_in_flight_limit` | 40 routed deliveries for one bridge and a bridge that answers nothing: exactly 16 frames are sent; after 4 `succeeded` answers 4 more are sent |
| `test_waiting_retries_do_not_block_other_deliveries` | 20 deliveries answered `retry` (their rows have `retry_at` set), then one new delivery for another instance of the same bridge: it is forwarded at once, while the 20 wait for their delay |
| `test_in_flight_ignores_stale_rows` | 16 rows `forwarded` with `updated_at` older than AckWait and no answer: a new delivery is forwarded |
| `test_succeeded_from_older_attempt_counts` | attempt 1 is not answered, attempt 2 is forwarded, then `succeeded` arrives with `command_id` `<id>:1` → row `done`, the message is acked |
| `test_off1_route_does_not_check_liveness` | `route` to an offline capable bridge succeeds (the caller decides, OFF-1 exception) |
| `test_off2_routed_delivery_is_replaced_on_disconnect` | `on_bridge_offline` with one `routed` row and a replacing sink: old row `replaced`, new row on the other bridge; when the old bridge returns, its message is acked without a frame |
| `test_off2b_forwarded_delivery_is_not_replaced` | `on_bridge_offline` with one `forwarded` row: `replace` is not called; the row stays `forwarded` |
| `test_off2_max_three_rounds` | a row with `round` 2 is not offered to `replace` |
| `test_off3_waits_for_reconnect` | a `routed` row whose sink has no `replace`; the bridge is offline for longer than `ack_wait`; after `on_bridge_online` the frame is sent with `attempt` 1 |
| `test_off3_expired_on_reconnect` | the same, with `expires_at` passed while offline: `on_bridge_online` closes it `failed`, `bridge_offline` without a frame |
| `test_off4_exhausted_from_advisory` | with `max_deliver` 3 and no answers: after the third frame and the advisory, the row is `failed`, `no_answer`, `on_final` once, and the stream holds no message on the subject (it was deleted) |
| `test_off5_expire_due_at_start` | `start` with one expired open row: closed before any forward |
| `test_forward_launch_drop_reconnect_single_effect` | forward; the fake bridge "acts" and the socket drops before the answer (`on_bridge_offline`); `on_bridge_online`; the redelivered frame has `command_id` `<id>:2`; the fake answers `succeeded` as its ledger would → exactly one delivery row exists for the ref, it is `done`, and `replace` was never called |
| `test_downgraded_bridge_closes_deliveries` | `on_bridge_online` for a bridge that no longer lists the feature: `routed` rows go through `replace`, the rest are `failed`, `bridge_too_old`; the consumer `brg_<id>` no longer exists |
| `test_incapable_bridge_gets_no_consumer` | `on_bridge_online` for a bridge that never had the feature: no consumer, no forwarder, no frame |
| `test_deleted_bridge_closes_deliveries` | `on_bridge_deleted`: open rows `failed`, `target_missing`; consumer deleted |
| `test_redelivery_after_hub_restart` | forward; `stop` the service without an answer; `start` a new service on the same database and server; the message is forwarded again with `attempt` 2 and the answer closes it |
| `test_start_stop_clean` | start, one delivery end to end, stop: nothing left allocated; every thread joined |
| `test_delivery_imports` (`boundary_test.odin`) | no file of the package imports `actions`, `eventinbox`, `bots`, `taskv2`, `taskchain`, `agent` or `content` |
| `test_prune_runs_when_a_delivery_becomes_final` | (S2) a closed row older than 30 days and a hub that was started long ago: the next delivery that becomes `done` deletes it; a row younger than 30 days stays; an open row of any age stays |
| `test_prune_at_most_once_per_hour` | (S2) 100 deliveries become final within one hour of injected time: `prune` ran once; after the clock passes the hour, the next final delivery runs it again |
| `test_event_path_queries_use_indexes` (`repository/sqlite`) | (S2) the statements behind Q15 to Q20 of 6.16 have no table scan in their query plan |
| `test_pipeline_never_reads_stopped_by` (`boundary_test.odin`) | no non-test file under `src/hub/service/delivery`, and not `src/hub/service/agent/start_begin.odin` (once T22 has created it), contains `stopped_by ==`, `stopped_by !=` or `STOPPED_BY_USER`. T10 and T18 extend the scanned set to `src/hub/service/actions` and `src/hub/service/eventinbox` |

### T17. Bridge executor

**Goal.** The bridge acts on an `event_deliver` frame and answers.
**Requirements.** REQ-BRG-1 to REQ-BRG-5, REQ-SCALE-1.
**Contracts.** 6.11.2, 6.11.6, 6.12.3, 6.12.4.
**Depends on.** T8 (the scheduler is gone from the files this task edits), T16 (the contracts file), T22 (the start-begin route; amendment S2).

**Files**

| File | Change |
|---|---|
| `src/bridge/event_executor.odin` | New: `bridge_event_deliver_handle`, the decision table, `bridge_event_start`, the notice typing |
| `src/bridge/event_ledger.odin` | New (6.11.6) |
| `src/bridge/event_executor_test.odin`, `src/bridge/event_ledger_test.odin` | New |
| `src/bridge/agent_wake.odin` | `Bridge_Wake_Result`, `bridge_wake_attempt`, `bridge_wake_start_begin`; `bridge_task_wake_if_needed` becomes a caller of `bridge_wake_attempt` |
| `src/bridge/hub_command_dispatch.odin` | A `case "event_deliver"` in `bridge_command_spec` (`src/bridge/hub_command_dispatch.odin:245`) and in the ordering-key switch (`src/bridge/hub_command_dispatch.odin:408`) |
| `src/bridge/hub_runtime_client.odin` | The `event_deliver` branch in `bridge_hub_handle_command` (`src/bridge/hub_runtime_client.odin:1006`); three fields on `Bridge_Command_Runtime_Status` (`src/bridge/hub_runtime_client.odin:4337`); `bridge_event_result_json`; the feature in `BRIDGE_RUNTIME_FEATURES` (`src/bridge/hub_runtime_client.odin:4616`) |
| `src/bridge/main.odin` | `bridge_event_ledger_load()` next to `bridge_agent_wake_init()` (`src/bridge/main.odin:265`) |

**Signatures**

```odin
// agent_wake.odin
Bridge_Wake_Outcome :: enum { Launched, Already_Active, Coalesced, Backing_Off, Parked, Failed }
Bridge_Wake_Result  :: struct { outcome: Bridge_Wake_Outcome, err: Bridge_Error, retry_after_ms: i64 }
// The body of today's bridge_task_wake_if_needed, returning what happened.
// delivery_id == "": fetch the manifest with bridge_wake_fetch_enriched_launch_json (today's behaviour; T24 deletes this branch).
// delivery_id != "": call bridge_wake_start_begin with ref = delivery_id and launch with the command it returns.
bridge_wake_attempt :: proc(instance_id: string, now: i64, deadline_ns: i64 = 0, delivery_id: string = "") -> Bridge_Wake_Result
// Unchanged signature and behaviour: returns bridge_wake_attempt(instance_id, now, deadline_ns).outcome == .Launched
bridge_task_wake_if_needed :: proc(instance_id: string, now: i64, deadline_ns: i64 = 0) -> bool
bridge_wake_start_begin :: proc(instance_id, delivery_id: string, deadline_ns: i64 = 0) -> (launch_json, command_id: string, err: Bridge_Error, ok: bool)

// event_executor.odin
bridge_event_deliver_handle :: proc(conn: ^ws.Connection, text: string) // sends exactly one command_result, as its last frame
bridge_event_start :: proc(instance_id, delivery_id: string, deadline_ns: i64) -> Bridge_Wake_Result // = bridge_wake_attempt(..., delivery_id)
// Pure: the decision table of 6.11.6 as data in, decision out. Tested as a table.
Bridge_Event_Local  :: enum { Absent, Stopping, Booting, Idle, Busy }
Bridge_Event_Action :: enum { Answer_Stored, Answer_Started, Type_Notice, Start, Retry, Fatal }
bridge_event_decide :: proc(ledger: Maybe(Bridge_Ledger_Entry), local: Bridge_Event_Local, final: bool, busy_reason: string) -> (action: Bridge_Event_Action, reason: string, retry_after_ms: i64)

// hub_runtime_client.odin — next to bridge_command_result_json; the caller frees the string
bridge_event_result_json :: proc(command_id, status, outcome, class: string, retry_after_ms: i64, cause, message: string) -> string
```

The three new fields of `Bridge_Command_Runtime_Status` are `outcome: string`, `class: string` and `retry_after_ms: i64`, each tagged `omitempty`, so every existing `command_result` keeps its bytes.

**The command spec.** Copy the `launch_agent` row (`src/bridge/hub_command_dispatch.odin:270`): class `.Lifecycle`, key kind `.Agent`, queued, `timeout_ms = contracts.DELIVERY_HANDLER_BUDGET_MS`; and set `retry_safe = true` as the `bot_deliver` row does (`src/bridge/hub_command_dispatch.odin:276`). The ordering key is `agent:<agent_instance_id>`, read from the frame's top-level `agent_instance_id`.

**Steps**

1. The ledger, with its tests.
2. `bridge_wake_attempt` and the unchanged wrapper. Run the existing wake tests; they MUST pass unchanged.
3. `bridge_wake_start_begin`.
4. The result fields and `bridge_event_result_json`.
5. `bridge_event_decide` (pure), then `bridge_event_deliver_handle` around it: parse with `json.unmarshal_string` into `contracts.Event_Deliver_Wire` (temp allocator), read the ledger and the snapshot, decide, act, write the ledger, answer.
6. Dispatch registration and the feature flag. Add the feature **last**, so a bridge never advertises a handler it does not have.

**Rules**

- The handler holds no mutex across `bridge_runtime_launch_agent`: that function takes the per-instance lifecycle mutex itself (`src/bridge/agent_lifecycle.odin:26`).
- Lock order is wake mutex, then runtime mutex, as today (`src/bridge/agent_wake.odin:208`). The ledger mutex is a leaf: nothing else is taken while it is held.
- Strings kept beyond the handler (ledger entries) are heap-allocated; everything else uses the worker's allocators, which the dispatcher resets per job.
- Snapshot strings alias registry storage; copy what is kept.
- The deadline for the start comes from `bridge_command_worker_deadline_ns` (`src/bridge/hub_command_dispatch.odin:774`).

**Non-goals.** No NATS client. No new frame type. No change to `launch_agent`, `wake_agent`, `bot_deliver` or the three notice callers of the wake path. No user-stop state on the bridge. No handling of kinds `lease` and `bot` beyond the `unknown_kind` answer (T20, T19). No change to the manifest GET. (T23 and T24 change the commands, the notice callers and the manifest GET.)

**Acceptance**

- The tests below pass; the tracking allocator is clean; the existing bridge tests pass unchanged.
- `grep -rn "nats" src/bridge --include=*.odin` prints nothing new compared with `origin/main` (record the before and after counts).
- `grep -n "stopped_by" src/bridge -r` prints nothing.

**Tests** (package `main` of `src/bridge`; process table, PTY host, hub HTTP and clock are replaced through the existing `*_proc` test seams or new ones of the same style)

| Name | Expected |
|---|---|
| `test_event_decide_table` | one case per row of the table in 6.11.6: rows 0, 1, 3, 3b, 4 (not final / final), 5 (not final / final), 6, 7, 8, 8b, 9 |
| `test_event_row1_done_answers_stored_outcome` | a `Done` entry with outcome `started` → `succeeded`, `started`; nothing typed, nothing launched |
| `test_event_row4_draining_and_vault_locked` | not final → `retry`; final → `fatal` with the reason |
| `test_event_row6_booting_succeeds_without_typing` | `succeeded`, `started`; no notice call |
| `test_event_row7_idle_types_message_notice` | kind `prompt`: the call made is the one `notify_agent_message` makes, with sender `user`; ledger `Done`, `notified` |
| `test_event_row7_idle_types_events_line` | kind `notice`, count 3: the typed line is the `[events] 3 new event(s)` text |
| `test_event_row8_busy_asks_retry` | `failed`, `retry`; nothing typed; no ledger entry left |
| `test_event_row8b_busy_final_types_anyway` | `succeeded`, `notified` |
| `test_event_row9_absent_starts` | start-begin is called once with the delivery id; the launch receives exactly the returned `data.launch` text and its `command_id`; `succeeded`, `started`; ledger `Done` |
| `test_event_start_never_generation_zero` | the launch command passed to `bridge_runtime_launch_agent` has `run_count` > 0 in every start test |
| `test_event_start_same_command_as_launch_agent` | for one descriptor, the bytes passed to the launch function equal the hub's `launch_agent` body apart from `command_id` |
| `test_event_start_user_stopped_instance` | an instance with an active 15 s stop-intent mark: the start proceeds and the mark is cleared by the launch |
| `test_event_start_begin_failure_classes` | each row of 6.12.4 → the stated class and reason |
| `test_event_already_running_with_local_process_is_started` | (S2 rework) start-begin answers 409 `already_running` and the bridge's snapshot shows a booting process: `succeeded`, `started` |
| `test_event_already_running_without_snapshot_retries` | (S2 rework) the same answer and no snapshot, not final: `failed`, `retry`, `retry_after_ms` 30000, reason `hub_row_live`; nothing launched; the ledger entry is cleared so the next attempt decides again |
| `test_event_already_running_without_snapshot_final_is_fatal` | (S2 rework) the same on a `final` frame: `failed`, `fatal`, reason `hub_row_live`; never `succeeded` |
| `test_event_stale_row_recovers_after_reaper` | (S2 rework, with a fake hub) attempts 1 to 3 get 409, attempt 4 gets 200: attempt 4 launches with the new generation and answers `started` |
| `test_event_start_gate_coalesced_backoff_parked` | `Coalesced` and `Backing_Off` → `retry` with the remaining time; `Parked` → `fatal`, `start_parked` |
| `test_event_start_retriable_on_final_is_fatal` | a retriable start failure with `final` → `failed`, `fatal` |
| `test_event_final_never_retry` | for every local state and every failure, a `final` frame is answered `succeeded` or `failed`/`fatal` |
| `test_event_restart_in_progress_start_running` | a persisted `In_Progress`/`Start` entry, instance active → `succeeded`, `started`; no launch |
| `test_event_restart_in_progress_start_absent` | the same, instance absent → a fresh start |
| `test_event_restart_in_progress_type` | a persisted `In_Progress`/`Type` entry, instance idle → the notice is typed again |
| `test_event_unknown_kind_and_invalid_frame` | `fatal`, `unknown_kind` / `invalid_frame` |
| `test_event_answer_is_last_frame` | the handler's final captured frame is the `command_result` |
| `test_ledger_survives_restart` | write, reload from the file: the same entries |
| `test_ledger_evicts_by_expiry_plus_margin` | (S2) an entry whose `expires_ms` + 10 minutes has passed is gone after a write; one inside the margin stays, also when the ledger is full; an entry with `expires_ms` 0 lives 48 hours |
| `test_ledger_redelivery_inside_margin_has_no_second_effect` | (S2) a delivery typed at `expires_at` − 1 s and redelivered at `expires_at` + 61 s: answered from the ledger with the stored outcome; nothing typed, nothing launched |
| `test_ledger_bridge_clock_ahead` | (S2) the bridge clock is 8 minutes ahead of the frame's `expires_at` base: a redelivery of a `Done` delivery before `expires_at` (hub time) is still answered from the ledger |
| `test_ledger_holds_rate_times_lifetime` | (S2) 1000 prompt deliveries (lifetime 1 hour) spread over 10 hours of injected time: the ledger never holds more than 120 entries and `begin` never returns false |
| `test_ledger_full_answers_retry` | with 4096 live entries `begin` returns false and the executor answers `retry` (`fatal`, `ledger_full` when final) |
| `test_ledger_corrupt_file_starts_empty` | invalid JSON, version 2, 5000 entries: an empty ledger, and the bad file is renamed |
| `test_ledger_file_is_private` | mode 0600; directory 0700 (the properties of `bridge_retry_atomic_write`) |
| `test_wake_attempt_wrapper_unchanged` | `bridge_task_wake_if_needed` returns the same bool as before for: already active, coalesced, backing off, parked, launch ok, launch failed |
| `test_event_result_json_fields` | `outcome`, `class`, `retry_after_ms` appear under `payload.result` only when set; an ordinary `bridge_command_result_json` output is byte-identical to `origin/main` |
| `test_event_deliver_spec_and_key` | `bridge_command_spec("event_deliver")` is queued with the budget timeout; the ordering key is `agent:<id>` |
| `test_features_list_has_event_pipeline` | `bridge_runtime_features()` contains `event_pipeline_v1` |

### T10. Matcher, router, runtime, run history

**Goal.** Turn events into runs, and runs into routed prompt deliveries; close runs from the pipeline's reports.
**Requirements.** REQ-ACT-3, REQ-ACT-4, REQ-ACT-6, REQ-ACT-7, REQ-ACT-8 (router), REQ-ACT-13, REQ-ACT-14, REQ-SCHED-2 (reconcile is called), REQ-SCHED-3, REQ-SCHED-5 (router part), REQ-PIPE-8 (the placement requirement).
**Contracts.** 6.7, 6.8, 6.9, 6.13, 6.2.6, 6.11.3 (`route`, `Sink`), the runs route of 6.14.
**Depends on.** T9, T16.

**Files**

| File | Change |
|---|---|
| `src/hub/service/actions/matcher.odin` | New: `Matcher`, `handle_message`, `subject_matches`, `data_matches` |
| `src/hub/service/actions/router.odin` | New (6.13) |
| `src/hub/service/actions/runtime.odin` | New: the worker thread |
| `src/hub/service/actions/matcher_test.odin`, `router_test.odin`, `overlap_test.odin`, `runtime_test.odin` | New |
| `src/hub/transport/http/action_handlers.odin` | Add `list_action_runs_handler` |
| `src/hub/app/wiring.odin` | `Agent_Port` and `Route_Port` adapters; `delivery.register_sink` for kind `prompt`; start and stop the runtime next to the relay; the runs route |
| `flake.nix` | A check `actions-runtime` that runs `src/hub/service/actions` under valgrind, modelled on `events-relay` (`flake.nix:429`) |

**Signatures**

```odin
// matcher.odin
// Handles one message in its own unit of work (6.7, steps 1 to 8). acked = false means "leave for redelivery".
handle_message :: proc(r: ^Runtime, msg: Event_View) -> (acked: bool)
subject_matches :: proc(filter, subject: string) -> bool               // pure
data_matches    :: proc(filter_json: string, data: json.Object) -> bool // pure

// runtime.odin
Options :: struct { nats_url: string, max_deliver: int } // cloned into the heap by start
Runtime :: struct { svc: ^Service, router: Router, options: Options, thread: ^thread.Thread, stop_flag: i32 /* atomic */,
	skipped_owner_mismatch, terminated: i64 /* atomic counters */ }
start :: proc(r: ^Runtime, svc: ^Service, router: Router, options: Options) -> bool
stop  :: proc(r: ^Runtime) // sets the flag, joins the thread, frees the cloned options

// router.odin: the procedures of 6.13.1, 6.13.4 and 6.13.5
```

**One change to the matcher of 6.7 (v7).** In step 7, before the lookup of the action's open run, call `expire_open_run(router, uow, action_id)` (6.8.4). The open-run lookup `run_open` returns a run in state `queued`, `deferred` or `routed`.

**The runtime thread** follows `eventrelay.entry` (6.1). One pass:

1. If not connected: connect with the same options the relay uses. On failure wait 1 s and start the pass again.
2. After a new connection: wait until `nats.stream_info` finds `HEIM_EVENTS` (the relay creates it); `nats.consumer_add` with the settings of 6.7 (an existing durable is kept); `nats.pull_bind`; set "reconcile pending"; call `drain_due` once.
3. If reconcile is pending, call `reconcile`; clear the flag when it returns `done = true`.
4. `nats.fetch(pull, 64, 1000)`. For each message: build the `Event_View`, call `handle_message`, ack when it returns true. If the envelope's `type` is `action.resume`, clone the subject's owner token and `data.run_id` into the pass arena as a `Resume_Hint`. Destroy the batch.
5. If the batch was not empty, call `drain_due` with the hints of this batch. If the support state read through the port is `Unsupported` and was not on the previous pass, call `drain_due` once.
6. `free_all(context.allocator)`.

The runtime is started in `src/hub/app/wiring.odin` directly after `delivery.start` and stopped directly before `delivery.stop`. `max_deliver` is the value the event inbox is started with.

**Wiring adapters.** `Agent_Port` (6.13.2): `find` lists the owner's instances of the agent through the agent service and applies the match rule, then reads the conversation with `content.get_conversation_by_instance` (`src/hub/service/content/content_service.odin:237`); `create` calls `agent.create_instance_stopped` (6.12.5) with the candidate's bridge, provider, profile and model and the action's project; `stop` calls `agent.stop_instance` (`src/hub/service/agent/agent_service.odin:842`) with reason `"action_fresh_per_run"`; `instance` reads one row; `persist_prompt` calls `content.persist_user_message` with `Message_Input{body, message_type = "action", metadata_json}` (`src/hub/service/content/content_service.odin:87`); `retire_prompt` calls `content_mark_messages_read` and rewrites the message's `metadata_json`. Each builds `contracts.Auth_Context{kind = .Internal_User, user_id = owner}`. `Route_Port` forwards to `delivery.route` and `delivery.expire`.

`retire_prompt` needs a way to rewrite one message's metadata. **Implementer choice:** use an existing content-repository update if one fits; otherwise add `content_update_message_metadata(r, owner, message_id, metadata_json, updated_at)` to `src/hub/repository/iface/content_repo.odin` and its SQLite implementation. Either way it is owner-scoped and writes one row.

`persist_user_message` refuses a conversation whose instance configuration is being changed (`src/hub/service/content/user_message.odin:15`). The router treats that as any other storage error: the run is `failed`, `delivery_failed`.

**Steps**

1. Write the pure helpers and `handle_message`.
2. Write the router: `drain_due`, Decide, Plan, Route, `prompt_effect`, target resolution.
3. Write `on_delivery_final`, `on_delivery_replace`, `expire_open_run`, and register the sink.
4. Write the runtime thread and its wiring.
5. Add the runs handler and route. The handler calls `expire_open_run` for the action before it reads the rows.
6. Add the flake check. Extend the scan set of `test_pipeline_never_reads_stopped_by` (T16) with `src/hub/service/actions`.

**Non-goals.** No timer or tick. No second effect kind. No retry logic of its own: retries belong to the pipeline. No waiting queue for placement. No bot path (a bot target cannot exist before T19). No bridge command and no NATS publish from the router: it only writes rows.

**Acceptance**

- The twenty-two cases of 6.8.5 pass under the names given there.
- The tests below pass; the tracking allocator is clean; the flake check passes.
- `grep -n "time.sleep\|thread.sleep" src/hub/service/actions/matcher.odin src/hub/service/actions/router.odin` prints nothing.
- `grep -rn "stopped_by\|user_stopped\|target_busy\|needs_recovery" src/hub/service/actions --include=*.odin` prints nothing outside test files.

**Tests** (package `actions` unless stated; `natstest` = against a real server; "fake pipeline" = a `Route_Port` that records `Route_Input` and writes nothing else)

| Name | Expected |
|---|---|
| `test_c01_…` to `test_c22_…` | 6.8.5 |
| `test_deferral_fire_real_server` (natstest) | with `min_interval_s` 5, the second match is deferred, nats-server delivers the `@at` fire, and the run is routed within 10 s without any other event |
| `test_subject_matches_table`, `test_data_matches_table` | wildcard token, token count mismatch, literal mismatch; missing key, non-string value compared as text, empty filter |
| `test_matcher_tenant_isolation` | an event of owner A never creates a run for a trigger of owner B, even with an identical chain id; an envelope whose `owner_user_id` differs from the subject is acked with no rows and counted |
| `test_matcher_terminates_bad_body` (natstest) | a body that is not a JSON object is terminated, counted, and not redelivered |
| `test_matcher_ignores_disabled_action_and_trigger` | no row |
| `test_once_fire_retires_trigger` | after the fire the trigger is disabled, `rev` + 1, one purge row; the run is `queued` |
| `test_window_and_blackout` | before `active_from` → `outside_window`; after `active_until` → `outside_window` and the trigger is retired; blackout date in the trigger's zone → `blackout` |
| `test_matcher_joins_routed_run` | a match while the action's run is `routed` is stored `joined` to it; no `Route_Input` is recorded |
| `test_matcher_expires_routed_run_before_join` | the open run's delivery has `expires_at` in the past: the match closes it `failed`, `bridge_offline` and is itself stored `queued` |
| `test_router_route_transaction_is_atomic` | with the real `delivery.route` and an in-memory database: after one drain there is exactly one chat message (`message_type = "action"`, direction `user_to_agent`), one `pipeline_deliveries` row, one `event_outbox` row with a `dlv.` subject, and the run is `routed` with `delivery_id`, `message_id`, `target_instance_id`, `started_at` set. All four appear in one commit: a fault injected after the message insert leaves none of them and the run still `queued` |
| `test_router_crash_before_route_routes_again_once` | the fault of the previous test, then a second drain: one chat message in total, one delivery |
| `test_router_crash_after_route_delivers_once` | a second drain after a committed route does nothing: `runs_due` does not return a `routed` run |
| `test_router_claim_is_exclusive` | two drains started for the same `queued` run: one route, one message |
| `test_router_flag_off` | `skipped`, `experiment_off`; nothing routed |
| `test_router_metadata_and_cause` | a schedule run routes with `cause = "schedule"`, `ref = "run:<id>"`, `notice_line = "message"`, `lifetime` 1 h, and stores the metadata of 6.13.1; an event run uses `cause = "event"` |
| `test_final_done_started_and_notified` | `on_delivery_final` with `done`/`started` and with `done`/`notified`: the run is `delivered` with `finished_at` |
| `test_final_failed_reason_mapping` | each delivery reason of 6.11.9 → the run reason of 6.13.4 |
| `test_final_stale_report_is_ignored` | a report for a delivery that is not the run's current `delivery_id`, and a report for a run that is already closed: no change |
| `test_retried_busy_target_ends_delivered` | route; the run stays `routed` across three `retry` answers (driven through the real `delivery` package with a fake bridge); then `succeeded` → `delivered`. Meanwhile two further matches are `joined` |
| `test_place_first_rule` | rule 0 satisfiable → `rule_position` 0 |
| `test_place_falls_to_second_rule` | the bridge of rule 0 is offline → rule 1 |
| `test_place_any_bridge_uses_module_order` | rule `(ANY, ANY, ANY)` → the first candidate of `placement.match` |
| `test_place_provider_any_model` | rule `(b, p, ANY)` → the provider's first active model |
| `test_place_requires_pipeline_feature` | two eligible bridges, only the second lists `event_pipeline_v1` → the second is used. No bridge lists it → `failed`, `bridge_too_old` |
| `test_place_pinned_offline_machine_waits` | rules name one bridge, it is offline, an instance exists there: the run is `routed` to it. With no instance there: `failed`, `no_placement` |
| `test_reuse_finds_or_creates` | an existing matching instance is used; none → `create` and `set_last_spawned` |
| `test_reuse_rule_one_beats_running_instance_on_rule_two` | a new instance is created under rule 0 |
| `test_reuse_user_stopped_instance_is_used` | the matching instance has `stopped_by = "user"`: it is the target; the run is `routed`; rule 1 is not tried |
| `test_reuse_failed_or_unreachable_instance_is_used` | an instance in `failed` or `unreachable`: it is the target (the bridge decides) |
| `test_fresh_per_run_stops_previous` | a new instance per run, created stopped; the previous one is stopped after the commit with a non-user reason |
| `test_no_placement` | `failed`, `no_placement` |
| `test_instance_target_missing_and_offline` | a missing instance → `target_missing`; an instance on an offline bridge → `routed` (it waits); on a revoked bridge → `no_placement`; on a bridge without the feature → `bridge_too_old` |
| `test_replace_moves_prompt_to_next_rule` | `on_delivery_replace` for a `routed` delivery on bridge 1 with rules for bridges 1 and 2: a second chat message exists in the instance of bridge 2; the first is read and its metadata has `moved_to_instance_id`; the run is `routed` with the new delivery; the new delivery has `round` 1 and bridge 1 excluded |
| `test_replace_refuses_instance_target_and_closed_run` | returns false; nothing written |
| `test_runs_pruned_after_finish` | more than 200 finished runs → 200 remain. Repeated for three histories that never reach the route: only `skipped: experiment_off` (router Decide), only `skipped: stale_rev` (matcher), only `joined` behind one deferred run (matcher) |
| `test_runs_endpoint` (`transport/http`) | newest first, `limit`, `before`, `joined_count`, the states `routed` and `delivered`; a `routed` run whose delivery expired is returned as `failed`, `bridge_offline`; another owner gets 404; flag off is refused |
| `test_runtime_start_stop_clean` (natstest) | start, one event routed end to end through fake ports, stop; nothing left allocated |
| `test_runtime_reconciles_on_connect` (natstest) | a schedule trigger saved while NATS was down has its definition in the stream after connect |
| `test_matcher_and_router_name_no_kind` (`boundary_test.odin`) | `matcher.odin` and `router.odin` do not contain the strings `"schedule"` or `"event"` as kind names, except `"schedule.fired"`, `"schedule"` and `"event"` in the cause mapping |

**Added by amendment S2.** T10 also depends on T22: the router creates instances with `agent.create_instance_stopped` through `Agent_Port` (6.12.5). The matcher passes the event's subject to `triggers_match` (6.7 step 4). `runs_due` and `runs_deferred` are written with `state IN ('queued','deferred')` so they use `action_runs_due`. If T1 reported that the server ignores `Nats-Schedule-TTL`, the matcher deletes each schedule fire and deferral fire by its stream sequence after its commit (6.3.4); otherwise it does not. T10 adds its statements (Q8, Q9, Q12 of 6.16) to `test_event_path_queries_use_indexes`.

| Name | Expected |
|---|---|
| `test_schedule_fire_reads_one_trigger` (`actions`) | an owner with 500 schedule triggers; one fire: the repository returned one trigger row for it (counted by a wrapping repository), and one run exists |
| `test_exact_and_wildcard_triggers_both_match` (`actions`) | an event trigger for one chain and one for any chain, same owner and type: an event of that chain creates a run for each; an event of another chain only for the wildcard one |

### T12. CLI v2

**Goal.** Make `ham-ctl hub actions` speak API v2.
**Requirements.** REQ-ACT-11.
**Contracts.** 6.14.
**Depends on.** T9, T10.

**Files.** `src/ctl/hub_mode.odin` (`ctl_hub_actions`, `src/ctl/hub_mode.odin:534`; the help text at `src/ctl/hub_mode.odin:662`; the body struct above line 534), `src/ctl/main.odin` (the top-level dispatch at `src/ctl/main.odin:143` also names the aliases `scheduled-prompts` and `scheduled-prompt`; remove them there), the ctl tests, and the `ham-ctl-reference` skill text if it lists the actions verbs.

**Commands**

```
ham-ctl hub actions list
ham-ctl hub actions show <action-id>
ham-ctl hub actions create --prompt <text> [--name <text>] <target> [--min-interval <seconds>] [--disabled] [--trigger <spec>]... [--trigger-json <json>]...
ham-ctl hub actions update <action-id> [--prompt <text>] [--name <text>] [<target>] [--min-interval <seconds>] [--trigger <spec>]... [--trigger-json <json>]...
ham-ctl hub actions enable <action-id>
ham-ctl hub actions disable <action-id>
ham-ctl hub actions delete <action-id>
ham-ctl hub actions runs <action-id> [--limit <n>] [--before <created_at>]

<target> is one of:
  --agent-id <id> [--project <id>] [--instance-strategy reuse|fresh_per_run] [--rule <bridge>:<provider>[:<model>]]...
  --instance <id>
  --bot <id>
```

| `--trigger` spec | Trigger |
|---|---|
| `cron:<5-field expr>[@<timezone>]` | `{"kind":"schedule","config":{"mode":"cron","cron_expr":…,"timezone":…}}`. Split at the **last** `@` |
| `every:<seconds>` | mode `interval` |
| `at:<RFC3339>` | mode `once` |
| `event:<event_type>[,chain=<id>][,<data key>=<value>]...` | kind `event`; every pair other than `chain` goes into `config.data` |

- `--trigger-json` takes one trigger object as in 6.14 and is the way to set `blackout_dates`, `active_from` and `active_until`.
- In `--rule`, each part is a value or `*`; a missing model means `*`. The order of the flags is the rule order.
- On `update`, giving any `--trigger` or `--trigger-json` replaces the whole trigger list, and giving any target flag replaces the whole target. The help text says so.
- The CLI does not check `target_kinds`; the server's 422 is printed.
- The verb `run` and the aliases `scheduled-prompts` and `scheduled-prompt` are removed (`src/ctl/hub_mode.odin:42` and the second occurrence in the help switch).

**Non-goals.** No client-side cron validation. No interactive mode.

**Acceptance and tests** (the ctl test package; requests are captured, no hub needed)

| Name | Expected |
|---|---|
| `test_ctl_actions_create_body` | `--trigger 'cron:0 9 * * 1-5@America/New_York' --trigger event:chain.state,state=completed --rule '*:claude' --rule brg_1:codex:gpt` produces the body of 6.14 with 2 triggers and 2 rules in order |
| `test_ctl_actions_trigger_specs` | each spec form, plus a malformed one that prints usage and sends nothing |
| `test_ctl_actions_update_partial` | only the given fields are in the PATCH body |
| `test_ctl_actions_enable_disable_runs_delete` | method and path of each |
| `test_ctl_actions_no_run_verb` | `actions run x` prints the usage line, which does not contain `run` as a verb |

**T12 note for v7.** `runs` prints the state as the server returns it, including `routed` and the reasons of 6.8.1, and prints `delivery_expires_at` for a `routed` run. The CLI holds no list of states or reasons of its own. Add to `test_ctl_actions_enable_disable_runs_delete`: a `routed` row with `delivery_expires_at` is printed with both values.

### T13. UI: triggers, placement rules, run history

**Goal.** Make the Actions pages show and edit API v2.
**Requirements.** REQ-ACT-10, REQ-PLACE-6 (rule editor), R3, R4, Q3 (note), Q7.
**Contracts.** 6.14, 6.10.7.
**Depends on.** T3, T9 (the runs view: T10).

**Files**

| File | Change |
|---|---|
| `src/ui/api/endpoints/actions.ts` | Types and calls for 6.14 and 6.10.7; remove `runAction` and the `scheduled-prompts` types |
| `src/ui/components/actions/actionModel.ts`, `actionCatalog.ts`, `scheduleUtils.ts` | The v2 model; a one-line summary per trigger |
| `src/ui/components/actions/ActionListPage.tsx`, `ActionRow.tsx` | One pill per trigger; filters; no Run button (`src/ui/components/actions/ActionListPage.tsx:269`) |
| `src/ui/components/actions/ActionDetail.tsx`, `ActionViewPage.tsx` | Sections Triggers, Target, Runs; no Run button (`src/ui/components/actions/ActionDetail.tsx:92`) |
| `src/ui/components/actions/ActionFormPage.tsx` | Uses the three new editors |
| `src/ui/components/actions/TriggerListEditor.tsx`, `EventTriggerEditor.tsx`, `PlacementRulesEditor.tsx`, `RunHistory.tsx` | New |
| `src/ui/components/actions/ScheduleEditor.tsx` | Becomes the editor of one schedule trigger; adds the DST note |
| `src/ui/components/workbench/AgentChatPane.tsx` | The action card (`src/ui/components/workbench/AgentChatPane.tsx:2137`) reads the metadata of 6.13.1 and shows the event type for event runs; when the metadata has `moved_to_instance_id` it shows "Moved to another machine" with a link to that instance |
| `tests/ui_actions_*.ts` | New |

**Behaviour**

- **List.** Each row shows the name (or the first line of the prompt), the target, the enabled switch and one pill per trigger (for example `0 9 * * 1-5 · New York`, `every 1 h`, `once 2026-12-01 09:00`, `Task chain completed`). Filters: All, Scheduled, Event, No trigger.
- **Form.** Prompt; name; target; triggers; minimum interval (seconds, with the limits from `trigger-types`).
  - Target kind options come from `target_kinds`. `agent` shows the agent picker, the optional project, the instance strategy and the placement rules. `instance` shows the instance picker. `bot` (only when offered) shows the bot picker.
  - **Placement rules editor.** An ordered list. Each row has three selects (machine, provider, model), each with an "Any" option. Options come from `GET /api/v1/placement/candidates?agent_id=`: `bridges` (offline machines are selectable and marked with their reason), `providers` and their `models`. "Any provider" forces "Any model". Rows can be added, removed and moved up or down; the saved order is the shown order. An empty list is shown as "Anywhere (the hub picks the first available machine)". At most `limits.max_rules` rows.
  - **Trigger list editor.** Add Schedule or Add Event; each trigger has its own enabled switch and a remove button. At most `limits.max_triggers`.
  - **Schedule trigger.** Mode cron, interval or once; time zone for cron; blackout dates and active window. When the zone is not UTC it shows: "In this time zone, a time skipped by daylight saving does not run, and a time that occurs twice runs twice." When `schedules_supported` is false, Add Schedule is disabled with the text "Scheduled triggers need nats-server 2.14 or newer."
  - **Event trigger.** Presets and event types come from `trigger_kinds[kind=event].events`. The preset "Task chain completed" fills type `chain.state` and `state = completed`. An optional chain picker sets `chain_id`. Data keys with listed values are selects; others are text fields.
  - The prompt field lists the placeholders of 6.9 under it.
- **Detail.** Triggers (with `next_fire_at` when present), Target (rules in order), Runs. A run row shows the time, the trigger, the state as a badge and: the reason for `skipped` and `failed`; "deferred until <not_before>" for `deferred`; "merged into <short id>" for `joined`; "+N merged" when `joined_count` > 0; a link to the instance when `target_instance_id` is set. "Load more" passes `before`.
- There is no Run button anywhere. Server validation errors are shown next to the field named by the code.

**Non-goals.** No client-side default placement logic. No cron evaluation beyond the existing preview helpers. No change to `ActionsRouteGate` or the experiment checks. No new event types.

**Acceptance and tests**

| Name | Expected |
|---|---|
| `tests/ui_actions_model_test.ts` | the API shape of 6.14 round-trips through the form model; trigger ids are kept on edit; removed triggers are omitted |
| `tests/ui_actions_trigger_summary_test.ts` | the pill text for cron, interval, once, preset event, plain event |
| `tests/ui_actions_rules_editor_test.ts` | reorder saves in order; "Any provider" clears the model; an offline bridge is listed with its reason; empty list text |
| `tests/ui_actions_target_kinds_test.ts` | no bot option when `target_kinds` lacks `bot`; it appears when present |
| `tests/ui_actions_runs_test.ts` | each state's row text, including "deferred until" and "merged into" |
| `tests/ui_actions_no_run_button_test.ts` | no source file under `src/ui/components/actions` contains `runAction` or a control labelled Run |
| `tests/ui_experimental_flags_test.ts` | passes unchanged |

Run the UI tests and the type check with the commands in `AGENTS.md`, and report them.

**T13 changes in v7**

- **Run rows.** States and texts: `queued` "Waiting"; `deferred` "Deferred until <not_before>"; `routed` "Sent to <machine label>, waiting for it" plus "expires <delivery_expires_at>"; `delivered` "Delivered"; `joined` "Merged into <short id>"; `skipped` and `failed` with the reason text below. "+N merged" when `joined_count` > 0.
- **Reason texts.** `bridge_offline` "The machine stayed offline"; `no_answer` "The machine did not answer"; `start_failed` "The agent could not be started on that machine"; `bridge_too_old` "The machine's bridge needs an update"; `no_placement` "No machine matched the rules"; `target_missing` "The target no longer exists"; `delivery_failed` "The prompt could not be stored"; `experiment_off`, `disabled`, `rate_limited`, `stale_rev`, `outside_window`, `blackout` as today's wording. The texts `user_stopped`, `needs_recovery` and `target_busy` MUST NOT appear in `src/ui/components/actions`.
- **Rule editor.** It calls the candidates endpoint with `feature=event_pipeline_v1` (6.10.10). A machine whose reason is `missing_feature` is selectable and marked "needs a bridge update to run actions".
- **Target hint.** Under the target section: "An action also starts an agent that you stopped. Disable the action to stop that."
- Further tests: `tests/ui_actions_runs_test.ts` covers the `routed` row with its expiry and each reason text above; `tests/ui_actions_rules_editor_test.ts` covers the `missing_feature` mark; `tests/ui_actions_moved_card_test.ts` covers the moved card.

### T14. Phase-1 integration, docs, E2E

**Goal.** One releasable phase 1.
**Requirements.** REQ-DEPLOY-1, REQ-SCHED-4, REQ-SCHED-0 (C2), REQ-PIPE-8 (rollout order).
**Depends on.** T1, T2, T3, T8, T9, T16, T17, T10, T12, T13.

**Steps**

1. Merge `origin/main`. Re-run the boundary tests, because new code on main may break them.
2. Remove what phase 1 left only for sequencing, if it is unused by now. Do **not** remove `validate_provider_model_intersection` (T4) or the allow-list entries of the boundary tests that name `taskv2` and `bots`.
3. Docs: `docs/plans/events-jetstream-spec.md` (the stream now has `sched.def.>`, schedules, the consumer `hub_action_matcher`; the second stream `HEIM_DELIVER`, its per-bridge consumers and its advisory stream; that deliveries are commands and are not bound by D6); `SELF_HOSTING.md` (nats-server 2.14 or newer; change the pinned image at `SELF_HOSTING.md:378`; state that the stream upgrade is forward-only and what an older server loses; state that actions need a bridge that reports `event_pipeline_v1`, and that the hub is upgraded before the bridges); the actions section of the user docs if one exists (an action wakes a user-stopped agent; disabling the action is the off switch); the `ham-ctl-reference` skill text for `hub actions`.
4. Run the full Odin test suite, the UI tests and the flake checks. Report counts per package.
5. Add `test_old_bridge_heartbeat_ok` (`src/hub/transport/http`): a heartbeat from a bridge build that still expects `schedules_version` gets a valid ack without it. **Assumption to verify:** a bridge built before T8 treats a missing `schedules_version` as "nothing to sync" and neither crashes nor loops. Verify by reading the bridge code at the base commit and by running the pre-T8 bridge binary against the new hub once on Mundus. If it misbehaves, stop and report.
6. Add `test_old_bridge_is_not_a_candidate` (`src/hub/transport/http` or `service/actions`): with one bridge whose hello lacks `event_pipeline_v1`, `GET /api/v1/placement/candidates?feature=event_pipeline_v1` lists it under `bridges` with `eligible = false` and reason `missing_feature` (6.10.10), and an action pinned to it ends `failed`, `bridge_too_old`.
7. Deploy to Mundus through a change request to `inst_18e8ba2e9e2c4e69`. The request MUST say: forward-only (condition C2); needs nats-server 2.14 or newer; existing actions are discarded (R1); **hub first, then bridges**; until a bridge is updated it cannot run actions.
8. Run the E2E list on Mundus and record each result in a task comment.
9. Brolabs is deployed only after the user says so explicitly.

**E2E list (Mundus, experiment on for the test user)**

| # | Scenario | Pass when |
|---|---|---|
| E1 | Cron action, two rules, the machine of rule 1 offline | the run is `delivered` with `rule_position` 1 and the prompt appears in the agent's conversation as an action card |
| E2 | Event trigger with the preset "Task chain completed" and a prompt using `{{event.chain_id}}` | completing a chain delivers the prompt with the chain id filled in |
| E3 | One action with a `chain.state` trigger and a `chain.work_finished` trigger that both match one completion | one prompt; one `delivered` and one `joined` or `deferred` run |
| E4 | A second matching event 5 s after a delivery | a `deferred` run that is routed once, about 30 s after the first, with no other activity on the hub |
| E5 | Target instance **stopped by the user** | it starts; the prompt is in its conversation; the run is `delivered` with outcome `started`; `stopped_by` is empty afterwards |
| E6 | Target instance stopped (not by the user) | it starts and the prompt is in its conversation |
| E7 | Target agent idle | the message notice is typed; the run is `delivered` with outcome `notified` |
| E8 | A normal task chain with a worker and a reviewer | leases launch and nudge as before (the pipeline is not used for leases in phase 1) |
| E9 | Experiment switched off | the routes are refused; a fire is recorded as `skipped`, `experiment_off` |
| E10 | A once trigger 2 minutes ahead | fires once; the trigger shows disabled afterwards |
| E11 | Hub restart with a schedule trigger present | the schedule keeps firing; the definition's stream sequence is unchanged (no republish) |
| E12 | `ham-bridge vault prune` with the owner's `actions` experiment off | reports the token as alive |
| E13 | An action whose target agent is in the middle of a long turn | the run stays `routed` while the agent works; the turn is not interrupted (no ESC in its terminal); the notice is typed after the turn; the run ends `delivered`. Later fires in between are `joined` |
| E14 | An action with rules for two machines; the first machine's bridge is stopped right after the run is routed and before it fetches the delivery (pause the bridge process, then kill it) | the prompt lands on the second machine; the first conversation shows the prompt as read and moved; one run, `delivered` |
| E15 | An action pinned to one machine that is offline for 10 minutes | the run is `routed` during the 10 minutes; on reconnect the prompt is delivered; the run is `delivered` |
| E16 | The same, offline for more than 1 hour | the run is `failed`, `bridge_offline` |
| E17 | The bridge is restarted while a delivery is in flight (kill it right after the notice was typed) | the agent's terminal shows one notice line, not two; the run is `delivered` |
| E18 | A bridge that does not report `event_pipeline_v1` (a pre-T17 build) and a new one, rule "any machine" | the new one is chosen; an action pinned to the old one ends `failed`, `bridge_too_old`, and the rule editor marks that machine |
| E19 | Hub restart while a run is `routed` | the delivery is forwarded again and answered from the bridge ledger; no second prompt message |

**Non-goals.** No phase-2 or phase-3 work. No Brolabs deploy without the user's explicit OK.

**Acceptance.** Steps 1 to 8 done with evidence in task comments; every E2E row passes or is reported with its failure.

### T18. `[events]` notices on the pipeline (phase 2)

**Goal.** An `[events]` notice is a chat message, routed as `kind = notice`. It reaches stopped agents, user-stopped ones included, and waits for a busy agent.
**Requirements.** REQ-FLOW-1, REQ-FLOW-4.
**Contracts.** 6.11.2, 6.11.3, 6.11.6 (the `events` notice line).
**Depends on.** T16, T17, and the event-inbox fix `task_18ea483f167575d2` merged to `origin/main` (section 7). **Before starting, re-read `src/hub/service/eventinbox` on `origin/main`:** the line numbers and the shape of `Event_Notice_Target` below are those of `f56f13e1`, before that fix.

**What exists** (at `f56f13e1`). `notify_pending` (`src/hub/service/eventinbox/notifications.odin:166`) decides when a subscriber is due a notice (30 s cooldown, 5 s back-off after a rejection) and calls the callback `Service.notice` (`src/hub/service/eventinbox/service.odin:17`), which wiring sets to `event_inbox_notice` (`src/hub/app/wiring.odin:1357`). The callback either starts a stopped instance through `start_instance` with `event_inbox_wake_guard` (`src/hub/app/wiring.odin:1406`), or sends a `notify_task_nudge` frame with the `[events]` line (`src/hub/app/wiring.odin:1389`).

**Files**

| File | Change |
|---|---|
| `src/hub/service/eventinbox/notifications.odin` | Remove the two `stopped_by` conditions (`src/hub/service/eventinbox/notifications.odin:186`, `src/hub/service/eventinbox/notifications.odin:282`); widen the "may be notified" condition as below |
| `src/hub/service/eventinbox/service.odin` | `Service` gains `pipeline: proc(ctx: rawptr, bridge_id: string) -> bool` (is this bridge on the pipeline?), using the existing `notice_ctx` |
| `src/hub/domain/event_subscription.odin`, `src/hub/repository/sqlite/event_subscription_repo.odin` | Remove the field `stopped_by` from `Event_Notice_Target` and the column from the query (`src/hub/repository/sqlite/event_subscription_repo.odin:362`) |
| `src/hub/app/wiring.odin` | `event_inbox_notice`: the pipeline branch; remove both `stopped_by` reads (`src/hub/app/wiring.odin:1367`, `src/hub/app/wiring.odin:1412`); the `pipeline` callback; register the `notice` sink |
| `src/contracts/delivery_wire.odin` | `EVENTS_NOTICE_FORMAT :: "[events] %d new event(s) — run ham-ctl events next"`; `wiring.odin` uses it in the old branch |
| `src/ui/components/workbench/AgentChatPane.tsx` | A compact renderer for `messageType === 'event_notice'` |
| Tests next to each | New and changed |

**Behaviour**

1. **Who may be notified** (in `notify_pending`, both in the pre-scan and in the final decision). Today: the target is idle, or stopped and the event is wake-worthy, and `stopped_by` is empty. New: let `p = s.pipeline(s.notice_ctx, target.bridge_id)`.
   - `p` false (old bridge): today's condition without the `stopped_by` term.
   - `p` true: the target instance exists and (its `runtime_status` is `running` or `idle`, **with any activity**, or it is `stopped` and the event is wake-worthy).
   The cooldown and back-off code is not touched.
2. **The callback** `event_inbox_notice`, when the target's bridge is on the pipeline (`delivery.bridge_capable` of the bridge row):
   1. Re-read the instance; wrong owner or agent → false (as today, without the `stopped_by` term).
   2. Begin a unit of work. If an open delivery exists with `ref = "sub:<agent_instance_id>"` (`open_by_ref`) → commit, return true: the pending notice covers the new events, and the cooldown starts.
   3. Store the notice as a chat message with `content.persist_user_message`: `message_type = "event_notice"`, body `fmt.tprintf(contracts.EVENTS_NOTICE_FORMAT, count)`, `metadata_json = {"count":<count>}`. It is a `user_to_agent` message, so a freshly started agent is told about it by the start-success step (V5).
   4. `delivery.route(uow, {kind = "notice", owner, bridge_id, agent_instance_id, cause = "event", ref = "sub:<agent_instance_id>", conversation_id, message_id, notice_line = "events", notice_count = count, lifetime = delivery.LIFETIME_NOTICE})`.
   5. Commit; return true. Any error → roll back; return false (the 5 s back-off applies).
   The `wake` argument is not used on this branch: the bridge decides whether to start.
3. **The callback on an old bridge:** today's two branches, with the `stopped_by` reads removed. `event_inbox_wake_guard` keeps its owner, agent and `runtime_status == "stopped"` checks. `start_instance` clears a user stop by itself (`src/hub/service/agent/agent_service.odin:912`).
4. **The sink** for kind `notice`: `on_final` does nothing for `done`; for `failed` it does nothing either (the inbox sends a fresh notice after the cooldown while events are still unacked). `still_valid` and `replace` are nil.
5. **UI.** `event_notice` renders as one muted centred line, like the "agent started" divider (`src/ui/components/workbench/AgentChatPane.tsx:2089`): the body text, no author label, no bubble. Add the branch to `renderConversationMessageBody` (`src/ui/components/workbench/AgentChatPane.tsx:1988`) before the `system` branch.

**Non-goals.** No change to how the notice target is chosen, to subscriptions, to cooldown or back-off values, or to the event catalog. No removal of the old branch. No notice for bots through this path (a bot target keeps what the inbox does for it today until T19).

**Acceptance**

- `grep -rn "stopped_by" src/hub/service/eventinbox src/hub/repository/sqlite/event_subscription_repo.odin` prints nothing; `grep -n "stopped_by" src/hub/app/wiring.odin` prints nothing inside `event_inbox_notice` and `event_inbox_wake_guard`.
- The existing cooldown and back-off tests of `src/hub/service/eventinbox` pass unchanged.
- The scan set of `test_pipeline_never_reads_stopped_by` includes `src/hub/service/eventinbox`.

**Tests**

| Name | Expected |
|---|---|
| `test_notice_stopped_agent_is_routed` (`app` or `eventinbox`, with the real `delivery` package and a fake bridge) | a stopped target on a capable bridge: one `event_notice` message, one `notice` delivery; the callback returned true |
| `test_notice_user_stopped_agent_is_routed` | the same with `stopped_by = "user"` on the row |
| `test_notice_idle_agent_is_routed` | the same for an idle target; the frame has `notice.line = "events"` and the count |
| `test_notice_busy_agent_is_routed_and_waits` | a `running` target with activity `active` is notified (it was skipped before); the delivery stays open across a `retry` answer and closes on `succeeded` |
| `test_notice_joins_open_delivery` | a second due notice while the first delivery is open: no second message, no second delivery, returns true |
| `test_notice_old_bridge_uses_old_path` | a bridge without the feature: idle → a `notify_task_nudge` frame with the `[events]` line; stopped → `start_instance`; no delivery row |
| `test_notice_old_bridge_user_stopped_is_started` | on the old path a user-stopped target is started too |
| `test_notice_cooldown_unchanged` | the existing 30 s and 5 s tests, unchanged |
| `test_notice_lifetime_five_minutes` | the delivery's `expires_at` is now + 5 min |
| `tests/ui_event_notice_test.ts` | an `event_notice` message renders the compact line and no author label |

### T19. Bots and the `bot` action target on the pipeline (phase 3)

**Goal.** The `bot_deliver` frame travels through the pipeline for capable bridges, and an action can target a bot.
**Requirements.** REQ-FLOW-2, REQ-FLOW-4, REQ-ACT-8 (bot part).
**Contracts.** 6.11.2 (`payload`), 6.11.3, 6.11.6 (kind `bot`).
**Depends on.** T10, T16, T17, T24.
**Amendment S2.** T24 runs first: the bot launch on the bridge already calls start-begin (`ref = bot_<attempt_id>`), and the hub already creates a bot's instance stopped. T19 changes the transport of the frame and nothing about how the process starts.

**What exists.** The bot supervisor creates one open delivery per bot, picks a bridge, and sends `bot_deliver` with `command_id = "cmd_bot_<attempt_id>"` (`bots_send_attempt_locked`, `src/hub/service/bots/delivery.odin:108`). The bridge starts a worker thread per attempt, is idempotent per `attempt_id` (`src/bridge/bot_delivery.odin:113`), and reports through `bot_delivery_report` frames. On reconnect the hub resends open attempts (`src/hub/service/bots/delivery.odin:177`). The `command_result` moves the attempt to Accepted or Exhausted (`bots_on_command_result`, `src/hub/service/bots/delivery.odin:56`).

**Files**

| File | Change |
|---|---|
| `src/hub/service/bots/delivery.odin` | `bots_send_attempt_locked`: the pipeline branch; `bots_on_bridge_hello`: no resend for a capable bridge; the `bot` sink |
| `src/hub/service/bots/inbound.odin`, `supervisor.odin` | Pending prompts open or extend a delivery like inbound messages do |
| `src/hub/service/bots/prompts.odin` | New: `bots_prompt_enqueue`, the pending-prompt rows |
| `src/hub/repository/sqlite/migrations/bots_pipeline_001.sql` and the bots repository | Table `bot_pending_prompts`; columns `cause`, `ref` on the delivery table (additive, defaults `'user'`, `''`) |
| `src/contracts/bot_wire.odin` | `Bot_Deliver_Wire` gains `cause`, `ref`, `prompt_text`, all `omitempty` |
| `src/bridge/bot_delivery.odin` | Type `prompt_text` when present; report `acted` after typing for a non-user cause |
| `src/bridge/event_executor.odin` | Kind `bot` |
| `src/hub/service/actions/router.odin`, `service.odin`; `src/hub/app/wiring.odin` | `Bot_Port`; target kind `bot`; `target_kinds` gains `"bot"` |

**Schema**

```sql
-- bots_pipeline_001.sql (registered last)
CREATE TABLE bot_pending_prompts (
  prompt_id TEXT PRIMARY KEY CHECK(prompt_id != ''),
  bot_id TEXT NOT NULL,
  owner_user_id TEXT NOT NULL,
  cause TEXT NOT NULL,                 -- schedule | event
  ref TEXT NOT NULL UNIQUE,            -- run:<run_id>
  prompt_text TEXT NOT NULL,
  delivery_id TEXT NOT NULL DEFAULT '',-- the bot delivery that carries it; '' = waiting
  state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','carried','done','failed')),
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE INDEX bot_pending_prompts_bot ON bot_pending_prompts(bot_id) WHERE state IN ('pending','carried');
```

The two additive columns on the bots delivery table are added with `ALTER TABLE … ADD COLUMN`; T19 reads the table's name from the bots migrations.

**Behaviour**

1. **Transport switch.** In `bots_send_attempt_locked`, when `delivery.bridge_capable(bridge)`: instead of `bridge_command_send_runtime`, call `delivery.route(uow, {kind = "bot", owner, bridge_id = a.bridge_id, agent_instance_id, cause = "bot", ref = "bot:<attempt_id>", payload = <the Bot_Deliver_Wire JSON it builds today>, lifetime = delivery.LIFETIME_FLOW})` in the unit of work that moves the attempt to Sent. A resend (`resend = true`) is a no-op on this branch. Otherwise: today's code, unchanged.
2. **Sink for kind `bot`.** `still_valid`: the attempt named by the ref is in an open state (Relocating, Sent, Accepted). `on_final`: `done` → the same transition `bots_on_command_result` makes for `succeeded`; `failed` → the one it makes for `failed`. `replace`: nil; the supervisor moves a bot between bridges by its own rounds.
3. **Reconnect.** `bots_on_bridge_hello` skips the resend loop for a capable bridge: the pipeline redelivers. The disconnect grace, the accept deadline and every other supervisor timer are unchanged.
4. **Bridge, kind `bot`.** The executor checks the ledger (row 1), writes `In_Progress`/`Flow`, calls `bridge_bot_handle_deliver(delivery.payload)` (`src/bridge/bot_delivery.odin:102`), writes `Done`, and answers `succeeded` with outcome `accepted` when that handler returned a succeeded result, or `failed`/`fatal` with reason `invalid_frame` when it returned a validation failure. `bridge_bot_handle_deliver` is already idempotent per attempt. Reports keep using `bot_delivery_report`.
5. **Bot action target.** The router's target kind `bot` (6.13.3):

```odin
// src/hub/service/actions — filled at wiring with bots.bots_prompt_enqueue
Bot_Port :: struct {
	ctx: rawptr,
	// Stores the prompt for the bot inside uow. Rows only. Not_Found when the bot is gone.
	enqueue: proc(ctx: rawptr, uow: ^iface.Unit_Of_Work, owner, bot_id, cause, ref, prompt_text: string) -> domain.Domain_Error,
}
// src/hub/service/bots/prompts.odin
bots_prompt_enqueue :: proc(s: ^Bots_Service, uow: ^iface.Unit_Of_Work, owner, bot_id, cause, ref, prompt_text: string) -> domain.Domain_Error
// Set at wiring: called inside the bots unit of work when a pending prompt is finished.
Prompt_Done :: proc(ctx: rawptr, uow: ^iface.Unit_Of_Work, ref: string, ok: bool, reason: string)
```

   - In the route transaction the router renders the prompt, calls `Bot_Port.enqueue` and claims the run as `routed` with `delivery_id = ""` and `target_instance_id` = the bot's instance, if it has one. It does not call `delivery.route` and stores no chat message: the bot path owns the delivery.
   - After the commit the router calls the existing bot entry point that reacts to new inbound work (`delivery_on_inbound`, `src/hub/service/bots/inbound.odin:88`) through the port's wiring adapter.
   - `bots_delivery_on_inbound_locked` (`src/hub/service/bots/inbound.odin:101`) treats a `pending` prompt like a fresh inbound message: with no open delivery it opens one; with an open delivery in Waiting it extends it; with a delivery already dispatched the prompt stays `pending` and is picked up by the re-run that follows an Acted attempt. Nothing is skipped (U3).
   - A frame carries **one** prompt: the oldest `pending` one becomes `carried` with that delivery, and its text, cause and ref go into the frame. A frame built for inbound channel messages carries none.
   - The bridge, for a frame with `prompt_text`: types `prompt_text` in place of `BOT_NOTICE` (`src/bridge/bot_delivery.odin:349`), and reports `acted` as soon as the typing succeeded; it does not watch for a channel read and reply, because an action prompt has no channel message to read.
   - When the attempt ends Acted, the carried prompt becomes `done` and `Prompt_Done(ref, true, "")` closes the run as `delivered`. When the delivery is abandoned, it becomes `failed` and the run is `failed`, `delivery_failed`.
   - A bridge that is not capable never carries a prompt: `bots_select_bridge` adds `event_pipeline_v1` to the required features when the delivery's next frame would carry one.
   - `actions.expire_open_run` closes a bot-target run that has been `routed` for more than 1 hour as `failed`, `bridge_offline`, and marks its prompt `failed`.

**Non-goals.** No change to bot rounds, relocation, reports or timers. No removal of the direct `bot_deliver` send. No change to channel handling.

**Acceptance and tests**

| Name | Expected |
|---|---|
| The existing tests of `src/hub/service/bots` and `src/bridge` bot delivery | pass on both transports: run the delivery tests once with a capable and once with an incapable bridge |
| `test_bot_attempt_routed_through_pipeline` | a capable bridge: no direct frame; one `bot` delivery whose `payload` parses as `Bot_Deliver_Wire` with the same field values as the direct frame |
| `test_bot_sink_done_and_failed` | `done` → attempt Accepted; `failed` → Exhausted |
| `test_bot_sink_still_valid` | a cancelled attempt's delivery is closed `superseded` at the gate |
| `test_bot_hello_does_not_resend_on_pipeline` | capable bridge: no resend; incapable: resend as today |
| `test_bridge_bot_kind_is_idempotent` | the same delivery twice: one worker thread |
| `test_action_bot_target_types_prompt` | an action with a bot target: the frame carries `prompt_text`; the bridge types it; the run ends `delivered` |
| `test_action_bot_target_joins_open_delivery` | the bot has a dispatched delivery: the prompt stays `pending`, the run stays `routed`; after that attempt is Acted a new delivery carries the prompt |
| `test_action_bot_target_needs_bots_experiment` | `skipped`, `experiment_off` |
| `test_bot_wire_fields_are_additive` | a frame without a prompt has the same bytes as on `origin/main` |
| `test_trigger_types_lists_bot` (`transport/http`) | `target_kinds` contains `bot` |

### T20. Task lease wakes on the pipeline (phase 3)

**Goal.** A lease wake is appended in the grant transaction and delivered by the pipeline, for capable bridges.
**Requirements.** REQ-FLOW-3, REQ-FLOW-4.
**Contracts.** 6.11.2 (`payload`), 6.11.3, 6.11.6 (kind `lease`), 6.12.6.
**Depends on.** T16, T17, T23, T25.
**Amendment S2.** T25 and T23 run first: the grant opens the generation through `start_begin`, and the direct path sends `start_agent`. T20 carries that same one-entry `start_agent` text through the pipeline. `capable(bridge_id)` is true only for a bridge that reports **both** `event_pipeline_v1` and `start_agent_v1`; every other bridge keeps the direct path (`start_agent`, or `wake_agent` for a bridge without that feature). The "What exists" paragraph below describes `origin/main`; read it together with T25.

**What exists.** `grant_attempt_in_uow` (`src/hub/service/taskv2/lease.odin:77`) writes the lease and the instance row (`launching`, `run_count + 1`) and calls `effect_wake_lease` (`src/hub/service/taskv2/wake.odin:27`), which keeps the wake in memory. After the commit `flush_wakes` (`src/hub/service/taskv2/wake.odin:146`) sends one `wake_agent` command per bridge and chain; a failed send parks the task (`on_dispatch_failed`, `src/hub/service/taskv2/dispatch.odin:178`). Unconfirmed wakes are sent again on bridge hello (`src/hub/service/taskv2/lease.odin:680`), at hub start (`src/hub/service/taskv2/lease.odin:888`) and by the grant-unconfirmed timer (`fire_grant_unconfirmed`, `src/hub/service/taskv2/timers.odin:404`).

**Files**

| File | Change |
|---|---|
| `src/hub/service/taskv2/wake.odin` | `effect_wake_lease`: the pipeline branch |
| `src/hub/service/taskv2/lease.odin` | `on_bridge_hello` and `boot`: no re-queue for a capable bridge |
| `src/hub/service/taskv2/timers.odin` | `fire_grant_unconfirmed`: no resend for a capable bridge |
| `src/hub/service/taskv2/pipeline.odin` | New: the `lease` sink |
| `src/hub/service/taskv2/service.odin`, `src/hub/app/wiring.odin` | `Service` gains a `Delivery_Port` (`route`, `capable`); the sink is registered |
| `src/bridge/start_agent.odin` | Nothing new: the executor calls `bridge_start_agent_apply` (T23) |
| `src/bridge/event_executor.odin` | Kind `lease` |

Package `taskv2` does not import `delivery`. It reaches the pipeline through a port that wiring fills with `delivery.bridge_capable` and `delivery.route`:

```odin
// src/hub/service/taskv2/service.odin
Delivery_Port :: struct {
	ctx: rawptr,
	capable: proc(ctx: rawptr, bridge_id: string) -> bool,
	// The fields of delivery.Route_Input that a lease needs. Rows only; inside uow.
	route:   proc(ctx: rawptr, uow: ^iface.Unit_Of_Work, owner, bridge_id, instance_id, lease_id, payload: string) -> domain.Domain_Error,
}
```

**Behaviour**

1. **Grant.** In `effect_wake_lease`, when `capable(bridge_id)`: build the ticket's run entry as T25 does and the command text `agent.start_command_json(command_id, chain_id, {entry}, nil)` with `command_id = "cmd_lease_" + lease_id`; call `route` with that text as `payload`, `ref = "lease:<lease_id>"`, `cause = "lease"`, `lifetime = LIFETIME_FLOW`, in the grant's unit of work. Nothing is added to the in-memory wake effects for this lease. The instance stop list (`stop`) keeps using the direct command, with an empty run list.
   - If an open delivery already exists for this ref (`open_by_ref`), do nothing: the pipeline is still delivering it.
   - The unit of work type of `taskv2` (`Uow`) wraps an `iface.Unit_Of_Work`; pass that inner value.
2. **Sink for kind `lease`.** `still_valid`: the lease exists, is held by the delivery's instance, is not in phase `waiting` and has no `confirmed_at`. `on_final`: `done` → nothing (confirmation still comes from start-success or the first lease verb); `failed` → `dispatch_failed_in_uow` for that lease with the reason as detail, the same call `on_dispatch_failed` makes. `replace`: nil; the task engine re-grants by its own rules.
3. **No second sender.** For a capable bridge: `on_bridge_hello` and `boot` do not call `effect_wake_lease` for unconfirmed leases; `fire_grant_unconfirmed` does not resend on its first fire (it still re-arms, and its second fire still fails the dispatch). The nudge to confirmed live holders and the orphan stop in `on_bridge_hello` are unchanged.
4. **Bridge, kind `lease`.** The executor applies the payload with `bridge_start_agent_apply(nil, payload, deadline)` (T23, 6.12.6): the same procedure that handles a direct `start_agent` frame, without the final `command_result`; `ok` is false when a launch of an entry failed. The executor, for kind `lease`:
   1. Ledger `Done` → `succeeded`, the stored outcome.
   2. Ledger `In_Progress` (restart): read `agent_instance_id` and `run_count` of the entry's launch object in `payload`; if a live child of exactly that generation exists (`bridge_startup_confirm_spawned`, `src/bridge/startup_readiness.odin:377`) → `Done`, `succeeded`, `started`. Otherwise continue.
   3. `begin(Flow)`; `bridge_start_agent_apply(nil, payload, deadline)`.
   4. `ok` → `Done`; `succeeded` with outcome `started`. Not ok → forget the entry; `err.class == .retriable` and not final → `failed`, `retry` with `err.retry_after_ms`; otherwise `failed`, `fatal`, reason `launch_failed`.
   There is no start-begin **request** for a lease: the grant already opened the generation on the hub through `start_begin` (T25), and the entry's launch object carries `run_count`.
5. **Bytes.** The text in `payload` is byte-identical to the `start_agent` command the direct path sends for a single run entry, apart from the command id.

**Non-goals.** No change to which instance is leased (v7-Q4), to grant, confirmation, nudge or `run_count` logic, to the `wake_agent` frame, or to the old path. No second start-begin for leases: T25's call in the grant is the only one.

**Acceptance and tests**

| Name | Expected |
|---|---|
| The existing lease, nudge, redelivery and confirmation tests of `src/hub/service/taskv2` | pass on both transports: once with a capable and once with an incapable bridge |
| `test_grant_appends_lease_delivery` | a grant to a capable bridge: one `lease` delivery and one outbox row in the grant's transaction; a rolled-back grant leaves neither; no `wake_agent` command is sent directly |
| `test_lease_payload_bytes_unchanged` | `payload` equals the `start_agent` text the direct path sends for one entry, apart from the command id |
| `test_lease_delivered_after_reconnect_without_hello_resend` | the bridge drops before the forward; on reconnect the pipeline forwards the delivery; `on_bridge_hello` queued no wake |
| `test_lease_sink_failed_parks_task` | a `failed` delivery → the task is parked exactly as a failed send parks it today |
| `test_lease_sink_still_valid` | a confirmed, released or re-granted lease's delivery is closed `superseded` at the gate |
| `test_grant_unconfirmed_timer_on_pipeline` | first fire: no resend; second fire: dispatch failed |
| `test_bridge_lease_kind_nudges_live_child` | `deliver = "nudge"` and a live child: the line is typed once; a redelivered frame types nothing |
| `test_bridge_lease_kind_launch_once` | a launch entry delivered twice: one launch |
| `test_bridge_lease_restart_in_progress` | a persisted `In_Progress` entry with a live child of that generation → `succeeded`; without one → the entry is applied again |
| `test_lease_pipeline_needs_both_features` | a bridge with `event_pipeline_v1` but without `start_agent_v1`: no `lease` delivery; the direct `wake_agent` path is used |

### T4. Placement adoption: task leases, taskchain, MCP, UI defaults (phase 3)

**Goal.** Every remaining consumer takes eligibility and defaults from the placement module.
**Requirements.** REQ-PLACE-2 (complete), REQ-PLACE-3, REQ-PLACE-5 (the two T4 rows of 6.10.4), REQ-PLACE-6 (UI start flows).
**Contracts.** 6.10; the rows of 6.10.9 marked T4.
**Depends on.** T3. Starts after T14.

**Files**

| File | Change |
|---|---|
| `src/hub/service/taskv2/placement.odin`, `placement_failures.odin`, `matcher.odin`, `lease.odin`, `placement_recovery.odin`, `dispatch.odin`, `recheck.odin` | Per 6.10.9 and the call-site table below |
| `src/hub/service/taskv2/dispatch_test.odin` | Its call of `agent.validate_provider_model_intersection` (`src/hub/service/taskv2/dispatch_test.odin:143`) becomes `placement.launchable` |
| `src/hub/service/taskchain/taskchain_service.odin` | Delete `fleet_model_on_bridge` and `resolve_fleet_launch_model`; its two internal callers use the taskv2 procedures |
| `src/hub/transport/http/taskchain_handlers.odin` | The fleet-change path (`src/hub/transport/http/taskchain_handlers.odin:2340`) calls the taskv2 procedures |
| `src/hub/service/mcp/catalog_read.odin`, `src/hub/app/mcp_task_mutations.odin`, `src/hub/app/mcp_runtime.odin`, `src/hub/app/mcp_chain_create.odin` | Flags and checks from `bridge_eligible` and `launchable` |
| `src/hub/service/agent/agent_service.odin` | Delete the wrapper `validate_provider_model_intersection` |
| `src/ui/components/chat/NewConversationPage.tsx`, `src/ui/components/tasks/fleetSelection.ts`, `src/ui/utils/bridgeLaunchOptions.ts` | Preselect the first entry of the candidates endpoint; delete the local default logic |
| `src/hub/service/placement/boundary_test.odin` | Extend the scan to the whole of `src/hub` |

**Steps**

1. `taskv2` receives a `^placement.Service` at wiring.
2. `placement_problem` (`src/hub/service/taskv2/placement_failures.odin:32`): keep the task-specific reasons; replace its bridge and provider checks with the predicate; map reasons to the existing codes (`not_owner`, `revoked`, `enrollment_pending`, `plan_disabled`, `missing_feature` → `bridge_ineligible`; `offline`, `no_live_connection` → `bridge_offline`; a `launchable` error → `provider_ineligible`). Keep the predicate's reason in the failure detail.
3. Move the body of `bridge_online` (`src/hub/service/taskv2/lease.odin:1104`) to `placement.bridge_status_online` and delete it from `taskv2`. Each of its 11 callers changes as follows. Only the first one changes behaviour.

   | Call site | What it does | After |
   |---|---|---|
   | `grant_attempt_in_uow` (`src/hub/service/taskv2/lease.odin:119`) | refuses a grant when the placement bridge is offline | **`placement.bridge_eligible`** + `eligibility_error`. This is a launch decision, and the one intended change (`test_lease_requires_live_connection`) |
   | `src/hub/service/taskv2/lease.odin:507` | keeps the claim of an `unreachable` instance while its bridge is away | `bridge_status_online`. Not a launch |
   | wake redelivery at start (`src/hub/service/taskv2/lease.odin:888`) | skips redelivery to a bridge that is away | `bridge_status_online`. Right after a hub start no bridge has reconnected yet, so the registry is empty; the full predicate would skip every redelivery |
   | `src/hub/service/taskv2/dispatch.odin:45` | labels a lost holder with cause `bridge_offline` | `bridge_status_online`. A diagnosis |
   | `stop_holder` (`src/hub/service/taskv2/dispatch.odin:76`) | sends a stop only to a bridge that is there | `bridge_status_online`. A stop must not depend on the plan or on feature flags |
   | `src/hub/service/taskv2/recheck.odin:109` | clears a `bridge_offline` block when the bridge is back | `bridge_status_online`. The grant that follows applies the full predicate |
   | `recheck_merge_in_uow` (`src/hub/service/taskv2/recheck.odin:206`) | re-queues a merge only when the bridge is there | `bridge_status_online`. Not a launch |
   | `recheck_merge_reasons` (`src/hub/service/taskv2/recheck.odin:304`) | explains a pending merge | `bridge_status_online`. Text only |
   | `src/hub/service/taskv2/matcher.odin:199` | solo coordinator: queue when its bridge is away | `bridge_status_online`. No launch happens on this branch |
   | `src/hub/service/taskv2/matcher.odin:679`, `src/hub/service/taskv2/matcher.odin:718` | reasons shown for an unplaced task | `bridge_status_online`. Text only; the placement failure carries the precise reason |

   `taskv2` reaches the bridge repository through the fields it already has. Do not keep a `bridge_online` wrapper in `taskv2`.
4. `resolve_launch_model` → `placement.select` with one rule. `resolve_placement` builds its fallback list as rules and calls `placement.select`.
5. Taskchain and MCP per 6.10.9. `fleet_model_on_bridge` and `resolve_fleet_launch_model` are deleted from `taskchain`; every caller uses `taskv2.fleet_model_on_bridge` (`src/hub/service/taskv2/placement.odin:12`) and `taskv2.resolve_launch_model` (`src/hub/service/taskv2/placement.odin:26`, which step 4 redirects to `placement.select`):

   | Caller | Change |
   |---|---|
   | `src/hub/service/taskchain/taskchain_service.odin:2230`, `src/hub/service/taskchain/taskchain_service.odin:2237` | call the taskv2 procedures with `service.agent_service` |
   | the fleet-change path, `src/hub/transport/http/taskchain_handlers.odin:2340` and the line after it | the same two calls, with the agent service the handler already holds |
   | `mcp_task_target`, `src/hub/app/mcp_task_mutations.odin:56` | `taskv2.fleet_model_on_bridge` |

   Then delete the wrapper `validate_provider_model_intersection` and switch its one remaining caller, the test at `src/hub/service/taskv2/dispatch_test.odin:143`.
6. UI: the three files call the endpoint and preselect `candidates[0]`.
7. Extend `test_agent_and_bots_use_the_predicate` into `test_one_eligibility_predicate`: no non-test file under `src/hub`, outside `src/hub/service/placement`, calls `bridge_runtime_registry_has_live(` or reads `.plan_disabled_at` to decide a launch. The allow-list holds the files that only display or persist those values; each entry carries a one-line reason.

**Non-goals.** No change to `pick_instance`. No change to how leases start instances (T20 changes only the transport of the wake). No new selector.

**Acceptance and tests**

- The existing tests of `src/hub/service/taskv2`, `src/hub/service/taskchain`, `src/hub/service/mcp` and `src/hub/app` pass.
- The hand-off lists the two behaviour changes below.

| Name (package) | Expected |
|---|---|
| `test_lease_requires_live_connection` (`taskv2`) | a bridge whose row is `Online` but which has no live connection gets no lease; the placement failure says `bridge_offline` with detail `no_live_connection` |
| `test_mcp_task_target_requires_live_connection` (`app`) | the same for the MCP target check |
| `test_resolve_placement_same_bridge` (`taskv2`) | for the pin, fleet row, chain directory and coordinator cases the chosen bridge equals the one chosen before this task (expected values taken from the existing tests) |
| `test_resolve_launch_model_matches_module_order` (`taskv2`) | the default provider and model equal `placement.match`'s first candidate on that bridge |
| `test_placement_problem_reason_mapping` (`taskv2`) | each predicate reason maps to its code |
| `test_redelivery_uses_bridge_status_only` (`taskv2`) | at start, with the bridge row `Online` and an empty registry, an unconfirmed wake lease is redelivered, as before this task |
| `test_stop_holder_uses_bridge_status_only` (`taskv2`) | a dispatch failure on a bridge whose row is `Online` but whose plan is disabled still stops the holder |
| `test_bridge_status_online` (`placement`) | true only for a row with status `Online`; an unknown or empty id is false |
| `test_no_bridge_online_left` (`placement/boundary_test.odin`) | no non-test file under `src/hub/service/taskv2` or `src/hub/service/taskchain` defines `bridge_online`, `fleet_model_on_bridge` (except `taskv2/placement.odin`) or `resolve_fleet_launch_model` |
| `test_one_eligibility_predicate` (`placement/boundary_test.odin`) | the scan finds nothing outside the allow-list |
| `tests/ui_placement_defaults_test.ts` | the new-conversation and fleet pickers preselect the first server candidate; with no candidates they show the empty state |

### T21. Phase-3 integration and E2E

**Goal.** One releasable phase 3.
**Requirements.** REQ-DEPLOY-1.
**Depends on.** T4, T19, T20.

**Steps**

1. Merge `origin/main`; re-run the boundary tests and the full suites; report counts per package.
2. Docs: the bots and task-engine sections that describe delivery; `docs/plans/events-jetstream-spec.md` (kinds `bot` and `lease`).
3. (Changed by amendment S2.) Finding F14 is closed by T22 and T25, and T26 records it. Nothing is filed here.
4. Deploy to Mundus through a change request (hub first, then bridges). Run the E2E list. Brolabs only after the user's explicit OK.

**E2E list (Mundus)**

| # | Scenario | Pass when |
|---|---|---|
| P1 | A task chain with a worker and a reviewer, on an updated bridge | leases launch, nudge and confirm as before; the hub's log shows `lease` deliveries and no direct `wake_agent` run entries |
| P2 | The same on a bridge that was not updated | works through the old path |
| P3 | The bridge is stopped right after a grant and restarted 2 minutes later | the worker starts after the reconnect without a second grant |
| P4 | A web channel message to a bot on an updated bridge | the bot answers; one `bot` delivery |
| P5 | An action with a bot target | the prompt text is typed into the bot's session; the run ends `delivered` |
| P6 | An action for a bot that is busy with a channel message | the prompt arrives after that delivery finished; nothing is skipped |
| P7 | The UI start flows after T4 | defaults come from the candidates endpoint |

**Non-goals.** No removal of old paths. No Brolabs deploy without the user's explicit OK.

**Acceptance.** Steps 1 to 4 done with evidence in task comments; every E2E row passes or is reported with its failure.

### T22. One hub start procedure (phase 1; amendment S2)

**Goal.** Every start that the hub or a bridge asks for opens its run generation in `start_begin`. Path A is rebuilt on it; the start-begin route exists for the bridge.
**Requirements.** REQ-ONE-1, REQ-ONE-2, REQ-ONE-7 (cases L1 to L13), REQ-PIPE-5.
**Contracts.** 6.12.2, 6.12.5, 6.12.7, 6.12.8.
**Depends on.** T3 (both edit the bridge checks of `src/hub/service/agent/agent_service.odin`; T22 keeps the form T3 left).

**Files**

| File | Change |
|---|---|
| `src/hub/service/agent/start_begin.odin` | New: the types and procedures of 6.12.2 and `create_instance_stopped` (6.12.5) |
| `src/hub/service/agent/agent_service.odin` | `relaunch_instance_locked` is deleted. `start_instance`, `restart_instance`, `relaunch_instance`, `reconfigure_instance` and `create_instance` become the thin callers of 6.12.7 |
| `src/hub/domain` (the file that defines `Agent_Instance`), the agent repository in `src/hub/repository/sqlite` | Field and column `start_ref` |
| `src/hub/repository/sqlite/migrations/agents_001_start_ref.sql`, `src/hub/repository/sqlite/migrations.odin` | New migration, registered last (6.4.1): `ALTER TABLE agent_instances ADD COLUMN start_ref TEXT NOT NULL DEFAULT '';` |
| `src/hub/transport/http/bridge_handlers.odin`, `src/hub/app/wiring.odin` | `bridge_instance_start_begin_handler` and its route (6.12.2); `"start_begin":true` in the `bridge_ready` frame (6.12.3) |
| `src/contracts/bridge.odin` | `BRIDGE_READY_START_BEGIN` |
| `src/hub/repository/iface/agent_repo.odin`, the agent repository in `src/hub/repository/sqlite` | `agent_save_instance_guarded` (6.12.2 step 10) |
| `src/hub/transport/http/content_handlers.odin` | `restart_stopped_conversation_instance` calls `start` with `.Keep` and passes an optional guard on |
| `src/hub/transport/http/coordinator_wake.odin` | Passes a guard that repeats the `stopped_by` check (F14 b) |
| `src/hub/app/mcp_chain_create.odin`, `src/hub/app/mcp_runtime.odin` | The two `prepare_instance` + `send_instance_launch` pairs (`src/hub/app/mcp_chain_create.odin:45`, `src/hub/app/mcp_runtime.odin:102`) become `create_instance_stopped` + `start` |
| `src/hub/service/agent/boundary_test.odin`, `src/hub/service/agent/start_begin_test.odin` | New |

**Steps**

1. Record, from `origin/main` before any change, the `launch_agent` bytes that `start_instance`, `restart_instance` and `create_instance` send for one fixed row (ids and times fixed). They are the expected values of `test_start_keeps_launch_bytes`.
2. Verify the two Assumptions of 6.12.2 and 6.12.5 (`validate_frozen_runtime_transport` reads only its argument; `prepare_instance` creates the conversation). Report the result.
3. The `start_ref` column, field and migration.
4. `start_begin` with the eleven steps of 6.12.2; `start_reuse`, the guarded save, `start_ticket_destroy`, `start_launch_json`, `start_send`, `start_settle`, `start_cancel`, `start`. Until T23 merges, `start_send` sends what `send_frozen_instance_launch` (`src/hub/service/agent/agent_service.odin:423`) sends today.
5. Replace `relaunch_instance_locked` and switch the thin callers. Run the existing tests of `src/hub/service/agent`, `src/hub/transport/http`, `src/hub/service/taskv2` and `src/hub/app`.
6. `create_instance_stopped`; switch `create_instance` and the two MCP call sites.
7. `start_begin_for_bridge`, the handler, the route and the `bridge_ready` flag.
8. The coordinator-wake guard.
9. `test_start_has_one_implementation` with the allow-list of 6.12.7.

**Behaviour that MUST NOT change:** the command bytes of a manual Start, Restart and create (step 1); every error code and HTTP status of the existing start routes; the send under `reconfiguration_mutex`; the `already_running` details; what `reconfigure_instance` and the fleet change relaunch.

**Behaviour that changes, and is intended:** a Start or Restart that is refused no longer erases the user's stop mark (today `restart_instance` clears it before it takes the lock, F18); an ACP refusal writes nothing (case L9); the coordinator wake's stop check runs under the mutex; a new instance whose first start is refused is left `stopped` with `run_count` 0 instead of `launching`.

**Non-goals.** No change to task lease dispatch (T25), to bots or the bridge (T24), or to the wire command (T23). No change to `create_provider_test_instance` or `reconfiguration_launch_destination`. No read of `stopped_by` in `start_begin.odin`.

**Acceptance**

- The tests below pass; the existing tests of the four packages of step 5 pass, with each changed expectation listed in the hand-off.
- `grep -n "relaunch_instance_locked" -r src` prints nothing.
- `grep -rn "stopped_by" src/hub/service/agent/start_begin.odin` prints only assignments.

**Tests** (package `service/agent` unless stated)

| Name | Expected |
|---|---|
| `test_start_keeps_launch_bytes` | for the fixed row of step 1: the same row fields, the same command bytes (apart from generated ids) and the same reservation as `origin/main`, for Start, Restart and create |
| `test_start_if_live_table` | a `running` row: `Refuse` → `Conflict` with details code `already_running`, nothing written; `Keep` → `kept_live`, nothing written, nothing sent; `Relaunch` → `run_count + 1` and a command |
| `test_start_refusals_write_nothing` | one case per row L1 and L3 to L9 of 6.12.8, each on a row with `stopped_by = "user"`: the stated error; the stored row is byte-equal to before (same `run_count`, `launch_epoch`, `stopped_by`, `start_ref`); no reservation is left |
| `test_start_restart_refused_keeps_user_stop` | `restart_instance` on a user-stopped row whose bridge is offline: `Bridge_Offline`; `stopped_by` is still `"user"` |
| `test_start_send_failure_marks_failed` | the command cannot be sent: the row is `failed`, the reservation is cancelled, the generation stays consumed (case L13) |
| `test_start_begin_in_open_unit_of_work` | `start_begin` called inside an open unit of work: the row change is visible inside it; a rollback restores the row; `start_cancel` leaves no reservation |
| `test_start_begin_opens_generation` | a stopped row with `run_count` 3: after `start_begin_for_bridge` the row is `launching`, `startup_status` `starting`, `run_count` 4, `start_ref` set, a reservation exists; the returned text equals `start_launch_json` for the saved row with command id `sb_<ref>` |
| `test_start_begin_is_idempotent_per_ref` | the same ref twice: `run_count` bumped once, `reused` true, identical bytes. A different ref afterwards on a stopped row bumps again |
| `test_start_begin_reuses_ref_in_any_live_status` | (S2 rework) a row opened by ref R that has since moved to `starting`, then `running`, then `idle`: `start_begin` with ref R and `if_live = .Relaunch` returns `reused` each time; `run_count`, `launch_epoch` and `start_ref` are unchanged; no reservation. With the row `failed` or `unreachable`, the same call opens a new generation |
| `test_start_reuse_never_writes` | (S2 rework) `start_reuse` for a live row with the same ref: `ok`; for a `failed`, `stopped` or `unreachable` row, or a live row with another `start_ref`: `ok` false, `ended` true; the stored row is byte-equal in every case |
| `test_start_begin_guarded_save` | (S2 rework) between step 2 and step 10 another writer bumps `run_count` (injected through a repository wrapper): `Conflict` with details code `start_raced`; the other writer's row is intact; no reservation is left |
| `test_bridge_ready_carries_start_begin` (`transport/http`) | (S2 rework) the `bridge_ready` frame contains `"start_begin":true` |
| `test_reaped_row_accepts_start_begin` (`service/agent`) | (S2 rework) a `running` row whose `last_seen_at` is older than 90 s: `start_begin_for_bridge` is refused `already_running`; after `reap_stale_instances` the row is `unreachable` and the same call opens a generation |
| `test_start_begin_clears_user_stop` | a row with `stopped_by = "user"`: after a successful call `stopped_by` is empty and the row is `launching` |
| `test_start_begin_refuses_live_row` | through `start_begin_for_bridge`, for a row that is `launching` from another ref, `launching` from a hub-initiated start (empty `start_ref`), `running`, and `idle`: `Conflict` with details code `already_running`; `run_count`, `launch_epoch`, `start_ref` and `stopped_by` unchanged; no reservation was taken |
| `test_start_begin_route` (`transport/http`) | the route needs the bridge token; 200 returns `data.launch`, `run_count`, `reused`; a live row returns 409 whose body contains `"code":"already_running"`; another bridge's instance returns 404; an empty `ref` returns the validation error |
| `test_start_begin_handler_auth` (`transport/http`) | no token, a token in the query, another bridge's token → refused as `bridge_instance_bootstrap_handler` refuses them |
| `test_start_begin_race_with_manual_start` | `start_instance` and `start_begin_for_bridge` for the same stopped row from two threads, 100 rounds: exactly one opens a generation each round; the other gets `already_running`; `run_count` grows by 1 per round |
| `test_start_begin_wrong_bridge_or_owner` | `Not_Found`; nothing written |
| `test_start_begin_acp_epoch` | an ACP instance: a new `launch_epoch` is minted; a status frame carrying that epoch is applied (`apply_bridge_status_report`); one carrying the old epoch is refused as superseded |
| `test_start_begin_failed_status_releases_reservation` (`service/agent` or `transport/http`) | after `start_begin_for_bridge`, a `failed` status frame with the new epoch and a higher sequence: the registry entry is no longer reserved and the owner's active count is back to its value before the call |
| `test_start_begin_reservation_expires` (`service/project`) | a reservation with no status frame is gone after the registry sweep at now + 61 s (drive the sweep with an injected time, as the existing registry tests do) |
| `test_start_success_before_command_result` (`transport/http`) | start-begin; the agent's `start-success` with the new `run_count` is accepted before any `command_result` |
| `test_start_success_when_command_result_is_lost` (`transport/http`) | start-begin; `start-success` accepted; no `command_result` ever: the instance is `running` |
| `test_create_instance_stopped` | the row is `stopped` with `stopped_by` empty and `run_count` 0; no reservation is left; its conversation exists |
| `test_create_instance_first_generation_is_one` | `create_instance`: the command carries `run_count` 1, as on `origin/main` |
| `test_coordinator_wake_guard_under_mutex` (`transport/http`) | F14 (b): a user stop that lands between the wake's first check and its start is honoured; the coordinator is not started and `stopped_by` stays `"user"` |
| `test_start_has_one_implementation` (`boundary_test.odin`) | the scan of 6.12.7 finds nothing outside its allow-list |

### T23. One start command: `start_agent` (phase S; amendment S2)

**Goal.** Hub-initiated starts travel in one command. Old bridges keep `launch_agent` and `wake_agent`; a new bridge still accepts both from an older hub.
**Requirements.** REQ-ONE-5, REQ-ONE-6.
**Contracts.** 6.12.6, 6.12.3.
**Depends on.** T22 (tickets), T17 (it edits the same bridge files; T23 rebases on it).

**Files**

| File | Change |
|---|---|
| `src/contracts/start_wire.odin` | New: the constants of 6.12.6 |
| `src/hub/service/agent/start_command.odin` | New: `Start_Lease`, `Start_Run_Entry`, `start_command_json`, `start_command_send` |
| `src/hub/service/agent/start_begin.odin` | `start_send` sends through `start_command_send` |
| `src/hub/service/agent/agent_service.odin`, `src/hub/service/agent/instance_reconfiguration.odin` | `send_frozen_instance_launch` sends through `start_command_send` (this covers the move to another bridge) |
| `src/bridge/start_agent.odin` | New: `bridge_start_agent_apply` |
| `src/bridge/hub_runtime_client.odin` | The `start_agent` branch; the `launch_agent` branch (`src/bridge/hub_runtime_client.odin:1136`) and `bridge_hub_handle_wake_agent` (`src/bridge/hub_runtime_client.odin:2496`) become adapters; the feature in `BRIDGE_RUNTIME_FEATURES` |
| `src/bridge/hub_command_dispatch.odin` | `start_agent` in `bridge_command_spec` and in the ordering-key switch |
| Tests next to each | New |

**Steps**

1. Record from `origin/main` the bytes of one `launch_agent` and of one `wake_agent` with a launch entry, a nudge entry and a stop entry. They are the expected values of the two old-bridge tests and the two adapter tests.
2. The contracts file and `start_command_json`.
3. `start_command_send` with the feature choice; switch `start_send` and `send_frozen_instance_launch`.
4. Bridge: move the body of `bridge_hub_handle_wake_agent` into `bridge_start_agent_apply`, reading each entry's `launch` object instead of building one. Then the three handlers.
5. Dispatcher registration. Add the feature **last**.

**Non-goals.** No change to task lease dispatch: until T25, `flush_wakes` keeps building `wake_agent` itself. No removal of the old names, the adapters, `wake_agent_command_json` or `bridge_wake_launch_command_json`. No change to `stop_agent`, `launch_provider_test` or `bot_deliver`.

**Acceptance**

- The tests below pass; the existing tests of `src/bridge` and `src/hub/service/agent` pass unchanged.
- The hand-off shows one manual Start on a bridge with the feature (the frame is `start_agent`) and one without (the frame is `launch_agent`).

**Tests**

| Name (package) | Expected |
|---|---|
| `test_start_command_json_shape` (`service/agent`) | one launch entry: `type` `start_agent`, the top-level `agent_instance_id`, `payload.run[0].launch` byte-equal to `start_launch_json`; two entries or a stop list: no top-level `agent_instance_id` |
| `test_start_command_send_new_bridge` (`service/agent`) | a bridge that reports `start_agent_v1` receives `start_agent` |
| `test_start_command_old_bridge_launch_agent_bytes` (`service/agent`) | a bridge without the feature receives `launch_agent` with the bytes of step 1 |
| `test_start_command_old_bridge_wake_agent_bytes` (`service/agent`) | the same for entries with lease keys, a nudge and a stop list: `wake_agent` with the bytes of step 1 |
| `test_start_agent_launch_entry_passes_launch_unchanged` (`bridge`) | the text handed to `bridge_runtime_launch_agent` is byte-equal to `entry.launch` |
| `test_start_agent_nudge_live_child` (`bridge`) | `deliver = nudge` and a live child of that generation: one typed line, no launch. No live child: a launch |
| `test_start_agent_stop_list` (`bridge`) | the stop list stops what the `wake_agent` stop list stops today; a coordinator is never stopped |
| `test_start_agent_failed_entry_reports_status` (`bridge`) | a failed launch: the instance's status frame is sent, the answer is `failed` with the typed error, the other entries are still applied |
| `test_launch_agent_adapter_unchanged` (`bridge`) | a `launch_agent` frame of step 1 produces the same launch call and the same frames as on `origin/main` |
| `test_wake_agent_adapter_unchanged` (`bridge`) | the same for the `wake_agent` frame of step 1, the `succeeded` answer included |
| `test_start_agent_spec_and_key` (`bridge`) | queued, class `.Lifecycle`; the key is `agent:<id>` with the top-level field and the `wake_agent` key without it; a frame without `command_id` is rejected |
| `test_features_list_has_start_agent` (`bridge`) | `bridge_runtime_features()` contains `start_agent_v1` |

### T24. Bridge-initiated starts on start-begin: the notice fallback and bots (phase S; amendment S2)

**Goal.** Path C is gone: the fallback and the bot launch ask the hub to open the generation, like a pipeline delivery. No launch with generation 0 is left.
**Requirements.** REQ-ONE-4, REQ-ONE-7 (cases L16 to L22).
**Contracts.** 6.12.3, 6.12.4, 6.12.5, 6.12.8.
**Depends on.** T17 (`bridge_wake_attempt`, `bridge_wake_start_begin`), T22 (the route, `create_instance_stopped`).

**Files**

| File | Change |
|---|---|
| `src/bridge/agent_wake.odin` | `bridge_wake_attempt`: with the hub flag (6.12.3) it calls start-begin with a mandatory `ref`; without the flag it keeps the manifest branch unchanged; the stale-row retry of 6.12.4; `bridge_task_wake_if_needed` passes `fb_<instance>_<n>`; `bridge_wake_fetch_enriched_launch_json` stays for the legacy branch only |
| `src/bridge/bot_delivery.odin` | `bridge_bot_launch_via_descriptor` becomes `bridge_bot_launch_via_start_begin(instance_id, attempt_id)`: `bridge_wake_start_begin` with `ref = bot_<attempt_id>`, then the launcher |
| `src/bridge/hub_runtime_client.odin` | Reads `start_begin` from `bridge_ready` into `bridge_hub_start_begin_supported` and resets it before every hello; the periodic loop calls the pending stale-row retries |
| `src/hub/service/bots/supervisor.odin` | The prepare-then-cancel pair (`src/hub/service/bots/supervisor.odin:104`) becomes `create_instance_stopped` |
| Tests next to each | New and changed |

**Steps**

1. **First, confirm the recovery path of case L20** by running `test_reaped_row_accepts_start_begin` (T22) and reading `reap_stale_instances` (`src/hub/service/agent/agent_service.odin:1461`): a live row without heartbeats becomes `unreachable` within the reaper window, and `unreachable` is accepted by `start_begin`. Report the measured window.
2. The fallback: the reference, the deleted branch. The gate, coalescing, back-off and parking are unchanged; the failure class of 6.12.4 feeds `bridge_task_wake_record_result` exactly as the manifest error does today.
3. On `already_running`: apply the table of 6.12.4. With a local process: release the gate, nothing else. Without one: schedule the stale-row retry (30 s, at most 5, same reference); no status frame is sent, because none can correct the row.
4. Bots: the bridge call and the hub's `create_instance_stopped`.
5. The hub flag: read it, reset it, and branch on it in `bridge_wake_attempt` and in the bot launch. The manifest branch and `bridge_wake_fetch_enriched_launch_json` stay, reachable only when the flag is absent. The hub's bootstrap route stays.

**Rollout.** No order is needed (review finding 5): against a hub without the `start_begin` flag the bridge behaves exactly as before this task. "Hub first" is still the recommended order, because the fallback only stops launching with generation 0 once both sides are updated.

**Non-goals.** No change to the wake gate, to bot rounds, relocation or reports, to the three notice frames, or to the pipeline executor. No new frame type. No removal of the hub's bootstrap route.

**Acceptance**

- The tests below pass; the existing wake and bot tests of `src/bridge` and `src/hub/service/bots` pass, with each changed expectation listed in the hand-off.
- `grep -rn "bridge_wake_fetch_enriched_launch_json(" src/bridge --include=*.odin` shows its definition and one call, inside the branch taken when `bridge_hub_start_begin_supported` is false.

**Tests** (package `main` of `src/bridge` unless stated)

| Name | Expected |
|---|---|
| `test_fallback_stale_row_recovers_after_reaper` (with a fake hub) | (S2 rework) the hub answers 409 `already_running` three times, then 200; the bridge has no process: retries at 30 s, 60 s and 90 s of injected time with the same ref, the fourth call launches; no failure was recorded and the wake was never parked |
| `test_fallback_calls_start_begin_with_ref` | a notice for an absent instance: one POST with `ref = fb_<instance>_<n>`; the launcher receives `data.launch` unchanged |
| `test_fallback_never_generation_zero` | with the hub flag set, the launch command of every fallback start has `run_count` > 0 |
| `test_fallback_ref_stable_across_retries` | two attempts of one wake send the same ref; after a successful launch the next wake sends another |
| `test_fallback_failure_classes` | each row of 6.12.4: retriable → back-off; 404 and other 4xx → parked |
| `test_fallback_already_running_with_local_process` | a 409 `already_running` while the bridge's snapshot shows a process: no launch, no retry, no recorded failure |
| `test_fallback_stale_row_retry_is_bounded` | 409 on every call: exactly 5 retries, then one ordinary retriable failure (back-off); a newer wake for the instance or an active instance drops the pending retry |
| `test_fallback_legacy_hub_uses_manifest` | (mixed versions) `bridge_ready` without `start_begin`: the fallback sends the manifest GET and no start-begin POST, and launches as on `origin/main` |
| `test_bot_launch_legacy_hub_uses_manifest` | the same for a bot attempt |
| `test_start_begin_flag_reset_on_reconnect` | a connection with the flag, then a reconnect to a hub without it: the next wake uses the manifest GET |
| `test_start_begin_404_without_error_body_is_retriable` | a 404 with an HTML or empty body: retriable `hub_unavailable`, back-off, not parked; a 404 with the hub's JSON error: fatal `target_missing` |
| `test_fallback_start_success_is_accepted` (`transport/http`) | an instance with `run_count` 5 started by the fallback: its `start-success` is accepted (on `origin/main` it is refused, V11) |
| `test_bot_launch_calls_start_begin` | a bot attempt for an absent instance: one POST with `ref = bot_<attempt_id>`; no manifest GET |
| `test_bot_instance_created_stopped` (`service/bots`) | a bot without an instance: the row is created `stopped` with `run_count` 0 and no reservation is left |
| `test_bot_first_generation_is_one` (`service/bots` with a fake bridge) | the first launch of a new bot carries `run_count` 1 |
| `test_bot_launch_refused_reports_attempt` | start-begin answers a 4xx: the attempt is reported failed with the reason; the supervisor's rounds continue as today |

### T25. Task lease dispatch on start-begin; path B deleted (phase S; amendment S2)

**Goal.** A task lease starts an instance through `start_begin` inside the grant. The grant's own state write is deleted. This is the highest-risk task of the amendment (risk S-K2).
**Requirements.** REQ-ONE-3, REQ-ONE-7 (cases L6 to L9, L13).
**Contracts.** 6.12.2 (locks and transactions), 6.12.5, 6.12.6, 6.12.7.
**Depends on.** T22, T23.

**Files**

| File | Change |
|---|---|
| `src/hub/service/taskv2/lease.odin` | `grant_attempt_in_uow` (`src/hub/service/taskv2/lease.odin:77`) calls `start_begin`; its own state write (`src/hub/service/taskv2/lease.odin:231`) is deleted |
| `src/hub/service/taskv2/service.odin` | The effects list (`Effects`, `src/hub/service/taskv2/service.odin:164`) carries tickets; a rollback cancels them where reservations are cancelled today (`cancel_reservations`, `src/hub/service/taskv2/service.odin:407`) |
| `src/hub/service/taskv2/wake.odin` | `effect_wake_lease` builds a `Start_Run_Entry` from the ticket; `flush_wakes` sends through `agent.start_command_send` and settles |
| `src/hub/service/taskv2/matcher.odin` | `jit_prepare` (`src/hub/service/taskv2/matcher.odin:435`) calls `create_instance_stopped`; it adds no reservation to the effects |
| `src/hub/service/agent/boundary_test.odin` | `lease.odin` leaves the allow-list |

**Steps**

1. **First, verify the Assumptions of F14 (a) and (c)** by writing `test_explicit_claim_clears_user_stop` and `test_jit_instance_run_count_is_one` against the unchanged code and seeing them fail. If either passes on unchanged code, report it; the gap does not exist and its test is kept as a regression test only.
2. In `grant_attempt_in_uow`, where the instance row is set to `launching` today, call `agent.start_begin(svc.agent_service, auth, instance_id, {ref = lease_id, if_live = policy})` on the same thread, inside the grant's unit of work. `policy` is `.Keep` where `wake_reuses_live_child` (`src/hub/service/taskv2/lease.odin:306`) is true today and `.Relaunch` otherwise. Do **not** take `reconfiguration_mutex` (6.12.2). The grant's earlier save of a changed provider or model stays.
3. An error from `start_begin` fails the grant for that instance. The matcher records its existing placement failure for the instance with the error's message as detail and tries again on its next run. No lease row is written.
4. Put the ticket into the effects list next to the wake entry. On commit the tickets flow to `flush_effects`; on rollback call `start_cancel` and `start_ticket_destroy` for each.
5. `flush_wakes` (`src/hub/service/taskv2/wake.odin:146`): one `Start_Run_Entry` per ticket (`deliver = nudge` for `kept_live`, `launch` otherwise; `launch_json = start_launch_json(ticket, &lease)`), one `start_command_send` per bridge and chain, then `start_settle(t, sent)` and `start_ticket_destroy` per ticket. A failed send also calls `on_dispatch_failed`, as today. Its own ACP check moves into `start_begin` step 8.
6. **Redelivery never opens a generation** (bridge hello, hub start, the grant-unconfirmed timer; review finding 3). `effect_wake_lease` outside a grant calls `agent.start_reuse(instance_id, lease_id)`, not `start_begin`. By then the bridge's status frames may have moved the row from `launching` to `starting` or `running` before the lease is confirmed; the reference still matches, so:
   - `ok` (the row is live and its `start_ref` is this lease): send the entry again with the **same generation and the same bytes** as the grant sent (`start_launch_json` of the reused ticket). Nothing is written. This is today's behaviour.
   - `ended` (the row is `failed`, `stopped` or `unreachable`, or another start replaced the generation): send nothing. The child this lease started is gone; relaunching the same generation, as a blind resend does today, would be refused at start-success. The lease takes the existing unconfirmed-dispatch path, `on_dispatch_failed` (`src/hub/service/taskv2/dispatch.odin:178`), and the next grant opens a new generation through `start_begin`. **This is an intended behaviour change**, listed below.
7. `jit_prepare`: `create_instance_stopped`.
8. Remove the allow-list entry.

**Behaviour that MUST NOT change:** which instance is leased (v7-Q4; `src/hub/service/taskv2/matcher.odin` changes only in `jit_prepare`); batching per bridge and chain; the nudge of a live child; redelivery of an unconfirmed wake; lease confirmation by `run_count`; the `wake_agent` bytes an old bridge receives for a grant to an existing stopped instance.

**Behaviour that changes, and is intended:** a just-created instance is launched with `run_count` 1, not 2 (F14 c); an explicit claim or transfer of a user-stopped instance clears the stop mark in the save that opens the generation (F14 a); a lease start now checks the plan, the live connection, the launch quota and ACP support, and a grant that fails them is refused instead of starting an agent (cases L6 to L9); a failed send marks the instance row `failed` (case L13); a redelivery for a lease whose child already failed or stopped no longer resends the old launch but fails the dispatch, so the next grant starts a new generation; a grant that loses the guarded save to a concurrent manual start fails with `start_raced` and is retried by the matcher.

**Non-goals.** No change to `pick_instance`, the lease state machine, the timers or the placement rules (T4). No pipeline transport (T20). No change to the stop list.

**Acceptance and tests** (package `taskv2` unless stated)

- The existing lease, dispatch, redelivery, confirmation and startup-wake tests pass. A test whose expected `run_count` for a just-created instance was 2 is changed to 1, and the hand-off lists each such test and each of the changed behaviours above.
- `grep -n "run_count += 1\|\"launching\"" src/hub/service/taskv2/lease.odin` prints nothing.

| Name | Expected |
|---|---|
| `test_explicit_claim_clears_user_stop` | F14 (a): the claim and the transfer of a user-stopped instance start it; `stopped_by` is empty in the row that is `launching` |
| `test_jit_instance_run_count_is_one` | F14 (c): after grant and flush the new instance has `run_count` 1 and the launch object carries 1 |
| `test_grant_rollback_cancels_ticket` | a grant whose unit of work rolls back leaves the instance row unchanged and no reservation |
| `test_grant_send_failure_marks_failed` | the command cannot be sent: the row is `failed`, the reservation is cancelled, and the lease follows `on_dispatch_failed` |
| `test_grant_live_instance_is_nudged` | `kept_live`: no row change, a nudge entry is sent |
| `test_grant_refused_plan_disabled` | case L6: no lease, no row change; the placement failure carries the plan reason |
| `test_grant_refused_no_live_connection` | case L7: a bridge whose row is `Online` but which has no live connection gets no lease |
| `test_grant_refused_quota` | case L8: at the owner's limit the grant to an existing stopped instance fails with the quota error; one below the limit it consumes one reservation |
| `test_grant_refused_acp_withdrawn` | case L9: no lease, no row change |
| `test_grant_redelivery_reuses_generation` | hello, hub start and the timer each resend the same launch bytes; `run_count`, `launch_epoch` and `start_ref` are unchanged. Repeated with the row moved to `starting` and to `running` by status frames before the redelivery: the same result, and no new generation |
| `test_grant_redelivery_after_child_failed` | the row is `failed` (and, in a second case, `unreachable`) when the redelivery runs: nothing is sent, the row is not written, `on_dispatch_failed` ran for the lease; the next grant carries `run_count + 1` |
| `test_grant_race_with_manual_start` | `start_instance` and a grant for the same stopped instance from two threads, 100 rounds: exactly one generation is opened per round (`run_count` grows by 1), exactly one launch command is sent, the loser gets `start_raced` (or `already_running` when it read the row after the winner's commit), and no reservation is left over |
| `test_lease_start_agent_entry` | a bridge with `start_agent_v1`: one `start_agent` per bridge and chain; the entry's `launch` carries the lease keys and the pack |
| `test_wake_agent_bytes_unchanged` | a bridge without the feature: the command equals a golden value recorded from `origin/main` for a grant to a stopped existing instance |
| `test_start_has_one_implementation` (`service/agent`) | passes with `lease.odin` removed from the allow-list |

### T26. Phase-S integration and E2E (amendment S2)

**Goal.** One releasable phase S: every agent start runs through `start_begin` and `bridge_runtime_launch_agent`.
**Requirements.** REQ-ONE-1 (final allow-list), REQ-ONE-5, REQ-DEPLOY-1.
**Depends on.** T23, T24, T25.

**Steps**

1. Merge `origin/main`; re-run the boundary tests and the full suites; report counts per package.
2. `prepare_instance` has no caller left that needs a `launching` row. Delete its `launching` write and its reservation; `create_instance_stopped` becomes its only caller. Remove it from the allow-list of `test_start_has_one_implementation`.
3. Add `test_one_launcher_two_callers` (`src/bridge`, a source scan in the style of `src/hub/app/thread_spawn_guard_test.odin:22`): `bridge_runtime_launch_agent(` is called only from `src/bridge/start_agent.odin` and `src/bridge/agent_wake.odin`.
4. Docs: the bridge protocol text (`start_agent`, the feature, the old names); `SELF_HOSTING.md` (hub first, then bridges, also for phase S); the task-engine section on why a lease can be refused (cases L6 to L9).
5. Close finding F14: comment on any issue that tracks gap (a), (b) or (c) with the test that proves it closed.
6. Deploy to Mundus through a change request (hub first, then bridges). Run the E2E list. Brolabs only after the user's explicit OK.

**E2E list (Mundus)**

| # | Scenario | Pass when |
|---|---|---|
| S1 | Manual Start and Restart of an agent on an updated bridge | the bridge log shows `start_agent`; `run_count` grows by 1 per start |
| S2 | The same on a bridge that was not updated | the bridge receives `launch_agent`; the agent starts |
| S3 | A task chain with a worker and a reviewer on an updated bridge | leases launch, nudge and confirm; a new instance's first `run_count` is 1; each further launch adds 1 |
| S4 | The same on a bridge that was not updated | works through `wake_agent` |
| S5 | A lease for an owner at the launch limit | the task waits with the quota reason and is granted after another agent stops |
| S6 | Kill an agent's process, then cause a task-status notice for it | the fallback restarts it with `run_count + 1`; its `start-success` is accepted |
| S7 | A web channel message to a bot whose instance is stopped | the bot starts with a generation above 0 and answers |
| S8 | An explicit lease claim for an instance the user stopped | it starts; `stopped_by` is empty afterwards |
| S9 | Restart the bridge while an agent's row is `running`, then cause a notice for it | the bridge retries; within about 150 s the reaper has marked the row `unreachable` and the agent starts with `run_count + 1`, without a second notice |
| S10 | Stop the bridge right after a grant, restart it 2 minutes later | the worker starts after the reconnect with the generation of the grant, without a second grant |

**Non-goals.** No removal of the old command names. No Brolabs deploy without the user's explicit OK.

**Acceptance.** Steps 1 to 6 done with evidence in task comments; every E2E row passes or is reported with its failure.

## 9. Traceability

### 9.1 Requirement → task → tests

| Requirement | Tasks | Tests that prove it |
|---|---|---|
| REQ-ACT-1 | T9 | `test_actions_reset_from_old_schema`, `test_action_repo_round_trip`, `test_actions_api_crud` |
| REQ-ACT-2 | T9, T10 | `test_fake_trigger_kind`, `test_matcher_and_router_name_no_kind` |
| REQ-ACT-3 | T9, T10 | `test_actions_imports` |
| REQ-ACT-4 | T1, T10 | `scenario_deliver_new`, `test_c12_crash_between_commit_and_ack`, `test_c13_first_start_ignores_history`, `test_matcher_tenant_isolation`, `test_window_and_blackout` |
| REQ-ACT-5 | T9, T10 | `test_event_compile_table`, `test_render_table`, `test_subject_matches_table`, `test_data_matches_table`; E2E E2 |
| REQ-ACT-6 | T10 | `test_router_route_transaction_is_atomic`, `test_router_crash_before_route_routes_again_once`, `test_router_crash_after_route_delivers_once`, `test_router_claim_is_exclusive`, `test_router_metadata_and_cause` |
| REQ-ACT-7 | T9, T10 | `test_runs_prune`, `test_runs_pruned_after_finish`, `test_runs_endpoint` |
| REQ-ACT-8 | T9, T10, T19 | `test_actions_api_flag_off`, `test_router_flag_off`, `test_action_bot_target_needs_bots_experiment`; E2E E9 |
| REQ-ACT-9 | T9 | `test_actions_api_crud`, `test_actions_api_validation`, `test_actions_routes` |
| REQ-ACT-10 | T13 | the `tests/ui_actions_*` tests, `tests/ui_actions_runs_test.ts` (v7 states) |
| REQ-ACT-11 | T12 | the `test_ctl_actions_*` tests |
| REQ-ACT-12 | T8, T9 | the grep acceptance items of T8 and T9; `test_prune_probe_is_ungated`, `test_update_catalog_probe_status_codes`, `test_actions_routes`; E2E E12 |
| REQ-ACT-13 | T10 | `test_c01_…` to `test_c22_…`, `test_deferral_fire_real_server`, `test_matcher_joins_routed_run`, `test_matcher_expires_routed_run_before_join`; E2E E3, E4, E13 |
| REQ-ACT-14 | T9, T10 | the `test_place_*`, `test_reuse_*`, `test_fresh_per_run_stops_previous`, `test_no_placement`, `test_instance_target_missing_and_offline` tests; E2E E1 |
| REQ-PLACE-1 | T3 | `test_placement_imports`, `test_match_*`, `test_validate_rules_codes`, `test_candidates_allocator_ownership` |
| REQ-PLACE-2 | T3, T4 | `test_bridge_eligible_table`, `test_launchable_table`, `test_agent_and_bots_use_the_predicate`, `test_one_eligibility_predicate` |
| REQ-PLACE-3 | T3, T4, T10 | the existing bots placement tests; `test_resolve_placement_same_bridge`, `test_resolve_launch_model_matches_module_order`, `test_placement_problem_reason_mapping` |
| REQ-PLACE-4 | T3 | `test_second_selector_needs_no_caller_change` |
| REQ-PLACE-5 | T3, T4 | `test_match_order` and the six tests of 6.10.4 |
| REQ-PLACE-6 | T3, T13, T4 | `test_placement_candidates_endpoint`, `tests/ui_actions_rules_editor_test.ts`, `tests/ui_placement_defaults_test.ts` |
| REQ-SCHED-0 | T1, T9, T14 | C1 `scenario_supports_schedules`, `test_version_at_least`; C2 `scenario_stream_update_keeps_data` and the T14 change request; C3 `scenario_ttl_never_outlives_max_age`, `test_schedule_definition_row`; C4 `test_relay_stream_has_schedule_subjects`; C5 `test_c02_…`, `test_c11_…`; C6 `test_schedule_definition_row` |
| REQ-SCHED-1 | T2 | the ported tests and the `test_nats_cron_*`, `test_cron_dst_*` tests |
| REQ-SCHED-2 | T9, T10 | `test_one_outbox_row_per_schedule_save`, `test_reconcile_plan_table`, `test_reconcile_real_server`, `test_runtime_reconciles_on_connect`; E2E E11 |
| REQ-SCHED-3 | T10 | `test_c03_cron_and_event_same_batch`, `test_router_metadata_and_cause` |
| REQ-SCHED-4 | T8, T14 | the T8 grep; `test_heartbeat_ack_with_schedule_fields_is_ignored`, `test_old_bridge_heartbeat_ok` |
| REQ-SCHED-5 | T1, T9, T10 | `test_relay_drops_definitions_when_unsupported`, `test_actions_api_schedules_unsupported`, `test_c18_no_schedule_support` |
| REQ-PIPE-1 | T1, T16 | `scenario_work_queue_ack_removes`, `scenario_work_queue_disjoint_consumers`, `test_relay_creates_delivery_stream`, `test_relay_publishes_delivery_row_once`, `test_route_writes_row_and_outbox`, `test_route_validation` |
| REQ-PIPE-2 | T16 | `test_forward_and_ack`, `test_incapable_bridge_gets_no_consumer`, `test_start_stop_clean`, `test_in_flight_limit`, `test_waiting_retries_do_not_block_other_deliveries`, `test_in_flight_ignores_stale_rows`, `test_reconnect_while_answers_arrive`, `test_answers_are_queued_not_sent_on_caller_thread`, the sleep grep of T16 |
| REQ-PIPE-3 | T16 | `test_gate_drops_closed_rows`, `test_gate_expires`, `test_gate_still_valid_false`, `test_gate_unknown_delivery_is_terminated` |
| REQ-PIPE-4 | T1, T16 | `scenario_nak_reply_delay`, `scenario_in_progress_reply`, `scenario_term_reply`, `test_accepted_keeps_message`, `test_retry_redelivers_after_delay`, `test_fatal_terminates`, `test_retry_delay_table`, `test_result_is_idempotent`, `test_transition_lost_cas_is_a_no_op`, `scenario_delayed_nak_counts_toward_max_ack_pending`, `scenario_ack_reply_async`, `test_succeeded_from_older_attempt_counts` |
| REQ-PIPE-5 | T22 | `test_start_keeps_launch_bytes`, `test_start_begin_opens_generation`, `test_start_begin_is_idempotent_per_ref`, `test_start_begin_clears_user_stop`, `test_start_begin_refuses_live_row`, `test_start_begin_race_with_manual_start`, `test_start_begin_acp_epoch`, `test_start_begin_failed_status_releases_reservation`, `test_start_success_before_command_result`, `test_start_success_when_command_result_is_lost`, `test_pipeline_never_reads_stopped_by`; E2E E5 |
| REQ-PIPE-6 | T16 | `test_off1_route_does_not_check_liveness`, `test_off2_routed_delivery_is_replaced_on_disconnect`, `test_off2b_forwarded_delivery_is_not_replaced`, `test_off2_max_three_rounds`, `test_off3_waits_for_reconnect`, `test_off3_expired_on_reconnect`, `test_off4_exhausted_from_advisory`, `test_off5_expire_due_at_start`, `test_forward_launch_drop_reconnect_single_effect`; E2E E14 to E16 |
| REQ-PIPE-7 | T1, T16 | `scenario_max_deliver_advisory`, `scenario_delete_message`, `test_off4_exhausted_from_advisory`, `test_retry_on_final_attempt_is_fatal` |
| REQ-PIPE-8 | T16, T10, T14, T18, T19, T20 | `test_route_refuses_incapable_bridge`, `test_incapable_bridge_gets_no_consumer`, `test_downgraded_bridge_closes_deliveries`, `test_place_requires_pipeline_feature`, `test_old_bridge_is_not_a_candidate`; E2E E18 |
| REQ-PIPE-9 | T16 | `test_delivery_imports` |
| REQ-PIPE-10 | T16 | `test_forward_and_ack` (the row is `forwarded` before the frame), `test_send_failure_keeps_forwarded`, `test_off2b_forwarded_delivery_is_not_replaced` |
| REQ-BRG-1 | T17 | `test_event_decide_table` and the `test_event_row*` tests, `test_event_start_user_stopped_instance` |
| REQ-BRG-2 | T17 | the `test_ledger_*` tests, `test_event_restart_in_progress_start_running`, `test_event_restart_in_progress_start_absent`, `test_event_restart_in_progress_type`; E2E E17, E19 |
| REQ-BRG-3 | T17 | `test_event_row9_absent_starts`, `test_event_start_never_generation_zero`, `test_event_start_same_command_as_launch_agent`, `test_event_start_gate_coalesced_backoff_parked`, `test_wake_attempt_wrapper_unchanged` |
| REQ-BRG-4 | T17 | `test_event_result_json_fields`, `test_event_final_never_retry`, `test_event_start_retriable_on_final_is_fatal`, `test_event_answer_is_last_frame` |
| REQ-BRG-5 | T17 | the `nats` grep of T17; `test_event_deliver_spec_and_key`, `test_features_list_has_event_pipeline`; review item: the diff adds no frame type and no request other than start-begin |
| REQ-FLOW-1 | T18 | the `test_notice_*` tests, `tests/ui_event_notice_test.ts`, the `stopped_by` grep of T18 |
| REQ-FLOW-2 | T19 | `test_bot_attempt_routed_through_pipeline`, `test_bot_sink_done_and_failed`, `test_bot_hello_does_not_resend_on_pipeline`, `test_action_bot_target_types_prompt`, `test_action_bot_target_joins_open_delivery`; E2E P4 to P6 |
| REQ-FLOW-3 | T20 | `test_grant_appends_lease_delivery`, `test_lease_payload_bytes_unchanged`, `test_lease_delivered_after_reconnect_without_hello_resend`, `test_lease_sink_failed_parks_task`, `test_grant_unconfirmed_timer_on_pipeline`, the `test_bridge_lease_*` tests; E2E P1, P3 |
| REQ-FLOW-4 | T18, T19, T20 | `test_notice_old_bridge_uses_old_path`, the existing bots and lease tests run on the old transport, `test_wake_agent_adapter_unchanged`, `test_lease_pipeline_needs_both_features`, `test_bot_wire_fields_are_additive`; E2E P2 |
| REQ-ONE-1 | T22, T25, T26 | `test_start_has_one_implementation` (allow-list shrinks in T25 and T26), `test_start_begin_in_open_unit_of_work`, `test_start_refusals_write_nothing`, `test_start_begin_guarded_save`, `test_grant_race_with_manual_start`, `test_start_begin_reuses_ref_in_any_live_status`, `test_start_reuse_never_writes` |
| REQ-ONE-2 | T22 | `test_start_keeps_launch_bytes`, `test_start_if_live_table`, `test_start_restart_refused_keeps_user_stop`, `test_start_send_failure_marks_failed`, `test_create_instance_stopped`, `test_create_instance_first_generation_is_one`, `test_coordinator_wake_guard_under_mutex`; E2E S1, S2 |
| REQ-ONE-3 | T25 | `test_explicit_claim_clears_user_stop`, `test_jit_instance_run_count_is_one`, `test_grant_rollback_cancels_ticket`, `test_grant_send_failure_marks_failed`, `test_grant_live_instance_is_nudged`, `test_grant_redelivery_reuses_generation`, `test_grant_redelivery_after_child_failed`, the lease grep of T25; E2E S3, S8, S10 |
| REQ-ONE-4 | T17, T24 | `test_event_start_never_generation_zero`, `test_fallback_calls_start_begin_with_ref`, `test_fallback_never_generation_zero`, `test_fallback_ref_stable_across_retries`, `test_fallback_start_success_is_accepted`, `test_bot_launch_calls_start_begin`, `test_bot_instance_created_stopped`, `test_bot_first_generation_is_one`, `test_bridge_ready_carries_start_begin`, `test_fallback_legacy_hub_uses_manifest`, `test_bot_launch_legacy_hub_uses_manifest`, `test_start_begin_flag_reset_on_reconnect`, `test_start_begin_404_without_error_body_is_retriable`, the grep of T24; E2E S6, S7 |
| REQ-ONE-5 | T23, T26 | `test_start_agent_launch_entry_passes_launch_unchanged`, `test_one_launcher_two_callers` |
| REQ-ONE-6 | T23, T25 | `test_start_command_json_shape`, `test_start_command_send_new_bridge`, `test_start_command_old_bridge_launch_agent_bytes`, `test_start_command_old_bridge_wake_agent_bytes`, `test_launch_agent_adapter_unchanged`, `test_wake_agent_adapter_unchanged`, `test_start_agent_nudge_live_child`, `test_start_agent_stop_list`, `test_start_agent_failed_entry_reports_status`, `test_start_agent_spec_and_key`, `test_features_list_has_start_agent`, `test_lease_start_agent_entry`, `test_wake_agent_bytes_unchanged`; E2E S1 to S4 |
| REQ-ONE-7 | T17, T22, T24, T25 | L1, L3 to L9: `test_start_refusals_write_nothing`; L2: `test_start_if_live_table`, `test_start_begin_refuses_live_row`; L6 to L9 for leases: `test_grant_refused_plan_disabled`, `test_grant_refused_no_live_connection`, `test_grant_refused_quota`, `test_grant_refused_acp_withdrawn`; L10: `test_coordinator_wake_guard_under_mutex`; L11: `test_create_instance_stopped`; L13: `test_start_send_failure_marks_failed`, `test_grant_send_failure_marks_failed`; L14: `test_old_bridge_is_not_a_candidate`; L15: `test_start_command_old_bridge_launch_agent_bytes`; L16: `test_event_start_begin_failure_classes`, `test_fallback_failure_classes`, `test_bot_launch_refused_reports_attempt`; L17: `test_event_row4_draining_and_vault_locked`; L18: `test_event_start_gate_coalesced_backoff_parked`; L19: `test_start_agent_failed_entry_reports_status`, `test_start_begin_failed_status_releases_reservation`; L20: `test_reaped_row_accepts_start_begin`, `test_event_already_running_without_snapshot_retries`, `test_event_already_running_without_snapshot_final_is_fatal`, `test_event_already_running_with_local_process_is_started`, `test_event_stale_row_recovers_after_reaper`, `test_fallback_stale_row_recovers_after_reaper`, `test_fallback_already_running_with_local_process`, `test_fallback_stale_row_retry_is_bounded`; L21: `test_grant_redelivery_reuses_generation`, `test_grant_redelivery_after_child_failed`; L22: `test_start_begin_is_idempotent_per_ref`, `test_start_begin_reservation_expires`; L12 and L23 are unchanged behaviour covered by the existing task-engine tests; E2E S5, S9 |
| REQ-SCALE-1 | T17 | `test_ledger_evicts_by_expiry_plus_margin`, `test_ledger_redelivery_inside_margin_has_no_second_effect`, `test_ledger_bridge_clock_ahead`, `test_ledger_holds_rate_times_lifetime` |
| REQ-SCALE-2 | T1 | `test_relay_wakes_on_commit`, `test_relay_rollback_does_not_wake`, `test_relay_publishes_batch_in_order`, `test_relay_idle_fallback_wait` |
| REQ-SCALE-3 | T16 | `test_prune_runs_when_a_delivery_becomes_final`, `test_prune_at_most_once_per_hour` |
| REQ-SCALE-4 | T1, T9 | `scenario_schedule_fire_ttl`, `test_schedule_rows_carry_fire_ttl` |
| REQ-SCALE-5 | T9, T10 | `test_match_key_derivation`, `test_triggers_match_reads_only_matching_keys`, `test_schedule_fire_reads_one_trigger`, `test_exact_and_wildcard_triggers_both_match` |
| REQ-LOOKUP-1 | T3, T9, T10, T16 | `test_event_path_queries_use_indexes` |
| REQ-DEPLOY-1 | T14, T21, T26 | the E2E lists and the change requests |

### 9.2 User decision → where it is built

Section 2 maps every decision to its sections and tasks. The tests are those of the requirements those tasks carry. These decisions have tests of their own:

| Decision | REQ IDs | Tasks | Tests |
|---|---|---|---|
| B1 hub consumer per bridge, forward over the link | PIPE-1, 2; BRG-5 | T1, T16, T17 | `test_forward_and_ack`, `scenario_work_queue_disjoint_consumers`, the `nats` grep of T17 |
| B2 hub picks the bridge at route time | ACT-6, PLACE-1..5 | T3, T10 | the `test_place_*` tests |
| B3 bridge starts; no stop check | BRG-1, 3; PIPE-5, 10 | T16, T22, T17 | `test_start_begin_clears_user_stop`, `test_event_start_user_stopped_instance`, `test_reuse_user_stopped_instance_is_used`, `test_pipeline_never_reads_stopped_by`; E2E E5 |
| B4 ack or nak from the bridge | PIPE-4, BRG-4 | T16, T17 | `test_retry_redelivers_after_delay`, `test_event_result_json_fields` |
| B5 one pipeline, four flows | PIPE-9, FLOW-1..3 | T10, T18, T19, T20 | `test_delivery_imports`; one routed-delivery test per kind |
| No stop check | PIPE-5, FLOW-1 | T16, T18 | `test_notice_user_stopped_agent_is_routed`, the greps of T16 and T18 |
| v7-Q1 old bridges cannot run actions | PIPE-8 | T10, T14 | `test_place_requires_pipeline_feature`, `test_old_bridge_is_not_a_candidate`; E2E E18 |
| v7-Q2 start-begin | PIPE-5, BRG-3 | T22, T17 | the `test_start_begin_*` tests, `test_event_row9_absent_starts` |
| v7-Q3 busy agent: retry about 15 minutes, then deliver | PIPE-4, BRG-1 | T16, T17 | `test_retry_delay_table`, `test_event_row8_busy_asks_retry`, `test_event_row8b_busy_final_types_anyway`, `test_retried_busy_target_ends_delivered`; E2E E13 |
| v7-Q4 lease stop avoidance unchanged | FLOW-3 | T20 | review item: `src/hub/service/taskv2/matcher.odin` is not in the diff of T20 |
| v7-Q5 user chat messages stay off the pipeline | — | — | review item on T16 and T10: `deliver_user_message` and `send_chat_message_handler` are not in any diff |
| v7-Q6 bot prompts and lease packs inside the message | FLOW-2, 3 | T19, T20 | `test_bot_attempt_routed_through_pipeline`, `test_lease_payload_bytes_unchanged` |
| v7-Q7 pinned offline machine: 1 h | PIPE-6 | T16, T10 | `test_gate_expires`, `test_place_pinned_offline_machine_waits`, `test_router_metadata_and_cause` (lifetime); E2E E15, E16 |
| A1 with `routed` open | ACT-13 | T10 | `test_c21_…`, `test_c22_…`, `test_matcher_joins_routed_run` |
| Q6 / A3 no run-now | ACT-9, 11 | T9, T12, T13 | `test_actions_routes`, `test_ctl_actions_no_run_verb`, `tests/ui_actions_no_run_button_test.ts` |
| v5-Q2 no hub tick | ACT-13, PIPE-2 | T10, T16 | the sleep greps of T10 and T16; `test_deferral_fire_real_server`; `test_c14_lost_deferral_fire` |
| S-A one start path | ONE-1 to 5, 7 | T22, T24, T25, T26 | `test_start_has_one_implementation`, `test_one_launcher_two_callers`, `test_fallback_never_generation_zero`, `test_jit_instance_run_count_is_one`; E2E S3, S6, S7 |
| S-B one start command | ONE-6 | T23, T25 | `test_start_command_json_shape`, the two old-bridge byte tests, the two adapter tests; E2E S1 to S4 |
| S-C fallback and bots on start-begin | ONE-4 | T24 | `test_fallback_calls_start_begin_with_ref`, `test_bot_launch_calls_start_begin`, the grep of T24 |
| S-D now, before phase 1 | — | T22 in phase 1; T23 to T26 in phase S | section 7 |
| Scale 1 to 5, Lookups | SCALE-1 to 5, LOOKUP-1 | T1, T9, T10, T16, T17 | the tests of those requirements |

## 10. Risks, and assumptions settled

### 10.1 Risks

| # | Risk | Handling |
|---|---|---|
| K1 | Enabling schedules on `HEIM_EVENTS` cannot be undone. An older hub binary can no longer bring its event relay up | Accepted by the user (Q1). The release is forward-only and the change request says so (T14). `HEIM_DELIVER` adds nothing irreversible |
| K2 | A self-hosted install runs nats-server older than 2.14 | Run-time check and fallback (6.3.3). Deferral degrades to `skipped: rate_limited` there. The pipeline's features (work queue, delayed nak) exist in older servers too; they were tested on 2.14.7 only |
| K3 | Stopping a schedule | Decided: purge the definition subject (6.2.3, 6.3.4). Tested in T1 |
| K4 | `chain.state` keeps only the newest state per chain (rollup) | Accepted (Q4) |
| K5 | An action that triggers itself runs once per `min_interval_s` without end | Visible in the run history; the interval can be raised per action; the action can be disabled |
| K7 | T3 and T4 change who is eligible (6.10.4) | Each change has a named test and is listed in the hand-off. Refusals carry a reason |
| K8 | Event notices as messages add lines to agent conversations (phase 2) | Compact line; at most one per 30 s per subscriber; one open notice per instance |
| K10 | `@every` restarts its interval when nats-server restarts or the definition is republished | Accepted. Definitions are republished only when changed (6.2.2) |
| K11 | A run with no satisfiable rule fails; there is no waiting queue | Recorded as `failed: no_placement`; the next trigger tries again |
| K14 | Between T9 and T12/T13 the old CLI and UI call routes that are gone | Inside phase 1 only, behind the experiment; T14 releases them together |
| K15 | A bridge built before T8 keeps running its scheduler against a hub without the bridge routes | Its requests get 404 and it fires nothing. Verified in T14 step 5 |
| K16 | The IANA zone database is missing on a hub host | Verified in T2 |
| V-K1 | **Start-begin replaces `relaunch_instance_locked`**, the procedure behind every manual start | See S-K1 |
| V-K2 | A machine that drops in the seconds between forward and answer holds its prompt until it returns or the prompt expires (OFF-2b) | Accepted in exchange for never running an action twice; the run history shows `routed` |
| V-K3 | One forwarder thread per capable bridge. Fine for tens of bridges; not measured for hundreds | A cap of 256 with a counter (6.11.4). If a deployment nears it, the follow-up is a small pool that multiplexes bridges; the `delivery` API does not change |
| V-K4 | Waking user-stopped agents surprises a user who stopped an agent on purpose | The user's decision (B3). The run history and the chat card show what woke it; disabling the action or the watch is the off switch; stated in the user docs (T14) |
| V-K5 | A busy agent delays a prompt by up to about 15 minutes, then is interrupted | The user's decision (v7-Q3) |
| V-K6 | Lease packs and bot prompt text rest in `HEIM_DELIVER` until acked (24 h at most) | The stream is private; work-queue retention removes acked messages; phase 3 only (v7-Q6) |
| V-K7 | Placing again writes a second chat message into another instance's conversation | Only for deliveries that were never forwarded, or that the bridge refused for good; the first message is marked read and labelled (6.13.5) |
| V-K8 | Old bridges cannot run actions until they update | Stated in the rule editor and run history; hub-first rollout |
| V-K9 | Two code paths per flow in phases 2 and 3 until old bridges are gone | Each flow has one switch (`delivery.bridge_capable`); removal is a later, separate change |
| V-K11 | A pinned machine that is offline keeps the action's run open for up to 1 hour, so later matches join it | This is A1 applied to the wait; visible as `joined` rows (v7-Q7) |
| V-K12 | A crash between the router's Plan step and its route transaction can leave an instance row that nothing uses (`fresh_per_run` only) | Rare; the row is `stopped` and visible; not cleaned up automatically |
| V-K13 | A row can stay `launching` on the hub when the bridge called start-begin and then died before launching | The stale-instance reaper and the next status frame correct it; the reservation expires after one minute; the delivery is retried and start-begin is called again |
| V-K14 | The dispatcher's class `Lifecycle` has two workers on the bridge. Two slow starts delay a third delivery | A start returns after the spawn, not after readiness; the hub's AckWait (60 s) is twice the handler budget; a late answer only causes one redelivery, which the ledger absorbs |
| V-K15 | `js_DeleteMsg` was not part of the capability check | T1 verifies it first (6.3.5); the fallback is harmless |
| V-K16 | The event-inbox fix changes the code T18 edits | T18 starts after it merged and re-reads the package (section 7) |
| V-K17 | The first notice after a start relies on the start-success step telling the agent about the first unread message. An instance that is *booting* and has already passed that step when the delivery arrives gets no typed line for it | The window is the few milliseconds between start-success on the hub and the status change on the bridge; the message stays unread in the conversation and is seen at the agent's next `chat read` |
| V-K18 | **Head-of-line blocking on one bridge.** Measured (N10): a delivery waiting for a delayed retry holds a `MaxAckPending` slot | `MaxAckPending` is 256 and is not the in-flight limit; the hub counts frames in flight itself (16, 6.11.4), and waiting retries are not counted. Blocking needs 256 open deliveries on one bridge at once. Open deliveries are bounded by design: one per action (A1), one notice per instance, one per bot, one per lease. If a deployment gets near 256, raise the constant; nothing else changes |
| V-K19 | A connection that the registry reports live while its writes fail uses up attempts | A failed send is not nak'd: it costs at most one attempt per minute (6.11.4 step 5), so the 8 attempts last at least 8 minutes, far longer than disconnect detection. A delivery that still runs out ends `failed`, `no_answer` and is not placed again, because the frame may have been sent in part |
| V-K20 | Start-begin for a row that is already live returns `already_running`, although this delivery started nothing | (Changed by the S2 rework.) The bridge answers `started` only when it has a process for the instance itself; then the live generation's start-success step finds the stored message. With no local process it answers `retry` until the hub's reaper has corrected a stale row or the other start has arrived, and `failed` (`hub_row_live`) on the final attempt. A delivery is not closed as delivered on the strength of a hub row alone |
| S-K1 | **T22 rebuilds every manual start** (Start, Restart, create, chat message, MCP, fleet change) and is on phase 1's critical path | The statements are moved, not rewritten; `test_start_keeps_launch_bytes` compares command bytes with `origin/main` for Start, Restart and create; the existing tests of four packages must pass; the intended changes are listed in T22 and in its hand-off |
| S-K2 | **Task lease dispatch changes behaviour.** A lease start now checks the plan, the live connection, the launch quota and ACP support (cases L6 to L9). A chain that started agents on a bridge with a disabled plan, or over the launch limit, stops doing so | This is what S-A asks for. Each refusal carries its reason in the placement failure and has a test (T25); E2E S5; the hand-off of T25 lists the four changes; the docs say why a lease can be refused (T26). T25 is in phase S, not phase 1, so the actions release does not carry this risk |
| S-K3 | **Mixed versions** of hub and bridge during rollout of the start command | Four combinations, all defined (6.12.6). The hub picks the wire form per bridge from one feature flag in one procedure; the old bytes are tested against `origin/main` on the hub, and the two old frames are tested through their adapters on the bridge. No rollout order is needed for T23 |
| S-K4 | **A bridge with T24 against a hub without T22** (self-hosted users and rollbacks do not follow a deploy order) | The hub announces start-begin in `bridge_ready`; without the flag the bridge keeps the manifest path, as on `origin/main`. A 404 without the hub's JSON error is retriable, never parked. Tests `test_fallback_legacy_hub_uses_manifest`, `test_bot_launch_legacy_hub_uses_manifest`, `test_start_begin_flag_reset_on_reconnect`, `test_start_begin_404_without_error_body_is_retriable` |
| S-K5 | **The grant calls `start_begin` without `reconfiguration_mutex`** while `start` holds the mutex but runs outside a unit of work. Unguarded, the two could write the same `run_count` twice (two launches of one generation) and `start` would erase the lease's `start_ref` | The save of step 10 is conditional on the `run_count`, `launch_epoch` and `configuration_revision` read in step 2 (6.12.2): one writer wins, the other gets `start_raced` and cancels its reservation. `test_start_begin_guarded_save`, `test_grant_race_with_manual_start` (100 rounds, exactly one generation and one launch per round). The grant's `agent_runtime_busy` and pending-stop checks stay |
| S-K6 | **A bridge-initiated start is refused while the hub's row is stale** (case L20): today the fallback launches regardless | Recovery is the hub's reaper (`REAPER_STALE_MS` (`src/hub/app/reaper.odin:27`) on a sweep every 20 s (`src/hub/app/reaper.odin:30`); about 110 s), not a frame from the bridge. The bridge retries past that window: 5 × 30 s for the fallback and bots, `retry` every 30 s for the pipeline. Cost: a restart after a bridge crash is up to about 2 minutes later than today. `test_reaped_row_accepts_start_begin`, `test_fallback_stale_row_recovers_after_reaper`, `test_event_stale_row_recovers_after_reaper`; E2E S9 |
| S-K7 | The launch quota now counts for leases, bots and the fallback. An owner near 2048 active instances sees refusals that did not exist | Intended (S-A). The refusal names the quota |
| S-K8 | A hub that is down for more than 24 hours loses the schedule fires older than that (before S2: 14 days) | A stale fire would run its action a day late. The definitions are untouched and fire again at their next time. Named in section 11 |
| S-K9 | A bridge whose clock differs from the hub's by more than about 9 minutes can forget a ledger entry too early and act twice on a redelivery | Only for a delivery redelivered at the very end of its life; the result is one extra notice or an `already_running` answer from start-begin, never a second generation. NTP keeps hosts far inside the margin |
| S-K10 | The relay's wake hook sits in the commit path of every transaction | It is one flag test per commit and a non-blocking signal. A missed signal costs at most the 1 s fallback wait |
| S-K11 | A redelivery for a lease whose child already failed no longer relaunches it; the lease waits for `on_dispatch_failed` and a new grant | Intended: the old relaunch reused a dead generation. **Assumption:** `on_dispatch_failed` returns the task to a state from which the matcher grants again; T25 verifies it first with `test_grant_redelivery_after_child_failed` and stops and reports if it does not |

Risks K13 and K17 of the v6 spec no longer exist: the prompt and the claim share a transaction (K13), and the bridge decides busy or idle at the moment it types (K17). With amendment S2, K6 (the lease start changes) is back as S-K2, and K9 (the fallback start is not converged) is closed by T24.

### 10.2 Assumptions of plan v7, section 10

| # | Assumption | Status | Evidence |
|---|---|---|---|
| 1 | cnats exposes work-queue retention, delayed nak and in-progress through the calls the wrapper would add | **Settled by execution** | A C program against the flake's toolchain (`nats.c` 3.13.0, `nats-server` 2.14.7), run with `nix develop -c sh run.sh`, 12 steps, 0 failures: facts N1 to N9 of 6.3.5, plus `natsMsg_NakWithDelay` (its argument order is message, delay, options). Sources and the full output are committed next to this document: `docs/plans/evidence/action-triggers-spec/check.c`, `run.sh` and `output.txt` (20 checks passed, 0 failed, including the delayed-nak measurement N10); T1 turns each step into a named scenario, so the proof is repeated in the repository |
| 2 | Splitting `relaunch_instance_locked` before its send leaves the ACP epoch and the transport freeze correct when the bridge, not the hub, sends the launch | **Settled by reading; proven by T22 tests** | The epoch is minted and the transport frozen inside the part that moves (`src/hub/service/agent/agent_service.odin:1147`, `src/hub/service/agent/agent_service.odin:1148`). Every epoch check compares against the row only: status frames (`src/hub/service/agent/agent_service.odin:1190`), the instance token (`src/hub/service/agent/agent_service.odin:563`). No check depends on the hub having sent `launch_agent`: the `cmd_launch_` id is generated (`src/hub/service/agent/agent_service.odin:1160`) and never stored or matched. One step is **not** in the moved part: `validate_frozen_runtime_transport` runs inside `send_frozen_instance_launch` (`src/hub/service/agent/agent_service.odin:424`); `start_begin` therefore calls it itself (6.12.2 step 8). Tests: `test_start_begin_acp_epoch`, `test_start_keeps_launch_bytes` |
| 3 | The bridge's instance-status frame after a failed launch releases the reservation taken at start-begin | **Settled by reading, with a condition; proven by T22 tests** | A `failed` status frame is applied only when its epoch matches (`src/hub/service/agent/agent_service.odin:1190`) and its sequence advances (`src/hub/service/agent/agent_service.odin:1195`); then the registry drops the active count (`src/hub/service/project/runtime_registry.odin:659`). When the frame does not pass those checks, the reservation still cannot leak: it expires one minute after it was taken (`src/hub/service/project/runtime_registry.odin:673`, swept at `src/hub/service/project/runtime_registry.odin:622`) and is dropped on disconnect. Tests: `test_start_begin_failed_status_releases_reservation`, `test_start_begin_reservation_expires` |

**Assumptions still open** (each names the task that verifies it first): `js_DeleteMsg` (6.3.5, T1); the conversation of a prepared instance (6.12.5, T22); the single column list of `agent_instances` (6.4.1, T22); finding F9 (T8); the old bridge's heartbeat handling (T14 step 5). Added by amendment S2: `validate_frozen_runtime_transport` reads only its argument (6.12.2, T22); `start_begin` joins an open unit of work, so a rolled-back grant restores the row (6.12.2, T25, `test_grant_rollback_cancels_ticket`); `on_dispatch_failed` leads to a new grant (T25, S-K11); the bridge has a periodic loop that can carry the stale-row retry (6.12.4, T24); one commit path in the SQLite layer (6.3.4, T1); `Nats-Schedule-TTL` on 2.14.7 (6.2.2, T1); the key names of the lease part of a launch object (6.12.6, T23).

## 11. Open questions

None. The eight questions of plan v7 are decided (section 2). U1, U2 and U4 of the v6 spec keep their defaults: a disabled action's open run is skipped when due; `fresh_per_run` stops the previous instance; the history keeps 200 runs and 30 days.

One deviation needs the user's eye when approving this spec, because it reads plan v7 in one of two possible ways: **D8** (a target pinned to one machine is routed to it even when it is offline).

**Amendment S2: points for the user's eye.** None blocks implementation; each states the choice the spec made.

| # | Point | The spec's choice |
|---|---|---|
| P1 | "Every start" has two named exceptions: the launch on the destination of a move to another bridge, and a provider test (6.12.7) | Left as they are. The move is a stop-then-launch state machine with its own recovery; it uses the one start command after T23, but keeps its own state write. A provider test is not an agent run |
| P2 | Phase S (T23 to T26) is outside phase 1 | Phase 1 carries only T22. The lease change (S-K2) is released on its own, after or with phase 1 |
| P3 | Mixed versions for T24 (S-K4) | No deploy order needed: the bridge uses start-begin only when the hub announces it in `bridge_ready`, and otherwise behaves as today |
| P4 | Fire life of 24 hours (S-K8) | The scaling report asked for "a short life"; 24 hours equals the life of a delivery |
| P5 | The byte limit on both streams (second half of scaling recommendation 4) | **Not specified.** With "discard old" a full `HEIM_EVENTS` would drop schedule definitions and schedules would stop silently; with "discard new" a full stream blocks the relay for every user (F21). It needs a decision on size and on which failure is preferred |
| P6 | A bridge-initiated start for an instance whose hub row is stale (case L20, S-K6) | The bridge retries for up to 150 s until the hub's reaper (about 110 s) has marked the row `unreachable`. A pipeline delivery in that state is answered `retry`, never `started`; on its final attempt it ends `failed` (`hub_row_live`) rather than `delivered`. The other reading (the bridge's "I have no process" overrides a live row at once) would change the live-row rule that S1 approved (D23) |

## 12. Deviations from plan v7

The plan is the approved design. Reading the code at `f56f13e1` and running the NATS check led to these changes. Each keeps the plan's intent.

| # | Plan v7 | This spec | Why |
|---|---|---|---|
| D1 | Table `event_deliveries` | Table `pipeline_deliveries`, type `domain.Pipeline_Delivery` | A table and a type with the plan's name already exist for the inbox's ack receipts (V12) |
| D2 | Frame `command_id` = the delivery id | `command_id` = `<delivery_id>:<attempt>` | The bridge dispatcher never runs a handler twice for one command id; it resends the cached answer (V13). A retry would get its own old `retry` answer back |
| D3 | A `final` attempt is never answered `accepted` | A `final` attempt always **ends** with a terminal answer; it is still preceded by the dispatcher's own `accepted` | The dispatcher sends `accepted` for every queued command before the handler runs (V13). Changing that for one command type would fork the dispatcher |
| D4 | The frame is `{type, command_id, attempt, final, delivery}` | Adds a top-level `agent_instance_id` | The bridge's per-instance ordering key reads that field from the frame; whether it finds a nested one was not established |
| D5 | The hub turns a result into ack/nak by holding the message | The reply subject, attempt and stream sequence are stored on the delivery row when `forwarded` is written; results use reply-subject calls | The answer arrives on another thread, possibly after a hub restart. T1 adds `nak_reply_delay`, `in_progress_reply`, `term_reply` next to the existing `ack_reply` |
| D6 | "The advisory stream also covers `HEIM_DELIVER`" (T1) | A separate advisory stream and consumer, owned by package `delivery` (T16) | The inbox's drain acks and drops every advisory that is not for `HEIM_EVENTS` (V9); sharing its consumer would lose them, and sharing its code would make `delivery` and `eventinbox` depend on each other |
| D7 | An exhausted delivery is closed from the advisory | Also deletes the message (`stream_delete_message`) and reads the delivery id from the stored message | Measured: an exhausted message stays in a work-queue stream, and the advisory carries only the stream sequence (N7) |
| D8 | OFF-1: a delivery is routed only to a bridge that is eligible at that moment. v7-Q7 and the E2E list: a prompt pinned to an offline machine waits up to 1 hour | A target that names exactly one machine is routed to it even when it is offline, and waits; every other target follows OFF-1 | The two statements conflict for a machine that is already offline at route time. This reading makes v7-Q7 true in that case too. The other reading (fail with `no_placement`, as v6 did) would make "wait 1 hour" apply only to a machine that drops after routing |
| D9 | The retry delay is "the bridge's `retry_after_ms`, bounded 10 s to 5 min"; "about 15 minutes with doubling delays" | The hub computes the doubling schedule (`retry_delay_ms`); the bridge's value can only lengthen a step | One place owns the schedule; a busy agent's bridge has no back-off of its own to report |
| D10 | `Agent_Port.create` creates the instance row stopped | New `agent.create_instance_stopped`: `prepare_instance`, cancel the reservation, save as `stopped` | No create-stopped path exists; `prepare_instance` always writes `launching` and needs a reservation (V17). Bots use the same prepare-then-cancel sequence |
| D11 | Start-begin returns "the launch descriptor with that generation" | It returns the launch command of `launch_command_json_full`, and the bridge passes it to the launch function unchanged | The manifest has no `run_count` (V16); the launch command is what makes a pipeline start byte-equal to a hub-sent `launch_agent` |
| D12 | The ledger knows `in_progress` and `done` | An `In_Progress` entry also records the intended effect (type, start, flow) | After a restart, "the instance runs" proves an earlier start but not an earlier notice. With the effect recorded, a start is never repeated and a notice is typed again at worst |
| D13 | Row 2 of the bridge table: an in-progress delivery with a live worker is answered `accepted` | Row 2 cannot occur in the handler | The dispatcher runs one command per instance at a time and answers `accepted` itself |
| D14 | Local states: running idle, running mid-turn, not running | Adds *booting* (answered `started` without typing) and *stopping* (retry) | A process that has not sent start-success cannot take a typed line; the start-success step tells it about the unread message |
| D15 | Run reasons added: `bridge_offline`, `start_failed`, `no_answer`, `bridge_too_old` | The same four on runs; delivery rows carry finer reasons (6.11.9) | The run history stays short; the delivery row keeps the detail for diagnosis |
| D16 | `HEIM_DELIVER` is ensured by "the relay" in T16 | In T1, with the wrapper | A `dlv.` outbox row published before its stream exists would block every event (F21); T16 and T9 can then run in parallel |
| D17 | A `[events]` notice for a busy agent "waits" | The inbox's "may be notified" condition is widened for pipeline bridges (any activity), and one open notice per instance absorbs later ones | Today the inbox does not call its callback for a busy agent at all |
| D18 | T19: the frame gains `cause`, `ref`, `prompt_text`; "a later cause joins the open delivery" | A table of pending prompts; one prompt per frame; the bridge reports `acted` after typing a prompt | A prompt that arrives while a frame is already out cannot be added to it; the bot's "acted" watch needs a channel message, which an action prompt does not have |
| D19 | T20: redelivery on reconnect is "deleted" | It is skipped for capable bridges and kept for the others | REQ-FLOW-4 keeps the old path |
| D20 | Pointers checked at `e96c2138` | Every pointer was re-checked at `f56f13e1`; section 14 | Main moved |
| D21 | Task branch state | The task branch equals local `main` (`503c1a1f`), which has diverged from `origin/main` (`f56f13e1`) by merges on both sides. The spec cites `origin/main` only | Implementers start from `origin/main`. This document is one new file and conflicts with nothing |
| D22 | Per-bridge consumer with MaxAckPending 16 as the flow limit | `MaxAckPending` 256; the hub enforces 16 frames in flight per bridge from the delivery rows; new column `retry_at` | Measured (N10): delayed naks hold `MaxAckPending` slots, so 16 busy agents would block a bridge's other deliveries for up to 15 minutes |
| D23 | Start-begin "opens the generation" for any row | It refuses a row that is already live (`already_running`), and clears the user stop only in the save that opens the generation | The live check of `start_instance` sits outside the code that is moved; a refused start must not erase the user's stop mark (v7-Q4 reads it) |
| D24 | The hub turns the answer into ack/nak on the thread that received it | Answers are queued and sent by the bridge's forwarder; acks are not awaited; a failed send is not nak'd | The WebSocket reader must not block on NATS or use a connection the supervisor may replace |

The deviations D1 to D20 of the v6 spec from plan v6 that concern reused parts still hold: purge rows instead of tombstones, the bots order, `target_missing` and `delivery_failed`, retiring a `once` trigger, reconcile by `data.rev`, relay poison handling, the three-state support value, `actions_001_reset.sql`, resume hints with C19 and C20, pruning on every path that ends a run, and `placement.bridge_status_online` for callers that do not decide a launch.

### 12.1 Changes made by amendment S2 to the text approved as S1

| # | S1 | S2 | Why |
|---|---|---|---|
| A1 | Start-begin is one seam for pipeline starts; lease dispatch, the fallback, bots and the manual starts keep their own code (non-goals, section 2.1, 6.12.3) | Every start opens its generation in `start_begin`; `relaunch_instance_locked` and the lease's own write are deleted; the fallback and bots call start-begin (6.12) | S-A, S-C |
| A2 | `relaunch_prepare_locked` and `start_begin_for_delivery(…, delivery_id)`; column `start_delivery_id`; request body `{"delivery_id"}` | `start_begin` with a `Start_Request` and a `Start_Ticket`; `start_begin_for_bridge(…, ref)`; column `start_ref`; request body `{"ref"}` | The procedure serves callers that have no delivery: a lease, a bot attempt, a fallback wake |
| A3 | `validate_frozen_runtime_transport` after the save; on an error the row is marked `failed` | Before the save, on the in-memory row; a refusal writes nothing (with an Assumption and a fallback to S1's order) | "A refused start writes nothing" then holds for every case, also inside a lease grant, where a `failed` row would be rolled back anyway |
| A4 | `create_instance_stopped` keeps the `run_count` that `prepare_instance` wrote (1) | It writes `run_count` 0; `start_begin` makes the first bump | One bump per start; the first launch still carries 1, and finding F14 (c) closes |
| A5 | Two wire commands; merging them is a non-goal | One command `start_agent` behind `start_agent_v1`; the old names stay for old bridges | S-B |
| A6 | T16 owns start-begin | T22 owns it; T16 keeps the pipeline. T17 and T10 depend on T22. New tasks T22 to T26, new phase S | S-D: phase 1 stays as parallel as before |
| A7 | F14 gaps are filed as issues by T21 | Closed: (a), (c) by T25, (b) by T22 | S-A |
| A8 | K9: the three notice callers keep the manifest GET | They call start-begin when the hub announces it in `bridge_ready` (T24); the manifest path stays only for an older hub | S-C |
| A9 | Ledger: flat 48 hours, `expires_at` informational on the bridge | Entry life = `expires_at` + 10 minutes; `expires_at` is load-bearing | Scaling recommendation 1 |
| A10 | Relay: one row per pass, 1 s idle sleep (unchanged from `origin/main`) | Woken on commit; up to 64 rows per pass | Scaling recommendation 2 |
| A11 | `delivery.prune` only at hub start and NATS reconnect; no index for it | Also when a delivery becomes final, at most hourly; index `pipeline_deliveries_closed` | Scaling recommendation 3 |
| A12 | Fires stay 14 days | `Nats-Schedule-TTL: 24h` on definitions and deferral rows, with a delete-after-commit fallback | Scaling recommendation 4 (first half; the byte limit is point P5 of section 11) |
| A13 | `triggers_match(owner, event_type)`; index on two columns | `triggers_match(owner, event_type, subject)`; column `match_key`; index on three columns | Scaling recommendation 5, without naming a kind in the matcher |
| A14 | No statement about lookups | Section 6.16, indexes `action_runs_due` and `pipeline_deliveries_expiry`, a query-plan test | The user's request of 2026-11-22 |
| A15 | Pointers checked at `f56f13e1` | The pointers S2 added or touched were checked at `99879b7b`; section 14.1 | Main moved |
| A16 | A bridge reports one new feature | Two features, independent: `event_pipeline_v1` (T17) and `start_agent_v1` (T23). A lease uses the pipeline only with both | The start command can roll out without the pipeline, and the reverse |
| A17 | Start-begin's `already_running` is answered `succeeded`, `started` (V-K20, D23) | `started` only with a local process; otherwise `retry`, and `failed` (`hub_row_live`) on the final attempt | Review of S2: with a stale row nothing would ever act on the delivery, yet its run was closed as delivered |
| A18 | Idempotency only while the row is `launching` | A reference is reused in any live status; `start_reuse` for repeats that must never start; the save of the opening write is conditional | Review of S2: a redelivery could open a second generation on a booting child, and a grant could race a manual start |

## 13. Glossary

| Term | Meaning |
|---|---|
| Action | A prompt, a target and 0 to 16 triggers, owned by one user |
| Trigger | A condition that makes an action run: kind `schedule` or kind `event` |
| Effective trigger | An enabled trigger of an enabled action |
| Occurrence | One event that matched one trigger |
| Run | The row in `action_runs` for one occurrence |
| Open run | A run in state `queued`, `deferred` or `routed` |
| Fire | The message nats-server publishes when a schedule is due |
| Definition | The message on `sched.def.<trigger_id>` that tells nats-server the schedule |
| Purge row | An outbox row that makes the relay purge a definition subject |
| Deferral | Holding a run until the action's minimum interval has passed |
| Reconcile | Making the definitions in the stream equal the effective schedule triggers |
| Producer | Code that publishes events through `event_outbox` |
| Matcher | The hub consumer that turns events into runs |
| Router | The hub code that turns a due run into a stored prompt and a routed delivery |
| Delivery | One row of `pipeline_deliveries` and one message on `HEIM_DELIVER`: "tell this instance on this bridge" |
| Kind | What a delivery carries: `prompt`, `notice`, `bot` or `lease` |
| Forwarder | The hub thread that sends one bridge's deliveries over the WebSocket |
| Forward gate | The check of the delivery row before each forward |
| Sink | A flow's callbacks for the result of its deliveries |
| Executor | The bridge code that acts on a delivery |
| Ledger | The bridge's persisted record of deliveries it handled |
| Attempt | One JetStream delivery of a message, 1 to 8; the last one is `final` |
| Outcome | What the bridge did: `started`, `notified` or `accepted` |
| Start-begin | `start_begin` on the hub: the one procedure that opens a new run generation before a launch (6.12.2). Also the bridge's request that calls it (`POST …/start-begin`) |
| Hub-initiated, bridge-initiated | Who asked for a start. Hub-initiated: the launch command travels in `start_agent`. Bridge-initiated: the bridge fetches it with the start-begin request |
| Start reference | The key that makes a repeated start-begin return the same generation: a delivery id, a lease id, `bot_<attempt>` or `fb_<instance>_<n>` |
| Start command | `start_agent`: the one hub → bridge command that starts, nudges and stops agents of one chain on one bridge (6.12.6) |
| Ticket | What `start_begin` returns: the saved row, the command id and the launch reservation |
| Generation | `run_count` of an instance: one number per launch |
| Placement rule | `(bridge, provider, model)`, each a value or `*` |
| Candidate | A launchable `(bridge, provider, model)` |
| Selector | The strategy that picks one candidate from the ordered list |
| Capable bridge | A bridge whose hello lists `event_pipeline_v1` |
| Unit of work | One SQLite transaction (`iface.Unit_Of_Work`) |
| Bridge | The program on a user's machine that runs agent processes |
| Instance | One agent process record on one bridge (`Agent_Instance`) |
| User stop | `stopped_by = "user"`: the user stopped the instance. Shown in the UI; the pipeline does not consult it, and start-begin clears it |
| Support state | Whether the connected nats-server can run schedules (6.3.3) |

## 14. Evidence index

Every `path:line` reference of this document, with the text found at that line in `origin/main` `f56f13e1`. To re-check: `git show origin/main:<path> | sed -n '<line>p'`. Long lines are cut at 80 characters; `|` is escaped and a backtick is shown as `'`.

| Path | Line | Source text |
|---|---|---|
| `SELF_HOSTING.md` | 378 | `nats:2.11 --config /etc/nats/server.conf` |
| `docs/plans/events-jetstream-spec.md` | 26 | `\| D6 \| **Events carry no end-to-end-encrypted content** (vault rule). The envelo` |
| `flake.nix` | 429 | `nats = pkgs.stdenv.mkDerivation {` |
| `src/bridge/action_scheduler.odin` | 87 | `action_scheduler_days_from_civil :: proc(y_in, m, d: int) -> int {` |
| `src/bridge/action_scheduler.odin` | 117 | `action_scheduler_format_rfc3339_utc :: proc(ms: i64) -> string {` |
| `src/bridge/agent_lifecycle.odin` | 26 | `bridge_agent_lifecycle_enter :: proc(instance_id:string)->^Bridge_Agent_Lifecycl` |
| `src/bridge/agent_token_store.odin` | 155 | `bridge_agent_token_store_path :: proc() -> string {` |
| `src/bridge/agent_wake.odin` | 111 | `bridge_wake_gate :: proc(st: Bridge_Wake_State, has: bool, now_ms: i64, unpark :` |
| `src/bridge/agent_wake.odin` | 146 | `bridge_provider_runnable :: proc(provider, model: string) -> bool {` |
| `src/bridge/agent_wake.odin` | 205 | `bridge_task_wake_if_needed :: proc(instance_id: string, now: i64, deadline_ns: i` |
| `src/bridge/agent_wake.odin` | 208 | `// Activity is checked UNDER the wake mutex (lock order: wake ->` |
| `src/bridge/agent_wake.odin` | 263 | `bridge_task_wake_record_result :: proc(instance_id: string, generation: u64, ok:` |
| `src/bridge/agent_wake.odin` | 299 | `bridge_wake_fetch_enriched_launch_json :: proc(instance_id, command_id: string, ` |
| `src/bridge/bot_delivery.odin` | 69 | `req := httpc.Request{method = .POST, url = bridge_hub_url(), path = {"api", "v1"` |
| `src/bridge/bot_delivery.odin` | 77 | `bridge_bot_launch_via_descriptor :: proc(instance_id, command_id: string) -> (ok` |
| `src/bridge/bot_delivery.odin` | 95 | `bridge_bot_busy_reason :: proc() -> (reason: string, busy: bool) {` |
| `src/bridge/bot_delivery.odin` | 102 | `bridge_bot_handle_deliver :: proc(command_json: string) -> string {` |
| `src/bridge/bot_delivery.odin` | 113 | `if _, exists := bridge_bot_workers[frame.attempt_id]; exists do return bridge_co` |
| `src/bridge/bot_delivery.odin` | 199 | `bridge_bot_run :: proc(w: ^Bridge_Bot_Worker) {` |
| `src/bridge/bot_delivery.odin` | 339 | `bridge_bot_ready :: proc(snap: Bridge_Runtime_Instance) -> bool {` |
| `src/bridge/bot_delivery.odin` | 349 | `return bridge_pty_host_deliver_to_agent(instance_id, "task_nudge", "bot", "", ""` |
| `src/bridge/credential_state.odin` | 821 | `bridge_refresh_after_publish :: proc() {` |
| `src/bridge/hub_command_dispatch.odin` | 121 | `BRIDGE_DISPATCH_LIFECYCLE_LIMIT :: 32` |
| `src/bridge/hub_command_dispatch.odin` | 245 | `bridge_command_spec :: proc(command_type: string) -> (Bridge_Command_Spec, bool)` |
| `src/bridge/hub_command_dispatch.odin` | 270 | `case "launch_agent", "launch_provider_test", "wake_agent":` |
| `src/bridge/hub_command_dispatch.odin` | 276 | `case "bot_deliver":` |
| `src/bridge/hub_command_dispatch.odin` | 408 | `case "bot_deliver", "launch_agent", "launch_provider_test", "stop_agent", "agent` |
| `src/bridge/hub_command_dispatch.odin` | 584 | `_ = bridge_hub_send(conn, cached)` |
| `src/bridge/hub_command_dispatch.odin` | 634 | `accepted := bridge_command_result_json(command_id, "accepted", "")` |
| `src/bridge/hub_command_dispatch.odin` | 774 | `bridge_command_worker_deadline_ns :: proc(conn: ^ws.Connection) -> i64 {` |
| `src/bridge/hub_runtime_client.odin` | 115 | `BRIDGE_STOP_INTENT_TTL_MS :: 15_000` |
| `src/bridge/hub_runtime_client.odin` | 501 | `bridge_action_scheduler_connection_changed()` |
| `src/bridge/hub_runtime_client.odin` | 1006 | `bridge_hub_handle_command :: proc(conn: ^ws.Connection, text: string) {` |
| `src/bridge/hub_runtime_client.odin` | 1033 | `schedules_version := extract_json_int(text, "schedules_version", 0)` |
| `src/bridge/hub_runtime_client.odin` | 1210 | `if type == "notify_agent_message" {` |
| `src/bridge/hub_runtime_client.odin` | 1225 | `ok := bridge_rollover_queue_notice(instance_id, sender) \|\| bridge_pty_host_deliv` |
| `src/bridge/hub_runtime_client.odin` | 2496 | `bridge_hub_handle_wake_agent :: proc(conn: ^ws.Connection, text: string) {` |
| `src/bridge/hub_runtime_client.odin` | 2676 | `bridge_wake_report_failed_status :: proc(conn: ^ws.Connection, instance_id: stri` |
| `src/bridge/hub_runtime_client.odin` | 2690 | `bridge_wake_launch_command_json :: proc(command_id, instance_id, task_id, role, ` |
| `src/bridge/hub_runtime_client.odin` | 2749 | `bridge_runtime_launch_agent :: proc(command_id, command_json: string, deadline_n` |
| `src/bridge/hub_runtime_client.odin` | 3565 | `bridge_runtime_instance_snapshot :: proc(instance_id: string) -> (Bridge_Runtime` |
| `src/bridge/hub_runtime_client.odin` | 3978 | `bridge_runtime_status_active :: proc(runtime_status: string) -> bool {` |
| `src/bridge/hub_runtime_client.odin` | 4337 | `Bridge_Command_Runtime_Status :: struct {` |
| `src/bridge/hub_runtime_client.odin` | 4360 | `Bridge_Command_Result_Wire :: struct {` |
| `src/bridge/hub_runtime_client.odin` | 4373 | `bridge_command_result_wire :: proc(command_id, status, runtime_status: string) -` |
| `src/bridge/hub_runtime_client.odin` | 4380 | `bridge_command_result_json :: proc(command_id, status, runtime_status: string) -` |
| `src/bridge/hub_runtime_client.odin` | 4616 | `BRIDGE_RUNTIME_FEATURES := [?]string{"capture_agent_pane", "get_agent_pane", "in` |
| `src/bridge/main.odin` | 265 | `bridge_agent_wake_init()` |
| `src/bridge/main.odin` | 278 | `bridge_hub_runtime_start()` |
| `src/bridge/main.odin` | 280 | `bridge_action_scheduler_start()` |
| `src/bridge/pty_host_runtime.odin` | 744 | `return strings.concatenate({"New message from ", s, " \u2014 run '" + agent_runt` |
| `src/bridge/pty_host_runtime.odin` | 794 | `bridge_pty_host_deliver_message :: proc(socket, instance, sender: string) -> boo` |
| `src/bridge/pty_host_runtime.odin` | 850 | `bridge_pty_host_deliver_to_agent :: proc(instance, kind, sender, task_id, target` |
| `src/bridge/result_error.odin` | 56 | `bridge_cause_wire_error :: proc(cause, message: string, retry_after_ms: i64 = 0,` |
| `src/bridge/retry_journal.odin` | 31 | `bridge_retry_journal_path :: proc() -> string {` |
| `src/bridge/retry_journal.odin` | 114 | `bridge_retry_atomic_write :: proc(path: string, bytes: []byte) -> bool {` |
| `src/bridge/startup_readiness.odin` | 377 | `bridge_startup_confirm_spawned :: proc(socket, instance_id: string, run_count: i` |
| `src/bridge/vault_prune.odin` | 29 | `bridge_prune_verdict :: proc(sent: bool, status: int) -> Prune_Verdict {` |
| `src/bridge/vault_prune.odin` | 113 | `resp, err := bridge_hub_http_send_alloc({method = .GET, url = bridge_hub_url(cfg` |
| `src/contracts/bot_wire.odin` | 31 | `Bot_Deliver_Wire :: struct {` |
| `src/ctl/hub_mode.odin` | 42 | `if resource == "actions" \|\| resource == "action" \|\| resource == "scheduled-promp` |
| `src/ctl/hub_mode.odin` | 534 | `ctl_hub_actions :: proc(hub: Ctl_Hub, tokens, args: []string) {` |
| `src/ctl/hub_mode.odin` | 662 | `if resource == "actions" \|\| resource == "action" \|\| resource == "scheduled-promp` |
| `src/ctl/main.odin` | 143 | `if cmd[0] == "actions" \|\| cmd[0] == "action" \|\| cmd[0] == "scheduled-prompts" \|\|` |
| `src/hub/app/mcp_chain_create.odin` | 15 | `mcp_create_chain :: proc(ctx:rawptr,raw:string,view:mcp.Access_View,args:mcp.Con` |
| `src/hub/app/mcp_task_mutations.odin` | 38 | `mcp_task_target :: proc(g:^App_Graph,owner:domain.User_ID,chain:domain.Task_Chai` |
| `src/hub/app/mcp_task_mutations.odin` | 56 | `provider,model:=tc.fleet_model_on_bridge(row,bridge_id)` |
| `src/hub/app/reaper.odin` | 255 | `reaped := agent_service.reap_stale_instances(&graph.agents, REAPER_STALE_MS)` |
| `src/hub/app/thread_spawn_guard_test.odin` | 22 | `@(test)` |
| `src/hub/app/wiring.odin` | 1135 | `http.router_add(&graph.router, "GET", "/api/v1/bridge/agent-instances/*/bootstra` |
| `src/hub/app/wiring.odin` | 1152 | `http.router_add(&graph.router, "GET", "/api/v1/bridge/update-catalog", rawptr(&g` |
| `src/hub/app/wiring.odin` | 1357 | `event_inbox_notice :: proc(` |
| `src/hub/app/wiring.odin` | 1367 | `if !found \|\| string(inst.owner_user_id) != owner \|\| inst.agent_id != agent \|\| in` |
| `src/hub/app/wiring.odin` | 1389 | `line := fmt.tprintf("[events] %d new event(s) — run ham-ctl events next", count)` |
| `src/hub/app/wiring.odin` | 1406 | `event_inbox_wake_guard :: proc(ctx: rawptr) -> domain.Domain_Error {` |
| `src/hub/app/wiring.odin` | 1412 | `if inst.stopped_by != "" \|\| inst.runtime_status != "stopped" do return domain.do` |
| `src/hub/domain/bridge.odin` | 10 | `Bridge :: struct {` |
| `src/hub/domain/event_outbox.odin` | 5 | `Event_Outbox_Row :: struct {` |
| `src/hub/domain/event_subscription.odin` | 22 | `Event_Delivery :: struct {` |
| `src/hub/domain/experiment.odin` | 12 | `ACTIONS_EXPERIMENT_KEY :: "actions"` |
| `src/hub/domain/experiment.odin` | 13 | `BOTS_EXPERIMENT_KEY :: "bots"` |
| `src/hub/platform/clock.odin` | 16 | `clock_now :: proc(clock: ^Clock) -> string {` |
| `src/hub/platform/clock.odin` | 122 | `rfc3339_to_unix_ms :: proc(s: string) -> (i64, bool) {` |
| `src/hub/platform/ids.odin` | 13 | `generate_id :: proc(generator: ^ID_Generator, prefix: string) -> string {` |
| `src/hub/repository/iface/agent_repo.odin` | 105 | `agent_get_support :: proc(repo: ^Agent_Repository, agent_id, bridge_id: string) ` |
| `src/hub/repository/iface/content_repo.odin` | 91 | `content_mark_messages_read :: proc(r: ^Content_Repository, owner: domain.User_ID` |
| `src/hub/repository/iface/event_outbox_repo.odin` | 22 | `append:         proc(ctx: rawptr, row: domain.Event_Outbox_Row) -> domain.Domain` |
| `src/hub/repository/iface/event_outbox_repo.odin` | 25 | `backlog:        proc(ctx: rawptr) -> (i64, domain.Domain_Error),` |
| `src/hub/repository/iface/repos.odin` | 3 | `Repositories :: struct {` |
| `src/hub/repository/iface/unit_of_work.odin` | 22 | `Unit_Of_Work :: struct {` |
| `src/hub/repository/iface/unit_of_work.odin` | 46 | `unit_of_work_begin :: proc(factory: ^Unit_Of_Work_Factory) -> (Unit_Of_Work, boo` |
| `src/hub/repository/sqlite/event_outbox_repo.odin` | 54 | `"SELECT outbox_seq,event_id,owner_user_id,subject,envelope_json,headers_json,cre` |
| `src/hub/repository/sqlite/event_subscription_repo.odin` | 362 | `'SELECT ai.agent_instance_id,ai.bridge_id,ai.runtime_status,ai.activity_status,a` |
| `src/hub/repository/sqlite/migrations.odin` | 722 | `MIGRATION_233_EXTENSION_VERSION_SYNC :: #load("migrations/233_extension_version_` |
| `src/hub/repository/sqlite/migrations.odin` | 726 | `migration_order :: [?]string {` |
| `src/hub/repository/sqlite/migrations.odin` | 973 | `"233_extension_version_sync_0_5_71.sql",` |
| `src/hub/repository/sqlite/migrations.odin` | 1483 | `if !upgrade_scheduled_prompts_schema(conn) do return false, domain.domain_error(` |
| `src/hub/repository/sqlite/migrations.odin` | 1506 | `migration_sql :: proc(name, migrations_dir: string) -> string {` |
| `src/hub/repository/sqlite/migrations.odin` | 2006 | `upgrade_scheduled_prompts_schema :: proc(conn: ^Conn) -> bool {` |
| `src/hub/repository/sqlite/migrations.odin` | 2027 | `upgrade_actions_schema :: proc(conn: ^Conn) -> bool {` |
| `src/hub/repository/sqlite/migrations/events_004_delivery.sql` | 3 | `CREATE TABLE event_deliveries (` |
| `src/hub/repository/sqlite/tx.odin` | 92 | `new_unit_of_work_factory :: proc(factory: ^SQLite_Unit_Of_Work_Factory, conn: ^C` |
| `src/hub/service/agent/agent_service.odin` | 24 | `reconfiguration_mutex: sync.Mutex,` |
| `src/hub/service/agent/agent_service.odin` | 346 | `prepare_instance :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, ` |
| `src/hub/service/agent/agent_service.odin` | 386 | `instance := domain.Agent_Instance{runtime_transport=transport,launch_epoch=runti` |
| `src/hub/service/agent/agent_service.odin` | 424 | `if err:=validate_frozen_runtime_transport(service,inst);err.code!=.None do retur` |
| `src/hub/service/agent/agent_service.odin` | 431 | `create_provider_test_instance :: proc(service: ^Agent_Service, auth: contracts.A` |
| `src/hub/service/agent/agent_service.odin` | 537 | `supported_bridge_count_for_agent :: proc(service: ^Agent_Service, agent: domain.` |
| `src/hub/service/agent/agent_service.odin` | 563 | `if token != expected do return {}, {}, false, domain.domain_error(.Unauthenticat` |
| `src/hub/service/agent/agent_service.odin` | 582 | `if inst.runtime_status == "stopped" \|\| inst.runtime_status == "stopping" \|\| inst` |
| `src/hub/service/agent/agent_service.odin` | 842 | `stop_instance :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, ins` |
| `src/hub/service/agent/agent_service.odin` | 856 | `if strings.has_prefix(reason, "user") && inst.stopped_by != STOPPED_BY_USER {` |
| `src/hub/service/agent/agent_service.odin` | 878 | `restart_instance :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, ` |
| `src/hub/service/agent/agent_service.odin` | 888 | `clear_user_stop :: proc(service: ^Agent_Service, inst: domain.Agent_Instance) ->` |
| `src/hub/service/agent/agent_service.odin` | 901 | `start_instance :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, in` |
| `src/hub/service/agent/agent_service.odin` | 906 | `if !ok do return domain.Agent_Instance{}, false, err` |
| `src/hub/service/agent/agent_service.odin` | 912 | `inst = clear_user_stop(service, inst)` |
| `src/hub/service/agent/agent_service.odin` | 1126 | `relaunch_instance_locked :: proc(service: ^Agent_Service, auth: contracts.Auth_C` |
| `src/hub/service/agent/agent_service.odin` | 1147 | `if err:=freeze_runtime_transport(service,&next);err.code!=.None do return {},fal` |
| `src/hub/service/agent/agent_service.odin` | 1148 | `next.launch_epoch=runtime_launch_epoch(service,next.runtime_transport,next.launc` |
| `src/hub/service/agent/agent_service.odin` | 1160 | `command_id := strings.concatenate({platform.generate_id(service.ids, "cmd_launch` |
| `src/hub/service/agent/agent_service.odin` | 1161 | `if sent, send_err := send_frozen_instance_launch(service, command_id, saved); !s` |
| `src/hub/service/agent/agent_service.odin` | 1190 | `if inst.launch_epoch != launch_epoch {` |
| `src/hub/service/agent/agent_service.odin` | 1195 | `if effective_state_seq <= inst.last_applied_seq {` |
| `src/hub/service/agent/agent_service.odin` | 1529 | `require_enabled_support :: proc(service: ^Agent_Service, auth: contracts.Auth_Co` |
| `src/hub/service/agent/agent_service.odin` | 1608 | `resolve_provider_model :: proc(service: ^Agent_Service, auth: contracts.Auth_Con` |
| `src/hub/service/agent/agent_service.odin` | 1635 | `validate_provider_model_intersection :: proc(service: ^Agent_Service, bridge_id,` |
| `src/hub/service/agent/agent_service.odin` | 1658 | `select_bridge_for_agent :: proc(service: ^Agent_Service, auth: contracts.Auth_Co` |
| `src/hub/service/agent/agent_service.odin` | 1758 | `runtime_expected_active :: proc(runtime_status: string) -> bool {` |
| `src/hub/service/agent/agent_service.odin` | 1781 | `launch_command_json_full :: proc(service: ^Agent_Service, command_id: string, in` |
| `src/hub/service/agent/agent_service.odin` | 1822 | `strings.write_string(&b, "\",\"run_count\":"); strings.write_string(&b, fmt.tpri` |
| `src/hub/service/agent/agent_service.odin` | 1891 | `wake_agent_command_json :: proc(command_id, chain_id: string, run: []Wake_Agent_` |
| `src/hub/service/agent/agent_service.odin` | 2244 | `bootstrap_manifest_json_for_bridge :: proc(service: ^Agent_Service, owner: domai` |
| `src/hub/service/agent/agent_service.odin` | 2247 | `if inst.bridge_id != bridge_id \|\| inst.owner_user_id != owner do return "", fals` |
| `src/hub/service/agent/agent_service.odin` | 2678 | `require_launch_bridge_enabled :: proc(service: ^Agent_Service, bridge: domain.Br` |
| `src/hub/service/agent/agent_service.odin` | 2722 | `validate_frozen_runtime_transport :: proc(service: ^Agent_Service, inst:domain.A` |
| `src/hub/service/agent/instance_reconfiguration.odin` | 56 | `bridge_feature_supported :: proc(bridge: domain.Bridge, feature: string) -> bool` |
| `src/hub/service/agent/instance_reconfiguration.odin` | 89 | `begin_instance_reconfiguration :: proc(service: ^Agent_Service, auth: contracts.` |
| `src/hub/service/agent/instance_reconfiguration.odin` | 447 | `validate_instance_message_configuration :: proc(service: ^Agent_Service, owner: ` |
| `src/hub/service/agent/instance_reconfiguration.odin` | 467 | `reconfiguration_validate_live_destination :: proc(service: ^Agent_Service, op: d` |
| `src/hub/service/bots/delivery.odin` | 56 | `bots_on_command_result :: proc(s: ^Bots_Service, bridge_id, command_id, status, ` |
| `src/hub/service/bots/delivery.odin` | 108 | `bots_send_attempt_locked :: proc(s: ^Bots_Service, a: domain.Bot_Delivery_Attemp` |
| `src/hub/service/bots/delivery.odin` | 177 | `if a.state == .Sent \|\| a.state == .Accepted do bots_send_attempt_locked(s, updat` |
| `src/hub/service/bots/gate.odin` | 27 | `bots_gate_on :: proc(repo: ^iface.Experiment_Repository, owner_user_id: string) ` |
| `src/hub/service/bots/inbound.odin` | 88 | `delivery_on_inbound :: proc(s: ^Bots_Service, bot_id: string, now_ms: i64, fresh` |
| `src/hub/service/bots/inbound.odin` | 101 | `bots_delivery_on_inbound_locked :: proc(s: ^Bots_Service, bot_id: string, now_ms` |
| `src/hub/service/bots/placement.odin` | 18 | `bots_validate_placement :: proc(s: ^Bots_Service, owner: string, rows: []domain.` |
| `src/hub/service/bots/placement.odin` | 42 | `bots_candidate_rank :: proc(policy: []domain.Bot_Placement_Candidate, bridge_id,` |
| `src/hub/service/bots/placement.odin` | 50 | `Ranked_Bot_Candidate :: struct {` |
| `src/hub/service/bots/placement.odin` | 55 | `bots_rank_before :: proc(a, b: Ranked_Bot_Candidate) -> bool {` |
| `src/hub/service/bots/placement.odin` | 64 | `bots_expand_candidates :: proc(s: ^Bots_Service, bot: domain.Bot, policy: []doma` |
| `src/hub/service/bots/placement.odin` | 110 | `bots_bridge_capable :: proc(b: domain.Bridge) -> bool {` |
| `src/hub/service/bots/placement.odin` | 114 | `bots_select_bridge :: proc(s: ^Bots_Service, bot: domain.Bot, delivery: domain.B` |
| `src/hub/service/bots/supervisor.odin` | 78 | `bots_dispatch_locked :: proc(s: ^Bots_Service, bot: domain.Bot, d: domain.Bot_De` |
| `src/hub/service/bots/supervisor.odin` | 104 | `inst, generation, prepared, prepare_err := agent_service.prepare_instance(s.agen` |
| `src/hub/service/bots/supervisor.odin` | 109 | `project_service.bridge_runtime_instance_cancel_reservation(s.registry, inst.brid` |
| `src/hub/service/bridge/bridge_service.odin` | 605 | `revoke_bridge :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context, br` |
| `src/hub/service/bridge_runtime/bridge_runtime.odin` | 66 | `if !project_service.bridge_runtime_registry_has_live(registry, command.bridge_id` |
| `src/hub/service/content/content_service.odin` | 87 | `Message_Input :: struct { body,artifact_ids_json,message_type,metadata_json: str` |
| `src/hub/service/content/content_service.odin` | 237 | `get_conversation_by_instance :: proc(s:^Content_Service, auth:contracts.Auth_Con` |
| `src/hub/service/content/content_service.odin` | 245 | `send_message :: proc(s:^Content_Service, auth:contracts.Auth_Context,cid:string,` |
| `src/hub/service/content/user_message.odin` | 11 | `persist_user_message :: proc(s:^Content_Service,auth:contracts.Auth_Context,cid:` |
| `src/hub/service/content/user_message.odin` | 15 | `if valid,e:=agent.validate_instance_message_configuration(s.agent_configuration_` |
| `src/hub/service/content/user_message.odin` | 31 | `deliver_user_message :: proc(s:^Content_Service,auth:contracts.Auth_Context,cid:` |
| `src/hub/service/eventinbox/filters.odin` | 9 | `filters :: proc(owner, chain, task, role: string) -> (result: []string, ok: bool` |
| `src/hub/service/eventinbox/filters.odin` | 43 | `subject_token :: proc(value: string) -> bool {` |
| `src/hub/service/eventinbox/notifications.odin` | 166 | `notify_pending :: proc(r: ^Runtime, rows: []domain.Event_Subscription, now: time` |
| `src/hub/service/eventinbox/notifications.odin` | 186 | `target.stopped_by == "" &&` |
| `src/hub/service/eventinbox/notifications.odin` | 282 | `if count > 0 && target.instance_id != "" && target.stopped_by == "" && (idle \|\| ` |
| `src/hub/service/eventinbox/runtime.odin` | 30 | `ADVISORY_STREAM :: "HEIM_EVENT_ADVISORIES"` |
| `src/hub/service/eventinbox/runtime.odin` | 31 | `ADVISORY_CONSUMER :: "hub_event_dlq"` |
| `src/hub/service/eventinbox/runtime.odin` | 232 | `prepare_advisories :: proc(conn: ^nats.Connection) -> bool {` |
| `src/hub/service/eventinbox/service.odin` | 12 | `Service :: struct {` |
| `src/hub/service/eventinbox/service.odin` | 17 | `notice: proc(ctx: rawptr, owner, agent: string, target: domain.Event_Notice_Targ` |
| `src/hub/service/eventrelay/relay.odin` | 26 | `stream_config :: proc() -> nats.Stream_Config {` |
| `src/hub/service/eventrelay/relay.odin` | 32 | `start :: proc(s: ^Service, factory: ^iface.Unit_Of_Work_Factory, options: nats.C` |
| `src/hub/service/eventrelay/relay.odin` | 55 | `entry :: proc(data: rawptr) {` |
| `src/hub/service/eventrelay/relay.odin` | 93 | `step_inner :: proc(s: ^Service) -> (bool, bool) {` |
| `src/hub/service/eventrelay/relay.odin` | 101 | `_, err = nats.stream_add(conn, cfg)` |
| `src/hub/service/eventrelay/relay.odin` | 131 | `_, pub_err := nats.publish(s.connection, row.subject, transmute([]byte)row.envel` |
| `src/hub/service/mcp/catalog_read.odin` | 27 | `catalog_bridge_eligible :: proc(b:domain.Bridge)->bool {return b.status==.Online` |
| `src/hub/service/project/project_service.odin` | 32 | `Runtime_Command :: struct {` |
| `src/hub/service/project/project_service.odin` | 82 | `bridge_command_send_runtime :: proc(sink: Bridge_Command_Sink, command: Runtime_` |
| `src/hub/service/project/runtime_registry.odin` | 419 | `bridge_runtime_registry_has_live :: proc(r: ^Bridge_Runtime_Registry, id: string` |
| `src/hub/service/project/runtime_registry.odin` | 622 | `if (!state.active \|\| state.reserved) && state.expires_ns <= now_ns { append(&key` |
| `src/hub/service/project/runtime_registry.odin` | 659 | `if exists && old.active && !active do _ = runtime_active_change(r, old.owner_id,` |
| `src/hub/service/project/runtime_registry.odin` | 673 | `state.expires_ns = now + i64(time.Minute)` |
| `src/hub/service/provider/provider_models.odin` | 41 | `apply_effective_models :: proc(repo: ^iface.Provider_Repository, bridge_id: stri` |
| `src/hub/service/provider/provider_service.odin` | 217 | `validate_launchable :: proc(` |
| `src/hub/service/provider/provider_service.odin` | 366 | `list_bridge_providers :: proc(service: ^Provider_Service, bridge_id: string) -> ` |
| `src/hub/service/taskchain/taskchain_service.odin` | 2171 | `fleet_model_on_bridge :: proc(fleet: domain.Task_Chain_Fleet, bridge_id: string)` |
| `src/hub/service/taskchain/taskchain_service.odin` | 2184 | `resolve_fleet_launch_model :: proc(service: ^Taskchain_Service, bridge_id, provi` |
| `src/hub/service/taskchain/taskchain_service.odin` | 2230 | `provider, model := fleet_model_on_bridge(fleet, out.bridge_id)` |
| `src/hub/service/taskchain/taskchain_service.odin` | 2237 | `rp, rm := resolve_fleet_launch_model(service, out.bridge_id, provider, model,out` |
| `src/hub/service/taskv2/catalog.odin` | 13 | `catalog_emit :: proc(` |
| `src/hub/service/taskv2/catalog.odin` | 65 | `headers_json  = '{"Nats-Rollup":"sub"}' if class == "state" else "{}",` |
| `src/hub/service/taskv2/catalog.odin` | 95 | `catalog_chain_state :: proc(` |
| `src/hub/service/taskv2/catalog.odin` | 234 | `catalog_work_finished :: proc(svc: ^Service, chain: domain.Task_Chain, outcome: ` |
| `src/hub/service/taskv2/dispatch.odin` | 45 | `if !bridge_online(svc, inst.bridge_id) && inst.runtime_status != "failed" && ins` |
| `src/hub/service/taskv2/dispatch.odin` | 76 | `stop_holder = bridge_online(svc, inst.bridge_id) && (instance_is_live(inst) \|\| i` |
| `src/hub/service/taskv2/dispatch.odin` | 178 | `on_dispatch_failed :: proc(svc: ^Service, lease_id, detail: string) {` |
| `src/hub/service/taskv2/dispatch_test.odin` | 143 | `selected,valid,validation_err:=agent.validate_provider_model_intersection(&svc,"` |
| `src/hub/service/taskv2/explicit_claims.odin` | 32 | `lease_claim_in_uow :: proc(svc:^Service,u:^Uow,auth:contracts.Auth_Context,input` |
| `src/hub/service/taskv2/explicit_claims.odin` | 120 | `lease_transfer_in_uow :: proc(svc:^Service,u:^Uow,auth:contracts.Auth_Context,in` |
| `src/hub/service/taskv2/lease.odin` | 77 | `grant_attempt_in_uow :: proc(svc: ^Service, u: ^Uow, req: Grant_Request, stoppin` |
| `src/hub/service/taskv2/lease.odin` | 119 | `if !bridge_online(svc, req.placement.bridge_id) do return {}, false, domain.doma` |
| `src/hub/service/taskv2/lease.odin` | 231 | `current.run_count += 1` |
| `src/hub/service/taskv2/lease.odin` | 507 | `if inst.runtime_status == "unreachable" && !bridge_online(svc, inst.bridge_id) d` |
| `src/hub/service/taskv2/lease.odin` | 680 | `if l.confirmed_at == "" {` |
| `src/hub/service/taskv2/lease.odin` | 888 | `if l.phase == domain.LEASE_PHASE_WAITING \|\| l.confirmed_at != "" \|\| l.delivery !` |
| `src/hub/service/taskv2/lease.odin` | 1104 | `bridge_online :: proc(svc: ^Service, bridge_id: string) -> bool {` |
| `src/hub/service/taskv2/matcher.odin` | 160 | `resolve_placement :: proc(ctx: ^Match_Context, task: domain.Task, fleet: domain.` |
| `src/hub/service/taskv2/matcher.odin` | 199 | `if !bridge_online(svc, ctx.coordinator.bridge_id) {` |
| `src/hub/service/taskv2/matcher.odin` | 328 | `pick_instance :: proc(svc: ^Service, u: ^Uow, ctx: ^Match_Context, task: domain.` |
| `src/hub/service/taskv2/matcher.odin` | 338 | `if inst.stopped_by == agent.STOPPED_BY_USER do return {}, false, "assigned insta` |
| `src/hub/service/taskv2/matcher.odin` | 679 | `if !bridge_online(svc, coord.bridge_id) {` |
| `src/hub/service/taskv2/matcher.odin` | 718 | `if !bridge_online(svc, placement.bridge_id) {` |
| `src/hub/service/taskv2/placement.odin` | 12 | `fleet_model_on_bridge :: proc(fleet: domain.Task_Chain_Fleet, bridge_id: string)` |
| `src/hub/service/taskv2/placement.odin` | 26 | `resolve_launch_model :: proc(agent_service: ^agent.Agent_Service, bridge_id, pro` |
| `src/hub/service/taskv2/placement_failures.odin` | 32 | `placement_problem :: proc(svc: ^Service, ctx: ^Match_Context, placement: Placeme` |
| `src/hub/service/taskv2/recheck.odin` | 109 | `if bridge := jsonx.extract_string(task.blocked_on_json, "bridge_id", "", true, c` |
| `src/hub/service/taskv2/recheck.odin` | 206 | `if bridge == "" \|\| !bridge_online(svc, bridge) do return ""` |
| `src/hub/service/taskv2/recheck.odin` | 304 | `} else if !bridge_online(svc, bridge) {` |
| `src/hub/service/taskv2/timers.odin` | 404 | `fire_grant_unconfirmed :: proc(svc: ^Service, u: ^Uow, t: Timer) -> Fire_Result ` |
| `src/hub/service/taskv2/wake.odin` | 27 | `effect_wake_lease :: proc(svc: ^Service, u: ^Uow, lease: domain.Task_Lease, task` |
| `src/hub/service/taskv2/wake.odin` | 146 | `flush_wakes :: proc(svc: ^Service, e: ^Effects) {` |
| `src/hub/transport/http/action_handlers.odin` | 19 | `Action_Handlers :: struct {` |
| `src/hub/transport/http/action_handlers.odin` | 136 | `validate_cron_expression :: proc(cron_expr: string) -> (bool, string) {` |
| `src/hub/transport/http/action_handlers.odin` | 512 | `run_action_handler :: proc(ctx: rawptr, req: Request) -> Response {` |
| `src/hub/transport/http/action_handlers.odin` | 596 | `bridge_list_actions_handler :: proc(ctx: rawptr, req: Request) -> Response {` |
| `src/hub/transport/http/action_handlers.odin` | 650 | `bridge_execute_action_handler :: proc(ctx: rawptr, req: Request) -> Response {` |
| `src/hub/transport/http/agent_action_handlers.odin` | 1326 | `agent_action_start_success_handler :: proc(ctx: rawptr, req: Request) -> Respons` |
| `src/hub/transport/http/agent_action_handlers.odin` | 1338 | `if expected < 0 \|\| (expected > 0 && expected != current.run_count) \|\| ((!has_gen` |
| `src/hub/transport/http/agent_action_handlers.odin` | 1387 | `if msg.direction == "user_to_agent" && msg.read_at == "" && msg.message_type != ` |
| `src/hub/transport/http/bot_handlers.odin` | 99 | `bot_placement_options_handler :: proc(ctx: rawptr, req: Request) -> Response {` |
| `src/hub/transport/http/bridge_auto_update_handlers.odin` | 15 | `bridge_auto_update_catalog_handler :: proc(ctx: rawptr, req: Request) -> Respons` |
| `src/hub/transport/http/bridge_handlers.odin` | 41 | `Bridge_Handlers :: struct {` |
| `src/hub/transport/http/bridge_handlers.odin` | 1889 | `if h.bots != nil do bots.bots_on_bridge_hello(h.bots, bridge.bridge_id)` |
| `src/hub/transport/http/bridge_handlers.odin` | 1999 | `taskv2.on_bridge_placement_changed(h.task_engine)` |
| `src/hub/transport/http/bridge_handlers.odin` | 2490 | `case "agent_instance_status":` |
| `src/hub/transport/http/bridge_handlers.odin` | 2552 | `case "session_projects_result", "auto_update_config_result", "provider_profile_o` |
| `src/hub/transport/http/bridge_handlers.odin` | 2556 | `if h.bots != nil && type == "command_result" && strings.has_prefix(command_id, "` |
| `src/hub/transport/http/bridge_handlers.odin` | 2557 | `status := jsonx.extract_string(text, "status", top_level_only = false, allocator` |
| `src/hub/transport/http/bridge_handlers.odin` | 2878 | `bridge_instance_bootstrap_handler :: proc(ctx: rawptr, req: Request) -> Response` |
| `src/hub/transport/http/content_handlers.odin` | 200 | `send_chat_message_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Conte` |
| `src/hub/transport/http/content_handlers.odin` | 371 | `restart_stopped_conversation_instance :: proc(h:^Content_Handlers, auth:contract` |
| `src/hub/transport/http/coordinator_wake.odin` | 288 | `if target.stopped_by == agent_service.STOPPED_BY_USER do return outcome` |
| `src/hub/transport/http/coordinator_wake.odin` | 299 | `restarted, restart_err := restart_stopped_conversation_instance(&ch, auth, cid)` |
| `src/hub/transport/http/experiment_rest_handlers.odin` | 184 | `require_experiment_enabled :: proc(repo: ^iface.Experiment_Repository, owner_use` |
| `src/hub/transport/http/router.odin` | 75 | `route_matches :: proc(pattern, path: string) -> bool {` |
| `src/hub/transport/http/taskchain_handlers.odin` | 2340 | `selected_provider, selected_model := taskchain_service.fleet_model_on_bridge(fle` |
| `src/lib/nats/adapter.c` | 71 | `int ham_nats_stream(ham_nats *h, int operation, const char *name,` |
| `src/lib/nats/adapter.c` | 83 | `cfg.Retention = js_LimitsPolicy;` |
| `src/lib/nats/adapter.c` | 100 | `int ham_nats_consumer_add(ham_nats *h, const char *stream, const char *durable,` |
| `src/lib/nats/adapter.c` | 109 | `cfg.DeliverPolicy = js_DeliverAll;` |
| `src/lib/nats/adapter.c` | 173 | `int ham_nats_metadata(natsMsg *msg, ham_metadata *out) {` |
| `src/lib/nats/ffi.odin` | 26 | `ham_nats_stream :: proc(conn: ^Connection, operation: c.int, name: cstring, subj` |
| `src/lib/nats/ffi.odin` | 27 | `ham_nats_consumer_add :: proc(conn: ^Connection, stream, durable: cstring, filte` |
| `src/lib/nats/nats.odin` | 23 | `Metadata :: struct {` |
| `src/lib/nats/nats.odin` | 35 | `Stream_Config :: struct {` |
| `src/lib/nats/nats.odin` | 44 | `Consumer_Config :: struct {` |
| `src/lib/nats/nats.odin` | 221 | `consumer_delete :: proc(conn: ^Connection, stream, durable: string) -> (err: Err` |
| `src/lib/nats/nats.odin` | 255 | `batch_destroy :: proc(batch: ^Batch) {ham_nats_batch_destroy(batch)}` |
| `src/lib/nats/nats.odin` | 282 | `message_metadata :: proc(msg: ^Message) -> (meta: Metadata, err: Error) {` |
| `src/lib/nats/nats.odin` | 288 | `ack :: proc(msg: ^Message) -> (err: Error) {` |
| `src/lib/nats/nats.odin` | 294 | `nak :: proc(msg: ^Message) -> Error {` |
| `src/lib/nats/nats.odin` | 299 | `term :: proc(msg: ^Message) -> Error {` |
| `src/lib/nats/nats.odin` | 324 | `message_reply :: proc(msg: ^Message) -> string {` |
| `src/lib/nats/nats.odin` | 330 | `ack_reply :: proc(conn: ^Connection, reply: string, timeout_ms: i64) -> Error {` |
| `src/lib/nats/nats.odin` | 336 | `stream_get :: proc(conn: ^Connection, stream: string, sequence: u64) -> (msg: ^M` |
| `src/lib/nats/nats.odin` | 382 | `stream_next :: proc(conn: ^Connection, stream, filter: string, start: u64) -> (m` |
| `src/lib/natstest/server.odin` | 17 | `start :: proc(extra_args: []string = nil) -> (server: Server, ok: bool) {` |
| `src/ui/components/actions/ActionDetail.tsx` | 92 | `const [runAction] = useRunActionMutation();` |
| `src/ui/components/actions/ActionListPage.tsx` | 269 | `const [runAction] = useRunActionMutation();` |
| `src/ui/components/chat/NewConversationPage.tsx` | 235 | `const preferredBridge = bridges.find((b: any) => b.bridge_id === prefs.bridge_id` |
| `src/ui/components/tasks/fleetSelection.ts` | 26 | `export function resolvedFleetProviderModel(` |
| `src/ui/components/workbench/AgentChatPane.tsx` | 526 | `function scheduleContextFromMetadata(metadata: any): {` |
| `src/ui/components/workbench/AgentChatPane.tsx` | 1988 | `function renderConversationMessageBody(message: ChatMessage, reveal?: StreamReve` |
| `src/ui/components/workbench/AgentChatPane.tsx` | 2089 | `className="my-2 flex w-full items-center gap-3"` |
| `src/ui/components/workbench/AgentChatPane.tsx` | 2137 | `if (message.messageType === 'action') {` |
| `src/ui/utils/bridgeLaunchOptions.ts` | 19 | `export function bridgeIsOnline(bridge: any): boolean {` |

### 14.1 References added or re-checked by amendment S2

The `path:line` references that amendment S2 added or moved, with the text found at that line in `origin/main` `99879b7b`. `src/hub/repository/sqlite/migrations.odin` grew by two migrations between the two commits, so its references in 4 and 6.4.1 were moved to the new lines; the rows of section 14 for its lines 726, 973, 1483, 1506, 2006 and 2027 are superseded by the rows here. All 331 references of this document resolve at `99879b7b`; for the 271 that section 14 lists, the text at that commit is identical to the text shown there.

| Path | Line | Source text |
|---|---|---|
| `src/bridge/action_scheduler.odin` | 1066 | `bridge_task_wake_if_needed(target_instance_id, now_ms, (now_ms + BRIDGE_OPERATIO` |
| `src/bridge/action_scheduler.odin` | 952 | `bridge_task_wake_if_needed(c.id, now_ms, (now_ms + BRIDGE_OPERATION_DEADLINE_MS)` |
| `src/bridge/agent_wake.odin` | 246 | `command_json, enrich_err, enrich_ok := bridge_wake_fetch_enriched_launch_json(in` |
| `src/bridge/agent_wake.odin` | 250 | `ok, detail, err = bridge_runtime_launch_agent(command_id, command_json, deadline` |
| `src/bridge/agent_wake.odin` | 60 | `bridge_task_status_notify_wake_local :: proc(instance_id: string) -> bool {` |
| `src/bridge/agent_wake.odin` | 74 | `Bridge_Wake_State :: struct {` |
| `src/bridge/bot_delivery.odin` | 84 | `command_json, fetch_err, fetched := bridge_wake_fetch_enriched_launch_json(insta` |
| `src/bridge/bot_delivery.odin` | 87 | `return bridge_runtime_launch_agent(command_id, command_json, deadline_ns)` |
| `src/bridge/hub_command_dispatch.odin` | 412 | `case "wake_agent", "task_status_changed_notify":` |
| `src/bridge/hub_command_dispatch.odin` | 519 | `if command_type == "wake_agent" {` |
| `src/bridge/hub_runtime_client.odin` | 1136 | `if type == "launch_agent" {` |
| `src/bridge/hub_runtime_client.odin` | 1145 | `ok, detail, launch_err := bridge_runtime_launch_agent(command_id, text, bridge_c` |
| `src/bridge/hub_runtime_client.odin` | 1314 | `ok := bridge_task_status_notify_wake_local(instance_id)` |
| `src/bridge/hub_runtime_client.odin` | 1351 | `ok := bridge_task_status_notify_wake_local(instance_id)` |
| `src/bridge/hub_runtime_client.odin` | 1452 | `if bridge_task_status_notify_wake_local(inst) {` |
| `src/bridge/hub_runtime_client.odin` | 2576 | `ok, detail, launch_err := bridge_runtime_launch_agent(syn_command_id, command_js` |
| `src/bridge/hub_runtime_client.odin` | 2594 | `ok, detail, launch_err := bridge_runtime_launch_agent(syn_command_id, command_js` |
| `src/bridge/hub_runtime_client.odin` | 2750 | `if !bridge_auto_update_launch_enter() do return false, "bridge is applying an au` |
| `src/bridge/hub_runtime_client.odin` | 3644 | `if !ok do return strings.clone("{}")` |
| `src/bridge/hub_runtime_client.odin` | 643 | `sync.atomic_store(&bridge_hub_features_update_supported, extract_json_bool(text,` |
| `src/bridge/hub_runtime_client.odin` | 671 | `sync.atomic_store(&bridge_hub_features_update_supported, false)` |
| `src/hub/app/mcp_chain_create.odin` | 45 | `inst,generation,prepared,perr:=agent.prepare_instance(&g.agents,principal,{` |
| `src/hub/app/mcp_runtime.odin` | 102 | `row,gen,ok,err:=agent.prepare_instance(&g.agents,principal,{agent_id=a.agent_id,` |
| `src/hub/app/mcp_runtime.odin` | 128 | `row,accepted,action_err:=agent.start_instance(&g.agents,principal,i.agent_instan` |
| `src/hub/app/reaper.odin` | 108 | `reaper_loop :: proc(graph: ^App_Graph) {` |
| `src/hub/app/reaper.odin` | 27 | `REAPER_STALE_MS :: 90_000` |
| `src/hub/app/reaper.odin` | 30 | `DEFAULT_REAPER_INTERVAL_SECONDS :: 20` |
| `src/hub/repository/sqlite/migrations.odin` | 1486 | `if !upgrade_scheduled_prompts_schema(conn) do return false, domain.domain_error(` |
| `src/hub/repository/sqlite/migrations.odin` | 1509 | `migration_sql :: proc(name, migrations_dir: string) -> string {` |
| `src/hub/repository/sqlite/migrations.odin` | 2010 | `upgrade_scheduled_prompts_schema :: proc(conn: ^Conn) -> bool {` |
| `src/hub/repository/sqlite/migrations.odin` | 2031 | `upgrade_actions_schema :: proc(conn: ^Conn) -> bool {` |
| `src/hub/repository/sqlite/migrations.odin` | 726 | `MIGRATION_235_EXTENSION_VERSION_SYNC :: #load("migrations/235_extension_version_` |
| `src/hub/repository/sqlite/migrations.odin` | 728 | `migration_order :: [?]string {` |
| `src/hub/repository/sqlite/migrations.odin` | 977 | `"235_extension_version_sync_0_5_72.sql",` |
| `src/hub/repository/sqlite/migrations/events_001_outbox.sql` | 12 | `CREATE INDEX event_outbox_pending ON event_outbox(outbox_seq) WHERE published_at` |
| `src/hub/service/agent/agent_service.odin` | 1097 | `reconfigure_instance :: proc(service: ^Agent_Service, auth: contracts.Auth_Conte` |
| `src/hub/service/agent/agent_service.odin` | 1118 | `relaunch_instance :: proc(service: ^Agent_Service, auth: contracts.Auth_Context,` |
| `src/hub/service/agent/agent_service.odin` | 1219 | `} else {` |
| `src/hub/service/agent/agent_service.odin` | 1461 | `reap_stale_instances :: proc(service: ^Agent_Service, stale_after_ms: i64) -> []` |
| `src/hub/service/agent/agent_service.odin` | 1620 | `validate_pinned_provider_model :: proc(service: ^Agent_Service, auth: contracts.` |
| `src/hub/service/agent/agent_service.odin` | 2697 | `freeze_runtime_transport :: proc(service: ^Agent_Service, inst: ^domain.Agent_In` |
| `src/hub/service/agent/agent_service.odin` | 2706 | `runtime_launch_epoch :: proc(service: ^Agent_Service, transport: string, legacy_` |
| `src/hub/service/agent/agent_service.odin` | 324 | `reserve_runtime_launch :: proc(service: ^Agent_Service, inst: domain.Agent_Insta` |
| `src/hub/service/agent/agent_service.odin` | 330 | `create_instance :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, i` |
| `src/hub/service/agent/agent_service.odin` | 423 | `send_frozen_instance_launch :: proc(service: ^Agent_Service, command_id: string,` |
| `src/hub/service/agent/instance_reconfiguration.odin` | 241 | `reconfiguration_launch_destination :: proc(service: ^Agent_Service, op: domain.I` |
| `src/hub/service/agent/instance_reconfiguration.odin` | 79 | `reconfiguration_require_idle :: proc(service: ^Agent_Service, instance_id: strin` |
| `src/hub/service/eventrelay/relay.odin` | 72 | `if !progress do wait = time.Second` |
| `src/hub/service/project/runtime_registry.odin` | 26 | `if limits.active_instances <= 0 do limits.active_instances = 16384` |
| `src/hub/service/taskv2/coordinator_wake.odin` | 15 | `// agent.stop_instance holds reconfiguration_mutex while it calls` |
| `src/hub/service/taskv2/dispatch.odin` | 191 | `start_solo_task_agent :: proc(svc: ^Service, auth: contracts.Auth_Context, task:` |
| `src/hub/service/taskv2/lease.odin` | 306 | `wake_reuses_live_child :: proc(inst: domain.Agent_Instance, needs_new_child: boo` |
| `src/hub/service/taskv2/matcher.odin` | 435 | `jit_prepare :: proc(svc: ^Service, u: ^Uow, ctx: ^Match_Context, fleet: domain.T` |
| `src/hub/service/taskv2/matcher.odin` | 449 | `inst, generation, ok, err := agent.prepare_instance(svc.agent_service, auth, inp` |
| `src/hub/service/taskv2/service.odin` | 164 | `Effects :: struct {` |
| `src/hub/service/taskv2/service.odin` | 407 | `cancel_reservations :: proc(svc: ^Service, e: ^Effects) {` |
| `src/hub/transport/http/agent_handlers.odin` | 344 | `inst, restarted, err := agent_service.restart_instance(h.agents, auth_ctx, path_` |
| `src/hub/transport/http/agent_handlers.odin` | 357 | `inst, started, err := agent_service.start_instance(h.agents, auth_ctx, path_part` |
| `src/hub/transport/http/bridge_handlers.odin` | 3367 | `strings.write_string(&b, ",\"" + contracts.BRIDGE_READY_FEATURES_UPDATE + "\":tr` |
| `src/hub/transport/http/taskchain_handlers.odin` | 2347 | `if relaunched_inst, relaunched, relaunch_err := agent_service.relaunch_instance(` |
