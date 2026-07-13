# Daemon Code Audit & Cleanup — Plan (Step 1)

Status: Draft (plan only; no code changes)
Scope: `src/daemon/` (20,675 LOC, 60 files). Goal: identify and remove bad code
smells — violations of single-responsibility, shared/duplicated logic, scattered
state, hardcoded strings, dead code, and consolidation/simplification
opportunities — in a phased, low-risk way.

This document is **Step 1: the audit plan**. It defines the smell taxonomy,
the measured baseline, and a phased remediation approach. No code is changed here.

## 1. Baseline signals (measured, not guessed)

Collected by grep/wc over `src/daemon/*.odin`:

| Signal | Measurement | Smell |
|---|---|---|
| Largest file | `task_service.odin` = 1,799 LOC | God file / SRP violation |
| Global mutable state | 51 package-level mutable decls; 24 fixed-size `[MAX]T` buffer arrays | Scattered/shared state |
| Manual JSON writes | 1,907 `strings.write_string`/`json_write_string` calls | Serialization scattered everywhere |
| Manual JSON parse | 497 `extract_json_*` calls; **0** use of `core:encoding/json` | Hand-rolled, fragile parsing |
| Hand-written (de)serializers | 81 `*_json ::` / `*_from_json ::` procs | Duplicated record↔JSON logic |
| Hardcoded status/role strings | `"coordinator"`×40, `"lgtm_required"`×21, `"in_progress"`×21, `"planning"`×20, `"completed"`×18, `"cancelled"`×18, `"review_ready"`×16, `"archived"`×15, `"lgtm_optional"`×13, `"user_proxy"`×12 | Magic strings, no enum/const |
| Auth/identity resolution | 70 call sites; 35 `itype != "user"` duplications | Duplicated middleware logic (see caller-identity chain) |
| Routing | 3 dispatch styles: 90 `has_prefix(request …)` in `server.odin`, 16 segment routes in `rest_router.odin`, per-module handlers (`chat_http`, `vcs_http`, `team_http`) | Inconsistent routing, no single table |
| DB access | 10 `*_db_service.odin`, **two** mechanisms: 3 shell out to `sqlite3` binary, 10 use cgo C-API | Inconsistent persistence layer, duplicated exec/query helpers |
| Dead code | 29 procs with ≤1 reference (5 confirmed definition-only across all packages) | Dead code |
| Debug/markers | 18 `DEBUG` printlns in production paths, 11 `deprecated` markers, 5 `ponytail:` notes, 1 TODO | Debug cruft / stale comments |

## 2. Smell taxonomy (what we hunt for)

1. **SRP violations / god files** — one file/proc owning many unrelated
   responsibilities (routing + auth + business logic + serialization + persistence
   in the same proc).
2. **Shared/duplicated logic** — same pattern copy-pasted (auth resolution, JSON
   (de)serialization, DB exec/query helpers, `itype != "user"` handling).
3. **Scattered state** — package-global mutable arrays/counters mutated from many
   files with no single owner; parallel arrays that must stay in sync.
4. **Hardcoded strings** — statuses, roles, recipients, routes as bare literals
   instead of enums/constants (overlaps with the two in-flight chains:
   caller-identity, task-status-enum).
5. **Dead code** — unreferenced procs, unreachable branches, `deprecated`/stub
   code still compiled.
6. **Consolidation/simplification** — near-identical procs that could merge;
   hand-rolled JSON that could use `core:encoding/json`; inconsistent DB access
   that could go through one layer.

## 3. Guiding principles for remediation

- **Behavior-preserving by default.** Each cleanup is a refactor with tests
  green before/after; no functional change unless explicitly called out.
- **Measure → prove dead → delete.** Never delete on a hunch; confirm zero
  references across ALL packages (daemon, contracts, lib, ctl, wrapper) and no
  runtime-only dispatch (route tables, string dispatch) references it.
- **One concern per phase.** Don't mix "extract module" with "introduce enum" in
  the same change; keep diffs reviewable.
- **Consolidate to a single owner.** For each duplicated concern, define ONE
  home (a module/proc/const set) and route all call sites through it.
- **No coupling to the in-flight chains.** The caller-identity and task-status
  work already own the `user_proxy`/`operator@local`/status-string cleanups;
  this audit references but does not duplicate them.
- **Smart-tier agents only; no cheap coder** when this becomes chains.

## 4. Phased plan

The audit is delivered as an ordered set of phases. Phases 0–1 are analysis;
2+ are remediation, each independently reviewable and shippable. Ordering is by
**risk-adjusted value**: low-risk/high-clarity first (dead code, debug cruft),
structural refactors later.

### Phase 0 — Inventory & smell map (analysis, no code)
- Produce a per-file responsibility map and a machine-checkable smell inventory
  (proc reference counts, string-literal index, state-ownership map, route table).
