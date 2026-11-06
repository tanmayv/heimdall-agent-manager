# Bridge-owned runtime: whole-goal audit

The examined code delivers a working, separately routed owner-local slice, **not completion of the full Bridge-owned product**. Its signed admission, transactional receipts, exact-child leases, requirements acknowledgement, independent review, merge intents and local search are substantial. Ordinary creation and worker commands still use Hub authority. That convergence is now explicitly pending in M4 revision 2. Two concrete delivered defects need fixes: creator revocation blocks later owner registry publication, and registry pagination hides live tasks. Access lifecycle and full aggregate/content preservation also need explicit acceptance coverage before migration.

## Scope and evidence boundary

- Examined production commit: **37495ef4a17223a65983ece3099d9e78a7f27d75**; this task worktree HEAD matched it.
- Compared original **ada2d4c8e76fdfaaf98f41e5f4ad96ded206cf04** and approved plan **1c83a464f19ded8ba967ecda24130d9e12fa4ef4**, `docs/plans/bridge-owned-runtime-local-search.md`.
- All production `path:line` citations below refer to the examined commit; plan citations refer to 1c83a464. Ranges describe the inspected code, not moving branch heads.
- Audit task: `task_18e568efcfe3e1c6`. Author durable identity: `agt_18dbb3d25b612dcd`; independent reviewer assigned: `agt_18dbb3d25c4e8afe`. Reviewer verification is required after this report; author submission is not that verdict.
- Pending task briefs read through the task API: M2c revision 1, M3 revision 1 plus its dispatch-scope comment, M4 **revision 2** including REQ-M4-5. These are plan coverage, not delivered source.
- No other worker's uncommitted tree, production data, live provider, deployment, restart or push was used. Checks used source and synthetic in-memory SQLite only.

User amendments retained: owner immutable, owner unavailable means authoritative work pauses, Hub metadata-only, authorized decrypted local search; browser caching and artifact-content indexing deferred; task-chain user review gates removed while named independent review remains. Optional product-configured human verdicts are distinct from approval of this implementation.

## Requirement-to-source/status matrix

