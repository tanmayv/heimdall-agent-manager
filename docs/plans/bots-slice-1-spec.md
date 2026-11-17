# Bots slice 1: implementation spec

**Status:** spec for implementation. Nothing in it is implemented yet.
**Branch:** all tickets land on `feat/bots`. Never commit to `main`.
**Base commit checked:** `71be91b1`. Every `path:line` reference below was read in that checkout. Paths are relative to the repository root. Section 25 lists each one with the symbol it points at, so a reviewer can re-check it mechanically.
**Sources:** the slice plan on `task_18e8e080f1f93aa6` (revision 2 `cmt_18e8e1de97424d51`, the experiment addendum `cmt_18e8e1e4760578a4`, and the hub/bridge split addendum `cmt_18e8e204adc54b9d`). The architecture plan on `task_18e8df0a464c4feb` is background only. **This document replaces both plans for implementers.** An implementer needs nothing else.

## 0. How to read this spec

- **MUST**, **MUST NOT** and **SHOULD** are normative. Everything else is explanation.
- Each name in this document (table, column, route, frame, field, flag, file, proc, constant) is fixed. Use it exactly as written.
- Section 21 lists the tickets. Each ticket names the sections it implements. A ticket is implementable from its own section plus the sections it references.
- Text marked **Assumption** has not been verified against the code. The named ticket MUST verify it first. If it is false, the ticket MUST stop and report to the coordinator.
- Section 23 lists open questions for the coordinator. None of them blocks a ticket: each has a stated default, and the default is what gets built.

## 1. Scope

### 1.1 What slice 1 delivers

A user who has turned on the `bots` experiment can:

1. create **one** bot in Settings > Bots, without choosing a machine or a model;
2. optionally restrict and rank the bridges, providers and models the bot may run on;
3. pair one Telegram private chat with the bot through a one-time link to a shared, hub-operated Telegram bot;
4. talk to the bot from Telegram. The bot can answer questions about the owner's task chains and tasks.

The hub stores each inbound message, picks a connected bridge and sends it one delivery. The bridge picks the provider and model, wakes or launches the bot, delivers the message, watches whether it is acted on, and retries locally with another candidate. When a bridge reports `exhausted`, disconnects or goes silent, the hub moves the bot to another bridge using the existing instance relocation. When no machine is available, the hub tells the user in Telegram and keeps the message.

### 1.2 Non-goals (MUST NOT be built in slice 1)

- NATS, an event inbox, attention or completion notifications, coordinator routing, webhooks.
- Review verdicts or any card action from Telegram.
- Discord, WhatsApp, group chats, channels, bring-your-own Telegram bot, more than one bot per user.
- Buttons, inline keyboards, media, files or voice in Telegram. Only plaintext text messages.
- Provider quota or rate-limit parsing. It is covered indirectly by the not-acted timers (section 14). Nothing parses `rate_limits` today: `src/ctl/extension/transcript_usage.odin:192-223` reads only token counts.
- Any change to scheduled Actions (`src/bridge/action_scheduler.odin`, `src/hub/transport/http/action_handlers.odin`).
- Several live instances sharing one conversation.
- Showing the Telegram transcript inside the agent conversation view.

### 1.3 Requirements

The requirements are taken from the slice plan after its addenda.

| ID | Requirement |
|---|---|
| REQ-S1-1 | A user has one bot, created without choosing a machine or model |
| REQ-S1-2 | A user can set allowed and preferred bridges and provider/models; the defaults allow all |
| REQ-S1-3 | The bot is an ordinary agent instance; context rollover and terminal streaming work unchanged |
| REQ-S1-4 | The hub chooses only the bridge. The bridge chooses provider and model, wakes or launches the bot, and delivers, with no user action |
| REQ-S1-5 | Relocation keeps the same conversation and Telegram thread |
| REQ-S1-6 | The bridge detects a message not acted on and retries with another local candidate. When it has none left it reports `exhausted` and the hub reroutes to another bridge. Each candidate and each bridge is tried at most once per message |
| REQ-S1-7 | With no candidate available the message is kept, the user is told, and it is delivered when a candidate returns |
| REQ-S1-8 | A user pairs one Telegram private chat through a one-time link and can disconnect it |
| REQ-S1-9 | A Telegram message is stored before Telegram is acknowledged and reaches the bot once (dedupe on `update_id`) |
| REQ-S1-10 | The bot can send text and links only to its owner's paired chat |
| REQ-S1-11 | The bot answers status questions from the owner's chains and tasks |
| REQ-S1-12 | Chat providers are reached only through a provider-neutral adapter interface |
| REQ-S1-13 | With the `bots` experiment off (the default), no bot API, CLI verb, background loop (the Telegram poller included) or UI is active, and existing behaviour is unchanged |
| REQ-S1-14 | With it on, a "Bots" section in Settings holds bot creation, placement settings and the Telegram connection |
| REQ-S1-15 | Every delivery has a hub-stored state and a deadline; open deliveries are re-sent when a bridge reconnects |
| REQ-S1-16 | A bridge without bot support is never selected (the capability is reported at hello) |

Section 22 maps each requirement to the spec sections and tickets that cover it.

## 2. Decisions on the six open items

### D1. Switching provider/model on the same bridge

**Decision.** The bridge never changes `agent_instances` itself. To move the bot to another local candidate, the bridge calls a new bridge-token route, `POST /api/v1/bridge/bot-attempts/{attempt_id}/switch` (section 12.6). The hub:

1. checks that the attempt is open on this bridge;
2. checks that the candidate appears in the attempt's stored candidate list, which is the policy expanded for this bridge;
3. calls the existing `reconfigure_instance` service proc with `Auth_Context{kind = .Internal_User, user_id = <owner>}`.

`reconfigure_instance` changes only provider, profile and model. It keeps the instance id, the bridge and the conversation (`src/hub/service/agent/agent_service.odin:1080-1099`):

- If the instance is in an active runtime status, it relaunches at once with the new provider through `relaunch_instance_locked` (`agent_service.odin:1096`). The hub sends `launch_agent` to this bridge.
- Otherwise it only saves the row (`agent_service.odin:1098`). The bridge then launches it locally (section 13.4). The launch descriptor the bridge fetches carries the provider and model from the row (`src/hub/service/agent/agent_service.odin:2208`, `bootstrap_manifest_json_for_bridge`).

The switch response says which of the two happened (`relaunched`). After a relaunch the bridge waits for the new launch record before it types the notice (13.4, `NEW_RUNTIME_READY`). When the running instance is already on an eligible candidate, the bridge keeps it and does not call switch (13.4, provider stickiness).

**Why.**

- The hub stays the record of instance state. `configuration_revision` is bumped by the existing upsert, so the UI and other services see the change through the normal paths.
- `validate_pinned_provider_model` re-checks the candidate against the hub's view of the bridge (`agent_service.odin:1589-1601`).
- The full relocation operation is the wrong tool on one bridge. It always stops the source and launches the destination, even when they are the same bridge, and it can leave a blocking `recovery_required` operation behind (`src/hub/service/agent/instance_reconfiguration.odin:88-181`, `:340-400`).
- The other option, passing an override in the launch descriptor, would make the bridge's launch disagree with the hub's row. The wake path reads provider and model only from the descriptor (`src/bridge/agent_wake.odin:299-353`), so the instance row would be wrong until the next status report.

**Evidence.**

- `reconfigure_instance` is user-only today only because of the HTTP layer: `PATCH /api/v1/agent-instances/*` uses `require_auth` (`src/hub/transport/http/agent_handlers.odin:333`). The service itself checks ownership through `get_instance` (`agent_service.odin:1084`).
- The hub already validates with an `Internal_User` auth for the owner: `src/hub/service/agent/instance_reconfiguration.odin:460`.

**Constraint.** `reconfigure_instance` refuses while a relocation operation blocks input (`reconfiguration_require_idle`, `instance_reconfiguration.odin:78-85`). The switch route then returns 409 `conflict` with details code `bot_relocation_open`. The bridge records the candidate outcome `switch_refused` and moves on.

**Moving to another bridge.** The hub starts the existing relocation with `begin_instance_reconfiguration` (`instance_reconfiguration.odin:88`), using an `Internal_User` auth for the owner (section 11.5).

### D2. The `bot_deliver` contract

**Decision.**

- **Frames and states.** One hub→bridge command, `bot_deliver` (section 12.3), answered with the existing `command_result` frame. One new bridge→hub frame, `bot_delivery_report` (section 12.4), answered with `bot_delivery_report_ack`.
- **Two records on the hub.** A *delivery* covers one batch of the owner's pending messages; an *attempt* is one try on one bridge. Their state machines are in section 11.
- **Deadline.** Each attempt has three hub timers:
  - an accept timer, 15 s;
  - a silence timer, 90 s since the last report (the bridge reports every 30 s while it works);
  - a total cap, 60 min.
- **Idempotency.** The `command_id` is `cmd_bot_<attempt_id>`. It is stable across re-sends, so the existing dispatcher's claim cache drops duplicates (`src/bridge/hub_command_dispatch.odin:530-630`). The bridge also keys its delivery workers by `attempt_id` (section 13.2).
- **Re-send.** Open attempts on a bridge are re-sent from a new hook, `bots.on_bridge_hello`. It is called next to `taskv2.on_bridge_hello` (`src/hub/transport/http/bridge_handlers.odin:1885`), the same pattern taskv2 uses for leases (`src/hub/service/taskv2/lease.odin:651-723`).
- **Hub restart.** Deliveries and attempts are SQLite rows. After a hub restart, the supervisor measures silence from `max(last_report_at, hub boot time)`, and the bridges' reconnect hellos re-send.
- **Capability.** A new runtime feature, `bot_deliver_v1`, goes in `BRIDGE_RUNTIME_FEATURES` (`src/bridge/hub_runtime_client.odin:4418`). The hub reads it with `bridge_feature_supported` (`instance_reconfiguration.odin:55`). A bridge is eligible only when it advertises both `bot_deliver_v1` and `instance_reconfiguration_v1`.

**Why.**

- The command channel is fire-and-forget and not durable. `send_runtime_command` returns `Bridge_Offline` at once and keeps no outbox (`src/hub/service/bridge_runtime/bridge_runtime.odin:64-77`).
- A queued bridge command is bounded by its spec `timeout_ms` (`hub_command_dispatch.odin:523`). So the command only *accepts* the work, and progress and outcome travel in a separate frame.

### D3. Not-acted detection on the bridge

**Decision.** The bridge watches five signals, all local:

1. **Launch outcome.** The result of `bridge_runtime_launch_agent` (`src/bridge/hub_runtime_client.odin:2615`).
2. **Readiness.** The local runtime snapshot reaches `running` or `idle` (`bridge_runtime_instance_snapshot`, `hub_runtime_client.odin:3390`).
3. **Startup blocked.** Status `blocked` from `bridge_pty_host_apply_startup_blocked` (`src/bridge/pty_host_runtime.odin:926`). This covers login prompts.
4. **Read and reply.** The bot calls `agent.channel.read` and `agent.channel.send`. The bridge sees both in the local agent relay (`src/bridge/wrapper_endpoint.odin:559-574`): it knows the method name and the calling instance. Nothing on the bridge detects a chat read today (survey result), so this hook is new.
5. **Activity before flattening.** The bridge reduces activity to `active`, `idle`, `waiting_user` or `unknown` (`src/bridge/pty_host_activity.odin:23`). It flattens `waiting_user` to `idle` only when it reports to the hub (`hub_runtime_client.odin:3356-3370`), so the bridge can still tell them apart.

**Telling a slow answer from a stuck agent.**

- While local activity is `active`, the bot is working and every reply timer is held.
- A bot is stuck when, after reading, its activity has been `idle` or `waiting_user` for 120 s without a reply.
- Before reading, the read timer (60 s) is extended in 60 s steps, at most 4 times, while activity is `active`. This covers a bot that is busy finishing an earlier turn.

All defaults and the per-message limits are in section 14. Each local candidate is tried at most once per attempt, and at most 3 candidates per attempt.

### D4. Chain, project, creation, start and idle stop

**Decision.**

- **Chain and project.** The bot needs no chain and no project of its own:
  - `project_id` stays empty;
  - `create_instance`/`prepare_instance` create a private `mixed_work` chain when `chain_id` is empty (`resolve_instance_chain`, `src/hub/service/agent/agent_service.odin:1514-1527`), and the instance becomes its coordinator (`agent_service.odin:400`).
- **Creation.** Creating the bot creates the `agt_` agent (template `tmpl_bot`) and the `bots` row. It does **not** create an instance.
- **First instance.** The hub creates the instance lazily, on the first dispatch to a bridge. It calls `prepare_instance` (`agent_service.odin:346`) with that bridge and the first candidate the hub expanded for it (section 10.3). `prepare_instance` persists the instance without launching it, and the bridge then launches it (section 13.4).
- **Idle stop.** A new hub supervisor timer stops the bot. It fires when:
  - the bot has had no open delivery for `bot_idle_stop_ms` (default 30 min), and
  - its runtime status is active.

  It calls `stop_instance` with reason `bot_idle` and `Internal_User` auth. A reason that does not start with `user` leaves `stopped_by` empty (`agent_service.odin:842`), so the next delivery can relaunch the bot freely.

**Why.**

- The fleet idle timer never touches the bot:
  - it is armed only when a task lease is released (`src/hub/service/taskv2/timers.odin:210`, `lease.odin:958`);
  - it skips chain coordinators (`lease.odin:1072`);
  - the bot never holds a lease and is the coordinator of its private chain.
- Leaving it alone and adding a bot-specific stop keeps taskv2 untouched.
- Lazy instance creation means bot creation never needs an online bridge. `prepare_instance` refuses an offline bridge (`agent_service.odin:356-361`).

### D5. Storing inbound Telegram text and the encryption notice

**Decision.** Inbound and outbound Telegram text is stored as **plaintext** in a new hub table, `channel_messages` (section 5). It is **not** stored in `chat_messages`.

- The bot reads it with `ham-ctl channel read`, which marks it read.
- The bot replies with `ham-ctl channel send`, which marks it replied.
- Bodies are purged (set to `''`) 30 days after creation, and immediately when the binding is disconnected or the bot is deleted.

**Why.**

1. The hub cannot encrypt to the vault. The keyring is symmetric per epoch and is held only by user devices and unsealed bridges; the hub holds no root key (`docs/architecture.md`, section 6; `docs/plans/passwordless-vault.md` "Keyring wrap").
2. `chat_messages` has no encryption marker. "Encrypted" means only that the body starts with `vault:v2:` (`src/hub/domain/vault_text_caps.odin:46`). Mixing plaintext rows into it would break the rule that human content in chat is ciphertext.
3. A `user_to_agent` row is drawn as the user's own bubble (`src/ui/components/workbench/AgentChatPane.tsx:673`).
4. A relocation's message hold blocks `user_to_agent` inserts while an operation blocks input (`src/hub/repository/sqlite/migrations/072_instance_reconfiguration.sql:60-101`). Telegram messages arriving mid-move would be refused.
5. Telegram itself can read these messages, so a separate plaintext store adds no new party.

**Notice.** The user is told twice:

- in Settings > Bots, next to the Connect button (copy in section 17.4);
- in Telegram, in the message sent when pairing succeeds (copy in section 9.6).

### D6. Hiding bridge and model; keeping the terminal reachable

**Decision.**

- **Main view.** The bot's conversation is hidden from the sidebar and from the Conversations home page while the experiment is on. The UI filters out the conversation whose `agentInstanceId` equals the bot's `agent_instance_id`. Data comes from `useListSidebarConversationsQuery` and `useListConversationInboxQuery` (`src/ui/api/endpoints/sidebar.ts:177`, `:202`), consumed in `src/ui/components/shell/AppShell.tsx` and `src/ui/components/chat/ConversationsHomePage.tsx`.
- **Settings > Bots.** The main bot card shows only status and the Telegram connection.
- **Advanced.** A collapsed "Advanced" disclosure in Settings > Bots shows the current machine, provider, model and runtime status. Its "Open terminal" button opens the existing terminal pane, `src/ui/components/workbench/AgentPtyWorkbenchPane.tsx`, for the bot instance.

**Why.** Filtering keeps `AgentChatPane.tsx` untouched. That file shows the bridge chip at `AgentChatPane.tsx:2966-2986` and the provider/model details at `:3455-3476`. The bot stays an ordinary instance (REQ-S1-3), so terminal streaming needs no new work.

## 3. Architecture overview

```text
Telegram Bot API  <──long poll / sendMessage──  hub: Channel_Adapter (telegram)
                                                 │
                                hub: bots service (store, pair, select bridge,
                                     deliveries/attempts, supervisor, relocation)
                                                 │  bot_deliver (WS command)
                                                 ▼
                            bridge: bot delivery worker (candidates, launch,
                                    notice, watch read/reply, switch, report)
                                                 │  PTY notice
                                                 ▼
                         bot agent: ham-ctl channel read / channel send
                         (bridge relay → hub /api/v1/agent-actions/channel/*)
```

**Message lifecycle**, happy path with a stopped bot on its sticky bridge:

1. The poller receives update `u` and stores `channel_messages(direction='inbound')` in a transaction that also advances `channel_cursors`. Only then does the next `getUpdates` call pass `offset=u+1`; that offset is Telegram's acknowledgement (REQ-S1-9).
2. The bots service creates delivery `bdl_…` (state `pending`).
3. The supervisor selects bridge B, creates attempt `bda_…` (state `sent`) and sends `bot_deliver`.
4. Bridge B replies `command_result{status:"succeeded"}`, and the hub sets the attempt to `accepted`. The bridge launches the bot with the first local candidate, waits until it is ready, and types the notice into its PTY.
5. The bot runs `./bin/ham-ctl channel read`. The hub marks the messages read; the bridge relay notes `read`.
6. The bot runs `./bin/ham-ctl channel send --text "…"`. The hub sends the text to Telegram, marks the messages replied, and sets the delivery to `acted`. The bridge relay notes `replied` and reports `acted`.
7. The hub records the report and replies `bot_delivery_report_ack`.

## 4. Experiment gating

### 4.1 Key

- **Hub.** Add `BOTS_EXPERIMENT_KEY :: "bots"` to `src/hub/domain/experiment.odin` after `ACTIONS_EXPERIMENT_KEY` (`experiment.odin:12`). Add `case BOTS_EXPERIMENT_KEY: return "Bots"` to `experiment_feature_label` (`experiment.odin:44`). It is **not** added to `EXPERIMENTS_DEFAULT_ON` (`experiment.odin:21`), so it is off by default.
- **UI.** Add `BOTS_EXPERIMENT_KEY = 'bots'` to `src/ui/components/settings/experimentFlags.ts` next to `ACTIONS_EXPERIMENT_KEY` (`experimentFlags.ts:5`). Append this entry to `EXPERIMENTAL_FLAGS` (`experimentFlags.ts:36-59`):

```ts
{ key: BOTS_EXPERIMENT_KEY, label: 'Bots', description: 'A personal bot you can talk to from Telegram. It runs on your machines; Ninjy picks the machine and model.' }
```

### 4.2 Server-side gate helpers

- **Request handlers** (everything in `src/hub/transport/http`) MUST call `require_experiment_enabled(repo, owner_user_id, domain.BOTS_EXPERIMENT_KEY, req.request_id)` (`src/hub/transport/http/experiment_rest_handlers.odin:181`). This covers the user routes (15), the agent routes (16.1) and the switch route (12.6).
- **Code in `src/hub/service/bots`** (supervisor, poller, inbound rules, frame hooks `bots_on_*`) MUST NOT import `src/hub/transport/http`. `transport/http` imports `service/bots` for its handlers, and the reverse import would be a package cycle. This code MUST call the bots-service gate helper instead. A1a adds it in `src/hub/service/bots/gate.odin`:

```odin
package bots

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// bots_gate_error returns {} when the bots experiment is on for owner_user_id,
// otherwise the refusal. Same semantics as experiment_gate_error
// (experiment_rest_handlers.odin:158): empty owner → refusal; repository error →
// .Internal_Error (fail closed); only this owner's rows are read.
bots_gate_error :: proc(repo: ^iface.Experiment_Repository, owner_user_id: string) -> domain.Domain_Error {
	if owner_user_id == "" do return domain.experimental_feature_disabled_error(domain.BOTS_EXPERIMENT_KEY)
	exps, err := iface.experiment_list_by_owner(repo, owner_user_id)
	defer {
		for exp in exps {
			delete(exp.owner_user_id)
			delete(exp.key)
			delete(exp.updated_at)
		}
		delete(exps)
	}
	if err.code != .None do return domain.domain_error(.Internal_Error, "could not read experiment settings")
	if domain.experiment_enabled_in(exps[:], domain.BOTS_EXPERIMENT_KEY) do return domain.Domain_Error{}
	return domain.experimental_feature_disabled_error(domain.BOTS_EXPERIMENT_KEY)
}

// bots_gate_on is bots_gate_error == {} as a bool, for loops that skip an owner.
bots_gate_on :: proc(repo: ^iface.Experiment_Repository, owner_user_id: string) -> bool {
	return bots_gate_error(repo, owner_user_id).code == .None
}
```

- The helper uses only `iface.experiment_list_by_owner` (`src/hub/repository/iface/experiment_repo.odin:19`) and `domain.experiment_enabled_in` (`src/hub/domain/experiment.odin:38`), both of which `service` packages may import.
- `experiment_gate_error` stays where it is and MUST NOT be called from `src/hub/service/bots`.
- **Response when off:** HTTP 403, `error.code = "forbidden"`, `error.details = {"code":"experimental_feature_disabled","feature":"bots"}`. This comes from `experimental_feature_disabled_error` (`experiment.odin:56`).

Add one repository proc to `Experiment_Repository` (`src/hub/repository/iface/experiment_repo.odin:8`):

```odin
count_enabled: proc(ctx: rawptr, key: string) -> (int, domain.Domain_Error),
experiment_count_enabled :: proc(repo: ^Experiment_Repository, key: string) -> (int, domain.Domain_Error)
```

SQLite implementation in `src/hub/repository/sqlite/experiment_repo_sqlite.odin`:

```sql
SELECT COUNT(*) FROM experiments WHERE key = ? AND enabled = 1;
```

### 4.3 Behaviour with the experiment off for a user

| Surface | Behaviour |
|---|---|
| `/api/v1/bots/*` user routes (section 15) | 403 `experimental_feature_disabled` |
| `/api/v1/agent-actions/channel/*` (section 16) | 403 `experimental_feature_disabled`, checked against the instance owner |
| `/api/v1/bridge/bot-attempts/*/switch` | 403 `experimental_feature_disabled`, checked against the bridge owner |
| `ham-ctl channel …` | the verb exists in the binary but prints the hub's 403 and exits 1 (section 16.4). `ctl` has no experiment checks today (survey: no `experiment` in `src/ctl`) |
| Hub delivery engine | creates no delivery and no attempt for the owner. Their open deliveries become `abandoned` with `finish_reason='experiment_disabled'` and no Telegram notice. A running bot instance is stopped with reason `bot_experiment_disabled` |
| Telegram poller | if it runs for other users, updates from this owner's bound chat are consumed (the cursor advances) and dropped without storing or replying. `/start <code>` for this owner is answered with the "not enabled" copy (section 9.6) |
| Bridge | unchanged; it advertises `bot_deliver_v1` but never receives `bot_deliver` for this owner |
| UI | no Bots entry in Settings and no conversation filtering. The bot conversation, if one exists, appears as an ordinary conversation |

