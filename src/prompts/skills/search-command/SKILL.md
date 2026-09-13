---
name: search-command
description: How to search the Hub for text matches and non-matches — the ham-ctl search CLI and the agent.search RPC, with scopes, typed parent-id filters, negation/exclusion, previews, and cursor paging. Load when you need to find conversations, tasks, comments, memories, artifacts, agents, or skills by text.
---

# Searching the Hub (text match & non-match)

Global entity search runs across every text-bearing scope on the Hub —
conversations, agents, agent instances, task-chains, tasks, comments, projects,
artifacts, memories, and skills. Queries are tokenized and multi-word: `memory leak`
matches `leak in memory`. Results are relevance-ranked (title/name matches rank
above body/description matches) and paged with a cursor.

There are two surfaces for the SAME engine (identical scoping and result shape):

- **`ham-ctl search`** — user-mode CLI (needs a user token). Use it from a shell.
- **`agent.search`** — the agent RPC over your instance token. Use it as an agent;
  the owner is derived from your token, never from the request.

## Owner isolation & skills
- Every result is scoped to the caller's owner: you only ever see your own
  entities. You cannot reach another owner's data by naming its ids.
- **Skills are global** (owner-independent): every caller sees the same skill hits,
  and typed parent-id filters do NOT apply to skills (a skill has no
  task/chain/project/conversation parent). A positive parent-id filter therefore
  excludes skills; a query with only negation filters still returns them.

## 1. ham-ctl search (CLI)

```
ham-ctl search <query> [--scope csv] [typed id filters] [--exclude text] [--limit n] [--json]
```

Auth: `--hub-url` + `--user-token` (or `HAM_HUB_URL` / `HAM_HUB_USER_TOKEN`).

Flags:
- `--scope` — CSV of scopes to search (default: all):
  `conversation,agent,agent_instance,task-chain,task,comment,project,artifact,memory,skill`.
- Typed parent-id filters (CSV; KEEP only rows under the named parent):
  `--task-ids`, `--chain-ids`, `--project-ids`, `--conversation-ids`.
- Negation filters (CSV; DROP rows under the named parent):
  `--not-in-task-ids`, `--not-in-chain-ids`, `--not-in-project-ids`, `--not-in-conversation-ids`.
- `--exclude` — drop hits whose matched text contains this substring (text non-match).
- `--limit` — page size (the server clamps to its max). Human mode auto-pages via
  the cursor and aggregates; `--json` prints the raw first-page envelope, which
  carries `next_cursor` / `has_more` for scripted paging.

Each hit reports which field matched and a `preview` snippet with the match
bracketed, e.g. `…fix the memory [leak] before…`. `matched_field` is one of:
`label` (a primary title/name match — note primary matches are always reported as
`label`, never `title`/`name`), a secondary column like `description` / `slug` /
`instructions`, `body` (a comment body match), `name` or `content` (a skill match),
or `id`. So a title-vs-name distinction is NOT exposed — both surface as `label`.

### Examples

Positive text match (all scopes):
```
ham-ctl search "memory leak"
```

Restrict scopes:
```
ham-ctl search "deploy runbook" --scope task,comment,skill
```

Scope by parent id (only hits under a chain):
```
ham-ctl search zebra --scope task,comment --chain-ids chain_123 --limit 20
```

Under a project but NOT under a chain (typed + negation together):
```
ham-ctl search zebra --project-ids proj_1 --not-in-chain-ids chain_9
```

Exclude a term (text non-match):
```
ham-ctl search timeout --exclude retry
```

Scripted paging with the raw envelope:
```
ham-ctl search zebra --limit 50 --json   # read next_cursor/has_more, then pass --cursor
```

## 2. agent.search (RPC)

As an agent, call the `agent.search` method. The owner is taken from your instance
token; you never pass ids for another owner. The `params` object mirrors the CLI
flags (each id field accepts a JSON string array OR a CSV string):

```json
{
  "method": "agent.search",
  "params": {
    "query": "memory leak",
    "scopes": "task,comment,memory",
    "task_ids": ["task_1", "task_2"],
    "chain_ids": "chain_123",
    "project_ids": [],
    "conversation_ids": [],
    "not_in_task_ids": [],
    "not_in_chain_ids": ["chain_9"],
    "not_in_project_ids": [],
    "not_in_conversation_ids": [],
    "exclude": "retry",
    "limit": 50,
    "cursor": ""
  }
}
```

Field mapping (RPC → meaning):
- `query` — the text to match (tokenized, multi-word).
- `scopes` — CSV/array of resource types to search (same vocabulary as `--scope`).
- `task_ids` / `chain_ids` / `project_ids` / `conversation_ids` — typed parent-id
  filters (keep only rows under the named parent; owner-AND-ed).
- `not_in_task_ids` / `not_in_chain_ids` / `not_in_project_ids` /
  `not_in_conversation_ids` — negation filters (drop rows under the named parent).
- `exclude` — substring text non-match.
- `limit` — page size (server-clamped); `cursor` — page forward with the returned
  `next_cursor` while `has_more` is true.

The response is the same grouped, relevance-ranked hit shape as the REST/CLI path.
Each hit carries `type`, `id`, `label`, `sublabel`, `route`, `score`,
`matched_field`, `preview`, and `parent` (`{id,type}` or null — e.g. a comment's
parent task), with a page envelope (`next_cursor`, `has_more`).

## Non-matching cheat-sheet
- Drop hits containing a term anywhere in the matched text → `--exclude <term>` /
  `"exclude"`.
- Drop hits under a specific parent → `--not-in-*-ids` / `"not_in_*_ids"`.
- Keep ONLY hits under a specific parent → `--*-ids` / the typed `"*_ids"` fields
  (note: this excludes skills, which have no parent).

There is NO `--scope-ids` / `scope_ids` field — that was replaced by the typed
per-parent id filters above. Use the typed filters.
