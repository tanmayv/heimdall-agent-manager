# Chat / Conversation Agents + Multi-Instance Identity

Status: Draft plan (phase 1 not started)
Owner: TBD
Related: `docs/plan/chat-conversation/mockups/` (UI mockups)

## 1. Goal

Deliver a ChatGPT / Claude-style chat experience in Heimdall while unifying it with a
broader capability: **any durable agent identity (`agent_id`) can have multiple concurrent
live instances**, each sharing the identity's project, memories, skills, provider/tier, and
persona.

Two user-visible outcomes:

1. **Conversation agents** — a `conversation` role/template used for open-ended chat. Each
   chat thread is its own agent instance with isolated context but shared identity details.
2. **Multi-instance for every agent** — remove the current "one running instance per agent"
   limitation. You can run several `coder`, `reviewer`, etc. instances at once, and each can
   still be assigned tasks and act as a reviewer.

Non-goal: backward compatibility. We are free to make breaking changes to instance-id
semantics and start APIs.

## 2. Core model change

Today `agent_instance_id = <agent_id>@<project>` conflates *identity* and *project*. That is
the root cause of the single-instance limit: a second launch of the same `agent_id@project`
coalesces onto the running instance.

New model:

```
agent_id (durable identity)                     Agent_Id_Record
  · template / persona / role
  · default provider / tier
  · default project
  · memories (target_agent_id = agent_id)
        │  1 ─────────────── *
        ▼
agent_instance_id = <agent_id>@<session-token>  Agent_Instance_Record
  · one live run  ==  one chat thread
  · project_id is a FIELD (inherited from identity, optionally overridden)
  · own chat history, current_task_id, ws / tmux pane
```

Rules:

- `@<session-token>` is an **opaque per-instance session id** (e.g. `s-9f3a2c`), NOT a project.
- Project lives in `Agent_Instance_Record.project_id` (already exists) and defaults from the
  identity; may be overridden per instance at launch.
- Everything shared comes from `agent_id`: template/persona/role, provider/tier defaults,
  default project, and memories (already keyed by `target_agent_id` → durable id).
- One instance = one chat thread falls out for free: chat is already keyed by
  `agent_instance_id` in `chat_store.odin` / `message_db_service.odin`.
- "Conversation" is just a template/role, not a special mechanism. Any agent type can be
  multi-instanced the same way.

## 3. Task assignment & review

Tasks reference agents by `assignee_agent_instance_id` and reviewer roles by instance id, so
this keeps working:

- Assign to a **concrete instance** (`coder@s-3a1`), or
- Assign to an **`agent_id`** with a policy `{reuse | new}` — the daemon resolves to an
  existing live instance or mints a fresh session. Only a small resolver is needed; routing,
  nudges, review, and notifications already key off `assignee_agent_instance_id`.

Conversation instances are ordinary instances: they can be handed a task or review; assigning
sets `current_task_id` and notifies that instance.

## 3b. Sidebar grouping data (capture on the instance record)

The UI sidebar groups conversations by **project only**. Agent_id is NOT shown, and
task-chain grouping/ordering is intentionally out of scope here — chains are surfaced in their
own Task Chains view, so conversations are not grouped or ordered by chain.

Grouping keys must NOT be parsed out of the `agent_instance_id` string — after the
session-token change the suffix is opaque. The project key is captured as a field on
`Agent_Instance_Record`, set at creation and updated as the agent is moved around, then sent
to the UI via an enriched `list_chats`.

What exists today on `Agent_Instance_Record` (src/daemon/agent_store.odin):
- `agent_id`     ✅ set at creation (prefix back-reference). Reliable.
- `project_id`   ✅ set at creation, updated on associate/disassociate. Authoritative — use this, not the suffix.
- `current_task_id` ✅ set/cleared via `agent_store_update_work_state`.

No new instance-record field is required for grouping: `project_id` already exists and is the
only grouping key. (No `current_chain_id` is added — chain state stays at the task-chain level.)

Capture / update points for `project_id`:
- On creation (`agent_record_upsert` / `handle_agent_instance_create` / `new_instance` start):
  set `project_id` from the identity default (or explicit override).