### 4.4 Background loops

Two hub threads exist for bots: the **poller** (section 9.3) and the **supervisor** (section 11.6). Neither starts unless the experiment is on for at least one user.

- **The proc.** `bots_runtime_reconcile(rt: ^Bots_Runtime)` in `src/hub/service/bots/runtime.odin` does the following:
  1. Reads `n := experiment_count_enabled(repo, "bots")`.
  2. If `n > 0` and the supervisor is not running, starts it. If `n == 0` and it is running, stops it.
  3. If `n > 0`, `config.telegram_bot_token != ""` and the poller is not running, starts it. If either condition is false and the poller is running, stops it.
- **When it runs:**
  - once in `app.run` after `taskv2.start_timer_thread` (`src/hub/app/app.odin:31-32`);
  - after every successful `PUT /api/v1/me/experiments/bots`. Add an optional field `on_changed: proc(ctx: rawptr, owner_user_id, key: string, enabled: bool)` and `on_changed_ctx: rawptr` to `Experiment_Rest_Handlers` (`experiment_rest_handlers.odin:12`), and call it at the end of `experiment_set_handler` (`experiment_rest_handlers.odin:71`). The wiring sets it to a bots proc. That proc calls `bots_runtime_reconcile` and, when `enabled == false`, `bots_on_experiment_disabled(owner)` (the row in section 4.3).
- **Thread pattern.** Start/stop MUST copy `bridge_catalog_refresher_start` and `_stop` (`src/hub/service/bridge/bridge_promoted_release.odin:288-326`): a stop flag, a mutex and a condition variable, `cond_wait_with_timeout`, then join and destroy. The poller passes `cancel = &stop_flag` to `httpc.send` so a stop aborts the long poll.

## 5. Data model and migration

### 5.1 Migration file

- **File.** `src/hub/repository/sqlite/migrations/209_bots.sql`. The highest file at the base commit is `208_extension_version_sync_0_5_54.sql`.
- **If 209 is taken.** If `209_*` exists when ticket A1a starts, A1a MUST use the next free number. It MUST then change this spec's references to the new file name in the same commit.
- **Registration** in `src/hub/repository/sqlite/migrations.odin` takes three edits:
  1. Add `MIGRATION_209_BOTS :: #load("migrations/209_bots.sql", string)` after `:662`.
  2. Append `"209_bots.sql"` to `migration_order` (`:664`) and raise the array length from 212 to 213.
  3. Add a branch to the `migration_sql` fallback (`:1368`).

```sql
-- 209_bots.sql: bots slice 1 (experiment "bots")

CREATE TABLE IF NOT EXISTS bots (
  bot_id              TEXT PRIMARY KEY,                 -- "bot_..."
  owner_user_id       TEXT NOT NULL UNIQUE,             -- one bot per user
  agent_id            TEXT NOT NULL,                    -- "agt_..." (template tmpl_bot)
  agent_instance_id   TEXT NOT NULL DEFAULT '',         -- "" until first dispatch
  display_name        TEXT NOT NULL DEFAULT 'Ninjy bot',
  placement_revision  INTEGER NOT NULL DEFAULT 1,
  created_at          TEXT NOT NULL,
  updated_at          TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS bot_placement_candidates (
  bot_id     TEXT NOT NULL REFERENCES bots(bot_id) ON DELETE CASCADE,
  position   INTEGER NOT NULL CHECK (position >= 0),
  bridge_id  TEXT NOT NULL,                             -- "brg_..." or "*"
  provider   TEXT NOT NULL,                             -- catalog provider id or "*"
  model      TEXT NOT NULL,                             -- model id or "*"
  tier       TEXT NOT NULL CHECK (tier IN ('preferred','allowed')),
  PRIMARY KEY (bot_id, position),
  CHECK (NOT (provider = '*' AND model <> '*'))
);

CREATE TABLE IF NOT EXISTS channel_bindings (
  binding_id         TEXT PRIMARY KEY,                  -- "chb_..."
  owner_user_id      TEXT NOT NULL,
  bot_id             TEXT NOT NULL,
  provider           TEXT NOT NULL CHECK (provider IN ('telegram')),
  external_chat_id   TEXT NOT NULL,                     -- Telegram chat.id as decimal text
  external_user_id   TEXT NOT NULL,                     -- Telegram from.id as decimal text
  external_display   TEXT NOT NULL DEFAULT '',          -- "@username" or first name
  state              TEXT NOT NULL CHECK (state IN ('active','revoked')),
  created_at         TEXT NOT NULL,
  revoked_at         TEXT NOT NULL DEFAULT ''
);
CREATE UNIQUE INDEX IF NOT EXISTS channel_bindings_active_chat
  ON channel_bindings(provider, external_chat_id) WHERE state = 'active';
CREATE UNIQUE INDEX IF NOT EXISTS channel_bindings_active_owner
  ON channel_bindings(owner_user_id, provider) WHERE state = 'active';

CREATE TABLE IF NOT EXISTS channel_pairings (
  code_hash      TEXT PRIMARY KEY,                      -- hex SHA-256 of the code
  owner_user_id  TEXT NOT NULL,
  bot_id         TEXT NOT NULL,
  provider       TEXT NOT NULL CHECK (provider IN ('telegram')),
  created_at     TEXT NOT NULL,
  expires_at     TEXT NOT NULL,
  consumed_at    TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS channel_pairings_owner ON channel_pairings(owner_user_id, provider);

CREATE TABLE IF NOT EXISTS channel_cursors (
  provider    TEXT PRIMARY KEY,                         -- "telegram"
  cursor      TEXT NOT NULL,                            -- Telegram: next offset as decimal text
  updated_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS channel_messages (
  message_id           TEXT PRIMARY KEY,                -- "chm_..."
  binding_id           TEXT NOT NULL,
  owner_user_id        TEXT NOT NULL,
  bot_id               TEXT NOT NULL,
  direction            TEXT NOT NULL CHECK (direction IN ('inbound','outbound')),
  provider_update_key  TEXT NOT NULL DEFAULT '',        -- inbound: "telegram:<bot_user_id>:<update_id>"
  external_message_id  TEXT NOT NULL DEFAULT '',
  body                 TEXT NOT NULL,                   -- plaintext; '' once purged
  body_purged          INTEGER NOT NULL DEFAULT 0 CHECK (body_purged IN (0,1)),
  send_state           TEXT NOT NULL DEFAULT '' CHECK (send_state IN ('','pending','sent','failed')),
  send_error           TEXT NOT NULL DEFAULT '',
  created_at           TEXT NOT NULL,
  read_at              TEXT NOT NULL DEFAULT '',
  replied_at           TEXT NOT NULL DEFAULT ''
);
CREATE UNIQUE INDEX IF NOT EXISTS channel_messages_update_key
  ON channel_messages(provider_update_key) WHERE provider_update_key <> '';
CREATE INDEX IF NOT EXISTS channel_messages_bot_pending
  ON channel_messages(bot_id, direction, replied_at, created_at);

CREATE TABLE IF NOT EXISTS bot_deliveries (
  delivery_id          TEXT PRIMARY KEY,                -- "bdl_..."
  bot_id               TEXT NOT NULL,
  owner_user_id        TEXT NOT NULL,
  through_message_id   TEXT NOT NULL,                   -- newest inbound message covered
  state                TEXT NOT NULL CHECK (state IN ('pending','dispatched','waiting','acted','abandoned')),
  round                INTEGER NOT NULL DEFAULT 1,
  waiting_reason       TEXT NOT NULL DEFAULT '',
  waiting_notice_at    TEXT NOT NULL DEFAULT '',
  finish_reason        TEXT NOT NULL DEFAULT '',
  created_at           TEXT NOT NULL,
  updated_at           TEXT NOT NULL,
  finished_at          TEXT NOT NULL DEFAULT ''
);
CREATE UNIQUE INDEX IF NOT EXISTS bot_deliveries_one_open
  ON bot_deliveries(bot_id) WHERE state IN ('pending','dispatched','waiting');

CREATE TABLE IF NOT EXISTS bot_delivery_attempts (
  attempt_id        TEXT PRIMARY KEY,                   -- "bda_..."
  delivery_id       TEXT NOT NULL REFERENCES bot_deliveries(delivery_id) ON DELETE CASCADE,
  round             INTEGER NOT NULL,
  bridge_id         TEXT NOT NULL,
  state             TEXT NOT NULL CHECK (state IN ('relocating','sent','accepted','acted','exhausted','busy','disconnected','deadline','cancelled')),
  relocation_key    TEXT NOT NULL DEFAULT '',           -- idempotency key used for begin_instance_reconfiguration
  candidates_json   TEXT NOT NULL DEFAULT '[]',         -- expanded candidates sent to the bridge
  report_json       TEXT NOT NULL DEFAULT '{}',         -- last bot_delivery_report payload
  report_seq        INTEGER NOT NULL DEFAULT 0,
  sent_at           TEXT NOT NULL DEFAULT '',
  accepted_at       TEXT NOT NULL DEFAULT '',
  last_report_at    TEXT NOT NULL DEFAULT '',
  disconnected_at   TEXT NOT NULL DEFAULT '',
  created_at        TEXT NOT NULL,
  finished_at       TEXT NOT NULL DEFAULT ''
);
CREATE UNIQUE INDEX IF NOT EXISTS bot_delivery_attempts_round_bridge
  ON bot_delivery_attempts(delivery_id, round, bridge_id);
CREATE INDEX IF NOT EXISTS bot_delivery_attempts_open
  ON bot_delivery_attempts(state) WHERE state IN ('relocating','sent','accepted');
```

### 5.2 Invariants

These hold beyond what the SQL enforces:

- **Bot.** One per user (`bots.owner_user_id UNIQUE`). `bots.agent_instance_id` is either empty or an instance whose `agent_id` is `bots.agent_id` and whose `owner_user_id` is the bot owner.
- **Bindings.** At most one active binding per owner and provider, and at most one active binding per chat. `bot_id` is part of the binding row, so a later multi-bot shape keeps this table. It only needs the owner index changed to `(owner_user_id, provider, bot_id)`.
- **Inbound pending.** An inbound message is *pending* while `replied_at = ''`.
- **Outbound.** Outbound rows always have `read_at = ''` and `replied_at = ''`.
- **Deliveries.** At most one open delivery per bot (`bot_deliveries_one_open`).
- **Attempts.** At most one attempt per (delivery, round, bridge). At most one attempt per delivery is open at a time; the service enforces this, not the SQL.

### 5.3 Domain types

**File:** `src/hub/domain/bot.odin`.

```odin
package domain

BOT_ID_PREFIX :: "bot_"
CHANNEL_BINDING_ID_PREFIX :: "chb_"
CHANNEL_MESSAGE_ID_PREFIX :: "chm_"
BOT_DELIVERY_ID_PREFIX :: "bdl_"
BOT_ATTEMPT_ID_PREFIX :: "bda_"
CHANNEL_PROVIDER_TELEGRAM :: "telegram"
BOT_PLACEMENT_ANY :: "*"
BOT_MAX_PLACEMENT_CANDIDATES :: 32

Bot :: struct {
	bot_id, owner_user_id, agent_id, agent_instance_id, display_name: string,
	placement_revision: int,
	created_at, updated_at: string,
}

Bot_Placement_Tier :: enum { Preferred, Allowed }

Bot_Placement_Candidate :: struct {
	position: int,
	bridge_id, provider, model: string, // each may be BOT_PLACEMENT_ANY
	tier: Bot_Placement_Tier,
}

Channel_Binding_State :: enum { Active, Revoked }

Channel_Binding :: struct {
	binding_id, owner_user_id, bot_id, provider: string,
	external_chat_id, external_user_id, external_display: string,
	state: Channel_Binding_State,
	created_at, revoked_at: string,
}

Channel_Pairing :: struct {
	code_hash, owner_user_id, bot_id, provider: string,
	created_at, expires_at, consumed_at: string,
}

Channel_Direction :: enum { Inbound, Outbound }
Channel_Send_State :: enum { None, Pending, Sent, Failed }

Channel_Message :: struct {
	message_id, binding_id, owner_user_id, bot_id: string,
	direction: Channel_Direction,
	provider_update_key, external_message_id, body: string,
	body_purged: bool,
	send_state: Channel_Send_State,
	send_error: string,
	created_at, read_at, replied_at: string,
}

Bot_Delivery_State :: enum { Pending, Dispatched, Waiting, Acted, Abandoned }

Bot_Delivery :: struct {
	delivery_id, bot_id, owner_user_id, through_message_id: string,
	state: Bot_Delivery_State,
	round: int,
	waiting_reason, waiting_notice_at, finish_reason: string,
	created_at, updated_at, finished_at: string,
}

Bot_Attempt_State :: enum { Relocating, Sent, Accepted, Acted, Exhausted, Busy, Disconnected, Deadline, Cancelled }

Bot_Delivery_Attempt :: struct {
	attempt_id, delivery_id: string,
	round: int,
	bridge_id: string,
	state: Bot_Attempt_State,
	relocation_key, candidates_json, report_json: string,
	report_seq: int,
	sent_at, accepted_at, last_report_at, disconnected_at, created_at, finished_at: string,
}

bot_attempt_state_open :: proc(s: Bot_Attempt_State) -> bool {
	return s == .Relocating || s == .Sent || s == .Accepted
}
bot_delivery_state_open :: proc(s: Bot_Delivery_State) -> bool {
	return s == .Pending || s == .Dispatched || s == .Waiting
}
```

- **Text form of enums.** The text written to SQLite is the lower-case enum name (`"preferred"`, `"relocating"`). For `Channel_Send_State.None` it is `""`.
- **`*_destroy` procs.** Each struct gets one, following `domain.agent_instance_destroy`.
- **Tests.** Every text ↔ enum mapping MUST have a round-trip test in `src/hub/domain/bot_test.odin`.

### 5.4 Repository interface

**Interface file:** `src/hub/repository/iface/bot_repo.odin`. **Implementation:** `src/hub/repository/sqlite/bot_repo_sqlite.odin`. It is wired in `src/hub/app/wiring.odin` next to `graph.experiment_repo` (`wiring.odin:323`).

```odin
Bot_Repository :: struct {
	ctx: rawptr,
	// bots
	bot_insert:            proc(ctx: rawptr, bot: domain.Bot) -> domain.Domain_Error,             // Conflict on UNIQUE(owner)
	bot_get_by_owner:      proc(ctx: rawptr, owner_user_id: string) -> (domain.Bot, bool, domain.Domain_Error),
	bot_get:               proc(ctx: rawptr, bot_id: string) -> (domain.Bot, bool, domain.Domain_Error),
	bot_get_by_instance:   proc(ctx: rawptr, agent_instance_id: string) -> (domain.Bot, bool, domain.Domain_Error),
	bot_set_instance:      proc(ctx: rawptr, bot_id, agent_instance_id, updated_at: string) -> domain.Domain_Error,
	bot_delete:            proc(ctx: rawptr, bot_id: string) -> domain.Domain_Error,             // cascades candidates
	bot_list_owners_with_open_deliveries: proc(ctx: rawptr) -> ([]string, domain.Domain_Error),
	// placement
	placement_list:        proc(ctx: rawptr, bot_id: string) -> ([]domain.Bot_Placement_Candidate, domain.Domain_Error),
	placement_replace:     proc(ctx: rawptr, bot_id: string, expected_revision: int, rows: []domain.Bot_Placement_Candidate, updated_at: string) -> (new_revision: int, err: domain.Domain_Error), // Conflict if revision moved
	// bindings and pairings
	binding_get_active_by_owner: proc(ctx: rawptr, owner_user_id, provider: string) -> (domain.Channel_Binding, bool, domain.Domain_Error),
	binding_get_active_by_chat:  proc(ctx: rawptr, provider, external_chat_id: string) -> (domain.Channel_Binding, bool, domain.Domain_Error),
	binding_activate:      proc(ctx: rawptr, binding: domain.Channel_Binding, pairing_code_hash, consumed_at: string) -> (revoked_previous: domain.Channel_Binding, had_previous: bool, err: domain.Domain_Error), // one tx: consume pairing, revoke owner's previous binding, insert
	binding_revoke:        proc(ctx: rawptr, binding_id, revoked_at: string) -> domain.Domain_Error,
	pairing_insert:        proc(ctx: rawptr, p: domain.Channel_Pairing) -> domain.Domain_Error,
	pairing_get:           proc(ctx: rawptr, code_hash: string) -> (domain.Channel_Pairing, bool, domain.Domain_Error),
	pairing_delete_for_owner: proc(ctx: rawptr, owner_user_id, provider: string) -> domain.Domain_Error,
	// cursor + inbound (one transaction)
	cursor_get:            proc(ctx: rawptr, provider: string) -> (string, bool, domain.Domain_Error),
	inbound_store_batch:   proc(ctx: rawptr, provider: string, rows: []domain.Channel_Message, next_cursor, now: string) -> (inserted: []string, err: domain.Domain_Error), // INSERT OR IGNORE on update key, then UPSERT cursor; returns ids actually inserted
	// channel messages
	message_insert_outbound: proc(ctx: rawptr, msg: domain.Channel_Message) -> domain.Domain_Error,
	message_set_send_result: proc(ctx: rawptr, message_id: string, state: domain.Channel_Send_State, external_message_id, send_error: string) -> domain.Domain_Error,
	messages_pending:      proc(ctx: rawptr, bot_id: string, limit: int) -> ([]domain.Channel_Message, domain.Domain_Error),   // inbound, replied_at='', oldest first
	messages_mark_read:    proc(ctx: rawptr, bot_id: string, message_ids: []string, read_at: string) -> domain.Domain_Error,     // only rows with read_at=''
	messages_mark_replied: proc(ctx: rawptr, bot_id, replied_at: string) -> (count: int, err: domain.Domain_Error),           // inbound rows with read_at<>'' AND replied_at=''
	messages_history:      proc(ctx: rawptr, bot_id: string, limit: int) -> ([]domain.Channel_Message, domain.Domain_Error),   // both directions, newest first
	messages_purge_binding: proc(ctx: rawptr, binding_id: string) -> domain.Domain_Error,
	messages_purge_older_than: proc(ctx: rawptr, cutoff: string) -> (int, domain.Domain_Error),
	// deliveries and attempts
	delivery_get_open:     proc(ctx: rawptr, bot_id: string) -> (domain.Bot_Delivery, bool, domain.Domain_Error),
	delivery_get:          proc(ctx: rawptr, delivery_id: string) -> (domain.Bot_Delivery, bool, domain.Domain_Error),
	delivery_insert:       proc(ctx: rawptr, d: domain.Bot_Delivery) -> domain.Domain_Error,
	delivery_update:       proc(ctx: rawptr, d: domain.Bot_Delivery, expected_state: domain.Bot_Delivery_State) -> (bool, domain.Domain_Error), // CAS on state
	delivery_list_open:    proc(ctx: rawptr) -> ([]domain.Bot_Delivery, domain.Domain_Error),
	delivery_list_recent:  proc(ctx: rawptr, bot_id: string, limit: int) -> ([]domain.Bot_Delivery, domain.Domain_Error),
	attempt_insert:        proc(ctx: rawptr, a: domain.Bot_Delivery_Attempt) -> domain.Domain_Error,
	attempt_get:           proc(ctx: rawptr, attempt_id: string) -> (domain.Bot_Delivery_Attempt, bool, domain.Domain_Error),
	attempt_update:        proc(ctx: rawptr, a: domain.Bot_Delivery_Attempt, expected_state: domain.Bot_Attempt_State) -> (bool, domain.Domain_Error), // CAS on state
	attempt_list_for_delivery: proc(ctx: rawptr, delivery_id: string) -> ([]domain.Bot_Delivery_Attempt, domain.Domain_Error),
	attempt_list_open:     proc(ctx: rawptr) -> ([]domain.Bot_Delivery_Attempt, domain.Domain_Error),
	attempt_list_open_on_bridge: proc(ctx: rawptr, bridge_id: string) -> ([]domain.Bot_Delivery_Attempt, domain.Domain_Error),
}
```

- **Wrappers.** Each field gets a wrapper proc named after it, in the same style as `iface.experiment_set` (`src/hub/repository/iface/experiment_repo.odin:14`).
- **Transactions.** `inbound_store_batch`, `binding_activate` and `placement_replace` MUST each run in one SQLite transaction.

## 6. Hub configuration

Add to `Hub_Config` (`src/hub/app/config_bind.odin:9`):

```odin
telegram_bot_token:  string, // secret; never logged
telegram_api_base:   string, // default "https://api.telegram.org"
bot_timers:          Bot_Timer_Config,
```

`Bot_Timer_Config` is defined in `src/hub/service/bots/config.odin`. Its defaults are in section 14.1.

| Source | Effect |
|---|---|
| env `HEIMDALL_TELEGRAM_BOT_TOKEN` | `telegram_bot_token` |
| env `HEIMDALL_TELEGRAM_BOT_TOKEN_FILE` | read the file and trim whitespace. Used only when `HEIMDALL_TELEGRAM_BOT_TOKEN` is empty |
| flag `--telegram-bot-token-file <path>` | same as the file env; a flag wins over env |
| env `HEIMDALL_TELEGRAM_API_BASE`, flag `--telegram-api-base <url>` | `telegram_api_base`; the fake server in tests uses it |
| env `HEIMDALL_BOT_TIMERS_JSON` | JSON object whose keys are the `Bot_Timer_Config` field names in section 14.1, values in ms; unknown keys refused at startup. For tests only; documented in `SELF_HOSTING.md` as such |

**Where the code goes:**

- Add `apply_telegram_env` in `src/hub/main.odin` and call it from `parse_args` next to `apply_vapid_env` (`main.odin:152`).
- Use the same file-reading helper as `HEIMDALL_VAPID_PRIVATE_KEY_FILE` (`read_key_file`, `main.odin:390-393`).
- Add the flags in the flag loop (`main.odin:188-336`).

**Token handling:**

- The token MUST NOT appear in any log line, error message, metrics label or HTTP response.
- `httpc` puts the token in the URL path (`bot<token>/getUpdates`). **Assumption** (verify in A4): `httpc.Response.detail` and the httpc error strings may include the URL. So the adapter MUST NOT log `detail`. It MUST log only the method name, the HTTP status and the Telegram `error_code`/`description`.

## 7. Contracts

**Files:** `src/contracts/bot_wire.odin` (Odin) and `src/ui/api/endpoints/bots.ts` (TypeScript types for the user API in section 15). The Odin file holds the wire constants and structs shared by hub and bridge:

```odin
package contracts

BRIDGE_FEATURE_BOT_DELIVER_V1 :: "bot_deliver_v1"
BOT_DELIVER_FRAME :: "bot_deliver"
BOT_DELIVERY_REPORT_FRAME :: "bot_delivery_report"
BOT_DELIVERY_REPORT_ACK_FRAME :: "bot_delivery_report_ack"

Bot_Candidate_Wire :: struct {
	provider:         string `json:"provider"`,
	provider_profile: string `json:"provider_profile"`,
	model:            string `json:"model"`,
	tier:             string `json:"tier"`, // "preferred" | "allowed"
}

Bot_Timers_Wire :: struct {
	launch_ready_ms:     i64 `json:"launch_ready_ms"`,
	read_ms:             i64 `json:"read_ms"`,
	read_extend_ms:      i64 `json:"read_extend_ms"`,
	read_max_extends:    int `json:"read_max_extends"`,
	idle_no_reply_ms:    i64 `json:"idle_no_reply_ms"`,
	reply_cap_ms:        i64 `json:"reply_cap_ms"`,
	progress_interval_ms: i64 `json:"progress_interval_ms"`,
}

Bot_Skip_Wire :: struct {
	provider: string `json:"provider"`,
	model:    string `json:"model"`,
	reason:   string `json:"reason"`,
}

Bot_Deliver_Wire :: struct {
	type:               string `json:"type"`, // "bot_deliver"
	command_id:         string `json:"command_id"`,
	bridge_id:          string `json:"bridge_id"`,
	agent_instance_id:  string `json:"agent_instance_id"`,
	bot_id:             string `json:"bot_id"`,
	delivery_id:        string `json:"delivery_id"`,
	attempt_id:         string `json:"attempt_id"`,
	through_message_id: string `json:"through_message_id"`,
	pending_count:      int    `json:"pending_count"`,
	current_provider:   string `json:"current_provider"`, // instance's provider in the hub record when the frame is built (11.4)
	current_model:      string `json:"current_model"`,    // instance's model in the hub record when the frame is built (11.4)
	candidates:         []Bot_Candidate_Wire `json:"candidates"`,
	skip:               []Bot_Skip_Wire `json:"skip"`,
	timers:             Bot_Timers_Wire `json:"timers"`,
}

Bot_Candidate_Outcome_Wire :: struct {
	provider: string `json:"provider"`,
	model:    string `json:"model"`,
	outcome:  string `json:"outcome"`, // section 13.6
	detail:   string `json:"detail"`,
}

Bot_Delivery_Report_Wire :: struct {
	type:              string `json:"type"`, // "bot_delivery_report"
	protocol_version:  int    `json:"protocol_version"`, // 1
	delivery_id:       string `json:"delivery_id"`,
	attempt_id:        string `json:"attempt_id"`,
	agent_instance_id: string `json:"agent_instance_id"`,
	seq:               int    `json:"seq"`,
	state:             string `json:"state"`, // "working" | "acted" | "exhausted" | "busy"
	phase:             string `json:"phase"`, // section 13.5
	candidate_index:   int    `json:"candidate_index"`,
	outcomes:          []Bot_Candidate_Outcome_Wire `json:"outcomes"`,
	reason:            string `json:"reason"`,
}

Bot_Delivery_Report_Ack_Wire :: struct {
	type:       string `json:"type"`, // "bot_delivery_report_ack"
	attempt_id: string `json:"attempt_id"`,
	seq:        int    `json:"seq"`,
}
```

The TypeScript types for the user API are given in section 15 next to each route.

## 8. Channel adapter interface (provider-neutral)

**File:** `src/hub/service/channel/adapter.odin` (new package `channel`). Hub code outside `src/hub/service/channel/` MUST NOT call Telegram directly. It MUST call only the `Channel_Adapter` procs (REQ-S1-12).

```odin
package channel

Channel_Error_Kind :: enum { None, Transient, Rate_Limited, Unauthorized, Chat_Unavailable, Invalid_Request, Aborted }

Channel_Error :: struct {
	kind:            Channel_Error_Kind,
	retry_after_ms:  i64,     // set for Rate_Limited
	provider_code:   int,     // Telegram error_code for the Telegram adapter; 0 if none
	message:         string,  // safe to log; never contains the token
}

Inbound_Kind :: enum { Text, Start, Disconnect, Unsupported }

Inbound :: struct {
	update_key:        string,  // globally unique per provider, used for dedupe
	external_chat_id:  string,
	external_user_id:  string,
	chat_is_private:   bool,
	sender_display:    string,
	kind:              Inbound_Kind,
	text:              string,  // Text: message text; Start: the start payload ("" when none)
}

Identity :: struct {
	bot_user_id:  string,
	bot_username: string,  // without "@"
}

Channel_Adapter :: struct {
	ctx:      rawptr,
	provider: string, // "telegram"
	// Blocks up to the provider's long-poll window. `cursor` is opaque; "" means start.
	poll:     proc(ctx: rawptr, cursor: string, cancel: ^bool, allocator := context.allocator) -> (batch: []Inbound, next_cursor: string, err: Channel_Error),
	send_text: proc(ctx: rawptr, external_chat_id: string, text: string) -> (external_message_id: string, err: Channel_Error),
	identity: proc(ctx: rawptr) -> (Identity, Channel_Error),
	pairing_url: proc(ctx: rawptr, identity: Identity, code: string, allocator := context.allocator) -> string,
}
```

**Contract every adapter MUST meet:**

1. `poll` MUST NOT acknowledge anything itself. The caller acknowledges by passing `next_cursor` to the following `poll`, and only after storing the batch.
2. `send_text` sends plaintext only: no markup and no buttons. `text` is at most 4000 bytes of valid UTF-8. The caller splits longer text first (section 9.5).
3. `update_key` MUST be stable for the same provider event across re-polls.

### 8.1 Telegram adapter

**File:** `src/hub/service/channel/telegram.odin`. It uses `httpc` only (`src/lib/httpc`, `send` at `send.odin:17`).

**`identity`**

- Calls `GET {api_base}/bot{token}/getMe`, with path segments `{"bot"+token, "getMe"}` and `timeout_ms = 10_000`.
- Caches the result for the process lifetime.
- `bot_user_id = result.id` as decimal text; `bot_username = result.username`.

**`poll`**

- Calls `GET {api_base}/bot{token}/getUpdates` with:
  - query `offset=<cursor>` (omitted when `cursor == ""`);
  - `timeout=30`;
  - `allowed_updates=["message"]`, JSON-encoded;
  - `timeout_ms = 40_000`, `max_response_bytes = 4 << 20`, `cancel = cancel`.
- `next_cursor` is `max(update_id)+1` over the batch, as decimal text, or `cursor` when the batch is empty.

Mapping each update:

| Update | `Inbound` |
|---|---|
| `message.chat.type == "private"`, `message.text` starts with `/start` | `kind=.Start`; `text` = the payload after `"/start "`, trimmed; `""` when absent |
| private, `message.text == "/disconnect"` | `kind=.Disconnect` |
| private, `message.text` present otherwise | `kind=.Text`, `text = message.text` |
| private, no `message.text` (photo, sticker, voice, …) | `kind=.Unsupported` |
| `message.chat.type != "private"` | `chat_is_private=false`, `kind=.Unsupported` |
| update without `message` | skipped; it still advances `next_cursor` |

- `update_key = "telegram:" + bot_user_id + ":" + update_id`.
- `external_chat_id = message.chat.id`; `external_user_id = message.from.id`. Both are decimal text.
- `sender_display = "@" + from.username` if `username` is present, else `from.first_name`.

**`send_text`**

- Calls `POST {api_base}/bot{token}/sendMessage` with JSON body `{"chat_id": <int64 parsed from external_chat_id>, "text": text, "disable_web_page_preview": false}` and `timeout_ms = 15_000`.
- `external_message_id = result.message_id` as decimal text.

**`pairing_url`** returns `"https://t.me/" + identity.bot_username + "?start=" + code`.

**Error mapping:**

| Telegram response | `Channel_Error_Kind` |
|---|---|
| httpc `.Timeout`, connection error, HTTP 5xx | `.Transient` |
| HTTP 429 | `.Rate_Limited`; `retry_after_ms = parameters.retry_after * 1000` |
| HTTP 401, 404 on the bot path | `.Unauthorized` |
| HTTP 403 (bot blocked by user), 400 "chat not found" | `.Chat_Unavailable` |
| other 4xx | `.Invalid_Request` |
| `cancel` set | `.Aborted` |

### 8.2 Fake Telegram server (test tool)

**File:** `tools/fake_telegram/server.mjs`. It is a Node 20 script with no dependencies. Usage:

```text
node tools/fake_telegram/server.mjs --port 18099 --token TEST:FAKE --bot-username ninjy_test_bot
```

**Bot API endpoints** (`/bot<token>/...`; a wrong token gets 401):

- `getMe`;
- `getUpdates` (honours `offset` and `timeout`, holds up to `timeout` seconds while the queue is empty);
- `sendMessage` (records the message, returns an incrementing `message_id`).

**Control endpoints** for tests:

- `POST /_control/inject {"chat_id":111,"from_id":222,"username":"alice","text":"hi","chat_type":"private"}` → `{"update_id":N}`
- `GET /_control/sent?chat_id=111` → `{"messages":[{"message_id":1,"chat_id":111,"text":"..."}]}`
- `POST /_control/fail {"method":"sendMessage","status":429,"retry_after":1,"count":1}` makes the next `count` calls fail.
- `GET /_control/offsets` → the list of offsets `getUpdates` was called with, so tests can check acknowledgement ordering.

## 9. Hub channel layer: poller, inbound, pairing, send

**Package:** `src/hub/service/bots/`. Files: `runtime.odin`, `poller.odin`, `inbound.odin`, `pairing.odin`, `channel_send.odin`, `service.odin`, `placement.odin`, `delivery.odin`, `supervisor.odin`, `copy.odin`.

### 9.1 Service struct

```odin
Bots_Service :: struct {
	repo:          ^iface.Bot_Repository,
	experiments:   ^iface.Experiment_Repository,
	agents:        ^agent_service.Agent_Service,
	providers:     ^provider_service.Provider_Service,
	bridges:       ^iface.Bridge_Repository,
	registry:      ^project_service.Bridge_Runtime_Registry,
	command_sink:  ^project_service.Bridge_Command_Sink,
	adapter:       ^channel.Channel_Adapter, // nil when no token is configured
	clock:         ^platform.Clock,
	ids:           ^platform.Id_Generator,
	timers:        Bot_Timer_Config,
	mutex:         sync.Mutex,               // serializes delivery/attempt transitions
	boot_unix_ms:  i64,
	hello_queue:   [dynamic]string,          // bridge ids from bots_on_bridge_hello; drained by the supervisor (11.6 step 3)
	last_waiting_recheck_ms: i64,            // supervisor clock for 11.1 row 10
}
```

- **Field types.** The field types name the existing repository and service types the wiring already builds in `src/hub/app/wiring.odin` (`build_graph`, `wiring.odin:214`).
- **Lock order.** `Bots_Service.mutex` MUST NOT be held while calling into `agent_service` procs that take `reconfiguration_mutex`. Release it, call, re-acquire, then re-read the row with CAS (`delivery_update` and `attempt_update` with an expected state).

### 9.2 Copy

**File:** `src/hub/service/bots/copy.odin`. These are all hub-generated Telegram texts, verbatim:

```odin
COPY_PAIRED :: "Connected to your Ninjy bot. Messages in this chat are not end-to-end encrypted: Telegram and your Ninjy hub can read them. Anyone who can send messages from this Telegram account can instruct your bot, which runs commands on your machines. Send /disconnect to disconnect."
COPY_PAIR_INVALID :: "This link has expired or was already used. Open Settings > Bots in Ninjy to get a new one."
COPY_PAIR_CHAT_TAKEN :: "This Telegram chat is already connected to another Ninjy account."
COPY_PAIR_NOT_ENABLED :: "Bots are not enabled for this Ninjy account. Turn on Bots in Settings > Experimental, then try again."
COPY_PAIR_NO_BOT :: "You have no Ninjy bot yet. Create one in Settings > Bots, then use the Connect link."
COPY_NOT_CONNECTED :: "This chat is not connected to Ninjy. Open Settings > Bots in Ninjy to connect it."
COPY_PRIVATE_ONLY :: "Ninjy bots work only in private chats."
COPY_UNSUPPORTED :: "Only text messages are supported for now."
COPY_REPLACED :: "This chat was disconnected from Ninjy because another chat was connected."
COPY_DISCONNECTED :: "Disconnected from Ninjy. Your messages here are no longer delivered to your bot."
COPY_NO_MACHINE :: "No machine is available right now. Your message is saved and will be answered when one is."
COPY_GAVE_UP :: "Your bot could not answer after several tries. Your message is saved; send another message to try again."
```

### 9.3 Poller loop

**Thread proc:** `bots_poller_thread(rt: ^Bots_Runtime)` in `poller.odin`.

```text
loop until stop:
  if adapter.identity fails: log kind, sleep 30 s (interruptible), continue
  cursor := repo.cursor_get("telegram") or ""
  batch, next, err := adapter.poll(cursor, &stop)
  if err.kind == .Aborted: exit
  if err.kind == .Unauthorized: log "telegram: token rejected", sleep 300 s, continue
  if err: sleep backoff (1 s, doubling, cap 60 s; reset on success), continue
  rows := map each Inbound to a Channel_Message per 9.4 (only kind .Text with an active, enabled binding)
  inserted, store_err := repo.inbound_store_batch("telegram", rows, next, now)   // one tx: rows + cursor
  if store_err: sleep 5 s, continue          // cursor not advanced → same batch is re-polled
  for each Inbound in batch: run its side effect per 9.4 (pairing, replies, notices)
  for each bot with a newly inserted row: delivery_on_inbound(s, bot_id, now) // 11.1 row 1; signature in 11.9
  free_all(context.temp_allocator)
```

**Ordering rule (REQ-S1-9).** Telegram learns that updates were received only when it gets the next `getUpdates` call with `offset = next`. That call happens only after `inbound_store_batch` has committed. If the hub crashes between commit and the next poll, Telegram re-sends the same updates, and `INSERT OR IGNORE` on `channel_messages_update_key` drops them.

**Duplicate side effects.** Side effects that send Telegram text (pairing replies and notices) are not stored. A crash between commit and send can repeat or lose one notice. This is accepted for slice 1, and section 23 records it.

### 9.4 Inbound handling

Rules for each `Inbound`, in order:

| # | Condition | Store | Side effect |
|---|---|---|---|
| 1 | `!chat_is_private` | nothing | `send_text(COPY_PRIVATE_ONLY)` |
| 2 | `kind == .Start` | nothing | pairing per 9.6 |
| 3 | no active binding for `(telegram, external_chat_id)` | nothing | `send_text(COPY_NOT_CONNECTED)` |
| 4 | binding owner has the experiment off | nothing | nothing |
| 5 | `kind == .Disconnect` | nothing | disconnect per 9.7 with `notify=true` |
| 6 | `kind == .Unsupported` | nothing | `send_text(COPY_UNSUPPORTED)` |
| 7 | `external_user_id != binding.external_user_id` | nothing | nothing |
| 8 | `kind == .Text` | `channel_messages` inbound row: `binding_id`, `owner_user_id`, `bot_id` from the binding; `body = text`; `provider_update_key = update_key`; `created_at = now` | `delivery_on_inbound(bot_id)` after commit |

- **Rows 1–7** produce no row. Their update keys are not stored, so a re-polled batch repeats their side effect (see 9.3).
- **Body limit.** A text longer than 16 384 bytes is stored truncated to the last complete UTF-8 character at or before 16 384 bytes, followed by `"\n[truncated]"`.

### 9.5 Sending text (used by `ham-ctl channel send` and by notices)

**Proc:**

```odin
channel_send :: proc(s: ^Bots_Service, binding: domain.Channel_Binding, text: string, record: bool) -> (message_ids: []string, err: domain.Domain_Error)
```

1. **Split.** Split `text` into chunks of at most 4000 bytes:
   - cut at the last `'\n'` within the window;
   - else at the last space;
   - else at the last UTF-8 character boundary.
   - Chunks keep their order. Empty chunks are dropped.
2. **Record.** When `record` is true, insert one outbound `channel_messages` row per chunk with `send_state='pending'` before sending. Agent replies use `record = true`. Hub notices (9.2) use `record = false`.
3. **Send.** Send each chunk with `adapter.send_text`. Retry policy for each chunk:
   - `.Transient`: up to 3 attempts, sleeping 1 s and then 2 s;
   - `.Rate_Limited`: wait `retry_after_ms`, up to 3 attempts, total wait capped at 20 s;
   - any other kind: no retry.
4. **Mark.** Mark each row `sent` with its `external_message_id`, or `failed` with `send_error = <kind name>`.
5. **Stop on failure.** If a chunk fails, the remaining chunks are not sent; their rows are marked `failed` with `send_error='not_sent'`. The proc returns a `domain_error(.Provider_Unavailable, "channel send failed")` with details `{"code":"channel_send_failed","kind":"<kind>"}`.
6. **No adapter.** When the adapter is nil (no token), it returns `domain_error(.Provider_Unavailable, "telegram is not configured on this hub")` with details `{"code":"channel_not_configured"}`.

### 9.6 Pairing

**Creating a link** (`POST /api/v1/bots/me/channels/telegram/pairing`, section 15):

1. Requires: an existing bot, the experiment on, and an adapter.
2. Generates a code of 32 lowercase hex characters from 16 bytes of CSPRNG (`src/hub/platform`). It stores `code_hash = hex(sha256(code))` with `expires_at = now + bot_pairing_ttl_ms` (default 10 min).
3. Deletes the owner's earlier unconsumed pairings first (`pairing_delete_for_owner`).
4. Returns `pairing_url = adapter.pairing_url(identity, code)` and `expires_at`. The code itself is never stored.

**Handling `/start <payload>`:**

| # | Condition | Result |
|---|---|---|
| 1 | `payload == ""` | if the chat has an active binding: nothing; else `COPY_NOT_CONNECTED` |
| 2 | no pairing with `code_hash = sha256(payload)`, or `consumed_at != ''`, or `expires_at <= now` | `COPY_PAIR_INVALID` |
| 3 | pairing owner has the experiment off | `COPY_PAIR_NOT_ENABLED` |
| 4 | pairing owner has no bot | `COPY_PAIR_NO_BOT` |
| 5 | chat has an active binding owned by **another** user | `COPY_PAIR_CHAT_TAKEN`; pairing left unconsumed |
| 6 | chat has an active binding owned by the **same** user | consume the pairing; reply `COPY_PAIRED` |
| 7 | otherwise | `binding_activate`: consume the pairing, revoke the owner's previous active Telegram binding, insert a new active binding `chb_…` with `external_display = sender_display`. Reply `COPY_PAIRED` to this chat. If a previous binding was revoked: purge its messages (9.7) and send `COPY_REPLACED` to the old chat |

Row 7 also publishes a user event so the Settings page refreshes. It uses the existing user event bus (`src/hub/service/events`) with event type `bot_changed` and payload `{"bot_id":"…"}`.

### 9.7 Disconnect

**Proc:**

```odin
bots_disconnect(s, owner_user_id: string, notify: bool) -> domain.Domain_Error
```

1. Revoke the active binding.
2. Purge its messages: `body=''`, `body_purged=1`.
3. Mark the open delivery `abandoned` with `finish_reason='binding_revoked'`. Mark its open attempt `cancelled`.
4. When `notify`, send `COPY_DISCONNECTED` to the chat.
5. Publish `bot_changed`.

`DELETE …/channels/telegram` calls it with `notify=true`. `/disconnect` in the chat also calls it with `notify=true`.

## 10. Placement policy and bridge selection

### 10.1 Policy semantics

A bot's policy is the ordered list `bot_placement_candidates`. A concrete triple `(bridge, provider, model)` **matches** a row when each field equals the row's value or the row's value is `*`.

- **Empty list.** Every owner bridge, every provider and every model is allowed, all at tier `allowed`. This is the default (REQ-S1-2).
- **Non-empty list.** A triple is allowed only if it matches some row. Its **rank** comes from the first matching row: `preferred` rows rank before `allowed` rows, then by ascending `position`.

**Validation** on `PUT …/placement` (all errors are 400 `validation_failed`, with `details.code` as listed):

| Check | `details.code` |
|---|---|
| at most `BOT_MAX_PLACEMENT_CANDIDATES` rows | `too_many_candidates` |
| `position` is `0..n-1` in array order (the request has no position field; position = index) | — |
| `bridge_id` is `*` or a bridge owned by the user (not required to be online) | `unknown_bridge` |
| `provider` is `*` or a provider id in the hub catalog | `unknown_provider` |
| `model` is `*`, or `provider` is concrete | `model_requires_provider` |
| no two rows with an identical `(bridge_id, provider, model)` | `duplicate_candidate` |

### 10.2 Bridge eligibility

Bridge `B` is **eligible** for bot `b` when all of the following hold:

1. `B.owner_user_id == b.owner_user_id`;
2. `B.status == .Online` and `bridge_runtime_registry_has_live(registry, B.bridge_id)`;
3. `require_launch_bridge_enabled` passes (plan limits), as the relocation code uses it (`instance_reconfiguration.odin:113`);
4. `bridge_feature_supported(B, "bot_deliver_v1") && bridge_feature_supported(B, "instance_reconfiguration_v1")` (REQ-S1-16);
5. the expanded candidate list for `B` (10.3) is non-empty.

### 10.3 Candidate expansion for one bridge

**Proc:**

```odin
bots_expand_candidates :: proc(s: ^Bots_Service, bot: domain.Bot, policy: []domain.Bot_Placement_Candidate, bridge_id: string) -> []contracts.Bot_Candidate_Wire
```

1. `views := provider_service.list_bridge_providers(s.providers, bridge_id)` (`src/hub/service/provider/provider_service.odin:359-412`). Keep views where all of these hold:
   - `view.enabled`;
   - `detection_state == "present"`;
   - the profile is enabled and not missing.
2. For each kept view, the models are its effective model list entries with state `active`, in list order (`effective_model_observation`, `provider_models.odin:10`).
3. Build every `(bridge_id, view.provider, model)` triple. Keep the allowed ones (10.1).
4. Sort by rank. Where the policy is empty or ranks tie, use catalog provider order, then effective model list order.
5. **`*` model.** When the matching row's model is `*`, emit only the **first** active model of that provider. Otherwise emit the named model.
6. Drop duplicate `(provider, model)` pairs, keeping the first.
7. Truncate to `bot_max_local_candidates` (default 3).
8. Each wire entry gets `provider_profile = view.profile_id` and `tier` from the matching row (`allowed` for an empty policy).

### 10.4 Bridge ranking

**Proc:**

```odin
bots_select_bridge(s, bot, delivery, round) -> (bridge_id: string, found: bool)
```

1. **Candidates.** Eligible bridges (10.2) that have no attempt in `(delivery, round)`.
2. **Sticky.** If the bot has an instance and its `bridge_id` is in the set, return it.
3. **Otherwise**, order by:
   - the best rank of any expanded candidate on that bridge;
   - then the bridge's `created_at`, ascending (oldest enrolled first);
   - then `bridge_id` ascending.
   Return the first.

## 11. Hub delivery engine

### 11.1 Delivery state machine

**Definitions used in this table**, evaluated on a supervisor tick for a delivery `d` of bot `b` in round `r = d.round`:

- `E` = the bridges that are eligible for `b` (10.2) at this tick.
- `U` = `E` minus every bridge that has an attempt in `(d, r)`.
- `A` = the attempts of `(d, r)`; "the round has attempts" means `len(A) > 0`.
- **Round end** = `len(A) > 0`, every attempt in `A` is terminal (11.2), and `U` is empty.

