# Delivery forwarder exhaustion: RCA and proposed fix

The delivery service can refuse a live bridge after 256 other capable bridges have connected and subsequently gone offline. Offline forwarders remain enabled, consume capacity and retain parked workers. Routing does not check forwarder admission, so an accepted prompt can sit in `routed` until expiry and then fail as `bridge_offline` even while its bridge is live. The proposed fix is bounded, generation-fenced reclamation of offline workers, explicit capacity diagnostics and automatic admission retries. This document requests user review only; no production implementation is included.

Issue: `iss_18eb101402b098fb`. Task: `task_18eb17492ed810d5`. Original discovery: scalability report `art_18eb1005543b7965` (not revalidated as a whole here). All source references below refer to base commit `50a8b74615afa21173aa5dd3b2d43addb885269e`.

## Findings and evidence

| Finding | Source evidence |
| --- | --- |
| Admission refuses forwarder 257 when 256 entries are enabled | `src/hub/service/delivery/offline.odin:42–84`, especially checks at 55 and 69. Both insertion and reactivation use literal `256` under `s.mutex`. |
| This is not an unconditional lifetime-distinct-bridge cap | `offline.odin:91–121,165–170`: deletion and capability downgrade disable entries; `active_forwarders_locked` counts only enabled entries. `review_regressions_test.odin:227–244` already covers retirement releasing capacity. Metadata remains until service stop, so historical list growth is a separate concern. |
| Offline bridges keep enabled capacity | `offline.odin:86–89`: disconnect runs row replacement and retires the local pull, without disabling, joining or removing the forwarder. `forwarder.odin:66–91`: worker parks on its semaphore when registry has no live connection. |
| Registry absence does not release capacity | `src/hub/service/project/runtime_registry.odin:221–228,428–446`: `has_live` acquires/releases a registry connection; marking offline removes the matching generation. Delivery admission count never consults this registry. |
| Retiring a pull is not deleting its durable consumer | `forwarder.odin:292–304` destroys the long-pull subscription under exclusive `conn_lock` and flushes. Consumer creation is at `forwarder.odin:143–157`, named `brg_<bridge_id>`, filtered to `dlv.*.<bridge_id>.>`. Deletion is a separate supervisor path in `advisory.odin:107–139`. |
| Route succeeds without admission or liveness checks | `delivery.odin:163–236`: validates identity, owner and feature capability, then inserts a `routed` row plus transactional outbox envelope. It does not call `find_forwarder` or test disabled/refused state. |
| Refused bridge does not receive a frame through this service | `forwarder.odin:18–22` only finds existing entries. New refused bridge has no worker/pull; existing disabled entry remains disabled on refused reactivation. `on_bridge_online` returns no admission result to its caller (`src/hub/transport/http/bridge_handlers.odin:1878`). |
| Expiry misattributes capacity failure to offline status | `delivery.odin:283–294,317–340`, `offline.odin:139–142`, `forwarder.odin:208–218` close expired open delivery as `failed / bridge_offline` without checking current liveness or refusal. |
| This is not a command-result failure | `result.odin:28–32,51–88` handles already-forwarded deliveries: accepted extends progress; retry uses delayed NAK; exhausted retries become `no_answer`; fatal answers use supplied cause or `start_failed`. Refused unforwarded delivery never reaches these branches. |

The other `256` in `src/contracts/delivery_wire.odin:7` is `DELIVERY_MAX_ACK_PENDING`: a JetStream per-bridge open-delivery bound. It is unrelated to the hardcoded service forwarder count. `DELIVERY_MAX_IN_FLIGHT=16` bounds unanswered frames per bridge, `ACK_WAIT_MS=60000`, handler budget is 30000 ms, and max deliveries is 8. Increasing AckPending cannot fix admission exhaustion.

### Focused executable reproduction

The retained scratch fixture is `docs/audits/delivery-capacity/capacity_repro.odin.txt`. It calls the actual delivery package functions and real in-memory SQLite repository using existing fixture helpers; it is not a Python model. It creates no production code change and no running service threads or NATS server. Temporary package test source was removed after execution.

