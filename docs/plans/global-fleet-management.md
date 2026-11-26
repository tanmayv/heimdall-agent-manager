# Global Fleet management for chain agents

Replace the per-chain Fleet drawer with the Home Fleet widget as the shared place to configure chain-agent runtimes. Each bridge has a default provider/profile/model and overrides for durable agent identities. Apply saves the bridge's changes and restarts affected running chain agents across chains. This plan follows the approved T6–T8 push to `origin/main` at `b47305d20732bce5f98e534c47764e64fb85345a`.

Status: proposed for approval in `task_18eb3d3e3e58a28b`. Implementation has not started.

## Product requirements

| ID | Required behavior |
| --- | --- |
| REQ-FLEET-1 | Remove the current per-chain Fleet management drawer and its launch-setting editors. Home Fleet becomes the shared runtime-management surface. |
| REQ-FLEET-2 | Store one default per bridge and optional overrides keyed by durable `agent_id` on that bridge. These settings apply across chains owned by the signed-in user. |
| REQ-FLEET-3 | Editing selects changes a draft. Apply saves and immediately requests restarts for affected running chain agents. There is no second restart-confirmation modal or “new instances only” choice. |
| REQ-FLEET-4 | Restart only instances whose effective provider/profile/model changes. Keep instance identity, conversation, chain membership, project/worktree, task responsibility, permission mode and review requirements. Stopped, failed or user-stopped agents remain stopped. |
| REQ-FLEET-5 | Apply settings to future chain-agent launches, resumed work and retry/recovery launches as well as running instances. A later dispatch must not revert to stale per-chain values. |
| REQ-FLEET-6 | Validate ownership, agent identity and the destination bridge's actual provider profiles/models before saving. Invalid selections produce typed errors. Never silently substitute another provider/model. |
| REQ-FLEET-7 | Show draft, applying, restarting, ready and failed results accurately. Preserve saved settings on a partial restart failure; permit retry without restarting successful targets twice. |
| REQ-FLEET-8 | Preserve the approved desktop/mobile design and widget independence. Use real bridge/provider/agent data, stable IDs, existing components, accessible controls and WebSocket updates. |
| REQ-FLEET-9 | Remove obsolete drawer entry points without removing chain staffing, capacity, placement pins or required review gates from the task engine. Keep role recovery functional. |

Interpretations included in this proposal:

- “Global” means shared across chains, with settings stored per bridge. It does not add a separate account-wide provider/model default.
- “Chain agents” includes coordinators, workers and reviewers participating in task execution. Mere presence of a non-empty `chain_id` is insufficient: some other instance kinds also have conversation/chain bindings. Bots, actions, interactive conversation instances, provider tests and shells are excluded from this policy and its restart targets.
- Capacity, warm counts, idle TTL, role assignment, pause state and bridge placement remain chain orchestration concerns. This phase does not make those settings global. The large Fleet drawer is retired; existing Review Roles and placement recovery remain available through their appropriate surfaces.
- Removing a per-agent override restores the bridge default and restarts only affected running instances. Apply is per bridge, so a change on one bridge cannot affect another.

## What the source currently does

Verified against the pushed baseline; no production configuration was changed during investigation.

