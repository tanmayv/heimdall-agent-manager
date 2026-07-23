#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAP_DOC = ROOT / "docs" / "plans" / "ui-backend-gap-analysis.md"
ARCH_DOC = ROOT / "docs" / "plans" / "ui-architecture.md"
ROUTE_DOC = ROOT / "docs" / "plans" / "ui-routes-component-hierarchy.md"
WIRING = ROOT / "src" / "hub" / "app" / "wiring.odin"


def require(text: str, needle: str, label: str) -> None:
    if needle not in text:
        raise AssertionError(f"missing {label}: {needle}")


def main() -> None:
    gap = GAP_DOC.read_text()
    arch = ARCH_DOC.read_text()
    routes = ROUTE_DOC.read_text()
    wiring = WIRING.read_text()

    require(gap, "# UI ↔ backend gap analysis (UI-17)", "UI-17 title")
    require(arch, "ui-backend-gap-analysis.md", "architecture companion link")
    require(routes, "ui-backend-gap-analysis.md", "route doc UI-17 link")

    for section in [
        "## 2. Current implemented backend route inventory",
        "## 3. Current UI data-layer inventory",
        "## 4. Surface-by-surface gap matrix",
        "## 5. Task status and review enum mapping",
        "## 6. Conversation launch needs",
        "## 7. Artifact/library needs",
        "## 8. Backend endpoints supported but unused by planned UI",
        "## 9. Recommended follow-up task list",
        "## 10. No-mock policy for unsupported needs",
    ]:
        require(gap, section, f"section {section}")

    for surface in [
        "App shell + auth",
        "Sidebar conversation tree",
        "New conversation launch",
        "Conversation page",
        "ChatComposer attachments + mentions",
        "Conversation Work chip/current task/inspector Work tab",
        "Chain list/detail",
        "Task comments vs chat messages",
        "Agent list/detail",
        "Library and artifact viewer",
        "Settings → Bridges",
        "Settings → Projects",
        "Settings → Providers/provider profiles",
        "Settings → Global memory",
        "Command palette",
        "Data layer + user WS invalidation",
        "Legacy cleanup",
    ]:
        require(gap, surface, f"surface {surface}")

    for status in [
        "`assigned`",
        "`in_progress`",
        "`in_validation`",
        "`validated_good`",
        "`validated_not_good`",
        "`paused`",
        "`completed`",
        "`cancelled`",
    ]:
        require(gap, status, f"task status {status}")

    for required_gap in [
        "artifact versions",
        "rollback",
        "annotations list/create/update/delete",
        "current handler parses top-level `artifact_ids`",
        "include `project_id`/project name on chat summaries",
        "public UI config/bootstrap endpoint",
        "GET /api/v1/search",
        "POST /api/v1/batch/get",
        "task-19f8ed3ac87",
        "task-19f8ec915a2",
        "search-as-you-type",
        "sub-100ms p95 server time",
        "per-hit N+1 queries",
        "prefix/word-boundary matches rank above interior substring matches",
        "indexed lowercased name/title/slug/id columns",
        "repository-layer ownership of search/index details",
        "never unbounded typeahead",
        "publish `resource_changed` for all resources",
        "do not create fake successful local-only mutations",
    ]:
        require(gap, required_gap, f"required gap marker {required_gap}")

    for route in [
        '"GET", "/api/v1/me"',
        '"GET", "/api/v1/user-ws"',
        '"POST", "/api/v1/chats"',
        '"POST", "/api/v1/agent-instances"',
        '"GET", "/api/v1/task-chains"',
        '"POST", "/api/v1/task-chains/*/tasks/*/status"',
        '"GET", "/api/v1/artifacts"',
        '"GET", "/api/v1/templates"',
        '"POST", "/api/v1/bridge-enrollments"',
    ]:
        require(wiring, route, f"backend route evidence {route}")

    stale_inline = "Artifact versions / rollback / annotations — RESOLVED (removed from UI)"
    if stale_inline in arch:
        raise AssertionError("stale inline gap resolution remains in ui-architecture.md")

    print("PASS: UI/backend gap analysis static")


if __name__ == "__main__":
    main()