| Goal / audit coverage | Source evidence | Assessment and remaining owner |
|---|---|---|
| Immutable creator Bridge, signed genesis, no takeover | Plan:29–39; `src/bridge/owner_local.odin:97–129`; `src/lib/owner_local/store.odin:128–140,202–205`; `src/hub/repository/sqlite/owner_registry.odin:15–26` | Implemented for new dedicated owner-local chains. Same-owner stale restore fencing remains M4, not proven by incrementing incarnation. |
| Normal new-chain creation, list/detail, ordinary agent commands | `src/ui/api/endpoints/taskChains.ts:354–384`; `src/bridge/agent_api.odin:112–138,487–492`; `src/hub/transport/http/taskchain_handlers.odin:1385–1417` | Still Hub-authoritative. Explicitly covered by **M4 REQ-M4-5**, including worker materialization and primary UI. Not whole-goal complete. |
| Real owner relay and offline metadata | `src/hub/transport/http/owner_local_handlers.odin:34–61,99–120`; `src/ctl/taskv2_cmds.odin:1334–1361`; `src/ui/components/taskchain/TaskChainsPage.tsx:486–498,778–792` | Real production routes, not test-only mocks; dedicated file-based CLI and form panel. Offline owner returns unavailable; no alternate-owner fallback here. Listing defect F2. |
| Hub allowlist, account isolation and signatures | `src/hub/repository/sqlite/migrations/202_owner_local_registry.sql:1–15`; handler:66–95; registry repository:50–61; `src/lib/owner_local/directory.odin:26–42` | New owner-local Hub rows contain IDs, signed genesis and protected registry bytes, not task state. Account predicates and enrolled recipient/key checks exist. Creator-current-status defect F1. Not a certification of all legacy logs/services. |
| No same-chain second writer | Migration202:1; publication handler:91–92 | Owner-local IDs have no legacy chain row; publisher rejects existing legacy IDs. Separate surfaces exist, but this is **not evidence of two writers on one chain**. Frozen migration/cutover remains M4. |
| Complete task/fleet/history/facet/configuration aggregate | Plan:43–72,82–94; `src/hub/domain/taskchain.odin:122–204`; `src/lib/owner_local/schema.sql:8–48`; migration004:50–85; migration007:53–107 | Only partial local equivalent. Immutable requirements, submissions, assignment/work-attempt/handoff records exist. Full brief/facets/events/member/directory/proposal/summary parity needs explicit reconciliation (C1), beyond merely copying rows. |
| Current authorization before historical replay; no live-fence replay dependency | `src/lib/owner_local/store.odin:101–169`; `src/lib/owner_local/leases.odin:49–95`; `src/lib/owner_local/lifecycle_agent.odin:12–68` | Ordering is correct in inspected paths. Current child/configuration/read scope intentionally remains required; release/request expiry is checked after receipt miss. Revocation may deny historical bodies without deleting dedupe. |
| Durable transaction/outbox/restart/clock/retention | `src/lib/owner_local/transaction.odin:14–68`; migrations.odin:13–64; store.odin:43–81; outbox.odin:37–107; retention.odin:15–56; `src/bridge/owner_local.odin:45–56` | WAL/FULL, exclusive profile writer, rollback, receipt/intent co-commit, exact claim completion and permanent tombstones present. Quotas reject instead of dropping evidence. Clock reconciliation is a trusted library API, not yet a product recovery flow. Real final crash/resource/restore gate remains M4. |
| Exact running child, local claim/heartbeat/expiry | `src/bridge/owner_local_leases.odin:16–43,46–116`; `src/lib/owner_local/leases.odin:60–145` | Local token plus actual PTY launch-key observation, not caller instance claims; maintenance runs without requests. Existing running-child slice does not implement general fleet launch. |
| Requirements ACK, submit, independent review and merge | `src/lib/owner_local/lifecycle_agent.odin:81–105`; lifecycle.odin:69–104; `src/bridge/owner_local_lifecycle.odin:19–57,89–119` | Exact presented ACK, immutable submission/reviewer identity and prepared merge/ref-CAS path exist. Git target must be unchecked-out; M4 REQ-M4-5 must resolve or explicitly gate this limitation. Multiple role/workflow folds pending M2c. |
| Holds, cancellation, assignment history and handoff | `src/lib/owner_local/store.odin:226–258`; migration007:53–107; `src/bridge/owner_local_controls.odin:14–68` | Durable controls and exact-old-child notices present; stale stop suppressed if child now owns newer work. Remote delivery/resource reconciliation remains M3. |
| Authorized durable local search/update/delete/history | `src/lib/owner_local/search.odin:36–105`; migration005:52–84; migration006:52–70; migration007:75–78 | Scope materialized before MATCH/snippet; no global BM25; bound literal query, VM/output limits; transactional postings, rebuild, all retained submission attempts and handoffs indexed. Current requirements only. |
| Legacy and owner search/common navigation | `src/ui/utils/taskChainSearch.ts:232–261`; `src/ui/api/ownerSearchClient.ts:17–45`; `src/bridge/task_chain_search_refresh.odin:70–92` | Mixed search deliberately retains Hub-fed legacy index; owner queries are separately signed, IDs excluded from legacy fallback. 101 owner headers trigger explicit scope error, not silent search truncation. Project/status filters exclude unknown local fields. |
| Human device grant lifecycle and revocation | Store:101–106,134–140,205; contracts owner_local.odin:33–35; directory.odin:37–42 | Creator device receives sole initial grant; no production grant management method found. Fail-closed access is correct, but multi-device/replacement access is unimplemented (C2), separate from owner authenticity. |
| Linked messages/artifact bodies/canonical envelopes and backup copies | Plan:43,68,154,172–182; schema.sql:8–33; store.odin:187–218; migration004:56–72 | Linked-content canonical storage is not delivered. Artifact **indexing** deferral does not defer artifact/facet storage. Most initial task/comment bodies retain plaintext only; requirements retain cipher too. Resolve C1/C3 explicitly with M2c/M4. |
| Remote slots, common launch, PTY/provider and Windows | `src/bridge/owner_local_leases.odin:16–43`; `docs/owner-local-search.md:71–84,88–98`; M3 brief/comment | Intentionally pending M3; final supported-platform/resource evidence M4. No real-provider or Windows claim follows from local demos. |
| Review gates and no rollout | Audit brief REQ-AUDIT-3/4; M2c/M3/M4 task records `requires_user_approval=false`, named reviewers retained | Implementation review remains independent. Stale prose in M3/M4 descriptions mentioning explicit user gate does not reinstate removed task-chain user gates. No rollout authorized. |