```bash
cp docs/audits/delivery-capacity/capacity_repro.odin.txt src/hub/service/delivery/rca_scratch_test.odin
nix develop -c odin test src/hub/service/delivery -collection:odin_test=src -define:ODIN_TEST_NAMES=delivery.test_rca_offline_capacity_and_expiry -define:ODIN_TEST_THREADS=1 -out:$HOME/.cache/heimdall-tests/delivery-rca-$(date +%s)
rm src/hub/service/delivery/rca_scratch_test.odin
```

Result: **1 test executed, 1 passed, exit 0**, 616.50911 ms; shell session `sh_2d16008770e7c99a548ee85ef36187ce`. Relevant captured output:

```text
[offline.odin:177:forwarder_refused_locked()] delivery forwarder limit reached brg_one
RCA: 256 offline retained; live 257th refused; route accepted; failed/bridge_offline on expiry while live; deletion releases capacity
Finished 1 test in 616.50911ms. The test was successful.
```

Assertions cover 256 successive registry online/offline transitions; enabled count and list length remain 256; absent registry entry parks `forwarder_pass`; live `brg_one` is refused; repeat refusal increments counter only once; routing still succeeds; explicit expiry after a one-hour clock advance invokes the final sink with `failed / bridge_offline` while `has_live` remains true; deletion of an earlier bridge permits admission. The test proves state transitions and admission behavior. It does not prove real threaded teardown, NATS consumer delivery or rendered UI behavior. Those are source-traced here and proposed as implementation regressions below. Existing suites were not run under the chain test-runner policy; this newly authored scratch test was run directly.

## What users and agents see today

For Actions prompt routing, the production sink is registered at `src/hub/app/wiring.odin:658–661`. `src/hub/service/actions/router.odin:112–140` maps delivery `failed / bridge_offline` into Action run `failed / bridge_offline`. Before expiry the run remains `routed` and its delivery remains `routed`; there is no capacity-specific reason. A successful prompt follows different semantics: `delivered` can mean awaiting read, then `done` after read; do not collapse these states in the fix.

The run-history endpoint (`src/hub/transport/http/action_handlers.odin:181–220`) exposes run `state`, `reason`, delivery ID, expiry, delivery state and outcome. `actions/router.odin:505–526` calls `expire_open_run` during history reads, so reading history after the deadline can itself finalize the failure. Startup/reconnect also calls `expire_due` (`delivery/advisory.odin:19,97`). Do not promise failure appears at the exact expiry instant: no unconditional periodic expiry call was found in the inspected delivery supervisor.

The Actions UI (`src/ui/components/actions/RunHistory.tsx:6–24`) shows “Sent to …, waiting for it · expires …” while routed, then a failed badge and **“The machine stayed offline”** for this failure. This implies an offline machine even when capacity is the cause. Agents/operators can inspect the same JSON through the automations run-history command, routed by `src/ctl/automation_cmds.odin:75–107`:

```bash
ham-ctl automations runs <action-id> --limit 50
```

A missing delivery frame means the target agent receives no corresponding notice/prompt from this path; the caller receives no synchronous admission failure. This is silent at admission, not absence of all durable history. Other bridge-offline messages in task placement, shell logs, bot delivery and ACP chat use separate mechanisms and must not be mistaken for proof that this delivery refusal is surfaced there. Only the Actions prompt sink is registered to this service in inspected production wiring; generic wire kinds `notice`, `bot`, `lease` are supported by route validation but that alone proves no production caller or user-visible finalization for them.

### Logging and observability gap

`offline.odin:172–177` logs **“delivery forwarder limit reached”** and increments `forwarders_refused` once per distinct refused bridge ID retained in `refused_bridges`. This is a deduplicated historical count, not current saturation, refusal attempts or recovery. Repository search found no production reader/exporter of `forwarders_refused` outside this service. Repeated retries for the same ID produce no new warning. There is no admission error returned from `on_bridge_online`, capacity reason persisted by `route`, user alert, or explicit recovery signal. NATS retry diagnostics in `advisory.odin` cover connection/consumer failures, not this early refusal. Calling this entirely unlogged would be incorrect.

## Options and recommendation

