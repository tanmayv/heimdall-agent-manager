# 00 · Locked decisions

This file records the locked design decisions for Teams v1. It is derived from `CHAIN_DESCRIPTION.md` and is intended to be the short, reviewable decision log for the rest of `docs/teams-v1/`.

For the reviewer checklist, see [`10-review-invariants.md`](./10-review-invariants.md). The invariant IDs in that file are the durable acceptance criteria for implementation tasks.

## Decisions

### 1. Vocabulary is Project / Team / Task Chain

**Decision:** The user-facing conceptual model uses **Project**, **Team**, and **Task Chain**. Do not introduce a fourth noun such as "workstream". Agents remain internal-ish team members.

**Rationale:** The existing system already exposes projects and task chains. Teams explain how roles are organized behind a chain, while agents are implementation details. Avoiding additional nouns keeps UI, CLI, and documentation coherent.

**Reviewer invariants:** `INV-1`, `INV-2`, `INV-3`, `UI-1`, `UI-2`.

### 2. Team kinds are a closed set

**Decision:** Team kinds are compiled into the daemon and limited to: `coding`, `research`, `debugging`, `data-analysis`, `writing`, `ops`, and `solo`.

**Rationale:** A closed set prevents role/template sprawl, makes scaffolds reviewable, and gives implementation tasks a stable registry to validate against.

**Reviewer invariants:** `INV-3`, `CFG-1`.

### 3. One team instance per task chain

**Decision:** Every task chain has exactly one team instance. Team lifecycle is bound to chain lifecycle.

**Rationale:** This keeps ownership, memory scope, VCS workspace ownership, and archival behavior auditable. Cross-team collaboration should be modeled as cross-chain dependency, not shared task ownership.

**Reviewer invariants:** `LC-1`, `LC-6`, `MEM-1`, `MEM-5`.

### 4. Agent boot is lazy

**Decision:** Creating a team does not start agents. Agents boot only when scheduler-recognized work requires them.

**Rationale:** Teams are records, not processes. Lazy boot reduces idle resource use and avoids a user-facing "start team" mental model.

**Reviewer invariants:** `INV-1`, `LC-1`, `LC-2`, `LC-4`.

### 5. Coordinator warm-on-focus is low priority

**Decision:** Opening a chain view may request coordinator boot, but only as a low-priority warm-on-focus event.

**Rationale:** The UI should feel responsive while still yielding resources to higher-priority work such as review-ready tasks.

**Reviewer invariants:** `LC-2`, `LC-5`, `UI-5`.

### 6. Idle shutdown grace defaults to 30 minutes

**Decision:** Team members shut down after 30 minutes idle by default, with per-kind override support.

**Rationale:** A fixed default gives predictable resource cleanup while preserving enough time for normal review/comment pauses.

**Reviewer invariants:** `LC-3`.

### 7. Chain `completed` is terminal; merge decision is an approval

**Decision:** `completed` remains a terminal chain state. For VCS-backed chains, merge/keep/abandon is surfaced as a Needs attention approval item, not as a new chain state.

**Rationale:** State-machine simplicity matters. Merge is an operator decision after completion, not more autonomous task-chain execution.

**Reviewer invariants:** `INV-4`, `INV-5`, `LC-6`, `VCS-4`, `UI-3`.

### 8. Solo mode is a team of one plus `user_proxy`

**Decision:** Solo mode uses a normal team instance with one worker and a synthetic `user_proxy` reviewer routed to `operator@local`.

**Rationale:** Solo work should use the same task/review machinery as team work while preserving user approval for review gates.

**Reviewer invariants:** `INV-2`, `UI-3`, `API-3`.

### 9. Chain chat routes user messages to the coordinator only

**Decision:** User-originated chain chat goes to the chain coordinator. Other agents can be represented through coordinator forwarding, not direct main-path chat.

**Rationale:** The coordinator owns prioritization and user-facing communication. This avoids conflicting answers and preserves a single escalation path.

**Reviewer invariants:** `INV-2`, `UI-2`, `UI-5`, `API-3`.

### 10. Git worktrees and jj workspaces are first-class VCS backends

**Decision:** VCS support is implemented through one backend interface with both git worktrees and jj workspaces supported from day one.

**Rationale:** Parallel chains need isolated filesystems. Git and jj users should receive the same Heimdall behavior except for backend-specific commands.

**Reviewer invariants:** `INV-4`, `INV-6`, `INV-7`, `VCS-1`, `VCS-2`, `VCS-3`, `VCS-4`, `VCS-5`, `VCS-6`.

### 11. User-facing memory scopes are Team_Project, Project, and Template

**Decision:** User-facing memory scopes are `Team_Project`, `Project`, and `Template`. `Personal` remains internal-only.

**Rationale:** The primary durable learning surface is how a team works in a project. Template memory supplies curated defaults, and project memory captures agent-independent local facts.

**Reviewer invariants:** `MEM-1`, `MEM-2`, `MEM-3`, `MEM-4`, `MEM-5`.

### 12. Project anchors use a closed vocabulary

**Decision:** Project anchors are limited to `git_repo`, `base_ref`, `vcs_kind`, `worktree_root`, `docs`, and `scratch`.

**Rationale:** Closed anchors make migration, VCS detection, bootstrap rendering, and UI surfacing deterministic. Free-form information belongs in project descriptions.

**Reviewer invariants:** `VCS-6`, `MIG-3`.

### 13. Testers are task assignees, not permanent reviewer slots

**Decision:** No team kind includes `tester` as a permanent reviewer role. Testers perform explicit validation tasks when independent execution evidence is needed.

**Rationale:** Review gates should stay attached to the work being validated through `lgtm_required` reviewers. Separate tester tasks are for independent test execution, not default review routing.

**Reviewer invariants:** `INV-3` and the task-authoring conventions in [`10-review-invariants.md`](./10-review-invariants.md).

## Consistency notes

- `Team` is a visible concept for chain roster/status and kind selection, but there is no main-path action to start a team directly.
- `Task Chain` remains the unit of user-visible work and VCS workspace ownership.
- `Agent` can appear in rosters, raw settings, and audit evidence, but direct user-to-agent workflow is not on the main path.
- VCS write operations may be previewed automatically but require an explicit operator action to execute.
