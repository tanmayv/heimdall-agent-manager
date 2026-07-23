#!/usr/bin/env python3
"""Static checks for UI-16 routes + component hierarchy doc."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOC = ROOT / "docs/plans/ui-routes-component-hierarchy.md"
ARCH = ROOT / "docs/plans/ui-architecture.md"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    doc = DOC.read_text(encoding="utf-8")
    arch = ARCH.read_text(encoding="utf-8")

    require("Route/component map: `ui-routes-component-hierarchy.md` (UI-16)" in arch, "ui-architecture must link the UI-16 route/component map")

    for section in [
        "## 2. Planned v1 route map",
        "## 3. App shell hierarchy",
        "## 4. Conversation hierarchy",
        "## 5. Chain hierarchy",
        "## 6. Agent hierarchy",
        "## 7. Library and Artifact viewer hierarchy",
        "## 8. Settings hierarchy",
        "## 9. Command palette hierarchy",
        "## 10. Responsive/mobile collapse ownership",
        "## 11. Removed / not-ported legacy route and surface inventory",
        "## 12. Later task traceability",
    ]:
        require(section in doc, f"missing required section: {section}")

    for route in [
        "/conversations/new",
        "/conversations/:conversation_id",
        "/chains/:chain_id/tasks/:task_id",
        "/agents/:agent_id",
        "/library/artifacts/:artifact_id",
        "/settings/bridges",
        "/settings/projects/:project_id",
        "/settings/providers",
        "/settings/memory",
    ]:
        require(route in doc, f"missing planned route: {route}")

    for component in [
        "AuthenticatedShell",
        "ProjectConversationTree",
        "ConversationPage",
        "CurrentTaskStrip",
        "ConversationInspector",
        "ChainPage",
        "TaskDetailPane",
        "AgentDetailPage",
        "ArtifactViewerOverlay",
        "SettingsSurface",
        "CommandPaletteOverlay",
        "MobileBottomTabBar",
    ]:
        require(component in doc, f"missing component owner: {component}")

    for legacy in [
        "/workspace/conversations/:agentInstanceId",
        "UnifiedWorkspaceShell",
        "GuideSidePanel",
        "MemoryManagementPage.tsx",
        "NewLocalProxyAgentWizard.tsx",
        "VimSidebar.tsx",
        "ChainEditor.tsx",
        "GlobalRightSidebar",
    ]:
        require(legacy in doc, f"missing removed legacy surface: {legacy}")

    for req in ["UI-1", "UI-2", "UI-3", "UI-4", "UI-5", "UI-6", "UI-7", "UI-8", "UI-9", "UI-10", "UI-11", "UI-12", "UI-13", "UI-14", "UI-15"]:
        require(req in doc, f"missing traceability for {req}")

    require("/api/v1" in doc, "doc must preserve /api/v1 backend assumption")
    require("no global right inspector" in doc.lower(), "doc must state no global right inspector")
    print("PASS: UI routes/component hierarchy static")


if __name__ == "__main__":
    main()