| Option | Benefit | Cost / limitation |
| --- | --- | --- |
| Offline TTL eviction | Reclaims parked workers after transient disconnect grace; predictable churn | Timer and reconnect fencing required; cannot admit during grace unless pressure overrides it |
| LRU eviction | Makes room under pressure | Evicting live/in-flight bridges creates unfairness, churn and replay risk; LRU must be restricted to eligible offline entries |
| On-demand reclamation | Before refusal, retire an eligible offline worker immediately | Admission must serialize selection/reservation and retry after retirement; every offline event still needs bounded cleanup |
| Raise/remove 256 | Larger simultaneous fleet | One thread and consumer per enabled bridge remains; removes symptom only, risks unbounded resources and historical metadata growth |
| Bounded worker pool | Scales active bridges independently of thread count | Larger scheduling redesign with fairness and pull ownership complexity |

**Recommended first fix:** configurable active-worker limit (default 256, independently named from AckPending), offline grace TTL of 60 seconds, plus immediate pressure reclamation of the oldest eligible offline worker. Keep live workers protected. Retain small stable metadata initially to preserve pointer safety, with an explicit bounded cleanup design as a later task. Do not use `disable_forwarder` unchanged: it requests durable consumer deletion, which is inappropriate for a temporary offline capacity eviction.

Retiring a worker must preserve its durable `brg_<bridge>` consumer and pending delivery semantics. Recreate/bind its local pull on later admission, recovering reservations from SQLite. Serialize reconnect/admission against retirement; validate registry generation again before parking. Automatically retry refused online bridges after capacity release and on a bounded retry timer, rather than requiring a new hello. Under 257 simultaneously live bridges, reject/defer transparently at the configured limit and expose it; TTL cannot create capacity in that case. A later worker-pool task can address that workload if required.

Add a distinct durable `delivery_capacity_exhausted` reason for known admission refusal, and propagate it through Actions finalization, HTTP/CLI JSON and UI (“Delivery service is at capacity; retrying”). Preserve accepted/outbox-backed work with a visible waiting reason until retry or deadline; expiry for known capacity starvation must retain that reason, never overwrite it with `bridge_offline`. If an API cannot retain work, return an explicit retriable capacity error (HTTP 503 with stable code and retry guidance) rather than success. All newly routed and already-pending deliveries need coherent classification, including refusal arriving after route commit. A synchronous check alone cannot cover that race.

Export low-cardinality gauges for enabled/live/offline/retiring/refused-waiting counts and configured capacity; counters for refusal attempts, reclamations and recoveries; oldest pending age and capacity-blocked age. Avoid bridge IDs as metric labels. Warn on entering/leaving saturation with rate limiting, and alert operators if saturation persists 60 seconds or oldest capacity-blocked delivery exceeds 60 seconds. Persist a user-visible health/status event per affected owner, deduplicated with recovery; agents obtain the same stable reason via status/run-history APIs. These are proposed defaults, not current behavior.

## Concurrency and durability requirements

- Stable pointers currently escape `s.mutex` through `find_forwarder`, `forwarder_snapshot` and result callbacks. Removing/freeing entries without reference ownership permits use-after-free. Retain metadata for the first fix; later cleanup requires refcounts or an owner-thread/message model.
- Never join a worker while holding `s.mutex` or `conn_lock`. Existing lifecycle mutex serializes start/join; worker passes and supervisor snapshots require other locks. Specify one lock order and test admission, retirement and shutdown together.
- Stop/fence new passes, wake the worker, wait for any bounded local receive and destroy its message before destroying the long pull. `conn_lock` protects connection/pull destruction; consult `docs/socket-lifetime.md` before implementation.
- Late result/ack callbacks must still find delivery state. Preserve/flush answers or safely rely on redelivery and database idempotency; never apply a late reply to another attempt or release another reservation. Account for recovered reservations conservatively for a full AckWait when necessary.
- Offline registry checks are snapshots. A stale offline callback/TTL must not retire a newly connected generation. TTL, on-demand pressure, reconnect and NATS reconnect require generation fencing plus revalidation.
- Do not delete a consumer for temporary reclamation: deletion/recreation can reset delivery counts and progress. Existing asynchronous `delete_consumer` requests can race with reactivation even without new reclamation; the fix must fence requests by lifecycle generation. Permanent deletion/downgrade still needs cleanup and must not recreate a consumer.
- Expiry, final result, replacement and admission-status updates must use state compare-and-set in a UoW, with notifications after commit. Preserve existing prompt read receipts and final sink idempotency. Avoid NATS I/O while holding a database transaction.

