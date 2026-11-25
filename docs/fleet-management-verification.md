# Integrated shared Fleet verification

Scope: REQ-FLEET-1..9 from the approved
[plan](plans/global-fleet-management.md), including the MCP active-task amendment.
The starting implementation is approved F3 `c25e6d6a76e378b21cbace47545693c43b7e97f7`,
with F1/F2, mobile Home `0a9bf9610` and Task chains plan `4a0f1e29e` in its ancestry.
This map describes coverage; exact final commit, commands, results and review
verdicts belong to task `task_18eb3f33d9107ea7` comments/handoff. A named test below
is not itself a claim that it passed.

## Requirement map

| Requirement | Executable evidence |
| --- | --- |
| 1: shared Home surface, retired drawer | `tests/ui_bridge_fleet_test.ts`, `tests/ui_fleet_actions_test.ts`, `tests/ui_placement_recovery_test.ts`: live settings/drafts, staffing-only writes, replacement recovery links and removed drawer |
| 2: bridge default and durable-agent overrides across chains | `src/hub/service/taskv2/fleet_application_test.odin`: `test_fleet_apply_all_instances_scope_and_duplicate_recovery` uses 132 targets across two chains; excludes a second bridge and non-task/stopped instances. Repository `fleet_settings_test.odin` covers atomic snapshot/revision and owner isolation |
| 3: draft versus Apply; authoritative preview | `test_fleet_preview_validation_runtime_and_override_removal`, `test_fleet_apply_atomic_rollback_validation_and_idempotency`; `fleet_integration_test.odin` adds `test_fleet_preview_revalidates_changed_running_targets`. Preview saves no settings/operations or commands; Apply takes its own current target snapshot. UI tests cover stale/loading/failed previews and direct Apply |
| 4: preserve identity, worktree, permission and task responsibility | `test_fleet_apply_active_claim_pack_generation_and_ready` covers active worker, actual-runtime pack, frozen redelivery and required gate. `test_fleet_restart_coordinator_waiting_worker_and_active_reviewer` adds coordinator, waiting author and active reviewer, unchanged claims/roles/attempts/worktree, and reviewer approval still waiting on the required user gate |
| 5: future dispatch/shared precedence, no startup reads | `src/hub/service/taskv2/shared_fleet_test.odin`, agent `start_begin_test.odin`/`start_command_test.odin`, placement/explicit-claim compatibility tests cover defaults/overrides/legacy/catalog, pins, true launches versus inline claims. Lifecycle tests inspect the existing stop/start command stream and task pack. UI tests ensure readiness does not refetch settings/preview |
| 6: validate before mutation and revalidate at acceptance | Fleet repository/service tests cover foreign owners, unavailable provider/profile/model, duplicate overrides, revision/request conflicts and rollback. Native reconfiguration tests cover changed generation/claim/stop fences; MCP tests revoke during project preflight |
| 7: saved versus restarting/ready/failed; recovery/retry | `test_fleet_apply_override_removal_and_capability_retry`, 132-target reconstruction/recovery, active-worker readiness, plus app `test_mcp_fleet_claim_retry_recovery_and_acknowledged_readiness`: ambiguous destination send, service reconstruction, stable operation/epoch/runtime/claim/worktree across a retry with fresh delivery IDs, byte-frozen same-command redelivery after retry, status reads without sends, successful targets skipped |
| 8: desktop/mobile/accessibility/WS | Focused Home layout/widgets, bridge Fleet, placement recovery, Fleet actions, reconfiguration refresh, provider profile/discovery and selection UI suites; `tests/fixtures/home-widgets/capture.mjs` inspects production components through an isolated API boundary at 1440/390 widths |
| 9: staffing/review recovery preserved | `src/hub/service/taskchain/shared_fleet_test.odin` covers staffing-only updates and runtime mutation refusal; UI staffing/Review Roles and placement recovery tests retain named/role/user gates and failed-holder context |
| MCP amendment | App `test_mcp_fleet_active_claim_shared_idempotency_cancel_and_revocation` covers delegated HTTP Apply, cross-surface replay, cancellation after commit and preflight revocation. New lifecycle regression covers HTTP Apply/status/retry through native launch failure/recovery/readiness with the same active claim/worktree/user gate. HTTP `fleet_contract_test.odin` enforces scope and strict complete draft parity |

