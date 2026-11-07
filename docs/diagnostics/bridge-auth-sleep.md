# Laptop sleep and Bridge credential renewal diagnosis

**Verdict: a delayed-renewal window is confirmed in the inspected source; the reported laptop incident remains unproven.** Reconnect repeatedly snapshots the current access token without checking its age or waking refresh. The independent refresh worker can still be sleeping after the Hub has expired that token. Linux suspend semantics make this a concrete source-backed scenario. The theory that reconnect permanently captured an old token is refuted: successful durable refresh changes the next reconnect snapshot. macOS/Windows native suspend behavior and incident causality have not been reproduced.

This is diagnosis and a repair proposal only, for task `task_18e5bd45faceb768`, requirements revision 2, on 2026-11-07. No authentication implementation, rollout, live refresh, sign-out, credential-store inspection or service restart was performed.

## Source and deployed-version boundary

All repository references below use source `873aa65cb717c752b2b75db93fe29b62e3c93634`, the isolated worktree and integrated checkout HEAD at investigation start.

| Device evidence supplied by coordinator | Reported build | Source comparison |
| --- | --- | --- |
| Mac `brg_18e30f3f36df903e`, online | 0.5.49, `ada2d4c8e76fdfaaf98f41e5f4ad96ded206cf04`, built 2026-11-05T14:15:48Z | Refresh file and four runtime authentication procedures identical |
| Windows `brg_18e3e1f4d5867bcd`, offline | 0.5.49, same commit, built 2026-11-05T15:14:29Z | Same source match; no Windows execution |
| riverwood/dawnstar Linux | 0.5.48, `486f2e1dd6939e79b6f57577f457bde7d5b2ec79`, built 2026-11-04T15:49:25Z | Same source match |

The coordinator supplied this nonsecret metadata in `msg_18e5bd767d2acf65`; no executable hashes or incident logs were supplied. This maps reported builds to checked-in logic, not a forensic verification of running laptop binaries or the live Hub. The ongoing native worktree was neither changed nor used as the source baseline.

[Offline probe](bridge-auth-sleep-model.py) verifies the entire refresh file plus `bridge_hub_runtime_worker`, `bridge_hub_reconnect_sleep`, `bridge_credential_reauth_drain` and `bridge_hub_session_frame` across all three revisions. Refresh-file SHA-256: `d38717a2ad8768aeb24b01e27829fcb91dcd0ed5b5dda281250c9f0820c1a86d`. Other native-runtime changes exist between releases and HEAD.

## Actual authentication path

These are **opaque, database-backed Bridge tokens**, not JWTs. No JWT payload or expiry parser is involved. Access credentials use `hba_`; refresh credentials use `hbf_`. This is independent of human OIDC/browser/Electron sessions and provider CLI OAuth. Agent instance tokens are another distinct local Bridge boundary.

