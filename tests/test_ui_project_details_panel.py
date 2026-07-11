#!/usr/bin/env python3
"""Source regression checks for the project details/update/delete UI."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
SETTINGS = ROOT / "src" / "ui" / "components" / "SettingsPage.tsx"
PROJECT_SLICE = ROOT / "src" / "ui" / "store" / "projectSlice.ts"
API = ROOT / "src" / "ui" / "api" / "daemonApi.ts"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    settings = SETTINGS.read_text(encoding="utf-8")
    project_slice = PROJECT_SLICE.read_text(encoding="utf-8")
    api = API.read_text(encoding="utf-8")

    require("{ key: 'projects', label: 'Projects' }" in settings, "Settings nav should expose a Projects page")
    require("function ProjectsPanel" in settings, "SettingsPage should render a ProjectsPanel")
    require("data-debug-id=\"settings-project-name-input\"" in settings, "ProjectsPanel should expose editable name input")
    require("data-debug-id=\"settings-project-save-btn\"" in settings, "ProjectsPanel should expose save button")
    require("data-debug-id=\"settings-project-delete-btn\"" in settings, "ProjectsPanel should expose delete button")
    require("data-debug-id=\"settings-project-vcs-enabled-checkbox\"" in settings, "ProjectsPanel should expose VCS enablement")
    require("data-debug-id=\"settings-project-directory-input\"" in settings, "ProjectsPanel should edit directory anchor")
    require("data-debug-id=\"settings-project-vcs-kind-select\"" in settings, "ProjectsPanel should edit vcs_kind anchor")
    require("buildVcsAnchors(vcsEnabled, directory, vcsKind, baseRef, worktreeRoot)" in settings, "ProjectsPanel should save VCS anchors")
    require("updateProjectFromUi" in project_slice, "projectSlice should keep updateProjectFromUi thunk")
    require("deleteProjectFromUi" in project_slice, "projectSlice should expose deleteProjectFromUi thunk")
    require("export async function deleteProject" in api, "daemonApi should expose deleteProject helper")

    print("UI PROJECT DETAILS PANEL TEST PASSED")


if __name__ == "__main__":
    main()
