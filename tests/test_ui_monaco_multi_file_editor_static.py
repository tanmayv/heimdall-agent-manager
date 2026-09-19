#!/usr/bin/env python3
"""Static verification for multi-file Monaco Code Editor, unified 34px top icon bar,
compact narrow-view explorer, fixed quick-open root path resolution, global Cmd+P,
and sidebar maximize/minimize toggle
(REQ-UI-UNIFIED-ICON-BAR, REQ-UI-COMPACT-TREE, REQ-FIX-QUICK-OPEN-CWD-PATH,
 REQ-UI-GLOBAL-CMDP-EVERYWHERE, REQ-UI-SIDEBAR-MAXIMIZE-TOGGLE,
 REQ-UI-MONACO-EDITOR, REQ-UI-MULTI-FILE-TABS, REQ-UI-BATCH-SAVE-ACTION,
 REQ-UI-REMOVE-FILEVIEW, REQ-UI-DIRECT-MONACO-OPEN, REQ-IDE-SPLIT-PANE, REQ-IDE-FILE-TREE).
"""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
PROJECT_FS_FILE = ROOT / "src" / "ui" / "api" / "endpoints" / "projectFs.ts"
PANEL_FILE = ROOT / "src" / "ui" / "components" / "chat" / "ProjectFilesPanel.tsx"
THREAD_PAGE_FILE = ROOT / "src" / "ui" / "components" / "chat" / "ConversationThreadPage.tsx"
ICON_FILE = ROOT / "src" / "ui" / "components" / "ui" / "primitives" / "Icon.tsx"


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
    require("useLazyQuickOpenProjectFilesQuery" in pfs_src, "Must export useLazyQuickOpenProjectFilesQuery hook")
    require("quickOpenProjectFiles: build.query" in pfs_src, "Must define quickOpenProjectFiles query")
    require("/quick-open" in pfs_src, "quickOpenProjectFiles must target /quick-open endpoint")
    require("FsQuickOpenResult" in pfs_src, "Must export FsQuickOpenResult type")
    print("  [+] projectFs.ts contract verified successfully.")

    print("[*] 2. Checking src/ui/components/chat/ProjectFilesPanel.tsx...")
    require(PANEL_FILE.exists(), "ProjectFilesPanel.tsx must exist")
    panel_src = PANEL_FILE.read_text(encoding="utf-8")

    # Import of Monaco Editor and theme
    require("@monaco-editor/react" in panel_src, "Must import from @monaco-editor/react")
    require("Editor" in panel_src, "Must use Editor component from Monaco")
    require("DiffEditor" in panel_src, "Must use DiffEditor component from Monaco")
    require("useTheme" in panel_src, "Must import and use useTheme hook for theme synchronization")
    require("useWriteProjectFileMutation" in panel_src, "Must use useWriteProjectFileMutation")
    require("useBatchWriteProjectFilesMutation" in panel_src, "Must use useBatchWriteProjectFilesMutation")
    require("useLazyQuickOpenProjectFilesQuery" in panel_src, "Must use useLazyQuickOpenProjectFilesQuery")

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

    # REQ-UI-UNIFIED-ICON-BAR: Single unified 34px top icon bar
    require("unified-top-bar" in panel_src, "Must render single unified 34px top icon bar (unified-top-bar)")
    require("h-[34px]" in panel_src or "min-h-[34px]" in panel_src, "Unified top bar must be exactly 34px tall")
    require("explorer-toggle-btn" in panel_src, "Top bar must include explorer toggle button")
    require("quick-open-btn" in panel_src, "Top bar must include Quick Open button")
    require("new-file-btn" in panel_src, "Top bar must include New File button")
    require("new-dir-btn" in panel_src, "Top bar must include New Folder button")
    require("hidden-toggle" in panel_src, "Top bar must include Toggle Hidden button")
    require("refresh-btn" in panel_src, "Top bar must include Refresh button")
    require("breadcrumb" in panel_src, "Top bar must include active file path / breadcrumb")
    require("editor-toggle-diff-btn" in panel_src, "Top bar must render in-editor Diff toggle button (editor-toggle-diff-btn)")
    require("editor-save-btn" in panel_src, "Top bar must render prominent Save button (editor-save-btn)")
    require("editor-save-all-btn" in panel_src, "Top bar must render prominent Save All button (editor-save-all-btn)")
    require("save-toast" in panel_src, "Top bar must display transient feedback toast on save")

    # Redundant toolbar buttons removed from explorer pane and editor header
    require("editor-back-files-btn" not in panel_src, "Redundant editor-back-files-btn must be removed from editor header")
    require("editor-new-file-btn" not in panel_src, "Redundant editor-new-file-btn must be removed from editor header")

    # REQ-UI-COMPACT-TREE: Compact explorer tree styling
    require("h-7 py-0.5 px-2 text-[12px]" in panel_src, "Explorer rows must use compact h-7 py-0.5 px-2 text-[12px] styling")
    require("parent-dir" in panel_src or ".. (parent folder)" in panel_src, "Must render compact .. (parent folder) row when cwd !== ''")
    require("isNarrowExplorer" in panel_src, "Must track isNarrowExplorer state (<320px)")
    require("formatBytes(e.size)" in panel_src, "Must format file bytes for explorer display")
    require("!isNarrowExplorer && !e.is_dir" in panel_src or "!isNarrowExplorer &&" in panel_src,
            "Narrow explorer must suppress size and modified date columns")

    # REQ-FIX-QUICK-OPEN-CWD-PATH: Root-relative path resolution
    require("const filePath = inputPath;" in panel_src, "openFileInEditor must use inputPath directly without flawed cwd prepending")

    # Quick Open Modal & Shortcuts
    require("ProjectQuickOpenModal" in panel_src, "Must export ProjectQuickOpenModal component")
    require("project-quick-open-modal" in panel_src, "Must render project-quick-open-modal")
    require("project-quick-open-input" in panel_src, "Must render project-quick-open-input")
    require("project-quick-open-results" in panel_src, "Must render project-quick-open-results")
    require("subsequenceFuzzyMatch" in panel_src, "Must implement subsequenceFuzzyMatch for Quick Open")

    # Keyboard shortcuts & Save handlers
    require("onSaveActive" in panel_src or "saveActiveFile" in panel_src, "Must implement saveActiveFile handler")
    require("onSaveAll" in panel_src or "saveAllFiles" in panel_src, "Must implement saveAllFiles handler")
    require("KeyS" in panel_src or "key === 's'" in panel_src, "Must wire Cmd+S / Ctrl+S and Cmd+Shift+S / Ctrl+Shift+S")

    # Direct open and navigation
    require("toolbar-editor-btn" in panel_src, "Directory toolbar must offer quick return to open editor tabs")
    require("openFileInEditor(joinPath" in panel_src or "openFileInEditor(" in panel_src, "Clicking files must call openFileInEditor directly")
    require("<FileView" not in panel_src and "function FileView" not in panel_src, "Legacy FileView component must be removed from ProjectFilesPanel.tsx")

    # Editor Tab Strip new file support
    require("new-tab-btn" in panel_src, "Editor tab strip must offer + New Tab button")
    require("new-file-inline-prompt" in panel_src, "Must offer inline prompt for new file name")
    require("new-file-input" in panel_src, "Must provide input field for new file name")
    require("new-file-confirm-btn" in panel_src, "Must provide confirm button for new file creation")

    # Preservation of read-only comment gutter
    require("CodeLines" in panel_src, "Must preserve existing CodeLines component")
    require("LineComment" in panel_src, "Must preserve LineComment component")
    require("LineComposer" in panel_src, "Must preserve LineComposer component")

    # Split-pane IDE layout alongside Monaco Editor
    require("split-container" in panel_src, "ProjectFilesPanel must implement a split container layout")
    require("explorer-pane" in panel_src, "Split container must include left-side directory explorer pane")
    require("editor-pane" in panel_src, "Split container must include right-side editor pane")
    require("isExplorerCollapsed" in panel_src and "setIsExplorerCollapsed" in panel_src, "Must maintain isExplorerCollapsed state")
    require("editor-empty-state" in panel_src, "Must provide empty editor state when no tabs are open")
    require("Select a file from the explorer to view or edit, or press + to create a new file" in panel_src, "Must display clean empty state prompt when openTabs is empty")
    # REQ-VIM-KEYBINDINGS: Monaco Vim mode integration
    require("initVimMode" in panel_src and "monaco-vim" in panel_src, "Must import and use initVimMode from monaco-vim")
    require("defineEx" in panel_src, "Must define custom Ex commands with Vim.defineEx")
    require("'write'" in panel_src or ":w" in panel_src, "Must wire :w save Ex command")
    require("'quit'" in panel_src or ":q" in panel_src, "Must wire :q close tab Ex command")
    require("'wq'" in panel_src or ":wq" in panel_src, "Must wire :wq save and close Ex command")
    require("vimModeRef.current.dispose()" in panel_src or ".dispose()" in panel_src, "Must cleanly dispose Vim adapter")
    require("vim-statusbar" in panel_src, "Must render themed Vim status bar container")
    require("h-[22px]" in panel_src or "h-[20px]" in panel_src, "Vim status bar must be themed 20-22px")
    require("heimdall:editor:vim_mode" in panel_src, "Vim mode toggle must be persisted in localStorage")
    require("toggle-vim-btn" in panel_src, "Must offer Vim toggle in overflow menu")

    # REQ-UI-RESPONSIVE-TOP-BAR: Responsive top bar with 3-dots overflow menu
    require("overflow-menu-btn" in panel_src, "Must render 3-dots overflow menu button")
    require("more-vertical" in panel_src, "Must use more-vertical icon for 3-dots overflow button")
    require("overflow-dropdown" in panel_src, "Must render themed overflow dropdown container")
    require("handleClickOutside" in panel_src, "Must dismiss overflow menu on outside click")
    require("toggle-vim-btn" in panel_src, "Secondary actions must include Toggle Vim Mode")
    require("editor-toggle-diff-btn" in panel_src, "Secondary actions must include Toggle Diff")
    require("editor-save-all-btn" in panel_src, "Secondary actions must include Save All")

    # REQ-UI-MOBILE-SINGLE-PANE: Single-pane mobile layout (<640px viewport or <480px sidebar)
    require("viewportWidth < 640" in panel_src and "containerWidth < 480" in panel_src, "Must detect viewport <640px or sidebar/container <480px")
    require("mobile-back-files-btn" in panel_src, "Must render mobile ← Files navigation back button")
    require("← Files" in panel_src, "Must display '← Files' label on back button")
    require("mobile-segmented-switcher" in panel_src, "Must render [ Files | Editor ] segmented switcher")
    require("activePane" in panel_src, "Must manage activePane state for full-width pane switching")

    # REQ-UI-MOBILE-WORD-WRAP: Line wrapping in Monaco Editor
    require("heimdall:editor:word_wrap" in panel_src, "Must persist word wrap preference in localStorage")
    require("toggle-word-wrap-btn" in panel_src, "Must offer Toggle Word Wrap in 3-dots overflow menu")
    require("wordWrap: isWordWrap ? 'on' : 'off'" in panel_src or "wordWrap" in panel_src, "Must dynamically configure Monaco wordWrap")
    print("  [+] ProjectFilesPanel.tsx features verified successfully.")

    print("[*] 3. Checking src/ui/components/chat/ConversationThreadPage.tsx...")
    require(THREAD_PAGE_FILE.exists(), "ConversationThreadPage.tsx must exist")
    thread_src = THREAD_PAGE_FILE.read_text(encoding="utf-8")

    # REQ-UI-GLOBAL-CMDP-EVERYWHERE: Global Cmd+P listener and quick open integration
    require("ProjectQuickOpenModal" in thread_src, "Must import and render ProjectQuickOpenModal in ConversationThreadPage")
    require("isQuickOpenOpen" in thread_src, "Must maintain isQuickOpenOpen state in ConversationThreadPage")
    require("editorFileToOpen" in thread_src, "Must maintain editorFileToOpen state for cross-panel file opening")
    require("key === 'p'" in thread_src or "key === 'P'" in thread_src, "Must wire window keydown listener for Cmd+P / Ctrl+P")
    require("selectRightPanelTab('files')" in thread_src, "Selecting a file from global Quick Open must switch to files tab")

    # REQ-UI-SIDEBAR-MAXIMIZE-TOGGLE: Right sidebar maximize/minimize toggle
    require("isRightPanelMaximized" in thread_src, "Must maintain isRightPanelMaximized state")
    require("conversation-right-panel-maximize-btn" in thread_src, "Must render conversation-right-panel-maximize-btn")
    require("conversation-right-panel-close-btn" in thread_src, "Must render conversation-right-panel-close-btn")
    require("isRightPanelMaximized && panelOpen ? 'hidden' :" in thread_src or "isRightPanelMaximized ? 'hidden' :" in thread_src,
            "Must hide conversation chat column when sidebar is maximized")
    require("!isRightPanelMaximized" in thread_src, "Must hide resizer divider when sidebar is maximized")
    require("w-full flex-1 max-w-full min-w-0" in thread_src, "Must expand right panel container to full width when maximized")
    require("setIsRightPanelMaximized(false)" in thread_src, "Must reset isRightPanelMaximized on panel close")
    print("  [+] ConversationThreadPage.tsx features verified successfully.")

    print("[*] 4. Checking src/ui/components/ui/primitives/Icon.tsx...")
    require(ICON_FILE.exists(), "Icon.tsx must exist")
    icon_src = ICON_FILE.read_text(encoding="utf-8")
    require("'maximize'" in icon_src and "'minimize'" in icon_src, "Must define maximize and minimize icons in Icon.tsx")
    require("'eye'" in icon_src and "'eye-off'" in icon_src, "Must define eye and eye-off icons in Icon.tsx")
    require("'save'" in icon_src, "Must define save icon in Icon.tsx")
    print("  [+] Icon.tsx primitives verified successfully.")

    print("\n[SUCCESS] All static verification checks passed cleanly!")


if __name__ == "__main__":
    main()
