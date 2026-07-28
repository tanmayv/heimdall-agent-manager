# Project Management (Hub Rewrite) — Plan

## Goal

Let a user, in the Heimdall UI:

1. Create and view projects in Settings.
2. Give each project a per-bridge working path (and optionally validate it).
3. Select a project when launching an agent instance, so the instance runs in
   that project's bridge-specific path.
4. Collapse/expand each project group in the sidebar so long project/session
   trees stay navigable.
5. Show a live indicator dot next to each agent/session, and color-code that dot
   per bridge so it is obvious which machine an instance is running on.

## Current State (what already exists)

Project management is **mostly implemented on the backend and bridge**; the gap
is almost entirely UI wiring plus one small backend read surface.

### Backend (Hub) — DONE

- Domain: `src/hub/domain/project.odin`
  - `Project` (name, slug, description, repo_url, vcs_kind, default_path)
  - `Project_Bridge_Path` (project_id, bridge_id, path, is_validated,
    last_validated_at, validation_error, validation_details_json)
- Repository: `src/hub/repository/iface/project_repo.odin` +
  `src/hub/repository/sqlite/*` (projects, project_bridge_paths tables from
  migration `002_owner_scoped_core.sql`).
- Service: `src/hub/service/project/project_service.odin`
  - `create`, `get`, `list`, `update`
  - `set_bridge_path`, `delete_bridge_path`, `list_bridge_paths`
  - `resolve_effective_path` (per-bridge override, else project default_path)
  - `validate_bridge_path` (sends `validate_project_path` command to the bridge)
- REST routes (`src/hub/app/wiring.odin`), all owner-scoped via `require_auth`:
  - `GET  /api/v1/projects`
  - `POST /api/v1/projects`
  - `GET  /api/v1/projects/{id}` (includes `bridge_paths`)
  - `PATCH /api/v1/projects/{id}`
  - `PUT  /api/v1/projects/{id}/bridge-paths/{bridgeId}`
  - `DELETE /api/v1/projects/{id}/bridge-paths/{bridgeId}`
  - `POST /api/v1/projects/{id}/bridge-paths/{bridgeId}/validate`

### Instance launch → project — DONE

- `agent_service.create_instance` accepts `project_id`, calls
  `resolve_project_path_for_launch` (per-bridge path, else default_path), and
  stores `project_path` on the instance.
- Launch command JSON to the bridge includes `project_path`.
- Bootstrap-for-bridge JSON includes project name/repo/vcs.

### Bridge — DONE

- `src/bridge/hub_runtime_client.odin`: `bridge_runtime_launch_agent` reads
  `project_path` from the launch command and uses it as the tmux `run_dir`
  (falls back to a default run dir when empty).
- `src/bridge/project_path_validation.odin`: `bridge_validate_project_path_local`
  checks existence, directory, and git-root (for `vcs_kind == "git"`).
- Hub↔bridge WS validation round-trip:
  `src/hub/service/bridge_runtime/bridge_runtime.odin` +
  `bridge_handlers.odin` (`project_path_validation_result`).

### UI — PARTIAL / STALE

- `src/ui/api/daemonApi.ts` project helpers use the **legacy `/user-rpc`
  actions** (`project_list`, `project_create`, …) that the rewrite Hub does not
  serve. `src/ui/api/endpoints/projects.ts` is built on those, so it is dead in
  the rewrite shell.
- `src/ui/api/daemonApi.ts` already has correct rewrite bridge-path helpers:
  `putProjectBridgePath`, `deleteProjectBridgePath`, `validateProjectBridgePath`
  (they hit `/api/v1/projects/.../bridge-paths/...`).
- `ProjectsSettingsPanel` in `src/ui/components/shell/AppShell.tsx` calls
  `cookieJsonFetch('/projects')` / `cookieMutation('/projects', ...)`
  (correct base → `/api/v1/projects`), but:
  - create only sends `name` + `description`; the Hub **requires
    `default_path`**, so creation currently fails validation.
  - it is read-only otherwise (no detail, no bridge paths, no edit).
- `ConversationLaunchComposer` already has a project `<select>`, but the project
  list comes from `useListSidebarProjectsQuery` and the selected `project_id` is
  passed into the bind/launch flow. It does **not** surface the per-bridge path
  or its validation state.
- Sidebar `ProjectConversationTree` (`AppShell.tsx`) renders each project group
  (`sidebar-project-group-${projectId}`) always-expanded; there is **no
  collapse/expand affordance** per project.
- The sidebar shows no live/running indicator per agent or session, and no
  bridge affiliation. `SidebarConversation` (`sidebar.ts`) does not currently
  carry `bridge_id` or `runtime_status`; the shell would need those to render a
  live dot colored per bridge. Agent instance JSON (`write_agent_instance_json`)
  already exposes `bridge_id` + `runtime_status`, so the data exists upstream.

