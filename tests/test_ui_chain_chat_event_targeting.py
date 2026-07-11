#!/usr/bin/env python3
"""Source regression checks for chain-aware chat_event targeting in App.tsx."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "src" / "ui" / "components" / "App.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    src = APP.read_text(encoding="utf-8")

    require("dispatch(chatEventReceived(payload));" in src, "chat_event handler should update unread metadata")
    require("const eventChainId = payload.chain_id || '';" in src, "chat_event handler should read payload.chain_id")
    require("if (focused && eventChainId && focused === eventChainId)" in src, "focused chain should refresh only on matching chain_id")
    require("focusedChain?.coordinatorAgentInstanceId === agentId" in src, "legacy fallback should still match focused coordinator for unscoped events")
    require("dispatch(revalidateChainView(focused));" in src, "matching chain-scoped events should revalidate chain view")
    require("dispatch(fetchSelectedChat({ agentId: selectedDirectAgent }));" in src, "selected direct chat should still refresh on message-less events")

    print("UI CHAIN CHAT EVENT TARGETING TEST PASSED")


if __name__ == "__main__":
    main()