## Requirements and implementation task breakdown

Scope includes delivery service lifecycle/admission, contract/error codes, configuration, registry generation integration, Actions reason propagation, diagnostics and status UI/CLI. Scope excludes deployment, changing max attempts/AckPending, unrelated bot/ACP/placement rewrites and a worker-pool redesign. Implementation begins only after user approval.

| Task | Requirements | Acceptance and main risk |
| --- | --- | --- |
| T1: Admission contract and state design | R1: distinct capacity reason and explicit retriable behavior. R2: configurable positive active-worker limit. Define waiting-state storage and owner-scoped health API/event contract before coding. | Contract fixtures distinguish offline/capacity; invalid config rejected; existing delivered/read semantics preserved. Risk: reason allowlists silently map new cause to `start_failed`. |
| T2: Offline worker reclamation | R3: TTL and pressure reclaim only offline workers, retain durable consumer. R4: serialize admission/retirement with registry and lifecycle generations. | 256 historical offline bridges do not prevent live bridge admission; limit never exceeded concurrently; reconnect before/after grace works; consumer progress survives. Risk: deadlock, stale consumer deletion, duplicate workers. |
| T3: Recovery and observability | R5: automatic fair retry of refused bridges. R6: metrics, warnings/recovery, owner-visible status, durable capacity waiting and expiry classification. | Saturated live fleet shows capacity reason promptly, recovers without hello/restart, no cross-owner data leak or high-cardinality metrics. Risk: missed wake, unfair retry loop, unbounded refused metadata. |
| T4: Actions/API/UI integration | R7: propagate stable cause through final sink, run-history API, automations CLI and Actions history; truthful pending/terminal text. | Current repro shows capacity wording instead of “machine stayed offline”; JSON reason matches; existing offline and awaiting-read text unchanged. Risk: enum/allowlist mismatch. |
| T5: Integrated regression and load validation | R8: prove lifecycle invariants under failures and measured resource bounds. Decide bounded metadata cleanup/pool follow-up from results. | Tests below pass; increasing distinct bridge churn does not increase enabled workers or retained pulls; known metadata retention measured and documented. Risk: mock-only validation misses NATS behavior. |

### Required regressions for the fix

1. Preserve this baseline reproduction, then invert assertions for automatic admission after offline reclamation; test 255/256/257 and configured limits, concurrent hello and repeated hello without duplicate entries.
2. TTL before/at/after boundary; reconnect immediately before selection, during join and after retirement; stale offline generation ignored. Pressure reclaims offline oldest only; never evicts live/in-flight workers merely for LRU recency.
3. Real NATS: `brg_<bridge>` survives temporary eviction with ack pending, delivery count and redelivery intact. Maintain 16-frame in-flight cap and 256 AckPending independently. Permanent deletion/downgrade removes consumer, including retry after NATS failure.
4. Reclaim while a message is fetched, result callback queued, progress reply pending, ACK fails or NATS reconnects. Older success, duplicate fatal result and delayed ACK remain idempotent; no dangling pull, use-after-free, double destroy or deadlock.
5. Refused live bridge gets visible capacity status before deadline and automatically resumes after another worker retires. Refusal after route commit updates pending status. Capacity expiry preserves capacity cause; actual offline expiry remains offline. Restart rebuilds admission/status coherently.
6. Actions final sink/API and automations request tests retain new cause; UI pending/failure/recovery text is accurate, including grouped runs and delivered-awaiting-read. Test tenant visibility and notification deduplication.
7. Churn thousands of bridges and 257+ simultaneously live bridges; measure threads, heap, consumers, refused metadata and pending latency. Verify saturation alert and recovery without restart; document configured operating envelope.

## Validation and review decision

The native scratch reproduction passed 1/1. No production, contract, UI or existing test source changes remain. Only this proposal and its inert reproduction fixture are committed. Broader suites and deployment were intentionally skipped because this is an investigation, not implementation. Confidence is high for the reproduced RCA; the proposed concurrent lifecycle is a design requiring the regressions above.

Requested decision: approve this fix scope and recommended policy, or request changes. Approval authorizes follow-up implementation tasks through the task workflow; this document itself does not implement or deploy the fix.
