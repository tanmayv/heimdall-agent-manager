# Shared bridge Fleet settings

The Hub owns task-agent runtime policy in SQLite. A bridge has one complete,
owner-scoped, versioned snapshot: a provider/profile/model default and overrides
keyed by durable `agent_id`. It applies across chains on that bridge. Bridge
placement, task pins, task assignees and reviewers, capacity and the per-row pause
switch remain chain or task controls. Updating runtime policy does not change those
controls. (Fleet rows have had no roles since SCHED-0: work goes to a task's
`assignee` agent and reviews to its listed `reviewers`.)

## Persistence and transition (REQ-FLEET-2, 4, 5, 6, 9)

`253_shared_fleet_settings.sql` adds `bridge_fleet_settings`,
`bridge_fleet_agent_overrides` and `instance_fleet_scope`. Migration imports no
legacy chain values and triggers no process operations. A missing settings row
means revision zero and an unconfigured bridge.

The first successful snapshot save establishes shared authority at revision 1.
Every later changed snapshot increments its revision; a semantic no-op retains
the revision. Overrides are a complete replacement, unique per bridge and durable
agent. Removing the last override restores inheritance. Reordering overrides is
a no-op. Provider profile IDs survive every read/write/resolution path. Deleting
an agent with an override advances the containing snapshot revision.

`fleet_settings.save` validates the full default and override draft before calling
the atomic repository save. It validates owner-controlled bridge/agents, active
agents, actual recorded profile enablement/presence, effective models and agent
bridge support. Invalid explicit choices return 422 with details code
`fleet_selection_unavailable`; they never silently select another runtime.
Foreign or absent resources return 404. A stale expected revision returns 409
with `fleet_revision_conflict`. No failed snapshot write partially replaces the
default or overrides.

Legacy chain fleet rows remain intact for audit and for bridges which have never
been configured. On a managed bridge, changing a legacy runtime selection returns
409 with `fleet_runtime_managed`, directing the caller to Home Fleet. Root runtime
changes are refused when they could affect a managed bridge; per-bridge changes
on unconfigured bridges remain valid. Staffing/placement-only updates continue
to work and preserve existing legacy runtime fields. Fresh rows (created for an
assignee or reviewer) need no runtime selection. Capacity, pause and required
review gates retain their existing contracts.

## Local runtime resolution

`src/hub/service/fleet_settings` is the shared policy resolver:

1. Bridge-agent override.
2. Bridge default.
3. Legacy chain fleet bridge selection, then its root selection, only on an
   unconfigured bridge.
4. Validated catalog order when legacy values are missing. Partial explicit
   legacy choices constrain fallback; unavailable explicit values are preserved
   for typed launch validation, never substituted.

The matcher, placement diagnosis/recovery, lease grant, trusted coordinator
creation, subsequent starts/retries and effective placement displays use this
policy. Task bridge pin → fleet bridge → chain directory → coordinator bridge
precedence is unchanged. Review placement keeps its existing pin semantics.
Effective displays report `agent_override`, `bridge_default`, legacy `fleet` or
`bridge_override`, or `catalog_default` as the source.

Placement uses `resolve(..., catalog_fallback=false)` to select authoritative
runtime policy while retaining bridge/directory facts. Bridge ownership,
liveness, agent support and workspace diagnosis precede provider availability
or settings-read errors. Catalog availability is checked at the existing
eligibility/launch stages, so transient availability does not change placement
configuration fingerprints. Existing unconfigured live-child reuse integrations
without a provider repository keep their no-launch behavior; any real new launch
still requires the normal provider/profile/model validation.

An inline claim promotes eligible task scope without replacing its running
process. Its lease, context-pack placement (including `provider_profile`) and
grant history record the actual instance tuple, even when the saved policy
differs. Shared settings take effect at a subsequent real launch. This preserves
the coordinator's pull-only behavior for tasks assigned to it and the required
review gate.

