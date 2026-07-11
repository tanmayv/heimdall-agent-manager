#!/usr/bin/env python3
"""Source regression checks for live chat WS fallback behavior in App.tsx."""

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

    onopen_marker = "socket.onopen = () => {"
    onopen_idx = src.find(onopen_marker)
    require(onopen_idx >= 0, "socket.onopen handler not found")
    onopen_block = src[onopen_idx:src.find("      };", onopen_idx) + len("      };")]
    require("dispatch(refreshAgents());" in onopen_block, "onopen should still refresh agents")
    require("selectedAgentRef.current" in onopen_block, "onopen should read selectedAgentRef")
    require("dispatch(fetchSelectedChat({ agentId: selected }));" in onopen_block, "onopen should refresh selected chat")

    chat_marker = "if (payload?.type === 'chat_event') {"
    chat_idx = src.find(chat_marker)
    require(chat_idx >= 0, "chat_event handler not found")
    chat_block = src[chat_idx:src.find("      };", chat_idx) + len("      };")]
    require("dispatch(chatEventReceived(payload));" in chat_block, "chat_event should update unread/session metadata")
    require("payload.message" in chat_block and "dispatch(appendMessage" in chat_block, "embedded message path should append")
    require("dispatch(fetchSelectedChat({ agentId: selectedDirectAgent }));" in chat_block, "message-less chat_event should fetch chat")

    print("UI LIVE CHAT WS FALLBACK TEST PASSED")


if __name__ == "__main__":
    main()