| # | From | Event | To | Action |
|---|---|---|---|---|
| 1 | — | `delivery_on_inbound(b)` is called (a new inbound row was committed, 9.3) and `b` has no open delivery | `pending` | `round=1`, `through_message_id` = newest pending message. This is the only way, besides R3 (11.3), that a delivery is created. Abandoning a delivery never creates a new one |
| 2 | `pending` | tick, `U` non-empty | `dispatched` | select from `U` (10.4); create an attempt (11.4) |
| 3 | `pending` | tick, `E` empty | `waiting` | `waiting_reason='no_bridge'`; send `COPY_NO_MACHINE` if `waiting_notice_at` is empty, then set it |
| 4 | `pending` | tick, round end, some attempt in `A` is `busy` | `waiting` | `waiting_reason='busy'`; no notice |
| 5 | `pending` | tick, round end, no attempt in `A` is `busy` | `abandoned` | `finish_reason='all_tried'`; send `COPY_GAVE_UP` |
| 6 | `dispatched` | attempt → `acted` | `acted` | `finished_at=now`, `finish_reason='acted'`; then 11.3 rule R3 |
| 7 | `dispatched` | attempt → `exhausted`, `busy`, `deadline`, or `disconnected` other than by 11.5.1 | `pending` | the next tick applies rows 2–5 in the same round |
| 8 | `dispatched` | attempt → `disconnected` by 11.5.1 (stranded relocation) | `waiting` | `waiting_reason='relocation_stranded'`; send `COPY_NO_MACHINE` if `waiting_notice_at` is empty, then set it |
| 9 | `dispatched` | hub observes the reply (11.3 R2) | `acted` | the open attempt → `acted` (`report_json` untouched) |
| 10 | `waiting` (`no_bridge`) | waiting re-check (below) finds `E` non-empty | `pending` | wake-up rule (below) |
| 11 | `waiting` (`busy`) | `now - finished_at` of the newest `busy` attempt in `A` ≥ `bot_busy_retry_ms` | `pending` | wake-up rule |
| 12 | `waiting` (`relocation_stranded`) | hello from the bridge that holds the instance (`inst.bridge_id`) | `pending` | wake-up rule |
| 13 | `waiting` (any reason) | placement changed (`PUT …/placement` succeeded) | `pending` | wake-up rule |
| 14 | `waiting` | new inbound message | `waiting` | `through_message_id` = newest pending message; no new notice |
| 15 | `pending` or `dispatched` | new inbound message | same | `through_message_id` unchanged; the message waits for R3 |
| 16 | any open | binding revoked | `abandoned` | `finish_reason='binding_revoked'`; no notice |
| 17 | any open | bot deleted | `abandoned` | `finish_reason='bot_deleted'`; no notice |
| 18 | any open | experiment turned off | `abandoned` | `finish_reason='experiment_disabled'`; no notice |

**Wake-up rule** (rows 10–13). Clear `waiting_reason`. If the round has attempts, set `round += 1`. If `round > bot_max_rounds` after that, go to `abandoned` instead, with `finish_reason='max_rounds'`, and send `COPY_GAVE_UP`. `waiting_notice_at` is not cleared, so one delivery sends `COPY_NO_MACHINE` at most once.

**Waiting re-check** (row 10). The supervisor runs it for every `waiting` delivery with `waiting_reason='no_bridge'`:

- on the first tick after `bots_on_bridge_hello` for a bridge owned by the delivery's owner (11.7 sets the request flag; the check itself runs on the tick);
- for all such deliveries at once, every `bot_waiting_recheck_ms` (30 000 ms) measured on the supervisor's in-memory `last_waiting_recheck_ms`. This covers a bridge whose provider inventory arrives after its hello.

The re-check computes `E` with the full 10.2 rules. Eligibility is checked on the tick, never in the hello hook.

**`waiting_reason` values:** `no_bridge`, `busy`, `relocation_stranded`. No other value is written.

**`finish_reason` values:** `acted`, `all_tried`, `max_rounds`, `binding_revoked`, `bot_deleted`, `experiment_disabled`.

**Why row 5 abandons.** A round end with no `busy` attempt means every eligible bridge was tried in this round and none could act. Waiting would never end while those bridges stay online (nothing would change). Abandoning sends `COPY_GAVE_UP`. The user's messages stay pending (`replied_at=''`), so the user's next message runs row 1, and its new delivery's `channel read` returns the earlier messages too.

- **Terminal states:** `acted`, `abandoned`.
- **Placement change.** Row 13 applies because a placement change can make new bridges eligible, and row 5 does not apply until that new round ends.

### 11.2 Attempt state machine

| From | Event | To |
|---|---|---|
| — | bridge selected, relocation needed (11.5) | `relocating` |
| — | bridge selected, no relocation needed | `sent` (frame sent) |
| `relocating` | relocation op phase `ready` | `sent` (frame sent) |
| `relocating` | relocation op phase `failed`, or `recovery_required` resolved by force stop (11.5) | `sent` with `skip` = the destination candidate, reason `relocation_failed` |
| `relocating` | destination bridge disconnects | `disconnected` |
| `relocating` | `bot_relocation_wait_ms` (default 240 s) since `created_at` | `deadline` |
| `sent` | `command_result` with status `succeeded` or `accepted` for `cmd_bot_<attempt_id>` | `accepted` |
| `sent` | `command_result` failed | `exhausted` (reason = the wire error code) |
| `sent` | `bot_attempt_accept_ms` (15 s) since `sent_at` | `deadline` |
| `sent`/`accepted` | `bot_delivery_report` with `state:"working"` | unchanged; `last_report_at = now` |
| `sent`/`accepted` | report `acted` | `acted` |
| `sent`/`accepted` | report `exhausted` | `exhausted` |
| `sent`/`accepted` | report `busy` | `busy` |
| `accepted` | `now - max(last_report_at, accepted_at, boot) > bot_attempt_silence_ms` (90 s) | `deadline` |
| any open | `now - created_at > bot_attempt_total_ms` (60 min) | `deadline` |
| any open | bridge WS disconnect | unchanged; `disconnected_at = now` |
| any open with `disconnected_at` set | same bridge hello within `bot_disconnect_grace_ms` (30 s) | unchanged; `disconnected_at=''`; re-send frame (11.7) |
| any open with `disconnected_at` set | `now - disconnected_at > bot_disconnect_grace_ms` | `disconnected` |
| any open | delivery abandoned | `cancelled` |

**Terminal attempt states:** `acted`, `exhausted`, `busy`, `disconnected`, `deadline`, `cancelled`.

**Leaving an attempt open on the bridge.** When an attempt ends by `deadline` or `cancelled` while its bridge is live, the hub MUST NOT send a stop command just for that. The next attempt either relocates the instance, which stops it, or runs on the same bridge, which the bridge handles (13.2). A late report for a finished attempt is acknowledged and ignored.

### 11.3 Reading and replying (hub-observed)

- **R1, read.** `channel read` (16.2) marks pending messages read. A delivery's progress is not changed by it.
- **R2, reply.** `channel send` from the bot instance does the following, after the Telegram send succeeds:
  1. Runs `messages_mark_replied(bot_id, now)`.
  2. If the open delivery's `through_message_id` now has `replied_at != ''`, moves the delivery to `acted` and its open attempt to `acted`.
  This makes acknowledgement independent of the bridge report. A re-sent or late `bot_deliver` cannot re-run work that was already answered.
- **R3, after acted.** When a delivery reaches `acted` and `messages_pending(bot_id)` is non-empty, create a new `pending` delivery at once.

### 11.4 Dispatching an attempt

```text
attempt := {attempt_id: new "bda_", delivery_id, round, bridge_id: B, state: ..., created_at: now}
candidates := bots_expand_candidates(bot, policy, B)
if bot.agent_instance_id == "":
    inst := prepare_instance(agents, Internal_User(owner), {agent_id: bot.agent_id, bridge_id: B,
             provider: candidates[0].provider, provider_profile: candidates[0].provider_profile,
             model: candidates[0].model, display_name: bot.display_name})
    repo.bot_set_instance(bot.bot_id, inst.agent_instance_id)
    → state = sent, send frame
elif instance.bridge_id == B:
    → state = sent, send frame
else:
    → state = relocating (11.5)
```

**Sending the frame:**

1. Store `candidates_json`. Read the instance row fresh and set `current_provider` and `current_model` in the frame from its `provider` and `model`. A re-sent frame (12.7) is rebuilt with the values read at re-send time.
2. Set `sent_at = now`.
3. Call `bridge_command_send_runtime` with the `bot_deliver` JSON (12.3).
4. If the send returns `Bridge_Offline`, the attempt goes straight to `disconnected`.

**Assumption** (verify in A2a): `prepare_instance` does not reserve runtime capacity that must be cancelled when no launch follows. Survey: `create_instance = prepare_instance + send_instance_launch` (`agent_service.odin:330`, `:414`). If `prepare_instance` returns a reservation `generation`, A2a MUST cancel it with `bridge_runtime_instance_cancel_reservation`, as `begin_instance_reconfiguration` does (`instance_reconfiguration.odin:158`).

### 11.5 Relocation to another bridge

1. Read the instance fresh.
2. Call `begin_instance_reconfiguration` (`instance_reconfiguration.odin:88`) with:
   - auth `Auth_Context{kind = .Internal_User, user_id = owner}`;
   - input `{bridge_id: B, project_id: "", provider: candidates[0].provider, provider_profile: candidates[0].provider_profile, model: candidates[0].model, idempotency_key: "bot:" + attempt_id, expected_revision: inst.configuration_revision}`.

   `relocation_key` stores the idempotency key.
3. **On error:**
   - `.Conflict` with an open operation (`reconfiguration_require_idle`): go to 11.5.1.
   - Any other error: the attempt goes to `exhausted` with `report_json = {"reason":"relocation_refused","detail":<message>}`.
4. **Watching the operation.** The supervisor reads it each tick (`instance_reconfiguration_get(agents, owner, instance_id, relocation_key)`):

   | Phase | Action |
   |---|---|
   | `ready` | send the frame |
   | `failed` | send the frame with `skip=[{provider, model, reason:"relocation_failed"}]` |
   | `recovery_required` | go to 11.5.1 |
   | any other | keep waiting |

**Why this works across offline sources.** The relocation fences an offline source and launches on the destination (`instance_reconfiguration.odin:231-237`). A stale runtime on the old bridge is killed after its next heartbeat (`detect_superseded_instances`, `agent_service.odin:1367`). The instance id and `conversation_id` do not change (REQ-S1-5).

#### 11.5.1 Resolving a blocking relocation operation

When the bot's instance has an operation that blocks input (`instance_reconfiguration_blocks_input`, `src/hub/domain/instance_reconfiguration.odin:70`), the supervisor resolves it:

- **Bridge live.** If the bridge that currently holds the instance (`inst.bridge_id`) is live, call `stop_instance(agents, Internal_User(owner), instance_id, {reason: "bot_recovery", force: true})`. This goes through `force_stop_instance_reconfiguration_locked` (`instance_reconfiguration.odin:487-506`); once the bridge confirms the stop, the operation becomes `failed` with `recovery_stopped`, which no longer blocks input (`domain/instance_reconfiguration.odin:70-72`). The attempt stays `relocating` until then.
- **Bridge not live.** Force stop needs the live bridge (`instance_reconfiguration.odin:494`). The attempt goes to `disconnected` and the delivery goes to `waiting` with `waiting_reason='relocation_stranded'` (11.1 row 8). It returns to `pending` on the hello of `inst.bridge_id` (11.1 row 12, wake-up rule), and the next dispatch finds the blocking operation again and force-stops as above. This is a known limit; see section 23, Q1.

### 11.6 Supervisor

**Thread proc:** `bots_supervisor_thread(rt)`. It ticks every `bot_supervisor_tick_ms` (1000 ms). It is interruptible and uses the start/stop pattern from 4.4.

Each tick runs, in order:

1. **Attempt timers.** For each open attempt: the timers in 11.2 and the relocation watch in 11.5.
2. **Pending deliveries.** For each `pending` delivery: select and dispatch (11.4), or move to `waiting` (11.1).
3. **Hello queue.** Drain `Bots_Service.hello_queue` (11.7). For each bridge id in it: run the waiting re-check (11.1 row 10) for `no_bridge` deliveries of that bridge's owner, and apply 11.1 row 12 to `relocation_stranded` deliveries whose instance's `bridge_id` is that bridge.
4. **Busy retry.** For each `waiting` delivery with `waiting_reason='busy'`: apply 11.1 row 11.
5. **Periodic re-check.** When `now - last_waiting_recheck_ms >= bot_waiting_recheck_ms`: run the waiting re-check for every `no_bridge` delivery, then set `last_waiting_recheck_ms = now`.
6. **Idle stop.** Runs every 60 s. For each bot that has an instance and no open delivery, whose instance `runtime_status` is active (`runtime_expected_active`, `agent_service.odin:1727`), and whose newest delivery `finished_at` (or `bots.updated_at` when there is none) is older than `bot_idle_stop_ms`: call `stop_instance(agents, Internal_User(owner), id, {reason: "bot_idle"})`.
7. **Retention.** Runs every 3600 s: `messages_purge_older_than(now - bot_channel_retention_ms)`.

Every transition MUST:

- use CAS on the expected state;
- run with `Bots_Service.mutex` held, except for agent-service calls (9.1).

### 11.7 Hello and disconnect hooks

- **`bots_on_bridge_hello(s, bridge_id)`.** Called in `bridge_ws_upgrade_handler` right after `taskv2.on_bridge_hello` (`src/hub/transport/http/bridge_handlers.odin:1885`). It:
  1. clears `disconnected_at` on open attempts on this bridge that are within grace, and re-sends their frame (12.3, same `command_id`);
  2. appends `bridge_id` to `Bots_Service.hello_queue` (`[dynamic]string`, guarded by `Bots_Service.mutex`). It changes no delivery. The supervisor's next tick applies 11.1 rows 10 and 12 from the queue (11.6 step 3), so eligibility (10.2) is checked in exactly one place: the tick.
- **`bots_on_bridge_disconnect(s, bridge_id)`.** Called from `bridge_disconnect_persist` (`bridge_handlers.odin:1928`) after the instances are marked unreachable. It sets `disconnected_at = now` on open attempts on this bridge.
- **Both hooks:**
  - MUST return at once when no user has the experiment on (`experiment_count_enabled == 0`);
  - MUST NOT block the WS reader on Telegram I/O. Notices are sent by the supervisor, not by the hooks.

### 11.8 Report handling

**Where.** In `bridge_ws_process_frame` (`bridge_handlers.odin:2335`, switch at `:2410`), add `case "bot_delivery_report":` before the default arm (`:2734`). It calls `bots_on_report(s, bridge_id, frame_json)`. Without this case, the default arm answers `unknown_frame_type` (`bridge_handlers.odin:2737`).

**`bots_on_report`:**

1. Parse into `contracts.Bot_Delivery_Report_Wire`. On parse failure, return `parse_failed = true`; the arm replies with a `protocol_error` frame, as the default arm does (11.9).
2. Load the attempt. If it is missing, or `attempt.bridge_id != bridge_id`, ack and ignore.
3. If `seq <= attempt.report_seq`, ack and ignore (duplicate).
4. Store `report_json` and `report_seq`; set `last_report_at = now`.
5. Apply 11.2 transitions for `state`. A report for a terminal attempt is acked and ignored.
6. Return `{"type":"bot_delivery_report_ack","attempt_id":…,"seq":…}`. The `case "bot_delivery_report":` arm writes it on the same connection (11.9).

**Command results.** `command_result` frames for `cmd_bot_*` ids already reach `runtime_command_result_for_connection` (`bridge_handlers.odin:2537`). Add one call there, `bots_on_command_result(s, bridge_id, command_id, status, error_code)`, for ids with prefix `cmd_bot_`.

### 11.9 Hub proc signatures

Every proc below is in package `bots` (`src/hub/service/bots/`). "Owner" is the ticket that writes the final body. Where another ticket needs the proc earlier, it adds the stub named in the last column, and the owner replaces the body without changing the signature.

```odin
// inbound.odin. Implements 11.1 row 1 exactly: in one transaction, if the bot has no
// open delivery, insert a `pending` delivery (round 1, through_message_id = newest
// pending inbound message). Otherwise apply row 14 (waiting) or row 15 (pending,
// dispatched). Never dispatches; the supervisor does. Called after inbound_store_batch commits.
delivery_on_inbound :: proc(s: ^Bots_Service, bot_id: string, now_ms: i64) -> domain.Domain_Error

// disable.odin. Implements the "Hub delivery engine" row of 4.3: every open delivery of
// the owner → `abandoned` (finish_reason 'experiment_disabled', no notice), its open
// attempt → `cancelled`; then, when the owner's bot has a running instance,
// stop_instance(agents, Internal_User(owner), id, {reason: "bot_experiment_disabled"}).
bots_on_experiment_disabled :: proc(s: ^Bots_Service, owner_user_id: string)

// runtime.odin. The on_changed hook installed on Experiment_Rest_Handlers (4.4).
// ctx is the ^Bots_Runtime. Ignores keys other than "bots". Calls bots_runtime_reconcile,
// then bots_on_experiment_disabled(owner) when !enabled.
bots_on_experiment_changed :: proc(ctx: rawptr, owner_user_id, key: string, enabled: bool)

// delivery.odin. Applies the 11.2 `command_result` rows to the attempt whose id is
// command_id without the "cmd_bot_" prefix. status is the payload status
// ("accepted", "succeeded", "failed"); error_code is the wire error code or "".
// Ignores unknown attempts, attempts on another bridge and terminal attempts.
bots_on_command_result :: proc(s: ^Bots_Service, bridge_id, command_id, status, error_code: string)

// delivery.odin. Implements 11.8 steps 1–5. Returns the ack JSON of 12.5 for the caller to
// write back on the same connection. When parse_failed is true, reply_json is "" and the
// caller in bridge_handlers.odin builds the refusal itself (service/bots MUST NOT import
// transport/http, 4.2): bridge_protocol_error_frame("bot_delivery_report",
// contracts.wire_error(.Validation_Failed, "invalid_bot_delivery_report",
// "bot_delivery_report could not be parsed")) (bridge_handlers.odin:2747).
// The caller writes the frame with write_ws_text_frame_locked (as at bridge_handlers.odin:2737) and deletes it.
bots_on_report :: proc(s: ^Bots_Service, bridge_id, frame_json: string) -> (reply_json: string, parse_failed: bool)

// delivery.odin. 11.7. Never blocks on Telegram I/O; never changes a delivery.
bots_on_bridge_hello :: proc(s: ^Bots_Service, bridge_id: string)
bots_on_bridge_disconnect :: proc(s: ^Bots_Service, bridge_id: string)
```

| Proc | Owner | Earlier stub |
|---|---|---|
| `delivery_on_inbound` | A5 | — (A5 writes the final body; A2a does not change it) |
| `bots_on_experiment_disabled` | A2a | A4 adds `disable.odin` with a body that only logs `bots: experiment disabled owner=<id>` |
| `bots_on_experiment_changed` | A4 | — |
| `bots_on_command_result`, `bots_on_report`, `bots_on_bridge_hello`, `bots_on_bridge_disconnect` | A2a | — |

**How `bridge_handlers.odin` reaches the service.** Add the field `bots: ^bots.Bots_Service` to `Bridge_Handlers` (`src/hub/transport/http/bridge_handlers.odin:39`), set in `wiring.odin` by A2a. Every call site MUST skip the call when `h.bots == nil`, so hub tests that build `Bridge_Handlers` without bots keep passing.

## 12. Hub–bridge protocol

### 12.1 Capability

- **Bridge.** Append `contracts.BRIDGE_FEATURE_BOT_DELIVER_V1` to `BRIDGE_RUNTIME_FEATURES` (`src/bridge/hub_runtime_client.odin:4418`). It is then sent in `bridge_hello.features` and in legacy heartbeats.
- **Hub.** No hello change is needed. The hub already stores `features` (`src/hub/service/bridge/bridge_service.odin:390-460`) and reads them with `bridge_feature_supported`.

### 12.2 Bridge command spec

In `bridge_command_spec` (`src/bridge/hub_command_dispatch.odin:245-325`):

```odin
case "bot_deliver":
	return {class = .Interactive, priority = .Interactive, key_kind = .Agent, queued = true, requires_id = true, timeout_ms = 10_000, cost_units = 2, coalescible = false, retry_safe = true}
```

- **Ordering key.** In `bridge_command_ordering_key` (`:353-410`), `bot_deliver` uses `"agent:" + agent_instance_id`, as `notify_*` and `launch_agent` do (`:402-405`).
- **Handler.** Add an `if type == "bot_deliver"` branch to `bridge_hub_handle_command` (`src/bridge/hub_runtime_client.odin:970-1574`) that calls `bridge_bot_handle_deliver(command_json)` (13.1).
- **Metrics label.** In `bridge_frame_kind` (`src/hub/service/project/runtime_metrics.odin:195`), add `"bot_deliver" → "bot"`.

### 12.3 `bot_deliver` (hub → bridge)

```json
{
  "type": "bot_deliver",
  "command_id": "cmd_bot_bda_01J9Z0T3",
  "bridge_id": "brg_18e8db5c741d67df",
  "agent_instance_id": "inst_18e8f0aa11223344",
  "bot_id": "bot_18e8f0a9aabbccdd",
  "delivery_id": "bdl_18e8f0b100000001",
  "attempt_id": "bda_01J9Z0T3",
  "through_message_id": "chm_18e8f0b0ffff0001",
  "pending_count": 2,
  "current_provider": "codex",
  "current_model": "gpt-6.1",
  "candidates": [
    {"provider": "claude", "provider_profile": "claude", "model": "opus", "tier": "preferred"},
    {"provider": "codex", "provider_profile": "codex", "model": "gpt-6.1", "tier": "allowed"}
  ],
  "skip": [],
  "timers": {
    "launch_ready_ms": 120000, "read_ms": 60000, "read_extend_ms": 60000, "read_max_extends": 4,
    "idle_no_reply_ms": 120000, "reply_cap_ms": 1800000, "progress_interval_ms": 30000
  }
}
```

- `candidates` is non-empty and ordered by rank. `skip` lists candidates the bridge MUST treat as already failed for this attempt.
- **Validation on the bridge.** Missing `attempt_id`, `agent_instance_id` or `candidates` → `bridge_command_failed_json(command_id, "validation_failed", …)` (`hub_runtime_client.odin:4195`). The hub maps that to attempt `exhausted`.

**Command result** (existing frame, `hub_runtime_client.odin:4162`). The dispatcher sends `accepted` on enqueue (`hub_command_dispatch.odin:530-630`). The handler then sends `succeeded` once its worker is registered:

```json
{"type":"command_result","protocol_version":1,"command_id":"cmd_bot_bda_01J9Z0T3","ok":true,"payload":{"status":"succeeded"}}
```

### 12.4 `bot_delivery_report` (bridge → hub)

```json
{
  "type": "bot_delivery_report",
  "protocol_version": 1,
  "delivery_id": "bdl_18e8f0b100000001",
  "attempt_id": "bda_01J9Z0T3",
  "agent_instance_id": "inst_18e8f0aa11223344",
  "seq": 4,
  "state": "exhausted",
  "phase": "done",
  "candidate_index": 1,
  "outcomes": [
    {"provider": "claude", "model": "opus", "outcome": "startup_blocked", "detail": "login"},
    {"provider": "codex", "model": "gpt-6.1", "outcome": "idle_no_reply", "detail": ""}
  ],
  "reason": "all_candidates_failed"
}
```

