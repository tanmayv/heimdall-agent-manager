---
name: action-cards
description: Create Action Cards, the proposals a user accepts or rejects: the `action create` CLI, the `agent.cards.create` payload, operation labels, the operation catalog, guards and source refs. Load before creating or attaching a card, for example to propose a memory approval or curator maintenance.
---

# Action Cards

An Action Card is a proposal the user reviews and explicitly accepts; accepting runs its `operations` atomically. Create one for operations the user must approve, such as approving a proposed durable memory.

**Task approval needs no action card.** Use the task review UI, or record the user's explicit verdict with `ham-ctl review post <task-id> --verdict approve|request_changes --on-behalf-of user`. Keep required review gates; never infer approval from a question-answer selection or silence.

## From an agent: `ham-ctl action create`
```bash
ham-ctl action create --title "Approve database indexing memory" \
  --operations '[{"op":"memory.approve","label":"Approve memory","args":{"memory_id":"mem_123"}}]'
# -> card id crd_abc123
ham-ctl chat send --to user --body "Please review the proposed memory." --actions crd_abc123
```
Attach the card to a chat message with `--actions <action-id>` (or repeated `--action`; `chat send` also takes a comma list). These cards remain available for their explicit operations, unlike question controls, which expire (see `heimdall-ctl-communication`).

## Card payload: `agent.cards.create` (or `POST /api/v1/cards`)
The curator and other agents that emit cards over the RPC send:
- `project_id`: target project ID.
- `title`: concise, imperative summary (for example "Consolidate duplicate Nix build memories").
- `rationale`: why the maintenance is recommended, based on recent activity.
- `scope`: entity scope, one of `"memory"`, `"project"`, `"agent"`, `"task"`.
- `provider`: `"curator_llm"`.
- `confidence`: 0.0 to 1.0.
- `source_refs`: JSON array of the exact entity IDs used as evidence, for example `["mem_123", "mem_456", "cmt_789"]` (`task_...`, `cmt_...`, `mem_...`, `chain_...`, `chat_...`, `agt_...`).
- `guard`: precondition object, see Guards (full form, or `{"expires_at": "..."}` alone).
- `operations`: JSON array of typed operation objects.

**Two shapes, both as sourced.** The CLI example above puts operation parameters under `"args"` (`ham-ctl action create --operations`). The RPC/REST payload (`agent.cards.create`, `POST /api/v1/cards`) and the examples under Operation labels and Operation catalog use flat operation objects (`"memory_id": …` beside `"op"` and `"label"`). Use the shape of the surface you call.

## Operation labels
Every operation object MUST carry a top-level `"label"`: a concise, plain-English summary shown in the user dashboard and in `ham-ctl cards show`. The user must understand what will happen without reading raw parameters.
```json
{"op": "memory.delete", "label": "Delete obsolete Nix setup memory mem_123", "memory_id": "mem_123"}
```
```json
{"op": "memory.create", "label": "Create consolidated memory for nix develop build flags",
 "title": "Nix build environment and develop flags",
 "body": "Use nix develop -c odin build ... with collection:odin_test=src.",
 "type": "fact", "evidence": "Verified across task_001 and task_002 comments"}
```

## Operation catalog
- `memory.create`: `title`, `body`, `type`, `description`, `evidence`
- `memory.delete` / `memory.archive`: `memory_id`
- `memory.update`: `memory_id`, `title`, `body`, `description`, `evidence`
- `memory.approve`: `memory_id`
- `memory.reject`: `memory_id`
- `task.vote`: `task_id`, `result` (`"lgtm"` / `"ngtm"`), `comment`
- `task_chain.set_status`: `chain_id`, `status` (`"completed"`, `"cancelled"`, `"active"`)
- `project.update`: `project_id`, `name`, `description`
- `agent.prompt`: `instance_id`, `prompt`

Common card types, what to detect and the operations they use:
- **Memory consolidation:** detect duplicate or fragmented memories covering the same topic. One atomic card, `memory.delete` for each duplicate plus one `memory.create` for the single synthesized, comprehensive memory.
- **Stale memory archival:** detect outdated instructions, obsolete tool versions or superseded conventions. `memory.delete` or `memory.archive`, with rationale citing newer activity.
- **Memory re-scoping:** detect memories assigned to inappropriate scopes, for example a repository build rule scoped globally instead of to `project_id`, or an agent-specific habit attached to a project. `memory.update` with corrected scope arrays (`agent_ids`, `project_ids`, `template_ids`, `bridge_ids`).
- **Chain status sync:** detect completed chains where every task is validated and merged but the chain is still `active`; `task_chain.set_status` with `status: "completed"`.
- **Project metadata:** `project.update` for description, conventions or guidelines, based on accumulated tasks.
- **Agent identity and prompt optimization:** `agent.prompt` for prompt refinement or durable agent configuration adjustments.

## Guards
A guard stops a card from applying against stale state. The curator template allows two forms: the full state guard below, or an expiry alone, `{"expires_at": "<ISO timestamp>"}`. The full form carries:
- `target_type`: `"memory"`, `"task"`, `"task_chain"` or `"agent"`;
- `target_id`;
- `field_conditions`: the expected current values, for example `{"status": "active"}`;
- optionally `expires_at` (ISO timestamp, the TTL).

Example: `{"target_type": "memory", "target_id": "mem_123", "field_conditions": {"status": "active"}}`. If live state diverges from the guard, Heimdall discards the card safely instead of applying a stale mutation.

## Confidence criteria for curator cards
Score each card 0.0 to 1.0 on this matrix; emit only High and solid Medium cards.
- **High (>= 0.80)**: direct textual duplication, identical memory titles or bodies, unambiguous chain completion (all tasks validated), or conflicting guidelines with an explicit newer resolution. Emit the card promptly.
- **Medium (0.60 to 0.79)**: plausible consolidation opportunities, minor scope misalignments or inferred stale entries. Emit the card with a thorough rationale and explicit evidence citations.
- **Low (< 0.60)**: ambiguous requirements, subjective style preferences or unconfirmed activity. Do not emit a card; wait for further activity or clearer evidence.
