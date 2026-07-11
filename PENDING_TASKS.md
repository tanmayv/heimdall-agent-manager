# Pending Task Context

Generated for handoff: statuses `planning`, `ready`, `working`, `blocked`, `review`.
Agents in scope: **odin-lead**, **odin-reviewer**, **odin-coder**, **odin-ui**.

This file includes only non-terminal tasks where one of these four agents is an assignee or participant.

## task_chain_id: `task-3706206b0c04`

### `task-3706206b0c04`
- status: **ready**
- relevance: odin-ui (assigned_agent), odin-ui (assignee), odin-lead (coordinator), odin-reviewer (reviewer)
- priority: normal
- title: Implement agent template and persisted agent UI support
- depends_on: task-522e1cb06472
- next_step: Dependency task-522e1cb06472 is now validated; resume review+final validation on persisted-agent UI behavior, especially daemon-generated IDs and display_name semantics in project/agent lists.
- description:
  Update Heimdall Electron UI for persisted agents and templates. Start Agent page should select Project, AgentTemplate/persona, Provider profile, and optional alias/name. Show role_hint as informational metadata, not a required choice. Agent list should distinguish known/persisted agents from currently connected agents and show project/template/provider/role_hint. Include simple create/copy-template override flow if feasible, or document as follow-up.
- acceptance_criteria:
  - Start Agent UI selects template, project, provider, and optional alias
  - role_hint is displayed but not required as a separate picker
  - Agent List shows persisted known agents and live connection state
  - known agents survive daemon restart in UI
  - existing start-agent flow remains usable
- participants:
  - odin-ui (assignee) — active
  - odin-lead (coordinator) — active
  - odin-reviewer (reviewer) — active


## task_chain_id: `task-611d9b66c9bf`

### `task-611d9b66c9bf`
- status: **ready**
- relevance: odin-ui (assigned_agent), odin-ui (assignee), odin-lead (coordinator), odin-reviewer (reviewer)
- priority: P1
- title: Implement Electron UI automation bridge
- depends_on: task-d1bd525486a4
- next_step: User requested odin-ui start now. Begin Electron-side UI automation bridge scaffolding in parallel with backend: define request handler/types for dom.query, redux.query, input.click, input.type, input.scroll; add stable data-testid selectors; implement bounded safe DOM/Redux query helpers; gate input actions behind a local permission flag/mock until daemon routing task lands; no arbitrary JS/eval.
- description:
  Implement Electron renderer/preload automation bridge for daemon-routed ui_control_request events. Support declarative actions: dom.query by selector with bounded text/attrs/rect/visible fields, redux.query by safe path subset, input.click, input.type with clear_first, and input.scroll. No arbitrary JS/eval. Add stable data-testid selectors for key UI surfaces and visible audit/diagnostic handling where appropriate.
- acceptance_criteria:
  - Electron advertises ui-control capabilities during client registration/heartbeat
  - dom.query and redux.query return bounded safe results
  - click/type/scroll execute only when permission allows and element is visible/enabled as appropriate
  - No arbitrary JS execution is exposed
- participants:
  - odin-ui (assignee) — active
  - odin-lead (coordinator) — active
  - odin-reviewer (reviewer) — active


## task_chain_id: `task-a34078da66ac`

### `task-a34078da66ac`
- status: **ready**
- relevance: odin-coder (assigned_agent), odin-coder (assignee), odin-lead (coordinator), odin-reviewer (reviewer)
- priority: normal
- title: Integrate role_hint with task assignment and attention routing
- depends_on: task-0f83318ed446
- next_step: Resume role_hint task assignment/attention routing now that durable AgentTemplate/AgentInstance task-0f83318ed446 is validated. Use role_hint as optional metadata for routing/filter helpers, not a required user-facing decision.
- description:
  Use AgentTemplate role_hint as internal metadata for task routing defaults and attention/nudge behavior without requiring users to choose a separate role. Add helper/query support to find known agents by role_hint and project. Ensure role_hint can support task system concepts like coder/reviewer/verifier/coordinator/lead/planner while remaining optional. Do not require role_hint for starting agents.
- acceptance_criteria:
  - role_hint is available in task assignment/routing helpers
  - UI/API can list/filter agents by role_hint and project
  - role_hint is optional and not a separate required user decision
  - existing explicit task participants still override/inform routing
