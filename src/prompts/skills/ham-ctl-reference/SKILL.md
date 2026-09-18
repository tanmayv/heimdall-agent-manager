---
name: ham-ctl-reference
description: Authoritative command reference for the ham-ctl agent CLI — every group (bridge, agents, task-chain, task, chat, memory, artifact, context, start-success) with exact verbs, flags, and valid values. Load whenever you need the precise ham-ctl syntax for a Heimdall action and want to get flags, positional ids, task/chain statuses, vote results, or memory scopes right the first time.
---

# ham-ctl command reference

`ham-ctl` is the agent control CLI for Heimdall. Every command is callable with your
agent token (already configured) via the managed wrapper in your run directory:

```
./.heimdall/bin/ham-ctl <group> <verb> [<positional-id>] [--flags]
```

Conventions used below:
- `<id>` positional args come right after the verb; most commands need only the
  positional id (task/chain ids are globally unique, so `--chain` is usually optional).
- Each command prints a single JSON response line.
- Run `./.heimdall/bin/ham-ctl <group> --help` for the built-in reference of any group;
  `./.heimdall/bin/ham-ctl --help` lists all groups.

Groups: `bridge`, `agents`, `task-chain`, `task`, `chat`, `memory`, `artifact`,
`shell-cmd`, `context`, `start-success`.

---

## bridge — discover bridges and their providers
- `bridge list [--scope hub|configured|all]` — bridges you can target. Default `all` =
  Hub-registered + locally-configured peers + this host (self).
- `bridge providers [--bridge <id>]` — providers (and tiers) for one bridge, or all.

## agents — durable identities, templates, and runtime instances
- `agents list` — your durable agent identities.
- `agents identity create --name <n> [--template <id>] [--provider <p>] [--tier <t>] [--slug <s>] [--instructions <t>]` — create a durable agent.
- `agents template list` — list agent templates (personas).
- `agents template create --name <n> [--description <d>] [--persona <t>] [--instructions <t>]` — create a template.
- `agents instance list [--agent <id>] [--live]` — list instances (durable, or only live with `--live`).
- `agents new-instance <agent-id> [--project <id>] [--bridge <id>] [--provider <p>] [--tier <t>] [--chain <id>]` — launch a NEW instance of a durable agent.
- `agents start <instance-id>` — start a STOPPED instance (errors if already running).
- `agents stop <instance-id> [--reason <t>]` — stop a running instance.
- `agents restart <instance-id>` — restart (stop-then-start) an instance.

## task-chain — your task chains
- `task-chain list [--mine] [--project <id>]` — chains (`--mine` = ones you coordinate).
- `task-chain show [<chain-id>]` — show a chain (defaults to your current chain).
- `task-chain set-title <title> [--chain <id>]` — rename a chain (coordinator only).
- `task-chain set-description <text> [--chain <id>]` (or `--stdin`) — set the chain
  description (coordinator only; pass `""` to clear; `--chain` defaults to your chain).
- `task-chain set-status --status <active|completed|cancelled> [--chain <id>]` — change
  the chain status (coordinator only). Chain statuses are exactly `active`, `completed`,
  `cancelled`. This is how a coordinator completes a chain.
- `task-chain reconcile <chain-id>` — self-heal / kick off a chain: promote actionable
  tasks, set each agent's current task, and nudge idle agents. **The chain id is REQUIRED**
  (positional, or `--chain <id>`; with neither it just prints help). Coordinator/owner only,
  idempotent. See the `coordinator-task-management` skill for when to run it.

## task — tasks within a chain
A positional `<task-id>` identifies the task and is enough on its own (task ids are
globally unique — you rarely need `--chain`).

- `task list [--chain <id>]` — your chain's tasks. Each carries a `comment_summary`
  (count, last_comment_at, author, preview) — NOT full comment bodies.
- `task show <task-id> [--chain <id>]` — a task + its `comment_summary` + votes (no bodies).
- `task comments <task-id> [--last N]` — fetch comment BODIES; `--last N` = newest N (max 100).
- `task create --title <t> [--description <d>] [--priority p0|p1|p2] [--assignee <instance-id>] [--reviewer <id,id,...>] [--depends-on <id,id>] [--chain <id>]` — create a task.
  `--reviewer` and `--depends-on` accept comma-separated lists.
- `task update <task-id> [--title <t>] [--description <d>] [--priority p0|p1|p2] [--assignee <instance-id>] [--reviewer <id,id,...>] [--depends-on <id,id>]` — edit an
  existing task (coordinator only). Only the fields you pass change; `--reviewer` and
  `--depends-on` REPLACE the whole list (pass `""` to clear).
- `task comment <task-id> --body <t>` (or `--stdin`) `[--notify <id,id>]` — add a comment
  (the only way to comment).
- `task status <task-id> --status <s>` — change status. Use `in_validation` to submit for
  review. **There is no `done` verb.**
- `task vote <task-id> --result <lgtm|ngtm> [--comment <t>]` — cast a review vote (the only
  way to vote). `--result` must be exactly `lgtm` or `ngtm`.
