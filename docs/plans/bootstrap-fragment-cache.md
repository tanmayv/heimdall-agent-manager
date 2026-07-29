# Bootstrap Fragment Cache (Hub ↔ Bridge) — Plan

## Goal

Stop re-transferring the whole agent bootstrap bundle on every instance launch.
Most of it (template persona, agent identity, system skills, applicable
memories, project block, task-guidance text) changes rarely and is shared across
many instances. Only a small dynamic slice (instance id, chain id, coordinator,
tokens, hub url) truly changes per run.

Design a **content-addressed fragment cache**: the Hub returns a small manifest
of fragment **hashes** + inline dynamic data; the bridge fetches only the
fragment bodies it does not already have and assembles `AGENTS.md` / skill files
locally.

Steady state per launch: one ~1 KB manifest, **zero** fragment bodies.

## Current State (what happens today)

- Route: `GET /api/v1/bridge/agent-instances/{id}/bootstrap`
  (`bridge_instance_bootstrap_handler`, `src/hub/transport/http/bridge_handlers.odin`).
- Builder: `bootstrap_json_for_bridge` (`src/hub/service/agent/agent_service.odin`)
  renders the **entire** bundle fresh on every call:
  - identity (`agent`, `owner_user`), bridge/runtime, project, chain,
    `task_context`, conversation `recent_messages` (twice!), `memory[]` array,
    the `AGENTS_MD` file `content` (with project block, tasks-guidance block,
    and memory markdown inlined), `default_skill_name` + `default_skill_content`,
    `instance_token`, `hub_url`.
- Materializer: `bridge_bootstrap_fetch_and_materialize`
  (`src/bridge/bootstrap_service.odin`) writes `AGENTS.md`, one SKILL.md,
  `.heimdall/bin/ham-ctl`, and `heimdall-bootstrap-manifest.json`. No caching.

Problems:
- Full re-render + full transfer every launch.
- `recent_messages` is embedded even though agents fetch chat via `ham-ctl`
  after notification (violates the metadata-only invariant and is the most
  volatile part).
- No dedup across instances/agents/bridges.

## Core Design

### 1. Fragments (rendered, then hashed)

Split the AGENTS.md assembly + skills into **named fragments**. Each fragment is
rendered to its final string, then addressed by `sha256(body)` → `hash`.

| Fragment section | Cache key source | Changes when |
|---|---|---|
| `header` | dynamic (inline, not hashed) | every run (tiny) |
| `agent_identity` | agent_id + agent.updated_at | agent edited |
| `template` | template_id + template.updated_at | template edited |
| `project` | project_id + project.updated_at | project edited |
| `tasks_guidance` | hub build id | code change |
| `memories` | agent_id + set of (memory_id@updated_at) | a memory approved/edited |
| `skill:<memory_id>` | memory_id + memory.updated_at | skill/migration edit |

Notes:
- **Hash the rendered output**, not the source row. This invalidates correctly
  when the *formatter code* changes, not just when a DB row changes. New content
  → new hash → one fetch → cached forever. Zero invalidation logic.
- `header` stays inline in the manifest (it is per-instance and tiny): agent
  name, instance id, chain id + title, coordinator line.
- **Drop `recent_messages`** from bootstrap entirely (agents fetch chat via
  `ham-ctl` after notification).

### 2. Manifest = assembly order + hashes + dynamic data

The bridge reconstructs `AGENTS.md` by concatenating section bodies in
`assembly` order (inline sections use `inline`, cached sections use `hash`),
then appending its local `bridge_bootstrap_ctl_guidance()` footer. Skills are
written to their `target` paths.

### 3. Bridge content-addressed blob cache

On-disk store keyed by hash, shared across all instances on that bridge:

```
<bridge.local_run_dir>/bootstrap-cache/
  blobs/<sha256>            # immutable fragment body (raw bytes)
  tmp/<sha256>.<rand>       # write-then-rename for atomicity
```

- Immutable by hash → safe to reuse forever, restart-safe.
- Size-bounded LRU (evict least-recently-read); a miss just re-fetches.

## API Endpoints

### A. Manifest (replaces full bootstrap for new bridges)

`GET /api/v1/bridge/agent-instances/{instance_id}/bootstrap?format=manifest`
Auth: bridge bearer token (unchanged).

Response `200`:

