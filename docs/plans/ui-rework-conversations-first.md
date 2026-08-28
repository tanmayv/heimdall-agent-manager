# UI Rework — "Conversations-first" implementation plan

**Status:** Not started (planning complete)
**Owner:** _unassigned_
**Design source:** `docs/mocks/simplified-ui.html` + `docs/mocks/simplified-ui-redesign.md`
**Last updated:** 2026-08-28

> Multi-session tracker. Update the **Status** boxes and the **Progress log** at the
> bottom as work lands. Keep each phase independently shippable behind the feature
> flag so we never break the current UI mid-flight.

---

## 1. Goal & guardrails

Rework the Heimdall desktop/mobile UI into a Claude/ChatGPT-style **conversations-first**
experience:

- Left rail = **coordinator conversations grouped by project** (not 7 competing nav items).
- A **runtime chip** on every conversation makes the multi-device / multi-model state
  plain and changeable: `‹status› · ‹bridge› · ‹provider› · ‹tier›`.
- **New chat** flow lets the user pick **project + coordinator agent-id + bridge/runtime**
  with correct **defaults pre-filled**.
- Task chain for a coordinator conversation is **one tap/click away** (header button →
  inspector on desktop, quick-bar → bottom sheet on mobile).
- **Mobile-first parity**: same data, adaptive layout (list→thread nav, bottom sheets, FAB).

### Hard guardrails
- **No new backend endpoints.** Every element maps to an existing hub/bridge capability
  (see §3 mapping). If something needs new backend, it is out of scope for this rework
  and gets its own ticket.
- **Icons only — strictly no emojis** in the UI. Use the inline SVG sprite pattern from
  the mock (`<svg class="ico"><use href="#i-…"/></svg>`). Add a shared `<Icon>` component.
- **Every interactive element needs a `data-debug-id`** (see AGENTS.md convention). New
  IDs must be added to the per-component registry table in AGENTS.md in the same PR.
- Ship behind a **feature flag** (`ui.conversationsFirst`) so the legacy shell stays
  usable until we cut over.

---

## 2. Target information architecture

```
Desktop:  [ rail: New chat + project-grouped convos + Manage ] [ conversation ] [ inspector? ]
Mobile:   list (search + grouped convos + FAB + tabbar)  <->  thread (runtime chip + chain bar)
```

- **Primary nouns:** Conversations, Projects.
- **Demoted into "Manage":** Agents catalog, Bridges/devices, Memory, Projects settings,
  Task-chains index. Reachable, not competing for attention.
- **Removed from primary flow:** federation/peer terminology, multi-daemon switcher.

---

## 3. Backend capability mapping (must stay true)

| UI element | Existing endpoint / module |
|---|---|
| Conversation list grouped by project | `api/endpoints/sidebar.ts` (`listConversationInbox`), instance `project_id`, `projects.ts` |
| New chat launch | `ConversationLaunchComposer` logic → `createAgentInstanceInChain` / `startAgent` (`agents.ts`) |
| Agent-id list + defaults | `useListAgentIdentitiesQuery` (`agents.ts`): `default_provider`, `default_tier` |
| Bridge/provider/tier options | `bridgeSupport.ts`: `useListBridgesQuery`, `useListAgentBridgeSupportQuery`, `normalizeBridgeCapabilities` |
| Runtime chip (status/bridge/provider/tier) | `agents.ts` `useFetchAgentInstanceQuery` → `runtime_status`, `bridge_id`, `provider`, `tier`; bridge label from `bridges` |
| Change device/provider/model | `reconfigureAgentInstance` + `restartAgentInstance` (`agents.ts`) |
| Start / Stop | `startAgent` / `stopAgentInstance` (`agents.ts`) |
| Messages / send / read | `chats.ts`: `fetchConversationMessages`, `sendConversationMessage`, `markConversationRead` |
| Inspector → Tasks | `tasks.ts` `listChainTasks` (+ live promotion from the hub work already shipped) |
| Inspector → Workspace diff | `workspace.ts` `fetchWorkspace`, `fetchWorkspaceDiff` |
| Inspector → Artifacts | `artifacts.ts` `listArtifacts` |
| Manage → Memory/Agents/Bridges/Projects | existing panels, relocated |

**Rule:** if a PR needs a field the API does not return, stop and flag it — do not fake it.

---

## 4. Phases (each independently shippable)

### Phase 0 — Foundations `[ ] not started`
- [ ] Add `ui.conversationsFirst` feature flag (route-level switch in `App.tsx`).
- [ ] Add shared `Icon` component + SVG sprite (port symbols from the mock: plus, gear,
      chat, grid, tasks, chevron-{left,right,down}, arrow-{up,right}, close, stop, play).
      Establish the "no emoji" lint expectation.