## Severity-ranked delivered defects

### F1 — High: revoking the creating browser disables later owner registry publication

**Evidence:** `src/hub/transport/http/owner_local_handlers.odin:76–89` looks up both creator and owner in the **current** trusted directory on every publication, rejects when creator is no longer approved, then calls genesis verification. `src/lib/vault/directory_verify.odin:96–100` removes a revoked subject from that trusted map. The registered genesis is immutable (`src/hub/repository/sqlite/owner_registry.odin:15–26`).

**Scenario:** browser A creates/publishes a chain; another approved device revokes A while owner Bridge B remains approved. Any outstanding publication, and any later publication from B, now returns Forbidden at handler:80. This includes already committed task titles/delete tombstones. The owner outbox retries the same rejected effect (`src/bridge/owner_local.odin:59–70`; outbox.odin:65–84), leaving Hub listing metadata stale. A stale title can survive a local delete.

This is **not** a claim that revoked browser A should retain command access. Nor does it establish wrong-owner signing: B still has the correct owner signature. Historical creation proof is being incorrectly treated as continuing permission from A.

**Fix:** authenticate the current owner/enrollment and exact existing immutable genesis binding for subsequent publications. Verify creation signatures under historical authenticated evidence at initial registration; preserve historical key evidence without treating revoked keys as current command signers. A first publication arriving after creator revocation needs an explicit safe policy, not arbitrary current-key substitution. Regression: approved B can publish the same bound chain's newer metadata after A revocation; A's mutations fail; conflicting genesis/owner still fails. Source-proven branch analysis; no live HTTP experiment.

### F2 — Medium: the owner panel silently omits tasks after the first registry page

**Evidence:** registry repository:50–61 applies raw row LIMIT 100 with keyset inputs. Handler:110–119 filters tombstones **after** that limit and returns an array without a continuation token. `src/ui/components/taskchain/OwnerLocalPanel.tsx:43–50,110` fetches one unpaged listing and supplies no next-page action.

**Reproduction:** actual migration202 plus extracted production SELECT in synthetic SQLite: one chain header +105 live task titles returns only header +99 tasks. Six live tasks disappear from the panel. With104 deleted task titles, a live header and live task105, the first raw page yields only the header after filtering; the surviving task is hidden. Creation/deletion of unstarted tasks can reach this state. Direct signed chain reads may still retrieve tasks: this is discovery/UI loss, not physical deletion.

**Fix:** expose a cursor derived from the last examined raw registry row, plus explicit terminal/stale semantics, and make panel consume pages. Never infer end-of-list from post-filter visible count. Test tombstones spanning pages, multiple chains and byte limits. Global owner search's >100-chain explicit error is a separate documented bound and is not this defect.

## Severity-ranked scope and acceptance risks

### C1 — High: final schema and command parity can be silently lost across slices

Plan:47 explicitly retains effective original columns/constraints, events and facets. Original tasks carry priority, publication, complete validated brief, attempt budget, placement, workflow provenance and timestamps (`src/hub/domain/taskchain.odin:164–204`). V7 `tasks` still has five fields (`schema.sql:24–28`). `lifecycle.odin:22–29` accepts only goal/acceptance, rejecting a full original brief. Submit accepts only requirements/head/summary (`src/contracts/owner_schema.odin:369–379`), whereas original `src/hub/service/taskv2/verbs_m2.odin:81–115` validates output contracts and writes separate facets. A local change tag is not an equivalent full event payload/history (`schema.sql:46–48`); chain/task edits overwrite original prose (store:206–218).

This is **not a defect against the explicitly narrowed delivered slices**, and absent table names alone do not prove missing semantics. The payload/column comparison does prove that full common-path inputs are not accepted yet. M2c REQ-W1-4 requires reconciliation; M4 REQ-M4-1/5 preserves/imports the aggregate and converges routes. Neither should pass based only on row counts plus summary-only demos.

**Action:** require a field/command mapping with each original field mapped to a local canonical equivalent or explicit approved disposition. Include propose/decide/publish, summaries, membership/directories, priorities/budgets, full brief inputs/output contracts, event authors/times and attempt facets/artifact references. Add a rich synthetic legacy fixture imported then exercised through ordinary commands; reject migration until every canonical record has a home. Do not replace the new runtime wholesale or reintroduce Hub authority to fill gaps.