| Area | Source and current behavior |
| --- | --- |
| New Home widget | `src/ui/components/home/FleetWidget.tsx:1`: local component state, mock providers and labels as override values. Changes are not persisted and no Apply operation exists. |
| Home data seam | `src/ui/api/endpoints/home.ts:34`: `getHomeFleet` returns `fleetFixture()`. Its comment anticipates `/bridges/{id}/launch-defaults` and `/agent-overrides`. Those routes and their tables do not exist in the baseline. |
| View model | `src/ui/components/home/widgetData.ts:53` and `:116`: bridge/override mapping must preserve durable agent IDs, profile IDs and version information instead of using a display name as identity. |
| Per-chain editor | `src/ui/components/tasks/FleetManagementDrawer.tsx:717`: applies individual chain fleet PUTs; `:796` and `:1512` implement the optional restart prompt and new-instances-only choice. |
| Drawer entry points | `src/ui/components/taskchain/TaskChainOverview.tsx:17`, `:265`, `:311`; `src/ui/components/attention/PlacementRecovery.tsx:13`, `:190`; Fleet action props in `TicketBoard.tsx`, `TicketBoardView.tsx`, `WorkflowPipelineView.tsx`. |
| Coupled helper imports | `src/ui/components/chat/ChainOverviewPanel.tsx:37` and `src/ui/components/tasks/CreateTaskModal.tsx:8` import `formatFleetRoleName` from the drawer. Extract that helper before deleting the drawer. |
| Current storage | `src/hub/domain/taskchain.odin:268`: provider/profile/model and `bridge_models_json` live on per-chain fleet rows. Existing migrations include `046_task_chain_fleets.sql` and `076_fleet_bridge_models.sql`. |
| Dispatch resolution | `src/hub/service/taskv2/matcher.odin:164` chooses bridge by task pin → fleet row → chain directory → coordinator. `src/hub/service/taskv2/placement.odin:12` chooses the row's bridge override, then row-wide runtime selection, then available catalog defaults. |
| Effective display | `src/hub/service/taskchain/taskchain_service.odin:2184`, `:2210` mirror runtime resolution for fleet reads. These must agree with actual dispatch. |
| Existing restart code | `src/hub/transport/http/taskchain_handlers.odin:2289`, `:2337`: persists a fleet row, enumerates that chain's matching live members, resolves each bridge and calls `agent_service.relaunch_instance`. It is scoped to a single chain. |
| Runtime boundary | `src/hub/service/agent/agent_service.odin:1081` uses the same-instance start/relaunch boundary. `start_begin.odin:89` checks generation/configuration races. `instance_reconfiguration.odin:82` provides persisted operations, idempotency, stop/launch sequencing and capability validation; `:313` provides autonomous reconciliation. Reuse these boundaries. |
| Real provider catalog | `src/ui/api/endpoints/bridgeSupport.ts:446` exposes enabled, present bridge providers, profiles and active models. Server validation is `validate_provider_model_intersection` in `agent_service.odin:1533`. |
| Task-role UI | `src/ui/components/tasks/ReviewRolesModal.tsx` exists independently of the Fleet drawer. `PlacementRecovery.tsx` distinguishes runtime/bridge problems from missing role holders; do not turn all recovery actions into a provider-settings link. |
| Documentation | `docs/fleet-management.md` currently describes per-chain runtime authority. Update it with this change; do not leave two contradictory precedence contracts. |

The original Fleet section in `artifact://art_18eb37f4cafb0541` already proposes bridge defaults and bridge-agent override tables. Its fallback mentions an agent's own provider/model, but the current durable `Agent` record has no such fields. The implementation must use the verified legacy fleet/catalog fallback below, rather than inventing missing agent fields.

## Settings and compatibility contract

Add owner-scoped repository/service contracts and migrations for bridge defaults and bridge-agent overrides, preserving `provider_profile` as well as provider/model. Maintain one revision for the complete bridge settings snapshot. Agent overrides use durable IDs and are unique per `(bridge_id, agent_id)`.

For task-agent launches on the selected bridge:

1. Bridge-agent override.
2. Bridge default.
3. Existing chain fleet runtime policy, only while that bridge has never been configured through the new surface.
4. Existing validated catalog fallback when no explicit legacy selection exists.

First Apply establishes the bridge default and makes the shared policy authoritative for all chain agents on that bridge. Do not automatically import conflicting settings from multiple chains, and do not restart anything merely because a migration ran. The UI must disclose that Apply affects running chain agents across chains and show an affected count.

Leave legacy data intact for audit/fallback on unconfigured bridges. Once a bridge is managed globally, legacy chain runtime writes must not silently defeat the new policy or report success for an ignored change. Return a typed conflict directing runtime changes to bridge Fleet settings; continue accepting unrelated staffing/placement updates. Update the UI, CLI, MCP contract and shipped guidance consistently where they expose these fields. Fresh fleet rows may still be provisioned for roles/capacity without authoring runtime choices.

Use a shared resolver for matcher selection, coordinator launch/restart integration, recovery and effective-setting displays. Preserve bridge pins and all chain ownership/review semantics. Do not apply this policy to manual conversation, bot or action launches.

## Apply API and restart behavior

Keep the original read seams:

- `GET /api/v1/bridges/{id}/launch-defaults`
- `GET /api/v1/bridges/{id}/agent-overrides`

Add a composite Apply mutation, proposed as `POST /api/v1/bridges/{id}/fleet/apply`, carrying a stable request ID, the expected settings revision, the default selection and the complete override draft. This replaces a series of independent writes from the widget: validate and save one bridge snapshot atomically, then execute runtime side effects after the transaction commits. Define request, response, error and event contracts before implementation in `src/contracts/` and the TypeScript mirror.

Expose owner-scoped application status, proposed as `GET /api/v1/bridges/{id}/fleet/applications/{application_id}`, so a refresh or lost response does not lose restart outcomes. A persisted application record identifies the settings revision and target instance IDs. Repeated identical requests return the same application; reuse with different contents fails. A stale revision returns 409 before saving or restarting anything.

For each application:

