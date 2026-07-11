#!/usr/bin/env python3
"""Source regression checks for the New Project UI creation path."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "src" / "ui" / "components" / "App.tsx"
PROJECT_SLICE = ROOT / "src" / "ui" / "store" / "projectSlice.ts"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    app = APP.read_text(encoding="utf-8")
    project_slice = PROJECT_SLICE.read_text(encoding="utf-8")

    require("createProjectFromUi" in project_slice, "projectSlice should expose createProjectFromUi thunk")
    require("data-debug-id=\"home-new-project-btn\"" in app, "App should expose home-new-project-btn")
    require("setNewProjectModalOpen(true)" in app, "New Project button should open a modal instead of routing away")
    require("function NewProjectModal" in app, "App should render a NewProjectModal")
    require("data-debug-id=\"new-project-name-input\"" in app, "NewProjectModal should collect project name")
    require("data-debug-id=\"new-project-vcs-enabled-checkbox\"" in app, "NewProjectModal should expose VCS enablement")
    require("data-debug-id=\"new-project-directory-input\"" in app, "NewProjectModal should collect directory anchor")
    require("data-debug-id=\"new-project-vcs-kind-select\"" in app, "NewProjectModal should collect vcs_kind anchor")
    require("buildVcsAnchors(vcsEnabled, directory, vcsKind, baseRef, worktreeRoot)" in app, "NewProjectModal should submit VCS anchors")
    require("dispatch(createProjectFromUi(payload)).unwrap()" in app, "App should dispatch createProjectFromUi on submit")
    require("dispatch(selectProject(result.project_id));" in app, "App should select the created project after success")
    require("new-chain-project-vcs-status" in app, "New chain modal should display selected project VCS support")

    print("UI NEW PROJECT CREATION TEST PASSED")


if __name__ == "__main__":
    main()
