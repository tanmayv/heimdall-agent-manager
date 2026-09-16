# Heimdall

A multi-agent orchestration system for developers who want more than a single chat window.

Heimdall runs a fleet of autonomous AI coding agents across your machines, coordinates
their work through a shared hub, and gives you a real-time dashboard to watch, steer, and
audit everything they do. Instead of one long conversation that slowly falls apart, you get
a team of specialized agents with durable memory, independent review, and a structured
record of every decision.

## The problem

If you do real project work in a single Claude Code chat session, you keep hitting the same
walls:

- **Context explosion.** A long conversation degrades in quality as the window fills up, and
  when you restart to clear it you lose everything you had built up.
- **No parallelism.** One thread means one thing at a time. You cannot investigate a bug,
  implement a feature, and review a change at the same time.
- **No persistent memory.** The agent forgets your project's facts, conventions, and past
  decisions between every session, so you re-explain the same context again and again.
- **No audit trail.** To find out what actually happened you have to re-read the entire
  conversation. There is no structured, skimmable record of the work.
- **No independent review.** The same agent that writes the code also signs off on it.
  Nothing ever gets a genuine second pair of eyes.
- **Provider lock-in.** You are tied to a single LLM provider, with no easy way to mix
  models or switch when a better one comes along.

## How Heimdall solves it

- **Multi-agent by design.** A Coordinator breaks the work into a task chain and delegates
  each task to a Worker agent. A separate Reviewer then votes LGTM or NGTM, and a task only
  completes once every required reviewer has approved it.
- **Persistent, scoped memory.** Facts, habits, episodes, and skills are stored durably and
  injected into each agent at bootstrap. Knowledge is scoped to an agent, a project, a
  device, or the whole fleet, so it survives across sessions and is shared where it belongs.
- **Fresh context every task.** Agents restart after each task. No single conversation ever
  grows long enough to degrade, and every task starts from a clean, focused window.
- **Structured audit trail.** Progress is captured as structured task comments and status
  changes — the real record of what happened, not an after-the-fact AI summary you have to
  trust.
- **Provider-agnostic.** Each agent is a thin adapter over whatever LLM you choose. Heimdall
  does not care which provider backs an agent, so you can mix and match freely.
- **Cross-device fleet.** Agents run on any device you own and are coordinated through a
  single hub, so your laptop, workstation, and servers all pull work from the same board.

## Architecture

Heimdall is a hub-and-bridge system. A central hub owns all shared state; one bridge per
device spawns and supervises the agent processes that do the work. Agents and humans both
drive the system through a CLI, and a desktop and web UI render the whole thing live.

- **Hub (Odin).** The central REST and WebSocket server. It manages agents, task chains,
  memories, and projects, and is the single source of truth for all shared state.
- **Bridge (Odin).** Runs on each device. It spawns and manages the Claude Code agent
  processes, executes shell commands on their behalf, and handles filesystem exploration so
  agents can read and search a project safely.
- **ham-ctl.** The command-line interface used by agents and humans alike to create and
  update tasks, read and send messages, propose memories, and run tracked shell commands.
- **UI (React / TypeScript / Electron + web).** The dashboard. It provides a task board, a
  conversation view, memory management, shell-job tracking, and a fleet view of every
  running agent across every device.

## How work flows

A typical run looks like this:

1. You describe what you want to the Coordinator through the UI or `ham-ctl`.
2. The Coordinator plans a task chain and assigns each task to a Worker, with a Reviewer
   attached.
3. A Worker picks up its task in a fresh agent session, does the work, records progress as
   task comments, and hands off for review.
4. The Reviewer inspects the change and votes. On LGTM the task completes; on NGTM it goes
   back to the Worker with feedback.
5. When the chain finishes, its memories are proposed for approval and carried forward to
   future work.

Everything above is visible and steerable in real time from the dashboard, and every step
leaves a durable record.

## Getting started

Heimdall is deployed as a NixOS flake. The hub runs on a VPS, and a bridge runs on each
developer machine that should host agents. Point the bridges at the hub, and agents on
every device coordinate through that one board.

See the `nix-homelab-config` repository for the deployment configuration.
