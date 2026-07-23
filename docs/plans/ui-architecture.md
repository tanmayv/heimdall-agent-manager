# Heimdall UI Architecture (Rewrite)

Status: Draft — decisions captured as we discuss, ahead of mockups
Companion to: `hub-bridge-user-owned-architecture-and-api.md` (data model + API)

This document records the UI structure decisions for the rewritten Heimdall
desktop app. It is chat-first and minimal: the conversation is the star, and
orchestration surfaces sit quietly behind it.

---

## 1. Shell — two regions

The app shell is intentionally simple: a **collapsible left sidebar** + a main
region. When collapsed, the left region becomes a thin icon rail. There is **no**
global context inspector and **no** guide panel (both removed).

```
┌───────────┬─────────────────────────────────────────────┐
│  LEFT     │              MAIN REGION                     │
│  SIDEBAR  │  (routed page; may own its own right panel)  │
└───────────┴─────────────────────────────────────────────┘
```

- The shell owns everything global: nav, current user, the single user-WS
  connection, settings modal, and sidebar collapsed/expanded
  state.
- Pages are routed views. A page that needs a side panel (e.g. the conversation
  inspector, the chain board) owns and toggles it **itself** — it is not shell
  infrastructure.
- No local login **form** (trusted-proxy auth), but there is an **unauthenticated
  landing** that redirects to the external IdP. See §1A.

---

## 1A. Authentication states (trusted-proxy)

Browser auth is delegated to Authentik/Authelia in front of the Hub (arch doc
2.4 / §6.6 / invariant 6–7). The UI never renders a Heimdall username/password
form. It only reacts to auth state.

States:

- **Authenticated:** trusted proxy injected valid identity headers; the Hub maps
  them to a Heimdall user and `/api/v1` calls succeed. Normal app shell renders.
- **Unauthenticated (missing/invalid identity):** any `/api/v1` request returns
  `401 unauthenticated`. The UI must not show the app shell with empty data;
  instead it renders a minimal **unauthenticated landing** and redirects to the
  external login.
- **Forbidden:** a `403` on a specific resource shows access-denied / route-away,
  but does **not** trigger the login redirect (the user is authenticated, just
  not authorized for that resource).

Unauthenticated landing behavior:

```text
app boot / any 401 from /api/v1 or user-ws:
  -> render UnauthenticatedLanding (no app chrome, no data fetch)
  -> redirect to the configured external login URL
     (Authentik/Authelia in prod; ham-dev-proxy selector in dev)
```

- The login/redirect URL is configuration provided to the UI (e.g. an
  `auth.login_url` / `login_url` from a public bootstrap/config endpoint or build
  config); the UI does not hardcode the IdP.
- The landing offers a single "Sign in" affordance that navigates to that URL, and
  auto-redirects when possible. It shows a brief "redirecting to sign in…" state
  rather than a blank screen.
- After successful IdP login, the proxy re-injects identity headers and the user
  returns to the app; the UI retries the failed requests / reloads the shell.
- **Session expiry mid-use:** if a previously authenticated session starts
  returning `401` (cookie/session expired), the UI drops to the same
  unauthenticated landing + redirect, preserving the intended return path where
  the proxy supports it.
- The footer user chip still links to the IdP/dev-proxy **logout** URL; logout
  lands the user back on the unauthenticated landing.

This keeps auth entirely in the trusted proxy while giving unauthenticated users
a clear redirect instead of a broken empty app.

---

## 2. Left sidebar

Global navigation + persistent context. Modeled after a clean chat-app sidebar.
Conversations are not a separate top-level concept from agents: **all
conversations are agent chats**, grouped first by Project and then by Agent ID.
Desktop uses one left region with two states:

- **Expanded:** full sidebar with labels, project → agent_id → session groups,
  unread rollups, footer user/settings controls.
- **Collapsed:** thin icon rail with the same primary destinations as icons;
  tooltips expose labels. Expanding restores the full sidebar. No separate
  contextual panel in v1.

```
┌─────────────────────────────┐
│  Heimdall           ⟨collapse⟩ │
├─────────────────────────────┤
│  ✎  New conversation        │
│  �� Search (⌘K palette)      │   ← opens the command palette (6B)
│  ▤  Library                 │   ← all artifacts, cross-conversation
├─────────────────────────────┤
│  Projects                  ⌄ │
│    ▾ Conversations       3    │   ← default project for new chats; unread rollup
│      ▾ Backend Agent     2    │   ← agent_id group unread rollup
│          inst_9a2f       1    │   ← conversation/session unread badge
│          inst_71bd       1    │
│      ▸ Reviewer Agent    1    │
│    ▸ Heimdall                 │
│    + New project              │
├─────────────────────────────┤
│  Agents / Templates           │   ← create/configure agent identities
│  Task Chains                  │   ← orchestration destination
├─────────────────────────────┤
│  �� User             ⚙︎        │   ← user • settings(modal)
└─────────────────────────────┘
```

Unread badges:

- Session rows show per-conversation unread counts.
- Agent groups show the sum of unread sessions under that `agent_id` within the
  project.
- Project groups show the sum of unread sessions under that project.
- Badges clear when the conversation is opened/read and the UI calls mark-read.
- The collapsed icon rail shows unread rollups for the visible destination icons
  (Chat/Projects tree, Task Chains if task comments/review requests are unread,
  Library if artifact activity is unread).

