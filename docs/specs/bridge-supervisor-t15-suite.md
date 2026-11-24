# T15: cross-OS failure-injection suite (Phase 1 exit)

Report §7 Phase 1 exit: "All tests pass on Linux, macOS, Windows CI runners." This file maps
every item of the Phase 1 test list (report §7) and of the engine spec's test obligations
(`bridge-supervisor-engine.md` §18) to the tests that cover it, and says where each runs.

Phase 1 acceptance also requires that **`ham-launcher` and `ham-supervisor` are in the
bundle but are not the service entry point yet** (see the last section).

## Where the suite runs

| Workflow | Packages / tests | Runners |
|---|---|---|
| `.github/workflows/supervisor-e2e.yml` | `src/supervisor/e2e` — real `ham-launcher` → `ham-supervisor` (test build) → `fakebridge`, fake GitHub on loopback, releases signed with the test key | ubuntu-24.04, macos-15, windows-latest |
| `.github/workflows/supervisor-unit.yml` | `src/supervisor/{resolver,engine,procs,runtimectl,service}` + `bridgesvc.test_service_entry_point_is_still_ham_bridge` | ubuntu-24.04, macos-15, windows-latest |
| `.github/workflows/supervisor-fetch.yml` | `src/supervisor/fetch` (verification, extraction, OS signatures, W2/W3) | ubuntu-24.04, macos-15, windows-latest |
| `.github/workflows/launcher.yml` | `src/launcher/core` (fallback rule, T_ready / T_commit, stop paths) | ubuntu-24.04, macos-15, windows-latest |
| `.github/workflows/release-local-binaries.yml` | bundle contents, storeless `--version` of every shipped binary | release runners (all targets) |

Local: `nix develop -c scripts/supervisor/e2e.sh [out-dir]` (Linux/macOS);
`E2E_TEST_NAMES=e2e.test_hub_offline,…` runs a subset. The two-OS-users test needs
`HEIMDALL_E2E_OTHER_USER` + `HEIMDALL_E2E_SHARED_DIR` (Windows also
`HEIMDALL_E2E_OTHER_PASSWORD`, `HEIMDALL_E2E_OTHER_SID`); CI creates the account. It is
skipped (with a warning) without them.

## Test hooks (test builds only)

All hooks live in test binaries or in code compiled only with
`-define:HEIMDALL_SUPERVISOR_TEST=true`; `scripts/supervisor/e2e.sh` and the Windows step
check that a default build carries no test key.

| Hook | Effect |
|---|---|
| `bin/behaviour.txt` / `<data>/fake-behaviour/<tree>` (fakebridge) | `good`, `crash` (exit after 3 s), `noready` (never writes its control file), `unhealthy` (stops answering after 3 s) |
| `<data>/fake-hub-up`, `<data>/fake-hub-down/<tree>` (fakebridge) | `runtime-status.json` `connected` true/false, per tree |
| `fakebridge --hold <s>` | a straggler process holding its release tree's executable |
| `bin/supervisor-behaviour.txt` (supervisor test build) | `noready` (never READY → launcher T_ready), `exit78` (exits 78 in probation) |
| `HEIMDALL_SUPERVISOR_TEST_{ORIGIN,PROBATION_S,READY_S,FIRST_CHECK_S}` | fake GitHub origin; 5 s probation; 10 s runtime-ready deadline; timer first check |
| fake GitHub (`src/supervisor/testkit/fake_github.odin`) | pagination with `Link: rel="next"` (newest first), `.Offline` (connection dropped), `.Unavailable` (503), metadata-only stub releases, asset 404, bundle bytes swapped, release re-published with a new digest |

## Report §7 Phase 1 list

