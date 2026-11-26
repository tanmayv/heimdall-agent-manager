---
name: ninjy-chain-routing
description: Use as the Ninjy bot before answering a question about a chain, sending a request to a chain's coordinator, or starting a new chain - how to pick the right chain, how to pass work on without disturbing what is running, and when a new chain is the right call.
---

# Ninjy chain routing

Approval rules are in CLAUDE.md/AGENTS.md (“Confirm first”). How to word what you send the user (names instead of IDs, short messages): “Writing replies” in `ninjy-channel-communication`. Cleanup after work ends: `ninjy-chain-hygiene`. Channel replies and chain events: `ninjy-channel-communication`.

## Chains and tasks
- `./bin/ham-ctl task-chain list`, `./bin/ham-ctl task-chain show <chain_id>`, `./bin/ham-ctl task list --chain <chain_id>`, `./bin/ham-ctl task show <task_id>`.
- Keep status answers short: a few lines, then offer detail.

## Pick the chain
1. Read `./bin/ham-ctl task-chain list`. Each chain has `status` (`active`, `completed`, `cancelled`, `archived`), `updated_at`, `project_name`, `task_count`, `completed_task_count` and `user_validation_count` (tasks waiting for the user's review).
2. A chain matches when all of these hold:
   - Same project as the request.
   - Same objective: the request continues, corrects or asks about the work that chain exists for. Read `task-chain show <chain_id>` and `task list --chain <chain_id>` when the title alone does not settle it.
   - `status` is `active`.
3. Prefer the chain the user was just talking about (channel history), then the one with the latest `updated_at`.
4. Check the chain's size before forwarding (next section). Forward only when your confidence meets the bar for that size.
5. One match that clears the bar: use it and name it in your reply. Several candidates, or none that clears the bar: do not guess and do not forward. Propose a new chain (“When a new chain is right”), naming the closest existing chain as the alternative, or list up to five candidates by name and ask which one.

## Chain size sets the bar
A request forwarded into a chain becomes work for its coordinator and competes with everything already planned there. The larger the chain, the more a wrong forward costs, so the more certain you must be that the request belongs to it. Size is `task_count` from `task-chain list`:

| Size | `task_count` | Forward when |
|---|---|---|
| Small | fewer than 5 | Same project and the request plausibly continues the chain's objective |
| Medium | 5 to 14 | Same project, and the request clearly continues or corrects work in that chain: it matches the chain's title or description, or a task in `task list --chain` |
| Large | 15 or more | High confidence only: the user named the chain, or was just discussing it, or the request refers to a specific task, change or result that exists in that chain |

- High confidence means evidence you can point to (the user's words, a task ID or title, the chain's stated objective), not a similar-sounding topic. Say what the evidence is in your brief (“My reading:”).
- Below the bar, do not forward. Create a new chain instead (it still needs the user's go-ahead, “Start a new chain”). When the closest chain is medium or large, say so: “This looks separate from <chain title> (<n> tasks). Start a new chain for it?”
- The bar applies to new work and corrections. A status question never forwards anything (“Do not disturb running work”), so size does not matter for it.
- When the user names the chain, use it whatever its size.

## Do not disturb running work
- **Questions are answered from records.** For “how is it going?”, “did it finish?”, “what is left?”, read `task-chain show`, `task list --chain` and `task show`. Do not message or wake a coordinator to answer a status question. Message it only when the records cannot answer and the user needs the answer.
- **New work is a request, not an interruption.** Ask the coordinator to record it as a new task and to schedule it after the work in progress. Say “urgent” or “stop the current work” only when the user said so, in their quoted words.
- **One chain, one objective.** Never steer a chain to work unrelated to its objective, and never ask a coordinator to drop or rewrite tasks the user did not mention. Unrelated work gets its own chain.
- **A correction to running work** goes to the coordinator of that chain at once, quoted, with the task or change it refers to when the user named one.
- **Respect a stop.** If the user stopped the coordinator earlier (`wake` returns `user_stopped`), ask before starting it.
- **One follow-up.** If a coordinator is silent or blocked, send at most one follow-up, then give the user concrete options. Do not poll.

## When a new chain is right
- No active chain has the same project and objective.
- A chain matches, but your confidence is below the bar for its size (“Chain size sets the bar”).
- The matching chain is `completed`, `cancelled` or `archived`. Offer the choice: a new chain (default), or `./bin/ham-ctl task-chain unarchive <chain_id>` when the user wants to continue an archived one.
- The request is large enough to stand alone (its own plan and review) even though it touches the same project.
- Never start a chain for something one command answers (“Run a command” in `ninjy-bot-operations`).

## Message a chain's coordinator
- Find the chain, then its `coordinator_agent_instance_id` in `./bin/ham-ctl task-chain show <chain_id>`.
- Send the brief with `./bin/ham-ctl chat send --to <coordinator_agent_instance_id> --body "<brief>"`. Start with “From the user via chat:” and put the user's exact words in quotes. Label everything else “My reading:” so nothing reads as something the user said. After the quote, give: the outcome wanted; constraints; relevant context from recent channel history; approvals the user granted and not granted (for example, a plan but not implementation); what to report back. Ask for tasks recorded before work starts, a planning task for new work, and the user's approval before implementation. Add “I will follow progress through chain events.” For an existing chain, adapt the brief to its current work and say where the request fits.
- The answer has a `wake` field:
  - `started`: the coordinator was stopped; Ninjy is starting it and it will read the message when it is up. Tell the user.
  - `not_needed`: it was running and got the message.
  - `user_stopped`: the user stopped it earlier, so it was not started. Tell the user and ask whether to start it; if yes, run `./bin/ham-ctl agents start <coordinator_agent_instance_id>`.
  - `rate_limited` or `failed`: the message is saved but the coordinator was not started. Tell the user.
- Reply with the chain title and say the message was sent.

## Start a new chain
- Work out the project and title. Use `./bin/ham-ctl projects list` and `./bin/ham-ctl projects show <project_id>`; if the project is ambiguous, list up to five candidates by name and ask which one. Ask for a title if it is missing.
- Run `./bin/ham-ctl agents list`. If the user names a coordinator, use that agent. Otherwise, if exactly one agent has `template_id` equal to `tmpl_coordinator`, use it. If several or none match, ask which agent should coordinate, listing up to five agents by name. Never invent a default.
- Resolve the project's path and bridge from `bridge_paths` as in “Servers and preview links” in `ninjy-bot-operations`; ask if placement is ambiguous.
- Send “I am about to start chain <title> in project <name> with coordinator <agent name>. Go ahead?” and stop. Approval works as in “Confirm first” in CLAUDE.md/AGENTS.md.
- Once approved, run `./bin/ham-ctl task-chain create --kind mixed_work --title "<title>" --project <project_id> --coordinator <agent_id> --bridge <bridge_id>`. Find the new chain's `coordinator_agent_instance_id` in the result or `task-chain show <chain_id>`.
- Send the coordinator the brief as in “Message a chain's coordinator” and handle the `wake` result the same way. Reply with the title.
