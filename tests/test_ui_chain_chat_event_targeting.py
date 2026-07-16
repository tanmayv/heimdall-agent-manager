#!/usr/bin/env python3
"""Static regression checks for chain-aware chat_event targeting in wsInvalidation."""

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

    require("import { handleUserWsEvent } from '../api/wsInvalidation';" in app, "App should import handleUserWsEvent")
    require("handleUserWsEvent(dispatch, payload, {" in app, "App websocket onmessage should delegate to wsInvalidation")
    require("const coordinatorChainId = eventChainId || (focusedCoordinatorAgentInstanceId and focusedCoordinatorAgentInstanceId === agentId ? focusedChainId : '')".replace(" and ", " && ") in ws, "wsInvalidation should derive coordinator chain targeting")
    require("dispatch(chatEventReceived(payload));" in ws, "chat_event should still update unread/session metadata")
    require("dispatch(wsChainViewRefreshRequested(`chat_event:${coordinatorChainId}:${payload.message_id || ''}`));" in ws, "focused coordinator chat should mark scoped WS refresh reason")
    require("dispatch(fetchSelectedChat({ agentId: selectedAgentId }));" not in ws, "wsInvalidation should not explicitly fetch direct chat on id-only events")
    require("dispatch(fetchGuideChat());" not in ws, "wsInvalidation should not explicitly fetch guide chat on id-only events")
    require("dispatch(fetchChainCoordinatorChatPage({ chainId: coordinatorChainId }));" not in ws, "wsInvalidation should not explicitly fetch coordinator chat on id-only events")
    require("dispatch(heimdallApi.util.invalidateTags([{ type: 'CoordinatorChat', id: coordinatorChainId }]));" in ws, "coordinator chat invalidation must be chain-scoped")
    require("dispatch(heimdallApi.util.invalidateTags([{ type: 'GuideChat', id: GUIDE_AGENT_ID }]));" in ws, "guide chat invalidation must be guide-scoped")
    require("dispatch(heimdallApi.util.invalidateTags([{ type: 'Chat', id: agentId }]));" in ws, "direct chat invalidation must be agent-scoped")

    print("UI CHAIN CHAT EVENT TARGETING TEST PASSED")


if __name__ == "__main__":
    main()
