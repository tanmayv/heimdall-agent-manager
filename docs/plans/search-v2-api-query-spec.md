# SEARCH-1 — API surface + SQL query spec (design gate, PART ONE)

Status: APPROVED (SEARCH-1) + decisions RESOLVED (2026-09-09). User calls, applied in
SEARCH-2..7: (a) REAL merge-stage load-more cursor (not emit-only); (b) skills expose a
REAL navigable route (SEARCH-3/5 add the viewer); (c) CLEAN nested hit shape (no wire
back-compat) — nested `parent{id,type}` (null when N/A) + `preview` + `matched_field`, keeping
id/label/sublabel/route/score. SEARCH-2 (API) + SEARCH-5 (UI) land in the SAME release.
Scope: EXTEND the existing global search (`GET /api/v1/search`) — reuse its layering,
routing, ownership, and bounded-scan discipline. Per user guidance (2026-09-09) we do NOT
need wire/back-compat with the current response shape, so the hit JSON is designed cleanly
(§2) and the UI (`src/ui/api/endpoints/search.ts`, `command-palette/CommandPalette.tsx`) is
updated to consume it as part of the SEARCH UI task. "Extend, don't rebuild" still holds:
the handler → service → iface → sqlite structure and the existing entity providers stay.

All file/line citations are against `main` @ `f4120e0`.

---

## 0. Current architecture (baseline, cited)

Request flows: HTTP handler → service → repository interface → SQLite repo.

- Handler: `src/hub/transport/http/search_handlers.odin`
  - `allowed_filters := [?]string{"types"}` (L20); `parse_api_query(req.query, allowed_filters[:], nil, nil)` (L21).
  - Extracts `types` CSV (L25–27); computes limit via `search_limit_from_query` (L28, L63).
  - Builds `search_service.Search_Input{q, types_csv, limit, cursor}` (L29).
  - Response grouping order `SEARCH_RESPONSE_TYPE_ORDER` (L61); per-hit JSON `write_search_hit_json` emits `id,label,sublabel,score,route` (L86–92); `score_json` (L95–99); envelope `respond_search` emits `data + page{limit,next_cursor,has_more} + meta` (L101+).
- Service: `src/hub/service/search/search_service.odin`
  - `DEFAULT_SEARCH_LIMIT :: 20`, `MAX_SEARCH_LIMIT :: 50`, `MAX_SEARCH_SCAN_CAP :: 200` (L9–11).
  - `Search_Input{q, types_csv, limit, cursor}` (L17–22).
  - `search_resources`: `ownership.owner_from_auth` (L28); trims `q`; clamps `response_limit`; `hard_scan_cap := response_limit * 4` capped at 200 (L35–37); empty `q` returns empty result (L38–40); calls `iface.search_resources` with `Search_Query` (L41).
- Interface: `src/hub/repository/iface/search_repo.odin`
  - `Search_Hit{resource_type,id,label,sublabel,route,score}`; `Search_Query{owner_user_id,q,types_csv,response_limit,hard_scan_cap,cursor}`; `Search_Result{hits,has_more,next_cursor}`.
- SQLite repo: `src/hub/repository/sqlite/search_repo_sqlite.odin`
  - `_ = query.cursor` — cursor accepted but IGNORED today (L17).
  - `SEARCH_TYPE_ORDER` (L37); `search_type_enabled` (empty=all, `task_chain`→`task-chain`, `all`) (L39–50).
  - `run_type_search`: binds `q` to params 1–7 (L59), `owner_user_id` to param 8 (L60), `q` to params 9–11 (L61), `hard_scan_cap` to param 12 (L62).
  - Per-type SQL: score `CASE` (exact/id-exact/prefix/word-boundary/id-prefix/interior = 100/98/90/80/70/50) then `WHERE owner_user_id = ? AND (lower(label) LIKE … OR lower(id) LIKE … OR lower(aux) LIKE …) ORDER BY score DESC, updated_at DESC, id ASC LIMIT ?`.
- UI: `src/ui/api/endpoints/search.ts` — `SearchHit{id,label,sublabel?,score?,route?,type?}`, `normalizeHit` tolerant of extra fields; `globalSearch({q,types?,limit?})`. `command-palette/CommandPalette.tsx` uses `hit.route`/`hitRoute`, `hitIcon`, `ENTITY_GROUP_LABEL`.
- Static guard: `tests/test_hub_ui18_search_static.py` (see §8.5 — must be revised for FTS).