### C2 — Medium: only the creating browser can read/mutate its chain; grant lifecycle has no route

Store:205 inserts a grant only for the creating principal/key. Store:102 requires an exact principal/key match; store:139 rejects missing grants. Enrolled browser B can discover account-owned registry titles, but its signed detail/search is denied even with the same account/keyring. Contracts:33–35 has no grant creation/update/revocation method; inspected production writers contain no other grant insertion. Test-only direct SQL grant edits are not an access-management feature.

This is a **fail-closed capability gap**, not a signature bypass, and another device should not automatically gain authority merely because it has a vault content key. Losing/revoking A can leave no human command principal. Pending tasks reference approved plan access generally but do not explicitly specify this recovery path.

**Action:** assign signed, scope-aware grant lifecycle and replacement-device access under an authenticated account/device policy; keep owner immutable and current read authorization before receipts. Test B denied before grant, allowed only within grant, then denied after revocation including replay. Define authorization expiry while disconnected; the initial grant currently uses MaxInt expiry. Coordinator should name the responsible acceptance item before final closure.

### C3 — Medium: linked canonical content and envelope retention need an explicit owner

Plan:43/68 requires chain-linked messages, artifacts and additional prose/facets locally, with canonical vault envelopes (plan:154) and one canonical body. Initial chain/task/comment rows retain only decrypted fields; admission decrypts then discards their input ciphertext (store:187–218,261–262). Requirements do retain both `brief_json` and `cipher` (migration004:56–59). No local message/artifact/blob object/reference schema or corresponding producer was found in V1–V7.

M2c explicitly adds workflow/handoff/output search producers and source episodes; that is not yet a complete linked-message/artifact-body migration API. M4's full-aggregate import can cover storage but must explicitly implement it. **Only artifact-content search and browser caching were deferred**, not canonical artifact references/bodies or linked content.

**Action:** allocate local canonical linked-content/blob lifecycle, authenticated producer/copy scope, envelope/key metadata retention or an explicitly reviewed alternative, plus transactional delete/GC and restore manifests. Keep artifact extractors/indexing deferred. Demonstrate linked-message authorization and preserved facet/artifact references through import/restart without Hub content authority.

## Planned gaps with retained task coverage

| Task | Legitimate pending work | Final acceptance guard |
|---|---|---|
| `task_18e562f7b94d63bb` M2c revision1 | Workflow definitions/executions/stage events/dependencies, multi-role gate folds; exact source consumption/ACK/resolution/retirement; both preserved R2C cold-discovery regressions; workflow/handoff/output search producers | Inspect eventual merged source, run both preserved regressions, require REQ-W1-4 full command matrix and explicit C1/C3 dispositions. Current unaccepted worker source was not examined. |
| `task_18e556f90cfa1e9c` M3 revision1 + dispatch comment | General unlaunched durable fleet/provider/model dispatch, one-device launch then remote; device-wide slots/manual/warm/directory budgets; prepare/activate/stop/reconcile; encrypted exact delivery; real provider interrupt/literal paste/Windows gates | Preserve selected PTY/delivery algorithms and exact identity once; cross-owner race and stale-child cases must use real ledger/runtime evidence. No Hub matching as fallback. |
| `task_18e556f919c82490` M4 revision2 | Explicit user-selected freeze/drain/export/import/cutover; same-owner backup/restore/loss, real repeated crash/resource tests, deletion/copy recovery; **ordinary CLI/worker/UI routes for new and migrated chains**, checked-out-target handling | REQ-M4-5 now closes the previously ambiguous normal-product destination. Require owner-offline metadata-only behavior, old routes disabled per chain, complete rich aggregate and task materialization, and remediation/disposition of F1/F2/C1–C3. |
| Explicit follow-ups, not completion blockers for this approved scope | Persistent browser cache; artifact text extraction/indexing | Do not quietly add them or treat their deferral as permission to omit canonical local content. |

Selected reuse inventory remains present in approved plan:186–198: strict contract lineage; producer/source algorithms; PTY and delivery; local authority/guards; unapproved R2C recovery only after its two fixes; baseline product/search adapters. Pending M2c/M3 own the corresponding unfinished code. The production delta is additive (94 files, 9905 insertions/29 deletions against original); original Hub schema/routes remain intact. No wholesale destructive schema replacement was observed. Separate strict Odin/TypeScript schemas and local-vs-legacy adapters are real maintenance cost; generated wire schema and narrow transaction seams are preferable to a third runtime framework. Their eventual convergence must be demonstrated, not assumed from reuse provenance.