Deliberately **not** in the sidebar:

- **Memory** — not a global destination. Lives in the conversation inspector
  (in-context) and in Settings (global list). See §4 and §5.
- **Bridges** — infrastructure; lives in Settings.
- **Projects as standalone management pages** — project management lives in
  Settings/Project detail, but the sidebar does show the user's conversation
  tree grouped by project → agent_id → session.

---

## 3. Conversation flow (New → bound)

A conversation starts as a chat composer with embedded launch controls. It
becomes a bound chat thread on first send. Everything needed to create the
session is chosen once **inside the chat input/composer shell**, then locked
(arch doc 7.7 / 7.13 / invariant 22b). Session creation transactionally creates
or loads the trio:

```text
TaskChain + AgentInstance + ChatConversation
```

For normal new conversations, no `chain_id` is supplied, so the Hub creates a
private/default task chain for the instance. That chain is the conversation's
Work context from day one. If the user does not choose a project, the Hub/UI use
the user's default **Conversations** project.

- **State A (empty):** the chat input/composer shell contains the launch
  controls above the message field. Composer is disabled until an agent is
  chosen. Visible launch params: agent (required), project (defaults to
  **Conversations**). Advanced launch params: bridge/machine (`Auto` default),
  provider, tier. Provider and tier options are filtered by the selected
  bridge's reported capabilities and the agent's bridge-support policy; if
  bridge is `Auto`, provider/tier choices are shown only when the Hub can
  resolve compatible options.
- **State B (starting):** on first send the params lock and the Hub creates the
  private/default `TaskChain` + new `AgentInstance` + `ChatConversation` in one
  transaction; selector is replaced by the transcript; a startup progress bar
  renders `startup_status` phases; the message shows as queued until the agent
  is ready.
- **State C (active):** transcript + enabled composer; header shows the bound
  agent + a live status dot. The composer shell shows the instance's current
  working task, when one exists, directly above the message input.

Rules:

- Agent binding and project grouping are chosen before the first message and
  then **immutable** (no change-agent/change-project). Conversation binds 1:1 to
  a restartable instance session, and that instance binds to one immutable task
  chain.
- Continuing an idle conversation restarts the **same** instance on the same
  pinned bridge and same chain (no new instance/chain).
- After start, the launch controls collapse into locked chips in/near the
  composer/header: agent, project, bridge, provider, tier. Agent/project/bridge
  are immutable for the conversation. Provider/tier are runtime tuning values.
  The UI exposes two explicit runtime controls:
  - **Reconfigure provider/tier** → `PATCH /api/v1/agent-instances/{id}` with the
    new provider/tier; the Hub restarts the same `agent_instance_id` process.
  - **Restart** → `POST /api/v1/agent-instances/{id}/restart` to relaunch the
    same instance without changing provider/tier (e.g. after a crash/idle).
  Both keep the same instance/conversation/chain; both are explicit actions with
  a restart indication, never silent dropdown changes.
- **Current task strip:** when the instance has a current assigned/in-progress
  task in its chain, render a compact task card directly above the chat input:
  title, status, assignee/reviewer chips, quick "open task" link, and primary
  legal next action if available (e.g. submit for review / mark complete / vote
  when the user is reviewer). This strip is the chat-local view of the Work tab,
  not a separate task source. If there is no active task, show no strip or a
  subtle "No active task" affordance.
- Provider/tier controls always depend on bridge selection: selecting a bridge
  narrows provider/tier to that bridge's capabilities intersected with
  `AgentBridgeSupport`; selecting a different bridge before first send may change
  or clear provider/tier. Once started, bridge is locked.
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
- **Workspace** — shown only if the conversation has a `project_id`. **v1 scope:**
  effective path on the pinned bridge plus bridge path-validation status only. No
  VCS branch view, no live diff, no changed-files list in v1 (no backend VCS/diff
  endpoints). VCS/diff is out of scope until backend adds it.
- **Memory** — this agent's memories (`agent_id`-scoped). Supports inline
  approve/reject of pending proposals so the user never leaves the chat. Shows a
  **badge** when proposals are pending, and the inspector surfaces/pulses when a
  new proposal arrives over WS. Hint text notes memory is shared across all
  conversations with this agent.
- **Artifacts** — this conversation's artifacts; click opens the fullscreen
  viewer.