- `task nudge <task-id> [--message <t>]` — nudge the task's owner.
- `task set-current <task-id>` — mark this as your current task.
- `task depend <task-id> --on <task-id>` — add a single dependency (`update --depends-on`
  replaces the whole list).

### Task statuses (the only valid `--status` values)
`assigned`, `queued`, `in_progress`, `in_validation`, `validated_good`,
`validated_not_good`, `paused`, `completed`, `cancelled`.

**There is no `approved` status and no explicit approve/complete-task verb.** Approval is
IMPLICIT: when a task is `in_validation` and its required reviewers reach an LGTM quorum
with no `ngtm`, the Hub auto-finalizes the task straight to `completed` (that is also the
only outcome that unblocks dependents — `validated_good` does not). A single `ngtm` moves
it to `validated_not_good` for rework. So the assignee's job is `--status in_validation`;
the reviewer's job is `--result lgtm|ngtm`; completion happens on its own.

## chat — inbox, sending, and this conversation's title
- `chat read [--limit N] [--since T] [--include-read] [--transcript]` — read messages.
- `chat send --to <user|agent-instance-id> --body <t>` (or `--stdin`) — send a message.
  `--to` is REQUIRED: `user` for the bound user, or an exact agent-instance-id for
  agent-to-agent.
- `chat set-title <title>` — rename THIS conversation (the chat thread shown in the UI).
  Distinct from `task-chain set-title`, which renames the chain board.

## shell-cmd — run a shell command on your local Bridge host
- `shell-cmd exec --cmd <command> [--cwd <dir>]` — run a shell command locally on the
  Bridge. Runs synchronously if it finishes in <15s (the response carries `status`,
  `exit_code`, `output`, and `exec_id`); if it runs >=15s it switches to async and
  returns immediately with `status:"running"` and an `exec_id` (see below).
  - `--cwd <dir>` — working directory for the command; a leading `~` is expanded and
    the directory must exist. If omitted, the command inherits the Bridge service's
    working directory (typically `$HOME`), NOT the project — so for build/test either
    pass `--cwd <project-dir>` or prefix the command with `cd <project-dir> &&`.
  - The command runs via `sh -c` with no interactive stdin, so it must be
    non-interactive (a command that waits for input will block until it is killed).
- `shell-cmd read <exec-id> [--offset <N>] [--limit <N>] [--grep <pattern>]` — fetch
  the status/output of a previously submitted exec (works while it is still running).
  - Default (no flags) returns the last 100 lines (tail), matching `exec`.
  - `--offset <N>` skips the first N lines of the output (0-indexed; default 0).
  - `--limit <N>` returns at most N lines (default 100).
  - `--grep <pattern>` returns only lines containing `<pattern>`, each prefixed with
    its original line number. Combine with `--offset`/`--limit` to page the matches.

### Async model + output truncation
- A command running >=15s returns right away with `status:"running"` and an `exec_id`;
  the Bridge keeps running it in the background and the Hub posts a chat notification
  to your conversation when it finishes. Retrieve the output any time with
  `shell-cmd read <exec_id>`.
- Output longer than 200 lines is truncated to the last 100 lines by default, with
  `truncated:true` in the response. The full, untruncated output is always on the
  Bridge filesystem at the `raw_output_location` path in the response — reach earlier
  lines with `shell-cmd read <id> --offset/--limit/--grep`.

## memory — durable memories
- `memory list [--agent-ids <id,...>] [--project-ids <id,...>] [--bridge-ids <id,...>] [--template-ids <id,...>] [--status <s>] [--type <t>] [--limit <n>]` — list memories (metadata only).
- `memory show <memory-id>` — full memory details (body + evidence).
- `memory content <memory-id>` — print the raw memory body.
- `memory propose --type <t> --title <t> [--description <t>] [--body <t>] [--evidence <t>] [--agent-ids <id,...>] [--project-ids <id,...>] [--bridge-ids <id,...>] [--template-ids <id,...>]` — propose a durable memory.

### Memory scope (FOUR dimensions — there is no `--scope` word-flag)
Scope is set by four id-list dimensions, each accepting singular/plural spellings and
either repeated flags or comma-separated values:

| Dimension | Accepted flag spellings |
|-----------|-------------------------|
| agent     | `--agent-id` / `--agent-ids` / `--agent` / `--agents` |
| project   | `--project-id` / `--project-ids` / `--project` / `--projects` |
| bridge    | `--bridge-id` / `--bridge-ids` / `--bridge` / `--bridges` |
| template  | `--template-id` / `--template-ids` / `--template` / `--templates` |

An OMITTED dimension applies broadly (to all); the agent dimension defaults to the
caller's own agent. "Global" scope = omit the scope flags. Repeatable or comma-separated:
`--project-ids proj_1,proj_2` and `--project proj_1 --project proj_2` are equivalent.

## context — instance snapshot
- `context` — one-shot snapshot of this instance: chain, current task, and unread counts.
  Takes no arguments.

## start-success — startup signal
- `start-success` — signal this instance is ready. Run once at startup; idempotent.