**`state` values:**

| Value | Meaning |
|---|---|
| `working` | progress; sent every `progress_interval_ms` and on every phase change |
| `acted` | the bot replied after reading |
| `exhausted` | every candidate failed; `reason = "all_candidates_failed"` |
| `busy` | the bridge cannot start any candidate now for a transient local reason; `reason` is `draining` or `vault_locked` (13.4 busy check) |

- `seq` starts at 1 and increases by one per report for the attempt.
- **Retries.** Terminal reports (`acted`, `exhausted`, `busy`) are held in memory and re-sent every 5 s until acked. They are also re-sent after reconnect. `working` reports are not retried.

### 12.5 `bot_delivery_report_ack` (hub → bridge)

```json
{"type":"bot_delivery_report_ack","attempt_id":"bda_01J9Z0T3","seq":4}
```

The bridge handles it in `bridge_hub_handle_command` as an unqueued type. It needs a `bridge_command_spec` case with `queued = false, requires_id = false` and calls `bridge_bot_handle_report_ack(command_json)` (13.9), which drops the held report for `(attempt_id, seq ≤ acked)`.

### 12.6 Switch route (bridge → hub, HTTP)

`POST /api/v1/bridge/bot-attempts/{attempt_id}/switch`. Auth: bridge bearer token (`bearer_token` + `verify_bridge_token`, `src/hub/service/bridge/bridge_service.odin:628`). Registered in `src/hub/app/wiring.odin` next to `"/api/v1/bridge/actions/*/execute"` (`wiring.odin:1036`).

Request:
```json
{"provider": "codex", "provider_profile": "codex", "model": "gpt-6.1"}
```
Response 200:
```json
{"data": {"agent_instance_id": "inst_18e8f0aa11223344", "provider": "codex", "provider_profile": "codex", "model": "gpt-6.1", "configuration_revision": 7, "relaunched": false}}
```

**Rules, in order:**

| # | Check | Error |
|---|---|---|
| 1 | bridge token valid | 401 `unauthenticated` |
| 2 | experiment on for the bridge owner | 403 `experimental_feature_disabled` |
| 3 | attempt exists, `attempt.bridge_id == token bridge`, attempt open | 404 `not_found`, details `{"code":"bot_attempt_not_found"}` |
| 4 | `(provider, model)` in `candidates_json` | 409 `conflict`, details `{"code":"bot_candidate_not_allowed"}` |
| 5 | instance's `bridge_id == token bridge` | 409 `conflict`, details `{"code":"bot_instance_elsewhere"}` |
| 6 | already on this provider and model | 200 with `relaunched:false`; no change |
| 7 | `reconfigure_instance(agents, Internal_User(owner), instance_id, {provider, provider_profile, model})` | its error, passed through by `respond_error`. A `reconfiguration_require_idle` conflict is returned as 409 `conflict` with details `{"code":"bot_relocation_open"}` |
| 8 | success | 200; `relaunched = runtime_expected_active(previous runtime_status)` |

**Assumption** (verify in A2a): `Reconfigure_Instance_Input` (`agent_service.odin:166`) has `provider`, `provider_profile` and `model` fields with `has_*` flags all false for the immutable fields. The survey confirms the immutable `has_*` checks at `agent_service.odin:1086`.

### 12.7 Re-send rules

| Situation | Hub action |
|---|---|
| bridge hello, open attempt `sent`/`accepted` on it, within grace | re-send the identical `bot_deliver` (same `command_id`); `sent_at` unchanged |
| bridge hello, attempt already `disconnected` | nothing for that attempt. The delivery is `pending` or `waiting`, and its next tick may pick this bridge only in a new round |
| hub restart | boot does not send anything; bridges reconnect and their hellos trigger the first row |

**Bridge handling of a re-sent frame:**

- the dispatcher claim cache drops an exact duplicate `command_id` while cached;
- otherwise `bridge_bot_handle_deliver` finds the worker by `attempt_id` and replies `succeeded` without starting a second worker (13.2);
- a bridge that restarted has no worker. It starts the attempt fresh. This is safe because `channel read` returns all unreplied messages (16.2), and R2 (11.3) acknowledges on the hub.

## 13. Bridge delivery worker

**Files:** `src/bridge/bot_delivery.odin`, with tests in `src/bridge/bot_delivery_test.odin`.

### 13.1 Entry point

```odin
bridge_bot_handle_deliver :: proc(command_json: string) -> string // returns the command_result JSON
```

- Parses `contracts.Bot_Deliver_Wire`.
- Registers it in `bridge_bot_workers: map[string]^Bridge_Bot_Worker`, keyed by `attempt_id` and guarded by `bridge_bot_workers_mutex`.
- Starts one thread per worker (`thread.create_and_start_with_data`).
- Returns `bridge_command_result_json(command_id, "succeeded", "")`.

### 13.2 Worker registry rules

- **Same attempt, worker exists.** A worker already exists for `attempt_id`: return `succeeded` and do nothing else.
- **Same instance, other attempt.** A worker exists for another attempt of the **same** `agent_instance_id`: the old worker is cancelled (its flag is set; it stops without a report), then the new one starts.
- **Lifetime.** A worker is removed after its terminal report is acked, or 10 min after it ends, whichever is first.
- **Bridge shutdown.** Workers are cancelled without reports.

### 13.3 Worker state (in memory only)

```odin
Bridge_Bot_Phase :: enum { Launching, Waiting_Ready, Notified, Read, Replying, Done }

Bridge_Bot_Worker :: struct {
	frame:            contracts.Bot_Deliver_Wire,
	cancel:           bool,             // atomic
	phase:            Bridge_Bot_Phase,
	candidate_index:  int,
	outcomes:         [dynamic]contracts.Bot_Candidate_Outcome_Wire,
	seq:              int,
	read_seen_ms:     i64,              // set by relay observation (13.7)
	reply_seen_ms:    i64,              // set by relay observation (13.7)
	notified_ms:      i64,
	read_extends:     int,
	idle_since_ms:    i64,              // continuous idle/waiting_user since; 0 when active
}
```

### 13.4 Candidate loop

**Order of candidates (provider stickiness).** The worker builds `order` once, before the loop:

1. `snap, found := bridge_runtime_instance_snapshot(instance)` (`src/bridge/hub_runtime_client.odin:3390`).
2. The **sticky candidate** is the entry `c` of `frame.candidates` with `c.provider == frame.current_provider` and `c.model == frame.current_model`, when all of these hold:
   - `found` and `bridge_runtime_status_active(snap.runtime_status)` (`hub_runtime_client.odin:3780`);
   - `c` is not in `frame.skip`;
   - `bridge_bot_candidate_backoff_active(c)` is false (13.8).
3. With a sticky candidate, `order = [sticky] + (frame.candidates without sticky, in frame order)`. Without one, `order = frame.candidates`.

The sticky candidate MUST NOT call the switch route and MUST NOT launch: the hub record already names it. The worker only waits for `READY` (which holds at once for a `running` or `idle` instance) and then delivers the notice. Every other candidate calls switch. A bot that is stopped (idle stop, crash) has no sticky candidate, so the next message uses the ranked order and the preferred candidate returns.

**Busy check.** Before the loop, the worker reports `busy` and ends (no candidate is tried, no outcome is recorded) when the first matching row applies:

| # | Check (existing bridge proc) | Busy when | `reason` |
|---|---|---|---|
| 1 | `sync.atomic_load(&bridge_hub_traffic_stopped)` (`src/bridge/hub_quiescence.odin:12`) | `true` | `draining` |
| 2 | `bridge_auto_update_launch_enter()` (`src/bridge/auto_update.odin:87`); on `true` the worker calls `bridge_auto_update_launch_leave()` (`auto_update.odin:95`) at once | `false` (an update reservation is active) | `draining` |
| 3 | `bridge_vault_status()` (`src/bridge/hub_runtime_client.odin:69`) | `!= .Unlocked` | `vault_locked` |

- There is no `capacity` reason. The bridge has no local limit on agent instances: the only bridge slot limit, `bridge_process_slot_has_capacity` (`src/bridge/process_deadline.odin:19`), counts shell processes, not agents. Plan limits on instances are checked on the hub (10.2 rule 3). The `busy` reason set is therefore exactly `draining` and `vault_locked`.
- A launch that `bridge_runtime_launch_agent` refuses because an update started after the check (`hub_runtime_client.odin:2616`, error with `retry_after_ms = 30_000`) is recorded as `launch_failed` with class `retriable` (13.8). It is not converted to `busy`.

**Loop:**

```text
report(working, Launching)
for cand in order:
    if cancel: exit silently
    if cand in frame.skip: outcomes += {cand, "skipped", skip.reason}; continue
    if !bridge_provider_runnable(cand.provider, cand.model): outcomes += {cand, "not_runnable", ""}; continue   // agent_wake.odin:146
    if cand != sticky and bridge_bot_candidate_backoff_active(cand): outcomes += {cand, "backoff", ""}; continue  // 13.8
    if cand == sticky:
        // already running on this candidate: no switch, no launch
        wait until READY or blocked or failed or launch_ready_ms elapsed   // passes at once when it is running/idle
        goto outcome
    // 1. make the hub record say this candidate
    pre, pre_found := bridge_runtime_get_launch(instance)        // hub_runtime_client.odin:2998
    pre_command_id := pre.command_id if pre_found else ""
    resp := POST /api/v1/bridge/bot-attempts/{attempt_id}/switch {cand}
    if resp.status != 200: outcomes += {cand, "switch_refused", detail}; continue
        // detail = "transport" when status is 0; else error.details.code; else "http_<status>"
    // 2. make it run
    if resp.relaunched:
        // The hub sent launch_agent for the new provider. The old process is still
        // running/idle until that command lands, so the snapshot status alone does not
        // prove the new runtime is ready. Wait for the new launch record first.
        wait until NEW_RUNTIME_READY or blocked or failed or launch_ready_ms elapsed
    else:
        snap := bridge_runtime_instance_snapshot(instance)
        if !bridge_runtime_status_active(snap.runtime_status):
            ok, detail, err := launch via descriptor: bridge_wake_fetch_enriched_launch_json + bridge_runtime_launch_agent   // agent_wake.odin:299, hub_runtime_client.odin:2615
            if !ok: outcomes += {cand, "launch_failed", err class}; record_failure(cand, err); continue
        wait until READY or blocked or failed or launch_ready_ms elapsed
  outcome:
    phase = Waiting_Ready; report(working)
    on blocked → outcomes += {cand, "startup_blocked", "login" if reason is login else "prompt"}; record_failure; continue
    on failed  → outcomes += {cand, "launch_failed", typed error class}; record_failure; continue
    on timeout → outcomes += {cand, "launch_timeout", ""}; record_failure; continue
    // 3. deliver the notice
    bridge_pty_host_deliver_to_agent(instance, "task_nudge", "telegram", "", "", human_message = BOT_NOTICE)   // pty_host_runtime.odin:759
    phase = Notified; notified_ms = now; report(working)
    // 4. watch (13.5)
    result := watch()
    if result == acted: report(acted, Done); return
    outcomes += {cand, result, ""}; record_failure(cand) for idle_no_reply and not_read
report(exhausted, Done, reason = "all_candidates_failed")
```

Every external call in the loop goes through its 13.10 seam (`bridge_bot_switch_proc`, `bridge_bot_launch_proc`, `bridge_bot_snapshot_proc`, `bridge_bot_launch_record_proc`, `bridge_bot_notice_proc`, `bridge_bot_report_proc`); the names above show which production proc each seam defaults to.

**Readiness predicates** (evaluated every 250 ms on fresh `bridge_runtime_instance_snapshot` and `bridge_runtime_get_launch` results):

- `READY`: `snap.runtime_status ∈ {"running", "idle"}` and `snap.start_success_seen`.
- `NEW_RUNTIME_READY`: `launch, ok := bridge_runtime_get_launch(instance)` gives `ok` and `launch.command_id != pre_command_id`, **and** `READY`. Why this is sound, from the bridge source: `bridge_runtime_launch_agent` sets the status to `starting` (`hub_runtime_client.odin:2693`), which clears `start_success_seen` (`:3283-3284`). Only after the new process is spawned does it call `bridge_runtime_record_launch` with the hub command's `command_id` (`:2835`), which replaces the instance's launch record (`:3012`). So once the launch record's `command_id` has changed, a later `READY` describes the new process. Each hub `launch_agent` command has its own `command_id` (`requires_id`, 12.2), so the id always differs from `pre_command_id`.
- `blocked`: `snap.runtime_status == "blocked"`. While waiting for `NEW_RUNTIME_READY`, a `blocked` status counts only after the launch record's `command_id` has changed.
- `failed`: `snap.runtime_status == "failed"`; the error class is `snap.last_error` when `snap.has_last_error`, else `retriable`.

- **Notice text.** `BOT_NOTICE` is verbatim (U+2014 dash, same style as `bridge_pty_host_message_notice`, `pty_host_runtime.odin:661-665`):

```text
New Telegram message for you — run './bin/ham-ctl channel read' to view and './bin/ham-ctl channel send --text "<reply>"' to answer.
```

- **Why `"task_nudge"`.** With a `human_message`, the bridge types that text verbatim (`pty_host_runtime.odin:668-679`). `interrupt` stays false, so a busy bot is not interrupted.
- **Rollover.** During a context rollover the notice MUST be queued with `bridge_rollover_queue_notice`, as `notify_agent_message` does (`hub_runtime_client.odin:1163-1186`). The read timer starts when the notice is actually typed.

### 13.5 Watch phase (not-acted detection)

The worker evaluates every 1000 ms. Let `act` be the local activity status of the instance before flattening: `active`, `idle`, `waiting_user` or `unknown`. It is `bridge_bot_activity_proc(instance)`, which reads the raw value recorded at the start of `bridge_runtime_note_agent_activity` before `bridge_runtime_normalize_activity_status` flattens it (13.10, `hub_runtime_client.odin:3127`, `:3356`).

| Phase | Condition | Result |
|---|---|---|
| any | `reply_seen_ms > 0` and `read_seen_ms > 0` and `reply_seen_ms >= read_seen_ms` | `acted` |
| any | instance status becomes `failed`, `stopped` or `unreachable` | outcome `crashed` |
| `Notified` | `read_seen_ms > 0` | phase → `Read`; `idle_since_ms = 0`; report `working` |
| `Notified` | `now - notified_ms >= read_ms + read_extends*read_extend_ms` and `act == active` and `read_extends < read_max_extends` | `read_extends += 1` |
| `Notified` | the same elapsed check, and not extendable | outcome `not_read` |
| `Read`/`Replying` | `act == active` | `idle_since_ms = 0`; phase → `Replying` |
| `Read`/`Replying` | `act ∈ {idle, waiting_user, unknown}` and `idle_since_ms == 0` | `idle_since_ms = now` |
| `Read`/`Replying` | `idle_since_ms > 0` and `now - idle_since_ms >= idle_no_reply_ms` | outcome `idle_no_reply` (detail `waiting_user` if `act == waiting_user`) |
| `Read`/`Replying` | `now - read_seen_ms >= reply_cap_ms` | outcome `reply_timeout` |

- **Reply without read.** A reply seen without a prior read does not count as acted. The bot must read the message first.
- **Progress.** `working` reports go out every `progress_interval_ms` regardless of phase.

### 13.6 Outcome codes

The `outcome` field values are fixed:

`skipped`, `not_runnable`, `backoff`, `switch_refused`, `launch_failed`, `startup_blocked`, `launch_timeout`, `crashed`, `not_read`, `idle_no_reply`, `reply_timeout`, `acted`.

### 13.7 Relay observation

**Where.** In `bridge_local_handle_agent` (`src/bridge/wrapper_endpoint.odin`), inside the `.Envelope` branch after a 2xx relay (`wrapper_endpoint.odin:563-571`). Add:

```odin
if method == "agent.channel.read" do bridge_bot_note_read(rec.agent_instance_id, relay.body, bridge_runtime_now_ms())
if method == "agent.channel.send" do bridge_bot_note_reply(rec.agent_instance_id, bridge_runtime_now_ms())
```

The two lines go after the `relay.status` check and before the `return` statements of the `.Envelope` branch, so they run only for a 2xx relay. `bridge_runtime_now_ms` is `hub_runtime_client.odin:3052`.

**Behaviour.** Both procs look up the live worker for that instance (by `frame.agent_instance_id`) and set `read_seen_ms` or `reply_seen_ms`. With no live worker they do nothing.

**Locating the messages in `relay.body`.** `relay.body` is the hub's HTTP response body. The hub builds it with `respond_success` (`src/hub/transport/http/respond.odin:22`), whose envelope is `{"data":<data>,"meta":{…}}` (`contracts.api_success_json`, `src/contracts/envelope.odin:50-56`). For `channel/read`, `<data>` is the 16.1 object, so the body is:

```json
{"data":{"messages":[{"message_id":"chm_…","body":"…","created_at":"…","sender":"@alice"}],"pending_total":1},"meta":{"request_id":"…","server_time":"…"}}
```

`bridge_bot_note_read` parses `relay.body` with `json.parse` (`core:encoding/json`) into the temp allocator and counts a read only when `root.(json.Object)["data"].(json.Object)["messages"].(json.Array)` exists and has at least one element. A parse failure, a missing key, a wrong type or an empty array is not a read. It never logs the body (it holds Telegram text).

### 13.8 Local candidate backoff

**State:** `bridge_bot_backoff: map[string]Bridge_Bot_Backoff`, keyed by `provider + "/" + model` and kept in memory.

**Failures that start a backoff:**

| Failure | Backoff |
|---|---|
| `launch_failed` with error class `retriable` | `60 s * 2^(n-1)`, cap 30 min, at least `retry_after_ms`; the same formula as `instance_retry_delay_ms` (`src/hub/service/agent/instance_failure.odin:52`) |
| `launch_failed` with error class `recoverable` or `fatal` | 30 min |
| `startup_blocked` | 30 min |
| `launch_timeout`, `not_read`, `idle_no_reply`, `crashed` | 5 min |

- **Reset.** An `acted` result clears the candidate's entry.
- **Why not the wake gate.** The bridge's wake gate (`agent_wake.odin:111`) is per instance, not per candidate. The bot worker MUST NOT call `bridge_task_wake_if_needed`. It calls the descriptor fetch and launch directly, as shown in 13.4.

### 13.9 Bridge proc signatures

All in package `main`, file `src/bridge/bot_delivery.odin`.

```odin
// 13.1. Returns the command_result JSON.
bridge_bot_handle_deliver :: proc(command_json: string) -> string

// 12.5. Drops held terminal reports of attempt_id with seq <= acked_seq.
bridge_bot_handle_report_ack :: proc(command_json: string)

// 13.7. relay_body is the hub response body of agent.channel.read (2xx only).
bridge_bot_note_read  :: proc(instance_id, relay_body: string, now_ms: i64)
bridge_bot_note_reply :: proc(instance_id: string, now_ms: i64)

// 13.8. Key is cand.provider + "/" + cand.model.
bridge_bot_candidate_backoff_active :: proc(cand: contracts.Bot_Candidate_Wire, now_ms: i64) -> bool
// outcome is a 13.6 code. err/has_err carry the launch error for launch_failed
// (its class picks the 13.8 row); other outcomes pass has_err = false.
bridge_bot_candidate_record_failure :: proc(cand: contracts.Bot_Candidate_Wire, outcome: string, err: Bridge_Error, has_err: bool, now_ms: i64)
bridge_bot_candidate_clear          :: proc(cand: contracts.Bot_Candidate_Wire)

// 13.4 busy check. Returns ("", false) when not busy.
bridge_bot_busy_reason :: proc() -> (reason: string, busy: bool)

// 13.5. One evaluation step of the watch table; pure, for tests.
// act is the unflattened activity status; status is snap.runtime_status.
bridge_bot_watch_step :: proc(w: ^Bridge_Bot_Worker, act, status: string, now_ms: i64) -> (result: string, done: bool)
```

| Proc | Owner |
|---|---|
| `bridge_bot_handle_deliver`, `bridge_bot_handle_report_ack`, `bridge_bot_candidate_backoff_active`, `bridge_bot_candidate_record_failure`, `bridge_bot_candidate_clear`, `bridge_bot_busy_reason` | A2b |
| `bridge_bot_note_read`, `bridge_bot_note_reply`, `bridge_bot_watch_step` | A3. A2b adds `bridge_bot_note_read` and `bridge_bot_note_reply` with these signatures and bodies that set the worker fields without the `data.messages` check, and a `bridge_bot_watch_step` that returns `acted` as soon as `reply_seen_ms > 0`. A3 replaces the three bodies |

### 13.10 Test seams

The worker reaches every outside dependency through a package-level proc variable in `src/bridge/bot_delivery.odin`. Production code MUST call only the variable. Tests assign a double and restore the default with `defer`. This lets A2b and A3 unit-test the worker with no hub and no provider process.

```odin
// POST /api/v1/bridge/bot-attempts/{attempt_id}/switch (12.6). The default builds an
// httpc.Request with httpc.bearer(bridge_credential_snapshot()), url = bridge_hub_url(),
// path = {"api","v1","bridge","bot-attempts",attempt_id,"switch"}, method .POST, and sends it
// with bridge_http_request_retry, as bridge_wake_fetch_enriched_launch_json does
// (agent_wake.odin:299-325). status is the HTTP status, 0 on transport failure;
// error_code is error.details.code, "" when absent. 13.4 maps both to the outcome detail.
bridge_bot_switch_proc: proc(attempt_id: string, cand: contracts.Bot_Candidate_Wire) -> (status: int, relaunched: bool, error_code: string) = bridge_bot_switch_http

// Descriptor fetch + launch (13.4 step 2): bridge_wake_fetch_enriched_launch_json then
// bridge_runtime_launch_agent with command_id "botl_" + attempt_id + "_" + candidate index.
bridge_bot_launch_proc: proc(instance_id, command_id: string) -> (ok: bool, detail: string, err: Bridge_Error) = bridge_bot_launch_via_descriptor

bridge_bot_snapshot_proc:      proc(instance_id: string) -> (Bridge_Runtime_Instance, bool) = bridge_runtime_instance_snapshot  // hub_runtime_client.odin:3390
bridge_bot_launch_record_proc: proc(instance_id: string) -> (Bridge_Runtime_Launch, bool)   = bridge_runtime_get_launch         // hub_runtime_client.odin:2998

// Types BOT_NOTICE (13.4 step 3), queuing it during a rollover. Returns false when the
// instance has no live PTY; the loop then records outcome crashed.
bridge_bot_notice_proc: proc(instance_id: string) -> bool = bridge_bot_deliver_notice

// Writes one bot_delivery_report frame on the current hub connection. Returns false when
// there is no connection; terminal reports stay held (12.4) either way.
bridge_bot_report_proc: proc(report_json: string) -> bool = bridge_bot_send_report

// Unflattened activity status of the instance (13.5): "active", "idle", "waiting_user"
// or "unknown", read from bridge_bot_raw_activity (below).
bridge_bot_activity_proc: proc(instance_id: string) -> string = bridge_bot_local_activity

// Inputs of the busy check (13.4). The default reads the three procs named there.
bridge_bot_busy_inputs_proc: proc() -> (traffic_stopped, update_reserved, vault_unlocked: bool) = bridge_bot_busy_inputs

bridge_bot_now_proc: proc() -> i64 = bridge_runtime_now_ms  // hub_runtime_client.odin:3052
```

