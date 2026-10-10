# Agent instance reconfiguration plan

Status: ready for manual testing; implementation is in the working tree. Manual
validation is next, using a local Hub and two Bridges. No production deployment.

Scope update: the user explicitly deferred context handoff. No continuation brief,
synthetic user message, or startup transcript injection is included. The durable
conversation transcript and configuration-change system events remain available.

Reviewed against the current working tree on 2026-10-10. This review is static
source inspection, not a runtime migration test.

## Goal

Allow bridge, project, provider, and model changes from the conversation composer.
Apply relaunches the same agent instance in the selected location. Preserve agent identity, instance identity, conversation identity, and
conversation history. Record configuration transitions as durable system messages
and display them subtly in the conversation.

## Original behavior found during review

- `src/hub/service/agent/agent_service.odin` rejects bridge and project changes in
  `reconfigure_instance`, along with agent, chain, and conversation identity changes.
- Provider/model reconfiguration already has a relaunch path. Inactive instances
  currently only save the new configuration.
- `src/ui/components/chat/ConversationThreadPage.tsx` shows fixed bridge/project
  context and automatically applies staged provider/model changes on message send.
- The Hub resolves project paths per bridge and generates launch/bootstrap context.
- Durable system messages exist, but configuration changes need structured metadata
  and a dedicated rendering rule rather than body-text matching.

## Implementation review and corrections

| Current implementation | Consequence for this plan |
| --- | --- |
| `agent_service.odin::reconfigure_instance` rejects bridge/project presence and relaunches active provider/model changes; inactive changes only persist. | Extend destination validation and make explicit Apply launch stopped instances too. Preserve existing PATCH callers through an explicit operation contract or versioned semantics. |
| `ConversationThreadPage.tsx::applyReconfigure` calls PATCH and then restart; PATCH already relaunches active instances. Its catch consumes errors, and submit continues after attempted reconfiguration. | Remove the second restart and implicit apply-on-send. One Apply must produce one operation and one launch; failed Apply must never send the draft. |
| `src/ui/api/endpoints/agents.ts::reconfigureAgentInstance` accepts `bridgeId` and claims the Hub supports moves, but the service rejects them. It has no project field and uses an `any` result. | Correct this existing contract mismatch; introduce typed destination and operation responses, including explicit project clearing. |
| Bridge launch closes a registered PTY instance and spawns fresh argv/env (`hub_runtime_client.odin::bridge_runtime_launch_agent_pty_host`). | Reuse fresh-spec spawning. Close failure currently only logs and spawn continues: fail closed before launching a replacement. Bootstrap materialization occurs before this close, so preflight must not rewrite a running source's managed files. |
| Bridge emits accepted and terminal command results for launch/stop; Hub caches terminal results in `service/bridge_runtime/runtime_protocol.odin`. | Reuse transport correlation and result retrieval. These are runtime projections, not a persisted reconfiguration workflow. Launch `succeeded` means starting, not startup ready. |
| `bridge_runtime_stop_agent` returns true and marks stopped even when daemon availability or PTY close fails. `bridge_pty_host_close` returns whether the reply is `.Closed`. | Bridge support needs changes, rather than being merely optional: propagate close failure and establish the PTY close reply's process-exit guarantee before treating a stop acknowledgement as termination proof. Handle absent/already-stopped instances explicitly. |
| Runtime connection/reservation generations already exist; `apply_bridge_status_report` uses bridge identity and a bridge-local sequence with reset recovery. | Connection generation is not per-launch fencing. Add a durable launch epoch and carry it through status, startup success, message delivery and token authorization. Also audit `verify_instance_token` / `mark_instance_start_success`: instance-only identity does not distinguish superseded runs. |
| Hub has task-context/bootstrap builders and an unused `write_bootstrap_messages` helper listing 20 messages; launch payload carries bootstrap URL and identity/location fields. | Reuse task/bootstrap assembly, but do not count conversation handoff as implemented. Wire bounded, ordered history with a captured boundary into actual Bridge materialization/prompt delivery and verify encrypted conversations separately. |
| `domain/content.odin::Chat_Message` has `message_type` and `metadata_json`; UI chat mapping already parses metadata. | Reuse durable message metadata. Add a typed configuration subtype and idempotent event writes/rendering; a new generic metadata column is unnecessary. |