- [ ] Add a `StatusDot` + `RuntimeChip` primitive (status → color: live/starting/stopped).
- **Acceptance:** flag off = legacy UI unchanged; flag on = empty new shell renders.

### Phase 1 — Shell + rail (conversations grouped by project) `[ ] not started`
- [ ] New `ConversationsShell` (left rail + main + optional inspector) behind the flag.
- [ ] Rail: **New chat** button, project-collapsible groups, conversation rows
      (status dot, title, preview, unread badge, time). Always-present "No project" group.
- [ ] Wire to `sidebar.ts` + `projects.ts`; group conversations by instance `project_id`.
- [ ] Bottom **Manage** entry linking to the relocated settings surface.
- [ ] Persist rail collapse state per project (local pref).
- **Acceptance:** can browse and open real conversations grouped by project.

### Phase 2 — Conversation view + runtime chip `[ ] not started`
- [ ] Header: title + **RuntimeChip** (`status · bridge · provider · tier`) with live dot.
- [ ] **Status is explicit** in the chip label (Running / Starting… / Stopped), not just a dot.
- [ ] Change popover (desktop) / bottom sheet (mobile): device→provider→tier segmented
      controls constrained to the bridge capability matrix; Apply&restart; Start/Stop.
- [ ] Reuse `ConversationThreadPage` message list/composer; do not regress read receipts,
      pane capture, artifact upload.
- **Acceptance:** user can see run status and change bridge/provider/model in place.

### Phase 3 — Task chain access (inspector + chain bar) `[ ] not started`
- [ ] Header **Task chain** button (with `done/total` progress) — only when the
      coordinator owns a chain. Toggles the right inspector.
- [ ] Inspector tabs: Tasks / Workspace / Artifacts (reuse existing tab components).
- [ ] Mobile: chain **quick-bar** under the thread header → **task bottom sheet**.
- **Acceptance:** from a coordinator chat, the chain + tasks are one tap away and reflect
      live promotion states.

### Phase 4 — New chat flow `[ ] not started`
- [ ] Desktop modal + mobile full-screen: **Project → Coordinator agent → Runtime**.
- [ ] Defaults pre-resolved: agent `default_provider`/`default_tier` on its first
      supported online bridge; advanced section only if the user wants to change.
- [ ] Constrain bridge list to the agent's bridge-support; constrain provider/tier to the
      chosen bridge's capabilities.
- [ ] Submit → create instance in a (new or standalone) chain and open the conversation.
- **Acceptance:** "just hit Start" works with sane defaults; power users can override.

### Phase 5 — Mobile polish + parity `[ ] not started`
- [ ] list↔thread slide nav, FAB, bottom tab bar (Chats/Projects/Manage).
- [ ] Runtime bottom sheet + task bottom sheet; safe-area/touch target sizing.
- [ ] Responsive breakpoints verified (phone / tablet / desktop).
- **Acceptance:** full flow usable one-handed on a phone.

### Phase 6 — Manage surface + cutover `[ ] not started`
- [ ] Consolidate Agents / Bridges / Memory / Projects / Task-chains index under Manage.
- [ ] Migrate deep links / breadcrumbs; keep old routes redirecting.
- [ ] Flip `ui.conversationsFirst` on by default; remove legacy shell after a soak period.
- **Acceptance:** no primary flow requires the old 7-way nav.

---

## 5. Cross-cutting checklist (every PR)
- [ ] Icons only, no emoji (grep the diff for emoji codepoints).
- [ ] `data-debug-id` on every interactive element + AGENTS.md registry updated.
- [ ] No new backend endpoint introduced.
- [ ] Keyboard + focus states; screen-reader labels on icon-only buttons.
- [ ] Loading / empty / error states for every data view.
- [ ] Feature-flag guarded; legacy path still builds.

---

## 6. Open questions / decisions to confirm
- [ ] "No project" group — always shown, or only when ungrouped conversations exist?
- [ ] New chat: always create a chain, or support a truly standalone (chain-less) chat?
      (Backend currently ties coordinator conversations to a chain in most flows.)
- [ ] Do we surface **remote/peer** proxies at all in the primary flow, or Manage-only?
- [ ] Manage IA: single page with sub-nav vs. separate routes.
- [ ] Runtime change while a chain is mid-flight — guard/confirm before restart?

---

## 7. Progress log
_Append newest first: `YYYY-MM-DD — <who> — <phase> — <what landed / decided>`._

- 2026-08-28 — planning — Phase plan drafted. Interactive mock (`docs/mocks/simplified-ui.html`)
  covers desktop + mobile, New chat flow, runtime chip with explicit run status, task-chain
  access, and an emoji-free SVG icon set. Ready to start Phase 0.