**Raw activity (checked in the source).** The snapshot's `activity_status` cannot be used: `bridge_runtime_note_agent_activity` normalizes before storing (`hub_runtime_client.odin:3136`, and again at `:3143`), and normalization maps `waiting_user`, `waiting` and `waiting_approval` to `idle` (`:3356-3366`). A2b therefore adds:

- `bridge_bot_raw_activity: map[string]string` and `bridge_bot_raw_activity_mutex: sync.Mutex` in `bot_delivery.odin`;
- `bridge_bot_note_raw_activity :: proc(instance_id, activity_status: string)`, which stores the classified value: `active`, `working`, `busy` → `active`; `waiting_user`, `waiting`, `waiting_approval` → `waiting_user`; `idle`, `inactive` → `idle`; anything else → `unknown` (comparison on `strings.to_lower(strings.trim_space(…))`, as `:3357` does);
- one call, `bridge_bot_note_raw_activity(instance_id, activity_status)`, as the first statement of `bridge_runtime_note_agent_activity` (`hub_runtime_client.odin:3127`). That one line is the only change to that proc.

`bridge_bot_local_activity` returns the stored value, or `unknown` when there is none. The worker removes the instance's entry when it ends.

## 14. Timers and limits

### 14.1 Defaults

| Field (`Bot_Timer_Config`) | Default | Where it runs |
|---|---|---|
| `bot_attempt_accept_ms` | 15 000 | hub |
| `bot_attempt_silence_ms` | 90 000 | hub |
| `bot_attempt_total_ms` | 3 600 000 | hub |
| `bot_disconnect_grace_ms` | 30 000 | hub |
| `bot_relocation_wait_ms` | 240 000 | hub (longer than the 180 s relocation timeout, `instance_reconfiguration.odin:354`) |
| `bot_busy_retry_ms` | 120 000 | hub |
| `bot_waiting_recheck_ms` | 30 000 | hub (11.1 row 10) |
| `bot_max_rounds` | 3 | hub |
| `bot_idle_stop_ms` | 1 800 000 | hub |
| `bot_supervisor_tick_ms` | 1 000 | hub |
| `bot_pairing_ttl_ms` | 600 000 | hub |
| `bot_channel_retention_ms` | 2 592 000 000 (30 days) | hub |
| `bot_max_local_candidates` | 3 | hub (truncates `candidates`) |
| `launch_ready_ms` | 120 000 | bridge (sent in frame) |
| `read_ms` | 60 000 | bridge |
| `read_extend_ms` | 60 000 | bridge |
| `read_max_extends` | 4 | bridge |
| `idle_no_reply_ms` | 120 000 | bridge |
| `reply_cap_ms` | 1 800 000 | bridge |
| `progress_interval_ms` | 30 000 | bridge |

### 14.2 Limits

| Limit | Value |
|---|---|
| bridges per message | each eligible bridge at most once per round; at most `bot_max_rounds` rounds |
| candidates per message on one bridge | each candidate at most once per attempt; at most `bot_max_local_candidates` |
| one round | every eligible bridge once. When the round ends with no `busy` attempt, the delivery is `abandoned` with `finish_reason='all_tried'` and `COPY_GAVE_UP` (11.1 row 5) |
| more rounds | a new round starts only through the wake-up rule (11.1 rows 10–13): a bridge came back, a busy retry, a stranded relocation's bridge came back, or a placement change |
| worst case | `bot_max_rounds` (3) rounds × eligible bridges × 3 candidates, after which the delivery is `abandoned` with `finish_reason='max_rounds'` and `COPY_GAVE_UP` |
| after abandon | the user's messages stay pending; the next inbound message opens a new delivery (11.1 row 1) at round 1 |

## 15. User HTTP API

**General rules:**

- Every route uses `require_auth` (`src/hub/transport/http/middleware.odin:8`) and then `require_experiment_enabled(..., "bots", ...)`.
- Handlers live in `src/hub/transport/http/bot_handlers.odin` (struct `Bot_Handlers{auth, bots, experiments}`). They are registered in `wiring.odin` with `http.router_add`.
- Responses use `respond_success` and `respond_error` (`src/hub/transport/http/respond.odin:22`, `:48`).
- TypeScript types and RTK Query endpoints go in `src/ui/api/endpoints/bots.ts`, with tag `'Bot'`.

**Errors common to all routes:**

| Case | Status / code |
|---|---|
| not signed in | 401 `unauthenticated` |
| experiment off | 403 `forbidden` + `experimental_feature_disabled` |
| no bot (except `POST /bots/me`) | 404 `not_found`, details `{"code":"bot_not_found"}` |

### 15.1 Bot view

```json
{
  "bot_id": "bot_18e8f0a9aabbccdd",
  "display_name": "Ninjy bot",
  "status": "ready",
  "status_detail": "",
  "telegram": {
    "configured": true,
    "bot_username": "ninjy_test_bot",
    "binding": {"state": "active", "display": "@alice", "connected_at": "2026-11-17T17:00:00Z"}
  },
  "placement_revision": 3,
  "advanced": {
    "agent_instance_id": "inst_18e8f0aa11223344",
    "bridge_id": "brg_18e8db5c741d67df",
    "bridge_label": "laptop",
    "provider": "claude",
    "model": "opus",
    "runtime_status": "idle"
  }
}
```

- `telegram.binding` is `null` when there is no active binding.
- `telegram.configured=false` and `bot_username=""` when no token is configured.
- `advanced` fields are `""` before the first dispatch.

**`status`**, first match wins:

| Status | When |
|---|---|
| `waiting_for_machine` | open delivery is `waiting` |
| `working` | open delivery is `dispatched` |
| `starting` | instance runtime status ∈ {`launching`, `starting`} |
| `ready` | instance runtime status ∈ {`running`, `idle`, `busy`} |
| `sleeping` | otherwise, when an instance exists |
| `new` | no instance yet |

`status_detail` is `waiting_reason` (`no_bridge`, `busy` or `relocation_stranded`) when the status is `waiting_for_machine`. When there is no open delivery and the newest delivery is `abandoned` with `finish_reason` `all_tried` or `max_rounds`, and no inbound message arrived after it, `status_detail` is `gave_up` and `status` is computed from the instance as usual. Otherwise `status_detail` is `""`.

### 15.2 Routes

| Method & path | Body | Success | Specific errors |
|---|---|---|---|
| `GET /api/v1/bots/me` | — | 200 bot view | 404 `bot_not_found` |
| `POST /api/v1/bots/me` | `{}` | 201 bot view | 409 `conflict` `{"code":"bot_exists"}` |
| `DELETE /api/v1/bots/me` | — | 200 `{"deleted":true}` | 404 |
| `GET /api/v1/bots/me/placement` | — | 200 `{"placement_revision":3,"candidates":[{"bridge_id":"*","provider":"claude","model":"*","tier":"preferred"}]}` | 404 |
| `PUT /api/v1/bots/me/placement` | `{"expected_revision":3,"candidates":[…]}` | 200 same shape, new revision | 400 `validation_failed` (10.1); 409 `conflict` `{"code":"placement_revision_changed"}` |
| `GET /api/v1/bots/me/placement/options` | — | 200 `{"bridges":[{"bridge_id","label","online":true,"bot_capable":true,"providers":[{"provider","label","models":["opus","sonnet"]}]}]}` | 404 |
| `POST /api/v1/bots/me/channels/telegram/pairing` | `{}` | 201 `{"pairing_url":"https://t.me/ninjy_test_bot?start=3f…","expires_at":"…"}` | 503 `provider_unavailable` `{"code":"channel_not_configured"}` |
| `DELETE /api/v1/bots/me/channels/telegram` | — | 200 `{"disconnected":true}` | 404 `{"code":"binding_not_found"}` |
| `GET /api/v1/bots/me/channels/telegram/messages?limit=50` | — | 200 `{"messages":[{"message_id","direction","body","body_purged","send_state","created_at","read_at","replied_at"}]}` newest first; `limit` 1..200, default 50 | 400 on bad limit |
| `GET /api/v1/bots/me/deliveries?limit=20` | — | 200 `{"deliveries":[{"delivery_id","state","round","waiting_reason","finish_reason","created_at","finished_at","attempts":[{"attempt_id","bridge_id","state","report":{…}}]}]}`; `limit` 1..100 | 400 on bad limit |

**`POST /bots/me`:**

1. `create_agent(agents, auth, {name: "Ninjy bot", template_id: domain.TEMPLATE_BOT_ID, has_template_id: true, permission_mode: "yolo"})` (`agent_service.odin:180`).
2. Insert the `bots` row `bot_…` with `agent_instance_id=''`.
3. If the insert fails, archive the created agent before returning the error.

**`DELETE /bots/me`:**

1. `bots_disconnect(notify=true)` if bound.
2. Abandon the open delivery (`bot_deleted`).
3. If the instance is active, `stop_instance(reason "bot_deleted")`.
4. Archive the agent through the existing archive path used by `DELETE /api/v1/agents/*`. **Assumption** (verify in A1b): that route archives rather than hard-deletes; name the proc it calls.
5. Purge the bot's `channel_messages`.
6. `bot_delete`.

The agent's conversation and instance rows stay, archived, like any archived agent.

**`PUT /bots/me/placement`** moves a `waiting` delivery to `pending` (11.1).

## 16. Agent API and `ham-ctl channel`

### 16.1 Hub routes (agent actions)

- **Struct.** Handlers go in `src/hub/transport/http/bot_agent_handlers.odin`, struct `Bot_Agent_Handlers{agent_actions: ^Agent_Action_Handlers, bots: ^bots.Bots_Service, experiments: ^iface.Experiment_Repository}`.
- **Auth.** Each handler calls `require_instance_action_auth(h.agent_actions, req)` (`src/hub/transport/http/agent_action_handlers.odin:1531`), then `require_experiment_enabled(experiments, auth.user_id, "bots", …)`, then `bot_get_by_instance(inst.agent_instance_id)`.
- **Parameters** are read from `json_object_raw(req.body, "params")`, as `agent_action_chat_send_to_user_handler` does (`agent_action_handlers.odin:236`).

| Route | Params | Response `data` |
|---|---|---|
| `POST /api/v1/agent-actions/channel/read` | `{"limit": 20}` (1..50, default 20) | `{"messages":[{"message_id","body","created_at","sender":"@alice"}],"pending_total":2}`: pending inbound messages, oldest first, marked read |
| `POST /api/v1/agent-actions/channel/send` | `{"text": "..."}` (1..16 384 bytes, valid UTF-8) | `{"message_ids":["chm_…"],"chunks":1}` |
| `POST /api/v1/agent-actions/channel/history` | `{"limit": 20}` (1..100, default 20) | `{"messages":[{"message_id","direction","body","created_at"}]}` newest first, purged rows omitted |

**Errors common to all three routes:**

| Case | Status / code |
|---|---|
| instance is not a bot | 403 `forbidden` `{"code":"not_a_bot"}` |
| experiment off | 403 `experimental_feature_disabled` |
| no active binding | 409 `conflict` `{"code":"channel_not_paired"}` |

**`send` errors:**

- 400 `validation_failed` `{"code":"text_invalid"}`;
- 503 `provider_unavailable` `{"code":"channel_send_failed"}` or `{"code":"channel_not_configured"}`.

The `send` handler applies R2 (11.3).

**Only the paired chat (REQ-S1-10).** `send` takes no chat id. The chat is always the active binding of the instance's bot. An instance that is not the bot gets `not_a_bot`.

### 16.2 Read semantics

- `read` returns every inbound row with `replied_at = ''` for the bot, oldest first, up to `limit`. Rows with `read_at = ''` are stamped `read_at = now`.
- An unreplied message is returned again on the next read. This makes re-delivery after a bridge restart safe (12.7). From the bot's point of view, a message keeps appearing until the bot answers.
- `sender` is the binding's `external_display`.

### 16.3 Bridge routing

In `src/bridge/agent_api.odin`:

- `bridge_agent_method_allowed` (`:326-375`): add `"agent.channel.read"`, `"agent.channel.send"` and `"agent.channel.history"`.
- `bridge_agent_route` (`:56-322`): add an `.Envelope` route for each, with path `/api/v1/agent-actions/channel/read`, `/channel/send` and `/channel/history`.

### 16.4 `ham-ctl` verbs

In `src/ctl/agent_mode.odin`:

- Add `case "channel", "channels": ctl_v2_channel(endpoint, token, rest, args); return` to the resource switch (`agent_mode.odin:43-65`).
- Implement `ctl_v2_channel` in a new file, `src/ctl/channel_cmds.odin`. Calls go through `ctl_agent_call_task`, so responses pass through `ctl_decrypt_json_string`. Plaintext comes through unchanged (survey: `vault_content.odin:65-69`).
- `channel send` MUST NOT seal the text. Unlike `chat send`, it does not call `ctl_seal_or_exit`.

**Usage** (added to `print_agent_help`, `agent_mode.odin:1847`, and to `src/ctl/help.odin`):

```text
ham-ctl channel read [--limit N]        Read your owner's unanswered Telegram messages (marks them read).
ham-ctl channel send --text <text>      Send plaintext to your owner's paired Telegram chat.
ham-ctl channel send --text-file <path> Same, text read from a UTF-8 file.
ham-ctl channel history [--limit N]     Recent Telegram messages in both directions, newest first.
Only a bot instance may use these verbs. Telegram messages are not end-to-end encrypted.
```

**Output.** Each verb prints the hub JSON response on stdout, as other agent-mode verbs do. Exit code 0 on success. On a hub error, exit code 1 with the error JSON.

**Example:**

```text
$ ./bin/ham-ctl channel read
{"v":1,"ok":true,"data":{"messages":[{"message_id":"chm_18e8f0b0ffff0001","body":"How is the billing migration going?","created_at":"2026-11-17T17:05:00Z","sender":"@alice"}],"pending_total":1}}
```

## 17. Bot template, skill and Settings > Bots UI

### 17.1 Template

- **File:** `src/templates/bot.md`.
- **Registration** follows the survey path:
  - `TEMPLATE_BOT_ID :: "tmpl_bot"` in `src/hub/domain/content.odin` next to the other ids (`content.odin:209-214`);
  - `TEMPLATE_MD_BOT` with `#load` and a case in `builtin_template` (`src/hub/domain/builtin_templates.odin:7-64`);
  - the id switch in `agent_template_available` (`agent_service.odin:238`);
  - the switches and list in `src/hub/service/content/content_service.odin` (`:403`, `:428`, `:440-470`, `:481`).
- **Visibility.** The bot template MUST NOT appear in the user-facing template list (`list_templates`). Only `POST /bots/me` uses it.

Template body (verbatim):

```markdown
# Role: Ninjy bot

You are the user's personal Ninjy bot. The user talks to you from Telegram.

## How messages reach you
- A line "New Telegram message for you" means the user wrote to you. Run `./bin/ham-ctl channel read` to get every unanswered message.
- Answer with `./bin/ham-ctl channel send --text "<answer>"`. Send one answer that covers all messages you read. Plain text only; links are fine.
- After a fresh start, run `./bin/ham-ctl channel history --limit 20` once to see the recent conversation.
- Never use `ham-ctl chat send` to answer Telegram messages.

## What you can do
- Answer questions about the user's task chains and tasks: use `./bin/ham-ctl task-chain list`, `./bin/ham-ctl task-chain show <id>`, `./bin/ham-ctl task list --chain <id>` and `./bin/ham-ctl task show <id>`.
- Keep answers short: a few lines, then offer detail.

## What you must not do
- Do not change tasks, chains, reviews, memories or files. Slice 1 bots only read and answer.
- Do not approve or request changes on reviews.
- Telegram is not end-to-end encrypted: do not send secrets, tokens or file contents that look sensitive.
```

**Assumption** (verify in A7): the `ham-ctl task-chain list|show` and `task list|show` verbs exist with these arguments for an instance outside the chain. `list_chains` is owner-scoped, not membership-scoped (`src/hub/service/taskchain/taskchain_service.odin:370-378`). A7 MUST adjust the command lines in the template to the exact verbs in `src/ctl/agent_mode.odin` help.

### 17.2 Skill

**Decision:** no new shipped skill. The template carries the instructions. Shipped skills go to every agent without role gating (`bootstrap_append_static_skills`, `agent_service.odin:2068`), so a bot skill would reach every agent. A7 also MUST NOT edit `src/prompts/skills/`.

### 17.3 UI structure

- **Settings registration.**
  - Add `{id: 'bots', label: 'Bots', title: 'Bots', description: 'Your personal bot on Telegram.'}` to `SETTINGS_CATEGORIES` in `src/ui/components/settings/SettingsModal.tsx` (`:27-83`), after `experimental`.
  - Extend `getVisibleSettingsCategories` (`:85`) with a `botsEnabled` argument that hides `bots` unless `resolveExperimentFlag(flags, 'bots') === 'enabled'` (`experimentFlags.ts:16`).
  - Add `case 'bots': return <BotsPanel />` to `renderTabContent` (`:208-249`).
- **Files:** `src/ui/components/settings/BotsPanel.tsx`, `BotPlacementEditor.tsx`, `BotTelegramCard.tsx`, `BotAdvancedSection.tsx`, and `src/ui/components/settings/botsView.ts` (pure helpers, unit-tested).
- **Data.** `useGetBotQuery`, `useCreateBotMutation`, `useDeleteBotMutation`, `useGetBotPlacementQuery`, `usePutBotPlacementMutation`, `useGetBotPlacementOptionsQuery`, `useCreateTelegramPairingMutation`, `useDisconnectTelegramMutation`, `useGetBotDeliveriesQuery`, all in `src/ui/api/endpoints/bots.ts`. The user WS event `bot_changed` invalidates tag `'Bot'`. The bot view is also polled every 10 s while the panel is open.
- **Conversation filter (D6).**
  - New helper `filterBotConversations<T extends {agentInstanceId?: string}>(rows: T[], botInstanceId: string | null): T[]` in `src/ui/components/settings/botsView.ts`.
  - It is applied wherever `useListSidebarConversationsQuery` and `useListConversationInboxQuery` results are rendered in `AppShell.tsx` and `ConversationsHomePage.tsx`.
  - The filter is active only when the experiment resolves `enabled` and `GET /bots/me` returned a bot with a non-empty `advanced.agent_instance_id`.

### 17.4 UI copy and `data-debug-id`s

Register every id in `docs/ui-debug-ids.md`.

| Element | Copy | `data-debug-id` |
|---|---|---|
| panel root | — | `settings-bots-panel` |
| empty state | "You don't have a bot yet. Your bot runs on your machines and answers you on Telegram." | `settings-bots-empty` |
| create button | "Create my bot" | `settings-bots-create-btn` |
| status line | `ready` "Ready", `working` "Answering…", `starting` "Starting…", `sleeping` "Asleep — wakes on your next message", `waiting_for_machine` "Waiting for a machine — your messages are saved", `new` "Not started yet" | `settings-bots-status` |
| status detail (shown under the status line only when `status_detail` is not `""`) | `no_bridge` "None of your machines is online.", `busy` "Your machine is busy; trying again in a few minutes.", `relocation_stranded` "Waiting for the machine your bot last ran on to come back online.", `gave_up` "Your bot could not answer your last message. Send another message to try again." | `settings-bots-status-detail` |
| Telegram card, not configured | "Telegram is not set up on this Ninjy hub. Ask your hub operator to add a Telegram bot token." | `settings-bots-telegram-unconfigured` |
| Telegram card, unpaired | "Connect a Telegram chat to talk to your bot." | `settings-bots-telegram-card` |
| encryption notice (always shown on the card) | "Telegram chats are not end-to-end encrypted. Telegram and your Ninjy hub can read these messages. Anyone who can send messages from your Telegram account can instruct your bot, which runs commands on your machines." | `settings-bots-telegram-notice` |
| connect button | "Connect Telegram" | `settings-bots-telegram-connect-btn` |
| link shown after connect | "Open this link on your phone within 10 minutes:" + the link + a copy button "Copy link" | `settings-bots-telegram-link`, `settings-bots-telegram-copy-btn` |
| paired state | "Connected to {display}" | `settings-bots-telegram-paired` |
| disconnect button | "Disconnect" (confirm dialog: "Disconnect Telegram? Your bot will stop receiving messages from this chat.") | `settings-bots-telegram-disconnect-btn`, `settings-bots-telegram-disconnect-confirm-btn` |
| placement section header | "Where your bot runs" (collapsed; helper text: "By default your bot can use any of your machines and models.") | `settings-bots-placement-toggle` |
| placement row | bridge select ("Any machine" + bridges), provider select ("Any provider" + providers), model select ("Any model" + models), tier select ("Preferred" / "Allowed"), remove button | `settings-bots-placement-row-{index}`, `settings-bots-placement-bridge-{index}`, `settings-bots-placement-provider-{index}`, `settings-bots-placement-model-{index}`, `settings-bots-placement-tier-{index}`, `settings-bots-placement-remove-{index}` |
| add row / save | "Add rule" / "Save" | `settings-bots-placement-add-btn`, `settings-bots-placement-save-btn` |
| placement conflict | "Placement changed elsewhere. Reload and try again." | `settings-bots-placement-error` |
| advanced toggle | "Advanced" (collapsed) | `settings-bots-advanced-toggle` |
| advanced details | "Machine: {bridge_label}", "Provider: {provider}", "Model: {model}", "Runtime: {runtime_status}" | `settings-bots-advanced-details` |
| open terminal | "Open terminal" (disabled with tooltip "Your bot has not started yet." when `agent_instance_id` is empty) | `settings-bots-advanced-terminal-btn` |
| recent deliveries | table of the last 20 deliveries (state, round, finish reason, time) | `settings-bots-advanced-deliveries` |
| delete bot | "Delete bot" (confirm dialog: "Delete your bot? Its Telegram connection and Telegram message history are removed.") | `settings-bots-delete-btn`, `settings-bots-delete-confirm-btn` |

- **Open terminal** opens the existing terminal pane for `advanced.agent_instance_id` with the same action the instance overflow menu uses to open `AgentPtyWorkbenchPane`. **Assumption** (verify in A8): an existing dispatch or helper opens that pane by instance id; A8 names it in its handoff.
- **Main view.** Bridge, provider and model appear **only** inside the Advanced section.

## 18. Security

