# Heimdall UI Architecture (Rewrite)

Status: Draft — decisions captured as we discuss, ahead of mockups
Companion to: `hub-bridge-user-owned-architecture-and-api.md` (data model + API)

This document records the UI structure decisions for the rewritten Heimdall
desktop app. It is chat-first and minimal: the conversation is the star, and
orchestration surfaces sit quietly behind it.

---

## 1. Shell — two regions

The app shell is intentionally simple: a left sidebar + a main region. There is
**no** global context inspector and **no** guide panel (both removed).

```
┌───────────┬─────────────────────────────────────────────┐
│  LEFT     │              MAIN REGION                     │
│  SIDEBAR  │  (routed page; may own its own right panel)  │
└───────────┴─────────────────────────────────────────────┘
```

- The shell owns everything global: nav, current user, the single user-WS
  connection, attention badge, settings modal.
- Pages are routed views. A page that needs a side panel (e.g. the conversation
  inspector, the chain board) owns and toggles it **itself** — it is not shell
  infrastructure.
- No login page (trusted-proxy auth). The footer user chip links to the IdP /
  dev-proxy logout URL.

---

## 2. Left sidebar

Global navigation + persistent context. Modeled after a clean chat-app sidebar.

```
┌─────────────────────────────┐
│  Heimdall           ⟨collapse⟩ │
├─────────────────────────────┤
│  ✎  New conversation        │
│  �� Search (⌘K palette)      │   ← opens the command palette (6B)
│  ▤  Library                 │   ← all artifacts, cross-conversation
├─────────────────────────────┤
│  ▸ Agents                 ⌄  │   ← expandable; pinned agents inline
│      ● Backend Agent        │       (click = new/open conversation)
│      +  New agent           │
├─────────────────────────────┤
│  Task Chains                │   ← the one orchestration destination
├─────────────────────────────┤
│  Recent                     │   ← recent conversations (title + agent dot)
├─────────────────────────────┤
│  �� User      ��    ⚙︎        │   ← user • attention bell • settings(modal)
└─────────────────────────────┘
```

Deliberately **not** in the sidebar:

- **Memory** — not a global destination. Lives in the conversation inspector
  (in-context) and in Settings (global list). See §4 and §5.
- **Bridges** — infrastructure; lives in Settings.
- **Projects** — treated as a scope/attribute, not a daily destination (open
  question whether it becomes a scope switcher; see §6).

---

## 3. Conversation flow (New → bound)

A conversation is an "instance launch form" that becomes a chat thread on first
send. Everything needed to create an `AgentInstance` is chosen once, above the
composer, then locked (arch doc 7.7 / 7.13).

- **State A (empty):** agent selector is the hero, above the composer. Composer
  disabled until an agent is chosen. Launch params: agent (required), project
  (optional), advanced provider/tier. No agent dropdown inside the composer.
- **State B (starting):** on first send the params lock into the conversation +
  a new `AgentInstance` session; selector is replaced by the transcript; a
  startup progress bar renders `startup_status` phases; the message shows as
  queued until the agent is ready.
- **State C (active):** transcript + enabled composer; header shows the bound
  agent + a live status dot.

Rules:

- Agent binding is chosen before the first message and then **immutable** (no
  change-agent). Conversation binds 1:1 to a restartable instance session.
- Continuing an idle conversation restarts the **same** instance on the same
  pinned bridge (no new instance).
- Provider/tier can be changed mid-conversation via reconfigure (restarts the
  same instance id; see arch 13.6). This is the only mutable launch param from
  the UI; agent/bridge/project are fixed for the conversation.
- Startup is detached from the page: navigating away does not cancel it.

---

## 4. Conversation right inspector

Per-conversation panel, owned by the conversation page. Collapsed by default
(chat-first). Tabs are conditional — hidden when empty — except Memory.

```
Right Inspector (toggle, default collapsed)
  [ Work ] [ Workspace ] [ Memory ] [ Artifacts ]
    ↑instance  ↑project     ↑agent_id   ↑conversation
```

- **Work** — this instance's single immutable task chain (private/default for a
  normal conversation, or shared team chain for chain work). Shows the chain
  summary plus actionable task rows with status; click the chain header to open
  the full chain board.
