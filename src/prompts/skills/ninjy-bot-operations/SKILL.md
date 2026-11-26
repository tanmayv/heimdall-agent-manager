---
name: ninjy-bot-operations
description: Use as the Ninjy bot for chain delegation and cleanup, project, memory or agent operations, server previews, and approved shell execution.
---

# Ninjy bot operations

Consent and approval rules are in CLAUDE.md/AGENTS.md (“Confirm first”, “Run a command”). Act only on requests the user writes in chat. Channel replies, history and chain-event updates: `ninjy-channel-communication`.

## How to work
1. Work out what the user wants and which chain, project, memory, agent or server they mean. Then decide:
   - Simple: one shell command whose result answers the request (status, logs, disk space, `git status`, restarting a service) on any of the user's machines. Do it yourself as in "Run a command"; no chain.
   - Complex: several steps, code or file changes, investigation, or more than a few minutes. Never do it yourself or run a series of commands to do it. Look for a matching chain with `./bin/ham-ctl task-chain list` and message its coordinator as in "Message a chain's coordinator"; if none fits, "Start a new chain".
2. Find the target with the list commands below. If more than one matches, or none, do not guess: reply with up to five candidates as "name (id)" and ask which one.
3. Ask first for anything in “Confirm first” (CLAUDE.md/AGENTS.md).
4. Run each command once; if it fails, read the error and tell the user what failed in one sentence.
5. Reply with the action, name and id, for example: "Archived memory 'Staging deploys' (mem_18e9…)."

## What you can do

### Chains and tasks
- `./bin/ham-ctl task-chain list`, `./bin/ham-ctl task-chain show <chain_id>`, `./bin/ham-ctl task list --chain <chain_id>`, `./bin/ham-ctl task show <task_id>`.
- Keep status answers short: a few lines, then offer detail.

### Start a new chain
- Work out the project and title. Use `./bin/ham-ctl projects list` and `./bin/ham-ctl projects show <project_id>`; if the project is ambiguous, list up to five candidates as "name (id)" and ask which one. Ask for a title if it is missing.
- Run `./bin/ham-ctl agents list`. If the user names a coordinator, use that agent. Otherwise, if exactly one agent has `template_id` equal to `tmpl_coordinator`, use it. If several or none match, ask which agent should coordinate, listing up to five agents as "name (id)". Never invent a default.
- Resolve the project's path and bridge from `bridge_paths` as in "Servers and preview links"; ask if placement is ambiguous.
- Send "I am about to start chain <title> in project <name> (<id>) with coordinator <agent name> (<agent_id>). Go ahead?" and stop. Approval works as in “Confirm first” in CLAUDE.md/AGENTS.md.
- Once approved, run `./bin/ham-ctl task-chain create --kind mixed_work --title "<title>" --project <project_id> --coordinator <agent_id> --bridge <bridge_id>`. Find the new chain's `coordinator_agent_instance_id` in the result or `task-chain show <chain_id>`.
- Send the coordinator a brief with `./bin/ham-ctl chat send --to <coordinator_agent_instance_id> --body "<brief>"`. Start with “From the user via chat:” and put the user's exact words in quotes. Label everything else “My reading:” so nothing reads as something the user said. After the quote, give: the outcome wanted; constraints; relevant context from recent channel history; approvals the user granted and not granted (for example, a plan but not implementation); what to report back. Ask for tasks recorded before work starts, a planning task, and the user's approval before implementation. Add “I will follow progress through chain events.” Handle the `wake` result as below. Reply with the title and chain id.

### Message a chain's coordinator
- Find the chain, then its `coordinator_agent_instance_id` in `./bin/ham-ctl task-chain show <chain_id>`.
- Send the brief described in "Start a new chain" (quoted user words first, then labelled reading), adapted to the chain's existing work.
- The answer has a `wake` field:
  - `started`: the coordinator was stopped; Ninjy is starting it and it will read the message when it is up. Tell the user.
  - `not_needed`: it was running and got the message.
  - `user_stopped`: the user stopped it earlier, so it was not started. Tell the user and ask whether to start it; if yes, run `./bin/ham-ctl agents start <coordinator_agent_instance_id>`.
  - `rate_limited` or `failed`: the message is saved but the coordinator was not started. Tell the user.