| Risk | Control |
|---|---|
| A stranger messages the shared Telegram bot | Only chats with an active binding are stored (9.4 row 3). Unbound chats get one fixed reply |
| A stranger in a paired chat (not possible for private chats, but a defence in depth) | `external_user_id` must equal the binding's (9.4 row 7) |
| Pairing code theft or guessing | 128-bit random code; only its SHA-256 is stored; single use; 10 min TTL; earlier codes revoked on new link creation |
| One chat claimed by two accounts | unique active binding per chat; second account gets `COPY_PAIR_CHAT_TAKEN` |
| Bot sends to an arbitrary chat | `channel send` has no chat parameter; the hub uses the bot's binding only (REQ-S1-10) |
| Another agent of the same owner uses the channel | routes require `bot_get_by_instance(inst)` to match; else `not_a_bot` |
| Token leakage | token from env or file only; never logged; adapter logs no httpc `detail` (section 6) |
| Plaintext at rest on the hub | limited to `channel_messages`; purged after 30 days, on disconnect and on bot deletion; user told before pairing and in the chat (D5) |
| Prompt injection from Telegram text | the bot is instructed to read and answer only (17.1). It runs with `permission_mode` `yolo` because a prompting bot cannot be answered from Telegram. Anyone controlling the owner's Telegram account controls an agent on the owner's machines; the notice says so. Section 23, Q3 offers a stricter default to the coordinator |
| Review verdicts from Telegram | not possible: no card or review route is reachable from channel verbs, and the template forbids it |
| Experiment-off isolation | every route and loop gated (section 4) |
| Hub never receives vault keys | unchanged: nothing in this slice touches `src/lib/vault` or the unseal protocol |

## 19. Logging and metrics

- **Hub log lines** use the prefix `bots:` and carry ids only, never message bodies:

```text
bots: delivery bdl_… state pending->dispatched bridge=brg_… attempt=bda_…
bots: attempt bda_… state accepted->exhausted reason=all_candidates_failed
bots: telegram poll error kind=Transient status=502
```

- **Bridge log lines** use the prefix `bot:` with attempt id, candidate and outcome.
- **No new metrics series in slice 1.**

## 20. Test plan

Odin tests run per package: `odin test <pkg> -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/<unique>`. UI tests are added to the `test` script in `package.json`.

### 20.1 Unit tests (named; each ticket adds its own)

| Ticket | File | Tests |
|---|---|---|
| A1a | `src/hub/domain/bot_test.odin` | `test_bot_enum_text_roundtrip`, `test_bot_attempt_state_open` |
| A1a | `src/hub/repository/sqlite/bot_repo_sqlite_test.odin` | `test_migration_209_applies_and_is_idempotent`, `test_bot_one_per_owner`, `test_binding_unique_active_chat_and_owner`, `test_inbound_store_batch_dedupes_update_key_and_advances_cursor_atomically`, `test_inbound_store_batch_rollback_keeps_cursor`, `test_delivery_one_open_per_bot`, `test_attempt_cas_rejects_stale_state`, `test_messages_mark_replied_only_read_rows`, `test_purge_older_than` |
| A1a | `src/hub/transport/http/experiment_rest_handlers_test.odin` (existing or new) | `test_experiment_count_enabled`, `test_experiment_set_calls_on_changed` |
| A1a | `src/hub/service/bots/gate_test.odin` | `test_bots_gate_error_off_on_empty_owner_and_repo_failure` (four cases: never set, set false, set true, empty owner; plus a failing repository → `.Internal_Error`), `test_bots_package_does_not_import_transport` (reads every `.odin` file in `src/hub/service/bots` and fails on the string `hub/transport`) |
| A1b | `src/hub/service/bots/placement_test.odin` | `test_placement_validation_errors` (one case per details code), `test_expand_candidates_empty_policy_allows_all`, `test_expand_candidates_ranks_preferred_first`, `test_expand_candidates_star_model_takes_first_active`, `test_expand_candidates_truncates_to_three`, `test_select_bridge_sticky_first`, `test_select_bridge_skips_tried_and_unsupported` |
| A1b | `src/hub/transport/http/bot_handlers_test.odin` | `test_bots_routes_refuse_when_experiment_off`, `test_create_bot_once`, `test_put_placement_revision_conflict`, `test_delete_bot_cleans_up` |
| A4 | `src/hub/service/channel/telegram_test.odin` | `test_telegram_maps_updates` (each row of 8.1), `test_telegram_error_mapping`, `test_telegram_token_never_in_error_message` |
| A4 | `src/hub/service/bots/poller_test.odin` | `test_poller_does_not_advance_offset_before_commit`, `test_poller_not_started_when_experiment_off_for_all`, `test_poller_not_started_without_token`, `test_runtime_reconcile_starts_and_stops` |
| A5 | `src/hub/service/bots/pairing_test.odin` | one test per row of 9.6, plus `test_inbound_rules_table` (each row of 9.4), `test_disconnect_purges_and_abandons` |
| A5 | `src/hub/transport/http/bot_agent_handlers_test.odin` | `test_channel_read_marks_read_and_repeats_unreplied`, `test_channel_send_only_paired_chat`, `test_channel_send_marks_replied_and_acts_delivery`, `test_channel_routes_not_a_bot`, `test_channel_send_splits_4000_bytes_utf8` |
| A2a | `src/hub/service/bots/delivery_test.odin` | one test per row of 11.1 and 11.2, plus `test_resend_on_hello_same_command_id`, `test_disconnect_grace`, `test_hub_restart_measures_silence_from_boot`, `test_relocation_ready_sends_frame`, `test_relocation_recovery_force_stops`, `test_relocation_stranded_waits_for_hello`, `test_idle_stop_uses_bot_idle_reason`, `test_report_seq_dedupe`, `test_switch_route_rules` (each row of 12.6), `test_single_bridge_all_exhausted_abandons_with_gave_up` (one online bridge, attempt `exhausted` → delivery `abandoned`/`all_tried`, `COPY_GAVE_UP` sent once, no `COPY_NO_MACHINE`), `test_new_message_after_abandon_opens_round_one_delivery`, `test_round_end_with_busy_waits_then_retries_next_round`, `test_no_bridge_recheck_on_hello_and_periodic` (hello of a not-yet-eligible bridge leaves the delivery `waiting`; it moves on the periodic re-check once providers are reported), `test_wakeup_past_max_rounds_abandons`, `test_hello_hook_changes_no_delivery` |
| A2b | `src/bridge/bot_delivery_test.odin` | `test_bot_deliver_spec_and_ordering_key`, `test_handle_deliver_idempotent_by_attempt`, `test_new_attempt_cancels_old_worker`, `test_candidate_loop_skips_skip_list_and_not_runnable`, `test_switch_refused_moves_on`, `test_terminal_report_resent_until_ack`, `test_feature_advertised`, `test_sticky_candidate_delivers_without_switch` (instance active on candidate 2, candidate 1 healthy → no switch call, notice delivered, outcome list has only candidate 2), `test_sticky_ignored_when_stopped_skipped_or_backed_off` (three cases; each uses ranked order and calls switch for candidate 1), `test_relaunch_waits_for_new_launch_record` (switch returns `relaunched:true`; the old runtime stays `running` with the old launch `command_id`; no notice is typed until the launch record shows a new `command_id` and `start_success_seen`), `test_relaunch_blocked_counts_only_after_new_record`, `test_busy_reasons` (traffic stopped → `draining`; update reservation → `draining`; vault locked → `vault_locked`; none → not busy), `test_backoff_table` |
| A3 | `src/bridge/bot_delivery_test.odin` | `test_watch_acted_requires_read_then_reply`, `test_watch_read_extends_while_active`, `test_watch_not_read`, `test_watch_idle_no_reply_after_read`, `test_watch_active_holds_reply_timer`, `test_watch_reply_cap`, `test_watch_failure_records_backoff` (`not_read` and `idle_no_reply` call `bridge_bot_candidate_record_failure`), `test_relay_observation_counts_non_empty_read_only` (bodies: non-empty `data.messages` → read; `[]`, missing `data`, invalid JSON → not read) |
| A6 | `src/ctl/channel_cmds_test.odin` | `test_channel_send_does_not_seal`, `test_channel_verbs_build_params`, `test_channel_help_text` |
| A7 | `src/hub/domain/builtin_templates_test.odin` (existing or new) | `test_bot_template_loaded_and_hidden_from_list` |
| A8 | `tests/ui_bots_test.ts` | `resolveBotStatusLabel`, `filterBotConversations`, placement form validation mirrors 10.1, settings category hidden when experiment off |

### 20.2 Integration tests (hub + real bridge process, no Telegram)

**Owner:** A2c. **File:** `tests/bridge_bot_delivery_integration_test.odin`. It runs only after A2a, A3 and A6 are merged, because it uses the real hub delivery engine, the real watch phase and the real `ham-ctl channel` verbs. No fake hub is built.

- Starts a hub test graph and one real `ham-bridge` whose provider command is the scripted bot agent `tools/mock_agent/bot-agent.sh` (added by A2c; described in 20.4).
- Injects a `channel_messages` row directly.
- Asserts the sequence: attempt `sent` → `accepted`; the agent runs `channel read` and `channel send`; delivery `acted`.
- Children are cleaned up with `bridge_shell_test_kill_pid` (`src/bridge/shell_common.odin`).

### 20.3 End-to-end (isolated local hub, two bridges, fake Telegram)

**Owner:** A9. **File:** `tests/e2e/bots_slice1_e2e.mjs`, run with `node tests/e2e/bots_slice1_e2e.mjs`.

**Setup:**

- **MUST NOT** touch the live hub or bridge. It uses `scripts/local-hub.sh` and `scripts/local-bridge.sh` with non-default names and ports.
- `node tools/fake_telegram/server.mjs --port 18099 --token TEST:FAKE --bot-username ninjy_test_bot`
- `HEIMDALL_TELEGRAM_BOT_TOKEN=TEST:FAKE HEIMDALL_TELEGRAM_API_BASE=http://127.0.0.1:18099 HEIMDALL_BOT_TIMERS_JSON='{"read_ms":15000,"idle_no_reply_ms":20000,"bot_attempt_silence_ms":30000,"bot_disconnect_grace_ms":5000}' scripts/local-hub.sh start --name bots-e2e --hub-port 18181 --proxy-port 18180 --ui-port 15273 --oidc-port 18190`
- `scripts/local-bridge.sh start --name bots-e2e-a --hub bots-e2e --port 49527 --local-endpoint-port 49528 --auto-enroll`
- `scripts/local-bridge.sh start --name bots-e2e-b --hub bots-e2e --port 49537 --local-endpoint-port 49538 --auto-enroll`
- **Assumption** (verify in A9): `local-hub.sh` passes the `HEIMDALL_*` environment through to `ham-hub`. If it does not, A9 adds a pass-through for exactly these four variables.
- **Provider.** Each bridge gets two provider profiles whose `binary_path` (`Provider_Profile_Config`, `src/bridge/provider_profiles.odin:36`) is a script: `bots-good` → `tools/mock_agent/bot-agent.sh` (20.4) and `bots-bad` → `tests/e2e/fixtures/bots_failing_provider.sh`, a POSIX sh script that exits 1 at once. The bot placement is set to `[{bridge:"*",provider:<bots-good provider>,model:"*",tier:"preferred"}]` for steps 1–6, and to `bots-bad` preferred, `bots-good` allowed for step 7. **Assumption** (verify in A9): provider profiles with a custom `binary_path` can be created on a local bridge through the existing provider profile API, and the hub launches them as ordinary providers. If not, A9 stops and reports to the coordinator.

**Steps.** Each step asserts through the user API and through `GET /_control/sent`.

| # | Step | Expected |
|---|---|---|
| 0 | experiment off: `GET /api/v1/bots/me` | 403 `experimental_feature_disabled`; hub log has no `bots:` poller start; fake server `/_control/offsets` empty after 35 s |
| 1 | enable experiment, `POST /bots/me` | 201, `status:new` (moment 1) |
| 2 | `POST …/pairing`, inject `/start <code>` | binding active; chat received `COPY_PAIRED` (moment 2) |
| 3 | inject "hi" | delivery `acted`; chat received the test agent's reply; `channel_messages` inbound has `replied_at` (moment 3) |
| 4 | inject "status?" with test agent scripted to run `task-chain list` | reply contains the seeded sample chain title (moment 4) |
| 5 | stop bridge A (`local-bridge.sh stop --name bots-e2e-a`), inject "still there?" | attempt on A `disconnected` (or none if already offline); relocation to B `ready`; same `agent_instance_id` and `conversation_id`; reply arrives (moment 5) |
| 6 | stop bridge B, inject "anyone?" | chat received `COPY_NO_MACHINE`; delivery `waiting`; start bridge B again → reply arrives (moments 6 and 7) |
| 7 | on B, make the first candidate fail at launch | report outcomes `[launch_failed, acted]`; reply arrives from the second provider |
| 8 | inject the same `update_id` twice through the control API | one `channel_messages` row |
| 9 | `DELETE …/channels/telegram` | chat received `COPY_DISCONNECTED`; bodies purged; a new inject gets `COPY_NOT_CONNECTED` |
| 10 | disable the experiment | open deliveries abandoned; supervisor and poller threads stopped (hub log `bots: runtime stopped`); Settings has no Bots entry (browser check on `settings-nav-item-bots` absent) |

**Teardown:** stop both bridges, the hub and the fake server. Then run `local-bridge.sh stop --purge-home` for both bridges.

### 20.4 Scripted bot agent (`tools/mock_agent/bot-agent.sh`)

A POSIX sh script, launched as the provider command. It needs `HAM_CTL`, which defaults to `./bin/ham-ctl`. It:

1. runs `$HAM_CTL agent start-success` once;
2. reads stdin line by line. For each line containing `New Telegram message for you`, it runs `$HAM_CTL channel read`, then extracts the first message body with `sed`:
   - if the body is `status?`, it runs `$HAM_CTL task-chain list` and sends its output's first chain title, as `chains: <title>`, with `$HAM_CTL channel send --text`;
   - otherwise it sends `echo: <body>`;
3. ignores every other line;
4. exits 0 on SIGTERM.

**Mode.** `BOT_AGENT_MODE` selects the behaviour. Unset or `reply` is the behaviour above. `silent` runs `channel read` for each notice and never runs `channel send`. No other value is accepted: the script prints `bot-agent: unknown BOT_AGENT_MODE` to stderr and exits 2.

## 21. Tickets

**Rules for every ticket:**

- Commit on the task branch with subjects in the repo style (`Hub: …`, `Bridge: …`, `UI: …`, `ctl: …`, `docs: …`). Do not push.
- Report the exact test commands and their outcomes.
- **Never edit** (any ticket): `src/bridge/action_scheduler.odin`, `src/hub/transport/http/action_handlers.odin`, `src/lib/vault/**`, `src/bridge/unseal_protocol.odin`, `src/hub/service/taskv2/**` (beyond the single call sites named below), `src/prompts/skills/**`, migrations other than the new `209_bots.sql`.

### A1a — Hub foundation: experiment key, schema, repositories, contracts, config

**Implements:** sections 4.1 (hub part), 4.2, 5, 6, 7.

**Files:**

- `src/hub/domain/experiment.odin`, `src/hub/domain/bot.odin`, `src/hub/domain/bot_test.odin`
- `src/hub/repository/iface/experiment_repo.odin`, `src/hub/repository/iface/bot_repo.odin`
- `src/hub/repository/sqlite/experiment_repo_sqlite.odin`, `src/hub/repository/sqlite/bot_repo_sqlite.odin` (+ `_test`)
- `src/hub/repository/sqlite/migrations/209_bots.sql`, `src/hub/repository/sqlite/migrations.odin`
- `src/hub/transport/http/experiment_rest_handlers.odin` (only the `on_changed` field and its call)
- `src/hub/app/config_bind.odin`, `src/hub/main.odin`, `src/hub/app/wiring.odin` (repo construction only)
- `src/contracts/bot_wire.odin`, `src/hub/service/bots/config.odin`
- `src/hub/service/bots/gate.odin`, `src/hub/service/bots/gate_test.odin` (4.2)

**Acceptance:**

- [ ] Migration applies on a fresh database and on a copy at migration 208. `run_migrations` is idempotent.
- [ ] All A1a tests in 20.1 pass. `odin test src/hub/repository/sqlite`, `src/hub/domain` and `src/hub/transport/http` pass.
- [ ] `ham-hub` starts with and without `HEIMDALL_TELEGRAM_BOT_TOKEN`. The token value does not appear in the hub's stdout/stderr (grep).
- [ ] `PUT /api/v1/me/experiments/bots {"enabled":true}` works with no further change. The key appears in `GET /api/v1/me/experiments` only after being set.

**Depends on:** none.

**Do not touch:** UI, bridge, ctl; any service logic (only types, storage, config and the gate helper in 4.2).

### A1b — Hub bot service core: bot CRUD, placement, user API

**Implements:** sections 9.1 (struct), 10, 15 (except pairing, disconnect and messages, which belong to A5), 17.1 template **registration only** (the template body belongs to A7, so A1b loads a placeholder `src/templates/bot.md` containing just `# Role: Ninjy bot`).

**Files:**

- `src/hub/service/bots/service.odin`, `src/hub/service/bots/placement.odin` (+ `_test`)
- `src/hub/transport/http/bot_handlers.odin` (+ `_test`)
- `src/hub/app/wiring.odin` (routes and service construction)
- `src/hub/domain/content.odin`, `src/hub/domain/builtin_templates.odin`
- `src/hub/service/agent/agent_service.odin` (template id switch at `:238` only)
- `src/hub/service/content/content_service.odin` (template switches only)
- `src/templates/bot.md` (placeholder)

**Acceptance:**

- [ ] All A1b tests pass.
- [ ] `GET/POST/DELETE /bots/me`, `GET/PUT /bots/me/placement` and `GET …/placement/options` behave per 15.2, including the experiment-off 403.
- [ ] The bot template is not listed by the template list API.
- [ ] The DELETE assumption in 15.2 is verified and recorded in the handoff.

**Depends on:** A1a.

**Do not touch:** bridge, UI, ctl, delivery engine.

### A4 — Telegram adapter, fake Telegram server, poller and runtime start/stop

**Implements:** sections 4.4, 8, 9.3 (loop only), 9.5 (`channel_send` proc), and the `bots_on_experiment_changed` hook plus the `disable.odin` stub (11.9).

**Inbound rows in A4.** The 9.4 rules belong to A5. In A4 the poller maps every update to no row: it calls `repo.inbound_store_batch("telegram", rows = {}, next, now)` with an empty row list, which commits the cursor only, and logs each update's kind. This is what `test_poller_does_not_advance_offset_before_commit` exercises (with a repository double whose `inbound_store_batch` fails, the next `getUpdates` MUST carry the old offset). A5 replaces only the row mapping and the side effects; the cursor commit stays as A4 wrote it.

**Files:**

- `src/hub/service/channel/adapter.odin`, `src/hub/service/channel/telegram.odin` (+ `_test`)
- `src/hub/service/bots/runtime.odin`, `src/hub/service/bots/poller.odin` (+ `_test`), `src/hub/service/bots/channel_send.odin`, `src/hub/service/bots/disable.odin` (stub, 11.9)
- `src/hub/app/app.odin` (one reconcile call), `src/hub/app/wiring.odin` (adapter construction, `on_changed` hook)
- `tools/fake_telegram/server.mjs`, `tools/fake_telegram/README.md`

**Acceptance:**

- [ ] A4 tests pass, including `test_poller_does_not_advance_offset_before_commit` against the fake server.
- [ ] With no user enabled, no poller or supervisor thread starts (a test asserts the runtime flags).
- [ ] `scripts/check-http-boundary.sh` passes, so only `httpc` is used.
- [ ] The token is absent from all adapter error strings.

**Depends on:** A1a.

**Do not touch:** pairing logic, delivery engine, bridge, UI.

### A5 — Pairing, inbound routing, channel agent routes

**Implements:** sections 9.2, 9.4, 9.6, 9.7, 11.3 R1/R2 (hub part), 15.2 pairing, disconnect and messages routes, 16.1, 16.2.

**Files:**

- `src/hub/service/bots/inbound.odin`, `src/hub/service/bots/pairing.odin` (+ `_test`), `src/hub/service/bots/copy.odin`
- `src/hub/transport/http/bot_handlers.odin` (three routes)
- `src/hub/transport/http/bot_agent_handlers.odin` (+ `_test`)
- `src/hub/app/wiring.odin`

**Acceptance:**

- [ ] A5 tests pass.
- [ ] Pairing works end to end against the fake server in a test (inject `/start`, binding active, `COPY_PAIRED` sent).
- [ ] An inbound text creates a `pending` delivery row through `delivery_on_inbound`, with its final body (11.9). Nothing dispatches it until A2a adds the supervisor.

**Depends on:** A1b, A4.

**Do not touch:** bridge, UI, ctl, attempt/relocation logic.

### A2a — Hub delivery engine: selection, attempts, relocation, timers, reports, switch route

**Implements:** sections 2 D1/D2/D4 (hub side), 10.4, 11 (all), 12.1 (hub reading), 12.3–12.7 (hub side), 14.

**Files:**

- `src/hub/service/bots/delivery.odin`, `src/hub/service/bots/supervisor.odin` (+ `_test`)
- `src/hub/transport/http/bridge_handlers.odin`, with exactly four call sites:
  - `bots_on_bridge_hello` after `:1885`;
  - `bots_on_bridge_disconnect` in `bridge_disconnect_persist` (`:1928`);
  - `case "bot_delivery_report"` before `:2734`;
  - `bots_on_command_result` near `:2537`.
- `src/hub/transport/http/bot_bridge_handlers.odin` (switch route)
- `src/hub/app/wiring.odin`

**Acceptance:**

- [ ] All A2a tests pass, including one test per row of the 11.1 and 11.2 tables.
- [ ] `odin test src/hub/transport/http` and `src/hub/service/agent` still pass.
- [ ] The `prepare_instance` and `Reconfigure_Instance_Input` assumptions are verified and recorded in the handoff.

**Depends on:** A1b, A5.

**Do not touch:** bridge, UI, ctl; `instance_reconfiguration.odin` and `agent_service.odin` stay unchanged. If A2a finds it needs to change them, it stops and reports to the coordinator.

### A2b — Bridge: `bot_deliver` handler, worker, candidate loop, switch call, reports, capability

**Implements:** sections 12.1 (bridge), 12.2, 12.3–12.5 (bridge side), 13.1–13.4, 13.6, 13.8, 13.9 (its procs and the A3 stubs), 13.10.

**Files:**

- `src/bridge/bot_delivery.odin` (+ `_test`)
- `src/bridge/hub_command_dispatch.odin` (spec and ordering key)
- `src/bridge/hub_runtime_client.odin` (feature list, two `if type ==` branches, one `bridge_bot_note_raw_activity` call in `bridge_runtime_note_agent_activity`, 13.10)
- `src/hub/service/project/runtime_metrics.odin` (label only)

**Acceptance:**

- [ ] A2b unit tests pass.
- [ ] Every test seam in 13.10 has its production default, and the unit tests above use only the seams (no hub, no real provider process).
- [ ] The A3-owned procs exist as the stubs named in 13.9.
- [ ] `odin test src/bridge` passes.

**Depends on:** A1a (contracts). It has no integration test of its own; the hub-plus-bridge run belongs to A2c.

**Do not touch:** hub service code, UI, ctl, `src/bridge/agent_wake.odin` (called, not changed), `src/bridge/action_scheduler.odin`.

### A3 — Bridge: not-acted detection and relay observation

**Implements:** sections 2 D3, 13.5, 13.7, 13.8 (failure recording from watch results), 13.9 (final bodies of `bridge_bot_note_read`, `bridge_bot_note_reply`, `bridge_bot_watch_step`).

**Files:** `src/bridge/bot_delivery.odin` (watch phase), `src/bridge/wrapper_endpoint.odin` (two observation lines), `src/bridge/bot_delivery_test.odin`.

**Acceptance:**

