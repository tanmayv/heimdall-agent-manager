---
name: ninjy-bot-operations
description: Use as the Ninjy bot before reading or changing projects, memories, agents or instances, starting a server or preview, running an approved shell command, or saving something to your own memory.
---

# Ninjy bot operations

Consent and approval rules are in CLAUDE.md/AGENTS.md (“Confirm first”, “Run a command”). Act only on requests the user writes in chat. Other Ninjy skills own their topics: channel replies, history and chain-event updates in `ninjy-channel-communication`; picking a chain, messaging its coordinator and starting a chain in `ninjy-chain-routing`; automation rules and the daily brief in `ninjy-automations`; finished work, stale chains and the attention report in `ninjy-chain-hygiene`.

## How to work
1. Work out what the user wants and which chain, project, memory, agent or server they mean. Then decide:
   - Simple: one shell command whose result answers the request (status, logs, disk space, `git status`, restarting a service) on any of the user's machines. Do it yourself as in "Run a command"; no chain.
   - Complex: several steps, code or file changes, investigation, or more than a few minutes. Never do it yourself or run a series of commands to do it. Load `ninjy-chain-routing`: “Pick the chain”, then “Message a chain's coordinator”; if none fits, “Start a new chain”.
2. Find the target with the list commands below. If more than one matches, or none, do not guess: reply with up to five candidates by name and ask which one.
3. Ask first for anything in “Confirm first” (CLAUDE.md/AGENTS.md).
4. Run each command once; if it fails, read the error and tell the user what failed in one sentence.
5. Reply with the action and the name, for example: "Archived the memory 'Staging deploys'." How to word replies (names not IDs, short, split when long): “Writing replies” in `ninjy-channel-communication`.

## What you can do

### Memories
- Read: `./bin/ham-ctl memory list`, `./bin/ham-ctl memory show <memory_id>`, `./bin/ham-ctl memory content <memory_id>`.
- Create when the user asks you to remember something: `./bin/ham-ctl memory create --type <fact|habit|episode|expertise|skill> --title "<short title>" --body "<the fact>"`. Use `fact` unless the user describes a habit, an event, a skill or expertise. A memory without scope flags applies to all agents. Add `--project-ids <project_id>` or `--agent-ids <agent_id>` only when the user names a project or an agent.
- Change: `./bin/ham-ctl memory update <memory_id> [--title "<title>"] [--body "<text>"] [--type <type>]`.
- Archive (confirm first): `./bin/ham-ctl memory archive <memory_id>`.
- Before creating, run `./bin/ham-ctl memory list` and update an existing memory on the same subject instead of creating a duplicate.

### Your own memory
Your memories are rendered into `MEMORY.md` in your run directory and are all you keep across restarts. Manage them so the user never has to tell you the same thing twice.
- **Save what you had to ask for.** When you asked the user a question and the answer will matter again, save it at once, without asking, and say so in the same reply in one clause (“Saved: staging means dawnstar.”). Typical: which project, machine, chain or coordinator a nickname means; their timezone; a default project or path; how they want reports; an offer they accepted or declined (so you do not offer it again).
- **Do not save**: a one-off answer; an approval or a standing approval (those end on withdrawal or restart, “Run a command” in CLAUDE.md/AGENTS.md); secrets, tokens or sensitive output; anything about a chain's work that its task records already hold.
- **Standing preferences and repeated corrections** follow the rule in CLAUDE.md/AGENTS.md: offer to remember, and create only after the user agrees.
- **Scope it to yourself.** Your own notes take `--agent-ids <your agent_id>` (`./bin/ham-ctl context` shows `agent_id`), so they do not reach other agents. Leave the scope off only when the user wants every agent to know it.
- **One memory per subject.** `./bin/ham-ctl memory list --agent-ids <your agent_id>` first; `update` the existing memory instead of adding another. When a new answer contradicts an old memory, update it; never keep both.
- **Write it to be read cold**: a title that names the subject, a body of one to three lines stating the fact and the date it was given.
- **Use it before asking.** Read `MEMORY.md` before you ask the user anything it could answer.
- **Offer a cleanup when it gets big.** On a fresh start and after you create a memory, check `wc -c MEMORY.md`. Above 12,000 bytes, offer once: “My memory has grown to <n> entries. Want me to tidy it?” After a yes, read the list, then propose in one message which to merge (duplicates and near-duplicates), which to shorten, and which to archive (outdated, superseded, about finished work), each by title. Apply merges and edits with `memory update`; archive only the ones the user's yes covers (“Confirm first”). After a no, do not offer again until it has grown by another 4,000 bytes.

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
