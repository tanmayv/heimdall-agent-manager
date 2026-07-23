# Heimdall TUI Architecture (`ham-tui`)

Status: Draft — target design for a terminal client
Companion to: `hub-bridge-user-owned-architecture-and-api.md` (data model + API),
`ui-architecture.md` (desktop UI decisions this mirrors)

`ham-tui` is a terminal client for the Heimdall Hub. It is a **third user client**
alongside the desktop UI and `ham-ctl`, built on the same `/api/v1` + user-WS
surface. It targets headless/SSH/dev use: chat with agents, launch instances, and
watch status from a terminal.

---

## 1. Goals and non-goals

Goals (v1):

- Authenticate to a Hub with a **user bearer token** (works headless/over SSH).
- **Chat** with an existing agent conversation/session.
- **Launch** a new instance of an `agent_id` (creating instance + conversation).
- **List + filter** sessions by `all` / agent-id / project / bridge.
- Show live **runtime status** (running/idle/stopped) via user-WS.
- **Stop / restart** an instance.
- **Responsive**: two-pane when wide, **single column when narrow**.
- Built to **extend to task viewing/interaction** later without redesign.

Non-goals (v1):

- Task chains, artifacts viewer, memory management, settings, bridge enrollment.
  These remain in the desktop UI. The TUI stays a chat + launch + status tool in
  v1, with task views planned as an additive phase (see §7).
- No browser/trusted-proxy login flow; machine clients use bearer tokens
  (arch invariant 8). No new backend endpoints are required for v1.

---

## 2. Technology stack

**Python + Textual** (Textual + Rich).

Rationale:

- **Batteries-included styled components**: CSS engine, widgets (`DataTable`,
  `Input`, `TextArea`, `Markdown`, `Tabs`, `ListView`, `Tree`, `Footer`), themes.
- **Responsive layout is first-class**: CSS breakpoints/`@media`-like rules drive
  the two-pane -> single-column collapse automatically (the key requirement).
- **Reactive model** maps onto our "WS event -> update state -> re-render" flow.
- **Markdown rendering** built in for agent chat and (future) task descriptions.
- Rich widget set means future **task tables/detail/tabs** are ready-made.

Tradeoff: Python runtime distribution. Mitigation:

- Beta: install via `uv tool install` / `pipx install ham-tui`.
- Later: single-binary via PyInstaller, shipped alongside the local package
  tarballs (same GitHub Actions release flow as `ham-bridge`/`ham-wrapper`/`ham-ctl`).

Alternatives rejected: Go+Bubble Tea (cleaner binaries but primitive widgets and
manual responsive work), Rust+ratatui (low-level, slower to build), Odin
(no TUI toolkit; would hand-roll rendering). The TUI is decoupled from the Odin
Hub by the HTTP/WS contract, so language consistency buys little; styled
components + responsiveness win.

---

## 3. Client + auth model

The TUI is a user client, identical in spirit to the desktop UI:

- Config/inputs (reusing `ham-ctl` conventions):
  - `--hub` / `$HEIMDALL_HUB_URL`
  - `--token` / `$HEIMDALL_TOKEN` (user API token, granted — not generated in-app)
  - optional `--config` file
- The user API token is **granted by an operator** on the Hub host
  (`ham-hub tokens issue --user <user_id>`, arch 6.3.1), or via the optional
  authenticated token API. There is no in-app token-creation page; the TUI only
  consumes a token it was given.
- On start: register a `client_instance_id` (like `/user-client/register`),
  heartbeat, and open `/api/v1/user-ws`.
- All REST calls send `Authorization: Bearer <user_token>`.
- The `--hub` URL may be a localhost/loopback **SSH tunnel** endpoint, same as
  bridges (free; it is just a base URL).
- Auth failure (`401`) shows a clear "not authenticated / check token" screen,
  not a broken UI. `403` shows access-denied for that resource.

No new backend: it consumes existing REST + user-WS.

---

## 4. Layout and responsiveness

Two layouts driven by Textual CSS breakpoints on terminal width.

Wide (>= ~100 cols): two-pane

```
┌──────────────┬────────────────────────────────────────┐
│ Filter: all ▾│  Backend Agent · running · Heimdall     │
│              │  ────────────────────────────────────   │
│ ▸ Heimdall   │  you: implement bridge enrollment       │
│   ● inst_9a2f│  agent: on it…                          │
│   ○ inst_71bd│                                          │
│ ▸ Conversat… │  ────────────────────────────────────   │
│   ● inst_c40e│  > message…                              │
│ [n]ew [/]flt │  [enter] send  [tab] switch  [q]uit     │
└──────────────┴────────────────────────────────────────┘
```