---

## 1. Query params (additive)

| Param | Status | Type | Meaning |
|-------|--------|------|---------|
| `q` | existing | string | Query text. Empty/whitespace → empty result (service L38–40). |
| `types` | existing | CSV | Provider filter (empty=all). Add `comment`,`skill` to the vocabulary (§4). |
| `limit` | existing | int | Response page size, clamped to `MAX_SEARCH_LIMIT=50`. |
| `cursor` | existing | opaque string | Page cursor. Currently ignored (L17); §3 activates it. |
| **typed parent-id filters** | **NEW (SEARCH-8)** | CSV each | `task_ids`, `chain_ids`, `project_ids`, `conversation_ids` (+ negations `not_in_*`) restrict hits to rows under the named parent(s). Empty = no constraint. Each maps to the precise containment column per provider and is AND-ed with `owner_user_id` (§4.2/§6). Replaces the removed generic `scope_ids`. |
| **`exclude`** | **NEW** | substring | Drop any hit whose match text contains this substring (case-insensitive). Empty = no exclusion (§7). |

### 1.1 Parser wiring (`transport/http/search_handlers.odin`)
- The allowlist carries `types`, `exclude`, and the 8 typed filters (`task_ids`/`chain_ids`/`project_ids`/`conversation_ids` + `not_in_*`). `parse_api_query` preserves any allowlisted key as a `filter` (see `src/hub/transport/http/parse.odin` L45–52), so no parser-core change is required — the handler reads each filter value into `Search_Input`.
- The generic `scope_ids` param is REMOVED (SEARCH-8) — not aliased.

### 1.2 Service Input (`service/search/search_service.odin`)
Extend `Search_Input` (L17–22) and `iface.Search_Query` additively:
```
Search_Input :: struct {
    q:          string,
    types_csv:  string,
    limit:      int,
    cursor:     string,
    task_ids, chain_ids, project_ids, conversation_ids: string, // NEW (SEARCH-8): CSV each
    not_in_task_ids, not_in_chain_ids, not_in_project_ids, not_in_conversation_ids: string,
    exclude:    string, // NEW: substring, empty = no exclusion
}
```
The same typed fields + `exclude` are added to `iface.Search_Query`. The repo splits each CSV once, builds a typed WHERE clause (§4.2), and applies `exclude` per §7.

---

## 2. Hit JSON shape (clean design — no back-compat constraint)

The hit is redesigned as one coherent object. `write_search_hit_json`
(`search_handlers.odin` L86–92) is rewritten to emit exactly these keys and `iface.Search_Hit`
carries the matching fields. The UI (`search.ts` `normalizeHit`, `CommandPalette`) is updated
to read this shape in the SEARCH UI task.

```
{
  "type":          "comment",          // resource type (provider) — replaces the group-only carrier
  "id":            "...",              // the hit's own id
  "label":         "...",              // primary display text
  "sublabel":      "...",              // secondary display text
  "route":         "...",              // navigation target ("" = not navigable, e.g. skills v1)
  "score":         0.90,               // 0.00–1.00 (score_json, L95)
  "parent":        {                    // owning entity; null when the hit IS a top-level entity
    "id":   "...",
    "type": "task"
  },
  "preview":       "…text [match] text…", // matched-text snippet (§7); omitted for id/label-only matches
  "matched_field": "body"               // which field matched: label|id|aux|body|content|name
}
```

Notes:
- `type` moves onto the hit itself (today it is only implied by the enclosing group). The
  response still also groups by type for the palette; the redundancy is intentional so a
  flattened hit is self-describing (the UI already flattens groups in `search.ts` L48).
- `parent` is a nested object (cleaner than flat `parent_id`/`parent_type`), `null` for
  top-level entities. `preview`/`matched_field` are omitted (not empty-string) when absent.
- Existing entity providers (agent/task/etc.) set `parent: null`, `matched_field` to the
  matched column, and no `preview` for pure id/label matches. The UI is updated in lockstep;
  there is no requirement to keep the old five-field shape working.

