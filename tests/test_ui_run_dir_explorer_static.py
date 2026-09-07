#!/usr/bin/env python3
"""Static regression checks for the run-dir explorer UI (P4).

Verifies InstanceRunDirPanel is a READ-ONLY fork (no FS mutations) that keeps the
view + comment flow with show-hidden ON by default, and that ConversationThreadPage
wires a third 'Run dir' tab with the folder+name labels (project name / instance
display name) + truncation.
"""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
PANEL = ROOT / "src" / "ui" / "components" / "chat" / "InstanceRunDirPanel.tsx"
THREAD = ROOT / "src" / "ui" / "components" / "chat" / "ConversationThreadPage.tsx"
API = ROOT / "src" / "ui" / "api" / "endpoints" / "instanceFs.ts"


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f"[-] FAIL: {msg}")
        sys.exit(1)


def main() -> None:
    panel = PANEL.read_text(encoding="utf-8")
    thread = THREAD.read_text(encoding="utf-8")
    api = API.read_text(encoding="utf-8")

    # --- Read-only API layer -------------------------------------------------
    for marker in ["useListInstanceDirQuery", "useReadInstanceFileQuery", "'InstanceFs'"]:
        require(marker in api, f"instanceFs.ts missing {marker}")
    require("agent-instances/${encodeURIComponent(instanceId)}/fs" in api, "instanceFs.ts must target the run-dir route")

    # --- Panel is a READ-ONLY fork ------------------------------------------
    require("useLazyListInstanceDirQuery" in panel and "useLazyReadInstanceFileQuery" in panel,
            "panel must use the instanceFs lazy hooks")
    for banned in [
        "useCreateProjectFileMutation", "useCreateProjectDirMutation",
        "useMoveProjectPathMutation", "useDeleteProjectPathMutation",
        "useLazyListProjectDirQuery", "beginAction(", "submitPending", "removeEntry(",
    ]:
        require(banned not in panel, f"panel must NOT contain mutation code: {banned}")
    # FS-mutation controls only (NOT the kept comment controls like
    # -line-comment-delete-, which are part of the view+comment flow).
    for banned_debug in ["-new-file-btn", "-new-dir-btn", "-name-input", "-name-editor"]:
        require(banned_debug not in panel, f"panel must NOT expose mutation control: {banned_debug}")

    # --- Show-hidden ON by default ------------------------------------------
    require("useState(true)" in panel and "includeHidden" in panel, "show-hidden must default TRUE")

    # --- View + COMMENT kept (writes no files) ------------------------------
    for marker in ["onPublishComments", "publishComments", "-comments-bar", "FileView", "MarkdownBody"]:
        require(marker in panel, f"panel must KEEP the view+comment flow marker: {marker}")

    # --- Third tab wired with folder + name labels + truncation -------------
    require('data-debug-id="conversation-right-panel-tab-rundir"' in thread, "missing Run dir tab")
    require("InstanceRunDirPanel" in thread, "thread must render InstanceRunDirPanel")
    require("'closed' | 'tasks' | 'files' | 'rundir'" in thread, "rightPanel union must include 'rundir'")
    require("instanceDisplayName" in thread, "run-dir tab must use the instance display name label")
    require("const filesLabel = projectName" in thread, "files tab must use the project name label")
    # both explorer tab labels truncate
    require(thread.count('<span className="truncate">') >= 2, "both explorer tab labels must truncate")

    print("PASS: run-dir explorer UI static checks")


if __name__ == "__main__":
    main()
