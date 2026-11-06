"""Shared report narrative; all claims concern the fixed cutoff."""
FINDINGS=[
("Scope expanded from a vertical slice to native parity.",
"The original broad M1 was replaced before implementation. Later audits established that narrow owner-local slices lacked full native task and workflow parity. Broad C1 grew to a 240-field/23-struct ledger and six attempts, then became C1a–C1f with its checkpoint preserved. C1's 5h25m created-to-cancellation age includes 3h01m before first start; first-start-to-cancellation was2h24m, not5h of uninterrupted coding.",
"task_18e556f8ef2f0c8d; task_18e569e48d6b5532 runtime/handoff facets; cmt_18e5754ba6b1830f"),
("Most elapsed time followed one implementation stream.",
"The primary worker has10h16m31s of recorded attempt envelopes inside11h57m26s of chain age. The second worker contributes1h49m38s, mostly overlapping. The observed order was plan → contracts → V1 → foundations → leases → lifecycle → search → controls → static workflows → full workflow language → C1 → C1a → C1b. Adding task ages would count dependencies and parallel time repeatedly.",
"All runtime facets; task timestamps/dependencies. Exact historical dependency revisions are unavailable."),
("Independent review caught concrete correctness defects.",
"Findings included receipt replay ordering, publication-result persistence, encoded response overflow, historical output indexing, source ACK/retry recovery, ordinary/static on_output coverage, and submitted human approval binding. C1a also fixed a retirement outcome missing from both wire validators. Their regression runs were validation of real fixes, not automatically waste.",
"Plan attempt3; M1b attempt2; V1 attempt4; M2 attempt3; M2c attempt4; workflow language attempts4/5; C1a d78c6c54"),
("Integration caused distinct rework.",
"M2c attempts5/6 resolved two shared harness conflicts, then fourteen grants/workflow conflicts including competing migration_008.sql files. Later compaction/workflow integration had to preserve accepted migration lineage. These were integration changes after parallel work, distinct from new product review defects.",
"task_18e562f7b94d63bb handoff facets attempts5/6; cmt_18e56d1a80a6993d; task_18e56a0d15295083 attempt6"),
("Real demos were expensive, but do not explain all elapsed time.",
"Nine evidence-linked demos among the ten largest shell records sum to34m12s of recorded spans. They followed changed source, held-lease/retirement/history fixes and committed/release binary verification. Child stages are not added again. Dependency installs, fixture repairs and failed drafts recur in handoffs, but unavailable command metadata prevents reliable full category costs.",
"Top sessions below; C1 attempts2–6; compaction handoff; known baseline failures remain qualified")]
IMPROVEMENTS=[
("Define parity before implementing the first slice.","Inventory native fields/commands up front. Give each bounded task an explicit accepted subset and mandatory successor; distinguish a usable vertical slice from full migration readiness. This targets the M1/C1/workflow scope revisions."),
("Coordinate migration numbering and shared harness edits.","Reserve migration numbers in a small integration ledger, or rebase a schema-changing task onto the accepted incoming parent before its final demo. Preserve independent review while reducing migration collisions and combined reruns."),
("Reuse exact-head verification evidence.","Attach source head, toolchain, fixture hash, session ID and nonzero test count. Recheck affected suites after source changes and one combined final smoke path; reuse unchanged evidence in delta reviews. Keep known baseline failures explicit."),
("Persist boundary measurement metadata.","Record task/lease/worktree IDs on shell sessions, actual process start/end and launch queue, plus immutable review/hold/block/outage intervals. Fix the pagination cursor separately. This improves attribution without storing private output."),
("Checkpoint bounded deliverables before context churn.","Use a native handoff with a small verified checkpoint and precise remaining ledger. Cache pinned worktree dependencies and supply focused test/demo commands. Keep independent reviewers; avoid re-reading whole history each continuation.")]
DEFINITIONS=[
("Chain elapsed","Cutoff minus chain creation: wall-clock age, not a sum of task durations."),
("Created / first-start elapsed","Creation or first task start to completion/cancellation; unfinished tasks stop at cutoff. Queue-only tasks show waiting age, not a completed duration."),
("Pre-start wait","First start minus creation, or cutoff minus creation when unstarted. Dependency, dispatch and hold wait cannot be split from these records."),
("Attempt envelope","Union of Hub runtime-facet started_at/ended_at intervals clipped at cutoff. A logical attempt can span restarts/renewed leases; this is not exact live-lease or productive time."),
("Review bounds / unclassified","Earliest-to-latest reviewer comments in the same gap between attempt envelopes. These are observed bounds, not full review lease durations. Remaining first-start elapsed is unclassified, not measured model thinking."),
("Shell sum / union","Sum of unique Hub session spans; union removes overlap. Includes launch and exit-delivery latency. Separate subprocess runtime, launch queue and CPU use are unknown."),
("Files / added / deleted LOC","Exact retained net diff between the task-specific Git base and checkpoint/submitted head, with rename detection. Integration bases remove inherited changes. Old C1/C1a retained rows overlap and must not be added."),
("Gross churn","Deduplicated nonmerge first-parent commit diffs. Merge resolution-only remerge diffs are separate diagnostics because synthetic conflict cleanup is not authored LOC.")]
LIMITS=[
"Cutoff:2026-11-06T14:44:57Z (20:14:57 IST). Metadata was fetched approximately14:48–14:51 UTC and reconstructed using timestamps and immutable facets/commits. The report task was created14:46:45 UTC and is excluded, as are later implementation commits.",
"All five historical instances were confirmed through task/comment/review identities. Each full shell page returned has_more=false; chain-scoped server listing was empty. Deduplication uses session_id.22 post-cutoff records were excluded. Ordinary200-record cursor pages demonstrably repeated/skipped records; a10,000-record single-page read recovered full authorized listings.",
"Command/cwd/label fields are blank in authorized list/show. Old Bridge spawn specs had been removed; only the current post-cutoff spec remained. Most task attribution therefore uses agent plus attempt/review-comment time windows. Confidence and an unassigned bucket are explicit; same-instance/time-range membership alone is not proof of chain ownership.",
"The1,506 entries are session records, not individual child commands. Nested build/test/demo stages are not summed. Unmanaged direct terminal commands are unmeasured. Second-resolution zero spans indicate insufficient granularity, not zero execution cost.",
"Exact historical review leases, every submit/rework transition, hold/block/outage intervals and launch/runtime splits were not exposed by list/show/facet records. Some handoffs are truncated; facets expose their latest version only. Narrative restarts/connectivity cannot be converted into precise outage seconds.",
"214 records have nonzero exit codes; five statuses are failed and1,501 exited. Nonzero exits include intentional rejection probes and drafts, not214 product regressions. Compaction's handoff records three unchanged taskv2 baseline failures: clock-jump expiry, removed-verify migration, fleet-delete gate (184-test baseline versus186-test changed suite). No blanket suite-green claim is made.",
"C1b had no committed checkpoint before cutoff. Committed delta is0; its uncommitted working delta isN/A. M3/M4/C3/C1c–f were unstarted with0 committed changes; their waiting ages are not execution estimates.",
"Token usage and monetary cost are unmeasured. Mutable current dependencies do not recover the exact historical critical-path graph. The observed serial stream is reported without invented exact critical-path attribution."]
DEMO_SOURCES={
"sh_89b935730f7edd8a64b3d9a08dbf79d0":"cmt_18e576a45c6f446c",
"sh_41d90a59840bde07efde87b5becce2a8":"cmt_18e57a53fec92a44",
"sh_a99440d70ac86a250d1f84345eda8f1c":"cmt_18e5778943098d67",
"sh_1681df9dd0e44a4745b90f2ee84af722":"cmt_18e576a45c6f446c",
"sh_bb45fb95ba0e364ecd76f59d21aecfed":"cmt_18e578cf990a27ce",
"sh_2007a293a1458ffe8eb4d15b2fcb0b38":"cmt_18e574fd4a8fea55",
"sh_b3ff73443bb29f7bcd8aca0b82949c47":"cmt_18e5754ba6b1830f",
"sh_a05b7f280555b9b777933b25c6cec1dc":"cmt_18e56f42fcf85dea",
"sh_9c093bafbdc09c18bf01c2ff68b64921":"cmt_18e56f42fcf85dea"}

