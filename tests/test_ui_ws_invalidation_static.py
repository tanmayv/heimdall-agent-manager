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

    require("import { handleUserWsEvent } from '../api/wsInvalidation';" in app, "App must import wsInvalidation handler")
    require("handleUserWsEvent(dispatch, payload, {" in app, "App websocket onmessage must delegate to wsInvalidation")

    require("dispatch(refreshTaskBoard());" not in ws, "wsInvalidation must not broadly refresh the task board")
    require("dispatch(fetchTasksForChain(chainId));" not in ws, "wsInvalidation must not broadly refetch chain task lists")
    require("dispatch(revalidateChainView(" not in ws, "wsInvalidation must not call broad chain revalidation")
    require("dispatch(refreshAgents());" not in ws, "wsInvalidation must not broadly refresh agents")
    require("dispatch(refreshMemory());" not in ws, "wsInvalidation must not broadly refresh memory")
    require("dispatch(refreshMergeDecisions());" not in ws, "wsInvalidation must not broadly refresh merge decisions")
    require("dispatch(refreshChatApprovals());" not in ws, "wsInvalidation must not broadly refresh chat approvals")
    require("dispatch(fetchSelectedChat(" not in ws, "wsInvalidation must not explicitly fetch direct chat")
    require("dispatch(fetchGuideChat(" not in ws, "wsInvalidation must not explicitly fetch guide chat")
    require("dispatch(fetchChainCoordinatorChatPage(" not in ws, "wsInvalidation must not explicitly fetch coordinator chat")
    require("dispatch(fetchMemoryDetail(" not in ws, "wsInvalidation must not explicitly fetch memory detail")
    require("dispatch(fetchWorkspaceForChain(" not in ws, "wsInvalidation must not explicitly fetch workspace")

    require("upsertQueryData('fetchTask'" in ws, "task events with records should patch fetchTask cache")
    require("updateQueryData('fetchChainTasks'" in ws, "task events with records should patch fetchChainTasks cache")
    require("updateQueryData('fetchDirectChat'" in ws, "chat events with records should patch direct chat cache")
    require("updateQueryData('fetchGuideChat'" in ws, "chat events with records should patch guide chat cache")
    require("updateQueryData('fetchCoordinatorChat'" in ws, "chat events with records should patch coordinator chat cache")

    for marker in [
        "invalidateTags([{ type: 'Chat', id: agentId }])",
        "invalidateTags([{ type: 'GuideChat', id: GUIDE_AGENT_ID }])",
        "invalidateTags([{ type: 'CoordinatorChat', id: coordinatorChainId }])",
        "invalidateTags([{ type: 'Memory', id: memoryId }, { type: 'MemoryHistory', id: memoryId }])",
        "invalidateTags([{ type: 'Workspace', id: chainId }])",
        "invalidateTags([{ type: 'MergeDecisions', id: 'ALL' }, { type: 'Attention', id: 'ALL' }])",
        "invalidateTags([{ type: 'ChatApprovals', id: 'ALL' }, { type: 'Attention', id: 'ALL' }])",
        "invalidateTags([{ type: 'Agents', id: agentId }])",
    ]:
        require(marker in ws, f"missing targeted invalidation marker: {marker}")

    print("UI WS INVALIDATION STATIC TEST PASSED")


if __name__ == "__main__":
    main()
