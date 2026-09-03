# Prompts Usage Audit — `src/prompts`

**Task:** `task_18d1bd8a95bcc6d2` (chain `chain_18d1bd65159d673c`)
**Date:** 2026-09-03
**Analyst:** Prompt Audit Analyst (`inst_18d1bdaecd20148d`)
**Scope:** All 33 files under `~/heimdall-hub-rewrite/src/prompts`

## Method

- **PA-1:** Enumerated all files under `src/prompts` (33 `.md` files).
- **PA-2:** Searched the whole repo (excluding `node_modules`, `dist`, `electron-dist`, `.run-logs`) for references to each prompt by full filename and by basename. Prompts are embedded at compile time via Odin `#load("../prompts/<file>", string)`. Cross-checked which subsystem loads each file.
- **PA-3:** Classified each file:
  - **USED** = loaded by a non-deprecated subsystem (`hub`/`bridge`/`ctl`/`wrapper`/`ui`/`lib`).
  - **DEPRECATED** = loaded ONLY by `src/daemon` (ham-daemon is deprecated & not deployed).
  - **UNUSED** = no code references anywhere.
- **PA-4:** This report + task-comment summary.

### Key evidence: daemon is deprecated
`src/daemon/main.odin:9` — `fmt.println("ham-daemon is deprecated and has been replaced by ham-hub and ham-bridge.")`. Therefore any prompt wired only into daemon flows is effectively unused / deletion-eligible.

### Loaders found
- `src/wrapper/main.odin` (non-deprecated) — loads `guide-agent.md`, `bootstrap_profile_guidance.md`.
- `src/ctl/help.odin` (non-deprecated) — loads `bootstrap_profile_guidance.md`.
- `src/daemon/user_pref_rest.odin` (deprecated) — also loads `bootstrap_profile_guidance.md`.
- `src/daemon/agent_template_db_service.odin` (deprecated) — seeds 12 agent-template role pairs (persona + instructions) = **24 files**.
- `src/daemon/memory_auditor_orchestrator.odin` (deprecated) — loads `memory_audit_chain_description.md` + `memory_audit_task_1..5.md` = **6 files**.

## Classification table