All policy reads are indexed SQLite reads inside existing Hub orchestration.
There are **zero new Fleet-settings HTTP/RPC calls on startup or restart**, no
agent-side settings fetch, no startup-triggered UI refetch and no new cache.
The Hub passes provider/profile/model through existing launch commands; bootstrap
traffic and frozen command redelivery remain unchanged. A committed snapshot is
observed on the next real launch, not by rewriting an already committed launch
command or restarting an instance during migration.

## Task-agent scope

`kind` remains `agent`. The separate `instance_fleet_scope` table records trusted
participation without changing owner/bridge/chain/live-instance enumeration:

| Scope | Meaning |
| --- | --- |
| `chain` | Trusted task coordinator/JIT creation or explicit task responsibility |
| `manual` | Plain conversation; binding a chain alone does not opt it in |
| `excluded` | Bot/action or another explicitly non-task origin; cannot promote |
| no row | Unknown legacy provenance; classified conservatively |

`iface.fleet_scope_get` is the one local classifier for existing starts and F2
Apply target enumeration. Unknown legacy instances require normal agent kind,
same-owner chain membership, and persisted task/workflow/claim
or explicit fleet/directory evidence. An empty private `mixed_work` chain and
coordinator membership alone are insufficient. Known bot/action bindings and
provider-test/non-agent kinds are excluded even if they have chain bindings.

Only trusted server paths write scope. Generic launch JSON cannot select it.
Plain conversation creation records `manual`; explicit task coordinator creation
and JIT workers/reviewers record `chain`. Explicit coordinator assignment or a
successful task claim may promote a manual instance. Failed grants roll back the
promotion with their native unit of work. Instances with the same durable agent
identity retain independent provenance. Unknown/ambiguous targets stay outside
Apply fan-out.

Excluded bot/action origins retain existing orchestration and eligible claim
permissions. Those callers inspect the explicit `Excluded` classifier result and
skip promotion and both shared/legacy chain runtime resolution while retaining
the instance's actual provider/profile/model for inline and wake claims. They
do not swallow arbitrary conflicts or storage errors. The marker setter itself
continues refusing excluded-to-chain promotion.

## Apply, status and retry (REQ-FLEET-3, 4, 6, 7)

Wire shapes live in `src/contracts/fleet_settings.odin` with the TypeScript mirror
in `src/ui/api/fleetSettings.ts`. `Fleet_Settings_Draft` has
`expected_revision`, `default_runtime`, and the complete `overrides` array. Reads
return `Fleet_Settings` with `bridge_id` and `revision`.

`fleet_settings.Service` receives existing bridge, agent and provider repository
interfaces. `validate`, `save`, `resolve`, `legacy_runtime` and
`iface.fleet_scope_get` are available without a new settings RPC or process
control boundary. Bridge repository snapshot reads return owned data; destroy
with `domain.fleet_settings_destroy`. Resolver runtime strings are owned; destroy
with `domain.fleet_runtime_destroy`.

`fleet_application.Service` validates and saves the settings, canonical request
and complete target snapshot in one existing Hub unit of work. Migration
`254_fleet_applications.sql` stores these applications, including their target
outcomes and private public-grant binding. Lifecycle work starts after commit.
The bridge instance query is unpaginated and deduplicated; native active-operation
reconciliation also has no first-page cap.

| Operation | REST | CLI / MCP |
| --- | --- | --- |
| Read complete settings | `GET /api/v1/bridges/{id}/launch-defaults` or `/agent-overrides` | `bridge fleet show` / `defaults` / `overrides`; `fleet.read` |
| Apply | `POST /api/v1/bridges/{id}/fleet/apply` | `bridge fleet apply`; `fleet.apply` |
| Status | `GET /api/v1/bridges/{id}/fleet/applications/{application_id}` | `bridge fleet status`; `fleet.status` |
| Retry | `POST /api/v1/bridges/{id}/fleet/applications/{application_id}/retry` | `bridge fleet retry`; `fleet.retry` |

