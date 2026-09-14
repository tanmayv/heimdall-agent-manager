---
name: heimdall-ctl-communication
description: Use Heimdall CLI for agent startup, chat communication, task coordination, and concise status reporting. Load when communicating through Heimdall or reacting to message notifications.
---

# Heimdall CLI communication

Use the managed Heimdall CLI wrapper from your agent run directory for all Heimdall communication: `./.heimdall/bin/ham-ctl`.

Messages from the user arrive through Heimdall, NOT your terminal. Text printed to stdout/stderr is NOT delivered to the user. You MUST use `ham-ctl` to read incoming messages and to send responses.

## 1. Startup signaling
- Once your agent instance is initialized, dependencies are confirmed, and you are fully ready to work, signal startup readiness:
  `./.heimdall/bin/ham-ctl start-success`

## 2. Reading messages & inbox
- Read unread inbound messages:
  `./.heimdall/bin/ham-ctl chat read`
- Read full history or transcript:
  `./.heimdall/bin/ham-ctl chat read --transcript [--limit N] [--since <timestamp>]`
- Include previously read messages:
  `./.heimdall/bin/ham-ctl chat read --include-read [--limit N]`

## 3. Sending messages
- **To the user**:
  `./.heimdall/bin/ham-ctl chat send --to user --body "<your message>"`
  - ALWAYS communicate status, answers, and completion to the user via this command.
  - Keep replies concise, concrete, and actionable: state what you did/found, exact results (commands run, files/paths, commit hashes), blockers, and next steps. Avoid dumping large raw logs inline.
- **To another agent instance (agent-to-agent)**:
  `./.heimdall/bin/ham-ctl chat send --to <agent-instance-id> --body "<message>"`
  - Use exact instance IDs (e.g. `inst_...`), not display names or slugs.

## 4. Setting conversation title
- Name the current conversation as soon as the goal is established so the user can easily find it in the dashboard:
  `./.heimdall/bin/ham-ctl chat set-title "<concise task summary>"`

## 5. Separation of concerns: Chat vs Task Comments
- **Task Comments** (`ham-ctl task comment <task-id> --body "..."`):
  - Use for technical progress tracking, step-by-step audit trails, test run outputs, code diff summaries, and review handoffs.
  - Permanent, auditable engineering logs attached directly to tasks in the chain.
- **Chat Send** (`ham-ctl chat send --to user|agent-instance-id --body "..."`):
  - Use for direct conversation with the user (answering questions, confirming intent, reporting milestones, acknowledging requests).
  - Use for peer agent coordination and routing questions/blockers to the coordinator.