```jsonc
{
  "data": {
    "protocol": 2,
    "instance": {
      "agent_instance_id": "inst_18c6…",
      "agent_id": "agt_18c6…",
      "chain_id": "chain_18c6…",
      "coordinator_agent_instance_id": "inst_18c6…",
      "project_id": "proj_18c6…",
      "project_path": "/Users/me/code/site",
      "instance_token": "hit_inst_18c6…",
      "hub_url": "https://hub.mundus.in"
    },
    "files": [
      {
        "kind": "AGENTS_MD",
        "relative_path": "AGENTS.md",
        "assembly": [
          { "section": "header",         "inline": "# Agent bootstrap\n\nAgent: backend-dev\nInstance: inst_18c6…\nTask chain: Payments (chain_18c6…)\nCoordinator: you (coordinator)" },
          { "section": "agent_identity", "hash": "sha256:9f2b…" },
          { "section": "project",        "hash": "sha256:1a77…" },
          { "section": "tasks_guidance", "hash": "sha256:c0de…" },
          { "section": "memories",       "hash": "sha256:4d4d…" }
        ]
      }
    ],
    "skills": [
      {
        "kind": "SKILL",
        "name": "heimdall-ctl-communication",
        "target_hint": ".agents/skills/heimdall-ctl-communication/SKILL.md",
        "hash": "sha256:5e5e…"
      },
      {
        "kind": "SKILL",
        "name": "heimdall-task-workflow",
        "target_hint": ".agents/skills/heimdall-task-workflow/SKILL.md",
        "hash": "sha256:7a7a…"
      }
    ]
  },
  "meta": { "request_id": "req_…", "server_time": "2026-07-29T…Z" }
}
```

- `hash` uses the `sha256:<hex>` form (mirrors existing `sha1:` token-hash style).
- `target_hint` for skills: the Hub proposes a path, but the bridge maps skills
  into the **provider's** `skill_dir` (per-provider), so the final path is
  bridge-decided; `target_hint` is advisory.
- The Hub computes hashes via an in-memory LRU keyed by
  `(section, source_id, source_updated_at)` so repeated launches skip re-render.

### B. Blob batch fetch (only missing hashes)

`POST /api/v1/bridge/blobs`
Auth: bridge bearer token. Body:

```jsonc
{ "hashes": ["sha256:1a77…", "sha256:4d4d…"] }
```

Response `200`:

```jsonc
{
  "data": {
    "blobs": [
      { "hash": "sha256:1a77…", "body": "## Project\nName: …\nPath: …" },
      { "hash": "sha256:4d4d…", "body": "## Applicable Memories / Skills\n…" }
    ],
    "missing": []          // hashes the Hub could not resolve (should be empty)
  },
  "meta": { … }
}
```

- Bodies are the exact rendered fragment strings (bridge verifies
  `sha256(body) == hash` before caching; mismatch → discard + fall back).
- `missing` lets the bridge fall back to full bootstrap if the Hub ever can't
  serve a referenced hash (e.g. LRU evicted mid-flight — see "Hub blob source").
- Batching keeps it to a single round-trip for all misses.

### C. Legacy full bootstrap (unchanged, for old bridges / fallback)

`GET /api/v1/bridge/agent-instances/{instance_id}/bootstrap`
Returns the current full bundle (protocol 1). Kept indefinitely; new bridges use
it only as a fallback when manifest/blob flow fails.

## Hub Blob Source (how B resolves a hash)

Two robust options; recommend **(1)**:

1. **Deterministic re-render on demand.** The Hub re-renders the requested
   fragment from current state and checks its hash matches. This works because
   fragments are pure functions of durable state; if state changed since the
   manifest, the hash won't match and the Hub returns it under `missing` →
   bridge refetches the manifest. Stateless, no blob store to manage.
   - To resolve "which fragment does this hash correspond to", the Hub keeps a
     small **hash → (section, source_id)** LRU (populated when the manifest was
     built). On a cold miss, it can rebuild the manifest for the instance and
     resolve from there.
2. **Short-TTL blob cache** on the Hub (hash → body) populated at manifest time.
   Simpler resolution, but adds memory + eviction races. Only add if (1) proves
   awkward.

## Flow Diagrams

### Cache HIT (steady state — everything already cached)

```
Bridge                                  Hub
  |  GET /bootstrap?format=manifest      |
  |------------------------------------->|  render header (inline) +
  |                                      |  compute/lookup fragment hashes (LRU)
  |   200 manifest (hashes only, ~1KB)   |
  |<-------------------------------------|
  |                                      |
  | for each hash in manifest:           |
  |   present in blobs/<hash>?  YES (all) |
  |                                      |
  | (NO POST /bridge/blobs call)         |
  |                                      |
  | assemble AGENTS.md = concat(         |
  |   header.inline,                     |
  |   cache[agent_identity],             |
  |   cache[project],                    |
  |   cache[tasks_guidance],             |
  |   cache[memories]) + ctl_footer      |
  | write skills from cache[skill:*]     |
  | write .heimdall/bin/ham-ctl (tokens) |
  | write manifest.json                  |
  | tmux launch in run_dir               |
```