---

## 3. Cursor + pagination (no regression)

Keep `next_cursor` / `has_more` (`respond_search`, `search_handlers.odin` L101+; `Search_Result`).

Today `has_more` is a boolean derived from per-provider scan caps and the global
`response_limit` truncation (`search_repo_sqlite.odin` L23–33), and `cursor` is ignored
(L17). This spec keeps that proven behavior as the DEFAULT and defines how the new params
interact so paging stays correct:

- **Ordering key for a cursor** = the existing global sort `(score DESC, updated_at DESC, id ASC)`. A cursor encodes the last emitted tuple `(score, updated_at, id)` (opaque, base64 of `score|updated_at|id`). When `cursor==""` behavior is the first-page default described above.
- typed filters/`exclude` are applied BEFORE truncation/cursor slicing, so pagination remains stable across pages (a scoped/excluded search paginates over the filtered set, not the raw set).
- Providers keep their `hard_scan_cap` (per-provider LIMIT); the global merge sorts and slices to `response_limit`. `has_more` = "merged set exceeded `response_limit`" OR "any provider hit its scan cap" — UNCHANGED from L28–31.
- **No regression to per-scope-LIMIT-only:** the per-provider `LIMIT ?` (bound to `hard_scan_cap`, param 12 today) stays; the cursor is applied at the MERGE stage, never by lowering a provider's LIMIT. FTS providers (§8) use the same merge-stage cursor.

Decision to confirm: activating real cursor paging is optional for v1 (typeahead rarely
pages). Recommendation: keep emitting `next_cursor`/`has_more` (already contract-stable),
and implement merge-stage cursor consumption in SEARCH-6/7 only if the redesigned page needs
"load more". Flagging for coordinator/user.

---

## 4. Scope IDs + aliases (keep all; add comments + skills)

Providers (resource types). KEEP the existing eight; ADD two.

KEEP: `conversation`, `agent`, `agent_instance`, `task-chain`, `task`, `project`, `artifact`, `memory` (`SEARCH_TYPE_ORDER` L37; `SEARCH_RESPONSE_TYPE_ORDER` handler L61).
ADD: `comment`, `skill`.

### 4.1 `types` alias → canonical map
Extend `search_type_enabled` (`search_repo_sqlite.odin` L39–50) and the handler grouping.
No existing alias is dropped.

| Alias(es) accepted | Canonical |
|--------------------|-----------|
| `conversation`, `conversations` | `conversation` |
| `agent`, `agents` | `agent` |
| `agent_instance`, `instance`, `instances` | `agent_instance` |
| `task-chain`, `task_chain` (existing L46), `chain`, `chains`, `taskchain` | `task-chain` |
| `task`, `tasks` | `task` |
| `project`, `projects` | `project` |
| `artifact`, `artifacts` | `artifact` |
| `memory`, `memories` | `memory` |
| **`comment`, `comments`** | **`comment`** (NEW) |
| **`skill`, `skills`** | **`skill`** (NEW) |
| `all` (existing L48) | every provider |

Both new canonical types are appended to `SEARCH_TYPE_ORDER` and `SEARCH_RESPONSE_TYPE_ORDER`
(place `comment` after `task`, `skill` last), and to UI `ENTITY_GROUP_LABEL`
(`CommandPalette.tsx`): `comment → "Comments"`, `skill → "Skills"`.

### 4.2 Typed parent-id filters (SEARCH-8; replaces `scope_ids`)
The generic `scope_ids` CSV is REMOVED. Instead, four TYPED filters — one per containment
parent — restrict results, each with a negation variant: `task_ids`/`not_in_task_ids`,
`chain_ids`/`not_in_chain_ids`, `project_ids`/`not_in_project_ids`,
`conversation_ids`/`not_in_conversation_ids`.

Bounded set: ONLY the 4 parents with a real containment relationship. Each provider exposes a
precise single-value scope column per parent (`—` = `''`, i.e. no such relationship):

