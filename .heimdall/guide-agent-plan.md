# Guide Agent Plan

## Goal
Create a singleton Heimdall Guide agent that starts with the daemon and is available globally to help users with Heimdall usage, debugging, UI workflows, task/team/chat state, and operational issues.

Long-term UX goal: a global side chat panel, accessible from every page, connected to this single guide agent.

## Non-goals / Boundaries
- The guide is not a project/team-chain agent and must not be assigned to arbitrary project work.
- It should not be launched per project, per chain, or per team.
- It must not receive a long-lived unrestricted user token in its prompt/bootstrap.
- It should not silently mutate user/project/task state without an auditable user authorization path.

## Proposed Identity
- Agent instance id: `guide@heimdall`
- Agent class/template: `guide`
- Scope: system/global, not project-scoped.
- Backing hidden/system project if required by current persistence model: `heimdall-system`, but UI should present it as global guide rather than a project member.
- Singleton invariant: exactly one live or startable guide instance.

## Capabilities

### Initial capabilities
1. Answer Heimdall usage questions.
2. Explain task chains, teams, Needs attention, approvals, memory, providers, daemon profiles, and runtime status.
3. Inspect global Heimdall state through safe daemon RPCs.
4. Talk to other agents through existing chat/message infrastructure.
5. Route user requests to coordinators/agents, but not bypass project workflow rules.

### Later capabilities
1. Drive Electron debug UI for guided troubleshooting.
2. Perform user-authorized actions using short-lived delegated user capabilities.
3. Produce guided walkthroughs in the side panel with inline action buttons.

## Security Model
The guide is high-privilege, so use capability delegation instead of giving it a raw persistent user token.

### Recommended model
- Add daemon-managed scoped capabilities for the guide:
  - read-only state inspection by default.
  - UI-debug actions only when an active Electron client registers debug control availability.
  - mutating user actions require explicit user confirmation or short-lived delegation.
- Every privileged guide action should be audited:
  - action type
  - user id
  - guide agent id
  - target resource
  - timestamp
  - result
- The guide can request actions, but the daemon enforces policy.

### Avoid
- Putting `operator@local` user tokens directly in the guide bootstrap.
- Letting the guide call arbitrary user RPC as the user with no approval trail.
- Letting the guide control Electron debug UI when no visible/active UI session is registered.

## Backend Plan

### 1. Config
Add a `[guide_agent]` or daemon config section:

```toml
[guide_agent]
enabled = true
agent_instance_id = "guide@heimdall"
provider_profile = "pi"
model_tier = "smart"
template_id = "guide"
autostart = true
restart_if_stopped = true
```

Also expose equivalent user preferences later for model/provider.

### 2. Template
Add a built-in `guide` template:
- Role: Heimdall product/operator guide.
- Context: knows Heimdall concepts, daemon/UI/debug workflows, task chains, teams, approvals, memory, providers.
- Operating rules:
  - answer user questions first
  - explain before acting
  - request explicit confirmation before mutation
  - use guide-safe RPCs/capabilities
  - escalate project-specific work to the relevant coordinator

### 3. Startup lifecycle
Add daemon startup reconciliation after auth/template/agent services are initialized:
- `guide_runtime_reconcile("daemon_startup")`
- If enabled and no live guide exists, launch `guide@heimdall`.
- Launch source logging:
  - `DAEMON_LAUNCH ... source=guide_startup target=guide@heimdall`
- Exempt from task autoscaler/team boot leases.
- Exempt from idle shutdown.
- Do not create team memberships or project chain tasks.

### 4. Singleton persistence
Extend agent store or add guide service rules:
- Ensure only `guide@heimdall` can have template `guide` unless explicitly allowed by dev/test config.
- Hide guide from normal project roster assignment lists.
- Show guide in global/system agents list with a special badge.

### 5. Guide-safe daemon RPCs
Add a constrained guide RPC surface:
- `guide_status`
- `guide_state_summary`
- `guide_list_chains`
- `guide_show_chain`
- `guide_show_agent_runtime`
- `guide_send_agent_message`
- Later: `guide_request_user_action`
- Later: `guide_ui_debug_action`

These should not require raw user-token impersonation.

### 6. UI debug bridge
Long term, route UI debug through the daemon rather than letting the guide call localhost debug server directly.

