#!/usr/bin/env python3
"""Source regression for hidden Task Chains Home diagnostics (TCUI-1/TCUI-2)."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "src/ui/components/App.tsx"
HOME_SLICE = ROOT / "src/ui/store/homeSlice.ts"

DIAGNOSTIC_DEBUG_IDS = [
    "home-http-load-evidence",
    "home-periodic-evidence",
    "home-ws-evidence",
    "home-local-action-evidence",
]
DIAGNOSTIC_TEXT = [
    "HTTP load:",
    "Periodic revalidation:",
    "Last WS refetch:",
    "Local action:",
]
FRESHNESS_STATE = [
    "lastHttpLoadUnixMs",
    "lastPeriodicRefreshUnixMs",
    "lastWsRefreshReason",
    "lastLocalAction",
    "httpLoadCompleted",
    "wsRefreshRequested",
]


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    app = APP.read_text(encoding="utf-8")
    home_slice = HOME_SLICE.read_text(encoding="utf-8")

    for debug_id in DIAGNOSTIC_DEBUG_IDS:
        require(debug_id not in app, f"HomePage should not render diagnostic debug id {debug_id}")
    for text in DIAGNOSTIC_TEXT:
        require(text not in app, f"HomePage should not render operator diagnostic text {text!r}")
    for token in FRESHNESS_STATE:
        require(token in home_slice or token in app, f"freshness plumbing token {token} should remain present")
    require("dispatch(httpLoadCompleted" in app, "HTTP load completion dispatch should remain wired")
    require("dispatch(wsRefreshRequested" in app, "websocket refresh dispatch should remain wired")
    print("TASK CHAINS HOME DIAGNOSTICS HIDDEN TEST PASSED")


if __name__ == "__main__":
    main()