The largest missing piece is the Hub-owned durable transition, not the selectors.
Do not equate transport acknowledgement, instance status, process termination, and
agent readiness. Each is a separate milestone with its own failure behavior.

## Implementation sequence

### REQ-CONFIG-1: Define the durable operation and API contract

Extend reconfiguration to accept bridge, project (including clearing the project),
provider, and model. Keep agent, instance, chain, and conversation IDs immutable.
Distinguish omitted fields from explicit empty values. Apply must launch the agent
even when the previous runtime is stopped.

Define an operation ID, idempotency key, expected configuration revision, old and
requested configurations, actor, timestamps, progress, and sanitized failure details.
Return accepted-operation state separately from launch success. Reject stale edits
and serialize concurrent changes to one instance. Update HTTP handlers, service
inputs, persistence, UI types, readers, and notifications together.

Persist operation progress so a Hub restart can reconcile an interrupted move.
Define launch-generation correlation for commands and runtime reports; ignore
reports from superseded launches, including changes on the same bridge.

### REQ-CONFIG-2: Validate the destination before stopping

Validate ownership and access, live bridge availability, launch capacity, provider
capabilities, model availability, and project path on the selected bridge. Derive
provider/model options from the staged bridge selection. Do not silently substitute
an unsupported selection.

Resolve the target working directory and bootstrap context before disrupting the
current runtime. Preparation must be read-only or use an operation-specific staging
directory; materialize managed files in the actual working directory only after
source termination is confirmed. Fail clearly when the project is unavailable on the destination.
Changing bridges does not copy files, repositories, or uncommitted work.

Preserve chain membership and directory references when moving an instance. The
current Hub does not model an owned VCS workspace binding; chain kind and directory
metadata must not impose bridge/project immutability. Validate chain ownership and
the destination project/path. Do not copy or implicitly migrate chain directories.

### REQ-CONFIG-3: Coordinate stop, commit, and launch

Implement a Hub-owned operation with explicit phases: prepared, stopping, source_stopped, launching, ready, failed, and recovery_required. Keep current and pending configurations
distinct while the operation runs.

Stop the source runtime and confirm termination before launching the destination.
An offline source cannot provide termination confirmation: leave the operation
blocked/failed rather than permit two live runtimes. Reconcile stopped instances
without requiring a redundant stop. Scope cleanup to this instance; other agents
and bridges must remain unaffected.

After confirmed stop, commit the new instance configuration and update the
conversation's project association consistently. Reserve destination capacity,
launch with a new generation, and wait for startup readiness before marking success.
Reset or epoch-scope runtime sequence state when changing bridges so a new
bridge's sequence does not lose to the old bridge's counter. Refresh runtime routing,
credentials, terminal subscriptions, files panels, sidebar
grouping, and relevant caches. Ensure old runtime credentials cannot continue
acting as the moved instance.

On failure before stop, retain the original running configuration. On failure after
stop, retain the truthful stopped/failed state and operation phase; never imply the
old runtime is still running. Support idempotent retry without duplicate launches
or messages. Do not automatically restart the old runtime when destination startup
is uncertain. Reconcile uncertain command delivery before retrying.

### REQ-CONFIG-4: Preserve transcript; defer context handoff

The user chose to skip startup context handoff for this implementation. Preserve
the instance/conversation identity and full durable history. Agents can fetch the
transcript, including configuration-change system events, through existing tools.
Do not inject a new user message or continuation brief. Rebuild the normal project-
specific bootstrap at the destination. Provider-native session portability and
file/repository copying remain outside this change.