## Scope Of This Work

Deliver a coherent UI on top of the existing backend:

1. Settings → Projects: create, list, open detail, edit, and manage per-bridge
   paths (set / validate / delete).
2. Fix project creation to include `default_path` (Hub requirement).
3. Instance launch: keep project selection, and show the resolved per-bridge
   path + validation status for the chosen bridge so the user knows where it
   will run.
4. Add the one missing Hub read route needed by the UI (see Task 1).
5. Make each sidebar project group collapsible/expandable, with persisted
   per-project collapsed state.
6. Add a per-agent/session live status dot in the sidebar, color-coded per
   bridge, with a legend/tooltip mapping color → bridge.

Non-goals (call out, do not implement here):
- Task-chain / VCS workspace project binding beyond what already exists.
- Multi-user/project sharing.
- Reordering projects (legacy `project_reorder` is not part of the rewrite).

---

## API Contracts (exact calls the UI makes)

All UI calls go through the trusted-proxy cookie session (`credentials:
'include'`) against `/api/v1`, mirroring `sidebar.ts` / bridges. Use
`cookieJsonFetch` (GET) and `cookieMutation` (POST/PATCH/PUT/DELETE).

### Projects

`GET /api/v1/projects` → list

```jsonc
// 200 -> { "data": [ ... ], "page": { ... } }   (cookieJsonFetch returns data[])
[
  {
    "project_id": "proj_ab12",
    "name": "Website rewrite",
    "slug": "website-rewrite",
    "repo_url": "git@github.com:me/site.git",
    "vcs_kind": "git",
    "default_path": "/Users/me/code/site",
    "updated_at": "2026-07-28T20:11:00Z"
  }
]
```

`POST /api/v1/projects` → create (⚠ `default_path` is REQUIRED)

```jsonc
// request
{
  "name": "Website rewrite",        // required
  "description": "Frontend migration",
  "repo_url": "git@github.com:me/site.git",
  "vcs_kind": "git",                 // "" | "git" | "jj"
  "default_path": "/Users/me/code/site"  // required
}
// 201 -> single project object (same shape as list row)
// 400 -> { "error": { "code": "validation_failed", "message": "default_path is required" } }
```

`GET /api/v1/projects/{projectId}` → detail (includes bridge_paths)

```jsonc
{
  "project_id": "proj_ab12",
  "name": "Website rewrite",
  "slug": "website-rewrite",
  "repo_url": "git@github.com:me/site.git",
  "vcs_kind": "git",
  "default_path": "/Users/me/code/site",
  "bridge_paths": [
    {
      "project_id": "proj_ab12",
      "bridge_id": "br_home_mac",
      "path": "/Users/me/code/site",
      "is_validated": true,
      "last_validated_at": "2026-07-28T20:15:00Z",
      "validation_error": "",
      "validation_details": { "transport": "bridge_ws", "vcs_kind": "git" }
    }
  ],
  "updated_at": "2026-07-28T20:11:00Z"
}
```

`PATCH /api/v1/projects/{projectId}` → update (send only changed fields)

```jsonc
{ "name": "New name", "description": "...", "repo_url": "...", "vcs_kind": "git", "default_path": "/new/path" }
// 200 -> project object
```

### Per-bridge paths

`PUT /api/v1/projects/{projectId}/bridge-paths/{bridgeId}` → set override

```jsonc
// request
{ "path": "/Users/me/code/site-worktree" }
// 200 -> bridge-path object (is_validated resets to false on set)
```

`POST /api/v1/projects/{projectId}/bridge-paths/{bridgeId}/validate` → validate

```jsonc
// request: {} (no body)
// 200 -> bridge-path object with is_validated + validation_error updated
// 409 -> { "error": { "code": "bridge_offline", "message": "bridge is offline" } }
```

`DELETE /api/v1/projects/{projectId}/bridge-paths/{bridgeId}` → remove override

```jsonc
// 200 -> { "deleted": true }
```

### Bridges (for the per-bridge editor + launch)

`GET /api/v1/bridges` (existing `useListBridgesQuery`) → each row has
`bridge_id`, `label`, `machine_hostname`, `status` (`online`/`offline`/…),
`capabilities` (`[{ provider, default_tier, tiers? }]`).

### Sidebar live status (needs bridge_id + runtime_status)

For the per-agent/session live dot the sidebar rows must carry the live
instance's bridge + runtime status. Two options, pick per Task 7:

- Preferred: enrich `GET /api/v1/chats` rows (and `SidebarConversation`) with
  `bridge_id` and `runtime_status` for the bound instance. The Hub already
  stores both on the instance; join them into the conversation list projection.