- **Workspace** — shown only if the conversation has a `project_id`. Effective
  path on the pinned bridge, VCS kind/branch, validation status, and live diff /
  changed files when VCS-backed.
- **Memory** — this agent's memories (`agent_id`-scoped). Supports inline
  approve/reject of pending proposals so the user never leaves the chat. Shows a
  **badge** when proposals are pending, and the inspector surfaces/pulses when a
  new proposal arrives over WS. Hint text notes memory is shared across all
  conversations with this agent.
- **Artifacts** — this conversation's artifacts; click opens the fullscreen
  viewer.

Scope note: Memory is identity-scoped (shared across the agent's conversations);
Work is the instance's immutable chain; Workspace/Artifacts are project/conversation scoped.

---

## 5. Library page (artifacts)

Top-level left-sidebar destination. A filterable gallery/list of **all** the
user's artifacts across every conversation/chain/project — the global
counterpart to the conversation inspector's Artifacts tab.

```
Library                              [ grid | list ]  [ + Upload ]
Search: [______]  Kind:[all▾]  Agent:[all▾]  Project:[all▾]  Chain:[all▾]
```

- Filters: kind, agent, project (primary); chain, task (secondary). Backed by
  the artifact provenance fields.
- Grid (thumbnails/previews) vs list (dense).
- Row/card click → fullscreen ArtifactViewer (versions, annotations, download).
- Upload supported here (user-created artifacts).

### Artifact naming / description / delete

- `name` is a human display label, free-form and non-unique; independent of the
  underlying filename/content-type. `artifact_id` is the identity.
- `description` is an optional longer note, shown in the Library and viewer.
- **Rename / edit description** inline (pencil on card + in viewer header) →
  `PATCH /api/v1/artifacts/{id}`.
- **Delete** from card menu + viewer → `DELETE /api/v1/artifacts/{id}`. Deleted
  artifact references in chat/comments render as an unavailable placeholder.
- Agent-created artifacts default `name` to the supplied filename; user can
  rename anytime.

Two artifact surfaces (consistent daily-vs-global pattern):

| Surface | Scope |
|---|---|
| Inspector → Artifacts tab | this conversation |
| Library page | all artifacts, filterable |

---

## 5A. Chain view (full page)

The chain page's job is **the map**: a simplified dependency graph showing the
order tasks will be worked, plus deep interaction with a selected task. This is
distinct from the conversation inspector, which is for high-level updates and
quick nudge/vote only.

```
┌───────────────────────────────────────────────────────────────────────┐
│  ← Hub Rewrite Chain     published · active · 12/20     [message coord] │
├──────────────────────────────────┬────────────────────────────────────┤
│         DEPENDENCY GRAPH          │        TASK DETAIL (selected)      │
│         (top -> bottom)          │                                    │
│              [P1]                │   Phase 7: Project API             │
│               │                  │   published · in_progress          │
│              [P2]                │   assignee ● coder  reviewer ● rev  │
│               │                  │   deps: P6                         │
│              [P3]                │   ─────────────────────────────     │
│            ┌──┼──┐               │   Description / acceptance (REQ-IDs)│
│          [P4][P5][P11]           │   Comments (threaded, paginated)   │
│               │                  │   [transitions] [nudge] [vote]     │
│              [P6] …              │   [assignee/reviewer] [publish]    │
└──────────────────────────────────┴────────────────────────────────────┘
```

Graph (the hero):

- **Top-to-bottom DAG**, laid out by `depth` levels from the chain-graph API
  (`GET /task-chains/{id}?expand=graph`).
- **Minimal edges only** — the backend transitively reduces the graph; the UI
  renders exactly the edges it returns. Order/structure is the point, not edge
  clutter.
- Node glyph/color = execution `status`; small avatar = assignee.
- The **unblocked frontier** (runnable-now tasks) is highlighted; downstream
  dimmed. This visualizes the exact order the backend will pick next tasks.
- **Draft tasks** render as dashed/ghost nodes (in the plan, not yet workable),
  so the whole plan is visible even before publish.
- Completed "waves" collapse by default with a show-completed toggle (keeps focus
  on now+next).
- **Click selects** a node (detail on the right). No hover preview.

Ordering is backend-owned (arch doc 15.3a, invariant 20d): the same canonical
order drives the graph layout AND next-task selection, so the graph never lies
about what runs next. The UI never computes its own ordering.

Task detail (right pane, side-by-side, on select):

- Header: title, publish_state + status, assignee/reviewer, dependency links.
- Body: description, acceptance criteria (REQ-IDs), full threaded comments
  (paginated load-older).
- Role-aware interactions: comment (add/resolve), legal status transitions only,
  nudge, vote lgtm/ngtm, assignee/reviewer pickers, publish (if draft).
- Nothing selected -> right pane shows chain overview (goal, coordinator,
  progress, final summary).

Coordinator chat is **linked out** ("message coordinator" opens the coordinator
conversation), not embedded — keeps the chain page focused on graph + tasks.

Inspector vs full chain view:

| Capability | Conversation inspector | Chain view (full page) |
|---|---|---|
| See tasks + status | list, grouped | the graph |
| Dependency order | no | yes (the point) |
| Quick nudge / vote | yes | yes |
| Read/add comments | no | yes (full threads) |
| Status transitions | no | yes |
| Assignee/reviewer edit | no | yes |
| Draft / publish | no | yes |

---

## 5B. Agent detail page

The home for a durable agent identity: configure it, launch/stop its instances,
see all its conversations, and manage its memory + bridge config.

Create-new-agent is a modal from the Agents list; it lands here on the new
agent's detail page.

```
┌───────────────────────────────────────────────────────────┐
│  ← Backend Agent      active     [ Edit ] [ Archive ]        │
│  claude · smart (defaults) · slug: backend-agent            │
├──────────────────────────────────────────────────────────┤
│  [ Overview ] [ Sessions ] [ Bridges ] [ Memory ]           │
└──────────────────────────────────────────────────────────┘
```

Header: name, state (active/archived), default provider/tier, slug.
`Edit` (name/template/defaults/instructions), `Archive`.

**Overview** — persona/template, instructions, defaults, counts (# enabled
bridges, # running instances). The "what is this agent" summary.

**Sessions** — every instance of this agent. Because an instance is 1:1 with a
conversation (arch invariant 22a), the instances list and conversations list are
the **same list**. Each row shows the **instance id** (displayed instead of a
conversation title here), plus bridge, provider/tier, `runtime_status`, and
origin (chat / chain).

```
Sessions                                        [ + Launch instance ]
  ● inst_9a2f   macbook  claude/smart  running   → open
  ○ inst_71bd   linuxbox claude/normal stopped   → open   [ start ]
  ● inst_c40e   macbook  claude/smart  running   (chain: Hub Rewrite)
```

- **`[ + Launch instance ]`** — configure bridge (from enabled support) +
  provider/tier (defaulted) + optional project, then start. Because no existing
  `chain_id` is supplied, this **creates a private/default task chain +
  conversation + starts the instance immediately** into an empty but live
  conversation, and navigates the user into it to chat (arch 7.13 / invariant
  22b). No first message required.
- **Open** — go to that instance's conversation.
- **Start / Stop** per instance — stop idles the conversation (revivable later by
  a message or relaunch, same restartable-session model); start relaunches the
  same instance id.
- Chain-work sessions appear here too (with a chain tag) and open the same way —
  this is how the user chats with the coordinator or an individual chain agent.

**Bridges** — the `AgentBridgeSupport` config: which bridges this agent may run
on, per-bridge provider/tier override, priority, max_instances, enable/disable
toggle. -> `PUT/PATCH /agents/{id}/bridge-support`. Validated against each
bridge's capabilities. (An agent with no enabled support cannot launch;
invariant 19.)

**Memory** — this agent's memories (`agent_id`-scoped): list + approve/reject
pending + add/edit. Same surface as the conversation inspector's Memory tab and
the global Settings → Memory view.

No Project tab: agents are project-agnostic (no `project_id` on Agent). A project
is chosen per launch and shown per session in the Sessions list.

---

## 6. Settings (modal)

Overlay, not a route. Houses infrequent/global management:

- **Providers** — provider config/defaults.
- **Bridges** — the user's machines (see 6A).
- **Memory (global)** — full unfiltered list of all memories across all agents,
  with search + filters (agent, type, status) and the same approve/reject
  actions available in the inspector. Global counterpart to the inspector tab.
- **Default agents / defaults**, dev-proxy/daemon connection, debug toggle.

### 6A. Settings → Bridges

The user's machines. Maps entirely onto existing endpoints (arch doc 10.x); no
new backend. Scope is intentionally minimal for v1: **no delete guard, no
migration, no DELETE endpoint**. "Remove" = revoke (cuts the machine off, keeps
the record).

```
Settings → Bridges                                   [ + Add bridge ]
  ● macbook     online    claude(smart,normal)   2 instances   → detail
  ○ linuxbox    offline   claude(normal)          0 instances
  ⊘ old-vps     revoked   —                         0 instances
```

List (`GET /bridges`): status dot, label, hostname/OS/arch, capabilities,
active-instance count, last-seen.

**Add bridge (enrollment ceremony):**

```
[ + Add bridge ]
  name: [ MacBook ]  (optional; defaults to reported hostname)
     → POST /bridge-enrollments { label, expires_in_seconds: 900 }
  ┌────────────────────────────────────────────┐
  │ Enrollment created — run on your machine:    │
  │   ham-bridge enroll --hub <url> \            │   ← from setup_command
  │     --token hbe_secret_once                  │   ← enrollment_token, copy btn
  │ ⚠ Shown once. Store it now.                  │
  │ Expires in 14:59   [ Regenerate ]           │   ← countdown
  └────────────────────────────────────────────┘
  → (waits) bridge runs enroll → POST /bridges/enroll → row appears online
```

- `enrollment_token` is rendered **once**; UI warns it is a secret, offers copy.
- Pending enrollments listed from `GET /bridge-enrollments` (never shows raw
  token); a pending enrollment can be revoked (`DELETE /bridge-enrollments/{id}`)
  or regenerated if expired.

**Bridge detail:**

- Status, hostname/OS/arch, capabilities (providers/tiers), last-seen
  (`GET /bridges/{id}?expand=instances,project_paths`).
- **Rename** inline → `PATCH /bridges/{id}` (sets user-customized label).
- Instances running on this bridge (from expand).
- Per-project path overrides for this bridge.
- **Rotate token** → `POST /bridges/{id}/rotate-token`; new token shown once,
  invalidates the old one (the running bridge must be restarted with the new
  token).
- **Revoke** (= "remove") → `POST /bridges/{id}/revoke`; invalidates token,
  disconnects the live WS, marks the bridge revoked/offline. The record is kept.

No hard delete, no dependency guard, no migration in v1.

---

## 6B. Command palette (global)

A single global overlay that unifies **navigation + actions + search**. It is one
component, invoked from multiple places, on both desktop and mobile.

Invocation:

- Desktop: hotkey (Cmd/Ctrl-K), and the sidebar "Search" item opens the same
  palette (Search and the palette are the same surface).
- Mobile: hotkey where available **plus a dedicated center button in the bottom
  tab bar** (the palette is the hub of mobile navigation).

Content (grouped results):

```
┌────────────────────────────────────────┐
│ �� Type a command or search…            │
├────────────────────────────────────────┤
│ NAVIGATE   New conversation, Library,   │
│            Task Chains, Settings…        │
│ CONVERSATIONS  recent, fuzzy-matched    │
│ AGENTS     jump / start new conversation │
│ CHAINS     jump to chain                 │
│ ARTIFACTS  jump to artifact              │
│ ACTIONS    New chain · New agent · New    │
│            project · Nudge task…         │
└────────────────────────────────────────┘
```

- **Navigate** — jump to any top-level destination.
- **Entities** — fuzzy-find + jump to a conversation, agent, chain, project,
  artifact.
- **Actions (verbs)** — New conversation, New chain, New agent, New project,
  Start agent X, Nudge task… The action layer is what makes it more than search.
- Results are grouped by type. Selecting an entity navigates; selecting an
  action runs it (or opens its modal).

Because the palette handles "get me to X" in a few keystrokes, mobile can keep
nav chrome minimal (see 6C).

---

## 6C. Responsive / mobile design

Mobile is a first-class target, built as one **responsive codebase** (not a
separate app), breakpoint-driven. Delivery to actual phones (PWA/web) is a later
concern, but layouts and touch ergonomics are designed for it now. The same
`/api/v1` + user-WS backend already supports non-desktop clients.

Breakpoints (approx): `< 768px` mobile, `768–1024px` tablet, `> 1024px` desktop.

### Priority tiers

Mobile philosophy: **monitor + lightweight actions**. You chat/triage from your
phone; you author/review structure from your desk. Concretely:

- **Tier 1 — must be excellent on mobile:**
  - **Conversation UI** — chat, compose, startup progress, status.
  - **Artifact viewer** — fullscreen read, image zoom/pan, markdown, download.
    (Annotation is best-effort/desktop-first.)
  - **Task chain view** — see the graph, tap a task, and **read + comment** (and
    nudge/vote). Task commenting is mobile-critical, not desktop-only.
- **Tier 2 — works, not optimized:** Library, Agents, Home/new conversation,
  Memory approve/reject.
- **Tier 3 — desktop-first, mobile read-mostly:** chain structure editing
  (dependencies), Bridges setup, diff-heavy workspace review, Settings authoring.

### Layout collapse strategy (side-by-side -> navigable)

Every desktop "two panes side-by-side" becomes a mobile screen/sheet:

| Desktop | Mobile |
|---|---|
| Sidebar + main | Sidebar = off-canvas drawer; main full-width. Core dests in bottom tab bar. |
| Conversation + right inspector | Inspector = bottom sheet (toggle in header); tabs = segmented control. Memory-proposal badge stays on the header button. |
| Chain graph + task detail | Drill-down: graph full-screen -> tap node -> task detail full-screen (back). Not side-by-side. |
| Library grid | Reflows to 1–2 columns; filters in a sheet. |
| Settings modal | Full-screen. |

### Bottom tab bar (mobile)

```
[ ��� Chat ]  [ ⛓ Chains ]   ( �� )   [ ▤ Library ]  [ ⚙ More ]
                             ↑ center = command palette
```

- **Chat** = conversations (list -> thread); Home/new-conversation is Chat's
  empty state.
- **Chains** = chain list -> graph -> task detail.
- **Center = command palette** (dedicated center button; also hotkey).
- **Library** = artifacts.
- **More** = Agents, Settings, Bridges (Tier 2/3), also reachable via palette.

Two of the four tabs (Chat, Chains) are Tier-1 surfaces; Library is the artifact
gateway; the palette absorbs the rest so nav chrome stays minimal.

### Mobile ergonomics (constraints on all components)

- Composer is keyboard-aware and bottom-pinned, respecting safe-area insets.
  The **task comment composer reuses the conversation composer component** (same
  behavior on the task detail screen).
- Chain graph is top-to-bottom, which suits vertical phone scrolling; horizontal
  branch fan-out may scroll horizontally within a level, with a "frontier list"
  fallback view when the graph is too wide.
- Touch targets >= 44px; artifact viewer supports pinch-zoom/pan for images.
- `data-debug-id` is layout-independent — same elements across breakpoints, so
  the Electron debug API keeps working on every layout.

---

## 7. Real-time + data layer

- One `/api/v1/user-ws` connection owned by the shell; receives lightweight
  `resource_changed` invalidation events (not full payloads).
- On an event: update from the summary if sufficient, else refetch just that
  resource. Drives the attention badge, list badges, live status dots, and the
  Memory-proposal badge/surface behavior.
- Data layer: typed `/api/v1` client with cursor pagination; compact list vs
  expand-on-detail. (Stack decision — RTK Query vs manual slices — still open.)

---

## 8. Open decisions

1. Left region: single collapsible sidebar vs icon-rail + contextual panel.
2. Projects: top-level scope switcher vs attribute-only vs Settings.
3. Conversation launch params: which are visible vs behind "advanced"
   (lean: agent + project visible; provider/tier advanced).
4. Data/real-time stack: RTK Query vs manual slices.
5. Task board grouping on the chain page: kanban columns vs list with status
   chips (8-state execution enum is a lot for columns).