Hold incoming user/agent message delivery while the operation is active or needs
recovery. This guard belongs in the Hub service and persistence boundary, not only
in the current UI. Let the transcript retain incoming agent output during teardown.

### REQ-CONFIG-5: Implement staged composer settings

Make all four settings editable. Keep staged configuration separate from confirmed
configuration; background polling must not overwrite pending edits.

Whenever any setting differs, disable message input and replace composer action
buttons with exactly **Reset** and **Apply**. Keep selectors available to refine
the pending configuration. Preserve draft text and attachments. Returning all
settings to their original values restores the normal composer automatically.

- Reset restores confirmed values without changing the runtime.
- Apply submits one explicit operation; remove implicit apply-on-send behavior.
- During Apply, disable selectors and both buttons, and show progress as status text.
- On readiness, adopt confirmed values and restore message input and normal actions.
- On failure, preserve edits and draft content and show actionable failure details.
  Reset clears the local edits; it does not undo a partially completed operation.
  A pending recovery requirement must continue to prevent message delivery.

Guard keyboard send, paste/upload actions, and alternate send paths while pending.
Use accessible labels, status announcements, and `data-debug-id` attributes for
every interactive element. Refresh destination-dependent files and capabilities.

### REQ-CONFIG-5A: Show source and destination progress clearly

Use one compact, persistent progress panel directly above the composer. It must
remain visible when menus close and fit narrow screens without horizontal scroll.
Show two clearly labeled rows: **Stopping on** the source bridge/project and
**Starting on** the destination bridge/project, with provider/model secondary text.
For moves within one bridge, still show both steps so location changes are clear.

Drive each row from authoritative operation phases: waiting, in progress, complete,
or failed. Use restrained icons and neutral styling, one accent for the active step,
and success/error accents only for confirmed outcomes. Never animate destination
startup before source termination is confirmed. Include readable phase text rather
than relying on color, and announce phase changes through an accessible live region.
Show preparation before the stop row and “Ready on [destination]” only after ready
confirmation. If stop fails, keep the source row failed and destination “Not started”.
If startup fails, show source stopped and destination failed with a concise reason.

Keep old/new labels captured by the operation so background instance polling cannot
change “Stopping on” to the destination. Show precise bridge labels, project names,
and an expandable path detail; preserve encrypted project label rendering. Keep
failure details and retry/recovery state visible across reload. Progress is status
text while running; staged composer actions remain exactly Reset and Apply.

Add interaction coverage for two distinct locations, same-location relaunch, source
stop failure, destination startup failure, slow readiness, mobile layout and reload.
The initial current-location banner is a first step; it cannot represent a move until
Hub operation phases and captured source/destination fields are implemented.

### REQ-CONFIG-5B: Invalid configurations make the conversation read-only

Validate the confirmed bridge, optional project, provider and model/tier against
current authoritative records and active capabilities. Missing, inaccessible,
archived/revoked, offline or disabled selections must not accept messages. Do not
use picker fallback values as proof of validity. Distinguish loading and failed
availability checks from confirmed invalid configuration; fail closed while unknown.
An intentionally empty project is valid and must not fall back to an old conversation
project association after the instance explicitly clears it.

Replace the input with a restrained “This conversation is read-only” panel listing
each invalid binding and the exact repair action. Keep transcript/history and repair
selectors accessible; preserve drafts and attachments. Block composer send, keyboard
send, reply sends, file-comment publication and uploads while invalid. Allow Apply
only when the staged destination is valid; current invalid provider/model must not
prevent repair to an active selection. Restore normal input after confirmed validity.

Initial implementation covers this UI guard and read-only panel. Hub rejection of
all alternate message entry points and bridge/project repair remain part of the
operation implementation. Cover archived/missing bindings, offline bridge, stale
picker options, failed discovery, loading, multiple invalid fields and recovery.

### REQ-CONFIG-6: Record and render conversation system messages