| Provider | scope_task_id | scope_chain_id | scope_project_id | scope_conversation_id |
|----------|:---:|:---:|:---:|:---:|
| conversation | — | `chain_id` | `project_id` | `conversation_id` |
| agent_instance | — | `chain_id` | `project_id` | `conversation_id` |
| task-chain | — | `chain_id` | — | — |
| task | `task_id` | `chain_id` | — | — |
| comment | `task_id` | `chain_id` | — | — |
| project | — | — | `project_id` | — |
| artifact | `task_id` | `chain_id` | `project_id` | — |
| agent | — | — | — | — |
| memory | — | — | — | — |
| skill | — | — | — | — (parentless) |

Semantics (each AND-ed with `owner_user_id`, and AND-ed with each other):
- Positive `<parent>_ids` ⇒ `scope_<parent> IN (…)`. A provider whose column is `''` is
  EXCLUDED by any positive filter — so `agent`/`memory` (no containment column) drop out of a
  task/chain/project/conversation scope. Memory targeting arrays are NOT containment and are
  intentionally out of scope here.
- Negation `not_in_<parent>_ids` ⇒ `scope_<parent> NOT IN (…)`; a `''` column passes (kept).
- Skills are parentless (global): like `agent`/`memory`, a POSITIVE typed filter EXCLUDES them
  (you're narrowing to rows under a parent they don't have); a negation-only query still returns
  them. They remain owner-independent and are matched by `q` (+ `exclude`).

Examples: `chain_ids=chain_1` → the chain + its tasks/comments/conversations/artifacts;
`project_ids=proj_1&not_in_chain_ids=chain_9` → project 1 minus chain 9; `task_ids=task_1` →
the task + its comments/artifacts.

---

## 5. Per-scope SQL for the NEW providers

### 5.1 Comments (`task_comments`)
Table (cited `migrations.odin` L148–157): `comment_id, task_id, chain_id, owner_user_id,
author_agent_instance_id, body, created_at, updated_at`. Parent = the task; route mirrors
`SEARCH_SQL_TASKS` (`/chains/{chain_id}/tasks/{task_id}`).

BEHAVIOR NOTE (SEARCH-6): when the FTS5 index exists, the comment provider matches the comment
BODY only (task_comments_fts MATCH) — a query of a raw `comment_id` is no longer a comment
search hit (comment ids aren't a free-text search term; the entity routes handle id navigation).
The indexed-LIKE fallback (used only when FTS5 is not compiled in) still matches comment_id OR body.

v1 (LIKE, pre-FTS) statement — same param convention as `run_type_search` (q in early
params, `owner_user_id`, then trailing filter params, `hard_scan_cap` last):
```sql
SELECT 'comment' AS resource_type,
       c.comment_id AS id,
       -- label = compact snippet of the comment body (first ~80 chars)
       substr(c.body, 1, 80) AS label,
       'comment on ' || t.title || ' · chain ' || c.chain_id AS sublabel,
       '/chains/' || c.chain_id || '/tasks/' || c.task_id AS route,
       c.updated_at,
       c.owner_user_id,
       c.task_id      AS parent_id,
       'task'         AS parent_type,
       c.body         AS match_text,          -- used to build preview (§7); NOT emitted raw
       'body'         AS matched_field,
       CASE
         WHEN lower(c.comment_id) = lower(?) THEN 98
         WHEN lower(c.body) LIKE lower(?) || '%' THEN 90
         WHEN lower(c.body) LIKE '% ' || lower(?) || '%' THEN 80
         ELSE 50
       END AS score
FROM task_comments c
JOIN tasks t ON t.task_id = c.task_id AND t.owner_user_id = c.owner_user_id
WHERE c.owner_user_id = ?
  AND lower(c.body) LIKE '%' || lower(?) || '%'
ORDER BY score DESC, c.updated_at DESC, c.comment_id ASC
LIMIT ?;
```
Notes: single JOIN to `tasks` for `parent_id`/route only (no N+1). Index required (§8.6).
This deliberately searches `task_comments.body` — see §8.5 re: the static-test guard.

### 5.2 Skills (in-memory `STATIC_SKILLS`)
Source: `src/hub/service/agent/static_skills_gen.odin` — `STATIC_SKILLS := []Static_Skill{slug, content}`,
where `content` is the `#load`ed `SKILL.md`. Skills are compiled-in, GLOBAL (served to every
agent, not owner-scoped). There is NO skills table, so this provider does NOT touch SQLite.

Design: a small pure Odin matcher in the repo layer (or a dedicated `skill` provider proc)
iterating `STATIC_SKILLS` in-memory:
```
for s in STATIC_SKILLS:
    hay_name    = lower(s.slug)
    hay_content = lower(s.content)
    if q in hay_name or q in hay_content:
        score = 100 if hay_name == q
                else 90 if hay_name startswith q
                else 80 if word-boundary(hay_name, q)
                else 60 if q in hay_name
                else 50            # content-only interior match
        emit Search_Hit{
            resource_type = "skill",
            id            = s.slug,
            label         = s.slug,
            sublabel      = "skill",
            route         = "/skills/" + s.slug, // RESOLVED (b): real viewer route
            parent        = null,                 // top-level entity
            preview       = snippet(s.content, q)  // §7
            matched_field = "name" if q in hay_name else "content",
            score         = score,
        }
```
Resolved decisions (2026-09-09, per user):
1. **Skill route = REAL.** Skill hits emit `/skills/<slug>`; SEARCH-5 adds the matching skills
   viewer route/page. (Supersedes the earlier `route=""` recommendation.)
2. **Skill scoping:** skills are parentless/global, so the typed parent filters (§4.2) treat
   them like `agent`/`memory` — a POSITIVE typed filter EXCLUDES skills, a negation-only query
   keeps them. `owner_user_id` is NOT applicable (no per-user skill rows); skills are the one
   provider not gated by owner. See §6.

---

## 6. Owner isolation (typed filters AND `owner_user_id`) + test

All SQL-backed providers already end with `WHERE owner_user_id = ?` bound from
`ownership.owner_from_auth` (`search_service.odin` L28; bound at `search_repo_sqlite.odin`
L60). Each typed filter (§4.2) is ANDed with — never replaces — that predicate. `build_typed_scope_clause`
emits, per set filter, one clause appended to the provider's WHERE (splice before the ORDER BY
anchor), with values bound positionally after the q/owner params and before LIMIT:

```sql
WHERE owner_user_id = ?                      -- caller's owner (param already bound)
  AND scope_<parent> IN (?, ?, …)            -- one per positive typed filter that is set
  AND scope_<parent> NOT IN (?, ?, …)        -- one per negation (not_in_*) that is set
  AND ( <existing match predicate> )
```
- `scope_<parent>` is the provider's precise column (`scope_task_id`/`scope_chain_id`/
  `scope_project_id`/`scope_conversation_id`), or `''` when the provider has no such parent —
  so a POSITIVE filter excludes parentless providers and a negation keeps them.
- All ids are bound as parameters (never string-concatenated) to avoid injection.
- Because `owner_user_id = ?` is ANDed FIRST, supplying another owner's ids in a typed filter
  returns zero rows: the rows exist under owner B, but `owner_user_id = A` excludes them.
- The `comment` provider ANDs `owner_user_id` on BOTH `task_comments` and the joined `tasks`
  (§5.1) so a cross-owner JOIN cannot leak a parent title.
- `skill` provider: global/compiled-in, parentless, no `owner_user_id`. Typed filters apply the
  parentless rule (positive excludes, negation keeps); there is no per-owner skill data to leak.

### 6.1 Cross-owner isolation test (REQUIRED, define now)
`tests/hub_search_owner_isolation_test.odin` (Odin, uses the in-repo sqlite test harness):
1. Seed owner A and owner B, each with: a task + a comment whose `body` contains the token
   `zeta-secret`, a memory titled `zeta-secret`, an artifact named `zeta-secret`.
2. As owner A, `search_resources(q="zeta-secret")` → results contain ONLY A's rows (assert
   every hit id belongs to A; assert count == A's seeded count).
3. As owner A, `search_resources(q="zeta-secret", chain_ids=<B's chain_id>)` (and other typed
   filters naming B's ids) → assert ZERO hits (B's ids cannot surface A-or-B data for caller A).
   Also assert a negation (`not_in_chain_ids=<A's chain>`) drops only A's in-chain rows.
4. As owner B, symmetric check.
5. Skill assertion: a `q` that matches a skill returns the SAME skill hit for both A and B
   (global), confirming skills are intentionally owner-independent.

---

