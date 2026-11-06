# Where the chain time went

At the cutoff, the chain had elapsed 11h 57m 26s: 15 tasks done, 2 cancelled, 7 queued and 1 in progress. Its 1,506 recorded shell sessions sum to 3h 57m 26s, or 3h 16m 20s after overlap. The accepted tree changes 161 files, +20,621/−145 LOC. Scope expansion, serial implementation, real regressions and integration work explain measured delays; missing phase data prevents attributing all remaining time.

Cutoff: **2026-11-06T14:44:57Z** (20:14:57 IST). Chain: chain_18e554c99be21d02.

## Measured time

- Chain wall age: **11h 57m 26s**.
- Shell span sum: **3h 57m 26s**; union: **3h 16m 20s** (27.4% of wall age).
- The other **8h 41m 06s** is unclassified by shell records, not measured thinking/idle time.
- Attempt envelopes: **12h 06m 09s** summed; **10h 25m 43s** union. Overlap duplicates **1h 40m 26s**.
- Attribution: **163 high** (reference+agent window), **1,318 medium** (agent window), **25 unassigned** records (**41s** union). Known-instance/time-range totals remain provisional for ownership of the unassigned part.
- Shell union intersecting any attempt envelope: **3h 10m 36s**. Subprocess runtime, launch queue and CPU use: **N/A**.

## Why it took this long

### Scope expanded from a vertical slice to native parity.

The original broad M1 was replaced before implementation. Later audits established that narrow owner-local slices lacked full native task and workflow parity. Broad C1 grew to a 240-field/23-struct ledger and six attempts, then became C1a–C1f with its checkpoint preserved. C1's 5h 25m created-to-cancellation age includes 3h 01m before first start; first-start-to-cancellation was 2h 24m, not 5h of uninterrupted coding.

Evidence: task_18e556f8ef2f0c8d; task_18e569e48d6b5532 runtime/handoff facets; cmt_18e5754ba6b1830f.

### Most elapsed time followed one implementation stream.

The primary worker has10h 16m 31s of recorded attempt envelopes inside 11h 57m 26s of chain age. The second worker contributes 1h 49m 38s, mostly overlapping. The observed order was plan → contracts → V1 → foundations → leases → lifecycle → search → controls → static workflows → full workflow language → C1 → C1a → C1b. Adding task ages would count dependencies and parallel time repeatedly.

Evidence: All runtime facets; task timestamps/dependencies. Exact historical dependency revisions are unavailable..

### Independent review caught concrete correctness defects.

Findings included receipt replay ordering, publication-result persistence, encoded response overflow, historical output indexing, source ACK/retry recovery, ordinary/static on_output coverage, and submitted human approval binding. C1a also fixed a retirement outcome missing from both wire validators. Their regression runs were validation of real fixes, not automatically waste.

Evidence: Plan attempt3; M1b attempt2; V1 attempt4; M2 attempt3; M2c attempt4; workflow language attempts4/5; C1a d78c6c54.

### Integration caused distinct rework.

M2c attempts5/6 resolved two shared harness conflicts, then fourteen grants/workflow conflicts including competing migration_008.sql files. Later compaction/workflow integration had to preserve accepted migration lineage. These were integration changes after parallel work, distinct from new product review defects.

Evidence: task_18e562f7b94d63bb handoff facets attempts5/6; cmt_18e56d1a80a6993d; task_18e56a0d15295083 attempt6.

### Real demos were expensive, but do not explain all elapsed time.

Nine evidence-linked demos among the ten largest shell records sum to 34m 12s of recorded spans. They followed changed source, held-lease/retirement/history fixes and committed/release binary verification. Child stages are not added again. Dependency installs, fixture repairs and failed drafts recur in handoffs, but unavailable command metadata prevents reliable full category costs.

Evidence: Top sessions below; C1 attempts2–6; compaction handoff; known baseline failures remain qualified.

## Every task at the cutoff

Ages run from creation to completion/cancellation or cutoff. First-start elapsed excludes pre-start wait. Attempt envelopes may span renewed leases/restarts; review bounds use comments, not exact closed leases. Task LOC rows show retained net and overlap for old C1/C1a. Queued tasks have waiting age, not completed duration.