- On project move (associate/disassociate handlers in agents_start.odin): update `project_id`
  (already persisted) — no id reparse needed.

Exposure to UI — enrich `chat_list_json` (src/daemon/user_rpc.odin) so each chat entry carries:
```json
{
  "agent_instance_id": "conversation@s-9f3a2c",
  "agent_id": "conversation",
  "project_id": "heimdall-core",
  "unread_count": 2,
  "last_message_unix_ms": 0                       // see title/timestamp note below
}
```
Each field is joined from the conversation's `Agent_Instance_Record` (not parsed from the id).

Title & last-message timestamp: `chat_list_json` today returns only `{agent_instance_id,
unread_count}`. Deriving a display title from the first user message is client-side and needs
no schema change; adding `last_message_unix_ms` for sort ordering is a small `message_db`
query addition.

## 4. CLI surface

Chat is already per-instance and needs **no new verbs**:

```
ham-ctl chat list
ham-ctl chat send  --agent-instance-id <id> --body ...
ham-ctl chat fetch --agent-instance-id <id>
ham-ctl chat mark-read --agent-instance-id <id>
```

New capability = instance lifecycle, under `agents` (no `chat new` alias):

```
ham-ctl agents run <agent_id> [--new] [--project <id>] [--tier <t>]   # mint agent_id@s-…, print instance id
ham-ctl agents instances <agent_id>                                    # list live/durable instances (threads)
ham-ctl tasks assign --agent <agent_id|instance_id> [--new-instance]   # resolver-aware assignment
```

## 5. Phased implementation

### Phase 1 — Decouple instance suffix from project (foundation)
- `agent_id_store.odin`: keep `agent_id_from_instance_id` (prefix before `@`). Change
  `agent_instance_id_compose(agent_id, project)` → session-token based
  `agent_instance_id_new(agent_id) -> <agent_id>@s-<hex>`.
- Add `agent_session_token()` generator (short random).
- `agent_store.odin`: `agent_scope_infer` stops deriving project/chain from the `@`-suffix;
  scope becomes explicit (passed at start) with template fallback.
- `agents_start.odin`: `/agents/start` gains a mode:
  - `reuse_instance` (default for chain/task work) — relaunch a given `agent_instance_id`.
  - `new_instance` — mint fresh `agent_id@s-…`, inherit project/provider/tier/template/role
    from `Agent_Id_Record`.
- `agent_runtime_tracker`: no change to coalescing; unique ids make launches no longer collide.

### Phase 2 — Instance lifecycle & inheritance
- On `new_instance`, create `Agent_Instance_Record` inheriting identity defaults.
- Wrapper bootstrap already pulls memories via `target_agent_id` → every instance shares
  memory automatically. Verify project/skill context flows for session-token instances.
- **No cap on concurrent live instances** per `agent_id`.
- Durable instances persist after the process stops (a saved thread). **Resume:** reopening a
  stopped thread relaunches the SAME instance id and reattaches chat history + memories.
- **Shared inbox on resume:** the resumed instance keeps the same `conversation_id` /
  agent-to-agent inbox, so messages and history are continuous across stop/start.
- Explicit "delete thread/instance" archives the `Agent_Instance_Record`.
- **Per-chat start/stop controls:** every conversation/agent chat has a **Start** and **Close
  (stop)** button, matching today's agent controls, with the same **progress bar** during the
  start and stop actions (reuse the existing stop-progress step UI:
  `agent-detail-stop-progress`, `*-stop-step-*`, and an analogous start-progress).

### Phase 3 — Conversation template/role
- Add `src/prompts/conversation_persona.md` + `conversation_instructions.md` (general
  assistant, no chain obligations).
- Seed `conversation` template in `agent_template_db_service.odin`;
  `agent_role_from_template("conversation") -> "conversation"`.
- Ensure chain/task reconcilers (`task_nudge_scheduler.odin`, `task_service.odin`) do not
  auto-nudge / auto-reap conversation instances unless they actually hold a task. Add an
  explicit guard for safety (consistent with the recent idle-shutdown removal).

### Phase 4 — Task assignment & review for any instance
- Assignment resolver accepts `agent_instance_id` OR `agent_id`.
- **Default policy = always new instance** when assigning by `agent_id` (mint a fresh
  `agent_id@session`). A concrete `agent_instance_id` still targets that exact instance.