- participants:
  - odin-coder (assignee) — active
  - odin-lead (coordinator) — active
  - odin-reviewer (reviewer) — active


## task_chain_id: `task-efb67e954998`

### `task-efb67e954998`
- status: **ready**
- relevance: odin-ui (assigned_agent), odin-ui (assignee), odin-lead (coordinator), odin-reviewer (reviewer)
- priority: P1
- title: Implement Electron Agents tab UI
- depends_on: task-4bda5e20655e
- next_step: Start Electron Agents tab UI now that backend/API support task-4bda5e20655e is validated. Implement Agents tab to list existing/persisted agents with display_name labels, add/start agents, delete/archive/remove agents where supported, create/view/update Agent Templates, and surface duplicate/invalid edit errors clearly.
- description:
  Add an Agents tab/page to Electron. Users can view existing agents, add/start agents, delete/archive/remove existing agents where supported, and create/view/update Agent Templates. UI labels must prefer display_name; durable IDs are hidden/internal; duplicate display_name/template constraints should be surfaced clearly. Reuse existing Start Agent/project-agent flows where sensible.
- acceptance_criteria:
  - Agents tab lists existing/persisted agents with display_name labels
  - Users can add/start and delete/archive/remove agents through the tab
  - Users can create/view/update Agent Templates
  - Duplicate names/invalid edits are blocked with clear errors
  - npm/Nix smokes pass
- participants:
  - odin-ui (assignee) — active
  - odin-lead (coordinator) — active
  - odin-reviewer (reviewer) — active


## task_chain_id: `task-d1bd525486a4`

### `task-d1bd525486a4`
- status: **planning**
- relevance: odin-coder (assigned_agent), odin-coder (assignee), odin-lead (coordinator), odin-reviewer (reviewer)
- priority: P1
- title: Implement daemon UI-control routing and APIs
- depends_on: task-91a22deeee2c
- description:
  Implement daemon/backend support for Electron UI-control requests. Track connected Electron client capabilities, expose client listing for agents, accept ui_control_request from authorized agents, route metadata-only request envelopes to target client_instance_id over user WS, correlate ui_control_response by request_id, enforce timeouts/size limits/permission mode, and persist/audit bounded events without raw large payloads.
- acceptance_criteria:
  - Agents can list connected controllable Electron clients and capabilities
  - Daemon routes ui_control_request to a specific client_instance_id and returns correlated response
  - Permission modes support inspect-only and gated input actions
  - Requests/responses are bounded and audited without arbitrary JS or raw bulky payloads
- participants:
  - odin-coder (assignee) — active
  - odin-lead (coordinator) — active
  - odin-reviewer (reviewer) — active


## task_chain_id: `task-0c70aee85903`

### `task-0c70aee85903`
- status: **planning**
- relevance: odin-coder (assigned_agent), odin-coder (assignee), odin-lead (coordinator), odin-reviewer (reviewer)
- priority: P1
- title: Add ham-ctl UI-control commands and docs
- depends_on: task-d1bd525486a4
- description:
  Add agent-facing CLI/docs for UI control: list clients, dom query, redux query, click, type, scroll. Commands should require agent token, target client_instance_id or default active Electron client where safe, and print bounded JSON results. Document selector best practices, data-testid usage, permission modes, and troubleshooting.
- acceptance_criteria:
  - ham-ctl can list UI clients and send each supported request type
  - CLI output is bounded JSON suitable for agents
  - Docs explain safe selectors, permissions, and examples
- participants:
  - odin-coder (assignee) — active
  - odin-lead (coordinator) — active
  - odin-reviewer (reviewer) — active


## task_chain_id: `task-0ad1eca3c062`

### `task-0ad1eca3c062`
- status: **planning**
- relevance: odin-reviewer (assigned_agent), odin-reviewer (assignee), odin-lead (coordinator)
- priority: P1
- title: Validate agent-to-Electron UI control E2E
- depends_on: task-611d9b66c9bf, task-0c70aee85903
- description:
  Validate UI-control flow end-to-end with a running daemon and Electron UI: agent lists clients, queries DOM by data-testid, queries Redux path, requests click/type/scroll under allowed mode, verifies denied actions under inspect-only mode, validates target-client routing, timeout/size limits, audit events, and no arbitrary JS execution.
