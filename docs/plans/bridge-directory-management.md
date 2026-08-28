# Bridge directory management — plan

**Status:** Phases 1–4 done (Phase 5 polish remaining)

### Confirmed decisions (2026-08-28)
1. Root default: **`$HOME` only** for v1 (single `fs_root`); allowlist later.
2. Listings: **return both dirs and files** (files flagged `is_dir:false`); UI shows
   dirs-only by default with a toggle.
3. **Add a separate read-only `fs_stat`** (do not overload `validate_project_path`).
4. mkdir: default umask, no mode control in v1.
5. Resolve the root's real (symlink-resolved) path once at startup; contain against it.
6. Multi-bridge "is path present" fan-out: **client-side N stat calls** for v1.

**Goal:** Add bridge endpoints for filesystem directory management on the machine
running a bridge, so the UI can offer a **bridge-aware directory picker** (browse +
create) for selecting per-bridge project paths, and highlight bridges where a
selected project path is missing (with an option to create it).

---

## 1. What exists today (grounding)

The plumbing for "ask a specific bridge about the filesystem" already exists — this
feature extends it rather than inventing a new channel.

- **Hub → Bridge command round-trip** (WebSocket, request/reply by `command_id`):
  - Hub: `project_service.validate_bridge_path` builds a typed command, sends it via
    `Bridge_Command_Sink.send_runtime_command_wait(command, timeout)` and blocks for
    the reply.
  - Bridge: `bridge_hub_handle_command` (in `hub_runtime_client.odin`) dispatches on
    `type`; `main.odin` already handles `validate_project_path` over the WS
    (`bridge_validate_project_path_ws_result_json`).
  - Reply correlation is **generic**: any WS frame from the bridge carrying a
    `command_id` is routed by `bridge_handlers.odin` →
    `runtime_command_result_idempotent(bridge_id, command_id, text)`, which unblocks
    the waiting `send_runtime_command_wait`. The result `type` is whitelisted in a
    `case "command_result", "project_path_validation_result", "providers_report":`
    switch — **we add our new result types there.**
- **Existing FS check**: `src/bridge/project_path_validation.odin`
  (`bridge_validate_project_path_local`) does `os.exists` / `os.is_dir` / git-root
  detection. Reused/extended for stat.
- **Home expansion**: `bridge_expand_home("~/...")` exists in `provider_store.odin`.
- **No "trusted root" concept exists yet** — we add one (default: `$HOME`).
- **UI today**: `ProjectsSurface` (bridge paths panel) + `settings/ProjectsPanel`
  already call `validateProjectBridgePath` and `setProjectBridgePath`. The picker
  slots in next to those.

Key architectural facts that shape the design:
- Agents run in their own managed run dir, **not** the project path — so project
  paths are purely a user-configured hint per bridge. Directory management is a
  **user-facing convenience**, not part of agent runtime.
- The bridge is already a per-user, per-machine trusted process (it holds the
  bridge token and launches local agents). Exposing scoped FS browse/create to its
  owner is consistent with its existing trust level, but MUST be sandboxed.

---

## 2. Security model (do this first, it gates everything)

Filesystem browse/create is dangerous. Constraints:

- **Trusted root (sandbox).** New bridge config `[bridge].fs_root` (default: `$HOME`).
  All FS operations are confined to this root. Support a small allowlist
  (`fs_roots = ["~", "/work"]`) later; start with a single root defaulting to home.
- **Path canonicalization + containment.** Every requested path is:
  1. `~`-expanded, then resolved to an absolute, symlink-resolved real path;
  2. rejected unless it is the root or a descendant of a configured root
     (defense against `..`, symlink escapes, absolute paths outside root).
  Reject with `error.code = "path_outside_root"`.
- **Auth.** These commands arrive over the **bridge WS from the hub**, which is
  already bridge-token authenticated; the hub only issues them for the bridge's
  **owner user** (same ownership check as `validate_bridge_path`). No new auth
  surface on the bridge's loopback endpoint is exposed to agents.
- **No file contents, no deletes, no rename (v1).** Only: list dir, stat path,
  make dir. Deleting/moving is explicitly out of scope for v1 (least privilege).
- **Bounded results.** Cap entries per listing (e.g. 1000) and path length; never
  follow into another mount if it escapes root.
- **Hidden entries.** Return them but flag `hidden: true` (leading `.`), so the UI
  can default to hiding them.

---

## 3. New bridge capabilities (WS command types)

Add three Hub→Bridge command types, mirroring `validate_project_path`:

### 3.1 `fs_list_dir`
List a directory's immediate children (dirs first; files optional/flagged).
- Request: `{ type, command_id, bridge_id, path }` (path defaults to the fs_root
  when empty → this is how the picker "opens at home").
