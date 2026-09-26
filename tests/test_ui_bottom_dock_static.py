#!/usr/bin/env python3
"""Static verification for Persistent Bottom Dock for Shells.
Requirements: REQ-BAR-1, REQ-BAR-2, REQ-BAR-3, REQ-BAR-4, REQ-BAR-5, REQ-BAR-6, REQ-BAR-7, REQ-BAR-8, REQ-BRIDGE-STATUS-1, REQ-BRIDGE-STATUS-2, REQ-BRIDGE-STATUS-3, REQ-BRIDGE-STATUS-4
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
BOTTOM_DOCK = ROOT / "src" / "ui" / "components" / "shell" / "BottomDock.tsx"
APP_SHELL = ROOT / "src" / "ui" / "components" / "shell" / "AppShell.tsx"
CONVERSATION_THREAD = ROOT / "src" / "ui" / "components" / "chat" / "ConversationThreadPage.tsx"
CLIENT_PERSISTENCE = ROOT / "src" / "ui" / "utils" / "clientPersistence.ts"
NEW_SHELL_DIALOG = ROOT / "src" / "ui" / "components" / "shells" / "NewShellDialog.tsx"
SHELL_TERMINAL_PANE = ROOT / "src" / "ui" / "components" / "shells" / "ShellTerminalPane.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def test_bottom_dock_exists_and_implements_requirements() -> None:
    require(BOTTOM_DOCK.is_file(), f"BottomDock.tsx must exist at {BOTTOM_DOCK}")
    src = BOTTOM_DOCK.read_text(encoding="utf-8")

    # 1. Component queries live shells across all bridges without bridge selector
    require("useListShellsQuery" in src, "BottomDock.tsx must query useListShellsQuery")
    require("status: 'live'" in src or 'status: "live"' in src, "BottomDock.tsx must query live shells")
    require("useKillShellMutation" in src, "BottomDock.tsx must call useKillShellMutation on tab close")

    # 2. Horizontal sidescrolling tabs
    require("overflow-x-auto" in src, "BottomDock.tsx must support horizontal sidescrolling")
    require("shrink-0" in src, "BottomDock.tsx tabs must have shrink-0")

    # 3. Removal of Jobs tab and bridge selector
    require("bottom-dock-tab-jobs" not in src, "BottomDock.tsx must not contain bottom-dock-tab-jobs")
    require("bottom-dock-bridge-select" not in src, "BottomDock.tsx must not contain bottom-dock-bridge-select")
    require("ShellJobsPanel" not in src, "BottomDock.tsx must not render ShellJobsPanel")

    # 4. Renders ShellTerminalPane, NewShellDialog
    require("<ShellTerminalPane" in src, "BottomDock.tsx must render ShellTerminalPane")
    require("<NewShellDialog" in src, "BottomDock.tsx must render NewShellDialog")

    # 5. Debug IDs for interactive controls
    require("bottom-dock-container" in src, "BottomDock.tsx must have bottom-dock-container")
    require("bottom-dock-header" in src, "BottomDock.tsx must have bottom-dock-header")
    require("bottom-dock-new-shell-btn" in src, "BottomDock.tsx must have bottom-dock-new-shell-btn")
    require("bottom-dock-minimize-btn" in src, "BottomDock.tsx must have bottom-dock-minimize-btn")
    require("bottom-dock-maximize-btn" not in src, "BottomDock.tsx must not have bottom-dock-maximize-btn")
    require("bottom-dock-close-btn" not in src, "BottomDock.tsx must not have bottom-dock-close-btn")

    # 6. Subtle vault status badge in BottomDock right controls
    require("vault-header-status-badge" in src, "BottomDock.tsx must have vault-header-status-badge")
    require("text-[11px]" in src, "BottomDock.tsx vault badge must be subtle text-[11px]")
    require("/settings/vault" in src, "BottomDock.tsx vault badge must navigate to /settings/vault")

    # 7. Subtle active tab styling
    require("border-subtle bg-surface-secondary" in src, "BottomDock.tsx active tab must use subtle styling")

    # 8. Collapses to 36px bar
    require("36" in src, "BottomDock.tsx must collapse to 36px bar")

    # 9. Optimistic shell tab close (REQ-OPT-CLOSE-1)
    require("closingSessionIds" in src, "BottomDock.tsx must track closingSessionIds for optimistic tab close")

    # 10. Immediate new shell focus via pendingSessions (REQ-NEW-SHELL-2)
    require("pendingSessions" in src, "BottomDock.tsx must maintain pendingSessions for immediate shell focus")

    # 11. Viewport-bounded dock sizing (REQ-DOCK-BOUNDS-3)
    require("max-h-[80vh]" in src or "min(calc(100vh - 100px), 80vh)" in src,
            "BottomDock.tsx container must bound maxHeight to viewport")
    require("Math.floor(window.innerHeight * 0.8)" in src or "window.innerHeight - 100" in src,
            "BottomDock.tsx resize handler must clamp to viewport bounds")

    # 12. Expand collapsed dock on tab click and auto-scroll active tab into view
    require("setIsMinimized(false)" in src and "writeBottomDockOpen(true)" in src,
            "BottomDock.tsx tab click must expand minimized dock")
    require("scrollIntoView" in src,
            "BottomDock.tsx active tab must auto-scroll into view")
    require("activeTabRef" in src,
            "BottomDock.tsx must track activeTabRef for scrollIntoView")

    # 13. Bridge status query and unreachable feedback (REQ-BRIDGE-STATUS-1, REQ-BRIDGE-STATUS-2)
    require("useListBridgesQuery" in src, "BottomDock.tsx must query useListBridgesQuery for bridge reachability")
    require("isBridgeReachable" in src, "BottomDock.tsx must resolve bridge reachability for session bridges")
    require("Bridge unreachable" in src, "BottomDock.tsx must include '(Bridge unreachable)' in tab tooltip when offline")


def test_shell_terminal_pane_full_parent() -> None:
    require(SHELL_TERMINAL_PANE.is_file(), f"ShellTerminalPane.tsx must exist at {SHELL_TERMINAL_PANE}")
    src = SHELL_TERMINAL_PANE.read_text(encoding="utf-8")

    # 1. Outer container fills parent container and uses bg-canvas
    require("flex-1" in src and "h-full" in src and "min-h-0" in src,
            "ShellTerminalPane.tsx outer container must have flex-1 h-full min-h-0")
    require("bg-canvas" in src, "ShellTerminalPane.tsx must use bg-canvas without card styling")

    # 2. Inner xterm container uses flex-1 min-h-0 w-full rather than fixed h-[360px]
    require("h-[360px]" not in src, "ShellTerminalPane.tsx must not use fixed h-[360px]")
    require("flex-1" in src and "min-h-0" in src and "w-full" in src,
            "ShellTerminalPane.tsx xterm container must use flex-1 min-h-0 w-full")

    # 3. Inner header is removed (no status dot or action buttons in pane header)
    require("border-b border-subtle bg-surface-raised" not in src,
            "ShellTerminalPane.tsx must not contain inner header bar")
    require("SIGINT" not in src, "ShellTerminalPane.tsx must not contain header SIGINT button")
    require("Restart" not in src, "ShellTerminalPane.tsx must not contain header Restart button")

    # 4. Loading indicator overlay (REQ-NEW-SHELL-2)
    require("shell-terminal-loading-" in src,
            "ShellTerminalPane.tsx must render shell-terminal-loading- indicator")
    require("Connecting to terminal" in src,
            "ShellTerminalPane.tsx must show Connecting to terminal text")

    # 5. Terminal focus on init / resize
    require("term.focus()" in src,
            "ShellTerminalPane.tsx must call term.focus() for immediate keyboard focus")

    # 6. Bridge unreachable overlay and non-destructive banner (REQ-BRIDGE-STATUS-3, REQ-BRIDGE-STATUS-4)
    require("shell-terminal-unreachable" in src,
            "ShellTerminalPane.tsx must render shell-terminal-unreachable feedback overlay")
    require("Bridge Unreachable" in src,
            "ShellTerminalPane.tsx must render 'Bridge Unreachable' text")
    require("Retry" in src,
            "ShellTerminalPane.tsx must include a Retry button in bridge unreachable feedback")
    require("shell-terminal-unreachable-banner" in src,
            "ShellTerminalPane.tsx must render shell-terminal-unreachable-banner when output exists")


def test_app_shell_integration() -> None:
    require(APP_SHELL.is_file(), f"AppShell.tsx must exist at {APP_SHELL}")
    src = APP_SHELL.read_text(encoding="utf-8")

    # 1. Imports and persistently renders BottomDock
    require("BottomDock" in src, "AppShell.tsx must import BottomDock")
    require("<BottomDock" in src, "AppShell.tsx must render <BottomDock")
    require("{isBottomDockOpen &&" not in src, "AppShell.tsx must persistently render BottomDock")

    # 2. Top bar is completely removed
    require("shell-top-header" not in src,
            "AppShell.tsx must not contain shell-top-header")
    require("shell-bottom-dock-toggle-btn" not in src,
            "AppShell.tsx must not contain shell-bottom-dock-toggle-btn")

    # 3. Keyboard shortcut handler for Ctrl+`
    require("event.key === '`'" in src or 'event.key === "`"' in src,
            "AppShell.tsx must handle Ctrl+` keydown")

    # 4. Route outlet flex containers shrink above bottom dock (REQ-DOCK-BOUNDS-3)
    require('data-debug-id="shell-main-route-outlet"' in src and "min-h-0" in src,
            "AppShell.tsx shell-main-route-outlet must include min-h-0")


def test_conversation_thread_page_no_shells_tab() -> None:
    require(CONVERSATION_THREAD.is_file(), f"ConversationThreadPage.tsx must exist at {CONVERSATION_THREAD}")
    src = CONVERSATION_THREAD.read_text(encoding="utf-8")

    # 1. Must NOT render shells right panel tab
    require("conversation-right-panel-tab-shells" not in src,
            "ConversationThreadPage.tsx must not render conversation-right-panel-tab-shells")

    # 2. Must NOT import or render ShellsPanel
    require("ShellsPanel" not in src,
            "ConversationThreadPage.tsx must not render ShellsPanel")
    require("ShellsTabBadge" not in src,
            "ConversationThreadPage.tsx must not render ShellsTabBadge")


def test_client_persistence_dock_helpers() -> None:
    require(CLIENT_PERSISTENCE.is_file(), f"clientPersistence.ts must exist at {CLIENT_PERSISTENCE}")
    src = CLIENT_PERSISTENCE.read_text(encoding="utf-8")

    require("readBottomDockOpen" in src, "clientPersistence.ts must export readBottomDockOpen")
    require("writeBottomDockOpen" in src, "clientPersistence.ts must export writeBottomDockOpen")
    require("readBottomDockHeight" in src, "clientPersistence.ts must export readBottomDockHeight")
    require("writeBottomDockHeight" in src, "clientPersistence.ts must export writeBottomDockHeight")


def test_new_shell_dialog_bridge_sync() -> None:
    require(NEW_SHELL_DIALOG.is_file(), f"NewShellDialog.tsx must exist at {NEW_SHELL_DIALOG}")
    src = NEW_SHELL_DIALOG.read_text(encoding="utf-8")

    require("bridgeId" in src, "NewShellDialog.tsx must accept bridgeId")
    require("setSelectedBridgeId(bridgeId)" in src,
            "NewShellDialog.tsx must sync bridgeId into selectedBridgeId")


def main() -> None:
    test_bottom_dock_exists_and_implements_requirements()
    test_shell_terminal_pane_full_parent()
    test_app_shell_integration()
    test_conversation_thread_page_no_shells_tab()
    test_client_persistence_dock_helpers()
    test_new_shell_dialog_bridge_sync()
    print("PASS: test_ui_bottom_dock_static")


if __name__ == "__main__":
    main()
