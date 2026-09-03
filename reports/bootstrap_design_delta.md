# Bootstrap Design Delta — Re-verification vs Refactored Manifest/Fragment Code

**Task:** `task_18d1c6a52a3ef745` (chain `chain_18d1bd65159d673c`)
**Date:** 2026-09-03
**Analyst:** Prompt Audit Analyst (`inst_18d1bdaecd20148d`)
**Amends:** `reports/bootstrap_prompt_snippets.md`, `reports/bootstrap_template_design.md`
**Type:** VERIFICATION / DELTA (no code changes). All line numbers re-derived from the CURRENT files.

> **Why this doc:** the bootstrap code was refactored after the three design reports were written. The prior reports described a hub that emitted the **whole AGENTS.md** (protocol-1 single-content builder `bootstrap_json_for_bridge` + protocol-2 fragments). That is no longer accurate. This delta re-maps the flow, marks each prior claim STILL-TRUE / CHANGED / STALE with corrected refs, re-confirms the template persona/instructions gap, and re-targets the template proposal onto the new architecture.

---

## RV-1. Current end-to-end bootstrap flow (re-derived)

### Two hub endpoints now exist (`src/hub/app/wiring.odin:239-242`)
| Route | Handler | Purpose |
|---|---|---|
| `GET /api/v1/bridge/agent-instances/*/bootstrap` | `bridge_instance_bootstrap_handler` (`bridge_handlers.odin:507`) | **Instance-keyed** manifest. Calls `bootstrap_manifest_json_for_bridge` (`agent_service.odin:1333`). Emits a `header` **inline** fragment (per-instance) + section hashes. |
| `GET /api/v1/bridge/agents/*/bootstrap-manifest` | `bridge_agent_manifest_handler` (`bridge_handlers.odin:529`) | **Agent-keyed**, conditional/ETag manifest. Calls `bootstrap_manifest_conditional` (`agent_service.odin:1620`) → `render_agent_manifest` (`agent_service.odin:1683`). **No header fragment** (no per-instance data). |
| `GET /api/v1/bridge/blobs/*` | `bridge_blob_handler` (`bridge_handlers.odin:594`) | Serves ONE immutable content-addressed fragment by hash (`resolve_single_blob`). |
| `POST /api/v1/bridge/blobs` | `bridge_blobs_handler` (`bridge_handlers.odin:580`) | Optional cold-start batch warmup (`resolve_blobs_json`). |

### Primary path = agent-keyed conditional manifest (WS launch)
The live launch path is the **agent-keyed conditional** one:
1. **Bridge** receives an enriched `launch_agent` WS payload and parses a per-instance `Bridge_Bootstrap_Descriptor` (`bootstrap_service.odin:310`, parsed by `bridge_bootstrap_descriptor_from_launch:327`). The descriptor carries `agent_name`, `instance_id`, `role`, `coordinator_id`, `chain_id`, `chain_title`, `project_*`, etc. (`hub_runtime_client.odin:528`).
2. `bridge_bootstrap_launch_materialize` (`bootstrap_service.odin:677`, called at `hub_runtime_client.odin:530`) → `bridge_bootstrap_conditional_manifest` (`:356`) issues ONE conditional `GET /api/v1/bridge/agents/{agent_id}/bootstrap-manifest?role=&provider=&project=` with `If-None-Match` from the persisted per-key ETag (`:365-380`).
   - **304 HIT** → reuse cached manifest, fetch zero blobs.
   - **200 MISS** → persist new manifest+ETag, then per-hash blob GETs for only the hashes missing from disk.