| Task | Status | Age min | First-start min | Pre-wait min | Attempt min | Review min | Gap min | Files | +LOC | −LOC | Shell count | Shell sum min | Shell union min |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Plan Bridge-owned runtime and searchable local storage (task_18e554dbf43e7642) | done | 37.6 | 37.2 | 0.4 | 31.6 | 0.9 | 4.8 | 1 | 211 | 0 | 33 | 0.1 | 0.1 |
| M1: Owner-local runtime end to end (task_18e556f8ef2f0c8d) | cancelled | 3.9 | 3.9 | 0.0 | 1.3 | 0.0 | 2.6 | 0 | 0 | 0 | 2 | 0.0 | 0.0 |
| M2: Complete local commands and scoped search (task_18e556f901cbcf41) | done | 278.5 | 61.2 | 217.3 | 52.3 | 6.6 | 2.4 | 36 | 1207 | 75 | 108 | 18.3 | 16.0 |
| M3: Fenced remote execution and slot reservations (task_18e556f90cfa1e9c) | backlog | 677.4 | N/A | 677.4 | 0.0 | 0.0 | N/A | 0 | 0 | 0 | 0 | 0.0 | 0.0 |
| M4: Migration and recovery integration gate (task_18e556f919c82490) | backlog | 677.4 | N/A | 677.4 | 0.0 | 0.0 | N/A | 0 | 0 | 0 | 0 | 0.0 | 0.0 |
| M1a: Strict owner and command contracts (task_18e55714c3bb18ea) | done | 36.8 | 36.8 | 0.0 | 17.3 | 1.6 | 17.9 | 13 | 1573 | 1 | 42 | 1.1 | 1.1 |
| M1b: Local transactional admission and receipts (task_18e55714d71968b1) | done | 137.8 | 36.4 | 101.4 | 32.8 | 2.8 | 0.8 | 20 | 1301 | 49 | 49 | 6.2 | 5.9 |
| M1c: Integrate owner-local runtime end to end (task_18e5571bd785f30b) | done | 176.4 | 39.0 | 137.3 | 34.8 | 2.5 | 1.8 | 35 | 1320 | 50 | 64 | 12.4 | 10.6 |
| V1: Runnable owner-local task and comment slice (task_18e55735054e37f6) | done | 99.0 | 64.5 | 34.6 | 53.5 | 8.2 | 2.8 | 34 | 1622 | 6 | 170 | 11.5 | 9.4 |
| M1d: Complete local submit and review lifecycle (task_18e55eb775acfc0f) | done | 75.3 | 38.3 | 37.0 | 34.3 | 3.2 | 0.8 | 37 | 1629 | 49 | 49 | 8.2 | 7.5 |
| M2b: Local controls and assignment lifecycle (task_18e562f7a4bb62aa) | done | 103.6 | 44.9 | 58.8 | 33.4 | 9.7 | 1.8 | 35 | 1300 | 57 | 54 | 12.3 | 10.6 |
| M2c: Workflows and source episode recovery (task_18e562f7b94d63bb) | done | 198.4 | 94.7 | 103.7 | 83.3 | 7.9 | 3.5 | 39 | 1962 | 57 | 146 | 28.9 | 26.2 |
| Audit merged runtime against overall Bridge-owned goal (task_18e568efcfe3e1c6) | done | 15.8 | 15.8 | 0.0 | 14.3 | 1.1 | 0.4 | 1 | 110 | 0 | 52 | 0.1 | 0.1 |
| Fix audited owner publication and registry pagination (task_18e569e455cd82bb) | done | 24.8 | 24.8 | 0.0 | 23.1 | 1.3 | 0.4 | 14 | 593 | 19 | 42 | 11.7 | 10.6 |
| Implement audited signed device-grant lifecycle (task_18e569e4750fe9fd) | done | 53.4 | 28.6 | 24.9 | 25.8 | 2.2 | 0.6 | 24 | 942 | 27 | 103 | 10.0 | 7.8 |
| Close audited full task aggregate and command parity (task_18e569e48d6b5532) | cancelled | 325.4 | 143.9 | 181.5 | 124.0 | 0.0 | 20.0 | 49 | 2784 | 100 | 165 | 44.7 | 39.4 |
| Preserve audited canonical linked content and envelopes (task_18e569e4a29a0fbe) | backlog | 330.7 | N/A | 330.7 | 0.0 | 0.0 | N/A | 0 | 0 | 0 | 0 | 0.0 | 0.0 |
| Complete owner-local workflow.v1 language parity (task_18e56a0d15295083) | done | 178.5 | 109.9 | 68.7 | 101.0 | 5.2 | 3.6 | 42 | 3549 | 38 | 206 | 44.1 | 37.9 |
| Bridge-owned chain compaction and overflow notification fix (task_18e56d155e88f266) | done | 49.6 | 49.6 | 0.0 | 46.5 | 2.7 | 0.4 | 36 | 950 | 140 | 164 | 26.6 | 20.6 |
| C1a: Review preserved event and hold foundation (task_18e57ad52bb4ea63) | done | 9.6 | 9.6 | 0.0 | 6.3 | 2.9 | 0.4 | 49 | 2875 | 100 | 25 | 0.3 | 0.3 |
| C1b: Native attempt history and typed facet parity (task_18e57ad551f091b8) | in_progress | 20.2 | 10.7 | 9.6 | 10.7 | 0.0 | 0.0 | 0 committed; working N/A | 0 | 0 | 7 | 0.2 | 0.2 |
| C1c: Native attempt-budget admission parity (task_18e57ad568e635ed) | backlog | 20.2 | N/A | 20.2 | 0.0 | 0.0 | N/A | 0 | 0 | 0 | 0 | 0.0 | 0.0 |
| C1d: Complete canonical metadata and configuration (task_18e57ad57cef82ce) | backlog | 20.2 | N/A | 20.2 | 0.0 | 0.0 | N/A | 0 | 0 | 0 | 0 | 0.0 | 0.0 |
| C1e: Local proposals publication and mixed-work graph (task_18e57ad591fe06b0) | backlog | 20.2 | N/A | 20.2 | 0.0 | 0.0 | N/A | 0 | 0 | 0 | 0 | 0.0 | 0.0 |
| C1f: Rich aggregate proof and final parity gate (task_18e57ad5a65c6c86) | backlog | 20.2 | N/A | 20.2 | 0.0 | 0.0 | N/A | 0 | 0 | 0 | 0 | 0.0 | 0.0 |

