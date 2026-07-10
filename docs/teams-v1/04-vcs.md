# 04 · VCS backend abstraction (git + jj)

Every chain in a VCS-enabled project gets its own **VCS workspace** — an isolated filesystem tree the team's agents work in. This is what makes two teams on the same project actually parallel instead of racing on one working tree.

Two backends ship day one:

- **git** via `git worktree`
- **jj** via `jj workspace`

The rest of the system does not know the difference except at the backend boundary.

## What a workspace is

Per chain, one workspace:

- A directory outside the repo's main working tree.
- Backed by either a git branch (`team/<team_id>/<chain_slug>`) or a jj workspace (`ws_<team_id>_<chain_slug>`).
- Anchored to a `base_ref` (usually `main`).
- Where **all agent wrappers of this chain's team `cd` into** on boot — replacing today's `<agent_run_dir>/<project>/<agent-instance>` layout for VCS chains.

Non-VCS chains have no workspace. Their agents run in a plain `agent_run_dir` per today.

## Project VCS binding

A project declares its VCS through its **closed-vocabulary anchors** (see [`01-model.md`](./01-model.md), enforced by [`08-http-and-cli.md`](./08-http-and-cli.md)):

```
anchor { type: "git_repo",       value: "/Users/…/heimdall-agent-manager", note: "" }
anchor { type: "base_ref",       value: "main" }
anchor { type: "vcs_kind",       value: "git" }         // or "jj" or "none"
anchor { type: "worktree_root",  value: "~/heimdall/worktrees/hmg" }
```

Anchor semantics:

- `git_repo` is a filesystem path. Required if `vcs_kind ∈ {git, jj}`. For `jj`, the same anchor points at the jj-colocated or native repo root.
- `base_ref` defaults to `main`. Used as the branching/workspace base.
- `vcs_kind` may be `auto` at project creation; the backend runs detection (see 4.4) and rewrites it to a concrete value.
- `worktree_root` defaults to `<HEIMDALL_HOME>/worktrees/<project_slug>`. Backend is free to create this directory tree.

## Data model

New SQLite: `vcs/vcs.db`

```sql
CREATE TABLE vcs_workspaces (
  workspace_id     TEXT PRIMARY KEY,
  chain_id         TEXT NOT NULL,
  project_id       TEXT NOT NULL,
  vcs_kind         TEXT NOT NULL,             -- 'git' | 'jj'
  path             TEXT NOT NULL,             -- absolute worktree/workspace path
  branch_or_change TEXT NOT NULL,             -- git branch or jj workspace/change name
  base_ref         TEXT NOT NULL,
  status           TEXT NOT NULL,             -- 'clean' | 'dirty' | 'conflicted' | 'merged' | 'archived'
  keep_on_archive  INTEGER NOT NULL DEFAULT 0,
  created_unix_ms  INTEGER NOT NULL,
  updated_unix_ms  INTEGER NOT NULL
);
CREATE INDEX idx_vcs_workspaces_chain ON vcs_workspaces(chain_id);
CREATE INDEX idx_vcs_workspaces_project ON vcs_workspaces(project_id);
```

`task_chains` gets a nullable `vcs_workspace_id` column (see [`03-lifecycle.md`](./03-lifecycle.md) §3.6).

## The backend interface

`src/lib/vcs/vcs.odin` defines a small vtable-style interface. Implementations under `src/lib/vcs/git.odin` and `src/lib/vcs/jj.odin`.

