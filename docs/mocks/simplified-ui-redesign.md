# Simplified UI Redesign — "Conversations first"

## Problem

The current UI is confusing for two reasons:

1. **Too many top-level surfaces.** The left rail has Home, Memory, Agents, Library,
   Task chains, Projects, Settings — seven peers with no obvious "start here". A user
   who just wants to talk to an agent has to understand the whole information
   architecture first.
2. **The multi-device / multi-agent nature leaks everywhere.** Agents are a separate
   noun from conversations, and it is never clear which **bridge** (device) and which
   **AI model** a given conversation is actually running on. "Agents are confusing —
   not sure which bridge/runtime they are backed by."

## Design goals

- Make the product feel like Claude / ChatGPT: a **single main column of
  conversations**, a composer, and a lightweight left rail.
- **Projects group conversations** (an optional folder layer), not a separate
  management surface you have to visit.
- Inside a conversation, surface **runtime facts plainly** — which bridge (device),
  which model/provider, live/stopped — and make them **changeable in place**.
- Be **minimal**: do not bombard the user. Secondary nouns (Memory, Agents catalog,
  Bridges, Task-chain internals) move into a single **Settings/Manage** area and an
  on-demand **inspector**, not the primary flow.

## What "conversation" means here

Every conversation is a chat with a **coordinator agent instance**. The backend
already models this:

- `chat_*` conversation ↔ `agent_instance_id` (the concrete running instance).
- The instance record carries the runtime truth we need to show:
  `bridge_id`, `provider`, `tier`, `runtime_status`, `startup_status`, `project_id`.
- Bridges have friendly labels (`macbook`, `dawnstar`, `cloudtop`) via `/api/v1/bridges`.
- Task chains have a `coordinator_agent_instance_id`; a coordinator conversation and a
  chain are two views of the same instance.

So "coordinator conversation" is just: **the chat with the instance that coordinates a
chain (or a standalone chat if there is no chain).** No new backend concept required.

## New information architecture

```
┌───────────────┬──────────────────────────────────────────────┬───────────────┐
│  LEFT RAIL    │  MAIN: conversation thread                   │  INSPECTOR    │
│               │                                              │  (on demand)  │
│  + New chat   │  ┌────────────────────────────────────────┐  │               │
│               │  │ Header: title                          │  │  Tasks /      │
│  ▸ Project A  │  │ ● macbook · claude · smart  [Change ▾] │  │  Workspace /  │
│    · convo 1  │  │────────────────────────────────────────│  │  Artifacts    │
│    · convo 2  │  │ messages …                             │  │               │
│  ▸ Project B  │  │                                        │  │  (only shown  │
│    · convo 3  │  │                                        │  │   when the    │
│  ▸ No project │  │────────────────────────────────────────│  │   convo has   │
│    · convo 4  │  │ [ composer …                    Send ] │  │   a chain)    │
│               │  └────────────────────────────────────────┘  │               │
│  ⚙ Manage     │                                              │               │
└───────────────┴──────────────────────────────────────────────┴───────────────┘
```

### Left rail (primary nav)

- **New chat** button (top). One click starts a conversation.
- **Projects as collapsible groups.** Each project is a folder; its conversations
  nest under it. An always-present **"No project"** group holds ungrouped chats.
- Each conversation row: title, a small **status dot** (green=live, grey=stopped),
  last-message preview, unread badge, relative time.
- A single **Manage** entry at the bottom collapses everything secondary
  (Agents catalog, Bridges/devices, Memory, Projects settings) into one place.

The rail intentionally **drops** Memory / Agents / Library / Task chains as top-level
peers. They are still reachable, just not competing for primary attention.

### Main column (the conversation)

- **Runtime chip** directly under the title is the key fix. It reads, in plain words:
  `● macbook · claude · smart` where
  - the dot = runtime status (green live / amber starting / grey stopped),
  - `macbook` = the **bridge label** (device),
  - `claude` = provider, `smart` = model tier.
- Clicking **Change ▾** opens a small popover to switch **bridge / provider / model**
  (backed by `reconfigure` + `restart` on the instance, constrained to each bridge's
  real capability matrix). Same popover offers **Start / Stop**.
- Messages + composer are standard chat. Nothing else on screen by default.

### Inspector (on demand, right)

Only appears when the conversation's coordinator owns a **task chain**. Tabs:
Tasks, Workspace (diff), Artifacts — all already backed today. Collapsed by default so
the default experience stays clean.

## Explicit non-goals / removed clutter

- No separate "Agents" browsing surface in the primary flow. You talk to
  conversations; the agent identity is an implementation detail shown as the runtime
  chip. (Agent identity management lives under Manage for power users.)
- No always-visible task-chain board. Task chains are reached through their
  coordinator conversation, or from Manage.
- No federation/peer terminology in the primary flow. "Bridge" is presented as
  **device** with a friendly label.
- No multi-daemon switcher up front (single hub per session).

## Backing every element with real backend capability

| UI element | Backend it maps to |
|---|---|
| Conversation list, grouped by project | `listConversations` + instance `project_id`; `listProjects` |
| New chat | `createAgentInstance` / launch composer (existing) |
| Runtime chip (bridge · provider · tier · status) | `agent-instances/{id}` fields + `bridges` labels |
| Change bridge/provider/model | `reconfigureAgentInstance` + `restartAgentInstance`, capability matrix from `bridges` |
| Start / Stop | `startAgent` / `stopAgent` |
| Messages / send / read | `fetchChat`, `sendToAgent`/`sendToCoordinator`, `markChatRead` |
| Inspector → Tasks | `listChainTasks`, task status/promotion (live) |
| Inspector → Workspace diff | `fetchWorkspace`, `fetchWorkspaceDiff` |
| Inspector → Artifacts | `listArtifacts` |
| Manage → Memory/Agents/Bridges/Projects | existing panels, relocated |

No element in the mock requires a capability the hub/bridge does not already expose.

## Mobile

The same model collapses to a standard mobile chat app — no separate IA:

- **List view** = the rail as a full screen: search, project group headers, and
  conversation rows that each show the runtime line (`macbook · claude · smart`) and a
  status dot on the avatar. A floating **＋** starts a new chat; a bottom tab bar gives
  Chats / Projects / Manage.
- **Thread view** slides in on tap: back chevron, title, the **runtime chip** in the
  header, and a `▤` for the task/workspace sheet.
- **Runtime** is a **bottom sheet** (device / provider / model + Apply & restart /
  Stop) instead of a popover — the touch-native equivalent of the desktop chip.

Everything is the same data and the same endpoints; only the layout adapts.

## Interactive mock

See `docs/mocks/simplified-ui.html` — a self-contained, clickable prototype rendering
**both the desktop and the mobile view side by side**, using the real bridge
labels/providers/instances observed on `hub.mundus.in` so the runtime chip,
change-popover, and mobile runtime sheet feel true to production.

Screenshots reviewed during design:
- Desktop default (conversations grouped by project, runtime chip under title).
- Desktop with runtime popover + task-chain inspector open (shows promotion states
  done → in progress → waiting).
- Mobile thread view with the runtime bottom sheet.