- acceptance_criteria:
  - E2E covers dom.query, redux.query, click, type, scroll
  - Permission denial and target-client routing are validated
  - Audit/bounded response/no arbitrary JS safety checks pass
  - Required npm/Nix/build smokes pass
- participants:
  - odin-reviewer (assignee) — active
  - odin-lead (coordinator) — active


## task_chain_id: `task-24184145e75b`

### `task-24184145e75b`
- status: **planning**
- relevance: odin-ui (assigned_agent), odin-ui (assignee)
- priority: P1
- title: Audit daemon display_name persistence and prompt usage
- description:
  Inspect daemon/backend code to verify /agents/start reads and persists display_name, whether reload/restart preserves it, and whether agent prompt/bootstrap uses display_name or daemon-generated agent_instance_id such as coder@project-...
- participants:
  - odin-ui (assignee) — active


## task_chain_id: `task-eb8b2ec5a30d`

### `task-eb8b2ec5a30d`
- status: **planning**
- relevance: odin-reviewer (assigned_agent), odin-reviewer (assignee), odin-lead (coordinator)
- priority: P1
- title: Validate Agents tab E2E
- depends_on: task-efb67e954998
- description:
  Validate the Agents tab end-to-end: create/update Agent Templates, list templates after daemon restart, view existing agents, add/start an agent with display_name and explicit project/provider/template, delete/archive/remove agents, verify duplicate display/template validation, and ensure provider-prefixed IDs are not shown as user-facing names.
- acceptance_criteria:
  - Template CRUD E2E validated
  - Existing-agent list/add/delete/archive E2E validated
  - Restart persistence validated
  - No provider-prefixed labels shown for display names
- participants:
  - odin-reviewer (assignee) — active
  - odin-lead (coordinator) — active


## task_chain_id: `task-80531b121aca`

### `task-80531b121aca`
- status: **blocked**
- relevance: odin-reviewer (assigned_agent), odin-reviewer (assignee), odin-lead (coordinator)
- priority: normal
- title: Final review persisted agent template/project model
- blocked_reason: Dependency task-8774a225e3b0 is not completed/validated yet; final review would be premature.
- depends_on: task-8774a225e3b0
- next_step: Resume final review after task-8774a225e3b0 is completed and validated.
- description:
  Final review of persistent agents/templates/project mapping, role_hint task-system integration, UI, bootstrap resolution, docs, and validation evidence.
- acceptance_criteria:
  - Agent persistence and replay are correct
  - role_hint improves task routing without extra required user choice
  - template/project/instance bootstrap resolution is correct
  - UI and existing workflows remain compatible
  - no regressions in task/memory/chat/start-agent flows
- participants:
  - odin-reviewer (assignee) — active
  - odin-lead (coordinator) — active


## task_chain_id: `task-cf9a43712379`

### `task-cf9a43712379`
- status: **ready**
- relevance: odin-coder (assigned_agent), odin-coder (assignee), odin-lead (coordinator), odin-reviewer (reviewer)
- priority: normal
- title: Integrate templates/projects/instances into bootstrap resolution
- depends_on: task-522e1cb06472, task-a34078da66ac
- next_step: Implement/review according to task description and acceptance criteria. Keep role_hint as template metadata, not a required user-facing decision, and persist AgentInstance records.
- description:
  Update managed agent bootstrap resolution to use AgentTemplate and AgentInstance records. Bootstrap context should include provider/profile runtime requirements, base template persona/memory templates, shallow derived template overrides, project memory/context/anchors, and instance-specific approved memory/learning. Preserve active-only memory semantics and exclude pending/rejected/archived memory and proposal reason/evidence metadata.
- acceptance_criteria:
  - bootstrap uses AgentTemplate persona/defaults and role_hint metadata where relevant
  - derived template overrides resolve predictably with shallow inheritance
  - project context and instance memory are included in the approved order
  - active-only memory and proposal metadata exclusion are preserved
  - legacy bootstrap behavior remains compatible
- participants:
  - odin-coder (assignee) — active
  - odin-lead (coordinator) — active
  - odin-reviewer (reviewer) — active


## task_chain_id: `task-8774a225e3b0`

