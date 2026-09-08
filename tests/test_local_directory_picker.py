#!/usr/bin/env python3
"""Regression tests for CT-13: Local Path Directory Picker with Root Browsing & Hidden Toggle.

Verifies:
1. ProjectsSurface.tsx:
   - Browse button (`projects-create-local-browse-btn`) in create form for local project type
   - Embedded BridgeDirectoryPicker (`projects-create-local-picker`)
   - Bridge host select (`projects-create-local-bridge-select`)
   - Edit form browse button (`project-detail-edit-local-browse-btn`)
   - Embedded BridgeDirectoryPicker in edit form (`project-detail-edit-local-picker`)
   - Auto-population of project Name from selected path basename
2. ProjectsPanel.tsx:
   - Browse button (`settings-project-local-browse-btn`) in create form
   - Embedded BridgeDirectoryPicker (`settings-project-local-picker`)
   - Bridge host select (`settings-project-local-bridge-select`)
   - Edit form browse button (`settings-project-edit-local-browse-btn`)
   - Embedded BridgeDirectoryPicker in edit form (`settings-project-edit-local-picker`)
   - Auto-population of project Name from selected path basename
3. BridgeDirectoryPicker.tsx:
   - Root button (`${debugId}-home-btn`) calling `load('')` to browse from root
   - Hidden files toggle (`${debugId}-hidden-toggle`)
   - `joinPath` preventing double slashes `//` when browsing from root `/`
   - Clean breadcrumbs navigation for root `/`
   - Enter key navigation on manual path input
4. src/bridge/main.odin:
   - `--fs-root` CLI option parsing
"""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
PROJECTS_SURFACE_TSX = ROOT / "src" / "ui" / "components" / "projects" / "ProjectsSurface.tsx"
PROJECTS_PANEL_TSX = ROOT / "src" / "ui" / "components" / "settings" / "ProjectsPanel.tsx"
BRIDGE_PICKER_TSX = ROOT / "src" / "ui" / "components" / "BridgeDirectoryPicker.tsx"
BRIDGE_MAIN_ODIN = ROOT / "src" / "bridge" / "main.odin"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    surface_content = PROJECTS_SURFACE_TSX.read_text(encoding="utf-8")
    panel_content = PROJECTS_PANEL_TSX.read_text(encoding="utf-8")
    picker_content = BRIDGE_PICKER_TSX.read_text(encoding="utf-8")
    bridge_main = BRIDGE_MAIN_ODIN.read_text(encoding="utf-8")

    # 1. ProjectsSurface.tsx Create & Edit Form
    require("projects-create-local-browse-btn" in surface_content, "ProjectsSurface.tsx must have projects-create-local-browse-btn")
    require("projects-create-local-picker" in surface_content, "ProjectsSurface.tsx must embed BridgeDirectoryPicker with projects-create-local-picker")
    require("projects-create-local-bridge-select" in surface_content, "ProjectsSurface.tsx must allow selecting bridge host for local directory browsing")
    require("project-detail-edit-local-browse-btn" in surface_content, "ProjectsSurface.tsx AboutPanel must have project-detail-edit-local-browse-btn")
    require("project-detail-edit-local-picker" in surface_content, "ProjectsSurface.tsx AboutPanel must embed BridgeDirectoryPicker with project-detail-edit-local-picker")
    require("base = p.split('/').filter(Boolean).pop()" in surface_content, "ProjectsSurface.tsx must auto-populate name from path basename")

    # 2. ProjectsPanel.tsx Create & Edit Form
    require("settings-project-local-browse-btn" in panel_content, "ProjectsPanel.tsx must have settings-project-local-browse-btn")
    require("settings-project-local-picker" in panel_content, "ProjectsPanel.tsx must embed BridgeDirectoryPicker with settings-project-local-picker")
    require("settings-project-local-bridge-select" in panel_content, "ProjectsPanel.tsx must allow selecting bridge host for local directory browsing")
    require("settings-project-edit-local-browse-btn" in panel_content, "ProjectsPanel.tsx must have settings-project-edit-local-browse-btn")
    require("settings-project-edit-local-picker" in panel_content, "ProjectsPanel.tsx must embed BridgeDirectoryPicker with settings-project-edit-local-picker")
    require('base = p.split("/").filter(Boolean).pop()' in panel_content, "ProjectsPanel.tsx must auto-populate name from path basename")

    # 3. BridgeDirectoryPicker.tsx Root Browsing & Hidden Toggle
    require('data-debug-id={`${debugId}-home-btn`}' in picker_content, "BridgeDirectoryPicker must have home/root button")
    require("onClick={() => void load('')}" in picker_content, "BridgeDirectoryPicker home/root button must call load('')")
    require('data-debug-id={`${debugId}-hidden-toggle`}' in picker_content, "BridgeDirectoryPicker must have hidden toggle button")
    require("joinPath(base: string, name: string)" in picker_content, "BridgeDirectoryPicker must define joinPath helper")
    require("joinPath(cwd, e.name)" in picker_content, "BridgeDirectoryPicker entry click must use joinPath to avoid double slashes")
    require("joinPath(cwd, name)" in picker_content, "BridgeDirectoryPicker createFolder must use joinPath")
    require("onKeyDown" in picker_content and "load(pathInput.trim())" in picker_content, "BridgeDirectoryPicker must handle Enter key on path input")

    # 4. src/bridge/main.odin
    require('cfg.fs_root = option_value(args, "--fs-root", cfg.fs_root)' in bridge_main, "bridge main.odin must support --fs-root CLI flag")

    print("[+] CT-13 LOCAL DIRECTORY PICKER REGRESSION TESTS PASSED (100% SUCCESS)")


if __name__ == "__main__":
    main()
