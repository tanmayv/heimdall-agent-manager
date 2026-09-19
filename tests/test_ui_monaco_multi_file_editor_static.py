#!/usr/bin/env python3
"""Static verification for multi-file Monaco Code Editor with dirty state tracking,
tabs, and single/batch save (REQ-UI-MONACO-EDITOR, REQ-UI-MULTI-FILE-TABS, REQ-UI-BATCH-SAVE-ACTION, REQ-UI-REMOVE-FILEVIEW, REQ-UI-DIRECT-MONACO-OPEN).
"""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
PROJECT_FS_FILE = ROOT / "src" / "ui" / "api" / "endpoints" / "projectFs.ts"
PANEL_FILE = ROOT / "src" / "ui" / "components" / "chat" / "ProjectFilesPanel.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    print("[*] 1. Checking src/ui/api/endpoints/projectFs.ts...")
    require(PROJECT_FS_FILE.exists(), "projectFs.ts must exist")
    pfs_src = PROJECT_FS_FILE.read_text(encoding="utf-8")

    # Types exported
    require("export type FsWriteResult" in pfs_src, "Must export FsWriteResult type")
    require("bytes_written" in pfs_src and "modified_at" in pfs_src, "FsWriteResult must have bytes_written and modified_at")
    require("export type FsBatchWriteResult" in pfs_src, "Must export FsBatchWriteResult type")
    require("saved: FsSavedItem[]" in pfs_src or "saved:" in pfs_src, "FsBatchWriteResult must include saved items array")
    require("errors: FsErrorItem[]" in pfs_src or "errors:" in pfs_src, "FsBatchWriteResult must include errors array")

    # Mutation endpoints
    require("writeProjectFile: build.mutation" in pfs_src, "Must define writeProjectFile mutation")
    require("batchWriteProjectFiles: build.mutation" in pfs_src, "Must define batchWriteProjectFiles mutation")
    require("cookieMutation" in pfs_src, "Must use cookieMutation")
    require("/file" in pfs_src, "writeProjectFile must target /file endpoint")
    require("/files" in pfs_src, "batchWriteProjectFiles must target /files endpoint")

    # Cache tag invalidations
    require("invalidatesTags" in pfs_src, "Endpoints must define invalidatesTags")
    require("parentOf" in pfs_src, "Cache invalidations must compute parent directory")

    # Exported hooks
    require("useWriteProjectFileMutation" in pfs_src, "Must export useWriteProjectFileMutation hook")
    require("useBatchWriteProjectFilesMutation" in pfs_src, "Must export useBatchWriteProjectFilesMutation hook")
    print("  [+] projectFs.ts contract verified successfully.")

    print("[*] 2. Checking src/ui/components/chat/ProjectFilesPanel.tsx...")
    require(PANEL_FILE.exists(), "ProjectFilesPanel.tsx must exist")
    panel_src = PANEL_FILE.read_text(encoding="utf-8")

    # Import of Monaco Editor and theme
    require("@monaco-editor/react" in panel_src, "Must import from @monaco-editor/react")
    require("Editor" in panel_src, "Must use Editor component from Monaco")
    require("useTheme" in panel_src, "Must import and use useTheme hook for theme synchronization")
    require("useWriteProjectFileMutation" in panel_src, "Must use useWriteProjectFileMutation")
    require("useBatchWriteProjectFilesMutation" in panel_src, "Must use useBatchWriteProjectFilesMutation")

    # Tab state
    require("openTabs" in panel_src and "setOpenTabs" in panel_src, "Must maintain openTabs state")
    require("activeTabPath" in panel_src and "setActiveTabPath" in panel_src, "Must maintain activeTabPath state")
    require("isEditMode" in panel_src and "setIsEditMode" in panel_src, "Must maintain isEditMode state")
    require("isDirty" in panel_src, "Must track isDirty state for tabs")
    require("initialContent" in panel_src, "Must track initialContent for dirty comparison")

    # Full content fetching with pagination
    require("fetchAllFileContent" in panel_src, "Must define fetchAllFileContent helper to buffer full content across pages")
    require("bytes_returned" in panel_src and "offset" in panel_src, "fetchAllFileContent must page through byte ranges")

    # Monaco Multi-file editor component
    require("MonacoMultiFileEditor" in panel_src, "Must implement MonacoMultiFileEditor component")
    require("getLanguageForMonaco" in panel_src, "Must map file paths to Monaco languages")
    require("tab-strip" in panel_src, "Must render tab strip")
    require("tab-dirty-bullet" in panel_src or "•" in panel_src, "Must display dirty bullet indicator on modified tabs")
    require("tab-close-btn" in panel_src, "Must have close tab button")
    require("close-confirm-modal" in panel_src, "Must provide confirmation modal when closing dirty tab")

    # Keyboard shortcuts & Save buttons
    require("onSaveActive" in panel_src or "saveActiveFile" in panel_src, "Must implement saveActiveFile handler")
    require("onSaveAll" in panel_src or "saveAllFiles" in panel_src, "Must implement saveAllFiles handler")
    require("editor-save-btn" in panel_src, "Must render prominent Save button")
    require("editor-save-all-btn" in panel_src, "Must render prominent Save All button")
    require("save-toast" in panel_src, "Must display transient feedback toast on save")
    require("KeyS" in panel_src or "key === 's'" in panel_src, "Must wire Cmd+S / Ctrl+S and Cmd+Shift+S / Ctrl+Shift+S")

    # Direct open and navigation (REQ-UI-REMOVE-FILEVIEW, REQ-UI-DIRECT-MONACO-OPEN)
    require("editor-back-files-btn" in panel_src, "MonacoMultiFileEditor must provide back button to return to directory browser")
    require("toolbar-editor-btn" in panel_src, "Directory toolbar must offer quick return to open editor tabs")
    require("openFileInEditor(joinPath" in panel_src or "openFileInEditor(" in panel_src, "Clicking files must call openFileInEditor directly")
    require("<FileView" not in panel_src and "function FileView" not in panel_src, "Legacy FileView component must be removed from ProjectFilesPanel.tsx")

    # New file creation support
    require("editor-new-file-btn" in panel_src, "Editor header must offer New File action")
    require("new-tab-btn" in panel_src, "Editor tab strip must offer + New Tab button")
    require("new-file-inline-prompt" in panel_src, "Must offer inline prompt for new file name")
    require("new-file-input" in panel_src, "Must provide input field for new file name")
    require("new-file-confirm-btn" in panel_src, "Must provide confirm button for new file creation")
    require("handleEditorNewFile" in panel_src, "Must implement handleEditorNewFile callback")
    require("isNew" in panel_src, "Must track isNew flag for newly created tabs")
    require("openFileInEditor(targetPath)" in panel_src, "Directory browser new file creation must open directly in editor")

    # Preservation of read-only comment gutter
    require("CodeLines" in panel_src, "Must preserve existing CodeLines component")
    require("LineComment" in panel_src, "Must preserve LineComment component")
    require("LineComposer" in panel_src, "Must preserve LineComposer component")
    print("  [+] ProjectFilesPanel.tsx editor features verified successfully.")

    print("\n[SUCCESS] All static verification checks passed cleanly!")


if __name__ == "__main__":
    main()