- Alternative: the shell also loads `GET /api/v1/agent-instances` (or
  `useListAgentsQuery` running=true) and maps `agent_instance_id →
  { bridge_id, runtime_status }` client-side, merging into the tree builder.

`GET /api/v1/agent-instances` rows include: `agent_instance_id`, `agent_id`,
`bridge_id`, `runtime_status` (`launching|starting|running|idle|busy|stopping|
stopped|unreachable|failed`), `startup_status`, `activity_status`, `project_id`,
`conversation_id`.

### Ordering & pagination (agents / instances / conversations)

Required behavior for any list the sidebar/settings render:

- **Most recently created first** by default. Agents and instances currently
  sort `ORDER BY updated_at DESC` (`agent_list_by_owner_sqlite`,
  `agent_list_instances_by_owner_sqlite`). Change the primary sort to
  `created_at DESC` (tie-break `agent_id`/`agent_instance_id`) so newly created
  entities are at the top regardless of later status churn.
- **Pagination** via the standard envelope `page { limit, next_cursor,
  has_more }` (`contracts/envelope.odin`, `respond_list`). Cursor is the last
  row's `created_at` (keyset), matching the conversation/message pattern
  (`content_list_conversations_sqlite` uses `created_at`/`updated_at < cursor`).
- Endpoints to support `?limit=&cursor=`:
  - `GET /api/v1/agents`
  - `GET /api/v1/agent-instances`
  - `GET /api/v1/projects`
  - `GET /api/v1/chats` (already limited; add cursor pagination if missing)
- Handlers currently hardcode `API_Page{limit = API_DEFAULT_PAGE_LIMIT,
  has_more=false}`; replace with real `limit` (clamped) + `next_cursor` +
  `has_more` computed from `len(rows) >= limit`.

### Instance launch (already wired; project is passed through)

`POST /api/v1/agent-instances`

```jsonc
// request
{
  "agent_id": "agt_x",
  "bridge_id": "br_home_mac",
  "provider": "pi",
  "tier": "normal",
  "project_id": "proj_ab12"   // optional; empty => no project (default run dir)
}
// 201 -> agent instance; includes "project_id" and resolved "project_path"
```

The Hub resolves `project_path` = per-bridge override, else project
`default_path`. The bridge uses `project_path` as the tmux `run_dir`.

---

## Live Dot Logic (is the agent running?)

Single source of truth for "running" is the agent **instance** `runtime_status`
(from `GET /api/v1/agent-instances` / enriched sidebar rows), NOT chat activity.

### Status → dot state mapping

```
runtime_status              dot state        fill      animation   meaning
--------------------------  ---------------  --------  ----------  ---------------------
running | idle | busy       LIVE             solid     pulse       instance up & usable
launching | starting        STARTING         solid◐    pulse       coming up
stopping                    STOPPING         solid     none        tearing down
stopped                     OFF              hollow ○  none        cleanly stopped
unreachable                 STALE            hollow ⊘  none        bridge lost contact
failed                      ERROR            solid ✕   none        startup/runtime failed
(no instance for agent)     NONE             hollow ○  none        never launched / all gone
```

Helper (frontend, centralize in `AppShell.tsx` or a small util):

```ts
type LiveState = 'live' | 'starting' | 'stopping' | 'off' | 'stale' | 'error' | 'none';

function liveStateFromRuntime(runtimeStatus?: string): LiveState {
  switch (String(runtimeStatus || '').toLowerCase()) {
    case 'running': case 'idle': case 'busy': return 'live';
    case 'launching': case 'starting':          return 'starting';
    case 'stopping':                            return 'stopping';
    case 'stopped':                             return 'off';
    case 'unreachable':                         return 'stale';
    case 'failed':                              return 'error';
    default:                                    return 'none';
  }
}
function isAgentRunning(runtimeStatus?: string): boolean {
  const s = liveStateFromRuntime(runtimeStatus);
  return s === 'live' || s === 'starting' || s === 'stopping';
}
```

### Rollup (agent group / project group)

- A **session dot** uses its bound instance's `runtime_status`.
- An **agent-group dot** = the "most alive" of its sessions:
  `live > starting > stopping > stale > error > off > none` (pick the highest).
- A **project group** may show a small count of live sessions in its header
  (optional), but the collapse chevron/unread stay primary.

### Freshness / liveness caveat

- `runtime_status` is a durable projection updated by bridge heartbeats. If a
  bridge dies without a clean stop, the Hub reconciler flips active instances to
  `unreachable` (see `reconcile_bridge_heartbeat`) → dot becomes STALE, not LIVE.
- Treat `unreachable`/`failed` as NOT running for any "can I message it now"
  affordance, but keep them visually distinct from a clean `stopped`.
