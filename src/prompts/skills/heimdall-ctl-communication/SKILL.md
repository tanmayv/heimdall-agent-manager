---
name: heimdall-ctl-communication
description: How an agent communicates through Heimdall with ham-ctl — signal readiness at startup (start-success), read your inbox and message history (`chat read`), send to the user or another agent (`chat send --to`), ask grouped questions or quick-reply options (and when those controls expire), and keep user-facing chat separate from technical task comments. Load when communicating through Heimdall: replying to the user, asking the user a question, coordinating agent-to-agent, or reacting to a new-message notification.
---

# Heimdall CLI communication

All commands use the managed wrapper `./bin/ham-ctl` from your run directory. Messages from the user arrive through Heimdall, NOT your terminal: text printed to stdout/stderr is NOT delivered. You MUST use `ham-ctl` to read incoming messages and send replies.

## 1. Startup
Once you are initialized and ready to work, run `./bin/ham-ctl start-success` (idempotent).

## 2. Read
```bash
./bin/ham-ctl chat read                                              # unread messages
./bin/ham-ctl chat read --transcript [--limit N] [--since <timestamp>]   # history
./bin/ham-ctl chat read --include-read [--limit N]                   # include already-read
```

## 3. Send
```bash
./bin/ham-ctl chat send --to user --body "<message>"                    # to the user
./bin/ham-ctl chat send --to <agent-instance-id> --body "<message>"     # agent to agent
```
- `--to` is REQUIRED: `user`, or an exact instance id (`inst_...`), never a display name or slug. `--stdin` reads the body from stdin. `--actions <id,...>` attaches action cards (see `action-cards`).
- ALWAYS report status, answers and completion to the user this way. Keep replies concise, concrete and actionable: what you did or found, exact results (commands run, files/paths, commit hashes), blockers, next steps. Do not dump large raw logs inline.
- `chat set-title` is DEPRECATED: do not call it. Name your work with `task-chain set-title` instead.

## 4. Asking questions
**A set of questions**: send them together as one grouped message.
```bash
./bin/ham-ctl chat send --to user --body "Choose the release settings." --questions-file questions.json
```
`questions.json` is a UTF-8 JSON **object**, not a bare array:
```json
{
  "version": 1,
  "questions": [
    {
      "id": "target",
      "text": "Where should the release go?",
      "selection_mode": "single",
      "options": [{"id": "staging", "label": "Staging"}, {"id": "production", "label": "Production"}]
    },
    {
      "id": "checks",
      "text": "Which checks should run?",
      "selection_mode": "multiple",
      "options": [{"id": "smoke", "label": "Smoke tests"}, {"id": "integration", "label": "Integration tests"}]
    }
  ]
}
```
- Limits: `version` must be `1`; 1–12 questions, each with `id`, nonempty `text` and 1–12 `options` (`id`, nonempty `label`). `selection_mode` is optional: `single` (default) takes one selection, `multiple` one or more. IDs are stable, nonempty, at most 64 ASCII letters, digits, `_` or `-`; question IDs are unique in the group, option IDs unique within a question. Question text is at most 8192 bytes, option labels 2048 bytes, the whole file 256 KiB. Unknown fields are rejected.
- Put plaintext in the file, not vault envelopes: the CLI validates it and vault-encrypts body, `text` and `label` (it fails closed).
- Every question also offers a typed custom answer **instead of** selections; do not add an "Other" option or a custom-label field. Every question requires an answer: selecting an option only updates the draft, and the user submits the whole group once.
- **One simple choice**: `--options "Option A,Option B"` (or repeated `--option`) gives quick-reply chips. Never combine flat options with `--questions-file`; grouped questions are user-only. `--actions` may accompany a group only for unrelated operations.
- **Last-message-only rule**: flat options and grouped-question controls work only while their message is the **LAST durable user-visible message** in that agent conversation. Any newer user or agent message expires them (the content stays readable); agent-to-agent messages do not count. Freshness follows durable insertion order, independent of timestamps, history pagination or synthetic UI rows. Put all related questions in one message and send no follow-ups while waiting for answers.
- **Task approval is not a question.** Use the task review UI, or record the user's explicit verdict with `review post --on-behalf-of user`. It needs no action card. Never treat an answer selection or silence as approval.

### Delivered answers
`chat read` returns a `user_to_agent` message with `message_type: "multi_question_answer"`. `body` is a readable summary; `metadata.multi_question_answer` carries the structure:
```json
{
  "direction": "user_to_agent",
  "message_type": "multi_question_answer",
  "body": "Where should the release go? Staging\nWhich checks should run? Run the full release suite.",
  "metadata": {"multi_question_answer": {
    "version": 1,
    "source_message_id": "msg_source",
    "idempotency_key": "client_generated_uuid_kept_for_retries",
    "answers": [
      {"question_id": "target", "option_ids": ["staging"]},
      {"question_id": "checks", "custom_text": "Run the full release suite."}
    ]
  }}
}
```
- Each question appears exactly once. A custom answer has nonempty `custom_text` and omitted or empty `option_ids`; mixing text and selections is invalid. A `multiple` answer lists several `option_ids`. The CLI decrypts `text`, `label` and `custom_text` as well as the body; the summary wording is illustrative.
- The Hub records one answer per source and delivers one inbox message. On the wire the summary body and custom text are vault-encrypted. A retry with the same `idempotency_key` replays success without a second delivery; a different key after success returns `question_answered` (409); a source superseded by a newer visible message returns `question_stale` (409). Preserve drafts on errors.

## 5. Chat vs task comments
- **Task comments** (`ham-ctl task comment <task-id> --body "..."`): permanent, auditable engineering log on the task: technical progress, test output, diff summaries, review handoffs.
- **Chat** (`ham-ctl chat send --to user|<agent-instance-id> --body "..."`): conversation with the user (answers, confirming intent, milestones, acknowledgements) and peer coordination, including routing questions and blockers to the coordinator.
