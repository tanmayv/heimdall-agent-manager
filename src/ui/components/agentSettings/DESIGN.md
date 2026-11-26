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
| 768–1279px          | drawer   | The same column over the conversation with a scrim. Esc or the scrim closes it. Always starts closed; opening it is not persisted. |
| < 768px             | page     | Full-screen page: 44px back button, title "Agent settings", subtitle "<agent> · <project>". Controls are >= 44px. Starts closed; not persisted. |

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
2. Runs on, 3. Model, 4. Connection, 5. Permissions: T6 (`agent-panel-bridge`,
   `-model`, `-connection`, `-permissions`). Until then the panel's "Configuration" slot
   hosts the old modal's controls so nothing becomes unreachable.
6. Staged-changes footer: T7 (`agent-panel-apply`).