- The sidebar query is WS-invalidated, so dots update on lifecycle events without
  manual refresh; add a modest poll (e.g. 10s) as a safety net for missed events.

### Color = bridge, shape/fill = status

- **Color** encodes `bridge_id` (which machine), via a deterministic hash into a
  fixed palette. Same bridge → same color everywhere.
- **Fill/shape/animation** encodes running vs not (table above). Never rely on
  color alone to signal "running" (accessibility) — hollow vs solid does that.
- Expose `data-bridge-color` and `data-live-state` on the dot for the debug API
  and tests.

```ts
const BRIDGE_PALETTE = ['emerald','sky','violet','amber','rose','teal','fuchsia','lime'];
function bridgeColorSlot(bridgeId: string): string {
  if (!bridgeId) return 'zinc'; // not-running / unknown bridge → grey
  let h = 0; for (const ch of bridgeId) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  return BRIDGE_PALETTE[h % BRIDGE_PALETTE.length];
}
// running dot uses the bridge color; non-running (off/stale/error/none) is grey.
```

---

## UI Mocks (ASCII)

### Settings → Projects (list + create) — Task 3

```
+----------------------------------------------------------------------+
| [Bridges] [Providers] [User tokens] [Projects*] [Memory] [Defaults]  |  settings-sub-nav
+----------------------------------------------------------------------+
|  Projects                                                            |
|                                                                      |
|  +--------------------------- Create project ----------------------+ |  settings-project-create-form
|  | Name*            [ Website rewrite____________ ]                | |  ..-name-input
|  | Description      [ Frontend migration_________ ]                | |  ..-description-input
|  | Repo URL         [ git@github.com:me/site.git_ ]                | |  ..-repo-input
|  | VCS              [ git v ]   (none | git | jj)                  | |  ..-vcs-select
|  | Default path*    [ /Users/me/code/site________ ]               | |  ..-default-path-input
|  |                                        [ Create project ]      | |  ..-create-btn
|  | ! default_path is required                                     | |  ..-create-error (on 400)
|  +----------------------------------------------------------------+ |
|                                                                      |
|  Your projects                                                       |
|  +----------------------------------------------------------------+ |  settings-project-row-${id}
|  | Website rewrite                                    [ Open > ]  | |  ..-open-btn-${id}
|  | /Users/me/code/site  ·  git  ·  updated 2m ago                 | |
|  +----------------------------------------------------------------+ |
|  | Docs site                                          [ Open > ]  | |
|  | /Users/me/code/docs  ·  none · updated 1d ago                  | |
|  +----------------------------------------------------------------+ |
+----------------------------------------------------------------------+
```

### Settings → Project detail (edit + per-bridge paths) — Task 3 + 4

```
+----------------------------------------------------------------------+
|  < Projects / Website rewrite                                        |  breadcrumb
+----------------------------------------------------------------------+
|  Project                                          [ Edit ] [ Save ]  |  ..-edit/save-btn-${id}
|  Name          [ Website rewrite____________ ]                       |
|  Description   [ Frontend migration_________ ]                       |
|  Repo URL      [ git@github.com:me/site.git_ ]                       |
|  VCS           [ git v ]                                             |
|  Default path  [ /Users/me/code/site________ ]                      |
|                                                                      |
|  Bridge paths                                                        |
|  +----------------------------------------------------------------+ |  ..-bridge-path-row-${bridgeId}
|  | home-mac (online)                                              | |
|  | Path [ /Users/me/code/site-worktree_____ ]                     | |  ..-bridge-path-input-${bridgeId}
|  | Status: ✓ validated 20:15   (effective: override)             | |  ..-bridge-path-status-${bridgeId}
|  |            [ Save ]  [ Validate ]  [ Remove ]                  | |  ..-save/validate/remove-btn-${bridgeId}
|  +----------------------------------------------------------------+ |
|  | cloudtop (offline)                                             | |
|  | Path [ (uses default: /Users/me/code/site) ]                  | |
|  | Status: — not set    Validate disabled (bridge offline)       | |
|  |            [ Save ]  [ Validate (disabled) ]                   | |
|  +----------------------------------------------------------------+ |
+----------------------------------------------------------------------+
```

### Instance launch — project select + effective-path hint — Task 5

```
+------------------------- New conversation --------------------------+
|  Agent     [ backend-dev            v ]                             |
|  Project   [ Website rewrite        v ]   new-convo-project-select  |
|  Bridge    [ home-mac (online)      v ]                             |
|  Provider  [ pi   v ]   Tier [ normal v ]                          |
|                                                                     |
|  Runs in: /Users/me/code/site-worktree  ✓ validated                |  new-convo-project-path-hint
|   (or)    /Users/me/code/site  ⚠ path not validated on this bridge |
|                                                                     |
|  [ Message__________________________________________ ]  [ Send ]   |
+---------------------------------------------------------------------+
```