Both read seams return the same complete revisioned `Fleet_Settings` snapshot,
so a caller cannot combine defaults and overrides from different revisions.
Apply takes the following complete object. Unknown fields, including nested
runtime and override fields, are rejected. Omitted `provider_profile` uses the
provider's normal default profile.

```json
{
  "request_id": "stable-client-request-id",
  "expected_revision": 0,
  "default_runtime": {"provider": "codex", "provider_profile": "codex", "model": "selected-model"},
  "overrides": []
}
```

```bash
ham-ctl bridge fleet show brg_example
ham-ctl bridge fleet apply brg_example --draft-file draft.json
ham-ctl bridge fleet status brg_example fleet_apply_example
ham-ctl bridge fleet retry brg_example fleet_apply_example
```

The response is a `Fleet_Application`, HTTP 202 for Apply/retry: `application_id`,
`request_id`, committed `settings_revision`, application `revision`,
`settings_saved`, `cancelled`, timestamps, `state` and `targets`. Each target
captures instance/agent/project/claim IDs, source configuration revision and
launch epoch, actual `before` and `desired` tuples, stable native `operation_key`,
`state`, `error_code`, `error_message` and `retryable`. Application states are
`pending`, `restarting`, `ready`, `partial_failure`; targets use `pending`,
`restarting`, `ready`, `failed`. Settings can be saved while restarts fail.

Replaying an identical request returns the original application without another
restart, even after the settings revision advances. Canonical comparison
normalizes default profile IDs and override order. Reusing the ID for different
contents returns 409 `fleet_request_conflict`. A new request with a stale expected
revision returns 409 before saving anything. Foreign resources return 404;
unavailable explicit selections return 422 `fleet_selection_unavailable`.

Only changed, currently running chain agents on the selected bridge become
targets. Stopped, failed, unreachable, user-stopped and non-task instances are
excluded. An unchanged actual tuple needs no restart, including a semantic
no-op. Removing an override compares the running process against the inherited
default. Target acceptance rechecks settings revision, scope, ownership,
project, claim identity, configuration revision, launch epoch and stop intent.
Newer settings or a changed target fail closed. Offline bridges, missing native
capabilities, conflicting operations and native recovery failures remain visible
as typed target failures. Retry retains operation keys and skips ready targets;
nonretryable changed targets require a fresh Apply after inspection.

An explicit native launch retry may issue new command/message IDs so an earlier
failed delivery can be retried. It retains the native operation key, launch epoch,
instance/configuration/run generation, runtime destination, claim/worktree and
review gates, and never repeats an acknowledged source stop. Redelivery of one
accepted command instead reuses its persisted frame byte-for-byte. These are
separate guarantees; whole-command equality across two explicit delivery IDs is
not required.

The shared service calls existing durable instance reconfiguration. It sends the
existing stop and launch commands and observes the acknowledged destination epoch
and startup readiness before reporting `ready`. Command acceptance is insufficient.
Hub recovery resumes pending fan-out or observes existing native operations;
read/status requests never start work. A late native readiness acknowledgement
can resolve a previously reported recoverable failure.

Native launch uses the committed instance row, including its incremented run
count. An existing claim keeps its ID, attempt, worktree, permission mode and
review gate. A lifecycle hook rebuilds its normal context pack with the actual
destination tuple; the complete launch frame is frozen durably for byte-identical
redelivery. Claim retention applies only to the matching durable Fleet target,
claim and source/destination generation. Ordinary unrelated failures and user
stops keep their existing cleanup. Home Fleet uses this service; the old drawer
has been retired.

Owner WebSocket `resource_changed` hints use `bridge_fleet_settings` (bridge ID,
summary bridge ID/revision) after a changed settings commit and
`bridge_fleet_application` (application ID and public application summary) after
application progress. Consumers refresh affected Fleet/effective-placement and
instance state; no startup-triggered settings fetch is added.

### MCP amendment, 2026-11-25

