---
name: ninjy-automations
description: Use as the Ninjy bot when the user wants something to happen on a schedule or when a chain event occurs, asks for a daily brief, asks why a rule did or did not fire, or keeps asking you for the same thing - how to design, test, debug and retire automation rules.
---

# Ninjy automations

An automation is a rule: one or more triggers plus a prompt delivered to a target (by default you, the bot) as an action message. Full syntax, filter operators and limits: `ham-ctl-reference`, “automations — event and cron rules”; webhooks: its “Agent webhook management”. How you answer an action message when it arrives: `ninjy-channel-communication`, “Action messages”. Action cards are separate (`action-cards`).

## Before you create anything
1. **Look first.** `./bin/ham-ctl automations list`, then `show <id>` for anything similar. Change an existing rule instead of adding a second one for the same purpose.
2. **Say what it will do and ask.** One message: what triggers it, when (time and timezone), what the user will receive and how often. Ask “Go ahead?” and wait. Ask for the timezone if you do not know it; never assume UTC for a person.
3. **Create one rule per purpose**, with a `--name` the user would recognise.
4. **Tell the user it is set**, by its name, and that they can ask you to change or stop it.
- Create rules only at the user's request or after they accepted your offer. Delete only when requested: `./bin/ham-ctl automations delete <id>`. To pause, `./bin/ham-ctl automations update <id> --disable`.

## Choose the trigger
| The user wants | Trigger |
|---|---|
| Something at a time of day or on weekdays | `cron:<5-field expression>@<IANA timezone>`, e.g. `cron:0 9 * * 1-5@Asia/Kolkata` |
| Something every N seconds | `every:<seconds>` (use cron for anything a person reads) |
| Something once | `at:<RFC3339>` |
| A reaction to a chain event | `event:<type>[,<field>=<op>:<value>]...`, with `--entity <chain_id>` to limit it to one chain |

- `./bin/ham-ctl automations trigger-types` lists the event types, their fields, operators and allowed values. Read it before writing an event filter; do not guess field names.
- `--delay <seconds|Ns|Nm|Nh>` (after the trigger it applies to) waits before delivering, so a burst settles first. `--min-interval <seconds>` on the rule stops it firing more often than that.
- Bot default: `./bin/ham-ctl automations create --prompt "<text>" --target bot --trigger "cron:0 9 * * 1-5@Asia/Kolkata"`. Explicit `--bot <id>`, `--instance <id>` or `--agent-id <id>` select another owned target.
- Event example: `--trigger "event:chain.state,state=eq:completed" --entity <chain_id> --delay 30`. Do not send the removed data map/chain_id.
- An automation can wake an agent the user stopped. Say so when the target is not you.

## Test an event filter before enabling
- Write the filter and a sample event to files in your working directory, then run `./bin/ham-ctl automations filter-test --event-type <type> --filter-file <path> --event-file <path>`. It evaluates without emitting or storing anything.
- Test one event that must match and one that must not. Create the rule only when both behave.

## Write the prompt
The prompt is what you (or another agent) will read later with no memory of this conversation. Make it complete:
- What to read (exact commands), what to send, and to whom.
- **One message.** Lead with what needs the user. Chain title on each line, no IDs, worded as in “Writing replies” in `ninjy-channel-communication`.
- **Silent when there is nothing to say**: tell the prompt to send nothing (or one fixed line the user asked for) when nothing matched.
- Chain titles cannot be templated: the prompt must fetch them with `task-chain show <chain_id>`.
- No approvals inside a prompt: an automation never authorizes a command, a cleanup or a new chain. It may only read, report and offer.

## When a rule misbehaves
- `./bin/ham-ctl automations runs <id>` shows what fired. Each run records the trigger revision it matched: compare it with the current revision first. If they differ, the rule was edited after that run, so the run explains the old rule.
- Fired but nothing useful arrived: the prompt is the problem. Did not fire: the trigger or filter is; re-run `filter-test` with a real event.
- Fix with `./bin/ham-ctl automations update <id> ...`. Any trigger flag replaces the whole trigger list and any target flag replaces the whole target, so restate every trigger you want to keep.

## Offer an automation
- When the user asks you for the same report or check a third time, offer once to schedule it. Record the answer as a memory (“Your own memory” in `ninjy-bot-operations`) so you do not offer it again after a no.
- Suggest, never create unprompted.

## Recipes

### Daily brief
- Only when the user asks for a daily or morning brief. Never create it unprompted.
- Confirm first, as for any automation: say the time, timezone (ask if unknown) and that it sends one message a day, then wait for a yes. Then create one rule:
  `./bin/ham-ctl automations create --target bot --trigger "cron:0 8 * * *@<user timezone>" --prompt "<the brief prompt below>"`
- The brief prompt tells the bot to read `./bin/ham-ctl task-chain list`, then `task-chain show <chain_id>` and `task list --chain <chain_id>` for each active chain, and send ONE plain-text message with these sections, in this order:
  1. Needs you: chains with a task waiting for the user's review, and chains blocked on the user (a task `blocked_on` human).
  2. Finished or failed since the last brief.
  3. Still running.
- Each line: chain title, plus one short clause (what is waiting, or the outcome). At most a few lines per section; if a section has more, give the count and the first few.
- Lead with section 1. If it is empty, the message starts with "Nothing needs you." Omit empty sections other than that line.
- To change or stop it: `./bin/ham-ctl automations update <id> --prompt "<text>"` or `--disable`; delete only when asked.

### Hygiene sweep
- The recurring check for stale chains and things needing attention. What it looks for and what it may do: `ninjy-chain-hygiene`, “The sweep”. Offer it once as described there; create it only after a yes:
  `./bin/ham-ctl automations create --name "Hygiene sweep" --target bot --trigger "cron:0 9 * * *@<user timezone>" --prompt "Run the sweep in ninjy-chain-hygiene and send its one message. Send nothing if nothing needs the user."`

### Failure alert for one chain
- `./bin/ham-ctl automations create --name "Failure alert: <chain title>" --target bot --trigger "event:chain.state,state=eq:failed" --entity <chain_id> --prompt "Chain {{event.entity.id}} failed. Fetch its title and the failed task, and tell the user what failed and the options."`
- Check the `state` values with `trigger-types` first. You already receive failures for chains you watch (`ninjy-channel-communication`, “Chain events”); use this for a chain you do not watch.

### Review-waiting reminder
- For a user who wants a nudge about reviews they owe: a cron rule whose prompt reads `task-chain list`, keeps chains with `user_validation_count` above zero, and sends one message listing them, or nothing when there are none.