- Validate the full snapshot, including referenced owner-controlled agents and available provider profiles/models. Return typed 422 for an invalid selection and 404 for another owner's bridge/agent.
- Persist the settings, application and bounded target snapshot before launching side effects. Enumerate all affected chain members on that bridge without a first-page limit; deduplicate instance IDs and exclude stopped/non-chain instances.
- Request same-bridge restarts through the existing guarded agent lifecycle. Reuse durable instance reconfiguration where supported; do not create a second stop/spawn implementation. An unsupported capability or an operation already in progress is an explicit per-instance failure, never a silent fallback to unsafe process handling.
- Preserve instance/conversation IDs, current task responsibility and working directories. A provider change may start a new native provider session; durable Heimdall conversation and task context must remain available after bootstrap.
- Record each request/operation ID and outcome. Recover unfinished fan-out after Hub restart using durable records and existing reconciliation. A retry resumes pending/failed targets with stable keys; successful targets are not restarted again.
- Do not label an accepted command “ready.” Observe startup readiness/failure through the existing operation/lifecycle events. Show saved settings separately from failed restarts, with a retry action.
- A no-op Apply does not restart anything. Settings for stopped agents take effect at their next valid chain launch. Concurrency/races use existing expected-revision/generation guards and must not overwrite a newer instance configuration.
- Publish settings/application changes on the existing user WebSocket. Invalidate the affected Home Fleet, provider/effective-setting and instance caches without polling the entire Home page.

Every new read endpoint gets `ham-ctl` read parity per the original specification. Mutation parity must use the same Apply service and deduplication rules rather than reimplementing restart fan-out in CLI/MCP clients.

### Approved amendment: MCP active-task Fleet Apply (2026-11-25)

User decision `msg_18eb444acf28d7e7`, recorded as F2 requirements revision 2,
explicitly aligns MCP Fleet Apply with native Apply: restart eligible running
chain agents even while they hold task leases. The earlier delegated native
instance-control idle constraint continues for unrelated tools; Fleet Apply is
the approved exception. `fleet.read`/`fleet.status` use existing
`mcp:instances:read`; `fleet.apply`/`fleet.retry` use existing
`mcp:instances:control`. No new capability or consent gate is required.

All four tools share the native Fleet service and durable request/target keys.
Preserve claims, attempts, context packs, worktrees, permission mode and required
reviews. Recheck owner/live grant/scope/cancellation at application and native
per-target acceptance, including after preflight. Recovery must honor grant
revocation before accepting new work without persisting raw OAuth tokens;
already accepted native operations remain idempotent. This amendment records
the scope decision explicitly rather than treating it as implicit in the
original approved plan.

## User interface

Retain Home Fleet's approved bridge cards, expandable agent overrides, typography, colors and responsive behavior. Replace mocks only for Fleet; Activity/Uptime and unrelated widgets remain in their current phase.

Each bridge has a versioned draft and Apply/Reset controls. Provider changes select that provider/profile's first valid model. Agent pickers use durable IDs, show readable names and omit identities with another override on that bridge. New overrides copy the bridge's current draft default. Removing the last override and applying restores inheritance.

Show a short scope statement, such as “Applies to chain agents on this bridge across all chains,” and an affected-running-agent count beside Apply. Apply directly saves and restarts; remove the old two-step restart choices. Disable duplicate submissions while applying. Report pending/ready/failure counts and actionable typed failures, including offline/unsupported bridges, without discarding the user's draft on a pre-save error.

Remove `FleetManagementDrawer.tsx` and its chain-local entry points after extracting shared helpers. Runtime recovery links open/focus the relevant bridge/agent in Home Fleet. Role-holder recovery continues through existing Review Roles/placement controls; if an existing worker staffing action has no replacement, resolve that gap explicitly before deleting its only entry point. Do not weaken ticket review requirements or silently replace a failed named reviewer as part of a runtime change.

## Delegated implementation tickets

Create these only after this planning task is approved. Assign all implementation work to existing durable worker `agt_18dbb3d25b612dcd` and independent review to `agt_18e5281575868be4`. Existing Test Runner `inst_18eb3898cd87d012` runs existing suites. Workers choose checks, report exact-commit results and submit early for code review in parallel with runner work.

### F1 — Durable bridge settings and authoritative chain runtime resolution

**Goal:** persist shared bridge defaults/agent overrides and make current/future chain runtime resolution consistent, with an explicit transition from legacy settings.

**Files/context:** new contracts under `src/contracts/`; `src/hub/domain/`; `src/hub/repository/iface/`; `src/hub/repository/sqlite/` and its migrations; new `src/hub/service/fleet_settings/`; `src/hub/service/taskv2/{placement.odin,matcher.odin,placement_recovery.odin}`; `src/hub/service/taskchain/{taskchain_service.odin,placement_recovery.odin}`; relevant coordinator creation/launch seams in `src/hub/service/agent/agent_service.odin` and `src/hub/service/taskchain/`; `docs/fleet-management.md`. Baseline and precedence are defined above.