| Prompt file | Status | Referencing subsystem(s) | Evidence (file:line) |
|---|---|---|---|
| bootstrap_profile_guidance.md | **USED** | wrapper, ctl, (daemon) | `src/wrapper/main.odin:1433`, `src/wrapper/main.odin:1795`, `src/ctl/help.odin:11`, also `src/daemon/user_pref_rest.odin:68` |
| guide-agent.md | **USED** | wrapper | `src/wrapper/main.odin:1319` (also `:1316`, `:1401`) |
| coder_persona.md | DEPRECATED | daemon only | `src/daemon/agent_template_db_service.odin:255` |
| coder_instructions.md | DEPRECATED | daemon only | `src/daemon/agent_template_db_service.odin:256` |
| conversation_persona.md | DEPRECATED | daemon only | `src/daemon/agent_template_db_service.odin:367` |
| conversation_instructions.md | DEPRECATED | daemon only | `src/daemon/agent_template_db_service.odin:368` |
| guide_persona.md | DEPRECATED | daemon only | `src/daemon/agent_template_db_service.odin:351` |
| guide_instructions.md | DEPRECATED | daemon only | `src/daemon/agent_template_db_service.odin:352` |
| lead_persona.md | DEPRECATED | daemon only | `src/daemon/agent_template_db_service.odin:223` |
| lead_instructions.md | DEPRECATED | daemon only | `src/daemon/agent_template_db_service.odin:224` |
| memory_auditor_persona.md | DEPRECATED | daemon only | `src/daemon/agent_template_db_service.odin:319` |
| memory_auditor_instructions.md | DEPRECATED | daemon only | `src/daemon/agent_template_db_service.odin:320` |
| memory_reviewer_persona.md | DEPRECATED | daemon only | `src/daemon/agent_template_db_service.odin:335` |
| memory_reviewer_instructions.md | DEPRECATED | daemon only | `src/daemon/agent_template_db_service.odin:336` |
| planner_persona.md | DEPRECATED | daemon only | `src/daemon/agent_template_db_service.odin:207` |
| planner_instructions.md | DEPRECATED | daemon only | `src/daemon/agent_template_db_service.odin:208` |
| researcher_persona.md | DEPRECATED | daemon only | `src/daemon/agent_template_db_service.odin:287` |
| researcher_instructions.md | DEPRECATED | daemon only | `src/daemon/agent_template_db_service.odin:288` |
| reviewer_persona.md | DEPRECATED | daemon only | `src/daemon/agent_template_db_service.odin:239` |
| reviewer_instructions.md | DEPRECATED | daemon only | `src/daemon/agent_template_db_service.odin:240` |
| specialist_persona.md | DEPRECATED | daemon only | `src/daemon/agent_template_db_service.odin:383` |
| specialist_instructions.md | DEPRECATED | daemon only | `src/daemon/agent_template_db_service.odin:384` |
| tester_persona.md | DEPRECATED | daemon only | `src/daemon/agent_template_db_service.odin:303` |
| tester_instructions.md | DEPRECATED | daemon only | `src/daemon/agent_template_db_service.odin:304` |
| worker_persona.md | DEPRECATED | daemon only | `src/daemon/agent_template_db_service.odin:271` |
| worker_instructions.md | DEPRECATED | daemon only | `src/daemon/agent_template_db_service.odin:272` |
| memory_audit_chain_description.md | DEPRECATED | daemon only | `src/daemon/memory_auditor_orchestrator.odin:10` |
| memory_audit_task_1.md | DEPRECATED | daemon only | `src/daemon/memory_auditor_orchestrator.odin:11` |
| memory_audit_task_2.md | DEPRECATED | daemon only | `src/daemon/memory_auditor_orchestrator.odin:12` |
| memory_audit_task_3.md | DEPRECATED | daemon only | `src/daemon/memory_auditor_orchestrator.odin:13` |
| memory_audit_task_4.md | DEPRECATED | daemon only | `src/daemon/memory_auditor_orchestrator.odin:14` |
| memory_audit_task_5.md | DEPRECATED | daemon only | `src/daemon/memory_auditor_orchestrator.odin:15` |
| coordinator_instructions.md | **UNUSED** | none (code) | No `#load`/code reference anywhere. Only mentioned in prose: `reports/teams-removal-analysis.md:416,442`. Note: the `lead` template loads `lead_*.md`, not `coordinator_*`. |

## Summary counts

| Status | Count |
|---|---|
| USED | 2 |
| DEPRECATED (daemon-only) | 30 |
| UNUSED | 1 |
| **Total** | **33** |

## Deletion candidates (UNUSED + DEPRECATED) — 31 files

**UNUSED (safe to delete immediately, no code refs):**
- `coordinator_instructions.md`

**DEPRECATED (loaded only by the deprecated `ham-daemon`; delete together with daemon cleanup):**
- Agent-template pairs (24): `coder_persona.md`, `coder_instructions.md`, `conversation_persona.md`, `conversation_instructions.md`, `guide_persona.md`, `guide_instructions.md`, `lead_persona.md`, `lead_instructions.md`, `memory_auditor_persona.md`, `memory_auditor_instructions.md`, `memory_reviewer_persona.md`, `memory_reviewer_instructions.md`, `planner_persona.md`, `planner_instructions.md`, `researcher_persona.md`, `researcher_instructions.md`, `reviewer_persona.md`, `reviewer_instructions.md`, `specialist_persona.md`, `specialist_instructions.md`, `tester_persona.md`, `tester_instructions.md`, `worker_persona.md`, `worker_instructions.md`
- Memory-audit orchestration (6): `memory_audit_chain_description.md`, `memory_audit_task_1.md`, `memory_audit_task_2.md`, `memory_audit_task_3.md`, `memory_audit_task_4.md`, `memory_audit_task_5.md`

## Keep (USED) — 2 files
- `bootstrap_profile_guidance.md` — loaded by `wrapper` and `ctl` (also daemon, but non-deprecated refs keep it USED).
- `guide-agent.md` — written out by `wrapper` as the guide-only handbook.

## Notes / caveats
- These prompts are compiled into binaries via `#load`; deleting a DEPRECATED file will break the daemon build until the corresponding daemon `#load` lines are also removed. Since the daemon is deprecated and not deployed, removing the daemon loaders + these prompts together is the clean path.
- `bootstrap_profile_guidance.md` is a `printf`-style template (`fmt.tprintf`) taking a `profile_desc` argument — keep its format placeholder intact if edited.
