#!/usr/bin/env python3
"""Static regression checks for passive UI event API churn.

Guards the performance fix: hover, typing, passive scroll, and route churn must
not be wired to broad durable fetch/focus APIs.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHAIN_VIEW = ROOT / "src" / "ui" / "store" / "chainViewSlice.ts"
WORKSPACE = ROOT / "src" / "ui" / "api" / "endpoints" / "workspace.ts"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    chain_view = CHAIN_VIEW.read_text(encoding="utf-8")
    workspace = WORKSPACE.read_text(encoding="utf-8")

    # NOTE: the bulk of this guard scanned src/ui/components/App.tsx (URL task-log
    # route guards, passive focus/scroll fetch avoidance, explicit chain-focus
    # wiring, WS delegation). Those assertions were dropped when that legacy
    # component was removed (dead code; the app mounts AppShell). The store/endpoint
    # ownership invariants that survive are guarded below.

    # Chain focus ownership lives behind workspace RTKQ endpoints/mutations.
    require("return daemonApi.focusTaskChain({ ...auth(session), chainId });" in workspace, "workspaceApi.focusChain should own focusTaskChain")
    require("daemonApi.focusTaskChain" not in chain_view, "chainViewSlice should not directly own focusTaskChain anymore")

    print("PASS: passive UI event API churn static checks")


if __name__ == "__main__":
    main()