## 7. `exclude` filter + preview snippet

### 7.1 `exclude` semantics
- Case-insensitive substring. A hit is DROPPED if `exclude` (non-empty) is contained in the
  hit's `match_text` (the field that produced the match: label/id/aux/body/content/name).
- Applied in the SERVICE/merge layer AFTER each provider returns rows and BEFORE global
  truncation + cursor slicing (so exclusion never leaves a short page). Applying it post-SQL
  keeps every provider statement simple and identical, and works uniformly for the in-memory
  skill provider too.
- Empty `exclude` = no-op (today's behavior).

### 7.2 Preview snippet algorithm (`…text [match] text…`)
Pure helper `search_preview(text, q, radius=32)`:
1. `idx := index(lower(text), lower(q))`. If `idx < 0` → return `""` (id/label-only match).
2. `start := max(0, idx-radius)`, `end := min(len, idx+len(q)+radius)`, snapped to UTF-8
   boundaries.
3. Build `("…" if start>0) + text[start:idx] + "[" + text[idx:idx+len(q)] + "]" + text[idx+len(q):end] + ("…" if end<len)`.
4. Collapse internal newlines/tabs to single spaces; hard cap length at ~160 chars.
- For SQL providers the preview is built from `match_text` (comment `body`, etc.), NOT from a
  raw column dump — only the bounded snippet crosses the wire.
- Under FTS (§8) the preview MAY instead use SQLite `snippet()` with the same `[`/`]` markers
  for consistency; the LIKE-based helper remains the fallback for non-FTS providers.

---

## 8. SEARCH-6 FTS5 plan (REQUIRED)

FTS5 is available in the linked runtime (`system:sqlite3`, nixpkgs; verified
`PRAGMA compile_options` → `ENABLE_FTS5`). Goal: fast body/content ranking for the two
free-text-heavy providers — **comments** and **skills** — without regressing the id/name
providers (which stay on the existing indexed-LIKE path).

### 8.1 Which tables get FTS5
- **comments** → external-content FTS5 over `task_comments.body` (external-content because the
  base table is the source of truth and we need `owner_user_id`/`task_id`/`chain_id` for
  scoping + routing, which we keep in the base row, not duplicated in the index).
- **skills** → NOT an FTS5 table. Skills are compiled-in strings (`STATIC_SKILLS`); the set is
  tiny (single digits) and rebuilt per binary. A linear in-memory scan (§5.2) is already
  sub-millisecond; adding an FTS table would need runtime backfill of static data for no gain.
  Preview uses the §7.2 helper. (Explicitly: skills are OUT of FTS by design.)
- Other providers (agent/instance/conversation/chain/task/project/artifact/memory) stay on the
  current indexed-LIKE queries — they match short id/name/title tokens where FTS gives no
  benefit and would complicate ranking. FTS is scoped to comment BODIES only in v1.

### 8.2 Schema (external-content FTS5)
New migration `029_search_fts_comments.sql` (+ embedded `MIGRATION_029_SEARCH_FTS_COMMENTS`,
appended to `migration_order`; renumbered 028->029 when landing on main, which already had a
`028_memory_description_and_cleanup.sql`). Follows the exact
on-disk-twin + embedded-fallback + idempotency-guard pattern (`migrations.odin` L765+,
L840+; guard style like the `026` `table_column_exists`/`sqlite_master` checks).
```sql
CREATE VIRTUAL TABLE IF NOT EXISTS task_comments_fts USING fts5(
  body,
  content='task_comments',
  content_rowid='rowid',
  tokenize='unicode61'
);
```
`content_rowid` uses `task_comments.rowid` (implicit; `comment_id` is a TEXT PK so the table
has an intrinsic rowid). We map FTS rowid → base row via JOIN on `rowid`.

### 8.3 Sync triggers (keep FTS consistent)
```sql
CREATE TRIGGER IF NOT EXISTS task_comments_ai AFTER INSERT ON task_comments BEGIN
  INSERT INTO task_comments_fts(rowid, body) VALUES (new.rowid, new.body);
END;
CREATE TRIGGER IF NOT EXISTS task_comments_ad AFTER DELETE ON task_comments BEGIN
  INSERT INTO task_comments_fts(task_comments_fts, rowid, body) VALUES('delete', old.rowid, old.body);
END;
CREATE TRIGGER IF NOT EXISTS task_comments_au AFTER UPDATE ON task_comments BEGIN
  INSERT INTO task_comments_fts(task_comments_fts, rowid, body) VALUES('delete', old.rowid, old.body);
  INSERT INTO task_comments_fts(rowid, body) VALUES (new.rowid, new.body);
END;
```
(The `'delete'` sentinel rows are the standard external-content contentless-delete idiom.)

### 8.4 Backfill (one-time, in the same migration, after table+triggers)
```sql
INSERT INTO task_comments_fts(rowid, body)
  SELECT rowid, body FROM task_comments
  WHERE rowid NOT IN (SELECT rowid FROM task_comments_fts);
```
Idempotency: the migration is guarded (skip if `task_comments_fts` already exists in
`sqlite_master`); the backfill `WHERE rowid NOT IN (...)` makes a re-run a no-op.

### 8.5 Ranking + preview on FTS
- Match: `WHERE task_comments_fts MATCH ?` with a sanitized query (wrap the user token in a
  quoted FTS string + trailing `*` for prefix: `"<q>"*`). Rank via `bm25(task_comments_fts)`
  (lower = better) mapped into the existing 0–100 integer score so the global merge sort is
  unchanged: `score := clamp(round(100 - bm25_normalized), 50, 98)`, with an exact/prefix
  boost preserved from §5.1 for parity with other providers.
- Preview: `snippet(task_comments_fts, 0, '[', ']', '…', 12)` — same `[match]` markers and
  ellipsis as §7.2, so the wire shape is consistent whether a hit came from FTS or LIKE.
- Scoped/excluded/owner predicates are applied on the JOINed base row (owner_user_id, scope
  columns) exactly as §6 — FTS only replaces the `body LIKE` predicate; it never bypasses
  owner isolation.
- Behavior for scopes NOT covered by FTS: unchanged (indexed-LIKE). The service picks the
  comment provider's FTS statement only when the FTS table exists (probe `sqlite_master`
  once at repo init); otherwise it falls back to the §5.1 LIKE statement. So a DB migrated
  before the FTS migrations, or a future provider without an FTS index, keeps working.

