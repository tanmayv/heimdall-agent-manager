# Agent settings panel

The Agent settings panel replaces the "Agent settings" modal. It is docked beside the
conversation and shows the agent's runtime, where it runs (bridge), its provider and
model, its connection protocol (PTY or ACP) and its permissions.

## Why a panel

- Restarting is the main consequence of these settings, and whether it's safe to
  restart is visible in the conversation (mid-turn or idle). The panel keeps both in
  view, and the user can watch the restart without closing anything.
- Five sections plus error states are too much for a modal; the old modal already
  scrolled inside itself.
- It works as an inspector and status view that doesn't block other work.
- Destructive actions (Force stop) stay as small confirmation dialogs inside it.
- Below 1280px the panel overlays the conversation as a drawer. On mobile (<768px) it
  is a full-screen page.

## Layout

| Viewport            | Mode     | Behaviour |
| ------------------- | -------- | --------- |
| >= 1280px (`DOCK_MIN`) | docked | Flex sibling of the transcript in `AgentChatPane` (not an AuxDock tab), `flex-basis` 400px, max 440px, 1px left border. Esc does not close it. Open/closed persists per user (`userScopedStorageKey('agentSettingsPanel.open')`). |
| 768–1279px          | drawer   | The same column in the `@ui` `Drawer` (right edge, max 440px): modal (`role="dialog"`, `aria-modal`, focus trap), Esc or the backdrop closes it, focus returns to the gear. Always starts closed; opening it is not persisted. |
| < 768px             | page     | A full-width `Drawer`: 44px back button, title "Agent settings", subtitle "<agent> · <project>". Controls are >= 44px. Modal like the drawer. Starts closed; not persisted. |

The gear `IconButton` in the conversation header (`aria-label="Agent settings"`,
`aria-expanded`) toggles it; the "Agent settings" item in the ⋮ menu and the composer's
settings/bridge chips open it. Focus moves to the panel heading on open and back to the
gear on close.

The panel is gated by the `agent_settings_panel` experiment (default on). With it off,
or before the flags load, the old modal opens instead and behaves exactly as before.

## Visual system

Ninjy tokens and `@ui` components only. Panel `bg-surface` (bg-100) with a
`border-subtle` left border; cards `bg-surface-raised` (bg-200), 1px `border-subtle`,
radius 12, padding 16, no shadow. Section labels use the `overline` role; the panel title
"Agent" uses `heading` in the display serif. Machine text (bridge, model, paths) uses
`code` / `code-sm`. Gold (accent) appears only on Apply, selected checks, the selected
connection card border and the bypass switch "on". Status words always come with
colour, never colour alone: Running/Restarting use the info tint, Stopped is neutral.

## Sections

1. **Runtime** (`RuntimeSection.tsx`, `agent-panel-runtime`): status pill
   (`role="status"`), detail line, `<bridge> · Provider · <model> · PTY|ACP`, the folder,
   Restart / Stop / "…" → Force stop (confirmed by `ForceStopDialog.tsx`), or Start.
2. **Runs on** (`BridgeSection.tsx`, `agent-panel-bridge`): radiogroup of owned,
   non-revoked bridges ("N of M connected"); offline bridges and bridges without the
   project's folder (its bridge path, else the project default path) are disabled at 45%.
   "Manage project folders" links to the project's edit page (its bridge paths).
3. **Model** (`ModelSection.tsx`, `agent-panel-model`): provider radiogroup for the
   DRAFT bridge's provider status, then "Model for <Provider> on <bridge>". Refresh
   re-runs discovery on the draft bridge (`refreshBridgeModels`).
4. **Connection** (`ConnectionSection.tsx`, `agent-panel-connection`): PTY / ACP cards
   (`runtime_transport`). The ACP alert is mapped from the hub's `acp_availability`
   only (`acpAvailabilityCopy.ts`); fixes call the existing endpoints (bridge update,
   ACP adapter install, and for "Check now" provider discovery `{stage:'providers'}`,
   the stage that records the adapter state `acp_availability` is classified from).
