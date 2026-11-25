---
name: search-command
description: How to search the Hub for text matches and non-matches — the `ham-ctl search` CLI and the `agent.search` RPC, with scopes, typed parent-id filters, negation/exclusion, previews and cursor paging — across conversations, tasks, comments, chains, memories, artifacts, agents and skills. Load before searching the Hub, or when authoring tasks that need prior context.
---

# Searching the Hub

Global entity search covers every text-bearing scope: conversations, agents, agent instances, task-chains, tasks, comments, projects, artifacts, memories and skills. Queries are tokenized and multi-word (`memory leak` matches `leak in memory`). Results are relevance-ranked (title/name matches above body/description matches) and paged with a cursor.

Two surfaces run the SAME engine (identical scoping and result shape):
- **`ham-ctl search`**: user-mode CLI (needs a user token); use it from a shell.
- **`agent.search`**: the agent RPC over your instance token; the owner is derived from the token, never from the request.

**Owner isolation and skills.** Every result is scoped to the caller's owner; you cannot reach another owner's data by naming its ids. **Skills are global** (owner-independent) and have no task/chain/project/conversation parent, so typed parent-id filters do NOT apply to them: a positive parent-id filter excludes skills, while a query with only negation filters still returns them.

## Parameters (CLI flag / RPC field)
| CLI | RPC | Meaning |
|---|---|---|
| `<query>` | `query` | text to match |
| `--scope csv` | `scopes` (CSV or array) | scopes to search, default all: `conversation,agent,agent_instance,task-chain,task,comment,project,artifact,memory,skill` |
| `--task-ids` `--chain-ids` `--project-ids` `--conversation-ids` | `task_ids` `chain_ids` `project_ids` `conversation_ids` | KEEP only rows under the named parent, owner-AND-ed (CSV; RPC accepts a JSON string array or a CSV string) |
| `--not-in-task-ids` `--not-in-chain-ids` `--not-in-project-ids` `--not-in-conversation-ids` | `not_in_task_ids` `not_in_chain_ids` `not_in_project_ids` `not_in_conversation_ids` | DROP rows under the named parent (also owner-AND-ed) |
| `--exclude text` | `exclude` | drop hits whose matched text contains this substring |
| `--limit n` | `limit` | page size (server-clamped) |
| `--cursor` | `cursor` | page forward with the returned `next_cursor` while `has_more` is true |
| `--json` | (none) | CLI only: print the raw first-page envelope (with `next_cursor` / `has_more`) instead of auto-paging |

There is NO `--scope-ids` / `scope_ids`: use the typed per-parent filters.

- CLI usage: `ham-ctl search <query> [--scope csv] [typed id filters] [--exclude text] [--limit n] [--json]`. Auth: `--hub-url` + `--user-token` (or `HAM_HUB_URL` / `HAM_HUB_USER_TOKEN`). Human mode auto-pages and aggregates; `--json` prints the raw first-page envelope (with `next_cursor` / `has_more`) for scripted paging.
- RPC: `{"method": "agent.search", "params": {"query": "memory leak", "scopes": "task,comment,memory", "task_ids": ["task_1"], "chain_ids": "chain_123", "not_in_chain_ids": ["chain_9"], "exclude": "retry", "limit": 50, "cursor": ""}}`. Omit or leave empty the fields you do not need: the handler reads each missing key as empty (`agent_action_csv_field` in `src/hub/transport/http/agent_action_handlers.odin` falls back to empty), and `ham-ctl` itself sends only the non-empty ones (`src/ctl/agent_mode.odin`).

## Examples (CLI; the RPC takes the same values)
```bash
ham-ctl search "memory leak"                                              # all scopes
ham-ctl search "deploy runbook" --scope task,comment,skill                # restrict scopes
ham-ctl search zebra --scope task,comment --chain-ids chain_123 --limit 20   # only under a chain
ham-ctl search zebra --project-ids proj_1 --not-in-chain-ids chain_9      # under a project but NOT a chain
ham-ctl search timeout --exclude retry                                    # text non-match
ham-ctl search zebra --limit 50 --json    # read next_cursor/has_more, then pass --cursor
```

## Results
Each hit carries `type`, `id`, `label`, `sublabel`, `route`, `score`, `matched_field`, `preview` (the match bracketed, e.g. `…fix the memory [leak] before…`) and `parent` (`{id,type}` or null, e.g. a comment's parent task), inside a page envelope (`next_cursor`, `has_more`). `matched_field` is `label` (any primary title/name match: a title-vs-name distinction is NOT exposed), a secondary column such as `description`, `slug` or `instructions`, `body` (a comment body), `name` or `content` (a skill), or `id`.

## Non-matching cheat-sheet
- Drop hits containing a term anywhere in the matched text: `--exclude <term>` / `"exclude"`.
- Drop hits under a specific parent: `--not-in-*-ids` / `"not_in_*_ids"`.
- Keep ONLY hits under a specific parent: `--*-ids` / `"*_ids"` (this excludes skills).
