#!/usr/bin/env python3
"""Source regression for New Chain progress gating until coordinator is ready."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "src/ui/components/App.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    src = APP.read_text(encoding="utf-8")
    require('chainCreationProgress' in src, "App should track chain creation progress state")
    require('ChainCreationProgressModal' in src, "progress modal component missing")
    require('elapsedMs >= 20_000' in src, "progress wait must timeout after 20 seconds")
    require('coordinatorReady' in src and 'openChain(chainCreationProgress.chainId)' in src, "chain should open only after coordinator readiness")
    require('dispatch(focusChainView(chainId));' in src, "new chain creation should request coordinator boot/focus")
    require('data-debug-id="chain-creation-progress-modal"' in src, "progress modal debug id missing")
    require('Coordinator running / start-success' in src, "start-success/running checkpoint missing")
    print("UI CHAIN CREATION PROGRESS TEST PASSED")


if __name__ == "__main__":
    main()