- [ ] A3 tests pass using `bridge_bot_now_proc` and `bridge_bot_activity_proc` (13.10) as the clock and activity source.
- [ ] `odin test src/bridge` passes.
- [ ] A test proves a `waiting_user` agent fails with `idle_no_reply` (detail `waiting_user`) after `idle_no_reply_ms`.

**Depends on:** A2b.

**Do not touch:** `pty_host_activity.odin` classification, `bridge_runtime_normalize_activity_status`, hub code.

### A2c — Integration test: real hub, real bridge, scripted bot agent

**Implements:** sections 20.2 and 20.4.

**Files:** `tests/bridge_bot_delivery_integration_test.odin`, `tools/mock_agent/bot-agent.sh`, `tools/mock_agent/README.md` (one paragraph naming the script).

**Acceptance:**

- [ ] The 20.2 test passes: attempt `sent` → `accepted`; the agent runs `channel read` and `channel send`; the delivery reaches `acted` through R2 (11.3); the bridge's terminal report is acked.
- [ ] A second case scripts the agent to read and never reply (`BOT_AGENT_MODE=silent`, 20.4) and asserts outcome `idle_no_reply`. The test builds the hub's `Bot_Timer_Config` with `read_ms` 5000 and `idle_no_reply_ms` 3000 and every other field at its 14.1 default.
- [ ] Every child process is cleaned up (`bridge_shell_test_kill_pid`); a second run in the same shell passes.

**Depends on:** A2a, A3, A6.

**Do not touch:** product code. A defect found here is reported to the coordinator with the failing assertion, and fixed in the owning ticket's area as a separate commit named in the handoff.

### A6 — `ham-ctl channel` verbs and bridge routing

**Implements:** sections 16.3, 16.4.

**Files:** `src/ctl/agent_mode.odin` (switch case and help line), `src/ctl/channel_cmds.odin` (+ `_test`), `src/ctl/help.odin`, `src/bridge/agent_api.odin` (allowlist and three routes).

**Acceptance:**

- [ ] A6 tests pass.
- [ ] Against a local hub with A5 merged, `./bin/ham-ctl channel read|send|history` from a bot instance returns the documented JSON. From a non-bot instance it returns `not_a_bot`.
- [ ] `odin test src/ctl` and `odin test src/bridge` pass.

**Depends on:** A5.

**Do not touch:** `chat send` sealing, vault code, hub code.

### A7 — Bot template content

**Implements:** sections 17.1 (template body), 17.2.

**Files:** `src/templates/bot.md` (+ template test).

**Acceptance:**

- [ ] The template text matches 17.1, with the command lines corrected to the exact existing verbs (the 17.1 assumption is verified).
- [ ] A bot instance launched on a local hub reads its `AGENTS.md`/`CLAUDE.md` with the template content.

**Depends on:** A1b, A6.

**Do not touch:** `src/prompts/skills/**`, `static_skills_gen.odin`.

### A8 — UI: Settings > Bots, conversation filter

**Implements:** sections 2 D6, 4.1 (UI part), 15 (TS types), 17.3, 17.4.

**Files:**

- `src/ui/components/settings/experimentFlags.ts`, `SettingsModal.tsx`, `BotsPanel.tsx`, `BotPlacementEditor.tsx`, `BotTelegramCard.tsx`, `BotAdvancedSection.tsx`, `botsView.ts`
- `src/ui/api/endpoints/bots.ts`, `src/ui/api/heimdallApi.ts` (tag `'Bot'`)
- `src/ui/components/shell/AppShell.tsx`, `src/ui/components/chat/ConversationsHomePage.tsx` (filter only)
- `docs/ui-debug-ids.md`
- `tests/ui_bots_test.ts`, `package.json` (test list)

**Acceptance:**

- [ ] `npm run typecheck` and `npm test` pass.
- [ ] With the experiment off there is no Bots entry. With it on, every copy string and `data-debug-id` in 17.4 is present.
- [ ] The bot conversation is absent from the sidebar and Conversations home when a bot exists.
- [ ] Bridge, provider and model appear only under Advanced.
- [ ] Open terminal opens the PTY pane.

**Depends on:** A1b, A5 (API shapes); can start in parallel against the 15.2 shapes.

**Do not touch:** `AgentChatPane.tsx`, the hub, the bridge.

### A9 — End-to-end check

**Implements:** section 20.3.

**Files:** `tests/e2e/bots_slice1_e2e.mjs`, `tests/e2e/fixtures/bots_failing_provider.sh`. It reuses `tools/mock_agent/bot-agent.sh` from A2c.

**Acceptance:**

- [ ] Every step of 20.3 passes on an isolated hub with two bridges and the fake Telegram server. The run log is attached to the handoff.
- [ ] The live hub and bridges are untouched.

**Depends on:** A2c, A7, A8.

**Do not touch:** product code, except fixes that are filed back to the owning ticket's area as separate commits named in the handoff.

### Ticket graph

```text
A1a ─┬─ A1b ─┬─────── A5 ──┬── A2a ───────┐
     │       │             ├── A6 ──┬─────┼── A2c ──┐
     ├─ A4 ──┘             │        └── A7 ─────────┤
     │                     └── A8 ──────────────────┤
     └─ A2b ── A3 ────────────────────────┘          └── A9
```

| Ticket | Depends on |
|---|---|
| A1a | — |
| A1b | A1a |
| A4 | A1a |
| A2b | A1a |
| A5 | A1b, A4 |
| A3 | A2b |
| A2a | A1b, A5 |
| A6 | A5 |
| A7 | A1b, A6 |
| A8 | A1b, A5 |
| A2c | A2a, A3, A6 |
| A9 | A2c, A7, A8 |

The table is normative; the drawing is a picture of it. A1b, A4 and A2b can run in parallel after A1a. A8 can start after A1b, against the documented shapes.

## 22. Traceability

| Requirement | Spec sections | Tickets |
|---|---|---|
| REQ-S1-1 | 2 D4, 15.2 `POST /bots/me`, 17.4 | A1b, A8 |
| REQ-S1-2 | 10.1–10.3, 15.2 placement, 17.4 | A1b, A8 |
| REQ-S1-3 | 2 D4, 2 D6, 17.3 (terminal pane) | A1b, A2a, A8, A9 |
| REQ-S1-4 | 2 D1, 10.4, 11.4, 13.4 (provider stickiness, relaunch readiness) | A2a, A2b, A2c |
| REQ-S1-5 | 11.5, 2 D5 (Telegram thread stored per binding, not per instance) | A2a, A9 |
| REQ-S1-6 | 2 D3, 11.1, 11.2, 13.4–13.10, 14.2, 20.2 | A2a, A2b, A3, A2c |
| REQ-S1-7 | 11.1 (rows 3, 10–13, wake-up rule, waiting re-check), 11.6, 11.7 | A2a, A9 |
| REQ-S1-8 | 9.6, 9.7, 15.2, 17.4 | A5, A8 |
| REQ-S1-9 | 5.1 (`channel_messages_update_key`), 9.3, 16.2 | A1a, A4, A5 |
| REQ-S1-10 | 9.5, 16.1, 18 | A5, A6 |
| REQ-S1-11 | 17.1 | A7, A9 |
| REQ-S1-12 | 8 | A4 |
| REQ-S1-13 | 4 (4.2 `bots_gate_error`) | A1a, A1b, A4, A5, A2a, A8, A9 |
| REQ-S1-14 | 17.3, 17.4 | A8 |
| REQ-S1-15 | 5.1 (`bot_deliveries`, `bot_delivery_attempts`), 11.2, 11.7, 12.7 | A1a, A2a |
| REQ-S1-16 | 10.2, 12.1 | A2a, A2b |

## 23. Open questions for the coordinator (defaults are what gets built)

| # | Question | Default built |
|---|---|---|
| Q1 | A relocation stuck in `recovery_required` while the destination bridge is offline cannot be force-stopped (`instance_reconfiguration.odin:494`). The bot then waits for that bridge (11.5.1). Should a later slice add a hub-side "abandon stranded relocation" to the relocation machine? | wait for the bridge; `waiting_reason='relocation_stranded'` shown in Settings |
| Q2 | Hub-sent notices (pairing replies, `COPY_NO_MACHINE`) are not stored, so a crash can repeat or lose one notice (9.3) | accepted for slice 1 |
| Q3 | The bot runs with `permission_mode` `yolo` (18). A stricter option is `ask` plus a Telegram reply "your bot needs approval in Ninjy" when it hits a permission prompt, which costs a slice-2 notification path | `yolo`, with the warning in the pairing notice and Settings |
| Q4 | New inbound messages that arrive while a delivery is `dispatched` wait for the next delivery (11.1 R3). The bot will usually see them anyway, because `channel read` returns every unreplied message | as described |
| Q5 | Channel message retention is fixed at 30 days and not user-configurable | fixed 30 days |

## 24. Glossary of new identifiers

| Kind | Names |
|---|---|
| Experiment key | `bots` (`BOTS_EXPERIMENT_KEY`) |
| Tables | `bots`, `bot_placement_candidates`, `channel_bindings`, `channel_pairings`, `channel_cursors`, `channel_messages`, `bot_deliveries`, `bot_delivery_attempts` |
| Id prefixes | `bot_`, `chb_`, `chm_`, `bdl_`, `bda_`, command ids `cmd_bot_<attempt_id>` |
| Template | `tmpl_bot` (`TEMPLATE_BOT_ID`), `src/templates/bot.md` |
| Bridge feature | `bot_deliver_v1` |
| Frames | `bot_deliver`, `bot_delivery_report`, `bot_delivery_report_ack` |
| User routes | `/api/v1/bots/me`, `/api/v1/bots/me/placement`, `/api/v1/bots/me/placement/options`, `/api/v1/bots/me/channels/telegram/pairing`, `/api/v1/bots/me/channels/telegram`, `/api/v1/bots/me/channels/telegram/messages`, `/api/v1/bots/me/deliveries` |
| Agent routes | `/api/v1/agent-actions/channel/read`, `/channel/send`, `/channel/history`; methods `agent.channel.read|send|history` |
| Bridge route | `/api/v1/bridge/bot-attempts/{attempt_id}/switch` |
| CLI | `ham-ctl channel read|send|history` |
| Config | `HEIMDALL_TELEGRAM_BOT_TOKEN`, `HEIMDALL_TELEGRAM_BOT_TOKEN_FILE`, `HEIMDALL_TELEGRAM_API_BASE`, `HEIMDALL_BOT_TIMERS_JSON`, `--telegram-bot-token-file`, `--telegram-api-base` |
| Packages and files | `src/hub/service/bots/`, `src/hub/service/channel/`, `src/bridge/bot_delivery.odin`, `src/ctl/channel_cmds.odin`, `src/contracts/bot_wire.odin`, `tools/fake_telegram/server.mjs`, `tests/e2e/bots_slice1_e2e.mjs` |
| UI | settings category `bots`, `BotsPanel.tsx`, `src/ui/api/endpoints/bots.ts`, tag `'Bot'`, WS event `bot_changed` |
| Copy constants | `COPY_*` in `src/hub/service/bots/copy.odin`, `BOT_NOTICE` in `src/bridge/bot_delivery.odin` |
| Hub procs and fields | `bots_gate_error`, `bots_gate_on` (`src/hub/service/bots/gate.odin`); the 11.9 procs; `Bots_Service.hello_queue`, `Bots_Service.last_waiting_recheck_ms`; `Bridge_Handlers.bots` |
| Bridge procs and seams | the 13.9 procs; the 13.10 `bridge_bot_*_proc` variables; `bridge_bot_raw_activity`, `bridge_bot_note_raw_activity` |
| Frame fields | `bot_deliver.current_provider`, `bot_deliver.current_model` |
| Timer | `bot_waiting_recheck_ms` |
| Enumerated values | `waiting_reason`: `no_bridge`, `busy`, `relocation_stranded`; `finish_reason`: `acted`, `all_tried`, `max_rounds`, `binding_revoked`, `bot_deleted`, `experiment_disabled`; `status_detail` adds `gave_up`; busy `reason`: `draining`, `vault_locked` |
| Test tooling | `BOT_AGENT_MODE` (`reply`, `silent`) for `tools/mock_agent/bot-agent.sh`; ticket `A2c` |

## 25. Evidence index

Each row names a file, a line, and a symbol that occurs within three lines of it at commit `71be91b1`. The check that ran at submission is described in the task's submit summary.

| Path | Line | Symbol |
|---|---|---|
| src/hub/domain/experiment.odin | 12 | ACTIONS_EXPERIMENT_KEY |
| src/hub/domain/experiment.odin | 21 | EXPERIMENTS_DEFAULT_ON |
| src/hub/domain/experiment.odin | 44 | experiment_feature_label |
| src/hub/domain/experiment.odin | 56 | experimental_feature_disabled_error |
| src/hub/transport/http/experiment_rest_handlers.odin | 12 | Experiment_Rest_Handlers |
| src/hub/transport/http/experiment_rest_handlers.odin | 71 | experiment_set_handler |
| src/hub/transport/http/experiment_rest_handlers.odin | 158 | experiment_gate_error |
| src/hub/transport/http/experiment_rest_handlers.odin | 181 | require_experiment_enabled |
| src/hub/repository/iface/experiment_repo.odin | 8 | Experiment_Repository |
| src/hub/repository/iface/experiment_repo.odin | 14 | experiment_set |
| src/hub/app/wiring.odin | 323 | experiment_repo |
| src/hub/app/wiring.odin | 1036 | /api/v1/bridge/actions/*/execute |
| src/hub/app/app.odin | 31 | start_timer_thread |
| src/hub/service/bridge/bridge_promoted_release.odin | 288 | bridge_catalog_refresher_start |
| src/hub/app/config_bind.odin | 9 | Hub_Config |
| src/hub/main.odin | 152 | apply_vapid_env |
| src/hub/main.odin | 390 | read_key_file |
| src/hub/repository/sqlite/migrations.odin | 662 | MIGRATION_208 |
| src/hub/repository/sqlite/migrations.odin | 664 | migration_order |
| src/hub/repository/sqlite/migrations.odin | 1368 | migration_sql |
| src/hub/transport/http/middleware.odin | 8 | require_auth |
| src/hub/transport/http/respond.odin | 22 | respond_success |
| src/hub/transport/http/respond.odin | 48 | respond_error |
| src/hub/service/agent/agent_service.odin | 1080 | reconfigure_instance |
| src/hub/service/agent/agent_service.odin | 1086 | immutable for an instance |
| src/hub/service/agent/agent_service.odin | 1096 | relaunch_instance_locked |
| src/hub/service/agent/agent_service.odin | 1098 | agent_save_instance |
| src/hub/service/agent/agent_service.odin | 166 | Reconfigure_Instance_Input |
| src/hub/service/agent/agent_service.odin | 180 | create_agent |
| src/hub/service/agent/agent_service.odin | 238 | agent_template_available |
| src/hub/service/agent/agent_service.odin | 330 | create_instance |
| src/hub/service/agent/agent_service.odin | 346 | prepare_instance |
| src/hub/service/agent/agent_service.odin | 356 | bridge_id is required |
| src/hub/service/agent/agent_service.odin | 400 | coordinator |
| src/hub/service/agent/agent_service.odin | 414 | send_instance_launch |
| src/hub/service/agent/agent_service.odin | 828 | stop_instance |
| src/hub/service/agent/agent_service.odin | 842 | STOPPED_BY_USER |
| src/hub/service/agent/agent_service.odin | 1367 | detect_superseded_instances |
| src/hub/service/agent/agent_service.odin | 1514 | resolve_instance_chain |
| src/hub/service/agent/agent_service.odin | 1589 | validate_pinned_provider_model |
| src/hub/service/agent/agent_service.odin | 1727 | runtime_expected_active |
| src/hub/service/agent/agent_service.odin | 2068 | bootstrap_append_static_skills |
| src/hub/service/agent/agent_service.odin | 2208 | bootstrap_manifest_json_for_bridge |
| src/hub/service/agent/instance_reconfiguration.odin | 55 | bridge_feature_supported |
| src/hub/service/agent/instance_reconfiguration.odin | 78 | reconfiguration_require_idle |
| src/hub/service/agent/instance_reconfiguration.odin | 88 | begin_instance_reconfiguration |
| src/hub/service/agent/instance_reconfiguration.odin | 113 | require_launch_bridge_enabled |
| src/hub/service/agent/instance_reconfiguration.odin | 158 | bridge_runtime_instance_cancel_reservation |
| src/hub/service/agent/instance_reconfiguration.odin | 231 | reconfiguration_fence_source_and_launch |
| src/hub/service/agent/instance_reconfiguration.odin | 354 | 180_000 |
| src/hub/service/agent/instance_reconfiguration.odin | 460 | Internal_User |
| src/hub/service/agent/instance_reconfiguration.odin | 487 | force_stop_instance_reconfiguration_locked |
| src/hub/service/agent/instance_reconfiguration.odin | 494 | reconnect the current bridge to confirm Force stop |
| src/hub/domain/instance_reconfiguration.odin | 70 | instance_reconfiguration_blocks_input |
| src/hub/repository/sqlite/migrations/072_instance_reconfiguration.sql | 15 | blocks_input = 1 |
| src/hub/service/agent/instance_failure.odin | 52 | instance_retry_delay_ms |
| src/hub/service/taskv2/timers.odin | 210 | arm_idle_ttl |
| src/hub/service/taskv2/lease.odin | 651 | on_bridge_hello |
| src/hub/service/taskv2/lease.odin | 1072 | is_coordinator |
| src/hub/service/taskchain/taskchain_service.odin | 370 | list_chains |
| src/hub/service/provider/provider_service.odin | 359 | list_bridge_providers |
| src/hub/service/bridge/bridge_service.odin | 628 | verify_bridge_token |
| src/hub/service/bridge_runtime/bridge_runtime.odin | 64 | send_runtime_command |
| src/hub/transport/http/bridge_handlers.odin | 1885 | on_bridge_hello |
| src/hub/transport/http/bridge_handlers.odin | 1928 | bridge_disconnect_persist |
| src/hub/transport/http/bridge_handlers.odin | 2335 | bridge_ws_process_frame |
| src/hub/transport/http/bridge_handlers.odin | 2410 | switch type |
| src/hub/transport/http/bridge_handlers.odin | 2537 | command_result |
| src/hub/transport/http/bridge_handlers.odin | 2737 | unknown_frame_type |
| src/hub/transport/http/agent_action_handlers.odin | 232 | agent_action_chat_send_to_user_handler |
| src/hub/transport/http/agent_action_handlers.odin | 236 | json_object_raw |
| src/hub/transport/http/agent_action_handlers.odin | 1531 | require_instance_action_auth |
| src/hub/transport/http/agent_handlers.odin | 333 | patch_agent_instance_handler |
| src/hub/domain/vault_text_caps.odin | 46 | is_vault_armored |
| src/hub/domain/content.odin | 209 | TEMPLATE_ |
| src/hub/domain/builtin_templates.odin | 15 | builtin_template |
| src/bridge/hub_runtime_client.odin | 4418 | BRIDGE_RUNTIME_FEATURES |
| src/bridge/hub_runtime_client.odin | 2615 | bridge_runtime_launch_agent |
| src/bridge/hub_runtime_client.odin | 3390 | bridge_runtime_instance_snapshot |
| src/bridge/hub_runtime_client.odin | 3356 | bridge_runtime_normalize_activity_status |
| src/bridge/hub_runtime_client.odin | 4162 | Bridge_Command_Result_Wire |
| src/bridge/hub_runtime_client.odin | 4195 | bridge_command_failed_json |
| src/bridge/hub_runtime_client.odin | 1163 | notify_agent_message |
| src/bridge/hub_command_dispatch.odin | 245 | bridge_command_spec |
| src/bridge/hub_command_dispatch.odin | 353 | bridge_command_ordering_key |
| src/bridge/hub_command_dispatch.odin | 523 | bridge_command_budget_ms |
| src/bridge/agent_wake.odin | 111 | bridge_wake_gate |
| src/bridge/agent_wake.odin | 146 | bridge_provider_runnable |
| src/bridge/agent_wake.odin | 205 | bridge_task_wake_if_needed |
| src/bridge/agent_wake.odin | 299 | bridge_wake_fetch_enriched_launch_json |
| src/bridge/pty_host_runtime.odin | 661 | bridge_pty_host_message_notice |
| src/bridge/pty_host_runtime.odin | 759 | bridge_pty_host_deliver_to_agent |
| src/bridge/pty_host_runtime.odin | 926 | bridge_pty_host_apply_startup_blocked |
| src/bridge/pty_host_activity.odin | 23 | Bridge_Activity_Status |
| src/bridge/wrapper_endpoint.odin | 563 | Envelope |
| src/bridge/agent_api.odin | 326 | bridge_agent_method_allowed |
| src/bridge/agent_api.odin | 56 | bridge_agent_route |
| src/ctl/agent_mode.odin | 54 | ctl_v2_chat |
| src/ctl/extension/transcript_usage.odin | 192 | codex_usage_from_tail |
| src/ui/api/endpoints/sidebar.ts | 177 | listSidebarConversations |
| src/ui/api/endpoints/sidebar.ts | 202 | listConversationInbox |
| src/ui/components/settings/experimentFlags.ts | 5 | ACTIONS_EXPERIMENT_KEY |
| src/ui/components/settings/experimentFlags.ts | 16 | resolveExperimentFlag |
| src/ui/components/settings/SettingsModal.tsx | 85 | getVisibleSettingsCategories |
| src/ui/components/workbench/AgentChatPane.tsx | 673 | normalizeConversationMessages |
| src/hub/domain/experiment.odin | 38 | experiment_enabled_in |
| src/hub/repository/iface/experiment_repo.odin | 19 | experiment_list_by_owner |
| src/contracts/envelope.odin | 50 | api_success_json |
| src/hub/transport/http/bridge_handlers.odin | 39 | Bridge_Handlers |
| src/hub/transport/http/bridge_handlers.odin | 2747 | bridge_protocol_error_frame |
| src/bridge/hub_runtime_client.odin | 69 | bridge_vault_status |
| src/bridge/hub_runtime_client.odin | 117 | Bridge_Runtime_Instance |
| src/bridge/hub_runtime_client.odin | 2616 | bridge_auto_update_launch_enter |
| src/bridge/hub_runtime_client.odin | 2693 | bridge_runtime_set_status |
| src/bridge/hub_runtime_client.odin | 2835 | bridge_runtime_record_launch |
| src/bridge/hub_runtime_client.odin | 2998 | bridge_runtime_get_launch |
| src/bridge/hub_runtime_client.odin | 3012 | bridge_runtime_launches |
| src/bridge/hub_runtime_client.odin | 3052 | bridge_runtime_now_ms |
| src/bridge/hub_runtime_client.odin | 3136 | bridge_runtime_normalize_activity_status |
| src/bridge/hub_runtime_client.odin | 3284 | start_success_seen |
| src/bridge/hub_runtime_client.odin | 3780 | bridge_runtime_status_active |
| src/bridge/hub_quiescence.odin | 12 | bridge_hub_traffic_stopped |
| src/bridge/auto_update.odin | 87 | bridge_auto_update_launch_enter |
| src/bridge/auto_update.odin | 95 | bridge_auto_update_launch_leave |
| src/bridge/process_deadline.odin | 19 | bridge_process_slot_has_capacity |