Notes:
- The hint appears only when a non-default project AND a bridge are selected.
- Warning is non-blocking; launch still allowed (Hub falls back to
  `default_path`).

### Sidebar — collapsible project groups — Task 6

Collapsed vs expanded (chevron toggles the body):

```
 PROJECTS
 +--------------------------------------------+   sidebar-project-group-${id}
 | ▾ Website rewrite                    (3)   |   ▾ = expanded; toggle = ..-toggle-btn-${id}
 |   ● backend-dev                  [+] (2)   |     ● = live dot (bridge color)
 |     ● fix login bug                  (1)   |     sidebar-session-row-${convId}
 |     ○ add tests                            |     ○ = not running (hollow/grey)
 |   ○ reviewer                     [+]       |
 +--------------------------------------------+
 | ▸ Docs site                          (5)   |   ▸ = collapsed; body hidden
 +--------------------------------------------+   (unread badge still visible)
 | ▸ Conversations (default)                  |
 +--------------------------------------------+
```

- Header row becomes a button (`sidebar-project-toggle-btn-${id}`) wrapping the
  chevron + name; unread badge stays outside/!collapsible.
- Body container `sidebar-project-body-${id}` is shown/hidden.
- Collapsed state persisted per `projectId` in `localStorage`.

### Sidebar — live status dot, colored per bridge — Task 7

```
 PROJECTS                                   Bridges:  ● home-mac  ● cloudtop  ● office-pc
 +--------------------------------------------+       (legend: sidebar-bridge-legend)
 | ▾ Website rewrite                    (3)   |
 |   ● backend-dev                  [+] (2)   |   ● green  = running on home-mac
 |     ● fix login bug                  (1)   |   ● green  = same bridge as its agent
 |   ● reviewer                     [+]       |   ● blue   = running on cloudtop
 |   ○ scratch-runner               [+]       |   ○ grey   = stopped / no live instance
 +--------------------------------------------+

 dot states:
   ● solid  + pulse   -> running/busy   (runtime_status in running/idle/busy)
   ◐ solid  + pulse   -> starting/launching
   ○ hollow grey      -> stopped/unreachable/none
   color               -> stable hash of bridge_id -> palette slot
```

- Each agent row (`sidebar-agent-status-dot-${agentId}`) and session row
  (`sidebar-session-status-dot-${convId}`) gets a leading dot.
- Dot **fill/animation** encodes runtime status; dot **color** encodes the
  bridge the live instance runs on (`bridge_id`).
- Color is a deterministic hash of `bridge_id` into a fixed palette (so the same
  bridge is always the same color across sessions/reloads); grey is reserved for
  "not running".
- Tooltip on the dot: `"<agent> · running on <bridge label>"`; hollow →
  `"not running"`.
- Optional compact legend at the top of the tree (`sidebar-bridge-legend`)
  mapping each active bridge color → label.

---

## Tasks

### Task 1 — Hub: expose project detail read for bridge paths (backend)

The UI needs to read a project's `bridge_paths`. `GET /api/v1/projects/{id}`
already returns them via `write_project_detail_json`. Confirm and, if missing,
add a dedicated list route for bridge paths.

- Verify `GET /api/v1/projects/{id}` returns `bridge_paths[]` with
  `bridge_id`, `path`, `is_validated`, `last_validated_at`, `validation_error`.
- (Optional, only if the detail payload proves awkward) add
  `GET /api/v1/projects/{id}/bridge-paths` → `project_service.list_bridge_paths`.
- Ensure `create_project` error message for missing `default_path` is
  user-friendly (already `"default_path is required"`).

Validation: `odin build src/hub`, curl the route with a user token.

Files:
- `src/hub/transport/http/project_handlers.odin`
- `src/hub/app/wiring.odin` (only if adding the optional route)

### Task 2 — UI API: rewrite-native project endpoints (frontend)

Replace the legacy `/user-rpc` project helpers with cookie-authenticated
`/api/v1/projects` calls and expose RTK Query hooks.

- In `src/ui/api/endpoints/projects.ts`, reimplement using
  `cookieJsonFetch` / `cookieMutation` (like `sidebar.ts` / bridges):
  - `listProjects` → `GET /projects`
  - `fetchProject` → `GET /projects/{id}` (returns `bridge_paths`)
  - `createProject` → `POST /projects` with
    `{ name, description, repo_url, vcs_kind, default_path }`
  - `updateProject` → `PATCH /projects/{id}`
  - `setProjectBridgePath` → `PUT /projects/{id}/bridge-paths/{bridgeId}`
  - `deleteProjectBridgePath` → `DELETE /projects/{id}/bridge-paths/{bridgeId}`
  - `validateProjectBridgePath` → `POST /projects/{id}/bridge-paths/{bridgeId}/validate`
