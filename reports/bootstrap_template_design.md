# Bootstrap Template Design — Single AGENTS.md Template (DB-value `{variable}`s + inline prose)

**Task:** `task_18d1bf800088e2ee` (chain `chain_18d1bd65159d673c`)
**Date:** 2026-09-03
**Analyst:** Prompt Audit Analyst (`inst_18d1bdaecd20148d`)
**Builds on:** `reports/bootstrap_prompt_snippets.md`, `reports/prompts_audit.md`
**Type:** DESIGN / PROPOSAL (no code changes yet)
**Revised:** 2026-09-03 (TPLR series) — applied the rule below.

> **Guiding principle: Variables = DB-fetched dynamic values ONLY. All static prose is inline in the template file, conditionally gated by boolean `{{#marker}}` blocks — never passed as a variable.** A `{variable}` therefore always corresponds to a value read from the database (or an instance field); a `{{#marker}}` is a boolean derived from DB presence/identity that gates static prose.

---

## 0. Recommendation in one line

Replace the two hand-duplicated hub assembly paths with **ONE bootstrap template file** — `src/prompts/bootstrap_agents_md.tmpl.md` — that holds **all static prose inline** and uses two constructs: DB-value placeholders `{name}` and boolean conditional blocks `{{#marker}}…{{/marker}}`. Keep the **4 default skills separate** (distinct files, per Section 4 of the prior report) and keep the **bridge `## Heimdall CLI` block separate** (written by a different process, fully static, lives in its own `bootstrap_ctl_guidance.md` — **not** a template variable). Net file set: **1 template + 1 CLI-guidance file + 4 skill files**.

---

## 1. Static vs Dynamic vs Conditional (TPL-1)

Re-confirmed against the two hub implementations and the bridge:
- **Protocol 1 (P1):** `bootstrap_json_for_bridge` `agent_service.odin:330`, AGENTS.md body emitted inline at `:393-412`, memories at `:578-591` (`write_bootstrap_memory_markdown`).
- **Protocol 2 (P2):** `bootstrap_manifest_json_for_bridge` `agent_service.odin:1391`, sections via `render_*` helpers `:1275-1345`, assembled at `:1503-1533`.
- **Bridge:** `bridge_bootstrap_ctl_guidance` `bridge/bootstrap_service.odin:164`, appended at `:18` / `:57` / `:386`.

| Section | Nature | Notes |
|---|---|---|
| Header (`# Agent bootstrap` + Agent/Instance) | **Dynamic** scalars | Always present. `agent_name`, `instance_id`. |
| Header chain lines (`Task chain:`, `Coordinator:`) | **Conditional + Dynamic** | Only when `chain_ok`. Coordinator line differs for self vs other. |
| `## Agent Identity & Instructions` | **Conditional + Dynamic** | Renders **only** `agent.instructions` today. **Present in P2 (`render_agent_identity:1275`), ABSENT in P1** — see §1.1. **Template persona/instructions are NOT injected — see §1.2 (current gap).** |
| `## Project` | **Conditional + Dynamic** | Only when name or path set; each of Name/Path/Repo/VCS/Description is an independently-conditional line. |
| `## Working with tasks (REQUIRED)` | **Static** | Identical fixed prose in both paths. |
| Role guidance (COORDINATOR / WORKER) | **Conditional + Static**, mutually exclusive | Only when `chain_ok`; coordinator vs worker branch. Each branch is fixed prose. |
| `## Applicable Memories` (+ per-item rows) | **Conditional + Dynamic** | Header only when ≥1 fact/habit memory; rows iterate memory title/type/body. |
| Bridge `## Heimdall CLI` | **Static**, appended by bridge | Cross-process — added after the hub body is written. |

### 1.1 Divergence the template will fix
- **P1 omits `## Agent Identity & Instructions`** (body order: header → Project → tasks → role → memories) while **P2 emits it** (header → agent_identity → project → tasks → role → memories). A single template makes the section set + order canonical.
- The role/tasks/project prose is **byte-duplicated** across P1 inline literals and P2 `render_*` procs — the core drift risk.