Narrow (< ~100 cols): single column, drill-down

```
┌────────────────────────┐
│ [Sessions] [Chat]      │  ← tabs / toggle
│ ────────────────────── │
│  session list          │  (or conversation when Chat active)
│ ────────────────────── │
│  > message…            │
│ [n]ew [/]flt [q]uit    │
└────────────────────────┘
```

- Wide: `SessionListPanel` + `ConversationScreen` side by side.
- Narrow: one column; the session list becomes a screen/tab you toggle to
  (mirrors the desktop UI's mobile drill-down). The breakpoint is a CSS rule, not
  bespoke logic.

---

## 5. Screens and components

Structured as screen + panel so future task views slot in additively.

- **AppShell** — owns Hub client, user-WS connection, global keybindings,
  status/footer, and the responsive container.
- **SessionListPanel** — filterable list of conversations/sessions:
  - Filter selector: `all` / `agent-id` / `project` / `bridge` (one active
    dimension at a time, matching the requirement).
  - Rows show agent name, instance id, status dot, project/bridge context, and
    **unread count**.
  - Grouping follows the filter (e.g. by project -> agent when filtering project).
- **ConversationScreen** — the chat surface, built with a **tabbed content
  region** so tasks can be added later:
  - `Chat` tab (v1): transcript (Markdown-rendered) + composer input; header
    chip with agent/status/project; stop/restart actions.
  - `Work` tab (reserved, hidden in v1): task list/detail for the conversation's
    `chain_id` (see §7).
- **NewInstanceModal** — launch an `agent_id` instance:
  - pick agent (required), optional project (default Conversations), advanced
    bridge/provider/tier (provider/tier depend on selected bridge).
  - `POST /api/v1/agent-instances` -> creates instance + conversation -> open it.
- **Reserved (future):** `TaskListScreen`, `TaskDetailScreen`, `WorkPanel`.

---

## 6. Data + real-time model

Mirrors the desktop UI's data discipline in TUI terms:

- Thin typed Hub client over `/api/v1` (REST) with cursor pagination.
- One user-WS connection; on invalidation events, refetch the smallest relevant
  resource (session list, a conversation's messages, an instance's status).
- Reactive app state -> Textual re-renders affected widgets.
- Unread counts and status dots come from the same WS-driven refresh path.

Endpoints used (all existing):

- `GET /api/v1/chats?...` (list conversations, filters)
- `GET /api/v1/chats/{conversation_id}/messages`
- `POST /api/v1/chats/{conversation_id}/messages`
- `POST /api/v1/chats/{conversation_id}/read`
- `GET /api/v1/agent-instances?agent_id=&bridge_id=&project_id=&runtime_status=`
- `POST /api/v1/agent-instances` (launch)
- `POST /api/v1/agent-instances/{id}/stop` and `/restart`
- `GET /api/v1/agents`, `GET /api/v1/projects`, `GET /api/v1/bridges` (filters)
- `GET /api/v1/user-ws` (invalidation events)

---

## 7. Future task support (designed for, not built in v1)

The conversation already carries `chain_id`, so tasks attach to the same
conversation screen without redesign:

- **`Work` tab** on `ConversationScreen`: task list for the chain + a
  current-task strip above the composer (mirrors desktop UI §4A CurrentTaskStrip
  and Work tab).
- **`TaskListScreen` / `TaskDetailScreen`**: full task list (creation-ordered,
  matching UI v1) and task detail with comments, legal status transitions, nudge,
  and same-chain assignment — reusing existing task endpoints
  (`/task-chains/{id}?expand=tasks`, task status/comments/nudge/assign).
- Because these are additive panels/screens over existing endpoints, enabling
  them is a later phase, not a rewrite.

---

## 8. Keybindings (baseline)

- `j`/`k` or arrows: navigate list
- `enter`: open session / send message
- `n`: new instance
- `/`: set/cycle filter (all / agent-id / project / bridge)
- `tab`: switch focus (list <-> conversation; tabs when narrow)
- `s`: stop instance, `r`: restart instance
- `q` / `ctrl+c`: quit
- Mouse optional; keyboard-first.

---

## 9. Distribution

- Binary/command name: `ham-tui`.
- Beta: `uv tool install ham-tui` / `pipx install ham-tui`.
- Later: PyInstaller single binary shipped with the local package tarballs
  (linux/mac x amd64/arm64) via the same GitHub Actions release workflow.

---

## 10. Open decisions

1. Exact narrow breakpoint (cols) and whether to also collapse on short height.
2. Whether v1 ships stop/restart or only chat+launch+filter+status.
3. Whether to reuse `ham-ctl` config file format directly or a TUI-specific config.
