#!/usr/bin/env python3
"""Static verification for Persistent Bottom Dock for Shells.
Requirements: REQ-DOCK-1, REQ-DOCK-2, REQ-DOCK-3, REQ-DOCK-4, REQ-DOCK-5
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
BOTTOM_DOCK = ROOT / "src" / "ui" / "components" / "shell" / "BottomDock.tsx"
APP_SHELL = ROOT / "src" / "ui" / "components" / "shell" / "AppShell.tsx"
CONVERSATION_THREAD = ROOT / "src" / "ui" / "components" / "chat" / "ConversationThreadPage.tsx"
CLIENT_PERSISTENCE = ROOT / "src" / "ui" / "utils" / "clientPersistence.ts"
NEW_SHELL_DIALOG = ROOT / "src" / "ui" / "components" / "shells" / "NewShellDialog.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def test_bottom_dock_exists_and_implements_requirements() -> None:
    require(BOTTOM_DOCK.is_file(), f"BottomDock.tsx must exist at {BOTTOM_DOCK}")
    src = BOTTOM_DOCK.read_text(encoding="utf-8")

    # 1. Component uses useListShellsQuery, useKillShellMutation, useListBridgesQuery
    require("useListShellsQuery" in src, "BottomDock.tsx must query useListShellsQuery")
    require("useKillShellMutation" in src, "BottomDock.tsx must call useKillShellMutation on tab close")
    require("useListBridgesQuery" in src, "BottomDock.tsx must query useListBridgesQuery")

    # 2. Uses Select from @ui, no native select
    require("from '@ui'" in src or 'from "@ui"' in src, "BottomDock.tsx must import Select from @ui")
    require("<select" not in src, "BottomDock.tsx must not use native <select>")

    # 3. Renders ShellTerminalPane, ShellJobsPanel, NewShellDialog
    require("<ShellTerminalPane" in src, "BottomDock.tsx must render ShellTerminalPane")
    require("<ShellJobsPanel" in src, "BottomDock.tsx must render ShellJobsPanel")
    require("<NewShellDialog" in src, "BottomDock.tsx must render NewShellDialog")

    # 4. Debug IDs for interactive controls
    require("bottom-dock-container" in src, "BottomDock.tsx must have bottom-dock-container")
    require("bottom-dock-header" in src, "BottomDock.tsx must have bottom-dock-header")
    require("bottom-dock-new-shell-btn" in src, "BottomDock.tsx must have bottom-dock-new-shell-btn")
    require("bottom-dock-tab-jobs" in src, "BottomDock.tsx must have bottom-dock-tab-jobs")
    require("bottom-dock-bridge-select" in src, "BottomDock.tsx must have bottom-dock-bridge-select")
    require("bottom-dock-minimize-btn" in src, "BottomDock.tsx must have bottom-dock-minimize-btn")
    require("bottom-dock-maximize-btn" in src, "BottomDock.tsx must have bottom-dock-maximize-btn")
    require("bottom-dock-close-btn" in src, "BottomDock.tsx must have bottom-dock-close-btn")


def test_app_shell_integration() -> None:
    require(APP_SHELL.is_file(), f"AppShell.tsx must exist at {APP_SHELL}")
    src = APP_SHELL.read_text(encoding="utf-8")

    # 1. Imports BottomDock
    require("BottomDock" in src, "AppShell.tsx must import BottomDock")
    require("<BottomDock" in src, "AppShell.tsx must render <BottomDock")

    # 2. Toggle button in header with debug ID
    require("shell-bottom-dock-toggle-btn" in src,
            "AppShell.tsx header must contain shell-bottom-dock-toggle-btn")

    # 3. Keyboard shortcut handler for Ctrl+`
    require("event.key === '`'" in src or 'event.key === "`"' in src,
            "AppShell.tsx must handle Ctrl+` keydown")


def test_conversation_thread_page_no_shells_tab() -> None:
    require(CONVERSATION_THREAD.is_file(), f"ConversationThreadPage.tsx must exist at {CONVERSATION_THREAD}")
    src = CONVERSATION_THREAD.read_text(encoding="utf-8")

    # 1. Must NOT render shells right panel tab
    require("conversation-right-panel-tab-shells" not in src,
            "ConversationThreadPage.tsx must not render conversation-right-panel-tab-shells")

    # 2. Must NOT import or render ShellsPanel
    require("ShellsPanel" not in src,
            "ConversationThreadPage.tsx must not import or render ShellsPanel")
    require("ShellsTabBadge" not in src,
            "ConversationThreadPage.tsx must not import or render ShellsTabBadge")


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
    test_app_shell_integration()
    test_conversation_thread_page_no_shells_tab()
    test_client_persistence_dock_helpers()
    test_new_shell_dialog_bridge_sync()
    print("PASS: test_ui_bottom_dock_static")


if __name__ == "__main__":
    main()