### 1.2 Current gap — template persona/instructions are never injected (TMPL-1)

**Verified end-to-end:** the agent-template's `persona` and `instructions` **never reach the bootstrap AGENTS.md**. Evidence:
- The `templates` table has `persona` + `instructions` columns and `domain.Template` carries both: schema `src/hub/repository/sqlite/migrations/002_owner_scoped_core.sql:225-226` (`persona TEXT NOT NULL DEFAULT '' / instructions TEXT NOT NULL DEFAULT ''`, table at `:219`); domain struct `src/hub/domain/content.odin:142` (fields `persona`, `instructions` at `:148-149`); repo SELECT `content_repo_sqlite.odin:143` (`content_get_template_sqlite`, `SELECT … persona, instructions … FROM templates`); `template_from_stmt` maps `persona=column_text(s,5)`, `instructions=column_text(s,6)` (`content_repo_sqlite.odin:172`).
  - **Caveat (latent trap):** the *embedded fallback* migration const `MIGRATION_002_OWNER_SCOPED_CORE` in `migrations.odin` (~`:213-248`) is a **stale/divergent copy** whose `templates` table is only `(template_id, owner_user_id, name, body)` — it has **no** persona/instructions columns. The loader prefers the on-disk `.sql` via `os.read_entire_file` (`migrations.odin:656`, const only as fallback), so real deployments get the correct `.sql` shape; but the divergence is worth flagging.
- The `agents` table has a **single** `instructions` column + a `template_id` FK — **no persona column** (`domain/agent.odin:22,25`; repo `agent_repo_sqlite.odin:42-66`).
- `create_agent` builds the agent with `instructions = input.instructions` and `template_id = input.template_id` but **does not copy** the template's persona/instructions into the agent (`agent_service.odin:85`). So template content is not snapshotted at creation either.
- The bootstrap identity renderer `render_agent_identity` uses **only** `agent.instructions` (`agent_service.odin:1275-1281`); P1 doesn't render identity at all (`:393-414`).
- **No template join in the bootstrap/agent path:** grep for `.persona` / `content_get_template` across `src/hub/service/agent/` returns **zero** hits — `agent_service.odin` only reads `template_id` as a string (for the memory `template_id`-scope filter at `:611-614`), never fetching the `templates` row. `content_get_template` exists on the repo iface (`repository/iface/content_repo.odin:70`) and the bootstrap service already holds `service.content`, but it is never called for templates.

> **Current gap: template persona/instructions are never injected into the bootstrap.** An agent created from a template gets only its own `agents.instructions`; the template's `persona` and `instructions` are silently dropped — making templates effectively cosmetic for the running agent. The design below fixes this with two new DB-backed variables.

---

## 2. Merge vs Keep-Separate decisions (TPL-2)

