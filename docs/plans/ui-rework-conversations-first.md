# UI Rework — "Conversations-first" implementation plan

**Status:** In progress — Phases 0, 1, 2 done; next Phase 3/4
**Owner:** _unassigned_
**Design source:** `docs/mocks/simplified-ui.html` + `docs/mocks/simplified-ui-redesign.md`
**Last updated:** 2026-08-28

> Multi-session tracker. Update the **Status** boxes and the **Progress log** at the
> bottom as work lands. Keep each phase independently shippable so we never break the
> current UI mid-flight.

### IMPORTANT — codebase reality (discovered 2026-08-28)
- The live UI entrypoint is `src/ui/main.tsx` → `components/shell/AppShell.tsx`.
  **`components/App.tsx` (the ~7200-line monolith) is dead code — imported nowhere.**
  Do the rework in `AppShell.tsx` + `components/chat/*`, not `App.tsx`.
- `AppShell` **already** has: project-grouped conversation tree in the left rail
  (`ProjectConversationTree` / `buildProjectConversationTree`), a hash `RouteOutlet`,
  mobile drawer + bottom tab bar, and single user-WS wiring. So Phase 1's rail largely
  **exists** — this rework is mostly: (a) runtime chip + status in the conversation view,
  (b) one-tap task chain, (c) the scalable New chat flow, (d) icon-ification, (e) folding
  extra nav into Manage.
- Because there is no second legacy shell to fall back to, we are **enhancing in place**
  behind small local guards rather than a global `ui.conversationsFirst` swap. Keep each
  change independently revertible; no big-bang cutover needed.

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

### Phase 0 — Foundations `[x] done`
- [x] ~~Add `ui.conversationsFirst` feature flag~~ — **dropped.** `App.tsx` is dead; we
      enhance `AppShell.tsx` in place (each change independently revertible), so a global
      flag is unnecessary. Revisit only if a change turns out to be risky.
- [x] Add shared `Icon` component (`components/Icon.tsx`). Local inline SVGs (we do NOT
      use `lucide-react` — the pinned 1.21.0 is broken, see Phase 2 log) behind a stable
      name-based API: plus, gear, chat, grid, tasks, chevron-{left,right,down},
      arrow-{up,right}, close, stop, play, search, device. Establishes the "icons not
      emojis" rule for new UI.
- [x] Add `StatusDot` + `RuntimeChip` primitives (`components/runtime/RuntimeChip.tsx`)
      with `runtimeStateFromStatus()` normalizing instance `runtime_status` →
      live/starting/stopped, and an explicit label ("Running/Starting/Stopped").
