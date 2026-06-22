# Bootstrap Configuration Redesign Plan

## Goals

Replace the current sprawl of overlapping bootstrap flags (`bootstrap_enabled`, `bootstrap_profile`, `agents_md_name`, `bootstrap_files`, `bootstrap_sections`) with a single, structured `bootstrap` config block per agent command.

The new model has three orthogonal axes:

1. **What** to generate — `enabled_features` lists the logical outputs.
2. **Where/how** to place each output — per-feature `name`, `relative_dir`, `filename`.
3. **What** goes into each output — per-feature `content` (for file features).

A guiding principle: **AGENTS.md should not be polluted with trivial, dynamic memory items**. Behavior-shaping memories (EXPERTISE, HABIT) live inline because the agent reads AGENTS.md every turn. Fact-recall memories (FACT, EPISODE) live in MEMORY.md and are referenced from AGENTS.md by title + relative path only.

---

## Features

### `AGENTS_MD`

The agent's primary instruction file — read every turn.

**Placement**
- `name`: filename to write (default: `"CLAUDE.md"` if agent cmd is `claude`, else `"AGENTS.md"`)

**Content sections** (configurable via `content = [...]`, default: all)
- `IDENTITY` — display name, instance id, provider/profile, daemon URL, managed-file notice.
- `GUIDANCE` — ham-ctl CLI reference (profile-aware text, inferred from agent cmd name).
- `PROJECT` — project context fetched from daemon.
- `MEMORY` — agent's behavior-shaping + recall index. See "Memory rendering in AGENTS.md" below.

### `MEMORY_MD`

A separate file containing the full bodies of FACT and EPISODE memories. Regenerated each run; AGENTS.md is mostly stable.

**Placement**
- `name`: filename (default: `"MEMORY.md"`)

**Content (fixed structure)**
- Each FACT memory: a section with title + full body.
- Each EPISODE memory: a section with title + full body.
- Each entry is addressable by a stable anchor slug derived from the memory title, so AGENTS.md can link to it (e.g. `MEMORY.md#prefers-concise-pr-descriptions`).

### `SKILLS`

One file per active SKILL-type memory, written under a subdirectory of the run dir.

**Placement**
- `relative_dir`: subdirectory (default: `"skills"`)
- `filename`: per-skill filename (default: `"SKILL.md"`)

**Layout**
- `<run_dir>/<relative_dir>/<skill-title-slug>/<filename>` per skill memory.
- File body is the skill's memory body verbatim, prefixed with the managed header for manifest-tracked cleanup.

---

## Memory rendering in AGENTS.md

The `MEMORY` content section of AGENTS.md is split by memory type. Type-specific rules:

| Type      | Where shown in AGENTS.md             | What is shown                                | ID shown? |
|-----------|--------------------------------------|----------------------------------------------|-----------|
| TEMPLATE  | `## Active Templates`                | Title + full body                            | No        |
| EXPERTISE | `## Expertise`                       | Title + full body                            | No        |
| HABIT     | `## Habits`                          | Title + full body                            | No        |
| FACT      | `## Facts` (index only)              | Title + ref to `MEMORY.md#<slug>`            | No        |
| EPISODE   | `## Episodes` (index only)           | Title + ref to `MEMORY.md#<slug>`            | No        |
| SKILL     | Not in AGENTS.md                     | Handled by `SKILLS` feature                  | n/a       |

Rationale:
- **EXPERTISE / HABIT / TEMPLATE** shape how the agent behaves on every turn. They must be inline. IDs are noise — the agent reads them as behavioral rules, not as data records to mutate. Strip them.
- **FACT / EPISODE** are recall content. The agent only needs to know *what facts exist* most of the time. The full body is one file-read away in MEMORY.md when actually needed. This keeps AGENTS.md compact.
- **SKILL** is structurally larger and benefits from its own directory + file per skill (already a separate feature).

If `MEMORY_MD` is **not** in `enabled_features`, FACT/EPISODE fall back to inline title + body in AGENTS.md (since there is nowhere else to put them). This is the simple-config fallback.

Anchor slug for cross-file references: `safe_slug(title)` — same slugger already used for project/agent dir names.

---

## Config shape

### Claude (typical)
```toml
[wrapper.agent-cmd.claude.bootstrap]
enabled_features = ["AGENTS_MD", "MEMORY_MD", "SKILLS"]

[wrapper.agent-cmd.claude.bootstrap.AGENTS_MD]
name = "CLAUDE.md"
content = ["IDENTITY", "GUIDANCE", "PROJECT", "MEMORY"]

[wrapper.agent-cmd.claude.bootstrap.MEMORY_MD]
name = "MEMORY.md"

[wrapper.agent-cmd.claude.bootstrap.SKILLS]
relative_dir = "skills"
filename = "SKILL.md"
```

### Pi (minimal, all defaults)
```toml
[wrapper.agent-cmd.pi.bootstrap]
enabled_features = ["AGENTS_MD"]
```
Yields a single `AGENTS.md` with all four sections; FACT/EPISODE are inline because there is no MEMORY_MD.

### Bootstrap disabled
Omit `[wrapper.agent-cmd.<name>.bootstrap]` entirely, or set `enabled_features = []`.

---

## Fields removed from `Agent_Command_Config`

| Removed                | Replaced by                                                   |
|------------------------|---------------------------------------------------------------|
| `bootstrap_enabled`    | `len(bootstrap.enabled_features) > 0`                         |
| `bootstrap_profile`    | Inferred from agent cmd name (existing fallback in `bootstrap_profile` proc) |
| `agents_md_name`       | `bootstrap.AGENTS_MD.name`                                    |
| `bootstrap_files`      | `bootstrap.enabled_features`                                  |
| `bootstrap_sections`   | `bootstrap.AGENTS_MD.content`                                 |

