#!/usr/bin/env python3
"""Source regression for repo-level Show diff workspace gating and labels."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "src/ui/components/App.tsx"
TASK_SLICE = ROOT / "src/ui/store/taskSlice.ts"
CHAIN_VIEW_SLICE = ROOT / "src/ui/store/chainViewSlice.ts"
VCS_HTTP = ROOT / "src/daemon/vcs_http.odin"
TASK_PROJECTION = ROOT / "src/daemon/task_projection.odin"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    app = APP.read_text(encoding="utf-8")
    task_slice = TASK_SLICE.read_text(encoding="utf-8")
    chain_view = CHAIN_VIEW_SLICE.read_text(encoding="utf-8")
    vcs_http = VCS_HTTP.read_text(encoding="utf-8")
    task_projection = TASK_PROJECTION.read_text(encoding="utf-8")

    # DIFF-2/DIFF-6: ChainView must show Workspace/Show diff only for a real
    # worktree or explicit daemon-declared repo-diff support, not every chain.
    require("chainRepoDiffSupported" in app, "ChainView should consume repo diff support metadata")
    require("workspaceForDisplay" in app and "repo_diff_supported: true" in app, "repo-level chains should synthesize workspace display data")
    require("const hasWorkspace = Boolean(chain.vcsWorkspaceId || workspaceForDisplay?.workspace_id || workspaceForDisplay?.repo_diff_supported" in app, "workspace gate should require worktree or repo_diff_supported")
    require("{hasWorkspace && (" in app and 'data-debug-id="chain-workspace-row"' in app, "workspace row should remain gated")
    require('data-debug-id="workspace-show-diff-btn"' in app, "Show diff button debug id missing")

    # DIFF-7: Labels must be explicit and rendered both as a badge and with
    # fetched diff metadata from the daemon.
    require('data-debug-id="workspace-diff-mode-label"' in app, "diff mode label badge missing")
    require("Changes since chain started (whole repo)" in app, "baseline repo diff label missing")
    require("Uncommitted changes" in app, "fallback repo diff label missing")
    require("Worktree changes" in app, "worktree diff label missing")
    require("currentDiff?.diff_label || currentDiff?.diffLabel" in app, "fetched diff label should override default label")
    require("Repo-level diffs are whole-repo/time-based" in app, "repo-level attribution warning missing")

    # DIFF-2/DIFF-4/DIFF-5: Empty file selection must fetch whole-repo diff for
    # repo-level chains, because they may not have a per-file status list yet.
    require("const diffKey = selectedFile || '';" in app, "empty diff key should represent whole-repo diff")
    require("onFetchDiff?.(diffKey);" in app, "diff fetch should support empty whole-repo path")
    require("state.workspaceDiffByChainId[action.payload.chainId][action.payload.file || '']" in chain_view, "diff cache should preserve whole-repo empty path key")

    # DIFF-2/DIFF-3/DIFF-6: Metadata must flow from daemon projection to Redux.
    require("diff_base_sha" in task_projection and "repo_diff_supported" in task_projection, "chain projection should expose diff_base_sha and repo_diff_supported")
    require("diffBaseSha: chain.diff_base_sha" in task_slice, "Redux chain mapping should keep diff_base_sha")
    require("repoDiffSupported: Boolean(chain.repo_diff_supported" in task_slice, "Redux chain mapping should keep repo_diff_supported")

    # DIFF-5/DIFF-6/DIFF-7: Daemon workspace response should distinguish
    # supported repo-level mode from unsupported/non-VCS ineligibility.
    require('"repo_diff_supported":false' in vcs_http, "unsupported workspace response should not claim repo diff support")
    require('` ,"repo_diff_supported":true' not in vcs_http, "guard against malformed repo_diff_supported JSON")
    require('repo_diff_supported":true' in vcs_http, "repo workspace response should claim support when eligible")
    require('mode = "repo_baseline"' in vcs_http and 'mode := "repo_uncommitted"' in vcs_http, "repo workspace response should expose both modes")
    require('workspace_diff_json(result.diff, result.mode, result.label, result.base_sha)' in vcs_http, "diff endpoint should pass mode label metadata")

    # DIFF-8: UI must not offer repo-level merge/preview actions as if a
    # dedicated worktree existed.
    require("onClick={isRepoLevel ? undefined : onPreviewMerge}" in app, "repo-level preview merge should be disabled")
    require("disabled={isRepoLevel}" in app, "repo-level preview merge button should be disabled")

    print("UI REPO DIFF WORKSPACE TEST PASSED")


if __name__ == "__main__":
    main()