### `task-8774a225e3b0`
- status: **ready**
- relevance: odin-coder (assigned_agent), odin-coder (assignee), odin-lead (coordinator), odin-reviewer (reviewer)
- priority: normal
- title: Document and validate persisted agents/templates/project mapping E2E
- depends_on: task-3706206b0c04, task-cf9a43712379
- next_step: Implement/review according to task description and acceptance criteria. Keep role_hint as template metadata, not a required user-facing decision, and persist AgentInstance records.
- description:
  Document AgentTemplate, role_hint, ProviderProfile, Project, AgentInstance, and memory/bootstrap resolution model. Validate E2E: create templates with role_hint, create project, start coding@project and coding-ui@project with provider profile, persist known agents across daemon restart, show live vs known agent state, verify one project per instance, verify bootstrap includes template/project/instance layers, and verify cross-project messaging remains allowed.
- acceptance_criteria:
  - docs explain template/persona vs role_hint vs provider vs instance
  - E2E persistence/restart smoke passes
  - bootstrap layer smoke passes
  - UI known/live agent smoke passes
  - build/nix/npm smokes pass
- participants:
  - odin-coder (assignee) — active
  - odin-lead (coordinator) — active
  - odin-reviewer (reviewer) — active


## task_chain_id: `task-2ddd1eac1a19`

### `task-2ddd1eac1a19`
- status: **review**
- relevance: odin-lead (assigned_agent), odin-lead (assignee), odin-lead (coordinator), odin-reviewer (reviewer)
- priority: normal
- title: Update odin-agent memories for Heimdall rename
- description:
  Coordinate memory audits/updates for odin-* agents after product rename from odin-test/Odin to Heimdall AI Manager and directory rename to /Users/tanmayvijay/heimdall-ai-manager. Agents should propose memory edits/additions/removals so durable memory reflects ham-* commands, Heimdall naming, and new path while preserving legacy alias knowledge only where useful.
- acceptance_criteria:
  - odin-coder, odin-reviewer, odin-ui, and odin-lead memories are checked for stale rename guidance
  - Useful memory proposals are created rather than directly mutating approved memory
- participants:
  - odin-lead (assignee) — active
  - odin-lead (coordinator) — active
  - odin-reviewer (reviewer) — active


## task_chain_id: `task-4a8a58d2fdbf`

### `task-4a8a58d2fdbf`
- status: **ready**
- relevance: odin-lead (assigned_agent), odin-lead (assignee), odin-lead (coordinator), odin-reviewer (reviewer)
- priority: normal
- title: Audit and update odin-lead memory for Heimdall rename
- next_step: Audit odin-lead memory for stale rename guidance and propose updates; do not self-approve memory.
- description:
  Audit odin-lead durable memory for stale odin-test/Odin/bc-* operational guidance and propose memory updates for Heimdall AI Manager rename, ham-* binaries, and new repo path.
- acceptance_criteria:
  - odin-lead stale rename-related memory is identified
  - Memory proposals are submitted for needed changes
- participants:
  - odin-lead (assignee) — active
  - odin-lead (coordinator) — active
  - odin-reviewer (reviewer) — active


## task_chain_id: `task-93ebe246afc2`

### `task-93ebe246afc2`
- status: **blocked**
- relevance: odin-coder (assigned_agent), odin-coder (assignee), odin-coder (coordinator)
- priority: normal
- title: Audit odin-coder durable memory
- blocked_reason: Waiting for user approval before submitting memory proposals; audit report has been presented.
- next_step: Approve proposed memory changes or request revisions.
- description:
  Audit odin-coder recent validated work, existing approved/pending memory, and task evidence; prepare conservative memory-maintenance report and proposed memory changes for user approval before any mutation.
- participants:
  - odin-coder (assignee) — active
  - odin-coder (coordinator) — active


## task_chain_id: `task-b2453ad6a87e`

### `task-b2453ad6a87e`
- status: **planning**
- relevance: odin-ui (assigned_agent), odin-ui (assignee)
- priority: normal
- title: Stylize Electron chat scrollbars
- next_step: Add minimal global scrollbar styling in UI CSS, then run npm build and smoke.
- description:
  Style the Electron UI scrollbars to match the dark Framer-like design without changing chat behavior or daemon APIs.
- participants:
  - odin-ui (assignee) — active


## task_chain_id: `task-6862f3296703`

### `task-6862f3296703`
- status: **planning**
- relevance: odin-ui (assigned_agent), odin-ui (assignee)
- priority: high
- title: Relocate Electron app into ui directory and wire flake package/app
- next_step: Create ui/electron directory, relocate files, update build paths and scripts, and add flake package/app for UI.
- description:
  Move Electron app runtime files into the ui/ directory and update Node package scripts plus flake.nix to include a buildable package/app entry for the Electron UI. Keep app behavior unchanged.