- Tag with `Projects` / `Project` and invalidate on mutations, plus invalidate
  `SidebarProjects` so the sidebar refreshes.
- Keep normalization tolerant of snake/camel case (`project_id`/`projectId`).

Validation: `npm run typecheck`.

Files:
- `src/ui/api/endpoints/projects.ts`
- `src/ui/api/heimdallApi.ts` (ensure `Projects`/`Project` tag types exist)

### Task 3 — UI: Projects settings surface with create + list + detail

Replace the minimal `ProjectsSettingsPanel` with a real surface. Prefer a
dedicated component `src/ui/components/settings/ProjectsPanel.tsx` and route it
from `AppShell` (mirroring `ProvidersPanel`/`BridgesPanel`).

Create form (must satisfy Hub validation):
- Inputs: `name` (required), `description`, `repo_url`, `vcs_kind`
  (select: none/git/jj), `default_path` (required).
- On submit → `createProject`, then clear + refetch.

List:
- Rows show name, `default_path`, repo/vcs, updated time.
- Row click → open detail (route `/settings/projects/{projectId}` or inline
  expand).

Detail:
- Show project fields + inline edit (name/description/repo/vcs/default_path)
  via `updateProject`.
- Bridge paths section (Task 4).

Debug IDs (register in `AGENTS.md`):
- `settings-projects-panel`, `settings-project-create-form`,
  `settings-project-name-input`, `settings-project-description-input`,
  `settings-project-repo-input`, `settings-project-vcs-select`,
  `settings-project-default-path-input`, `settings-project-create-btn`,
  `settings-project-create-error`, `settings-project-row-${projectId}`,
  `settings-project-open-btn-${projectId}`,
  `settings-project-edit-btn-${projectId}`,
  `settings-project-save-btn-${projectId}`.

Validation: `npm run typecheck`; click-through via Electron debug API.

Files:
- `src/ui/components/settings/ProjectsPanel.tsx` (new)
- `src/ui/components/shell/AppShell.tsx` (route `/settings/projects` → new panel;
  optional `/settings/projects/{id}` detail route)
- `AGENTS.md` (registry)

### Task 4 — UI: per-bridge project paths editor

Inside project detail, manage `Project_Bridge_Path` per bridge.

- Load bridges from `useListBridgesQuery`; load current paths from
  `fetchProject().bridge_paths`.
- For each owned bridge, show:
  - current path (editable input, prefilled with override or empty),
  - validation state (`is_validated`, `last_validated_at`, `validation_error`),
  - actions: Save (`setProjectBridgePath`), Validate
    (`validateProjectBridgePath`), Remove (`deleteProjectBridgePath`).
- Validation requires the bridge to be Online; when offline, disable Validate
  and show a hint (Hub returns `Bridge_Offline`).
- Effective-path hint: if no override, show the project `default_path` as the
  effective path.

Debug IDs:
- `settings-project-bridge-path-row-${bridgeId}`,
  `settings-project-bridge-path-input-${bridgeId}`,
  `settings-project-bridge-path-save-btn-${bridgeId}`,
  `settings-project-bridge-path-validate-btn-${bridgeId}`,
  `settings-project-bridge-path-remove-btn-${bridgeId}`,
  `settings-project-bridge-path-status-${bridgeId}`.

Validation: `npm run typecheck`; validate a real path against the local bridge.

Files:
- `src/ui/components/settings/ProjectsPanel.tsx`
- `AGENTS.md` (registry)

### Task 5 — UI: project selection at instance launch shows path + validity

The launch composer already selects a project. Enhance it so the user sees where
the instance will run on the chosen bridge.

- When both a project (non-default) and a bridge are selected, fetch the
  project's `bridge_paths` (reuse `fetchProject`) and show the effective path
  for that bridge, plus validation status.
- If the path is unvalidated/offline, show a non-blocking warning ("path not
  validated on this bridge") but still allow launch (backend falls back to
  `default_path`).
- Keep passing `project_id` into the existing bind/launch call (already wired).

Also audit the other instance-launch entry points and give them the same project
select + effective-path hint where a bridge is chosen:
- `ConversationLaunchComposer` (`new-convo-*`)
- Sidebar agent launch (`sidebar-agent-launch-*`)
- Agent detail launch (`agent-detail-launch-*`)

Debug IDs:
- `new-convo-project-path-hint`, `sidebar-agent-launch-project-path-hint`,
  `agent-detail-launch-project-path-hint` (only where a bridge is selectable).

