# Bootstrap & Agent Bug Tracker

## BUG-1 — Template memory appears twice in AGENTS.md
**Status:** Fixed  
**File:** `src/wrapper/main.odin` → `format_active_memory_bootstrap`

**Root cause:** `active_memory_bootstrap` makes two calls. Call 1 (global, `templates_only=true`) writes matching template memories to `# Active Approved Memory Templates`. Call 2 (per-agent, `templates_only=false`) includes ALL types for the agent — so template memories whose `subject_agent` matches the bootstrapped agent appear in both sections.

**Fix:** In `format_active_memory_bootstrap`, when `templates_only=false`, skip entries where `type == "template" && memory_template_matches(object, memory_templates)`. Requires passing `memory_templates` through to the second call so it knows what was already shown.

---

## BUG-2 — Memory injected redundantly into both AGENTS.md and starter prompt
**Status:** Fixed  
**File:** `src/wrapper/main.odin` → `build_agent_command` (line 865)

**Root cause:** When `bootstrap_enabled=true` AND `starter_prompt` is set AND `memory_templates` is configured, `active_memory_bootstrap()` is called once inside `generate_bootstrap_files` (writes to AGENTS.md) and again inside `build_agent_command` (appended to the starter prompt). Memory appears twice: once in the file the agent reads, once in the initial prompt.

**Fix:** In `build_agent_command`, skip the `active_memory_bootstrap` append when `agent_cmd.bootstrap_enabled == true`. `memory_cli_guidance` (usage instructions) should still be included — only the `active_memory_bootstrap` content is redundant when AGENTS.md already has it.

---

## BUG-3 — Manifest records files that couldn't be written
**Status:** Fixed  
**File:** `src/wrapper/main.odin` → `generate_bootstrap_files`

**Root cause:** `write_manifest(cwd, files)` is called unconditionally with the full configured `files` list, even for files skipped because `can_write_managed_file` returned false (pre-existing unmanaged file). The manifest falsely claims bootstrap owns those files.

**Fix:** Track which files were actually written into a `written: [dynamic]string` slice inside the loop. Pass `written[:]` to `write_manifest` instead of the full `files` list. Skipped files are never recorded as bootstrap-managed.

---

## BUG-4 — Memory propose error message incorrectly lists `type` as required
**Status:** Fixed  
**File:** `src/daemon/memory_service.odin` (lines 27-31)

**Root cause:** The validation error at line 31 says `"memory propose new requires subject_agent, type, title, and body"` but the check only validates `subject_agent`, `title`, and `body`. `type` is validated separately at line 27-28 with a distinct `"invalid memory type"` error. Omitting `type` produces the wrong error. `memory_type_parse("")` returns `(.Fact, false)` — the intent is unclear (optional with default, or required?).

**Fix (two-part):**
1. Make `type` truly optional: change `memory_type_parse` to return `(.Fact, true)` for empty string.
2. Update the error message at line 31 to remove "type": `"memory propose new requires subject_agent, title, and body"`.

---

## BUG-5 — Fallback project context appears in AGENTS.md when project = "default" has no real project
**Status:** Fixed  
**File:** `src/wrapper/main.odin` → `project_bootstrap_context`

**Root cause:** When `agent_cmd.project` is unset, the function falls back to `cfg.project` which defaults to `"default"`. The `/projects/show` call returns 404. Rather than returning empty, the fallback writes `"# Project Context\nConfigured project: default\n..."` — a noise section with no useful information to the agent.

**Fix:** When `/projects/show` returns non-200, return `""` (no project context section). Only write project context when the API call succeeds and `format_project_bootstrap` returns non-empty content.

---

## BUG-6 — Global memory scan returns all active memories to any authenticated agent
**Status:** Won't Fix (accepted)  
**File:** `src/wrapper/main.odin` → `active_memory_bootstrap` (first call); `src/daemon/memory_service.odin`

**Note:** Fine for agents to read all memories. Leaving as-is.

---

## BUG-7 — Nix build broken: `src/ui/debugCapture.ts` untracked in git
**Status:** Fixed  
**File:** `src/ui/debugCapture.ts` (untracked), `src/ui/main.tsx` (imports it)

**Root cause:** The nix flake only includes git-tracked files. `debugCapture.ts` was created but never `git add`-ed. `npm run build` inside the nix derivation fails with `Could not resolve "./debugCapture" from "src/ui/main.tsx"`.

**Fix:** `git add src/ui/debugCapture.ts`.

---

## BUG-8 — Agent provider shows agent class instead of actual provider profile
**Status:** Fixed  
**File:** `src/daemon/agents_start.odin` → `handle_agents_list` (line 66)

**Root cause:** For live-registry agents without a persisted record, `handle_agents_list` writes `ag.agent_class` as `provider_profile`. Agents that received a startup_report (all wrapper-started agents) get `ag.provider_profile` updated in-memory via `registry_update_startup`, but only agents with a persisted record are shown from that record. Live-registry-only agents always show agent_class as provider.

**Fix:** Use `ag.provider_profile` if non-empty, else fall back to `ag.agent_class`:
```odin
provider := ag.provider_profile if ag.provider_profile != "" else ag.agent_class
```
One-line change at line 66.

---

## BUG-9 — Agent stuck in "starting" state after wrapper dies
**Status:** Fixed  
**Files:** `src/daemon/registry.odin` → `registry_clear_ws`; new `src/daemon/agent_startup_janitor.odin`; `src/lib/config/config.odin`

**Root cause:** `registry_register` sets `startup_status = "starting"` when the wrapper connects. `registry_clear_ws` (called on WS disconnect) only clears `connected`/`has_ws` — it does not clear `startup_status`. If the wrapper dies before sending a startup_report, the agent stays stuck in "starting" permanently. Two sub-cases:
1. Wrapper connected WS but died before startup_report → WS closes but `startup_status` stays "starting"
2. Wrapper registered (`/register`) but never opened WS and then died → `connected = true`, `has_ws = false`, `startup_status = "starting"` forever

**Fix (two layers):**
1. `registry_clear_ws`: immediately set `startup_status = "startup_failed"` with `reason_code = "ws_disconnected"` when status is "starting" — covers sub-case 1 instantly.
2. New `agent_startup_janitor` background thread: every 30s scans for agents still in "starting" past `startup_stale_after_seconds` (default 120s, configurable in `[daemon]`), marks them `startup_failed` with `reason_code = "startup_stale"` and emits lifecycle event — covers sub-case 2.

---

## BUG-10 — Archived/missing agents persist in Electron local cache
**Status:** Fixed  
**File:** `src/ui/store/chatSlice.ts` → `mergeKnownAndLiveAgents`, `refreshAgents`

**Root cause:** `mergeKnownAndLiveAgents` seeds `byId` from `localKnownAgents` (localStorage) first. Archived agents and agents no longer returned by `/agents` survive the merge because local cache entries are never pruned.

**Fix:** Track `daemonReachable` in `refreshAgents` (true when `/agents` call succeeds). In `mergeKnownAndLiveAgents`, build a `daemonIds` set from daemon-returned agents. When daemon is reachable, skip any local-cache entry whose ID is not in `daemonIds`. `storeKnownAgents(merged)` then persists the pruned list, keeping localStorage in sync.