## Git provenance and deduplication

Exact accepted net: ada2d4c8 → d78c6c54,161 files, +20,621/−145 = +20,476 lines. Integration bases remove inherited work: ec3bdaab→a1ff381b (M2c), a1ff381b→c04b5610 (compaction), c04b5610→6b076ac7 (workflow language). Other bases are the first owned commit's parent. Per-task new net line deltas reconcile to+20,476.

Old C1:6b076ac7→bfac0d0d,+2,784/−100 across 49 files. Its nine commits were copied into C1a: bfac0d0d and 4867e4fa have identical trees. C1a retained net is+2,875/−100; its new correction bfac0d0d→d78c6c54 is only+93/−2 across 5 files. Count preserved work once.

Deduplicated nonmerge authored gross churn:+21,234/−877 across 157 unique paths. Merge resolution-only remerge diffs are separate diagnostics, not added to gross totals because they include synthetic conflict cleanup. Final accepted net is the authoritative unique-chain size.

| Task | Net base → head | Files / + / − |
|---|---|---:|
| Plan Bridge-owned runtime and searchable local storage | ada2d4c8 → 1c83a464 | 1 / +211 / −0 |
| M2: Complete local commands and scoped search | 21072f5c → 6e87ca20 | 36 / +1207 / −75 |
| M1a: Strict owner and command contracts | 1c83a464 → b4b34929 | 13 / +1573 / −1 |
| M1b: Local transactional admission and receipts | 47ee1544 → f4cd91d9 | 20 / +1301 / −49 |
| M1c: Integrate owner-local runtime end to end | f4cd91d9 → 233014ae | 35 / +1320 / −50 |
| V1: Runnable owner-local task and comment slice | b4b34929 → 47ee1544 | 34 / +1622 / −6 |
| M1d: Complete local submit and review lifecycle | 233014ae → 21072f5c | 37 / +1629 / −49 |
| M2b: Local controls and assignment lifecycle | 6e87ca20 → 37495ef4 | 35 / +1300 / −57 |
| M2c: Workflows and source episode recovery | ec3bdaab → a1ff381b | 39 / +1962 / −57 |
| Audit merged runtime against overall Bridge-owned goal | 37495ef4 → f3cc56d1 | 1 / +110 / −0 |
| Fix audited owner publication and registry pagination | f3cc56d1 → 6bb3864d | 14 / +593 / −19 |
| Implement audited signed device-grant lifecycle | 6bb3864d → ec3bdaab | 24 / +942 / −27 |
| Close audited full task aggregate and command parity | 6b076ac7 → bfac0d0d | 49 / +2784 / −100 |
| Complete owner-local workflow.v1 language parity | c04b5610 → 6b076ac7 | 42 / +3549 / −38 |
| Bridge-owned chain compaction and overflow notification fix | a1ff381b → c04b5610 | 36 / +950 / −140 |
| C1a: Review preserved event and hold foundation | 6b076ac7 → d78c6c54 | 49 / +2875 / −100 |