**Acceptance:** owner isolation and storage round trips; profile-aware validation; override/default/legacy/catalog resolution; first Apply transition does not import conflicting legacy choices; globally managed runtime writes fail explicitly; future dispatch and displayed effective selection agree; staffing, placement, review gates and non-chain launches retain their contracts. Repository/service/placement tests cover multiple chains and bridges.

### F2 — Apply service, durable restart results, HTTP and command parity

**Depends on:** F1.

**Goal:** atomically save a bridge draft and restart affected running chain agents with recoverable, deduplicated results.

**Files/context:** F1 contracts/service/repository; `src/hub/service/agent/{agent_service.odin,start_begin.odin,start_command.odin,instance_reconfiguration.odin}`; `src/hub/transport/http/` new Fleet handlers and existing `taskchain_handlers.odin:2289`; `src/hub/app/wiring.odin` and reaper wiring; `src/hub/repository/iface/{agent_repo.odin,taskchain_repo.odin}`; `src/ctl/`; affected MCP adapters and `src/prompts/` guidance. Reuse lifecycle primitives and owner checks identified above.

**Acceptance:** complete-snapshot validation and revision checks precede side effects; no-op Apply; all-page target enumeration and deduplication; changed/default/removed override scenarios across multiple chains; stopped/non-chain/other-owner exclusions; same instance/conversation/claim/workdir retained; duplicate request, race, offline/unsupported bridge, partial failure, retry and Hub restart recovery; result distinguishes requested from ready. HTTP/CLI/MCP parity and read commands are documented. No new process-control boundary.

### F3 — Live Home Fleet UI and retirement of the per-chain drawer

**Depends on:** F2.

**Goal:** make the approved Home widget the working shared settings UI and remove the old per-chain editor.

**Files/context:** `src/ui/components/home/{FleetWidget.tsx,widgetData.ts,HomePage.css,homeWidgetFixtures.ts}`; `src/ui/api/endpoints/{home.ts,bridgeSupport.ts,taskChains.ts,agents.ts}` and `src/ui/api/{heimdallApi.ts,useUserWebSocket.ts}`; `src/ui/components/tasks/{FleetManagementDrawer.tsx,fleetSelection.ts,TicketBoard.tsx,TicketBoardView.tsx,WorkflowPipelineView.tsx,CreateTaskModal.tsx,ReviewRolesModal.tsx}`; `src/ui/components/taskchain/TaskChainOverview.tsx`; `src/ui/components/attention/PlacementRecovery.tsx`; `src/ui/components/chat/ChainOverviewPanel.tsx`; `tests/{ui_home_widgets_test.ts,ui_fleet_actions_test.ts,fleetSelection.test.ts}`; `docs/ui-debug-ids.md`. Add focused tests for the new API/draft/application behavior.

**Acceptance:** live bridge/profile/model/agent data, stable IDs and independent loading/errors; per-bridge Apply/Reset and precise restart results; direct Apply without the old modal; draft preservation and conflict/error recovery; duplicate submit prevention; override add/remove/provider-change behavior; WebSocket refresh with no Home-wide polling; old drawer/imports/entry points removed; runtime links focus Home Fleet and role recovery remains functional. Reviewed 1440px/390px screenshots cover normal, expanded, draft, applying, partial failure and empty states; keyboard/touch behavior meets the approved design.

### F4 — Integrated verification and documentation

**Depends on:** F3.

**Goal:** demonstrate the complete behavior on an isolated fixture/test environment and reconcile all public contracts.

**Files/context:** changed F1–F3 code; tests beside affected Hub packages; `tests/` UI/integration scenarios; `docs/fleet-management.md`; API/CLI/MCP guidance and `docs/ui-debug-ids.md`. Use controlled test instances, not the currently executing production agent fleet.

**Acceptance:** two chains sharing a bridge use the same settings; another bridge is unaffected; override/default/remove/no-op cases work; Apply restarts changed running coordinator/worker/reviewer fixtures while preserving responsibility/context; stopped instances stay stopped; new dispatch uses the saved values; partial failure and retry are visible and recoverable; obsolete per-chain UI/contract references are accounted for. Final commit has appropriate runner evidence and independent review, with visual artifacts and known limits recorded.

## Verification and approval

This investigation used source inspection and read-only repository searches. No test suite was run for a planning-only deliverable, and no live agent was restarted. Implementation verification will use the designated Test Runner plus worker browser checks and independent review; workers choose exact commands appropriate to their diffs.

Confidence is high for the baseline findings because the source was inspected directly. Runtime preservation, capability support and failure recovery remain implementation acceptance items until exercised in controlled integration tests.

Approval of this planning task accepts the proposed global scope, inclusion of chain coordinators, per-bridge Apply, legacy transition and four-ticket sequence. Any requested changes should be recorded on this task before implementation tasks are published. The original T8 push authorization has been fulfilled; a later Fleet push/release is a separate shipping decision.