`memory_templates` stays where it is (on both `Agent_Command_Config` and `Wrapper_Config`) — it gates *which* TEMPLATE memories appear in bootstrap output, and it is also consumed by the starter prompt path.

---

## New Odin structs (`src/lib/config/config.odin`)

```odin
Bootstrap_Feature_Config :: struct {
    name:         string,    // AGENTS_MD / MEMORY_MD: filename
    content:      []string,  // AGENTS_MD: section list
    relative_dir: string,    // SKILLS: subdirectory
    filename:     string,    // SKILLS: per-skill filename
}

Bootstrap_Config :: struct {
    enabled_features: []string,
    features:         map[string]Bootstrap_Feature_Config,
}
```

`Agent_Command_Config` gains `bootstrap: Bootstrap_Config` and loses the five fields above.

---

## TOML parser changes

Current sections handled:
- `[wrapper]`
- `[wrapper.agent-cmd.<name>]`
- `[wrapper.agent-cmd.<name>.startup_detection]`

Add two more:
- `[wrapper.agent-cmd.<name>.bootstrap]`
- `[wrapper.agent-cmd.<name>.bootstrap.<FEATURE>]`

`Section` enum gains:
- `Wrapper_Agent_Bootstrap`
- `Wrapper_Agent_Bootstrap_Feature`

Parser state tracks `current_agent_command` (existing) and a new `current_bootstrap_feature`. Match logic in `parse_config` is extended in priority order (most specific first), mirroring how `startup_detection` is handled.

---

## Bootstrap process changes (`src/wrapper/main.odin`)

Replace `generate_bootstrap_files` with a feature-driven dispatch:

```
if len(agent_cmd.bootstrap.enabled_features) == 0: return

for feature in enabled_features:
    switch feature:
    case "AGENTS_MD": write_agents_md(...)
    case "MEMORY_MD": write_memory_md(...)
    case "SKILLS":    write_skills(...)
    default:          log unknown feature, skip
```

### `write_agents_md`
1. Resolve `name` (default per profile).
2. Resolve `content` (default: all four sections).
3. Build sections in order. The MEMORY section calls a renderer that knows whether MEMORY_MD is enabled (to decide inline vs reference for FACT/EPISODE).
4. Write to `<run_dir>/<name>` with managed header.

### `write_memory_md`
1. Resolve `name` (default `"MEMORY.md"`).
2. Iterate active FACT + EPISODE memories.
3. Emit `## <title> {#<slug>}` blocks with full body and a stable anchor.
4. Write to `<run_dir>/<name>` with managed header.

### `write_skills`
1. Resolve `relative_dir` and `filename`.
2. Iterate active SKILL memories.
3. For each: `mkdir <run_dir>/<relative_dir>/<safe_slug(title)>`, write `<filename>` with managed header + skill body.

### Memory fetcher
The existing `active_memory_bootstrap` already pulls active memories from the daemon via `/agent-rpc memory_list`. Refactor to return a typed list (id, type, title, body, scope) rather than a pre-rendered string. The three writers then filter/format from that single list:
- AGENTS.md renderer: filter by type, drop ID for inline types, render reference for index types.
- MEMORY.md renderer: filter FACT + EPISODE, emit full bodies with anchors.
- SKILLS renderer: filter SKILL, write per-skill files.

This avoids re-fetching from the daemon three times.

### Manifest
The existing `.heimdall-bootstrap-manifest` tracks written files for cleanup. Extend it to track skill subdirectory contents (each skill file path relative to `run_dir`). Cleanup logic already keys on "file has managed header" so it remains safe.

---

## `bootstrap_profile` removal — guidance text inference

The `GUIDANCE` content section currently produces provider-specific text (claude vs codex vs pi). The current `bootstrap_profile` proc already falls back to inferring from the agent command name when the explicit field is empty. With the field removed entirely, that fallback becomes the only path. No new field needed.

---

## Migration

`config.toml` ships with three agent commands: `pi`, `claude`, `codex`. The redesign is a config-only break — the daemon schema and wire protocol are unchanged. Steps:

1. Update `config.toml` to the new shape for all three commands.
2. Update default `Bootstrap_Config` in `default_config()` to match what each command needs.
3. Existing managed files in agent run dirs are still owned by the manifest header check, so a stale `AGENTS.md` from the previous flow is overwritten cleanly on next start.
4. `MEMORY.md` and `skills/*/SKILL.md` are new files — they appear on next start.

---

## Implementation order (when implementation begins)

1. **Config types + parser**
   - Add `Bootstrap_Config`, `Bootstrap_Feature_Config` to `config.odin`.
   - Add new `Section` enum variants.
   - Extend `parse_config` to recognize the two new section headers.
   - Add `parse_bootstrap_key` and `parse_bootstrap_feature_key`.
   - Remove the five replaced fields from `Agent_Command_Config` and their parser cases.
2. **Wrapper refactor**
   - Refactor `active_memory_bootstrap` to return typed memory records.
   - Replace `generate_bootstrap_files` with the feature dispatcher.
   - Implement `write_agents_md`, `write_memory_md`, `write_skills`.
   - Update manifest write/cleanup to handle nested skill paths.
   - Remove `default_bootstrap_files`, `bootstrap_section_enabled` (subsumed by content list), and the old `bootstrap_file_content` proc.
3. **Config file**
   - Update `config.toml` for `pi`, `claude`, `codex`.
4. **Verify**
   - Build via `nix build .#ham-wrapper`.
   - Start an agent and inspect the run dir: AGENTS.md (or CLAUDE.md), MEMORY.md, `skills/<name>/SKILL.md`.
   - Confirm FACT/EPISODE in AGENTS.md show only title + reference, and EXPERTISE/HABIT show title + body with no IDs.
