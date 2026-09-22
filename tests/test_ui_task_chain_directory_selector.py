#!/usr/bin/env python3
"""Verification test for REQ-UI-TASK-CHAIN-DIRECTORY-SELECTOR,
REQ-UI-DIRECTORY-BRIDGE-DISPLAY, REQ-UI-PER-DIRECTORY-MONACO-INSTANCES,
and REQ-UI-DIRECTORY-SCOPED-QUICK-OPEN.
"""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
TASKS_FILE = ROOT / "src" / "ui" / "api" / "endpoints" / "tasks.ts"
PROJECT_FS_FILE = ROOT / "src" / "ui" / "api" / "endpoints" / "projectFs.ts"
PANEL_FILE = ROOT / "src" / "ui" / "components" / "chat" / "ProjectFilesPanel.tsx"
THREAD_PAGE_FILE = ROOT / "src" / "ui" / "components" / "chat" / "ConversationThreadPage.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def test_tasks_endpoints() -> None:
    print("[*] Checking tasks.ts...")
    require(TASKS_FILE.exists(), "tasks.ts must exist")
    content = TASKS_FILE.read_text(encoding="utf-8")

    require("export type TaskChainDirectory" in content, "Must export TaskChainDirectory type")
    require("directoryId: string" in content, "TaskChainDirectory must have directoryId")
    require("path: string" in content, "TaskChainDirectory must have path")
    require("bridgeId: string" in content, "TaskChainDirectory must have bridgeId")
    require("vcsKind: string" in content, "TaskChainDirectory must have vcsKind")
    require("export function normalizeTaskChainDirectory" in content, "Must export normalizeTaskChainDirectory")
    require("directories: (data.directories || []).map(normalizeTaskChainDirectory)" in content,
            "normalizeTaskChainDetail must include normalized directories")
    require("addChainDirectory: build.mutation" in content, "Must define addChainDirectory mutation")
    require("useAddChainDirectoryMutation" in content, "Must export useAddChainDirectoryMutation")
    print("  [+] tasks.ts verified successfully.")


def test_project_fs_endpoints() -> None:
    print("[*] Checking projectFs.ts...")
    require(PROJECT_FS_FILE.exists(), "projectFs.ts must exist")
    content = PROJECT_FS_FILE.read_text(encoding="utf-8")

    require("export type FsScopeArgs" in content, "Must export FsScopeArgs type")
    require("chainId?: string" in content, "FsScopeArgs must include chainId")
    require("directoryId?: string" in content, "FsScopeArgs must include directoryId")
    require("/task-chains/${encodeURIComponent(target.chainId)}/directories/${encodeURIComponent(target.directoryId)}/fs" in content,
            "base() must route extra task chain directories to /task-chains/:chainId/directories/:dirId/fs")
    require("quickOpenProjectFiles: build.query" in content, "quickOpenProjectFiles query must exist")
    require("matches" in content or "files" in content, "quickOpenProjectFiles must handle matches or files")
    print("  [+] projectFs.ts verified successfully.")


def test_project_files_panel() -> None:
    print("[*] Checking ProjectFilesPanel.tsx...")
    require(PANEL_FILE.exists(), "ProjectFilesPanel.tsx must exist")
    content = PANEL_FILE.read_text(encoding="utf-8")

    # 1. Directory selector dropdown (REQ-UI-TASK-CHAIN-DIRECTORY-SELECTOR)
    require("TaskChainDirectorySelector" in content, "Must define TaskChainDirectorySelector component")
    require("task-chain-directory-selector-btn" in content, "Must render task-chain-directory-selector-btn")
    require("task-chain-directory-dropdown" in content, "Must render task-chain-directory-dropdown")
    require("directory-option-primary" in content, "Must render directory-option-primary")
    require("directory-option-${dir.id}" in content or "directory-option-" in content, "Must render directory-option-<id>")

    # 2. Bridge badge display (REQ-UI-DIRECTORY-BRIDGE-DISPLAY)
    require("active-directory-bridge-badge" in content, "Must render active-directory-bridge-badge")
    require("rounded bg-neutral-soft px-1.5 py-0.5 text-[10px] font-medium text-muted" in content,
            "Must use correct styling for bridge badge")
    require("getBridgeDisplay" in content, "Must use getBridgeDisplay helper")
    require("useListBridgesQuery" in content, "Must use useListBridgesQuery to resolve bridge names")

    # 3. Per-directory Monaco instances (REQ-UI-PER-DIRECTORY-MONACO-INSTANCES)
    require("mountedDirIds" in content, "Must track mountedDirIds for multi-mount Monaco instances")
    require("directory-editor-container-" in content, "Must render per-directory editor containers")
    require("style={{ display: isCurrent ? 'flex' : 'none' }}" in content,
            "Must toggle visibility using CSS display: none to preserve Monaco editor instance and undo history")
    require("heimdall:editor:tabs:" in content, "Must persist tabs per directory")

    # 4. Scoped Quick Open (REQ-UI-DIRECTORY-SCOPED-QUICK-OPEN)
    require("ProjectQuickOpenModal" in content, "Must export ProjectQuickOpenModal")
    require("quick-open-scope-badge" in content, "Must render quick-open-scope-badge")
    require("activeFsTarget" in content, "Must compute activeFsTarget")

    # 5. Guardrail: No native <select>
    require("<select" not in content, "Native <select> is banned per ui_no_native_select_test")

    # 6. Add Directory Modal (REQ-UI-ADD-DIRECTORY-MODAL)
    require("add-task-chain-directory-btn" in content, "Must render add-task-chain-directory-btn")
    require("AddChainDirectoryModal" in content, "Must define AddChainDirectoryModal component")
    require("add-chain-directory-modal" in content, "Must render add-chain-directory-modal dialog")
    require("add-chain-dir-picker" in content, "Must embed BridgeDirectoryPicker with add-chain-dir-picker")
    require("BridgeDirectoryPicker" in content, "Must import and render BridgeDirectoryPicker")
    require("useAddChainDirectoryMutation" in content, "Must call useAddChainDirectoryMutation")
    require("add-chain-dir-bridge-selector" in content, "Must render add-chain-dir-bridge-selector")
    print("  [+] ProjectFilesPanel.tsx verified successfully.")


def test_conversation_thread_page() -> None:
    print("[*] Checking ConversationThreadPage.tsx...")
    require(THREAD_PAGE_FILE.exists(), "ConversationThreadPage.tsx must exist")
    content = THREAD_PAGE_FILE.read_text(encoding="utf-8")

    require("chainId={chainId}" in content, "ConversationThreadPage must pass chainId")
    require("directories={chainDetailQuery.data?.chain?.directories}" in content,
            "ConversationThreadPage must forward task chain directories to panels")
    print("  [+] ConversationThreadPage.tsx verified successfully.")


def main() -> None:
    test_tasks_endpoints()
    test_project_fs_endpoints()
    test_project_files_panel()
    test_conversation_thread_page()
    print("\n[SUCCESS] All UI directory selector and Monaco instance tests passed!")


if __name__ == "__main__":
    main()
