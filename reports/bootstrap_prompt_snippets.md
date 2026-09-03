# Bootstrap Markdown & Default Skills — Inline Prompt Audit & Extraction Proposal

**Task:** `task_18d1be094b3165b7` (chain `chain_18d1bd65159d673c`)
**Date:** 2026-09-03
**Analyst:** Prompt Audit Analyst (`inst_18d1bdaecd20148d`)
**Scope:** `src/bridge`, `src/hub` (+ `src/wrapper`, `src/ctl` where they contribute) — inline prompt text concatenated/templated into the bootstrapped AGENTS.md / CLAUDE.md handbook, **and** the built-in default SKILL.md files delivered alongside it.

**Sections:** (1) Bootstrap assembly flow · (2) AGENTS.md inline snippet inventory + proposals (BP-1..BP-4) · (3) Summary · (4) **Default Skills (BP-5..BP-7)**.

---

## 1. Bootstrap assembly flow (BP-1)

### Live path (bridge + hub) — the one that matters
1. The **bridge** requests the bootstrap document from the hub:
   - `src/bridge/hub_runtime_client.odin:518` and `src/bridge/main.odin:137` call `bridge_bootstrap_fetch_manifest_and_materialize(...)`, hitting `GET /api/v1/bridge/agent-instances/<id>/bootstrap?format=manifest`.
   - Fallback to protocol-1 (`?` no manifest) via `bridge_bootstrap_fetch_and_materialize(...)` at `hub_runtime_client.odin:519` / `main.odin:138`.
2. The **hub HTTP handler** `src/hub/transport/http/bridge_handlers.odin:515-520` dispatches:
   - `format=manifest` → `agent_service.bootstrap_manifest_json_for_bridge` (**protocol 2**, fragment/hash assembly).
   - otherwise → `agent_service.bootstrap_json_for_bridge` (**protocol 1**, single inline JSON blob).
3. The **hub service** `src/hub/service/agent/agent_service.odin` builds the AGENTS.md body from string-literal sections (this is where the inline prompt snippets live).
4. The **bridge** materializes the file: writes `AGENTS.md`/`CLAUDE.md` (name resolved by `bridge_bootstrap_agents_md_name`), then **appends** its own CLI guidance via `bridge_bootstrap_ctl_guidance()` (`src/bridge/bootstrap_service.odin:398`, appended at lines 21 & 341), and writes skills as separate `SKILL.md` files.

Key structural note: the hub has **two parallel implementations of the same prompt text**:
- **Protocol 1** — inline JSON string builder: `bootstrap_json_for_bridge` (`agent_service.odin:330`), with the AGENTS.md content emitted inline around lines **393–412** and helpers `write_bootstrap_memory_markdown` (`:578`), `write_bootstrap_skill_fields` (`:422`).
- **Protocol 2** — fragment/hash assembler: `bootstrap_manifest_json_for_bridge` (`agent_service.odin:1391`), which already factors each section into a `render_*` helper (`render_header_inline:1347`, `render_agent_identity:1275`, `render_project:1283`, `render_tasks_guidance:1295`, `render_role_guidance:1303`, `render_memories_markdown:1311`) and skill helpers (`bootstrap_coordinator_task_skill:476`, `bootstrap_worker_task_skill:483`, `bootstrap_fallback_skill:488`).

**These two paths hold byte-for-byte-duplicated prompt strings.** That duplication is the core driver for extracting the text into shared `src/prompts/*.md` files loaded once (via Odin `#load`) and reused by both paths.

### Legacy path (wrapper) — note only, not the focus
`src/wrapper/main.odin` `build_agents_md` (`:1388`, called from `generate_bootstrap_files:1257` using `daemon_url`) assembles a *different* AGENTS.md with many inline literals (`# You`, `# Project`, `# Task Chain`, `# Collaboration Context`, `# Agent Operating Rules`, `# Tools`). It already externalizes one block via `#load("../prompts/bootstrap_profile_guidance.md")` (`:1433`). This is the wrapper/daemon-era generation path; per the chain guidance (ham-daemon deprecated) proposals below target the **live bridge/hub** path. Wrapper snippets are listed at the end as secondary candidates.