Validation: `npm run typecheck`; launch an instance into a real project path and
confirm the tmux `run_dir` matches (`ps`/bridge log `project_path`).

Files:
- `src/ui/components/chat/ConversationLaunchComposer.tsx`
- `src/ui/components/shell/AppShell.tsx` (sidebar launch), and/or
  `src/ui/components/agents/AgentDetailPanel.tsx`
- `AGENTS.md` (registry)

### Task 6 — UI: collapsible sidebar project groups

Make each project group in the sidebar collapsible. Today
`ProjectConversationTree` in `src/ui/components/shell/AppShell.tsx` always
renders every project's agent/session tree expanded.

- Convert the project group header row into a `<button>` toggle that
  collapses/expands that project's body (agents + sessions).
- Add a rotating chevron (▸ collapsed / ▾ expanded) before the project name;
  keep the existing unread badge visible even when collapsed (so unread counts
  are not hidden).
- Persist collapsed state per project in `localStorage` (keyed by
  `projectId`), so it survives reloads. Default: expanded.
  - Reuse the existing local-storage helper style in `chatSlice.ts`
    (`getStoredValue`/`setStoredValue`) or a small local `useState` + effect.
- Keep the default/synthetic "Conversations" project group behaving the same
  (it is just another collapsible group).
- Accessibility: `aria-expanded` on the toggle, `aria-controls` pointing at the
  group body id.

Debug IDs (register in `AGENTS.md`):
- `sidebar-project-toggle-btn-${projectId}` (the header toggle button)
- `sidebar-project-body-${projectId}` (the collapsible body container)
- `sidebar-project-chevron-${projectId}` (optional, on the chevron span)

Keep existing IDs intact: `sidebar-project-group-${projectId}`,
`sidebar-project-unread-${projectId}`, `sidebar-project-empty-${projectId}`.

Validation: `npm run typecheck`; via Electron debug API click
`sidebar-project-toggle-btn-*` and assert `sidebar-project-body-*`
appears/disappears; reload and confirm collapsed state persists.

Files:
- `src/ui/components/shell/AppShell.tsx`
- `AGENTS.md` (registry: add the three IDs above to the `Sidebar` row)

### Task 7 — UI: live status dot colored per bridge in the sidebar

Render a live indicator dot next to each agent/session, encoding runtime status
by fill/animation and the running bridge by color.