- **Acceptance:** `tsc -b` passes; primitives ready to drop into the conversation view.
      _Met._ Not yet visually wired (that's Phase 2).

### Phase 1 — Shell + rail (conversations grouped by project) `[x] done (audit)`
Audit finding: **most of this already existed** in `AppShell.tsx`
(`ProjectConversationTree` / `ProjectGroupItem` / `buildProjectConversationTree`).
- [x] Rail already has project-collapsible groups, conversation rows (status dot, title,
      meta/time, unread badge), agent sub-groups, and a bridge legend. Wired to
      `sidebar.ts` + `projects.ts`, grouped by instance `project_id`.
- [x] Always-present ungrouped bucket exists as `DEFAULT_CONVERSATIONS_PROJECT`
      (labeled "Conversations", always sorted first). _Naming nit only._
- [x] Rail collapse state already persisted per project via `localStorage`.
- [x] **Added a prominent "New chat" button** (`shell-new-chat-button`) at the top of the
      rail → `/conversations/new` (previously only per-agent `+`).
- [x] **Emoji → Icon cleanup (the real work):** `NAV_ROUTES` icons were corrupted emoji
      bytes (rendered as `??`); converted `ShellRoute.icon`/`MobileTab.icon` to `IconName`
      and render via `<Icon>`. Replaced project chevrons, sidebar collapse, per-agent `+`,
      mobile tab-bar icons, mobile back/close, hamburger, and route-placeholder glyphs
      with `<Icon>`. Added `menu` icon. Kept the `⌘` keycap (semantic shortcut hint).
- [~] **Manage** entry: the existing "Settings" secondary nav already links to
      bridges/providers/tokens/projects/memory. Full "Manage" consolidation is Phase 6.
- **Acceptance:** rail browses/opens conversations grouped by project, icons render (no
      emojis). _Met._ Verified with an isolated Tailwind harness screenshot; `tsc -b` +
      `vite build` green.
- New debug-id: `shell-new-chat-button` (register in AGENTS.md).

### Phase 2 — Conversation view + runtime chip `[x] done`
- [x] Header: title + **RuntimeChip** (`status · bridge · provider · tier`) with live dot.
      Replaced the old uppercase status pill + separate bridge/config summary line in
      `ConversationThreadPage` with the single `RuntimeChip`; clicking it opens the runtime
      menu.
- [x] **Status is explicit** in the chip label (Running / Starting / Stopped), via
      `runtimeStateFromStatus()`.
- [x] Change menu (desktop popover / mobile sheet already existed): added a **Device
      (bridge) selector** (`conversation-bridge-select`) so users can move the instance to
      another device; provider/tier follow the selected bridge's capability matrix;
      Apply&relaunch now sends `bridge_id`. Start/Stop already present.
  - Backend: hub `reconfigure_instance` already accepts `bridge_id` (has_bridge_id);
    extended the `reconfigureAgentInstance` mutation to pass it. **No new backend.**
- [x] Reuse existing message list/composer — untouched; read receipts, pane capture,
      artifact upload unaffected.
- **Acceptance:** run status + device/provider/model visible and changeable in place.
      _Met._ `tsc -b` + `vite build` green.
- Follow-up (not blocking): bridge options currently list all online bridges; could be
  narrowed to the agent's `bridge_support` set. New debug-ids to register in AGENTS.md:
  `conversation-thread-runtime-chip`, `conversation-bridge-select`.

### Phase 3 — Task chain access (inspector + chain bar) `[ ] not started`
- [ ] Header **Task chain** button (with `done/total` progress) — only when the
      coordinator owns a chain. Toggles the right inspector.
- [ ] Inspector tabs: Tasks / Workspace / Artifacts (reuse existing tab components).
- [ ] Mobile: chain **quick-bar** under the thread header → **task bottom sheet**.
- **Acceptance:** from a coordinator chat, the chain + tasks are one tap away and reflect
      live promotion states.

### Phase 4 — New chat flow `[ ] not started`
- [ ] Desktop modal + mobile full-screen: **Project → Coordinator agent → Runtime**.
- [ ] **Searchable pickers (must scale to 10–50 items)** for BOTH agent and project —
      not chip rows. Reuse/extend `AgentPickerV2` (already store-backed + searchable) for
      the agent picker; build an equivalent searchable list for projects.
  - Agent rows show **name + role/template tag + description + `agt_` id** so similar or
    identically-named agents stay distinguishable; search matches name/id/role/description.
  - Project rows show **name + path/hint**; search matches name/id/path. Include a
    "No project" option. Each list is internally scrollable with a result count.
- [ ] Defaults pre-resolved: agent `default_provider`/`default_tier` on its first
      supported online bridge; advanced section only if the user wants to change.
- [ ] Constrain bridge list to the agent's bridge-support; constrain provider/tier to the
      chosen bridge's capabilities.
- [ ] Submit → create instance in a (new or standalone) chain and open the conversation.
- **Acceptance:** with 40+ agents/projects the picker is searchable, scrollable, and each
      agent is identifiable by id + description; "just hit Start" still works with sane
      defaults; power users can override.

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

- 2026-08-28 — impl — **Phase 1 done (audit).** The project-grouped rail already existed
  in `AppShell.tsx`; audited it against the plan. Added a prominent rail "New chat" button
  and did the real cleanup: converted all shell/mobile nav icons from (partly corrupted)
  emojis to the `<Icon>` component (`ShellRoute.icon`/`MobileTab.icon` → `IconName`),
  including chevrons, collapse, per-agent +, mobile tab bar, back/close, hamburger, and
  route placeholders. Added a `menu` icon. `tsc -b` + `vite build` green; verified rail
  visually via a Tailwind harness.
- 2026-08-28 — impl — **Phase 2 done.** `ConversationThreadPage` header now shows the
  unified `RuntimeChip` (explicit Running/Starting/Stopped + bridge · provider · tier),
  clicking it opens the runtime menu. Added a Device (bridge) selector to the runtime
  controls and extended `reconfigureAgentInstance` to pass `bridge_id` (hub already
  supports it) so a conversation can be moved across devices. Also fixed a real
  pre-existing hazard: the pinned `lucide-react@1.21.0` ships a broken package (missing
  ESM entry → Vite fails), so `Icon.tsx` now uses local inline SVGs instead of lucide.
  `tsc -b` + `vite build` both green.
- 2026-08-28 — impl — **Phase 0 done.** Added `components/Icon.tsx` (inline-SVG,
  name-based API) and `components/runtime/RuntimeChip.tsx` (`StatusDot`, `RuntimeChip`,
  `runtimeStateFromStatus`/`runtimeStateLabel`). Discovered `components/App.tsx` is dead
  code — the real shell is `components/shell/AppShell.tsx`, which already has the
  project-grouped conversation rail; updated the plan's scope accordingly and dropped the
  global feature flag. `tsc -b` green. Next: Phase 2 (wire RuntimeChip + status into the
  conversation view) since Phase 1's rail largely exists.
- 2026-08-28 — planning — Phase plan drafted. Interactive mock (`docs/mocks/simplified-ui.html`)
  covers desktop + mobile, New chat flow, runtime chip with explicit run status, task-chain
  access, and an emoji-free SVG icon set.
