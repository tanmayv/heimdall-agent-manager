#!/usr/bin/env python3
"""Regression tests for Fig (CitC) Frontend RTK Query endpoints, FigDirectoryPicker UI,
ProjectsPanel & ProjectsSurface toggle, workspace creation modal, and sidebar accordion folder icons.
(REQ-FIG-6, REQ-FIG-7, REQ-FIG-7B)."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
BRIDGE_FIG_TS = ROOT / "src" / "ui" / "api" / "endpoints" / "bridgeFig.ts"
PROJECTS_TS = ROOT / "src" / "ui" / "api" / "endpoints" / "projects.ts"
SIDEBAR_TS = ROOT / "src" / "ui" / "api" / "endpoints" / "sidebar.ts"
HEIMDALL_API_TS = ROOT / "src" / "ui" / "api" / "heimdallApi.ts"
ICON_TSX = ROOT / "src" / "ui" / "components" / "Icon.tsx"
APP_SHELL_TSX = ROOT / "src" / "ui" / "components" / "shell" / "AppShell.tsx"
FIG_PICKER_TSX = ROOT / "src" / "ui" / "components" / "FigDirectoryPicker.tsx"
PROJECTS_PANEL_TSX = ROOT / "src" / "ui" / "components" / "settings" / "ProjectsPanel.tsx"
PROJECTS_SURFACE_TSX = ROOT / "src" / "ui" / "components" / "projects" / "ProjectsSurface.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    bridge_fig = BRIDGE_FIG_TS.read_text(encoding="utf-8")
    projects_api = PROJECTS_TS.read_text(encoding="utf-8")
    sidebar_api = SIDEBAR_TS.read_text(encoding="utf-8")
    heimdall_api = HEIMDALL_API_TS.read_text(encoding="utf-8")
    icon_tsx = ICON_TSX.read_text(encoding="utf-8")
    app_shell_tsx = APP_SHELL_TSX.read_text(encoding="utf-8")
    fig_picker_tsx = FIG_PICKER_TSX.read_text(encoding="utf-8")
    projects_panel_tsx = PROJECTS_PANEL_TSX.read_text(encoding="utf-8")
    projects_surface_tsx = PROJECTS_SURFACE_TSX.read_text(encoding="utf-8")

    # 1. REQ-FIG-6: RTK Query endpoints & types (bridgeFig.ts, heimdallApi.ts)
    require("listBridgeFigWorkspaces" in bridge_fig, "bridgeFig.ts must define listBridgeFigWorkspaces")
    require("createBridgeFigWorkspace" in bridge_fig, "bridgeFig.ts must define createBridgeFigWorkspace")
    require("listBridgeFigFs" in bridge_fig, "bridgeFig.ts must define listBridgeFigFs")
    require("useListBridgeFigWorkspacesQuery" in bridge_fig, "bridgeFig.ts must export useListBridgeFigWorkspacesQuery")
    require("useCreateBridgeFigWorkspaceMutation" in bridge_fig, "bridgeFig.ts must export useCreateBridgeFigWorkspaceMutation")
    require("useLazyListBridgeFigFsQuery" in bridge_fig, "bridgeFig.ts must export useLazyListBridgeFigFsQuery")
    require("'BridgeFigWorkspaces'" in heimdall_api, "heimdallApi.ts must declare BridgeFigWorkspaces tag")

    # 2. Projects API schema extensions (projects.ts)
    require("project_type?:" in projects_api, "projects.ts Project type must include project_type")
    require("workspace_name?:" in projects_api, "projects.ts Project type must include workspace_name")
    require("relative_path?:" in projects_api, "projects.ts Project type must include relative_path")
    require("project_type?: string;" in projects_api, "projects.ts createProject mutation must accept project_type")

    # 3. REQ-FIG-7B: Sidebar project_type propagation & accordion folder open/close icons
    require("project_type" in sidebar_api and "projectType" in sidebar_api, "sidebar.ts must pass project_type and projectType")
    require("workspace_name" in sidebar_api and "workspaceName" in sidebar_api, "sidebar.ts must pass workspace_name and workspaceName")
    require("'folder-open'" in icon_tsx, "Icon.tsx must support folder-open icon")
    require("folder-open" in app_shell_tsx, "AppShell.tsx must use folder-open icon for expanded projects")
    require("folder" in app_shell_tsx, "AppShell.tsx must use folder icon for collapsed projects")
    require("text-amber-400" in app_shell_tsx, "AppShell.tsx must color Fig CitC project icons with amber-400")
    require("sidebar-project-workspace-" in app_shell_tsx, "AppShell.tsx must render workspace name badge next to CitC project")

    # 4. REQ-FIG-7: FigDirectoryPicker UI (FigDirectoryPicker.tsx)
    require("export default function FigDirectoryPicker" in fig_picker_tsx, "FigDirectoryPicker.tsx must export FigDirectoryPicker")
    require("useLazyListBridgeFigFsQuery" in fig_picker_tsx, "FigDirectoryPicker.tsx must use useLazyListBridgeFigFsQuery")
    require("limit: 50" in fig_picker_tsx, "FigDirectoryPicker.tsx must request 50 items/batch")
    require("loadMore" in fig_picker_tsx, "FigDirectoryPicker.tsx must support paginated loadMore")
    require("crumbs" in fig_picker_tsx, "FigDirectoryPicker.tsx must render breadcrumbs")
    require("handleJumpSubmit" in fig_picker_tsx, "FigDirectoryPicker.tsx must support direct jump search")
    require("visibleEntries" in fig_picker_tsx, "FigDirectoryPicker.tsx must sort dirs before files")

    # 5. REQ-FIG-7: Settings ProjectsPanel (ProjectsPanel.tsx)
    require("settings-project-type-toggle" in projects_panel_tsx, "ProjectsPanel.tsx must have project type toggle")
    require("settings-project-type-local-btn" in projects_panel_tsx, "ProjectsPanel.tsx must have Local Directory toggle button")
    require("settings-project-type-fig-btn" in projects_panel_tsx, "ProjectsPanel.tsx must have Fig (CitC) toggle button")
    require("settings-project-fig-workspace-select" in projects_panel_tsx, "ProjectsPanel.tsx must have CitC workspace select dropdown")
    require("settings-project-fig-new-workspace-btn" in projects_panel_tsx, "ProjectsPanel.tsx must have New CitC workspace button")
    require("settings-project-fig-modal" in projects_panel_tsx, "ProjectsPanel.tsx must have CitC workspace creation modal")
    require("settings-project-fig-relative-path-input" in projects_panel_tsx, "ProjectsPanel.tsx must have relative google3 path input")
    require("settings-project-fig-browse-btn" in projects_panel_tsx, "ProjectsPanel.tsx must have Browse google3 button")
    require("settings-project-fig-offline-warning" in projects_panel_tsx, "ProjectsPanel.tsx must have offline warning banner")
    require("settings-project-fig-retry-btn" in projects_panel_tsx, "ProjectsPanel.tsx must have offline retry button")
    require("settings-project-fig-bridge-select" in projects_panel_tsx, "ProjectsPanel.tsx must have bridge select")

    # 6. REQ-FIG-7: Desktop UI ProjectsSurface (ProjectsSurface.tsx)
    require("projects-create-type-toggle" in projects_surface_tsx, "ProjectsSurface.tsx must have project type toggle")
    require("projects-create-type-local-btn" in projects_surface_tsx, "ProjectsSurface.tsx must have Local Directory toggle button")
    require("projects-create-type-fig-btn" in projects_surface_tsx, "ProjectsSurface.tsx must have Fig (CitC) toggle button")
    require("projects-create-fig-workspace-select" in projects_surface_tsx, "ProjectsSurface.tsx must have CitC workspace select dropdown")
    require("projects-create-fig-new-workspace-btn" in projects_surface_tsx, "ProjectsSurface.tsx must have New CitC workspace button")
    require("projects-create-fig-modal" in projects_surface_tsx, "ProjectsSurface.tsx must have CitC workspace creation modal")
    require("projects-create-fig-relative-path-input" in projects_surface_tsx, "ProjectsSurface.tsx must have relative google3 path input")
    require("projects-create-fig-browse-btn" in projects_surface_tsx, "ProjectsSurface.tsx must have Browse google3 button")
    require("projects-create-fig-picker" in projects_surface_tsx, "ProjectsSurface.tsx must embed FigDirectoryPicker")
    require("projects-create-fig-offline-warning" in projects_surface_tsx, "ProjectsSurface.tsx must have offline warning banner")
    require("projects-create-fig-retry-btn" in projects_surface_tsx, "ProjectsSurface.tsx must have offline retry button")
    require("projects-create-fig-bridge-select" in projects_surface_tsx, "ProjectsSurface.tsx must have bridge select")

    print("[+] FIG CITC FRONTEND & PICKER REGRESSION TESTS PASSED")


if __name__ == "__main__":
    main()