Data:
- Ensure the sidebar has per-row `bridge_id` + `runtime_status` (see "Sidebar
  live status" in API Contracts). Prefer enriching `SidebarConversation`
  (`sidebar.ts`) with `bridgeId` + `runtimeStatus`; otherwise merge from a
  running-instances query in the tree builder (`buildProjectConversationTree`).
- Roll agent-group status up from its sessions (running if any session running).

Rendering:
- Add a small `<StatusDot bridgeId runtimeStatus />` component:
  - fill/animation: running/idle/busy → solid + subtle `animate-pulse`;
    launching/starting → half/solid + pulse; stopped/unreachable/failed/none →
    hollow grey.
  - color: `bridgeColor(bridge_id)` = deterministic hash → fixed Tailwind
    palette slot (e.g. emerald/sky/violet/amber/rose/teal); grey reserved for
    not-running. Keep the mapping stable and centralized so the same bridge is
    always the same color.
- Place the dot leading each agent row and session row; keep existing unread
  badges and the new-conversation `+` button.
- Tooltip: `"<agent/session> · running on <bridge label>"` or `"not running"`.
- Optional legend row at the top of `ProjectConversationTree`
  (`sidebar-bridge-legend`) listing active bridges with their colors + labels;
  derive labels from `useListBridgesQuery`.

Debug IDs (register in `AGENTS.md`, `Sidebar` row):
- `sidebar-agent-status-dot-${agentId}`
- `sidebar-session-status-dot-${conversationId}`
- `sidebar-bridge-legend` (+ `sidebar-bridge-legend-item-${bridgeId}` if listed)

Accessibility: dot has `title` + `aria-label`; do not rely on color alone —
status is also conveyed by fill/shape (solid vs hollow) and the tooltip.

Validation: `npm run typecheck`; via Electron debug API assert the dot exists
and that two instances on different bridges get different `data-bridge-color`
values; launch/stop an instance and confirm the dot updates live (WS
invalidation refreshes the sidebar query).

Files:
- `src/ui/api/endpoints/sidebar.ts` (add `bridgeId` + `runtimeStatus`; or add a
  running-instances query)
- `src/ui/components/shell/AppShell.tsx` (`StatusDot`, `bridgeColor`, tree
  wiring, legend)
- `AGENTS.md` (registry)

### Task 8 — Hub: created-first ordering + cursor pagination for lists

Back the sidebar/settings lists with deterministic ordering and pagination.

- Ordering: change primary sort to `created_at DESC` (tie-break on id) for:
  - `agent_list_by_owner_sqlite` (agents)
  - `agent_list_instances_by_owner_sqlite` (instances)
  - `project_list_by_owner` (projects)
  Keep an `updated_at` secondary sort only as a tie-break if needed.
- Pagination: add `limit` + keyset `cursor` (last row `created_at`) to the
  repo list procs and thread through the service + handlers. Emit real
  `API_Page{ limit, next_cursor, has_more }` instead of the hardcoded page.
  - `list_agents_handler`, `list_agent_instances_handler`,
    `list_projects_handler`, and `list_chats` (if not already).
  - Parse `?limit=&cursor=` with `query_int`/`query_value`; clamp limit to a
    sane max (e.g. ≤ 200), default `API_DEFAULT_PAGE_LIMIT`.
- Frontend: update RTK Query endpoints to pass `limit`/`cursor`, and make the
  sidebar/settings "Show more" use `next_cursor` (mirror the existing
  `sidebar-conversations-show-more-btn` / `sidebar-agents-show-more-btn`
  paging affordances noted in `AGENTS.md`).

Validation: `odin build src/hub`; curl `GET /api/v1/agents?limit=2` twice with
the returned `next_cursor` and confirm newest-first, non-overlapping pages;
`npm run typecheck`.

Files:
- `src/hub/repository/sqlite/agent_repo_sqlite.odin`
- `src/hub/repository/iface/agent_repo.odin` (proc signatures if adding
  limit/cursor)
- `src/hub/repository/sqlite/project_repo_sqlite.odin`,
  `src/hub/repository/iface/project_repo.odin`
- `src/hub/service/agent/agent_service.odin`,
  `src/hub/service/project/project_service.odin`
- `src/hub/transport/http/agent_handlers.odin`,
  `src/hub/transport/http/project_handlers.odin`
- `src/ui/api/endpoints/agents.ts`, `projects.ts`, `sidebar.ts`

### Task 9 — End-to-end verification + docs

- Manual E2E on `hub.mundus.in` + local macbook bridge:
  1. Create a project with `default_path` = a real repo dir.
  2. Set the macbook bridge path (or rely on default), Validate → `is_validated`.
  3. Launch an instance with that project selected on the macbook bridge.
  4. Confirm the wrapper/tmux cwd is the project path (bridge log `project_path`,
     `ps` on the wrapper, or `pwd` inside the agent).
  5. Collapse/expand the project in the sidebar; reload; confirm persistence.
  6. Confirm the live dot turns colored while running and grey when stopped, and
     that instances on two different bridges show two distinct colors.
  7. Create several agents; confirm the newest appears first and "Show more"
     pages through without duplicates/gaps.
- Update this doc's status and note any follow-ups.

Validation: `npm run typecheck`, `odin build src/hub`, live launch check.

---

## Sequencing

1. Task 1 (confirm backend read) — small, unblocks UI.
2. Task 2 (UI API layer) — foundational for 3–5.
3. Task 3 (Projects settings create/list/detail).
4. Task 4 (per-bridge paths editor).
5. Task 5 (launch-time project path surfacing).
6. Task 6 (collapsible sidebar project groups) — independent of 1–5.
7. Task 7 (live status dot per bridge) — depends on Task 8's instance data
   (bridge_id + runtime_status on sidebar rows).
8. Task 8 (created-first ordering + pagination) — backend; unblocks Task 7 data
   and improves all lists; can run in parallel with 3–6.
9. Task 9 (E2E + docs).

## Risks / Notes

- **Do not** reintroduce `/user-rpc` project actions; the rewrite Hub is
  REST-first under `/api/v1`.
- `default_path` is mandatory at creation — the current create form omitting it
  is the concrete bug to fix first.
- Validation depends on a **live, Online** bridge with the WS validation adapter;
  offline bridges must degrade gracefully in the UI.
- Instance `project_id`, `bridge_id`, `project_path` are immutable per instance;
  changing project means launching a new instance (already enforced by
  `Reconfigure_Instance_Input`).
- Live-dot truth is instance `runtime_status`, not chat activity. `unreachable`
  and `failed` must render as NOT running (distinct from clean `stopped`).
- Ordering must be **created-first**; today several lists sort `updated_at DESC`,
  which reshuffles rows on status churn — switch primary sort to `created_at`.
- Keyset pagination uses `created_at` as the cursor; ensure `created_at` is
  monotonic/unique enough (tie-break by id) to avoid skipped/duplicated rows.
- Every new interactive element needs a `data-debug-id` and an `AGENTS.md`
  registry entry.