| Item | Real-process e2e (3 OSes) | Unit / package tests (3 OSes) |
|---|---|---|
| Failing candidate | `test_failing_candidates`: runtime never ready (`runtime_not_ready`), unhealthy after ready (`runtime_unhealthy`), supervisor never READY and supervisor exit 78 in probation (both `launcher_fallback`); each rolled back to v0.6.0 and pinned. `test_supervisor_end_to_end` step 3: crash in probation (`runtime_exited`) | engine `inject_test` baseline outcomes; launcher `test_no_ready_within_t_ready_falls_back`, `test_exit_78_of_unproven_current_falls_back`, `test_unproven_past_t_commit_falls_back` (hang after READY: 270 s T_commit, launcher-level only) |
| Failing rollback | `test_failing_rollback_and_repair`: candidate and rollback target both crash → `rollback_failed`, no runtime; sticky across a restart; `repair` of the intact tree is `noop up_to_date` and says the instance is **still** in rollback_failed; repair after damage installs `-r1`, commits, clears it | engine `test_rollback_failed_survives_restart`, `…_sticky_after_side_and_rejected_lines`, `…_sticky_after_failed_install`; service `test_rollback_failed_stays_sticky_in_service` |
| GitHub offline | `test_github_offline`: connections dropped and HTTP 503 → `failed resolve_incomplete`; bundle 404 → `failed download_failed`; same runtime process keeps running, pointers unchanged; update succeeds when GitHub is back | resolver rate-limit / partial-page tests; fetch `test_tampered_*_leaves_installed_running` |
| Hub offline | `test_hub_offline`: never reachable → `committed probation_offline`; hub up → committed without note; hub down at update time → still committed offline (an outage never blocks or rolls back); candidate that cannot reach a reachable hub → `rolled_back hub_unreachable`, pinned, rollback without the hub | engine `test_hub_rule` |
| >100 releases | `test_many_releases_and_mutable_assets` step 1: fast channel, v0.7.0 on list page 2 behind 120 newer lower releases → found and installed (fake GitHub counts page ≥ 2 requests) | resolver `test_fast_pages_to_exhaustion_over_100_releases`, `test_page_cap`, `test_fast_partial_pages_keep_installed` |
| Mutable asset | same test, step 2: v0.7.0 re-published with another digest → `failed digest_conflict`; step 3: bundle bytes swapped after publish → `failed bundle_mismatch`; nothing changes | resolver `test_equal_version_different_digest_refused`; fetch `test_tampered_bundle_leaves_installed_running` |
| Fast → stable without downgrade | same test, step 4: `set_channel stable` then `update_now` from 0.7.0 with stable 0.6.0 → `noop` | resolver `test_fast_to_stable_never_downgrades` |
| Two OS users on one hub | `test_two_os_users_on_one_hub`: B (second local account, same hub and profile/service name) and A each install and commit; A's launcher and `repair` on B's root → exit 78 (`ownership_mismatch`) although B opened the root to everyone; B rolls a bad release back while A is untouched | launcher `test_ownership_mismatch_refuses` |
| Two profiles at different versions | `test_two_profiles_at_different_versions`: A on 0.6.0, B on 0.6.1; A's bad release (rollback + pin) and A's supervisor crash (J0 reap) leave B's pointers, pins, journal and runtime process untouched; concurrent updates of both commit independently | engine `test_instance_lock_is_exclusive`; procs `test_stop_only_this_instance` |
| Busy PTY host | `test_supervisor_end_to_end` step 2: timer op waits in `waiting_for_idle` on a live session; activates once it ends, not forced | engine `gate_test` (2 h wait with a fake clock, countdown, force, `update_now` interrupt, cancel, restart keeps `force_at`); runtimectl gate hooks |
| Windows file-in-use | `test_file_in_use_and_antivirus_delay`: a straggler runs from v0.6.0's tree through three updates (W4); GC with the straggler alive: POSIX deletes the tree, Windows keeps it or its `.trash-*` (W5); removed by the next start's GC once the straggler exits | fetch `test_windows_open_file_blocks_rename_then_succeeds`; engine pointer W3 tests |
| Antivirus delay | same test: a handle without `FILE_SHARE_DELETE` on `.staging-<op>/bin` for 3 s during extraction (staging rename waits, W2/W3) and on `current.json` from before activation to 3 s after `pointers_begin` (ReplaceFileW waits); both ops commit. On POSIX the holds do not block (asserted as such) | engine `test_pointer_replace_retries_sharing_violations`, `test_pointer_replace_busy_beyond_budget_fails_before_switch`; fetch `test_staging_rename_retries_sharing_violations` |

## Spec §18 obligations beyond the Phase 1 list