## Checks, limits and reviewer handoff

Exact inspection commands included:

```bash
git rev-parse HEAD
git diff --stat ada2d4c8 37495ef4
git show 1c83a464:docs/plans/bridge-owned-runtime-local-search.md
# Focused nl/sed/grep source reads are captured in managed shell task sessions.
```

A Python3 in-memory SQLite probe executed actual `202_owner_local_registry.sql`, extracted the SELECT literal from `owner_registry.odin`, and bound the same account/keyset/limit arguments as production. Corrected reachable reproduction session **sh_c75511e4821ede33ad5fc766781d1854**, exit0:106 rows ->100; header +live task105 behind104 tombstones ->header only. Earlier exploratory session **sh_917911ff8bc864a287e26685a8456ce6**, exit0, also applied `schema.sql` and SQL migrations002–007 and printed the five task columns/missing named aggregate tables. Its deleted-chain-header scenario was unreachable in this API and was replaced, not used as finding evidence. The SQL schema probe does not claim to execute Odin's migration orchestration or its digest backfills.

No production test/build rerun was needed for this documentation-only change. Existing nearby test sources/docs were inspected as prior evidence, not relabeled as tests run by this audit. No live credential, HTTP revocation experiment, platform/provider run or full failure/resource test was performed. Read-only source coverage is focused, not exhaustive proof of every old Hub endpoint/log, OS ACL, key-loss behavior or candidate branch. Full-run success on prior slices cannot establish whole-goal completion.

Independent reviewer should verify F1 against current-vs-historical directory trust and unchanged owner binding; repeat F2 with reachable tombstones; check C1 payload parity and C2 grant writers; confirm the matrix and pending M4 revision2 without treating unfinished work as a delivered regression. Author confidence is high for these source conclusions and synthetic SQL behavior; full product readiness remains unestablished.

## F1/F2 remediation follow-up

Task `task_18e569e455cd82bb` addresses the two delivered defects above. The audit
and its pinned source citations remain historical evidence at `37495ef4`.
Current behavior and reproduction commands are documented in
[the owner-local demo](../owner-local-v1-demo.md#protected-registry-listing-and-creator-revocation).

- **F1:** current approved owner/enrollment and each registry signature remain
  mandatory. Subsequent publication compares the exact stored immutable genesis
  binding without requiring the creator to remain approved. An unregistered
  genesis still requires current creator approval and both signatures; first
  publication after creator revocation fails closed. Current command authorization
  and owner revocation remain independent denial boundaries.
- **F2:** the panel follows explicit bounded pages through live titles and
  tombstones. Cursors advance over the last examined raw row, with explicit
  terminal state and live keyset concurrency semantics. Whole encoded data pages
  are capped at 262144 bytes and 100 examined rows, with one unconsumed lookahead.
  Header-only legacy search discovery keeps its separate 101-header sentinel.

Focused signed-publication and real authenticated listing-handler tests cover
creator/owner revocation, initial registration, immutable conflicts, 105 live
tasks, 104 tombstones, empty nonterminal pages, byte-split continuation and
cross-account cursors. The isolated enrollment regression additionally exercises
actual HTTP owner publication/relay and the rendered production panel. Exact run
results and commit are recorded in the remediation task's submission; independent
named review remains required. This follow-up does not dispose of C1–C3 or mark
the overall Bridge-owned product complete.

## C2 device-grant remediation follow-up

Task `task_18e569e4750fe9fd` adds signed chain-scoped device grant set/revoke/read,
explicit versioned recovery-policy opt-in, and paired-root-only recovery. The
owner verifies current signer and target enrollment against its durable root
and directory pin, and applies expiry/revocation before historical replies or
search. Delegated writers cannot administer grants. New content grants have a
30-day maximum; upgrading V7 bounds legacy grants and leaves recovery disabled.

See [owner-local-grants.md](../owner-local-grants.md) for the UI/CLI flow, exact
authority matrix, safe refusal when root/policy is unavailable, migration
semantics, offline revocation limits and irreversible decrypted-copy limits.
Immutable signed grant audit records commit with grants and receipts. Recovery
does not alter creator/genesis/owner. C1/C3 and whole-product migration gates
remain separate; independent named review is required for this remediation.
