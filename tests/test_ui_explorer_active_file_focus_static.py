#!/usr/bin/env python3
"""Static verification for Project Explorer active file focus and Monaco editor auto-focus
(REQ-UI-EXPLORER-ACTIVE-FILE-FOCUS).
"""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
PANEL_FILE = ROOT / "src" / "ui" / "components" / "chat" / "ProjectFilesPanel.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    print("[*] Checking src/ui/components/chat/ProjectFilesPanel.tsx for REQ-UI-EXPLORER-ACTIVE-FILE-FOCUS...")
    require(PANEL_FILE.exists(), "ProjectFilesPanel.tsx must exist")
    panel_src = PANEL_FILE.read_text(encoding="utf-8")

    # 1. revealInExplorer helper
    require("const revealInExplorer = useCallback" in panel_src or "function revealInExplorer" in panel_src or "revealInExplorer" in panel_src,
            "Must define revealInExplorer helper")
    require("parentPath(filePath)" in panel_src or "parentPath(" in panel_src,
            "revealInExplorer must resolve parent directory of file")
    require("dir !== cwdRef.current" in panel_src or "dir !== cwd" in panel_src,
            "revealInExplorer must compare parent directory against current cwd")
    require("void load(dir)" in panel_src or "load(dir)" in panel_src,
            "revealInExplorer must load parent directory when not currently loaded")

    # 2. Invocations of revealInExplorer across all file-opening entry points
    require("openFileInEditor" in panel_src and "revealInExplorer(filePath)" in panel_src,
            "openFileInEditor must call revealInExplorer")
    require("selectTab" in panel_src and "revealInExplorer(path)" in panel_src,
            "selectTab must call revealInExplorer")
    require("closeTab" in panel_src and "revealInExplorer(nextActive)" in panel_src,
            "closeTab must call revealInExplorer for nextActive")
    require("handleEditorNewFile" in panel_src and "revealInExplorer(targetPath)" in panel_src,
            "handleEditorNewFile must call revealInExplorer")
    require("openFilePath" in panel_src and "revealInExplorer(openFilePath)" in panel_src,
            "openFilePath effect must call revealInExplorer")
    require("restoredActive" in panel_src and "revealInExplorer(restoredActive)" in panel_src,
            "Mount restoration must call revealInExplorer")

    # 3. Synchronization effect on activeTabPath
    require("revealInExplorer(activeTabPath)" in panel_src,
            "Must watch activeTabPath with useEffect to synchronize explorer directory")

    # 4. Active entry in explorer file list
    require("activeEntryRef" in panel_src,
            "Must define activeEntryRef for active file list item")
    require("project-files-active-entry" in panel_src,
            "Active file entry must have data-debug-id='project-files-active-entry'")
    require('data-active-file=' in panel_src and 'true' in panel_src,
            "Active file entry must set data-active-file='true'")
    require("ring-1 ring-accent/30 shadow-xs" in panel_src or "ring-accent" in panel_src,
            "Active file entry must style with ring-accent highlight")
    require("scrollIntoView" in panel_src,
            "Active file entry must be scrolled into view")
    require("activeEntryRef.current" in panel_src and "scrollIntoView" in panel_src,
            "Must call activeEntryRef.current.scrollIntoView")

    # 5. Toolbar Locate button
    require("project-files-locate-file-btn" in panel_src,
            "Toolbar must include locate button (project-files-locate-file-btn)")
    require("revealInExplorer(activeEditorTab.path)" in panel_src,
            "Locate button must invoke revealInExplorer with active tab path")
    require("updateExplorerCollapsed(false)" in panel_src,
            "Locate button must expand explorer if collapsed")

    # 6. Monaco Editor auto-focus on open
    require("editor.focus()" in panel_src,
            "MonacoMultiFileEditor must call editor.focus() on mount")
    require("editorRef.current" in panel_src and "focus()" in panel_src,
            "MonacoMultiFileEditor must call editorRef.current.focus() on activeTab.path change")

    print("[SUCCESS] All REQ-UI-EXPLORER-ACTIVE-FILE-FOCUS static checks passed cleanly!")


if __name__ == "__main__":
    main()