```odin
Vcs_Kind :: enum { None, Git, Jj }

Vcs_Detect_Result :: struct {
    kind:      Vcs_Kind,
    repo_root: string,
    base_ref:  string,
    ok:        bool,
    message:   string,
}

Vcs_Workspace_Handle :: struct {
    path:             string,
    branch_or_change: string,
    base_ref:         string,
    kind:             Vcs_Kind,
}

Vcs_File_Change :: struct {
    path:    string,
    status:  string,   // "M" | "A" | "D" | "R" | "?" | "U"
    adds:    int,
    deletes: int,
}

Vcs_Status :: struct {
    ahead_commits:      int,
    behind_commits:     int,
    files:              []Vcs_File_Change,
    is_conflicted:      bool,
    summary_line:       string,   // e.g. "3 modified, 1 added, 1 untracked"
}

Vcs_Merge_Preview :: struct {
    can_fast_forward:   bool,
    conflicts:          []string,        // file paths
    commands:           []string,        // exact commands operator would run
    summary:            string,
}

Vcs_Backend :: struct {
    kind:               Vcs_Kind,
    detect:             proc(repo_path: string) -> Vcs_Detect_Result,
    workspace_add:      proc(repo: string, name: string, base_ref: string, worktree_root: string) -> (Vcs_Workspace_Handle, bool, string),
    workspace_remove:   proc(handle: Vcs_Workspace_Handle, force: bool) -> (bool, string),
    workspace_status:   proc(handle: Vcs_Workspace_Handle) -> (Vcs_Status, bool, string),
    workspace_diff:     proc(handle: Vcs_Workspace_Handle, path: string) -> (string, bool, string),
    workspace_pull_base:proc(handle: Vcs_Workspace_Handle) -> (bool, string),
    merge_preview:      proc(handle: Vcs_Workspace_Handle, target: string) -> (Vcs_Merge_Preview, bool, string),
    merge_execute:      proc(handle: Vcs_Workspace_Handle, target: string) -> (bool, string), // optional; called only after operator click
}

vcs_backend_for :: proc(kind: Vcs_Kind) -> ^Vcs_Backend
```

All methods return `(value, ok, message)`; the message is safe operator-facing text (no raw shell stderr with secrets).

### 4.1 Backend selection

```
project.vcs_kind == "git"  → git backend
project.vcs_kind == "jj"   → jj backend
project.vcs_kind == "auto" → run detect(), rewrite anchor
project.vcs_kind == "none" → no workspace ever provisioned
```

## Git backend

### 4.1.1 detect

```
git -C <repo> rev-parse --show-toplevel        → repo_root
git -C <repo> symbolic-ref --short HEAD        → base_ref (fallback: "main")
```

Returns `kind = Git` on success.

### 4.1.2 workspace_add

```
git -C <repo> fetch --quiet origin <base_ref>      # best-effort; not fatal
git -C <repo> worktree add <path> -b <branch> <base_ref>
```

where:

- `branch = team/<team_id>/<chain_slug>`
- `path   = <worktree_root>/<team_id>/<chain_slug>`

If the branch already exists (rerun after crash), fall back to `git worktree add <path> <branch>` without `-b`. Idempotent-ish.

### 4.1.3 workspace_status

```
git -C <path> status --porcelain=v1 -uall       → files
git -C <path> rev-list --left-right --count <base_ref>...HEAD  → ahead/behind
git -C <path> diff --numstat <base_ref>...HEAD  → per-file +adds -dels
```

Parse into `Vcs_Status`.

### 4.1.4 workspace_diff

```
git -C <path> diff <base_ref>...HEAD -- <file>
```

Return string. Truncate at 512 KB with `… [truncated]` sentinel.

### 4.1.5 workspace_pull_base

```
git -C <path> fetch origin <base_ref>
git -C <path> rebase origin/<base_ref>
```

If rebase halts on conflict, mark `Vcs_Status.is_conflicted = true`, do **not** try to continue automatically.

### 4.1.6 merge_preview

```
git -C <repo> fetch origin <base_ref>
git -C <repo> merge-tree --write-tree --name-only origin/<base_ref> <branch>
```

Parse `merge-tree` output; conflicts → `conflicts[]`; else `can_fast_forward = true`.

`commands[]` template:

```
git -C <repo> switch <base_ref>
git -C <repo> merge --no-ff <branch>
git -C <repo> push origin <base_ref>          # if remote configured
```

### 4.1.7 merge_execute

Runs the commands above only after operator clicks `Run` from `Needs attention`. Returns non-ok if any command fails; operator must resolve by hand.

### 4.1.8 workspace_remove

```
git -C <repo> worktree remove <path> [--force]
git -C <repo> branch -D <branch>              # only if merged or force
```

If `keep_on_archive`, skip both. Marker file `<path>/.heimdall-kept` is written so future GC sees it.

## Jj backend

`jj` is a first-class citizen. Its workspace model already matches what we want; the mapping is cleaner than git's.

### 4.2.1 detect

```
jj -R <repo> workspace root         → repo_root
jj -R <repo> log -r 'trunk()' --no-graph -T commit_id.short()   → base_ref (as a change_id)
```

If the repo has a git backend colocated (`.jj` next to `.git`), still call it `kind = Jj` — we use jj commands throughout.

### 4.2.2 workspace_add

```
jj -R <repo> workspace add --name <ws_name> <path>
jj -R <path> new <base_ref>          # create a new change on top of base
jj -R <path> describe -m "team/<team_id>/<chain_slug>"
```

`ws_name = ws_<team_id>_<chain_slug>` (jj disallows `/` in workspace names; we substitute `_`).

### 4.2.3 workspace_status

```
jj -R <path> status                  # summary
jj -R <path> diff --stat -r @-..@    # since branch base
jj -R <path> log -r 'ancestors(@, 20)' -T 'commit_id.short() ++ "\n"'
```

Compute `ahead/behind` from `jj log --template` counts against `base_ref`. `is_conflicted` from `jj status` `has_conflicts` marker.

### 4.2.4 workspace_diff

```
jj -R <path> diff -r @- --context 3 -- <file>
```

### 4.2.5 workspace_pull_base

```
jj -R <path> git fetch origin/<base_ref>      # if git-backed
jj -R <path> rebase -d <base_ref>
```

Conflicts show up as `has_conflicts` change; do not auto-resolve.

### 4.2.6 merge_preview

`jj` is happier expressing this as a rebase-and-check than a merge-tree:

```
jj -R <repo> log -r '<change_id> % <base_ref>' --template …    # divergent commits
```

Parse for changes ahead of base. Detect conflicts by simulating: `jj rebase -r <change_id> -d <base_ref> --dry-run` (available in recent jj; if unavailable, do a real rebase in a scratch clone and inspect).

`commands[]` template:

```
jj -R <repo> workspace forget <ws_name>                     # if not keeping
jj -R <repo> rebase -r <change_id> -d <base_ref>
jj -R <repo> git push --branch main                          # if colocated + remote
```

### 4.2.7 merge_execute

Same policy as git: only on operator click. jj's atomic rebase makes recovery easier.

### 4.2.8 workspace_remove

```
jj -R <repo> workspace forget <ws_name>
rm -rf <path>                                    # if not keep_on_archive
```

## Naming rules

- **Branch (git) or workspace-name (jj):** `team/<team_id>/<chain_slug>` (git) or `ws_<team_id>_<chain_slug>` (jj).
- **Chain slug:** lowercase, `[a-z0-9-]`, truncated at 40 chars, derived from `chain.title`. Fall back to `chain_id[-8:]`.
- **Path on disk:** `<worktree_root>/<team_slug>/<chain_slug>` for both backends.

## Wrapper cwd

When the wrapper boots for a team member of a chain with a workspace:

- Ignore today's `agent_run_dir` layout.
- `cwd` = the workspace `path`.
- Bootstrap file (`AGENTS.md` / `CLAUDE.md`) is written there, alongside `.heimdall-bootstrap-manifest`.
- `# Workspace` section of the bootstrap file lists `path`, `branch_or_change`, `base_ref`, `vcs_kind`, and merge policy (see [`06-bootstrap.md`](./06-bootstrap.md)).