Write Hub-authored durable system messages with a configuration-change subtype and
structured metadata: operation ID, actor, timestamp, changed fields with old/new
IDs and display labels, and outcome. Capture request and terminal outcome separately
so interrupted or failed operations remain understandable. Deduplicate by operation
and event phase; persist and publish messages consistently with operation progress.

Render a muted inline event, for example:

> Configuration changed · Bridge A → Bridge B · Project X → Project Y · Claude → Codex

Show only changed fields. Offer expandable details for model, actor, timestamp,
progress, and failure information. Avoid normal chat-card chrome, reply actions,
and misleading success wording for pending or failed transitions. Keep history
readable even if referenced projects or bridges are later deleted. Use structured
message metadata rather than inspecting text for words such as “restart”.

### REQ-CONFIG-7: Validate failures, recovery, and compatibility

Add meaningful coverage for:

- Each setting independently and all four together; no-op and Reset behavior.
- Running and stopped instances; unchanged identity and conversation history.
- Destination ownership, offline bridges, unsupported models, missing paths,
  capacity failures, and incompatible chain/workspace bindings.
- Confirmed source termination before destination launch; unrelated runtimes remain live.
- Duplicate Apply, concurrent editors, stale revisions, lost acknowledgements,
  delayed old-generation reports, and Hub/Bridge restarts during each phase.
- Preserved transcript and configuration events across provider/bridge changes, without injecting context or copying local files.
- Draft/attachment preservation, disabled keyboard send, progress and failure UI,
  and durable subtle messages across reload and conversation pagination.
- Mixed versions: unsupported Bridge capabilities fail before source shutdown.

Run focused Hub/service tests, UI interaction tests, and an end-to-end scenario
with two bridges and at least two provider configurations. Map evidence to these
REQ IDs. Confirm whether existing Bridge builds suffice before defining release order.

## Impact and rollout

Hub changes cover API contracts, operation persistence, instance/conversation
metadata, launch coordination, authorization, runtime routing, and system messages.
UI changes cover selectors, composer state, operation status, transcript rendering,
and caches/panels that depend on location. Bridge changes are required for trustworthy stop failure reporting and launch-epoch
fencing through the current wrapper-free PTY path. Context handoff is deferred. Audit
legacy wrapper compatibility separately rather than making wrapper changes a
prerequisite for the current runtime.

Deploy compatible Hub support before enabling the UI feature. Capability-check
Bridge requirements before any destructive runtime transition. Audit callers of
`reconfigure_instance` and `relaunch_instance`, including fleet/task-chain flows,
so their existing semantics remain explicit and compatible.

## Acceptance criteria

Users can stage all four settings, Reset without side effects, and Apply explicitly.
Input is disabled whenever a configuration change or its recovery is pending. A
successful Apply leaves exactly one ready runtime at the selected destination with
stable instance/conversation IDs and preserved history. Every
transition has an accurate durable system record and a subtle conversation entry.
Failures and restarts preserve history and never permit an unconfirmed source stop to start a destination runtime.

## Estimate and implementation order after review

Revised estimate: **8–12 engineering days** for the complete behavior and recovery
requirements. The previous 6–9 day estimate understated Bridge changes and durable
recovery. This is an estimate from source inspection, with overlap between areas:

- Hub contract, durable operation/reconciliation, destination validation: 3–4 days.
- Bridge termination proof, launch epochs and correlated readiness: 1–2 days.
- Composer staging and dependent surface refresh: 1–2 days.
- Structured system events: 1 day; context handoff is excluded by user request.
- Focused regression and two-bridge/provider integration validation: 2–3 days.

Implement in this order:

1. Specify operation persistence, revision/epoch semantics, typed request/results,
   and authoritative termination/readiness signals. Verify PTY close semantics and
   the provider/model intersection before source shutdown.
2. Fix Bridge stop/close failure propagation and epoch reporting/authorization.
   Add capability advertisement so older bridges reject moves before source stop.
