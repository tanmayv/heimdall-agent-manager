# Chat UI unification — audit → decide → implement → validate

## Problem

Heimdall has **three** chat surfaces that were built independently and look/behave
inconsistently:

1. **Coordinator chat** — inside `ChainView` (`chain-coordinator-panel`), with a chain
   sidebar (progress panel + task list) beside it. **This is the reference layout.**
2. **Conversation chat** — `ConversationThreadPage` (`conversation-composer-*`). Its composer
   footer (Provider/Tier/Project controls + context hint) is the **reference composer**.
3. **Agent (direct) chat** — `AgentDetailPage` (`agent-detail-chat-*`).

They duplicate shells, headers, banners, and composers with subtle differences. Shared
fragments already exist but are used inconsistently: `Composer.tsx`,
`RuntimeRestartControls.tsx`, `ChatRuntimeBanner`, `CoordinatorMessageList`, `MessageBubble`,
`ArtifactUploadButton`.

## Goal

Make all three feel like **one app**: shared header, shared message list, shared
working/task banner, and **one** composer — maximizing code reuse (no parallel one-off
components). Reference = **coordinator chat layout + sidebar**, with the **conversation
composer** as the input box.

## Target composer (reference)

See `target-composer.png`. The single shared composer must have:

- Multiline input ("Ask anything…").
- **Upload** button (artifact upload).
- **Provider:** dropdown (change provider).
- **Tier:** dropdown (change tier).
- **Project:** dropdown — **visible in all three**, editable in conversation + agent chat,
  **read-only/disabled for coordinator** (coordinator's project is fixed by the chain).
- "Runtime settings applied" hint + **Send** button.
- Context footer: `📁 <Project> · shares memories & skills from the <identity>` + `⌘↵ to send`.

## Required unified features (superset across the three)

The chain's info-gathering task must produce the authoritative list; known so far:

- Header: title, live status dot/label, back nav, refresh, artifacts toggle, start/stop.
- Working/task **banner** showing current task info when available (`ChatRuntimeBanner`).
- Message list with hover-copy, load-older/pagination, message actions.
- Composer: upload, provider, tier, project (see above), send, runtime-restart, ⌘↵ hint.
- Start-agent affordance when the agent is offline (status banner + start button).
- **Sidebar (new for agent chat):** like coordinator chat — show the task chain the agent is
  working plus its tasks, styled like the task-chain view (reuse the chain progress panel +
  task list components). Coordinator already has this; conversation/agent should reuse it.

## Constraints

- **Maximize reuse.** Prefer extracting/So consolidating into shared components
  (`ChatHeader`, `ChatComposer`, `ChatWorkBanner`, `ChatMessageList`, `ChatSidebar`) over
  editing three copies. No new parallel one-off components.
- Preserve every existing `data-debug-id` contract (AGENTS.md registry) — keep the per-surface
  prefixes (`conversation-composer`, `chain-coordinator`, `agent-detail-chat`) working via a
  `debugPrefix` prop on the shared components.
- Keep RTK Query data flow; no new fetch orchestration.
- Coordinator project stays fixed (project visible but not changeable).

## Chain shape (4 phases, 4 different agents)

1. **Gather (researcher):** screenshot all three chats; enumerate every feature/prop/debug-id
   per surface; produce a comparison matrix + the authoritative feature list as an artifact.
2. **Decide (planner/lead):** design the shared component set + prop contracts + which
   surface owns what; write the design doc + task breakdown as an artifact. No code.
3. **Implement (coder):** build the shared components and refactor all three surfaces onto
   them (header, composer with project/provider/tier + upload, work banner, message list,
   agent-chat sidebar reusing chain progress/task-list). Maximize reuse.
4. **Validate (tester):** screenshot all three again; verify consistent look/feel, all
   features present, debug-id contract intact, `tsc -b` + `vite build` green, and the
   before/after comparison as an artifact.

Each phase is a **different agent** (researcher, planner/lead, coder, tester).
