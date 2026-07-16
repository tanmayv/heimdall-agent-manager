#!/usr/bin/env python3
"""Static regression checks for live chat WS fallback behavior in wsInvalidation."""

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

    onopen_marker = "socket.onopen = () => {"
    onopen_idx = app.find(onopen_marker)
    require(onopen_idx >= 0, "socket.onopen handler not found")
    onopen_block = app[onopen_idx:app.find("      };", onopen_idx) + len("      };")]
    require("dispatch(refreshAgents());" in onopen_block, "onopen should still refresh agents")
    require("dispatch(fetchSelectedChat({ agentId: selected }));" not in onopen_block, "onopen should not refresh selected chat directly anymore")

    require("dispatch(fetchSelectedChat({ agentId: selectedAgentId }));" not in ws, "message-less direct chat WS path should not explicitly fetch")
    require("dispatch(fetchGuideChat());" not in ws, "message-less guide WS path should not explicitly fetch")
    require("dispatch(appendMessage({ agentId, message: payload.message }));" in ws, "embedded direct chat messages should append locally")
    require("dispatch(appendMessage({ agentId: GUIDE_AGENT_ID, message: payload.message }));" in ws, "embedded guide messages should append locally")
    require("dispatch(chatEndpoints.util.updateQueryData('fetchDirectChat'" in ws, "record-bearing direct chat events should patch RTKQ cache")
    require("dispatch(chatEndpoints.util.updateQueryData('fetchGuideChat'" in ws, "record-bearing guide events should patch RTKQ cache")

    print("UI LIVE CHAT WS FALLBACK TEST PASSED")


if __name__ == "__main__":
    main()
