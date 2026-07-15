# Multi-Daemon Management (single UI, many daemons)

Status: Draft plan
Related: `docs/plan/chat-conversation/PLAN.md` (conversation model), this repo's `src/ui`.

## 1. Goal

Let one Heimdall UI connect to **multiple daemons at once** and manage them together:

- **Merged views** — conversations, home chains, agents, and attention from all connected
  daemons appear in one flat list.
- **Daemon disambiguation via a small colored dot** on every row (conversation, agent, chain),
  not by renaming/prefixing entities.
- **Scoped actions** — anything that mutates a specific entity (assign task, start agent, VCS,
  create task) is pinned to that entity's daemon; pickers only show that daemon's agents.

Non-goal: cross-daemon operations (e.g. moving an agent between daemons). Daemons remain
unaware of each other; the merge is purely client-side.

## 2. Why this is mostly a client change

The UI already threads `daemonUrl` through every API call (`src/ui/api/daemonApi.ts`, ~170
call sites). What is single-tenant today is the **state shape**: one `session` in
`chatSlice` (one `daemonUrl`, one `clientInstanceId`/`clientToken`, one `/user-ws`).

Multi-daemon = restructure that state into **N sessions** + **namespace every id by daemon**.
No backend change is required for the merge itself. One small optional backend addition (a
stable daemon self-id) is described in §6.

## 3. Core model: namespace every id by daemon

Native ids (`agent_instance_id`, `project_id`, `chain_id`, `client_instance_id`) are unique
**only within one daemon**. Merging two daemons risks id collisions (e.g. `coder@s-3a1` or
project `heimdall-core` existing on both). Therefore the UI must key everything by a composite
`(daemon_id, native_id)` and never by the native id alone.

```ts
type DaemonConn = {
  id: string;          // stable UI id for this connection
  label: string;       // user-facing name ("prod", "laptop")
  url: string;         // daemonUrl
  color: string;       // dot color, assigned on add
  status: 'connected' | 'connecting' | 'error';
  session: Session;    // per-daemon clientInstanceId/clientToken/ws
};

type ScopedId = { daemon: string; id: string };  // { daemon: 'prod', id: 'coder@s-3a1' }
```

Redux shape: replace the single `session` with `daemons: Record<string, DaemonConn>` plus an
`activeDaemonFilter` set. Every merged entity in the store carries its `daemon` id.

## 4. UI behaviors

### 4.1 Merged, flat lists with daemon dots
- Conversations, home chains, agents, and attention items from all connected daemons are
  merged into one flat list (conversations still grouped by **project only**, per the
  conversation plan).
- Each row gets a **small colored dot** (the daemon's color) + tooltip with the daemon label.
- **Same-name projects across daemons are NOT renamed.** The dot + tooltip disambiguates them.
  (Flat structure with dot indicator — chosen over two-level Daemon→Project grouping.)
- Optional **daemon filter chips** in list headers to show/hide a daemon's items.

### 4.2 Per-daemon connection lifecycle
- Each daemon has its own `/user-client/register`, `/user-client/heartbeat`, and `/user-ws`
  connection and its own client token. WS events are tagged with the originating daemon and
  merged into the same reducers (keyed by `(daemon, id)`).
- Connection status shown per daemon (dot color + connected/connecting/error).

### 4.3 Scoped actions (correctness invariant)
- A task/chain/agent lives on exactly one daemon. Any mutation targets that daemon's API using
  that daemon's session.
- **Assignee / reviewer pickers filter to the entity's daemon agents only.** You cannot assign
  an agent from daemon A to a task on daemon B — this is an invariant, not a limitation to work
  around.
- Start-agent, VCS, create-task, memory actions all use the active entity's daemon.
- Breadcrumb / detail header always shows which daemon the open entity belongs to.

## 5. Settings surface (daemons + providers)

Multi-daemon is configured from the redesigned **Settings** page (modal two-pane layout; see
`docs/plan/chat-conversation/mockups/17-settings.html`). Relevant sections:

- **Daemons** — list connected daemons with color dot + status; add (url + label + user id),
  remove, reconnect, recolor. Backed by per-daemon `/user-client/register` + `/health`.
- **Providers** — per selected daemon, list provider profiles and their model-tier mapping
  (`cheap/normal/smart`) from `/agents/providers`; set the daemon's default provider/tier.
  (Provider profiles are defined in each daemon's `config.toml` under `[wrapper.agent-cmd.*]`;
  the UI reads them read-only for now and only sets the default selection.)
- Existing sections (Agents & templates, Projects, Defaults) become **per-daemon scoped**:
  a daemon selector at the top of those sections; created agents/projects belong to the
  selected daemon.

## 6. Backend addition: daemon self-id endpoint

Add a stable **daemon self-identity** so the UI can pin a consistent key even if the URL
changes. Add `/daemon/info` (or extend `/health`) to return:

```json
{ "daemon_id": "…", "version": "…" }
```

**`daemon_id` is the only backend-provided field.** The daemon's **display name and dot color
are UI-only** settings, configured and stored in the UI (keyed by `daemon_id`), never sent by
or stored on the daemon. If the endpoint is missing, the UI falls back to URL-as-key.

## 7. Sequencing & phases

**v1 = single-daemon first, with a daemon switcher.** The conversation work ships against one
active daemon, but the UI shell includes a **daemon switcher** (select the active daemon) and
the `/daemon/info` endpoint lands early so keys are stable. The full multi-daemon *merge* (one
list across daemons with dots) is a later phase.

0. **Daemon switcher + `/daemon/info`** — single active daemon at a time; switcher in the shell;
   UI stores per-daemon name/color keyed by `daemon_id`.
1. **State restructure** — `daemons: Record<id, DaemonConn>`; migrate `session` consumers to a
   per-daemon lookup; keep single-daemon behavior identical when only one is connected.
2. **Per-daemon connections** — N registrations + N WebSockets; tag WS events with daemon id;
   merge into reducers keyed by `(daemon, id)`.
3. **Merged views + dots** — conversations/home/agents/attention render merged with daemon dot;
   filter chips.
4. **Scoped actions** — pickers and mutations pinned to the entity's daemon.
5. **Settings** — Daemons section (add/remove/reconnect/color) + Providers section; scope
   existing settings sections per daemon.
6. **(Optional) Backend** — daemon self-id endpoint for stable keys/colors.

## 8. Open decision

**Client id per daemon vs. shared:** each daemon issues its own `client_instance_id`/token via
its own `/user-client/register`. Recommend **per-daemon client identity** (simplest, matches the
current registration flow) rather than trying to share one client identity across daemons.
