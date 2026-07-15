#!/usr/bin/env python3
"""Regression: workspace endpoints prefer/discover chain worktrees before repo fallback."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
VCS_HTTP = ROOT / "src/daemon/vcs_http.odin"
VCS_DB = ROOT / "src/daemon/vcs_db_service.odin"
APP = ROOT / "src/ui/components/App.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    vcs_http = VCS_HTTP.read_text(encoding="utf-8")
    vcs_db = VCS_DB.read_text(encoding="utf-8")
    app = APP.read_text(encoding="utf-8")

    require("workspace_resolve_chain_workspace :: proc" in vcs_http, "workspace resolver helper missing")
    require("workspace_setup_path_and_base_ref :: proc" in vcs_http, "setup-task path parser missing")
    require('task.title != "Prepare chain workspace"' in vcs_http, "resolver should inspect workspace setup task")
    require('workspace_setup_value(task.description, "Worktree path")' in vcs_http, "resolver should parse worktree path from setup task")
    require('workspace_path_allowed_for_project' in vcs_http and 'fmt.tprintf("%s/", root)' in vcs_http, "resolver should constrain discovered paths to project worktree root")
    require('if !os.is_dir(path) do return Vcs_Workspace_Record{}, false' in vcs_http, "resolver should require an existing worktree directory")
    require('if !vcs_db_insert_workspace(rec) do return Vcs_Workspace_Record{}, false' in vcs_http, "resolver should register discovered worktrees")
    require('workspace_record_chain_workspace_id(chain.chain_id, workspace_id)' in vcs_http, "resolver should persist chain workspace id after discovery")

    require('if rec, found := workspace_resolve_chain_workspace(chain_id); found {' in vcs_http, "workspace endpoints should resolve chain worktree before repo fallback")
    require('rec, found := workspace_resolve_chain_workspace(chain_id)' in vcs_http, "merge/refresh endpoints should reuse resolved chain workspace")
    require('WORKSPACE_SOURCE_CHAIN_LABEL' in vcs_http and 'WORKSPACE_SOURCE_REPO_LABEL' in vcs_http, "source labels missing from backend")
    require('"source_kind":"' in vcs_http and '"source_label":"' in vcs_http, "workspace JSON should expose source metadata")
    require('vcs_write_workspace_json :: proc(b: ^strings.Builder, rec: Vcs_Workspace_Record, status: vcs.Vcs_Status, source_kind, source_label: string)' in vcs_db, "workspace JSON writer should accept source metadata")

    require('const sourceLabel = workspace?.source_label || workspace?.sourceLabel' in app, "UI should consume workspace source metadata")
    require('data-debug-id="workspace-source-label"' in app, "UI should render source label badge")

    print("CHAIN WORKSPACE SOURCE RESOLUTION TEST PASSED")


if __name__ == "__main__":
    main()