### 8.6 Static-test guard update (call out now)
`tests/test_hub_ui18_search_static.py` currently FORBIDS body/content scans
(`forbidden_scan_fields = ['chat_messages','body AS','content AS','memories.body','artifacts.content']`).
That guard encoded the v1 "no full-table body scan for perf" rule. SEARCH-6 satisfies the
SAME performance intent via an FTS index (not a full scan), so this test MUST be revised in
the implementation tasks to (a) allow `task_comments_fts` MATCH usage and the bounded
comment-body snippet, while (b) keeping the ban on UNINDEXED full-table `chat_messages`/
artifact-content scans. This is a required, in-scope test change — flagged here so review
expects it. A non-FTS `comment` LIKE fallback still avoids unbounded scans (indexed via §8.6
b-tree index below) but the FTS path is the primary.
- Also add b-tree index for the LIKE fallback + JOIN:
  `CREATE INDEX IF NOT EXISTS idx_search_task_comments_owner ON task_comments(owner_user_id, task_id, updated_at DESC, comment_id DESC);`
  (placed in `002_owner_scoped_core.sql`'s search-index block, matching the existing
  `idx_search_*` indexes the static test asserts).

### 8.7 SEARCH-10 — FTS5 everywhere + weighted bm25 + boosts (IMPLEMENTED)
SEARCH-10 broadens the FTS foundation from comment bodies to EVERY text-bearing scope
(migration 030): per-table external-content FTS5 vtables + ai/ad/au triggers + idempotent
backfill for chat_conversations(title), agents(name,slug,instructions),
agent_instances(display_name,agent_id), task_chains(title,description), tasks(title,description),
projects(name,slug,description), artifacts(name,description), memories(title,body). Migration
030 is a fixed-array `[29]->[30]` bump; the embedded constant is `#load`ed from the on-disk twin
(byte-identical by construction) and guarded by `fts5_available` (boot-safe: skipped => the
indexed-LIKE fallback still serves). A generic `Fts_Provider` descriptor + `build_fts_sql` render
the per-provider FTS query (one builder, not 8 constants).