## UI surfacing

Every VCS-backed chain view shows a **Workspace box** with:

- backend badge (`git` / `jj`)
- branch/change name
- absolute path (copyable)
- ahead/behind against base
- changed files with `M/A/D/?` flags and per-file `+adds −dels`
- `Show diff` toggle → collapsible diff panel with file picker
- Actions: `Refresh`, `Pull base`, `Preview merge`

On `completed` chains with a workspace, the merge decision surfaces in `Needs attention` with the same VCS box inlined next to the three buttons: `Merge` / `Keep worktree` / `Abandon`.

See [`07-ui.md`](./07-ui.md) for exact placement.

## HTTP endpoints

```
GET  /chains/{id}/workspace                → Vcs_Workspace_Handle + Vcs_Status
GET  /chains/{id}/workspace/diff?file=…    → text/plain diff
POST /chains/{id}/workspace/refresh        → recomputes status
POST /chains/{id}/workspace/pull-base      → runs backend.workspace_pull_base
GET  /chains/{id}/workspace/merge-preview  → Vcs_Merge_Preview
POST /chains/{id}/workspace/merge          → runs backend.merge_execute (after user click)
POST /chains/{id}/workspace/archive        → removes workspace (or keeps if flag)
```

All write ops require operator token. All are idempotent to the extent the backend allows.

## `ham-ctl` surface

```
ham-ctl workspace show   --chain <id>
ham-ctl workspace pull   --chain <id>
ham-ctl workspace merge  --chain <id> [--execute]
ham-ctl workspace diff   --chain <id> [--file <path>]
ham-ctl workspace forget --chain <id> [--keep]
```

Agents may call `ham-ctl workspace show / diff` to introspect their own state. Only `operator@local` (or an explicitly-privileged user token) can call `pull`, `merge --execute`, or `forget`.

## Failure and edge cases

### Detect ambiguity

If `git_repo` anchor points at a path where both `.git` and `.jj` exist, detect picks `jj` (matches the reasoning of the jj-first flag). Operator can override by editing the `vcs_kind` anchor to `git`.

### Missing repo path at project create

If the user provides no `git_repo`, `vcs_kind = "none"` is forced. Chains created in this project skip workspace provisioning. If they later add the anchor, new chains get workspaces; existing chains do not retroactively gain one.

### Base ref moves during a chain

- Detected on `workspace_pull_base`; if the rebase applies cleanly, workspace status becomes `clean` again.
- If conflicts arise, status = `conflicted`; scheduler surfaces this as an attention item to the coordinator (who forwards to operator).

### Worktree deleted by user out-of-band

- `workspace_status` returns non-ok.
- Daemon marks the workspace row `status = archived` (with a note "path missing").
- Chain continues; agents next-booted for that chain refuse to launch until operator either restores the workspace or creates a new chain.

### Force removal

`workspace_remove(force=true)` used only during migration or explicit archive-with-force. Never called from automated paths.

### Cross-project chains

Not supported. Each chain has exactly one project → one workspace at most. Cross-project collaboration is expressed as separate chains with dependencies (out of scope for teams v1).

## Test surface (Task 11.T)

Backend unit tests exercise both backends on scratch repos in `/tmp`:

- `workspace_add` creates a clean tree at the right path with the right branch/workspace name.
- `workspace_status` reports edits correctly (`M`, `A`, `?`).
- `workspace_diff` returns the same textual diff as `git diff` / `jj diff` invoked directly.
- `workspace_pull_base` succeeds on non-conflicting rebase; reports `is_conflicted` on conflict.
- `merge_preview` correctly classifies FF vs conflict vs merge-commit needed.
- `workspace_remove` cleans up completely (or, with `keep`, leaves a `.heimdall-kept` marker).

See [`10-review-invariants.md`](./10-review-invariants.md) for the reviewer checklist.