| Final accepted category | Files | Added | Deleted |
|---|---:|---:|---:|
| docs | 18 | 2938 | 5 |
| source/tooling | 95 | 8921 | 136 |
| tests | 46 | 7223 | 4 |
| generated | 2 | 1539 | 0 |

## Largest ten recorded shell spans

Nine documented real demos sum to 34m 12s; the tenth category is unknown (3m 41s). These are wrapper spans; no nested stages are added. Context labels come from task evidence, not decrypted command metadata. Full build/test/install/Git/read category totals are N/A.

| Session | Task | UTC start | Span | Exit | Evidence |
|---|---|---|---:|---:|---|
| sh_89b935730f7edd8a64b3d9a08dbf79d0 | Close audited full task aggregate and command parity | 2026-11-06T12:59:37Z | 4m 15s | 0 | cmt_18e576a45c6f446c |
| sh_41d90a59840bde07efde87b5becce2a8 | Close audited full task aggregate and command parity | 2026-11-06T14:10:42Z | 3m 48s | 0 | cmt_18e57a53fec92a44 |
| sh_a99440d70ac86a250d1f84345eda8f1c | Close audited full task aggregate and command parity | 2026-11-06T13:20:17Z | 3m 47s | 0 | cmt_18e5778943098d67 |
| sh_1681df9dd0e44a4745b90f2ee84af722 | Close audited full task aggregate and command parity | 2026-11-06T13:03:10Z | 3m 46s | 0 | cmt_18e576a45c6f446c |
| sh_bb45fb95ba0e364ecd76f59d21aecfed | Close audited full task aggregate and command parity | 2026-11-06T13:43:15Z | 3m 46s | 0 | cmt_18e578cf990a27ce |
| sh_2007a293a1458ffe8eb4d15b2fcb0b38 | Close audited full task aggregate and command parity | 2026-11-06T12:32:47Z | 3m 45s | 0 | cmt_18e574fd4a8fea55 |
| sh_b3ff73443bb29f7bcd8aca0b82949c47 | Close audited full task aggregate and command parity | 2026-11-06T12:38:18Z | 3m 43s | 0 | cmt_18e5754ba6b1830f |
| sh_a05b7f280555b9b777933b25c6cec1dc | Bridge-owned chain compaction and overflow notification fix | 2026-11-06T10:47:55Z | 3m 41s | 0 | cmt_18e56f42fcf85dea |
| sh_9c093bafbdc09c18bf01c2ff68b64921 | Bridge-owned chain compaction and overflow notification fix | 2026-11-06T10:52:05Z | 3m 41s | 0 | cmt_18e56f42fcf85dea |
| sh_ea11b6d3f28680a3230f92cf5c6e6554 | Complete owner-local workflow.v1 language parity | 2026-11-06T11:34:12Z | 3m 41s | 0 | category unavailable; agent-window only |

## Coverage and limits

| Instance | Full page | Before chain | After cutoff | In range | has_more |
|---|---:|---:|---:|---:|---|
| inst_18e554c99e0743ee | 12 | 0 | 0 | 12 | false |
| inst_18e554e13ee165a7 | 966 | 0 | 7 | 959 | false |
| inst_18e5568123390193 | 174 | 0 | 0 | 174 | false |
| inst_18e568efd2a64539 | 316 | 0 | 15 | 301 | false |
| inst_18e569b6fc61248b | 60 | 0 | 0 | 60 | false |

- Cutoff: 2026-11-06T14:44:57Z (20:14:57 IST). Metadata was fetched approximately14:48–14:51 UTC and reconstructed using timestamps and immutable facets/commits. The report task was created14:46:45 UTC and is excluded, as are later implementation commits.
- All five historical instances were confirmed through task/comment/review identities. Each full shell page returned has_more=false; chain-scoped server listing was empty. Deduplication uses session_id.22 post-cutoff records were excluded. Ordinary200-record cursor pages demonstrably repeated/skipped records; a10,000-record single-page read recovered full authorized listings.
- Command/cwd/label fields are blank in authorized list/show. Old Bridge spawn specs had been removed; only the current post-cutoff spec remained. Most task attribution therefore uses agent plus attempt/review-comment time windows. Confidence and an unassigned bucket are explicit; same-instance/time-range membership alone is not proof of chain ownership.
- The 1,506 entries are session records, not individual child commands. Nested build/test/demo stages are not summed. Unmanaged direct terminal commands are unmeasured. Second-resolution zero spans indicate insufficient granularity, not zero execution cost.
- Exact historical review leases, every submit/rework transition, hold/block/outage intervals and launch/runtime splits were not exposed by list/show/facet records. Some handoffs are truncated; facets expose their latest version only. Narrative restarts/connectivity cannot be converted into precise outage seconds.
- 214 records have nonzero exit codes; five statuses are failed and 1,501 exited. Nonzero exits include intentional rejection probes and drafts, not 214 product regressions. Compaction's handoff records three unchanged taskv2 baseline failures: clock-jump expiry, removed-verify migration, fleet-delete gate (184-test baseline versus186-test changed suite). No blanket suite-green claim is made.
- C1b had no committed checkpoint before cutoff. Committed delta is 0; its uncommitted working delta is N/A. M3/M4/C3/C1c–f were unstarted with 0 committed changes; their waiting ages are not execution estimates.
- Token usage and monetary cost are unmeasured. Mutable current dependencies do not recover the exact historical critical-path graph. The observed serial stream is reported without invented exact critical-path attribution.