- Reply `type: "fs_list_dir_result"`:
  ```json
  { "type":"fs_list_dir_result", "command_id":"...", "ok":true,
    "path":"/Users/x/work",            // canonical absolute path actually listed
    "root":"/Users/x",                  // the sandbox root (for UI breadcrumb bounds)
    "parent":"/Users/x",                // parent within root, or "" if path==root
    "entries":[
      {"name":"heimdall","is_dir":true,"hidden":false,"has_git":true},
      {"name":"notes.md","is_dir":false,"hidden":false}
    ],
    "truncated":false,
    "error":{"code":"","message":""} }
  ```
- `has_git` reuses `bridge_path_has_git_root` (cheap: check `<entry>/.git`) so the
  picker can badge repo dirs. (Optional; can defer.)

### 3.2 `fs_stat`
Check whether a specific path exists / is a dir (this is what "highlight bridges
where the selected project path is not present" uses — one stat per bridge).
- Request: `{ type, command_id, bridge_id, path, vcs_kind }`.
- Reply `type: "fs_stat_result"`:
  ```json
  { "type":"fs_stat_result", "command_id":"...", "ok":true,
    "path":"/Users/x/proj", "exists":true, "is_dir":true, "has_git":true,
    "within_root":true, "error":{"code":"","message":""} }
  ```
- Note: `validate_project_path` already does most of this; `fs_stat` is the
  lighter-weight, VCS-agnostic version the picker uses for the "present on which
  bridges?" grid. We can either add `fs_stat` or extend the existing validate
  result — **decision: add `fs_stat`** to keep validate's semantics (which also
  persists a `Project_Bridge_Path` row) separate from a read-only probe.

### 3.3 `fs_make_dir`
Create a directory (with parents, like `mkdir -p`) inside the root.
- Request: `{ type, command_id, bridge_id, path }`.
- Reply `type: "fs_make_dir_result"`:
  ```json
  { "type":"fs_make_dir_result", "command_id":"...", "ok":true,
    "path":"/Users/x/newproj", "created":true, "within_root":true,
    "error":{"code":"","message":""} }
  ```
- `created:false, ok:true` if it already existed and is a dir (idempotent).
- Errors: `path_outside_root`, `mkdir_failed`, `path_exists_not_dir`.

All three are cached-by-`command_id` (idempotent replay) exactly like the existing
validate handler's `bridge_validation_command_cached/store`.

---

## 4. Hub HTTP endpoints (what the UI calls)

The hub proxies these to the target bridge via `send_runtime_command_wait`, applying
the **owner + online** checks already used by `validate_bridge_path`.

| Method + path | Purpose | Body / query |
|---|---|---|
| `GET /api/v1/bridges/{bridge_id}/fs?path=<p>` | list a directory | `path` optional (defaults to root) |
| `GET /api/v1/bridges/{bridge_id}/fs/stat?path=<p>` | stat a path | `path` required |
| `POST /api/v1/bridges/{bridge_id}/fs/mkdir` | create a directory | `{ "path": "<p>" }` |

- Reuse `require_auth` + bridge ownership + `.Online` status checks (copy the guards
  from `project_service.validate_bridge_path`).
- Bridge-offline / revoked → the same `Bridge_Offline` / `Bridge_Revoked` errors the
  path-validation flow already returns, so the UI can show "can't browse: bridge
  offline."
- Timeout: reuse the runtime-command timeout (a few seconds). FS ops are fast.
- **No hub-side persistence.** These are live pass-throughs (unlike
  `validate_bridge_path`, which persists a `Project_Bridge_Path` row). Setting a
  project's per-bridge path still goes through the existing
  `PUT /projects/{id}/bridge-paths/{bridge_id}` (`setProjectBridgePath`).

Contracts: add `ROUTE_*` constants and command/result type strings to
`src/contracts/bridge.odin` (contracts-first).

---

## 5. UI: bridge-aware directory picker

New shared component `BridgeDirectoryPicker` (`components/BridgeDirectoryPicker.tsx`):

- Props: `bridgeId`, `initialPath?`, `onPick(path)`, `debugId`.
- Behavior:
  - On open, `GET /bridges/{id}/fs` (root) → show breadcrumb (bounded to `root`),
    directory list (dirs first, git-badged), and a path input.
  - Clicking a dir navigates (`GET …/fs?path=…`); breadcrumb navigates up (never
    above `root`).
  - **Create**: an inline "New folder" affordance → `POST …/fs/mkdir` → refresh +
    select. Also: if the user types a path that doesn't exist, offer "Create this
    directory" (mkdir then pick).
  - Hidden entries toggle (default hidden).
  - Loading / offline / permission-error states (bridge offline → clear message).
- Debug-ids: `${debugId}`, `${debugId}-breadcrumb`, `${debugId}-crumb-${i}`,
  `${debugId}-entry-${name}`, `${debugId}-path-input`, `${debugId}-new-folder-btn`,
  `${debugId}-new-folder-input`, `${debugId}-new-folder-create-btn`,
  `${debugId}-create-typed-btn`, `${debugId}-pick-btn`, `${debugId}-hidden-toggle`,
  `${debugId}-loading`, `${debugId}-error`, `${debugId}-offline`. Register in AGENTS.md.

