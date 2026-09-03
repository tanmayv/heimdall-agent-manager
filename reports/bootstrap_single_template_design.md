# Bootstrap AGENTS.md — Single-Template + Static-Skills Design (BT-1)

**Author:** Prompt Audit Analyst (`inst_18d1bdaecd20148d`)
**Reviewer:** `inst_18d1bdb028c099ec`
**Status:** Design only — user approves before implementation (BT-2..BT-6).
**Supersedes:** the multi-fragment direction in `reports/bootstrap_template_design.md` and `reports/bootstrap_design_delta.md`. IMPL 1's externalized fragment `.md` files fold INTO the single template here; IMPL 2/3/4/5 were cancelled and re-planned as BT-2..BT-6.

All current-behavior claims cite real `file:line` against the checkout at `~/heimdall-hub-rewrite`.

---

## 0. Goal & responsibility split (recap)

Generate `AGENTS.md` from **ONE static templated markdown** file (`src/prompts/bootstrap_agents.md`) plus **DB-derived variables**, and externalize the **skills common to all agents** into **static `SKILL.md` files** in `src/prompts/`. End state of `src/prompts/` = one bootstrap template + a set of static skill files (+ the wrapper-only `guide-agent.md`, which is out of scope here).

| Layer | Responsibility | Today's entry point |
|---|---|---|
| **HUB** | Source of truth ONLY. Serves (a) the static template, (b) each variable value individually, (c) the static skill files — all *fetched-on-change* via the existing ETag/hash conditional flow. | `bootstrap_manifest_conditional` + `render_agent_manifest` (`src/hub/service/agent/agent_service.odin`); handlers `bridge_agent_manifest_handler` / `bridge_blob_handler` (`src/hub/app/wiring.odin:240-241`). |
| **BRIDGE** | Renders `AGENTS.md`: fetch template + variables + role flags, substitute `{placeholders}`, evaluate the minimal role conditionals; **caches** template/variables/static-skill blobs locally. | `bridge_bootstrap_conditional_manifest` (`src/bridge/bootstrap_service.odin:356`), `bridge_bootstrap_assemble_agents_md` (:536), disk cache `src/bridge/bootstrap_cache.odin`. |
| **WRAPPER** | Fetches the finished `AGENTS.md` + skill files from the bridge and writes them into the run dir (`AGENTS.md`/`CLAUDE.md` + `skills/<slug>/SKILL.md`). | `generate_bootstrap_files` (`src/wrapper/main.odin:1257`), `write_skills` (:1548); bridge RPC serving `bridge_bootstrap_fileset_*` (`src/bridge/bootstrap_rpc.odin:35-96`). |

**Consequence (explicit):** output is **NOT byte-identical** to today — memories section removed from `AGENTS.md`, `is_reviewer` role added, template persona/instructions injected, static skills no longer role-gated. BT-5's golden test asserts a **NEW** expected output.

---

## 1. Full draft: `src/prompts/bootstrap_agents.md`

This is the **single static template**. All prose is inline. Three role sections are gated by `is_coordinator` / `is_worker` / `is_reviewer`. Scalar `{placeholders}` are substituted by the bridge. Static section headings stay inline even when their variable is empty (stray empty headings are ACCEPTABLE per the chain spec — no conditional hiding for empty scalars). There is **NO memories section**.

Conditional/among-substitution syntax is defined in §3. The literal template body:

```markdown
# Agent bootstrap

Agent: {agent_name}
Instance: {instance_id}
Task chain: {chain_title} ({chain_id})
{{#is_coordinator}}Coordinator: you (coordinator)
{{/is_coordinator}}{{#is_worker}}Coordinator: {coordinator_id}
{{/is_worker}}{{#is_reviewer}}Coordinator: {coordinator_id}
{{/is_reviewer}}
## Agent Identity & Instructions

### Persona
{template_persona}

### Instructions
{template_instructions}

{agent_instructions}

## Project
This agent is associated with a project. You run in your own managed working directory (not the project directory). Work against the project checkout below when the task requires it.

- Name: {project_name}
- Path: {project_path}
- Repo: {project_repo}
- VCS: {project_vcs}
- Description: {project_description}

{{#is_coordinator}}
## You are the COORDINATOR of this task chain (delegate — do not do the work yourself)
Your role is to PLAN and ORCHESTRATE the chain, not to implement it. Doing substantial work yourself instead of delegating is a failure mode.

What this means in practice:
1. Break the goal into discrete tasks and ASSIGN each to a worker agent. Do not implement features, write the code, run the research, or produce the deliverable yourself — that is the assignees' job.
2. Add the agents you need to the chain (`./.heimdall/bin/ham-ctl agent chains add-agent ...`) and create tasks with an explicit `--assignee <agent_instance_id>`; set order with `--depends-on` and blocking reviewers with `tasks participant --role lgtm_required`.
3. Own the chain description as the canonical design doc (goal, scope, REQ-IDs, task plan, validation strategy). Keep it in sync as scope changes.
4. Be the ONLY point of contact for the user. Team agents route questions/blockers through you; you synthesize and reply. Acknowledge user messages promptly.
5. Enforce review gates: `tasks done` -> `review_ready` -> required reviewers LGTM -> `approved`. The chain is `completed` only when YOU complete it with a verifiable final summary.
6. Only do work yourself for trivial coordination glue. Anything a worker can own, delegate.

Read the `coordinator-task-management` skill for the full ham-ctl command reference and delegation workflow.
{{/is_coordinator}}
{{#is_worker}}
## You are a WORKER on this task chain
Execute the tasks ASSIGNED to you. Do not take on work outside your assigned tasks or coordinate the whole chain — that is the coordinator's job. Route questions, blockers, and user-facing messages to the coordinator (chat with chain context is redirected to them automatically). Keep your task status and comments current, and hand off for review with `tasks done` when complete. Read the `worker-task-management` skill for the ham-ctl command reference.
{{/is_worker}}
{{#is_reviewer}}
## You are a REVIEWER on this task chain
Your job is to REVIEW work handed off by other agents and vote on it — not to implement the tasks yourself. Focus on correctness, scope, and evidence.

What this means in practice:
1. Watch for tasks that reach `review_ready` where you are a required reviewer. Read the task description, the linked REQ-IDs, and the assignee's handoff comment before voting.
2. Verify the work against its acceptance criteria: re-derive load-bearing claims from the actual checkout (do not trust summaries), run the tests/build the task cites, and check that scope was not silently expanded.
3. Vote with evidence: `./.heimdall/bin/ham-ctl agent tasks vote --task-id <id> --result lgtm|ngtm --comment "<specific, actionable feedback>"`. An `ngtm` must say exactly what to fix; an `lgtm` should note what you verified.
4. Keep reviews tight and unblock quickly — a stalled review blocks the chain. Re-review promptly after the assignee addresses `ngtm` feedback.
5. Route questions and disagreements you cannot resolve to the coordinator; do not take over the implementation.

Read the `worker-task-management` skill for the shared ham-ctl command reference (the reviewing subsection applies to you).
{{/is_reviewer}}
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
```

