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
6. Staged-changes footer: T7 (`agent-panel-apply`). Until then a minimal Discard/Apply
   row (`agent-panel-interim-apply`) applies the draft through the existing
   reconfiguration.

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
transport and bypass, and sends `runtime_transport` / `permission_mode` only when they
change. Radiogroups share `radioGroup.ts` (roving tab stop, arrow keys skip disabled
rows). Selected rows use `bg-surface-overlay` (the spec's bg-300 token) and a gold check.
