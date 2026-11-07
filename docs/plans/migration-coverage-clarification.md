# Migration coverage clarification and proposed amendment

Status: PROPOSED for named review; design only. Task task_18e5d7a475c051ec, REQ-COV-1/2/3.
This is a separate amendment to migration-origin-binding-decision.md@1e9e215b, not a reinterpretation of its approval. Until named approval, unknown coverage refuses the signed inventory/adoption consumer. Runtime routes remain disabled.

## Source-backed conclusion

Audit: M4a checkout at 317a55f3 (read-only); original decision at 1e9e215b. No shared worktree edits.

| Source | Finding |
| --- | --- |
| src/lib/executor_local/schema.sql:304-318 | New databases seed journal (1,0,1,1). CHECK and transition triggers forbid clearing prior_coverage_unknown, replacing or deleting the journal. |
| src/lib/executor_local/migration_011.sql:88-94; store.odin:47-76 | Upgrade introduces the same unknown history; opening an existing database increments incarnation and enters reconciling. New database creation is not proof of new machine/resource history. |
| src/lib/executor_local/legacy_observation.odin:16-28 | Snapshot covers durable database changes only, explicitly excluding dispatcher memory, daemon children, filesystem mutations and missing pre-upgrade admissions. |
| src/lib/executor_local/legacy_barrier.odin:46-88 | Optional snapshot CAS checks incarnation, sequence, coverage version and unknown flag. It neither interprets unknown coverage nor authenticates completeness. Exact barrier replay is read-only. |
| src/bridge/legacy_execution_barrier.odin:8-22,49-79 | Physical gate and exact native close keys protect targets; installation waits for guarded invocations but cannot prove surviving children absent. |
| src/hub/repository/sqlite/owner_migration.odin, legacy_effect_prepare / legacy_source_freeze | Selection closes new effect scope; freeze requires fixed generation/revision, no leases/outstanding effects. Empty source ledger does not enumerate pre-ledger execution. |

The approved note rejects unknown coverage and missing raw/admission mappings, while mentioning offline reconciliation without a wire or authorization contract. Therefore it provides NO implementable general positive path merely from a current scan when prior_coverage_unknown=1. Treating the flag as false, ignoring it, or claiming current process absence discharges it would invent authority.

Historical ignorance and unresolved migration relevance are different facts. The immutable flag records the former. A separate, independently justified complete coverage certificate could establish the latter is empty without rewriting history. The proposal below authorizes that narrower interpretation only after named review. It does not make existing code complete.

## Proposed exact acceptance predicate

For selected migration M, let E be the complete independently verified executor set and R the transitive closure of actual affected resources and their users. R includes task/instance, canonical directory identity/revision/key and workdir hash, repository/branch, startup configuration and daemon identity, plus aliases and shared owners. Source chain labels alone cannot delimit R. Inability to bound E or R is refusal.

Let U be the union, across E and R, of source effects through immutable scope generation G; durable native admissions/observations/drafts; running handlers; memory and persisted ingress/retry/reconnect queues; startup/rollover/resize specs; daemon children and descendants; pending stops/merges; and FS/VCS/Shell/LSP/MCP/provider/setup/alternate-instance resource users. Include dormant/replayable work, not just runnable processes. Cross-chain resource users belong in U; an unrelated history item may be excluded only with locally verifiable disjoint resource AND future-admission proof. Missing target identity is relevant unknown, never automatically disjoint.

Inventory acceptance requires ALL:
1. Existing approved source selection fence and immutable scope G; consistent complete source snapshot and independently verified E/R.
2. Each member of U has an exact retained raw parent/entry/native association to a source effect, or an explicit resource-only exclusion/disposition that grants no execution or origin attribution. A required source mapping with missing raw evidence refuses adoption even if its child has stopped.
3. Every coverage class has a complete independently supported census AND continuous admission control from that census through barrier installation. Any pre-observation or pre-upgrade gap must have independently verifiable closure evidence covering dormant/replayable state. A newly created database, zero counts, a scan, a user assertion, or an executor signature by itself is not such evidence.
4. Exact current evidence/CAS/freshness below, no unresolved relevant unknowns, and explicit enrolled-device migration-only adoption under the original note.

Final drain acceptance additionally requires retained barriers over the full R, all U dispositions accounted, zero queued/admitted/running/child/merge/unresolved relevant work, physical termination observation and no usable dormant replay path, plus source freeze checks and complete signed executor receipts. Inventory acceptance is not drain acceptance. Known mapped children may exist at inventory/adoption time solely to permit exact migration cleanup.

Refuse if any conjunct is false or unknown. prior_coverage_unknown remains 1 in both accepted and refused cases; it is always reported. No generic unknown override bit is introduced.

## Minimum certificate and verifier contract (new, not implemented)

Extend migration-executor-inventory-v1 with a required coverage_certificate_digest; add domain migration-relevant-coverage-v1 using the original strict canonical encoding, sorted unique bounded lists, counts/digests and SHA-256. Reject missing/unknown/duplicate fields, unfinished pagination and unsupported coverage versions.

Certificate fields:
- protocol/coverage version; account, chain, migration, selection digest; source database identity, immutable inventory digest, scope G and fence revision; E and R counts/digests.
- executor Bridge/key, pinned verified directory root/head sequence/hash/epoch, executor incarnation, database journal sequence/version and prior_coverage_unknown=1.
- For EVERY U class: class identifier, enumerator implementation/version digest, namespace/resource boundaries, count/list digest, observed memory revision or daemon incarnation/sequence, admission gate identifier/revision, and coverage interval start/end.
- For every historical gap: explicit gap interval/domain, affected resources, closure method/version, raw evidence digest, issuer key and independently verifiable trust anchor, and exact prevention of later replay. Missing or unsupported closure method yields unresolved, never empty.
- Mapping and explicit exclusion/disposition counts/digests; unresolved relevant count; challenge, issued/expiry, operation ID and certificate digest. Detailed evidence remains encrypted; no tokens/raw commands are exported.