- acceptance_criteria:
  - Electron main/preload and related runtime files live under ui/ directory; package.json entrypoints resolve correctly; flake.nix exports a dedicated UI app/package (or updates existing) and can be addressed as flake apps for launch; no behavioral regressions in UI flow.
- participants:
  - odin-ui (assignee) — active


## task_chain_id: `task-984817254c74`

### `task-984817254c74`
- status: **planning**
- relevance: odin-coder (assigned_agent), odin-coder (assignee), odin-lead (coordinator), odin-reviewer (reviewer)
- priority: high
- title: Distributed task orchestration: hub event log + remote assignee support
- depends_on: task-eaeb1a64c7e5
- next_step: Queued after current UI alignment closure; keep priority high. Work with odin-reviewer once implementation proposal ready. Preserve existing local task durability and UI compatibility.
- description:
  Add distributed task architecture per user roadmap: switch from completed-only archive model to central hub storing live encrypted task event log. Local daemon keeps durable task projection/cache in data_dir, replays events on restart, and advances sync cursor only after durable append+apply. Add hub->daemon pull/push sync with hub record metadata (task_chain_id, task_id, target_agent_instance_ids, target_user_ids, source_daemon_id, namespace/user_id, record_seq, event_id) and encrypted task.event payloads for append-only audit. Preserve non-empty comments for status mutations. Support remote Electron notifications via local daemon after sync, mixed local/remote assignees/reviewers/coordinators, cross-daemon dependencies, idempotency via event_id, ordered sync via record_seq, and coordinator-daemon-only automation (dependency unblocking/ready transitions/rollups) to avoid duplicate execution. Keep hub as opaque relay (no payload decryption). Add reliability via local pending outbox + retry/backoff + offline ready-task reminders. Preserve existing metadata-only WS patterns and daemon/agent architecture boundaries. Phased rollout recommended: (1) rich local task model/events, (2) hub append/sync, (3) distributed assignment/routing, (4) reliability hardening.
- acceptance_criteria:
  - Detailed design and implementation plan delivered plus scoped tasks/patches: hub stores encrypted event log with metadata and ordered record_seq/event_id idempotency; local daemon projection + cursor sync implemented with durable append before cursor advance; status mutations require comments; mixed local/remote roles and dependencies handled; remote Electron updates received via local daemon; coordinator-daemon gate preserved; offline reminders and pending outbox retry/backoff added. Build/build-like smoke for task subsystem pass; no WS payload changes.
- participants:
  - odin-coder (assignee) — active
  - odin-lead (coordinator) — active
  - odin-reviewer (reviewer) — active


## task_chain_id: `task-315117462f6d`

### `task-315117462f6d`
- status: **planning**
- relevance: odin-reviewer (assigned_agent), odin-reviewer (assignee), odin-lead (coordinator)
- priority: high
- title: Review distributed task orchestration roadmap/implementation
- depends_on: task-984817254c74
- description:
  Review architecture task for hub-backed distributed task orchestration. Verify local daemon durable projection/cursor sync, encrypted task.event records with metadata-only at hub, idempotent ordered record_seq/event_id processing, mixed local/remote assignees/dependencies, coordinator-daemon automation boundaries, local pending outbox + retry/backoff, and offline reminder behavior. Ensure status transitions preserve comment/body requirement and no WS metadata/body regressions.
- acceptance_criteria:
  - Review records phased plan + design evidence, risk assessment, and implementation results for distributed task orchestration.
- participants:
  - odin-reviewer (assignee) — active
  - odin-lead (coordinator) — active


## task_chain_id: `task-6c0ca129c45c`

### `task-6c0ca129c45c`
- status: **planning**
- relevance: odin-reviewer (assigned_agent), odin-reviewer (assignee)
- priority: P2
- title: Audit odin-reviewer durable memory
- description:
  Audit odin-reviewer Broccoli Comms tasks/events/working state and approved memory; prepare conservative memory-maintenance report and wait for approval before proposing memory mutations.
- participants:
  - odin-reviewer (assignee) — active


Source: `broccoli-comms task list --json --include-participants --status planning,ready,working,blocked,review`
