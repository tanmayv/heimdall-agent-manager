#!/usr/bin/env python3
"""Static regression tests for Command Palette actions routing and removal of current task indicator above composer.

Requirements:
- REQ-PALETTE-NAV-1: CommandPalette DEFAULT_ACTIONS defines:
    - new-conversation -> /conversations/new
    - new-agent -> /agents/new
    - new-chain -> /chains
    - new-project -> /projects
- REQ-PALETTE-NAV-2: AppShell defines handlePaletteAction routing to those paths and passes onAction to CommandPalette.
- REQ-REMOVE-CURRENT-TASK-STRIP: ConversationThreadPage does not render CurrentTaskStrip above the composer.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PALETTE = (ROOT / "src/ui/components/ui/patterns/CommandPalette.tsx").read_text(encoding="utf-8")
APP_SHELL = (ROOT / "src/ui/components/shell/AppShell.tsx").read_text(encoding="utf-8")
THREAD_PAGE = (ROOT / "src/ui/components/chat/ConversationThreadPage.tsx").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


# REQ-PALETTE-NAV-1: DEFAULT_ACTIONS in CommandPalette.tsx
require(
    "{ id: 'new-conversation', label: 'New conversation', icon: 'plus', hint: 'Start a new conversation', route: '/conversations/new' }" in PALETTE,
    "DEFAULT_ACTIONS must define new-conversation routing to /conversations/new",
)
require(
    "{ id: 'new-agent', label: 'New agent', icon: 'bot', hint: 'Create a durable identity', route: '/agents/new' }" in PALETTE,
    "DEFAULT_ACTIONS must define new-agent routing to /agents/new",
)
require(
    "{ id: 'new-chain', label: 'New task chain', icon: 'tasks', hint: 'Start a chain', route: '/chains' }" in PALETTE,
    "DEFAULT_ACTIONS must define new-chain routing to /chains",
)
require(
    "{ id: 'new-project', label: 'New project', icon: 'grid', hint: 'Grouping + paths', route: '/projects' }" in PALETTE,
    "DEFAULT_ACTIONS must define new-project routing to /projects",
)
require(
    "route?: string;" in PALETTE,
    "PaletteAction and PaletteResult should support route",
)
require(
    "if (result.route) {\n        onNavigate(result.route);\n      }" in PALETTE,
    "CommandPalette activate() should navigate to result.route when action has route",
)

# REQ-PALETTE-NAV-2: AppShell handlePaletteAction and onAction prop
require(
    "const handlePaletteAction = (actionId: string) => {" in APP_SHELL,
    "AppShell must define handlePaletteAction",
)
require(
    "case 'new-conversation':\n        handlePaletteNavigate('/conversations/new');" in APP_SHELL,
    "handlePaletteAction must route new-conversation to /conversations/new",
)
require(
    "case 'new-agent':\n        handlePaletteNavigate('/agents/new');" in APP_SHELL,
    "handlePaletteAction must route new-agent to /agents/new",
)
require(
    "case 'new-chain':\n        handlePaletteNavigate('/chains');" in APP_SHELL,
    "handlePaletteAction must route new-chain to /chains",
)
require(
    "case 'new-project':\n        handlePaletteNavigate('/projects');" in APP_SHELL,
    "handlePaletteAction must route new-project to /projects",
)
require(
    "onAction={handlePaletteAction}" in APP_SHELL,
    "AppShell must pass onAction={handlePaletteAction} to CommandPalette",
)

# REQ-REMOVE-CURRENT-TASK-STRIP: ConversationThreadPage must not render CurrentTaskStrip
require(
    "CurrentTaskStrip" not in THREAD_PAGE,
    "ConversationThreadPage must not import or render CurrentTaskStrip",
)

print("ALL COMMAND PALETTE & CURRENT TASK STRIP STATIC TESTS PASSED")