- No routing changes once `assignee_agent_instance_id` is set.
- CTL: `ham-ctl tasks assign --agent <…>` (agent_id → new instance; instance id → that instance).

### Phase 5 — CLI & UI surface
- CTL: `agents run`, `agents instances` (Section 4).
- UI (see mockups):
  - Chat-first shell: sidebar keeps its current structure with a Conversations section
    grouped by project only (agent_id hidden; no chain grouping/ordering — chains stay in the
    Task Chains view). An Active Task Chains section remains separate as today.
  - **Task chain view = split layout.** Left half is the coordinator chat (reuses the
    conversation composer + message bubbles); right half is a **toggleable** tasks pane. The
    tasks pane keeps the current design: a progress card plus a dependency-ordered todo list
    (Active / Completed groups) with expandable task rows and the existing task detail drawer.
    Do NOT replace the tasks list with a kanban board. Toggling the pane
    (`chain-tasks-toggle-btn`) collapses it to a full-width coordinator chat.
  - Agent identity page listing live/durable instances with "New instance".
  - New `data-debug-id`s to register in `AGENTS.md`:
    `sidebar-new-conversation-btn`, `conversation-thread-${instanceId}`,
    `conversation-thread-open-btn-${instanceId}`, `conversation-composer-input`,
    `conversation-composer-send-btn`, `conversation-model-select`, `conversation-tier-select`,
    `agent-detail-new-instance-btn`, `agent-instance-row-${instanceId}`,
    `agent-instance-open-btn-${instanceId}`.

## 6. Resolved decisions

- **Data migration:** no backwards-compat. Existing `agent@project` instances may be
  **wiped/regenerated** when the session-token id scheme lands.
- **Conversation title:** derived **client-side from the first user message**. No durable
  `title` field / rename support in v1.
- **Instance count:** **no limit** on concurrent live instances per `agent_id`.
- **Resume:** reopening a stopped thread relaunches the **same instance id** and shares the
  **same inbox / `conversation_id`** and history.
- **Assignment default:** assigning by `agent_id` **always creates a new instance**.
- **Per-chat controls:** Start + Close (stop) buttons on every agent/conversation chat, with
  progress bars on both actions (reuse existing stop-progress UI).
- **Project binding per instance:** **per-instance override** — instance inherits the identity's
  default project but may be pointed at another project at launch (`project_id` already exists).
- **Multi-daemon:** out of scope for v1 backend/state work — ship **single-daemon first**, but
  include a **daemon switcher** in the UI shell. Full multi-daemon merge is tracked separately
  in `../multi-daemon/PLAN.md`.
- **Debug-id registry:** new `data-debug-id`s are folded into `AGENTS.md` **after the UI lands**.

## 7. UI mockups

See `mockups/index.html` (all pages share one cross-linked sidebar so navigation is clickable;
each page has a footer listing real data sources vs. new backend fields, and small
`data-debug-id` tags):

New conversation model:
- `01-conversation.html` — active thread; sidebar grouped by project only.
- `02-new-conversation.html` — empty/new state; instance minted on first message.
- `04-agent-instances.html` — identity + multiple live instances sharing details.

Existing features restyled to match (real data + existing debug IDs):
- `10-home.html` — chains by project + running agents.
- `11-chain-view.html` — **split layout**: coordinator chat (left) + toggleable tasks pane
  (right) that keeps the current progress card + dependency-ordered todo list (not a kanban
  board).
- `12-vcs-diff.html` — workspace changed files + rich diff + merge preview.
- `13-chain-editor.html` — create chain + seed tasks.
- `14-artifact-viewer.html` — markdown + PNG annotations.
- `15-attention.html` — approvals, blocked, merge decisions.
- `16-agent-detail.html` — status, chat, tasks, memory (+ “all instances” link).
- `17-settings.html` — agents, templates (incl. new `conversation`), defaults.
- `18-memory.html` — browser, proposal form, history.

Mockups reuse the app's design tokens from `src/ui/styles.css` (dark canvas `#090909`,
accent `#0099ff`) so the chat-first shell stays visually consistent with current Heimdall.