3. **Hub** side of that endpoint: `bootstrap_manifest_conditional` (`agent_service.odin:1620`) checks a per-`(agent_id,role,provider,project)` cache keyed by `bootcache.content_epoch()`; on miss it calls `render_agent_manifest` (`:1683`) which renders each section via `render_agent_identity:1217`, `render_project:1225`, `render_tasks_guidance:1237`, `render_role_guidance:1245`, `render_memories_markdown_agent:1838`, hashes each (`bootstrap_fragment_hash:1209`), pushes the body into the in-process blob cache (`hub_fragment_cache_put:1315`), and computes a `bootstrap_version = sha256(ordered fragment hashes)` used as the ETag.
4. **Bridge assembles the AGENTS.md locally** — `bridge_bootstrap_assemble_agents_md` (`bootstrap_service.odin:536`):
   - renders the **header locally** from the descriptor via `bridge_bootstrap_render_header` (`:509`),
   - walks the manifest `assembly` array, emitting each section (an `inline` literal OR a `hash` resolved from the disk/blob cache via `bootstrap_cache_get`),
   - appends `bridge_bootstrap_ctl_guidance()` (proc `:206`, appended `:573`).
   Skills are written as separate files; the file set is built by `bridge_bootstrap_build_file_set` (`:594`) and published to the wrapper via RPC (the bridge does NOT write the run_dir; the wrapper materializes it — WRP-1).

### Secondary/legacy paths (still present)
- **Instance-keyed manifest** `bootstrap_manifest_json_for_bridge` (`agent_service.odin:1333`) + the CLI `--bootstrap-fetch` materializer `bridge_bootstrap_fetch_manifest_and_materialize` (`bootstrap_service.odin:692`, called from `main.odin:137`). This path emits/consumes a `header` inline fragment from the hub and assembles inline (`:737+`). It is the fallback/CLI route; the WS launch path uses the agent-keyed conditional flow above.
- **Legacy content fetch** `bridge_bootstrap_fetch_and_materialize` (`bootstrap_service.odin:52`) is now only the last-ditch fallback (`main.odin:138`).
- **Dead code:** `write_bootstrap_skill_fields` (`agent_service.odin:331`) and `write_bootstrap_memory_markdown` (`:487`) are defined but **never called** anywhere in `src/` — leftovers from the removed protocol-1 single-content bundle. Safe to delete.

### Where the body is authored vs assembled (the key architectural shift)
- **Authored (hub):** each *section* fragment (`agent_identity`, `project`, `tasks_guidance`, `role_guidance`, `memories`) as an independent, content-addressed blob. The hub no longer produces the whole AGENTS.md string.
- **Assembled (bridge):** the final AGENTS.md = locally-rendered header + fragments (in manifest order) + locally-appended ctl guidance.

---

## RV-2. Delta table — prior claims vs current code