1. **Startup:** [main.odin:197](../../src/bridge/main.odin#L197) resolves persisted credentials; [main.odin:541](../../src/bridge/main.odin#L541) adopts the default credential file only if neither an explicit token nor a credential path was supplied. Runtime starts at line 276, then the refresh worker at line 280. Thus startup can attempt a cached expired access credential before its first renewal.
2. **Refresh admission:** [enroll_device_flow.odin:757](../../src/bridge/enroll_device_flow.odin#L757) starts renewal only with a credential file and readable, usable adjacent refresh file. Missing files return without starting; malformed refresh emits a diagnostic. An explicit access token with no credential file does not gain renewal merely because a default pair exists elsewhere. This configuration-dependent indefinite failure is distinct from sleep delay.
3. **Schedule:** [enroll_device_flow.odin:701](../../src/bridge/enroll_device_flow.odin#L701) schedules 75–85% of the returned lifetime, with a 30-second floor capped by lifetime. The worker first sleeps 30 seconds; after a normal 3600-second grant it sleeps 2700–3060 seconds (2880 with jitter byte 128). [Worker:776](../../src/bridge/enroll_device_flow.odin#L776) uses one relative `time.sleep` before each cycle. It has no resume callback, expiry metadata consultation or reconnect wake signal.
4. **Hub validity:** [bridge_token_service.odin:86](../../src/hub/service/bridge/bridge_token_service.odin#L86) defines 3600-second access, 30-day sliding refresh and 365-day absolute family lifetime. [Expiry comparison:299](../../src/hub/service/bridge/bridge_token_service.odin#L299) uses the Hub clock with 60-second boundary grace. [verify_access_token_scoped:342](../../src/hub/service/bridge/bridge_token_service.odin#L342) checks stored kind, secret, scope, revocation and expiry. A client's local clock does not decide Hub acceptance.
5. **Reconnect:** [hub_runtime_client.odin:377](../../src/bridge/hub_runtime_client.odin#L377) takes a mutex-protected fresh snapshot for every dial. [Snapshot:1770](../../src/bridge/enroll_device_flow.odin#L1770) clones current in-memory bytes. [ws.odin:57](../../src/lib/ws/ws.odin#L57) creates that attempt's bearer header, including the TLS path. There is no reconnect closure holding one token forever and no disk reread per dial.
6. **Rejection:** failed WS connect logs status and backs off (500ms to 30s with jitter), without refresh. The current Hub normally verifies Bridge identity after upgrade/hello, [bridge_handlers.odin:1750](../../src/hub/transport/http/bridge_handlers.odin#L1750), and emits a typed `bridge_token_expired` frame. [Session handling:854](../../src/bridge/hub_runtime_client.odin#L854) logs expiry and reconnects, again without waking refresh. This covers both HTTP upgrade rejection and the actual post-upgrade expiry path. A revoked credential or pending sunset parks traffic instead.
7. **Established sessions:** [bridge_handlers.odin:2155](../../src/hub/transport/http/bridge_handlers.odin#L2155) closes expired sessions and revalidates token rows. Successful refresh sets an in-band reauthentication flag; [reauth drain:840](../../src/bridge/hub_runtime_client.odin#L840) sends the new credential when negotiated. A failed renewal frame can still lead to reconnect; it does not itself exchange refresh tokens.
8. **HTTP:** [hub_http.odin:30](../../src/bridge/hub_http.odin#L30) handles admission/revocation/sunset, not generic refresh-on-401. Callers such as [action_scheduler.odin:687](../../src/bridge/action_scheduler.odin#L687) snapshot credentials per operation and fence stale responses at line 705. An already admitted request can carry the previous generation; this is not evidence of persistent WS header caching.

The Hub service comment saying expired access “refreshes and retries once” is descriptive intent; it is not implemented by these WS branches.

## Suspend, clocks and offline evidence

The Nix development toolchain reported `odin version dev-2026-09`, root `/nix/store/4p3p3dbyygl9xj2j4rspdz7j0hw65s5c-odin-dev-2026-07a/share/`. Its platform implementations use Linux `linux.nanosleep`, Darwin `posix.nanosleep` and Windows `win32.Sleep`. The separately installed host Odin 2026-06 has the same bindings; it was not used to run the suites. Release compiler identity was not independently established.

| Platform | Established evidence | Limit |
| --- | --- | --- |
| Linux | Odin calls relative nanosleep. [Linux nanosleep documentation](https://man7.org/linux/man-pages/man2/nanosleep.2.html) identifies CLOCK_MONOTONIC; [clock documentation](https://man7.org/linux/man-pages/man2/clock_gettime.2.html) states it excludes system suspend. | A source/API-backed failure scenario, not a physical suspend run |
| Darwin | Odin calls POSIX nanosleep and resumes remaining time after EINTR. [Apple libc source](https://github.com/apple-oss-distributions/Libc/blob/55b54c0a0c37b3b24393b42b90a4c561d6c606b1/gen/nanosleep.c) has relative wait and mach-time branches. | Exact deployed libc/kernel, hardware and sleep-mode behavior not mapped or measured; Linux timing must not be attributed to the Mac |
| Windows | Odin calls [Sleep](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-sleep). | Native low-power timing unmeasured. Microsoft's explicit suspend exclusion for [WaitForSingleObject](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-waitforsingleobject) is for a different API and does not alone prove this Sleep path |

The committed probe is an intentionally conditional scheduler model, not execution of the production worker or proof of native power behavior. It checks exact source premises before modeling:

- Mint generation A at wall/awake time 0, expiry 3600; next renewal at awake time 2880.
- Suspend at awake time 600 for 7200 wall seconds. Hub time reaches 7800, beyond expiry and grace.
- With suspend-excluding relative sleep, renewal still has 2280 awake seconds remaining. Reconnect at 0, 30, 300 and 2279 seconds after resume snapshots expired A. Neither rejection branch wakes renewal.
- At remaining-timer expiry, successful durable rotation adopts B; the next snapshot is B. The modeled outage is 38 minutes plus connection/refresh scheduling and transport latency. The whole jitter band allows up to roughly 51 minutes of remaining awake timer in this normal one-hour case; it is not a universal recovery bound.
- If a platform counts suspend toward its timer, refresh can be due immediately on resume. Refresh-first yields B; reconnect-first can yield an expired A attempt before B is adopted. No deterministic thread ordering is promised.
- This model assumes a healthy surviving worker and successful persistence. Refresh failure, network restoration, process termination or scheduler delays add separate conditions; permanent retry is not implied by the sleep model.

## Failure and rotation paths

[Refresh transport:1776](../../src/bridge/enroll_device_flow.odin#L1776) POSTs the **refresh** bearer to `/api/v1/device/bridge-refresh`, with a cumulative timeout up to 10 seconds. [Hub handler:44](../../src/hub/transport/http/bridge_refresh_handlers.odin#L44) needs no user session or valid access token. Expired access alone therefore does not prevent renewal.

The worker has one renewal thread. Its bounded exchange budget is six attempts/120 seconds, [retry_budget.odin:7](../../src/bridge/retry_budget.odin#L7). Budgets use wall time with a process-local monotonic lower bound; this is separate from the long relative scheduling sleep. Clock rollback can park a budget rather than silently extend it.

- **Transient exchange failure, no returned pair:** [worker:878](../../src/bridge/enroll_device_flow.odin#L878) pauses 60 seconds and reopens retriable terminal budgets. Restart does the same at line 810. The old “one timeout permanently parks renewal” behavior is covered by an existing regression and is not the current intended path.
- **Lost reply:** a durable request ID exists before send and survives retry/restart. Unknown outcomes retry with that identity. [Hub rotation:468](../../src/hub/service/bridge/bridge_token_service.odin#L468) permits bounded same-rotation recovery, including a 600-second request-ID window, subject to descendant delivery/redemption constraints. An in-flight rotation followed by a long suspend can exceed this window; retry may then be rejected as spent-token reuse and revoke the family. That is a separate conditional explanation, not failure to use refresh.
- **Returned pair but local persistence failure:** [recovery step:1865](../../src/bridge/enroll_device_flow.odin#L1865) retains the pair, saves a pending record and commits refresh then access files before adoption. It does not repeatedly exchange the spent refresh token. After the local commit budget exhausts, the worker returns with the pair parked; old in-memory access can subsequently expire and continue reconnecting. Restart/local repair can resume the pending pair, but this is not automatic indefinite transient recovery within that worker lifetime.
- **Invalid pending record/no resumable receipt:** worker lines 788/805 return deliberately. A corrupt/full/failed retry journal can also prevent exchange. These are repair conditions, not proof of a token-expiry timer bug.
- **Final refresh rejection:** [typed refresh:1790](../../src/bridge/enroll_device_flow.odin#L1790) stops traffic; [apply rejection:1898](../../src/bridge/enroll_device_flow.odin#L1898) removes persisted pair and marks re-enrollment. Expired/revoked refresh, absolute family expiry and spent-token rejection are distinct from expired access. No such cleanup was invoked against live state.
- **Successful adoption:** [adopt:1884](../../src/bridge/enroll_device_flow.odin#L1884) changes in-memory credential only after durable pair writes. Reconnect then uses B. External file replacement alone does not update that memory; this investigation did not replace files.

Network/TLS/DNS outage, clock changes, profile mismatch, vault-key/boot handshake failure and provider/browser session expiry can resemble “offline” and need separate status evidence. A vault error after successful Bridge authentication does not establish bearer expiry.

## Proposed robust repair (not implemented)

1. **One credential owner:** replace independent “snapshot bytes” admission with a deadline-bounded `ensure_access_credential` used before each connect and appropriate authenticated HTTP admission. Keep proactive refresh as a client of that owner. Preserve opaque-token semantics; do not parse tokens as JWTs.
2. **Track validity conservatively:** retain generation, receipt time and Hub-returned lifetime alongside the durable pair. Use suspend-inclusive elapsed time where available plus bounded wall-clock/wake re-evaluation. Treat restart without trustworthy age, detected suspend, backward/large forward clock changes and unknown metadata as requiring revalidation/refresh. A wrong wall clock must not cause unlimited retries or authenticate expired data; the Hub remains authoritative. Account conservatively for exchange latency and refresh safety margin.
3. **Wakeable scheduling:** use an event/condition and a maximum bounded reevaluation interval, not one uninterruptible 45–51-minute sleep. Resume/network restoration/reconnect admission can wake the owner. Concurrent wakeups coalesce. Avoid polling continuously or refreshing independently on every failure.
4. **Bound rejection recovery:** typed access-expired frames and an auth rejection may request at most one shared renewal and one retry for the attempted generation, within the existing operation deadline/backoff. If a newer generation already exists, retry it without spending refresh again. Repeated rejection of the new generation surfaces an explicit status and backs off. Generic 403, plan limit, sunset and revocation must retain their own policy; do not blindly refresh every authorization failure. Raw upgrade status lacks sufficient cause, so retain a bounded policy without treating it as refresh-token rejection.
5. **Serialize and fence:** one in-flight exchange per hub/bridge/profile; waiters share its result. Bind each request/result to the owner identity, activation epoch and credential generation. A late old response cannot replace newer enrollment, undo revocation, clear a newer pending renewal or delete current files. Recheck those fences before durable commit and in-memory publication. Also fence handshake success clearing the reauth flag: an old-generation hello must not clear a renewal published while that hello was in flight.
6. **Preserve crash-safe rotation:** retain durable request identity and pending pair. A pair received becomes local-commit work, never another spend of the old refresh token. Commit metadata and both credential files transactionally through a durable recoverable manifest/journal; current sequential writes are safe only with the pending record and recovery protocol. Publish a new generation after durable commit. Resume local-commit repair with bounded backoff and explicit health status rather than silently returning forever. Retain fail-closed behavior for corruption and final rejection; never weaken Hub reuse detection to hide loss.
7. **Resilient retries and telemetry:** keep finite per-operation budgets, pause/reopen retriable network failures, preserve credentials across transient sunset and lost replies, and surface parked/disabled renewal. Emit only generation numbers, reason/status, age/due duration, worker state and attempt counts. Never emit credentials or token hashes.

### Acceptance for a separately authorized implementation

| Test | Required outcome |
| --- | --- |
| Fake suspend longer than access lifetime; both timer semantics; reconnect-first and refresh-first | Expired generation is not repeatedly dialed for an entire remaining proactive interval; one bounded shared renewal |
| Cold restart with expired/unknown-age cached access; missing/invalid refresh file; explicit-token configuration | Prompt bounded renewal when eligible, otherwise explicit actionable state; no hidden permanent retry |
| Proactive timer, reconnect, HTTP 401 and resume race | One refresh exchange; all waiters use the committed generation |
| Old handshake/401/refresh result arrives after newer rotation, enrollment or revocation | Cannot overwrite or delete newer state or clear its renewal flag |
| Disconnect/lost reply before/after send, process crash, request-ID retry inside/outside grace | Preserve current Hub security contract and explain final rejection; no duplicate independent spends |
| Disk full, pending-write failure, each pair-write crash point, journal corruption | Recover received pair without reexchange; bounded local retries and visible parked status; no half-pair publication |
| DNS/TLS/offline, 429/5xx, sunset, final invalid_grant, family expiry | Retry only retriable cases with bounded budgets; preserve final refusal and sunset rules |
| Forward/backward clock jumps and actual Linux/Darwin/Windows suspend | No dependence on JWT parsing or trusted client wall time; native timings measured and release/compiler identities recorded |

Do not expand this repair into provider OAuth, browser-session refresh or the separate cancel/split planning task. Required independent and user review gates still apply before any implementation authorization.

## Verification record and remaining evidence

All commands ran in `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e5bd45faceb768`.

- `python3 docs/diagnostics/bridge-auth-sleep-model.py`: exit 0; three source matches and six modeled ordering observations. Session `sh_e049ea1105de4826d2f4e939d2106d49`.
- Bridge suite below: **10/10 successful**, exit 0, session `sh_e8ef3ca6bd04685e93fba8af347be034`. Mock exchange/persistence callbacks and isolated test files; ODIN_TEST journal avoids production state.
- Hub suite below: **11/11 assertions successful**, exit 0, session `sh_0ee05b6958f8e9b1431b4df306a16493`. Temporary SQLite fixtures and fake Hub clock. Runner also reports allocation leaks and bad-free warnings in fixture/repository cleanup; this is **not a clean memory-safety result**. No unrelated fixes made.
- Full suites/builds/native suspend/live auth checks skipped: no implementation changed; targeted checks establish these source/model claims without altering live credentials or disrupting native work.
- Initial shell `rg` was unavailable; used bounded `grep`/Python instead. Nix store compiler files were readable only inside `nix develop`; host-path lookup failure was not platform evidence.

Exact focused test commands:

```bash
nix develop --command sh -c 'odin test src/bridge -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/auth-diagnosis-bridge-$$ -define:ODIN_TEST_NAMES=refresh_delay_lands_in_the_jittered_band,refresh_delay_is_zero_for_a_non_expiring_credential,refresh_delay_never_schedules_past_expiry_on_short_lifetimes,refresh_local_persistence_failure_never_reexchanges_spent_token,refresh_pending_pair_survives_disk_restart_and_preserves_parent_budget,refresh_unknown_outcome_retries_instead_of_parking,refresh_lost_reply_is_recovered_by_a_retry_with_the_same_request_id,refresh_restart_after_retriable_terminal_receipt_retries,refresh_request_id_is_durable_and_scoped,refresh_200_with_an_unusable_body_is_a_protocol_error_not_a_timeout'
nix develop --command sh -c 'odin test src/hub/service/bridge -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/auth-diagnosis-hub-$$ -define:ODIN_TEST_NAMES=test_access_token_expires,test_refresh_rotates_and_kills_the_old_token,test_refresh_token_reuse_revokes_the_whole_family,test_refresh_grace_window_recovers_a_crashed_bridge,test_family_absolute_cap_forces_reenrollment,test_token_kinds_are_not_interchangeable,test_token_expiry_edge_cases,test_refresh_retry_with_same_request_id_recovers_a_lost_reply,test_refresh_retry_refused_once_the_new_access_token_was_used,test_concurrent_retries_never_mint_two_live_generations,test_refresh_retry_without_matching_request_id_or_after_window_is_theft'
```

To attribute the actual incident, obtain only: affected bridge/profile and build identity, OS/sleep mode, UTC suspend/resume and first failure/success times, redacted auth status/typed cause, and whether refresh was running, paused, rejected or parked. Correlate “credential refreshed”, “refresh paused/recovery stopped”, “bridge_token_expired”, connect failures and renewed-session timestamps. Do not collect complete logs or credential files. No incident UTC/status logs were available, so **actual Mac/Windows incident cause remains inconclusive**. Confidence is high for the source trace, source/release comparison and conditional Linux window; native incident causality is explicitly outside that confidence.