Transfer: 1 request, 1 small manifest response. No blob bodies.

### Cache MISS (new bridge, or a fragment changed)

```
Bridge                                  Hub
  |  GET /bootstrap?format=manifest      |
  |------------------------------------->|
  |   200 manifest (hashes)              |
  |<-------------------------------------|
  |                                      |
  | missing = [h in manifest             |
  |            if not blobs/<h>]         |
  |   e.g. [project, memories]           |
  |                                      |
  |  POST /bridge/blobs {hashes:[h2,h4]} |
  |------------------------------------->|  re-render fragments,
  |                                      |  verify hash, return bodies
  |   200 { blobs:[{h2,body},{h4,body}]  |
  |         missing:[] }                 |
  |<-------------------------------------|
  |                                      |
  | verify sha256(body)==hash            |
  | write blobs/<h2>, blobs/<h4> (atomic)|
  |                                      |
  | assemble AGENTS.md + skills          |
  | (all fragments now present)          |
  | write ham-ctl + manifest.json        |
  | tmux launch                          |
```

Transfer: 1 manifest + only the changed/new fragment bodies. Next launch of any
instance on this bridge that reuses those fragments = full HIT.

### Partial MISS after a memory change (only the changed fragment refetched)

Steady state: this bridge has previously cached every fragment for this agent.
A user then approves/edits one memory. On the next launch, only the `memories`
fragment hash changes (its rendered body differs → new sha256); all other
fragment hashes are unchanged and still cached.

```
Bridge                                  Hub
  |  GET /bootstrap?format=manifest      |
  |------------------------------------->|  header inline;
  |                                      |  hashes: agent_identity=9f2b (same),
  |                                      |          project=1a77 (same),
  |                                      |          tasks_guidance=c0de (same),
  |                                      |          memories=NEW 8bb1  ← changed
  |   200 manifest (hashes)              |
  |<-------------------------------------|
  |                                      |
  | check each hash against blobs/:      |
  |   9f2b HIT   1a77 HIT   c0de HIT     |
  |   8bb1 MISS  ← only this one         |
  |                                      |
  |  POST /bridge/blobs {hashes:[8bb1]}  |   (single hash)
  |------------------------------------->|  re-render `memories` for this
  |                                      |  agent, verify hash, return body
  |   200 { blobs:[{8bb1,body}],         |
  |         missing:[] }                 |
  |<-------------------------------------|
  |                                      |
  | verify sha256(body)==8bb1            |
  | write blobs/8bb1 (atomic)            |
  |                                      |
  | assemble AGENTS.md =                 |
  |   header.inline +                    |
  |   cache[9f2b] + cache[1a77] +        |
  |   cache[c0de] + cache[8bb1] + footer |
  | (old memories blob 4d4d stays in     |
  |  cache; LRU-evicted eventually)      |
  | write ham-ctl + manifest.json        |
  | tmux launch                          |
```

Transfer: 1 manifest + exactly **one** fragment body (the changed `memories`
section). Everything else is served from cache. The previous `memories` blob
(`4d4d`) is now unreferenced and ages out via LRU — no explicit invalidation.

### Fallback (manifest/blob flow fails)

```
Bridge: manifest error OR blobs.missing non-empty OR hash-verify fails
  → GET /bootstrap   (legacy full bundle, protocol 1)
  → materialize as today
```

## Bridge Cache Layout & Lifecycle

```
<local_run_dir>/bootstrap-cache/
  blobs/sha256_<hex>          # immutable body
  tmp/sha256_<hex>.<rand>     # staged write, fsync + rename → blobs/
  index.jsonl                 # optional: {hash, size, last_used_ms} for LRU
```

- **Write**: stage in `tmp/`, `sha256` verify, atomic rename into `blobs/`.
- **Read**: `blobs/<hash>` exists → hit; touch `last_used_ms`.
- **Evict**: when total size > `bootstrap_cache_max_bytes` (config, default e.g.
  256 MB), delete least-recently-used blobs. Safe: a later miss re-fetches.
- **Restart-safe**: cache survives bridge restarts (on-disk, content-addressed).
- **Corruption-safe**: on read, optionally re-verify hash; mismatch → delete +
  treat as miss.

