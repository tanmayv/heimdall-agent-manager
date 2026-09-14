---
name: memory-management-workflow
description: Core guidance for Heimdall memory management, scope selection, proposal review, and ham-ctl CLI commands.
---

# Heimdall Memory Management & Workflow Skill

Use Heimdall memory management for managing long-term agent knowledge, project scopes, habits, facts, and expertise.

All commands use the managed wrapper from your run directory: `./.heimdall/bin/ham-ctl`.

## Scope Selection Rules
- **Agent Scope** (`--agent <agent-id>`): Knowledge specific to an agent definition across instances.
- **Project Scope** (`--project <project-id>`): Knowledge scoped to a specific project repository.
- **Bridge Scope** (`--bridge <bridge-id>`): Host environment or infrastructure knowledge.
- **Template Scope** (`--template <template-id>`): Guidance for agents initialized from a specific template.
- **Global Scope**: Omit scope flags for system-wide knowledge applicable across all agents, projects, and bridges.
- **Ephemeral Instances**: Ephemeral instance memories bind durably to the instance's underlying agent_id (and project/bridge where applicable).

## Memory Types
- `fact`: Static declarative truth or project configuration.
- `habit`: Behavioral pattern or operational preference.
- `episode`: Record of specific past event or task run outcome.
- `expertise`: Special knowledge, architectural insight, or deep domain rule.
- `skill`: Machine-actionable procedure or SKILL.md instruction set.
Template targeting is available through the `--template` scope flag; template is not a memory type.

## Propose-Review-Approve Workflow
- Agents propose new memories in `pending` status using `ham-ctl memory propose`.
- Humans review pending proposals in Settings -> Memory UI or CLI.
- Proposals can be edited before approval, approved directly (flipping status to `active`), or rejected.
- System memories (`owner_user_id = 'system'`) are read-only.

## CLI Usage Examples (ham-ctl)
- **Propose a memory**:
  `./.heimdall/bin/ham-ctl memory propose --type fact --title "Build Rule" --body "Always run tests before committing." [--project <project-id>] [--agent <agent-id>]`
- **List memories**:
  `./.heimdall/bin/ham-ctl memory list [--status active|pending] [--type <type>]`
- **Show memory details**:
  `./.heimdall/bin/ham-ctl memory show <memory-id>`
- **Approve proposal** (operator/admin):
  `./.heimdall/bin/ham-ctl memory approve <memory-id>`