## Retired surface and compatibility audit

`FleetManagementDrawer.tsx` and its production entry points are removed. The
replacement `ChainStaffingModal.tsx` edits capacity, warm count, idle TTL, pause
and bridge placement without sending runtime fields. `ReviewRolesModal.tsx`
retains role membership and task review requirements. Runtime recovery navigates
to Home Fleet; role and worker-holder recovery open the appropriate replacement
dialog, preserving failed role/task context.

Remaining symbols are deliberate boundaries:

| Retained surface | Reason and boundary |
| --- | --- |
| Legacy task-chain fleet HTTP/CLI/MCP fields, `bridge_models`, `restart_live_instances` | Audit/fallback and unconfigured-bridge compatibility. Managed runtime mutations fail with `fleet_runtime_managed`; staffing-only writes preserve prior values |
| `src/ui/components/tasks/fleetSelection.ts` | Catalog normalization/types are imported by Home Fleet; task cards/details use effective placement and Review Roles uses role-name validation. Legacy restart/apply helpers have test-only callers; they do not drive shared Apply |
| `updateTaskChainFleet` mutation's legacy runtime/restart fields | Retains the wire contract for compatibility. Replacement staffing/role dialogs omit these fields; Home calls the bridge Fleet endpoints |
| `homeWidgetFixtures.ts` and `home.ts` fixture imports | Standalone visual/Phase-1 widgets still use fixtures. Production `getHomeFleet` reads `/bridges`; each live editor reads complete bridge settings/catalog/agent IDs. Task chains/Activity/Uptime are separate scopes |

Audit with symbol searches across `src/ui`, `tests`, `src/ctl` and
`src/hub/transport/http`; do not treat the presence of a legacy field or helper
test as a surviving drawer entry point. The shared service's `select_targets`
is used by both preview and Apply; UI membership/`chain_id` approximations do
not decide affected counts.

## Evidence and limits

F3's approved browser gallery is `artifact://art_18eb4afeec4d3a2e`. Its final
frontend build/typecheck and focused nine UI suites passed (165 tests); unchanged
backend evidence at `92f04bac2` was taskv2 308/0 and HTTP 745/0 with 168
warning-bearing tests, plus Nix build. These are baseline results, not execution
of F4's new tests. The earlier F3 frontend failure and tests-pending handoff were
superseded by final evidence comment `cmt_18eb4b137e1eac1f`.

All new/existing automated suites for this chain run through the designated Test
Runner, with exact committed head and nonzero execution count reported durably.
Choose focused app Fleet/taskv2 tests plus affected package checks and relevant
UI suites. No production code or build graph changes are needed by this coverage
and guidance pass; do not rerun unrelated packages merely to inflate evidence.

The app/service fixtures use independent SQLite state and synthetic command
sinks. Hub recovery here means reconstructing the service over durable database
records. Command assertions prove no additional Fleet settings command in that
flow; source inspection establishes local indexed Hub resolution and unchanged
Bridge bootstrap. This is not a physical cross-machine/provider test or a
measurement of production HTTP traffic. Browser fixtures replace API responses,
include a geometry-only sidebar, and perform no live Fleet restart. Full live
Electron/provider E2E and production recovery remain unexecuted in this task.

HTTP package memory warnings remain; a passing suite is not a leak-free claim.
The separately recorded coordinator-send mutex flake `iss_18eb486c5d7117f5` is
user-deferred/nonblocking. Preserve assertions and report it if encountered;
unrelated failures are not automatically waived. No push/deploy/release or live
fleet restart is authorized by this verification task.
