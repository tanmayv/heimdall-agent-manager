---
name: memory-management-workflow
description: Propose and read durable Heimdall memories with `ham-ctl memory`, and pick the right scope and type. Load before proposing a memory or when deciding where long-term knowledge belongs.
---

# Heimdall memory management

Use memories for long-term knowledge: project rules, habits, facts, expertise. All commands use `./bin/ham-ctl`.

## Scope
Scope is set by FOUR id-list dimensions on `memory propose`; there is NO `--scope` word-flag. Each dimension accepts singular/plural spellings and either repeated flags or comma-separated values (`--project-ids proj_1,proj_2` == `--project proj_1 --project proj_2`):

| Dimension | Flag spellings | Use for |
|---|---|---|
| Agent | `--agent-id` / `--agent-ids` / `--agent` / `--agents` | knowledge specific to an agent definition across its instances; defaults to the caller's own agent if omitted |
| Project | `--project-id` / `--project-ids` / `--project` / `--projects` | a specific project repository |
| Bridge | `--bridge-id` / `--bridge-ids` / `--bridge` / `--bridges` | host environment or infrastructure |
| Template | `--template-id` / `--template-ids` / `--template` / `--templates` | agents initialized from a specific template |

- **Global**: omit the scope flags for system-wide knowledge. An omitted dimension applies broadly (to all).
- Ephemeral instance memories bind durably to the instance's underlying `agent_id` (and project/bridge where applicable).

## Types
- `fact`: static declarative truth or project configuration.
- `habit`: behavioral pattern or operational preference.
- `episode`: record of a specific past event or task run outcome.
- `expertise`: special knowledge, architectural insight or deep domain rule.
- `skill`: machine-actionable procedure or SKILL.md instruction set.

Template is a scope (`--template`), not a type.

## Propose, review, approve
- Agents propose with `ham-ctl memory propose`; the memory is `pending`.
- Approval is a HUMAN/operator action; there is no agent `memory approve` verb. A human approves in Settings -> Memory, via `ham-ctl hub memories approve <id>` (hub/user token), or by accepting a Curator action card (`memory.approve`, see `action-cards`). Approval makes it `active`; proposals can also be edited or rejected.
- You only propose and read (`propose`, `list`, `show`, `content`); you cannot approve your own or others' memories. System memories (`owner_user_id = 'system'`) are read-only.

## Commands
```bash
./bin/ham-ctl memory propose --type fact --title "Build Rule" --body "Always run tests before committing." \
  --project-ids <project-id> --agent-ids <agent-id> [--description <t>] [--evidence <t>] [--bridge-ids <id,...>]
./bin/ham-ctl memory propose --type habit --title "Reviewer checklist" --body "..." --template-ids <template-id>
./bin/ham-ctl memory list [--status active|pending] [--type <type>] [--agent-ids ...] [--project-ids ...] [--bridge-ids ...] [--template-ids ...] [--limit N]   # metadata only
./bin/ham-ctl memory show <memory-id>      # full details: body + evidence
./bin/ham-ctl memory content <memory-id>   # raw body
```