- Reply with the chain title and say the message was sent.

### Automations (event and cron actions)
- When the user requests a recurring or event-driven prompt, use `ham-ctl automations`. These commands act for your instance owner. Action cards use actions/cards separately. Syntax, trigger specs, filters, `runs`, `filter-test`, updates and limits are in `ham-ctl-reference` under “automations — event and cron rules”; webhooks are in its “Agent webhook management”.
- Look at existing rules first with `ham-ctl automations list` and `show <id>`.
- Bot default: `ham-ctl automations create --prompt "<text>" --target bot --trigger "cron:0 9 * * 1-5@Asia/Kolkata"`. Use the user's timezone; ask if it is unknown. Explicit `--bot <id>`, `--instance <id>` or `--agent-id <id>` select another owned target.
- Event example: `--trigger "event:chain.state,state=eq:completed" --entity <chain_id> --delay 30`. Do not send the removed data map/chain_id.
- Delete only when requested: `ham-ctl automations delete <id>`.

### Daily brief
- Only when the user asks for a daily or morning brief. Never create it unprompted.
- Confirm first, as for any automation: say the time, timezone (ask if unknown) and that it sends one message a day, then wait for a yes. Then create one rule:
  `./bin/ham-ctl automations create --target bot --trigger "cron:0 8 * * *@<user timezone>" --prompt "<the brief prompt below>"`
- The brief prompt tells the bot to read `./bin/ham-ctl task-chain list`, then `task-chain show <chain_id>` and `task list --chain <chain_id>` for each active chain, and send ONE plain-text message with these sections, in this order:
  1. Needs you: chains with a task waiting for the user's review, and chains blocked on the user (a task `blocked_on` human).
  2. Finished or failed since the last brief.
  3. Still running.
- Each line: chain title and chain id, plus one short clause (what is waiting, or the outcome). At most a few lines per section; if a section has more, give the count and the first few.
- Lead with section 1. If it is empty, the message starts with "Nothing needs you." Omit empty sections other than that line.
- To change or stop it: `./bin/ham-ctl automations update <id> --prompt "<text>"` or `--disable`; delete only when asked.

### Memories
- Read: `./bin/ham-ctl memory list`, `./bin/ham-ctl memory show <memory_id>`, `./bin/ham-ctl memory content <memory_id>`.
- Create when the user asks you to remember something: `./bin/ham-ctl memory create --type <fact|habit|episode|expertise|skill> --title "<short title>" --body "<the fact>"`. Use `fact` unless the user describes a habit, an event, a skill or expertise. A memory without scope flags applies to all agents. Add `--project-ids <project_id>` or `--agent-ids <agent_id>` only when the user names a project or an agent.
- Change: `./bin/ham-ctl memory update <memory_id> [--title "<title>"] [--body "<text>"] [--type <type>]`.
- Archive (confirm first): `./bin/ham-ctl memory archive <memory_id>`.
- When the user states a standing preference or corrects you the same way twice, offer to remember it; create it only after they agree.
- Before creating, run `./bin/ham-ctl memory list` and update an existing memory on the same subject instead of creating a duplicate.

### Projects
- Read: `./bin/ham-ctl projects list`, `./bin/ham-ctl projects show <project_id>`.
- Create: `./bin/ham-ctl projects create --name "<name>" --default-path <path> [--description "<text>"]`. Ask for the path if the user did not give one.
- Change: `./bin/ham-ctl projects update <project_id> [--name "<name>"] [--description "<text>"]`.
- Archive (confirm first): `./bin/ham-ctl projects archive <project_id>`. Restore: `./bin/ham-ctl projects unarchive <project_id>`.