Scope note: Memory is identity-scoped (shared across the agent's conversations);
Work is the instance's immutable chain; Workspace/Artifacts are project/conversation scoped.

### 4A. Task chain presentation inside an open agent chat

Every open agent chat has exactly one immutable chain via its bound
`AgentInstance.chain_id`. The chat page should make that chain visible without
turning the conversation into a project-management page. The hierarchy is:

```text
ConversationPage
  ConversationHeader     → agent/project/bridge/status chips + open full chain
  ChatMessageList        → normal transcript
  ChatComposerShell
    CurrentTaskStrip     → current working task above input
    ChatInput
  ConversationInspector
    WorkTab              → compact chain/task overview
```

#### Header chain affordance

The conversation header includes a compact Work chip when a chain exists (always
true after start), plus a user-review chip when any task in this chain needs the
user's review:

```text
Backend Agent  ● running   Project: Heimdall   Work: Backend Agent session · 2/5
                                           Review needed: 1   [open chain]
```

- Click `Work` / `open chain` → full Chain view for `chain_id`.
- Click `Review needed` → opens the **oldest** task in this chain whose status is
  `in_validation` and whose effective reviewers include the current user
  (ordered by task `created_at`); the chip shows the total count of such tasks.
- For team-chain conversations, include chain title and role hint, e.g.
  `Work: Hub Rewrite · reviewer`.
- The review chip is scoped to this conversation's chain only. Global/multi-chain
  review attention still surfaces through unread badges and the command palette.

#### ChatComposer capabilities

The conversation composer is the central input surface. It supports both initial
launch and ongoing chat.

Baseline input behavior:

- multiline text input
- Enter to send, Shift+Enter for newline
- send button with disabled/loading states
- visible send error and retry affordance for failed sends
- bottom-pinned, keyboard-aware mobile behavior with safe-area padding
- draft text retained while navigating within the app/session when practical

Attachments / artifact creation:

- file upload from composer
- drag/drop files onto composer
- paste image/file into composer
- **upload-before-send:** a dropped/pasted/selected file uploads immediately to
  create a user artifact, showing a per-file **progress bar**; the message is
  sent with the resulting `artifact_ids` only after uploads complete
- upload error display + retry/remove per file
- attached artifact chips shown before send (name, kind, progress, remove)
- uploaded files become user-created artifacts associated with the conversation,
  project, chain, and message where applicable
- send is disabled while any attachment upload is in progress
- composer can attach existing artifacts from Library later, but v1 priority is
  upload/paste/drag-drop into the current conversation

Mentions:

Composer supports structured mentions using:

```text
@<category>:<id>
```

Supported categories:

- `@agent:<agent_id>`
- `@task:<task_id>`
- `@task-chain:<chain_id>`
- `@memory:<memory_id>`
- `@project:<project_id>`
- `@artifact:<artifact_id>`

Autocomplete behavior:

- Typing `@` opens category suggestions.
- Typing `@task:` / `@artifact:` etc. switches to entity search for that
  category.
- Suggestions show human label + stable id + compact metadata (status for task,
  kind for artifact, project for chain/task, etc.).
- Selecting a suggestion inserts the canonical mention text and renders it as a
  chip in the composer while preserving plain-text form in the outgoing body.
- Mention resolution is user-scoped and permission-checked. Unknown/deleted refs
  render as unresolved/deleted chips in history.
- Mentions are metadata hints/context links; they do not by themselves assign
  tasks, change reviewers, or grant access.
- **Storage:** the mention text always travels in the message `body`. If the
  backend message model exposes a structured mentions field, also send parsed
  mentions as metadata (e.g. `mentions: [{ type, id }]`); if it does not, the
  plain-text `@category:id` in the body is sufficient for v1. The UI renders
  mention chips by parsing the body when no metadata is present.

Recommended non-v1 / later:

- slash commands
- markdown toolbar
- voice input
- implicit "also attach this chat message as a task comment" behavior

#### CurrentTaskStrip (above chat input)

Directly above the chat input, show the task this instance is currently expected
to act on. This is the most important work affordance in chat.

```
┌─────────────────────────────────────────────────────────────┐
│ Current task: Implement bridge enrollment        in_progress │
│ Assignee: you/this agent   Reviewer: user        [ Open ]     │
│ Acceptance: one-time token · hashed bridge token             │
│ [Submit for review] [Comment] [Nudge]                        │
└─────────────────────────────────────────────────────────────┘
Message Backend Agent…
```

Data source (client-side inference, no new endpoint required):

- The conversation already loads its chain tasks for the Work tab via
  `GET /api/v1/task-chains/{chain_id}?expand=tasks`. The current-task strip and
  the review-needed chip are **derived from that same cached task list** using
  effective assignee/reviewer resolution; the UI does not need a separate
  per-conversation "current task" call.
- Selection order:
  1. task where effective assignee is this conversation's `agent_instance_id`
     and status is `in_progress`
  2. else task where this instance is an effective reviewer and status is
     `in_validation`
  3. else next `assigned`/unblocked task for this instance
  4. else no strip, or a subtle collapsed "No active task" row
- If the backend later adds convenience fields (e.g. `current_task_id`,
  `review_needed_count`) to conversation/chain detail, the UI may consume them,
  but inference from the loaded task list is the v1 approach and the source of
  truth for the badge counts.

Contents:

- task title + status
- role label: `assignee`, `reviewer`, `coordinator`, or `observer`
- compact acceptance criteria summary (first 1–2 items)
- assignee/reviewer chips
- primary legal action for the current actor:
  - assignee: start / submit for review / pause / comment
  - reviewer/user: vote good/not-good / comment
  - coordinator: mark complete / nudge / comment
- `Open` opens the task detail in the full Chain view or inspector detail state.

Rules:

- The strip is a view of the task-chain state; it does not create separate chat
  state.
- Do not show multiple active task cards. If multiple tasks match due to backend
  inconsistency, show the highest-priority/current one and include a warning in
  WorkTab.
- The strip updates from the same RTK Query/WS invalidation path as the Work tab.
- On mobile, the strip is collapsible to one line so it does not crowd the
  keyboard/composer.

#### WorkTab in conversation inspector

The Work tab is the compact chain dashboard for the current conversation. It is
not the full chain editor.

```
Work
  Chain: Backend Agent session        private_conversation · active
  Progress: 2/5 complete
  Coordinator: inst_9a2f
  Default reviewers: user

  Active / next
    ● Implement bridge enrollment       in_progress    [open]
    ○ Add tests                         assigned       [open]

  Completed
    ✓ Define bridge schema              completed

  [Open full chain]
```

WorkTab shows:

- chain title, kind, status, progress counts
- coordinator instance chip (click opens coordinator conversation; for private
  chain this is the current conversation)
- default reviewer chips
- active/assigned/in-validation tasks first, then completed collapsed
- unread task-comment/review badges
- **Needs user review** group/chip for tasks where `status = in_validation` and
  effective reviewers include the current user
- quick actions: open task, comment, nudge, vote when legal
- `Open full chain` route to full Chain view

WorkTab does not show dependency graph or structure editing in current v1.

#### Task comments from chat

- Quick `Comment` from CurrentTaskStrip opens a small comment composer in the
  strip or WorkTab; submitting creates a normal task comment, not a chat message.
- If the user types a normal chat message while a current task is active, it
  remains a chat message. The UI may offer a secondary "also attach to current
  task" action later, but v1 keeps chat and task comments explicit.
- New task comments/review requests increment unread badges for the relevant
  session/project/chain surfaces.

#### Empty/private chain behavior

A newly launched conversation may have a private/default chain with no tasks yet.
In that state:

- Header still shows `Work: <session title> · 0 tasks`.
- CurrentTaskStrip is hidden or collapsed as `No active task`.
- WorkTab shows an empty state: "No concrete tasks yet. Ask the agent to make a
  plan, or create a task." Optional `[Create task]` opens a draft-task form with
  default assignee = this instance and default reviewer = user.

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
- Row/card click → fullscreen ArtifactViewer (view + download; no versioning in
  v1).
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

### Artifact viewer (recommendation)

The viewer is a fullscreen overlay opened from any artifact chip/card. It is a
Tier-1 mobile surface, so it must be excellent on small screens.

Required (v1):

- **Fullscreen overlay** with breadcrumb/title, meta strip (kind, size, project,
  chain, creator, updated), close.
- **Kind-aware rendering:**
  - text/markdown/json/diff → rendered with monospace/markdown/diff view and
    copy-all
  - image (png/jpg/etc.) → image view with **pinch-zoom/pan** on touch and
    wheel/drag zoom on desktop
  - unknown/binary → metadata + download only
- **Download** the artifact content.
- **Rename / edit description** from the viewer header (`PATCH`).
- **Delete** from the viewer (`DELETE`), with the unavailable-placeholder rule.

Explicitly out of v1 (no backend support):

- version history / version selector
- rollback to a prior version
- annotations (view or create)

These return only if/when the backend adds artifact versioning/annotation APIs.

Data/loading:

- Metadata via artifact detail; bytes via the separate artifact content route
  (never embedded in list payloads).
- Large artifacts stream/lazy-load; show a loading state and size guard before
  fetching very large blobs on mobile.

---

## 5A. Chain view (full page)

Current v1 Chain UI is intentionally simple because backend graph/dependency
support is not in place yet: show tasks as a **vertical list ordered by
creation** (`created_at`, with `task_id` as deterministic tie-breaker if needed),
plus deep interaction with a selected task. This is distinct from the
conversation inspector, which is for high-level updates and quick nudge/vote
only.

```
┌───────────────────────────────────────────────────────────────────────┐
│  ← Hub Rewrite Chain     published · active · 12/20     [message coord] │
├──────────────────────────────────┬────────────────────────────────────┤
│          TASK LIST                │        TASK DETAIL (selected)      │
│          (creation order)         │                                    │
│  1. Phase 1: Foundation      ✓    │   Phase 7: Project API             │
│  2. Phase 2: Auth           ✓    │   published · in_progress          │
│  3. Phase 3: Owner scope    ✓    │   assignee ● coder  reviewer ● rev  │
│  4. Phase 7: Project API    ●    │   ─────────────────────────────     │
│  5. Phase 8: Runtime        ○    │   Description / acceptance (REQ-IDs)│
│  6. Phase 9: Bootstrap      ○    │   Comments (threaded, paginated)   │
│                                  │   [transitions] [nudge] [vote]     │
│                                  │   [assignee/reviewer] [publish]    │
└──────────────────────────────────┴────────────────────────────────────┘
```

Task list (current v1):

- Vertical list, ordered by task creation time (`created_at`) with stable tie
  break by `task_id` if needed.
- Row glyph/color = execution `status`; small avatar = assignee; reviewer badge
  when present.
- Draft tasks are visible with dashed/ghost styling but not actionable until
  published.
- Completed tasks can collapse behind a show-completed toggle once lists get
  long.
- Click selects a task and opens detail on the right. No dependency graph or DAG
  layout in current v1 UI.

Future backend graph support can replace/augment this list later, but the
current UI must not invent dependency order client-side.

Task detail (right pane, side-by-side, on select):

- Header: title, publish_state + status, assignee/reviewer, dependency links.
- Body: description, acceptance criteria (REQ-IDs), full threaded comments
  (paginated load-older).
- Role-aware interactions: comment (add/resolve), legal status transitions only,
  nudge (`POST .../tasks/{id}/nudge`), vote via status transition
  (`validated_good`/`validated_not_good`), assignee/reviewer pickers, and
  **publish** for draft tasks (`POST .../tasks/{id}/publish`).
- **Chain-level lifecycle controls** (chain header/overview): `publish` the chain
  (`POST /task-chains/{id}/publish`) to move draft->active, and `complete`
  (`POST /task-chains/{id}/complete`) with final summary + quality rating. These
  draft->published->complete controls must be visibly placed, not buried.
- **Assignment picker:** tasks assign actor refs, not free-form names. The
  assignee picker shows same-chain agent instances grouped by `agent_id` (no user
  option in v1). The reviewer picker shows the user plus same-chain agent
  instances. Agent-instance options must validate
  `agent_instance.chain_id == task.chain_id`.
- **Add agent to chain from picker:** if the desired agent identity is not yet in
  the chain, the picker can offer "Add agent to this chain". That flow chooses an
  `agent_id`, hydrates a new `AgentInstance` into the current `chain_id`
  (`POST /api/v1/agent-instances` with the existing `chain_id`), which creates
  its 1:1 conversation, then selects the new `agent_instance_id` for the task.
  The picker never attaches an unrelated live instance from another chain.
- **User as actor (recommendation):** allow the **user as a reviewer** ref on any
  task (this is the default for private chains). Do **not** support the user as a
  task assignee in v1 — assignees are agent instances that do the work. Revisit
  user-as-assignee only if a manual/user-owned task type is added later.
- Nothing selected -> right pane shows chain overview (goal, coordinator,
  progress, final summary).

Coordinator chat is **linked out** ("message coordinator" opens the coordinator
conversation), not embedded — keeps the chain page focused on tasks.

Inspector vs full chain view:

| Capability | Conversation inspector | Chain view (full page) |
|---|---|---|
| See tasks + status | compact list | vertical list |
| Dependency order | no | not yet (future graph support) |
| Quick nudge / vote | yes | yes |
| Current working task above chat input | yes | n/a |
| Read/add comments | no | yes (full threads) |
| Status transitions | no | yes |
| Assignee/reviewer edit | no | yes (same-chain picker + hydrate-agent flow) |
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
bridges, # running instances), and a **memory summary** from
`GET /api/v1/agents/{id}?expand=memory_summary` (active/pending counts + recent
items). The "what is this agent" summary.

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
pending + add/edit. Uses `memory_summary` for header counts and the memory list
endpoint for the full list. Same surface as the conversation inspector's Memory
tab and the global Settings → Memory view.

No Project tab: agents are project-agnostic (no `project_id` on Agent). A project
is chosen per launch and shown per session in the Sessions list.

---

## 6. Settings (modal)

Overlay, not a route. Houses infrequent/global management:

- **Providers / provider profiles** — provider config/defaults (see 6F).
- **Bridges** — the user's machines (see 6A).
- **Projects** — project metadata, default path, and per-Bridge path overrides
  (see 6C).
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
nav chrome minimal (see 6D).

---

## 6C. Settings → Projects / Project detail

Projects are context and grouping. They are selected at launch/chain creation,
shown as chips in conversations/chains, used as filters in Library/Chains,
discoverable through the command palette, and used by the sidebar to group agent
chats by project → agent_id → session. Every user has a default project named
**Conversations** used when a new chat does not select another project.

Project detail is opened from:

- command palette result (`Project: Heimdall`),
- a project chip in a conversation/chain header,
- Settings → Projects list.

```
Project: Heimdall                                      [ Edit ]
  repo: github.com/tanmayv/heimdall-agent-manager
  vcs: git

Default path
  /Users/tanmayvijay/heimdall-agent-manager            [ Save ]

Bridge paths
  macbook      /Users/tanmayvijay/heimdall-agent-manager  valid   [ validate ] [ edit ]
  linuxbox     /home/tanmay/src/heimdall                   valid   [ validate ] [ edit ]
  old-vps      (uses default path)                         unknown [ set override ]
```

Required controls:

- **Create/edit project metadata:** name, description, repo URL, VCS kind.
- **Default path:** mandatory Hub-owned fallback path used when a Bridge has no
  override. Editable from Project detail.
- **Per-Bridge path overrides:** one row per owned Bridge; optional override path
  stored as `ProjectBridgePath`. Empty means "use default path".
- **Validate path** per Bridge -> Bridge path validation command. Shows status:
  unknown / valid / invalid, last validated time, and error details.
- **Used by** summary: agent chat sessions (grouped by agent_id), chains, and
  artifacts that reference this project (compact counts + links), so opening a
  project still gives context without becoming a top-level workspace page.

Launch behavior:

```text
effective_path(project_id, bridge_id):
  ProjectBridgePath override if present
  else Project.default_path
```

Path validation is **advisory only and never blocks launch** in v1. The effective
path is used to populate bootstrap context (e.g. the working-directory hint in
the generated `AGENTS.md`), not to gate whether an instance may run. If
validation is `unknown` or `invalid`, the UI may show a non-blocking warning, but
the user can always start the instance.

Default project behavior:

- The first user setup creates or ensures a user-owned project named
  **Conversations** (`vcs_kind = none`).
- New agent chats default to this project unless the user selects a different
  project in the composer launch controls.
- The default project is **renamable but not deletable** (it always remains the
  user's fallback conversation project even if renamed).
- Its path controls work like any other project: default path plus optional
  per-Bridge overrides. This gives casual conversations a predictable local
  working directory on each Bridge.

---

## 6D. Responsive / mobile design

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
  - **Task chain view** — see the ordered task list, tap a task, and **read +
    comment** (and nudge/vote). Task commenting is mobile-critical, not
    desktop-only.
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
| Chain task list + task detail | Drill-down: list full-screen -> tap task -> task detail full-screen (back). Not side-by-side. |
| Library grid | Reflows to 1–2 columns; filters in a sheet. |
| Settings modal | Full-screen. |

### Bottom tab bar (mobile)

```
[ ��� Chat ]  [ ⛓ Chains ]   ( �� )   [ ▤ Library ]  [ ⚙ More ]
                             ↑ center = command palette
```

- **Chat** = conversations (list -> thread); Home/new-conversation is Chat's
  empty state. Shows a badge for total unread agent-chat messages.
- **Chains** = chain list -> task list -> task detail. Shows a badge for unread
  task comments/review requests assigned to the user.
- **Center = command palette** (dedicated center button; also hotkey).
- **Library** = artifacts. Shows a badge for unread/new artifact activity if the
  backend exposes artifact attention counts.
- **More** = Agents, Settings, Bridges (Tier 2/3), also reachable via palette.

Two of the four tabs (Chat, Chains) are Tier-1 surfaces; Library is the artifact
gateway; the palette absorbs the rest so nav chrome stays minimal.

### Mobile ergonomics (constraints on all components)

- Composer is keyboard-aware and bottom-pinned, respecting safe-area insets.
  The conversation composer includes the current-task strip above the input when
  applicable. The **task comment composer reuses the conversation composer
  component** (same behavior on the task detail screen).
- Chain task list is vertical and creation-ordered, which suits phone scrolling.
  Future graph support can add a separate mobile fallback later.
- Touch targets >= 44px; artifact viewer supports pinch-zoom/pan for images.
- `data-debug-id` is layout-independent — same elements across breakpoints, so
  the Electron debug API keeps working on every layout.

---

## 6E. Legacy UI code to remove / not port

The rewrite should not carry forward old UI surfaces that are not represented in
this design. Prefer deleting/replacing them over hiding them behind flags; hidden
legacy surfaces create navigation, data, and debug-id ambiguity.

### Remove / do not port as standalone surfaces

- **Global workspace shell / inspector architecture** — replaced by the simple
  shell: collapsible left sidebar + routed main page. Do not port:
  - `workspace/UnifiedWorkspaceShell.tsx`
  - `workspace/WorkspaceLeftSidebar.tsx`
  - `workspace/WorkspaceMainRegion.tsx`
  - `workspace/ContextInspector.tsx`
  - `workspace/GenericAgentWorkspacePage.tsx`
  - `workspace/routes.ts` / workspace route indirection
- **Guide panel / guide-agent UI** — no guide panel in the rewrite. Remove any
  guide-specific chat/panel/debug controls instead of reintroducing a global
  assistant surface.
- **Home/dashboard/getting-started/onboarding surfaces** — the default daily
  entry is the conversation/project-agent tree plus New Conversation. Do not port
  hero dashboards or onboarding cards as primary navigation. (`OnboardingWizard`
  may be replaced later by a small first-run checklist, but it is not part of v1
  shell design.)
- **Standalone Memory page** — memory lives in Conversation inspector, Agent
  detail, and Settings → Memory. Do not port `MemoryManagementPage.tsx` as a
  top-level route.
- **Standalone Attention page and global attention badge** — removed in v1.
  Attention is expressed through per-surface unread badges (sidebar tree, mobile
  tabs, Work tab review chips) and the command palette, not a dedicated bell/page.
  Do not port `AttentionPage` or a global attention bell.
- **Global right sidebar / global context inspector** — page-owned panels only.
  Conversation owns its inspector; Chain owns its task detail panel; Settings owns
  its modal/fullscreen surface.
- **Local proxy / remote proxy agent wizard surfaces** — federation/proxy
  compatibility is out of v1. Do not port `NewLocalProxyAgentWizard.tsx` or
  proxy-specific management UI.
- **Vim/sidebar-specific editing surfaces** — not in v1 UI. Do not port
  `VimSidebar.tsx` as a global component.
- **Old ChainEditor dependency/structure editing surface** — current v1 chain UI
  is a creation-ordered task list + task detail. Do not port graph/dependency
  editing until backend graph/dependency support is designed and implemented.

### Keep only as refactor sources

These components may contain useful behavior, but should be treated as source
material for new rewrite components, not kept as-is if their assumptions conflict
with this document:

- `chat/ChatComposer.tsx`, `chat/ChatMessageList.tsx`, `MessageBubble.tsx` —
  reuse/refactor for the new Conversation page. Add launch controls + locked
  chips + current-task strip to the composer shell.
- `ArtifactViewer.tsx`, `ArtifactUpload.tsx` — reuse/refactor for Library and
  conversation artifacts. Mobile fullscreen viewer behavior is required. Drop
  version-history and annotation UI (out of v1); keep view/download/rename/
  description/delete.
- **Workspace VCS/diff UI** — do not port diff/branch/changed-file components; v1
  Workspace tab is effective-path + validation status only.
- `RuntimeRestartControls.tsx` — reuse/refactor for provider/tier restart flows;
  must respect locked agent/project/bridge and Bridge-dependent provider/tier
  options.
- `AgentPickerV2.tsx` / `AgentPicker.tsx` — reuse/refactor into the new
  same-chain task assignment picker plus "hydrate agent into this chain" flow.
- `SettingsPage.tsx` — replace with the new Settings modal/fullscreen sections:
  Bridges, Projects, Providers, Memory, defaults/dev/debug.

### Delete route/state coupling with removed surfaces

When removing these components, also remove their route entries, Redux slices,
WS invalidation branches, debug IDs, and API endpoint calls if they are only used
by removed surfaces. Keep shared endpoint modules only when they are still used
by the rewrite pages above.

---

## 6F. Settings → Providers / provider profiles (recommendation)

Provider profiles are **configuration only** (no code/binary installation). They
describe how an already-installed provider CLI is launched and how its runtime
state is detected. Based on current backend capability, profiles are
**Bridge-local config** (arch runtime doc §11 `[providers.*]`), and the Hub only
stores selected defaults.

Settings → Providers should show:

- **Per-Bridge capability view:** for each Bridge, the providers/tiers it
  currently reports (`capability_report`), online/offline, last capability
  refresh, and a **Refresh capabilities** action (`refresh_capabilities`).
- **Account defaults:** default provider + default tier used when a launch does
  not override them (Hub-stored).
- **Read-only profile inspection (v1):** show the effective profile fields a
  Bridge is using per provider:
  - command + structured args/flags (arrays, not raw shell)
  - tier -> model mapping
  - bootstrap file preferences
  - startup detection (ready/blocked/failed patterns, safe auto-inputs)
  - activity detection (active/blocked patterns, idle timeout)

Editing model (recommendation, staged):

- **v1:** provider profiles are edited as Bridge-local config files/import;
  the UI surfaces them read-only plus the refresh action, because the Hub does
  not own provider-profile records yet.
- **later:** if the Hub adds durable provider-profile storage, add UI to
  create/import/review/enable profiles and push them to Bridges. Until then,
  the UI must not imply the Hub owns editable provider profiles.

Hard rule: provider profiles never install software or run arbitrary scripts.
Commands/args are structured with a fixed placeholder set
(`{model}`, `{project_path}`, `{prompt_file}`, …); secrets are referenced by env
var name, never stored in the profile.

---

## 7. Real-time + data layer

Use the **current stable UI data model as the main reference**, adapted to the
rewrite API:

- RTK Query API slice for server state/cache (`src/ui/api/heimdallApi.ts` style):
  endpoint modules by resource, tag types, cursor pagination, compact list vs
  expand-on-detail.
- Normal Redux slices/component state for local UI state only: selected tab,
  sidebar collapsed state, composer draft, transient progress/toasts, local
  optimistic UI.
- One `/api/v1/user-ws` connection owned by the shell; receives lightweight
  invalidation/summary events (not full durable payloads).
- WS handling follows the current `wsInvalidation.ts` pattern: patch cached query
  data from event summaries when safe, otherwise invalidate/refetch the smallest
  relevant RTK Query tag/resource.
- This drives unread badges, list badges, live status dots, conversation
  updates, task/chain refresh, artifact/library refresh, and Memory-proposal
  badge/surface behavior. There is no separate global attention badge in v1.

Principle: **server state lives in RTK Query; UI-only state lives in slices or
component state; WebSocket events patch/invalidate server-state caches.**

---

## 8. UI <-> backend gap analysis

Comparison of the rewrite backend surface (arch doc `/api/v1`, runtime protocol)
against what this UI design consumes. Two directions.

### 8.1 Backend supports it, UI has not surfaced it yet

These exist in the backend plan but are not (fully) placed in the UI; either wire
them up or consciously defer.

- **`GET /api/v1/me` + `GET /api/v1/me/logout-url`** — the shell must consume
  `/me` for the current user chip and `/me/logout-url` for logout (UI 1A / footer).
  Add explicitly; currently only implied.
- **`GET /api/v1/templates` + `POST /api/v1/templates`** — agent templates are
  referenced in Agent detail (persona/template), but there is no UI surface to
  browse/create templates. Decide: a Templates area in the Agents section or
  Settings, or defer template authoring.
- **`POST /api/v1/batch/get`** — batch fetch is available; the data layer should
  use it for list->detail hydration and mention/chip resolution instead of N
  calls. Not mentioned in §7; add as a data-layer optimization.
- **`GET /api/v1/agents/{id}?expand=memory_summary`** — RESOLVED: Agent detail
  Overview + Memory tab now consume `memory_summary` for counts/recent items.
- **Bridge `project_paths` expand / `POST .../bridge-paths/{bridge_id}/validate`
  / `PUT|DELETE bridge-paths`** — Project detail (6C) uses these; confirm the UI
  wires validate + override CRUD, including the per-Bridge delete override.
- **`agent-instances/{id}/restart` vs reconfigure** — RESOLVED: conversation
  runtime controls now surface both `PATCH /agent-instances/{id}` (reconfigure
  provider/tier) and `POST .../restart` (plain relaunch) explicitly.
- **Task nudge / publish endpoints** — RESOLVED: task detail places
  `POST .../tasks/{id}/publish` and `nudge`; chain header places chain
  `publish` and `complete`.

### 8.2 UI expects it, backend does not cover it yet

These are UI needs with no clear backend endpoint in the current plan. Each needs
a backend task or an explicit UI simplification.

- **Reviewer vote / LGTM endpoint** — RESOLVED (UI simplification): v1 voting is a
  task status transition (`validated_good`/`validated_not_good`) via
  `POST .../tasks/{id}/status`. No separate vote endpoint.
- **Artifact versions / rollback / annotations** — RESOLVED (removed from UI): v1
  artifact viewer is view + download + rename + description + delete only. No
  version history, rollback, or annotations in the UI. Backend needs no artifact
  versioning/annotation work for UI v1.
- **Workspace/VCS diff surface** — RESOLVED (removed from UI): v1 Workspace tab is
  effective path + bridge path-validation status only. No VCS branch view or live
  diff in the UI. Backend needs no VCS/diff endpoints for UI v1.
- **Structured message mentions storage** — composer emits `@category:id`; backend
  `ChatMessage` has no mentions field. Handled by the body-only fallback (§3), but
  if we want clickable/validated mentions we need a backend `mentions` field.
- **Conversation convenience fields (`current_task_id`, `review_needed_count`)** —
  UI infers these client-side from loaded chain tasks (works for v1). Optional
  backend convenience fields would reduce per-conversation task fetches.
- **Unread counts beyond chat** — sidebar/mobile want unread rollups for task
  comments/review and artifact activity. Chat has `unread_count`; task/artifact
  attention counts are not defined. Needs backend attention counts or UI derives
  chat-only unread in v1 and computes review-needed from loaded tasks.
- **Artifact "used by" / provenance links** — Project detail and Library filters
  rely on artifact provenance fields (present on the model); ensure list filters
  (`agent_id`, `chain_id`, `task_id`, `project_id`) are all queryable.
- **Command palette global search** — DECIDED: add a **backend global search
  endpoint** (spec in §8.4). The palette targets one search endpoint instead of
  fanning out to N per-resource `?q=` calls.

### 8.3 Resolution ownership

- UI-only simplifications (no viewer versions/annotations, no Workspace diff,
  chat-only unread, status-transition voting) are captured above and need **no
  backend work**.
- The one net-new backend requirement for UI v1 is the **global search endpoint**
  (§8.4). Optional/deferred backend items (structured mentions field, non-chat
  attention counts, artifact versioning/annotations, VCS/diff) are **not** blockers
  for the UI v1 skeleton and can be filed separately.

### 8.4 Backend task: global search endpoint

Needed by the command palette (6B) and sidebar search. Define and hand to the
coordinator.

Endpoint:

```http
GET /api/v1/search?q=<text>&types=<csv>&limit=<n>&cursor=<opaque>
```

Request:

- `q` — required free-text query (min length e.g. 1–2 chars).
- `types` — optional CSV filter over
  `agent,agent_instance,conversation,task,task-chain,project,artifact,memory`.
  Omitted = all supported types.
- `limit` — per-response cap (e.g. default 20, max 50), applied across grouped
  results.
- `cursor` — opaque pagination cursor (optional).

Behavior:

- Owner-scoped only: results are restricted to the authenticated user's resources
  (same `owner_user_id` rules as every other endpoint). No cross-user leakage.
- Matches on human-visible fields per type (name/title/body-preview/slug/id).
- Returns grouped, ranked, compact hits — not full resource payloads (the UI
  fetches detail on selection, optionally via `POST /batch/get`).

Response shape:

```json
{
  "data": {
    "groups": [
      {
        "type": "conversation",
        "hits": [
          {
            "id": "conv_123",
            "label": "Bridge migration plan",
            "sublabel": "Backend Agent · Heimdall",
            "score": 0.91,
            "route": "/conversations/conv_123"
          }
        ]
      },
      {
        "type": "task",
        "hits": [
          {
            "id": "task_123",
            "label": "Implement bridge enrollment",
            "sublabel": "chain: Hub Rewrite · in_progress",
            "score": 0.72,
            "route": "/chains/chain_123?task=task_123"
          }
        ]
      }
    ]
  },
  "page": { "limit": 20, "next_cursor": null, "has_more": false }
}
```

Field notes:

- `type` — one of the supported entity types.
- `id` — stable resource id (used for `@category:id` mention resolution too).
- `label` / `sublabel` — display strings; `sublabel` carries compact context
  (agent, project, chain, status, kind).
- `score` — relevance score for ranking within/across groups (impl-defined).
- `route` — optional UI route hint; the UI may compute its own route from
  `type`+`id` instead.

Non-goals for v1:

- No full-text body indexing guarantees; substring/prefix matching on key fields
  is acceptable for the beta.
- No highlighting/snippets required in v1 (nice-to-have later).
- Same endpoint also backs `@category:id` mention autocomplete by passing
  `types=<single-category>`.

---

## 9. Open decisions

No open structural UI decisions currently. Remaining work is the routes +
component hierarchy section and detailed component specs (conversation page,
artifact viewer, task detail/comments, Settings subsections, provider profiles).