| Prior claim (report) | Status | Corrected current reality + ref |
|---|---|---|
| "Two hub builders: P1 `bootstrap_json_for_bridge:330` (inline JSON bundle) and P2 `bootstrap_manifest_json_for_bridge`" | **STALE** | `bootstrap_json_for_bridge` is **removed**. The instance handler comment states "the legacy bundle response has been removed (HUB-4)" (`bridge_handlers.odin:514`). There is no single-content builder anymore. |
| "P1 emits the whole AGENTS.md body inline at `:393-412`; memories at `:578-591`" | **STALE** | Those procs/lines no longer exist. Body is now fragment-rendered by `render_agent_manifest:1683` / `bootstrap_manifest_json_for_bridge:1333`. |
| "P1 vs P2 hold byte-duplicated prose (core drift risk)" | **CHANGED (mostly resolved)** | There is now **one** fragment source set (`render_*` helpers). The remaining duplication is narrower: the **header** logic exists twice — hub `render_header_inline` (`agent_service.odin:1289`) for the instance-keyed path AND bridge `bridge_bootstrap_render_header` (`bootstrap_service.odin:509`) for the agent-keyed path. Section prose (identity/project/tasks/role/memories) is single-sourced in the hub `render_*` procs. |
| "P1 omits `## Agent Identity & Instructions` while P2 emits it — a divergence" | **STALE (no longer applicable)** | With P1 gone there is a single fragment path; `render_agent_identity` (`:1217`) is included by both `bootstrap_manifest_json_for_bridge` (`:1362`) and `render_agent_manifest` (`:1699`). No P1/P2 identity divergence remains. |
| "The bridge just writes whatever `content` the hub returns; bridge needs no change" | **CHANGED** | The bridge now **assembles** the AGENTS.md from fragments and **renders the header locally** from the descriptor (`bridge_bootstrap_assemble_agents_md:536` + `bridge_bootstrap_render_header:509`). It is an active participant, not a passthrough writer. |
| "Header is rendered hub-side (`render_header_inline`) — variables `{agent_name}/{instance_id}/{chain_title}/{chain_id}/{coordinator_line}` are hub DB values" | **CHANGED** | On the **primary** (agent-keyed) path the header is rendered **bridge-side** from the `Bridge_Bootstrap_Descriptor` (`bootstrap_service.odin:509`), whose values arrive in the launch WS payload — the bridge does not query hub tables for them. On the instance-keyed path the hub still renders the header inline (`agent_service.odin:1289`). So these variables are now **descriptor/launch-payload-sourced at assembly time**, not a hub template value on the primary path. |
| "Bridge appends `## Heimdall CLI` via `bridge_bootstrap_ctl_guidance` at `bootstrap_service.odin:164`" | **CHANGED (moved)** | Still bridge-appended and still static, but the proc is now at `bootstrap_service.odin:206`; appended inside `bridge_bootstrap_assemble_agents_md` (`:573`), the CLI materializer (`:831`), the legacy fetch fallback (`:60`) and provider-test (`:99`). |
| "4 default skills (coordinator/worker/fallback + memory-workflow), emitted as separate SKILL.md" | **STILL-TRUE** | `bootstrap_coordinator_task_skill`, `bootstrap_worker_task_skill`, `bootstrap_fallback_skill` still exist and are emitted as skill manifest items in both `bootstrap_manifest_json_for_bridge` (`:1400-1435`) and `render_agent_manifest` (`:1740-1760`); `memory-management-workflow` still the SQL seed. `target_hint` = `.agents/skills/<name>/SKILL.md` (`:1809`). |
| "Section fragments (identity/project/tasks/role/memories) are the clean modular sources" | **STILL-TRUE** | Confirmed — these `render_*` procs are the single source now. Line refs updated: `render_agent_identity:1217`, `render_project:1225`, `render_tasks_guidance:1237`, `render_role_guidance:1245`, `render_memories_markdown:1253` (instance) / `render_memories_markdown_agent:1838` (agent-keyed). |
| "Content is hashed + cached; per-section fragments" | **STILL-TRUE (now central)** | `bootstrap_fragment_hash:1209` + `hub_fragment_cache_put:1315`/`get:1324`; plus a manifest-level cache with ETag/epoch (`bootstrap_manifest_conditional:1620`) and immutable per-hash blob serving. The fragment/hash idea the prior report anticipated is now the whole architecture. |

---

## RV-3. Template persona/instructions GAP — re-confirmed against current code

**Still a real gap. Verified in the CURRENT manifest path:**
- `render_agent_identity` (`agent_service.odin:1217-1223`) returns `"\n\n## Agent Identity & Instructions\n" + agent.instructions` and renders **only** `agent.instructions`. It never reads a template.
- **No templates join anywhere in the current bootstrap path:** grep for `content_get_template` / `.persona` / `template_persona` / `template_instructions` across `src/hub/service/agent/agent_service.odin` returns **zero** hits. Neither `render_agent_manifest` (`:1683`) nor `bootstrap_manifest_json_for_bridge` (`:1333`) fetches the `templates` row; both only pass `agent` to `render_agent_identity`.
- `create_agent` still does not copy template persona/instructions into the agent (`agent_service.odin:85` — builds `domain.Agent{… instructions = input.instructions, template_id = input.template_id …}`), so nothing snapshots them either.
- The `templates` table still has the columns and `domain.Template` still carries them (schema `migrations/002_owner_scoped_core.sql:225-226`; struct `domain/content.odin:142`, fields `:148-149`; repo `content_get_template_sqlite` `content_repo_sqlite.odin:143`, mapping `template_from_stmt:172`).