5. **Permissions** (`PermissionsSection.tsx`, `agent-panel-permissions`): the @ui Toggle,
   per running instance only.
6. **Staged changes** (`ApplyFooter.tsx`, `agent-panel-apply`): the sticky footer, see
   "Staged changes and Apply" below.

## The draft

Every control in sections 2-5 edits a draft; nothing applies on click. The rules live
in `agentSettingsDraft.ts` (pure, unit-tested in `tests/ui_agent_settings_draft_test.ts`):
picking a bridge whose provider status says the draft provider is not installed there
switches to the first installed provider and its first model (applied when that
bridge's status arrives); picking a provider resets the model to its first model;
`draftDiff` gives `{field, label, from, to}` per change for the footer;
`applyBlockedReason` blocks Apply while ACP is selected and the hub's verdict for the
draft bridge + provider is not `available` ("Fix the connection above before applying.").
`AgentChatPane` stores the draft in its staged bridge/provider/model state plus staged
transport and bypass. The old modal (flag off) still sends `runtime_transport` /
`permission_mode` only when they change; the panel's Apply always sends the full
destination (below). Radiogroups share `radioGroup.ts` (roving tab stop, arrow keys skip disabled
rows). Selected rows use `bg-surface-overlay` (the spec's bg-300 token) and a gold check.

## Staged changes and Apply

`useApplyAgentSettings.ts` owns the request and its outcome; `ApplyFooter.tsx` renders
`applyFooterView` (both unit-tested in `tests/ui_agent_settings_apply_test.ts`; the
browser check is `tests/e2e/agent_settings_apply_browser_check.mjs`).

- The footer appears while the draft differs from the instance, and while a change is
  queued, restarting, failed or needs recovery. One chip per change
  (`Bridge riverwood → dawnstar`, radius-sm like Badge, not the pill radius): mono
  values, the arrow `aria-hidden` with an sr-only "to". While a change is queued with no
  draft staged here, the chips come from the queued operation's destination.
- Note: "Restarts the agent with a fresh session. The conversation stays."; a bridge
  move names the bridge and the project's folder there; mid-turn (activity busy)
  appends "It's mid-turn, so the restart waits for the turn to finish."; stopped:
  "Starts the agent with these settings."
- Buttons: Discard (ghost) + the gold primary "Apply and restart" | mid-turn "Restart
  after this turn" plus a ghost "Restart now" | stopped "Apply and start" |
  recovery_required "Retry change" (the existing retry endpoint). The ACP gate or a
  destination issue disables the primary with its reason. Touch: Discard 1 part, the
  primary 2 parts, 44px.
- Apply sends the FULL destination (`bridge_id`, `project_id`, `provider`,
  `provider_profile`, `model`, `runtime_transport`, `permission_mode`) with
  `expected_revision` = `configuration_revision`, an idempotency key per intent (replayed
  only after a 5xx or network failure) and `apply: 'after_turn'` mid-turn, else `'now'`.
  Restart now is `'now'` with a new key, which supersedes the queued change.
- 409: the instance is refetched, the draft is kept and the footer says "Changed since
  you opened: …" (the configuration the draft started from vs the refreshed one). Any
  other failure shows the hub's error; the draft is kept.
- Accepted: "Restarting" (footer and Runtime card) until the instance reports running on
  a new `launch_epoch` (WS agent_instance summary), or the operation fails.
- `waiting_for_idle`: "Waiting for the turn to finish…" + Cancel (accessible name
  "Cancel restart"; the cancel endpoint); 30 minutes after `waiting_since`, "Still
  waiting" + Restart now (the hub keeps waiting).
- Accessibility: the status line is one `role="status"` region mounted with the footer
  (empty until needed), so "Restarting the agent…" / "Waiting…" are announced; when the
  focused primary button unmounts, focus moves to that line. A disabled Apply is tied to
  its reason with `aria-describedby`.
- With the flag on, the composer shows no Reset/Apply pair: the panel owns Apply.