| Obligation | Covered by |
|---|---|
| Every J0–J35 row: crash (and power loss) at each durable step | engine `test_crash_at_every_durable_step`, `test_non_crash_failure_at_every_durable_step`, `test_gate_interrupt_crash_matrix` |
| Partial page set | resolver `test_fast_partial_pages_keep_installed` |
| N-1/N+1 supervisor handover (§8) | e2e: every update hands over from the old to the new supervisor (exit 75) |
| Torn `current.json`, torn journal line | launcher `test_current_corrupt_falls_back_to_previous`; engine `test_torn_journal_tail_is_truncated`, `test_corrupt_journal_is_set_aside` |
| Snapshot-required rollback (§11.3) | engine `test_one_way_migration_restored_on_rollback` |
| Orphaned runtime after SIGKILL of the supervisor (J0; macOS lifeline only) | e2e `test_supervisor_end_to_end` step 4, `test_two_profiles_at_different_versions` step 2 |
| Supervisor that hangs after READY / exits 78 in probation (§7.2) | launcher `test_unproven_past_t_commit_falls_back`; e2e `test_failing_candidates` (exit 78) |
| Crash between `pointers_done` and exit 75 (J15a) | engine crash matrix |
| Fallback after commit / with no journal (§7.6) | engine `test_fallback_after_commit_hands_over`, `test_fallback_without_journal_rolls_back_synthetically` |
| Service stop in every row of §7.5; three clean stops in probation do not roll back | e2e `test_stops_during_probation` (3 clean stops through the stop-request file → committed; 3 hard kills → `rolled_back probation_interrupted`); engine `test_three_clean_stops_do_not_roll_back`, `test_three_unclean_restarts_roll_back`, `test_service_stop_during_activation_before_switch` |
| Windows: clean stops use the §7.3 paths; logoff / `schtasks /End` | **Windows expectation (T9 carry-over c):** only the stop event (same session) and the stop-request file (any session, incl. SSH/headless) are clean. `schtasks /End` and logoff kill the launcher's job hard (TerminateJobObject): unclean, they count toward the 3 attempts. `test_stops_during_probation` asserts both on Windows (TerminateProcess of the launcher = what End does to the job). Session-end delivery is tested synthetically only (launcher `test_windows_session_end_is_graceful`); it is not relied on. |
| `retry_failed` → fresh T_commit (§7.2) | launcher `test_unproven_without_fallback_gets_fresh_t_commit` |
| `repair` of a damaged live tree (J34, `-r<n>`) | e2e `test_failing_rollback_and_repair` step 3; fetch `test_tree_name_choice` |
| Slow orphan reap within T_ready (J0) | procs `test_stop_escalates_after_grace` |
| `cancel` without active op / non-matching target (J35) | engine `test_gate_cancel_*`; service `test_cancel_during_download` |
| Op-id replay after rotation | engine `test_rotation_and_interrupted_rotation` |
| Preflight-after-rename under sharing violations (W2) | fetch `test_staging_rename_retries_sharing_violations`, `test_preflight_failures_remove_the_new_tree` |

## Findings recorded by the suite

- **Hub rule reads the runtime's current status.** `host_hub` (`src/supervisor/service/host.odin`,
  `hub_recently_connected`) is true only while `runtime-status.json` says `connected` *now*
  (fresh within 5 min). Spec §14 says "reported connected within 5 min before
  `gate_closed`". With a hub outage that started seconds before an update, the update
  therefore commits `probation_offline` instead of requiring the hub and rolling back.
  This is the safer behaviour for outages and `test_hub_offline` asserts it; the spec
  wording should follow (or the runtime must keep a last-connected timestamp) — decided
  outside T15.

- **Windows file-in-use, verified on windows-latest (CI run 45337661021).** A handle without
  `FILE_SHARE_DELETE` on `.staging-<op>/bin` blocks the staging rename, and one on
  `current.json` blocks `ReplaceFileW`; both ops waited in the W3 loop and committed once
  the handle closed (spec §17 "verify in T15": confirmed). GC of a tree whose `ham-bridge.exe`
  was still **running** (a straggler): the directory rename to `.trash-*` *succeeded* and
  only the delete failed, so the report's F11 hypothesis ("a directory with a loaded image
  cannot be renamed") does not hold for running executables; W1 (never touch a live tree) is
  what protects live trees, and W5 left the `.trash-*` for the next start, which removed it.
- **A refusing launcher writes `launcher-status.json` into the root it refused** (here another
  user's root that was opened to everyone on purpose) and waits `refuse_wait` (60 s) before
  exiting 78. Diagnostics only and harmless with normal permissions; noted for Phase 2.

## Launcher and supervisor in the bundle, not the service entry point

- Bundles: `release-ham-launcher` / `release-ham-supervisor` flake attrs (same static
  recipe as `ham-bridge`, no test defines) are packaged as `bin/ham-launcher` and
  `bin/ham-supervisor` in every linux/darwin tarball
  (`scripts/release/package-local-binary-tarball.sh`, codesigned on macOS with identifiers
  `works.earendil.heimdall.{launcher,supervisor}`), and `scripts/windows/build.ps1` +
  `scripts/release/package-windows-bundle.ps1` ship `ham-launcher.exe` /
  `ham-supervisor.exe` in the Windows zip. The release workflow requires both entries and
  runs `--version` of each storeless. Termux bundles do not carry them (Termux keeps its own
  path, report F8).
- Not the entry point: `bridgesvc.test_service_entry_point_is_still_ham_bridge` renders the
  systemd unit, LaunchAgent, Scheduled Task (+ `run.cmd`, `run.vbs`) and runit service and
  asserts they start `ham-bridge` and never name `ham-launcher` / `ham-supervisor`. Phase 2
  changes that test together with the services.
