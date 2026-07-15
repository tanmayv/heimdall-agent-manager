# Conversation UX mockups bundle

Primary local entrypoint:

```text
docs/plan/chat-conversation/mockups/index.html
```

Open locally with:

```bash
open docs/plan/chat-conversation/mockups/index.html
```

Key screens:

- `docs/plan/chat-conversation/mockups/01-conversation.html` — conversation shell
- `docs/plan/chat-conversation/mockups/02-new-conversation.html` — new conversation flow
- `docs/plan/chat-conversation/mockups/04-agent-instances.html` — agent instances page
- `docs/plan/chat-conversation/mockups/10-home.html` — home/sidebar direction
- `docs/plan/chat-conversation/mockups/11-chain-view.html` — coordinator chat + toggleable task pane
- `docs/plan/chat-conversation/mockups/12-vcs-diff.html` — workspace diff
- `docs/plan/chat-conversation/mockups/13-chain-editor.html` — chain editor
- `docs/plan/chat-conversation/mockups/14-artifact-viewer.html` — artifact viewer
- `docs/plan/chat-conversation/mockups/15-attention.html` — attention page
- `docs/plan/chat-conversation/mockups/16-agent-detail.html` — agent detail
- `docs/plan/chat-conversation/mockups/17-settings.html` — settings daemons pane
- `docs/plan/chat-conversation/mockups/17b-settings-providers.html` — settings providers pane
- `docs/plan/chat-conversation/mockups/18-memory.html` — memory management
- `docs/plan/chat-conversation/mockups/mock.css` — shared mockup styling

Important UX decisions represented:

- Conversations are grouped by project in the sidebar.
- Task chain view is split: coordinator chat left, toggleable task pane right.
- Task pane keeps the progress-card + dependency-ordered todo-list design, not kanban.
- Settings is a modal two-pane layout with Daemons and Providers sections.
- Single-daemon switcher is included; merged multi-daemon views are future work.
- UI debug IDs should be added to AGENTS.md after implementation lands.