- Deliverable: `docs/audits/daemon-smell-inventory.md` + a repeatable script
  (`scripts/audit_daemon.sh`) so regressions are catchable later.
- Exit: every smell in §1 has a concrete, itemized list (file:line), not a count.

### Phase 1 — Dead code & debug cruft (lowest risk)
- Confirm and remove the ~29 dead procs (prove 0 refs across all packages + no
  string/route dispatch use).
- Gate the 18 `DEBUG` printlns behind a debug flag or remove them.
- Triage the 11 `deprecated` markers: delete or finish; resolve the stale TODO/
  `ponytail:` notes.
- Exit: build + full test suite green; measurable LOC reduction; no behavior change.

### Phase 2 — Constants for magic strings (bounded, mechanical)
- Introduce a single constants/enums home for statuses, roles
  (`lgtm_required`/`lgtm_optional`/`coordinator`/…), and the human-recipient
  address. Replace bare literals with references.
- **Coordinate with** the caller-identity chain (recipient/identity) and the
  task-status-enum audit (chain/task status) so this phase covers only what
  those don't (roles, misc route/kind literals).
- Exit: no business-logic branch on bare status/role literals in the touched
  scope; tests green.

### Phase 3 — Consolidate the persistence layer
- Pick ONE DB access mechanism (cgo C-API is already the majority: 10 vs 3).
  Migrate the 3 shell-out `sqlite3` services (`team_db`, `vcs_db`,
  `teams_v1_migration`) onto it, OR extract a single `db_exec`/`db_query` helper
  used by all — remove per-file duplicated `_db_exec`/`_db_query`/`sql_text`.
- Extract shared helpers (`extract_int`, `sql_text`, `parent_dir`, `expand_home`)
  duplicated across files into one utility module.
- Exit: one persistence path; duplicated helpers have a single definition.

### Phase 4 — Unify request routing & auth
- Replace the 3 dispatch styles with a single route table (method + path →
  handler) so `server.odin`'s 90 `has_prefix` checks, `rest_router`'s segment
  matching, and the per-module handlers converge.
- Route all handlers through one auth/identity middleware that yields
  `(identity_id, identity_type)` once (eliminating the 70 scattered resolutions
  and 35 `itype != "user"` duplications) — building on the caller-identity work.
- Exit: one routing table, one auth entry point; handler bodies contain only
  business logic.

### Phase 5 — Serialization consolidation (largest, do last)
- Evaluate `core:encoding/json` (or a single internal codec) to replace the
  1,907 manual writes / 497 manual parses / 81 hand-written (de)serializers.
- If full migration is too large, at minimum consolidate the repeated
  record→JSON builders into per-entity `marshal`/`unmarshal` in one place, and
  replace `extract_json_*` scatter with a single typed request-decoding helper.
- Exit: serialization has a single home per entity; parsing goes through one
  typed decoder; wire format byte-for-byte unchanged (contract tests guard it).

### Phase 6 — SRP split of god files
- Decompose `task_service.odin` (1,799 LOC) along its real responsibilities
  (chain lifecycle, task lifecycle, scaffolding, reviews/votes, comments,
  participants) into focused modules with clear ownership; same for other
  outliers (`agents_start.odin` 685, `registry.odin` 579, `task_queries.odin` 753).
- Pure move-refactors: no logic change, tests green throughout.
- Exit: no single file owns unrelated concerns; each module has one reason to
  change.

## 5. Sequencing & safety

- **Prereq:** land the two in-flight chains (caller-identity, and the
  task-status-enum work when it exists) first — Phases 2/4 build on them and
  would otherwise conflict.
- **Guardrails per phase:** `nix build .#ham-daemon .#ham-ctl .#ham-wrapper`,
  `tsc`, and the affected python/Odin tests must pass; contract/wire tests guard
  Phases 4–5.
- **Reversibility:** each phase is an independent branch/chain; no phase depends
  on a later one.

## 6. Deliverables of this audit
1. `docs/audits/daemon-smell-inventory.md` — itemized smell list (Phase 0).
2. `scripts/audit_daemon.sh` — repeatable smell metrics to prevent regression.
3. One reviewed task chain per remediation phase (2–6), smart-tier, no cheap
   coder, each behavior-preserving with tests.

## 7. Explicit non-goals
- No functional/feature changes.
- No re-litigating the `user_proxy`/`operator@local`/status-string cleanups owned
  by the caller-identity and task-status-enum chains — reference, don't duplicate.
- No rewrite; this is incremental, measured, behavior-preserving cleanup.

## 8. Next step
Proceed to **Phase 0** (build the itemized smell inventory + audit script) as the
first task chain, then review its findings before committing to Phases 1–6.
