# Curator Agent: Durable Identity & Scheduled Trigger Integration

The Heimdall **Curator** is an AI-native agent persona (`tmpl_curator`) that periodically reviews project activity (task chains, tasks, comments, conversations, and memories) to emit high-signal, low-risk maintenance recommendations as **Action Cards** (`agent.cards.create`, REQ-CARD-1 / REQ-AGENT-1).

This document explains how to configure the durable Curator agent and trigger it on a recurring schedule using Heimdall's **existing scheduled actions engine** (`src/bridge/action_scheduler.odin`, `domain/action.odin`, `POST /api/v1/actions`) without modifying the scheduler.

---

## 1. Durable Agent Identity (`Curator`)

The Curator agent identity is bound to the system template `tmpl_curator` seeded via migration `035_curator_template.sql`.

### Create Command
```bash
./.heimdall/bin/ham-ctl agents identity create --name Curator --template tmpl_curator
```

### Pre-Seeded Identity
- **Name**: `Curator`
- **Slug**: `Curator`
- **Template**: `tmpl_curator`
- **Agent ID**: `agt_18d54b63432ba200`

---

## 2. Launching a Curator Instance

Before scheduling automated runs, spawn a runtime instance for the Curator agent attached to your target project:

```bash
# Launch a new instance of the Curator agent for your target project
./.heimdall/bin/ham-ctl agents new-instance agt_18d54b63432ba200 --project <project_id>
```

This returns an instance record with `agent_instance_id` (e.g. `inst_curator_01`).

---

## 3. Scheduled Trigger via Existing Actions Engine

Heimdall's bridge daemon runs an automated background ticker (`src/bridge/action_scheduler.odin`) that polls the Hub for scheduled actions. When an action is due:
1. The bridge leases the action from `actions` table (`domain/action.odin`).
2. It sends the prompt to the target instance (`target_instance_id`).
3. It computes the next cron run time (`cron_expr`) and reschedules automatically.

**No changes to the scheduler or bridge are required.**

### API Endpoint & Request Payload
- **Endpoint**: `POST /api/v1/actions`
- **Headers**:
  - `Authorization: Bearer <agent_token_or_user_token>`
  - `Content-Type: application/json`

### Example JSON Payload (Hourly Cron)
```json
{
  "target_instance_id": "inst_curator_01",
  "prompt_text": "Run periodic project curation. Inspect recent task chains, tasks, comments, and memories for this project using read-only commands. Propose high-signal maintenance cards (memory consolidation/deduplication, stale memory archival, memory re-scoping, and chain status synchronization) via agent.cards.create. Strictly adhere to REQ-UX-1: every emitted operation must include a plain-language 'label' string. Include preconditions guards and honest confidence scores.",
  "cron_expr": "0 * * * *",
  "timezone": "UTC"
}
```

### Copy-Pasteable Curl Invocation
```bash
curl -s -X POST "http://localhost:8080/api/v1/actions" \
  -H "Authorization: Bearer ${HEIMDALL_AGENT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "target_instance_id": "inst_curator_01",
    "prompt_text": "Run periodic project curation for this project. Review recent task chains, tasks, comments, and memories. Propose deduplication, archival, or scope fixes as Action Cards via agent.cards.create with explicit guards, honest confidence, and per-operation human-readable labels.",
    "cron_expr": "0 * * * *",
    "timezone": "UTC"
  }'
```

---

## 4. Viewing and Managing Resulting Cards

When the Curator runs, it emits cards via `agent.cards.create`. Users can inspect, show, accept, reject, or discard them:

```bash
# List all pending cards for the project
./.heimdall/bin/ham-ctl cards list --project <project_id>

# Display human-friendly view of a card and its labeled operations (REQ-UX-1)
./.heimdall/bin/ham-ctl cards show <card_id>

# Accept and atomically execute card operations
./.heimdall/bin/ham-ctl cards accept <card_id>

# Reject or discard a card
./.heimdall/bin/ham-ctl cards reject <card_id>
./.heimdall/bin/ham-ctl cards discard <card_id>
```

---

## 5. Architectural Guardrails & Safety
- **Strictly Read-Only Analysis**: The Curator never mutates tasks, chains, memories, or projects directly. All changes are submitted as proposed cards.
- **Human-Friendly Operations (REQ-UX-1)**: Every operation in `operations[]` carries a descriptive `label` property, ensuring transparency in both CLI and Dashboard.
- **Precondition Verification**: The Hub re-evaluates each card's `guard` immediately before execution. If live state has changed or expired, the card is safely discarded without partial mutation.
- **Atomic Unit of Work**: Card operations execute within an atomic transaction rollback boundary.