3. Implement Hub operation coordination and restart reconciliation, reusing existing
   command-result plumbing, capacity reservations, project resolution and bootstrap.
4. Write idempotent system events through existing metadata; no context handoff.
5. Replace UI PATCH-plus-restart with one Apply operation and staged Reset/Apply;
   verify failed Apply cannot fall through to send and polling preserves edits.
6. Validate transitions and failures with two bridges, including unrelated agents
   on the same machine, and publish compatibility requirements before UI rollout.

Initial implementation now removes UI duplicate restart and implicit apply-on-send,
blocks input/uploads during staged changes and runtime transitions, adds explicit
provider/model Reset/Apply and a visible location/status banner, and propagates
Bridge stop/respawn close failures. This is not yet the durable move operation. Remaining investigation
is now manual validation of the completed flow and its recovery behavior.

## Initial implementation validation

- Full UI production/Electron build and typecheck passed; 11 focused UI tests passed, including executable sequencing
  tests for active/stopped Apply and both configuration/start failure propagation.
- Bridge Odin check and native build passed. Two static guard-order regression tests
  passed; these do not replace a live PTY termination/failure integration test.
- Legacy static tests are stale: real-launch test references deleted
  `src/bridge/provider_seeds.odin`; restartable test expects removed tier-era symbols.
- Nix is unavailable in this environment; the native Odin build is the current build
  evidence. No deployment or running-service replacement has been performed.

Read-only validation: seven executable validity tests cover active/projectless
configuration, missing/revoked/archived/offline bridges, archived/missing projects,
unsupported provider/tier, multiple issues, failed verification, and repair. All
18 focused UI tests passed; UI typecheck and whitespace checks passed.

## Current implementation and manual validation gate

- Migration 072 persists operations, exclusive per-instance transitions and immutable
  source/destination snapshots. An atomic trigger commits instance routing and
  conversation project association only after source termination is acknowledged.
  Configuration revisions and launch epochs prevent stale instance saves/reports.
- POST `/api/v1/agent-instances/{id}/reconfigurations` accepts a full destination,
  idempotency key and expected configuration revision. GET on the same path returns
  durable progress. POST `/reconfigurations/retry` retries a recovery operation with
  its key and expected operation revision.
- Source and destination must advertise `instance_reconfiguration_v1`. The Hub
  validates provider/model against active catalog, enabled/present destination
  providers, ownership, online state, capacity and destination project path before
  stop. Older Bridges reject the move before source disruption.
- New Bridge code propagates close failures, reports epoch-correlated status,
  persists epoch assertions in its local token store and reuses a matching live
  destination on duplicate launch rather than spawning it twice.
- UI stages all four fields without substituting provider/model when Bridge changes.
  Invalid destination blocks Apply with specific reasons. Source/destination labels
  remain captured through progress; recovery is read-only and Apply retries the
  existing operation. Reset changes local selection only.
- Request, success and recovery events are durable `configuration_change` messages
  with structured metadata, rendered as subtle inline transcript entries.
- Hub input guards and a database trigger hold incoming messages during operations.
  Task-chain runtime fanout avoids instances undergoing reconfiguration. Chain membership and directory references are preserved; chain kind does not
  block Bridge/project moves.
- Context handoff is intentionally excluded.

Manual setup requires the newly built Hub, both newly built Bridges, and current UI.
Do not use an existing production Hub for the first validation. Native binaries are
`/tmp/heimdall-reconfiguration-hub` and `/tmp/heimdall-reconfiguration-bridge`; the UI
production build is in `dist/`. Use existing local enrollment/config tooling to give
both Bridges different IDs, config/data roots, local endpoints and sockets.

First manual scenarios:

1. Start a private conversation on Bridge A. Choose Bridge B with a provider/model
   unavailable there: Apply must be disabled and Bridge A must continue running.
2. Choose a supported combination and active project on B. Confirm source A/project
   and destination B/project in progress, one stopped source and one ready destination,
   preserved IDs/history, system events and restored input.