Flow:
1. Electron debug server registers with daemon:
   - client id
   - debug port
   - enabled actions
   - active window/page metadata
2. Guide requests a UI action through daemon.
3. Daemon checks user/session policy.
4. Electron executes the action and returns result.
5. Daemon audits result and forwards it to guide.

## UI Plan

### 1. Global side chat panel
Add a persistent Guide button in the app shell:
- visible on every page
- opens right-side panel
- panel title: `Heimdall Guide`
- status indicator: starting / ready / offline / blocked
- unread indicator

### 2. Guide chat surface
Reuse coordinator/direct chat primitives where possible, but conversation target is fixed:
- `agent_instance_id = guide@heimdall`
- no project/chain required
- optimistic send
- delivery/read status
- markdown rendering
- quick action cards later

### 3. Guide runtime controls
In Settings or panel overflow:
- Start/restart guide
- Show logs
- Show runtime/tmux pane
- Change provider/tier if allowed

### 4. Guided actions
Later, render guide-suggested actions as buttons:
- “Open Settings”
- “Show daemon logs”
- “Open chain X”
- “Run health check”
- “Ask coordinator”

Mutating actions should require confirmation.

## Agent-to-Agent Communication
The guide should be able to message other agents using existing chat infrastructure, with policy:
- Can contact any live agent for diagnostics.
- For project work, should prefer project coordinator.
- Should not directly assign/modify project tasks unless user authorizes it.
- Should include itself as `guide@heimdall` in messages for auditability.

## Implementation Phases

### Phase 1: Backend singleton + autostart
- Add guide config defaults.
- Add `guide` template.
- Add guide startup reconciliation on daemon boot.
- Ensure singleton identity and no task/team assignment.
- Exempt from idle shutdown.
- Add logs and tests.

Acceptance:
- Fresh daemon boot launches exactly one `guide@heimdall`.
- `/agents` shows guide as system/global.
- Reboot does not create duplicates.
- Guide startup logs show `source=guide_startup`.

### Phase 2: Basic global guide chat
- Add global side panel button.
- Add chat store plumbing for `guide@heimdall`.
- Send/fetch messages without project/chain id.
- Show runtime state.

Acceptance:
- User can open side panel from Home, Settings, Tasks/chain pages.
- Messages to guide persist and dedupe correctly.
- Offline/starting states are clear.

### Phase 3: Safe inspection tools
- Add guide-safe read-only RPCs.
- Update guide bootstrap to use them.
- Add tests for access controls.

Acceptance:
- Guide can summarize daemon/project/chain status without user token impersonation.
- Unauthorized mutating calls fail.

### Phase 4: UI debug bridge
- Electron registers debug-control capability with daemon.
- Guide can request read-only UI inspection first.
- Add explicit confirmation for click/type/select actions.

Acceptance:
- Guide can inspect current page/elements through daemon-mediated API.
- User can approve a suggested UI action.
- All UI debug actions are audited.

### Phase 5: Delegated user actions
- Add short-lived scoped user delegation tokens or action grants.
- Guide can perform approved user actions through daemon policy.

Acceptance:
- User authorizes a specific guide action.
- Guide performs it.
- Audit trail records the authorization and result.

## Tests

Backend:
- Guide autostarts on daemon startup.
- Singleton enforcement prevents duplicates.
- Guide is not assigned to project/team scaffold roles.
- Guide exempt from idle shutdown.
- Guide launch source is logged as `guide_startup`.
- Guide cannot use mutating user RPCs without delegation.

UI:
- Guide side panel visible on every route.
- Guide chat send/fetch works without chain id.
- Guide status updates from agent lifecycle events.
- Panel does not interfere with coordinator chat.

Security/integration:
- UI debug bridge unavailable unless Electron client registers it.
- Mutating guide action requires confirmation.
- Audit events are persisted.

## Open Questions
1. Should the guide always run by default, or should first-run onboarding ask the user to enable it?
2. Should the guide use `pi smart` by default, or inherit `default_agent_provider_profile/default_agent_model_tier`?
3. Should guide be visible in the normal Agents page, or only in Settings/Guide panel?
4. Should guide be allowed to message every agent by default, or only coordinators unless the user approves broader contact?
5. How much daemon internals/docs should be included in bootstrap versus exposed as read-only tools?
