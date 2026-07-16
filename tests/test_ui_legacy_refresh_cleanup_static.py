#!/usr/bin/env python3
"""Static cleanup checks for quarantined legacy UI request orchestration."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
TASK_SLICE = ROOT / "src" / "ui" / "store" / "taskSlice.ts"
CHAT_SLICE = ROOT / "src" / "ui" / "store" / "chatSlice.ts"
HOME_SLICE = ROOT / "src" / "ui" / "store" / "homeSlice.ts"
APP = ROOT / "src" / "ui" / "components" / "App.tsx"
SETTINGS = ROOT / "src" / "ui" / "components" / "SettingsPage.tsx"
FOLLOW_UP_DOC = ROOT / "docs" / "plan" / "ui-request-services" / "follow-up-domains.md"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def block_after(text: str, marker: str, span: int = 900) -> str:
    idx = text.find(marker)
    require(idx >= 0, f"marker not found: {marker}")
    return text[idx:idx + span]


def main() -> None:
    task_slice = read(TASK_SLICE)
    chat_slice = read(CHAT_SLICE)
    home_slice = read(HOME_SLICE)
    app = read(APP)
    settings = read(SETTINGS)
    follow_up_doc = read(FOLLOW_UP_DOC)

    # No parallel request-coordinator/service cache layer may exist in src/ui.
    ui_tree = "\n".join(read(path) for path in (ROOT / "src" / "ui").rglob("*.ts*"))
    require("requestCoordinator" not in ui_tree, "src/ui must not add a requestCoordinator layer")
    require("taskService" not in ui_tree, "src/ui must not add a taskService layer")
    require("chatService" not in ui_tree, "src/ui must not add a chatService layer")

    # Remaining legacy task/chat thunks should be explicitly quarantined.
    for text, name in [
        (task_slice, "taskSlice"),
        (chat_slice, "chatSlice"),
        (home_slice, "homeSlice"),
        (app, "App.tsx"),
        (settings, "SettingsPage.tsx"),
    ]:
        require("TODO(rtkq-migration owner=task-19f69e242e4)" in text, f"{name} should mark transitional request orchestration with an owner")

    # Attention task voting should no longer do mutation -> refresh A -> refresh B.
    vote_block = block_after(task_slice, "export const voteOnAttentionTask = createAsyncThunk(") if "export const voteOnAttentionTask = createAsyncThunk(" in task_slice else block_after(task_slice, "export const voteOnAttentionTask = createAsyncThunk('tasks/voteOnAttentionTask'")
    require("tasksApi.endpoints.voteTask.initiate" in vote_block, "attention task voting should route through tasksApi voteTask")
    require("fetchTasksForChain(" not in vote_block, "attention task voting must not refetch chain tasks directly")
    require("refreshTaskBoard(" not in vote_block, "attention task voting must not refresh the task board directly")

    # New-chain creation may refresh the board once, but should not immediately
    # chain into a second task-list refresh thunk.
    submit_block = block_after(home_slice, "export const submitNewChain = createAsyncThunk(") if "export const submitNewChain = createAsyncThunk(" in home_slice else block_after(home_slice, "export const submitNewChain = createAsyncThunk('home/submitNewChain'")
    require("await (dispatch as any)(refreshTaskBoard()).catch(() => undefined);" in home_slice, "submitNewChain should keep a single board refresh for overview visibility")
    require("fetchTasksForChain(" not in submit_block, "submitNewChain must not chain fetchTasksForChain after refreshTaskBoard")

    # New-chain creation progress polling must not reintroduce broad board/task
    # refresh fan-out; task polling should stay RTKQ-scoped.
    creation_poll_block = block_after(app, "useEffect(() => {\n    if (!chainCreationProgress?.active || !chainCreationProgress.chainId) return undefined;")
    require("dispatch(refreshTaskBoard())" not in creation_poll_block, "creation progress polling must not refresh the task board")
    require("dispatch(fetchTasksForChain(" not in creation_poll_block, "creation progress polling must not refetch chain tasks via legacy thunk")
    require("dispatch(revalidateChainView(chainCreationProgress.chainId))" in creation_poll_block, "creation progress polling should stay chain-scoped")
    require("const creationProgressChainTasksQuery = useFetchChainTasksQuery(" in app, "creation progress should use scoped RTKQ task polling")
    require("pollingInterval: chainCreationProgress?.active ? 2000 : 0" in app, "creation progress RTKQ task polling should be bounded to active modal state")
    if "dispatch(refreshAgents()).catch(() => undefined);" in creation_poll_block:
        require("TODO(rtkq-migration owner=task-19f69e242e4): chain creation progress still polls refreshAgents()" in app, "creation progress refreshAgents polling must carry an explicit bounded TODO owner")

    # Follow-up domains and no-service-layer guidance must be documented.
    for snippet in [
        "Agents",
        "Memory",
        "Projects",
        "Attention",
        "Workspace",
        "Artifacts",
        "Settings",
        "requestCoordinator",
        "taskService",
        "chatService",
    ]:
        require(snippet in follow_up_doc, f"follow-up domain doc missing: {snippet}")

    print("UI LEGACY REFRESH CLEANUP STATIC TEST PASSED")


if __name__ == "__main__":
    main()