## Metric definitions

- **Chain elapsed:** Cutoff minus chain creation: wall-clock age, not a sum of task durations.
- **Created / first-start elapsed:** Creation or first task start to completion/cancellation; unfinished tasks stop at cutoff. Queue-only tasks show waiting age, not a completed duration.
- **Pre-start wait:** First start minus creation, or cutoff minus creation when unstarted. Dependency, dispatch and hold wait cannot be split from these records.
- **Attempt envelope:** Union of Hub runtime-facet started_at/ended_at intervals clipped at cutoff. A logical attempt can span restarts/renewed leases; this is not exact live-lease or productive time.
- **Review bounds / unclassified:** Earliest-to-latest reviewer comments in the same gap between attempt envelopes. These are observed bounds, not full review lease durations. Remaining first-start elapsed is unclassified, not measured model thinking.
- **Shell sum / union:** Sum of unique Hub session spans; union removes overlap. Includes launch and exit-delivery latency. Separate subprocess runtime, launch queue and CPU use are unknown.
- **Files / added / deleted LOC:** Exact retained net diff between the task-specific Git base and checkpoint/submitted head, with rename detection. Integration bases remove inherited changes. Old C1/C1a retained rows overlap and must not be added.
- **Gross churn:** Deduplicated nonmerge first-parent commit diffs. Merge resolution-only remerge diffs are separate diagnostics because synthetic conflict cleanup is not authored LOC.

## Five improvements

1. **Define parity before implementing the first slice.** Inventory native fields/commands up front. Give each bounded task an explicit accepted subset and mandatory successor; distinguish a usable vertical slice from full migration readiness. This targets the M1/C1/workflow scope revisions.
2. **Coordinate migration numbering and shared harness edits.** Reserve migration numbers in a small integration ledger, or rebase a schema-changing task onto the accepted incoming parent before its final demo. Preserve independent review while reducing migration collisions and combined reruns.
3. **Reuse exact-head verification evidence.** Attach source head, toolchain, fixture hash, session ID and nonzero test count. Recheck affected suites after source changes and one combined final smoke path; reuse unchanged evidence in delta reviews. Keep known baseline failures explicit.
4. **Persist boundary measurement metadata.** Record task/lease/worktree IDs on shell sessions, actual process start/end and launch queue, plus immutable review/hold/block/outage intervals. Fix the pagination cursor separately. This improves attribution without storing private output.
5. **Checkpoint bounded deliverables before context churn.** Use a native handoff with a small verified checkpoint and precise remaining ledger. Cache pinned worktree dependencies and supply focused test/demo commands. Keep independent reviewers; avoid re-reading whole history each continuation.

## Reproduce and independently audit

Frozen calculations: metrics.json; task summary: tasks.csv. Raw authorized CLI snapshots remain in the local analysis cache; SHA-256 digests are in metrics.json. Exact runtime facet IDs, review comment bounds, session IDs, Git parents/numstats and copy mappings support independent validation. No command output logs or credentials are packaged.

```bash
python3 reports/chain-timing/collect.py --cli /absolute/path/to/bin/ham-ctl --out /analysis/cache
python3 reports/chain-timing/analyze.py --snapshot /analysis/cache
python3 reports/chain-timing/render.py
python3 reports/chain-timing/validate.py --metrics reports/chain-timing/metrics.json
git diff --numstat -M ada2d4c8 d78c6c54
git diff --exit-code bfac0d0d 4867e4fa
```

Collection is live and cannot recreate overwritten historical event versions. Use the frozen metrics artifact for this cutoff. Validator recomputes sums/unions and checks Git objects independently of the aggregation implementation. Independent review remains required; no self-approval is implied.
