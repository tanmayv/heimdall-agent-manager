#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHELL = ROOT / "src" / "ui" / "components" / "shell" / "AppShell.tsx"
ROUTE_DOC = ROOT / "docs" / "plans" / "ui-routes-component-hierarchy.md"
ARCH_DOC = ROOT / "docs" / "plans" / "ui-architecture.md"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    shell = SHELL.read_text()
    route_doc = ROUTE_DOC.read_text()
    arch = ARCH_DOC.read_text()

    for marker in [
        "type ProjectGroup",
        "type AgentGroup",
        "type SessionGroup",
        "type ConversationSummary",
        "DEFAULT_CONVERSATIONS_PROJECT",
        "name: 'Conversations'",
        "isDefaultConversations: true",
        "buildProjectConversationTree",
        "ProjectConversationTree",
        "data-debug-id=\"sidebar-project-agent-session-tree\"",
        "data-debug-id={`sidebar-project-group-${projectGroup.project.projectId}`}",
        "data-debug-id={`sidebar-agent-group-${agentGroup.agentId}`}",
        "data-debug-id={`sidebar-session-row-${conversation.conversationId}`}",
        "data-debug-id=\"sidebar-default-conversations-project-policy\"",
        "renamable · not deletable",
        "sidebar-project-unread-",
        "sidebar-agent-unread-",
        "sidebar-session-unread-",
        "shell-nav-unread-" ,
        "totalUnread",
        "fetchApiList('/chats?limit=100')",
        "fetchApiList('/projects?limit=100')",
        "normalizeConversation",
        "normalizeProject",
        "hasDefaultMarker",
        "raw?.is_default_conversations === true",
        "raw?.isDefaultConversations === true",
        "markedDefaultProject",
        "defaultProjectId",
    ]:
        require(marker in shell, f"missing sidebar tree marker: {marker}")

    require("ProjectConversationTree groups={conversationTree}" in shell, "expanded sidebar must render project tree")
    require("!collapsed && <ProjectConversationTree" in shell, "tree must be expanded-sidebar only")
    require("name.toLowerCase() === 'conversations'" not in shell, "default project policy must not be inferred from the display name")
    require("const isSyntheticFallback = projectId === DEFAULT_CONVERSATIONS_PROJECT.projectId" in shell, "synthetic fallback default project id must be explicit")
    require("rawProjectId === DEFAULT_CONVERSATIONS_PROJECT.projectId ? defaultProjectId : rawProjectId" in shell, "fallback conversations must move under a marked renamed default project")
    require("badge={item.path === '/conversations' ? totalUnread : 0}" in shell, "collapsed rail conversations nav must receive unread badge")
    require("conversation.projectId || DEFAULT_CONVERSATIONS_PROJECT.projectId" in shell, "missing default project fallback for conversations")
    require("agentId" in shell and "sessions" in shell, "agent/session hierarchy missing")

    for doc_marker in [
        "project → agent_id → session",
        "renamable, not deletable",
        "unread rollups",
    ]:
        require(doc_marker in arch or doc_marker in route_doc, f"docs missing UI-3 marker: {doc_marker}")

    forbidden = ["Standalone Projects", "ProjectsManagementPage", "GlobalRightSidebar", "GuideSidePanel"]
    for marker in forbidden:
        require(marker not in shell, f"sidebar tree should not reintroduce legacy/standalone surface: {marker}")

    print("PASS: UI sidebar tree static")


if __name__ == "__main__":
    main()