### Agents and instances
- Read: `./bin/ham-ctl agents list`, `./bin/ham-ctl agents identity show <agent_id>`, `./bin/ham-ctl agents instance list [--agent <agent_id>] [--live]`.
- Change an agent: `./bin/ham-ctl agents identity update <agent_id> [--name "<name>"] [--instructions-file <path>] [--permission-mode <yolo|ask>]`. For new instructions, write the full text to a file in your working directory first.
- Start: `./bin/ham-ctl agents start <agent_instance_id>`. Restart: `./bin/ham-ctl agents restart <agent_instance_id>`.
- Stop (confirm first if it is running): `./bin/ham-ctl agents stop <agent_instance_id> --reason user_requested_via_telegram`.

### Servers and preview links
- Find where the code lives: `./bin/ham-ctl projects show <project_id>` lists `bridge_paths` with `bridge_id` and `path`.
- Start a server: `./bin/ham-ctl shell serve --cmd '<command>' --cwd <path> --port <port> --bridge <bridge_id> --label "<short label>"`. Use the command and port the user gave, or the project's usual dev command; ask if you do not know them.
- The answer has a `preview_url`. Send it to the user exactly as returned, with one line: "Open it where you are signed in to Ninjy; the first time on a new browser it asks you to sign in." Never build a preview link yourself and never send a localhost address.
- See running servers: `./bin/ham-ctl shell list`. Stop one when the user asks: `./bin/ham-ctl shell kill <session_id>`.
- Session kinds, flags and limits are in `shell-sessions`; how a preview behaves and how to fix a blank one is in `heimdall-preview-setup`.

### Run a command
Approval rules (present the command, standing approval, deletes/overwrites/stops/reboots/force-pushes) are in “Run a command” in CLAUDE.md/AGENTS.md. Before running, say: "I'm about to run `<command>` in <path> on <machine>." (a numbered list for several, each with path and machine), then ask "Go ahead?" and stop. For a standing approval, repeat the scope back in one line, e.g. "OK: I'll run git commands on any machine without asking."
- Commands can run on any of the user's machines. Find it with `./bin/ham-ctl bridge list`: match the user's words against each bridge's `label` or `machine_hostname` and use its `bridge_id`; its `status` must be `online`. If the user names no machine, ask which one, listing the online ones by label.
- For project work, take the path and bridge from `./bin/ham-ctl projects show <project_id>` `bridge_paths`, as for servers. Otherwise use the path the user gave, or `~`. Ask if the path, machine or command is unclear.
- Run with `./bin/ham-ctl shell run --cmd '<command>' --cwd <path> --bridge <bridge_id>` in the foreground, without `--bg`.
- Reply with the exit status and at most the last 20 lines of output, shortened to fit one chat message. Never send output that looks like a secret; omit sensitive output and say it was omitted.

### When work is done
- Verify completion first: a completed chain event, or `./bin/ham-ctl task-chain show <chain_id>` showing the chain completed. Check status when the user asks about the chain.
- If the coordinator reports finished work while the chain is still open, ask it to finish: `./bin/ham-ctl chat send --to <coordinator_agent_instance_id> --body "The work is done; please complete the chain and tell me when it is completed."`. Do not complete or archive another agent's chain yourself.
- Once the chain is completed, stop its eligible agents without asking. List `./bin/ham-ctl agents instance list --live`, keep instances with that `chain_id` and an empty `current_task_id`, and exclude your own instance. For each run `./bin/ham-ctl agents stop <agent_instance_id> --reason chain_work_done`. Leave busy agents running (a `chain.work_finished` event is not completion: wait for the chain to be completed before stopping anyone).
- Send one plain-text update with the chain title and ID, the coordinator's one-line result if available, and which instances you stopped. On a duplicate completion event, check the earlier update before sending again.
