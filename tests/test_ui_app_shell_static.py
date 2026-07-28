#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHELL = ROOT / "src" / "ui" / "components" / "shell" / "AppShell.tsx"
MAIN = ROOT / "src" / "ui" / "main.tsx"
ROUTE_DOC = ROOT / "docs" / "plans" / "ui-routes-component-hierarchy.md"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    shell = SHELL.read_text()
    main_tsx = MAIN.read_text()
    route_doc = ROUTE_DOC.read_text()

    require("import AppShell from './components/shell/AppShell';" in main_tsx, "main must render the v1 shell")
    require("<AppShell />" in main_tsx, "main must mount AppShell")
    require("./components/App" not in main_tsx, "main must not mount legacy App chrome")

    for marker in [
        'data-debug-id="app-shell"',
        'data-debug-id={collapsed ? \'shell-left-sidebar-collapsed\' : \'shell-left-sidebar-expanded\'}',
        'data-debug-id="shell-main-route-outlet"',
        'data-debug-id="shell-sidebar-collapse-toggle"',
        'data-debug-id="shell-user-ws-owner"',
        'aria-label={collapsed ? item.label : undefined}',
        'title={collapsed ? item.label : item.description}',
    ]:
        require(marker in shell, f"missing shell marker: {marker}")

    for route in [
        "/conversations",
        "/conversations/new",
        "/chains",
        "/chains/new",
        "/agents",
        "/agents/new",
        "/library",
        "/settings",
        "/settings/bridges",
        "/settings/projects",
        "/settings/providers",
        "/settings/memory",
        "/settings/defaults",
    ]:
        require(route in shell, f"shell missing route {route}")
        require(route in route_doc, f"route doc missing route {route}")

    forbidden_chrome = [
        "GuideSidePanel",
        "GlobalRightSidebar",
        "ContextInspector",
        "UnifiedWorkspaceShell",
        "WorkspaceLeftSidebar",
        "WorkspaceMainRegion",
        "attentionSlice",
        "/workspace",
        "global attention",
    ]
    for forbidden in forbidden_chrome:
        require(forbidden not in shell, f"v1 shell must not include legacy/global surface: {forbidden}")

    require("workspace" in shell.lower(), "route-not-found copy should acknowledge legacy workspace removal")
    require("No graph editor" in shell, "chain placeholder should preserve no-graph-editor constraint")
    require("not by global shell chrome" in shell, "conversation inspector ownership must be page-owned")

    print("PASS: UI app shell static")


if __name__ == "__main__":
    main()