> **Gap re-confirmed: template `persona`/`instructions` are still never injected into the bootstrap AGENTS.md.** The `bootstrap_template_design.md` §1.2 finding stands; only the fix location moves (below).

### Restating the fix in the NEW architecture
The identity content is a **hub-authored fragment** (`render_agent_identity`), so the fix belongs there — NOT in the bridge header:
1. **Add the templates fetch in `render_agent_manifest` (`agent_service.odin:1683`)** (and, for parity, `bootstrap_manifest_json_for_bridge:1333`): when `agent.template_id != ""`, call `iface.content_get_template(service.content, agent.template_id)` to get `template.persona` / `template.instructions`. `service.content` is already in scope (used for memories/skills at `render_agent_manifest` `:1748`). Treat miss as empty.
2. **Extend `render_agent_identity`** to compose the fragment from three DB values — `template.persona`, `template.instructions`, `agent.instructions` — using the precedence from `bootstrap_template_design.md` §2.1 (persona first; effective instructions = template base + agent appended; each sub-block gated on presence; widen the early-return guard so the fragment renders when ANY of the three is non-empty). Change its signature to accept the template values (e.g. `render_agent_identity(agent, template_persona, template_instructions)`).
3. Because the identity fragment is **content-addressed**, adding persona/instructions changes its hash → the `bootstrap_version` ETag changes → bridges naturally re-fetch it. No bridge change needed for this fix; the persona/instructions ride inside the existing `agent_identity` fragment.
4. **Where it lives:** the identity fragment is agent-keyed data (persona/instructions depend on the agent + its template, not the instance), so it fits the agent-keyed manifest cleanly — no per-instance recomputation. The **header** (bridge-side) is the wrong place: it is per-instance descriptor data and would lose the fragment caching + would duplicate template lookups per instance.

---

## RV-4. Re-mapping the single-template / `{variables}` proposal onto the new architecture

The prior "one template file for the whole AGENTS.md body, shared by P1 and P2" recommendation is **partly obsoleted**: there is no whole-body builder to unify anymore, and the body is assembled bridge-side from independently-cached fragments. The externalization goal (editable `.md`, no escaped Odin literals, no duplication) still applies, but the unit is now **per-fragment**, not one monolithic template.

### Recommended split (given the fragment/manifest design)

**Option (i) — hub renders each fragment from `#load`-ed `.md` files. RECOMMENDED.**
- Externalize each hub `render_*` fragment's static prose into its own `src/prompts/*.md`, loaded with `#load` and consumed by the `render_*` proc:
  - `render_tasks_guidance:1237` → `#load("bootstrap_tasks_guidance.md")` (100% static — trivial).
  - `render_role_guidance:1245` → `bootstrap_role_coordinator.md` + `bootstrap_role_worker.md` (static prose; keep the `is_coordinator`/`chain_ok` selection in code).
  - `render_project:1225` → static heading/prose from `bootstrap_project.md`; keep the per-field DB interpolation in code.
  - `render_agent_identity:1217` → static sub-headings (`### Persona`, `### Instructions`) from `bootstrap_agent_identity.md`; DB values (persona/template_instructions/agent_instructions) filled in code per RV-3.
  - memories heading (`render_memories_markdown*`) → `bootstrap_memories_header.md`; rows stay code-rendered.
- **Bridge unchanged** for these (it just resolves hashes). This keeps content addressing/caching intact: the fragment body still hashes the same whether authored inline or `#load`-ed, and editing an `.md` changes the fragment → new hash → ETag change → re-fetch. This is the cleanest fit.

