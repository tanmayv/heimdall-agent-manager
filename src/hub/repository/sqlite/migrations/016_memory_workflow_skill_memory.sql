INSERT INTO memories (memory_id, owner_user_id, agent_id, project_id, template_id, bridge_id, type, status, title, body, evidence, created_at, updated_at)
VALUES (
  'mem_system_heimdall_memory',
  'system',
  '',
  '',
  '',
  '',
  'skill',
  'active',
  'Heimdall Memory Management & Workflow Skill',
  '---
name: memory-management-workflow
description: Core guidance for Heimdall memory management, scope selection, proposal review, and ham-ctl CLI commands.
---

# Heimdall Memory Management & Workflow Skill

Use Heimdall memory management for managing long-term agent knowledge, project scopes, habits, facts, and expertise.

## Scope Selection Rules
- **Agent Scope** (agent_id): Knowledge specific to an agent definition across instances.
- **Project Scope** (project_id): Knowledge scoped to a specific project repository.
- **Bridge Scope** (bridge_id): Host environment or infrastructure knowledge.
- **Template Scope** (template_id): Guidance for agents initialized from a specific template.
- **Global Scope**: Leave scope fields empty for system-wide knowledge.
- **Ephemeral Instances**: Ephemeral instance memories bind durably to the instance''s underlying agent_id (and project/bridge where applicable).

## Memory Types
- fact: Static declarative truth or project configuration.
- habit: Behavioral pattern or operational preference.
- episode: Record of specific past event or task run outcome.
- expertise: Special knowledge, architectural insight, or deep domain rule.
- skill: Machine-actionable procedure or SKILL.md instruction set.
Template targeting is available through template_id scope; template is not a memory type.

## Propose-Review-Approve Workflow
- Agents propose new memories in pending status using ham-ctl or agent actions.
- Humans review pending proposals in Settings -> Memory UI or CLI.
- Proposals can be edited before approval, approved directly (flipping status to active), or rejected.
- System memories (owner_user_id = ''system'') are read-only.

## CLI Usage Examples (ham-ctl)
- Propose a memory: ./.heimdall/bin/ham-ctl agent memory propose --title "Build Rule" --type "fact" --body "Always run tests before committing."
- Approve proposal: ./.heimdall/bin/ham-ctl memory approve mem_123
- List memories: ./.heimdall/bin/ham-ctl memory list --status active',
  'Seeded system default memory for memory workflow skill.',
  '2026-07-29T00:00:00Z',
  '2026-07-29T00:00:00Z'
)
ON CONFLICT(memory_id) DO UPDATE SET
  agent_id=excluded.agent_id,
  project_id=excluded.project_id,
  template_id=excluded.template_id,
  bridge_id=excluded.bridge_id,
  type=excluded.type,
  status=excluded.status,
  title=excluded.title,
  body=excluded.body,
  evidence=excluded.evidence,
  updated_at=excluded.updated_at;
