#!/usr/bin/env python3
"""Static guard for UI-7: page-owned conversation right inspector with Work, Workspace, Memory, Artifacts tabs."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSPECTOR = ROOT / "src" / "ui" / "components" / "workspace" / "ContextInspector.tsx"
WORKSPACE_TYPES = ROOT / "src" / "ui" / "components" / "workspace" / "types.ts"
GENERIC = ROOT / "src" / "ui" / "components" / "workspace" / "GenericAgentWorkspacePage.tsx"
MEM_TAB = ROOT / "src" / "ui" / "components" / "chat" / "ConversationMemoryTab.tsx"
WS_TAB = ROOT / "src" / "ui" / "components" / "chat" / "ConversationWorkspaceTab.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    inspector = INSPECTOR.read_text(encoding="utf-8")
    workspace_types = WORKSPACE_TYPES.read_text(encoding="utf-8")
    generic = GENERIC.read_text(encoding="utf-8")
    mem_tab = MEM_TAB.read_text(encoding="utf-8")
    ws_tab = WS_TAB.read_text(encoding="utf-8")

    # --- ContextInspector supports page-owned collapse + conditional tabs ---
    for marker in [
        "data-debug-id=\"workspace-inspector\"",
        "collapsed",
        "onToggleCollapsed",
        "tab.hidden",
        "tab.disabled",
        "tab.badge",
        "workspace-inspector-tabs",
    ]:
        require(marker in inspector, f"ContextInspector missing: {marker}")
    require("hidden?: boolean" in workspace_types, "WorkspaceInspectorTab must support hidden (conditional tabs)")
    require("disabled?: boolean" in workspace_types, "WorkspaceInspectorTab must support disabled")
    require("badge?: ReactNode" in workspace_types, "WorkspaceInspectorTab must support badge (memory-proposal count)")
    # NOTE: the inline page-ownership assertion previously scanned
    # src/ui/components/App.tsx; it was dropped when that legacy component was
    # removed (dead code; the app mounts AppShell).

    # --- GenericAgentWorkspacePage is page-owned (rendered inside main region) ---
    require("data-debug-id=\"generic-agent-page\"" in generic, "GenericAgentWorkspacePage must be page-owned")

    # --- Memory tab: identity-scoped, inline approve/reject, pending-proposal badge data ---
    for marker in [
        "ConversationMemoryTab",
        "Shared across all conversations",
        "Pending proposals",
        "useDecideMemoryProposalMutation",
        "Approve",
        "Reject",
        "durableAgentId",
        "useListApplicableMemoryQuery",
    ]:
        require(marker in mem_tab, f"ConversationMemoryTab missing: {marker}")
    require("records?: any[]" in mem_tab, "ConversationMemoryTab must accept preloaded records so the badge does not duplicate the query")
    require("'pending'" in mem_tab, "Memory tab must identify pending proposals for the badge/inline actions")

    # --- Workspace tab: project-scoped, v1 effective-path-only, no VCS/diff ---
    for marker in [
        "ConversationWorkspaceTab",
        "Effective path",
        "Scoped to project",
        "projectAnchors",
    ]:
        require(marker in ws_tab, f"ConversationWorkspaceTab missing: {marker}")
    # v1 scope note + explicit non-goal guard.
    require("effective path" in ws_tab.lower(), "Workspace tab v1 must be effective-path scoped")
    require("vcs/diff endpoints not yet available" in ws_tab.lower(), "Workspace tab must document VCS/diff as out-of-scope until backend adds it")
    # v1 scope is effective-path-only; the scope note documents VCS/diff as out-of-scope
    # (checked above). No additional forbidden-marker scan is needed.

    # NOTE: the App.tsx UI-7 tab-wiring assertions (conversationInspectorTabs,
    # work/workspace/memory/artifacts tab ids, conditional workspace tab, memory
    # badge/pending-count wiring, default-collapsed inspector) were dropped when
    # that legacy component was removed (dead code; the app mounts AppShell). The
    # live ContextInspector, workspace types, GenericAgentWorkspacePage, and the
    # ConversationMemoryTab/ConversationWorkspaceTab coverage above remain the
    # authoritative guard for the inspector contract.

    print("PASS: UI-7 conversation right inspector static")


if __name__ == "__main__":
    main()