**Option (ii) — header template moves to a bridge-side `.md`.**
- The header is now rendered by the **bridge** (`bridge_bootstrap_render_header:509`) from the descriptor, so its (small) static scaffold (`# Agent bootstrap`, `Agent:`, `Instance:`, `Task chain:`, `Coordinator:` labels + the `you (coordinator)` literal) would have to be externalized on the **bridge side** (a bridge `#load`), not the hub. Given the header is tiny and its logic (chain/coordinator branching) is inherently code, externalizing it yields little; **recommend leaving the header in bridge code** (or a very small bridge-side `.md` if desired). Note the header exists in TWO places (hub `render_header_inline:1289` for the instance path, bridge `render_header:509` for the agent path) — if externalized, a **shared** `bootstrap_header.md` `#load`-ed by both would remove that one remaining duplication.

### Updated rule (DB-only variables) under the new reality
The `bootstrap_template_design.md` rule — *variables = DB-fetched values only; static prose inline, gated by boolean markers* — still holds **per fragment**, with one clarification the new architecture forces:
- The **header** is assembled bridge-side from the launch **descriptor** (not a hub DB read at render time). Its "variables" (`agent_name`, `instance_id`, `chain_title`, `chain_id`, `coordinator_id`) are descriptor fields (which the hub populated into the launch payload upstream). So on the primary path the header is not a hub template at all; treat it as bridge-side descriptor interpolation with the label prose inline (the bridge already inlines the chain/coordinator branching at `:516-527`).
- All other sections remain hub fragments where the DB-only rule applies exactly as written (identity now gains `template_persona`/`template_instructions` per RV-3).

### Net recommended file set (revised)
- Hub-loaded fragment prose (`src/prompts/`): `bootstrap_tasks_guidance.md`, `bootstrap_role_coordinator.md`, `bootstrap_role_worker.md`, `bootstrap_project.md`, `bootstrap_agent_identity.md`, `bootstrap_memories_header.md`.
- Bridge-loaded: `bootstrap_ctl_guidance.md` (already proposed; appended by `bridge_bootstrap_ctl_guidance:206`) and OPTIONALLY a shared `bootstrap_header.md` `#load`-ed by both header renderers to kill the last duplication.
- Skills (unchanged): `skills/{coordinator-task-management,worker-task-management,heimdall-ctl-communication,memory-management-workflow}/SKILL.md`.
- **Dropped:** the single monolithic `bootstrap_agents_md.tmpl.md` — the fragment architecture makes per-fragment `.md` files the right granularity; a whole-body template no longer maps to any single code site.

---

## RV-5. Summary of what changed vs the old reports

- **`bootstrap_prompt_snippets.md`:** the "two hub paths (P1 inline + P2 fragments)" framing is stale — P1 is removed; the CLI/instance path and the WS/agent-keyed path both now use fragments. The snippet→proposal mapping is still directionally right but line refs must use the current `render_*` locations (RV-1/RV-2). ctl guidance moved `164→206`.
- **`bootstrap_template_design.md`:** the "single whole-body template shared by P1/P2" is obsoleted by the fragment/manifest design (RV-4). The §1.1 "P1 omits Agent Identity" divergence is STALE (P1 gone). The §1.2 template-persona/instructions **gap is STILL VALID** (RV-3), fix relocates into `render_agent_identity` + a templates fetch in `render_agent_manifest`. The DB-only variable rule survives per-fragment, with the header now a bridge-side descriptor concern.
- **Still true across both:** section prose is single-sourced in hub `render_*` procs; 4 default skills as separate SKILL.md; externalizing prose to `#load`-ed `.md` is still the right refactor — just at fragment granularity.
- **New findings:** (a) bridge now assembles + renders header locally; (b) agent-keyed conditional/ETag manifest with immutable per-hash blob serving is the primary path; (c) header logic is duplicated hub-side vs bridge-side; (d) `write_bootstrap_skill_fields`/`write_bootstrap_memory_markdown` are dead code.

All refs above re-derived from the current `src/hub/service/agent/agent_service.odin`, `src/bridge/bootstrap_service.odin`, `src/hub/transport/http/bridge_handlers.odin`, and `src/hub/app/wiring.odin`.