Trust anchors are existing pinned enrollment identities and locally retained raw native evidence, not Hub chain labels. Source snapshot is authenticated database evidence, not historical origin proof. An executor signature authenticates the observer, not the truth of a guessed census. Device independently checks every class/gap proof against supported verifier methods, then explicitly adopts the exact certificate/mapping for migration cleanup only.

Crucial missing implementation/approval boundary: current code has no universal enumerator, continuous memory/daemon coverage clock, or approved gap-closure method. This amendment does NOT register an offline recovery method or permit a free-form attestation. A deployment needing closure for unobserved pre-upgrade work must supply a separately named-reviewed method defining concrete evidence, issuer authority, exhaustive persistent replay domains, and verification algorithm. Until then that deployment refuses. Avoid implementing a certificate parser that accepts arbitrary method strings or an unresolved=0 claim as proof.

For a genuinely fresh isolated execution domain, a future supported verifier may use continuously retained provisioning evidence: exclusive namespace/resource creation, absence of inherited daemon/startup/queue stores, all resource capabilities controlled from creation, and complete guarded admission history to current observation. It must bind local creation identities and continuous control, not database creation time. This method is also not supplied by today's journal; absence of such evidence refuses.

## CAS, freshness and ordering

Use original selection -> immutable scope inventory -> explicit adoption -> barrier/drain -> frozen aggregate ordering. Immutable scope G is NOT mutable source settlement revision. Bind both separately; cleanup may advance settlement only through authorized dispositions without changing execution scope.

Device generates an unpredictable single-use challenge bound to M and a persisted request. It verifies a current pinned directory extension and complete E replies. Observation validity is at most 60 seconds on a nondecreasing monotonic verifier clock from challenge issuance; clocks/restarts without retained time continuity fail closed. Signed timestamps are audit data, not sufficient freshness. Each executor also retains challenge issuance/expiry on its own monotonic clock and consumes it atomically on new installation. Expired/missing challenge or uncertain clock requires reobservation; no retrospective extension.

Under application -> startup I/O -> physical -> Store lock order, compare source selection/G/inventory, enrollment head/key, executor incarnation/journal, each memory/daemon revision, actual resource/config/run identities and coverage gate revisions to the signed certificate. Persist binding and full barrier in the same Store transaction as journal CAS; hold the relevant non-SQL gates across comparison/commit. No network under gates. Recheck after network or lock gaps. Any changed pre-install component invalidates the observation and requires fresh device binding; do not silently update signed bytes.

After installation, authorized cleanup changes journal/settlement state. Record causal revisions and sign a NEW drain observation against the unchanged scope and binding, current journal/memory/daemon revisions and barrier receipt; do not require drain sequence to equal pre-drain sequence. Source freeze atomically CASes current expected settlement revision and unchanged G, dispositions and receipt set. Device verifies all receipts before activation.

Persist exact operation/nonce/input digest dedupe; historical exact replay returns a receipt under current read authorization and never reinstalls authority, releases barriers or executes. Changed bytes conflict. Restart, re-enrollment, resource replacement or lost coverage requires fresh evidence; crash leaves fences retained. Other migrations' shared-resource protection survives.

## Cases and required focused verification

| Case | Inventory/adoption result | Drain result |
| --- | --- | --- |
| Fresh database on old host; G=0 and empty process scan | Refuse: database freshness cannot exclude old daemon/startup/replay stores. | Refuse. |
| Fresh isolated domain with independently verified continuous creation-to-barrier coverage and complete mapped or empty U | Proposed amendment permits acceptance with flag retained 1; current implementation lacks this verifier. | Accept only after separate current physical/queue/replay absence and all original checks. |
| Upgrade with exact retained mappings, exhaustive current union AND independently verified closure of every prior relevant gap | Proposed amendment permits migration-only adoption; otherwise refuse. | Requires exact cleanup and fresh signed absence evidence. |
| Unknown survivor with missing raw/source mapping, or dormant replay store not enumerated | Refuse; do not relabel/backfill or infer never-admitted. | Separate offline recovery design required; no automatic import. |
| Known mapped survivor sharing a directory with another chain | Include all owners and resource users; refuse if any cannot be accounted/fenced. | Keep every owning fence; handler return alone never suffices. |
| Historical item provably disjoint from R and unable to regain admission into R | May retain historical unknown with explicit checked exclusion. | Exclusion cannot erase a required source disposition or raw-mapping requirement. |

Implementation tests must reject forged empty certificates, unsupported gap methods, G0+old survivor, daemon/memory-only mutation, late replay after scan, omitted shared users, raw mismatch, enrollment rollback, expired/replayed challenges and changed CAS. Positive tests need actual supported coverage evidence, not fixtures setting unknown=false. Crash/restart tests retain fences and invalidate uncovered observations. This task changes documentation only; no runtime capability or positive migration success is claimed.

## M4a handoff

Continue independent ingress/resource guards. Keep signed inventory/adoption consumer blocked on named approval AND implemented supported coverage verification. Do not gate solely on clearing immutable unknown, and do not bypass it using current snapshots. Existing scope closure and source revision separation remain mandatory. If no supported proof closes a relevant gap, expose an explicit refusal; retain recovery/frozen state. Do not add runtime origin backfill, task grants, generic stop authority or live effects.
