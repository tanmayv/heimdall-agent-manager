---
name: ninjy-chain-hygiene
description: Use as the Ninjy bot when a chain's work is done or completed, when running a hygiene sweep, or when the user asks what needs their attention or what could be cleaned up or improved - stale-chain detection, what may be cleaned up without asking, and the attention and improvement report.
---

# Ninjy chain hygiene

Approval rules are in CLAUDE.md/AGENTS.md (“Confirm first”). Picking and messaging chains: `ninjy-chain-routing`. Which events produce a message: `ninjy-channel-communication`, “Chain events”.

## What you may do without asking, and what needs a yes
| Action | Rule |
|---|---|
| Stop idle agents of a completed or stale chain | Without asking. Report it in the same message as the finding |
| Ask a coordinator to complete a chain whose work is done | Without asking |
| Archive or cancel a chain | Propose it, ask “Go ahead?”, wait for a yes |
| Stop an agent that is working | Ask first (“Confirm first”) |
| Complete another agent's chain yourself | Never. Completion belongs to its coordinator |

## When work is done
- Verify completion first: a completed chain event, or `./bin/ham-ctl task-chain show <chain_id>` showing the chain completed. Check status when the user asks about the chain.
- If the coordinator reports finished work while the chain is still open, ask it to finish: `./bin/ham-ctl chat send --to <coordinator_agent_instance_id> --body "The work is done; please complete the chain and tell me when it is completed."`. Do not complete another agent's chain yourself; archive or cancel one only as in “Stale chains”.
- Once the chain is completed, stop its eligible agents without asking, as in “Stop idle agents” (a `chain.work_finished` event is not completion: wait for the chain to be completed before stopping anyone).
- Tell the user once, in plain text with the chain title and ID, the coordinator's one-line result if available, and which instances you stopped, only when the user asked you for that work or asked to be told; otherwise stay silent and answer when asked (`ninjy-channel-communication`, “Chain events”). On a duplicate completion event, check the earlier update before sending again.

## Stop idle agents
- List `./bin/ham-ctl agents instance list --live`. Keep instances with that `chain_id` and an empty `current_task_id`, and exclude your own instance. For each run `./bin/ham-ctl agents stop <agent_instance_id> --reason chain_work_done`.
- Leave busy agents running: an instance with a `current_task_id` is working.
- Applies to completed chains and to stale chains (below). For any other chain, ask first.

## Stale chains
A chain is stale when its `status` is `active` and either holds:
- **No activity for 3 days**: `updated_at` in `./bin/ham-ctl task-chain list` is more than 3 days old.
- **Work done but chain still open**: `task_count` is above zero and every task in `./bin/ham-ctl task list --chain <chain_id>` is done or cancelled.

Not stale, whatever the date: a chain with a task waiting for the user's review (`user_validation_count` above zero) or blocked on the user's answer. That chain is waiting for the user; report it under “Needs you”.

For each stale chain:
1. **Work done but open**: ask the coordinator to complete it (“When work is done”). Nothing to tell the user unless the coordinator does not answer after one follow-up.
2. **No activity for 3 days**: stop its idle agents (“Stop idle agents”). Then read `task-chain show <chain_id>` and `task list --chain <chain_id>` to say in one clause where it stopped.
3. Propose one of: archive (`./bin/ham-ctl task-chain archive <chain_id>`, reversible with `unarchive`), cancel (`./bin/ham-ctl task-chain set-status cancelled --chain <chain_id>`, for work the user abandoned), nudge the coordinator, or leave it. Ask “Go ahead?” per chain or for the listed set, and act only on the chains the user's yes covers.
4. **Raise each stale chain once.** Before reporting, check `./bin/ham-ctl channel history --limit 50` for an earlier report of the same chain. Raise it again only when its state changed since, or the user asked to be reminded. A “leave it” answer is final for that chain until it changes.

## Needs your attention
What the user must act on, across chains. Read `task-chain list`, then `task list --chain <chain_id>` and `task show <task_id>` for chains that qualify:
- A task waiting for the user's review (`user_validation_count` above zero): task title and ID; the verdict is theirs.
- A task blocked on the user (`blocked_on` human): the real question from the task.
- A chain or workflow run that failed: what failed, and the options.
- A stale chain with a cleanup proposal (above).

## Worth improving
Suggestions, at most three per report, each with the evidence and one concrete proposal. Never act on one without a yes.
- **A task that keeps bouncing**: a high `attempt_no` in `task show`, or repeated review rounds. Suggest asking the coordinator to sharpen or split it.
- **A task that cannot get an agent**: `blocked_on` with kind `agent_not_running`, or a `ready_since` long past. Say which agent, provider and machine; offer to start it.
- **Something the user asks for repeatedly**: offer an automation (`ninjy-automations`, “Offer an automation”).
- **Something you had to ask twice**: save it as a memory (“Memories” in `ninjy-bot-operations`).
- **Many chains for one objective**: suggest continuing in one chain next time.
Do not repeat a suggestion the user declined; record the decline as a memory when it is a standing preference.

## The sweep
One pass over all chains, run when the user asks “what needs me?” or “clean up”, or when the hygiene automation fires.
1. `./bin/ham-ctl task-chain list`. Classify each active chain: needs the user, stale, or fine.
2. Do the actions that need no approval (complete requests, idle-agent stops).
3. Send ONE plain-text message, in this order, omitting empty sections:
   - Needs you: one line per item, chain title and chain id.
   - Stale: one line per chain with where it stopped and the proposed action, then “Go ahead?”.
   - Cleaned up: instances stopped, by chain.
   - Worth improving: at most three suggestions.
4. When every section is empty, send nothing if an automation triggered the sweep; answer “Nothing needs you.” if the user asked.

**Offering the recurring sweep.** You wake only on messages, events and automations, so a recurring sweep needs a rule. Offer it once, the first time a sweep finds something or the user asks about cleanup: say it runs daily at a time they choose and sends a message only when something needs them. Create it only after a yes, as in `ninjy-automations`, “Hygiene sweep”. Record the answer as a memory so you never offer it twice.
