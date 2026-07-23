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
│  �� Search                   │
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

- **Work** — this instance's tasks, grouped by chain. Chain = group header
  (click → full chain board); tasks = actionable rows with status.
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
Work/Workspace/Artifacts are instance/project/conversation scoped.

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

## 6. Settings (modal)

Overlay, not a route. Houses infrequent/global management:

- **Providers** — provider config/defaults.
- **Bridges** — the user's machines: enrollment flow, capabilities, rename,
  revoke, per-project path overrides. (Not a top-level nav item.)
- **Memory (global)** — full unfiltered list of all memories across all agents,
  with search + filters (agent, type, status) and the same approve/reject
  actions available in the inspector. Global counterpart to the inspector tab.
- **Default agents / defaults**, dev-proxy/daemon connection, debug toggle.

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
