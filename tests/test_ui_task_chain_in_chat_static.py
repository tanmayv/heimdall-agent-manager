#!/usr/bin/env python3
"""Static guard for UI-6: Task chain presentation inside an open agent chat."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INFERENCE = ROOT / "src" / "ui" / "components" / "chat" / "chainTaskInference.ts"
STRIP = ROOT / "src" / "ui" / "components" / "chat" / "CurrentTaskStrip.tsx"
CHIPS = ROOT / "src" / "ui" / "components" / "chat" / "WorkChips.tsx"
WORKTAB = ROOT / "src" / "ui" / "components" / "chat" / "WorkTab.tsx"
HOOK = ROOT / "src" / "ui" / "components" / "chat" / "useChatChainWork.ts"
GENERIC = ROOT / "src" / "ui" / "components" / "workspace" / "GenericAgentWorkspacePage.tsx"
WORKSPACE_TYPES = ROOT / "src" / "ui" / "components" / "workspace" / "types.ts"
AGENT_CATALOG = ROOT / "src" / "ui" / "api" / "agentCatalog.ts"
APP = ROOT / "src" / "ui" / "components" / "App.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    inference = INFERENCE.read_text(encoding="utf-8")
    strip = STRIP.read_text(encoding="utf-8")
    chips = CHIPS.read_text(encoding="utf-8")
    worktab = WORKTAB.read_text(encoding="utf-8")
    hook = HOOK.read_text(encoding="utf-8")
    generic = GENERIC.read_text(encoding="utf-8")
    workspace_types = WORKSPACE_TYPES.read_text(encoding="utf-8")
    agent_catalog = AGENT_CATALOG.read_text(encoding="utf-8")
    app = APP.read_text(encoding="utf-8")

    # --- Pure inference module derives current task + review-needed from cached tasks ---
    for marker in [
        "deriveCurrentTask",
        "deriveReviewNeededTasks",
        "deriveChainProgress",
        "isUserEffectiveReviewer",
        "isInstanceEffectiveReviewer",
        "USER_REVIEWER_IDS",
        "in_progress",
        "review_ready",
    ]:
        require(marker in inference, f"chainTaskInference missing: {marker}")

    # Selection order documented in design doc.
    require("taskAssigneeOf(task) === agentInstanceId && taskStatusOf(task) === 'in_progress'" in inference,
            "deriveCurrentTask must prefer in_progress task assigned to this instance first")
    require("taskStatusOf(task) === 'review_ready' && isInstanceEffectiveReviewer" in inference,
            "deriveCurrentTask must fall back to review_ready task where instance is reviewer")
    require("taskCreatedMs(a) - taskCreatedMs(b)" in inference,
            "deriveReviewNeededTasks must sort oldest-first (oldest is what the review chip opens)")
    require("deriveReviewNeededTasks" in inference and "review_ready" in inference,
            "review-needed derivation must be scoped to review_ready + user reviewer")

    # --- CurrentTaskStrip renders above input, separates task comments from chat ---
    for marker in [
        "Current task",
        "data-task-comment-mode=\"true\"",
        "Submit for review",
        "Comment",
        "onComment",
        "Add comment",
        "onOpenTask",
        "in_progress",
    ]:
        require(marker in strip, f"CurrentTaskStrip missing: {marker}")
    # Task comment composer is separate from chat send path.
    require("Add a task comment (not a chat message)" in strip,
            "CurrentTaskStrip comment composer must create task comments, not chat messages")
    # Submit-for-review is the assignee's legal action; vote is the reviewer's.
    require("onSubmitForReview" in strip and "onVote" in strip,
            "CurrentTaskStrip must expose submit-for-review (assignee) and vote (reviewer) actions")

    # --- WorkChips: header Work chip + scoped Review-needed chip ---
    for marker in [
        "work-chip",
        "review-needed-chip",
        "data-review-needed-count",
        "Review needed:",
        "onOpenChain",
        "onOpenReviewTask",
    ]:
        require(marker in chips, f"WorkChips missing: {marker}")
    require("reviewNeededTasks[0]" in chips,
            "WorkChips review chip must open the OLDEST review-needed task in this chain")

    # --- WorkTab: compact chain dashboard, no graph editing ---
    for marker in [
        "WorkTab",
        "Progress:",
        "Coordinator:",
        "Needs your review",
        "Active / next",
        "Completed",
        "Open full chain",
        "No concrete tasks yet",
    ]:
        require(marker in worktab, f"WorkTab missing: {marker}")
    forbidden_graph = ["graph editor", "onCreateEdge", "onCreateNode", "reactflow"]
    lowered = worktab.lower()
    for marker in forbidden_graph:
        require(marker not in lowered, f"WorkTab must NOT include graph editing: {marker}")

    # --- Hook derives from the SAME cached task list (no separate current-task endpoint) ---
    for marker in [
        "useFetchChainTasksQuery",
        "useFetchChainQuery",
        "selectTaskCacheProjection",
        "chainTasks(tasksById, chainId)",
        "deriveCurrentTask",
        "deriveReviewNeededTasks",
    ]:
        require(marker in hook, f"useChatChainWork missing: {marker}")
    # Empty/private chain state returns stable empty values.
    require("progress: { total: 0" in hook, "useChatChainWork must return stable empty state for private/empty chains")

    # --- GenericAgentWorkspacePage renders the currentTaskStrip slot above composer ---
    require("context.currentTaskStrip" in generic, "GenericAgentWorkspacePage must render currentTaskStrip slot")
    require("currentTaskStrip?: ReactNode | null" in workspace_types, "WorkspaceGenericAgentContext must declare currentTaskStrip")

    # --- agent instance maps chain_id so the chat can resolve its bound chain ---
    require("chainId: agent.chain_id || agent.chainId" in agent_catalog,
            "mapAgent must surface bound chainId for UI-6 chat work surfaces")

    # --- App.tsx wires work surfaces into BOTH conversation and direct-agent pages ---
    for marker in [
        "useChatChainWork",
        "WorkChips",
        "WorkTab",
        "CurrentTaskStrip",
        "currentTaskStrip: chainWork",
        "bottom: <WorkChips",
        "id: 'work'",
    ]:
        require(marker in app, f"App.tsx missing UI-6 wiring: {marker}")
    require(app.count("useChatChainWork") >= 2,
            "App.tsx must derive chain work for both ConversationThreadPage and AgentDetailPage")
    require("onAddComment={addTaskComment}" in app and "onVoteTask={voteTask}" in app,
            "App.tsx must pass shared task-action handlers to both chat pages")
    # Task comments use the task comment thunk, not the chat send path.
    require("addCommentToSelectedTask" in app, "task comments must use addCommentToSelectedTask (not chat send)")

    print("PASS: UI-6 task chain in chat static")


if __name__ == "__main__":
    main()