3. Reset staged changes and confirm draft/attachments/runtime are unaffected.
4. Change provider/model on one Bridge and verify one replacement with the new argv.
5. Archive/disable a selected project/provider/model or disconnect the Bridge; confirm
   read-only reasons. Repair the configuration and verify input returns only when valid.
6. Exercise source-stop failure, destination startup failure, repeated Apply and Hub
   restart. Verify truthful phase/recovery, no simultaneous runtimes and safe retry.
7. Leave an unrelated agent on each Bridge running and verify it stays untouched.

The user requested manual validation before additional test writing. Existing tests
written before that instruction are retained; no further tests were added afterward.
After manual findings, add focused regression coverage for observed failure paths.
Nix is unavailable; native Odin Hub/Bridge builds and UI production/Electron build are
available as compile/build evidence. Build verification is not a live move test.

Final handoff: native Hub and Bridge builds, UI production/Electron build, and diff
whitespace checks passed. Project preflight does not hold the reconfiguration lock
while waiting for a Bridge response. Destination catalog/availability/project state
is revalidated before launch and recovery retries. No local or production services
were replaced; the first live move remains the user's local two-Bridge manual test.

Local manual environment is now running at http://127.0.0.1:5193 with the updated
Hub at 127.0.0.1:8191 and two enrolled Bridges, labeled Local Bridge A and Local
Bridge B. Both advertise reconfiguration support and have Claude/Codex enabled.
Manual preflight exposed a legacy validation endpoint dependency; path validation
now uses the live Hub-to-Bridge command channel with a queued Bridge handler.
Destination project validation succeeded after that fix. The composer agent
switcher was removed at the user's request. No additional test code was written.

Manual finding: ordinary UI conversations use `team_work` chains, so the initial
private-conversation-only exception wrongly blocked their location changes. Removed
the chain-kind guard. Chain directories are context references; the current Hub has
no owned workspace binding to migrate. Chain ownership and destination project/path
validation remain required, while identity, membership and history are preserved.

Manual UI follow-up: the successful runtime progress panel now disappears roughly
five seconds after confirmed readiness and stays hidden on later reloads. Pending
and failed/recovery phases remain visible. The durable configuration-change entries
remain in the transcript. The composer agent switcher is removed.

UI follow-up: project selection is read-only. Bridge/provider/model selection opens
a touch-friendly settings modal with Start/Stop and Force stop (disabled when
stopped). Pending settings remain right-aligned. Mobile uses one input/send/more
row; input grows to three lines, and More contains current model/tier, settings,
terminal pane toggle and upload. The header now shows project / chain / agent with
a runtime status dot. Its agent name opens a chain-scoped switcher with coordinator
labels, refreshed when opened. No context handoff or additional test code was added.

Apply connectivity guard: bridge responses expose `runtime_connected` from the Hub's
live command registry. Destination selection and both Apply buttons fail closed
without a connected destination. Availability refreshes every five seconds while
editing and when settings open. Hub rechecks connection after preflight, before
stopping the source, and before destination launch/retry.

Recovery follow-up: Force stop is allowed during active reconfiguration/startup,
including when the status projection says stopped but termination is unconfirmed.
It targets only the instance's current owning bridge and persists a correlated
stop command. No new launch or settings edit occurs until successful termination
is acknowledged. That acknowledgement ends the old operation, releases its lock,
marks the instance stopped and changes its launch epoch/revision to reject late
reports. The user can then select another model/bridge and Apply a new operation.
Unconfirmed stops remain read-only and can be retried after reconnection.

Project paths are optional launch context. A destination with no resolved project
path may launch in its managed instance directory and receives an empty project
path in bootstrap variables. A configured nonempty path still passes destination
preflight validation. Bootstrap must preserve an empty resolved instance path
instead of substituting a global default path. Project ownership/state checks
and source-stop/destination-connectivity guards remain in place.