F2 requirements revision 2 records user decision `msg_18eb444acf28d7e7`. The
original delegated instance-control idle restriction remains in effect for
unrelated tools. The four Fleet tools use this same service and request/target
deduplication. `fleet.read` and `fleet.status` require `mcp:instances:read`;
`fleet.apply` and `fleet.retry` require the existing `mcp:instances:control`.
Fleet Apply explicitly supports eligible active-task holders, preserving their
claims/context/review gates, without a new capability or consent gate.

Owner, live signed grant, scope, delegation/directory binding and request
cancellation are checked at application acceptance and before each new native
target acceptance, including after remote preflight. Recovery revalidates the
persisted public grant binding before new work; raw OAuth tokens are never
stored. Cancellation after policy commit leaves `settings_saved=true` and marks
the application cancelled, preventing new target work. Already accepted native
operations continue through their existing idempotent lifecycle. Revocation
does not undo a policy commit or duplicate accepted operations.

The existing chain fleet HTTP/CLI/MCP surfaces are compatibility controls during
this transition. They cannot override managed runtime policy. The old
per-chain drawer's separate Apply/restart behavior is retired by F3; it is not
the new shared Apply contract.

## Home Fleet

Home Fleet reads each bridge's complete settings snapshot from
`GET /bridges/{id}/launch-defaults`, the existing provider-status catalog and
durable owner agent identities. Provider profiles and override agents keep their
IDs even when labels are identical. Activity, Uptime and Task chains retain
their separate data sources.

`POST /bridges/{id}/fleet/preview` accepts the complete
`Fleet_Settings_Draft` (`expected_revision`, `default_runtime`, `overrides`).
It returns `{bridge_id, expected_revision, affected_instances}`. Preview and Apply
share the authoritative target classifier, including scope exclusions, actual
runtime comparison and profile normalization. Preview validates owner, revision
and selections inside a rolled-back UOW; it saves nothing, creates no durable
IDs, publishes no events and sends no lifecycle commands. Counts are a
point-in-time observation; Apply takes and validates its own snapshot.

Each bridge has an independent draft, Apply and Reset. Unknown, failed and
loading previews never appear as zero, and only the response for the current
complete draft enables Apply. Conflict responses keep the draft; Reset loads
the latest saved snapshot. Apply directly saves and restarts eligible changed
running chain agents across chains. There is no second restart confirmation.
Saved settings and individual pending/ready/failed results are shown separately.
Failed retryable targets use the original application's retry endpoint.

The browser keeps the pending request and application ID in account-scoped tab
session storage. A lost response replays the identical request, and reloading
resumes the durable application status. Storage is optional; server request keys
remain authoritative. The existing user WebSocket invalidates bridge-specific
settings/application queries. Agent startup and application readiness do not
refetch settings or preview. Counts can be refreshed explicitly; no Home polling
is added.

The per-chain runtime drawer is retired. Chain staffing retains holder capacity,
warm count, idle TTL, pause/resume and bridge placement. Reviewers are named
per task (`brief.reviewers`). Staffing writes omit runtime fields so
managed bridge settings cannot be cleared accidentally. Placement recovery
opens the relevant bridge/agent in Home Fleet for runtime errors and the task's
assignee or reviewer for agent setup.
Recovery links reveal a hidden Fleet widget for that route without rewriting the
saved Home layout. Runtime changes never replace task assignees or reviewers.

## Verification

Focused tests are beside repository, matcher/launch and taskchain code. Coverage
includes owner isolation, atomic revisioned snapshots, no-op/removal, actual
availability validation, multiple chains/bridges, bridge pins, default/override/
legacy/catalog precedence, manual/task promotion and non-task exclusions. Existing
suites run only through the chain's designated Test Runner; task comments and
handoffs record the exact committed SHA, commands and results.

The [integrated verification map](fleet-management-verification.md) ties each
requirement to executable coverage and records the retained compatibility
boundaries, browser evidence and limits. Synthetic transports prove Hub command
ordering and persistence; they do not prove physical provider execution.
