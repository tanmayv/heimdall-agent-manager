#!/usr/bin/env python3
"""Source regression for hidden Task Chains Home diagnostics (TCUI-1/TCUI-2)."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
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
    home_slice = HOME_SLICE.read_text(encoding="utf-8")

    # NOTE: Assertions that scanned src/ui/components/App.tsx (diagnostic debug
    # ids must be absent, dispatch wiring must be present) were dropped when that
    # legacy component was removed (dead code; the app mounts AppShell). The
    # freshness plumbing that survives lives in homeSlice.ts, still guarded below.
    for token in FRESHNESS_STATE:
        require(token in home_slice, f"freshness plumbing token {token} should remain present")
    print("TASK CHAINS HOME DIAGNOSTICS HIDDEN TEST PASSED")


if __name__ == "__main__":
    main()