### Existing prompt files (reuse context)
From the prior audit (`reports/prompts_audit.md`): the only `src/prompts` files loaded by non-deprecated code today are `bootstrap_profile_guidance.md` and `guide-agent.md`. The 30 role persona/instructions files and 6 memory-audit files are daemon-only (deprecated). None of the bootstrap **section** text below currently lives in a `.md` file — it is all inline in Odin. So most proposals are **new** files; a few can reuse existing names.

---

## 2. Inline snippet inventory & extraction proposals (BP-2 / BP-3)

Legend: **P1** = protocol-1 inline (`bootstrap_json_for_bridge`), **P2** = protocol-2 fragment (`bootstrap_manifest_json_for_bridge`). "When populated" describes the trigger/interpolation.

| # | Snippet (label) | Code ref (file:line + fn) | When / how populated | Proposed `src/prompts/*.md` target |
|---|---|---|---|---|
| 1 | AGENTS.md header (`# Agent bootstrap` / Agent / Instance / Task chain / Coordinator) | P2 `render_header_inline` `agent_service.odin:1347`; P1 inline `:393-398` | Always. Interpolates agent name, instance id; adds `Task chain: <title> (<id>)` and `Coordinator: you (coordinator)`/`<coordinator_id>` when `chain_ok`. | **new** `bootstrap_header.md` (template with `%s` placeholders / documented tokens) |
| 2 | `## Project` block | P2 `render_project` `agent_service.odin:1283`; P1 inline `:401-407` | Only when project name or path present. Interpolates Name/Path/Repo/VCS/Description (each line conditional). | **new** `bootstrap_project.md` (template) |
| 3 | `## Working with tasks (REQUIRED)` (7 numbered rules) | P2 `render_tasks_guidance` `agent_service.odin:1295`; P1 inline `:408` | Always. Fully static, no interpolation. | **new** `bootstrap_tasks_guidance.md` |
| 4 | `## You are the COORDINATOR of this task chain …` | P2 `render_role_guidance` (coordinator branch) `agent_service.odin:1306`; P1 inline `:410` | When `chain_ok && is_coordinator`. Static. | **new** `bootstrap_role_coordinator.md` |
| 5 | `## You are a WORKER on this task chain …` | P2 `render_role_guidance` (worker branch) `agent_service.odin:1308`; P1 inline `:412` | When `chain_ok && !is_coordinator`. Static. | **new** `bootstrap_role_worker.md` (note: distinct from the `worker-task-management` SKILL in Section 4) |
| 6 | `## Applicable Memories` section header + per-memory `### <title>` / `Type:` formatting | P2 `render_memories_markdown` `agent_service.odin:1311-1325`; P1 `write_bootstrap_memory_markdown` `:578-591` | When ≥1 active fact/habit memory applies. Header static; body interpolates memory title/type/body. | **new** `bootstrap_memories_header.md` (just the static `## Applicable Memories` heading + intro; the per-item rows stay code-generated) |
| 7 | `## Agent Identity & Instructions` header | P2 `render_agent_identity` `agent_service.odin:1275-1281` | When `agent.instructions` non-empty. Header static; body = agent instructions (dynamic, DB-sourced — keep dynamic). | **new** `bootstrap_agent_identity_header.md` (heading only; body stays dynamic) |
| 8 | `## Heimdall CLI` guidance (managed ham-ctl usage + examples + env vars) | `bridge_bootstrap_ctl_guidance` (proc def `src/bridge/bootstrap_service.odin:164`) | Always appended by bridge after the hub body. Called at `:18` (`bridge_bootstrap_fetch_and_materialize`, protocol-1), `:57` (`bridge_bootstrap_materialize_local_provider_test`, provider-test), and `:386` (`bridge_bootstrap_fetch_manifest_and_materialize`, protocol-2/manifest). Static. | **new** `bootstrap_ctl_guidance.md` |