## Backward Compatibility & Rollout

- **Capability-gated.** Bridge advertises `bootstrap_fragment_cache: true` in its
  hello/capabilities. Hub serves manifest only when asked (`?format=manifest`);
  otherwise full bundle.
- Old bridges: unchanged (`GET /bootstrap`).
- New bridges: try manifest → blobs; **any** failure falls back to full bundle,
  so correctness never depends on the cache.
- No agent-visible change: the final `AGENTS.md` + skill files are byte-identical
  to today (assembled from the same fragments), minus `recent_messages`.

## Tasks

### Task 1 — Hub: refactor bootstrap into named fragments [COMPLETED]
- Extract the inline AGENTS_MD sections in `bootstrap_json_for_bridge` into pure
  render procs returning strings: `render_agent_identity`, `render_project`,
  `render_tasks_guidance`, `render_memories_markdown`, `render_skill(memory)`.
- Add `sha256` (core:crypto/hash) hashing helper `bootstrap_fragment_hash`.
- Remove `recent_messages` from the bootstrap payload.
- Files: `src/hub/service/agent/agent_service.odin`.

### Task 2 — Hub: manifest endpoint + hash LRU [COMPLETED]
- `GET …/bootstrap?format=manifest` → build header inline + fragment hashes.
- Add `(section, source_id, source_updated_at) → (hash, body)` LRU to skip
  re-render and to resolve blob requests.
- Keep the legacy full endpoint intact (protocol 1).
- Files: `bridge_handlers.odin`, `wiring.odin`, `agent_service.odin`.

### Task 3 — Hub: `POST /api/v1/bridge/blobs` [COMPLETED]
- Resolve each hash by re-render or LRU; verify; return `blobs` + `missing`.
- Files: `bridge_handlers.odin`, `wiring.odin`.

### Task 4 — Bridge: content-addressed blob cache [COMPLETED]
- Implement `bootstrap-cache/` store: `has(hash)`, `get(hash)`, `put(hash,body)`
  with atomic write + verify + LRU eviction (`bootstrap_cache_max_bytes`).
- Files: new `src/bridge/bootstrap_cache.odin`.

### Task 5 — Bridge: manifest fetch + local assembly + fallback [COMPLETED]
- New `bridge_bootstrap_fetch_manifest_and_materialize`: fetch manifest, compute
  missing, one `POST /bridge/blobs`, verify+cache, assemble AGENTS.md (+ ctl
  footer), write skills into provider `skill_dir`, write `ham-ctl` + manifest.
- On any failure → call existing full-bundle path.
- Advertise `bootstrap_fragment_cache` capability.
- Files: `src/bridge/bootstrap_service.odin`, `hub_runtime_client.odin`,
  `main.odin` (capabilities).

### Task 6 — Config + docs [COMPLETED]
- Config: `bootstrap_cache_max_bytes` (bridge). Default 256 MB.
- Update `AGENTS.md` architecture notes + this doc's status.

### Task 7 — E2E verification
- Launch instance A on a fresh bridge → miss path fetches fragments; verify
  AGENTS.md byte-identical to legacy (minus recent_messages).
- Launch instance B (same agent) → full HIT, zero blob bodies transferred
  (assert via bridge log / request count).
- Edit a memory → only `memories` fragment refetched on next launch.
- Kill/restart bridge → cache persists, next launch still HIT.
- Old-bridge path (no capability) still uses full bundle.

## Sequencing

1. Task 1 (fragment render + hash; drop recent_messages) — foundational.
2. Task 2 (manifest) + Task 3 (blobs) — Hub API.
3. Task 4 (bridge cache) → Task 5 (bridge manifest flow + fallback).
4. Task 6 (config/docs) → Task 7 (E2E).

## Risks / Notes

- **Hash the rendered bytes**, never the source row, so formatter changes
  invalidate correctly.
- **Fallback must be total**: any manifest/blob/verify error → legacy full
  bundle. The cache is an optimization, never a correctness dependency.
- **Do not embed chat**: `recent_messages` is removed; agents fetch via
  `ham-ctl` (matches the metadata-only invariant).
- **Skill target is bridge-decided** (provider `skill_dir`); Hub `target_hint`
  is advisory — this is also why a provider without `skill_dir` skips skills
  (separate existing bug, out of scope here).
- **Tokens/dynamic data are never cached** — they live only in the manifest
  `instance` block and the `ham-ctl` wrapper, regenerated each run.
- Immutable blobs mean the Hub can also set long `Cache-Control`/`ETag` on blob
  responses if you later want HTTP-proxy caching for free.
