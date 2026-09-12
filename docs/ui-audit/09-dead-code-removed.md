# Dead-code removal (P0) — record

**Date:** 2026-09-12. **Task:** Remove dead/unused UI components.

## Method
Built a reachability graph from the entry point `src/ui/main.tsx`, following static
`import`/`export … from`, dynamic `import()`, `React.lazy`, and `require` edges (multi-line imports
included). Any `src/ui/components/**/*.tsx` not reachable from the entry is dead. Verified with a
second pass that **no reachable file imports any removed module** (0 live importers). Confirmed the
app builds after removal.

## Result
- Component files: **75 → 47** (28 removed).
- `npm run typecheck` ✓ · `npm run build` ✓ (vite built in ~7s, electron tsc ✓).
- This is the pre-"conversations-first rework" UI, left orphaned when the current chat/AppShell flow
  replaced it. User confirmed the chain graph editor is not shown; the graph confirmed the rest.

## Removed files (28)
Top-level: `AgentListItem`, `AgentPicker`, `AgentPickerV2`, `ChainArtifactsPanel`, `ChainEditor`,
`Composer` (legacy), `ConnectionBadge`, `MemoryManagementPage`, `NewLocalProxyAgentWizard`,
`OnboardingWizard`, `RuntimeRestartControls`, `SessionConfig`, `VimSidebar`.
`chat/`: `AgentBridgesTab`, `AgentSessionsTab`, `ChatComposer`, `ChatHeader`, `ChatSidebar`,
`ChatWorkBanner`, `ConversationMemoryTab`, `ConversationWorkspaceTab`, `WorkChips`, `WorkTab`.
`workspace/` (whole dir): `ContextInspector`, `GenericAgentWorkspacePage`, `UnifiedWorkspaceShell`,
`WorkspaceLeftSidebar`, `WorkspaceMainRegion`.

## Kept (were suspected, but reachable)
`ChatMessageList` (live via `ConversationThreadPage`), `memory/memoryScope` + `SearchableMultiSelect`
(live via `MemoryPage`/`MemoryDetailPage`), `RuntimeChip` (live via `ConversationThreadPage`),
`SearchableSelect`, `MemoryScopeSelector` (live via `MemoryPanel` — stays until replaced by `ScopeField`).

## Inventory impact (verdict → delete, REMOVED)
EL-083 ChainEditor · EL-087 ConnectionBadge · EL-017 framer-pill (`Composer`) · parts of EL-050
(`AgentListItem` dot) · EL-034 picker-as-button (`AgentPicker`). The workspace/chat-tab clusters were
not individually EL-id'd (folded into cluster rows); they are removed wholesale.

## Follow-on task impact (now moot / adjust)
- **ConnectionBadge** build+migrate task → **moot** (component removed; no live call site). Close.
- **Composer** merge task → **moot** (both `Composer` and `ChatComposer` removed; live chat uses the
  inline composer in `ConversationThreadPage`). Close.
- **AgentPickerField** task → **likely moot** (both pickers were only used by the removed `ChainEditor`;
  confirm no live agent-picker need before building).
- **RuntimeChip** task → keep, but `RuntimeRestartControls` reference is removed; scope to `RuntimeChip` only.