Wire it into the two existing bridge-path surfaces:
- **`ProjectsSurface` bridge-paths panel** and **`settings/ProjectsPanel`**: replace
  the raw path text input with "type a path OR pick via `BridgeDirectoryPicker`".
- **"Highlight bridges where the path is missing"**: in the project's bridge-path
  list, for each online bridge fan out `GET …/fs/stat?path=<effective>` and show a
  red "not present — create?" affordance that calls mkdir then re-stats.

RTK Query endpoints (in `api/endpoints/bridgeSupport.ts` or a new `bridgeFs.ts`):
`listBridgeDir`, `statBridgePath`, `mkdirBridgePath` (cookie-auth mutations/queries).

---

## 6. Config

`[bridge]` section in `config.toml` / `Bridge_Config`:
- `fs_root` (string, default `~` → `$HOME`). Single root for v1.
- (Future) `fs_roots` (array) for multiple allowed roots.
- (Future) `fs_read_only` (bool) to disable `fs_make_dir`.

Parsed in `parse_bridge_key` (next to the nudge keys), stored on `Bridge_Config`,
resolved with `bridge_expand_home` at startup.

---

## 7. Implementation phases

- **Phase 1 — Bridge FS core (sandboxed). `[x] done`** `src/bridge/fs_management.odin`:
  `bridge_fs_init` (resolve root, default $HOME, symlink-resolved), containment via
  `bridge_fs_resolve_within` (~-expand, relative-to-root, resolves deepest existing
  ancestor to defeat symlink escapes, then contains), and `bridge_fs_list_dir` /
  `bridge_fs_stat` / `bridge_fs_make_dir` (dirs+files, git-badged, hidden-flagged,
  2000-entry cap, idempotent mkdir). Config `[bridge].fs_root` parsed + wired into
  bridge startup. Test `tests/bridge_fs_management_test.odin` covers containment
  (absolute-outside, `..`, `root/../outside` all rejected) + list/stat/mkdir happy
  paths. `odin check src/bridge` clean; test PASS; no regressions.
- **Phase 2 — WS command handlers.** Add `fs_list_dir` / `fs_stat` / `fs_make_dir`
  dispatch in `bridge_hub_handle_command`, with `command_id` caching. Add result
  types to the hub's result-type whitelist in `bridge_handlers.odin`.
- **Phase 3 — Hub HTTP endpoints.** `bridge_handlers.odin` handlers +
  `wiring.odin` routes; owner/online guards; pass-through via
  `send_runtime_command_wait`. Contracts constants.
- **Phase 4 — UI. `[x] done`** RTK endpoints (`api/endpoints/bridgeFs.ts`:
  listBridgeDir / statBridgePath / mkdirBridgePath). `BridgeDirectoryPicker`
  (browse + breadcrumb + new-folder + typed-path create + hidden toggle). Reworked
  the project **Working directory** panel to the confirmed model: a single
  **default path** (no bridge picker — edits `project.default_path`) + a per-online-
  bridge list showing the **effective** path (override or default) with a live
  **present / not present** indicator (`statBridgePath`), a **Create** action for
  missing paths (`mkdirBridgePath` → re-probe), **Override** (opens the picker →
  `setProjectBridgePath`), and **Reset to default** (`deleteProjectBridgePath`).
  Verified live: default-path save, per-bridge override, and stat/mkdir round-trips.
- **Phase 5 — Polish.** Hidden toggle, git badges, breadcrumb bounds, empty/error
  states, AGENTS.md debug-id registry, docs.

Each phase is independently shippable and testable.

---

## 8. Open questions / decisions to confirm

1. **Root default**: `$HOME` only for v1, or also allow an explicit allowlist now?
   (Proposed: `$HOME` only, allowlist later.)
2. **Files in listings**: list files too (flagged `is_dir:false`) or dirs-only?
   (Proposed: return both; UI shows dirs-only by default with a toggle — cheap and
   flexible.)
3. **`fs_stat` vs extend `validate_project_path`**: add a separate read-only
   `fs_stat` (proposed) vs overloading validate (which persists a row).
4. **mkdir permissions**: create with default umask; no explicit mode control in v1.
5. **Symlinked roots** (e.g. `$HOME` is a symlink): resolve the root itself once at
   startup and contain against the resolved real path.
6. **Multi-bridge stat fan-out**: do it client-side (N calls) or add a hub
   convenience endpoint that stats a path across all of a project's bridges in one
   call? (Proposed: client-side N calls for v1; add a batch endpoint only if it's
   slow.)

---

## 9. Non-goals (v1)
- Reading/writing file contents.
- Delete / rename / move.
- Arbitrary shell / glob.
- Browsing outside the configured root.
- Exposing FS management to **agents** (this is a user/UI capability via the hub;
  the bridge's agent-facing loopback endpoint is untouched).
