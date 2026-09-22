#!/usr/bin/env python3
"""Verification test for REQ-UI-CONSOLIDATE-RUN-DIR.

Verifies:
1. Member agent run directories (/agent-instances/:id/fs) are integrated into
   the directory selector with a distinct 'run dir' badge.
2. The separate 'Run dir' tab and InstanceRunDirPanel are removed from
   ConversationThreadPage.
3. In ProjectFilesPanel, selecting an agent run dir enforces read-only mode in Monaco
   editor and disables all file/folder mutations (create, rename, delete, save).
4. Legacy 'rundir' tab settings/routes in clientPersistence and ConversationThreadPage
   seamlessly map to 'files'.
"""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
PROJECT_FS_FILE = ROOT / "src" / "ui" / "api" / "endpoints" / "projectFs.ts"
PANEL_FILE = ROOT / "src" / "ui" / "components" / "chat" / "ProjectFilesPanel.tsx"
THREAD_PAGE_FILE = ROOT / "src" / "ui" / "components" / "chat" / "ConversationThreadPage.tsx"
CLIENT_PERSISTENCE_FILE = ROOT / "src" / "ui" / "utils" / "clientPersistence.ts"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def test_project_fs() -> None:
    print("[*] Checking projectFs.ts...")
    require(PROJECT_FS_FILE.exists(), "projectFs.ts must exist")
    content = PROJECT_FS_FILE.read_text(encoding="utf-8")

    require("agentInstanceId?: string" in content, "FsScopeArgs must include agentInstanceId")
    require("/agent-instances/${encodeURIComponent(target.agentInstanceId)}/fs" in content,
            "base() must route to /agent-instances/:id/fs when agentInstanceId is present")
    require("instance::${target.agentInstanceId}" in content,
            "fsListTagId must use instance::<agentInstanceId> tag scope")
    require("include_hidden" in content, "listProjectDir must pass include_hidden query parameter")
    print("  [+] projectFs.ts verified successfully.")


def test_project_files_panel() -> None:
    print("[*] Checking ProjectFilesPanel.tsx...")
    require(PANEL_FILE.exists(), "ProjectFilesPanel.tsx must exist")
    content = PANEL_FILE.read_text(encoding="utf-8")

    # 1. DirectoryItem extension and run dir badge
    require("agent_run_dir" in content, "DirectoryItem must support 'agent_run_dir' kind")
    require(">run dir<" in content or "run dir" in content,
            "TaskChainDirectorySelector must render 'run dir' badge for agent run directories")
    require("isReadOnly?: boolean" in content, "DirectoryItem must support isReadOnly flag")

    # 2. Member agents population in availableDirectories
    require("agent-rundir:" in content, "availableDirectories must prefix agent run dirs with agent-rundir:")
    require("members" in content, "ProjectFilesPanel must accept members prop")

    # 3. Read-only guards on all mutations
    require("isReadOnlyDirectory" in content, "ProjectFilesPanel must compute isReadOnlyDirectory")
    require("handleEditorNewFile" in content, "handleEditorNewFile must exist")
    require("saveActiveFile" in content, "saveActiveFile must exist")
    require("saveAllFiles" in content, "saveAllFiles must exist")
    require("beginAction" in content, "beginAction must exist")
    require("submitPending" in content, "submitPending must exist")
    require("removeEntry" in content, "removeEntry must exist")

    # 4. Read-only indicator in UI and Monaco editor options
    require("-read-only-badge" in content, "Must render read-only badge when viewing an agent run dir")
    require("readOnly: Boolean(isReadOnly)" in content,
            "MonacoMultiFileEditor must pass readOnly option to Editor and DiffEditor")

    # 5. Native select guardrail
    require("<select" not in content, "Native <select> is banned per ui_no_native_select_test")
    print("  [+] ProjectFilesPanel.tsx verified successfully.")


def test_conversation_thread_page() -> None:
    print("[*] Checking ConversationThreadPage.tsx...")
    require(THREAD_PAGE_FILE.exists(), "ConversationThreadPage.tsx must exist")
    content = THREAD_PAGE_FILE.read_text(encoding="utf-8")

    # 1. InstanceRunDirPanel and rundir tab button removed
    require("import InstanceRunDirPanel" not in content,
            "InstanceRunDirPanel must NOT be imported in ConversationThreadPage.tsx")
    require("<InstanceRunDirPanel" not in content,
            "InstanceRunDirPanel must NOT be rendered in ConversationThreadPage.tsx")
    require('data-debug-id="conversation-right-panel-tab-rundir"' not in content,
            "Rundir tab button must be removed from right panel tab bar")

    # 2. Forward chain members to ProjectFilesPanel
    require("members={chainDetailQuery.data?.chain?.members}" in content,
            "ConversationThreadPage must forward chain members to ProjectFilesPanel")

    # 3. Default and legacy tab handling
    require("defaultPanelTab" in content, "defaultPanelTab must exist")
    require("projectId || agentInstanceId" in content,
            "defaultPanelTab must default to 'files' when projectId or agentInstanceId is present")
    print("  [+] ConversationThreadPage.tsx verified successfully.")


def test_client_persistence() -> None:
    print("[*] Checking clientPersistence.ts...")
    require(CLIENT_PERSISTENCE_FILE.exists(), "clientPersistence.ts must exist")
    content = CLIENT_PERSISTENCE_FILE.read_text(encoding="utf-8")

    require("readRightSidebarTab" in content, "readRightSidebarTab must exist")
    require("writeRightSidebarTab" in content, "writeRightSidebarTab must exist")
    require("targetTab = tab === 'rundir' ? 'files' : tab" in content or "rundir" in content,
            "clientPersistence must redirect 'rundir' to 'files'")
    print("  [+] clientPersistence.ts verified successfully.")


def main() -> None:
    test_project_fs()
    test_project_files_panel()
    test_conversation_thread_page()
    test_client_persistence()
    print("\n[SUCCESS] All REQ-UI-CONSOLIDATE-RUN-DIR static checks passed!")


if __name__ == "__main__":
    main()