> The three default-SKILL string literals (`coordinator-task-management`, `worker-task-management`, `heimdall-ctl-communication`) and the migration-seeded `memory-management-workflow` SKILL are **not** AGENTS.md body snippets — they are written as separate `SKILL.md` files. They are covered in **Section 4 (Default Skills, BP-5..BP-7)** with their own table and `skills/<name>/SKILL.md` proposals.

### Secondary (legacy wrapper path — `src/wrapper/main.odin build_agents_md`)
Lower priority (daemon-era generation), listed for completeness:

| # | Snippet (label) | Code ref | When | Proposed target |
|---|---|---|---|---|
| L1 | `# Collaboration Context` bullets | `main.odin:1425` (`build_agents_md`) | Always in wrapper path | **new** `wrapper_collaboration_context.md` |
| L2 | `# Tools` cheatsheet bullets | `main.odin:1450-1455` | Always | **new** `wrapper_tools_cheatsheet.md` |
| L3 | `# Agent Operating Rules` block | `main.odin:1433` | Always | **reuse existing** `bootstrap_profile_guidance.md` (already `#load`ed here) |
| L4 | Memory section headers (`# Active Approved Memory[…]`) | `main.odin:1474`/`:1491`/`:1506` (`render_memory_for_agents_md`) | When memories present | **new** `wrapper_memory_headers.md` (headers only) |

---

## 3. Summary (BP-4)

### Proposed NEW prompt files (8 primary AGENTS.md/bridge snippets)
AGENTS.md section fragments (7):
- `bootstrap_header.md`
- `bootstrap_project.md`
- `bootstrap_tasks_guidance.md`
- `bootstrap_role_coordinator.md`
- `bootstrap_role_worker.md`
- `bootstrap_memories_header.md`
- `bootstrap_agent_identity_header.md`

Bridge-appended (1):
- `bootstrap_ctl_guidance.md`

> The four default-SKILL files are proposed separately in **Section 4** as `skills/<name>/SKILL.md` (not flat `src/prompts/*.md`).

### Reuse of EXISTING prompt files
- `bootstrap_profile_guidance.md` — already `#load`ed by the wrapper path (L3); no change needed there. Not currently used by the hub bridge path.

### Why extract (motivation for the refactor)
1. **Duplication:** every AGENTS.md section text exists twice in `agent_service.odin` — once in protocol-1 inline JSON (`:393-412`, `:578-591`) and once in protocol-2 `render_*` helpers (`:1275-1345`). Extracting to a single `#load`ed `.md` removes the drift risk (edit-one-forget-the-other bugs).
2. **Editability:** product/prompt wording currently requires editing escaped Odin string literals (`\\n`, `\\\"`). Markdown files are far safer to edit and review.
3. **Consistency with existing pattern:** the codebase already externalizes prompts via `#load("../prompts/*.md")` (wrapper), so this extends an established convention.

### Recommended extraction mechanics
- Add the new `.md` files under `src/prompts/`.
- Load each once as a compile-time constant: `SECTION_TASKS :: #load("../prompts/bootstrap_tasks_guidance.md", string)` in `agent_service.odin`.
- For templated sections (header, project, agent identity), keep the dynamic interpolation in Odin but source the static scaffolding/heading text from the `.md` (e.g. `fmt.tprintf` with the loaded template, or load the heading and concatenate the dynamic body).
- Have **both** protocol-1 and protocol-2 code paths consume the same constants to collapse the duplication.