> **Note on the `## Heimdall CLI` block:** it is appended by the **bridge** after the body (`bridge_bootstrap_ctl_guidance`, `src/bridge/bootstrap_service.odin:206-207`) in three call sites incl. the provider-test path that has no hub body. It is fully static and cross-process, so it stays a **bridge-owned appendix** (optionally its own `src/prompts/bootstrap_ctl_guidance.md` #load-ed by the bridge). It is **not** a template variable and is intentionally omitted from the template body above.

---

## 2. Variable list + source mapping

Every variable is DB-derived, individually fetchable, fetched-on-change, and cached at the bridge. "Where from" cites the current hub producer/DB field; "Maps to" is the template slot.

| Variable | Template slot | Source in hub (current code) |
|---|---|---|
| `agent_name` | `Agent: {agent_name}` | `agent.name` — used in header today at `render_header_inline` (`agent_service.odin:1372`, called at :1443) / bridge `bridge_bootstrap_render_header` (`bootstrap_service.odin:511`, from descriptor `agent_name`). |
| `instance_id` | `Instance: {instance_id}` | `inst.agent_instance_id`; bridge descriptor `instance_id` (`bootstrap_service.odin:330`). Per-instance — bridge-side today. |
| `chain_title` | `Task chain: {chain_title} ...` | `chain.title` via `taskchain_get_chain` (`agent_service.odin` manifest path); bridge descriptor `chain_title` (`bootstrap_service.odin:337`). |
| `chain_id` | `... ({chain_id})` | `chain.chain_id`; descriptor `chain_id` (`bootstrap_service.odin:336`). |
| `coordinator_id` | `Coordinator: {coordinator_id}` (worker/reviewer) | `chain.coordinator_agent_instance_id`; descriptor `coordinator_id` (`bootstrap_service.odin:335`). |
| `template_persona` | `### Persona\n{template_persona}` | `templates.persona` (schema `migrations/002_owner_scoped_core.sql:225-226`; struct `domain/content.odin:148`) via `content_get_template` (`content_repo/iface content_repo.odin:70`, sqlite `content_repo_sqlite.odin:148`). Fetched by `agent.template_id`. **Not injected today — this is the gap.** |
| `template_instructions` | `### Instructions\n{template_instructions}` | `templates.instructions` (same schema/struct/proc as above). **Not injected today.** |
| `agent_instructions` | appended after `{template_instructions}` | `agent.instructions` (`domain/agent.odin:25`) — the ONLY identity source rendered in the pre-IMPL-2 baseline (`render_agent_identity`, `agent_service.odin:1250`; the checkout now carries the cancelled-IMPL-2 signature which composes all three — that composition logic is reused by this template design). |
| `project_name` | `- Name: {project_name}` | `project.name` via `project_get`; set in `render_project` args (`agent_service.odin` manifest builders :1453 and :1791). |
| `project_path` | `- Path: {project_path}` | `project.default_path` / `inst.project_path` (manifest builders). |
| `project_repo` | `- Repo: {project_repo}` | `project.repo_url`. |
| `project_vcs` | `- VCS: {project_vcs}` | `project.vcs_kind`. |
| `project_description` | `- Description: {project_description}` | `project.description`. |
| `is_coordinator` (flag) | `{{#is_coordinator}}` | `chain.coordinator_agent_instance_id == inst.agent_instance_id` (`agent_service.odin` manifest builders); bridge has it as `d.role == "coordinator"` (`bootstrap_service.odin:515`). |
| `is_worker` (flag) | `{{#is_worker}}` | derived: chain member AND not coordinator AND not reviewer. Today the only two roles are coordinator/worker (`descriptor.role` default `"worker"`, `bootstrap_service.odin:346`). |
| `is_reviewer` (flag) | `{{#is_reviewer}}` | **NEW.** Derived from the agent's chain role = reviewer. See §8 open decision on how role is resolved (task `reviewer_refs` vs a per-instance role). |

**Key mapping change vs today (§1 of the old delta):** today the header is rendered **bridge-side** from the descriptor and the identity/project/role bodies are **hub fragments**. In the new model the hub emits the same values as **individual variables** and the bridge does ALL substitution against the single template. The header values (`agent_name`, `instance_id`, `chain_*`, `coordinator_id`) are already bridge-local in the descriptor, so they need no new hub fetch; the DB-only additions the hub must now expose per-variable are `template_persona`, `template_instructions`, and the `project_*` set (already computed in the manifest builders).

---

## 3. Conditional + substitution syntax (bridge-evaluated)

Keep it minimal and unambiguous. Two constructs only:

1. **Scalar substitution:** `{name}` → replaced by the variable's value (empty string if unset). Single braces. No nesting, no expressions. Unknown `{name}` → replaced with empty string (fail-soft) and logged once.
2. **Role section:** `{{#flag}} ... {{/flag}}` where `flag ∈ {is_coordinator, is_worker, is_reviewer}` — the ONLY three flags. The block's inner text is emitted verbatim (after scalar substitution) iff the flag is true; otherwise the whole block including its delimiters is dropped. No `{{^inverted}}`, no arbitrary booleans, no nesting of `{{#}}` blocks.

Rationale for this exact subset:
- Scalars use single `{}`; sections use double `{{#}}/{{/}}` — visually distinct, trivial to scan for, and cannot collide (a role flag never appears as a scalar).
- Exactly three known flags means the bridge can evaluate with three booleans from the descriptor — no general expression engine, no template-injection surface.
- Empty scalars are NOT hidden (spec: stray empty headings acceptable). This means the parser never has to hide surrounding lines — it only substitutes text. Only the three explicit role blocks are conditional.

**Whitespace rule:** a role block's opening `{{#flag}}` and closing `{{/flag}}` each consume the single trailing newline immediately after the tag when the tag sits alone on its line, so a dropped block leaves no blank line and a kept block starts cleanly. (Implementation detail for BT-3; called out here so the golden output in §7 is deterministic.)

---

## 4. HUB contract (BT-2)

The hub already serves a **content-addressed manifest + per-hash blobs** with ETag/epoch conditional semantics. The single-template model reuses that machinery unchanged in shape; only the *set of items* changes.

**4.1 What the hub serves**
- **The static template** `bootstrap_agents.md` — a content-addressed blob. Its hash changes only when the template file itself changes (compile-time `#load` const, hashed once). Served as one manifest entry `{"kind":"AGENTS_TEMPLATE","hash":...}`.
- **Each variable value individually** — the hub emits a `variables` array in the manifest: `[{"name":"template_persona","hash":H1},{"name":"project_name","hash":H2},...]`, each value pushed into the in-process blob cache (`hub_fragment_cache_put`, `agent_service.odin:1398`) exactly like fragments are today, so the per-hash blob GET (`resolve_single_blob`, `agent_service.odin:1644`) serves them with no re-render. Role flags travel as tiny value blobs too (`"true"`/`""`) OR inline in the manifest (they are one byte) — recommend **inline** in the manifest to avoid three extra blob round-trips.
- **The static skill files** — sourced via **build-time codegen (Option B, per coordinator DM 2026-09-03)**: a codegen step scans `src/prompts/skills/*/SKILL.md` and generates an Odin file (e.g. `src/hub/service/agent/static_skills_gen.odin`) with one `#load` per file plus a `STATIC_SKILLS: []Static_Skill` slice (`{slug, content}`). The hub iterates `STATIC_SKILLS` in place of today's hardcoded `bootstrap_coordinator_task_skill`/`bootstrap_worker_task_skill`/`bootstrap_fallback_skill` procs (`agent_service.odin:385-401`). Each entry is hashed + cached and listed in the existing `skills` array (`{"kind":"SKILL","name":slug,"hash":...}`) exactly as skills are listed today (`render_agent_manifest` skills loop, `agent_service.odin:1826-1841`). **Reconciliation (per review):** the content-addressed blob the hub serves to the bridge is produced FROM the compile-time-embedded `STATIC_SKILLS` slice — NOT from a runtime scan of `src/prompts/skills/`. The folder is an input to the *codegen* (build time); at *run* time the hub only ever reads the embedded `#load`ed strings, hashes them, and serves those bytes — identical to how it embeds the template and every fragment today (`#load` consts, `agent_service.odin:1225-1232`). Because the static set is the SAME for ALL agents (no role gating), these hashes are identical across agents and dedupe naturally in the bridge cache. Add/remove a skill = drop a `.md` in the folder, re-run codegen, recompile (see §7 for the codegen + flake wiring).

**4.2 render_* procs become per-variable producers**
Today `render_agent_identity` / `render_project` / role helpers each emit a *composed fragment body*. Under BT-2 they are decomposed into **value producers**:
- `render_project(...)` (`agent_service.odin:1306`) → stops emitting the heading/prose (that lives in the template) and instead the manifest builder emits the five `project_*` values it already computes.
- `render_agent_identity(...)` (`agent_service.odin:1250`) → replaced by three values: `template_persona`, `template_instructions` (from `content_get_template(service.content, agent.template_id)` via `bootstrap_template_identity_fields`, `agent_service.odin:1298-1303`), and `agent_instructions` (`agent.instructions`). The composition/precedence moves into the template layout (§1) + bridge substitution.
- Role helpers (`render_role_guidance`, `agent_service.odin:1328`) → gone from the hub; the role prose is in the template and the hub emits only the boolean `is_coordinator`/`is_worker`/`is_reviewer`.
- `render_header_inline` (`agent_service.odin:1372`) → the hub can drop it entirely; the header prose is in the template and the header values are already bridge-local in the descriptor (see §2). (This finally kills the hub/bridge header duplication the delta flagged.)

**4.3 Fetched-on-change**
The `bootstrap_version` = `sha256(concat of input hashes in stable order)` (`render_agent_manifest` version builder, `agent_service.odin:1851-1863`) now folds the template hash + each variable hash + each static-skill hash. Adding/removing/changing any of them changes the version → new ETag → `If-None-Match` miss → bridge refetches only the blobs whose hashes it lacks (`bridge_bootstrap_fetch_missing_blobs`, `bootstrap_service.odin:429`). Warm/unchanged launches still short-circuit to **304** via the content epoch (`bootstrap_manifest_conditional`, `agent_service.odin:1704`; `manifest_render_count` guard). No new transport is introduced — same handlers/wiring (`wiring.odin:239-242`).

---

## 5. BRIDGE contract (BT-3)

The bridge already: does the conditional manifest GET, fetches missing blobs, assembles the doc, and persists a per-key manifest+ETag + an LRU blob cache on disk. Changes:

- **Fetch:** `bridge_bootstrap_conditional_manifest` (`bootstrap_service.odin:356`) is unchanged in transport; the manifest it parses now contains the template hash + `variables` array + `skills` array. It fetches any missing hashes via `bridge_bootstrap_fetch_missing_blobs` (:429) into the disk cache (`bootstrap_cache_put`, `bootstrap_cache.odin:175`).
- **Render (replaces assemble):** `bridge_bootstrap_assemble_agents_md` (`bootstrap_service.odin:536`) is rewritten from "concat header + fragment bodies + ctl guidance" to **"load template blob → substitute {scalars} from the variable blobs + descriptor header values → evaluate the three `{{#role}}` blocks from the descriptor role → append ctl guidance"** (§3). The header values come from the descriptor (`agent_name`/`instance_id`/`chain_*`/`coordinator_id`, `bootstrap_service.odin:310-343`); the DB variables come from the fetched blobs. `bridge_bootstrap_render_header` (:509) is deleted (its job moves into the template + substitution).
- **Cache:** unchanged — the same disk cache holds the template blob, the variable-value blobs, and the static-skill blobs, all keyed by content hash (`bootstrap_cache.odin`). Static skills dedupe across agents automatically (same hashes). Confirmed caching is at the **bridge** (not just hub): the per-key manifest+ETag store (`bootstrap_manifest_store_save/load`, `bootstrap_cache.odin:114-127`) + the content-hash blob store give a full local cache so a 304 needs zero blob fetches.
- **Serve to wrapper:** the finished file set (`AGENTS.md`, each `skills/<slug>/SKILL.md`, ctl shim, manifest json) is built once (`bridge_bootstrap_build_file_set`, `bootstrap_service.odin:594`) and exposed over the wrapper RPCs (`bridge_bootstrap_fileset_list_json` / `bridge_bootstrap_fileset_file_json`, `bootstrap_rpc.odin:63/96`). Skills now come from the `STATIC_SKILLS` codegen set (§7) instead of role-chosen hardcoded strings; the bridge just caches + serves whatever skill blobs the manifest lists.

---

## 6. WRAPPER contract (BT-4)

The wrapper writes bootstrap files into the run dir. Today `generate_bootstrap_files` (`src/wrapper/main.odin:1257`) BUILDS the AGENTS.md itself (`build_agents_md`) and materializes skills from DB memories via `write_skills` (:1548). Under the new model the **bridge** produces the finished bytes, so the wrapper's job narrows to *fetch + write*:

- Fetch the finished file set from the bridge RPCs (`fileset_list` then `fileset_file` per file, `bootstrap_rpc.odin:63/96`) instead of composing locally.
- Write `AGENTS.md`/`CLAUDE.md` (name still chosen by provider: `CLAUDE.md` for the claude profile, else `AGENTS.md`, `wrapper/main.odin:~1276-1283`) and each `skills/<slug>/SKILL.md` under `skills/` (`write_skills` layout, :1548) — but the CONTENT is the bridge's bytes, wrapper does not re-render.
- Keep `cleanup_removed_bootstrap_files` + `write_manifest` (:1327-1329) so stale managed files are removed.
- `MEMORY.md` and DB **skill-type memories** remain the wrapper's existing behavior (they are per-agent, from `fetch_all_active_memories`, `wrapper/main.odin:1270`) — see §9 boundary. `guide-agent.md` stays a wrapper-only `#load` (`wrapper/main.odin:~1319`), unaffected.

---

## 7. Static skills — Option B build-time codegen (proposal — user approves)

Today the "common" skills are **hardcoded Odin strings** and chosen by role:
- `bootstrap_coordinator_task_skill` → slug `coordinator-task-management` (`agent_service.odin:385`).
- `bootstrap_worker_task_skill` → slug `worker-task-management` (`agent_service.odin:392`).
- `bootstrap_fallback_skill` → slug `heimdall-ctl-communication` (`agent_service.odin:397`).

Per the user DECISION, **ALL agents get the SAME full static set — no role gating**. Proposed `src/prompts/skills/` file set (slug = directory name, `SKILL.md` inside):

| Slug | Source today | Notes |
|---|---|---|
| `coordinator-task-management` | `bootstrap_coordinator_task_skill` string (`agent_service.odin:385`) | Externalize verbatim to `src/prompts/skills/coordinator-task-management/SKILL.md`. Now given to everyone (a worker/reviewer can read how coordination works). |
| `worker-task-management` | `bootstrap_worker_task_skill` string (`agent_service.odin:392`) | Externalize verbatim. Contains the shared reviewing subsection the reviewer prose references. |
| `heimdall-ctl-communication` | `bootstrap_fallback_skill` string (`agent_service.odin:397`) | Externalize verbatim — CLI/startup/chat basics for all agents. |

**Recommendation:** ship exactly these **three** as the static common set (they are the complete current hardcoded inventory). Two open sub-questions for the user (§8): (a) whether to ALSO promote `heimdall-task-planning` (already a real dir under `skills/heimdall-task-planning`, not one of the hardcoded three) into this static set, and (b) whether a dedicated `reviewer-task-management` skill should be authored to accompany the new reviewer role, or the reviewer keeps using the `worker-task-management` reviewing subsection (my draft prose in §1 uses the latter to avoid inventing more prose before approval).

**7.1 Migration list — today's hardcoded skills → externalized files**

| # | Current hardcoded proc (`agent_service.odin`) | New file | Also referenced at | Action |
|---|---|---|---|---|
| 1 | `bootstrap_coordinator_task_skill` :385 | `src/prompts/skills/coordinator-task-management/SKILL.md` | selected at :1490, :1826 | copy the Odin string literal verbatim (unescape `\n`) into the `.md`; delete the proc in BT-6. |
| 2 | `bootstrap_worker_task_skill` :392 | `src/prompts/skills/worker-task-management/SKILL.md` | selected at :1492, :1828 | same. |
| 3 | `bootstrap_fallback_skill` :397 | `src/prompts/skills/heimdall-ctl-communication/SKILL.md` | fallback at :366, :1511 | same. |

The role-selection logic that today picks coordinator-vs-worker (`if is_coordinator ... else ...` at :1489-1493 and :1825-1829) and the `len(skills_list)==0` fallback (:1510-1515) are all **removed** — replaced by "append every entry of `STATIC_SKILLS`". DB skill-type memories continue to be appended per-agent alongside the static set (§9).

**7.2 Codegen mechanism (Option B, per coordinator DM)**

Because Odin `#load` needs literal, compile-time-known paths, an arbitrary folder of skills cannot be `#load`ed by a loop. A small **codegen** step bridges that:

1. A generator (a tiny Odin program under `tools/` or a shell/awk script) scans `src/prompts/skills/*/SKILL.md`.
2. It writes `src/hub/service/agent/static_skills_gen.odin` (checked-in-or-generated) containing:
   ```odin
   package agent
   Static_Skill :: struct { slug: string, content: string }
   STATIC_SKILLS := []Static_Skill{
       {"coordinator-task-management", #load("../../../prompts/skills/coordinator-task-management/SKILL.md", string)},
       {"worker-task-management",      #load("../../../prompts/skills/worker-task-management/SKILL.md", string)},
       {"heimdall-ctl-communication",  #load("../../../prompts/skills/heimdall-ctl-communication/SKILL.md", string)},
   }
   ```
   (slug = the skill directory name; one `#load` line per file; `#load` paths relative to the generated file's location, matching the existing convention at `agent_service.odin:1225-1232`.)
3. The hub replaces the three hardcoded procs with `for s in STATIC_SKILLS { hash := bootstrap_fragment_hash(s.content); hub_fragment_cache_put(hash, s.content); append(&skills_list, {name=s.slug, hash=hash}) }` at both builder sites (:1489-1515, :1825-1841).

**Add/remove a skill** = drop/delete a `SKILL.md` in the folder, re-run codegen, recompile. No Odin edit by hand.

**7.3 Flake wiring (before `odin build`)**

The codegen must run **before** every hub compile so the generated file is current. In `flake.nix`, both hub build phases run `odin build ${srcDir}` inside `buildPhase` after `runHook preBuild` (`flake.nix:25-28` for `mkOdinPackage`; `:43-46` for `mkOdinPackageWithRuntime`, which builds `ham-hub` at `:145`). Wire the generator into `preBuild` (or as an explicit line immediately before `odin build`) for the `ham-hub` derivation (and the golden-test derivation `:156` if it also compiles the agent package). Concretely: add a step like `odin run tools/gen_static_skills -- src/prompts/skills src/hub/service/agent/static_skills_gen.odin` (or the script equivalent) ahead of the hub `odin build`. Because `src = ./.` copies the whole tree into the sandbox (`flake.nix:21/38`), the `src/prompts/skills/` inputs are present at build time. Decision for the user (§8): commit the generated file to the repo (simpler, reviewable diffs) vs generate-in-sandbox-only (no checked-in artifact). Recommend **commit + regenerate-and-verify-clean in CI** so local `odin build` without nix still works.

**7.4 Folder layout + slug/frontmatter convention (gap (a))**

Layout: `src/prompts/skills/<slug>/SKILL.md` — one directory per skill, the directory name IS the slug, the file is always `SKILL.md`. This mirrors both the run-dir output shape the wrapper writes (`skills/<slug>/SKILL.md`, `write_skills` layout `wrapper/main.odin:1548`) and the existing checked-in example `skills/heimdall-task-planning/SKILL.md`.

Frontmatter: each `SKILL.md` MUST begin with YAML frontmatter delimited by `---` containing at minimum `name:` and `description:` (the format the current provider skill loader and `bootstrap_skill_file_content` already expect — it passes any body already starting with `---\n` through verbatim, `agent_service.odin:409`; example `skills/heimdall-task-planning/SKILL.md:1-9`). The three hardcoded skills ALREADY embed exactly this frontmatter inside their string literals (e.g. `bootstrap_coordinator_task_skill` content starts `---\nname: coordinator-task-management\ndescription: ...\n---`, `agent_service.odin:386`), so externalizing them is a verbatim copy — the frontmatter comes along and no wrapper/loader change is needed. Convention rule for the codegen: **slug (directory name) MUST equal the frontmatter `name:`** so the manifest `name` and the run-dir path agree; the generator asserts this and fails the build on mismatch.

DB skill-type memories are **out of this set** — see §9.

---

## 8. New expected output — sample rendered AGENTS.md

Concrete render for a **coordinator** instance, in a chain, with a project, and a template that has persona + instructions, and the agent has its own instructions. (Ctl guidance appendix shown; skills are separate files, not shown inline.)

```markdown
# Agent bootstrap

Agent: Backend Agent
Instance: inst_abc123
Task chain: Bootstrap refactor (chain_xyz789)
Coordinator: you (coordinator)

## Agent Identity & Instructions

### Persona
You are Odin, a meticulous systems engineer.

### Instructions
Follow the house style. Write tests before code.

Prefer small, reviewed diffs. Cite file:line in every claim.

## Project
This agent is associated with a project. You run in your own managed working directory (not the project directory). Work against the project checkout below when the task requires it.

- Name: Heimdall
- Path: ~/heimdall-hub-rewrite
- Repo: git@example.com:heimdall.git
- VCS: git
- Description: Enterprise multi-agent orchestrator.

## You are the COORDINATOR of this task chain (delegate — do not do the work yourself)
Your role is to PLAN and ORCHESTRATE the chain, not to implement it. Doing substantial work yourself instead of delegating is a failure mode.

What this means in practice:
1. Break the goal into discrete tasks and ASSIGN each to a worker agent. Do not implement features, write the code, run the research, or produce the deliverable yourself — that is the assignees' job.
2. Add the agents you need to the chain (`./.heimdall/bin/ham-ctl agent chains add-agent ...`) and create tasks with an explicit `--assignee <agent_instance_id>`; set order with `--depends-on` and blocking reviewers with `tasks participant --role lgtm_required`.
3. Own the chain description as the canonical design doc (goal, scope, REQ-IDs, task plan, validation strategy). Keep it in sync as scope changes.
4. Be the ONLY point of contact for the user. Team agents route questions/blockers through you; you synthesize and reply. Acknowledge user messages promptly.
5. Enforce review gates: `tasks done` -> `review_ready` -> required reviewers LGTM -> `approved`. The chain is `completed` only when YOU complete it with a verifiable final summary.
6. Only do work yourself for trivial coordination glue. Anything a worker can own, delegate.

Read the `coordinator-task-management` skill for the full ham-ctl command reference and delegation workflow.

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

## Heimdall CLI

Use the managed CLI at `./.heimdall/bin/ham-ctl` for Heimdall actions from this run directory. Examples:

```bash
./.heimdall/bin/ham-ctl agent start-success
./.heimdall/bin/ham-ctl agent chat read
./.heimdall/bin/ham-ctl agent chat send --body "..."
```

The bridge also exports `HEIMDALL_AGENT_TOKEN` and `HEIMDALL_AGENT_INSTANCE_ID` in your process environment.
```

**Deltas from today (call-outs):**
1. **Memories removed** — there is NO `## Applicable Memories` section in `AGENTS.md` anymore (memories are fetched separately; DB skill memories still become skill files).
2. **Template persona/instructions injected** — the `### Persona` + `### Instructions` (template base then agent-appended) now appear; today they are silently dropped (`render_agent_identity` renders only `agent.instructions`, `agent_service.odin:1250` baseline).
3. **`is_reviewer` role added** — a reviewer instance gets the new `## You are a REVIEWER ...` section instead of the worker/coordinator one.
4. **Static skills no longer role-gated** — every agent receives all three static skill files from `STATIC_SKILLS` (§7 codegen), not the single role-chosen one (`bootstrap_coordinator_task_skill` vs `bootstrap_worker_task_skill`).
5. **Header single-sourced** — header prose now lives in the template; the hub `render_header_inline` and bridge `bridge_bootstrap_render_header` duplication is removed (bridge substitutes header values into the template).

---

## 9. Boundary: static skills vs DB skill-type memories (explicit)

- **Static skills** (this design): the same fixed set for every agent, authored as `src/prompts/skills/<slug>/SKILL.md`, embedded at build time via the `STATIC_SKILLS` codegen (§7), served by the hub as content-addressed blobs, cached by the bridge, written by the wrapper. Independent of the agent's memories.
- **DB skill-type memories** (unchanged): per-agent, resolved from `content_list_memories` + scope filters and rendered via `render_skill` (`agent_service.odin:1366`) / wrapper `write_skills` (`wrapper/main.odin:1548`). These continue to be materialized per-agent exactly as today.
- **Collision rule:** if a DB skill memory has the same slug as a static skill, the static file wins for the common set and the DB one is skipped (or namespaced) — flag for BT-3/BT-4 to implement deterministically; recommend static-wins to keep the common set stable.

---

## 10. Open decisions to surface to the user (via coordinator)

1. **Identity ordering** (§1 identity section): the draft uses **persona → template_instructions → agent_instructions** (compose/append, agent augments the template base). Confirm this order, or prefer agent-first, or a hard override. (My cancelled IMPL 2 implemented exactly this compose order with an 8-row presence matrix; reusing it here.)
2. **Reviewer prose wording** (§1 `{{#is_reviewer}}` block): the drafted reviewer section is new — user should approve/adjust the wording and whether it should point at `worker-task-management` or a dedicated reviewer skill.
3. **Static skill file set** (§7): confirm the three (`coordinator-task-management`, `worker-task-management`, `heimdall-ctl-communication`); decide (a) whether to also include `heimdall-task-planning`, and (b) whether to author a dedicated `reviewer-task-management` skill.
3b. **Codegen artifact** (§7.3): commit the generated `static_skills_gen.odin` to the repo (recommended — reviewable diffs, local `odin build` works without nix) vs generate-in-sandbox-only. Confirm the generator form (tiny Odin tool under `tools/` vs shell/awk) and its `flake.nix` `preBuild` wiring point.
4. **Role flags as blobs vs inline** (§4.1): recommend inlining the three role booleans in the manifest (one byte each) rather than three extra blob fetches — confirm acceptable.
5. **Empty-scalar headings** (§1/§3): spec says stray empty headings are acceptable; confirm we do NOT hide e.g. an empty `### Persona` or empty `## Project` field lines. (Current draft leaves them visible.)
6. **`is_reviewer` derivation** (§2): confirm how a reviewer instance is identified — from the chain task `reviewer_refs`/participant role, or a per-instance role field. This affects BT-2's flag producer.

---

## 11. Cross-references
- Identity composition/precedence + 8-row presence matrix: `reports/bootstrap_template_design.md §2.1` (reused for §1/§10.1).
- Current refactored architecture (manifest/fragment, bridge assembly, header duplication, dead code): `reports/bootstrap_design_delta.md` (RV-1..RV-5).
- Prompt inventory + daemon-only/unused files for BT-6 cleanup: `reports/prompts_audit.md`.

*Design only — no code changed by this task. Implementation is BT-2..BT-6 after user approval.*