| Fragment | Decision | Rationale |
|---|---|---|
| Header + chain/coordinator lines | **MERGE** into template | Always-present scaffold. Static label prose (`# Agent bootstrap`, `Agent:`, `Instance:`, `Task chain:`, `Coordinator:`) is inline; only the DB values (`{agent_name}`, `{instance_id}`, `{chain_title}`, `{chain_id}`, `{coordinator_instance_id}`) are variables. The `Coordinator:` label + the `you (coordinator)` literal are inline under `{{#is_coordinator}}`/`{{#is_worker}}` markers. |
| `## Agent Identity & Instructions` | **MERGE** (conditional block) | Static heading + dynamic body → `{{#agent_identity}}## Agent Identity & Instructions\n{agent_instructions}{{/agent_identity}}`. Fixes the P1/P2 divergence. |
| `## Project` | **MERGE** (conditional block, nested optional lines) | Whole block (heading + static prose) inline under `{{#project}}`; each field line gated by its own value marker so an empty DB field drops just that line. Only the field values are variables. |
| Role guidance (coordinator/worker) | **MERGE** as TWO inline mutually-exclusive blocks `{{#is_coordinator}}…{{/is_coordinator}}` / `{{#is_worker}}…{{/is_worker}}` | Per the DB-values-only rule: the two role texts are **static prose inlined verbatim in the template**, each gated by a boolean marker. The only code inputs are `is_coordinator`/`is_worker` (booleans derived from DB: `chain.coordinator_agent_instance_id == inst.agent_instance_id`). No `{role_guidance}` variable. |
| `## Working with tasks` | **MERGE** (static, inline) | 100% static 7-rule prose inlined verbatim in the template. No variable. |
| `## Applicable Memories` | **MERGE** heading as a conditional block; **keep row rendering in code** | Header (`## Applicable Memories`) is static prose inline in the template under `{{#memories}}`. The variable-length `### <title>` rows are DB-derived (memory rows), so they are passed as the one DB-backed block variable `{memory_items}`. |
| Bridge `## Heimdall CLI` | **KEEP SEPARATE (not a variable)** | Written by the **bridge process** (`bootstrap_service.odin:164`) after the hub returns the body, in three call sites incl. the provider-test path that has no hub body at all. It is fully static and cross-process → lives in its own `src/prompts/bootstrap_ctl_guidance.md` loaded by the bridge (prior report snippet #8). It is **not** a hub-template variable and does not appear in the variable table. |
| 4 default skills | **KEEP SEPARATE** (own files) | They are distinct `SKILL.md` files materialized to per-provider skill dirs, not part of the AGENTS.md body. Covered by Section 4 of `bootstrap_prompt_snippets.md` → `skills/<name>/SKILL.md`. |

**Recommended concrete file set:**
1. `src/prompts/bootstrap_agents_md.tmpl.md` — the single AGENTS.md body template (replaces the 7 AGENTS.md fragment files proposed earlier + both inline code paths).
2. `src/prompts/bootstrap_ctl_guidance.md` — bridge-appended CLI block (separate process).
3. `src/prompts/skills/{coordinator-task-management,worker-task-management,heimdall-ctl-communication,memory-management-workflow}/SKILL.md` — the 4 default skills.

This collapses the earlier "8 fragment files" to **1 template** while honoring the two genuine cross-process boundaries (bridge CLI block, skill files).

### 2.1 Identity composition & precedence (TMPL-3)

The `## Agent Identity & Instructions` section must now compose **three** DB-backed sources: `template.persona`, `template.instructions`, and `agent.instructions`. Recommended layout and precedence:

**Order inside the section:**
1. **Persona first** (`{template_persona}`) — the role/character framing that should color everything after it.
2. **Effective instructions** = **template base + agent augmentation**, in that order:
   - `{template_instructions}` (the template's base instructions) then
   - `{agent_instructions}` (the agent-specific instructions that augment/override).

**Recommended rule: COMPOSE (append), do not replace.** Render `template.instructions` as the base and **append** `agent.instructions` after it under a clear sub-heading, so the agent-level text augments/overrides in context without discarding the template's content. Rationale: the template exists to carry reusable role guidance; silently dropping it whenever an agent has its own instructions would waste the template and surprise users who set both. Markdown/LLM precedence is positional — later, more-specific instructions naturally take priority, so "append agent after template" gives override semantics without data loss.

**Proposed sub-structure:**
```
## Agent Identity & Instructions

### Persona                (only if template.persona)
<template.persona>

### Instructions           (only if template.instructions OR agent.instructions)
<template.instructions>    (only if present)

<agent.instructions>       (only if present; appended after template base)
```

**Presence matrix (which of the three is set):**
| template.persona | template.instructions | agent.instructions | Result |
|:---:|:---:|:---:|---|
| ✓ | ✓ | ✓ | Persona, then template instructions, then agent instructions appended. |
| ✓ | ✓ | — | Persona + template instructions. |
| ✓ | — | ✓ | Persona + agent instructions. |
| — | ✓ | ✓ | Template instructions + agent instructions appended (no persona heading). |
| ✓ | — | — | Persona only. |
| — | ✓ | — | Template instructions only. |
| — | — | ✓ | Agent instructions only (today's behavior). |
| — | — | — | Whole `## Agent Identity & Instructions` section dropped (marker false). |

The `{{#agent_identity}}` marker is therefore widened to **`has(template.persona) OR has(template.instructions) OR has(agent.instructions)`** (today it is just `agent.instructions != ""`). Each of the three sub-blocks is independently gated so empty sources drop cleanly without leaving stray headings/blank lines. The `### Persona` / `### Instructions` sub-headings are **static prose** inline in the template (not variables), gated by their markers.

**Alternative considered — full override (rejected):** treat a non-empty `agent.instructions` as a complete replacement for `template.instructions`. Simpler, but it wastes template content and makes the `templates.instructions` column meaningless whenever an agent sets its own — exactly the "templates are pointless" failure the user flagged. Compose/append is preferred; if a hard override is ever wanted it should be an explicit, modeled flag, not an implicit side effect of setting agent instructions.

---

## 3. Variable list (TPL-3, revised per TPLR-4)

**Rule applied:** a `{variable}` appears **only** for a value fetched from the DB (or an instance field). Static prose is never a variable — it is inline in the template, gated by boolean `{{#marker}}` blocks. The markers themselves are booleans derived from DB presence/identity, listed here because they shape the template, but they carry no prose payload.

Legend — **Req**: R = required (always substituted), C = conditional (block may be dropped). **Kind**: scalar (single DB value) / block (multi-line DB-derived markdown) / marker (boolean gating static inline prose).

| Variable | Semantics | Source (file:line / DB field) | Req/Cond | Scalar vs Block |
|---|---|---|---|---|
| `{agent_name}` | Agent display name in header | `agent.name` — `agent_get` (`agent_service.odin:337`; DB `agents.name`) | R | scalar |
| `{instance_id}` | Agent instance id in header | `inst.agent_instance_id` (DB `agent_instances.agent_instance_id`) | R | scalar |
| `{{#chain}}…{{/chain}}` | Wraps the two chain header lines | `chain_ok` (`agent_service.odin:1389`/`:377`) | C | marker |
| `{chain_title}` | Chain title | `chain.title` (DB `task_chains.title`) | C (within `chain`) | scalar |
| `{chain_id}` | Chain id | `chain.chain_id` | C (within `chain`) | scalar |
| `{{#is_coordinator}}` / `{{#is_worker}}` | Booleans selecting the `Coordinator:` line form and the role block | `is_coordinator := chain.coordinator_agent_instance_id == inst.agent_instance_id` (`:1389`, P1 `:395`); `is_worker := chain_ok && !is_coordinator` | C (within `chain`) | marker |
| `{coordinator_instance_id}` | Coordinator's instance id (the only DB value in a worker's `Coordinator:` line) | `chain.coordinator_agent_instance_id` (DB `task_chains.coordinator_agent_instance_id`) | C (within `chain` + `is_worker`) | scalar |
| `{{#agent_identity}}…{{/agent_identity}}` | Wraps the whole `## Agent Identity & Instructions` section (static heading inline) | true when **any** of `template.persona`, `template.instructions`, `agent.instructions` is non-empty (widened from the current `agent.instructions != ""` at `render_agent_identity:1275`) | C | marker |
| `{{#template_persona}}…{{/template_persona}}` | Gates the persona sub-block | `template.persona != ""` (join `agents.template_id` → `templates`) | C (within `agent_identity`) | marker |
| `{template_persona}` | **NEW** — template persona (role/character framing) | `templates.persona` via `content_get_template(service.content, agent.template_id)` (repo `content_repo_sqlite.odin:172`; iface `content_repo.odin:70`) | C | block |
| `{{#template_instructions}}…{{/template_instructions}}` | Gates the template-instructions sub-block | `template.instructions != ""` (same join) | C (within `agent_identity`) | marker |
| `{template_instructions}` | **NEW** — template base instructions | `templates.instructions` (same join/source) | C | block |
| `{{#agent_instructions}}…{{/agent_instructions}}` | Gates the agent-specific instructions sub-block | `agent.instructions != ""` | C (within `agent_identity`) | marker |
| `{agent_instructions}` | Agent-specific instructions (augments/overrides template) | `agent.instructions` (DB `agents.instructions`) | C (within `agent_identity`) | block |
| `{{#project}}…{{/project}}` | Wraps `## Project` block | `project_name != "" || project_path != ""` (`render_project:1283`) | C | marker |
| `{project_name}` | Project name line value | `project.name` (`project_get`; DB `projects.name`) | C | scalar (line omitted if empty) |
| `{project_path}` | Project path | `inst.project_path` or `project.default_path` (`:1418-1425`) | C | scalar |
| `{project_repo}` | Repo URL | `project.repo_url` | C | scalar |
| `{project_vcs}` | VCS kind | `project.vcs_kind` | C | scalar |
| `{project_desc}` | Description | `project.description` | C | scalar |
| `{{#memories}}…{{/memories}}` | Wraps `## Applicable Memories` heading (static prose inline) | ≥1 applicable fact/habit memory (`render_memories_markdown:1311`) | C | marker |
| `{memory_items}` | DB-derived, pre-rendered `### <title>\nType: …\n\n<body>` rows | code loop over `content_list_memories` filtered by `bootstrap_memory_applies` + type ∈ {Fact,Habit} (`:1316-1325`; DB `memories.*`) | C (within `memories`) | block |

### Removed variables (now inline static prose, per the DB-only rule)
| Was a variable | Now | Why |
|---|---|---|
| ~~`{tasks_guidance}`~~ | Inline verbatim in the template (always-on section) | 100% static 7-rule prose (`render_tasks_guidance:1295`) — no DB value. |
| ~~`{role_guidance}`~~ | Inline both texts under `{{#is_coordinator}}` / `{{#is_worker}}` | Static prose; only the selecting booleans are code/DB-derived. |
| ~~`{coordinator_line}`~~ | Inline label `Coordinator: you (coordinator)` / `Coordinator: {coordinator_instance_id}` under the role markers | The label text is static; only `{coordinator_instance_id}` is a DB value. |
| ~~`{ctl_guidance}`~~ | Not in the hub template at all | Fully static, bridge-appended out-of-band (`bootstrap_service.odin:164`) from `bootstrap_ctl_guidance.md`. |

Notes:
- **Every remaining `{variable}` is a DB-fetched value:** `agents.name`, `agent_instances.agent_instance_id`, `task_chains.title`/`chain_id`/`coordinator_agent_instance_id`, `agents.instructions`, `projects.name/repo_url/vcs_kind/description` (+ instance `project_path`), and `{memory_items}` (rendered from `memories` rows). Confirmed against the field reads in `bootstrap_json_for_bridge`/`bootstrap_manifest_json_for_bridge`.
- **Every `{{#marker}}` is a boolean derived from DB presence/identity** (`chain_ok`, `agent.instructions != ""`, project presence, `is_coordinator`/`is_worker`, ≥1 memory) — it gates static prose; it is not prose.
- Memory **rows** remain code-rendered (`{memory_items}`) — a variable-length loop with per-item escaping over DB rows; only the static heading is in the template.

---

## 4. Templating approach (TPL-4)

### Scheme
A minimal, dependency-free two-construct scheme — and, per the DB-only rule, **all prose is inline in the template; the constructs only inject DB values or gate static prose**:
1. **DB-value placeholders:** `{name}` → replaced by the DB-fetched value. Unknown/empty scalars replace to empty string. These are the *only* variables.
2. **Boolean conditional blocks:** `{{#flag}} … {{/flag}}` → the enclosed static-prose span (including its own newlines) is emitted only when `flag` is truthy; otherwise the whole span (and its surrounding blank line) is dropped. `flag` is a code/DB boolean (`chain`, `agent_identity`, `project`, `is_coordinator`, `is_worker`, `memories`, `template_persona`, `template_instructions`, `agent_instructions`, and per-field markers like `project_repo`). Nesting up to 3 is now needed (persona/instructions sub-blocks live inside `{{#agent_identity}}`).
3. **Inverted section (one construct):** `{{^flag}} … {{/flag}}` → emitted only when `flag` is **falsy/empty**. Used once, to print the `### Instructions` heading from the agent-instructions block only when there is no template-instructions block. This is the sole inverted marker; keeping it to one place keeps the mini-engine trivial.

This is a tiny subset of Mustache — intentionally not a full engine. It maps cleanly onto Odin `strings.replace_all` for the DB-value placeholders plus a small block-strip pass for `{{#…}}/{{/…}}`.

### Escaping
- The template is authored as **plain markdown** (no JSON escaping) — this is the whole point vs today's `\\n`/`\\\"` literals.
- Substituted **scalar** values are inserted raw into the markdown body. JSON-escaping happens **later**, once, when the assembled body is written into the transport JSON (P1) or hashed as a fragment (P2) — reuse the existing `write_service_json_string` at the boundary, not inside the template fill.
- Values that themselves contain `{` / `}` (rare; e.g. project description) are safe because substitution is single-pass left-to-right over known placeholder names only (we scan for the known set, not arbitrary braces).

### Shared by both protocol paths
Yes — and this is the primary goal. Load the template once:
```odin
BOOTSTRAP_TMPL :: #load("../../prompts/bootstrap_agents_md.tmpl.md", string)
```
Then a single `render_bootstrap_body(ctx) -> string` fills it: substitute the DB-value placeholders and resolve the boolean blocks. **P1** writes that body via `write_service_json_string` into its inline `content` field; **P2** emits the whole rendered body as one fragment, eliminating the `render_*` helpers. Both call the one renderer → duplication and the P1/P2 divergence (§1.1) disappear. Because all prose is inline in the file, there are no prose inputs to the renderer at all — only DB values and booleans.

### Template sketch (all static prose inline; only DB values are `{placeholders}`)
```markdown
# Agent bootstrap

Agent: {agent_name}
Instance: {instance_id}
{{#chain}}Task chain: {chain_title} ({chain_id})
{{#is_coordinator}}Coordinator: you (coordinator)
{{/is_coordinator}}{{#is_worker}}Coordinator: {coordinator_instance_id}
{{/is_worker}}{{/chain}}
{{#agent_identity}}

## Agent Identity & Instructions
{{#template_persona}}
### Persona
{template_persona}
{{/template_persona}}{{#template_instructions}}
### Instructions
{template_instructions}
{{/template_instructions}}{{#agent_instructions}}
{{^template_instructions}}
### Instructions
{{/template_instructions}}
{agent_instructions}
{{/agent_instructions}}
{{/agent_identity}}
{{#project}}

## Project
This agent is associated with a project. You run in your own managed working directory (not the project directory). Work against the project checkout below when the task requires it.
{{#project_name}}
- Name: {project_name}{{/project_name}}{{#project_path}}
- Path: {project_path}{{/project_path}}{{#project_repo}}
- Repo: {project_repo}{{/project_repo}}{{#project_vcs}}
- VCS: {project_vcs}{{/project_vcs}}{{#project_desc}}
- Description: {project_desc}{{/project_desc}}
{{/project}}

## Working with tasks (REQUIRED)
You MUST track all substantial work as tasks in this task chain. This is not optional.

Rules you must follow:
1. Before starting work, ALWAYS run ./.heimdall/bin/ham-ctl agent tasks fetch to see the current tasks in your chain.
2. Do NOT do meaningful work that is not represented by a task. If a task does not exist for what you are about to do, create one (coordinator) or ask the coordinator to create one.
3. When you begin a task, move it to in_progress: ./.heimdall/bin/ham-ctl agent tasks status --task-id <id> --status in_progress
4. As you make progress, you MUST post a comment on the task describing what you did, what changed, and what is next: ./.heimdall/bin/ham-ctl agent tasks comment --task-id <id> --body "<progress update>". Add a comment at every meaningful step, on blockers, and before handing off for review.
5. When the work is complete, submit it for review: ./.heimdall/bin/ham-ctl agent tasks status --task-id <id> --status in_validation (or ./.heimdall/bin/ham-ctl agent tasks done --task-id <id>). Include a summary comment of what to review.
6. Reviewers vote with ./.heimdall/bin/ham-ctl agent tasks vote --task-id <id> --result lgtm|ngtm --comment "<feedback>". If you receive ngtm, address the feedback, comment what you changed, and re-submit.
7. Use ./.heimdall/bin/ham-ctl agent tasks nudge --task-id <id> to request attention on a stalled task.

Keep task status and comments current at all times so the whole chain reflects real progress.
{{#is_coordinator}}

## You are the COORDINATOR of this task chain (delegate — do not do the work yourself)
Your role is to PLAN and ORCHESTRATE the chain, not to implement it. Doing substantial work yourself instead of delegating is a failure mode.

（…full coordinator prose inlined verbatim from render_role_guidance:1306…）

Read the `coordinator-task-management` skill for the full ham-ctl command reference and the delegation workflow.
{{/is_coordinator}}{{#is_worker}}

## You are a WORKER on this task chain
Execute the tasks ASSIGNED to you. Do not take on work outside your assigned tasks or coordinate the whole chain — that is the coordinator's job. Route questions, blockers, and user-facing messages to the coordinator (chat with chain context is redirected to them automatically). Keep your task status and comments current, and hand off for review with `tasks done` when complete. Read the `worker-task-management` skill for the ham-ctl command reference.
{{/is_worker}}
{{#memories}}

## Applicable Memories
{memory_items}
{{/memories}}
```
Every line above is either literal static prose or a DB-value `{placeholder}` (`{agent_name}`, `{instance_id}`, `{chain_title}`, `{chain_id}`, `{coordinator_instance_id}`, `{template_persona}`, `{template_instructions}`, `{agent_instructions}`, `{project_*}`, `{memory_items}`). The `### Persona` / `### Instructions` sub-headings are static prose gated by their markers. `{{^template_instructions}}…{{/template_instructions}}` is an **inverted** section (emit when the value is empty) so the `### Instructions` heading is printed exactly once — by the template-instructions block if it exists, otherwise by the agent-instructions block. The full 7-rule and coordinator prose is shown/elided only for brevity — in the real file it is inline verbatim. The bridge appends `## Heimdall CLI` from `bootstrap_ctl_guidance.md` **after** this body — not part of the template.

---

## 5. Migration note — how P1 and P2 both consume it (TPL-5)

1. Add `src/prompts/bootstrap_agents_md.tmpl.md` (+ keep `bootstrap_ctl_guidance.md` and the 4 `skills/*/SKILL.md` from the prior report).
2. **Add a templates fetch in the bootstrap builder.** Right after the existing `agent_get` (near `agent_service.odin:1416-1425`, alongside the project lookup), when `agent.template_id != ""` call `iface.content_get_template(service.content, agent.template_id)` to obtain `template.persona` / `template.instructions`. `service.content` is already available (used for memories at `:442`/`:557`/`:580`) so no new dependency is needed. Do the same in the P1 builder (`bootstrap_json_for_bridge`) so both paths have the values. Treat a missing/failed lookup as empty strings (section markers simply go false).
3. Implement `render_bootstrap_body(agent, inst, chain, chain_ok, project fields, template_persona, template_instructions, memory_items, is_coordinator) -> string` in `agent_service.odin`, using `#load(BOOTSTRAP_TMPL)` + the DB-value/boolean-block fill described in §4. Inputs are only DB values and booleans (`is_coordinator`, `is_worker := chain_ok && !is_coordinator`, project/identity/memory presence, and the three identity-source presence flags); the role and task prose is already inline in the template, so `render_role_guidance`/`render_tasks_guidance` are deleted rather than called, and `render_agent_identity` is replaced by the composed persona/instructions blocks. The memory loop still computes the DB-derived `{memory_items}` string.
4. **P1** (`bootstrap_json_for_bridge:330`): delete the inline body writes at `:393-412` and the `write_bootstrap_memory_markdown` call at `:414`; instead compute `body := render_bootstrap_body(...)` and emit it with `write_service_json_string(&b, body)`. Note this also **fixes P1's missing identity section AND the template-persona gap** in one move.
5. **P2** (`bootstrap_manifest_json_for_bridge:1391`): the simplest form makes the whole AGENTS.md a single fragment: `body := render_bootstrap_body(...)`, hash it, emit one `{"section":"body","hash":…}` in the assembly array. This removes `render_header_inline/render_agent_identity/render_project/render_tasks_guidance/render_role_guidance/render_memories_markdown` (`:1275-1345`) as separate section sources. If per-section caching is still desired, keep the fragment split but source each fragment's text from the same template (sliced by block) — not recommended; the single-body form is cleaner and the fragment cache still works on the whole-body hash.
6. Delete the now-duplicate literals; both paths now share one template → the §1.1 divergence (P1 missing Agent Identity) and the §1.2 template-persona/instructions gap are both resolved.
7. Bridge unchanged except that `bridge_bootstrap_ctl_guidance` (`bootstrap_service.odin:164`) is refactored to `#load("../prompts/bootstrap_ctl_guidance.md")` (prior report snippet #8). The append points `:18/:57/:386` stay.

### Risks / caveats
- **`ham-daemon` deprecated:** the wrapper `build_agents_md` path (`wrapper/main.odin:1388`) is a separate, legacy generator; this design targets the live hub/bridge path only.
- **Whitespace fidelity:** the current output has specific `\n\n` section spacing; the template must reproduce it. Author the template with exact blank lines and unit-test the rendered bytes against a captured golden of today's P2 output for a representative agent (chain worker + project + memories) to guarantee no behavioral drift.
- **Conditional blank-line handling:** dropping a block should also drop its leading blank line (as sketched by placing the blank line *inside* the `{{#block}}`), so omitted sections don't leave double blank lines.
- **JSON escaping stays at the transport boundary** — never escape inside the template fill, or you will double-escape.

---

## 6. Summary

- **Principle:** Variables = DB-fetched dynamic values ONLY; all static prose is inline in the template, conditionally gated by boolean `{{#marker}}` blocks.
- **Decision:** 1 bootstrap template (`bootstrap_agents_md.tmpl.md`, containing all static prose inline) + 1 separate bridge CLI file (`bootstrap_ctl_guidance.md`, fully static, not a variable) + 4 separate skill files. Supersedes the "8 separate fragment files" idea while respecting the two real cross-process boundaries.
- **Current gap fixed (TMPL):** template `persona`/`instructions` are **never** injected today (verified §1.2: `create_agent:85` doesn't copy them, `render_agent_identity:1275` renders only `agent.instructions`, no template join anywhere in `src/hub/service/agent/`). Two new DB-backed variables plus a templates fetch close it.
- **DB-backed variables (10):** `{agent_name}` (`agents.name`), `{instance_id}` (`agent_instances.agent_instance_id`), `{chain_title}`/`{chain_id}`/`{coordinator_instance_id}` (`task_chains.*`), **`{template_persona}` (`templates.persona`)**, **`{template_instructions}` (`templates.instructions`)**, `{agent_instructions}` (`agents.instructions`), `{project_name|path|repo|vcs|desc}` (`projects.*`/instance — one project group), and `{memory_items}` (rendered from `memories` rows). No static-prose variables remain.
- **Identity composition (TMPL-3):** inside `## Agent Identity & Instructions`, render **persona first**, then **effective instructions = template.instructions (base) + agent.instructions (appended augmentation)** — compose, never silently drop; full-override alternative rejected as it wastes template content. Presence matrix + sub-headings in §2.1.
- **Boolean markers (gate static prose, not variables):** `{{#chain}}`, `{{#is_coordinator}}`, `{{#is_worker}}`, `{{#agent_identity}}` (widened to persona OR either instructions), `{{#template_persona}}`, `{{#template_instructions}}`, `{{#agent_instructions}}`, `{{#project}}` (+ per-field `{{#project_*}}`), `{{#memories}}`; plus one inverted `{{^template_instructions}}` for the shared `### Instructions` heading.
- **Removed vs the first draft:** `{tasks_guidance}`, `{role_guidance}`, `{coordinator_line}`, `{ctl_guidance}` — all were static prose, now inline (or bridge-owned).
- **Mechanism:** minimal `{db-value}` + `{{#boolean-block}}` substitution, plain-markdown authoring, JSON-escaping only at the transport boundary, one shared renderer consumed by both P1 and P2 — which also eliminates the current inline/render_* duplication and the P1-missing-Agent-Identity divergence.
