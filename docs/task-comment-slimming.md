# Task fetch: comment summary + separate comment fetch

Status: **PROPOSAL — API first, implement after confirmation**

## Problem

Fetching tasks ships every comment body on every task. Concretely:

- `GET /api/v1/task-chains/{chain}/tasks` (agent `task list`) calls
  `write_task_detail_json` per task, which embeds the FULL `comments` array
  (every `comment_id`, `author`, `body`, timestamps) AND the full `votes` array.
- `GET .../tasks/{task}` (agent `task show`) does the same.
- The agent `context` snapshot embeds the current task via
  `write_agent_current_task_json` (need to confirm whether it includes comments;
  it should follow the same rule).

So a chain with N tasks × M comments sends N×M comment bodies just to list
tasks. Agents rarely need every historical comment to decide what to do next —
they need to know a task HAS new discussion and how recent it is.

## Proposed API (for confirmation)

### 1. Task objects carry a comment SUMMARY, not the full array

In `write_task_detail_json` (used by `task list`, `task show`, `task create`,
and the agent context current-task), replace the embedded `comments: [...]`
array with a compact summary:

```jsonc
{
  "task_id": "...",
  "title": "...",
  "status": "in_progress",
  // ...existing fields...
  "comment_summary": {
    "count": 7,                          // total comments on the task
    "last_comment_at": "2026-09-04T17:08:23Z",  // "" if none
    "last_comment_author_agent_instance_id": "inst_...", // "" if none
    "last_comment_preview": "pushed fix, tests gr…"      // first ~80 chars, optional
  }
  // "comments" is NO LONGER embedded here
}
```

- `count` + `last_comment_at` are the load-bearing signals (the user's ask).
- `last_comment_author` and a short `last_comment_preview` are cheap and make
  the summary actionable without a second call. (Confirm if you want the
  preview; dropping it makes the summary purely counters+timestamp.)
- `votes` stays as-is (small, bounded by reviewer count) unless you want it
  summarized too — flagged as an open question below.

### 2. Separate command to fetch the last N comments

A dedicated fetch that returns only the tail of the comment thread:

- Wire: `agent.task.comments { task_id, chain_id?, last?: N }`
- Bridge route: `GET /api/v1/task-chains/{chain}/tasks/{task}/comments?last=N`
  (the comments endpoint already exists; add a `last` query param that returns
  the newest N by `created_at`, default e.g. 20, max e.g. 100).
- CLI: `ham-ctl task comments <task-id> [--last N] [--chain <id>]`

Response is the existing comment array shape, just bounded:

```jsonc
{ "task_id": "...", "count": 7, "returned": 5, "comments": [ /* newest N */ ] }
```

So the agent flow becomes:
1. `task list` / `task show` → sees `comment_summary.count` grew or
   `last_comment_at` is newer than what it acted on.
2. `task comments <id> --last 5` → pulls just the recent thread it needs.

### 3. `task show` behavior

Two options — please pick:

- **(A) `show` is also slim** (summary only), and `task comments` is the ONLY
  way to get bodies. Most consistent with "don't send data unless asked".
- **(B) `show` keeps full comments** (it's an explicit single-task fetch, so the
  payload is one task), while `list` and `context` use the summary.

Proposal: **(A)** — one rule everywhere; `show` gives the task + summary + votes,
and `comments --last N` gives the thread. Keeps every task-returning path cheap.

## Hub changes

- `domain`/service: add a cheap `count_task_comments` + `last_task_comment`
  (or derive from the existing `list_task_comments` result: `len` +
  `comments[len-1]`) so the summary needs no extra query cost beyond what the
  list already does. Better: a repo `task_comment_summary(task_id)` returning
  `(count, last_created_at, last_author, last_preview)` via one SQL
  `SELECT COUNT(*), MAX(created_at) ...` so `list_tasks` doesn't load bodies.
- `write_task_detail_json`: emit `comment_summary`, drop `comments`.
- `list_task_comments_handler`: honor `?last=N` (newest N, default/max bounds).
- Add `agent.task.comments` to the bridge route table + allowlist and the
  `ham-ctl task comments` verb + help.

## UI impact (must update, not optional)

`TaskChainOverview.tsx:1026` maps `task.comments`, and
`src/ui/api/endpoints/tasks.ts:31` normalizes `task.comments`. With the slim
change, the chain/task list no longer carries bodies. The UI already has a
dedicated comments fetch (`fetchTaskLog`/comment endpoints at tasks.ts:370+), so
the task list would render `comment_summary.count` + `last_comment_at` and lazy
-load the thread on expand via `task comments`. Confirm you're OK updating the
UI list to summary + on-demand thread.

## Open questions (need your call)

1. **Preview field**: include `last_comment_preview` (~80 chars) in the summary,
   or counters + timestamp + author only?
2. **`show` payload**: option (A) slim everywhere, or (B) `show` keeps full
   comments? (Proposal: A.)
3. **Votes**: leave `votes` embedded (bounded by reviewer count), or also move
   behind a summary/fetch? (Proposal: leave embedded.)
4. **`--last` defaults**: default N and max cap for `task comments` (proposal:
   default 20, max 100; `--last 0` or a `--all` flag to get everything).
5. **Field names**: `comment_summary.{count,last_comment_at,
   last_comment_author_agent_instance_id,last_comment_preview}` OK, or shorter
   (`comments_count`, `last_comment_at`) as flat task fields instead of a nested
   object?
