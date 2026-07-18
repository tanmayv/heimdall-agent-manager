#!/usr/bin/env python3
"""Static regression checks for targeted websocket invalidation wiring."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "src" / "ui" / "components" / "App.tsx"
WS = ROOT / "src" / "ui" / "api" / "wsInvalidation.ts"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    app = APP.read_text(encoding="utf-8")
    ws = WS.read_text(encoding="utf-8")

    require("handleUserWsEvent" in app and "from '../api/wsInvalidation'" in app, "App must import wsInvalidation handler")
    require("resyncAfterReconnect(dispatch)" in app, "App must resync RTK Query cache on WS reconnect")
    require("handleUserWsEvent(dispatch, payload, {" in app, "App websocket onmessage must delegate to wsInvalidation")

    # WS handling should never fall back to broad component/store refresh fan-out.
    for marker in [
        "dispatch(refreshTaskBoard());",
        "dispatch(fetchTasksForChain(chainId));",
        "dispatch(revalidateChainView(",
        "dispatch(refreshAgents());",
        "dispatch(refreshMemory());",
        "dispatch(refreshMergeDecisions());",
        "dispatch(refreshChatApprovals());",
        "dispatch(fetchSelectedChat(",
        "dispatch(fetchGuideChat(",
        "dispatch(fetchChainCoordinatorChatPage(",
        "dispatch(fetchMemoryDetail(",
        "dispatch(fetchWorkspaceForChain(",
    ]:
        require(marker not in ws, f"wsInvalidation must not use broad refresh/fetch marker: {marker}")

    # Record-carrying events should patch targeted caches/helpers in place.
    for marker in [
        "upsertQueryData('fetchTask'",
        "updateQueryData('fetchChainTasks'",
        "updateQueryData('fetchTaskLog'",
        "updateQueryData('fetchDirectChat'",
        "updateQueryData('fetchGuideChat'",
        "upsertQueryData('fetchChain'",
        "updateQueryData('listChains'",
        "patchMemoryCachesFromWs(",
        "patchChatApprovalCachesFromWs(",
        "patchMergeDecisionCachesFromWs(",
        "patchAgentCachesFromWs(",
    ]:
        require(marker in ws, f"missing targeted ws patch marker: {marker}")

    # Id-only / compact events should invalidate only scoped RTKQ tags.
    for marker in [
        "invalidateTags([{ type: 'TaskLog', id: taskId }])",
        "invalidateTags([{ type: 'TaskComments', id: taskId }])",
        "{ type: 'Chain', id: chainId },",
        "{ type: 'ChainList', id: 'ALL' },",
        "{ type: 'ChainTasks', id: chainId },",
        "invalidateTags([{ type: 'GuideChat', id: GUIDE_AGENT_ID }])",
        "invalidateTags([{ type: 'Chat', id: agentId }])",
        "invalidateTags([{ type: 'ConversationSummaries', id: 'ALL' }])",
        "{ type: 'Workspace', id: chainId },",
        "{ type: 'WorkspaceDiff', id: `${chainId}:` },",
    ]:
        require(marker in ws, f"missing targeted invalidation marker: {marker}")

    print("UI WS INVALIDATION STATIC TEST PASSED")


if __name__ == "__main__":
    main()