Ranking (deterministic + cursor-safe):
- FIELD-WEIGHTED bm25: the per-provider inner `ORDER BY bm25(<tbl>_fts, W_PRIMARY, …)` weights
  the primary title/name column highest, choosing the most relevant rows within the scan cap.
- SCORE = tier CASE on the PRIMARY field, following the single canonical ladder:
  exact 100 / id-exact 98 / prefix 90 / word-boundary 80 / id-prefix 70 / primary-interior 50 /
  secondary-or-content 40. A row that matched FTS only in a secondary/body column gets the unified
  `FTS_TIER_SECONDARY :: 40` tier (never silently 0), which the same value used for skills
  content-only matches. matched_field is set to the primary (`label`) or the provider's secondary
  column. INVARIANT: any primary-field match (>=50) strictly outranks any secondary/body-only match
  (=40), and TYPE_PRIORITY (<=4) can never bridge the >=10-pt gap between tiers. This is the
  field-weighting the user sees: title/name matches rank above body/description matches, but the
  latter are still FOUND.
  - Comment provider exception (SEARCH-6): the `comment` provider legitimately keeps its own tiers
    (98/90/80/70/50) because for a comment the BODY *is* the primary field (its `label` is a
    substr of the body). So those are primary-field tiers, not the secondary=40 tier — the single
    canonical ladder above still holds for every provider whose primary field is a title/name.
- TYPE_PRIORITY: a small static, tunable addend (conversation+4, task+4, task-chain+3, agent+3,
  agent_instance+2, project+2, memory+2, artifact+1, comment+1, skill 0), clamped ≤100 and applied
  uniformly in the merge. Tiers are spaced ≥10 and the addend is ≤4, so it ONLY breaks same-tier
  cross-type ties (never lifts a lower tier above a higher one).
- RECENCY (decision A): the existing `updated_at DESC` secondary sort in the ORDER-BY anchor IS the
  recency mechanism. Recency is deliberately NOT blended into the score, because the score is the
  cursor key — a now-relative decay would make `next_cursor` time-dependent (dup/drop across pages).

Skills stay in-memory but gain the same token-AND multi-word matching (every alnum query token must
appear in the slug or content). Owner scoping, the SEARCH-8 typed filters, cursor total-order, and
snippet()-based preview (whitespace-collapsed) are preserved; each entity provider keeps its
indexed-LIKE variant as the FTS-absent fallback.

---

## 9. Summary of files to touch (for SEARCH-2..7; NO code in this task)
- `src/hub/transport/http/search_handlers.odin` — allowlist the typed id filters + `exclude`; read them; rewrite `write_search_hit_json` to the §2 shape; add `comment`/`skill` to response order.
- `src/hub/service/search/search_service.odin` — `Search_Input`+`Search_Query` typed filter fields; build the typed scope clause; apply `exclude`+preview at merge; merge-stage cursor.
- `src/hub/repository/iface/search_repo.odin` — `Search_Hit` gains `parent`/`preview`/`matched_field`; `Search_Query` gains the typed id filters + `exclude`.
- `src/hub/repository/sqlite/search_repo_sqlite.odin` — `comment` SQL (+FTS variant); scope predicate; type-order + alias additions.
- `src/hub/service/agent/…` skill provider matcher over `STATIC_SKILLS` (in-memory).
- `src/hub/repository/sqlite/migrations.odin` + `migrations/028_search_fts_comments.sql` — FTS table/triggers/backfill; `002_owner_scoped_core.sql` comment index.
- `src/ui/api/endpoints/search.ts` + `command-palette/CommandPalette.tsx` — consume the §2 hit shape (`type`/`parent`/`preview`/`matched_field`); add `Comments`/`Skills` group labels + icons (SEARCH UI task).
- `tests/` — `hub_search_owner_isolation_test.odin` (§6.1); revise `test_hub_ui18_search_static.py` (§8.6).

---

## 10. GATE
Blocked until: reviewer LGTM on this spec AND coordinator/user confirmation of the two open
decisions (§3 cursor activation; §5.2 skill route + skill owner-independence). Only then do
SEARCH-2..7 begin.
