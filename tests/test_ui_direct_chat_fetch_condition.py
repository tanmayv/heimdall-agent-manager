#!/usr/bin/env python3
"""Regression check: explicit direct-agent chat fetches must not be blocked.

Agent detail and running-agent chat panes fetch by explicit agentId without making
that agent the global selectedAgentId. The thunk condition must allow those
fetches even when there is no existing chat cache yet; otherwise sends reach the
agent but the chat window remains empty.
"""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
CHAT_SLICE = ROOT / "src" / "ui" / "store" / "chatSlice.ts"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    src = CHAT_SLICE.read_text(encoding="utf-8")
    require("const hasExplicitAgentId" in src, "fetchSelectedChat condition should detect explicit agent ids")
    require("typeof payload === 'string'" in src, "string payloads should count as explicit agent ids")
    require("payload.agentId" in src, "object payload agentId should count as explicit")
    require(
        re.search(r"if \(!hasExplicitAgentId && !isSelected && !isCached\)\s*\{\s*return false;\s*\}", src),
        "condition should only block uncached non-selected fetches when no explicit agentId was requested",
    )
    require(
        "if (!isSelected && !isCached)" not in src,
        "old unconditional uncached/non-selected guard must not remain",
    )
    print("UI DIRECT CHAT FETCH CONDITION TEST PASSED")


if __name__ == "__main__":
    main()
