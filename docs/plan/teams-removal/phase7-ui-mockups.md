# Phase 7 UI mockups: no teams, no chain kind, default-agent map

## Scope
This mockup covers `task-19f7ae4a50f` (TR-14, TR-15, TR-16). It is intentionally implementation-faithful and text-first so it can be reviewed quickly before UI code changes.

## Mock 1 — New chain modal

```text
┌ Create task chain ──────────────────────────────────────────────┐
│ Title                                                          │
│ [ Implement upload retry policy______________________________ ] │
│                                                                │
│ Goal                                                           │
│ [ Describe the outcome. The coordinator will use skills       ] │
│ [ (coordinator-playbook + scaffold recipe skills) to plan.    ] │
│                                                                │
│ Project                                                        │
│ [ heimdall-agent-manager ▾ ]                                   │
│                                                                │
│ Workspace                                                      │
│ [x] Request VCS workspace setup task                           │
│     Creates an explicit “Prepare chain workspace” task.        │
│                                                                │
│ The daemon no longer asks for chain kind, scaffold, or roster. │
│ The chain starts with a coordinator planning task.              │
│                                                                │
│                                      [ Cancel ] [ Create ]      │
└────────────────────────────────────────────────────────────────┘
```

Required debug ids:
- `new-chain-title-input`
- `new-chain-goal-textarea`
- `new-chain-project-select`
- `new-chain-wants-vcs-checkbox`
- `new-chain-create-btn`

Removed from this surface:
- chain kind selector
- scaffold selector
- generated team/roster preview
- any `team_id`/team allocation progress step

## Mock 2 — Chain/task editor

```text
┌ Chain: Implement upload retry policy ──────────────────────────┐
│ Goal-driven chain. Roles are task participants, not team slots. │
│                                                                │
│ [Chain controls] [Task graph] [Artifacts]                      │
│                                                                │
│ No roster card. Add work by creating tasks and participants:   │
│   task assignee / coordinator / required reviewer / subscriber │
└────────────────────────────────────────────────────────────────┘
```

Removed from this surface:
- `Team member` inspector label
- `+ Add member` / `/teams/add-member`
- chain team id context row
- team fetch/loading state

## Mock 3 — Settings: Default agents

```text
Settings › Default agents

Role/default-use → durable default agent id
These defaults are suggestions used by skills/coordinators when assigning task
participants. Task participants remain the authority for actual roles.

┌ Use             Durable agent id                         Status ┐
│ conversation    [ conversation ▾ ]                       seeded │
│ guide           [ guide ▾ ]                              seeded │
│ coordinator     [ coordinator ▾ ]                        seeded │
│ worker          [ worker ▾ ]                             seeded │
│ assignee        [ worker ▾ ]                             alias  │
│ coder           [ worker ▾ ]                             alias  │
│ tester          [ worker ▾ ]                             alias  │
│ researcher      [ worker ▾ ]                             alias  │
│ specialist      [ worker ▾ ]                             alias  │
│ reviewer        [ reviewer ▾ ]                           seeded │
└────────────────────────────────────────────────────────────────┘

[ Refresh ]                                      [ Save changes ]
```

Implementation notes:
- Use existing AgentPicker/AgentSelect patterns for durable agent ids.
- Read/write via `/agents/defaults` / `ham-ctl agents defaults` equivalent API.
- Do not add behavioral role fields to agent/template records.

Required debug ids:
- `settings-default-agents-panel`
- `settings-default-agents-refresh-btn`
- `settings-default-agents-save-btn`
- `settings-default-agent-use-${use}-picker-btn`
- `settings-default-agent-use-${use}-value`

## Mock 4 — Memory management

```text
Memory management
Filters: [Agent target] [Project target] [Type] [Status] [Targeting]

Core/scaffold skills appear as normal editable memories:
- task-workflow
- review-and-evidence
- coordinator-playbook
- git-hygiene
- contracts-first
- testing-discipline
- scaffold-coding-feature
- scaffold-coding-bugfix
- scaffold-research
- scaffold-solo
- vcs-workspace-setup
```

Required behavior:
- No team/kind targeting labels.
- Skills are visible when filtering `type=skill`.
- Existing edit/proposal flow can edit these skill memories.

## Acceptance mapping
- TR-14: new chain and chain editor have no team concept, `/teams` dependency, chain kind selector, scaffold selector, or scaffold roster selector.
- TR-15: Settings exposes editable role/default-use → durable agent id map.
- TR-16: core/scaffold skills are normal visible/editable memories without team/kind targeting terminology.