### Caveats
- `ham-daemon` is deprecated; the wrapper path (L1–L4) is secondary. Prioritize the hub live-path snippets (#1–#8).
- Templated snippets (#1, #2, #8) must retain their conditional per-line logic in code; only the static text/headers move to `.md`.
- Default SKILL content carries YAML frontmatter (`---\nname: …`); preserve it verbatim (see Section 4).

---

## 4. Default Skills (BP-5 / BP-6 / BP-7)

Heimdall ships built-in **SKILL.md** files that are materialized into the agent run directory alongside AGENTS.md. Unlike the AGENTS.md body snippets in Section 2, these are written as **separate files** (one dir per skill), so they belong in a `skills/` externalization, not in `src/prompts/`.

### 4.1 How default skills are produced & delivered (BP-5)

**Producer = hub** (`src/hub/service/agent/agent_service.odin`). The hub emits a `skills` array (protocol-2) / `skills` + `default_skill_name`/`default_skill_content` fields (protocol-1) in the bootstrap payload. The skill CONTENT is inline Odin string literals:
- `write_bootstrap_skill_fields` (P1) `agent_service.odin:422` — builds the JSON `skills` array; injects the role skill first (`:428-441`), then memory-backed skills (`:443-455`), then a fallback if none (`:457-461`); also emits `default_skill_name`/`default_skill_content` (`:463-464`).
- Skills manifest loop (P2) inside `bootstrap_manifest_json_for_bridge` `agent_service.odin:1458-1479` — same three sources, emitting `{name, target_hint, hash}`; `target_hint` is `fmt.tprintf(".agents/skills/%s/SKILL.md", item.name)` (`:1538-1539`).
- Inline content procs (the actual literal text):
  - `bootstrap_coordinator_task_skill` `agent_service.odin:476` — returns name `coordinator-task-management` + full playbook (with `---\nname: …` frontmatter).
  - `bootstrap_worker_task_skill` `agent_service.odin:483` — name `worker-task-management` + full guide.
  - `bootstrap_fallback_skill` `agent_service.odin:488` — name `heimdall-ctl-communication` + basics.
- Memory-seeded skill: `memory-management-workflow` SKILL is a **SQL heredoc** seeded as a system skill memory at `src/hub/repository/sqlite/migrations.odin:531-566`; it reaches an agent via the memory→skill path (`bootstrap_memory_applies` + `m.type == .Skill`, rendered by `render_skill`/`bootstrap_skill_file_content` `agent_service.odin:1341`).

**Writer = bridge** (`src/bridge/bootstrap_service.odin`). The bridge takes the hub payload and writes each skill to disk:
- `bridge_bootstrap_write_skills` `bootstrap_service.odin:35` — iterates the `skills` array (`name`+`content`), computes a path, writes each (`:36-43`). If the array is empty it falls back to a single default: `default_skill_name` (default `"heimdall-ctl-communication"`) + `default_skill_content` (`:45-50`).
- Protocol-2 variant writes skills from cached blobs in the manifest loop at `bootstrap_service.odin:400-411`.
- `bridge_bootstrap_skill_relative_path` `bootstrap_service.odin:118` — resolves `<skill_dir>/<safe-name>/SKILL.md`. `skill_dir` comes from the provider profile (`profile.skill_dir`), else `bridge_provider_default_skill_dir` (`:122`).
- `bridge_bootstrap_write_skill_file` `bootstrap_service.odin:141` — writes the file (guards against path traversal / empty content).

**Per-provider default skill dir** — `bridge_provider_default_skill_dir` `src/bridge/provider_store.odin:238`:
- `pi` → `.pi/skills`
- `antigravity` / `agy` → `.agents/skills`
- everything else (incl. `claude`) → `skills`

(Config can override via `bootstrap.features['skills'].relative_dir`; see `bridge_provider_skill_dir_from_config` `provider_store.odin:229`.)

### 4.2 Default skills table (BP-6)

| Skill (name) | Code ref (file:line + fn) | When populated | Current source | Proposed `skills/` target |
|---|---|---|---|---|
| `coordinator-task-management` | content: `bootstrap_coordinator_task_skill` `agent_service.odin:476`; emitted P1 `write_bootstrap_skill_fields:428-441`, P2 loop `:1462-1471` | Chain member **and** `is_coordinator`. Injected first; also becomes `default_skill_*`. | **inline Odin string literal** (with frontmatter) | `skills/coordinator-task-management/SKILL.md` |
| `worker-task-management` | content: `bootstrap_worker_task_skill` `agent_service.odin:483`; emitted P1 `:428-441` (else branch), P2 `:1462-1471` | Chain member **and** not coordinator. Injected first; also `default_skill_*`. | **inline Odin string literal** | `skills/worker-task-management/SKILL.md` |
| `heimdall-ctl-communication` | content: `bootstrap_fallback_skill` `agent_service.odin:488`; emitted P1 `:457-461`, P2 `:1473-1478`; bridge fallback default `bootstrap_service.odin:46` | Fallback when no other skill applies (`written == 0`) OR when the hub returns an empty skills array (bridge-side default). | **inline Odin string literal** (in hub) + hardcoded default name in bridge | `skills/heimdall-ctl-communication/SKILL.md` |
| `memory-management-workflow` | SQL seed `src/hub/repository/sqlite/migrations.odin:531-566`; rendered via memory→skill path `render_skill`/`bootstrap_skill_file_content` `agent_service.odin:1341` | Present as a seeded active **system** skill memory; applies to all agents (no scope restriction) via `bootstrap_memory_applies`. | **inline SQL heredoc** (migration) | `skills/memory-management-workflow/SKILL.md` |

Notes on triggering: the role skill (coordinator vs worker) is chosen by `is_coordinator := chain.coordinator_agent_instance_id == inst.agent_instance_id` and only when `chain_ok`. Provider/tier do not change WHICH skill is chosen, only the on-disk **directory** (per-provider default dir above). Memory-backed skills additionally require the memory to pass scope filters in `bootstrap_memory_applies` (`agent_service.odin`).

### 4.3 Which are already file-based vs inline

All four default skills are currently **inline** (three Odin string literals + one SQL heredoc). **None** are loaded from a file today. This mirrors the AGENTS.md snippet problem and, for the three role/fallback skills, the same **P1/P2 duplication** (the literal is returned by one shared proc each — `bootstrap_*_skill` — but that proc's text is what should move to a file; the callers in both protocol paths already share the proc, so a single `#load` fixes both).

### 4.4 Proposed `skills/` layout & load-from-file (BP-7)

Introduce a source tree that mirrors the on-disk SKILL layout, e.g. under `src/prompts/skills/` (kept with the other externalized prompt assets):

```
src/prompts/skills/
  coordinator-task-management/SKILL.md
  worker-task-management/SKILL.md
  heimdall-ctl-communication/SKILL.md
  memory-management-workflow/SKILL.md
```

Load-from-file wiring:
- Hub: replace the inline returns with compile-time loads, e.g.
  `bootstrap_coordinator_task_skill :: proc() -> (string, string) { return "coordinator-task-management", #load("../../prompts/skills/coordinator-task-management/SKILL.md", string) }` (adjust the relative path to the file's package dir). Same for `worker-task-management` and `heimdall-ctl-communication`. Both protocol-1 and protocol-2 already call these procs, so one change updates both.
- Migration skill: have the seeder read `src/prompts/skills/memory-management-workflow/SKILL.md` (via `#load`) and bind it as the memory `body` at seed time, instead of the `migrations.odin:531-566` heredoc.
- The bridge writer needs **no change** — it already writes whatever `name`/`content` the hub sends into `<skill_dir>/<name>/SKILL.md`. The externalization is purely on the hub content-source side.
- Preserve each file's YAML frontmatter (`---\nname: …\ndescription: …\n---`) verbatim; the bridge writes the content byte-for-byte.

### 4.5 Default-skills summary
- **4 default skills**, all currently inline (3 Odin literals in `agent_service.odin`, 1 SQL heredoc in `migrations.odin`).
- **0 already file-based.**
- Proposal: 4 new `skills/<name>/SKILL.md` files loaded via `#load` (hub) / seeder read (migration). Bridge delivery path unchanged.
- Same rationale as the prompt snippets: editable, reviewable, and de-duplicated across the P1/P2 bootstrap code paths.
